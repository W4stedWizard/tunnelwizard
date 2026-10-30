#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source <(awk '/^create_render_capture_file\(\) \{/ { capture=1 } capture { print; if ($0 == "}") exit }' "$root/tunnels.sh")
source <(awk '/^paint_row\(\) \{/ { capture=1 } capture { print; if ($0 == "}") exit }' "$root/tunnels.sh")

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

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

printf 'Render capture fallback tests passed.\n'
