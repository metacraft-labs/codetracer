#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VISUAL_REPLAY_REPO="${CODETRACER_VISUAL_REPLAY_REPO_PATH:-${REPO_ROOT}/../codetracer-visual-replay}"
NATIVE_BACKEND_REPO="${CODETRACER_NATIVE_BACKEND_REPO_PATH:-${VISUAL_REPLAY_REPO}/../codetracer-native-backend}"
# shellcheck disable=SC1091
source "${REPO_ROOT}/ci/test/visual-replay-gate-lib.sh"

NIM_TESTS=(
	"src/tests/gui/tests/frame-viewer/frame_viewer_vm_test.nim"
	"src/tests/gui/tests/frame-viewer/visual_replay_layout_test.nim"
	"src/tests/gui/tests/frame-viewer/visual_player_lifecycle_test.nim"
	"src/tests/gui/tests/frame-viewer/video_player_vm_test.nim"
	"src/tests/gui/tests/frame-viewer/video_player_polish_test.nim"
	"src/tests/gui/tests/debug-controls/live_mcr_debug_controls_test.nim"
)

VISUAL_REPLAY_NIM_TESTS=(
	"tests/test_player_context.nim"
	"tests/test_gl_executor.nim"
	"tests/test_golden_compare.nim"
	"tests/test_rpc_server.nim"
	"tests/test_server_timing.nim"
	"tests/test_mcr_recording.nim"
	"tests/test_gl_extraction.nim"
)

PLAYWRIGHT_TESTS=(
	"tests/frame-viewer/visual-replay-gui.spec.ts"
	"tests/frame-viewer/frame-viewer-storybook.spec.ts"
	"tests/frame-viewer/video-player-storybook.spec.ts"
)

PLAYWRIGHT_REAL_RECORDING_TEST="tests/frame-viewer/visual-replay-real-recording.spec.ts"

REQUIRED_SOURCE_FILES=(
	"${NIM_TESTS[@]}"
	"src/tests/gui/${PLAYWRIGHT_TESTS[0]}"
	"src/tests/gui/${PLAYWRIGHT_TESTS[1]}"
	"src/tests/gui/${PLAYWRIGHT_TESTS[2]}"
	"src/tests/gui/${PLAYWRIGHT_REAL_RECORDING_TEST}"
	"storybook/package-lock.json"
)

cd "$REPO_ROOT"

bash ci/test/visual-replay-gate-test.sh

echo "###############################################################################"
echo "Checking required visual replay tests and build siblings"
echo "###############################################################################"

# shellcheck disable=SC1091
source ci/test/visual-replay-private-cargo-env.sh

for required_file in "${REQUIRED_SOURCE_FILES[@]}"; do
	if [[ ! -f $required_file ]]; then
		echo "Missing required visual replay gate source: $required_file" >&2
		exit 1
	fi
done

if [[ ! -d $VISUAL_REPLAY_REPO ]]; then
	echo "Missing codetracer-visual-replay sibling at $VISUAL_REPLAY_REPO" >&2
	exit 1
fi
for required_file in "${VISUAL_REPLAY_NIM_TESTS[@]}"; do
	if [[ ! -f $VISUAL_REPLAY_REPO/$required_file ]]; then
		echo "Missing required visual replay sibling test: $required_file" >&2
		exit 1
	fi
done

bash ci/test/visual-replay-build-sibling-preflight.sh "$REPO_ROOT/.."
bash ci/test/visual-replay-private-cargo-preflight-test.sh
bash ci/test/visual-replay-private-cargo-preflight.sh "$NATIVE_BACKEND_REPO"

# The Nix dev shell provides the flake-locked Rust-backed recorder via
# CODETRACER_PYTHON_CMD. CodeTracer's recording CLI consumes the more specific
# interpreter variable, so bind the two contracts explicitly and fail before
# the GUI tests if the recorder package is unavailable.
if [[ -z ${CODETRACER_PYTHON_INTERPRETER:-} ]]; then
	CODETRACER_PYTHON_INTERPRETER="${CODETRACER_PYTHON_CMD:-}"
	export CODETRACER_PYTHON_INTERPRETER
fi
if [[ -z $CODETRACER_PYTHON_INTERPRETER ]] ||
	! "$CODETRACER_PYTHON_INTERPRETER" -c 'import codetracer_python_recorder'; then
	echo "Missing required flake-locked Python recorder interpreter." >&2
	exit 1
fi

# Playwright's forbidOnly is enabled through CI=1 below. This explicit source
# check makes the required visual-replay slice fail before execution if it is
# accidentally marked skip/fixme/fail or focused-only.
if rg -n \
	'(^|[^[:alnum:]_])(test|describe)(\.(only|skip|fixme|fail)|\.describe\.(only|skip))\s*\(' \
	"src/tests/gui/${PLAYWRIGHT_TESTS[0]}" \
	"src/tests/gui/${PLAYWRIGHT_TESTS[1]}" \
	"src/tests/gui/${PLAYWRIGHT_TESTS[2]}" \
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
npm ci --prefix storybook --ignore-scripts --no-audit --no-fund
just storybook-build

