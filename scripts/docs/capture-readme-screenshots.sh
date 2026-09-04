#!/usr/bin/env bash
# NOT-A-CI-GATE: documentation asset capture.
#
# Nothing in the tree calls it -- not even a `just` recipe. That is a
# fact about how the README images get refreshed, not a hole in CI.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# Read by the sourced library below, which prefixes every diagnostic with it.
# shellcheck disable=SC2034
CTDR_LABEL="capture-readme-screenshots"
# shellcheck source=scripts/docs/deep-review-capture-lib.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deep-review-capture-lib.sh"

# We use the absolute path for the trace to ensure it's found
TRACE_PATH="${REPO_ROOT}/fibonacci-readme.ct"
OUTPUT_DIR="${REPO_ROOT}"

# THE BUILD TREE IS PHOTOGRAPHED AS IT STANDS. Same check, same reason, and the
# same wording as `capture-deep-review-screenshots.sh`: the stylesheet the
# window loads and the renderer bundle that draws every panel must be newer than
# the sources they were built from, or these images document a CodeTracer that
# no longer exists — on the README.
ctdr_resolve_ct "${REPO_ROOT}"
ctdr_require_fresh_build "${REPO_ROOT}"

# Record the trace first
"${CTDR_CT}" record -o "${TRACE_PATH}" -- python3 "${REPO_ROOT}/examples/fibonacci.py"

echo "Capturing README animations using just test-e2e..."
export CODETRACER_REAL_VISUAL_TRACE="${TRACE_PATH}"
export CODETRACER_README_SCREENSHOT_DIR="${OUTPUT_DIR}"

VIDEO_DIR="${REPO_ROOT}/src/tests/gui/test-results/readme-animations-video"
rm -rf "${VIDEO_DIR}"

# Run via just to ensure environment (DISPLAY, etc) is handled if possible,
# but here we'll just call npx playwright directly for control over output dir.
cd "${REPO_ROOT}/src/tests/gui"

run_playwright() {
	npx playwright test tests/docs/readme-screenshots.spec.ts --workers=1 --output="${VIDEO_DIR}"
}

if [[ "$(uname -s)" == "Linux" ]] && [[ -z ${DISPLAY:-} ]]; then
	echo "Starting Xvfb..."
	DISPLAY_NUM=99
	while [ -e "/tmp/.X${DISPLAY_NUM}-lock" ]; do
		DISPLAY_NUM=$((DISPLAY_NUM + 1))
	done
	Xvfb ":${DISPLAY_NUM}" -screen 0 1920x1080x24 -nolisten tcp &
	XVFB_PID=$!
	trap 'kill $XVFB_PID 2>/dev/null || true' EXIT
	sleep 1
	export DISPLAY=":${DISPLAY_NUM}"
	run_playwright
else
	run_playwright
fi

echo "Converting videos to animated WebP..."
for test_name in omniscience tracepoint calltrace state-and-history eventlog terminal; do
	video_file=$(find "${VIDEO_DIR}" -path "*${test_name}*" -name "*.webm" | head -n 1)

	if [[ -n ${video_file} ]]; then
		echo "Converting ${test_name} animation..."
		ffmpeg -y -i "${video_file}" \
			-vcodec libwebp -filter_complex "[0:v] fps=12,scale=1280:-1:flags=lanczos" \
			-loop 0 -vsync 0 -q:v 80 "${OUTPUT_DIR}/${test_name}.webp"
		echo "Generated ${test_name}.webp"
	else
		echo "Warning: Video for ${test_name} not found!"
	fi
done

rm -rf "${VIDEO_DIR}"
echo "Done! Animated screenshots are in ${OUTPUT_DIR}"
