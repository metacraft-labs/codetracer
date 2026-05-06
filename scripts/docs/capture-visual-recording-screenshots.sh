#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"
VISUAL_REPLAY_REPO="${VISUAL_REPLAY_REPO:-${WORKSPACE_ROOT}/codetracer-visual-replay}"
NATIVE_RECORDER_REPO="${NATIVE_RECORDER_REPO:-${WORKSPACE_ROOT}/codetracer-native-recorder}"
NATIVE_TEST_PROGRAMS_REPO="${NATIVE_TEST_PROGRAMS_REPO:-${WORKSPACE_ROOT}/codetracer-native-test-programs}"

CT_MCR="${CODETRACER_CT_MCR_CMD:-${NATIVE_RECORDER_REPO}/ct_cli/ct_cli}"
GFX_PLAYER="${CODETRACER_CT_GFX_PLAYER_CMD:-${VISUAL_REPLAY_REPO}/ct_gfx_player}"
TRACE_PATH="${CODETRACER_REAL_VISUAL_TRACE:-}"
OUTPUT_DIR="${CODETRACER_BOOK_SCREENSHOT_DIR:-${REPO_ROOT}/docs/book/src/generated/visual_recordings}"
CAPTURE_ATTEMPTS="${CODETRACER_BOOK_SCREENSHOT_TRACE_ATTEMPTS:-3}"

if [[ ! -x "${CT_MCR}" ]]; then
	echo "Missing executable MCR command: ${CT_MCR}" >&2
	echo "Set CODETRACER_CT_MCR_CMD or build codetracer-native-recorder." >&2
	exit 1
fi

if [[ ! -x "${GFX_PLAYER}" ]]; then
	echo "Missing executable visual replay player: ${GFX_PLAYER}" >&2
	echo "Set CODETRACER_CT_GFX_PLAYER_CMD or build codetracer-visual-replay." >&2
	exit 1
fi

run_capture() {
	local trace_path="$1"
	rm -rf "${OUTPUT_DIR}"
	mkdir -p "${OUTPUT_DIR}"

	echo "Capturing book screenshots into ${OUTPUT_DIR}"
	cd "${REPO_ROOT}/src/tests/gui"
	CI=1 \
		PLAYWRIGHT_RETRIES="${PLAYWRIGHT_RETRIES:-0}" \
		CODETRACER_REAL_VISUAL_TRACE="${trace_path}" \
		CODETRACER_CT_MCR_CMD="${CT_MCR}" \
		CODETRACER_CT_GFX_PLAYER_CMD="${GFX_PLAYER}" \
		CODETRACER_CT_GFX_PLAYER_BACKEND="${CODETRACER_CT_GFX_PLAYER_BACKEND:-software}" \
		CODETRACER_BOOK_SCREENSHOT_DIR="${OUTPUT_DIR}" \
		npx playwright test tests/docs/visual-recording-book-screenshots.spec.ts --workers=1
}

record_trace() {
	local attempt="$1"
	local trace_path="$2"
	local frame_output_base="$3"
	echo "Recording visual trace for book screenshots (attempt ${attempt}): ${trace_path}"
	LIBGL_ALWAYS_SOFTWARE="${LIBGL_ALWAYS_SOFTWARE:-1}" \
		LP_NUM_THREADS="${LP_NUM_THREADS:-1}" \
		"${CT_MCR}" record --use-interpose -o "${trace_path}" -- "${GL_SCENE}" "${frame_output_base}"
}

if [[ -n "${TRACE_PATH}" ]]; then
	run_capture "${TRACE_PATH}"
else
	GL_SCENE="${NATIVE_TEST_PROGRAMS_REPO}/gl/gl_scene"
	if [[ ! -x "${GL_SCENE}" ]]; then
		echo "Missing GL scene fixture: ${GL_SCENE}" >&2
		echo "Set CODETRACER_REAL_VISUAL_TRACE to an existing visual .ct trace or build codetracer-native-test-programs." >&2
		exit 1
	fi

	TMP_ROOT="${TMPDIR:-/tmp}/ct-book-visual-recording"
	rm -rf "${TMP_ROOT}"
	mkdir -p "${TMP_ROOT}"

	for attempt in $(seq 1 "${CAPTURE_ATTEMPTS}"); do
		ATTEMPT_ROOT="${TMP_ROOT}/attempt-${attempt}"
		rm -rf "${ATTEMPT_ROOT}"
		mkdir -p "${ATTEMPT_ROOT}"
		TRACE_PATH="${ATTEMPT_ROOT}/gl_scene.ct"
		FRAME_OUTPUT_BASE="${ATTEMPT_ROOT}/gl_scene"
		record_trace "${attempt}" "${TRACE_PATH}" "${FRAME_OUTPUT_BASE}"
		if run_capture "${TRACE_PATH}"; then
			break
		fi
		if [[ "${attempt}" == "${CAPTURE_ATTEMPTS}" ]]; then
			echo "Failed to capture visual recording screenshots after ${CAPTURE_ATTEMPTS} attempts." >&2
			exit 1
		fi
		echo "Capture attempt ${attempt} failed; recording a fresh trace and retrying." >&2
	done
fi

echo "Captured:"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '*.png' -print | sort
