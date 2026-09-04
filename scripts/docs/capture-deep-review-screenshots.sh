#!/usr/bin/env bash
# NOT-A-CI-GATE: documentation asset capture.
#
# The two frozen `ct review` images the book quotes line for line. Its
# fixture is deliberately frozen, which is the opposite of what a gate
# wants from a fixture.
# Capture the DeepReview screenshots the book serves from
# `/assets/img/deep_review/`.
#
# The images in `docs/book-isonim/static/img/deep_review/` are GENERATED, not
# drawn: this script builds a real two-commit Noir repository, records it twice
# with the shipping `ct record`, collects a real review dataset with the
# shipping `ct review collect`, opens it with the shipping `ct review`, and
# photographs the running window. Nothing in the pictures is a mock-up, which is
# the only reason they are worth publishing next to prose that claims the
# feature works.
#
# Noir is the subject because `nargo` ships with CodeTracer and produces a
# MATERIALIZED trace — the trace kind RV-4 added a collector for, and the one
# the page's worked example uses. A native/rr capture would need an rr-capable
# machine (`perf_event_paranoid <= 1`) and would illustrate the rr-only past
# rather than the present.
#
# THE FIXTURE BELOW IS FROZEN. `docs/book-isonim/content/usage_guide/
# deep_review.md` quotes the program, the commit messages and the CLI output
# line for line, so editing the repository built here silently falsifies the
# prose the images sit next to. The design-review harness
# (`tools/visual-review/capture-deepreview-views.sh`) needs a much richer
# corpus; it gets its own fixture and shares only the machinery, in
# `scripts/docs/deep-review-capture-lib.sh`.
#
# Usage:
#   just capture-deep-review-assets
#   CODETRACER_BOOK_SCREENSHOT_DIR=/tmp/shots bash scripts/docs/capture-deep-review-screenshots.sh
#
# Every prerequisite is checked up front and named with its remedy, so a missing
# tool fails loudly here instead of leaving stale images in place.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# Read by the sourced library below, which prefixes every diagnostic with it.
# shellcheck disable=SC2034
CTDR_LABEL="capture-deep-review-screenshots"
# shellcheck source=scripts/docs/deep-review-capture-lib.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/deep-review-capture-lib.sh"

OUTPUT_DIR="${CODETRACER_BOOK_SCREENSHOT_DIR:-${REPO_ROOT}/docs/book-isonim/static/img/deep_review}"
DISPLAY_NUM="${CODETRACER_BOOK_SCREENSHOT_DISPLAY:-:96}"
SCREEN_SIZE="${CODETRACER_BOOK_SCREENSHOT_SCREEN:-2560x1200x24}"
WINDOW_TIMEOUT="${CODETRACER_BOOK_SCREENSHOT_WINDOW_TIMEOUT:-120}"
SETTLE_SECONDS="${CODETRACER_BOOK_SCREENSHOT_SETTLE:-15}"

ctdr_resolve_ct "${REPO_ROOT}"
ctdr_require_runtime_config "${REPO_ROOT}"
ctdr_require_fresh_build "${REPO_ROOT}"
ctdr_require_recording_tools
ctdr_require_display_tools
ctdr_require_cmd magick "install ImageMagick (v7); 'magick' does the trim/crop/resize."
ctdr_require_cmd import "install ImageMagick (v7); 'import' takes the screenshot."

CT="${CTDR_CT}"

WORK="$(mktemp -d -t ct-deep-review-shots-XXXXXX)"
CT_PID=""
cleanup() {
	[[ -n ${CT_PID} ]] && kill "${CT_PID}" 2>/dev/null || true
	sleep 1
	pkill -f "ct review ${WORK}/review" 2>/dev/null || true
	[[ -n ${CTDR_XVFB_PID:-} ]] && kill "${CTDR_XVFB_PID}" 2>/dev/null || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

# --- 1. a real two-commit repository -----------------------------------------
# The change under review adds a per-iteration `contribution` inside a loop, so
# the picture can show what only a review can show: the same line holding a
# different value on each pass.
REPO="${WORK}/scale_sum"
mkdir -p "${REPO}/src"
cat >"${REPO}/Nargo.toml" <<'EOF'
[package]
name = "scale_sum"
type = "bin"
authors = [""]

[dependencies]
EOF
printf 'x = "5"\n' >"${REPO}/Prover.toml"
cat >"${REPO}/src/main.nr" <<'EOF'
fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        sum = sum + x;
    }
    let final_result = sum;
    assert(final_result == 20);
}
EOF
ctdr_git_init "${REPO}"
ctdr_git_commit "${REPO}" "base: sum x four times"
cat >"${REPO}/src/main.nr" <<'EOF'
fn main(x: Field) {
    let mut sum: Field = 0;
    for i in 0..4 {
        let contribution = (i as Field) * x;
        sum = sum + contribution;
    }
    let final_result = sum;
    assert(final_result == 30);
}
EOF
ctdr_git_commit "${REPO}" "scale each term by the loop index"

