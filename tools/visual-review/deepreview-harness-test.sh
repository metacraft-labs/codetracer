#!/usr/bin/env bash
#
# deepreview-harness-test.sh — the contract suite for the DeepReview design
# review harness (UD-0).
#
# WHY IT EXISTS. The harness's whole value is that a rating it produces can be
# trusted, and that trust rests on three properties that are easy to break
# silently:
#
#   1. The matrix covers what the campaign changes. A view quietly dropped
#      from the driver would simply stop being reviewed, and nothing would say
#      so — the loop would keep reporting good ratings for the views that
#      remained.
#   2. The brief has an expected-elements block for every view. The
#      methodology calls this non-negotiable: without it a low rating cannot be
#      told apart from a broken capture. A view added to the driver and not to
#      the brief reintroduces exactly that ambiguity.
#   3. Targeting is real. "Re-capture one view without a full rebuild" is what
#      makes the loop usable; if a targeted run secretly re-recorded, or if it
#      deleted the other views' captures, the loop would be unusable in a way
#      that only shows up after a 10-minute wait.
#
# WHAT IT DOES NOT MOCK. The matrix and brief contracts run against the real
# driver and the real brief. The orchestration contracts stub `ct`, `Xvfb`,
# `xdotool` and `node` on PATH and assert against a TRACE FILE of what was
# actually invoked — not against a grep of the script's source, which would
# only prove the script contains a string. Electron is never launched here;
# that it launches and produces images is verified by running the harness for
# real, which no unit-shaped test can stand in for.
#
# Run directly:  bash tools/visual-review/deepreview-harness-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

CAPTURE="${SCRIPT_DIR}/capture-deepreview-views.sh"
DRIVER="${SCRIPT_DIR}/capture-deepreview-views.mjs"
PROMPT="${SCRIPT_DIR}/deepreview-review-prompt.sh"
BRIEF="${SCRIPT_DIR}/deepreview-diff-brief.md"
STYLES_TUPFILE="${REPO_ROOT}/src/frontend/styles/Tupfile"

# Every contract this suite claims to check. A suite that silently runs fewer
# assertions than it advertises is a suite that stops protecting anything, so
# the count is asserted at the end and has to be changed deliberately.
EXPECTED_ASSERTIONS=66

ASSERTIONS=0
FAILURES=0

ok() {
	ASSERTIONS=$((ASSERTIONS + 1))
	printf '  ok   %s\n' "$1"
}

bad() {
	ASSERTIONS=$((ASSERTIONS + 1))
	FAILURES=$((FAILURES + 1))
	printf '  FAIL %s\n' "$1"
	shift
	local line
	for line in "$@"; do printf '         %s\n' "${line}"; done
}

section() { printf '\n== %s\n' "$1"; }

assert_contains() {
	local haystack="$1" needle="$2" desc="$3"
	if [[ ${haystack} == *"${needle}"* ]]; then
		ok "${desc}"
	else
		bad "${desc}" "expected to find: ${needle}" "in: ${haystack:0:600}"
	fi
}

assert_not_contains() {
	local haystack="$1" needle="$2" desc="$3"
	if [[ ${haystack} != *"${needle}"* ]]; then
		ok "${desc}"
	else
		bad "${desc}" "did not expect to find: ${needle}"
	fi
}

assert_file_exists() {
	if [[ -f $1 ]]; then ok "$2"; else bad "$2" "no such file: $1"; fi
}

assert_file_absent() {
	if [[ ! -e $1 ]]; then ok "$2"; else bad "$2" "unexpectedly present: $1"; fi
}

# run_expect_failure <desc> <fragment> -- <command...>
run_expect_failure() {
	local desc="$1" fragment="$2" out status
	shift 3 # desc, fragment, --
	out="$("$@" 2>&1)"
	status=$?
	if [[ ${status} -eq 0 ]]; then
		bad "${desc}" "the command unexpectedly succeeded" "output: ${out:0:400}"
		return
	fi
	assert_contains "${out}" "${fragment}" "${desc}"
}

TEST_ROOT="$(mktemp -d -t ct-deepreview-harness-test-XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

for required in "${CAPTURE}" "${DRIVER}" "${PROMPT}" "${BRIEF}"; do
	if [[ ! -f ${required} ]]; then
		echo "deepreview-harness-test: missing '${required}' — the harness is not in place" >&2
		exit 3
	fi
done
command -v node >/dev/null 2>&1 || {
	echo "deepreview-harness-test: missing 'node'; the matrix cannot be read" >&2
	exit 3
}

