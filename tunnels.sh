#!/usr/bin/env bash
set -uo pipefail

# Find the script and its default config in the same directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
CONFIG="${1:-$SCRIPT_DIR/tunnels.conf}"

# A newly opened system-terminal window runs the script in this lightweight
# mode. It connects directly instead of starting another tunnel dashboard.
if [[ "${1:-}" == --connect-base64 ]]; then
    encoded_target="${2:-}"

    if [[ -z "$encoded_target" ||
          ! "$encoded_target" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
        echo 'Invalid encoded SSH target.' >&2
        exit 2
    fi

    if [[ "$(uname -s)" == Darwin ]]; then
        target=$(printf '%s' "$encoded_target" | base64 -D) || exit 2
    else
        target=$(printf '%s' "$encoded_target" | base64 -d) || exit 2
    fi

    if [[ -z "$target" || "$target" == -* ]]; then
        echo 'Invalid SSH target.' >&2
        exit 2
    fi

    exec ssh "$target"
fi

CONNECT_TIMEOUT=10
STARTUP_WAIT=1

declare -a TUNNEL_IDS=()
declare -a PIDS=()
declare -a SHELL_NAMES=()
declare -a SHELL_TARGETS=()

declare -A LABEL=()
declare -A SSH_HOST=()
declare -A SSH_USER=()
declare -A IDENTITY=()
declare -A FORWARD_COUNT=()
declare -A FORWARD=()
declare -A STATUS=()
declare -A PID_TO_TUNNEL=()

CURRENT_ALIAS=""
CURRENT_SSH_HOST=""
CURRENT_SSH_USER=""
CURRENT_IDENTITY=""
CURRENT_GROUP=""
GROUP_TUNNEL_ID=""
GROUP_FORWARD_INDEX=0
MACHINE_NUMBER=0

UI_MODE="dashboard"
SHELL_SELECTION=0
MENU_SCROLL=0
MESSAGE=""
KEY=""

STOPPING=0
EXIT_REQUESTED=0
REDRAW_NEEDED=1
FORCE_REPAINT=1
RESIZE_EVENT=0
USE_COLOUR=0
ALT_SCREEN=0
TTY_CONFIGURED=0
TTY_STATE=""
TTY_OPEN=0
LOG_DIR=""

TERM_WIDTH=80
TERM_HEIGHT=24
BODY_ROW=1
BODY_LAST_ROW=1
PAINTED_MODE=""
PAINTED_WIDTH=0
PAINTED_HEIGHT=0
declare -a ROW_CACHE=()
declare -a ROW_CACHE_VALID=()
declare -a ROW_SEEN=()
RENDER_BUFFER=""
RENDER_CAPTURE_FILE=""

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    USE_COLOUR=1
fi

# Config syntax:
#   machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP
#   tunnel  DISPLAY_NAME LOCAL_FORWARD
#   shell   DISPLAY_NAME SSH_TARGET
#
# Each tunnel belongs to the most recently declared machine.
# GROUP=yes: all that machine's forwards share an SSH process.
# GROUP=no:  each forward gets its own SSH process.

machine() {
    if (($# != 5)); then
        echo 'Usage: machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP' >&2
        return 2
    fi

    case "$5" in
        yes|no) ;;
        *)
            echo "Error: GROUP for '$1' must be 'yes' or 'no'." >&2
            return 2
            ;;
    esac

    CURRENT_ALIAS=$1
    CURRENT_SSH_HOST=$2
    CURRENT_SSH_USER=$3
    CURRENT_IDENTITY=$4
    CURRENT_GROUP=$5

    if [[ "$CURRENT_IDENTITY" == "~/"* ]]; then
        CURRENT_IDENTITY="$HOME/${CURRENT_IDENTITY:2}"
    fi

    MACHINE_NUMBER=$((MACHINE_NUMBER + 1))
    GROUP_TUNNEL_ID="machine-${MACHINE_NUMBER}-group"
    GROUP_FORWARD_INDEX=0
}

tunnel() {
    if [[ -z "$CURRENT_ALIAS" ]]; then
        echo 'Error: define a machine before its tunnels.' >&2
        return 2
    fi

    if (($# != 2)); then
        echo 'Usage: tunnel DISPLAY_NAME LOCAL_FORWARD' >&2
        return 2
    fi

    local name=$1
    local forward=$2
    local id index local_port display
    local -a parts=()

    # Hostname/IPv4 forms:
    #   LOCAL_PORT:DEST_HOST:DEST_PORT
    #   BIND_ADDRESS:LOCAL_PORT:DEST_HOST:DEST_PORT
    IFS=: read -r -a parts <<< "$forward"

    case "${#parts[@]}" in
        3) local_port=${parts[0]} ;;
        4) local_port=${parts[1]} ;;
        *)
            echo "Error: unrecognized forward format: $forward" >&2
            return 2
            ;;
    esac

    printf -v display '%5s : %s' "$local_port" "$name"

    if [[ "$CURRENT_GROUP" == yes ]]; then
        id=$GROUP_TUNNEL_ID

        if ((GROUP_FORWARD_INDEX == 0)); then
            TUNNEL_IDS+=("$id")
            LABEL["$id"]=""
            SSH_HOST["$id"]=$CURRENT_SSH_HOST
            SSH_USER["$id"]=$CURRENT_SSH_USER
            IDENTITY["$id"]=$CURRENT_IDENTITY
            FORWARD_COUNT["$id"]=0
            STATUS["$id"]="PENDING"
        fi

        index=$GROUP_FORWARD_INDEX
        GROUP_FORWARD_INDEX=$((GROUP_FORWARD_INDEX + 1))

        FORWARD["$id:$index"]=$forward
        FORWARD_COUNT["$id"]=$GROUP_FORWARD_INDEX

        if [[ -n "${LABEL[$id]}" ]]; then
            LABEL["$id"]+=", "
        fi
        LABEL["$id"]+="$display"
    else
        id="tunnel-${#TUNNEL_IDS[@]}"
        TUNNEL_IDS+=("$id")

        LABEL["$id"]=$display
        SSH_HOST["$id"]=$CURRENT_SSH_HOST
        SSH_USER["$id"]=$CURRENT_SSH_USER
        IDENTITY["$id"]=$CURRENT_IDENTITY
        FORWARD["$id:0"]=$forward
        FORWARD_COUNT["$id"]=1
        STATUS["$id"]="PENDING"
    fi
}

shell() {
    if (($# != 2)); then
        echo 'Usage: shell DISPLAY_NAME SSH_TARGET' >&2
        return 2
    fi

    if [[ "$2" == -* ]]; then
        echo "Error: SSH target cannot begin with '-': $2" >&2
        return 2
    fi

    SHELL_NAMES+=("$1")
    SHELL_TARGETS+=("$2")
}

if [[ ! -r "$CONFIG" ]]; then
    echo "Cannot read config file: $CONFIG" >&2
    exit 1
fi

# The config is sourced as Bash code; only use a config you trust.
if ! source "$CONFIG"; then
    echo "Error while reading config file: $CONFIG" >&2
    exit 1
fi

if ((${#TUNNEL_IDS[@]} == 0 && ${#SHELL_NAMES[@]} == 0)); then
    echo "No tunnels or shell connections configured in $CONFIG" >&2
    exit 1
fi

colour() {
    local code=$1 text=$2

    if ((USE_COLOUR)); then
        printf '\033[%sm%s\033[0m' "$code" "$text"
    else
        printf '%s' "$text"
    fi
}

status_badge() {
    local status=$1 padded code

    printf -v padded ' %-9s' "$status"

    case "$status" in
        RUNNING)  code='38;2;181;245;190;48;2;27;67;44' ;;
        STARTING) code='38;2;185;235;250;48;2;29;60;76' ;;
        STOPPED)  code='38;2;255;190;190;48;2;92;37;49' ;;
        SKIPPED)  code='38;2;255;222;165;48;2;89;67;36' ;;
        PENDING)  code='38;2;205;198;220;48;2;57;52;70' ;;
        *)        code='0' ;;
    esac

    colour "$code" "$padded"
}