# --- 2. two real recordings ---------------------------------------------------
# Two, so the review carries two trace contexts and two invocations of `main` —
# which is what makes the invocation stepper ("main: call 1 / 2") appear.
echo "capture-deep-review-screenshots: recording run-1 and run-2"
ctdr_record "${REPO}" "${WORK}/runs/run-1" "${WORK}/record-1.log"
printf 'x = "7"\n' >"${REPO}/Prover.toml"
ctdr_record "${REPO}" "${WORK}/runs/run-2" "${WORK}/record-2.log"
git -C "${REPO}" checkout -- Prover.toml

# --- 3. a real review dataset -------------------------------------------------
echo "capture-deep-review-screenshots: collecting the review dataset"
ctdr_collect "${REPO}" "${WORK}/runs" "${WORK}/review"

# --- 4. photograph the running app -------------------------------------------
# A throwaway XDG_CONFIG_HOME, so the window is the one a fresh install gets
# rather than whatever layout this machine happens to have saved.
mkdir -p "${WORK}/xdg"
ctdr_start_xvfb "${DISPLAY_NUM}" "${SCREEN_SIZE}" "${WORK}/xvfb.log"

echo "capture-deep-review-screenshots: opening the review"
DISPLAY="${DISPLAY_NUM}" XDG_CONFIG_HOME="${WORK}/xdg" \
	"${CT}" review "${WORK}/review" >"${WORK}/ct.log" 2>&1 &
CT_PID=$!

waited=0
until [[ $(DISPLAY="${DISPLAY_NUM}" xdotool search --onlyvisible --name "." 2>/dev/null | wc -l) -gt 0 ]]; do
	sleep 2
	waited=$((waited + 2))
	[[ ${waited} -ge ${WINDOW_TIMEOUT} ]] &&
		ctdr_die "no window appeared within ${WINDOW_TIMEOUT}s; see ${WORK}/ct.log"
done
# The window maps before the renderer has laid the review out; wait for it to
# settle rather than photographing a half-painted frame.
sleep "${SETTLE_SECONDS}"

mkdir -p "${OUTPUT_DIR}"
DISPLAY="${DISPLAY_NUM}" import -window root "${WORK}/raw.png"
# `-trim` removes the unused screen around the window, so the framing does not
# depend on the Xvfb geometry above.
magick "${WORK}/raw.png" -bordercolor black -fuzz 2% -trim +repage "${WORK}/window.png"
magick "${WORK}/window.png" -resize 1500x "${OUTPUT_DIR}/review-window.png"
# The close-up: the diff tab, where the steppers and the value chips are.
magick "${WORK}/window.png" -crop 600x400+270+60 +repage -resize 1200x \
	"${OUTPUT_DIR}/diff-tab.png"
# The second close-up: the VCS panel, the review's whole navigation surface.
# `deep_review/reading.md` walks it control by control — the `Review: <commit>`
# header, the trace-context selector, the Unified Diff toggle and the
# changed-file row with its coverage badge — and all four are unreadably small
# in the whole-window shot.
#
# The crop is derived from the captured window, not written as four fixed
# numbers, so a different CODETRACER_BOOK_SCREENSHOT_SCREEN (or a different
# trim) still frames the panel. The two axes are derived DIFFERENTLY, because
# the panel behaves differently on each:
#
#   * WIDTH is a fraction. The panel is a flex column of the layout, so it keeps
#     its share of a wider or narrower window.
#   * HEIGHT is in pixels. Its contents are fixed-height chrome — a header, a
#     dropdown, a totals line, a toggle and one row per changed file — so the
#     panel occupies the SAME number of pixels in a short window as in a tall
#     one, and a larger FRACTION of the short one. Taking 20% of the height
#     framed it at 2560x1200 and cut the changed-file row off at 1600x900,
#     which is the one control the article's coverage-badge paragraph needs.
#
# A here-string, not a process substitution: `identify -format` emits no
# trailing newline, so `read` would hit EOF, return non-zero and take the whole
# script down under `set -e` — after eight minutes of recording.
read -r WIN_W WIN_H <<<"$(magick identify -format '%w %h' "${WORK}/window.png")"
VCS_TOP=30 # skips the window's own title/toolbar strip, above the tab row
VCS_HEIGHT=280
magick "${WORK}/window.png" \
	-crop "$((WIN_W * 15 / 100))x${VCS_HEIGHT}+0+${VCS_TOP}" \
	+repage -resize 900x "${OUTPUT_DIR}/vcs-panel.png"

echo "capture-deep-review-screenshots: captured window ${WIN_W}x${WIN_H}; wrote"
echo "  ${OUTPUT_DIR}/review-window.png"
echo "  ${OUTPUT_DIR}/diff-tab.png"
echo "  ${OUTPUT_DIR}/vcs-panel.png"