echo "###############################################################################"
echo "Running required headless CodeTracer visual replay ViewModel tests"
echo "###############################################################################"
for test_index in "${!NIM_TESTS[@]}"; do
	test_file="${NIM_TESTS[$test_index]}"
	test_name="$(basename "$test_file" .nim)"
	cache="/tmp/ct-nim-cache/visual-replay-gate-${test_name}"
	visual_replay_run_nim_suite "$test_file" \
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
visual_replay_run_playwright_stage fake "$PLAYWRIGHT_GATE_JSON" \
	just test-gui-prebuilt "${PLAYWRIGHT_TESTS[@]}"

echo "###############################################################################"
echo "Running codetracer-visual-replay headless player and golden tests"
echo "###############################################################################"
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
source "$CODETRACER_VISUAL_REPLAY_GATE_LIB"
run_visual_replay_nim_test() {
	local test_file="$1" test_name cache
	test_name="$(basename "$test_file" .nim)"
	cache="${TMPDIR:-/tmp}/ct-nim-cache/visual-replay-sibling-gate-${test_name}"
	visual_replay_run_nim_suite "$test_file" \
		nim c -r --hints:off \
		--nimcache:"$cache" \
		-o:"$cache/$test_name" \
		"$test_file"
}
run_visual_replay_nim_test tests/test_player_context.nim
run_visual_replay_nim_test tests/test_gl_executor.nim
run_visual_replay_nim_test tests/test_golden_compare.nim
run_visual_replay_nim_test tests/test_rpc_server.nim
run_visual_replay_nim_test tests/test_server_timing.nim
run_visual_replay_nim_test tests/test_mcr_recording.nim
run_visual_replay_nim_test tests/test_gl_extraction.nim
VISUAL_REPLAY_COMMAND

	export CODETRACER_VISUAL_REPLAY_GATE_LIB="${REPO_ROOT}/ci/test/visual-replay-gate-lib.sh"
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

# shellcheck disable=SC2016
# The $VAR references inside the heredoc-style string are intentionally
# unexpanded — they are expanded by the inner ``bash -lc`` invocation
# below using the environment exported on the calling line.
real_visual_record_command='set -euo pipefail
cd "$VISUAL_REPLAY_REPO"
LIBGL_ALWAYS_SOFTWARE=1 LP_NUM_THREADS="${LP_NUM_THREADS:-1}" ../codetracer-native-recorder/ct_cli/ct_cli record \
	--use-interpose \
	-o "$REAL_VISUAL_TRACE" \
	-- ../codetracer-native-test-programs/gl/gl_scene "$REAL_VISUAL_OUTPUT_BASE"
test -f "$REAL_VISUAL_TRACE"
'

if [[ ${CODETRACER_VISUAL_REPLAY_USE_NIX:-1} == "1" ]] && command -v nix >/dev/null 2>&1; then
	# shellcheck disable=SC2097,SC2098
	# Bash propagates per-command env assignments to the immediate
	# child process; here that child is ``nix develop`` which in turn
	# inherits the caller's environment when invoking ``--command``.
	# Shellcheck cannot trace through the indirection.
	VISUAL_REPLAY_REPO="$VISUAL_REPLAY_REPO" \
		REAL_VISUAL_TRACE="$REAL_VISUAL_TRACE" \
		REAL_VISUAL_OUTPUT_BASE="$REAL_VISUAL_OUTPUT_BASE" \
		nix develop "${VISUAL_REPLAY_REPO}/.?submodules=1" --command bash -lc "$real_visual_record_command"
else
	# shellcheck disable=SC2097,SC2098
	# Same env-propagation pattern as the nix branch above — bash
	# forwards the per-command assignments to the immediate ``bash
	# -lc`` child.
	VISUAL_REPLAY_REPO="$VISUAL_REPLAY_REPO" \
		REAL_VISUAL_TRACE="$REAL_VISUAL_TRACE" \
		REAL_VISUAL_OUTPUT_BASE="$REAL_VISUAL_OUTPUT_BASE" \
		bash -lc "$real_visual_record_command"
fi

echo "###############################################################################"
echo "Running real-recording CodeTracer visual replay GUI integration test"
echo "###############################################################################"
REAL_PLAYWRIGHT_GATE_JSON="${REPO_ROOT}/src/tests/gui/test-results/visual-replay-real-gate-results.json"
CODETRACER_REAL_VISUAL_TRACE="$REAL_VISUAL_TRACE" \
	CODETRACER_CT_MCR_CMD="${VISUAL_REPLAY_REPO}/../codetracer-native-recorder/ct_cli/ct_cli" \
	CODETRACER_CT_GFX_PLAYER_CMD="${VISUAL_REPLAY_REPO}/ct_gfx_player" \
	CODETRACER_CT_GFX_PLAYER_BACKEND="${CODETRACER_CT_GFX_PLAYER_BACKEND:-software}" \
	visual_replay_run_playwright_stage real "$REAL_PLAYWRIGHT_GATE_JSON" \
	just test-gui-prebuilt "$PLAYWRIGHT_REAL_RECORDING_TEST"
