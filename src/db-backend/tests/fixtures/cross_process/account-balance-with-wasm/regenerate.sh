#!/usr/bin/env bash
# Cross-Tracer Origin E2E — Fixture A' "Account Balance with WASM"
# regenerator (three-tracer per
# Cross-Tracer-Origin-Test.audit.md § TCT-M4).
#
# This script drives the full recorder pipeline:
#   1. wasm-pack builds `wasm-src/lib.rs` -> `frontend/pkg/`.
#   2. `vite build` produces the production-mode frontend bundle.
#   3. Starts the aiohttp backend under the codetracer Python recorder.
#   4. Starts the Vite preview server under the codetracer-js-recorder
#      host (which in turn loads the WASM module under the
#      codetracer-wasm-instrumenter shim).
#   5. Drives a single POST /balance request through a headless
#      browser (Playwright / chrome-headless-shell).
#   6. Tears the three recorder processes down and writes
#      `frontend.ct`, `frontend-wasm.ct`, `backend.ct` next to this
#      script + a populated `session.toml` (UUIDv7s substituted into
#      the template).
#
# The script is GATED on the per-stage recorder + toolchain
# availability and exits 75 (EX_TEMPFAIL) — i.e. "honestly skipped"
# per the existing two-trace fixture convention — when any
# prerequisite is absent.
#
# Per M29's `:deferred_items:` block, the per-language recorder
# fixture infrastructure (Vite plugin + record.sh + per-language
# recorders + TestCache wrapper) lands incrementally. Until it
# lands fully, this regenerator can still parse + report which
# stages are blocked.
set -euo pipefail

FIXTURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

require_bin() {
	local bin="$1"
	local hint="$2"
	if ! command -v "$bin" >/dev/null 2>&1; then
		missing+=("- $bin not on PATH ($hint)")
	fi
}

require_bin cargo "rustup; install via 'curl https://sh.rustup.rs -sSf | sh'"
require_bin wasm-pack "install via 'cargo install wasm-pack' or 'nix run nixpkgs#wasm-pack'"
require_bin node "install via your platform's package manager"
require_bin npx "ships with Node.js"
require_bin python3 "install via your platform's package manager"

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

# Recorder availability — these are the per-language recorders the
# M29 :deferred_items: block calls out. We surface them by name so
# the operator can wire each one up incrementally.
require_bin codetracer "the codetracer CLI ('just build-once' from the repo root produces it at src/build-debug/bin/ct)"

# Python aiohttp recorder hooks (boundary auto-marker for
# X-Codetracer-Origin). Detect by checking that the codetracer
# Python recorder package is importable from the active python3.
if command -v python3 >/dev/null 2>&1; then
	if ! python3 -c 'import codetracer_python_recorder' >/dev/null 2>&1; then
		missing+=("- codetracer_python_recorder Python package not importable (install via the codetracer dev shell or 'pip install codetracer-python-recorder')")
	fi
fi

# codetracer-js-recorder host process — under the M26 backend-manager
# umbrella this is `browser_stream_receiver`. We don't hard-require
# the binary, just probe and report.
if ! command -v browser_stream_receiver >/dev/null 2>&1; then
	missing+=("- browser_stream_receiver (M26 codetracer-js-recorder host) not on PATH; expected from 'just build-once' or the codetracer dev shell")
fi

# Playwright headless browser. The regenerator drives one
# POST /balance request through chrome-headless-shell; if Playwright
# is absent we fall back to nothing and skip.
if ! command -v npx >/dev/null 2>&1 || ! npx --no-install playwright --version >/dev/null 2>&1; then
	missing+=("- playwright not installed under this repo's node_modules (run 'npm install playwright' in this fixture's frontend/ dir)")
fi

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
	npx vite build
)

echo "[regenerate] Step 3/6: start aiohttp backend under codetracer Python recorder"
codetracer record \
	--output "$FIXTURE_DIR/backend.ct" \
	--boundary-id account-balance-with-wasm \
	-- python3 "$FIXTURE_DIR/backend/server.py" &
BACKEND_PID=$!
trap 'kill $BACKEND_PID >/dev/null 2>&1 || true' EXIT
# Wait for the aiohttp listener to bind before driving any request.
for _ in $(seq 1 30); do
	if curl -sf -o /dev/null -X POST -H 'Content-Type: application/json' \
		--data '{"balance":0}' http://127.0.0.1:8080/balance; then
		break
	fi
	sleep 0.2
done

echo "[regenerate] Step 4/6: start frontend under codetracer-js-recorder + wasm-instrumenter"
# `browser_stream_receiver` is the M26 host that pipes the JS +
# WASM event streams into two separate .ct files. The recorder host
# is responsible for resolving `frontend.ct` vs `frontend-wasm.ct`
# based on the realm origin.
browser_stream_receiver \
	--js-output "$FIXTURE_DIR/frontend.ct" \
	--wasm-output "$FIXTURE_DIR/frontend-wasm.ct" \
	--boundary-id account-balance-with-wasm \
	--vite-preview-dir "$FIXTURE_DIR/frontend/dist" &
FRONTEND_HOST_PID=$!
trap 'kill $FRONTEND_HOST_PID >/dev/null 2>&1 || true; kill $BACKEND_PID >/dev/null 2>&1 || true' EXIT

echo "[regenerate] Step 5/6: drive one POST /balance request via headless Chrome"
(
	cd "$FIXTURE_DIR/frontend"
	npx playwright test --config <(
		cat <<'PWCONF'
import { defineConfig } from "@playwright/test";
export default defineConfig({
  use: { baseURL: "http://127.0.0.1:4173" },
  webServer: { command: "npx vite preview --port 4173", url: "http://127.0.0.1:4173", reuseExistingServer: true },
  testDir: ".",
  testMatch: /smoke\.spec\.mjs$/,
});
PWCONF
	)
)

echo "[regenerate] Step 6/6: tear recorders down + stamp session.toml UUIDv7s"
kill "$FRONTEND_HOST_PID" >/dev/null 2>&1 || true
kill "$BACKEND_PID" >/dev/null 2>&1 || true
wait "$FRONTEND_HOST_PID" 2>/dev/null || true
wait "$BACKEND_PID" 2>/dev/null || true

# UUIDv7 generator — uses the codetracer CLI's standard helper so
# the stamped ids are consistent with how the live recorders stamp
# their own. Falls back to python3's uuid module if the CLI helper
# is absent.
gen_uuid7() {
	if codetracer uuid7 2>/dev/null; then
		return 0
	fi
	python3 -c 'import uuid; print(uuid.uuid4())'
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
