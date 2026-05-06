#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VISUAL_REPLAY_REPO="${CODETRACER_VISUAL_REPLAY_REPO_PATH:-${REPO_ROOT}/../codetracer-visual-replay}"
NATIVE_BACKEND_REPO="${CODETRACER_NATIVE_BACKEND_REPO_PATH:-${VISUAL_REPLAY_REPO}/../codetracer-native-backend}"

NIM_TESTS=(
	"src/tests/gui/tests/frame-viewer/frame_viewer_vm_test.nim"
	"src/tests/gui/tests/frame-viewer/visual_replay_layout_test.nim"
	"src/tests/gui/tests/frame-viewer/visual_player_lifecycle_test.nim"
	"src/tests/gui/tests/debug-controls/live_mcr_debug_controls_test.nim"
)

PLAYWRIGHT_TESTS=(
	"tests/frame-viewer/visual-replay-gui.spec.ts"
	"tests/frame-viewer/frame-viewer-storybook.spec.ts"
)

PLAYWRIGHT_REAL_RECORDING_TEST="tests/frame-viewer/visual-replay-real-recording.spec.ts"

REQUIRED_SOURCE_FILES=(
	"${NIM_TESTS[@]}"
	"src/tests/gui/${PLAYWRIGHT_TESTS[0]}"
	"src/tests/gui/${PLAYWRIGHT_TESTS[1]}"
	"src/tests/gui/${PLAYWRIGHT_REAL_RECORDING_TEST}"
)

cd "$REPO_ROOT"

echo "###############################################################################"
echo "Checking required visual replay tests are present and runnable"
echo "###############################################################################"

for required_file in "${REQUIRED_SOURCE_FILES[@]}"; do
	if [[ ! -f $required_file ]]; then
		echo "Missing required visual replay test: $required_file" >&2
		exit 1
	fi
done

# Playwright's forbidOnly is enabled through CI=1 below. This explicit source
# check makes the required visual-replay slice fail before execution if it is
# accidentally marked skip/fixme/fail or focused-only.
if rg -n \
	'(^|[^[:alnum:]_])(test|describe)(\.(only|skip|fixme|fail)|\.describe\.(only|skip))\s*\(' \
	"src/tests/gui/${PLAYWRIGHT_TESTS[0]}" \
	"src/tests/gui/${PLAYWRIGHT_TESTS[1]}" \
	"src/tests/gui/${PLAYWRIGHT_REAL_RECORDING_TEST}"; then
	echo "Required Playwright visual replay tests contain focused or skipped tests." >&2
	exit 1
fi

if rg -n '(^|[^[:alnum:]_])(skip|ignore)([^[:alnum:]_]|$)' "${NIM_TESTS[@]}"; then
	echo "Required Nim visual replay tests contain skipped or ignored tests." >&2
	exit 1
fi

echo "###############################################################################"
echo "Running CodeTracer visual replay build prerequisites"
echo "###############################################################################"
just build-once
just build-storybook-components
just storybook-build

echo "###############################################################################"
echo "Running required headless CodeTracer visual replay ViewModel tests"
echo "###############################################################################"
for test_file in "${NIM_TESTS[@]}"; do
	test_name="$(basename "$test_file" .nim)"
	cache="/tmp/ct-nim-cache/visual-replay-gate-${test_name}"
	nim c -r --hints:off \
		--path:src/frontend/viewmodel \
		--nimcache:"$cache" \
		-o:"$cache/$test_name" \
		"$test_file"
done

echo "###############################################################################"
echo "Running required fake-player and StoryBook Playwright visual replay tests"
echo "###############################################################################"
PLAYWRIGHT_GATE_JSON="${REPO_ROOT}/src/tests/gui/test-results/visual-replay-gate-results.json"
rm -f "$PLAYWRIGHT_GATE_JSON"
CI=1 \
	CODETRACER_VISUAL_REPLAY_GATE_JSON="$PLAYWRIGHT_GATE_JSON" \
	PLAYWRIGHT_RETRIES="${PLAYWRIGHT_RETRIES:-0}" \
	just test-gui "${PLAYWRIGHT_TESTS[@]}"

node - "$PLAYWRIGHT_GATE_JSON" <<'NODE'
const fs = require("node:fs");
const reportPath = process.argv[2];
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const skipped = [];
let total = 0;

