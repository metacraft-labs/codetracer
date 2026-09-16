#!/usr/bin/env bash
# Emit the review prompt for one captured DeepReview view.
#
# The methodology's rule is that screenshots are NEVER read into the driving
# agent's context: each review runs in a disposable sub-agent that views the
# image in its own context window and returns a few hundred words of text. This
# script is the seam. It prints the prompt; the driving agent spawns a
# sub-agent with it and keeps only the text that comes back.
#
# It is a separate script, and not a `--print-prompt` flag on the capture, for
# one reason: a review is re-run far more often than a capture. Re-reviewing a
# view — a fresh reviewer for the final round, as UD-4 requires — must not
# re-photograph it, or the two would no longer be the same image.
#
# What it refuses to do:
#   * name a view, size or theme the harness does not define — a typo would
#     otherwise produce a prompt pointing at a file that will never exist;
#   * emit a prompt for a screenshot that is not on disk — an agent sent to
#     look at a missing file reports a missing file, which is indistinguishable
#     in the driving context from a view that renders nothing;
#   * emit a prompt for a screenshot that is OLDER THAN THE BUILD IT CLAIMS TO
#     SHOW. The producer asks that question (`capture-deepreview-views.sh` calls
#     `ctdr_resolve_ct` + `ctdr_require_fresh_build` before it photographs
#     anything); this consumer asked nothing, and only a FULL regeneration
#     clears the screenshots directory. So a targeted re-capture — the whole
#     point of the harness's targeting — leaves every other view's PNG behind at
#     its old mtime, and the next review round packages those for a reviewer who
#     rates them as the current design. Existence was standing in for freshness
#     at the exact seam where a rating is produced.
#
# Usage:
#   bash tools/visual-review/deepreview-review-prompt.sh \
#        --view diff-flow-values --size wide --theme dark \
#        [--changed "UD-1 replaced the plaintext model with a diff editor"]

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# Read by the sourced library below, which prefixes every diagnostic with it.
# shellcheck disable=SC2034
CTDR_LABEL="deepreview-review-prompt"
# shellcheck source=scripts/docs/deep-review-capture-lib.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/docs/deep-review-capture-lib.sh"

DRIVER="${SCRIPT_DIR}/capture-deepreview-views.mjs"
BRIEF="${SCRIPT_DIR}/deepreview-diff-brief.md"
SHOTS="${CODETRACER_DESIGN_REVIEW_DIR:-${SCRIPT_DIR}/screenshots/deepreview}"

VIEW=""
SIZE=""
THEME=""
CHANGED=""

die() {
	echo "deepreview-review-prompt: $*" >&2
	exit 1
}

