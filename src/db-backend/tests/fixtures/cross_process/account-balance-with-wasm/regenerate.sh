#!/usr/bin/env bash
# Cross-process origin demo — recording pipeline.
#
# Produces three real recordings from one run of the demo application:
#
#   backend.ct        Node.js server, recorded by `codetracer-js-recorder record`
#   frontend.ct       browser JavaScript, recorded via the Vite plugin + record-web
#   frontend-wasm.ct  the WebAssembly module, recorded via ct-instrument + record-web
#
# plus the `session.toml` that binds them into one debugger session.
#
# Nothing here fabricates trace content. Every `.ct` is written by a
# recorder from an actual execution; if a prerequisite is missing the
# script fails loudly rather than emitting a placeholder, because a
# plausible-looking fake recording is far worse than an absent one — it
# makes the tests that consume it report success without ever exercising
# the pipeline.
#
# Exit codes:
#   0   all three recordings written
#   75  (EX_TEMPFAIL) a prerequisite is missing; nothing was written
#   1   a stage ran and failed
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../../.." && pwd -P)"
WORKSPACE_ROOT="$(cd "$CODETRACER_ROOT/.." && pwd -P)"
cd "$FIXTURE_DIR"

JS_RECORDER="${CODETRACER_JS_RECORDER_PATH:-$WORKSPACE_ROOT/codetracer-js-recorder}"
WASM_INSTRUMENTER="${CODETRACER_WASM_INSTRUMENTER_PATH:-$WORKSPACE_ROOT/codetracer-wasm-instrumenter}"
export CODETRACER_JS_RECORDER_PATH="$JS_RECORDER"
export CODETRACER_WASM_INSTRUMENTER_PATH="$WASM_INSTRUMENTER"

BACKEND_PORT="${DEMO_BACKEND_PORT:-8080}"
PREVIEW_PORT="${DEMO_PREVIEW_PORT:-4173}"
RECORD_WEB_PORT="${DEMO_RECORD_WEB_PORT:-9230}"

echo "[regenerate] cross-process origin demo"
echo "[regenerate] fixture:    $FIXTURE_DIR"
echo "[regenerate] js-recorder: $JS_RECORDER"
echo "[regenerate] instrumenter: $WASM_INSTRUMENTER"
echo

# ---------------------------------------------------------------------------
# Prerequisites. Collected in full before bailing so one run tells the
# operator everything that is missing.
# ---------------------------------------------------------------------------
missing=()

require_bin() {
	command -v "$1" >/dev/null 2>&1 || missing+=("- $1 not on PATH ($2)")
}

require_bin cargo "the Rust toolchain builds the WASM tier"
require_bin node "runs the backend tier and the Vite build"
require_bin npx "ships with Node.js"

if ! rustc --print target-list 2>/dev/null | grep -qx 'wasm32-unknown-unknown'; then
	missing+=("- rustc cannot target wasm32-unknown-unknown (rustup target add wasm32-unknown-unknown)")
fi

JS_RECORDER_CLI="$JS_RECORDER/packages/cli/dist/index.js"
if [ ! -f "$JS_RECORDER_CLI" ]; then
	missing+=("- codetracer-js-recorder is not built ($JS_RECORDER_CLI; run 'just build' in that repo)")
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

if ! node -e 'require.resolve("playwright")' >/dev/null 2>&1 &&
	! (cd "$FIXTURE_DIR/frontend" && node -e 'require.resolve("playwright")') >/dev/null 2>&1; then
	missing+=("- playwright not installed (npm install in $FIXTURE_DIR/frontend)")
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

# ---------------------------------------------------------------------------
# Clean slate. Partial recordings from an interrupted run would be worse
# than none, since the tests gate on the directories existing.
# ---------------------------------------------------------------------------
rm -rf "$FIXTURE_DIR/frontend.ct" "$FIXTURE_DIR/frontend-wasm.ct" \
	"$FIXTURE_DIR/backend.ct" "$FIXTURE_DIR/session.toml" \
	"$FIXTURE_DIR/frontend/balance_calc.wasm" \
	"$FIXTURE_DIR/frontend/balance_calc.wasm.manifest.json"

cleanup_pids=()
cleanup() {
	for pid in "${cleanup_pids[@]:-}"; do
		[ -n "$pid" ] || continue
		# Kill the whole process group, not just the direct child. The
		# JS recorder execs the program under a generated runner in a
		# child process, so signalling only the pid we spawned leaves
		# the recorded server holding its port — which then makes the
		# *next* run fail to bind, for reasons that look unrelated.
		kill -- "-$pid" >/dev/null 2>&1 || kill "$pid" >/dev/null 2>&1 || true
	done
}
trap cleanup EXIT

# A leftover process from an interrupted run would make the backend fail
# to bind and silently record nothing useful, so refuse to start rather
# than produce a confusing trace.
if (exec 3<>"/dev/tcp/127.0.0.1/$BACKEND_PORT") 2>/dev/null; then
	exec 3<&- 3>&-
	echo "[regenerate] 127.0.0.1:$BACKEND_PORT is already in use." >&2
	echo "[regenerate] Stop the process holding it (or set DEMO_BACKEND_PORT) and re-run." >&2
	exit 1
fi

# Wait for a TCP listener without opening a connection the server will
# see as a broken client. `record-web` speaks WebSocket, and a bare
# connect-then-close shows up in its log as a failed handshake.
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