# ---------------------------------------------------------------------------
section "--list needs no npm packages"
#
# `--list` prints static data out of the driver, and three scripts (the shell
# wrapper, the review-prompt emitter and THIS SUITE) learn the matrix from it.
# It used to be gated behind a top-level `import { _electron } from
# "playwright"`, so it needed an npm package no CI lane installs: `ci-verdict`
# runs this suite on a stock runner and `lint-bash` runs it inside the dev
# shell, and neither has a repo-root `node_modules`. Both failed with
#
#     Error [ERR_MODULE_NOT_FOUND]: Cannot find package 'playwright'
#       imported from .../tools/visual-review/capture-deepreview-views.mjs
#
# in every completed `dev` run for three weeks -- and the suite exited 3 on its
# FIRST assertion, so its other 65 contracts never ran either.
#
# THIS CASE MUST RUN SOMEWHERE WITH NO ANCESTOR node_modules. Node resolves a
# bare specifier by walking the filesystem upward, so a checkout that sits
# under a workspace with its own `node_modules/playwright` -- which is exactly
# the layout this repo is developed in -- resolves the import and passes while
# CI fails. Copying the driver into a temporary directory is what makes the
# case honest, and the guard below refuses to pretend otherwise if even that
# location turns out to be contaminated.
# ---------------------------------------------------------------------------

_probe_dir="${TEST_ROOT}/no-node-modules/tools/visual-review"
mkdir -p "${_probe_dir}"
cp "${DRIVER}" "${_probe_dir}/"
_contaminated=""
_d="${_probe_dir}"
while [[ ${_d} != "/" ]]; do
	if [[ -e ${_d}/node_modules/playwright ]]; then _contaminated="${_d}/node_modules"; fi
	_d="$(dirname "${_d}")"
done
[[ -e /node_modules/playwright ]] && _contaminated="/node_modules"

if [[ -n ${_contaminated} ]]; then
	# Loud, and a FAILURE rather than a silent pass: a green here would claim
	# the driver needs no npm packages while proving the opposite.
	bad "--list runs with no node_modules anywhere above it" \
		"cannot test: ${_contaminated}/playwright is visible from the probe directory," \
		"so node would resolve the import regardless of how the driver is written." \
		"Run this suite from a path with no ancestor node_modules."
else
	if _probe_out="$(node "${_probe_dir}/$(basename "${DRIVER}")" --list 2>&1)"; then
		assert_contains "${_probe_out}" "review-shell" \
			"--list runs with no node_modules anywhere above it"
	else
		bad "--list runs with no node_modules anywhere above it" \
			"the driver imported an npm package before it had anything to launch;" \
			"this is what fails ci-verdict and lint-bash on every run." \
			"output: ${_probe_out:0:400}"
	fi
fi
unset _probe_dir _contaminated _d _probe_out

# ---------------------------------------------------------------------------
section "the matrix covers what the campaign changes"
# ---------------------------------------------------------------------------

if ! MATRIX="$(node "${DRIVER}" --list 2>&1)"; then
	echo "deepreview-harness-test: '${DRIVER} --list' failed: ${MATRIX}" >&2
	exit 3
fi

views_of() { printf '%s\n' "${MATRIX}" | awk -F'\t' '$1 == "view" { print $2 }'; }
VIEW_NAMES="$(views_of)"

# UD-0 names the states this campaign changes; each needs a view or it will
# never be looked at.
for required_view in \
	review-shell \
	diff-intraline \
	diff-collapsed-context \
	diff-expanded-context \
	diff-flow-values \
	diff-long-line \
	diff-other-language; do
	if grep -qx "${required_view}" <<<"${VIEW_NAMES}"; then
		ok "the matrix defines the '${required_view}' view"
	else
		bad "the matrix defines the '${required_view}' view" "known views: $(printf '%s' "${VIEW_NAMES}" | paste -sd' ' -)"
	fi
done

# The non-Noir view is only meaningful if it actually points at a non-Noir
# file; a view named `diff-other-language` over `main.nr` would pass the check
# above and prove nothing.
OTHER_FILE="$(printf '%s\n' "${MATRIX}" | awk -F'\t' '$1 == "view" && $2 == "diff-other-language" { print $3 }')"
if [[ -n ${OTHER_FILE} && ${OTHER_FILE} != *.nr ]]; then
	ok "the non-Noir view targets a non-Noir file (${OTHER_FILE})"
else
	bad "the non-Noir view targets a non-Noir file" "it targets '${OTHER_FILE}'"
fi

