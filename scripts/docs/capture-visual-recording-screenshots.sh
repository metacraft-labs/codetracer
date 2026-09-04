#!/usr/bin/env bash
# Documentation asset capture, not a check on the product. It no longer
# carries the not-a-CI-gate marker because its stale-sibling refusals ARE exercised
# from CI by `ci/test/stale-artefact-guards-test.sh`, and
# `shell-gate-coverage.sh` fails a file that is both reachable and declared
# unwired.
#
# Driven by two `just` recipes and by repro.nim, when a person
# regenerates the book's images.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
WORKSPACE_ROOT="$(cd -- "${REPO_ROOT}/.." && pwd)"

# Read by the sourced library below, which prefixes every diagnostic with it.
# shellcheck disable=SC2034
CTDR_LABEL="capture-visual-recording-screenshots"
# shellcheck source=scripts/docs/deep-review-capture-lib.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deep-review-capture-lib.sh"
VISUAL_REPLAY_REPO="${VISUAL_REPLAY_REPO:-${WORKSPACE_ROOT}/codetracer-visual-replay}"
NATIVE_RECORDER_REPO="${NATIVE_RECORDER_REPO:-${WORKSPACE_ROOT}/codetracer-native-recorder}"
NATIVE_TEST_PROGRAMS_REPO="${NATIVE_TEST_PROGRAMS_REPO:-${WORKSPACE_ROOT}/codetracer-native-test-programs}"

CT_MCR="${CODETRACER_CT_MCR_CMD:-${NATIVE_RECORDER_REPO}/ct_cli/ct_cli}"
GFX_PLAYER="${CODETRACER_CT_GFX_PLAYER_CMD:-${VISUAL_REPLAY_REPO}/ct_gfx_player}"
TRACE_PATH="${CODETRACER_REAL_VISUAL_TRACE:-}"
OUTPUT_DIR="${CODETRACER_BOOK_SCREENSHOT_DIR:-${REPO_ROOT}/docs/book/src/generated/visual_recordings}"
CAPTURE_ATTEMPTS="${CODETRACER_BOOK_SCREENSHOT_TRACE_ATTEMPTS:-3}"

# EXECUTABILITY IS NOT CURRENCY.
#
# These two guards used to be `[[ ! -x ... ]]`, which asks whether SOMETHING was
# built, never whether it was built from the sources that are on disk now. The
# images this script writes go straight into the book
# (`docs/book/src/generated/visual_recordings`), so a recorder or a player older
# than its own sources publishes pictures of an old product and nothing in the
# picture says so.
#
# The source list is the sibling's own `git ls-files` rather than a pattern
# guessed from here — see `ctdr_require_sibling_binary_not_stale`. That is what
# unblocks a fix that was reported and skipped once already, on the (correct)
# grounds that neither sibling's layout is this repository's to assume.
ctdr_require_sibling_binary_not_stale "the MCR command (ct_cli)" \
	"${CT_MCR}" "${NATIVE_RECORDER_REPO}" \
	"Set CODETRACER_CT_MCR_CMD or build codetracer-native-recorder."

ctdr_require_sibling_binary_not_stale "the visual replay player (ct_gfx_player)" \
	"${GFX_PLAYER}" "${VISUAL_REPLAY_REPO}" \
	"Set CODETRACER_CT_GFX_PLAYER_CMD or build codetracer-visual-replay."

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

if [[ -n ${TRACE_PATH} ]]; then
	run_capture "${TRACE_PATH}"
else
	GL_SCENE="${NATIVE_TEST_PROGRAMS_REPO}/gl/gl_scene"
	# The same axis again, and this one is the SUBJECT of the recording rather
	# than a tool used to make it: every frame in the published images is a
	# frame `gl_scene` drew. A binary older than `gl/gl_scene.c` photographs a
	# scene the repository no longer contains.
	ctdr_require_sibling_binary_not_stale "the GL scene fixture (gl_scene)" \
		"${GL_SCENE}" "${NATIVE_TEST_PROGRAMS_REPO}" \
		"Set CODETRACER_REAL_VISUAL_TRACE to an existing visual .ct trace or build codetracer-native-test-programs."

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
		if [[ ${attempt} == "${CAPTURE_ATTEMPTS}" ]]; then
			echo "Failed to capture visual recording screenshots after ${CAPTURE_ATTEMPTS} attempts." >&2
			exit 1
		fi
		echo "Capture attempt ${attempt} failed; recording a fresh trace and retrying." >&2
	done
fi

echo "Captured:"
find "${OUTPUT_DIR}" -maxdepth 1 -type f -name '*.png' -print | sort
