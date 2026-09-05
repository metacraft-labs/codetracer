#!/usr/bin/env bash
#
# stale-artefact-guards-test.sh — one contract suite for the whole
# existence-checked-as-freshness sweep (GOAL #100, codetracer's share).
#
# THE DEFECT THIS EXISTS TO KEEP FIXED.
#
# Code that decides whether an artefact may be reused, published, photographed
# or trusted, and asks only whether a PATH EXISTS — or is executable, or
# non-empty — when the property it actually needs is that the artefact is
# CURRENT with respect to its sources. The tell is almost always in the code's
# own words: "build it first", "run the capture first", "at the workspace-locked
# revision" — a message naming the exact condition its guard cannot detect.
#
# WHY ONE SUITE AND NOT FIVE. Every site below is the same mistake in a
# different file, and the thing that has to keep working is not any one guard
# but the habit of asking the question. A single suite that STALES a real
# artefact in a throwaway tree and asserts the guard refuses is also the only
# form of evidence that means anything here: a guard that has never been seen to
# go red is indistinguishable from a guard that cannot.
#
# WHAT IT DOES NOT MOCK. Every assertion runs the REAL script or module against
# a real filesystem — synthetic git repositories, synthetic build trees, real
# openssl, real `git rev-parse`. Where a script would go on to do something
# expensive (launch Playwright, run `npm ci`, `nix build` a private repo), only
# that last step is stubbed on PATH, and the stub records what it was asked to
# do so the assertion is against an invocation rather than against source text.
#
# ONE SITE FROM THE SWEEP IS NOT HERE, on purpose:
# `tools/visual-review/deepreview-review-prompt.sh` is covered by
# `tools/visual-review/deepreview-harness-test.sh`, which already owns that
# harness's stubs and is already wired into `lint-bash` and into the stock
# runner verdict job.
#
# Run directly:  bash ci/test/stale-artefact-guards-test.sh

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# `SUITE_ROOT`, deliberately NOT `REPO_ROOT`: this suite sources
# `ci/setup-rr-backend.sh`, which assigns a `REPO_ROOT` of its own. See the
# long note above `rr_guard` for what the collision cost.
SUITE_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

# THE SUITE RUNS THE REAL SCRIPTS, so a shell that cannot run them reports
# their guards as ABSENT rather than as unrunnable — which is this suite making
# the very mistake it grades, one level up.
#
# MEASURED on macOS, where `/usr/bin/env bash` is 3.2 and has no `mapfile`:
# four contracts went red with "the command unexpectedly succeeded", because
# `scripts/docs/generate-webp-animations.sh` died at its `mapfile` line before
# reaching the guard, and three more followed. Under the `lint-bash` lane's
# bash 5 the same tree is 46/46. A reader who met those four on a workstation
# would have gone looking for a defect in a fix that is fine.
#
# `bash.sh`'s `require-tools` line already refuses a shell missing `openssl` or
# `sha256sum` BY NAME. This is the same refusal for the interpreter itself.
# shellcheck disable=SC2016  # the `$(...)` in the usage line below is a literal
# placeholder, not a substitution; see the longer note on the sibling block.
if ! command -v mapfile >/dev/null 2>&1 && ! type -t mapfile >/dev/null 2>&1; then
	echo "stale-artefact-guards-test: this bash (${BASH_VERSION}) has no \`mapfile\`." >&2
	echo "  The suite executes the scripts it grades, and several of them use it, so" >&2
	echo "  the guards would be reported MISSING when they are merely unreachable." >&2
	echo "  Run it in the lane it belongs to:" >&2
	echo '    nix develop .#$(...)lint -c ./ci/lint/bash.sh' >&2
	echo "  or under any bash >= 4." >&2
	exit 2
fi

# AND THE INTERPRETER THAT ACTUALLY RUNS THEM, WHICH IS A DIFFERENT ONE.
#
# The check above grades the shell running THIS FILE. Every graded script is
# started as `bash <script>` — resolved from `PATH`, not inherited — so on a
# machine where `/bin/bash` (3.2) precedes a modern one, the suite passes its
# own version check and then hands every script it grades to a shell that dies
# at `mapfile`. MEASURED on this repository: `bash5 ci/test/stale-artefact-
# guards-test.sh` with `/bin/bash` first on PATH prints
# `expected=46 executed=46 failed=8` — a partial score that reads exactly like
# eight broken guards and is in fact one broken instrument. That is the very
# defect this suite grades, committed by the grader, and the earlier version of
# this file caught only half of it.
#
# `bash -c` rather than a version-string parse: the question is whether the
# builtin is there, and that is what asking for it answers.
# SC2016 on the single-quoted lines below is disabled for the whole block:
# every one of them is literal prose -- markdown-style backticks around tool
# names, and a `$(...)` placeholder in a usage line the reader substitutes into.
# They are single-quoted because `shfmt` rewrites the escaped double-quoted
# spelling into exactly this, so any other quoting makes the formatter and the
# linter undo each other on every commit.
# shellcheck disable=SC2016
if ! bash -c 'type -t mapfile' >/dev/null 2>&1; then
	echo 'stale-artefact-guards-test: the `bash` on PATH has no `mapfile`.' >&2
	echo "  found:   $(command -v bash)" >&2
	echo "  version: $(bash -c 'echo "${BASH_VERSION}"' 2>/dev/null)" >&2
	echo '  This suite EXECUTES the scripts it grades, as `bash <script>`, so they' >&2
	echo "  would die before reaching their guards and be scored as missing ones —" >&2
	echo "  which is this suite making the very mistake it grades." >&2
	echo "  Put a bash >= 4 first on PATH, or run the lane it belongs to:" >&2
	echo '    nix develop .#$(...)lint -c ./ci/lint/bash.sh' >&2
	exit 2
fi

VISUAL_CAPTURE="${SUITE_ROOT}/scripts/docs/capture-visual-recording-screenshots.sh"
STORYBOOK_FRESHNESS="${SUITE_ROOT}/tools/visual-review/storybook-freshness.mjs"
STORYBOOK_DEPS="${SUITE_ROOT}/scripts/storybook-deps.sh"
RR_SETUP="${SUITE_ROOT}/ci/setup-rr-backend.sh"
SETUP_CERTS="${SUITE_ROOT}/browser-replay/setup-certs.sh"
WEBP="${SUITE_ROOT}/scripts/docs/generate-webp-animations.sh"
CAPTURE_LIB="${SUITE_ROOT}/scripts/docs/deep-review-capture-lib.sh"
DESKTOP_COMPONENT="${SUITE_ROOT}/scripts/build-desktop-component.sh"
DEVELOPER_SETUP="${SUITE_ROOT}/scripts/developer-setup.sh"
DEPLOY_WASM="${SUITE_ROOT}/browser-replay/deploy-wasm.sh"
CROSS_REPO="${SUITE_ROOT}/scripts/run-cross-repo-tests.sh"
DESKTOP_CAPS="${SUITE_ROOT}/resources/codetracer-desktop-capabilities"
VERSION_NIM="${SUITE_ROOT}/src/ct/version.nim"

# Every contract this suite claims to check. A suite that silently runs fewer
# assertions than it advertises is a suite that stops protecting anything, so
# the count is asserted at the end and has to be changed deliberately.
EXPECTED_ASSERTIONS=93

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
		bad "${desc}" "expected to find: ${needle}" "in: ${haystack:0:800}"
	fi
}

assert_not_contains() {
	local haystack="$1" needle="$2" desc="$3"
	if [[ ${haystack} != *"${needle}"* ]]; then
		ok "${desc}"
	else
		bad "${desc}" "did not expect to find: ${needle}" "in: ${haystack:0:800}"
	fi
}

assert_file_exists() {
	if [[ -f $1 ]]; then ok "$2"; else bad "$2" "no such file: $1"; fi
}

# The other half of the one above, and the only way to say "the refusal stopped
# the deploy" rather than "the refusal printed something".
assert_file_absent() {
	if [[ ! -e $1 ]]; then ok "$2"; else bad "$2" "expected no such path: $1"; fi
}

# run_expect_failure <desc> <fragment> -- <command...>
run_expect_failure() {
	local desc="$1" fragment="$2" out status
	shift 3 # desc, fragment, --
	out="$("$@" 2>&1)"
	status=$?
	if [[ ${status} -eq 0 ]]; then
		bad "${desc}" "the command unexpectedly succeeded" "output: ${out:0:600}"
		return
	fi
	assert_contains "${out}" "${fragment}" "${desc}"
}

for required in "${VISUAL_CAPTURE}" "${STORYBOOK_FRESHNESS}" "${STORYBOOK_DEPS}" \
	"${RR_SETUP}" "${SETUP_CERTS}" "${WEBP}" "${CAPTURE_LIB}" \
	"${DESKTOP_COMPONENT}" "${DEVELOPER_SETUP}" "${DEPLOY_WASM}" \
	"${CROSS_REPO}" "${DESKTOP_CAPS}" "${VERSION_NIM}"; do
	if [[ ! -f ${required} ]]; then
		echo "stale-artefact-guards-test: missing '${required}'" >&2
		exit 3
	fi
