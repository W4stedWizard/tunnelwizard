#!/usr/bin/env bash
set -uo pipefail

# Find the script and its default config in the same directory.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
CONFIG="$SCRIPT_DIR/tunnels.conf"
SSH_CONFIG_FILE="$SCRIPT_DIR/ssh_config"
SSH_CONFIG_EXPLICIT=0
SSH_CONFIG_B64_USED=0
CONNECT_MODE=0
CONNECT_TARGET_B64=""

set_ssh_config_path() {
    local path=$1
    if [[ -z "$path" ]]; then
        echo 'SSH config path cannot be empty.' >&2
        return 2
    fi
    if [[ "$path" == '~' || "$path" == '~/'* ]]; then
        if [[ -z "${HOME:-}" ]]; then
            echo 'Cannot expand SSH config path: HOME is not set.' >&2
            return 2
        fi
        if [[ "$path" == '~' ]]; then
            path=$HOME
        else
            path="${HOME%/}/${path#\~/}"
        fi
    fi
    [[ "$path" == /* ]] || path="$PWD/$path"
    SSH_CONFIG_FILE=$path
    SSH_CONFIG_EXPLICIT=1
}

decode_base64() {
    if [[ "$(uname -s)" == Darwin ]]; then
        printf '%s' "$1" | base64 -D
    else
        printf '%s' "$1" | base64 -d
    fi
}

parse_cli_args() {
    local config_seen=0 ssh_config_seen=0 path

    CONFIG="$SCRIPT_DIR/tunnels.conf"
    SSH_CONFIG_FILE="$SCRIPT_DIR/ssh_config"
    SSH_CONFIG_EXPLICIT=0
    SSH_CONFIG_B64_USED=0
    CONNECT_MODE=0
    CONNECT_TARGET_B64=""

    while (($#)); do
        case "$1" in
            --ssh-config|-cssh)
                if ((ssh_config_seen)) || (($# < 2)) || [[ -z "$2" || "$2" == -* ]]; then
                    echo 'Usage: tunnels.sh [TUNNELS_CONFIG] [--ssh-config|-cssh SSH_CONFIG]' >&2
                    return 2
                fi
                set_ssh_config_path "$2" || return $?
                ssh_config_seen=1
                shift 2
                ;;
            --ssh-config=*|-cssh=*)
                if ((ssh_config_seen)); then
                    echo 'SSH config was specified more than once.' >&2
                    return 2
                fi
                path=${1#*=}
                set_ssh_config_path "$path" || return $?
                ssh_config_seen=1
                shift
                ;;
            --connect-base64)
                if ((CONNECT_MODE)) || (($# < 2)) ||
                   [[ ! "$2" =~ ^[A-Za-z0-9+/]+={0,2}$ ]]; then
                    echo 'Invalid encoded SSH target.' >&2
                    return 2
                fi
                CONNECT_MODE=1
                CONNECT_TARGET_B64=$2
                shift 2
                ;;
            --ssh-config-b64)
                if ((ssh_config_seen)) || (($# < 2)); then
                    echo 'Invalid internal SSH config argument.' >&2
                    return 2
                fi
                SSH_CONFIG_B64_USED=1
                if [[ "$2" != - ]]; then
                    if [[ ! "$2" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] ||
                       ! path=$(decode_base64 "$2"); then
                        echo 'Invalid encoded SSH config path.' >&2
                        return 2
                    fi
                    if [[ "$path" != /* ]]; then
                        echo 'Encoded SSH config path must be absolute.' >&2
                        return 2
                    fi
                    SSH_CONFIG_FILE=$path
                    SSH_CONFIG_EXPLICIT=1
                fi
                ssh_config_seen=1
                shift 2
                ;;
            --)
                shift
                if ((CONNECT_MODE)) || ((config_seen)) || (($# > 1)); then
                    echo 'Usage: tunnels.sh [TUNNELS_CONFIG] [--ssh-config|-cssh SSH_CONFIG]' >&2
                    return 2
                fi
                if (($# == 1)); then CONFIG=$1; fi
                config_seen=1
                if (($# == 1)); then shift; fi
                ;;
            -* )
                echo "Unknown option: $1" >&2
                echo 'Usage: tunnels.sh [TUNNELS_CONFIG] [--ssh-config|-cssh SSH_CONFIG]' >&2
                return 2
                ;;
            *)
                if ((CONNECT_MODE)) || ((config_seen)); then
                    echo 'Only one TunnelWizard config path may be supplied.' >&2
                    return 2
                fi
                CONFIG=$1
                config_seen=1
                shift
                ;;
        esac
    done

    if ((SSH_CONFIG_B64_USED && !CONNECT_MODE)); then
        echo 'Internal SSH config option requires --connect-base64.' >&2
        return 2
    fi
    if ((CONNECT_MODE && config_seen)); then
        echo 'Internal SSH connection mode does not accept a TunnelWizard config path.' >&2
        return 2
    fi
}

validate_ssh_config() {
    if ((SSH_CONFIG_EXPLICIT)); then
        if [[ ! -f "$SSH_CONFIG_FILE" || ! -r "$SSH_CONFIG_FILE" ]]; then
            echo "SSH config must be a readable regular file: $SSH_CONFIG_FILE" >&2
            return 1
        fi
    elif [[ -e "$SSH_CONFIG_FILE" &&
            ( ! -f "$SSH_CONFIG_FILE" || ! -r "$SSH_CONFIG_FILE" ) ]]; then
        echo "SSH config must be a readable regular file: $SSH_CONFIG_FILE" >&2
        return 1
    fi
}

parse_cli_args "$@" || exit $?
validate_ssh_config || exit $?

ssh_with_config() {
    if [[ -f "$SSH_CONFIG_FILE" ]]; then
        command ssh -F "$SSH_CONFIG_FILE" "$@"
    else
        command ssh "$@"
    fi
}

# A newly opened system-terminal window runs this lightweight connection mode.
if ((CONNECT_MODE)); then
    target=$(decode_base64 "$CONNECT_TARGET_B64") || exit 2

    if [[ -z "$target" || "$target" == -* ]]; then
        echo 'Invalid SSH target.' >&2
        exit 2
    fi

    if [[ -f "$SSH_CONFIG_FILE" ]]; then
        exec ssh -F "$SSH_CONFIG_FILE" "$target"
    fi
    exec ssh "$target"
fi

CONNECT_TIMEOUT=10
STARTUP_WAIT=1

declare -a TUNNEL_IDS=()
declare -a PIDS=()
declare -a SHELL_NAMES=()
declare -a SHELL_TARGETS=()
declare -a LOCAL_HOSTNAMES=()
declare -a LOCAL_ADDRESSES=()
declare -A HOSTNAME_IP=()
declare -A IP_HOSTNAME=()
declare -A HOSTS_PRESENCE=()

declare -A LABEL=()
declare -A SSH_HOST=()
declare -A SSH_USER=()
declare -A IDENTITY=()
declare -A FORWARD_NAME=()
declare -A FORWARD_HOSTNAME=()
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
HOSTS_MANAGEMENT=no
CONFIG_ERROR=0

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
# Input remains responsive at 10 Hz; child-process status checks are slower.
INPUT_POLL_TIMEOUT=0.1
TUNNEL_POLL_INTERVAL=2
NEXT_TUNNEL_POLL=0
USE_COLOUR=0
ALT_SCREEN=0
TTY_CONFIGURED=0
TTY_STATE=""
TTY_OPEN=0
LOG_DIR=""

TERM_WIDTH=80
TERM_HEIGHT=24
TERM_SIZE_VALID=0
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
RENDER_CAPTURE_DISABLED=0

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    USE_COLOUR=1
fi

# Config syntax:
#   machine ALIAS SSH_HOST SSH_USER IDENTITY_FILE GROUP
#   tunnel  DISPLAY_NAME LOCAL_FORWARD [LOCAL_HOSTNAME]
#   shell   DISPLAY_NAME SSH_TARGET
#   hosts_management yes|no (default: no; only enables the manual Windows menu)
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

hosts_management() {
    if (($# != 1)) || [[ "$1" != yes && "$1" != no ]]; then
        echo 'Usage: hosts_management yes|no' >&2
        CONFIG_ERROR=1
        return 2
    fi
    HOSTS_MANAGEMENT=$1
}

valid_local_hostname() {
    local hostname=${1,,} label
    [[ ${#hostname} -le 253 && "$hostname" =~ ^[a-z0-9.-]+$ &&
       "$hostname" != *..* && "$hostname" != .* && "$hostname" != *. ]] || return 1
    local -a labels=()
    IFS=. read -r -a labels <<< "$hostname"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
    done
    # Numeric IPv4-looking names must not masquerade as host aliases.
    [[ ! "$hostname" =~ ^[0-9]+(\.[0-9]+){3}$ ]]
}

local_host_ip() {
    local hostname=${1,,} hash=0 char ascii i
    for ((i = 0; i < ${#hostname}; i++)); do
        char=${hostname:i:1}
        printf -v ascii '%d' "'$char"
        hash=$(((hash * 131 + ascii) % 16387064))
    done
    printf '127.%d.%d.%d' "$((hash / 64516 + 1))" \
        "$((hash / 254 % 254 + 1))" "$((hash % 254 + 1))"
}

valid_loopback_ip() {
    local address=$1 octet
    local -a octets=()
    [[ "$address" =~ ^127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    octets=(127 "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}")
    for octet in "${octets[@]}"; do
        [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
        ((10#$octet <= 255)) || return 1
    done
}

tunnel() {
    if [[ -z "$CURRENT_ALIAS" ]]; then
        echo 'Error: define a machine before its tunnels.' >&2
        CONFIG_ERROR=1
        return 2
    fi

    if (($# != 2 && $# != 3)); then
        echo 'Usage: tunnel DISPLAY_NAME LOCAL_FORWARD [LOCAL_HOSTNAME]' >&2
        CONFIG_ERROR=1
        return 2
    fi

    local name=$1
    local forward=$2
    local id index local_port display hostname ip bind
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
            CONFIG_ERROR=1
            return 2
            ;;
    esac

    if (($# == 3)); then
        hostname=${3,,}
        if ! valid_local_hostname "$hostname"; then
            echo "Error: invalid local hostname: $3" >&2
            CONFIG_ERROR=1
            return 2
        fi
        ip=$(local_host_ip "$hostname")
        if ((${#parts[@]} == 4)); then
            bind=${parts[0]}
            if ! valid_loopback_ip "$bind"; then
                echo "Error: hostname '$hostname' can only bind to an IPv4 loopback address (127/8), not '$bind'." >&2
                CONFIG_ERROR=1
                return 2
            fi
            # An explicit loopback bind is the hostname's stable address.
            ip=$bind
        fi
        if [[ -n "${HOSTNAME_IP[$hostname]:-}" && "${HOSTNAME_IP[$hostname]}" != "$ip" ]]; then
            echo "Error: conflicting hostname: $hostname" >&2
            CONFIG_ERROR=1
            return 2
        fi
        if [[ -n "${IP_HOSTNAME[$ip]:-}" && "${IP_HOSTNAME[$ip]}" != "$hostname" ]]; then
            echo "Error: loopback address collision: $hostname and ${IP_HOSTNAME[$ip]} ($ip)" >&2
            CONFIG_ERROR=1
            return 2
        fi
        forward="$ip:$local_port:${parts[${#parts[@]}-2]}:${parts[${#parts[@]}-1]}"
        if [[ -z "${HOSTNAME_IP[$hostname]:-}" ]]; then
            LOCAL_HOSTNAMES+=("$hostname")
            LOCAL_ADDRESSES+=("$ip")
            HOSTNAME_IP["$hostname"]=$ip
            IP_HOSTNAME["$ip"]=$hostname
        fi
    fi

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
        FORWARD_NAME["$id:$index"]=$name
        FORWARD_HOSTNAME["$id:$index"]=${hostname:-}
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
        FORWARD_NAME["$id:0"]=$name
        FORWARD_HOSTNAME["$id:0"]=${hostname:-}
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

if ((CONFIG_ERROR)); then
    echo "Invalid tunnel or hosts management setting in $CONFIG" >&2
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

key_hint() {
    colour '1;38;2;105;180;255' "$1"
}

render_arrow_hint() {
    key_hint '←'
    printf '/'
    key_hint '→'
    printf '/'
    key_hint '↑'
    printf '/'
    key_hint '↓'
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

ensure_terminal_size() {
    if ((!TERM_SIZE_VALID)); then
        TERM_WIDTH=$(terminal_width)
        TERM_HEIGHT=$(terminal_height)
        TERM_SIZE_VALID=1
    fi
}

create_render_capture_file() {
    local temp_dir candidate
    local -a temp_dirs=()

    [[ -n "${XDG_RUNTIME_DIR:-}" ]] && temp_dirs+=("$XDG_RUNTIME_DIR")
    temp_dirs+=(/dev/shm "${TMPDIR:-/tmp}" /tmp)
    for temp_dir in "${temp_dirs[@]}"; do
        [[ -d "$temp_dir" && -w "$temp_dir" ]] || continue
        if candidate=$(mktemp "$temp_dir/ssh-tunnel-render.XXXXXX" 2>/dev/null) &&
           [[ -n "$candidate" && -f "$candidate" ]]; then
            RENDER_CAPTURE_FILE=$candidate
            return 0
        fi
    done

    RENDER_CAPTURE_FILE=""
    RENDER_CAPTURE_DISABLED=1
    return 1
}

is_windows_shell() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) return 1 ;;
    esac
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

    ensure_terminal_size
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

    if [[ -z "$RENDER_CAPTURE_FILE" || ! -f "$RENDER_CAPTURE_FILE" ]]; then
        if ((!RENDER_CAPTURE_DISABLED)); then
            create_render_capture_file || true
        fi
    fi

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

    if [[ -n "$RENDER_CAPTURE_FILE" && -f "$RENDER_CAPTURE_FILE" &&
          -w "$RENDER_CAPTURE_FILE" ]]; then
        "$@" >"$RENDER_CAPTURE_FILE" || render_status=$?
        content=$(<"$RENDER_CAPTURE_FILE")
    else
        if [[ -n "$RENDER_CAPTURE_FILE" ]]; then
            rm -f -- "$RENDER_CAPTURE_FILE" 2>/dev/null || true
        fi
        RENDER_CAPTURE_FILE=""
        RENDER_CAPTURE_DISABLED=1
        if content=$("$@"); then
            render_status=0
        else
            render_status=$?
        fi
    fi
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
    # Keep the capture file for the next paint; cleanup removes it on exit.
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
    local remaining shown padding fade_width=6 text_width index style
    local -a fade_styles=(
        '48;2;42;24;64'
        '48;2;34;19;51'
        '48;2;25;14;38'
        '48;2;17;10;26'
        '48;2;8;5;13'
        '48;2;0;0;0'
    )

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
        if ((remaining >= fade_width)); then
            text_width=$((remaining - fade_width))
            if ((text_width > 0)); then
                shown=$(truncate_text "$subtitle" "$text_width")
                printf -v padding '%*s' "$((text_width - ${#shown}))" ''
                colour '38;2;204;181;247;48;2;42;24;64' "${shown}${padding}"
            fi
            for index in "${!fade_styles[@]}"; do
                style=${fade_styles[$index]}
                colour "$style" ' '
            done
        else
            shown=$(truncate_text "$subtitle" "$remaining")
            colour '38;2;204;181;247;48;2;42;24;64' "$shown"
        fi
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
        colour '38;2;245;228;190;48;2;54;45;70' \
            "$(truncate_text "  ▪ $MESSAGE" "$((TERM_WIDTH - 1))")"
    fi
}

render_global_controls() {
    local full='  H Hosts    Ctrl+R Restart tunnels    Ctrl+C Stop and exit'

    if ((TERM_WIDTH <= ${#full})); then
        if ((TERM_WIDTH < 34)); then
            printf '  '
            key_hint 'H'
            printf ' '
            key_hint '^R'
            printf ' '
            key_hint '^C'
            return
        fi
        printf '  '
        key_hint 'H'
        printf ' Hosts  '
        key_hint '^R'
        printf ' Restart  '
        key_hint '^C'
        printf ' Exit'
        return
    fi

    printf '  '
    key_hint 'H'
    printf '  Hosts    '
    key_hint 'Ctrl+R'
    printf '  Restart tunnels    '
    key_hint 'Ctrl+C'
    printf '  Stop and exit'
}

render_dashboard_shell_controls() {
    local full='  1–9 Open instantly    ←/→/↑/↓ Navigate    Enter Open'

    if ((TERM_WIDTH > ${#full})); then
        printf '  '
        key_hint '1–9'
        printf ' Open instantly    '
        render_arrow_hint
        printf ' Navigate    '
        key_hint 'Enter'
        printf ' Open'
    else
        printf '  '
        if ((TERM_WIDTH < 34)); then
            key_hint '1–9'
            printf ' '
            key_hint '↑↓←→'
            printf ' '
            key_hint 'Enter'
        else
            key_hint '1–9'
            printf ' Open '
            key_hint '↑↓←→'
            printf ' Move '
            key_hint 'Enter'
            printf ' Open'
        fi
    fi
}

render_dashboard_global_controls() {
    local full='  S  Saved SSH shells    H  Hosts    Ctrl+R  Restart    Ctrl+C  Stop and exit'

    if ((TERM_WIDTH <= ${#full})); then
        if ((TERM_WIDTH < 34)); then
            printf '  '
            key_hint 'S'
            printf ' '
            key_hint 'H'
            printf ' '
            key_hint '^R'
            printf ' '
            key_hint '^C'
            return
        fi
        printf '  '
        key_hint 'S'
        printf ' Shells  '
        key_hint 'H'
        printf ' Hosts  '
        key_hint '^R'
        printf ' Restart  '
        key_hint '^C'
        printf ' Exit'
        return
    fi

    printf '  '
    key_hint 'S'
    printf '  Saved SSH shells    '
    key_hint 'H'
    printf '  Hosts    '
    key_hint 'Ctrl+R'
    printf '  Restart    '
    key_hint 'Ctrl+C'
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

render_tunnel_label() {
    local id=$1 max_width=$2 index forward local_port hostname display_name
    local plain='' separator='' prefix visible_width keep_width cursor=0
    local start length highlight_length output=''
    local -a host_starts=() host_lengths=() parts=()

    for ((index = 0; index < FORWARD_COUNT[$id]; index++)); do
        forward=${FORWARD["$id:$index"]}
        IFS=: read -r -a parts <<< "$forward"
        if ((${#parts[@]} == 3)); then
            local_port=${parts[0]}
        else
            local_port=${parts[1]}
        fi
        hostname=${FORWARD_HOSTNAME["$id:$index"]:-}
        display_name=${FORWARD_NAME["$id:$index"]}
        plain+="$separator"
        printf -v prefix '%5s : ' "$local_port"
        plain+="$prefix"
        if [[ -n "$hostname" ]]; then
            host_starts+=("${#plain}")
            host_lengths+=("${#hostname}")
            plain+="$hostname "
        fi
        plain+="$display_name"
        separator=', '
    done

    visible_width=${#plain}
    keep_width=$visible_width
    if ((visible_width > max_width)); then
        keep_width=$((max_width - 3))
        ((keep_width < 0)) && keep_width=0
        visible_width=$max_width
    fi

    for index in "${!host_starts[@]}"; do
        start=${host_starts[$index]}
        length=${host_lengths[$index]}
        ((start < keep_width)) || break
        output+="${plain:cursor:start-cursor}"
        highlight_length=$length
        ((highlight_length > keep_width - start)) && highlight_length=$((keep_width - start))
        output+="$(colour '1;38;2;255;255;255' "${plain:start:highlight_length}")"
        cursor=$((start + highlight_length))
    done
    output+="${plain:cursor:keep_width-cursor}"
    if ((visible_width > keep_width)); then
        output+='...'
    fi

    printf '%s' "$output"
    printf '%*s' "$((max_width - visible_width))" ''
}

render_tunnel_row() {
    local id=$1 label_width=$2 host_width=$3
    local host

    host=$(truncate_text "${SSH_HOST[$id]}" "$host_width")

    printf '  '
    render_tunnel_label "$id" "$label_width"
    printf '  '
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
        # Dark-grey background (#4B4B52), with purple selection accents.
        colour '1;38;2;184;127;242;48;2;75;75;82' "$marker"
        colour '1;38;2;184;127;242;48;2;75;75;82' \
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
        footer_at "$TERM_HEIGHT" render_menu_controls_full
    else
        if [[ -n "$MESSAGE" ]]; then
            footer_at "$((TERM_HEIGHT - 2))" render_message
        fi
        footer_at "$((TERM_HEIGHT - 1))" render_menu_controls_short
        footer_at "$TERM_HEIGHT" render_menu_return_hint
    fi
}

render_menu_controls_full() {
    printf '  '
    key_hint '1–9'
    printf ' Open instantly    '
    render_arrow_hint
    printf ' Navigate    '
    key_hint 'Enter'
    printf ' Open    '
    key_hint 'Esc'
    printf '/'
    key_hint 'Q'
    printf ' Return'
}

render_menu_controls_short() {
    printf '  '
    key_hint '1–9'
    printf ' Open '
    key_hint '↑↓←→'
    printf ' Navigate'
}

render_menu_return_hint() {
    printf '  '
    key_hint 'Enter'
    printf ' Open '
    key_hint 'Esc'
    printf '/'
    key_hint 'Q'
    printf ' Return'
}

render_shell_menu() {
    local count=${#SHELL_NAMES[@]}
    local full='  1–9 Open instantly    ←/→/↑/↓ Navigate    Enter Open    Esc/Q Return'
    local cell_width grid_rows total_lines available selected_line
    local max_scroll line grid_row footer_rows

    ensure_terminal_size
    if ((TERM_WIDTH > ${#full})); then
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

render_hosts_menu() {
    local footer_rows=2 index config_name
    config_name=${CONFIG##*/}
    [[ "$config_name" == *.conf && "$config_name" != .conf ]] && config_name=${config_name%.conf}
    ensure_terminal_size
    if is_windows_shell && ((TERM_WIDTH < 96)); then
        footer_rows=3
    fi
    [[ -n "$MESSAGE" ]] && footer_rows=$((footer_rows + 1))
    begin_screen "$footer_rows"
    body_line render_header_line
    body_line :
    if is_windows_shell; then
        body_line print_clipped_line "  WINDOWS HOSTS · $config_name"
    else
        body_line print_clipped_line "  LOCAL HOSTNAMES · $config_name"
    fi
    body_line render_rule
    body_line render_hosts_warning
    if ! is_windows_shell; then
        body_line print_clipped_line '  Hosts-file sync is Windows-only; forwards remain local.'
    fi
    body_line render_hosts_heading
    body_line render_rule
    if ((${#LOCAL_HOSTNAMES[@]} == 0)); then
        body_line print_clipped_line '  No local hostnames are configured in this config.'
    fi
    for index in "${!LOCAL_HOSTNAMES[@]}"; do
        body_line render_hosts_row "${LOCAL_ADDRESSES[$index]}" \
            "${LOCAL_HOSTNAMES[$index]}" data "$((index % 2))"
    done
    [[ -n "$MESSAGE" ]] && footer_at "$((TERM_HEIGHT - footer_rows + 1))" render_message
    if is_windows_shell; then
        if ((TERM_WIDTH < 96)); then
            footer_at "$((TERM_HEIGHT - 2))" render_hosts_legend
            footer_at "$((TERM_HEIGHT - 1))" render_hosts_controls_short
            footer_at "$TERM_HEIGHT" render_hosts_controls_return
        else
            footer_at "$((TERM_HEIGHT - 1))" render_hosts_legend
            footer_at "$TERM_HEIGHT" render_hosts_controls
        fi
    else
        footer_at "$((TERM_HEIGHT - 1))" render_hosts_legend
        footer_at "$TERM_HEIGHT" render_hosts_return_controls
    fi
    finish_screen
}

render_hosts_warning() {
    local warning='! Hosts entries persist after exit; remove them explicitly.'
    local max=$((TERM_WIDTH - 1)) remaining shown index style fade_width=0
    local -a fade_styles=(
        '48;2;45;25;60'
        '48;2;36;20;48'
        '48;2;27;15;36'
        '48;2;18;10;24'
        '48;2;9;5;12'
        '48;2;0;0;0'
    )

    ((max > 0)) || return
    if ((max <= 2)); then
        colour '1;38;2;255;190;232;48;2;57;31;74' "$(truncate_text '  ' "$max")"
        return
    fi

    printf '  '
    remaining=$((max - 2))
    shown=$warning
    if ((remaining < ${#warning})); then
        shown=$(truncate_text "$warning" "$remaining")
    else
        fade_width=$((remaining - ${#warning}))
        ((fade_width > ${#fade_styles[@]})) && fade_width=${#fade_styles[@]}
    fi
    colour '1;38;2;255;190;232;48;2;57;31;74' "$shown"
    for ((index = 0; index < fade_width; index++)); do
        style=${fade_styles[$index]}
        colour "$style" ' '
    done
}

render_hosts_legend() {
    printf '  '
    if ((TERM_WIDTH < 26)); then
        colour '1;38;2;184;127;242' 'M'
        printf ' | '
        colour '38;2;157;159;168' 'A'
        printf ' | '
        colour '1;38;2;231;183;111' 'C'
    elif ((TERM_WIDTH < 34)); then
        colour '1;38;2;184;127;242' 'Map'
        printf ' | '
        colour '38;2;157;159;168' 'Absent'
        printf ' | '
        colour '1;38;2;231;183;111' 'Conflict'
    else
        colour '1;38;2;184;127;242' 'Mapped'
        printf ' | '
        colour '38;2;157;159;168' 'Absent'
        printf ' | '
        colour '1;38;2;231;183;111' 'Conflict'
    fi
}

render_hosts_heading() {
    render_hosts_row 'IP' 'HOSTNAME' heading
}

render_hosts_row() {
    local ip=$1 hostname=$2 kind=$3 stripe=${4:-0}
    local hostname_width=$((TERM_WIDTH - 20)) shown room ip_width ip_style name_style stripe_style ip_cell padding_width
    if ((hostname_width < 1)); then
        if [[ "$kind" == heading ]]; then
            print_clipped_line "  $ip  $hostname"
        elif ((TERM_WIDTH < 7)); then
            printf '  '
            shown=$(truncate_text "$hostname" "$((TERM_WIDTH - 3))")
            hosts_status_style "$hostname" "$stripe"
            colour "$name_style;$stripe_style" "$shown"
        else
            room=$((TERM_WIDTH - 3))
            ip_width=$(((room - 2) / 2))
            ((ip_width < 1)) && ip_width=1
            hostname_width=$((room - ip_width - 2))
            shown=$(truncate_text "$hostname" "$hostname_width")
            hosts_status_style "$hostname" "$stripe"
            printf '  '
            printf -v ip_cell '%-*s  ' "$ip_width" "$(truncate_text "$ip" "$ip_width")"
            colour "$ip_style;$stripe_style" "$ip_cell"
            colour "$name_style;$stripe_style" "$shown"
        fi
    else
        if [[ "$kind" == heading ]]; then
            printf '  %-15s  %s' "$ip" "$(truncate_text "$hostname" "$hostname_width")"
            return
        fi
        hosts_status_style "$hostname" "$stripe"
        printf '  '
        printf -v ip_cell '%-15s  ' "$ip"
        colour "$ip_style;$stripe_style" "$ip_cell"
        shown=$(truncate_text "$hostname" "$hostname_width")
        colour "$name_style;$stripe_style" "$shown"
        padding_width=$((hostname_width - ${#shown}))
        if ((padding_width > 0)); then
            printf -v ip_cell '%*s' "$padding_width" ''
            colour "$stripe_style" "$ip_cell"
        fi
    fi
}

hosts_status_style() {
    local hostname=$1 stripe=$2
    case "${HOSTS_PRESENCE[$hostname]:-ABSENT}" in
        PRESENT)
            ip_style='38;2;184;127;242'
            name_style='1;38;2;184;127;242'
            ;;
        CONFLICT)
            ip_style='38;2;231;183;111'
            name_style='1;38;2;231;183;111'
            ;;
        *)
            ip_style='38;2;157;159;168'
            name_style='38;2;157;159;168'
            ;;
    esac
    if ((stripe % 2)); then
        stripe_style='48;2;29;31;37'
    else
        stripe_style='48;2;24;26;32'
    fi
}

render_hosts_return_controls() {
    printf '  '
    key_hint 'Esc'
    printf ' or '
    key_hint 'Q'
    printf ' Return (sync is Windows-only)'
}

render_hosts_controls() {
    printf '  '
    key_hint 'A'
    printf ' Apply    '
    key_hint 'D'
    printf ' Delete host config    '
    key_hint 'Ctrl+D'
    printf ' Delete all TW host blocks    '
    key_hint 'Esc'
    printf ' or '
    key_hint 'Q'
    printf ' Return'
}

render_hosts_controls_short() {
    printf '  '
    if ((TERM_WIDTH < 24)); then
        key_hint 'A'
        printf ' '
        key_hint 'D'
    elif ((TERM_WIDTH < 34)); then
        key_hint 'A'
        printf ' Apply  '
        key_hint 'D'
        printf ' Delete'
    else
        key_hint 'A'
        printf ' Apply    '
        key_hint 'D'
        printf ' Delete host config'
    fi
}

render_hosts_controls_return() {
    printf '  '
    if ((TERM_WIDTH < 24)); then
        key_hint '^D'
        printf ' all  '
        key_hint 'Esc'
        printf ' '
        key_hint 'Q'
    elif ((TERM_WIDTH < 46)); then
        key_hint '^D'
        printf ' all TW  '
        key_hint 'Esc'
        printf ' or '
        key_hint 'Q'
    elif ((TERM_WIDTH < 64)); then
        key_hint '^D'
        printf ' Delete all TW blocks   '
        key_hint 'Esc'
        printf ' or '
        key_hint 'Q'
    else
        key_hint 'Ctrl+D'
        printf ' Delete all TW host blocks    '
        key_hint 'Esc'
        printf ' or '
        key_hint 'Q'
    fi
    printf ' Return'
}

render_screen() {
    local resize_event=$RESIZE_EVENT

    case "$UI_MODE" in
        menu) render_shell_menu ;;
        hosts) render_hosts_menu ;;
        *) render_dashboard ;;
    esac

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

    ((count > 0)) || return 0

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

    ((count > 0)) || return 0

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
trap 'RESIZE_EVENT=$((RESIZE_EVENT + 1)); TERM_SIZE_VALID=0; FORCE_REPAINT=1; REDRAW_NEEDED=1' WINCH

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

    if [[ -f "$SSH_CONFIG_FILE" ]]; then
        ssh_args=( -F "$SSH_CONFIG_FILE" "${ssh_args[@]}" )
    fi

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
    local pid=${2:-} index answer error_line

    while true; do
        ((EXIT_REQUESTED)) && return

        if [[ -z "$pid" ]]; then
            STATUS["$id"]="STARTING"
            render_dashboard

            start_one "$id"
            pid=${PIDS[-1]}

            # Retry check only; initial starts share a single grace period.
            sleep "$STARTUP_WAIT"
            ((EXIT_REQUESTED)) && return
        fi

        if kill -0 "$pid" 2>/dev/null; then
            STATUS["$id"]="RUNNING"
            render_dashboard
            return
        fi

        wait "$pid" 2>/dev/null || true
        for index in "${!PIDS[@]}"; do
            if [[ "${PIDS[$index]}" == "$pid" ]]; then
                unset "PIDS[$index]"
                break
            fi
        done
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
        FORCE_REPAINT=1

        case "$answer" in
            y|Y|yes|YES) pid="" ;;
            *)
                STATUS["$id"]="SKIPPED"
                render_dashboard
                return
                ;;
        esac
    done
}

poll_tunnel_processes() {
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

    ssh_with_config "$target" <&3
    ssh_status=$?

    printf '\nSSH session ended (exit status %s).\n' "$ssh_status"
    read -r -p 'Press Enter to return to the wizard... ' _ <&3 || true

    if ! set_tty_mode; then
        EXIT_REQUESTED=1
        return 1
    fi

    printf '\033[?25l'
    MESSAGE=""
    FORCE_REPAINT=1
    REDRAW_NEEDED=1
    return 0
}

open_shell_window() {
    local index=$1
    local target=${SHELL_TARGETS[$index]}
    local name=${SHELL_NAMES[$index]}
    local wezterm_bin bash_bin bash_win workdir_win
    local encoded_title encoded_target encoded_ssh_config=-

    if ((SSH_CONFIG_EXPLICIT)); then
        encoded_ssh_config=$(printf '%s' "$SSH_CONFIG_FILE" | base64 | tr -d '\r\n')
    fi

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
            'printf "\033]1337;SetUserVar=SSH_WIZARD_TITLE=%s\007" "$2"; if [[ "$4" == 1 && ( ! -f "$3" || ! -r "$3" ) ]]; then echo "SSH config is no longer readable: $3" >&2; exit 1; fi; if [[ -f "$3" ]]; then exec ssh -F "$3" "$1"; else exec ssh "$1"; fi' \
            wizard-shell "$target" "$encoded_title" "$SSH_CONFIG_FILE" "$SSH_CONFIG_EXPLICIT" \
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
                   WIZARD_SSH_CONFIG_B64="$encoded_ssh_config" \
                   powershell.exe -NoProfile -NonInteractive -Command \
                   'try { $launchArgs = "-c `"exec bash ./tunnels.sh --connect-base64 " + $env:WIZARD_TARGET_B64 + " --ssh-config-b64 " + $env:WIZARD_SSH_CONFIG_B64 + "`""; Start-Process -FilePath $env:WIZARD_BASH_EXE -WorkingDirectory $env:WIZARD_WORKDIR -ArgumentList $launchArgs -ErrorAction Stop } catch { exit 1 }' \
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
                    -e 'do script ("bash " & quoted form of (item 1 of argv) & " --connect-base64 " & item 2 of argv & " --ssh-config-b64 " & item 3 of argv)' \
                    -e 'activate' \
                    -e 'end tell' \
                    -e 'end run' \
                    -- "$SCRIPT_PATH" "$encoded_target" "$encoded_ssh_config" \
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
                    --ssh-config-b64 "$encoded_ssh_config" \
                    </dev/null >/dev/null 2>&1 &
                MESSAGE="Opened '$name' in new window."
                return 0
            elif command -v x-terminal-emulator >/dev/null 2>&1; then
                x-terminal-emulator -e bash "$SCRIPT_PATH" \
                    --connect-base64 "$encoded_target" \
                    --ssh-config-b64 "$encoded_ssh_config" \
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
    local first="" next="" timeout=${1:-0.1}
    local i

    KEY=""

    if ! IFS= read -r -s -N 1 -t "$timeout" -u 3 first 2>/dev/null; then
        return 1
    fi

    if [[ "$first" != $'\033' ]]; then
        case "$first" in
            $'\r'|$'\n') KEY="ENTER" ;;
            $'\x12')      KEY="RESTART" ;;
            $'\x04')      KEY="REMOVE_ALL_HOSTS" ;;
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

configured_hosts_entries() {
    local index
    for index in "${!LOCAL_HOSTNAMES[@]}"; do
        printf '%s %s\n' "${LOCAL_HOSTNAMES[$index]}" "${LOCAL_ADDRESSES[$index]}"
    done
}

check_hosts_presence() {
    local context helper entries response line status name
    local -A seen=()
    HOSTS_PRESENCE=()
    entries=$(configured_hosts_entries)
    if ! context=$(readlink -f -- "$CONFIG") ||
       ! context=$(cygpath -w "$context") ||
       ! helper=$(cygpath -w "$SCRIPT_DIR/hosts-manager.ps1") ||
       ! response=$(WIZARD_CONTEXT_PATH="$context" WIZARD_HOSTS="$entries" \
           powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
           -File "$helper" -Mode Check -Action Sync </dev/null 2>&1); then
        MESSAGE='Could not read Windows hosts mappings; presence is unavailable.'
        return 1
    fi
    response=${response//$'\r'/}
    if [[ -n "$response" ]]; then
        while IFS= read -r line; do
            if [[ ! "$line" =~ ^HOST\|(PRESENT|ABSENT|CONFLICT)\|([a-z0-9.-]+)$ ]]; then
                HOSTS_PRESENCE=()
                MESSAGE='Invalid Windows hosts check response; presence is unavailable.'
                return 1
            fi
            status=${BASH_REMATCH[1]}
            name=${BASH_REMATCH[2]}
            if [[ -z "${HOSTNAME_IP[$name]:-}" || -n "${seen[$name]:-}" ]]; then
                HOSTS_PRESENCE=()
                MESSAGE='Invalid Windows hosts check response; presence is unavailable.'
                return 1
            fi
            seen["$name"]=1
            HOSTS_PRESENCE["$name"]=$status
        done <<< "$response"
    fi
    for name in "${LOCAL_HOSTNAMES[@]}"; do
        if [[ -z "${seen[$name]:-}" ]]; then
            HOSTS_PRESENCE=()
            MESSAGE='Incomplete Windows hosts check; presence is unavailable.'
            return 1
        fi
    done
    MESSAGE=""
}

manage_hosts() {
    local action=$1 context helper entries preview snapshot answer="" result line
    entries=$(configured_hosts_entries)
    if [[ "$action" != Sync ]]; then
        entries=""
    fi

    restore_tty_mode
    printf '\033[?25h\033[H\033[J'
    if [[ "$action" == RemoveAll ]]; then
        printf 'Windows hosts: delete ALL TunnelWizard blocks across ALL configs\n\n'
    elif [[ "$action" == Remove ]]; then
        printf 'Windows hosts: delete this config block only\n\n'
    else
        printf 'Windows hosts: Apply configured hostnames (this config only)\n\n'
    fi
    if ! context=$(readlink -f -- "$CONFIG") ||
       ! context=$(cygpath -w "$context") ||
       ! helper=$(cygpath -w "$SCRIPT_DIR/hosts-manager.ps1"); then
        printf 'Cannot resolve config or hosts helper path.\n'
    elif ! preview=$(WIZARD_CONTEXT_PATH="$context" WIZARD_HOSTS="$entries" \
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
        -File "$helper" -Mode Preview -Action "$action" 2>&1); then
        printf 'Preview refused: %s\n' "$preview"
    else
        preview=${preview//$'\r'/}
        snapshot=${preview##*$'\n'SNAPSHOT=}
        if [[ ! "$snapshot" =~ ^[0-9a-f]{64}$ ]]; then
            printf 'Invalid preview response; no changes made.\n'
        else
            while IFS= read -r line; do
                case "$line" in
                    DIFF\|Equal\|*)  colour '38;2;144;148;157' "  ${line#DIFF|Equal|}"; printf '\n' ;;
                    DIFF\|Remove\|*) colour '38;2;221;145;153' "- ${line#DIFF|Remove|}"; printf '\n' ;;
                    DIFF\|Add\|*)    colour '38;2;145;204;163' "+ ${line#DIFF|Add|}"; printf '\n' ;;
                    *)               printf '%s\n' "$line" ;;
                esac
            done <<< "${preview%$'\n'SNAPSHOT=*}"
            printf '\n'
            if [[ "$preview" == *'No changes needed.'* ]]; then
                printf 'No hosts edit or DNS flush was needed.\n'
            else
                if [[ "$action" == RemoveAll ]]; then
                    read -r -p 'Confirm DELETE ALL TunnelWizard blocks across ALL configs? This requests administrator elevation (UAC). [y/N] ' answer <&3 || true
                elif [[ "$action" == Remove ]]; then
                    read -r -p 'Confirm DELETE this config block? This requests administrator elevation (UAC). [y/N] ' answer <&3 || true
                else
                    read -r -p 'Confirm APPLY this config hosts? This requests administrator elevation (UAC). [y/N] ' answer <&3 || true
                fi
                if [[ "$answer" == y || "$answer" == Y ]]; then
                    local commit_output
                    commit_output=$(WIZARD_CONTEXT_PATH="$context" WIZARD_HOSTS="$entries" \
                        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass \
                        -File "$helper" -Mode Commit -Action "$action" \
                        -ExpectedHash "$snapshot" < /dev/null 2>&1)
                    result=$?
                    [[ -n "$commit_output" ]] && printf '%s\n' "$commit_output"
                    case "$result" in
                        0) printf 'Hosts updated; Windows DNS cache flushed.\n' ;;
                        3) printf 'Hosts updated, but ipconfig /flushdns FAILED. Retry flush manually.\n' ;;
                        4) printf 'UAC cancelled; hosts file was not changed.\n' ;;
                        *) printf 'Hosts update failed; review the diagnostic above and try again.\n' ;;
                    esac
                else
                    printf 'Cancelled; hosts file was not changed.\n'
                fi
            fi
        fi
    fi
    read -r -p 'Press Enter to return... ' _ <&3 || true
    check_hosts_presence || true
    if ! set_tty_mode; then
        EXIT_REQUESTED=1
        return 1
    fi
    printf '\033[?25l'
    FORCE_REPAINT=1
    REDRAW_NEEDED=1
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

    if [[ -n "$RENDER_CAPTURE_FILE" ]]; then
        rm -f -- "$RENDER_CAPTURE_FILE"
        RENDER_CAPTURE_FILE=""
    fi

    trap - INT TERM EXIT WINCH
    if ((SSH_CONFIG_EXPLICIT)); then
        exec "$SCRIPT_PATH" "$CONFIG" --ssh-config "$SSH_CONFIG_FILE"
    fi
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

if ((${#TUNNEL_IDS[@]} > 0)); then
    declare -A STARTUP_PIDS=()

    # Launch all initial tunnels before waiting, so the early-exit grace
    # period is shared rather than cumulative across configured tunnels.
    for id in "${TUNNEL_IDS[@]}"; do
        ((EXIT_REQUESTED)) && exit 130
        STATUS["$id"]="STARTING"
        start_one "$id"
        STARTUP_PIDS["$id"]=${PIDS[-1]}
    done

    render_dashboard
    # Early-exit check, not a remote-service health check.
    sleep "$STARTUP_WAIT"
    ((EXIT_REQUESTED)) && exit 130

    for id in "${TUNNEL_IDS[@]}"; do
        start_with_retry "$id" "${STARTUP_PIDS[$id]}"
        ((EXIT_REQUESTED)) && exit 130
    done
fi

render_screen

while true; do
    ((EXIT_REQUESTED)) && exit 130

    if ((SECONDS >= NEXT_TUNNEL_POLL)); then
        poll_tunnel_processes
        NEXT_TUNNEL_POLL=$((SECONDS + TUNNEL_POLL_INTERVAL))
    fi

    if ((REDRAW_NEEDED)); then
        render_screen
    fi

    if ! read_key "$INPUT_POLL_TIMEOUT"; then
        continue
    fi

    ((EXIT_REQUESTED)) && exit 130

    if [[ "$KEY" == RESTART ]]; then
        request_restart
    fi

    if [[ "$UI_MODE" == hosts ]]; then
        case "$KEY" in
            a|A|d|D|REMOVE_ALL_HOSTS)
                if ! is_windows_shell; then
                    MESSAGE='Hosts-file sync is Windows-only; configured forwards still bind locally.'
                    REDRAW_NEEDED=1
                elif [[ "$KEY" == a || "$KEY" == A ]]; then
                    manage_hosts Sync || true
                elif [[ "$KEY" == REMOVE_ALL_HOSTS ]]; then
                    manage_hosts RemoveAll || true
                else
                    manage_hosts Remove || true
                fi
                ;;
            ESC|q|Q)
                UI_MODE="dashboard"
                MESSAGE=""
                REDRAW_NEEDED=1
                ;;
        esac
    elif [[ "$UI_MODE" == dashboard ]]; then
        case "$KEY" in
            h|H)
                if [[ "$HOSTS_MANAGEMENT" != yes ]]; then
                    MESSAGE='Hosts UI disabled. Add hosts_management yes to this config to opt in.'
                elif ! is_windows_shell; then
                    MESSAGE='Automatic hosts management is Windows-only; add aliases manually.'
                elif ! command -v powershell.exe >/dev/null 2>&1 ||
                     ! command -v cygpath >/dev/null 2>&1 ||
                     ! command -v readlink >/dev/null 2>&1 ||
                     [[ ! -r "$SCRIPT_DIR/hosts-manager.ps1" ]]; then
                    MESSAGE='Windows hosts helper, PowerShell, cygpath or readlink unavailable.'
                else
                    UI_MODE="hosts"
                    MESSAGE=""
                    check_hosts_presence || true
                fi
                REDRAW_NEEDED=1
                ;;
            s|S)
                if ((${#SHELL_NAMES[@]} > 0)); then
                    UI_MODE="menu"
                    SHELL_SELECTION=0
                    MENU_SCROLL=0
                    MESSAGE=""
                    REDRAW_NEEDED=1
                fi
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
                if ((${#SHELL_NAMES[@]} > 0)); then
                    open_shell_window "$SHELL_SELECTION" || true
                    REDRAW_NEEDED=1
                fi
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
