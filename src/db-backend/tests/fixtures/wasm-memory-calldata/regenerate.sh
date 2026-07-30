#!/usr/bin/env bash
# Host-supplied-state demo — recording pipeline.
#
# Produces one real browser recording of a WebAssembly module whose
# **linear memory is imported** and whose inputs are read out of that
# memory rather than taken as arguments:
#
#   ledger-settle.ct/      the browser recording, including the
#                          `boundary_state.json` sidecar carrying spec
#                          §3.3 initial state and §3.4 host mutations
#   module/ledger_settle.wasm
#                          the ORIGINAL, uninstrumented module — what the
#                          offline replay is driven against (spec §6.1)
#   page/ledger_settle.instrumented.wasm(+.manifest.json)
#                          what the browser loaded
#
# Nothing here fabricates trace content. If a prerequisite is missing the
# script fails loudly rather than emitting a placeholder: a plausible
# fake recording is far worse than an absent one, because it makes the
# checks that consume it report success without exercising anything.
#
# Prerequisites are checked BEFORE anything is deleted. (The sibling
# fixture `cross_process/account-balance-with-wasm/regenerate.sh` gets
# that order wrong and will `rm -rf` its committed recordings before
# discovering it cannot rebuild them.)
#
# Exit codes:
#   0   the recording was written and verified
#   75  (EX_TEMPFAIL) a prerequisite is missing; nothing was written
#   1   a stage ran and failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"
cd "$FIXTURE_DIR"

WASM_INSTRUMENTER="${CODETRACER_WASM_INSTRUMENTER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-instrumenter}"
export CODETRACER_WASM_INSTRUMENTER_PATH="$WASM_INSTRUMENTER"

PREVIEW_PORT="${DEMO_PREVIEW_PORT:-4180}"
RECORD_WEB_PORT="${DEMO_RECORD_WEB_PORT:-9231}"

echo "[regenerate] host-supplied-state demo"
echo "[regenerate] fixture:      $FIXTURE_DIR"
echo "[regenerate] instrumenter: $WASM_INSTRUMENTER"
echo

# ---------------------------------------------------------------------------
# Prerequisites, collected in full so one run tells the operator
# everything that is missing.
# ---------------------------------------------------------------------------
missing=()

require_bin() {
	command -v "$1" >/dev/null 2>&1 || missing+=("- $1 not on PATH ($2)")
}

require_bin cargo "the Rust toolchain builds the WASM tier"
require_bin node "runs the static server and the headless driver"
require_bin zstd "compresses the pinned module under the repo's file-size cap"

if ! rustc --print target-list 2>/dev/null | grep -qx 'wasm32-unknown-unknown'; then
	missing+=("- rustc cannot target wasm32-unknown-unknown")
fi

CT_INSTRUMENT_BIN="${CT_INSTRUMENT_BIN:-}"
if [ -z "$CT_INSTRUMENT_BIN" ]; then
	for candidate in \
		"$WASM_INSTRUMENTER/target/release/ct-instrument" \
		"$WASM_INSTRUMENTER/target/debug/ct-instrument"; do
		if [ -x "$candidate" ]; then
			CT_INSTRUMENT_BIN="$candidate"
			break
		fi
	done
fi
if [ -z "$CT_INSTRUMENT_BIN" ] && command -v ct-instrument >/dev/null 2>&1; then
	CT_INSTRUMENT_BIN="$(command -v ct-instrument)"
fi
if [ -z "$CT_INSTRUMENT_BIN" ]; then
	missing+=("- ct-instrument not found (cargo build --release -p ct-instrument-cli in $WASM_INSTRUMENTER)")
fi

RECORD_WEB_BIN="${CODETRACER_RECORD_WEB_BIN:-}"
if [ -z "$RECORD_WEB_BIN" ]; then
	for candidate in \
		"$CODETRACER_ROOT/src/backend-manager/target/release/session-manager" \
		"$CODETRACER_ROOT/src/backend-manager/target/debug/session-manager" \
		"$CODETRACER_ROOT/src/build-debug/bin/session-manager"; do
		if [ -x "$candidate" ]; then
			RECORD_WEB_BIN="$candidate"
			break
		fi
	done
fi
if [ -z "$RECORD_WEB_BIN" ]; then
	missing+=("- session-manager not built (cargo build in $CODETRACER_ROOT/src/backend-manager)")
fi

if [ ! -d "$WASM_INSTRUMENTER/recorder-runtime" ]; then
	missing+=("- the instrumenter's recorder-runtime/ is not present at $WASM_INSTRUMENTER")
fi

if ! node -e 'require("node:module").createRequire(process.argv[1]).resolve("playwright")' \
	"$CODETRACER_ROOT/package.json" >/dev/null 2>&1; then
	missing+=("- playwright is not installed in $CODETRACER_ROOT/node_modules")
fi