usage() {
	cat <<'EOF'
deepreview-review-prompt.sh --view NAME --size NAME --theme NAME [--changed TEXT]

Prints the prompt for a disposable review sub-agent. Screenshots are never read
into the driving context; the sub-agent returns text.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--view)
		[[ $# -ge 2 ]] || die "--view needs a value"
		VIEW="$2"
		shift 2
		;;
	--size)
		[[ $# -ge 2 ]] || die "--size needs a value"
		SIZE="$2"
		shift 2
		;;
	--theme)
		[[ $# -ge 2 ]] || die "--theme needs a value"
		THEME="$2"
		shift 2
		;;
	--changed)
		[[ $# -ge 2 ]] || die "--changed needs a value"
		CHANGED="$2"
		shift 2
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		die "unknown option '$1'"
		;;
	esac
done

[[ -n ${VIEW} ]] || die "--view is required"
[[ -n ${SIZE} ]] || die "--size is required"
[[ -n ${THEME} ]] || die "--theme is required"
[[ -f ${BRIEF} ]] || die "missing the design brief at '${BRIEF}'"

command -v node >/dev/null 2>&1 ||
	die "missing 'node' — it is how the matrix is read from ${DRIVER}"
MATRIX="$(node "${DRIVER}" --list)" || die "could not read the matrix from ${DRIVER}"

known() {
	local kind="$1" name="$2"
	printf '%s\n' "${MATRIX}" | awk -F'\t' -v k="${kind}" -v n="${name}" \
		'$1 == k && $2 == n { found = 1 } END { exit found ? 0 : 1 }'
}
names_of() {
	printf '%s\n' "${MATRIX}" | awk -F'\t' -v k="$1" '$1 == k { print $2 }' | paste -sd' ' -
}

known view "${VIEW}" || die "unknown view '${VIEW}'; known: $(names_of view)"
known size "${SIZE}" || die "unknown size '${SIZE}'; known: $(names_of size)"
known theme "${THEME}" || die "unknown theme '${THEME}'; known: $(names_of theme)"

SHOT="${SHOTS}/${VIEW}--${SIZE}--${THEME}.png"
[[ -f ${SHOT} ]] || die "no screenshot at '${SHOT}'. Capture it first with: bash ${SCRIPT_DIR}/capture-deepreview-views.sh --view ${VIEW} --size ${SIZE} --theme ${THEME}"

# ...AND IT MUST BE A PICTURE OF THE BUILD THAT IS ON DISK NOW.
#
# The same two artefacts the producer checks, asked in the other direction: the
# capture refuses to photograph a build older than its sources, and this refuses
# to review a photograph older than the build. Both stylesheets are named
# because the matrix carries both themes, exactly as in
# `capture-deepreview-views.sh` — a theme whose CSS was never built must fail
# here by name rather than reach a reviewer as an unstyled window.
#
# There is no "if the build tree is missing, skip" branch on purpose. A
# screenshot in this directory was produced by a run that REQUIRED a build tree,
# so its absence means the thing this image documents is gone, and the honest
# answer is a refusal rather than a prompt nobody can reproduce.
ctdr_resolve_ct "${REPO_ROOT}"
ctdr_require_fresh_build "${REPO_ROOT}" default_white_theme_electron.css
ctdr_require_artefact_not_stale "capture" \
	"the ${VIEW}--${SIZE}--${THEME} screenshot" "${SHOT}" \
	"A reviewer would rate a CodeTracer that no longer exists, and the rating would be filed against the current one. Re-capture it with: bash ${SCRIPT_DIR}/capture-deepreview-views.sh --view ${VIEW} --size ${SIZE} --theme ${THEME}" \
	"${CTDR_BUILD_ROOT}/ui.js" \
	"${CTDR_BUILD_ROOT}/frontend/styles/default_dark_theme_electron.css" \
	"${CTDR_BUILD_ROOT}/frontend/styles/default_white_theme_electron.css"

DESCRIPTION="$(printf '%s\n' "${MATRIX}" |
	awk -F'\t' -v n="${VIEW}" '$1 == "view" && $2 == n { print $4 }')"
GEOMETRY="$(printf '%s\n' "${MATRIX}" |
	awk -F'\t' -v n="${SIZE}" '$1 == "size" && $2 == n { print $3 }')"

# Every view but `review-shell` is captured as a CLIP of the region it is
# about. Without this said out loud, a reviewer measures the PNG, finds it far
# narrower than the viewport it is labelled with, and reports the mismatch as
# evidence of a broken capture — which is precisely the false positive the
# expected-elements section exists to prevent, arriving by another door. The
# first calibration round produced exactly that finding.
if [[ ${VIEW} == "review-shell" ]]; then
	FRAMING="The image is the WHOLE application window, ${GEOMETRY} content pixels."
else
	FRAMING="The image is a CLIP of the region this view is about, taken from a window
whose content area was ${GEOMETRY}. Its pixel dimensions are therefore smaller
than the viewport, and that is expected — do not read it as a cropped or
undersized window. Judge only what is inside the frame; content cut off by the
frame edge is the clip, not the product. Content cut off by a PANE edge that
you can see inside the frame is the product, and is worth reporting."
fi

cat <<EOF
Read the design brief at ${BRIEF}, then view the screenshot at ${SHOT}.

The screenshot is the \`${VIEW}\` view at the \`${SIZE}\` viewport in the
\`${THEME}\` theme. ${DESCRIPTION}

${FRAMING}

The brief's § "What is Expected on the Screenshot" has a block for
\`${VIEW}\`. Verify those elements FIRST: your first job is to establish that
the capture shows the state it claims to, not to evaluate its aesthetics. If an
expected element is missing, distorted, or replaced by a placeholder, say so as
your first finding and rate the screenshot 1-3 out of 10 no matter how polished
the rest of it looks. Only if every expected element is present do you go on to
rate the design.
${CHANGED:+
This iteration changed: ${CHANGED}
Say whether that change is visible and whether it landed well.
}
Report in under 250 words, in this order:
1. "Expected elements: present" — or "missing: <what>" / "replaced by: <what>".
2. One sentence of overall impression.
3. Specific issues, each with a location ("hunk header: 6px of padding on the
   left, 14px on the right").
4. The one or two highest-priority fixes.
5. A rating out of 10.

Return text only. Do not write files, do not attach the image, and do not
include the screenshot in your reply.
EOF
