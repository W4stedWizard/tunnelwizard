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
    dashboard_shell_count render_dashboard render_shell_menu \
    render_menu_controls_full render_menu_controls_short render_menu_return_hint \
    render_alias_return_hint render_hosts_return_controls render_hosts_controls \
    render_hosts_controls_return render_help; do
    load_function "$fn"
done

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
key_hint() { printf '%s' "$1"; }
render_arrow_hint() { printf '←/→/↑/↓'; }
colour() { printf '%s' "$2"; }
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
[[ $footer == *'Alt+1–9 Open 10–18'* && $footer != *'? Help'* ]] ||
    fail 'dashboard quick-launch row showed an Alt hint incorrectly or duplicated Help'
((${#footer} <= TERM_WIDTH - 1)) || fail 'opt-in Alt footer exceeded the safe width'
dashboard_footer="$footer$(render_dashboard_global_controls)"
[[ $dashboard_footer == *'? Help'* && ${dashboard_footer#*'? Help'} != *'? Help'* ]] ||
    fail 'dashboard footer did not show exactly one Help hint'
QUICK_LAUNCH_ALT=no
footer=$(render_dashboard_shell_controls)
[[ $footer != *'Alt+1–9'* ]] || fail 'disabled Alt range was visible in the dashboard footer'

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
render_dashboard_footer() { :; }
render_menu_footer() { :; }
ensure_terminal_size() { :; }
TUNNEL_IDS=()
MESSAGE=''
TERM_HEIGHT=40
MENU_SCROLL=0
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

# Render contextual help through the same row callbacks, without a terminal.
TERM_WIDTH=80
for context in dashboard menu aliases hosts; do
    HELP_RETURN_MODE=$context
    help_text=$(render_help)
    case "$context" in
        dashboard) [[ $help_text == *'N  New local SSH-configured shell'* && $help_text == *'Alt+1–9'* ]] ;;
        menu) [[ $help_text == *'Navigate all entries'* && $help_text == *'Alt+1–9'* ]] ;;
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
[[ $help_text != *'Alt+1–9'* ]] || fail 'help showed Alt shortcuts without entries 10–18'
QUICK_LAUNCH_ALT=no
HELP_RETURN_MODE=menu
help_text=$(render_help)
[[ $help_text != *'Alt+1–9'* ]] || fail 'disabled Alt shortcut was visible in help'

# The selected marker is the only visual difference in the first row. Keep it
# single-column so the first row's later cells line up with the rows below in
# terminals that render ambiguous-width Unicode chevrons as double-width.
QUICK_NAMES=(a bb cccccc)
SHELL_SELECTION=0
for TERM_WIDTH in 35 80; do
    cell_width=$((TERM_WIDTH < 36 ? (TERM_WIDTH - 4) / 3 : (TERM_WIDTH - 7) / 3))
    row=$(render_shell_row 0 3 "$cell_width")
    [[ $row == *'>1 '* || $row == *'> 1 '* ]] ||
        fail 'selected quick-launch marker was not the one-column ASCII marker'

    if ((TERM_WIDTH < 36)); then
        margin=1 gap=1 prefix_width=3
    else
        margin=2 gap=2 prefix_width=4
    fi
    for cell in 0 1 2; do
        name_column=$((margin + cell * (cell_width + gap) + prefix_width))
        expected_initial=${QUICK_NAMES[$cell]:0:1}
        [[ ${row:name_column:1} == "$expected_initial" ]] ||
            fail "quick-launch cell $((cell + 1)) name shifted at width $TERM_WIDTH"
    done
done

printf 'Render capture fallback tests passed.\n'