done
for tool in git node openssl sha256sum; do
	command -v "${tool}" >/dev/null 2>&1 || {
		echo "stale-artefact-guards-test: missing '${tool}'" >&2
		exit 3
	}
done

TEST_ROOT="$(mktemp -d -t ct-stale-artefact-guards-XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

BIN="${TEST_ROOT}/bin"
mkdir -p "${BIN}"
export TRACE="${TEST_ROOT}/trace.tsv"
: >"${TRACE}"

# ---------------------------------------------------------------------------
section "the book's visual-recording capture refuses a stale sibling binary"
# ---------------------------------------------------------------------------
#
# `capture-visual-recording-screenshots.sh` tested `-x` on three binaries owned
# by three OTHER repositories and treated executability as currency. The images
# it writes go into `docs/book/src/generated/visual_recordings`, so a recorder,
# a player or a scene fixture older than its own sources publishes pictures of
# an old product. The reason this went unfixed once is that no pattern of source
# names could be assumed for a sibling; the guard now asks the sibling's own
# `git ls-files` instead, which is layout-agnostic and is what these assertions
# actually exercise.

WS="${TEST_ROOT}/ws"
mkdir -p "${WS}"

# make_sibling <name> <binary-relative-path>
make_sibling() {
	local name="$1" rel="$2" dir="${WS}/$1"
	mkdir -p "${dir}/$(dirname -- "${rel}")"
	printf 'int main(void) { return 0; }\n' >"${dir}/source.c"
	printf 'readme\n' >"${dir}/README.md"
	git -C "${dir}" init -q
	git -C "${dir}" config user.email t@t.local
	git -C "${dir}" config user.name t
	git -C "${dir}" add -A
	git -C "${dir}" commit -qm "sources"
	# The stub's body is written verbatim; the expansions in it are the stub's,
	# not this script's.
	# shellcheck disable=SC2016
	printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "%s" "$*" >>"${TRACE}"\nexit 0\n' \
		"${name}" >"${dir}/${rel}"
	chmod +x "${dir}/${rel}"
}

make_sibling codetracer-native-recorder ct_cli/ct_cli
make_sibling codetracer-visual-replay ct_gfx_player
make_sibling codetracer-native-test-programs gl/gl_scene

# The only expensive step in the capture is the Playwright run; stub exactly it.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "npx\\t%%s\\n" "$*" >>"${TRACE}"\nexit 0\n' >"${BIN}/npx"
chmod +x "${BIN}/npx"

SHOTS="${TEST_ROOT}/book-shots"

# `run_visual_capture` photographs a SUPPLIED trace; `run_visual_recording` has
# the script record one first, which is the only path that reaches the GL scene
# fixture. Two functions rather than one with an argument, so they can be handed
# to `run_expect_failure` by name.
run_visual_capture() {
	: >"${TRACE}"
	PATH="${BIN}:${PATH}" \
		NATIVE_RECORDER_REPO="${WS}/codetracer-native-recorder" \
		VISUAL_REPLAY_REPO="${WS}/codetracer-visual-replay" \
		NATIVE_TEST_PROGRAMS_REPO="${WS}/codetracer-native-test-programs" \
		CODETRACER_BOOK_SCREENSHOT_DIR="${SHOTS}" \
		CODETRACER_REAL_VISUAL_TRACE="${TEST_ROOT}/provided.ct" \
		bash "${VISUAL_CAPTURE}" 2>&1
}

run_visual_recording() {
	: >"${TRACE}"
	PATH="${BIN}:${PATH}" \
		NATIVE_RECORDER_REPO="${WS}/codetracer-native-recorder" \
		VISUAL_REPLAY_REPO="${WS}/codetracer-visual-replay" \
		NATIVE_TEST_PROGRAMS_REPO="${WS}/codetracer-native-test-programs" \
		CODETRACER_BOOK_SCREENSHOT_DIR="${SHOTS}" \
		bash "${VISUAL_CAPTURE}" 2>&1
}

# -- healthy: every binary is newer than its own sources ---------------------
HEALTHY="$(run_visual_capture)"
assert_contains "${HEALTHY}" "Capturing book screenshots into ${SHOTS}" \
	"a recorder and player newer than their sources are photographed"
assert_not_contains "${HEALTHY}" "stale sibling build" \
	"nothing is refused when nothing is stale"

# -- stale recorder ----------------------------------------------------------
touch "${WS}/codetracer-native-recorder/source.c"
run_expect_failure "a recorder older than its own sources is refused" \
	"stale sibling build: the MCR command (ct_cli)" -- run_visual_capture
STALE_MCR="$(run_visual_capture)"
assert_contains "${STALE_MCR}" "source.c" \
	"the refusal names the source file that outran the recorder"
assert_not_contains "${STALE_MCR}" "Capturing book screenshots" \
	"a stale recorder stops the capture before any image is written"
touch "${WS}/codetracer-native-recorder/ct_cli/ct_cli"

# -- stale player ------------------------------------------------------------
touch "${WS}/codetracer-visual-replay/README.md"
run_expect_failure "a player older than its own sources is refused" \
	"stale sibling build: the visual replay player (ct_gfx_player)" -- \
	run_visual_capture
touch "${WS}/codetracer-visual-replay/ct_gfx_player"

# -- stale scene fixture -----------------------------------------------------
#
# Reached only on the recording path (no CODETRACER_REAL_VISUAL_TRACE), which is
# the path the book actually uses. This binary is the SUBJECT of the recording,
# not a tool used to make it.
RECORDED="$(run_visual_recording)"
assert_contains "${RECORDED}" "Recording visual trace for book screenshots" \
	"with no supplied trace the capture records one with the fresh fixture"

touch "${WS}/codetracer-native-test-programs/source.c"
run_expect_failure "a GL scene fixture older than its own sources is refused" \
	"stale sibling build: the GL scene fixture (gl_scene)" -- \
	run_visual_recording
touch "${WS}/codetracer-native-test-programs/gl/gl_scene"

# -- the two cases the guard cannot ask, and says so -------------------------
mv "${WS}/codetracer-visual-replay/ct_gfx_player" "${TEST_ROOT}/parked-player"
run_expect_failure "a missing binary is still refused, with the remedy" \
	"Set CODETRACER_CT_GFX_PLAYER_CMD" -- run_visual_capture
mv "${TEST_ROOT}/parked-player" "${WS}/codetracer-visual-replay/ct_gfx_player"

OUTSIDE="${TEST_ROOT}/elsewhere/ct_gfx_player"
mkdir -p "$(dirname -- "${OUTSIDE}")"
printf '#!/usr/bin/env bash\nexit 0\n' >"${OUTSIDE}"
chmod +x "${OUTSIDE}"
touch -t 199001010000 "${OUTSIDE}"
OUT_OF_TREE="$(CODETRACER_CT_GFX_PLAYER_CMD="${OUTSIDE}" run_visual_capture)"
assert_contains "${OUT_OF_TREE}" "was supplied from outside" \
	"a binary supplied from outside the sibling checkout says why it is not checked"
assert_contains "${OUT_OF_TREE}" "Capturing book screenshots" \
	"...and is used, rather than refused for a question that cannot be asked"

NOT_GIT="${TEST_ROOT}/vendored"
mkdir -p "${NOT_GIT}/ct_cli"
printf '#!/usr/bin/env bash\nexit 0\n' >"${NOT_GIT}/ct_cli/ct_cli"
chmod +x "${NOT_GIT}/ct_cli/ct_cli"
NOT_GIT_OUT="$(PATH="${BIN}:${PATH}" \
	NATIVE_RECORDER_REPO="${NOT_GIT}" \
	VISUAL_REPLAY_REPO="${WS}/codetracer-visual-replay" \
	NATIVE_TEST_PROGRAMS_REPO="${WS}/codetracer-native-test-programs" \
	CODETRACER_BOOK_SCREENSHOT_DIR="${SHOTS}" \
	CODETRACER_REAL_VISUAL_TRACE="${TEST_ROOT}/provided.ct" \
	bash "${VISUAL_CAPTURE}" 2>&1)"
assert_contains "${NOT_GIT_OUT}" "is not a git checkout" \
	"a vendored sibling tree says its sources are unknown instead of passing quietly"

# ---------------------------------------------------------------------------
section "the visual-review storybook corpus refuses to be photographed stale"
# ---------------------------------------------------------------------------
#
# `capture-storybook.mjs:227` asked `existsSync(storybook-static)` and told the
# reader to "Run without --no-build first" — naming the condition it could not
# detect. `--no-build` is documented, and `storybook-static` is deleted only by
# a real build, so the corpus could be photographs of components from several
# commits ago with no signal in the report. `storybook build` COPIES the
# frontend build tree into that directory, so the renderer is inside the corpus
# too, which is why the source list below includes it.

