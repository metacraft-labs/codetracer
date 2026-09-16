#!/usr/bin/env bash
# browser-seekable-container.sh — M0 "Browser Replay Gate": prove that a
# NEW-FORMAT (split-stream, seekable) `.ct` container opens and navigates in the
# REAL wasm32 replay engine, and report what the JSON `postMessage` transport
# costs while we are in there.
#
# The host-side Rust suites (`browser_seekable_container_test`,
# `interning_tables_parity_test`, `wasm_seekable_sources_guard_test`) prove the
# reader. They cannot prove the BROWSER, because on the host
# `CTFSTraceReader::open` exists and the Nim FFI reader is linked in — neither
# is true in a tab. This script closes that gap by driving the actual
# `wasm32-unknown-unknown` artifact.
#
# There is no skip path. If the WASM artifact, the node host, the probe or the
# trace-writing example is missing, this FAILS and names what is missing. A
# suite that goes green because its subject is absent is worse than no suite.
#
# Build the WASM first if it is not present:
#   src/db-backend/build_wasm.sh
#
# Environment:
#   CT_M0_STEP_SIZES   space-separated user-step counts to probe
#                      (default "20 1000 9000"). The largest matters most: the
#                      gate is about a trace that does not fit in a tab, and a
#                      container small enough to fit passes a stepping test
#                      while leaving the materialisation holes in place.
#   CT_M0_BENCH        set to 0 to skip the transport benchmark (it is a
#                      measurement, not a gate, so it never fails the script).
#   CT_M0_BENCH_ITERS  iterations per benchmark case (default 60).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${REPO_ROOT}/ci/lib/nim-cache-root.sh"
cd "$REPO_ROOT" || exit 1

WASM_TESTING="src/db-backend/wasm-testing"
PKG="$WASM_TESTING/pkg"
NODE_HOST="$WASM_TESTING/node-host"
PROBE="$NODE_HOST/probe_seekable_container.mjs"
BENCH="$NODE_HOST/bench_transport.mjs"
WORKER="$WASM_TESTING/worker.js"
HOST="$NODE_HOST/worker_host.mjs"
INPROC="$NODE_HOST/inproc_host.mjs"
EXAMPLE="src/db-backend/examples/write_seekable_fixture.rs"
OUT="$(ct_nim_cache_root "${REPO_ROOT}")/m0-seekable"

STEP_SIZES="${CT_M0_STEP_SIZES:-20 1000 9000}"
BENCH_ITERS="${CT_M0_BENCH_ITERS:-60}"

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

echo "=== M0: a seekable split-stream container in the real wasm32 engine ==="

for required in \
	"$PKG/db_backend_bg.wasm" \
	"$PKG/db_backend.js" \
	"$WORKER" \
	"$HOST" \
	"$INPROC" \
	"$PROBE" \
	"$BENCH" \
	"$EXAMPLE"; do
	[ -f "$required" ] || fail "missing required input: $required
  (the WASM engine is built by src/db-backend/build_wasm.sh; its output
   lands in $PKG and is not checked in)"
done

wasm_bytes=$(wc -c <"$PKG/db_backend_bg.wasm" | tr -d ' ')
[ "$wasm_bytes" -gt 1000000 ] || fail "$PKG/db_backend_bg.wasm is only ${wasm_bytes} bytes — not a real engine build"
echo "  engine: $PKG/db_backend_bg.wasm (${wasm_bytes} bytes)"

command -v node >/dev/null 2>&1 || fail "node is not on PATH"
command -v cargo >/dev/null 2>&1 || fail "cargo is not on PATH (run inside the dev shell)"

mkdir -p "$OUT" || fail "cannot create $OUT"

# The containers are WRITTEN here rather than committed. A committed binary
# fixture nobody can regenerate is how a suite quietly stops testing the
# current format; this one comes out of the same Nim FFI write path every live
# recorder drives, so it tracks the writer automatically.
echo "  writing containers with the production Nim writer ..."
largest=""
largest_n=0
for n in $STEP_SIZES; do
	ct="$OUT/seekable_${n}.ct"
	if ! (cd src/db-backend && cargo run --quiet --example write_seekable_fixture -- "$ct" "$n"); then
		fail "could not write a ${n}-step container (cargo run --example write_seekable_fixture)"
	fi
	[ -s "$ct" ] || fail "the writer produced an empty container at $ct"
	if [ "$n" -ge "$largest_n" ]; then
		largest="$ct"
		largest_n="$n"
	fi
done

status=0
for n in $STEP_SIZES; do
	ct="$OUT/seekable_${n}.ct"
	echo
	echo "--- ${n} user steps ($(wc -c <"$ct" | tr -d ' ') bytes) ---"
	if ! node "$PROBE" "$ct"; then
		echo "FAIL: the ${n}-step container did not pass the browser probe" >&2
		status=1
	fi
done

[ "$status" -eq 0 ] || fail "one or more container sizes failed the browser probe"

# --- the transport measurement -------------------------------------------
#
# This is a MEASUREMENT, not a gate. M0's last deliverable asks for a number,
# not a threshold, and a benchmark that fails a build on timing noise teaches
# people to ignore it. It runs by default so the number stays current, and its
# exit status is deliberately not propagated.
if [ "${CT_M0_BENCH:-1}" != "0" ]; then
	echo
	echo "--- transport measurement (informational; does not gate) ---"
	if ! node "$BENCH" "$largest" "$BENCH_ITERS"; then
		echo "note: the transport benchmark did not complete; this does not fail the gate" >&2
	fi
fi

echo
echo "=== M0 browser seekable-container gate OK ==="
