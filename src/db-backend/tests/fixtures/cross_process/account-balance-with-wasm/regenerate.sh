#!/usr/bin/env bash
# Cross-Tracer Origin E2E — Fixture A' "Account Balance with WASM"
# regenerator (three-tracer per
# Cross-Tracer-Origin-Test.audit.md § TCT-M4).
#
# This script drives the full recorder pipeline:
#   1. wasm-pack builds `wasm-src/lib.rs` -> `frontend/pkg/`.
#   2. `vite build` produces the production-mode frontend bundle.
#   3. Starts the aiohttp backend under the codetracer Python recorder.
#   4. Starts `ct record-web`, the current browser stream receiver host.
#   5. Drives a single POST /balance request and emits the browser
#      receiver protocol through a headless browser (Playwright /
#      chrome-headless-shell).
#   6. Tears the three recorder processes down and writes
#      `frontend.ct`, `frontend-wasm.ct`, `backend.ct` next to this
#      script + a populated `session.toml` (UUIDv7s substituted into
#      the template).
#
# The script is GATED on the per-stage recorder + toolchain
# availability and exits 75 (EX_TEMPFAIL) when any prerequisite is
# absent. Callers that prepare CI fixtures must treat that as failure,
# not as a skipped test.
#
# Per M29's `:deferred_items:` block, the per-language recorder
# fixture infrastructure (Vite plugin + record.sh + per-language
# recorders + TestCache wrapper) lands incrementally. Until it
# lands fully, this regenerator can still parse + report which
# stages are blocked.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODETRACER_ROOT="$(cd "$FIXTURE_DIR/../../../../../.." && pwd -P)"
cd "$FIXTURE_DIR"

echo "[regenerate] M29 / TCT-M4 Fixture A' — Account Balance with WASM"
echo "[regenerate] fixture dir: $FIXTURE_DIR"
echo

# ---------------------------------------------------------------------------
# Prerequisite check. Each missing component prints a short diagnostic
# explaining why this regenerator cannot finish and what's needed to
# unblock it. We collect all gaps before bailing so the operator gets
# one full report.
# ---------------------------------------------------------------------------
missing=()
PYTHON_BIN=""
RECORD_WEB_BIN=""

require_bin() {
	local bin="$1"
	local hint="$2"
	if ! command -v "$bin" >/dev/null 2>&1; then
		missing+=("- $bin not on PATH ($hint)")
	fi
}

resolve_python() {
	if command -v python3 >/dev/null 2>&1; then
		command -v python3
		return 0
	fi
	if command -v python >/dev/null 2>&1; then
		command -v python
		return 0
	fi
	if [ -x "$CODETRACER_ROOT/.python-recorder-venv/bin/python" ]; then
		printf '%s\n' "$CODETRACER_ROOT/.python-recorder-venv/bin/python"
		return 0
	fi
	return 1
}

resolve_record_web() {
	if command -v ct >/dev/null 2>&1 && ct record-web --help >/dev/null 2>&1; then
		printf '%s\n' "$(command -v ct)"
		return 0
	fi
	if command -v session-manager >/dev/null 2>&1 &&
		session-manager record-web --help >/dev/null 2>&1; then
		printf '%s\n' "$(command -v session-manager)"
		return 0
	fi
	if [ -x "$CODETRACER_ROOT/src/build-debug/bin/session-manager" ] &&
		"$CODETRACER_ROOT/src/build-debug/bin/session-manager" record-web --help >/dev/null 2>&1; then
		printf '%s\n' "$CODETRACER_ROOT/src/build-debug/bin/session-manager"
		return 0
	fi
	return 1
}

require_bin cargo "rustup; install via 'curl https://sh.rustup.rs -sSf | sh'"
require_bin wasm-pack "install via 'cargo install wasm-pack' or 'nix run nixpkgs#wasm-pack'"
require_bin node "install via your platform's package manager"
require_bin npx "ships with Node.js"
if ! PYTHON_BIN="$(resolve_python)"; then
	missing+=("- python interpreter not found (python3, python, or codetracer/.python-recorder-venv/bin/python)")
fi