SB="${TEST_ROOT}/sb-repo"
mkdir -p "${SB}/storybook/.storybook" "${SB}/storybook/stories" \
	"${SB}/storybook/scripts" "${SB}/storybook/dist" \
	"${SB}/storybook/storybook-static" \
	"${SB}/src/frontend" "${SB}/src/build-debug/frontend" "${SB}/src/build-debug/public"
printf 'x\n' >"${SB}/storybook/.storybook/main.ts"
printf 'x\n' >"${SB}/storybook/stories/One.stories.js"
printf 'x\n' >"${SB}/storybook/scripts/check.mjs"
printf '{}\n' >"${SB}/storybook/package.json"
printf '{}\n' >"${SB}/storybook/package-lock.json"
printf 'x\n' >"${SB}/src/frontend/index.html"
printf 'x\n' >"${SB}/src/frontend/ui.nim"
printf 'x\n' >"${SB}/src/build-debug/frontend/ui.js"
printf 'x\n' >"${SB}/src/build-debug/public/index.css"
printf 'x\n' >"${SB}/storybook/dist/components.js"
printf 'x\n' >"${SB}/storybook/storybook-static/index.html"

cat >"${TEST_ROOT}/check-storybook.mjs" <<EOF
import { requireFreshStorybookStatic } from "${STORYBOOK_FRESHNESS}";
try {
  requireFreshStorybookStatic(process.argv[2]);
  console.log("FRESH");
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
EOF

check_storybook() { node "${TEST_ROOT}/check-storybook.mjs" "${SB}" 2>&1; }

assert_contains "$(check_storybook)" "FRESH" \
	"a storybook-static newer than everything it is built from passes"

touch "${SB}/storybook/stories/One.stories.js"
run_expect_failure "a story file newer than the built corpus is refused" \
	"Stale storybook corpus" -- check_storybook
assert_contains "$(check_storybook)" "One.stories.js" \
	"the refusal names the story file that outran the build"
touch "${SB}/storybook/storybook-static/index.html"

# The staticDirs copy is the half a reader is least likely to think of: the
# renderer build tree is INSIDE storybook-static, so a `just build-once` between
# two review rounds makes the corpus a picture of the previous renderer.
touch "${SB}/src/build-debug/frontend/ui.js"
run_expect_failure "a rebuilt renderer makes the copied corpus stale" \
	"ui.js" -- check_storybook
touch "${SB}/storybook/storybook-static/index.html"

touch "${SB}/src/frontend/ui.nim"
run_expect_failure "Nim sources newer than the components bundle are refused" \
	"Stale storybook components" -- check_storybook
touch "${SB}/storybook/dist/components.js" "${SB}/storybook/storybook-static/index.html"
assert_contains "$(check_storybook)" "FRESH" \
	"rebuilding both artefacts makes it green again"

rm -f "${SB}/storybook/storybook-static/index.html"
run_expect_failure "an absent corpus is still refused, with the remedy" \
	"just storybook-build" -- check_storybook

# ---------------------------------------------------------------------------
section "CI's rr-backend setup refuses a checkout that is not the locked one"
# ---------------------------------------------------------------------------
#
# The highest-consequence site in the sweep: it decides which backend binary CI
# builds and tests against. `clone_rr_backend` reused whatever was at
# `$CLONE_DIR` on the strength of `[[ -d "$CLONE_DIR/.git" ]]` with a comment
# asserting the revision was correct, and `main()` deliberately skipped
# resolving the locked revision whenever the directory existed — so the one
# value that could have answered the question was never computed. The evidence
# that stale checkouts happen on these machines is in the script itself: "Clean
# up any previous clone (self-hosted runners reuse workspaces)".

BACKEND="${TEST_ROOT}/codetracer-native-backend"
mkdir -p "${BACKEND}"
git -C "${BACKEND}" init -q
git -C "${BACKEND}" config user.email t@t.local
git -C "${BACKEND}" config user.name t
printf 'one\n' >"${BACKEND}/file"
git -C "${BACKEND}" add -A
git -C "${BACKEND}" commit -qm one
REV_OLD="$(git -C "${BACKEND}" rev-parse HEAD)"
printf 'two\n' >"${BACKEND}/file"
git -C "${BACKEND}" add -A
git -C "${BACKEND}" commit -qm two
REV_NEW="$(git -C "${BACKEND}" rev-parse HEAD)"
git -C "${BACKEND}" checkout -q "${REV_OLD}"

# Sourced rather than executed, so the guard is exercised without reaching
# `nix build`. The script's `main` is behind a BASH_SOURCE guard for this.
# Always in a SUBSHELL: sourcing it assigns `REPO_ROOT` and `CLONE_DIR`, and
# the subshell is what keeps those assignments from reaching this suite.
#
# THIS SUITE'S OWN ROOT IS `SUITE_ROOT`, NOT `REPO_ROOT`, AND THAT NAME IS
# LOAD-BEARING. It used to be `REPO_ROOT` too, defended only by this subshell.
# The containment was correct and the runtime behaviour was never wrong — but
# the linter, once it can SEE the sourced file, reads `REPO_ROOT="$(pwd)"`
# inside this subshell and then reports SC2031 ("modified in a subshell, that
# change might be lost") at every later top-level use of the suite's OWN
# variable. Nine such findings, all false, exited `shellcheck` 1 and failed
# `lint-bash` — which skipped every build job behind it.
#
# It surfaced only when `ci/lint/bash.sh` gained `shopt -s globstar`. The
# linter follows a `source` only when the sourced file is ALSO an input, and
# globstar is what first brought `ci/setup-rr-backend.sh` into `ci/**/*.sh`.
# So `shellcheck <this file>` alone still exits 0 and the narrower
# "shellcheck: stale-artefact guards" step stayed green throughout, which is
# why the two steps disagreed about one file.
#
# Renaming is the fix rather than a `disable=SC2031`, because the name
# collision was a real hazard that the subshell merely hid: with two distinct
# names there is nothing for either the linter or a future reader to confuse.
rr_guard() {
	(
		export CLONE_DIR="$1"
		cd "${SUITE_ROOT}" || exit 1
		# shellcheck source=ci/setup-rr-backend.sh disable=SC1091
		source "${RR_SETUP}"
		require_locked_checkout "$1" "$2"
	) 2>&1
}

MISMATCH="$(rr_guard "${BACKEND}" "${REV_NEW}")"
assert_contains "${MISMATCH}" "stale codetracer-native-backend checkout" \
	"a checkout at the wrong revision is refused"
assert_contains "${MISMATCH}" "${REV_OLD}" \
	"the refusal names the revision the checkout is actually at"
assert_contains "${MISMATCH}" "${REV_NEW}" \
	"the refusal names the revision the workspace lock requires"
assert_contains "${MISMATCH}" "git -C '${BACKEND}' checkout" \
	"the refusal names the command that fixes it"

MATCH="$(rr_guard "${BACKEND}" "${REV_OLD}")"
assert_contains "${MATCH}" "verified at ${REV_OLD}" \
	"a checkout at the locked revision is reused, and says it was verified"

UNKNOWN="$(rr_guard "${BACKEND}" 0123456789012345678901234567890123456789)"
assert_contains "${UNKNOWN}" "cannot tell whether" \
	"a revision the checkout does not have and cannot fetch is a refusal, not a pass"

# -- a MOVING ref is compared against what it points at now ------------------
#
# The one workflow step that calls this script passes `RR_BACKEND_REF: dev`. A
# reused workspace's local `dev` branch is exactly as stale as the checkout
# sitting on it, so resolving the name locally would answer "is this checkout at
# the `dev` it was at last week" — which is not a freshness question.
UPSTREAM="${TEST_ROOT}/upstream-backend"
git clone -q "${BACKEND}" "${UPSTREAM}"
git -C "${UPSTREAM}" checkout -q -B dev "${REV_OLD}"
MOVING="${TEST_ROOT}/moving-backend"
git clone -q --branch dev "${UPSTREAM}" "${MOVING}"
# Upstream moves on; the clone's local `dev` does not.
git -C "${UPSTREAM}" reset -q --hard "${REV_NEW}"
MOVED="$(rr_guard "${MOVING}" dev)"
assert_contains "${MOVED}" "is a moving ref; re-fetching it" \
	"a branch name is re-fetched rather than resolved against a stale local branch"
assert_contains "${MOVED}" "stale codetracer-native-backend checkout" \
	"...so a checkout sitting on last week's dev is refused"

git -C "${MOVING}" config advice.detachedHead false
git -C "${MOVING}" fetch -q origin dev
git -C "${MOVING}" checkout -q "${REV_NEW}"
CAUGHT_UP="$(rr_guard "${MOVING}" dev)"
assert_contains "${CAUGHT_UP}" "verified at ${REV_NEW}" \
	"a checkout brought up to the branch tip is reused"

# END TO END, as a script: `main` must resolve the ref even though the directory
# is present. This is the exact thing the old code skipped, and it fails before
# `build_rr_support` so no nix, no credential and no network are involved.
# shellcheck disable=SC2031  # SUITE_ROOT is only ever modified inside rr_guard's subshell
END_TO_END="$(cd "${SUITE_ROOT}" && env CLONE_DIR="${BACKEND}" RR_BACKEND_REF="${REV_NEW}" \
	bash "${RR_SETUP}" 2>&1)"
assert_contains "${END_TO_END}" "Using rr-backend ref: ${REV_NEW}" \
	"the locked revision is resolved even when the sibling is already present"
assert_contains "${END_TO_END}" "stale codetracer-native-backend checkout" \
	"...and the present-but-wrong sibling is refused rather than built against"

# ---------------------------------------------------------------------------
section "storybook deps are keyed on the lockfile, not on the tree existing"
# ---------------------------------------------------------------------------
#
# `just storybook-deps` skipped `npm ci` entirely when
# `node_modules/.bin/storybook` was executable, so a `package-lock.json` change
# was never installed on any machine that had run it once.

DEPS="${TEST_ROOT}/deps/storybook"
mkdir -p "${DEPS}"
printf '{"lockfileVersion":3}\n' >"${DEPS}/package-lock.json"
cat >"${BIN}/npm" <<'STUB'
#!/usr/bin/env bash
printf 'npm\t%s\n' "$*" >>"${TRACE}"
mkdir -p node_modules/.bin
printf '#!/usr/bin/env bash\nexit 0\n' >node_modules/.bin/storybook
chmod +x node_modules/.bin/storybook
exit 0
STUB
chmod +x "${BIN}/npm"

run_deps() {
	: >"${TRACE}"
	PATH="${BIN}:${PATH}" bash "${STORYBOOK_DEPS}" "${DEPS}" 2>&1
}

run_deps >/dev/null
assert_contains "$(cat "${TRACE}")" $'npm\tci' \
	"a cold checkout installs from the lockfile"
assert_file_exists "${DEPS}/node_modules/.package-lock-digest" \
	"the install records which lockfile it was made from"

SECOND="$(run_deps)"
assert_contains "${SECOND}" "matches package-lock.json" \
	"a warm checkout with an unchanged lockfile skips the install"
assert_not_contains "$(cat "${TRACE}")" $'npm\tci' \
	"...and really does not run npm"

printf '{"lockfileVersion":3,"changed":true}\n' >"${DEPS}/package-lock.json"
THIRD="$(run_deps)"
assert_contains "${THIRD}" "has changed since the last install" \
	"a changed lockfile is reinstalled instead of skipped"
assert_contains "$(cat "${TRACE}")" $'npm\tci' \
	"...and npm ci actually runs"

# ---------------------------------------------------------------------------
section "the browser-replay certificate is checked for validity, not presence"
# ---------------------------------------------------------------------------
#
# `[ -f server.crt ] && [ -f server.key ]` -> "Certificates already exist" ->
# exit 0. The certificate is issued for 365 days and for one SAN set, so
# presence answers neither of the questions that decide whether it works.

CERTS_HOME="${TEST_ROOT}/browser-replay"
mkdir -p "${CERTS_HOME}"
cp "${SETUP_CERTS}" "${CERTS_HOME}/setup-certs.sh"
CERT_DIR="${CERTS_HOME}/certs"

run_certs() { bash "${CERTS_HOME}/setup-certs.sh" 2>&1; }

assert_contains "$(run_certs)" "Certificate generated" \
	"a missing certificate is issued"
assert_contains "$(run_certs)" "are current" \
	"a valid, in-date, correctly-named certificate is left alone"

# An expiring certificate: presence is unchanged, validity is not.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${CERT_DIR}/server.key" \
	-out "${CERT_DIR}/server.crt" -days 1 -subj "/CN=localhost" \
	-addext "subjectAltName=DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
EXPIRING="$(run_certs)"
assert_contains "${EXPIRING}" "expires within 7 days" \
	"a certificate about to expire is re-issued, not accepted for existing"

# A certificate for the wrong names: also present, also in date, also useless.
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${CERT_DIR}/server.key" \
	-out "${CERT_DIR}/server.crt" -days 365 -subj "/CN=localhost" \
	-addext "subjectAltName=DNS:example.invalid" >/dev/null 2>&1
WRONG_SAN="$(run_certs)"
assert_contains "${WRONG_SAN}" "but this server is reached at" \
	"a certificate covering the wrong names is re-issued"

# A key that does not belong to the certificate — what a half-finished run of
# this very script leaves behind, since `openssl req` writes the key first.
openssl genrsa -out "${CERT_DIR}/server.key" 2048 >/dev/null 2>&1
MISMATCHED_KEY="$(run_certs)"
assert_contains "${MISMATCHED_KEY}" "does not match the certificate" \
	"a key that does not belong to the certificate is re-issued"

# ---------------------------------------------------------------------------
section "the book's WebP animations cannot be named from a stale video dir"
# ---------------------------------------------------------------------------
#
# A different mechanism with the same consequence. `ls -1tr videos/*.webm` was
# mapped POSITIONALLY onto six fixed book-animation names, over a directory
# Playwright never cleans — so every previous run's videos were in the list, and
# the sixth-oldest file, whatever it was, became `terminal.webp` in the book.

WEBP_REPO="${TEST_ROOT}/webp-repo"
mkdir -p "${WEBP_REPO}/scripts/docs" "${WEBP_REPO}/src/tests/gui" \
	"${WEBP_REPO}/test-results/videos"
cp "${WEBP}" "${WEBP_REPO}/scripts/docs/generate-webp-animations.sh"

# Videos left behind by earlier runs. Before the fix these were in the list.
for stale in a b c d; do
	printf 'old\n' >"${WEBP_REPO}/test-results/videos/stale-${stale}.webm"
done

cat >"${BIN}/npm" <<'STUB'
#!/usr/bin/env bash
printf 'npm\t%s\n' "$*" >>"${TRACE}"
mkdir -p "${WEBP_VIDEO_DIR}"
for i in $(seq 1 "${WEBP_VIDEO_COUNT}"); do
	printf 'new\n' >"${WEBP_VIDEO_DIR}/run-${i}.webm"
	sleep 0.01
done
exit 0
STUB
chmod +x "${BIN}/npm"
cat >"${BIN}/ffmpeg" <<'STUB'
#!/usr/bin/env bash
printf 'ffmpeg\t%s\n' "$*" >>"${TRACE}"
out=""
for arg in "$@"; do out="${arg}"; done
printf 'webp\n' >"${out}"
exit 0
STUB
chmod +x "${BIN}/ffmpeg"

run_webp() {
	: >"${TRACE}"
	PATH="${BIN}:${PATH}" \
		WEBP_VIDEO_DIR="${WEBP_REPO}/test-results/videos" \
		WEBP_VIDEO_COUNT="$1" \
		bash "${WEBP_REPO}/scripts/docs/generate-webp-animations.sh" 2>&1
}

SIX="$(run_webp 6)"
assert_contains "${SIX}" "Done! Animations generated" \
	"six recorded videos map onto the six names the book uses"
assert_file_exists "${WEBP_REPO}/docs/book/src/generated/animations/terminal.webp" \
	"the sixth name comes from the sixth video OF THIS RUN, not from a leftover"
assert_not_contains "$(cat "${TRACE}")" "stale-a.webm" \
	"videos left behind by an earlier run are never converted"

# A filtered run records fewer videos than there are names, which is the case
# that silently published three animations of an older product.
FILTERED="$(run_webp 3)"
assert_contains "${FILTERED}" "recorded 3 video(s) but this script names 6" \
	"a run that records fewer videos than there are names is refused"
assert_contains "${FILTERED}" "assigned BY POSITION" \
	"the refusal explains why the count has to match"

# ---------------------------------------------------------------------------
section "the desktop component bundle refuses to publish a stale core"
# ---------------------------------------------------------------------------
#
# `scripts/build-desktop-component.sh` walked five candidate build trees and
# took the first one whose `bin/ct` was `-x`, then symlinked or copied it into
# `codetracer-desktop@<version>/bin/codetracer` — the component the LAUNCHER
# execv()s. Two mistakes at once: the choice was made by existence (a month-old
# `src/build-release/bin/ct` beats a fresh repro tree that has no debug
# variant), and the "has not been built" refusal underneath said "Build it with:
# just build-once", naming the condition it could not detect. The bundle
# directory is named from `src/ct/version.nim` as it reads NOW, so a stale core
# is published under the current version string.
#
# The fixture is a synthetic checkout carrying the real script, the real
# capability resource and the real `version.nim`, so the name/version derivation
# is the product's and only the sources are synthetic.

DESK="${TEST_ROOT}/desktop-repo"
mkdir -p "${DESK}/scripts/docs" "${DESK}/resources" "${DESK}/src/ct" \
	"${DESK}/src/build-debug/bin"
cp "${DESKTOP_COMPONENT}" "${DESK}/scripts/build-desktop-component.sh"
cp "${CAPTURE_LIB}" "${DESK}/scripts/docs/deep-review-capture-lib.sh"
cp "${DESKTOP_CAPS}" "${DESK}/resources/codetracer-desktop-capabilities"
cp "${VERSION_NIM}" "${DESK}/src/ct/version.nim"
printf 'echo "ct"\n' >"${DESK}/src/ct/codetracer.nim"
printf 'readme\n' >"${DESK}/README.md"
git -C "${DESK}" init -q
git -C "${DESK}" config user.email t@t.local
git -C "${DESK}" config user.name t
git -C "${DESK}" add -A
git -C "${DESK}" commit -qm sources
# Built AFTER the sources, and outside the index — which is also what makes it
# invisible to the `git ls-files` the guard asks.
printf '#!/usr/bin/env bash\nexit 0\n' >"${DESK}/src/build-debug/bin/ct"
chmod +x "${DESK}/src/build-debug/bin/ct"

run_desktop() {
	CODETRACER_COMPONENT_OUT_ROOT="${DESK}/out" \
		bash "${DESK}/scripts/build-desktop-component.sh" "$@" 2>&1
}

assert_contains "$(run_desktop)" "codetracer-desktop component bundle ready:" \
	"a core newer than every Nim source is published as the component"

touch "${DESK}/src/ct/codetracer.nim"
run_expect_failure "a core older than the Nim it is compiled from is refused" \
	"stale build: the CodeTracer core binary" -- run_desktop
STALE_CORE="$(run_desktop)"
assert_contains "${STALE_CORE}" "codetracer.nim" \
	"the refusal names the source file that outran the core"
assert_not_contains "${STALE_CORE}" "bundle ready" \
	"a refused run publishes no bundle at all"

# A core handed in from elsewhere — a Nix store path, another worktree — was not
# built from this checkout's sources, so the question cannot be asked. It says
# so and proceeds, rather than manufacturing a refusal.
OUTSIDE_CT="${TEST_ROOT}/elsewhere-ct/ct"
mkdir -p "$(dirname -- "${OUTSIDE_CT}")"
printf '#!/usr/bin/env bash\nexit 0\n' >"${OUTSIDE_CT}"
chmod +x "${OUTSIDE_CT}"
touch -t 199001010000 "${OUTSIDE_CT}"
FOREIGN_CORE="$(run_desktop --core-bin "${OUTSIDE_CT}")"
assert_contains "${FOREIGN_CORE}" "was supplied from outside" \
	"a core supplied from outside the checkout says why it is not checked"
assert_contains "${FOREIGN_CORE}" "bundle ready" \
	"...and is published, rather than refused for a question that cannot be asked"

# ---------------------------------------------------------------------------
section "developer-setup refuses to INSTALL a stale ct"
# ---------------------------------------------------------------------------
#
# `[ ! -f src/build-debug/bin/ct ]` -> "Please run 'just build-once' first."
# The sentence is the tell. Nothing deletes that binary, so one build on any
# branch at any time satisfies the test forever — and what follows is not a
# report: `ct install` puts THAT binary on the developer's PATH and writes its
# desktop entry, and Phase 2 copies it to `/usr/local/lib/codetracer/` and
# grants it cap_bpf,cap_perfmon,cap_dac_read_search.
#
# `--without-bpf` is passed so the run stops after Phase 1 on any platform;
# every assertion here is about Phase 1, which is the phase that installs.

DEV="${TEST_ROOT}/dev-repo"
mkdir -p "${DEV}/scripts/docs" "${DEV}/src/ct" "${DEV}/src/build-debug/bin"
cp "${DEVELOPER_SETUP}" "${DEV}/scripts/developer-setup.sh"
cp "${CAPTURE_LIB}" "${DEV}/scripts/docs/deep-review-capture-lib.sh"
printf 'echo "ct"\n' >"${DEV}/src/ct/codetracer.nim"
git -C "${DEV}" init -q
git -C "${DEV}" config user.email t@t.local
git -C "${DEV}" config user.name t
git -C "${DEV}" add -A
git -C "${DEV}" commit -qm sources
# The `ct` under test records what it was asked to install, so the assertions
# below are against an invocation rather than against source text.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nprintf "ct\\t%%s\\n" "$*" >>"${TRACE}"\nexit 0\n' \
	>"${DEV}/src/build-debug/bin/ct"
chmod +x "${DEV}/src/build-debug/bin/ct"

run_devsetup() {
	: >"${TRACE}"
	bash "${DEV}/scripts/developer-setup.sh" --without-bpf 2>&1
}

assert_contains "$(run_devsetup)" "=== CodeTracer Developer Machine Setup ===" \
	"a ct newer than every Nim source is installed"
assert_contains "$(cat "${TRACE}")" $'ct\tinstall --bpf=false' \
	"...and the install really is the binary from the build tree"

touch "${DEV}/src/ct/codetracer.nim"
run_expect_failure "a ct older than the Nim it is compiled from is not installed" \
	"stale build: the ct binary" -- run_devsetup
assert_contains "$(run_devsetup)" "codetracer.nim" \
	"the refusal names the source file that outran the binary"
assert_not_contains "$(cat "${TRACE}")" "install" \
	"...and nothing was installed onto the machine"

# ---------------------------------------------------------------------------
section "the browser-replay WASM deploy is dated, not merely present"
# ---------------------------------------------------------------------------
#
# `[ ! -d "$PKG_SRC" ]` -> "Run: cd src/db-backend && bash build_wasm.sh". The
# directory survives every build, so from the second one onwards the test is
# satisfied by history. What happens next is a DEPLOY: the glue and the module
# are copied into the directory nginx serves, and browser-replay then runs an
# out-of-date db-backend against current traces with nothing in the page saying
# which module it got.
#
# The fixture starts STALE, so the first thing asserted is that nothing is
# copied — the healthy path is exercised afterwards, once the module has been
# "rebuilt". A suite that deployed first could not tell a refusal from a no-op.

WASMREPO="${TEST_ROOT}/wasm-repo"
WASM_PKG="${WASMREPO}/src/db-backend/wasm-testing/pkg"
WASM_DST="${WASMREPO}/browser-replay/app/pkg"
mkdir -p "${WASMREPO}/browser-replay" "${WASMREPO}/scripts/docs" \
	"${WASMREPO}/src/db-backend/src" "${WASM_PKG}"
cp "${DEPLOY_WASM}" "${WASMREPO}/browser-replay/deploy-wasm.sh"
cp "${CAPTURE_LIB}" "${WASMREPO}/scripts/docs/deep-review-capture-lib.sh"
printf 'pub fn replay() {}\n' >"${WASMREPO}/src/db-backend/src/lib.rs"
printf '[package]\nname = "db-backend"\n' >"${WASMREPO}/src/db-backend/Cargo.toml"
printf 'lock\n' >"${WASMREPO}/src/db-backend/Cargo.lock"
printf 'x\n' >"${WASMREPO}/src/db-backend/build.rs"
printf 'glue\n' >"${WASM_PKG}/db_backend.js"
printf 'wasm\n' >"${WASM_PKG}/db_backend_bg.wasm"
git -C "${WASMREPO}" init -q
git -C "${WASMREPO}" config user.email t@t.local
git -C "${WASMREPO}" config user.name t
git -C "${WASMREPO}" add -A
git -C "${WASMREPO}" commit -qm sources
# The crate moves on; the built module does not. This is the whole defect.
touch "${WASMREPO}/src/db-backend/src/lib.rs"

run_deploy_wasm() { bash "${WASMREPO}/browser-replay/deploy-wasm.sh" 2>&1; }

run_expect_failure "a module older than the crate it is built from is refused" \
	"stale WASM build: db_backend.js" -- run_deploy_wasm
assert_contains "$(run_deploy_wasm)" "lib.rs" \
	"the refusal names the Rust source that outran the module"
assert_file_absent "${WASM_DST}/db_backend_bg.wasm" \
	"nothing reaches the directory nginx serves"

touch "${WASM_PKG}/db_backend.js" "${WASM_PKG}/db_backend_bg.wasm"
assert_contains "$(run_deploy_wasm)" "Deployed WASM to" \
	"a rebuilt module is deployed"
assert_file_exists "${WASM_DST}/db_backend_bg.wasm" \
	"...and the module really is copied there"

# BOTH HALVES, NOT ONE. `wasm-bindgen` writes the glue and the module
# separately; a run that died between them leaves a current `.js` beside a
# `.wasm` a build old, and the deploy would ship a loader calling into exports
# the module does not have. Checking only the first file found would pass this.
touch "${WASMREPO}/src/db-backend/src/lib.rs"
touch "${WASM_PKG}/db_backend.js"
run_expect_failure "a half-written package is refused on its OTHER half" \
	"stale WASM build: db_backend_bg.wasm" -- run_deploy_wasm

# ---------------------------------------------------------------------------
section "the cross-repo runner dates the sibling backend it tests against"
# ---------------------------------------------------------------------------
#
# THE TWIN OF `ci/setup-rr-backend.sh`, and it had the identical shape: the
# workspace-locked revision was resolved on the CI-clone path ONLY, so a sibling
# checkout found on disk was used without the pin ever being computed, and the
# binary inside it was chosen by `-x` between `target/release` and
# `target/debug` — first one that exists, not newest. What that decides is which
# `ct-native-replay` the nim/rust/go/lean flow suites replay against, so a
# checkout at last month's revision yields a green run that measured the wrong
# backend and names no revision anywhere.
#
# THE FIXTURE PINS TO ITS OWN COMMITS, never to a branch tip: `REV_NB_OLD` and
# `REV_NB_NEW` are the two commits this suite makes, so what is asserted cannot
# change under it.
#
# The runner is copied into a synthetic checkout so its `target/` logs and its
# `cd src/db-backend` land in the throwaway tree, and `cargo` / `rustc` / `rr`
# — which its own prerequisite check demands by name — are stubbed on PATH.

XREPO="${TEST_ROOT}/xrepo"
XWS="${TEST_ROOT}/xws"
NB="${XWS}/codetracer-native-backend"
mkdir -p "${XREPO}/scripts/docs" "${XREPO}/src/db-backend" "${NB}/src"
cp "${CROSS_REPO}" "${XREPO}/scripts/run-cross-repo-tests.sh"
cp "${CAPTURE_LIB}" "${XREPO}/scripts/docs/deep-review-capture-lib.sh"

for stub in cargo rustc rr; do
	# shellcheck disable=SC2016
	printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" "%s" "$*" >>"${TRACE}"\nexit 0\n' \
		"${stub}" >"${BIN}/${stub}"
	chmod +x "${BIN}/${stub}"
done

git -C "${NB}" init -q
git -C "${NB}" config user.email t@t.local
git -C "${NB}" config user.name t
printf 'pub fn replay() {}\n' >"${NB}/src/main.rs"
printf '[package]\nname = "ct-native-replay"\n' >"${NB}/Cargo.toml"
git -C "${NB}" add -A
git -C "${NB}" commit -qm one
REV_NB_OLD="$(git -C "${NB}" rev-parse HEAD)"
printf 'pub fn replay() { /* two */ }\n' >"${NB}/src/main.rs"
git -C "${NB}" add -A
git -C "${NB}" commit -qm two
REV_NB_NEW="$(git -C "${NB}" rev-parse HEAD)"
git -C "${NB}" config advice.detachedHead false
git -C "${NB}" checkout -q "${REV_NB_OLD}"

# Built after the checkout, and never tracked, so `git ls-files` does not see it.
mkdir -p "${NB}/target/debug" "${NB}/target/release"
printf '#!/usr/bin/env bash\nexit 0\n' >"${NB}/target/debug/ct-native-replay"
chmod +x "${NB}/target/debug/ct-native-replay"

# run_cross <ref>  — `CT_NATIVE_REPLAY_LD_LIBRARY_PATH` short-circuits the
# `nix develop` query, which is the only other expensive step before the guard.
run_cross() {
	: >"${TRACE}"
	PATH="${BIN}:${PATH}" \
		METACRAFT_WORKSPACE_ROOT="${XWS}" \
		RR_BACKEND_REF="$1" \
		CT_NATIVE_REPLAY_LD_LIBRARY_PATH="${TEST_ROOT}/nolibs" \
		bash "${XREPO}/scripts/run-cross-repo-tests.sh" nim-flow 2>&1
}
run_cross_locked() { run_cross "${REV_NB_OLD}"; }
run_cross_moved() { run_cross "${REV_NB_NEW}"; }
run_cross_unpinned() {
	: >"${TRACE}"
	PATH="${BIN}:${PATH}" \
		METACRAFT_WORKSPACE_ROOT="${XWS}" \
		CT_NATIVE_REPLAY_LD_LIBRARY_PATH="${TEST_ROOT}/nolibs" \
		bash "${XREPO}/scripts/run-cross-repo-tests.sh" nim-flow 2>&1
}

HEALTHY_X="$(run_cross_locked)"
assert_contains "${HEALTHY_X}" "verified at ${REV_NB_OLD}" \
	"a sibling at the locked revision is used, and says it was verified"
assert_contains "${HEALTHY_X}" "Using ct-native-replay: ${NB}/target/debug/ct-native-replay" \
	"...and the binary it names is the one from that checkout"

run_expect_failure "a sibling at the WRONG revision is refused" \
	"stale codetracer-native-backend checkout" -- run_cross_moved
WRONG_REV="$(run_cross_moved)"
assert_contains "${WRONG_REV}" "${REV_NB_NEW}" \
	"the refusal names the revision the pin requires"

# THE SECOND, INDEPENDENT QUESTION. `git checkout` of the pinned revision
# leaves the PREVIOUS revision's binary sitting in `target/`, correctly pinned
# and completely stale; the revision check above cannot see it.
touch "${NB}/src/main.rs"
run_expect_failure "a binary older than the sibling's own sources is refused" \
	"stale sibling build: ct-native-replay" -- run_cross_locked
touch "${NB}/target/debug/ct-native-replay"

# THE NEWEST BUILD, NOT THE FIRST THAT EXISTS. `release` was returned whenever
# it was executable, so a release binary from an old revision outranked a debug
# one built minutes ago. Both profiles exist here and `debug` is the newer.
printf '#!/usr/bin/env bash\nexit 0\n' >"${NB}/target/release/ct-native-replay"
chmod +x "${NB}/target/release/ct-native-replay"
touch "${NB}/target/debug/ct-native-replay"
assert_contains "$(run_cross_locked)" \
	"Using ct-native-replay: ${NB}/target/debug/ct-native-replay" \
	"between two profiles the NEWER build is used, not the preferred directory"

# A workstation commit with no workspace lock is ordinary, and dying there would
# make the guard something people route around — but it is SAID, never passed
# over in silence, and the mtime comparison still runs.
assert_contains "$(run_cross_unpinned)" \
	"cannot check whether '${NB}' is at the workspace-locked revision" \
	"an unresolvable pin is spoken out loud rather than passed over"

# ---------------------------------------------------------------------------
section "the nimcache root names the checkout, not just the consumer"
# ---------------------------------------------------------------------------
#
# THE CLUSTER. Thirty-six gates spelled their compiler cache
# `"${CT_NIM_CACHE_ROOT:-/tmp/ct-nim-cache}"/<gate-name>` — a key naming the
# CONSUMER with no component naming the TREE. That keeps two different gates
# apart and is useless for keeping two checkouts of the same gate apart, which
# is the collision that actually happens: this workstation carries ~35
# worktrees of one repository and every one of them can run
# `ci/test/web-bundle-smoke.sh`.
#
# MEASURED when the fix was written: `/tmp/ct-nim-cache` held 34 directories
# and 1.9 GB, of which exactly four carried a checkout key — the ones
# `ci/lib/run-nim-test-lane.sh` writes since it fixed this for itself on
# 2026-09-03. The other thirty were shared by every worktree that had ever run
# that gate.
#
# The failure is silent and points the wrong way: nim reuses a cached artefact
# it believes current, so the loser of a race links objects from a DIFFERENT
# TREE and still reports a clean pass — or a mutation arm reports SURVIVED
# because the mutation it planted was never in the bytes it graded.
#
# `ci/lib/nim-cache-root.sh` is the one cause; these contracts are against it,
# and the last two are against the sites actually delegating to it.

NIMCACHE_LIB="${SUITE_ROOT}/ci/lib/nim-cache-root.sh"
assert_file_exists "${NIMCACHE_LIB}" "the shared nimcache-root helper exists"

# Two synthetic checkouts, which is the whole point: same gate name, different
# trees. Real directories rather than strings — the helper checksums a path and
# a path that does not exist would still checksum, so using real ones keeps the
# test honest about what it is measuring.
CK_A="${TEST_ROOT}/checkouts/alpha"
CK_B="${TEST_ROOT}/checkouts/beta"
mkdir -p "${CK_A}" "${CK_B}"

nimcache_for() {
	# `env -u` so an ambient CT_NIM_CACHE_ROOT in the runner's environment
	# cannot silently answer for the helper and turn every contract below
	# green. Measured hazard: `build-error-nav-mutations.sh` exports it.
	# The single quotes are deliberate: `$1` and `$2` are the INNER shell's
	# positional parameters, bound from the arguments after `_`. Expanding them
	# here would inline the paths and stop testing argument passing.
	# shellcheck disable=SC2016
	env -u CT_NIM_CACHE_ROOT bash -c \
		'source "$1"; ct_nim_cache_root "$2"' _ "${NIMCACHE_LIB}" "$1"
}

ROOT_A="$(nimcache_for "${CK_A}")"
ROOT_B="$(nimcache_for "${CK_B}")"

if [[ -n ${ROOT_A} && ${ROOT_A} != "${ROOT_B}" ]]; then
	ok "two checkouts running the same gate get different cache roots"
else
	bad "two checkouts running the same gate get different cache roots" \
		"alpha: ${ROOT_A}" "beta:  ${ROOT_B}"
fi

# The other half, and the one a careless fix breaks: a root that differed per
# INVOCATION would end the collision by ending caching, turning every gate into
# a cold compile. That would look like a pass here if only difference were
# asserted.
if [[ "$(nimcache_for "${CK_A}")" == "${ROOT_A}" ]]; then
	ok "...and the same checkout gets the same root twice, so the cache is reused"
else
	bad "...and the same checkout gets the same root twice, so the cache is reused" \
		"first: ${ROOT_A}" "second: $(nimcache_for "${CK_A}")"
fi

assert_contains "${ROOT_A}" "alpha" \
	"the root carries the checkout's name, so a human can read the directory listing"

# A caller that sets it has said which directory it wants — usually because it
# is handing a scratch directory to a child it is about to grade. Second-guessing
# that would break `ci/test/build-error-nav-mutations.sh`.
EXPLICIT="$(CT_NIM_CACHE_ROOT="${TEST_ROOT}/explicit-cache" bash -c \
	'source "$1"; ct_nim_cache_root "$2"' _ "${NIMCACHE_LIB}" "${CK_A}")"
assert_contains "${EXPLICIT}" "${TEST_ROOT}/explicit-cache" \
	"an explicit CT_NIM_CACHE_ROOT is still honoured verbatim"

# The helper is sourced by the shell gates and EXECUTED by justfile recipes,
# which run under `sh` and cannot source a bash library. Two entry points that
# disagreed would be a defect that only ever showed up in `just`.
EXEC_MODE="$(cd "${CK_A}" && env -u CT_NIM_CACHE_ROOT "${NIMCACHE_LIB}")"
if [[ ${EXEC_MODE} == "${ROOT_A}" ]]; then
	ok "run as a command it prints what sourcing it computes, so justfile and gates agree"
else
	bad "run as a command it prints what sourcing it computes, so justfile and gates agree" \
		"executed: ${EXEC_MODE}" "sourced:  ${ROOT_A}"
fi

# AND THE SITES. The contracts above grade the cause; this one grades whether
# the thirty-six consumers actually reach it, because a perfect helper nobody
# calls fixes nothing.
#
# Source text, deliberately, and it is the right question for THIS defect: the
# bug is literally a spelling — a path constant with no checkout in it — so its
# absence is what "fixed" means. This suite's own prose contains the string
# (above), so it is excluded by name rather than by a pattern that might
# quietly exclude a real gate too.
BARE_ROOTS="$(
	grep -rln '/tmp/ct-nim-cache' \
		"${SUITE_ROOT}/ci/test" "${SUITE_ROOT}/scripts" "${SUITE_ROOT}/justfile" 2>/dev/null |
		grep -v 'stale-artefact-guards-test.sh' || true
)"
if [[ -z ${BARE_ROOTS} ]]; then
	ok "no gate, script or justfile recipe spells a bare /tmp/ct-nim-cache any more"