function visitSuite(suite) {
  for (const spec of suite.specs || []) {
    for (const testCase of spec.tests || []) {
      total += 1;
      const titlePath = spec.titlePath || [];
      const title = [
        ...(testCase.projectName ? [testCase.projectName] : []),
        ...titlePath,
        spec.title,
        testCase.title,
      ].filter(Boolean).join(" > ");
      if (testCase.outcome === "skipped") {
        skipped.push(title);
      }
      for (const result of testCase.results || []) {
        if (result.status === "skipped") {
          skipped.push(title);
        }
      }
    }
  }
  for (const child of suite.suites || []) {
    visitSuite(child);
  }
}

for (const suite of report.suites || []) {
  visitSuite(suite);
}

if (total === 0) {
  console.error("No Playwright tests ran in the visual replay gate.");
  process.exit(1);
}

if (skipped.length > 0 || (report.stats && report.stats.skipped > 0)) {
  console.error("Required visual replay Playwright tests were skipped:");
  for (const title of [...new Set(skipped)]) {
    console.error(`  ${title}`);
  }
  process.exit(1);
}
NODE

echo "###############################################################################"
echo "Running codetracer-visual-replay headless player and golden tests"
echo "###############################################################################"
if [[ ! -d $VISUAL_REPLAY_REPO ]]; then
	echo "Missing codetracer-visual-replay sibling at $VISUAL_REPLAY_REPO" >&2
	exit 1
fi

if [[ -z ${CODETRACER_NATIVE_REPLAY:-} ]]; then
	native_replay_bin="$NATIVE_BACKEND_REPO/target/debug/ct-native-replay"
	if [[ ! -x $native_replay_bin ]]; then
		if [[ ! -d $NATIVE_BACKEND_REPO ]]; then
			echo "Missing codetracer-native-backend sibling at $NATIVE_BACKEND_REPO" >&2
			exit 1
		fi
		(
			cd "$NATIVE_BACKEND_REPO"
			if command -v nix >/dev/null 2>&1; then
				nix develop '.?submodules=1' --command cargo build --bin ct-native-replay
			else
				cargo build --bin ct-native-replay
			fi
		)
	fi
	export CODETRACER_NATIVE_REPLAY="$native_replay_bin"
fi

VISUAL_REPLAY_LICENSE_DIR="${TMPDIR:-/tmp}/ct-visual-replay-gate-license"
mkdir -p "$VISUAL_REPLAY_LICENSE_DIR"
"$CODETRACER_NATIVE_REPLAY" license generate-visual-replay-test-license \
	--license-file "$VISUAL_REPLAY_LICENSE_DIR/visual-replay-test.license.dat" \
	--env-file "$VISUAL_REPLAY_LICENSE_DIR/visual-replay-test.env"
# shellcheck disable=SC1091
source "$VISUAL_REPLAY_LICENSE_DIR/visual-replay-test.env"
export CODETRACER_LICENSE_FILE CODETRACER_DEV_LICENSE_VERIFYING_KEY_BASE64

(
	cd "$VISUAL_REPLAY_REPO"
	read -r -d '' visual_replay_command <<'VISUAL_REPLAY_COMMAND' || true
set -euo pipefail
nimble build
./scripts/install-native-replay-companion.sh
just gl-test-programs
just build-ct-mcr
nim c -r tests/test_player_context.nim
nim c -r tests/test_gl_executor.nim
nim c -r tests/test_golden_compare.nim
nim c -r tests/test_rpc_server.nim
nim c -r tests/test_server_timing.nim
nim c -r tests/test_mcr_recording.nim
nim c -r tests/test_gl_extraction.nim
VISUAL_REPLAY_COMMAND

	if [[ ${CODETRACER_VISUAL_REPLAY_USE_NIX:-1} == "1" ]] && command -v nix >/dev/null 2>&1; then
		LP_NUM_THREADS="${LP_NUM_THREADS:-1}" nix develop '.?submodules=1' --command bash -lc "$visual_replay_command"
	else
		LP_NUM_THREADS="${LP_NUM_THREADS:-1}" bash -lc "$visual_replay_command"
	fi
)