# `rustup target add wasm32-unknown-unknown` is required for the
# wasm-pack build to succeed. Detect by asking rustc for its target
# list — `rustup` is the canonical interface but we also accept a
# bare rustc that already has the target installed.
if command -v rustup >/dev/null 2>&1; then
	if ! rustup target list --installed 2>/dev/null | grep -q '^wasm32-unknown-unknown$'; then
		missing+=("- rustup target wasm32-unknown-unknown not installed (run 'rustup target add wasm32-unknown-unknown')")
	fi
elif command -v rustc >/dev/null 2>&1; then
	if ! rustc --print target-list 2>/dev/null | grep -q '^wasm32-unknown-unknown$'; then
		missing+=("- rustc does not list wasm32-unknown-unknown as an available target (install rustup or a rustc with the wasm32 target preinstalled)")
	fi
fi

# Recorder availability — the extension fixture prep puts the current
# CodeTracer CLI on PATH as `ct`.
require_bin ct "the codetracer CLI ('just build-once' from the repo root produces it at src/build-debug/bin/ct)"

# Python aiohttp recorder hooks (boundary auto-marker for
# X-Codetracer-Origin). Detect by checking that the codetracer
# Python recorder package is importable from the resolved interpreter.
if [ -n "$PYTHON_BIN" ]; then
	if ! "$PYTHON_BIN" -c 'import codetracer_python_recorder' >/dev/null 2>&1; then
		missing+=("- codetracer_python_recorder Python package not importable from $PYTHON_BIN (install via the codetracer dev shell or 'pip install codetracer-python-recorder')")
	fi
fi

if ! RECORD_WEB_BIN="$(resolve_record_web)"; then
	missing+=("- record-web host not available (expected ct record-web or $CODETRACER_ROOT/src/build-debug/bin/session-manager record-web)")
fi

require_bin curl "install via your platform's package manager"