else
	# Unquoted ON PURPOSE: `bad` prints each argument on its own line, and
	# `BARE_ROOTS` is a newline-separated list of paths. Quoting it would report
	# every offending file as one unreadable run-on line.
	# shellcheck disable=SC2086
	bad "no gate, script or justfile recipe spells a bare /tmp/ct-nim-cache any more" \
		"still hardcoding a host-global root:" ${BARE_ROOTS}
fi

# ---------------------------------------------------------------------------
section "a resolver picks the newest build, not the first profile that exists"
# ---------------------------------------------------------------------------
#
# THE CLUSTER. Five fixture regenerators carry the same two resolvers,
# copy-pasted — `ct-instrument` over two profiles and `session-manager` over
# three — each one `break`ing on the first executable candidate:
#
#   src/db-backend/tests/fixtures/wasm-memory-calldata/regenerate.sh
#   src/db-backend/tests/fixtures/wasm-parity-corpus/regenerate.sh
#   src/db-backend/tests/fixtures/wasm-nan-payloads/regenerate.sh
#   .../cross_process/account-balance-with-wasm/regenerate.sh
#   .../cross_process/account-balance-with-wasm/stream-snapshots-demo.sh
#
# "Prefer release" is a preference between two CURRENT builds; applied to
# whatever is on disk it is a preference for whichever is older, because
# `target/release` and `target/debug` are separate directories and neither
# build removes the other.
#
# WHAT IT COSTS HERE is worse than the usual stale-artefact story: these
# scripts do not run a binary and check a result, they REGENERATE COMMITTED
# FIXTURES with it. A stale `ct-instrument` does not fail — it writes a fixture
# in last month's format, which then becomes the ground truth every future
# parity assertion agrees with.
#
# `scripts/run-cross-repo-tests.sh` already fixed this shape for
# `ct-native-replay` (graded above). `ci/lib/newest-build.sh` is that fix
# extracted, so the sixth copy of the regenerator inherits it rather than the
# defect.

