#!/usr/bin/env bash
# The DeepReview design-review capture harness (UD-0).
#
# WHAT THIS IS FOR, AND HOW IT RELATES TO THE DOCS CAPTURE.
#
# `scripts/docs/capture-deep-review-screenshots.sh` produces two frozen images
# for the book. This produces a MATRIX — named views x named viewport sizes x
# both themes — re-captured on every milestone of the unified-diff campaign so
# each one can be reviewed as it lands. The two share the expensive and fragile
# half (preflight, the stale-build refusal, `ct record`, `ct review collect`,
# Xvfb) through `scripts/docs/deep-review-capture-lib.sh`, and share nothing
# else:
#
#   * The docs fixture is FROZEN — `docs/book-isonim/content/usage_guide/
#     deep_review.md` quotes it line for line. This harness needs a corpus with
#     collapsed context regions, intra-line edits, a long line and a second
#     language, which is precisely what the book must not be given.
#   * The docs capture crops the root X window at fixed pixel offsets. That is
#     fine for two images and useless for a review loop, where every view is a
#     different UI state and a different region, both of which move when the
#     layout changes.
#
# So: a shared library, not a shared script and not a shared fixture. Extending
# the docs script instead would have meant rewriting published images on every
# milestone; starting over would have meant re-deriving the preflight checks
# that stop a stale build from being photographed.
#
# TARGETING. Any combination of --view / --size / --theme captures just that
# slice, reusing the already-collected corpus, so a single view re-captures in
# one app launch instead of a full re-record. A full regeneration (no filters)
# is the only thing that cleans the output directory, so stale PNGs from
# renamed or deleted views cannot survive it.
#
# Usage:
#   just capture-deepreview-design-views                 # everything
#   bash tools/visual-review/capture-deepreview-views.sh --list
#   bash tools/visual-review/capture-deepreview-views.sh --view diff-flow-values --size wide --theme dark
#   bash tools/visual-review/capture-deepreview-views.sh --view diff-flow-values --size wide \
#        --theme dark --sabotage hide-value-chips        # the calibration step

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CTDR_LABEL="capture-deepreview-views"
# shellcheck source=scripts/docs/deep-review-capture-lib.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/docs/deep-review-capture-lib.sh"

DRIVER="${SCRIPT_DIR}/capture-deepreview-views.mjs"
OUTPUT_DIR="${CODETRACER_DESIGN_REVIEW_DIR:-${SCRIPT_DIR}/screenshots/deepreview}"
CORPUS_DIR="${CODETRACER_DESIGN_REVIEW_CORPUS:-${SCRIPT_DIR}/deepreview-corpus}"
DISPLAY_NUM="${CODETRACER_DESIGN_REVIEW_DISPLAY:-:97}"
# Larger than the widest viewport in the matrix, so the window is never
# clamped by the screen and a `wide` capture is actually 1920 wide.
SCREEN_SIZE="${CODETRACER_DESIGN_REVIEW_SCREEN:-2560x1600x24}"

VIEWS=()
SIZES=()
THEMES=()
SABOTAGE=""
REBUILD_CORPUS=0

