#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source <(awk '/^create_render_capture_file\(\) \{/ { capture=1 } capture { print; if ($0 == "}") exit }' "$root/TW.sh")
source <(awk '/^paint_row\(\) \{/ { capture=1 } capture { print; if ($0 == "}") exit }' "$root/TW.sh")
source <(awk '/^render_global_controls\(\) \{/ { capture=1 } capture { print; if ($0 == "}") exit }' "$root/TW.sh")
source <(awk '/^render_dashboard_shell_controls\(\) \{/ { capture=1 } capture { print; if ($0 == "}") exit }' "$root/TW.sh")
source <(awk '/^render_dashboard_global_controls\(\) \{/ { capture=1 } capture { print; if ($0 == "}") exit }' "$root/TW.sh")
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { copying=1 } copying { print; if ($0 == "}") exit }' "$root/TW.sh")
}
for fn in render_footer_help_hint truncate_cell_name render_shell_cell render_shell_row \
    shift_ui_line_left status_badge_palette status_badge render_tunnel_row \
    render_status_bleed dashboard_shell_count dashboard_controls_layout \
    render_dashboard_controls_row_one render_dashboard_controls_row_two \
    render_dashboard_controls_full render_dashboard_controls_compact \
    render_dashboard_quick_launch_title render_dashboard_hat_line render_dashboard_gap_hat \
    render_dashboard_footer render_message render_dashboard render_shell_menu \
    render_menu_controls_full render_menu_controls_short render_menu_return_hint \
    render_alias_return_hint render_hosts_return_controls render_hosts_controls \
    render_hosts_controls_return render_help; do
    load_function "$fn"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
key_hint() { printf '%s' "$1"; }
render_arrow_hint() { printf '←/→/↑/↓'; }
colour() {
    if [[ ${CAPTURE_COLOUR_STYLE:-no} == yes ]]; then
        printf '<%s>%s' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}
print_clipped_line() { printf '%s' "${1:0:TERM_WIDTH-1}"; }
QUICK_LAUNCH_ALT=no
QUICK_NAMES=()

RENDER_CAPTURE_FILE=""
RENDER_CAPTURE_DISABLED=0

# Simulate an environment where every candidate temp directory rejects mktemp.
mktemp() { return 1; }
if create_render_capture_file; then
    fail 'capture file unexpectedly created when all temp paths fail'
fi
[[ -z "$RENDER_CAPTURE_FILE" && $RENDER_CAPTURE_DISABLED -eq 1 ]] ||
    fail 'failed temp creation did not enable the no-file fallback'

render_test_row() { printf 'fallback row'; }
RENDER_BUFFER=""
ROW_CACHE=()
ROW_CACHE_VALID=()
ROW_SEEN=()
paint_row 1 render_test_row
[[ "${ROW_CACHE[1]}" == 'fallback row' && "${ROW_SEEN[1]}" == 1 ]] ||
    fail 'row was not captured in memory when temp storage was unavailable'
[[ "$RENDER_BUFFER" == *'fallback row'* ]] || fail 'fallback row was not queued for display'
render_indented_test_row() { printf '  UI row'; }
paint_row 2 render_indented_test_row
[[ "${ROW_CACHE[2]}" == ' UI row' ]] ||
    fail 'painted UI row was not shifted left by exactly one column'

# Exercise the regular capture-file branch as well as the in-memory fallback.
test_capture_file=$(command mktemp)
trap 'rm -f -- "$test_capture_file"' EXIT
RENDER_CAPTURE_FILE=$test_capture_file
RENDER_CAPTURE_DISABLED=0
render_file_test_row() { printf '  file row\n'; }
paint_row 3 render_file_test_row
[[ "${ROW_CACHE[3]}" == ' file row' && ${ROW_SEEN[3]} == 1 ]] ||
    fail 'capture-file row was not shifted left by exactly one column'
[[ $RENDER_CAPTURE_FILE == "$test_capture_file" && $RENDER_CAPTURE_DISABLED -eq 0 ]] ||
    fail 'successful capture-file rendering unexpectedly disabled capture'
[[ "$RENDER_BUFFER" == *'file row'* ]] || fail 'file-captured row was not queued for display'
RENDER_CAPTURE_FILE=""
rm -f -- "$test_capture_file"
trap - EXIT