NEWEST_LIB="${SUITE_ROOT}/ci/lib/newest-build.sh"
assert_file_exists "${NEWEST_LIB}" "the shared newest-build helper exists"

PROFILES="${TEST_ROOT}/profiles"
mkdir -p "${PROFILES}/release" "${PROFILES}/debug"
printf '#!/usr/bin/env bash\nexit 0\n' >"${PROFILES}/release/tool"
printf '#!/usr/bin/env bash\nexit 0\n' >"${PROFILES}/debug/tool"
chmod +x "${PROFILES}/release/tool" "${PROFILES}/debug/tool"

newest_of() {
	bash -c 'source "$1"; shift; newest_executable "$@"' _ "${NEWEST_LIB}" "$@"
}

# Release is listed FIRST, as the old code preferred it, and is deliberately
# the older file. Explicit mtimes rather than `touch` ordering: `-nt` compares
# whole seconds on some filesystems, and two files written in the same second
# would make this pass for the wrong reason.
touch -t 202001010000 "${PROFILES}/release/tool"
touch -t 202001020000 "${PROFILES}/debug/tool"
assert_contains "$(newest_of "${PROFILES}/release/tool" "${PROFILES}/debug/tool")" \
	"${PROFILES}/debug/tool" \
	"a debug build newer than release wins, though release is preferred"