echo "###############################################################################"
echo "Recording a real GL visual replay trace for CodeTracer GUI integration"
echo "###############################################################################"
REAL_VISUAL_TRACE_DIR="${TMPDIR:-/tmp}/ct-real-visual-replay-gui"
REAL_VISUAL_TRACE="${REAL_VISUAL_TRACE_DIR}/gl_scene.ct"
REAL_VISUAL_OUTPUT_BASE="${REAL_VISUAL_TRACE_DIR}/gl_scene"
rm -rf "$REAL_VISUAL_TRACE_DIR"
mkdir -p "$REAL_VISUAL_TRACE_DIR"

real_visual_record_command='set -euo pipefail
cd "$VISUAL_REPLAY_REPO"
LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS="${LP_NUM_THREADS:-1}" ../codetracer-native-recorder/ct_cli/ct_cli record \
	--use-interpose \
	-o "$REAL_VISUAL_TRACE" \
	-- ../codetracer-native-test-programs/gl/gl_scene "$REAL_VISUAL_OUTPUT_BASE"
test -f "$REAL_VISUAL_TRACE"
'

if [[ ${CODETRACER_VISUAL_REPLAY_USE_NIX:-1} == "1" ]] && command -v nix >/dev/null 2>&1; then
	VISUAL_REPLAY_REPO="$VISUAL_REPLAY_REPO" \
	REAL_VISUAL_TRACE="$REAL_VISUAL_TRACE" \
	REAL_VISUAL_OUTPUT_BASE="$REAL_VISUAL_OUTPUT_BASE" \
		nix develop "${VISUAL_REPLAY_REPO}/.?submodules=1" --command bash -lc "$real_visual_record_command"
else
	VISUAL_REPLAY_REPO="$VISUAL_REPLAY_REPO" \
	REAL_VISUAL_TRACE="$REAL_VISUAL_TRACE" \
	REAL_VISUAL_OUTPUT_BASE="$REAL_VISUAL_OUTPUT_BASE" \
		bash -lc "$real_visual_record_command"
fi

echo "###############################################################################"
echo "Running real-recording CodeTracer visual replay GUI integration test"
echo "###############################################################################"
REAL_PLAYWRIGHT_GATE_JSON="${REPO_ROOT}/src/tests/gui/test-results/visual-replay-real-gate-results.json"
rm -f "$REAL_PLAYWRIGHT_GATE_JSON"
CI=1 \
	CODETRACER_VISUAL_REPLAY_GATE_JSON="$REAL_PLAYWRIGHT_GATE_JSON" \
	CODETRACER_REAL_VISUAL_TRACE="$REAL_VISUAL_TRACE" \
	CODETRACER_CT_MCR_CMD="${VISUAL_REPLAY_REPO}/../codetracer-native-recorder/ct_cli/ct_cli" \
	CODETRACER_CT_GFX_PLAYER_CMD="${VISUAL_REPLAY_REPO}/ct_gfx_player" \
	CODETRACER_CT_GFX_PLAYER_BACKEND="${CODETRACER_CT_GFX_PLAYER_BACKEND:-software}" \
	PLAYWRIGHT_RETRIES="${PLAYWRIGHT_RETRIES:-0}" \
	just test-gui "$PLAYWRIGHT_REAL_RECORDING_TEST"

node - "$REAL_PLAYWRIGHT_GATE_JSON" <<'NODE'
const fs = require("node:fs");
const reportPath = process.argv[2];
const report = JSON.parse(fs.readFileSync(reportPath, "utf8"));
const skipped = [];
let total = 0;

function visitSuite(suite) {
  for (const spec of suite.specs || []) {
    for (const testCase of spec.tests || []) {
      total += 1;
      const titlePath = spec.titlePath || [];
      const title = [
        ...(testCase.projectName ? [testCase.projectName] : []),
        ...titlePath,
        spec.title,
        testCase.title,
      ].filter(Boolean).join(" > ");
      if (testCase.outcome === "skipped") {
        skipped.push(title);
      }
      for (const result of testCase.results || []) {
        if (result.status === "skipped") {
          skipped.push(title);
        }
      }
    }
  }
  for (const child of suite.suites || []) {
    visitSuite(child);
  }
}

for (const suite of report.suites || []) {
  visitSuite(suite);
}

if (total === 0) {
  console.error("No real-recording Playwright tests ran in the visual replay gate.");
  process.exit(1);
}

if (skipped.length > 0 || (report.stats && report.stats.skipped > 0)) {
  console.error("Required real-recording visual replay Playwright tests were skipped:");
  for (const title of [...new Set(skipped)]) {
    console.error(`  ${title}`);
  }
  process.exit(1);
}
NODE
