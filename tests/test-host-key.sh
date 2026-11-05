#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source <(awk '$0 == "classify_host_key_failure() {" { copying=1 } copying { print; if ($0 == "}") exit }' "$root/tunnels.sh")
source <(awk '
    /^open_host_key_verification_window\(\) \{/ { copying=1 }
    copying && /^open_command_in_current_window\(\) \{/ { exit }
    copying { print }
' "$root/tunnels.sh")

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
skip_terminal_subtests=0
if [[ -z "${TUNNELWIZARD_TEST_NO_TTY:-}" ]] && { : </dev/tty; } 2>/dev/null; then
    if command -v setsid >/dev/null 2>&1; then
        exec setsid env TUNNELWIZARD_TEST_NO_TTY=1 "$BASH" "${BASH_SOURCE[0]}" "$@"
    else
        skip_terminal_subtests=1
    fi
fi
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

cat > "$tmp/unknown.log" <<'EOF'
The authenticity of host 'host.example.invalid' can't be established.
Host key verification failed.
EOF
[[ $(classify_host_key_failure "$tmp/unknown.log") == verify ]] ||
    fail 'first-use host key failure was not classified for interactive verification'

cat > "$tmp/changed.log" <<'EOF'
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
Host key verification failed.
EOF
[[ $(classify_host_key_failure "$tmp/changed.log") == changed ]] ||
    fail 'changed host key was not distinguished from a first-use key'

printf '%s\n' 'Permission denied (publickey).' > "$tmp/auth.log"
[[ $(classify_host_key_failure "$tmp/auth.log") == none ]] ||
    fail 'ordinary authentication failure was misclassified as a host-key issue'

if ((skip_terminal_subtests)); then
    printf 'Skipping terminal-launch subtests: no safe no-TTY runner is available.\n' >&2
else
mkdir "$tmp/bin"
cat > "$tmp/bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$SSH_CAPTURE"
EOF
chmod +x "$tmp/bin/ssh"
config="$tmp/custom ssh_config"
printf 'Host *\n' > "$config"
host='host.example.invalid'
user='tunnel-user'
identity="$tmp/private key"
label='Database tunnel'
encode() { printf '%s' "$1" | base64 | tr -d '\r\n'; }
encoded_config=$(encode "$config")
encoded_host=$(encode "$host")
encoded_user=$(encode "$user")
encoded_identity=$(encode "$identity")
encoded_label=$(encode "$label")
export SSH_CAPTURE="$tmp/ssh-args"
output="$tmp/verify-output"
PATH="$tmp/bin:$PATH" bash "$root/tunnels.sh" \
    --verify-host-key-base64 "$encoded_host" "$encoded_user" "$encoded_identity" "$encoded_label" \
    --ssh-config-b64 "$encoded_config" > "$output" 2>&1 <<< ''

printf '%s\n' -F "$config" -o BatchMode=no -i "$identity" -l "$user" "$host" > "$tmp/expected-args"
cmp -s "$tmp/expected-args" "$SSH_CAPTURE" ||
    fail 'interactive verification did not use the tunnel target, identity, user and SSH config'
grep -Fq $'\033[1;38;2;249;239;255;48;2;78;45;112m  TunnelWizard · HOST KEY VERIFICATION  \033[0m' "$output" ||
    fail 'verification window did not show the purple explanation'
grep -Fq 'Only accept it if you have verified it through a trusted source.' "$output" ||
    fail 'verification window omitted the fingerprint safety instruction'

# Exercise the WezTerm trampoline with a mock CLI and SSH executable. This
# guards argument forwarding without opening a real terminal or network session.
cat > "$tmp/bin/wezterm" <<'EOF'
#!/usr/bin/env bash
while (($#)); do
    if [[ "$1" == -- ]]; then
        shift
        "$@" > "$WEZTERM_OUTPUT" 2>&1
        printf '%s\n' "$?" > "$WEZTERM_STATUS"
        exit 0
    fi
    shift
done
exit 1
EOF
chmod +x "$tmp/bin/wezterm"
running_in_wezterm() { return 0; }
declare -A SSH_HOST=([test-id]='verify.example.invalid')
declare -A SSH_USER=([test-id]='verify-user')
declare -A IDENTITY=([test-id]="$tmp/verify key")
declare -A LABEL=([test-id]='Verify entry')
SSH_CONFIG_FILE="$tmp/no-default-ssh-config"
SSH_CONFIG_EXPLICIT=0
SSH_CAPTURE="$tmp/wezterm-ssh-args"
export SSH_CAPTURE
WEZTERM_OUTPUT="$tmp/wezterm-output"
export WEZTERM_OUTPUT
WEZTERM_STATUS="$tmp/wezterm-status"
export WEZTERM_STATUS
PATH="$tmp/bin:$PATH" open_host_key_verification_window test-id ||
    fail 'WezTerm verification launcher did not start its command'
if [[ ! -s "$SSH_CAPTURE" ]]; then
    cat "$WEZTERM_OUTPUT" >&2 || true
    fail "WezTerm child exited before calling SSH (status $(cat "$WEZTERM_STATUS" 2>/dev/null || printf unknown))"
fi
printf '%s\n' -o BatchMode=no -i "$tmp/verify key" -l verify-user verify.example.invalid > "$tmp/wezterm-expected"
cmp -s "$tmp/wezterm-expected" "$SSH_CAPTURE" ||
    fail 'WezTerm launcher did not pass the host, user and identity to interactive SSH'
grep -Fq $'\033[1;38;2;249;239;255;48;2;78;45;112m  TunnelWizard · HOST KEY VERIFICATION  \033[0m' "$WEZTERM_OUTPUT" ||
    fail 'WezTerm verification window did not use the purple header theme'
fi

printf 'Host-key verification tests passed.\n'
