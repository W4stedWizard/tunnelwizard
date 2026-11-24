#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source <(awk '/^if \[\[ ! -r "\$CONFIG" \]\]; then/ { exit } { print }' "$root/TW.sh")
load_function() {
    source <(awk -v name="$1" '$0 == name "() {" { copying=1 } copying { print; if ($0 == "}") exit }' "$root/TW.sh")
}
load_function dashboard_shell_count
load_function move_shell_horizontal
load_function move_shell_vertical
load_function open_quick_window
load_function colour
load_function status_badge_palette
load_function status_badge
load_function stop_tunnels
load_function kill_all_tunnels
load_function running_in_wezterm
load_function is_windows_shell
load_function find_cygpath
load_function to_windows_path
load_function spawn_wezterm
load_function open_local_shell_window
load_function print_local_shell_banner
load_function handle_ui_key
load_function handle_dashboard_key
load_function read_key
load_function start_with_retry
load_function start_or_skip_startup_tunnel
SCRIPT_DIR=$root

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
test_home=$(mktemp -d)
trap 'rm -rf -- "$test_home"' EXIT
custom="$test_home/custom ssh_config"
printf 'Host *\n    ServerAliveInterval 15\n' >"$custom"

# Git Bash may not have its standard /usr/bin directory on PATH even though
# the current Bash and its sibling cygpath.exe are present.
fake_git_bin="$test_home/fake-git/usr/bin"
empty_path="$test_home/empty-path"
mkdir -p "$fake_git_bin" "$empty_path"
touch "$fake_git_bin/bash"
cat >"$fake_git_bin/cygpath.exe" <<'EOF'
#!/bin/sh
printf 'C:\\Git\\usr\\bin\\bash\n'
EOF
chmod +x "$fake_git_bin/bash" "$fake_git_bin/cygpath.exe"
sibling_cygpath=$(PATH="$empty_path" find_cygpath "$fake_git_bin/bash")
[[ "$sibling_cygpath" == "$fake_git_bin/cygpath.exe" ]] ||
    fail 'cygpath beside the running Bash was not found when absent from PATH'

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
[[ $QUICK_LAUNCH_ALT == no ]] || fail 'Alt quick launch must default off'
if quick_launch_alt maybe 2>/dev/null; then fail 'invalid quick_launch_alt value was accepted'; fi
[[ $CONFIG_ERROR -eq 1 ]] || fail 'invalid quick_launch_alt did not flag a config error'
CONFIG_ERROR=0
if quick_launch_alt yes extra 2>/dev/null; then fail 'extra quick_launch_alt argument was accepted'; fi
CONFIG_ERROR=0
quick_launch_alt yes
[[ $QUICK_LAUNCH_ALT == yes ]] || fail 'quick_launch_alt yes was not applied'
for i in {13..21}; do custom_command "Local $i" "echo $i"; done
exec 3< <(printf '\0339')
read_key 1 || fail 'Alt+9 was not parsed'
[[ $KEY == ALT_9 ]] || fail 'Escape plus digit was not decoded as Alt+digit'
exec 3<&-
UI_MODE=menu
SHELL_SELECTION=4
MENU_SCROLL=3
MESSAGE='unchanged'
KEY=ALT_9
handle_ui_key || fail 'Alt+9 was not consumed'
[[ $selected == command:17 && $SHELL_SELECTION -eq 17 ]] || fail 'Alt+9 did not open entry 18'
KEY=ALT_1
handle_ui_key || fail 'Alt+1 was not consumed'
[[ $selected == command:9 ]] || fail 'Alt+1 did not open entry 10'
KEY='?'
handle_ui_key || fail 'menu help did not open'
[[ $UI_MODE == help && $HELP_RETURN_MODE == menu ]] || fail 'menu help context was lost'
KEY=ENTER
handle_ui_key || fail 'help did not absorb a launch key'
[[ $UI_MODE == help && $selected == command:9 ]] || fail 'help launched an entry'
for dismiss in '?' ESC Q; do
    KEY=$dismiss
    handle_ui_key || fail 'help dismissal was ignored'
    [[ $UI_MODE == menu && $SHELL_SELECTION -eq 9 && $MENU_SCROLL -eq 3 && $MESSAGE == unchanged ]] ||
        fail 'help did not restore the exact menu state'
    KEY='?'
    handle_ui_key || fail 'help could not reopen'
