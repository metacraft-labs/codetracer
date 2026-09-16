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
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${REPO_ROOT}/ci/lib/nim-cache-root.sh"
cd "$REPO_ROOT" || exit 1

WASM_TESTING="src/db-backend/wasm-testing"
HOST="$WASM_TESTING/node-host/worker_host.mjs"
WORKER="$WASM_TESTING/worker.js"
SRC="src/frontend/viewmodel/tests/e2e/worker_backend_wasm_e2e.nim"
TRACE="${CT_WORKER_E2E_TRACE:-src/db-backend/tests/fixtures/stylus-fund-trace/stylus_fund_tracking_demo.ct}"
OUT="$(ct_nim_cache_root "${REPO_ROOT}")/worker-backend-e2e"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

echo "=== WorkerBackendService <-> db-backend WASM e2e ==="

for required in "$WORKER" "$HOST" "$SRC" "$TRACE"; do
	[ -f "$required" ] || fail "missing required input: $required"
done

# The engine has to be the one THIS TREE builds, not merely one that exists.
#
# This check replaces "the file is there and is over a megabyte", which was not
# a check of anything. Measured on 2026-09-06 in a worktree at origin/dev
# (1006b5ab1) carrying the engine built on 2026-08-31 — 42 db-backend commits
# earlier, a binary 79,304 bytes different from this tree's — this suite
# reported "19 passed, 0 failed". Nineteen green assertions about a replay
# engine, none of them about the engine in the tree.
#
# `wasm_engine_assert_fresh` prints the reason and the exact rebuild command.
# shellcheck source=ci/lib/wasm-engine-freshness.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "$REPO_ROOT/ci/lib/wasm-engine-freshness.sh"
wasm_engine_assert_fresh "$REPO_ROOT" || fail "the WASM engine does not match this tree (see above)"
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