SIZE_COUNT="$(printf '%s\n' "${MATRIX}" | awk -F'\t' '$1 == "size"' | wc -l)"
if [[ ${SIZE_COUNT} -ge 3 ]]; then
	ok "the matrix defines at least three viewport sizes (${SIZE_COUNT})"
else
	bad "the matrix defines at least three viewport sizes" "found ${SIZE_COUNT}"
fi

WIDEST="$(printf '%s\n' "${MATRIX}" | awk -F'\t' '$1 == "size" { split($3, d, "x"); if (d[1] > w) w = d[1] } END { print w + 0 }')"
if [[ ${WIDEST} -ge 1920 ]]; then
	ok "the widest viewport is at least 1920px (${WIDEST})"
else
	bad "the widest viewport is at least 1920px" "widest is ${WIDEST}"
fi

assert_contains "${MATRIX}" $'theme\tdark\tdefault_dark' "the matrix defines the dark theme"
assert_contains "${MATRIX}" $'theme\tlight\tdefault_white' "the matrix defines the light theme"

# "Both themes" is only real if both stylesheets are actually built. Until the
# light Electron sheet existed, `theme: default_white` pointed the window's
# `#theme` link at a file that was not there and the app rendered unstyled.
TUPFILE_TEXT="$(cat "${STYLES_TUPFILE}")"
assert_contains "${TUPFILE_TEXT}" "default_dark_theme_electron.css" \
	"the styles Tupfile builds the dark Electron stylesheet"
assert_contains "${TUPFILE_TEXT}" "default_white_theme_electron.css" \
	"the styles Tupfile builds the light Electron stylesheet"

# The calibration instrument the methodology's checklist item 7 requires.
assert_contains "${MATRIX}" $'sabotage\thide-value-chips' \
	"the driver offers the 'remove the value chips' calibration"
assert_contains "${MATRIX}" $'sabotage\twrong-file' \
	"the driver offers the 'wrong file' calibration"

# ---------------------------------------------------------------------------
section "the brief has an expected-elements block for every view"
# ---------------------------------------------------------------------------

BRIEF_TEXT="$(cat "${BRIEF}")"
assert_contains "${BRIEF_TEXT}" "## What is Expected on the Screenshot" \
	"the brief has the mandatory expected-elements section"

missing_blocks=()
vague_blocks=()
while IFS= read -r view; do
	[[ -n ${view} ]] || continue
	if ! grep -qF "### View: \`${view}\`" "${BRIEF}"; then
		missing_blocks+=("${view}")
		continue
	fi
	# A block that only describes the view is not sharp enough to let a
	# reviewer call a break a break; each one has to say what "missing" looks
	# like. This is the guard that keeps the calibration honest as views are
	# added later.
	block="$(awk -v v="### View: \`${view}\`" '
		$0 == v { inblock = 1; next }
		/^### View: / { inblock = 0 }
		/^---$/ { inblock = 0 }
		inblock { print }
	' "${BRIEF}")"
	if [[ ${block} != *"Missing-element examples:"* ]]; then
		vague_blocks+=("${view}")
	fi
done <<<"${VIEW_NAMES}"