done
KEY=ESC
handle_ui_key || fail 'help could not close'
for context in dashboard aliases hosts; do
    UI_MODE=$context
    KEY='?'
    handle_ui_key || fail "$context help did not open"
    [[ $UI_MODE == help && $HELP_RETURN_MODE == "$context" ]] || fail "$context help is not contextual"
    KEY=q
    handle_ui_key || fail "$context help did not close"
    [[ $UI_MODE == "$context" ]] || fail "$context help returned to a different screen"
done
quick_launch_alt no
UI_MODE=dashboard
SHELL_SELECTION=2
selected=unchanged
KEY=ALT_1
if handle_ui_key; then fail 'disabled Alt shortcut was consumed'; fi
[[ $selected == unchanged && $SHELL_SELECTION -eq 2 ]] || fail 'disabled Alt launched an entry'
quick_launch_alt yes
handle_ui_key || fail 'dashboard Alt+1 was not consumed'
[[ $selected == command:9 && $SHELL_SELECTION -eq 2 ]] ||
    fail 'dashboard Alt+1 did not open entry 10 or changed its top-nine selection'
selected=unchanged
for dashboard_nav_key in UP DOWN LEFT RIGHT ENTER; do
    KEY=$dashboard_nav_key
    handle_dashboard_key
done
[[ $selected == unchanged && $SHELL_SELECTION -eq 2 ]] ||
    fail 'dashboard navigation moved or opened the invisible selection cursor'
KEY=3
handle_dashboard_key
[[ $selected == ssh:1 && $SHELL_SELECTION -eq 2 ]] ||
    fail 'dashboard 1–9 shortcut did not open instantly without moving menu selection'
UI_MODE=aliases
selected=unchanged
handle_ui_key && fail 'Alt+1 should not launch from aliases'
[[ $selected == unchanged ]] || fail 'Alt+1 launched from aliases'