# The preference is not discarded, only demoted below currency: with equal
# mtimes the earlier argument still wins, which is what "prefer release" was
# always meant to mean.
touch -t 202001030000 "${PROFILES}/release/tool" "${PROFILES}/debug/tool"
assert_contains "$(newest_of "${PROFILES}/release/tool" "${PROFILES}/debug/tool")" \
	"${PROFILES}/release/tool" \
	"...and release still wins a tie between two builds of the same revision"

# A path that exists but is not executable is a half-finished or interrupted
# build, and `cargo` leaves those behind.
chmod -x "${PROFILES}/debug/tool"
touch -t 202001040000 "${PROFILES}/debug/tool"
assert_contains "$(newest_of "${PROFILES}/release/tool" "${PROFILES}/debug/tool")" \
	"${PROFILES}/release/tool" \
	"a newer but non-executable candidate is not chosen"
chmod +x "${PROFILES}/debug/tool"

# Non-zero rather than an empty string, so `... || VAR=""` is the caller saying
# out loud that it accepts absence. An empty string that looked like success
# would flow into `"$BIN" record ...` and fail somewhere unrecognisable.
if bash -c 'source "$1"; newest_executable "$2"' _ "${NEWEST_LIB}" \
	"${TEST_ROOT}/definitely-absent" >/dev/null 2>&1; then
	bad "no executable candidate is a non-zero return, not an empty success" \
		"the command unexpectedly succeeded"