if [[ ${#missing_blocks[@]} -eq 0 ]]; then
	ok "every view in the matrix has a '### View:' block in the brief"
else
	bad "every view in the matrix has a '### View:' block in the brief" \
		"no block for: ${missing_blocks[*]}"
fi
if [[ ${#vague_blocks[@]} -eq 0 ]]; then
	ok "every view's block names what a missing element would look like"
else
	bad "every view's block names what a missing element would look like" \
		"no 'Missing-element examples:' for: ${vague_blocks[*]}"
fi

# The brief must not let a reviewer confuse a campaign target with a broken
# capture, or every UD-0 capture would be rated as broken.
assert_contains "${BRIEF_TEXT}" "findings, not capture failures" \
	"the brief separates known campaign gaps from capture failures"

# ---------------------------------------------------------------------------
section "each size is captured from the landing state, not the last size's"
# ---------------------------------------------------------------------------

# One Electron launch serves all three sizes of a view, which is what makes a
# targeted re-capture cost 12 seconds. The cost of that is that a view's
# `setup` MUTATES the surface, and the mutation used to be carried into the
# next size on the same page. Two views were silently size-dependent because of
# it: `diff-expanded-context` refused at `laptop` with "the boundary hid [0,0]
# lines before and [0,0] after" — it had expanded that boundary at `wide` — and
# `diff-flow-values` timed out at `narrow` waiting for a chip whose content
# widget was `visibility: hidden`, because the editor was still scrolled where
# `laptop` had left it.
#
# `resetDiffTabs` is driven here against a STUB page rather than grepped for,
# so a reset that stopped closing tabs, or that stopped noticing it had failed,
# fails this suite in a second instead of a 21-capture regeneration in ten
# minutes. Whether it closes REAL tabs is settled by running the harness for
# real, which no stub can stand in for.
# shellcheck disable=SC2016  # deliberate: this is JavaScript source, and the
# `${...}` inside it is a JS template literal that the shell must NOT expand.
RESET_HARNESS='
import { resetDiffTabs } from "DRIVER_PATH";

// The smallest Playwright surface `resetDiffTabs` uses. `tabs` is re-derived
// on every call, exactly as a real locator is, so a reset holding one stale
// handle across the loop shows up as a hang rather than as a pass.
function stubPage(tabTitles, { stubborn = false } = {}) {
  const clicked = [];
  const state = { titles: [...tabTitles] };
  const filtered = (re) => ({
    count: async () => state.titles.filter((t) => re.test(t)).length,
    first: () => ({
      locator: (sel) => ({
        click: async () => {
          if (sel !== ".lm_close_tab") throw new Error("closed the wrong thing: " + sel);
          const i = state.titles.findIndex((t) => re.test(t));
          clicked.push(state.titles[i]);
          if (!stubborn) state.titles.splice(i, 1);
        },
      }),
    }),
  });
  return {
    clicked,
    state,
    page: {
      locator: (sel) => {
        if (sel !== ".lm_tab") throw new Error("queried the wrong thing: " + sel);
        return { filter: ({ hasText }) => filtered(hasText) };
      },
      waitForTimeout: async () => {},
    },
  };
}

const results = [];

{
  const s = stubPage(["Diff: main.nr", "Program", "Diff: report.py"]);
  await resetDiffTabs({ page: s.page });
  results.push("closed=" + s.clicked.length);
  results.push("left=" + s.state.titles.join(","));
}

{
  const s = stubPage(["Program", "Event log"]);
  await resetDiffTabs({ page: s.page });
  results.push("noDiffTabsClicked=" + s.clicked.length);
}

{
  const s = stubPage(["Diff: main.nr"], { stubborn: true });
  try {
    await resetDiffTabs({ page: s.page });
    results.push("stubborn=accepted");
  } catch (err) {
    results.push("stubborn=" + (/could not close/.test(err.message) ? "refused" : "wrong-error"));
  }
}

console.log(results.join(" "));
'
RESET_OUT="$(node --input-type=module -e "${RESET_HARNESS//DRIVER_PATH/file://${DRIVER}}" 2>&1)" || true
assert_contains "${RESET_OUT}" "closed=2" \
	"the size loop's reset closes every open diff tab"
assert_contains "${RESET_OUT}" "left=Program" \
	"the reset leaves tabs that are not diff tabs alone"
assert_contains "${RESET_OUT}" "noDiffTabsClicked=0" \
	"the reset closes nothing when no diff tab is open"
assert_contains "${RESET_OUT}" "stubborn=refused" \
	"a tab that will not close fails the capture rather than being captured over"

# ---------------------------------------------------------------------------
section "a clip frames the pane the view is about"
# ---------------------------------------------------------------------------

# A Monaco `.view-line` is laid out as wide as the WIDEST line of the whole
# document and as tall as one row, so a clip taken from its bounding box alone
# runs far past the diff pane into whatever panel sits beside it. The
# `diff-long-line` capture was exactly that — a 1699x62 sliver of the status bar
# and a neighbouring chat composer — and the reviewer sent to it spent an entire
# budget correctly reporting the view's own subject as missing, at 1/10.
#
# Driven against stub locators rather than grepped for, so the arithmetic is
# what is checked.
# shellcheck disable=SC2016  # deliberate: this is JavaScript source, and the
# `${...}` inside it is a JS template literal that the shell must NOT expand.
CLIP_HARNESS='
import { unionClip } from "DRIVER_PATH";

const box = (x, y, width, height) => ({
  count: async () => 1,
  nth: () => ({ boundingBox: async () => ({ x, y, width, height }) }),
  boundingBox: async () => ({ x, y, width, height }),
});
const viewport = { width: 1920, height: 1080 };
const out = [];

// The real `diff-long-line` shape: a one-row target 2500px wide inside a diff
// pane that ends at x=940.
const line = box(330, 700, 2500, 19);
const pane = box(330, 60, 610, 900);

const clamped = await unionClip(null, line, 24, viewport, pane);
out.push("right=" + (clamped.x + clamped.width));
out.push("height=" + clamped.height);
out.push("insidePane=" + (clamped.x >= 330 && clamped.x + clamped.width <= 940));

// Without a pane to clamp to, the same target keeps its old runaway shape —
// which is what says the clamp, and not some other change, is what fixed it.
const loose = await unionClip(null, line, 24, viewport, null);
out.push("looseRight=" + (loose.x + loose.width));
out.push("looseHeight=" + loose.height);

// Growth never breaks out of a pane shorter than the minimum.
const shortPane = box(330, 690, 610, 40);
const inShort = await unionClip(null, line, 24, viewport, shortPane);
out.push("shortTop=" + (inShort.y >= 690) + " shortBottom=" + (inShort.y + inShort.height <= 730));

console.log(out.join(" "));
'
CLIP_OUT="$(node --input-type=module -e "${CLIP_HARNESS//DRIVER_PATH/file://${DRIVER}}" 2>&1)" || true
assert_contains "${CLIP_OUT}" "insidePane=true" \
	"a clip never reaches past the diff pane it is taken inside of"
assert_contains "${CLIP_OUT}" "height=160" \
	"a one-row target is grown to a height a reviewer can judge"
assert_contains "${CLIP_OUT}" "looseRight=1920" \
	"without a pane the same target still runs to the viewport edge (the defect)"
assert_contains "${CLIP_OUT}" "shortTop=true shortBottom=true" \
	"growing a clip never breaks out of a pane shorter than the minimum"

# ---------------------------------------------------------------------------
section "the driver refuses to capture something it cannot name"
# ---------------------------------------------------------------------------

run_expect_failure "the driver refuses an unknown view" "unknown view 'nope'" -- \
	node "${DRIVER}" --ct /bin/true --dataset /tmp --out "${TEST_ROOT}/o" --xdg /tmp --view nope
run_expect_failure "the driver refuses an unknown size" "unknown size 'huge'" -- \
	node "${DRIVER}" --ct /bin/true --dataset /tmp --out "${TEST_ROOT}/o" --xdg /tmp --size huge
run_expect_failure "the driver refuses an unknown theme" "unknown theme 'sepia'" -- \
	node "${DRIVER}" --ct /bin/true --dataset /tmp --out "${TEST_ROOT}/o" --xdg /tmp --theme sepia

# ---------------------------------------------------------------------------
section "the review prompt is emitted only for something that exists"
# ---------------------------------------------------------------------------

SHOT_DIR="${TEST_ROOT}/shots"
mkdir -p "${SHOT_DIR}"

run_expect_failure "the prompt emitter refuses an unknown view" "unknown view 'nope'" -- \
	env CODETRACER_DESIGN_REVIEW_DIR="${SHOT_DIR}" bash "${PROMPT}" \
	--view nope --size wide --theme dark
run_expect_failure "the prompt emitter refuses a screenshot that is not there" "Capture it first" -- \
	env CODETRACER_DESIGN_REVIEW_DIR="${SHOT_DIR}" bash "${PROMPT}" \
	--view diff-flow-values --size wide --theme dark

: >"${SHOT_DIR}/diff-flow-values--wide--dark.png"
PROMPT_TEXT="$(CODETRACER_DESIGN_REVIEW_DIR="${SHOT_DIR}" bash "${PROMPT}" \
	--view diff-flow-values --size wide --theme dark --changed "UD-1 landed the diff editor" 2>&1)"

assert_contains "${PROMPT_TEXT}" "${BRIEF}" "the prompt names the brief"
assert_contains "${PROMPT_TEXT}" "${SHOT_DIR}/diff-flow-values--wide--dark.png" \
	"the prompt names the screenshot"
assert_contains "${PROMPT_TEXT}" "diff-flow-values" "the prompt names the view"
assert_contains "${PROMPT_TEXT}" "wide" "the prompt names the viewport size"
assert_contains "${PROMPT_TEXT}" "dark" "the prompt names the theme"
assert_contains "${PROMPT_TEXT}" "UD-1 landed the diff editor" \
	"the prompt passes on what this iteration changed"
assert_contains "${PROMPT_TEXT}" "Verify those elements FIRST" \
	"the prompt puts verification before aesthetics"
assert_contains "${PROMPT_TEXT}" "rate the screenshot 1-3" \
	"the prompt makes a missing element outrank polish"
assert_contains "${PROMPT_TEXT}" "Return text only" \
	"the prompt keeps the screenshot out of the driving context"
# The first calibration round had a reviewer measure a clipped capture, find it
# narrower than the viewport it was labelled with, and offer that as evidence
# the capture was broken. Naming the framing is what stops that false positive.
assert_contains "${PROMPT_TEXT}" "The image is a CLIP" \
	"the prompt says a clipped view is a clip, not an undersized window"
assert_contains "${PROMPT_TEXT}" "1920x1080" \
	"the prompt states the window geometry the clip was taken from"
: >"${SHOT_DIR}/review-shell--wide--dark.png"
SHELL_PROMPT="$(CODETRACER_DESIGN_REVIEW_DIR="${SHOT_DIR}" bash "${PROMPT}" \
	--view review-shell --size wide --theme dark 2>&1)"
assert_contains "${SHELL_PROMPT}" "WHOLE application window" \
	"the whole-window view is described as the whole window, not as a clip"

# ---------------------------------------------------------------------------
section "capture orchestration (stubbed ct / node / Xvfb)"
# ---------------------------------------------------------------------------

BIN="${TEST_ROOT}/bin"
BUILD="${TEST_ROOT}/build"
mkdir -p "${BIN}" "${BUILD}/bin" "${BUILD}/config" "${BUILD}/frontend/styles"

export HARNESS_TRACE="${TEST_ROOT}/trace.tsv"
: >"${HARNESS_TRACE}"

cat >"${BUILD}/bin/ct" <<'STUB'
#!/usr/bin/env bash
# Recording stub for `ct`. It records what it was asked to do and produces the
# minimum on disk for the caller to proceed, so the orchestration can be
# asserted against a trace of real invocations rather than against source text.
printf 'ct\t%s\n' "$*" >>"${HARNESS_TRACE}"
if [[ ${1:-} == record ]]; then
	shift
	while [[ $# -gt 0 ]]; do
		if [[ $1 == -o ]]; then
			mkdir -p "$2"
			printf 'stub\n' >"$2/trace.json"
			break
		fi
		shift
	done
elif [[ ${1:-} == review && ${2:-} == collect ]]; then
	shift 2
	while [[ $# -gt 0 ]]; do
		if [[ $1 == --output ]]; then
			mkdir -p "$2"
			printf '{}\n' >"$2/review.json"
			break
		fi
		shift
	done
fi
exit 0
STUB
chmod +x "${BUILD}/bin/ct"

REAL_NODE="$(command -v node)"
cat >"${BIN}/node" <<STUB
#!/usr/bin/env bash
# Stands in for the Playwright driver: records the invocation, and records the
# theme the generated config actually asked for, which is the one thing about
# the launch the shell is responsible for.
#
# \`--list\` is delegated to the REAL node. The matrix is the harness's single
# source of truth and the shell reads its theme table from it; stubbing that
# out would mean the orchestration is tested against a matrix invented here
# rather than the one that ships.
if [[ \$* == *--list* ]]; then
	exec "${REAL_NODE}" "\$@"
fi
STUB
cat >>"${BIN}/node" <<'STUB'
printf 'node\t%s\n' "$*" >>"${HARNESS_TRACE}"
xdg=""
prev=""
for arg in "$@"; do
	if [[ ${prev} == --xdg ]]; then xdg="${arg}"; fi
	prev="${arg}"
done
if [[ -n ${xdg} && -f "${xdg}/codetracer/.config.yaml" ]]; then
	printf 'config\t%s\n' "$(grep -E '^theme:' "${xdg}/codetracer/.config.yaml")" >>"${HARNESS_TRACE}"
fi
exit 0
STUB
chmod +x "${BIN}/node"

printf '#!/usr/bin/env bash\nexec sleep 300\n' >"${BIN}/Xvfb"
printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN}/xdotool"
printf '#!/usr/bin/env bash\nexit 0\n' >"${BIN}/nargo"
chmod +x "${BIN}/Xvfb" "${BIN}/xdotool" "${BIN}/nargo"

# A build tree that is newer than the sources, so the staleness guard passes
# and the orchestration is what is under test.
touch "${BUILD}/ui.js" \
	"${BUILD}/config/default_config.yaml" \
	"${BUILD}/config/default_layout.json" \
	"${BUILD}/frontend/styles/default_dark_theme_electron.css" \
	"${BUILD}/frontend/styles/default_white_theme_electron.css"

CORPUS="${TEST_ROOT}/corpus"
OUT="${TEST_ROOT}/out"

seed_corpus() {
	rm -rf "${CORPUS}"
	mkdir -p "${CORPUS}/review"
	printf '{}\n' >"${CORPUS}/review/review.json"
	sha256sum "${CAPTURE}" | cut -d' ' -f1 >"${CORPUS}/.fingerprint"
}

run_capture() {
	: >"${HARNESS_TRACE}"
	PATH="${BIN}:${PATH}" \
		CODETRACER_CT_CMD="${BUILD}/bin/ct" \
		CODETRACER_DESIGN_REVIEW_DISPLAY=":98" \
		bash "${CAPTURE}" --out "${OUT}" --corpus "${CORPUS}" "$@" 2>&1
}

# -- a targeted run reuses the corpus and leaves the other captures alone ----
seed_corpus
mkdir -p "${OUT}"
: >"${OUT}/stale-view--wide--dark.png"
TARGETED_OUT="$(run_capture --view diff-flow-values --size wide --theme dark)"
TARGETED_TRACE="$(cat "${HARNESS_TRACE}")"

assert_file_exists "${OUT}/stale-view--wide--dark.png" \
	"a targeted capture does not clean the output directory"
assert_not_contains "${TARGETED_TRACE}" "ct	record" \
	"a targeted capture with a cached corpus does not re-record"
assert_not_contains "${TARGETED_TRACE}" "review collect" \
	"a targeted capture with a cached corpus does not re-collect"
assert_contains "${TARGETED_OUT}" "reusing the corpus" \
	"a targeted capture says it is reusing the corpus"
assert_contains "${TARGETED_TRACE}" "--view diff-flow-values" \
	"a targeted capture passes the view through to the driver"
assert_contains "${TARGETED_TRACE}" "--size wide" \
	"a targeted capture passes the size through to the driver"
# One theme was named, so only one launch should have happened.
THEME_LAUNCHES="$(printf '%s\n' "${TARGETED_TRACE}" | grep -c '^node	')"
if [[ ${THEME_LAUNCHES} -eq 1 ]]; then
	ok "a single-theme run launches the driver once"
else
	bad "a single-theme run launches the driver once" "launched ${THEME_LAUNCHES} times"
fi

# -- a calibration run cannot overwrite a healthy capture --------------------
#
# The screenshot name is (view, size, theme) and says nothing about the damage,
# so a sabotaged capture written beside the healthy ones would replace the
# healthy capture of that view with a deliberately broken one that looks
# identical on disk — and the next reviewer sent to that path would report the
# sabotage as a product defect. Calibration is re-run whenever the brief
# changes, so it has to be safe to repeat.
seed_corpus
run_capture --view diff-flow-values --size wide --theme dark --sabotage hide-value-chips >/dev/null
SABOTAGE_TRACE="$(cat "${HARNESS_TRACE}")"
assert_contains "${SABOTAGE_TRACE}" "--out ${OUT}/sabotage-hide-value-chips --xdg" \
	"a sabotaged capture is written under its own directory"
assert_not_contains "${SABOTAGE_TRACE}" "--out ${OUT} --xdg" \
	"a sabotaged capture never writes where the healthy captures live"

# -- the light theme is actually configured, not just named ------------------
seed_corpus
run_capture --view diff-flow-values --size wide --theme light >/dev/null
LIGHT_TRACE="$(cat "${HARNESS_TRACE}")"
assert_contains "${LIGHT_TRACE}" 'theme: "default_white"' \
	"a light-theme run writes a config asking for default_white"

# -- a full regeneration cleans, and covers both themes ----------------------
seed_corpus
mkdir -p "${OUT}"
: >"${OUT}/stale-view--wide--dark.png"
run_capture >/dev/null
FULL_TRACE="$(cat "${HARNESS_TRACE}")"
assert_file_absent "${OUT}/stale-view--wide--dark.png" \
	"a full regeneration clears stale captures from a renamed or deleted view"
# A full regeneration covers every theme the product can currently PAINT, which
# it reads from the matrix rather than from a second copy of the theme table.
# `light` is defined and is blocked (CodeTracer has no light palette for the
# Electron surface), so today that is one theme; the moment a real light
# palette lands and the `blocked` string is cleared, this becomes two with no
# change here.
CAPTURABLE_THEMES="$(printf '%s\n' "${MATRIX}" |
	awk -F'\t' '$1 == "theme" && $4 == "" { print $2 }' | wc -l)"
FULL_LAUNCHES="$(printf '%s\n' "${FULL_TRACE}" | grep -c -- '--ct ')"
if [[ ${FULL_LAUNCHES} -eq ${CAPTURABLE_THEMES} ]]; then
	ok "a full regeneration captures every theme the product can currently paint (${FULL_LAUNCHES})"
else
	bad "a full regeneration captures every theme the product can currently paint" \
		"launched the driver ${FULL_LAUNCHES} times for ${CAPTURABLE_THEMES} capturable theme(s)"
fi

# A blocked theme is still in the matrix, and says why. Dropping it would lose
# the axis; leaving it silent would make "both themes" look done.
BLOCKED_LIGHT="$(printf '%s\n' "${MATRIX}" | awk -F'\t' '$1 == "theme" && $2 == "light" { print $4 }')"
if [[ -n ${BLOCKED_LIGHT} ]]; then
	ok "the light theme is in the matrix and records why it is not yet capturable"
else
	ok "the light theme is capturable — the palette gap UD-0 recorded has been closed"
fi
# Naming it explicitly must still LAUNCH, so the refusal is the paint assertion
# finding a dark window rather than a hard-coded 'no' that could outlive the
# problem.
seed_corpus
run_capture --view review-shell --size wide --theme light >/dev/null
LIGHT_ONLY_TRACE="$(cat "${HARNESS_TRACE}")"
assert_contains "${LIGHT_ONLY_TRACE}" "--theme light" \
	"asking for a blocked theme still launches the driver, so the refusal stays evidence-based"

# -- --rebuild-corpus does re-record -----------------------------------------
seed_corpus
run_capture --view review-shell --size wide --theme dark --rebuild-corpus >/dev/null
REBUILD_TRACE="$(cat "${HARNESS_TRACE}")"
RECORDS="$(printf '%s\n' "${REBUILD_TRACE}" | grep -c 'ct	record')"
if [[ ${RECORDS} -eq 2 ]]; then
	ok "--rebuild-corpus records the corpus twice, so the review has two trace contexts"
else
	bad "--rebuild-corpus records the corpus twice" "recorded ${RECORDS} times"
fi
assert_contains "${REBUILD_TRACE}" "review collect" \
	"--rebuild-corpus collects a fresh review dataset"

# -- a corpus whose definition has changed is not reused ---------------------
seed_corpus
printf 'not-the-current-fingerprint\n' >"${CORPUS}/.fingerprint"
STALE_CORPUS_OUT="$(run_capture --view review-shell --size wide --theme dark)"
assert_not_contains "${STALE_CORPUS_OUT}" "reusing the corpus" \
	"a corpus recorded from a different fixture definition is rebuilt, not reused"

# -- preflight refuses rather than photographing the wrong thing -------------
seed_corpus
touch -d '1990-01-01' "${BUILD}/frontend/styles/default_dark_theme_electron.css"
run_expect_failure "a stale build is refused, naming the remedy" "just build-once" -- \
	env PATH="${BIN}:${PATH}" CODETRACER_CT_CMD="${BUILD}/bin/ct" \
	bash "${CAPTURE}" --out "${OUT}" --corpus "${CORPUS}" --view review-shell
touch "${BUILD}/frontend/styles/default_dark_theme_electron.css"

mv "${BUILD}/frontend/styles/default_white_theme_electron.css" "${TEST_ROOT}/parked.css"
run_expect_failure "a missing light stylesheet is refused before any capture" \
	"default_white_theme_electron.css" -- \
	env PATH="${BIN}:${PATH}" CODETRACER_CT_CMD="${BUILD}/bin/ct" \
	bash "${CAPTURE}" --out "${OUT}" --corpus "${CORPUS}" --view review-shell
mv "${TEST_ROOT}/parked.css" "${BUILD}/frontend/styles/default_white_theme_electron.css"

run_expect_failure "an unknown option is refused" "unknown option '--zoom'" -- \
	env PATH="${BIN}:${PATH}" CODETRACER_CT_CMD="${BUILD}/bin/ct" \
	bash "${CAPTURE}" --zoom

# ---------------------------------------------------------------------------
printf '\n'
printf 'deepreview-harness-test summary: expected=%d executed=%d failed=%d\n' \
	"${EXPECTED_ASSERTIONS}" "${ASSERTIONS}" "${FAILURES}"
if [[ ${ASSERTIONS} -ne ${EXPECTED_ASSERTIONS} ]]; then
	echo "deepreview-harness-test: expected ${EXPECTED_ASSERTIONS} assertions, ran ${ASSERTIONS}." >&2
	echo "A contract was deleted or short-circuited; update EXPECTED_ASSERTIONS deliberately." >&2
	exit 3
fi
if [[ ${FAILURES} -ne 0 ]]; then
	echo "deepreview-harness-test: ${FAILURES} contract(s) failed." >&2
	exit 1
fi
echo "deepreview-harness-test: all contracts hold."