if [ ${#missing[@]} -gt 0 ]; then
	echo "[regenerate] One or more prerequisites are missing:"
	for line in "${missing[@]}"; do
		echo "    $line"
	done
	echo
	echo "[regenerate] Honest-skip per the existing fixture convention."
	echo "[regenerate] The fixture sources (frontend/, backend/, wasm-src/,"
	echo "             ANSWERS.md, session.toml.template) remain parseable"
	echo "             by tests that exercise the synthetic-fixture path."
	echo "[regenerate] When all prereqs land, re-run this script to refresh"
	echo "             the three .ct files in place."
	exit 75 # EX_TEMPFAIL
fi

# ---------------------------------------------------------------------------
# Pipeline. Only reached when every prerequisite above is satisfied —
# until the recorder-driven fixture infrastructure (M29 :deferred_items:)
# lands fully, this branch is exercised only on developer workstations
# with the full dev shell active.
# ---------------------------------------------------------------------------

echo "[regenerate] Step 1/6: build WASM module with wasm-pack"
(
	cd "$FIXTURE_DIR/wasm-src"
	wasm-pack build --target web --release \
		--out-dir "$FIXTURE_DIR/frontend/pkg" \
		--out-name balance_calc
)

echo "[regenerate] Step 2/6: install frontend dev deps + vite build"
(
	cd "$FIXTURE_DIR/frontend"
	if [ ! -d node_modules ]; then
		npm install --no-audit --no-fund
	fi
	npx --no-install playwright --version >/dev/null
	npx vite build
)

rm -rf "$FIXTURE_DIR/frontend.ct" "$FIXTURE_DIR/frontend-wasm.ct" "$FIXTURE_DIR/backend.ct"

echo "[regenerate] Step 3/6: start stdlib HTTP backend under codetracer Python recorder"
CODETRACER_PYTHON_INTERPRETER="$PYTHON_BIN" ct record \
	--lang python \
	--output-folder "$FIXTURE_DIR/backend.ct" \
	"$FIXTURE_DIR/backend/server.py" &
BACKEND_PID=$!
trap 'kill $BACKEND_PID >/dev/null 2>&1 || true' EXIT
# Wait for the aiohttp listener to bind before driving any request.
backend_ready=0
for _ in $(seq 1 30); do
	if curl -sf -o /dev/null -X POST -H 'Content-Type: application/json' \
		--data '{"balance":0}' http://127.0.0.1:8080/balance; then
		backend_ready=1
		break
	fi
	sleep 0.2
done
if [ "$backend_ready" -ne 1 ]; then
	echo "[regenerate] Backend did not become ready on http://127.0.0.1:8080/balance" >&2
	exit 1
fi

echo "[regenerate] Step 4/6: start ct record-web browser receiver"
RECORD_WEB_OUT="$(mktemp -d)"
"$RECORD_WEB_BIN" record-web --out-dir "$RECORD_WEB_OUT" --workdir "$FIXTURE_DIR" &
RECORD_WEB_PID=$!
trap 'kill $RECORD_WEB_PID >/dev/null 2>&1 || true; kill $BACKEND_PID >/dev/null 2>&1 || true; rm -rf "$RECORD_WEB_OUT"' EXIT
record_web_ready=0
for _ in $(seq 1 30); do
	if bash -c '</dev/tcp/127.0.0.1/9230' >/dev/null 2>&1; then
		record_web_ready=1
		break
	fi
	sleep 0.2
done
if [ "$record_web_ready" -ne 1 ]; then
	echo "[regenerate] ct record-web did not become ready on 127.0.0.1:9230" >&2
	exit 1
fi

echo "[regenerate] Step 5/6: drive one POST /balance request via headless Chrome"
(
	cd "$FIXTURE_DIR/frontend"
	PW_CONFIG="$FIXTURE_DIR/frontend/.regenerate.playwright.config.mjs"
	trap 'rm -f "$PW_CONFIG"' EXIT
	cat >"$PW_CONFIG" <<'PWCONF'
import { defineConfig } from "@playwright/test";
const executablePath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH || undefined;
export default defineConfig({
  use: {
    baseURL: "http://127.0.0.1:4173",
    launchOptions: {
      executablePath,
      args: ["--no-sandbox", "--disable-dev-shm-usage"],
    },
  },
  webServer: {
    command: "npx --no-install vite preview --host 127.0.0.1 --port 4173",
    url: "http://127.0.0.1:4173",
    reuseExistingServer: true,
  },
  testDir: ".",
  testMatch: /smoke\.spec\.mjs$/,
});
PWCONF
	npx playwright test --config "$PW_CONFIG"
)

echo "[regenerate] Step 6/6: tear recorders down + stamp session.toml UUIDv7s"
kill -INT "$RECORD_WEB_PID" >/dev/null 2>&1 || true
wait "$RECORD_WEB_PID" 2>/dev/null || true
cp -R "$RECORD_WEB_OUT/frontend.ct" "$FIXTURE_DIR/frontend.ct"
cp -R "$RECORD_WEB_OUT/frontend-wasm.ct" "$FIXTURE_DIR/frontend-wasm.ct"

kill -INT "$BACKEND_PID" >/dev/null 2>&1 || true
wait "$BACKEND_PID" 2>/dev/null || true

# UUIDv7 generator — uses the codetracer CLI's standard helper so
# the stamped ids are consistent with how the live recorders stamp
# their own. Falls back to Python's uuid module if the CLI helper
# is absent.
gen_uuid7() {
	if ct uuid7 2>/dev/null; then
		return 0
	fi
	"$PYTHON_BIN" -c 'import uuid; print(uuid.uuid4())'
}

FE_JS_ID=$(gen_uuid7)
FE_WASM_ID=$(gen_uuid7)
BE_ID=$(gen_uuid7)

# Substitute the placeholders into the template and write the
# final session.toml next to the .ct files.
sed \
	-e "s|{{frontend_js_recording_id}}|$FE_JS_ID|" \
	-e "s|{{frontend_wasm_recording_id}}|$FE_WASM_ID|" \
	-e "s|{{backend_recording_id}}|$BE_ID|" \
	"$FIXTURE_DIR/session.toml.template" >"$FIXTURE_DIR/session.toml"

echo
echo "[regenerate] Done. Three traces refreshed:"
echo "    $FIXTURE_DIR/frontend.ct"
echo "    $FIXTURE_DIR/frontend-wasm.ct"
echo "    $FIXTURE_DIR/backend.ct"
echo "    $FIXTURE_DIR/session.toml"