usage() {
	cat <<'EOF'
capture-deepreview-views.sh [options]

  --list                 print the view / size / theme / sabotage matrix and exit
  --view NAME            capture only NAME (repeatable)
  --size NAME            capture only at NAME (repeatable)
  --theme dark|light     capture only in that theme (repeatable)
  --sabotage KIND        deliberately break the capture; the calibration step.
                         Always writes to <out>/sabotage-KIND/, so it can never
                         overwrite a healthy capture.
  --rebuild-corpus       re-record and re-collect even if a corpus is cached
  --out DIR              output directory (default tools/visual-review/screenshots/deepreview)
  --corpus DIR           corpus cache directory
  -h, --help             this text

With no --view/--size/--theme filter and no --sabotage this is a FULL
REGENERATION: the output directory is emptied first, so stale captures from
renamed or deleted views cannot survive.
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--list)
		exec node "${DRIVER}" --list
		;;
	--view)
		[[ $# -ge 2 ]] || ctdr_die "--view needs a value"
		VIEWS+=("$2")
		shift 2
		;;
	--size)
		[[ $# -ge 2 ]] || ctdr_die "--size needs a value"
		SIZES+=("$2")
		shift 2
		;;
	--theme)
		[[ $# -ge 2 ]] || ctdr_die "--theme needs a value"
		THEMES+=("$2")
		shift 2
		;;
	--sabotage)
		[[ $# -ge 2 ]] || ctdr_die "--sabotage needs a value"
		SABOTAGE="$2"
		shift 2
		;;
	--out)
		[[ $# -ge 2 ]] || ctdr_die "--out needs a value"
		OUTPUT_DIR="$2"
		shift 2
		;;
	--corpus)
		[[ $# -ge 2 ]] || ctdr_die "--corpus needs a value"
		CORPUS_DIR="$2"
		shift 2
		;;
	--rebuild-corpus)
		REBUILD_CORPUS=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		usage >&2
		ctdr_die "unknown option '$1'"
		;;
	esac
done

# A full regeneration is the only run that may delete anything.
FULL_REGEN=0
if [[ ${#VIEWS[@]} -eq 0 && ${#SIZES[@]} -eq 0 && ${#THEMES[@]} -eq 0 && -z ${SABOTAGE} ]]; then
	FULL_REGEN=1
fi
# The DEFAULT theme set is every theme the product can currently paint, read
# from the driver's matrix rather than hard-coded here. `light` is in the
# matrix and is not in this set: CodeTracer has no light palette for the
# Electron surface yet (the driver carries the measurement and the reason), so
# a run of `--theme light` launches, fails the paint assertion, and says why.
# Asking for it explicitly is how you check whether that is still true.
if [[ ${#THEMES[@]} -eq 0 ]]; then
	mapfile -t THEMES < <(node "${DRIVER}" --list |
		awk -F'\t' '$1 == "theme" && $4 == "" { print $2 }')
	[[ ${#THEMES[@]} -gt 0 ]] ||
		ctdr_die "no theme in the matrix is currently capturable; see '${DRIVER} --list'"
fi

# --- preflight ---------------------------------------------------------------
ctdr_require_cmd node "install the CodeTracer dev shell, which provides node and Playwright."
[[ -f ${DRIVER} ]] || ctdr_die "missing the capture driver at '${DRIVER}'"
ctdr_resolve_ct "${REPO_ROOT}"
ctdr_require_runtime_config "${REPO_ROOT}"
# Both themes are part of the matrix, so BOTH stylesheets must exist and be
# current. A theme whose CSS was never built renders as unstyled HTML, which a
# reviewer would rate as a catastrophic design failure rather than report as a
# missing build artefact — exactly the confusion this harness exists to remove.
ctdr_require_fresh_build "${REPO_ROOT}" default_white_theme_electron.css
ctdr_require_display_tools

WORK="$(mktemp -d -t ct-deepreview-design-XXXXXX)"
cleanup() {
	pkill -f "review ${CORPUS_DIR}/review" 2>/dev/null || true
	[[ -n ${CTDR_XVFB_PID:-} ]] && kill "${CTDR_XVFB_PID}" 2>/dev/null || true
	rm -rf "${WORK}"
}
trap cleanup EXIT

# --- the corpus ---------------------------------------------------------------
#
# A review surface needs a review dataset, and this one is real: two commits of
# a real repository, recorded twice with the shipping `ct record`, collected
# with the shipping `ct review collect`. It is cached between runs because
# recording is the slow half and re-capturing a single view must not pay for
# it. The cache is keyed on a fingerprint of THIS script, so editing the corpus
# below invalidates it rather than silently outliving its own definition.

corpus_fingerprint() {
	sha256sum "${BASH_SOURCE[0]}" | cut -d' ' -f1
}

# build_corpus <dir>
#
# The corpus is designed backwards from the views it has to support:
#
#   * `scale`'s parameter is renamed, so a hunk exists whose changed lines
#     differ only in one word     -> view `diff-intraline`
#   * the two changed regions are separated by a wide unchanged region, so the
#     diff collapses in the middle -> views `diff-collapsed-context` /
#                                       `diff-expanded-context`
#   * `main` runs a loop whose per-iteration value changes, and it is recorded,
#     so inline values exist       -> view `diff-flow-values`
#   * the assert carries a long message, on a changed line
#                                  -> view `diff-long-line`
#   * a second, non-Noir file is changed in the same commit
#                                  -> view `diff-other-language`
#
# `expected` is computed from `x` rather than hard-coded, so the SECOND
# recording (a different `Prover.toml`) still satisfies the assertion; a
# recording that aborts on a failed constraint would leave the review with one
# trace context and no invocation stepper.
build_corpus() {
	local dir="$1" repo="$1/repo"
	rm -rf "${dir}"
	mkdir -p "${repo}/src" "${repo}/tools"

	cat >"${repo}/Nargo.toml" <<'EOF'
[package]
name = "review_corpus"
type = "bin"
authors = [""]

[dependencies]
EOF
	printf 'x = "5"\n' >"${repo}/Prover.toml"

	cat >"${repo}/src/main.nr" <<'EOF'
// The review corpus the design harness photographs.
//
// It is deliberately longer than the change it carries: a unified diff can
// only show a collapsed context region if there is an unchanged region wide
// enough to collapse.

fn scale(index: Field, factor: Field) -> Field {
    index * factor
}

// --- unchanged padding ------------------------------------------------------
// Everything between the two changed regions stays the same across the two
// commits, which is what makes the middle of the diff collapse.

fn identity(value: Field) -> Field {
    value
}

fn twice(value: Field) -> Field {
    value + value
}

fn add(left: Field, right: Field) -> Field {
    left + right
}

fn is_positive(value: Field) -> bool {
    value != 0
}

fn combine(left: Field, right: Field) -> Field {
    add(identity(left), identity(right))
}

fn checked(value: Field) -> Field {
    assert(is_positive(twice(value + 1)));
    value
}

// --- end of padding ---------------------------------------------------------

fn main(x: Field) {
    let mut sum: Field = 0;
    for _i in 0..4 {
        sum = sum + x;
    }
    let final_result = combine(checked(sum), 0);
    let expected = x + x + x + x;
    assert(final_result == expected);
}
EOF

	cat >"${repo}/tools/report.py" <<'EOF'
"""Human-readable summary of a review_corpus run.

Not Noir. It is here so the review surface can be shown to tokenize the file
it is actually looking at, rather than to have been tuned to one language.
"""

TITLE = "sum report"


def format_row(index: int, value: int) -> str:
    """Render one loop iteration as a single line."""
    return f"  iteration {index}: contribution = {value}"


def report(x: int, iterations: int = 4) -> str:
    lines = [TITLE]
    total = 0
    for i in range(iterations):
        total += x
        lines.append(format_row(i, x))
    lines.append(f"total = {total}")
    return "\n".join(lines)
EOF

	ctdr_git_init "${repo}"
	ctdr_git_commit "${repo}" "base: sum x four times"

	cat >"${repo}/src/main.nr" <<'EOF'
// The review corpus the design harness photographs.
//
// It is deliberately longer than the change it carries: a unified diff can
// only show a collapsed context region if there is an unchanged region wide
// enough to collapse.

fn scale(index: Field, multiplier: Field) -> Field {
    index * multiplier
}

// --- unchanged padding ------------------------------------------------------
// Everything between the two changed regions stays the same across the two
// commits, which is what makes the middle of the diff collapse.

fn identity(value: Field) -> Field {
    value
}

fn twice(value: Field) -> Field {
    value + value
}

fn add(left: Field, right: Field) -> Field {
    left + right
}

fn is_positive(value: Field) -> bool {
    value != 0
}

fn combine(left: Field, right: Field) -> Field {
    add(identity(left), identity(right))
}

fn checked(value: Field) -> Field {
    assert(is_positive(twice(value + 1)));
    value
}

// --- end of padding ---------------------------------------------------------

fn main(x: Field) {
    let mut total: Field = 0;
    for i in 0..4 {
        let contribution = scale(i as Field, x);
        total = total + contribution;
    }
    let final_result = combine(checked(total), 0);
    let expected = scale(1, x) + scale(2, x) + scale(3, x);
    assert(final_result == expected, "the scaled sum must equal x times the triangular number of the loop bound, and this message is deliberately long so that the harness has a horizontal-overflow view to review");
}
EOF

	cat >"${repo}/tools/report.py" <<'EOF'
"""Human-readable summary of a review_corpus run.

Not Noir. It is here so the review surface can be shown to tokenize the file
it is actually looking at, rather than to have been tuned to one language.
"""

TITLE = "scaled sum report"


def format_row(index: int, value: int) -> str:
    """Render one loop iteration as a single line."""
    return f"  iteration {index}: contribution = {value} (scaled by the loop index, which is the whole point of the change under review)"


def report(x: int, iterations: int = 4) -> str:
    lines = [TITLE]
    total = 0
    for i in range(iterations):
        total += i * x
        lines.append(format_row(i, i * x))
    lines.append(f"total = {total}")
    return "\n".join(lines)
EOF

	ctdr_git_commit "${repo}" "scale each term by the loop index"

	echo "${CTDR_LABEL}: recording run-1 and run-2"
	ctdr_record "${repo}" "${dir}/runs/run-1" "${dir}/record-1.log"
	printf 'x = "7"\n' >"${repo}/Prover.toml"
	ctdr_record "${repo}" "${dir}/runs/run-2" "${dir}/record-2.log"
	git -C "${repo}" checkout -- Prover.toml

	echo "${CTDR_LABEL}: collecting the review dataset"
	ctdr_collect "${repo}" "${dir}/runs" "${dir}/review"

	corpus_fingerprint >"${dir}/.fingerprint"
}

corpus_is_current() {
	local dir="$1"
	[[ -f "${dir}/review/review.json" ]] || return 1
	[[ -f "${dir}/.fingerprint" ]] || return 1
	[[ "$(cat "${dir}/.fingerprint")" == "$(corpus_fingerprint)" ]]
}

if [[ ${REBUILD_CORPUS} -eq 1 ]] || ! corpus_is_current "${CORPUS_DIR}"; then
	ctdr_require_recording_tools
	build_corpus "${CORPUS_DIR}"
else
	echo "${CTDR_LABEL}: reusing the corpus at ${CORPUS_DIR} (pass --rebuild-corpus to re-record)"
fi

# --- output directory ---------------------------------------------------------
#
# A sabotaged capture always goes to its own subdirectory. The file name is
# (view, size, theme) and says nothing about the damage, so writing it beside
# the healthy captures would REPLACE the healthy capture of that view with a
# deliberately broken one that is indistinguishable from it on disk — and the
# next reviewer sent to that path would report the sabotage as a product
# defect. Calibration is meant to be re-run whenever the brief changes, so it
# has to be safe to repeat, not safe once. Unconditional rather than "unless
# --out was given", so the invariant needs no caveat: no sabotaged PNG ever
# shares a path with a healthy one.
if [[ -n ${SABOTAGE} ]]; then
	OUTPUT_DIR="${OUTPUT_DIR}/sabotage-${SABOTAGE}"
fi
if [[ ${FULL_REGEN} -eq 1 && -d ${OUTPUT_DIR} ]]; then
	echo "${CTDR_LABEL}: full regeneration — clearing ${OUTPUT_DIR}"
	rm -rf "${OUTPUT_DIR}"
fi
mkdir -p "${OUTPUT_DIR}"

# --- the display ---------------------------------------------------------------
ctdr_start_xvfb "${DISPLAY_NUM}" "${SCREEN_SIZE}" "${WORK}/xvfb.log"

# --- capture, one theme at a time ----------------------------------------------
#
# The theme is chosen the only way CodeTracer supports choosing it: a
# `.config.yaml` carrying `theme:`, discovered through XDG_CONFIG_HOME. Each
# theme gets its own throwaway config home, so a run also starts from the
# layout a fresh install gets rather than whatever this machine has saved.
# Read from the driver's matrix rather than restated here: a second copy of the
# theme table is a second thing to forget to update.
MATRIX="$(node "${DRIVER}" --list)" || ctdr_die "could not read the matrix from ${DRIVER}"

for theme in "${THEMES[@]}"; do
	value="$(printf '%s\n' "${MATRIX}" |
		awk -F'\t' -v t="${theme}" '$1 == "theme" && $2 == t { print $3 }')"
	[[ -n ${value} ]] || ctdr_die "unknown theme '${theme}'; known: $(printf '%s\n' "${MATRIX}" |
		awk -F'\t' '$1 == "theme" { print $2 }' | paste -sd' ' -)"
	xdg="${WORK}/xdg-${theme}"
	mkdir -p "${xdg}/codetracer"
	sed "s|^theme:.*|theme: \"${value}\"|" \
		"${REPO_ROOT}/src/config/default_config.yaml" >"${xdg}/codetracer/.config.yaml"
	grep -q "theme: \"${value}\"" "${xdg}/codetracer/.config.yaml" ||
		ctdr_die "could not set theme '${value}' in the generated config; src/config/default_config.yaml has no 'theme:' line"

	args=(--ct "${CTDR_CT}" --dataset "${CORPUS_DIR}/review"
		--out "${OUTPUT_DIR}" --xdg "${xdg}" --theme "${theme}")
	for v in ${VIEWS[@]+"${VIEWS[@]}"}; do args+=(--view "${v}"); done
	for s in ${SIZES[@]+"${SIZES[@]}"}; do args+=(--size "${s}"); done
	[[ -n ${SABOTAGE} ]] && args+=(--sabotage "${SABOTAGE}")

	echo "${CTDR_LABEL}: capturing the ${theme} theme"
	DISPLAY="${DISPLAY_NUM}" node "${DRIVER}" "${args[@]}"
done

echo "${CTDR_LABEL}: screenshots are in ${OUTPUT_DIR}"
echo "${CTDR_LABEL}: review one with"
if [[ -n ${SABOTAGE} ]]; then
	# The prompt emitter reads the same env var the capture does, so a
	# calibration is reviewed by pointing it at the sabotage directory rather
	# than by teaching it a second naming scheme.
	echo "  CODETRACER_DESIGN_REVIEW_DIR=${OUTPUT_DIR} \\"
	echo "    bash ${SCRIPT_DIR}/deepreview-review-prompt.sh --view <view> --size <size> --theme <theme>"
else
	echo "  bash ${SCRIPT_DIR}/deepreview-review-prompt.sh --view <view> --size <size> --theme <theme>"
fi