if [ ${#missing[@]} -gt 0 ]; then
	echo "[regenerate] missing prerequisites:"
	printf '    %s\n' "${missing[@]}"
	echo
	echo "[regenerate] nothing was written. Install the above and re-run."
	exit 75
fi

echo "[regenerate] using ct-instrument: $CT_INSTRUMENT_BIN"
echo "[regenerate] using record-web:    $RECORD_WEB_BIN"
echo

cleanup_pids=()
cleanup() {
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		kill -- "-$pid" >/dev/null 2>&1 || kill "$pid" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

wait_for_port() {
	local port="$1" label="$2"
	for _ in $(seq 1 100); do
		if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
			exec 3<&- 3>&-
			return 0
		fi
		sleep 0.2
	done
	echo "[regenerate] $label never bound 127.0.0.1:$port" >&2
	return 1
}

for port in "$PREVIEW_PORT" "$RECORD_WEB_PORT"; do
	if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
		exec 3<&- 3>&-
		echo "[regenerate] 127.0.0.1:$port is already in use." >&2
		exit 1
	fi
done

# Everything checked; only now is anything removed.
rm -rf "$FIXTURE_DIR/ledger-settle.ct" \
	"$FIXTURE_DIR/module/ledger_settle.wasm.zst" \
	"$FIXTURE_DIR/page/ledger_settle.instrumented.wasm" \
	"$FIXTURE_DIR/page/ledger_settle.instrumented.wasm.manifest.json"

# ---------------------------------------------------------------------------
# 1/4 — build the module with an IMPORTED memory, and instrument it.
# ---------------------------------------------------------------------------
echo "[regenerate] 1/4 building wasm-src -> wasm32-unknown-unknown"
(
	cd "$FIXTURE_DIR/wasm-src"
	# `--import-memory` is the whole point: it makes `env.memory` an
	# import, and therefore makes the module's starting state
	# host-supplied. The stack size only keeps the memory small.
	RUSTFLAGS="-C link-arg=--import-memory -C link-arg=-zstack-size=65536" \
		cargo build --target wasm32-unknown-unknown
)
RAW_WASM="$FIXTURE_DIR/wasm-src/target/wasm32-unknown-unknown/debug/ledger_settle.wasm"
[ -f "$RAW_WASM" ] || {
	echo "[regenerate] cargo did not produce $RAW_WASM" >&2
	exit 1
}

# The ORIGINAL module is what the offline replay runs (spec §6.1), and it
# has to be *this* build: `boundary_state.json` records absolute
# linear-memory offsets, so a module compiled by a different toolchain puts
# `LEDGER` at a different address and the recording no longer describes it
# (measured: a rebuild diverges at the first host call). So it is committed
# alongside the recording rather than left in `target/`.
#
# Compressed, because the repo caps a committed file at 500 KB and a
# debug-built `.wasm` is ~1.5 MB of DWARF — which is exactly the part the
# replay needs. zstd takes it to ~270 KB; `verify.sh` expands it into a
# temp directory.
mkdir -p "$FIXTURE_DIR/module"
rm -f "$FIXTURE_DIR/module/ledger_settle.wasm"
zstd -19 -q -f -o "$FIXTURE_DIR/module/ledger_settle.wasm.zst" "$RAW_WASM"

echo "[regenerate]     instrumenting with ct-instrument"
"$CT_INSTRUMENT_BIN" "$RAW_WASM" \
	--output "$FIXTURE_DIR/page/ledger_settle.instrumented.wasm" \
	--manifest "$FIXTURE_DIR/page/ledger_settle.instrumented.wasm.manifest.json" \
	--source-path "wasm-src/lib.rs"

# ---------------------------------------------------------------------------
# 2/4 — start the recording daemon and the static server.
# ---------------------------------------------------------------------------
echo "[regenerate] 2/4 starting record-web on :$RECORD_WEB_PORT"
RECORD_WEB_OUT="$(mktemp -d)"
setsid "$RECORD_WEB_BIN" record-web \
	--bind "127.0.0.1:$RECORD_WEB_PORT" \
	--out-dir "$RECORD_WEB_OUT" \
	--workdir "$FIXTURE_DIR" &
RECORD_WEB_PID=$!
cleanup_pids+=("$RECORD_WEB_PID")
wait_for_port "$RECORD_WEB_PORT" "record-web" || exit 1

setsid node "$FIXTURE_DIR/serve.mjs" "$PREVIEW_PORT" &
SERVE_PID=$!
cleanup_pids+=("$SERVE_PID")
wait_for_port "$PREVIEW_PORT" "the static server" || exit 1

# ---------------------------------------------------------------------------
# 3/4 — drive the page once in headless Chromium.
# ---------------------------------------------------------------------------
echo "[regenerate] 3/4 driving the page in headless Chromium"
node "$FIXTURE_DIR/drive.mjs" "$PREVIEW_PORT" "$RECORD_WEB_PORT"

# ---------------------------------------------------------------------------
# 4/4 — collect the recording.
# ---------------------------------------------------------------------------
echo "[regenerate] 4/4 finalising"
kill -INT "$RECORD_WEB_PID" >/dev/null 2>&1 || true
wait "$RECORD_WEB_PID" 2>/dev/null || true

if [ ! -d "$RECORD_WEB_OUT/ledger-settle.ct" ]; then
	echo "[regenerate] record-web did not produce ledger-settle.ct" >&2
	ls -la "$RECORD_WEB_OUT" >&2 || true
	exit 1
fi
cp -R "$RECORD_WEB_OUT/ledger-settle.ct" "$FIXTURE_DIR/ledger-settle.ct"
rm -rf "$RECORD_WEB_OUT"

if [ ! -f "$FIXTURE_DIR/ledger-settle.ct/boundary_state.json" ]; then
	echo "[regenerate] the recording carries no boundary_state.json." >&2
	echo "[regenerate] This fixture exists to demonstrate spec §3.3/§3.4;" >&2
	echo "[regenerate] a recording without the sidecar is not one." >&2
	exit 1
fi

echo
echo "[regenerate] done:"
echo "    $FIXTURE_DIR/ledger-settle.ct"
echo "    $FIXTURE_DIR/module/ledger_settle.wasm.zst"
echo
echo "[regenerate] now run ./verify.sh to replay it."
