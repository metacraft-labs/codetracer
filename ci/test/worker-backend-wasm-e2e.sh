#!/usr/bin/env bash
# worker-backend-wasm-e2e.sh — drive `WorkerBackendService` against the real
# db-backend WASM replay engine over a real `.ct` trace.
#
# There is no skip path. If the WASM artifact, the worker, the node host or
# the trace fixture is missing, this FAILS and names what is missing. A suite
# that goes green because its subject is absent is worse than no suite.
#
# Build the WASM first if it is not present:
#   src/db-backend/build_wasm.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

WASM_TESTING="src/db-backend/wasm-testing"
PKG="$WASM_TESTING/pkg"
HOST="$WASM_TESTING/node-host/worker_host.mjs"
WORKER="$WASM_TESTING/worker.js"
SRC="src/frontend/viewmodel/tests/e2e/worker_backend_wasm_e2e.nim"
TRACE="${CT_WORKER_E2E_TRACE:-src/db-backend/tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct}"
OUT="${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}/worker-backend-e2e"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

echo "=== WorkerBackendService <-> db-backend WASM e2e ==="

for required in "$PKG/db_backend_bg.wasm" "$PKG/db_backend.js" "$WORKER" "$HOST" "$SRC" "$TRACE"; do
	[ -f "$required" ] || fail "missing required input: $required
  (the WASM engine is built by src/db-backend/build_wasm.sh; its output
   lands in $PKG and is not checked in)"
done

wasm_bytes=$(wc -c <"$PKG/db_backend_bg.wasm" | tr -d ' ')
[ "$wasm_bytes" -gt 1000000 ] || fail "$PKG/db_backend_bg.wasm is only ${wasm_bytes} bytes — not a real engine build"
echo "  engine:  $PKG/db_backend_bg.wasm (${wasm_bytes} bytes)"
echo "  trace:   $TRACE"

command -v node >/dev/null 2>&1 || fail "node is not on PATH"
command -v nim >/dev/null 2>&1 || fail "nim is not on PATH (run inside the dev shell)"

mkdir -p "$OUT"
echo "  compiling $SRC ..."
if ! nim js -d:nodejs --hints:off --warnings:off \
	--path:src/frontend/viewmodel \
	--nimcache:"$OUT/nimcache" \
	-o:"$OUT/e2e.js" "$SRC"; then
	fail "could not compile $SRC"
fi

echo "  running ..."
node "$OUT/e2e.js" "$REPO_ROOT/$HOST" "$REPO_ROOT/$TRACE"
status=$?

if [ "$status" -ne 0 ]; then
	fail "worker/WASM e2e exited with status $status"
fi
echo "=== e2e OK ==="