terminal_width() {
    local width

    if command -v tput >/dev/null 2>&1; then
        width=$(tput cols 2>/dev/null || printf '%s' "${COLUMNS:-80}")
    else
        width="${COLUMNS:-80}"
    fi

    [[ "$width" =~ ^[0-9]+$ ]] || width=80
    printf '%s' "$width"
}

terminal_height() {
    local height

    if command -v tput >/dev/null 2>&1; then
        height=$(tput lines 2>/dev/null || printf '%s' "${LINES:-24}")
    else
        height="${LINES:-24}"
    fi

    [[ "$height" =~ ^[0-9]+$ ]] || height=24
    printf '%s' "$height"
}

truncate_text() {
    local text=$1 max=$2

    if ((${#text} > max)); then
        if ((max > 3)); then
            printf '%s...' "${text:0:max-3}"
        else
            printf '%s' "${text:0:max}"
        fi
    else
        printf '%s' "$text"
    fi
}

# Used by the shutdown and retry screens.
render_header() {
    local title='  ✦ SSH TUNNEL WIZARD ✦  '
    local subtitle='  Your tunnels, conjured and watched over.'
    local width remaining

    width=$(terminal_width)
    remaining=$((width - 2 - ${#title}))

    printf '  '
    colour '1;38;2;255;178;225;48;2;42;24;64' "$title"

    if ((remaining > 0)); then
        colour '38;2;204;181;247' \
            "$(truncate_text "$subtitle" "$remaining")"
    fi

    printf '\n\n'
}

# Draw individual rows by cursor position so the controls stay at the
# bottom, even when there are many tunnels or saved shells. Cache the
# complete rendered row (including colour codes), not just its text.
begin_screen() {
    local footer_rows=$1
    local force_clear=0

    TERM_WIDTH=$(terminal_width)
    TERM_HEIGHT=$(terminal_height)
    BODY_ROW=1
    BODY_LAST_ROW=$((TERM_HEIGHT - footer_rows))
    ROW_SEEN=()
    RENDER_BUFFER=""

    if ((FORCE_REPAINT)) || [[ "$PAINTED_MODE" != "$UI_MODE" ]] ||
       ((TERM_WIDTH != PAINTED_WIDTH || TERM_HEIGHT != PAINTED_HEIGHT)); then
        force_clear=1
        ROW_CACHE=()
        ROW_CACHE_VALID=()
    fi

    RENDER_CAPTURE_FILE=$(mktemp "${TMPDIR:-/tmp}/ssh-tunnel-render.XXXXXX") || return 1

    if ((force_clear)); then
        RENDER_BUFFER=$'\033[H\033[J'
    fi

    PAINTED_MODE=$UI_MODE
    PAINTED_WIDTH=$TERM_WIDTH
    PAINTED_HEIGHT=$TERM_HEIGHT
    FORCE_REPAINT=0
}

paint_row() {
    local row=$1 content render_status=0
    shift

    "$@" >"$RENDER_CAPTURE_FILE" || render_status=$?
    content=$(<"$RENDER_CAPTURE_FILE")
    ROW_SEEN[$row]=1

    if ((render_status != 0)); then
        return "$render_status"
    fi

    if [[ ${ROW_CACHE_VALID[$row]:-0} == 1 && "${ROW_CACHE[$row]}" == "$content" ]]; then
        return
    fi

    # Clear only changed rows; reset attributes before erasing a coloured
    # row so shorter replacement text cannot leave a styled tail behind.
    RENDER_BUFFER+="$(printf '\033[%d;1H\033[0m\033[2K%s' "$row" "$content")"
    ROW_CACHE[$row]=$content
    ROW_CACHE_VALID[$row]=1
}

finish_screen() {
    local row

    # Rows left over from a longer body or a moved footer must also go.
    for row in "${!ROW_CACHE[@]}"; do
        if [[ ! ${ROW_SEEN[$row]+present} ]]; then
            if [[ -n "${ROW_CACHE[$row]}" ]]; then
                RENDER_BUFFER+="$(printf '\033[%d;1H\033[0m\033[2K' "$row")"
            fi
            unset "ROW_CACHE[$row]"
            unset "ROW_CACHE_VALID[$row]"
        fi
    done

    printf '%s' "$RENDER_BUFFER"
    if [[ -n "$RENDER_CAPTURE_FILE" ]]; then
        rm -f -- "$RENDER_CAPTURE_FILE"
        RENDER_CAPTURE_FILE=""
    fi
    RENDER_BUFFER=""
}

body_line() {
    if ((BODY_ROW >= 1 && BODY_ROW <= BODY_LAST_ROW)); then
        paint_row "$BODY_ROW" "$@"
    fi

    BODY_ROW=$((BODY_ROW + 1))
}

footer_at() {
    local row=$1
    shift

    if ((row >= 1 && row <= TERM_HEIGHT)); then
        paint_row "$row" "$@"
    fi
}

print_clipped_line() {
    local max=$((TERM_WIDTH - 1))

    if ((max > 0)); then
        truncate_text "$1" "$max"
    fi
}

render_header_line() {
    local title='  ✦ SSH TUNNEL WIZARD ✦  '
    local subtitle='  Your tunnels, conjured and watched over.'
    local max=$((TERM_WIDTH - 1))
    local remaining shown padding

    ((max > 0)) || return

    if ((max <= 2)); then
        colour '1;38;2;255;178;225;48;2;42;24;64' \
            "$(truncate_text '  ' "$max")"
        return
    fi

    printf '  '
    remaining=$((max - 2))

    if ((remaining < ${#title})); then
        colour '1;38;2;255;178;225;48;2;42;24;64' \
            "$(truncate_text "$title" "$remaining")"
        return
    fi

    colour '1;38;2;255;178;225;48;2;42;24;64' "$title"
    remaining=$((remaining - ${#title}))

    if ((remaining > 0)); then
        shown=$(truncate_text "$subtitle" "$remaining")
        printf -v padding '%*s' "$((remaining - ${#shown}))" ''

        colour '38;2;204;181;247;48;2;42;24;64' \
            "${shown}${padding}"
    fi
}

render_rule() {
    local max=$((TERM_WIDTH - 1))
    local dash_count rule

    ((max >= 3)) || return

    # Leave the terminal's final column untouched to prevent wrapping.
    # The small square caps the extended divider.
    dash_count=$((max - 3))
    printf -v rule '%*s' "$dash_count" ''
    rule=${rule// /─}

    colour '2' "  ${rule}▪"
}

render_message() {
    if [[ -n "$MESSAGE" ]]; then
        print_clipped_line "  $MESSAGE"
    fi
}

render_global_controls() {
    local full='  Ctrl+R  Restart tunnels     Ctrl+C  Stop and exit'

    if ((TERM_WIDTH <= ${#full})); then
        print_clipped_line '  Ctrl+R Restart    Ctrl+C Exit'
        return
    fi

    printf '  '
    colour '1;36' 'Ctrl+R'
    printf '  Restart tunnels     '
    colour '1;36' 'Ctrl+C'
    printf '  Stop and exit'
}

render_dashboard_shell_controls() {
    local full='  1–9 Open instantly    ←/→/↑/↓ Navigate    Enter Open'

    if ((TERM_WIDTH > ${#full})); then
        printf '%s' "$full"
    else
        print_clipped_line '  1–9 Open    Arrows Move    Enter Open'
    fi
}

render_dashboard_global_controls() {
    local full='  S  Saved SSH shells    Ctrl+R  Restart tunnels    Ctrl+C  Stop and exit'

    if ((TERM_WIDTH <= ${#full})); then
        print_clipped_line '  S Menu  Ctrl+R Restart  Ctrl+C Exit'
        return
    fi

    printf '  '
    colour '1;36' 'S'
    printf '  Saved SSH shells    '
    colour '1;36' 'Ctrl+R'
    printf '  Restart tunnels    '
    colour '1;36' 'Ctrl+C'
    printf '  Stop and exit'
}

render_dashboard_footer() {
    if ((${#SHELL_NAMES[@]} > 0)); then
        if [[ -n "$MESSAGE" ]]; then
            footer_at "$((TERM_HEIGHT - 2))" render_message
        fi

        footer_at "$((TERM_HEIGHT - 1))" render_dashboard_shell_controls
        footer_at "$TERM_HEIGHT" render_dashboard_global_controls
    else
        if [[ -n "$MESSAGE" ]]; then
            footer_at "$((TERM_HEIGHT - 1))" render_message
        fi

        footer_at "$TERM_HEIGHT" render_global_controls
    fi
}

render_tunnel_heading() {
    local label_width=$1 host_width=$2

    printf '  %-*s  %-10s  %s' \
        "$label_width" "PORT : TUNNEL" "STATUS" \
        "$(truncate_text 'SSH SERVER' "$host_width")"
}

render_tunnel_row() {
    local id=$1 label_width=$2 host_width=$3
    local label host

    label=$(truncate_text "${LABEL[$id]}" "$label_width")
    host=$(truncate_text "${SSH_HOST[$id]}" "$host_width")

    printf '  %-*s  ' "$label_width" "$label"
    status_badge "${STATUS[$id]}"
    printf '  %s' "$host"
}

render_hidden_tunnels() {
    print_clipped_line "  … $1 more tunnel(s); enlarge the window to see them."
}

render_shell_cell() {
    local index=$1 cell_width=$2
    local marker=' ' hotkey=' ' name name_width padded_name

    if ((index == SHELL_SELECTION)); then
        marker='›'
    fi

    if ((index < 9)); then
        hotkey=$((index + 1))
    fi

    name_width=$((cell_width - 4))
    name=$(truncate_text "${SHELL_NAMES[$index]}" "$name_width")
    printf -v padded_name '%-*s' "$name_width" "$name"

    if ((index == SHELL_SELECTION)); then
        # Dark-grey background (#4B4B52), with the cyan marker
        # and pink number/name.
        colour '1;36;48;2;75;75;82' "$marker"
        colour '1;35;48;2;75;75;82' \
            " $hotkey $padded_name"
    else
        printf '%s %s %s' "$marker" "$hotkey" "$padded_name"
    fi
}

render_shell_row() {
    local first=$1 count=$2 cell_width=$3
    local index

    printf '  '

    for ((index = first; index < first + 3 && index < count; index++)); do
        if ((index > first)); then
            printf '  '
        fi

        render_shell_cell "$index" "$cell_width"
    done
}

dashboard_shell_count() {
    local count=${#SHELL_NAMES[@]}
    ((count > 9)) && count=9
    printf '%s' "$count"
}

render_dashboard() {
    local shell_count=${#SHELL_NAMES[@]}
    local top_count tunnel_count label_width host_width
    local grid_lines available_tunnel_rows visible_tunnels hidden_tunnels
    local cell_width index id footer_rows

    if ((shell_count > 0)); then
        footer_rows=2
    else
        footer_rows=1
    fi

    if [[ -n "$MESSAGE" ]]; then
        footer_rows=$((footer_rows + 1))
    fi

    begin_screen "$footer_rows"

    body_line render_header_line
    body_line :

    top_count=$(dashboard_shell_count)
    tunnel_count=${#TUNNEL_IDS[@]}

    if ((TERM_WIDTH < 48)); then
        body_line print_clipped_line \
            '  Widen this window to see the tunnel table.'
    elif ((tunnel_count > 0)); then
        label_width=$((TERM_WIDTH * 45 / 100))
        ((label_width < 18)) && label_width=18

        # Leave the rightmost terminal column unused to avoid wrapping.
        host_width=$((TERM_WIDTH - label_width - 17))
        ((host_width < 1)) && host_width=1

        body_line render_tunnel_heading "$label_width" "$host_width"
        body_line render_rule

        # Two blank rows, a title, a rule, then the top-nine grid.
        grid_lines=0

        if ((shell_count > 0)); then
            if ((TERM_WIDTH < 36)); then
                grid_lines=5
            else
                grid_lines=$((4 + (top_count + 2) / 3))
            fi
        fi

        available_tunnel_rows=$((BODY_LAST_ROW - BODY_ROW + 1 - grid_lines))
        ((available_tunnel_rows < 0)) && available_tunnel_rows=0

        visible_tunnels=$tunnel_count
        if ((visible_tunnels > available_tunnel_rows)); then
            visible_tunnels=$available_tunnel_rows
            ((visible_tunnels > 0)) && visible_tunnels=$((visible_tunnels - 1))
        fi

        for ((index = 0; index < visible_tunnels; index++)); do
            id=${TUNNEL_IDS[$index]}
            body_line render_tunnel_row "$id" "$label_width" "$host_width"
        done

        hidden_tunnels=$((tunnel_count - visible_tunnels))
        if ((hidden_tunnels > 0 && available_tunnel_rows > 0)); then
            body_line render_hidden_tunnels "$hidden_tunnels"
        fi
    else
        body_line print_clipped_line '  No port forwards configured.'
    fi

    if ((shell_count > 0)); then
        body_line :
        body_line :
        body_line print_clipped_line '  SAVED SSH SHELLS (TOP 9)'
        body_line render_rule

        if ((TERM_WIDTH < 36)); then
            body_line print_clipped_line \
                '  Widen this window to see the three-column grid.'
        else
            # Keep the final terminal column free to prevent wrapping.
            cell_width=$(((TERM_WIDTH - 7) / 3))

            for ((index = 0; index < top_count; index += 3)); do
                body_line render_shell_row "$index" "$top_count" "$cell_width"
            done
        fi
    fi

    render_dashboard_footer
    finish_screen
}

render_menu_footer() {
    local full='  1–9 Open instantly    ←/→/↑/↓ Navigate    Enter Open    Esc/Q Return'

    if ((TERM_WIDTH > ${#full})); then
        if [[ -n "$MESSAGE" ]]; then
            footer_at "$((TERM_HEIGHT - 1))" render_message
        fi
        footer_at "$TERM_HEIGHT" printf '%s' "$full"
    else
        if [[ -n "$MESSAGE" ]]; then
            footer_at "$((TERM_HEIGHT - 2))" render_message
        fi
        footer_at "$((TERM_HEIGHT - 1))" print_clipped_line \
            '  1–9 Open    Arrows Navigate'
        footer_at "$TERM_HEIGHT" print_clipped_line \
            '  Enter Open    Esc/Q Return'
    fi
}

render_shell_menu() {
    local count=${#SHELL_NAMES[@]}
    local full='  1–9 Open instantly    ←/→/↑/↓ Navigate    Enter Open    Esc/Q Return'
    local cell_width grid_rows total_lines available selected_line
    local max_scroll line grid_row footer_rows

    if (($(terminal_width) > ${#full})); then
        footer_rows=1
    else
        footer_rows=2
    fi

    if [[ -n "$MESSAGE" ]]; then
        footer_rows=$((footer_rows + 1))
    fi

    begin_screen "$footer_rows"

    body_line render_header_line
    body_line :
    body_line printf '%s' '  SAVED SSH SHELLS'
    body_line render_rule

    # The full S menu includes connections after #9.
    if ((TERM_WIDTH < 36)); then
        body_line print_clipped_line \
            '  Widen this window to see the three-column grid.'
    else
        cell_width=$(((TERM_WIDTH - 7) / 3))
        grid_rows=$(((count + 2) / 3))
        total_lines=$grid_rows

        if ((count > 9)); then
            total_lines=$((total_lines + 3))
        fi

        available=$((BODY_LAST_ROW - BODY_ROW + 1))

        if ((available > 0)); then
            selected_line=$((SHELL_SELECTION / 3))
            if ((SHELL_SELECTION >= 9)); then
                selected_line=$((selected_line + 3))
            fi

            if ((selected_line < MENU_SCROLL)); then
                MENU_SCROLL=$selected_line
            elif ((selected_line >= MENU_SCROLL + available)); then
                MENU_SCROLL=$((selected_line - available + 1))
            fi

            max_scroll=$((total_lines - available))
            ((max_scroll < 0)) && max_scroll=0
            ((MENU_SCROLL > max_scroll)) && MENU_SCROLL=$max_scroll

            for ((line = MENU_SCROLL;
                   line < total_lines && line < MENU_SCROLL + available;
                   line++)); do
                if ((count > 9 && line == 3)); then
                    body_line :
                elif ((count > 9 && line == 4)); then
                    body_line colour '2' '  MORE CONNECTIONS'
                elif ((count > 9 && line == 5)); then
                    body_line :
                else
                    grid_row=$line
                    if ((count > 9 && line >= 6)); then
                        grid_row=$((line - 3))
                    fi

                    body_line render_shell_row \
                        "$((grid_row * 3))" "$count" "$cell_width"
                fi
            done
        fi
    fi

    render_menu_footer
    finish_screen
}

render_screen() {
    local resize_event=$RESIZE_EVENT

    if [[ "$UI_MODE" == menu ]]; then
        render_shell_menu
    else
        render_dashboard
    fi

    # A resize delivered during a render still needs its own full repaint.
    if ((RESIZE_EVENT == resize_event)); then
        REDRAW_NEEDED=0
    fi
}

# Move horizontally within the current row, wrapping at its edges.
# The dashboard passes a count of at most nine; the S menu uses all shells.
move_shell_horizontal() {
    local direction=$1
    local count=${2:-${#SHELL_NAMES[@]}}
    local row_start row_size column

    row_start=$((SHELL_SELECTION / 3 * 3))
    row_size=$((count - row_start))
    ((row_size > 3)) && row_size=3

    column=$((SHELL_SELECTION - row_start))
    column=$(((column + direction + row_size) % row_size))

    SHELL_SELECTION=$((row_start + column))
    REDRAW_NEEDED=1
}

# Move between rows, wrapping top/bottom. A partial destination row
# uses its last available cell if the current column doesn't exist.
move_shell_vertical() {
    local direction=$1
    local count=${2:-${#SHELL_NAMES[@]}}
    local rows row column destination

    rows=$(((count + 2) / 3))
    row=$((SHELL_SELECTION / 3))
    column=$((SHELL_SELECTION % 3))

    row=$(((row + direction + rows) % rows))
    destination=$((row * 3 + column))

    if ((destination >= count)); then
        destination=$((count - 1))
    fi

    SHELL_SELECTION=$destination
    REDRAW_NEEDED=1
}

set_tty_mode() {
    if [[ -z "$TTY_STATE" ]]; then
        TTY_STATE=$(stty -g <&3 2>/dev/null) || return 1
    fi

    # Keep ISIG enabled: Ctrl+C remains a real interrupt.
    stty -echo -icanon isig min 1 time 0 <&3 || return 1
    TTY_CONFIGURED=1
}

restore_tty_mode() {
    if ((TTY_CONFIGURED)); then
        stty "$TTY_STATE" <&3 2>/dev/null || true
        TTY_CONFIGURED=0
    fi
}

restore_screen() {
    restore_tty_mode

    if ((ALT_SCREEN)); then
        printf '\033[?25h\033[?1049l'
        ALT_SCREEN=0
    fi
}

stop_tunnels() {
    local pid

    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null || true
    done

    for pid in "${PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    PIDS=()
    PID_TO_TUNNEL=()
}

cleanup() {
    ((STOPPING)) && return
    STOPPING=1

    trap '' INT TERM
    trap - EXIT WINCH

    if ((ALT_SCREEN)); then
        printf '\033[H\033[J'
        render_header
        printf '  Closing the portals and stopping SSH connections...\n'
    fi

    stop_tunnels

    if [[ -n "$RENDER_CAPTURE_FILE" ]]; then
        rm -f -- "$RENDER_CAPTURE_FILE"
        RENDER_CAPTURE_FILE=""
    fi

    if [[ -n "$LOG_DIR" && -d "$LOG_DIR" ]]; then
        rm -rf -- "$LOG_DIR"
    fi

    if ((ALT_SCREEN)); then
        printf '  All tracked tunnel processes have stopped.\n'
        sleep 1
    fi

    restore_screen

    if ((TTY_OPEN)); then
        exec 3>&-
        TTY_OPEN=0
    fi
}

trap cleanup EXIT
trap 'EXIT_REQUESTED=1' INT TERM
trap 'RESIZE_EVENT=$((RESIZE_EVENT + 1)); FORCE_REPAINT=1; REDRAW_NEEDED=1' WINCH

start_one() {
    local id=$1
    local index
    local -a ssh_args=(
        -n
        -N
        -o 'BatchMode=yes'
        -o "ConnectTimeout=${CONNECT_TIMEOUT}"
        -o 'ExitOnForwardFailure=yes'
        -i "${IDENTITY[$id]}"
        -l "${SSH_USER[$id]}"
    )

    for ((index = 0; index < FORWARD_COUNT[$id]; index++)); do
        ssh_args+=( -L "${FORWARD[$id:$index]}" )
    done

    ssh "${ssh_args[@]}" "${SSH_HOST[$id]}" \
        >/dev/null 2>"$LOG_DIR/$id.log" &

    local pid=$!
    PIDS+=("$pid")
    PID_TO_TUNNEL["$pid"]=$id
}

start_with_retry() {
    local id=$1
    local pid answer error_line

    while true; do
        ((EXIT_REQUESTED)) && return

        STATUS["$id"]="STARTING"
        render_dashboard

        start_one "$id"
        pid=${PIDS[-1]}

        # Early-exit check, not a remote-service health check.
        sleep "$STARTUP_WAIT"
        ((EXIT_REQUESTED)) && return

        if kill -0 "$pid" 2>/dev/null; then
            STATUS["$id"]="RUNNING"
            render_dashboard
            return
        fi

        wait "$pid" 2>/dev/null || true
        unset 'PIDS[-1]'
        unset "PID_TO_TUNNEL[$pid]"

        STATUS["$id"]="STOPPED"
        render_dashboard

        restore_tty_mode
        printf '\033[?25h\033[H\033[J'
        render_header
        printf "  Could not start '%s'.\n" "${LABEL[$id]}"

        if [[ -s "$LOG_DIR/$id.log" ]]; then
            error_line=$(tail -n 1 -- "$LOG_DIR/$id.log" |
                tr -cd '\11\40-\176')
            printf '  SSH: %s\n' "$error_line"
        fi

        printf '  Check VPN/network settings, authentication, and the local port.\n\n'

        answer=""
        read -r -p '  Retry? [y/N] ' answer <&3 || true
        ((EXIT_REQUESTED)) && return

        printf '\033[?25l'
        set_tty_mode || return

        case "$answer" in
            y|Y|yes|YES) ;;
            *)
                STATUS["$id"]="SKIPPED"
                render_dashboard
                return
                ;;
        esac
    done
}

poll_tunnels() {
    local index pid id

    for index in "${!PIDS[@]}"; do
        pid=${PIDS[$index]}

        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null || true
            id=${PID_TO_TUNNEL[$pid]:-}

            if [[ -n "$id" ]]; then
                STATUS["$id"]="STOPPED"
                unset "PID_TO_TUNNEL[$pid]"
                MESSAGE="Tunnel stopped: ${LABEL[$id]}. Ctrl+R restarts all."
                REDRAW_NEEDED=1
            fi

            unset "PIDS[$index]"
        fi
    done
}

running_in_wezterm() {
    [[ -n "${WEZTERM_PANE:-}" || "${TERM_PROGRAM:-}" == WezTerm ]]
}

open_shell_in_current_window() {
    local target=$1
    local name=$2
    local ssh_status

    restore_tty_mode
    printf '\033[?25h\033[H\033[J'
    printf 'SSH shell: %s\n\n' "$name"

    ssh "$target" <&3
    ssh_status=$?

    printf '\nSSH session ended (exit status %s).\n' "$ssh_status"
    read -r -p 'Press Enter to return to the wizard... ' _ <&3 || true

    if ! set_tty_mode; then
        EXIT_REQUESTED=1
        return 1
    fi

    printf '\033[?25l'
    MESSAGE=""
    REDRAW_NEEDED=1
    return 0
}

open_shell_window() {
    local index=$1
    local target=${SHELL_TARGETS[$index]}
    local name=${SHELL_NAMES[$index]}
    local wezterm_bin bash_bin bash_win workdir_win
    local encoded_title encoded_target

    # Keep the original WezTerm behavior when running inside WezTerm.
    if running_in_wezterm && command -v wezterm >/dev/null 2>&1; then
        wezterm_bin=$(command -v wezterm)
        bash_bin=$(command -v bash)

        if command -v cygpath >/dev/null 2>&1; then
            bash_bin=$(cygpath -w "$bash_bin")
        fi

        encoded_title=$(printf '%s' "$name" | base64 | tr -d '\r\n')

        if "$wezterm_bin" cli spawn --new-window --cwd "$HOME" -- \
            "$bash_bin" -c \
            'printf "\033]1337;SetUserVar=SSH_WIZARD_TITLE=%s\007" "$2"; exec ssh "$1"' \
            wizard-shell "$target" "$encoded_title" \
            </dev/null >/dev/null 2>&1; then
            MESSAGE="Opened '$name' in new window."
            return 0
        fi

        # If WezTerm's CLI fails, try the system launcher below.
    fi

    # Encoding avoids inserting the SSH target into a PowerShell,
    # AppleScript, or terminal-launcher command.
    encoded_target=$(printf '%s' "$target" | base64 | tr -d '\r\n')

    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            # Launch Git Bash as a console program. Windows uses its
            # configured default console terminal host for the window.
            if command -v powershell.exe >/dev/null 2>&1 &&
               command -v cygpath >/dev/null 2>&1; then
                bash_bin=$(command -v bash)
                bash_win=$(cygpath -w "$bash_bin")
                workdir_win=$(cygpath -w "$SCRIPT_DIR")

                if WIZARD_BASH_EXE="$bash_win" \
                   WIZARD_WORKDIR="$workdir_win" \
                   WIZARD_TARGET_B64="$encoded_target" \
                   powershell.exe -NoProfile -NonInteractive -Command \
                   'try { $launchArgs = "-c `"exec bash ./tunnels.sh --connect-base64 " + $env:WIZARD_TARGET_B64 + "`""; Start-Process -FilePath $env:WIZARD_BASH_EXE -WorkingDirectory $env:WIZARD_WORKDIR -ArgumentList $launchArgs -ErrorAction Stop } catch { exit 1 }' \
                   </dev/null >/dev/null 2>&1; then
                    MESSAGE="Opened '$name' in new window."
                    return 0
                fi
            fi
            ;;

        Darwin)
            # macOS has no universal launcher for the user's preferred
            # terminal application; use the built-in Terminal app.
            if command -v osascript >/dev/null 2>&1; then
                if osascript \
                    -e 'on run argv' \
                    -e 'tell application "Terminal"' \
                    -e 'do script ("bash " & quoted form of (item 1 of argv) & " --connect-base64 " & item 2 of argv)' \
                    -e 'activate' \
                    -e 'end tell' \
                    -e 'end run' \
                    -- "$SCRIPT_PATH" "$encoded_target" \
                    </dev/null >/dev/null 2>&1; then
                    MESSAGE="Opened '$name' in new window."
                    return 0
                fi
            fi
            ;;

        *)
            # Prefer the desktop's configured terminal launcher.
            if command -v xdg-terminal-exec >/dev/null 2>&1; then
                xdg-terminal-exec bash "$SCRIPT_PATH" \
                    --connect-base64 "$encoded_target" \
                    </dev/null >/dev/null 2>&1 &
                MESSAGE="Opened '$name' in new window."
                return 0
            elif command -v x-terminal-emulator >/dev/null 2>&1; then
                x-terminal-emulator -e bash "$SCRIPT_PATH" \
                    --connect-base64 "$encoded_target" \
                    </dev/null >/dev/null 2>&1 &
                MESSAGE="Opened '$name' in new window."
                return 0
            fi
            ;;
    esac

    # Last resort: connect without opening another terminal.
    open_shell_in_current_window "$target" "$name"
}

read_key() {
    local first="" next=""
    local i

    KEY=""

    if ! IFS= read -r -s -N 1 -t 0.25 -u 3 first 2>/dev/null; then
        return 1
    fi

    if [[ "$first" != $'\033' ]]; then
        case "$first" in
            $'\r'|$'\n') KEY="ENTER" ;;
            $'\x12')      KEY="RESTART" ;;
            *)            KEY=$first ;;
        esac
        return 0
    fi

    if ! IFS= read -r -s -N 1 -t 0.5 -u 3 next 2>/dev/null; then
        KEY="ESC"
        return 0
    fi

    if [[ "$next" != "[" && "$next" != "O" ]]; then
        KEY="OTHER"
        return 0
    fi

    for ((i = 0; i < 16; i++)); do
        if ! IFS= read -r -s -N 1 -t 0.5 -u 3 next 2>/dev/null; then
            KEY="OTHER"
            return 0
        fi

        if [[ "$next" == [@-~] ]]; then
            case "$next" in
                A) KEY="UP" ;;
                B) KEY="DOWN" ;;
                C) KEY="RIGHT" ;;
                D) KEY="LEFT" ;;
                *) KEY="OTHER" ;;
            esac
            return 0
        fi
    done

    KEY="OTHER"
    return 0
}

request_restart() {
    stop_tunnels

    if [[ -n "$LOG_DIR" && -d "$LOG_DIR" ]]; then
        rm -rf -- "$LOG_DIR"
        LOG_DIR=""
    fi

    restore_screen

    if ((TTY_OPEN)); then
        exec 3>&-
        TTY_OPEN=0
    fi

    trap - INT TERM EXIT WINCH
    exec "$SCRIPT_PATH" "$CONFIG"
}

if ! exec 3<>/dev/tty; then
    echo 'SSH TUNNEL WIZARD needs an interactive terminal.' >&2
    exit 1
fi
TTY_OPEN=1

LOG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ssh-tunnel-wizard.XXXXXX") || {
    echo 'Could not create temporary SSH log directory.' >&2
    exit 1
}

printf '\033]0;SSH TUNNEL WIZARD\007'

if [[ -t 1 ]]; then
    printf '\033[?1049h\033[?25l'
    ALT_SCREEN=1
fi

if ! set_tty_mode; then
    echo 'Could not configure terminal input.' >&2
    exit 1
fi

for id in "${TUNNEL_IDS[@]}"; do
    start_with_retry "$id"
    ((EXIT_REQUESTED)) && exit 130
done

render_screen

while true; do
    ((EXIT_REQUESTED)) && exit 130

    poll_tunnels

    if ((REDRAW_NEEDED)); then
        render_screen
    fi

    if ! read_key; then
        continue
    fi

    ((EXIT_REQUESTED)) && exit 130

    if [[ "$KEY" == RESTART ]]; then
        request_restart
    fi

    if [[ "$UI_MODE" == dashboard ]]; then
        if ((${#SHELL_NAMES[@]} == 0)); then
            continue
        fi

        case "$KEY" in
            s|S)
                UI_MODE="menu"
                SHELL_SELECTION=0
                MENU_SCROLL=0
                MESSAGE=""
                REDRAW_NEEDED=1
                ;;
            UP)
                move_shell_vertical -1 "$(dashboard_shell_count)"
                ;;
            DOWN)
                move_shell_vertical 1 "$(dashboard_shell_count)"
                ;;
            LEFT)
                move_shell_horizontal -1 "$(dashboard_shell_count)"
                ;;
            RIGHT)
                move_shell_horizontal 1 "$(dashboard_shell_count)"
                ;;
            ENTER)
                open_shell_window "$SHELL_SELECTION" || true
                REDRAW_NEEDED=1
                ;;
            [1-9])
                index=$((KEY - 1))
                if ((index < ${#SHELL_NAMES[@]})); then
                    SHELL_SELECTION=$index
                    open_shell_window "$index" || true
                    REDRAW_NEEDED=1
                fi
                ;;
        esac
    else
        case "$KEY" in
            UP)
                move_shell_vertical -1
                ;;
            DOWN)
                move_shell_vertical 1
                ;;
            LEFT)
                move_shell_horizontal -1
                ;;
            RIGHT)
                move_shell_horizontal 1
                ;;
            ENTER)
                open_shell_window "$SHELL_SELECTION" || true
                REDRAW_NEEDED=1
                ;;
            [1-9])
                index=$((KEY - 1))
                if ((index < ${#SHELL_NAMES[@]})); then
                    SHELL_SELECTION=$index
                    open_shell_window "$index" || true
                    REDRAW_NEEDED=1
                fi
                ;;
            ESC|q|Q)
                UI_MODE="dashboard"
                SHELL_SELECTION=0
                MESSAGE=""
                REDRAW_NEEDED=1
                ;;
        esac
    fi
done
