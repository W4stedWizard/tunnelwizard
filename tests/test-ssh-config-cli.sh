#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source <(awk '/^if \[\[ ! -r "\$CONFIG" \]\]; then/ { exit } { print }' "$root/tunnels.sh")
SCRIPT_DIR=$root

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
custom="$tmp/custom ssh_config"
printf 'Host *\n    ServerAliveInterval 15\n' >"$custom"

parse_cli_args
[[ "$CONFIG" == "$root/tunnels.conf" ]] || fail 'default TunnelWizard config changed'
[[ "$SSH_CONFIG_FILE" == "$root/ssh_config" && $SSH_CONFIG_EXPLICIT -eq 0 ]] ||
    fail 'default SSH config selection changed'

parse_cli_args --ssh-config "$custom" "$root/tunnels.conf"
[[ "$CONFIG" == "$root/tunnels.conf" && "$SSH_CONFIG_FILE" == "$custom" &&
   $SSH_CONFIG_EXPLICIT -eq 1 ]] || fail 'SSH option before positional config failed'
validate_ssh_config || fail 'existing custom SSH config should validate'

parse_cli_args "$root/tunnels.conf" --ssh-config="$custom"
[[ "$CONFIG" == "$root/tunnels.conf" && "$SSH_CONFIG_FILE" == "$custom" ]] ||
    fail 'SSH option after positional config failed'

parse_cli_args -cssh "$custom" "$root/tunnels.conf"
[[ "$CONFIG" == "$root/tunnels.conf" && "$SSH_CONFIG_FILE" == "$custom" ]] ||
    fail 'short SSH config option failed'
parse_cli_args "$root/tunnels.conf" -cssh="$custom"
[[ "$CONFIG" == "$root/tunnels.conf" && "$SSH_CONFIG_FILE" == "$custom" ]] ||
    fail 'short SSH config equals form failed'

old_pwd=$PWD
cd "$tmp"
parse_cli_args --ssh-config 'custom ssh_config'
[[ "$SSH_CONFIG_FILE" == "$custom" ]] || fail 'relative SSH config path was not resolved from cwd'
cd "$old_pwd"

old_home=${HOME:-}
HOME=$tmp
parse_cli_args --ssh-config '~/custom ssh_config'
HOME=$old_home
[[ "$SSH_CONFIG_FILE" == "$custom" ]] || fail 'tilde SSH config path was not expanded'

encoded=$(printf '%s' "$custom" | base64 | tr -d '\r\n')
parse_cli_args --connect-base64 dGVzdA== --ssh-config-b64 "$encoded"
[[ $CONNECT_MODE -eq 1 && "$CONNECT_TARGET_B64" == dGVzdA== &&
   "$SSH_CONFIG_FILE" == "$custom" && $SSH_CONFIG_EXPLICIT -eq 1 ]] ||
    fail 'internal saved-shell mode did not preserve custom SSH config'
validate_ssh_config || fail 'transported custom SSH config should validate'

parse_cli_args --connect-base64 dGVzdA== --ssh-config-b64 -
[[ $CONNECT_MODE -eq 1 && "$SSH_CONFIG_FILE" == "$root/ssh_config" &&
   $SSH_CONFIG_EXPLICIT -eq 0 ]] || fail 'default saved-shell config transport failed'

if parse_cli_args --connect-base64 dGVzdA== --connect-base64 dGVzdA== 2>/dev/null; then
    fail 'duplicate internal connection targets were accepted'
fi
if parse_cli_args --connect-base64 dGVzdA== "$root/tunnels.conf" 2>/dev/null; then
    fail 'internal connection mode accepted a TunnelWizard config path'
fi
if parse_cli_args --ssh-config-b64 "$encoded" 2>/dev/null; then
    fail 'internal SSH config transport was accepted outside connection mode'
fi

parse_cli_args -- "$tmp/-tunnels.conf"
[[ "$CONFIG" == "$tmp/-tunnels.conf" ]] || fail 'option terminator did not allow a dash-leading config path'

parse_cli_args --ssh-config "$tmp/missing ssh_config"
if validate_ssh_config 2>/dev/null; then
    fail 'missing explicit SSH config was accepted'
fi

if parse_cli_args --ssh-config "$custom" --ssh-config "$custom" 2>/dev/null; then
    fail 'duplicate SSH config options were accepted'
fi

printf 'SSH config CLI tests passed.\n'