else
	ok "no executable candidate is a non-zero return, not an empty success"
fi

# AND THE SITES, for the same reason as above: the helper is only worth having
# if the five copies reach it. `break` inside the candidate loop is the exact
# shape that was removed, so its return is what regression looks like.
REGENERATORS=(
	"src/db-backend/tests/fixtures/wasm-memory-calldata/regenerate.sh"
	"src/db-backend/tests/fixtures/wasm-parity-corpus/regenerate.sh"
	"src/db-backend/tests/fixtures/wasm-nan-payloads/regenerate.sh"
	"src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/regenerate.sh"
	"src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm/stream-snapshots-demo.sh"
)
NOT_DELEGATING=()
for regen in "${REGENERATORS[@]}"; do
	full="${SUITE_ROOT}/${regen}"
	if [[ ! -f ${full} ]]; then
		NOT_DELEGATING+=("${regen} (missing)")
	elif ! grep -q 'newest_executable' "${full}"; then
		NOT_DELEGATING+=("${regen} (does not call newest_executable)")
	elif grep -q 'for candidate in' "${full}"; then
		NOT_DELEGATING+=("${regen} (still resolves by first-existing)")
	fi
done
if [[ ${#NOT_DELEGATING[@]} -eq 0 ]]; then
	ok "all five fixture regenerators resolve through the shared helper"
else
	bad "all five fixture regenerators resolve through the shared helper" \
		"${NOT_DELEGATING[@]}"
fi

# ---------------------------------------------------------------------------
section "a contrast spec refuses a stylesheet older than the styl it came from"
# ---------------------------------------------------------------------------
#
# THE CLUSTER. Five contrast/layout specs carried the same resolver — return
# the first candidate directory in which the built `.css` exists:
#
#   src/tests/gui/tests/debug-controls/toolbar-marks-contrast.spec.ts
#   src/tests/gui/tests/build/build-panel-contrast-guard.spec.ts
#   src/tests/gui/tests/status-bar/footer-contrast-guard.spec.ts
#   src/tests/gui/tests/status-bar/footer-visibility-css-guard.spec.ts
#   src/tests/gui/tests/session-chrome/edit-toolbar-layout.spec.ts
#
# The stylesheet is not an input to these specs, it is the SUBJECT of them.
# Resolving it by existence means the measurement is taken from whatever CSS
# was last compiled, which after an edit to any `.styl` is the previous build —
# so the spec reports green about a file nobody changed and stays green through
# the regression it was written to catch.
#
# EVERY ONE OF THE FIVE SAID SO IN ITS OWN WORDS, which is the tell this whole
# suite exists to notice. `build-panel-contrast-guard.spec.ts` put it in the
# error message of the very function that could not detect it: "run `just
# build-once` after editing any `.styl`, or this measures the previous build".
# `toolbar-marks-contrast.spec.ts`: "a stale stylesheet is not detectable from
# here" — in a file whose NEXT function compares its bundle's mtime against the
# two `.nim` views it is built from. The fix was already in the building, ten
# lines below the defect.
#
# WHY THIS RUNS THE `.cjs` AND NOT THE `.ts`: there is no `tsc` in the
# repository's node_modules and this suite's lane has no npm install, so a
# resolver written only as TypeScript could never be watched going red. The
# implementation is therefore plain CommonJS that `node` runs with no toolchain,
# and `built-theme-css.ts` is a types-only binding over it — one implementation,
# not two copies.

CSS_LIB="${SUITE_ROOT}/src/tests/gui/lib/built-theme-css.cjs"
CSS_TYPES="${SUITE_ROOT}/src/tests/gui/lib/built-theme-css.ts"
assert_file_exists "${CSS_LIB}" "the shared built-CSS resolver exists"
assert_file_exists "${CSS_TYPES}" "...and the typed binding the specs import"

# A synthetic checkout with the two build variants that are routinely BOTH
# present — `src/build-debug` from tup and `src/build-debug-repro` from
# reprobuild, neither of which removes the other.
CSSTREE="${TEST_ROOT}/csstree"
mkdir -p "${CSSTREE}/src/frontend/styles/components" \
	"${CSSTREE}/src/build-debug/frontend/styles" \
	"${CSSTREE}/src/build-debug-repro/frontend/styles"
printf '.x { color: red }\n' >"${CSSTREE}/src/frontend/styles/components/status_bar.styl"
printf '.x{color:red}\n' >"${CSSTREE}/src/build-debug/frontend/styles/theme.css"
printf '.x{color:red}\n' >"${CSSTREE}/src/build-debug-repro/frontend/styles/theme.css"

resolve_css() {
	node -e '
		const { resolveBuiltThemeCss } = require(process.argv[1]);
		try {
			process.stdout.write(resolveBuiltThemeCss(process.argv[2], process.argv[3]));
		} catch (e) {
			process.stdout.write("REFUSED: " + e.message);
			process.exit(1);
		}
	' "${CSS_LIB}" "${CSSTREE}" theme.css 2>&1
}

# `src/build-debug` is listed first and is the older of the two. The old
# resolver returned it for that reason alone.
touch -t 202001010000 "${CSSTREE}/src/frontend/styles/components/status_bar.styl"
touch -t 202001020000 "${CSSTREE}/src/build-debug/frontend/styles/theme.css"
touch -t 202001030000 "${CSSTREE}/src/build-debug-repro/frontend/styles/theme.css"

assert_contains "$(resolve_css)" "build-debug-repro/frontend/styles/theme.css" \
	"between two build variants the NEWER stylesheet is used, not the first listed"

# THE SECOND, INDEPENDENT QUESTION, and the one the whole cluster was missing:
# the winner may still predate its own sources. Editing a component `.styl` is
# exactly what a developer does before running one of these specs.
touch -t 202001040000 "${CSSTREE}/src/frontend/styles/components/status_bar.styl"
STALE_CSS="$(resolve_css)"
assert_contains "${STALE_CSS}" "is STALE" \
	"a stylesheet older than a .styl under src/frontend/styles is refused"
assert_contains "${STALE_CSS}" "components/status_bar.styl" \
	"...and the refusal names the source file that outdates it"
assert_contains "${STALE_CSS}" "just build-once" \
	"...and says what to run, so the refusal is actionable rather than a puzzle"

# The other direction, which is what makes the contract above meaningful: a
# guard that refused everything would also have passed those three.
touch -t 202001050000 "${CSSTREE}/src/build-debug-repro/frontend/styles/theme.css"
assert_contains "$(resolve_css)" "build-debug-repro/frontend/styles/theme.css" \
	"a stylesheet rebuilt after the .styl edit is accepted again"

# Absence still fails loudly and says where it looked. A resolver answering ""
# would reach `page.addStyleTag({ path: "" })`, which does not obviously fail —
# and a contrast assertion against an unstyled page measures browser defaults
# and can PASS.
MISSING_CSS="$(node -e '
	const { resolveBuiltThemeCss } = require(process.argv[1]);
	try {
		process.stdout.write(resolveBuiltThemeCss(process.argv[2], process.argv[3]));
	} catch (e) {
		process.stdout.write("REFUSED: " + e.message);
	}
' "${CSS_LIB}" "${CSSTREE}" absent_theme.css 2>&1)"
assert_contains "${MISSING_CSS}" "not found" \
	"a missing stylesheet is refused rather than returned as an empty path"
assert_contains "${MISSING_CSS}" "build-debug" \
	"...and the refusal lists the directories it looked in"

# AND THE SITES.
CONTRAST_SPECS=(
	"src/tests/gui/tests/debug-controls/toolbar-marks-contrast.spec.ts"
	"src/tests/gui/tests/build/build-panel-contrast-guard.spec.ts"
	"src/tests/gui/tests/status-bar/footer-contrast-guard.spec.ts"
	"src/tests/gui/tests/status-bar/footer-visibility-css-guard.spec.ts"
	"src/tests/gui/tests/session-chrome/edit-toolbar-layout.spec.ts"
)
CSS_NOT_DELEGATING=()
for spec in "${CONTRAST_SPECS[@]}"; do
	full="${SUITE_ROOT}/${spec}"
	if [[ ! -f ${full} ]]; then
		CSS_NOT_DELEGATING+=("${spec} (missing)")
	elif ! grep -q 'resolveBuiltThemeCss' "${full}"; then
		CSS_NOT_DELEGATING+=("${spec} (does not call resolveBuiltThemeCss)")
	elif grep -q 'if (fs.existsSync(candidate)) return candidate;' "${full}"; then
		CSS_NOT_DELEGATING+=("${spec} (still resolves by first-existing)")
	fi
done
if [[ ${#CSS_NOT_DELEGATING[@]} -eq 0 ]]; then
	ok "all five contrast specs resolve their stylesheet through the shared helper"
else
	bad "all five contrast specs resolve their stylesheet through the shared helper" \
		"${CSS_NOT_DELEGATING[@]}"
fi

# ---------------------------------------------------------------------------
printf '\n'
printf 'stale-artefact-guards-test summary: expected=%d executed=%d failed=%d\n' \
	"${EXPECTED_ASSERTIONS}" "${ASSERTIONS}" "${FAILURES}"
if [[ ${ASSERTIONS} -ne ${EXPECTED_ASSERTIONS} ]]; then
	echo "stale-artefact-guards-test: expected ${EXPECTED_ASSERTIONS} assertions, ran ${ASSERTIONS}." >&2
	echo "A contract was deleted or short-circuited; update EXPECTED_ASSERTIONS deliberately." >&2
	exit 3
fi
if [[ ${FAILURES} -ne 0 ]]; then
	echo "stale-artefact-guards-test: ${FAILURES} contract(s) failed." >&2
	exit 1
fi
echo "stale-artefact-guards-test: all contracts hold."
