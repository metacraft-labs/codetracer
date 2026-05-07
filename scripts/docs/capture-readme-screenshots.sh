#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# We use the absolute path for the trace to ensure it's found
TRACE_PATH="${REPO_ROOT}/fibonacci-readme.ct"
OUTPUT_DIR="${REPO_ROOT}"

# Record the trace first
"${REPO_ROOT}/src/build-debug/bin/ct" record -o "${TRACE_PATH}" -- python3 "${REPO_ROOT}/examples/fibonacci.py"

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
