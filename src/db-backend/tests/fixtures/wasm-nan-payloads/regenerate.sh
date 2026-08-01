#!/usr/bin/env bash
# NaN-payload demo (M52) — recording pipeline.
#
# Produces one real browser recording of a WebAssembly module that
# computes with the three float values a JavaScript host could not carry
# before M52 — an f32 signalling NaN, an f64 payload-carrying quiet NaN,
# and a negative zero:
#
#   nan-payloads.ct/       the browser recording
#   module/nan_payloads.wasm.zst
#                          the ORIGINAL, uninstrumented module — what the
#                          offline replay is driven against (spec §6.1)
#   page/nan_payloads.instrumented.wasm(+.manifest.json)
#                          what the browser loaded
#   expected-bits.json     the bit patterns the page asked for, written
#                          by the driver from the run itself
#
# Nothing here fabricates trace content.  If a prerequisite is missing
# the script fails loudly rather than emitting a placeholder: a
# plausible fake recording is far worse than an absent one, because it
# makes the checks that consume it report success without exercising
# anything.  Prerequisites are checked BEFORE anything is deleted.
#
# Exit codes:
#   0   the recording was written
#   75  (EX_TEMPFAIL) a prerequisite is missing; nothing was written
#   1   a stage ran and failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"
cd "$FIXTURE_DIR"

WASM_INSTRUMENTER="${CODETRACER_WASM_INSTRUMENTER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-instrumenter}"
export CODETRACER_WASM_INSTRUMENTER_PATH="$WASM_INSTRUMENTER"

# Where the recording lands. Nothing here is committed: the recording and
# the ORIGINAL module the offline replay is driven against (spec §6.1)
# are produced together, so they cannot describe different builds — and a
# change in `ct-instrument` or the browser recorder re-makes both instead
# of being replayed against a frozen pair that no longer represents the
# pipeline.
OUT_DIR="${CT_RECORDING_OUT_DIR:-$FIXTURE_DIR}"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"

PREVIEW_PORT="${DEMO_PREVIEW_PORT:-4182}"
RECORD_WEB_PORT="${DEMO_RECORD_WEB_PORT:-9233}"

echo "[regenerate] NaN-payload demo (M52)"
echo "[regenerate] fixture:      $FIXTURE_DIR"
echo "[regenerate] instrumenter: $WASM_INSTRUMENTER"
echo

missing=()

require_bin() {
	command -v "$1" >/dev/null 2>&1 || missing+=("- $1 not on PATH ($2)")
}

require_bin cargo "the Rust toolchain builds the WASM tier"
require_bin node "runs the static server and the headless driver"

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

# Drop an already-reaped pid, so the exit trap cannot later signal a
# *recycled* process group that happens to have been given the same number.
forget_pid() {
	local target="$1" pid
	local kept=()
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		[ "$pid" = "$target" ] || kept+=("$pid")
	done
	cleanup_pids=("${kept[@]:-}")
}

cleanup() {
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		kill -- "-$pid" >/dev/null 2>&1 || kill "$pid" >/dev/null 2>&1 || true
	done
	cleanup_pids=()
}

# Everything started below is `setsid`-detached, so it sits in its own
# session where no terminal SIGHUP and no `kill -- -<our pgid>` can reach
# it. This trap is therefore the only reaper in the system, and it is worth
# being explicit about when it runs.
#
# Naming INT/TERM/HUP is deliberate but is *not* what fixes the orphaned
# daemons, and it would be misleading to imply otherwise: bash already runs
# an `EXIT` trap when the shell dies on an untrapped SIGTERM, including
# while it is blocked in a foreground command. This was measured, not
# assumed. What the explicit traps buy is that the reaping no longer
# depends on that subtlety, and that a signalled run exits 128+signo
# instead of whatever the default disposition produces.
#
# The real gap is SIGKILL — a CI step timeout, `timeout(1)` escalation, an
# OOM kill — where no trap of any kind can run. That is why `record-web`
# also stands itself down after an idle period (`--idle-timeout`, default
# 10 minutes), which is the only defence that survives this script being
# killed outright.
on_signal() {
	trap - EXIT
	cleanup
	# Conventional 128+signo, so a caller can tell a signalled run from a
	# failed one.
	exit "$1"
}
trap cleanup EXIT
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

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
rm -rf "$OUT_DIR/nan-payloads.ct" \
	"$OUT_DIR/module/nan_payloads.wasm" \
	"$FIXTURE_DIR/page/nan_payloads.instrumented.wasm" \
	"$FIXTURE_DIR/page/nan_payloads.instrumented.wasm.manifest.json"

# ---------------------------------------------------------------------------
# 1/4 — build the module and instrument it.
# ---------------------------------------------------------------------------
echo "[regenerate] 1/4 building wasm-src -> wasm32-unknown-unknown"
(
	cd "$FIXTURE_DIR/wasm-src"
	cargo build --target wasm32-unknown-unknown
)
RAW_WASM="$FIXTURE_DIR/wasm-src/target/wasm32-unknown-unknown/debug/nan_payloads.wasm"
[ -f "$RAW_WASM" ] || {
	echo "[regenerate] cargo did not produce $RAW_WASM" >&2
	exit 1
}

# The ORIGINAL module is what the offline replay runs (spec §6.1) and it
# has to be *this* build, so it is copied out beside the recording it
# belongs to.  Uncompressed: the zstd step existed only to fit a
# *committed* file under the repo's 500 KB cap, and nothing here is
# committed.
mkdir -p "$OUT_DIR/module"
cp -f "$RAW_WASM" "$OUT_DIR/module/nan_payloads.wasm"

echo "[regenerate]     instrumenting with ct-instrument"
"$CT_INSTRUMENT_BIN" "$RAW_WASM" \
	--output "$FIXTURE_DIR/page/nan_payloads.instrumented.wasm" \
	--manifest "$FIXTURE_DIR/page/nan_payloads.instrumented.wasm.manifest.json" \
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
forget_pid "$RECORD_WEB_PID"

if [ ! -d "$RECORD_WEB_OUT/nan-payloads.ct" ]; then
	echo "[regenerate] record-web did not produce nan-payloads.ct" >&2
	ls -la "$RECORD_WEB_OUT" >&2 || true
	exit 1
fi
cp -R "$RECORD_WEB_OUT/nan-payloads.ct" "$OUT_DIR/nan-payloads.ct"

echo
echo "[regenerate] wrote $OUT_DIR/nan-payloads.ct"
echo "[regenerate] run ./verify.sh to replay it and check the bit patterns"
