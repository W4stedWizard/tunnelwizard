#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source <(awk '/^if \[\[ ! -r "\$CONFIG" \]\]; then/ { exit } { print }' "$root/tunnels.sh")
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { copying=1 } copying { print; if ($0 == "}") exit }' "$root/tunnels.sh")
}
load_function dashboard_shell_count
load_function move_shell_horizontal
load_function move_shell_vertical
load_function open_quick_window
load_function colour
load_function status_badge
load_function stop_tunnels
load_function kill_all_tunnels

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
shell 'SSH one' one.example.invalid
custom_command 'Local one' 'printf "%s" "$HOME"; echo done'
shell 'SSH two' two.example.invalid
[[ ${QUICK_NAMES[*]} == 'SSH one Local one SSH two' ]] || fail 'declaration order was lost'
[[ ${QUICK_KINDS[*]} == 'ssh command ssh' ]] || fail 'entry types were lost'
[[ ${QUICK_VALUES[1]} == 'printf "%s" "$HOME"; echo done' ]] || fail 'command text was expanded'
[[ ${SHELL_TARGETS[*]} == 'one.example.invalid two.example.invalid' ]] || fail 'SSH targets changed'
for i in {4..12}; do custom_command "Local $i" "echo $i"; done
[[ $(dashboard_shell_count) == 9 && ${#QUICK_NAMES[@]} -eq 12 ]] || fail 'dashboard/menu counts differ'
SHELL_SELECTION=8
move_shell_vertical 1 9
[[ $SHELL_SELECTION -eq 2 ]] || fail 'dashboard row wrap changed'
SHELL_SELECTION=8
move_shell_vertical 1
[[ $SHELL_SELECTION -eq 11 ]] || fail 'menu does not reach items past nine'
move_shell_horizontal 1
[[ $SHELL_SELECTION -eq 9 ]] || fail 'menu row wrap changed'
open_shell_window() { selected="ssh:$1"; }
open_command_window() { selected="command:$1"; }
open_quick_window 0
[[ $selected == ssh:0 ]] || fail 'first SSH entry not dispatched'
open_quick_window 1
[[ $selected == command:1 ]] || fail 'local command was sent to SSH'
open_quick_window 2
[[ $selected == ssh:1 ]] || fail 'second SSH entry lost SSH array index'
open_quick_window 9
[[ $selected == command:9 ]] || fail 'menu-only command was not dispatched'
parse_cli_args --run-command-base64 ZWNobyBoZWxsbw==
[[ $COMMAND_MODE -eq 1 && $COMMAND_B64 == ZWNobyBoZWxsbw== ]] || fail 'command transport not parsed'
if parse_cli_args --run-command-base64 ZWNobyBoZWxsbw== --ssh-config x 2>/dev/null; then
    fail 'local command accepted SSH config options'
fi
if parse_cli_args --connect-base64 ZWNobyBoZWxsbw== --run-command-base64 ZWNobyBoZWxsbw== 2>/dev/null; then
    fail 'SSH connect mode and local command mode were both accepted'
fi

USE_COLOUR=1
badge=$(status_badge RUNNING)
[[ "$badge" == *$'\033[38;2;224;188;255;48;2;68;43;91m'*RUNNING* ]] ||
    fail 'RUNNING badge is not purple'

killed_pids=()
waited_pids=()
kill() { killed_pids+=("$1"); }
wait() { waited_pids+=("$1"); }
PIDS=(111 222)
PID_TO_TUNNEL=([111]=one [222]=two)
TUNNEL_IDS=(one two three)
declare -A STATUS=([one]=RUNNING [two]=STARTING [three]=SKIPPED)
EXIT_REQUESTED=0
UI_MODE=dashboard
MESSAGE=''
REDRAW_NEEDED=0
kill_all_tunnels
[[ ${killed_pids[*]} == '111 222' && ${waited_pids[*]} == '111 222' ]] ||
    fail 'K did not stop and reap every tunnel subprocess'
[[ ${#PIDS[@]} -eq 0 && ${#PID_TO_TUNNEL[@]} -eq 0 ]] || fail 'stopped subprocesses remain tracked'
[[ ${STATUS[one]} == STOPPED && ${STATUS[two]} == STOPPED && ${STATUS[three]} == SKIPPED ]] ||
    fail 'K did not update only active tunnel statuses'
[[ $EXIT_REQUESTED -eq 0 && $UI_MODE == dashboard && $REDRAW_NEEDED -eq 1 ]] ||
    fail 'K exited or left the dashboard instead of redrawing it'
[[ $MESSAGE == *'Ctrl+R restarts them'* ]] || fail 'K did not explain how to restart tunnels'
kill_all_tunnels
[[ $MESSAGE == 'No active tunnel subprocesses.' ]] || fail 'empty K action was not reported'

test_home=$(mktemp -d)
trap 'rm -rf -- "$test_home"' EXIT
literal_command="printf '%s' 'literal; value'"
encoded_command=$(printf '%s' "$literal_command" | base64 | tr -d '\r\n')
actual=$(HOME="$test_home" bash "$root/tunnels.sh" --run-command-base64 \
    "$encoded_command" 2>/dev/null <<< '')
[[ "$actual" == *'literal; value'* && "$actual" == *'Command ended (exit status 0)'* ]] ||
    fail 'base64 local command mode did not run the exact command'
printf 'Quick-launch model and dispatch tests passed.\n'
