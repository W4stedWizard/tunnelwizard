#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Load the configuration DSL without sourcing a config or opening the TUI.
# The cut stops immediately before tunnels.sh's config-loading block.
source <(awk '/^if \[\[ ! -r "\$CONFIG" \]\]; then/ { exit } { print }' "$root/tunnels.sh")

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
[[ "$HOSTS_MANAGEMENT" == no ]] || fail 'hosts UI must be disabled by default'
[[ $(local_host_ip pmx-one) == 127.105.144.115 ]] || fail 'address mapping changed unexpectedly'
[[ $(local_host_ip pmx-one) == "$(local_host_ip PMX-ONE)" ]] || fail 'unstable address'
[[ $(local_host_ip pmx-one) != "$(local_host_ip pmx-two)" ]] || fail 'sample hosts collide'

machine first first.invalid alice ~/.ssh/id_ed25519 no
tunnel 'first' 443:127.0.0.1:8006 pmx-one
ip_one=$(local_host_ip pmx-one)
[[ ${FORWARD[tunnel-0:0]} == "$ip_one:443:127.0.0.1:8006" ]] || fail 'missing bind rewrite'
[[ ${FORWARD_HOSTNAME[tunnel-0:0]} == pmx-one ]] || fail 'hostname not retained for display'
[[ ${FORWARD_NAME[tunnel-0:0]} == first ]] || fail 'forward name not retained for display'

machine second second.invalid alice ~/.ssh/id_ed25519 yes
tunnel 'second' 443:127.0.0.1:8006 PMX-TWO
ip_two=$(local_host_ip pmx-two)
[[ ${FORWARD[machine-2-group:0]} == "$ip_two:443:127.0.0.1:8006" ]] || fail 'group bind rewrite'
tunnel 'same hostname, second port' "$ip_two:8006:127.0.0.1:8006" pmx-two
[[ ${#LOCAL_HOSTNAMES[@]} == 2 ]] || fail 'duplicate hosts entry'

tunnel 'legacy' 8000:127.0.0.1:8006
[[ ${FORWARD[machine-2-group:2]} == 8000:127.0.0.1:8006 ]] || fail 'legacy syntax changed'

if tunnel 'bad bind' 0.0.0.0:443:127.0.0.1:8006 pmx-three 2>/dev/null; then
    fail 'non-loopback explicit bind accepted'
fi
tunnel 'explicit hostname bind' 127.0.0.66:443:127.0.0.1:8006 pmx-three
[[ ${HOSTNAME_IP[pmx-three]} == 127.0.0.66 ]] || fail 'explicit loopback bind not adopted'
[[ ${FORWARD[machine-2-group:3]} == 127.0.0.66:443:127.0.0.1:8006 ]] || fail 'explicit loopback bind changed'
if tunnel 'bad host' 443:127.0.0.1:8006 'bad..host' 2>/dev/null; then
    fail 'invalid hostname accepted'
fi
if tunnel 'numeric host' 443:127.0.0.1:8006 127.1.1.1 2>/dev/null; then
    fail 'IPv4 address accepted as hostname'
fi
IP_HOSTNAME["$(local_host_ip pmx-four)"]=another-name
if tunnel 'collision' 443:127.0.0.1:8006 pmx-four 2>/dev/null; then
    fail 'loopback collision accepted'
fi
printf 'Hostname DSL tests passed.\n'