# ---------------------------------------------------------------------------
# 1/5 — build the WebAssembly tier and instrument it.
# ---------------------------------------------------------------------------
echo "[regenerate] 1/5 building wasm-src -> wasm32-unknown-unknown"
(
	cd "$FIXTURE_DIR/wasm-src"
	# Dev profile: keeps the DWARF line programs `ct-instrument` reads
	# to give recorded frames real source locations. See wasm-src/Cargo.toml.
	cargo build --target wasm32-unknown-unknown
)
RAW_WASM="$FIXTURE_DIR/wasm-src/target/wasm32-unknown-unknown/debug/balance_calc.wasm"
[ -f "$RAW_WASM" ] || {
	echo "[regenerate] cargo did not produce $RAW_WASM" >&2
	exit 1
}

echo "[regenerate]     instrumenting with ct-instrument"
"$CT_INSTRUMENT_BIN" "$RAW_WASM" \
	--output "$FIXTURE_DIR/frontend/balance_calc.wasm" \
	--manifest "$FIXTURE_DIR/frontend/balance_calc.wasm.manifest.json" \
	--source-path "wasm-src/lib.rs"

# ---------------------------------------------------------------------------
# 2/5 — build the browser bundle through the CodeTracer Vite plugin.
# ---------------------------------------------------------------------------
echo "[regenerate] 2/5 building the browser bundle (vite + @codetracer/vite-plugin)"
(
	cd "$FIXTURE_DIR/frontend"
	[ -d node_modules ] || npm install --no-audit --no-fund
	# Both ports are build-time inputs, not run-time ones: the backend
	# origin goes into the preview proxy and the daemon port is baked
	# into the recorder endpoint (see vite.config.js). Passing only one
	# of them would move the daemon while leaving the page dialling the
	# default, which records nothing without failing.
	DEMO_BACKEND_PORT="$BACKEND_PORT" DEMO_RECORD_WEB_PORT="$RECORD_WEB_PORT" npx vite build
)

# ---------------------------------------------------------------------------
# 3/5 — start the recording daemon and the recorded backend.
# ---------------------------------------------------------------------------
echo "[regenerate] 3/5 starting record-web daemon on :$RECORD_WEB_PORT"
RECORD_WEB_OUT="$(mktemp -d)"
setsid "$RECORD_WEB_BIN" record-web \
	--bind "127.0.0.1:$RECORD_WEB_PORT" \
	--out-dir "$RECORD_WEB_OUT" \
	--workdir "$FIXTURE_DIR" &
RECORD_WEB_PID=$!
cleanup_pids+=("$RECORD_WEB_PID")

wait_for_port "$RECORD_WEB_PORT" "record-web" || exit 1

echo "[regenerate]     starting the Node backend under codetracer-js-recorder"
# The recorder writes `<out-dir>/trace-<handle>/`, so record into a
# scratch directory and rename the single result afterwards; that keeps
# `backend.ct` a stable path for `session.toml` and the tests.
BACKEND_OUT="$(mktemp -d)"
setsid env DEMO_BACKEND_PORT="$BACKEND_PORT" node "$JS_RECORDER_CLI" record \
	--out-dir "$BACKEND_OUT" \
	"$FIXTURE_DIR/backend/server.js" &
BACKEND_PID=$!
cleanup_pids+=("$BACKEND_PID")

wait_for_port "$BACKEND_PORT" "the backend" || exit 1

# ---------------------------------------------------------------------------
# 4/5 — drive the page once in a headless browser.
# ---------------------------------------------------------------------------
echo "[regenerate] 4/5 driving the page in headless Chromium"
(
	cd "$FIXTURE_DIR/frontend"
	DEMO_PREVIEW_PORT="$PREVIEW_PORT" DEMO_BACKEND_PORT="$BACKEND_PORT" node ./drive.mjs
)

# The backend closes its listener after one request; wait for the
# recorder to finalise the trace on exit.
wait "$BACKEND_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5/5 — collect the browser recordings and stamp the session manifest.
# ---------------------------------------------------------------------------
echo "[regenerate] 5/5 finalising recordings"
kill -INT "$RECORD_WEB_PID" >/dev/null 2>&1 || true
wait "$RECORD_WEB_PID" 2>/dev/null || true

for name in frontend frontend-wasm; do
	if [ ! -d "$RECORD_WEB_OUT/$name.ct" ]; then
		echo "[regenerate] record-web did not produce $name.ct" >&2
		echo "[regenerate] contents of $RECORD_WEB_OUT:" >&2
		ls -la "$RECORD_WEB_OUT" >&2 || true
		exit 1
	fi
	cp -R "$RECORD_WEB_OUT/$name.ct" "$FIXTURE_DIR/$name.ct"
done
rm -rf "$RECORD_WEB_OUT"

backend_trace="$(find "$BACKEND_OUT" -mindepth 1 -maxdepth 1 -type d -name 'trace-*' | head -1)"
if [ -z "$backend_trace" ]; then
	echo "[regenerate] the backend recorder did not produce a trace under $BACKEND_OUT" >&2
	ls -la "$BACKEND_OUT" >&2 || true
	exit 1
fi
cp -R "$backend_trace" "$FIXTURE_DIR/backend.ct"
rm -rf "$BACKEND_OUT"

# Recording ids are stable per fixture so the committed ANSWERS.md and the
# tests can name them; they identify *which* recording a span belongs to,
# not which run produced it.
sed \
	-e "s|{{frontend_js_recording_id}}|018f0000-0000-7000-8000-frontendjs01|" \
	-e "s|{{frontend_wasm_recording_id}}|018f0000-0000-7000-8000-frontendwsm1|" \
	-e "s|{{backend_recording_id}}|018f0000-0000-7000-8000-backendnode1|" \
	"$FIXTURE_DIR/session.toml.template" >"$FIXTURE_DIR/session.toml"

echo
echo "[regenerate] done:"
echo "    $FIXTURE_DIR/frontend.ct"
echo "    $FIXTURE_DIR/frontend-wasm.ct"
echo "    $FIXTURE_DIR/backend.ct"
echo "    $FIXTURE_DIR/session.toml"