# A failed tunnel can set the skip-all flag; subsequent healthy startup
# processes stay running while subsequent failed ones are marked skipped.
retry_log_dir="$test_home/retry-logs"
mkdir -p "$retry_log_dir"
LOG_DIR=$retry_log_dir
STARTUP_WAIT=0
EXIT_REQUESTED=0
SKIP_ALL_STARTUP_RETRIES=0
sleep() { :; }
render_dashboard() { :; }
render_header() { :; }
restore_tty_mode() { :; }
set_tty_mode() { :; }
classify_host_key_failure() { printf 'none'; }
kill() { return 1; }
wait() { :; }
PIDS=(701)
declare -A STATUS PID_TO_TUNNEL
STATUS[retry]=STARTING
LABEL[retry]='retry'
PID_TO_TUNNEL[701]=retry
exec 3< <(printf 's\n')
start_with_retry retry 701 >/dev/null
exec 3<&-
[[ $SKIP_ALL_STARTUP_RETRIES -eq 1 && ${STATUS[retry]} == SKIPPED &&
   ${#PIDS[@]} -eq 0 && -z ${PID_TO_TUNNEL[701]:-} ]] ||
    fail 'skip-all retry choice did not skip and reap the failed tunnel'

SKIP_ALL_STARTUP_RETRIES=1
PIDS=(801 802)
STATUS[healthy]=STARTING
STATUS[failed]=STARTING
PID_TO_TUNNEL[801]=healthy
PID_TO_TUNNEL[802]=failed
kill() { [[ ${1:-} == -0 && ${2:-} == 801 ]]; }
start_or_skip_startup_tunnel healthy 801
start_or_skip_startup_tunnel failed 802
[[ ${STATUS[healthy]} == RUNNING && ${STATUS[failed]} == SKIPPED &&
   -z ${PID_TO_TUNNEL[802]:-} ]] ||
    fail 'skip-all incorrectly stopped a healthy tunnel or left a failed tunnel uncollected'
parse_cli_args --run-command-base64 ZWNobyBoZWxsbw==
[[ $COMMAND_MODE -eq 1 && $COMMAND_B64 == ZWNobyBoZWxsbw== ]] || fail 'command transport not parsed'
if parse_cli_args --run-command-base64 ZWNobyBoZWxsbw== --ssh-config x 2>/dev/null; then
    fail 'local command accepted SSH config options'
fi
if parse_cli_args --connect-base64 ZWNobyBoZWxsbw== --run-command-base64 ZWNobyBoZWxsbw== 2>/dev/null; then
    fail 'SSH connect mode and local command mode were both accepted'
fi
encoded_custom=$(printf '%s' "$custom" | base64 | tr -d '\r\n')
encoded_bash_title=$(printf '%s' '✦ Bash' | base64 | tr -d '\r\n')
parse_cli_args --local-shell --ssh-config-b64 "$encoded_custom"
[[ $LOCAL_SHELL_MODE -eq 1 && $SSH_CONFIG_EXPLICIT -eq 1 &&
   "$SSH_CONFIG_FILE" == "$custom" ]] || fail 'local shell did not accept its selected SSH config'
if parse_cli_args --local-shell "$root/tunnels.conf" 2>/dev/null; then
    fail 'internal local-shell mode accepted a TunnelWizard config path'
fi
if parse_cli_args --local-shell -- "$root/tunnels.conf" 2>/dev/null; then
    fail 'internal local-shell mode accepted a TunnelWizard config after --'
fi
if parse_cli_args --local-shell --connect-base64 ZWNobyBoZWxsbw== 2>/dev/null; then
    fail 'internal local-shell mode combined with SSH connection mode'
fi

mkdir -p "$test_home/bin"
cat >"$test_home/bin/wezterm" <<'EOF'
#!/bin/bash
if [[ $1 == cli && $2 == spawn ]]; then
    printf '%s\0' "$@" >"$WEZTERM_SPAWN_LOG"
    printf 'pane-mock\n'
elif [[ $1 == cli && $2 == set-tab-title ]]; then
    printf '%s\0' "$@" >>"$WEZTERM_TITLE_LOG"
fi
EOF
chmod +x "$test_home/bin/wezterm"
wezterm_spawn_log="$test_home/wezterm-spawn"
wezterm_title_log="$test_home/wezterm-title"
SCRIPT_PATH="$root/TW.sh"
SSH_CONFIG_FILE=$custom
SSH_CONFIG_EXPLICIT=1
HOME=$test_home
expected_bash=$BASH
if command -v cygpath >/dev/null 2>&1; then
    expected_bash=$(cygpath -w "$expected_bash")
fi
export PATH="$test_home/bin:$PATH" WEZTERM_PANE=mock \
    WEZTERM_SPAWN_LOG="$wezterm_spawn_log" WEZTERM_TITLE_LOG="$wezterm_title_log"
open_local_shell_window || fail 'N did not launch a local shell in WezTerm'
unset WEZTERM_PANE
wezterm_spawn_args=()
while IFS= read -r -d '' arg; do wezterm_spawn_args+=("$arg"); done <"$wezterm_spawn_log"
expected_local_shell_command="printf '\\033]1337;SetUserVar=SSH_WIZARD_TITLE=%s\\007' '$encoded_bash_title'; exec \"\$BASH\" ./TW.sh --local-shell --ssh-config-b64 $encoded_custom"
[[ " ${wezterm_spawn_args[*]} " == *" --cwd $root "* &&
   " ${wezterm_spawn_args[*]} " == *" -- $expected_bash -i -c $expected_local_shell_command"* ]] ||
    fail 'WezTerm N launcher lost the project root, interactive shell, or selected SSH config'
[[ " ${wezterm_spawn_args[*]} " != *"--domain-name "* ]] ||
    fail 'WezTerm N launcher requested a domain on a non-Windows shell'
wezterm_titles=()
while IFS= read -r -d '' arg; do wezterm_titles+=("$arg"); done <"$wezterm_title_log"
[[ " ${wezterm_titles[*]} " == *'set-tab-title --pane-id pane-mock ✦ Bash'* &&
   " ${wezterm_spawn_args[*]} " == *"SetUserVar=SSH_WIZARD_TITLE=%s"* &&
   " ${wezterm_spawn_args[*]} " == *"'$encoded_bash_title'"* ]] ||
    fail 'WezTerm N launcher did not set the local shell window title to ✦ Bash'

# Simulate Git Bash on Linux for the WezTerm N path; the in-process cygpath
# maps the real bash executable to the mock Windows launcher and rewrites the
# project root into fake Windows drive form.
fake_root_win="C:${root//\//\\}"
fake_bash_win="C:${expected_bash//\//\\}"
wsl_bash_log="$test_home/wsl-bash-args"
mkdir -p "$test_home/windows-bin"
cat >"$test_home/windows-bin/bash" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$WSL_BASH_ARGS_LOG"
exit 127
EOF
chmod +x "$test_home/windows-bin/bash"
cat >"$test_home/bin/cygpath" <<'EOF'
#!/bin/sh
[ "$1" = -w ] || exit 1
if [ "$2" = "$BASH_PATH" ]; then printf '%s\n' "$FAKE_BASH_EXE"; else printf '%s\n' "$FAKE_ROOT_WIN"; fi
EOF
chmod +x "$test_home/bin/cygpath"
uname() { printf 'MINGW64_NT-10.0\n'; }
export -f uname
export WEZTERM_PANE=mock
: >"$wezterm_spawn_log"
BASH_PATH="$expected_bash" FAKE_BASH_EXE="$fake_bash_win" FAKE_ROOT_WIN="$fake_root_win" \
WSL_BASH_ARGS_LOG="$wsl_bash_log" PATH="$test_home/windows-bin:$test_home/bin:$PATH" \
    open_local_shell_window || fail 'N did not launch a local shell in WezTerm on Git Bash'
unset -f uname
unset WEZTERM_PANE
[[ ! -e "$wsl_bash_log" ]] || fail 'N used the WSL bash shim instead of the running Git Bash'
wezterm_spawn_args=()
while IFS= read -r -d '' arg; do wezterm_spawn_args+=("$arg"); done <"$wezterm_spawn_log"
[[ " ${wezterm_spawn_args[*]} " == *" --cwd $fake_root_win "* &&
   " ${wezterm_spawn_args[*]} " == *" -- $fake_bash_win -i "* &&
   " ${wezterm_spawn_args[*]} " == *" --domain-name local "* ]] ||
    fail 'WezTerm N launcher did not use the Windows-form bash, cwd, and local domain on Git Bash'
[[ " ${wezterm_spawn_args[*]} " != *" $root "* &&
   " ${wezterm_spawn_args[*]} " != *" $expected_bash "* ]] ||
    fail 'WezTerm N launcher passed unconverted POSIX paths on Git Bash'
[[ " ${wezterm_spawn_args[*]} " == *" -- $fake_bash_win -i -c $expected_local_shell_command"* ]] ||
    fail 'WezTerm N launcher lost the selected SSH config in its Git Bash startup command'

# A failing or missing cygpath must make N fall through without spawning a
# WezTerm pane with POSIX paths.
cat >"$test_home/bin/cygpath" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$test_home/bin/cygpath"
uname() { printf 'MINGW64_NT-10.0\n'; }
export -f uname
export WEZTERM_PANE=mock
: >"$wezterm_spawn_log"
if open_local_shell_window 2>/dev/null; then fail 'N did not fail closed when cygpath fails on Git Bash'; fi
unset -f uname
unset WEZTERM_PANE
[[ ! -s "$wezterm_spawn_log" || "$(tr -d '\0' <"$wezterm_spawn_log")" != *" $root "* &&
   "$(tr -d '\0' <"$wezterm_spawn_log")" != *" $expected_bash "* ]] ||
    fail 'WezTerm N launcher spawned with POSIX paths when cygpath fails'

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

mkdir -p "$test_home/bin"
cat >"$test_home/bin/ssh" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$SSH_ARGS_LOG"
EOF
chmod +x "$test_home/bin/ssh"
ssh_args_log="$test_home/ssh-args"
HOME="$test_home" PATH="$test_home/bin:$PATH" SSH_ARGS_LOG="$ssh_args_log" \
    bash "$root/TW.sh" --local-shell --ssh-config-b64 "$encoded_custom" \
    2>/dev/null <<< 'ssh test.example.invalid; exit' >/dev/null
[[ $(cat "$ssh_args_log") == $'-F\n'"$custom"$'\ntest.example.invalid' ]] ||
    fail 'interactive local-shell ssh function did not pass the selected -F config'

# The N window can inherit a Windows PATH that omits Git Bash's utility
# directory. TW.sh must restore the running Bash's own bin directory before
# the first dirname/base64/uname lookup.
minimal_path_output="$test_home/minimal-path-output"
HOME="$test_home" PATH="$empty_path" \
    "$BASH" "$root/TW.sh" --local-shell --ssh-config-b64 "$encoded_custom" \
    >"$minimal_path_output" 2>&1 <<< 'exit' ||
    fail 'local shell failed when PATH omitted Git Bash utility commands'
if grep -Eq 'command not found|Invalid encoded SSH config path' "$minimal_path_output"; then
    fail 'local shell did not restore its Bash utility directory before startup'
fi

# Simulate Git Bash on Linux with a WSL-style `bash` shim first on PATH. The
# local shell must reuse its running Bash instead of invoking that shim.
real_bash=$(command -v bash)
mkdir -p "$test_home/windows-bin"
cat >"$test_home/windows-bin/bash" <<'EOF'
#!/bin/sh
printf '%s\n' "$@" >"$WSL_BASH_ARGS_LOG"
exit 127
EOF
chmod +x "$test_home/windows-bin/bash"
cat >"$test_home/windows-bin/uname" <<'EOF'
#!/bin/sh
printf 'MINGW64_NT-10.0\n'
EOF
chmod +x "$test_home/windows-bin/uname"
: >"$test_home/.bashrc"
WSL_BASH_ARGS_LOG="$test_home/wsl-bash-args" \
HOME="$test_home" PATH="$test_home/windows-bin:$test_home/bin:$PATH" SSH_ARGS_LOG="$ssh_args_log" \
    "$real_bash" "$root/TW.sh" --local-shell --ssh-config-b64 "$encoded_custom" \
    2>"$test_home/windows-shell-warning" <<< 'ssh windows.example.invalid; exit' >/dev/null ||
    fail 'Windows local shell failed to reuse the running Bash'
[[ ! -e "$test_home/wsl-bash-args" ]] ||
    fail 'Windows local shell invoked the PATH-resolved WSL bash shim'
shell_banner=$(cat "$test_home/windows-shell-warning")
[[ $shell_banner == *'✓ Using current Bash'* &&
   $shell_banner == *"SSH Config: …/${test_home##*/}/custom ssh_config"* &&
   $shell_banner == *'Bash rc: ~/.bashrc'* &&
   $shell_banner == *'Have a magical time ✧⋆｡˚'* &&
   $shell_banner == *'__/_______\__'* &&
   $shell_banner == *'*'* &&
   $shell_banner != *'TW config'* ]] ||
    fail 'Windows local shell did not show its status, selected SSH config, and wizard hat'
[[ $(cat "$ssh_args_log") == $'-F\n'"$custom"$'\nwindows.example.invalid' ]] ||
    fail 'Windows-path local shell lost the selected -F SSH config'

# Simulate Git Bash on Windows without a separate WSL `bash` on PATH. The
# five-line local-shell banner should not depend on finding another Bash.
mkdir -p "$test_home/windows-no-wsl-bin"
cat >"$test_home/windows-no-wsl-bin/uname" <<'EOF'
#!/bin/sh
printf 'MINGW64_NT-10.0\n'
EOF
chmod +x "$test_home/windows-no-wsl-bin/uname"
HOME="$test_home" PATH="$test_home/windows-no-wsl-bin:$test_home/bin:$PATH" \
    SSH_ARGS_LOG="$ssh_args_log" \
    "$real_bash" "$root/TW.sh" --local-shell --ssh-config-b64 "$encoded_custom" \
    2>"$test_home/windows-no-wsl-shell-banner" <<< 'exit' >/dev/null ||
    fail 'Windows local shell without a WSL bash failed to start'
no_wsl_shell_banner=$(cat "$test_home/windows-no-wsl-shell-banner")
[[ $no_wsl_shell_banner == *'✓ Using current Bash'* &&
   $no_wsl_shell_banner == *'__/_______\__'* &&
   $no_wsl_shell_banner == *'Have a magical time ✧⋆｡˚'* ]] ||
    fail 'Windows local shell without a separate WSL bash omitted its startup banner'

literal_command="printf '%s' 'literal; value'"
encoded_command=$(printf '%s' "$literal_command" | base64 | tr -d '\r\n')
actual=$(HOME="$test_home" bash "$root/TW.sh" --run-command-base64 \
    "$encoded_command" 2>/dev/null <<< '')
[[ "$actual" == *'literal; value'* && "$actual" == *'Command ended (exit status 0)'* ]] ||
    fail 'base64 local command mode did not run the exact command'
printf 'Quick-launch model and dispatch tests passed.\n'