shifted_ansi_row=$(shift_ui_line_left $'\033[1m  styled row\033[0m')
[[ $shifted_ansi_row == $'\033[1m styled row\033[0m' ]] ||
    fail 'left shift did not preserve leading ANSI styling'

for render_footer in \
    render_global_controls \
    render_dashboard_shell_controls \
    render_dashboard_global_controls \
    render_menu_controls_full \
    render_menu_controls_short \
    render_menu_return_hint \
    render_alias_return_hint \
    render_hosts_return_controls; do
    for TERM_WIDTH in 20 30 34 40 55 70 80 140; do
        if [[ $render_footer == render_menu_controls_full ]] && ((TERM_WIDTH < 80)); then continue; fi
        footer=$("$render_footer")
        ((${#footer} <= TERM_WIDTH - 1)) ||
            fail "$render_footer exceeded the safe width at $TERM_WIDTH columns (${#footer} chars)"
        [[ "$footer" != *$'\n'* ]] ||
            fail "$render_footer emitted a line break at $TERM_WIDTH columns"
        if ((TERM_WIDTH < 65)); then
            [[ "$footer" != *'H Hosts'* ]] ||
                fail "$render_footer emitted a potentially wrapping Hosts label at $TERM_WIDTH columns"
        fi
    done
done

QUICK_NAMES=(one two three four five six seven eight nine ten)
TERM_WIDTH=100
QUICK_LAUNCH_ALT=yes
footer=$(render_dashboard_shell_controls)
[[ $footer == *'[A]1–9 Open 10–18'* && $footer != *'? Help'* ]] ||
    fail 'dashboard quick-select row omitted its Alt hint or duplicated Help'
((${#footer} <= TERM_WIDTH - 1)) || fail 'opt-in Alt footer exceeded the safe width'
dashboard_footer="$footer$(render_dashboard_global_controls)"
[[ $dashboard_footer == *'? Help'* && ${dashboard_footer#*'? Help'} != *'? Help'* ]] ||
    fail 'dashboard footer did not show exactly one Help hint'
TERM_WIDTH=150
dashboard_footer=$(render_dashboard_shell_controls)
[[ $dashboard_footer == *'S Shells'* && $dashboard_footer == *'A Aliases'* &&
   $dashboard_footer == *'? Help'* ]] ||
    fail 'wide dashboard did not combine all controls into one row'
QUICK_LAUNCH_ALT=no
footer=$(render_dashboard_shell_controls)
[[ $footer != *'[A]1–9'* ]] || fail 'disabled Alt range was visible in the dashboard footer'

for TERM_WIDTH in 25 29 35 36 80; do
    QUICK_NAMES=('A very long first name' 'A very long second name' 'A very long third name')
    SHELL_SELECTION=1
    row=$(render_shell_row 0 3 "$((TERM_WIDTH < 36 ? (TERM_WIDTH - 4) / 3 : (TERM_WIDTH - 7) / 3))")
    ((${#row} <= TERM_WIDTH - 1)) || fail "quick-launch grid overflowed at $TERM_WIDTH columns"
    [[ $row == *'»'* && $row != *'...'* ]] || fail "cell truncation was not a one-column glyph at $TERM_WIDTH"
done
QUICK_NAMES=()
for i in {1..21}; do QUICK_NAMES+=("Entry number $i with a long label"); done
TERM_WIDTH=29
SHELL_SELECTION=17
QUICK_LAUNCH_ALT=no
row=$(render_shell_row 15 21 "$(((TERM_WIDTH - 4) / 3))")
[[ $row != *A9* ]] || fail 'disabled Alt shortcut was visible on an entry'
QUICK_LAUNCH_ALT=yes
row=$(render_shell_row 15 21 "$(((TERM_WIDTH - 4) / 3))")
[[ $row == *A7* && $row == *A8* && $row == *A9* ]] || fail 'enabled Alt labels 16–18 are missing'
((${#row} <= TERM_WIDTH - 1)) || fail 'Alt labels overflowed the compact grid'
row=$(render_shell_row 18 21 "$(((TERM_WIDTH - 4) / 3))")
[[ $row != *A1* && $row == *'»'* ]] || fail 'entries after 18 lost full-menu navigation'

# Exercise the dashboard/menu layouts as well as their cell renderer at the
# old 36-column boundary and the new compact minimum.
begin_screen() { BODY_ROW=1; BODY_LAST_ROW=$((TERM_HEIGHT - $1)); }
body_line() { "$@"; printf '\n'; BODY_ROW=$((BODY_ROW + 1)); }
footer_at() { shift; "$@"; printf '\n'; }
finish_screen() { :; }
render_header_line() { :; }
render_rule() { :; }
render_menu_footer() { :; }
ensure_terminal_size() { :; }
TUNNEL_IDS=()
MESSAGE=''
TERM_HEIGHT=40
MENU_SCROLL=0

# Empty quick-launch grids still use the same responsive control grouping.
QUICK_NAMES=()
for width_layout in '20:short' '55:short' '80:rows' '140:full'; do
    TERM_WIDTH=${width_layout%%:*}
    expected_layout=${width_layout#*:}
    [[ $(dashboard_controls_layout) == "$expected_layout" ]] ||
        fail "empty dashboard controls chose the wrong layout at width $TERM_WIDTH"
    footer=$(render_dashboard_footer)
    mapfile -t footer_lines <<< "$footer"
    expected_lines=1
    [[ $expected_layout == rows ]] && expected_lines=2
    ((${#footer_lines[@]} == expected_lines)) ||
        fail "empty dashboard footer rendered ${#footer_lines[@]} rows at width $TERM_WIDTH"
    for line in "${footer_lines[@]}"; do
        ((${#line} <= TERM_WIDTH - 1)) ||
            fail "empty dashboard footer overflowed at width $TERM_WIDTH"
    done
done
QUICK_NAMES=()
for i in {1..21}; do QUICK_NAMES+=("Entry number $i with a long label"); done

# The quick-launch title remains text-clipped but receives bold styling.
truncate_text() { printf '%s' "${1:0:$2}"; }
TERM_WIDTH=80
QUICK_LAUNCH_ALT=yes
CAPTURE_COLOUR_STYLE=yes
title=$(render_dashboard_quick_launch_title)
CAPTURE_COLOUR_STYLE=no
[[ $title == '<1>  QUICK LAUNCH (TOP 18)' ]] ||
    fail 'quick-launch title was not bold or selected the wrong launch range'
QUICK_LAUNCH_ALT=no

# Small fade circles retain each status badge's foreground hue while growing
# brighter toward the badge, rather than staying purple.
CAPTURE_COLOUR_STYLE=yes
stopped_badge=$(status_badge STOPPED)
stopped_fade=$(render_status_bleed STOPPED)
CAPTURE_COLOUR_STYLE=no
[[ $stopped_badge == '<38;2;255;190;190;48;2;92;37;49> '* ]] ||
    fail 'stopped badge did not use the expected status palette'
[[ $stopped_fade == '<38;2;89;66;66>·<38;2;165;123;123>·<38;2;229;171;171>·' ]] ||
    fail 'status fade circles did not retain and brighten the badge colour'

# The fade uses existing label padding on wide terminals, keeping the status
# column at the same position; compact widths omit it.
render_tunnel_label() { printf '%-*s' "$2" 'label'; }
status_badge() { printf '[%s]' "$1"; }
declare -A SSH_HOST STATUS
SSH_HOST[test]='example.test'
STATUS[test]=RUNNING
TERM_WIDTH=80
wide_status_row=$(render_tunnel_row test 30 12)
TERM_WIDTH=60
compact_status_row=$(render_tunnel_row test 30 12)
[[ $wide_status_row == *'···[RUNNING]'* && $compact_status_row != *'···'* ]] ||
    fail 'small circle fade did not lead directly into the status badge only at wide layout'
wide_badge_column=${wide_status_row%%\[*}
compact_badge_column=${compact_status_row%%\[*}
[[ ${#wide_badge_column} -eq ${#compact_badge_column} ]] ||
    fail 'status fade shifted the table status column'

QUICK_LAUNCH_ALT=yes
for TERM_WIDTH in 25 35 36; do
    dashboard=$(render_dashboard)
    menu=$(render_shell_menu)
    [[ $dashboard == *'»'* && $dashboard != *'Widen this window to see the three-column grid.'* ]] ||
        fail "dashboard hid the compact quick-launch grid at $TERM_WIDTH"
    [[ $menu == *'MORE CONNECTIONS'* && $menu == *A9* &&
       $menu != *'Widen this window to see the three-column grid.'* ]] ||
        fail "menu hid entries beyond nine at $TERM_WIDTH"
    while IFS= read -r line; do
        ((${#line} <= TERM_WIDTH - 1)) || fail "dashboard/menu row overflowed at $TERM_WIDTH"
    done <<< "$dashboard"$'\n'"$menu"
done

# The tunnel list and quick-launch title are now separated by one blank row.
QUICK_NAMES=(one two three)
QUICK_LAUNCH_ALT=no
TERM_HEIGHT=40
TERM_WIDTH=80
dashboard=$(render_dashboard)
spacer_count=0
in_quick_launch_gap=0
while IFS= read -r line; do
    if [[ $line == *'No port forwards configured.'* ]]; then
        in_quick_launch_gap=1
        continue
    fi
    if ((in_quick_launch_gap)); then
        if [[ $line == *'QUICK LAUNCH'* ]]; then break; fi
        [[ -z $line ]] && ((spacer_count += 1))
    fi
done <<< "$dashboard"
((spacer_count == 1)) || fail "expected one blank row before quick launch, found $spacer_count"

# The decorative hat fits only in a seven-row blank gap after quick launches.
# The last-event message consumes a footer row, and bonus launches reduce the
# gap by adding grid rows.
TERM_WIDTH=80
QUICK_NAMES=(one two three four five six seven eight nine)
QUICK_LAUNCH_ALT=no
TERM_HEIGHT=17
dashboard=$(render_dashboard)
[[ $dashboard != *'_.,_'* ]] || fail 'dashboard drew the hat in a six-row gap'
TERM_HEIGHT=18
dashboard=$(render_dashboard)
[[ $dashboard == *'_.,_'* && $dashboard == *'__/_______\__'* ]] ||
    fail 'dashboard did not draw the hat in a seven-row gap'
hat_row=''
while IFS= read -r line; do
    if [[ $line == *'_.,_'* ]]; then hat_row=$line; break; fi
done <<< "$dashboard"
hat_prefix=${hat_row%%_.,_*}
expected_hat_column=$(((TERM_WIDTH - 18) / 2 + 10))
[[ ${#hat_prefix} -eq $expected_hat_column ]] ||
    fail 'dashboard hat was not centered horizontally'

MESSAGE='Tunnel stopped: 65022 : Mnemosyne SSH. Ctrl+R restarts all.'
TERM_HEIGHT=18
dashboard=$(render_dashboard)
[[ $dashboard != *'_.,_'* ]] ||
    fail 'dashboard drew the hat in space reserved for the last-event message'
TERM_HEIGHT=19
dashboard=$(render_dashboard)
[[ $dashboard == *'_.,_'* ]] ||
    fail 'last-event message did not leave the hat visible with seven blank rows'
MESSAGE=''

# Non-positive gaps are rejected without emitting padding or hat rows.
TERM_WIDTH=80
BODY_ROW=12
BODY_LAST_ROW=11
hat_output=$(render_dashboard_gap_hat)
[[ -z $hat_output && $BODY_ROW -eq 12 ]] ||
    fail 'zero-row dashboard gap unexpectedly rendered the hat'
BODY_LAST_ROW=10
hat_output=$(render_dashboard_gap_hat)
[[ -z $hat_output && $BODY_ROW -eq 12 ]] ||
    fail 'negative-row dashboard gap unexpectedly rendered the hat'

QUICK_NAMES=()
for i in {1..18}; do QUICK_NAMES+=("Entry $i"); done
QUICK_LAUNCH_ALT=yes
TERM_HEIGHT=20
dashboard=$(render_dashboard)
[[ $dashboard != *'_.,_'* ]] ||
    fail 'bonus quick launches did not reduce the available gap'
TERM_HEIGHT=21
dashboard=$(render_dashboard)
[[ $dashboard == *'_.,_'* ]] ||
    fail 'dashboard did not show the hat when the bonus-launch layout had seven blank rows'

# Render contextual help through the same row callbacks, without a terminal.
TERM_WIDTH=80
for context in dashboard menu aliases hosts; do
    HELP_RETURN_MODE=$context
    help_text=$(render_help)
    case "$context" in
        dashboard) [[ $help_text == *'N  New local SSH-configured shell'* &&
                      $help_text == *'[A]1–9'* &&
                      $help_text == *'S  Shells menu (all entries)'* ]] ;;
        menu) [[ $help_text == *'HELP · SHELLS'* && $help_text == *'Navigate all entries'* &&
                 $help_text == *'[A]1–9'* ]] ;;
        aliases) [[ $help_text == *'I  Import'* && $help_text == *'C  Clear all managed aliases'* ]] ;;
        hosts) [[ $help_text == *'Ctrl+D  Delete all TunnelWizard hosts blocks'* ]] ;;
    esac || fail "$context help is missing relevant shortcuts"
    [[ $help_text == *'Ctrl+R  Restart tunnels'* && $help_text == *'Ctrl+C  Stop and exit'* &&
       $help_text == *'? / Esc / Q  Return'* ]] || fail "$context help is missing global/return controls"
done
QUICK_NAMES=(one two three four five six seven eight nine)
QUICK_LAUNCH_ALT=yes
HELP_RETURN_MODE=dashboard
help_text=$(render_help)
[[ $help_text != *'[A]1–9'* ]] || fail 'help showed Alt shortcuts without entries 10–18'
QUICK_LAUNCH_ALT=no
HELP_RETURN_MODE=menu
help_text=$(render_help)
[[ $help_text != *'[A]1–9'* ]] || fail 'disabled Alt shortcut was visible in help'

# The dashboard has no selection cursor; the Shells menu retains the marker.
QUICK_NAMES=(a bb cccccc)
SHELL_SELECTION=0
for TERM_WIDTH in 35 80; do
    cell_width=$((TERM_WIDTH < 36 ? (TERM_WIDTH - 4) / 3 : (TERM_WIDTH - 7) / 3))
    row=$(render_shell_row 0 3 "$cell_width" no)
    [[ $row != *'>'* ]] || fail 'dashboard quick-launch grid drew a selection cursor'
    menu_row=$(render_shell_row 0 3 "$cell_width")
    [[ $menu_row == *'>  1 '* || $menu_row == *'> 1 '* ]] ||
        fail 'Shells menu lost its selected marker'

    if ((TERM_WIDTH < 36)); then
        margin=1 gap=1 prefix_width=4
    else
        margin=2 gap=2 prefix_width=5
    fi
    for cell in 0 1 2; do
        name_column=$((margin + cell * (cell_width + gap) + prefix_width))
        expected_initial=${QUICK_NAMES[$cell]:0:1}
        [[ ${row:name_column:1} == "$expected_initial" ]] ||
            fail "quick-launch cell $((cell + 1)) name shifted at width $TERM_WIDTH"
    done
done

# The digits in 1/4/7 and their Alt variants A1/A4/A7 share a column in each
# cell, in both compact and wide layouts.
QUICK_NAMES=(alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november oscar papa quebec romeo)
QUICK_LAUNCH_ALT=yes
SHELL_SELECTION=-1
for TERM_WIDTH in 35 80; do
    cell_width=$((TERM_WIDTH < 36 ? (TERM_WIDTH - 4) / 3 : (TERM_WIDTH - 7) / 3))
    digit_column=$((TERM_WIDTH < 36 ? 2 : 3))
    for column in 0 1 2; do
        regular_index=$((column * 3))
        alt_index=$((regular_index + 9))
        regular_cell=$(render_shell_cell "$regular_index" "$cell_width")
        alt_cell=$(render_shell_cell "$alt_index" "$cell_width")
        expected_digit=$((regular_index + 1))
        [[ ${regular_cell:digit_column:1} == "$expected_digit" &&
           ${alt_cell:digit_column:1} == "$expected_digit" ]] ||
            fail "quick-launch digit $expected_digit shifted between regular and Alt labels at width $TERM_WIDTH"
    done
done

printf 'Render capture fallback tests passed.\n'
