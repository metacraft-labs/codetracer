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
# `ci/setup-rr-backend.sh`, which USED TO assign a `REPO_ROOT` of its own. That
# script now names it `RR_REPO_ROOT` and DECLARES what it leaks, and
# `ci/test/sourced-var-collision-gate.sh` holds it to that declaration — so the
# collision this name avoids can no longer be reintroduced silently. The name
# stays as it is: `SUITE_ROOT` says which script owns it, which is the property
# worth keeping. See the long note above `rr_guard` for what the collision cost.
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
BUILD_COMPONENTS="${SUITE_ROOT}/scripts/build-storybook-components.sh"
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
BUILD_SIBLINGS="${SUITE_ROOT}/scripts/build-siblings.sh"

# Every contract this suite claims to check. A suite that silently runs fewer
# assertions than it advertises is a suite that stops protecting anything, so
# the count is asserted at the end and has to be changed deliberately.
EXPECTED_ASSERTIONS=170

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

for required in "${VISUAL_CAPTURE}" "${STORYBOOK_FRESHNESS}" "${STORYBOOK_DEPS}" "${BUILD_COMPONENTS}" \
	"${RR_SETUP}" "${SETUP_CERTS}" "${WEBP}" "${CAPTURE_LIB}" \
	"${DESKTOP_COMPONENT}" "${DEVELOPER_SETUP}" "${DEPLOY_WASM}" \
	"${CROSS_REPO}" "${DESKTOP_CAPS}" "${VERSION_NIM}" "${BUILD_SIBLINGS}"; do
	if [[ ! -f ${required} ]]; then
		echo "stale-artefact-guards-test: missing '${required}'" >&2
		exit 3
	fi
done
for tool in git just node openssl sha256sum; do
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
# Deliberately inherit unrelated command selectors in the healthy capture,
# recording and vendored cases below. The helpers must select their throwaway
# sibling even inside a dev environment that exports the real workspace's MCR.
AMBIENT_MCR="${TEST_ROOT}/unrelated-workspace/ct_cli"

# `run_visual_capture` photographs a SUPPLIED trace; `run_visual_recording` has
# the script record one first, which is the only path that reaches the GL scene
# fixture. Two functions rather than one with an argument, so they can be handed
# to `run_expect_failure` by name.
run_visual_capture() {
	: >"${TRACE}"
	# The capture script must discover the fixture sibling, not an inherited
	# command from the developer's environment.
	PATH="${BIN}:${PATH}" \
		NATIVE_RECORDER_REPO="${WS}/codetracer-native-recorder" \
		VISUAL_REPLAY_REPO="${WS}/codetracer-visual-replay" \
		NATIVE_TEST_PROGRAMS_REPO="${WS}/codetracer-native-test-programs" \
		CODETRACER_BOOK_SCREENSHOT_DIR="${SHOTS}" \
		CODETRACER_REAL_VISUAL_TRACE="${TEST_ROOT}/provided.ct" \
		env -u CODETRACER_CT_MCR_CMD -u CT_MCR bash "${VISUAL_CAPTURE}" 2>&1
}

run_visual_recording() {
	: >"${TRACE}"
	PATH="${BIN}:${PATH}" \
		NATIVE_RECORDER_REPO="${WS}/codetracer-native-recorder" \
		VISUAL_REPLAY_REPO="${WS}/codetracer-visual-replay" \
		NATIVE_TEST_PROGRAMS_REPO="${WS}/codetracer-native-test-programs" \
		CODETRACER_BOOK_SCREENSHOT_DIR="${SHOTS}" \
		env -u CODETRACER_CT_MCR_CMD -u CT_MCR bash "${VISUAL_CAPTURE}" 2>&1
}

# -- healthy: every binary is newer than its own sources ---------------------
HEALTHY="$(CODETRACER_CT_MCR_CMD="${AMBIENT_MCR}" CT_MCR="${AMBIENT_MCR}" run_visual_capture)"
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
RECORDED="$(CODETRACER_CT_MCR_CMD="${AMBIENT_MCR}" CT_MCR="${AMBIENT_MCR}" run_visual_recording)"
assert_contains "${RECORDED}" "Recording visual trace for book screenshots" \
	"with no supplied trace the capture records one with the fresh fixture"
assert_contains "$(cat "${TRACE}")" $'codetracer-native-recorder\trecord --interpose' \
	"recording uses the throwaway recorder despite inherited MCR selectors"

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
NOT_GIT_OUT="$(CODETRACER_CT_MCR_CMD="${AMBIENT_MCR}" CT_MCR="${AMBIENT_MCR}" \
	PATH="${BIN}:${PATH}" \
	NATIVE_RECORDER_REPO="${NOT_GIT}" \
	VISUAL_REPLAY_REPO="${WS}/codetracer-visual-replay" \
	NATIVE_TEST_PROGRAMS_REPO="${WS}/codetracer-native-test-programs" \
	CODETRACER_BOOK_SCREENSHOT_DIR="${SHOTS}" \
	CODETRACER_REAL_VISUAL_TRACE="${TEST_ROOT}/provided.ct" \
	env -u CODETRACER_CT_MCR_CMD -u CT_MCR bash "${VISUAL_CAPTURE}" 2>&1)"
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

# EVERY MTIME BELOW IS STATED, NOT RACED FOR — same reason, and the same
# remedy, as the `newest_executable` fixture further down (search for
# "202001010000"): "two files written in the same second would make this pass
# for the wrong reason".
#
# Here it made one FAIL for the wrong reason. `requireFreshStorybookStatic`
# compares STRICTLY (`stat.mtimeMs > referenceMs`), so equal mtimes read as
# fresh. This section used bare `touch`es to order the corpus against its
# sources, and two of the pairs were ADJACENT STATEMENTS with no work between
# them — a rebuild of the corpus immediately followed by a touch of a file that
# has to come out strictly newer. Those land in the same coarse clock tick
# (~1-10ms depending on CONFIG_HZ, and whole seconds on a filesystem with
# one-second mtime granularity) often enough to be seen: `lint-bash` failed with
#
#     FAIL a rebuilt renderer makes the copied corpus stale
#            the command unexpectedly succeeded
#            output: FRESH
#
# which is what this assertion prints when ui.js did NOT come out newer.
#
# A rerun is not evidence either way — the window is one tick, so a rerun very
# likely passes by winning the race. The deterministic repro is to give the two
# files the SAME stamp on purpose, which fails 100% against the strict compare.
#
# The stamps run Jan 1 -> Jan 8 2020, one day apart, in the order the assertions
# need. NOTHING IS WEAKENED: each "stale" step still puts its source strictly
# NEWER than the corpus, so the guard must still refuse it; the ordering is now
# established by construction instead of by timing luck.
SB_T_SOURCES=202001010000  # every source file, the baseline
SB_T_BUILT=202001020000    # the corpus: newer than all of them => FRESH
SB_T_STORY=202001030000    # a story file outruns the build
SB_T_REBUILD1=202001040000 # corpus rebuilt, fresh again
SB_T_RENDERER=202001050000 # the copied renderer outruns the build
SB_T_REBUILD2=202001060000 # corpus rebuilt, fresh again
SB_T_NIM=202001070000      # a Nim source outruns the components bundle
SB_T_REBUILD3=202001080000 # both artefacts rebuilt, fresh again
SB_T_PROGRAM=202001090000  # a compiled test program beside its .nim
SB_T_NIM2=202001100000     # a Nim source outruns an unchanged bundle
SB_T_STAMP=202001110000    # the bundle recompiled unchanged: only its stamp moves

# `firstNewerThan` walks directories but only ever COMPARES files (it recurses
# on `isDirectory()` and stats the leaves), so stamping the files is enough and
# directory mtimes do not matter here.
touch -t "${SB_T_SOURCES}" \
	"${SB}/storybook/.storybook/main.ts" \
	"${SB}/storybook/stories/One.stories.js" \
	"${SB}/storybook/scripts/check.mjs" \
	"${SB}/storybook/package.json" \
	"${SB}/storybook/package-lock.json" \
	"${SB}/storybook/dist/components.js" \
	"${SB}/src/frontend/index.html" \
	"${SB}/src/frontend/ui.nim" \
	"${SB}/src/build-debug/frontend/ui.js" \
	"${SB}/src/build-debug/public/index.css"
touch -t "${SB_T_BUILT}" "${SB}/storybook/storybook-static/index.html"

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

touch -t "${SB_T_STORY}" "${SB}/storybook/stories/One.stories.js"
run_expect_failure "a story file newer than the built corpus is refused" \
	"Stale storybook corpus" -- check_storybook
assert_contains "$(check_storybook)" "One.stories.js" \
	"the refusal names the story file that outran the build"
touch -t "${SB_T_REBUILD1}" "${SB}/storybook/storybook-static/index.html"

# The staticDirs copy is the half a reader is least likely to think of: the
# renderer build tree is INSIDE storybook-static, so a `just build-once` between
# two review rounds makes the corpus a picture of the previous renderer.
#
# THIS IS THE PAIR THAT FAILED IN CI. The corpus rebuild above and the renderer
# touch below were adjacent bare `touch`es; ui.js has to come out STRICTLY newer
# and, at one clock tick apart, sometimes did not.
touch -t "${SB_T_RENDERER}" "${SB}/src/build-debug/frontend/ui.js"
run_expect_failure "a rebuilt renderer makes the copied corpus stale" \
	"ui.js" -- check_storybook
touch -t "${SB_T_REBUILD2}" "${SB}/storybook/storybook-static/index.html"

# The same adjacent-touch shape as the pair above. It has not been seen to fail,
# and only because `src/frontend` is not in the FIRST check's source list — its
# `ui.nim` is compared against `dist/components.js` by the SECOND check instead,
# which happens to leave a wider gap. That is an accident of which list a path
# is on, not a property anybody chose; stamped like the rest so it stays true.
touch -t "${SB_T_NIM}" "${SB}/src/frontend/ui.nim"
run_expect_failure "Nim sources newer than the components bundle are refused" \
	"Stale storybook components" -- check_storybook
touch -t "${SB_T_REBUILD3}" "${SB}/storybook/dist/components.js" \
	"${SB}/storybook/storybook-static/index.html"
assert_contains "$(check_storybook)" "FRESH" \
	"rebuilding both artefacts makes it green again"

# A test program `nim c` wrote beside its source (no `-o`: an extensionless
# executable named after the .nim) is an output of that compile, not a source
# of the bundle. Counted as one, compiling a test under src/frontend made the
# next check refuse a fresh build. The same file without the executable bit,
# or with no .nim beside it, is still a source.
printf '\177ELF\n' >"${SB}/src/frontend/ui"
chmod +x "${SB}/src/frontend/ui"
touch -t "${SB_T_PROGRAM}" "${SB}/src/frontend/ui"
assert_contains "$(check_storybook)" "FRESH" \
	"a compiled Nim test program beside its source is not a source"
chmod -x "${SB}/src/frontend/ui"
run_expect_failure "...but a newer extensionless file that is not a program is" \
	"Stale storybook components" -- check_storybook
rm -f "${SB}/src/frontend/ui"
assert_contains "$(check_storybook)" "FRESH" \
	"...and removing it makes it green again"

# `just build-storybook-components` touches a compile stamp beside the bundle
# and leaves the bundle itself alone (`nim js` does not rewrite identical
# output), so a recompile that changes nothing does not make storybook-static
# older than the bundle it copied. The bundle is current with its Nim sources
# as of the later of the two, and the stamp is no source of storybook-static:
# here it is newer than the corpus, and the corpus is still fresh.
touch -t "${SB_T_NIM2}" "${SB}/src/frontend/ui.nim"
touch -t "${SB_T_STAMP}" "${SB}/storybook/dist/components.js.compiled"
assert_contains "$(check_storybook)" "FRESH" \
	"a compile stamp newer than the Nim source keeps an unchanged bundle current, and the corpus fresh"
rm -f "${SB}/storybook/dist/components.js.compiled"
run_expect_failure "...and without the stamp the same bundle is refused" \
	"Stale storybook components" -- check_storybook
touch -t "${SB_T_NIM}" "${SB}/src/frontend/ui.nim"

rm -f "${SB}/storybook/storybook-static/index.html"
run_expect_failure "an absent corpus is still refused, with the remedy" \
	"just storybook-build" -- check_storybook

# ---------------------------------------------------------------------------
section "A components build that Nim left unchanged is still a fresh build"
# ---------------------------------------------------------------------------
#
# codetracer-pm issues/2026-11-04-capture-storybook-refuses-a-fresh-build-as-stale.md.
# Nim does not rewrite an output whose bytes would not change, so after a
# SUCCESSFUL compile the bundle kept its old mtime, and the guard refused every
# capture that followed it, naming a rebuild that changed nothing. This section
# runs the recipe itself (`just --no-deps` skips the story generation it depends
# on) with a stub `nim` on PATH that does what Nim does on an unchanged output:
# exit 0 and write nothing. Nothing else is stubbed.

CB="${TEST_ROOT}/components-repo"
CB_BIN="${TEST_ROOT}/components-bin"
CB_NIM_CALLS="${TEST_ROOT}/components-nim-calls.log"
CB_REF="${TEST_ROOT}/components-ref"
mkdir -p "${CB}/storybook/.storybook" "${CB}/storybook/stories" "${CB}/storybook/scripts" \
	"${CB}/storybook/dist" "${CB}/storybook/storybook-static" \
	"${CB}/src/frontend" "${CB}/src/build-debug/frontend" "${CB}/src/build-debug/public" \
	"${CB}/scripts" "${CB_BIN}"
cp "${SUITE_ROOT}/justfile" "${CB}/justfile"
cp "${BUILD_COMPONENTS}" "${CB}/scripts/"
printf 'x\n' >"${CB}/storybook/.storybook/main.ts"
printf 'x\n' >"${CB}/storybook/stories/One.stories.js"
printf 'x\n' >"${CB}/storybook/scripts/check.mjs"
printf '{}\n' >"${CB}/storybook/package.json"
printf '{}\n' >"${CB}/storybook/package-lock.json"
printf 'x\n' >"${CB}/src/frontend/index.html"
printf 'x\n' >"${CB}/src/frontend/ui.nim"
printf 'x\n' >"${CB}/src/frontend/storybook_components.nim"
printf 'x\n' >"${CB}/src/build-debug/frontend/ui.js"
printf 'x\n' >"${CB}/src/build-debug/public/index.css"
printf 'x\n' >"${CB}/storybook/dist/components.js"
printf 'x\n' >"${CB}/storybook/storybook-static/index.html"

# The stub records its argv, then fails when NIM_FAIL is set. On success it
# leaves the output alone, which is what an unchanged compile looks like, unless
# NIM_WRITE is set: then it rewrites the bundle, as a compile that changed it does.
cat >"${CB_BIN}/nim" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${CB_NIM_CALLS}"
[[ -z "\${NIM_FAIL:-}" ]] || exit 1
[[ -z "\${NIM_WRITE:-}" ]] || printf 'y\n' >"${CB}/storybook/dist/components.js"
STUB
chmod +x "${CB_BIN}/nim"

# Stated mtimes: the bundle is an old build, and the Nim source is newer than it,
# so the guard must refuse until the recipe rebuilds the bundle.
touch -t 202001010000 "${CB}/storybook/.storybook/main.ts" "${CB}/storybook/stories/One.stories.js" \
	"${CB}/storybook/scripts/check.mjs" "${CB}/storybook/package.json" \
	"${CB}/storybook/package-lock.json" "${CB}/src/frontend/index.html" \
	"${CB}/src/frontend/storybook_components.nim" "${CB}/src/build-debug/frontend/ui.js" \
	"${CB}/src/build-debug/public/index.css"
touch -t 202001020000 "${CB}/storybook/dist/components.js"
touch -t 202001030000 "${CB}/src/frontend/ui.nim"
touch -t 202001060000 "${CB}/storybook/storybook-static/index.html"

cat >"${TEST_ROOT}/check-components.mjs" <<MJS
import { requireFreshStorybookStatic } from "${STORYBOOK_FRESHNESS}";
try {
  requireFreshStorybookStatic(process.argv[2]);
  console.log("FRESH");
} catch (error) {
  console.error(error.message);
  process.exit(1);
}
MJS

check_components() { node "${TEST_ROOT}/check-components.mjs" "${CB}" 2>&1; }
build_components() { (cd "${CB}" && PATH="${CB_BIN}:${PATH}" just --no-deps build-storybook-components 2>&1); }

# The recipe's compile, as a developer runs it. `storybook-build` writes the
# corpus after the bundle, so the corpus is touched next, as it would be.
build_out="$(build_components)"
build_status=$?
if [[ ${build_status} -eq 0 ]]; then
	ok "the components recipe succeeds when nim does"
else
	bad "the components recipe succeeds when nim does" "output: ${build_out:0:600}"
fi
assert_contains "$(cat "${CB_NIM_CALLS}")" "js src/frontend/storybook_components.nim" \
	"the recipe compiles the components entry point"
touch "${CB}/storybook/storybook-static/index.html"
assert_contains "$(check_components)" "FRESH" \
	"a bundle the recipe has just built is fresh, though nim left it unchanged"
bundle="${CB}/storybook/dist/components.js"
compiled_stamp="${bundle}.compiled"
touch -t 202001020000 "${CB_REF}"
if [[ ! ${bundle} -nt ${CB_REF} && ! ${CB_REF} -nt ${bundle} ]]; then
	ok "a compile nim left unchanged leaves the bundle's mtime alone"
else
	bad "a compile nim left unchanged leaves the bundle's mtime alone" "the bundle's mtime moved"
fi

# `storybook-static` copies the bundle, so a recompile that changes nothing (the
# low-level-code gate recompiles it) must not leave the corpus older than an
# identical bundle: the stamp beside the bundle moves, the bundle does not.
sleep 1
build_components >/dev/null
assert_contains "$(check_components)" "FRESH" \
	"a recompile that changes nothing leaves the corpus built before it fresh"

# A Nim source edited after that build is still refused. The sleep makes the
# edit strictly newer than the stamp on a filesystem with one-second mtimes.
sleep 1
touch "${CB}/src/frontend/ui.nim"
run_expect_failure "a Nim source edited after that build is still refused" \
	"Stale storybook components" -- check_components
assert_contains "$(check_components)" "ui.nim" \
	"the refusal names the Nim source that was edited"

# A compile that fails must not stamp the bundle: the guard keeps refusing.
touch -r "${CB}/storybook/dist/components.js" "${CB_REF}"
touch -r "${compiled_stamp}" "${CB_REF}.compiled"
fail_out="$(NIM_FAIL=1 build_components)"
fail_status=$?
if [[ ${fail_status} -ne 0 ]]; then
	ok "a failed compile fails the recipe"
else
	bad "a failed compile fails the recipe" "output: ${fail_out:0:600}"
fi
if [[ ! ${bundle} -nt ${CB_REF} && ! ${CB_REF} -nt ${bundle} ]]; then
	ok "a failed compile does not restamp the bundle"
else
	bad "a failed compile does not restamp the bundle" "the bundle's mtime changed"
fi
if [[ ! ${compiled_stamp} -nt ${CB_REF}.compiled && ! ${CB_REF}.compiled -nt ${compiled_stamp} ]]; then
	ok "a failed compile does not move the compile stamp"
else
	bad "a failed compile does not move the compile stamp" "the stamp's mtime changed"
fi
run_expect_failure "a failed compile leaves the bundle refused" \
	"Stale storybook components" -- check_components

# A successful rebuild after the edit is fresh again.
build_out="$(build_components)"
build_status=$?
if [[ ${build_status} -eq 0 ]]; then
	ok "a successful rebuild after the edit succeeds"
else
	bad "a successful rebuild after the edit succeeds" "output: ${build_out:0:600}"
fi
touch "${CB}/storybook/storybook-static/index.html"
assert_contains "$(check_components)" "FRESH" \
	"a successful rebuild after the edit makes it fresh again"

# A compile that does rewrite the bundle dates it at the compile's start, as the
# stamp is: an edit made while nim read the sources must not read as built.
NIM_WRITE=1 build_components >/dev/null
if [[ ! ${bundle} -nt ${compiled_stamp} && ! ${compiled_stamp} -nt ${bundle} ]]; then
	ok "a bundle nim rewrote is dated at the compile's start, like the stamp"
else
	bad "a bundle nim rewrote is dated at the compile's start, like the stamp" \
		"bundle and stamp mtimes differ"
fi

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
# Always in a SUBSHELL: sourcing it assigns `RR_REPO_ROOT` and `CLONE_DIR`, and
# the subshell is what keeps those assignments from reaching this suite. The
# subshell is now BELT AND BRACES rather than the only defence — neither of
# those names can collide with anything here — but it stays, because what it
# actually contains is the `cd` and the PATH edits, not just the two variables.
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
#
# BOTH SIDES ARE RENAMED NOW, and the second one is what closes the class.
# Renaming only this suite left `ci/setup-rr-backend.sh` free to collide with
# the NEXT script that sources it, and nothing would have said so. That file
# now declares what it leaks (`ct-leaks: CLONE_DIR`) and
# `ci/test/sourced-var-collision-gate.sh` fails if it ever leaks anything else.
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
# `RR_BACKEND_REF` may name a branch (the workflow step used to pass `dev`). A
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

# -- a FRESH clone of a ref the repository does not have is a refusal --------
#
# The clone path (no sibling at `$CLONE_DIR`) answered a failed
# `git checkout "$ref"` with "Warning: ref not found, falling back to main" and
# went on to build `main` — a tree nobody pinned — while the job reported the
# pinned revision it had been asked for. The script's own header promised
# "there is no main fallback". The pinned ref now comes from flake.lock (the
# workflow passes a commit), so a mistyped or unpublished pin is exactly what
# this path must refuse.
#
# The clone URL is the real GitHub one; a temporary global git config maps it
# onto a local fixture with `insteadOf`, the same mechanism the script itself
# uses for credentials, so no network or token is involved. The fixture HAS a
# `main`, so the old fallback would have succeeded — the case can only pass by
# refusing.
CLONE_UPSTREAM="${TEST_ROOT}/clone-upstream-backend"
git clone -q "${BACKEND}" "${CLONE_UPSTREAM}"
git -C "${CLONE_UPSTREAM}" branch -q -f main "${REV_NEW}"
CLONE_GITCONFIG="${TEST_ROOT}/clone-gitconfig"
git config --file "${CLONE_GITCONFIG}" \
	url."file://${CLONE_UPSTREAM}".insteadOf \
	"https://x-access-token:fixture-token@github.com/metacraft-labs/codetracer-native-backend.git"
CLONE_TARGET="${TEST_ROOT}/fresh-clone-backend"
# Sourced in a separate bash, not a subshell of this suite: the fixture
# credentials and the script's assignments never touch this shell, and the
# linter has no subshell-scoped CLONE_DIR to pair with `rr_guard`'s.
# shellcheck disable=SC2016  # the inner script is single-quoted on purpose: $1/$2 are its own arguments
rr_fresh_clone() {
	(cd "${SUITE_ROOT}" &&
		env CLONE_DIR="$1" GH_TOKEN=fixture-token GIT_CONFIG_GLOBAL="$2" \
			bash -c 'source "$1" && clone_rr_backend "$2"' rr-fresh-clone "${RR_SETUP}" "$3") 2>&1
}
CLONE_RC=0
FRESH_CLONE="$(rr_fresh_clone "${CLONE_TARGET}" "${CLONE_GITCONFIG}" \
	0123456789abcdef0123456789abcdef01234567)" || CLONE_RC=$?
FRESH_CLONE="${FRESH_CLONE}"$'\n'"exit=${CLONE_RC}"
assert_not_contains "${FRESH_CLONE}" "exit=0" \
	"a fresh clone of a ref the repository does not have fails"
assert_contains "${FRESH_CLONE}" "0123456789abcdef0123456789abcdef01234567" \
	"...and the refusal names the ref it could not check out"
assert_not_contains "${FRESH_CLONE}" "falling back to main" \
	"...and no other tree is checked out in its place"

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
# exit 0. Presence answers neither "is it still in date" nor "does it cover the
# name this server is reached by".
#
# Since `848e47b0d` the script issues nothing: it VERIFIES the org development
# leaf at `/etc/mcl-dev-certs/codetracer.localhost/` and fails loudly when that
# material is absent, expiring, for the wrong names, or paired with the wrong
# key (metacraft-dev-guidelines `environment-domains-and-dev-certificates.md`
# §5). The cases below grade that, one property at a time.
#
# THE ONE THING THIS SECTION FAKES, AND WHY. The script reads a fixed location
# and by design accepts no override: §5 forbids a dev environment to "accept a
# path from the environment", because an overridable path is one that can be
# pointed at a second root. Run as-is, the cases would grade whatever the host
# happens to have installed — absent on a CI bare-metal host, a real 90-day leaf
# on a workstation — which is neither hermetic nor able to show any guard going
# red. So the script is run from a COPY in which that one assignment is
# rewritten to a fixture directory laid out exactly as §5 specifies, holding a
# fixture root CA and leaves this suite mints. Every other byte of the script
# runs unchanged, and the rewrite is refused unless it matches exactly one line
# and leaves no executable reference to the real location behind, so a renamed
# variable fails this suite instead of silently grading the host.
# A mount namespace bound over `/etc/mcl-dev-certs` would avoid even that edit,
# and was rejected: unprivileged user namespaces are disabled on some runners
# (Ubuntu's AppArmor default), and on a host where the real directory exists an
# overlay merges it with the fixture instead of replacing it.

CERTS_HOME="${TEST_ROOT}/browser-replay"
FIXTURE_DEV_CERTS="${TEST_ROOT}/mcl-dev-certs"
mkdir -p "${CERTS_HOME}"
REAL_CERTS_LINE='MCL_DEV_CERTS=/etc/mcl-dev-certs'
if [[ $(grep -cxF "${REAL_CERTS_LINE}" "${SETUP_CERTS}") != 1 ]]; then
	echo "stale-artefact-guards-test: ${SETUP_CERTS} no longer has exactly one line '${REAL_CERTS_LINE}'." >&2
	echo "  The certificate cases redirect that one assignment to a fixture; update the section with the script." >&2
	exit 3
fi
sed "s|^${REAL_CERTS_LINE}\$|MCL_DEV_CERTS='${FIXTURE_DEV_CERTS}'|" "${SETUP_CERTS}" \
	>"${CERTS_HOME}/setup-certs.sh"
if grep -v '^[[:space:]]*#' "${CERTS_HOME}/setup-certs.sh" | grep -F '/etc/mcl-dev-certs' >/dev/null; then
	echo "stale-artefact-guards-test: the redirected copy of ${SETUP_CERTS} still names /etc/mcl-dev-certs outside a comment." >&2
	echo "  The certificate cases would read the host's real material; update the section with the script." >&2
	exit 3
fi

LEAF_DIR="${FIXTURE_DEV_CERTS}/codetracer.localhost"
FIXTURE_CA_KEY="${TEST_ROOT}/fixture-ca.key"

run_certs() { bash "${CERTS_HOME}/setup-certs.sh" 2>&1; }

# mint_leaf <days> <subjectAltName> — a leaf signed by the fixture root, with a
# fresh key that belongs to it, written where §5 puts the real one.
mint_leaf() {
	openssl req -new -newkey rsa:2048 -nodes -keyout "${LEAF_DIR}/key.pem" \
		-subj "/CN=codetracer.localhost" -out "${TEST_ROOT}/leaf.csr" >/dev/null 2>&1
	openssl x509 -req -in "${TEST_ROOT}/leaf.csr" -days "$1" \
		-CA "${FIXTURE_DEV_CERTS}/root-ca.crt" -CAkey "${FIXTURE_CA_KEY}" -CAcreateserial \
		-extfile <(printf 'subjectAltName=%s\n' "$2") \
		-out "${LEAF_DIR}/fullchain.pem" >/dev/null 2>&1
}

# Nothing installed: a loud failure that names the location, not an issuance.
run_expect_failure "an absent certificate set is refused loudly, not issued" \
	"${FIXTURE_DEV_CERTS} does not exist" -- run_certs

mkdir -p "${LEAF_DIR}"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${FIXTURE_CA_KEY}" \
	-out "${FIXTURE_DEV_CERTS}/root-ca.crt" -days 30 \
	-subj "/CN=stale-artefact-guards fixture root" >/dev/null 2>&1
# The shape of the real org leaf: an apex and a one-label wildcard.
mint_leaf 90 "DNS:codetracer.localhost,DNS:*.codetracer.localhost"
assert_contains "$(run_certs)" "TLS material OK" \
	"a valid, in-date, correctly-named certificate is accepted"

# An expiring certificate: presence is unchanged, validity is not.
mint_leaf 1 "DNS:codetracer.localhost,DNS:*.codetracer.localhost"
run_expect_failure "a certificate about to expire is refused, not accepted for existing" \
	"expires within 7 days" -- run_certs

# A certificate for the wrong names: also present, also in date, also useless.
# `*.localhost` covers `codetracer.localhost` but not one label deeper, which is
# where the server is reached — the wildcard rule the script spells out.
mint_leaf 90 "DNS:codetracer.localhost,DNS:*.localhost"
run_expect_failure "a certificate covering the wrong names is refused" \
	"does not cover 'replay.codetracer.localhost'" -- run_certs

# A key that does not belong to the certificate: present, in date, correctly
# named and still unusable — what a partial activation leaves behind.
mint_leaf 90 "DNS:codetracer.localhost,DNS:*.codetracer.localhost"
openssl genrsa -out "${LEAF_DIR}/key.pem" 2048 >/dev/null 2>&1
run_expect_failure "a key that does not belong to the certificate is refused" \
	"does not belong to the certificate" -- run_certs

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
	# `env -u`, for the same reason `nimcache_for` below uses it: the script
	# under test reads THREE environment overrides that name a core binary, and
	# every one of them points OUT OF THIS FIXTURE when it is set.
	#
	# MEASURED, and it is why this block is here rather than being tidy. Inside
	# the codetracer dev shell `CODETRACER_BUILD_DIR` is an absolute path to the
	# real checkout's `src/build-debug`, so it is the FIRST candidate
	# build-desktop-component.sh tries — ahead of `$ROOT_DIR/src/build-debug`,
	# which is the fixture's. The script then correctly observes that the core
	# it was handed lives outside `${DESK}`, says "was supplied from outside",
	# skips the staleness question it cannot ask about a foreign binary, and
	# publishes. Three contracts below went red with "the command unexpectedly
	# succeeded" — and the one above them went GREEN VACUOUSLY, having graded
	# the real repository's `ct` instead of the stale fixture core it built.
	#
	# So the suite passed outside the dev shell and failed inside it, which is
	# the instrument reporting on its own environment rather than on the guard.
	# `CODETRACER_CORE_BIN` and `CODETRACER_E2E_CT_PATH` are unset alongside it
	# because build-desktop-component.sh consults both as `CORE_BIN` defaults;
	# neither is exported by the dev shell today, but a fixture that is hermetic
	# only against the variable that happened to bite is not hermetic.
	#
	# Unset rather than overridden: pointing `CODETRACER_BUILD_DIR` at the
	# fixture would exercise the override path, whereas what these contracts
	# grade is the DEFAULT candidate walk.
	env -u CODETRACER_BUILD_DIR -u CODETRACER_CORE_BIN -u CODETRACER_E2E_CT_PATH \
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
#
# THE LIBRARIES IT SOURCES ARE READ FROM THE RUNNER, NOT LISTED HERE. This
# fixture used to copy the runner and one hand-named library. When the runner
# began sourcing `ci/lib/codetracer-home.sh` (`6db923c20`) that list was not
# updated, and all seven cases below died at the `source` line, before the
# guard they exist to show going red. A copy list kept in a second file goes
# stale exactly the way the artefacts this suite grades do, so it is derived
# from the runner's own `source "$REPO_ROOT/<path>"` lines. A runner in which
# that pattern finds nothing is refused rather than copied bare.

XREPO="${TEST_ROOT}/xrepo"
XWS="${TEST_ROOT}/xws"
NB="${XWS}/codetracer-native-backend"
mkdir -p "${XREPO}/scripts" "${XREPO}/src/db-backend" "${NB}/src"
cp "${CROSS_REPO}" "${XREPO}/scripts/run-cross-repo-tests.sh"
# shellcheck disable=SC2016 # `$REPO_ROOT` is matched literally in the runner's text
mapfile -t XREPO_SOURCED < <(sed -nE 's#^[[:space:]]*(source|\.)[[:space:]]+"\$REPO_ROOT/([^"]*)".*#\2#p' "${CROSS_REPO}")
if [[ ${#XREPO_SOURCED[@]} -eq 0 ]]; then
	echo "stale-artefact-guards-test: no 'source \"\$REPO_ROOT/...\"' line found in ${CROSS_REPO}." >&2
	echo "  The cross-repo fixture copies exactly what the runner sources, so it cannot be built." >&2
	exit 3
fi
for sourced in "${XREPO_SOURCED[@]}"; do
	if [[ ! -f "${SUITE_ROOT}/${sourced}" ]]; then
		echo "stale-artefact-guards-test: ${CROSS_REPO} sources '${sourced}', which does not exist." >&2
		exit 3
	fi
	mkdir -p "${XREPO}/$(dirname -- "${sourced}")"
	cp "${SUITE_ROOT}/${sourced}" "${XREPO}/${sourced}"
done

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

# THE RUN REMOVES THE SCRATCH HOME IT MADE, and only that. The runner exports a
# scratch `CODETRACER_HOME` (`ci/lib/codetracer-home.sh`) and never removed it:
# 42 `ct-home-cross-repo.*` directories had piled up in /tmp on one
# workstation (codetracer-pm issue
# `2026-10-26-run-cross-repo-tests-never-removes-the-scratch-codetracer-home-it-creates.md`).
# Each run here gets its own TMPDIR and no inherited home, so the home it makes
# is the only `ct-home-cross-repo.*` there. A `cargo` stub records the home the
# run's tests were given, which proves a home was made and used (without it,
# "none is left" would hold for a run that never made one).
XTMP="${TEST_ROOT}/xtmp"
HOME_BIN="${TEST_ROOT}/home-bin"
HOMES_SEEN="${TEST_ROOT}/homes-seen.txt"
mkdir -p "${XTMP}" "${HOME_BIN}"
# shellcheck disable=SC2016 # expanded by the stub, not here
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${CODETRACER_HOME:-}" >>"%s"\nexit 0\n' \
	"${HOMES_SEEN}" >"${HOME_BIN}/cargo"
chmod +x "${HOME_BIN}/cargo"
# run_cross_in_xtmp <ref> [VAR=value...] — the runner with TMPDIR=${XTMP}.
run_cross_in_xtmp() {
	local ref="$1"
	shift
	: >"${HOMES_SEEN}"
	env -u CODETRACER_HOME "$@" \
		PATH="${HOME_BIN}:${BIN}:${PATH}" \
		TMPDIR="${XTMP}" \
		METACRAFT_WORKSPACE_ROOT="${XWS}" \
		RR_BACKEND_REF="${ref}" \
		CT_NATIVE_REPLAY_LD_LIBRARY_PATH="${TEST_ROOT}/nolibs" \
		bash "${XREPO}/scripts/run-cross-repo-tests.sh" nim-flow >/dev/null 2>&1
}
scratch_homes_left() {
	find "${XTMP}" -maxdepth 1 -name 'ct-home-cross-repo.*' -print 2>/dev/null
}

run_cross_in_xtmp "${REV_NB_OLD}"
assert_contains "$(head -n 1 "${HOMES_SEEN}")" "${XTMP}/ct-home-cross-repo." \
	"a run with no inherited home makes a scratch one and runs its tests under it"
LEFT="$(scratch_homes_left)"
if [[ -z ${LEFT} ]]; then
	ok "...and removes it when it ends"
else
	bad "...and removes it when it ends" "left behind: ${LEFT}"
fi

run_cross_in_xtmp "${REV_NB_NEW}"
LEFT="$(scratch_homes_left)"
if [[ -z ${LEFT} ]]; then
	ok "a run that is refused removes the scratch home it made too"
else
	bad "a run that is refused removes the scratch home it made too" "left behind: ${LEFT}"
fi

INHERITED="${XTMP}/inherited-home"
mkdir -p "${INHERITED}"
run_cross_in_xtmp "${REV_NB_OLD}" CODETRACER_HOME="${INHERITED}"
assert_contains "$(head -n 1 "${HOMES_SEEN}")" "${INHERITED}" \
	"an inherited scratch home is the one the run uses"
if [[ -d ${INHERITED} ]]; then
	ok "...and it is kept: a run removes only the home it made"
else
	bad "...and it is kept: a run removes only the home it made" "removed: ${INHERITED}"
fi

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

# AND THE TUP BUILD. `src/Tuprules.tup` gave every Nim binary its nimcache under
# `/tmp/ct-nim-cache/%B_<kind>`: the binary in the key, not the checkout. Two
# worktrees running `just build-once` at once wrote one cache, and one failed
# "final link failed: bad value" linking ct-test (measured 2026-11-14 by
# concurrent grading agents). The grep above never saw it: it reads ci/test,
# scripts and the justfile, and the build rules are in src/.
#
# The rules now take the root from CT_TUP_NIM_CACHE_ROOT (a Tup `import`),
# which the entry points compute with `ci/lib/nim-cache-root.sh --tup`. Four
# contracts: the helper's tup root is per checkout and stays inside the Windows
# exclusion; every --nimcache in the rules goes through that root; no rule
# line spells the bare host-global root; and every entry point that runs tup
# exports it.
#
# Source text again, for the same reason as above: the defect is a spelling.
# Comment lines are dropped first, because the file's own prose names the old
# path to explain why it is gone.
TUPRULES="${SUITE_ROOT}/src/Tuprules.tup"

tup_root_for() {
	# CT_NIM_CACHE_ROOT is set ON PURPOSE: the tup root must ignore it (a
	# scratch override would leave the Windows exclusion regex and force a
	# full rebuild), so an ambient one cannot be allowed to answer here.
	# shellcheck disable=SC2016 # $1 and $2 are the inner shell's parameters
	CT_NIM_CACHE_ROOT="${TEST_ROOT}/explicit-cache" bash -c \
		'source "$1"; ct_tup_nim_cache_root "$2"' _ "${NIMCACHE_LIB}" "$1"
}
TUP_ROOT_A="$(tup_root_for "${CK_A}")"
TUP_ROOT_B="$(tup_root_for "${CK_B}")"
# The rule's Windows exclusion, as the file spells it, applied to a path the
# compiler would write. Extracted rather than restated so that tightening the
# regex without moving the root (or the reverse) fails here, not on Windows.
NIM_IGNORE_RE="$(sed -n 's/^NIM_SIDE_OUTPUTS_IGNORE = //p' "${TUPRULES}")"
if [[ -n ${TUP_ROOT_A} && ${TUP_ROOT_A} != "${TUP_ROOT_B}" &&
	${TUP_ROOT_A} == "$(nimcache_for "${CK_A}")" && -n ${NIM_IGNORE_RE} ]] &&
	printf '%s\n' "${TUP_ROOT_A}/codetracer_codetracer_binary/@mcodetracer.nim.c" |
	grep -Eq -- "${NIM_IGNORE_RE}"; then
	ok "the tup nimcache root is per checkout, ignores an override, and stays inside the Windows exclusion"
else
	bad "the tup nimcache root is per checkout, ignores an override, and stays inside the Windows exclusion" \
		"alpha: ${TUP_ROOT_A}" "beta:  ${TUP_ROOT_B}" "lane:  $(nimcache_for "${CK_A}")" \
		"NIM_SIDE_OUTPUTS_IGNORE: ${NIM_IGNORE_RE:-<not found>}"
fi

TUP_RULE_LINES="$(grep -v '^[[:space:]]*#' "${TUPRULES}" 2>/dev/null || true)"
TUP_NIMCACHE_ALL="$(grep -c -- '--nimcache:' <<<"${TUP_RULE_LINES}" || true)"
# shellcheck disable=SC2016 # the needle is Tup source text, not an expansion
TUP_NIMCACHE_ROOTED="$(grep -c -- '--nimcache:$(NIM_CACHE_ROOT)/' <<<"${TUP_RULE_LINES}" || true)"
if [[ ${TUP_NIMCACHE_ALL} -gt 0 && ${TUP_NIMCACHE_ALL} -eq ${TUP_NIMCACHE_ROOTED} ]]; then
	ok "every --nimcache in src/Tuprules.tup is under the per-checkout NIM_CACHE_ROOT"
else
	bad "every --nimcache in src/Tuprules.tup is under the per-checkout NIM_CACHE_ROOT" \
		"rooted ${TUP_NIMCACHE_ROOTED} of ${TUP_NIMCACHE_ALL}:" \
		"$( # shellcheck disable=SC2016 # Tup source text, not an expansion
			grep -n -- '--nimcache:' "${TUPRULES}" | grep -vF -- '--nimcache:$(NIM_CACHE_ROOT)/'
		)"
fi

# No rule line spells the root at all any more: it arrives only through the
# import, and the `tup-from-pwd` fallback is gone (it is checked for by name
# below).
TUP_BARE="$(grep -n '/tmp/ct-nim-cache' <<<"${TUP_RULE_LINES}" || true)"
if [[ -z ${TUP_BARE} ]]; then
	ok "no src/Tuprules.tup rule spells a bare /tmp/ct-nim-cache any more"
else
	bad "no src/Tuprules.tup rule spells a bare /tmp/ct-nim-cache any more" \
		"still hardcoding a host-global root (line numbers exclude comments):" "${TUP_BARE}"
fi

# UNSET STOPS THE PARSE. The `tup-from-pwd` fallback could only be reached by
# a shell with the Cargo values set by hand and not this one, and there it
# chose a root unlike the scripted one and rebuilt every Nim target. The rules
# now refuse, like the Cargo import below.
# shellcheck disable=SC2016 # Tup source text, not expansions
if grep -qxF 'NIM_CACHE_ROOT = $(CT_TUP_NIM_CACHE_ROOT)' <<<"${TUP_RULE_LINES}" &&
	grep -qxF 'import CT_TUP_NIM_CACHE_ROOT=' <<<"${TUP_RULE_LINES}" &&
	grep -q '^error ' <<<"$(grep -A1 -xF 'ifeq ($(CT_TUP_NIM_CACHE_ROOT),)' <<<"${TUP_RULE_LINES}")" &&
	! grep -qE 'tup-from-pwd|import PWD' <<<"${TUP_RULE_LINES}"; then
	ok "src/Tuprules.tup takes its Nim cache root only from the environment, and refuses without it"
else
	bad "src/Tuprules.tup takes its Nim cache root only from the environment, and refuses without it" "$(grep -n 'NIM_CACHE_ROOT\|PWD' <<<"${TUP_RULE_LINES}" | head -8)"
fi

# ---------------------------------------------------------------------------
section "the tup Cargo targets belong to one checkout and one compiler"
# ---------------------------------------------------------------------------
#
# THE CLUSTER. `src/Tuprules.tup` built every crate into a host-global root,
# `/tmp/codetracer/<crate>_target` (`C:/tmp/...` on Windows). Every measured
# consequence came from sharing it: E0514 when one checkout's rustc 1.96
# metadata met another's 1.89; one checkout running ANOTHER checkout's build
# script, fresh by mtime, so the emulator library was never deployed
# (2026-11-05); `.cargo-lock` unopenable because another account owned the
# root (2026-10-27). codetracer-pm
# issues/2026-10-05-ui-tup-cargo-targets-collide-across-workspaces-and-compilers.md,
# contract spec/Testing/UI-Cargo-Output-Ownership.md.
#
# `ci/lib/tup-cargo-target.sh` is the one cause; the rules import its two
# values and refuse without them. The contracts below grade the helper on real
# directories (distinct per checkout, re-entered by the same one, distinct per
# compiler, and every refusal the spec lists), then the sites.
#
# THE COMPILER IS A STUB, and that is the one mock here. The helper reads three
# things from it: the path it resolves to, `rustc -vV` and `--print sysroot`.
# A script printing two different release/sysroot texts at two different paths
# is a genuine pair of distinct identities as far as the helper can tell, which
# is exactly what is being graded. It is a stub because this suite runs on the
# lint runner, which has no Rust toolchain; the real-compiler measurement is
# the concurrent two-worktree `just build-once` recorded with the change.
CARGO_LIB="${SUITE_ROOT}/ci/lib/tup-cargo-target.sh"
STUB_RUSTC_DIR="${TEST_ROOT}/stub-rustc"
mkdir -p "${STUB_RUSTC_DIR}/1.89" "${STUB_RUSTC_DIR}/1.96"
for rel in 1.89 1.96; do
	cat >"${STUB_RUSTC_DIR}/${rel}/rustc" <<STUB
#!/usr/bin/env bash
case "\$1" in
-vV) printf 'rustc ${rel}.0 (stub)\nbinary: rustc\nhost: x86_64-unknown-linux-gnu\nrelease: ${rel}.0\n' ;;
--print) printf '%s\n' "${STUB_RUSTC_DIR}/${rel}/sysroot" ;;
*) exit 2 ;;
esac
STUB
	chmod +x "${STUB_RUSTC_DIR}/${rel}/rustc"
done
CK_CA="${TEST_ROOT}/cargo-checkouts/alpha"
CK_CB="${TEST_ROOT}/cargo-checkouts/beta"
mkdir -p "${CK_CA}/src" "${CK_CB}/src"

# `env -u` both values: an ambient one (this suite may run inside a prepared
# dev shell) would be refused as "supplied by someone else" and turn every
# contract red for the wrong reason.
cargo_base_for() { # <checkout> <rustc release>
	env -u CT_TUP_CARGO_TARGET_BASE -u CT_TUP_CARGO_TARGET_IGNORE \
		RUSTC="${STUB_RUSTC_DIR}/$2/rustc" bash "${CARGO_LIB}" "$1" 2>&1
}
first_line() { printf '%s\n' "$1" | sed -n 1p; }

CB_A="$(cargo_base_for "${CK_CA}" 1.89)"
CB_B="$(cargo_base_for "${CK_CB}" 1.89)"
CB_A2="$(cargo_base_for "${CK_CA}" 1.89)"
CB_A96="$(cargo_base_for "${CK_CA}" 1.96)"
BASE_A="$(first_line "${CB_A}")"
if [[ ${BASE_A} == "${CK_CA}"/build/tup-cargo-targets/rustc-1.89.0-* && -d ${BASE_A} &&
	"$(first_line "${CB_B}")" == "${CK_CB}"/build/tup-cargo-targets/rustc-1.89.0-* &&
	${CB_A2} == "${CB_A}" ]]; then
	ok "each checkout gets its own Cargo target base inside it, and re-enters the same one"
else
	bad "each checkout gets its own Cargo target base inside it, and re-enters the same one" \
		"alpha: ${CB_A}" "beta: ${CB_B}" "alpha again: ${CB_A2}"
fi
BASE_A96="$(first_line "${CB_A96}")"
if [[ ${BASE_A96} == "${CK_CA}"/build/tup-cargo-targets/rustc-1.96.0-* &&
	${BASE_A96} != "${BASE_A}" && -d ${BASE_A96} ]]; then
	ok "...and another compiler in the same checkout gets a different base (the E0514 case)"
else
	bad "...and another compiler in the same checkout gets a different base (the E0514 case)" \
		"1.89: ${BASE_A}" "1.96: ${CB_A96}"
fi

# The ignore expression must cover a write into this checkout's base and NOT
# the same write into another's, or the Windows exclusion would be either
# broken or a host-wide hole again. `sed` turns the Tupfile spelling `[/\\]`
# (kept verbatim by tup in a variable, measured) into the ERE `[/\]`.
IGNORE_A="$(printf '%s\n' "${CB_A}" | sed -n 2p)"
IGNORE_ERE="^$(printf '%s' "${IGNORE_A}" | sed 's/\[\/\\\\\]/[\/\\]/g')db_backend_target[A-Za-z0-9]*[/\\].*\$"
if grep -Eq -- "${IGNORE_ERE}" <<<"${BASE_A}/db_backend_target/debug/replay-server" &&
	grep -Eq -- "${IGNORE_ERE}" <<<"${BASE_A}/db_backend_targetF5RTUl/CACHEDIR.TAG" &&
	! grep -Eq -- "${IGNORE_ERE}" <<<"$(first_line "${CB_B}")/db_backend_target/debug/replay-server"; then
	ok "the ignore expression covers this base's target writes and not another checkout's"
else
	bad "the ignore expression covers this base's target writes and not another checkout's" \
		"expression: ${IGNORE_A}" "as ERE: ${IGNORE_ERE}"
fi

# THE REFUSALS. Each must say no on stderr, print nothing on stdout (so a
# caller cannot eval half an answer), and exit non-zero.
cargo_refuses() { # <desc> <fragment> <checkout> [env assignments...]
	local desc="$1" fragment="$2" checkout="$3" out err status
	shift 3
	out="$(env -u CT_TUP_CARGO_TARGET_BASE -u CT_TUP_CARGO_TARGET_IGNORE "$@" \
		RUSTC="${STUB_RUSTC_DIR}/1.89/rustc" bash "${CARGO_LIB}" "${checkout}" 2>"${TEST_ROOT}/cargo-err")"
	status=$?
	err="$(cat "${TEST_ROOT}/cargo-err")"
	if [[ ${status} -ne 0 && -z ${out} && ${err} == *"${fragment}"* ]]; then
		ok "${desc}"
	else
		bad "${desc}" "status: ${status}" "stdout: ${out}" "stderr: ${err}"
	fi
}

cargo_refuses "a base supplied by the environment for another checkout is refused" \
	"already set to a different base" "${CK_CA}" \
	CT_TUP_CARGO_TARGET_BASE="$(first_line "${CB_B}")"

printf 'x\n' >"${BASE_A}/stray"
cargo_refuses "an unknown object in the base is refused" "unexpected entry" "${CK_CA}"
rm -f "${BASE_A}/stray"

ln -s /tmp "${BASE_A}/db_backend_target"
cargo_refuses "a target directory that is a link is refused" "not a plain directory" "${CK_CA}"
rm -f "${BASE_A}/db_backend_target"

cp "${BASE_A}/.ct-tup-cargo-owner" "${TEST_ROOT}/marker-saved"
sed -i.bak "s|^checkout=.*|checkout=${CK_CB}|" "${BASE_A}/.ct-tup-cargo-owner"
cargo_refuses "a base whose owner marker names another checkout is refused" \
	"different checkout or compiler" "${CK_CA}"
cp "${TEST_ROOT}/marker-saved" "${BASE_A}/.ct-tup-cargo-owner"
rm -f "${BASE_A}/.ct-tup-cargo-owner.bak"

CK_CL="${TEST_ROOT}/cargo-checkouts/linked"
mkdir -p "${CK_CL}/src" "${TEST_ROOT}/cargo-elsewhere"
ln -s "${TEST_ROOT}/cargo-elsewhere" "${CK_CL}/build"
cargo_refuses "a build directory that is a link out of the checkout is refused" \
	"is a symbolic link" "${CK_CL}"
if [[ -z "$(ls -A "${TEST_ROOT}/cargo-elsewhere")" ]]; then
	ok "...and nothing was created through it"
else
	bad "...and nothing was created through it" "$(ls -A "${TEST_ROOT}/cargo-elsewhere")"
fi

# After every refusal above was undone, the same checkout re-enters cleanly.
if [[ "$(cargo_base_for "${CK_CA}" 1.89)" == "${CB_A}" ]]; then
	ok "...and once the foreign objects are gone the same base is re-entered"
else
	bad "...and once the foreign objects are gone the same base is re-entered" \
		"$(cargo_base_for "${CK_CA}" 1.89)"
fi

# AND THE SITES. Source text, comments dropped, as above.
TUP_CARGO_BARE="$(grep -nE '[/\]tmp[/\]codetracer|tmp\[/\\\\\]codetracer' <<<"${TUP_RULE_LINES}" || true)"
# shellcheck disable=SC2016 # Tup source text, not expansions
if [[ -z ${TUP_CARGO_BARE} ]] &&
	grep -qxF 'CARGO_TARGET_BASE = $(CT_TUP_CARGO_TARGET_BASE)' <<<"${TUP_RULE_LINES}" &&
	grep -qxF 'import CT_TUP_CARGO_TARGET_BASE=' <<<"${TUP_RULE_LINES}" &&
	grep -qxF 'import CT_TUP_CARGO_TARGET_IGNORE=' <<<"${TUP_RULE_LINES}" &&
	grep -q '^error ' <<<"$(grep -A1 -xF 'ifeq ($(CT_TUP_CARGO_TARGET_BASE),)' <<<"${TUP_RULE_LINES}")" &&
	grep -q '^error ' <<<"$(grep -A1 -xF 'ifeq ($(CT_TUP_CARGO_TARGET_IGNORE),)' <<<"${TUP_RULE_LINES}")"; then
	ok "src/Tuprules.tup takes its Cargo target base only from the helper, and refuses without it"
else
	bad "src/Tuprules.tup takes its Cargo target base only from the helper, and refuses without it" \
		"host-global spellings (line numbers exclude comments):" "${TUP_CARGO_BARE:-<none>}" \
		"$(grep -n 'CARGO_TARGET_BASE\|CT_TUP_CARGO' <<<"${TUP_RULE_LINES}" | head -12)"
fi

# Every --target-dir under that base, and every Cargo ignore built from the
# helper's expression: a rule added with its own root would pass the check above.
TD_ALL="$(grep -o -- '--target-dir [^ ]*' <<<"${TUP_RULE_LINES}" | wc -l)"
# shellcheck disable=SC2016 # Tup source text
TD_ROOTED="$(grep -o -- '--target-dir $(CARGO_TARGET_BASE)/[a-z_]*_target' <<<"${TUP_RULE_LINES}" | wc -l)"
IGN_ALL="$(grep -c '^[A-Z_]*_CARGO_IGNORE_OUTPUTS = ' <<<"${TUP_RULE_LINES}" || true)"
# shellcheck disable=SC2016 # Tup source text
IGN_ROOTED="$(grep -c '^[A-Z_]*_CARGO_IGNORE_OUTPUTS = ^($(CT_TUP_CARGO_TARGET_IGNORE)[a-z_]*_target\[A-Za-z0-9\]\*' <<<"${TUP_RULE_LINES}" || true)"
if [[ ${TD_ALL} -gt 0 && ${TD_ALL} -eq ${TD_ROOTED} && ${IGN_ALL} -gt 0 && ${IGN_ALL} -eq ${IGN_ROOTED} ]]; then
	ok "every Cargo rule builds under the base and every Cargo ignore is built from the helper's expression"
else
	bad "every Cargo rule builds under the base and every Cargo ignore is built from the helper's expression" \
		"--target-dir: ${TD_ROOTED} of ${TD_ALL} under \$(CARGO_TARGET_BASE)" \
		"ignores: ${IGN_ROOTED} of ${IGN_ALL} from \$(CT_TUP_CARGO_TARGET_IGNORE)"
fi

TUP_CARGO_ENTRY_MISSING=""
for entry in scripts/build-once.sh scripts/build.sh ci/build/dev.sh \
	nix/shells/ci-base.nix non-nix-build/env.sh \
	non-nix-build/windows/setup-codetracer-runtime-env.sh; do
	grep -Eq 'tup-cargo-target\.sh"? (--reap )?--export' "${SUITE_ROOT}/${entry}" 2>/dev/null ||
		TUP_CARGO_ENTRY_MISSING="${TUP_CARGO_ENTRY_MISSING} ${entry}"
done
if [[ -z ${TUP_CARGO_ENTRY_MISSING} ]]; then
	ok "every tup entry point sets the Cargo target base through tup-cargo-target.sh"
else
	# shellcheck disable=SC2086 # one line per file, see BARE_ROOTS above
	bad "every tup entry point sets the Cargo target base through tup-cargo-target.sh" \
		"missing in:" ${TUP_CARGO_ENTRY_MISSING}
fi

# The builds reap; the scripts that only prepare a shell must not, or entering
# a shell with another compiler would remove a base a running build uses.
REAP_WRONG=""
for entry in scripts/build-once.sh scripts/build.sh ci/build/dev.sh build_for_extension.sh; do
	grep -Eq 'tup-cargo-target\.sh"? --reap' "${SUITE_ROOT}/${entry}" 2>/dev/null ||
		REAP_WRONG="${REAP_WRONG} ${entry}(does not reap)"
done
for entry in nix/shells/ci-base.nix non-nix-build/env.sh \
	non-nix-build/windows/setup-codetracer-runtime-env.sh; do
	# Code only: these files explain in comments why they do not pass it.
	! grep -q -- '--reap' <<<"$(grep -v '^[[:space:]]*#' "${SUITE_ROOT}/${entry}" 2>/dev/null)" ||
		REAP_WRONG="${REAP_WRONG} ${entry}(reaps)"
done
if [[ -z ${REAP_WRONG} ]]; then
	ok "the build entry points reap old bases, and the shell preparers do not"
else
	# shellcheck disable=SC2086 # one line per file
	bad "the build entry points reap old bases, and the shell preparers do not" ${REAP_WRONG}
fi

# --export is the ONE setup command, so it must carry the Nim root too, and the
# same one the lanes' helper computes for this checkout.
EXPORT_A="$(env -u CT_TUP_CARGO_TARGET_BASE -u CT_TUP_CARGO_TARGET_IGNORE \
	RUSTC="${STUB_RUSTC_DIR}/1.89/rustc" bash "${CARGO_LIB}" --export "${CK_CA}" 2>&1)"
NIM_FOR_CA="$(env -u CT_NIM_CACHE_ROOT bash "${NIMCACHE_LIB}" --tup "${CK_CA}")"
assert_contains "${EXPORT_A}" "export CT_TUP_NIM_CACHE_ROOT='${NIM_FOR_CA}'" \
	"--export sets the Nim cache root too, the same one ci/lib/nim-cache-root.sh --tup gives"

# THE REAPER. One checkout holding, beside the base about to be selected:
#   old      this checkout's older-compiler base, with a target in it  -> removed
#   newer    this checkout's base with a NEWER marker                  -> kept
#   unmarked a base-named directory with no marker                     -> kept
#   foreign  a base whose marker names another checkout                -> kept
#   stray    this checkout's older base holding an object we never put -> kept
#   linked   a base-named LINK to a directory outside the root         -> kept, target intact
#   outside  a directory beside the root, not in it                    -> kept
# Run twice: once WITHOUT --reap (the control: nothing may go), then with it.
CK_R="${TEST_ROOT}/cargo-checkouts/reap"
mkdir -p "${CK_R}/src"
reap_base() { # <rustc release> [--reap]
	env -u CT_TUP_CARGO_TARGET_BASE -u CT_TUP_CARGO_TARGET_IGNORE \
		RUSTC="${STUB_RUSTC_DIR}/$1/rustc" bash "${CARGO_LIB}" ${2:+"$2"} "${CK_R}" 2>"${TEST_ROOT}/reap-err" | sed -n 1p
}
R_ROOT="${CK_R}/build/tup-cargo-targets"
R_OLD="$(reap_base 1.89)"
mkdir -p "${R_OLD}/db_backend_target/debug"
printf 'artefact\n' >"${R_OLD}/db_backend_target/debug/replay-server"
mkdir -p "${R_ROOT}/rustc-1.80.0-1" "${R_ROOT}/rustc-1.81.0-2" "${R_ROOT}/rustc-1.82.0-3" \
	"${R_ROOT}/rustc-1.84.0-5" "${TEST_ROOT}/reap-link-target" "${CK_R}/build/outside"
printf 'keep\n' >"${TEST_ROOT}/reap-link-target/precious"
printf 'keep\n' >"${CK_R}/build/outside/precious"
sed "s|^checkout=.*|checkout=${CK_CB}|" "${R_OLD}/.ct-tup-cargo-owner" >"${R_ROOT}/rustc-1.81.0-2/.ct-tup-cargo-owner"
cp "${R_OLD}/.ct-tup-cargo-owner" "${R_ROOT}/rustc-1.82.0-3/.ct-tup-cargo-owner"
printf 'x\n' >"${R_ROOT}/rustc-1.82.0-3/stray"
cp "${R_OLD}/.ct-tup-cargo-owner" "${R_ROOT}/rustc-1.84.0-5/.ct-tup-cargo-owner"
ln -s "${TEST_ROOT}/reap-link-target" "${R_ROOT}/rustc-1.83.0-4"
# Every marker so far is "old"; the newer one is stamped a day ahead after the
# selected base exists, so `-ot` keeps it.
touch -t 202001010000 "${R_OLD}/.ct-tup-cargo-owner" "${R_ROOT}"/rustc-1.8[0-2].0-*/.ct-tup-cargo-owner
reap_snapshot() {
	local d
	for d in "${R_ROOT}"/* "${TEST_ROOT}/reap-link-target/precious" "${CK_R}/build/outside/precious"; do
		[[ -e ${d} || -L ${d} ]] && printf '%s\n' "${d##*/}"
	done
}
R_NEW="$(reap_base 1.96)"
touch -t "$(date -d '+1 day' +%Y%m%d%H%M 2>/dev/null || date -v+1d +%Y%m%d%H%M)" \
	"${R_ROOT}/rustc-1.84.0-5/.ct-tup-cargo-owner"
R_BEFORE="$(reap_snapshot)"
if [[ -d ${R_OLD}/db_backend_target && -d ${R_NEW} && -z "$(cat "${TEST_ROOT}/reap-err")" ]]; then
	ok "control: selecting a base without --reap removes nothing"
else
	bad "control: selecting a base without --reap removes nothing" "$(cat "${TEST_ROOT}/reap-err")" "${R_BEFORE}"
fi
R_SEL="$(reap_base 1.96 --reap)"
R_AFTER="$(reap_snapshot)"
R_EXPECT="$(printf '%s\n' "${R_BEFORE}" | grep -vxF "${R_OLD##*/}")"
if [[ ${R_SEL} == "${R_NEW}" && ! -e ${R_OLD} && ${R_AFTER} == "${R_EXPECT}" &&
	-f ${TEST_ROOT}/reap-link-target/precious ]]; then
	ok "--reap removes only this checkout's older, marked, clean base, and keeps the selected one"
else
	bad "--reap removes only this checkout's older, marked, clean base, and keeps the selected one" \
		"selected: ${R_SEL} (expected ${R_NEW})" "before:" "${R_BEFORE}" "after:" "${R_AFTER}" \
		"stderr: $(cat "${TEST_ROOT}/reap-err")"
fi
assert_contains "$(cat "${TEST_ROOT}/reap-err")" "rustc-1.82.0-3: unexpected entry" \
	"...and says why it left the base holding an object it did not put there"

# THE REPRO SLOT. A constant path the repro graph names, kept bound to the
# compiler about to run: created with the marker, kept for the same compiler,
# retired (then reaped, being older) when another compiler takes over, and
# refused when it is a link or carries another checkout's marker.
CK_P="${TEST_ROOT}/cargo-checkouts/repro"
mkdir -p "${CK_P}/src"
repro_slot() { # <rustc release>
	env RUSTC="${STUB_RUSTC_DIR}/$1/rustc" bash "${CARGO_LIB}" --repro-slot "${CK_P}" 2>"${TEST_ROOT}/slot-err"
}
P_ROOT="${CK_P}/build/repro-cargo-targets"
P1="$(repro_slot 1.89)"
mkdir -p "${P_ROOT}/active/db_backend_target"
P2="$(repro_slot 1.89)"
P3="$(repro_slot 1.96)"
if [[ ${P1} == "${P_ROOT}/active" && ${P2} == "${P1}" && ${P3} == "${P1}" &&
	"$(sed -n 's/^release: //p' "${P_ROOT}/active/.ct-tup-cargo-owner")" == 1.96.0 &&
	! -e ${P_ROOT}/active/db_backend_target &&
	"$(find "${P_ROOT}" -mindepth 1 -maxdepth 1 | wc -l)" -eq 1 ]]; then
	ok "the repro slot keeps one path, re-binds it to a new compiler, and reaps the old compiler's"
else
	bad "the repro slot keeps one path, re-binds it to a new compiler, and reaps the old compiler's" \
		"slots: ${P1} | ${P2} | ${P3}" "$(ls -la "${P_ROOT}" "${P_ROOT}/active")" "$(cat "${TEST_ROOT}/slot-err")"
fi
sed -i.bak "s|^checkout=.*|checkout=${CK_CB}|" "${P_ROOT}/active/.ct-tup-cargo-owner"
rm -f "${P_ROOT}/active/.ct-tup-cargo-owner.bak"
if ! repro_slot 1.96 >/dev/null && grep -q 'belongs to a different checkout' "${TEST_ROOT}/slot-err" &&
	[[ -d ${P_ROOT}/active ]]; then
	ok "a repro slot carrying another checkout's marker is refused, not retired"
else
	bad "a repro slot carrying another checkout's marker is refused, not retired" "$(cat "${TEST_ROOT}/slot-err")"
fi

# AND THE REPRO SITES. The graph names the slot, not a host-global root, and
# both Cargo actions are ordered after the uncacheable action that binds it.
REPRO_NIM="${SUITE_ROOT}/repro.nim"
REPRO_CODE="$(grep -v '^[[:space:]]*#' "${REPRO_NIM}")"
# The slot action's declaration, held in a variable so each property below is
# a here-string match rather than a pipe into an early-exiting `grep -q`.
REPRO_SLOT_ACTION="$(grep -A8 'actionIdValue = "repro-cargo-target-slot"' <<<"${REPRO_CODE}")"
# shellcheck disable=SC2016 # Nim source text
if ! grep -qE '"(C:)?/tmp/codetracer"' <<<"${REPRO_CODE}" &&
	grep -qF 'const ReproCargoSlot = "build/repro-cargo-targets/active"' <<<"${REPRO_CODE}" &&
	[[ "$(grep -c 'targetDir = ReproCargoSlot & "/' <<<"${REPRO_CODE}")" -eq "$(grep -c 'targetDir = ' <<<"${REPRO_CODE}" | awk '{print $1 - 1}')" ]] &&
	grep -qF 'targetDir = "build/repro-cargo-targets/probe"' <<<"${REPRO_CODE}" &&
	[[ "$(grep -c 'after = @\[reproCargoTargetSlot\]' <<<"${REPRO_CODE}")" -eq "$(grep -c 'targetDir = ReproCargoSlot & "/' <<<"${REPRO_CODE}")" ]] &&
	grep -q 'afterValue = \[reproCargoProbe\]' <<<"${REPRO_SLOT_ACTION}" &&
	grep -q 'tup-cargo-target.sh --repro-slot --rustc-probe' <<<"${REPRO_SLOT_ACTION}" &&
	grep -q 'cacheableValue = false' <<<"${REPRO_SLOT_ACTION}"; then
	ok "repro.nim builds Cargo only into the bound slot, after the uncacheable action that binds it to the probed compiler"
else
	bad "repro.nim builds Cargo only into the bound slot, after the uncacheable action that binds it to the probed compiler" \
		"$(grep -nE 'tmp/codetracer|targetDir = |ReproCargoSlot|reproCargoTargetSlot|cargo.build\(' "${REPRO_NIM}" | head -12)"
fi

# build_for_extension.sh: the replay backend is built into the compiler-bound
# base, not the crate's unbound `target/`.
EXT_SH="${SUITE_ROOT}/build_for_extension.sh"
EXT_CODE="$(grep -v '^[[:space:]]*#' "${EXT_SH}")"
# shellcheck disable=SC2016 # shell source text
if grep -qF 'cargo build --target-dir "${cargo_base}/db_backend_target"' <<<"${EXT_CODE}" &&
	grep -qF 'cp "${cargo_base}/db_backend_target/debug/replay-server" "$2"' <<<"${EXT_CODE}" &&
	! grep -q 'src/db-backend/target' <<<"${EXT_CODE}"; then
	ok "build_for_extension.sh builds the replay backend into the compiler-bound base"
else
	bad "build_for_extension.sh builds the replay backend into the compiler-bound base" \
		"$(grep -n 'cargo\|target' "${EXT_SH}")"
fi

# THE LINKER RESPONSE FILES. NIM_SIDE_OUTPUTS_IGNORE's second alternative is
# meant to exclude Nim's `<name>_linkerArgs.txt` side outputs on Windows. It was
# spelled `_linkerArgs\\.txt`, and tup 0.8 keeps `\\` verbatim inside a
# variable, so the regex said "a backslash, then any character" and never
# matched the file (measured with tup 0.8 on a rule that writes one: "was
# written to, but is not in .tup/db"; with `[.]` it is Updated). The expression
# is applied here as an ERE to the path such a write has, which treats `\\` and
# `[/\\]` exactly as tup's regex engine does.
if grep -Eq -- "${NIM_IGNORE_RE}" <<<"/w/src/build-debug/ct/ct_linkerArgs.txt" &&
	grep -Eq -- "${NIM_IGNORE_RE}" <<<'C:\w\src\build-debug\ct\ct_linkerArgs.txt' &&
	! grep -Eq -- "${NIM_IGNORE_RE}" <<<"/w/src/build-debug/ct/ct_linkerArgsXtxt"; then
	ok "NIM_SIDE_OUTPUTS_IGNORE matches a <name>_linkerArgs.txt side output, and only that name"
else
	bad "NIM_SIDE_OUTPUTS_IGNORE matches a <name>_linkerArgs.txt side output, and only that name" \
		"NIM_SIDE_OUTPUTS_IGNORE: ${NIM_IGNORE_RE:-<not found>}"
fi

# THE EMULATOR LIBRARY TRAVELS WITH replay-server. A produced binary must
# carry no load path into a build-scratch root (codetracer-pm issue
# 2026-10-05, the 2026-10-12 addendum: macOS's /tmp cleanup emptied the Cargo
# target's `out/` an installed `replay-server` loaded `libmcr_emulator.dylib`
# from). src/db-backend/build.rs therefore gives every binary of the crate one
# run-time search path, its own directory, and names the macOS library by
# `@rpath`; every place that installs `replay-server` installs the library
# beside it (or, for the AppImage, in the `lib/` its rewritten rpath names).
# Source text, comments dropped: the defect is the `-rpath,<OUT_DIR>` emit and
# a copy that forgets the library.
BUILD_RS_CODE="$(grep -vE '^[[:space:]]*//' "${SUITE_ROOT}/src/db-backend/build.rs")"
LOADPATH_WRONG=""
# shellcheck disable=SC2016 # Rust and Tup source text, not expansions
{
	grep -qF 'cargo:rustc-link-arg=-Wl,-rpath,{}' <<<"${BUILD_RS_CODE}" &&
		LOADPATH_WRONG="${LOADPATH_WRONG} build.rs(rpath-into-OUT_DIR)"
	grep -qF 'cargo:rustc-link-arg=-Wl,-rpath,$ORIGIN' <<<"${BUILD_RS_CODE}" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} build.rs(no-\$ORIGIN)"
	grep -qF 'cargo:rustc-link-arg=-Wl,-rpath,@loader_path' <<<"${BUILD_RS_CODE}" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} build.rs(no-@loader_path)"
	grep -qF -- '-Wl,-install_name,@rpath/' <<<"${BUILD_RS_CODE}" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} build.rs(macOS-install-name-not-@rpath)"
	[[ "$(grep -c 'deploy_shared_beside_binaries(&so_path)' <<<"${BUILD_RS_CODE}")" -ge 1 ]] &&
		grep -qF 'profile_dir.join("deps")' <<<"$(grep -A12 'fn deploy_shared_beside_binaries' <<<"${BUILD_RS_CODE}")" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} build.rs(not-deployed-beside-binaries-and-tests)"
	grep -qF 'cp $(CARGO_TARGET_BASE)/db_backend_target/debug/libmcr_emulator.so %2o' <<<"${TUP_RULE_LINES}" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} Tuprules(linux)"
	grep -qF 'cp $(CARGO_TARGET_BASE)/db_backend_target/debug/libmcr_emulator.dylib %2o' <<<"${TUP_RULE_LINES}" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} Tuprules(macos)"
	grep -qF '../bin/replay-server$(EXE_SUFFIX) ../bin/libmcr_emulator.dylib' "${SUITE_ROOT}/src/db-backend/Tupfile" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} db-backend/Tupfile(macos)"
	grep -qF 'target("replay-server", [replayServer, replayServerEmulator])' <<<"${REPRO_CODE}" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} repro.nim"
	grep -qF 'cp "${cargo_base}/db_backend_target/debug/${emulator_library}" "$(dirname "$2")/${emulator_library}"' <<<"${EXT_CODE}" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} build_for_extension.sh"
	grep -qF '"${CODETRACER_PREFIX}/lib/libmcr_emulator.so"' "${SUITE_ROOT}/appimage-scripts/build_db_backend.sh" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} appimage-scripts/build_db_backend.sh"
	grep -qF '"$DIST_DIR/bin/${emulator_library}"' "${SUITE_ROOT}/non-nix-build/build_db_backend.sh" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} non-nix-build/build_db_backend.sh"
	# The dev shell's stdenv self-rpath (`-rpath $out/lib`, $out being
	# `<checkout>/outputs/out` there) is removed, or every `cargo build` in
	# the shell gets that second, dead entry.
	grep -qF "NIX_LDFLAGS=\"''\${NIX_LDFLAGS//-rpath \$out\\/lib/}\"" "${SUITE_ROOT}/nix/shells/ci-base.nix" ||
		LOADPATH_WRONG="${LOADPATH_WRONG} nix/shells/ci-base.nix(self-rpath)"
}
if [[ -z ${LOADPATH_WRONG} ]]; then
	ok "replay-server loads its emulator library only from beside itself, and every installer puts it there"
else
	# shellcheck disable=SC2086 # one item per line
	bad "replay-server loads its emulator library only from beside itself, and every installer puts it there" \
		${LOADPATH_WRONG}
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
	# `env -u CODETRACER_BUILD_DIR` for the same reason `run_desktop` above does
	# it: `resolveBuiltThemeCss` pushes `$CODETRACER_BUILD_DIR/frontend/styles`
	# as its FIRST candidate directory, and inside the codetracer dev shell that
	# variable is an absolute path to the REAL checkout — not to `${CSSTREE}`.
	# The resolver then picks the NEWEST candidate, so a real built stylesheet
	# would outrank every file this fixture stages and these contracts would be
	# grading the developer's build tree.
	#
	# It does not bite TODAY only by luck: the fixture stages `theme.css`, and
	# the real build tree emits `default_dark_theme.css` and friends under that
	# name instead, so the candidate never resolves. That is a filename
	# coincidence, not isolation — rename the fixture's stylesheet to a real
	# theme name and four contracts below start measuring the wrong tree. Unset
	# it and the coincidence stops being load-bearing.
	#
	# `CODETRACER_E2E_CT_PATH` goes with it because `candidateStyleDirs` reads
	# BOTH: it derives a fourth candidate from the ct binary's grandparent
	# directory, which for any ct outside this fixture is again the wrong tree.
	# Unsetting only the variable that happened to bite would be the exact
	# half-measure `run_desktop` above refuses — see its note. Neither is
	# exported by the dev shell today; hermeticity that depends on that staying
	# true is not hermeticity.
	env -u CODETRACER_BUILD_DIR -u CODETRACER_E2E_CT_PATH node -e '
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
MISSING_CSS="$(env -u CODETRACER_BUILD_DIR -u CODETRACER_E2E_CT_PATH node -e '
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
# THE DB-BACKEND WASM REPLAY ENGINE.
#
# `src/db-backend/wasm-testing/pkg/` is a build output, gitignored twice over
# (`*.wasm` at the repo root, `dist/` in browser-replay), so it is never
# checked in, never refreshed by a pull, and never disturbed by a branch
# switch. Its readers asked "is there a .wasm, and is it over a megabyte?".
#
# MEASURED on 2026-09-06: in a worktree at origin/dev (1006b5ab1) holding the
# engine built on 2026-08-31 — 42 db-backend commits earlier, 79,304 bytes
# different from what that tree builds — `ci/test/worker-backend-wasm-e2e.sh`
# printed "19 passed, 0 failed". Nineteen green assertions about a replay
# engine, not one of them about the engine in the tree.
#
# THE CHECK IS NOT AN MTIME, and the two contracts below are the reason. This
# engine's build is not reproducible across checkout paths — it embeds absolute
# source paths, so two CLEAN checkouts of the SAME commit emit different
# binaries (measured: 5abaaece… here, 39e47d47… in a sibling worktree, both at
# 1006b5ab1). That rules out "assert a rebuild emits the same sha256". And a
# rebuild after a comment-only edit emitted a BYTE-IDENTICAL wasm (measured),
# which is the blocktracer 6f106f2 case where an mtime gate cannot be cleared
# by the remedy it prints. So the stamp records the digest of the INPUTS, is
# rewritten on every build whether or not the output changed, and is therefore
# always clearable by the command the refusal names.
section "db-backend WASM engine: existence is not freshness"

WASM_FRESHNESS_LIB="${SUITE_ROOT}/ci/lib/wasm-engine-freshness.sh"
WORKER_E2E="${SUITE_ROOT}/ci/test/worker-backend-wasm-e2e.sh"
BUILD_DIST="${SUITE_ROOT}/browser-replay/build-dist.sh"
TEST_DIST="${SUITE_ROOT}/browser-replay/tests/test_dist.sh"
BUILD_WASM="${SUITE_ROOT}/src/db-backend/build_wasm.sh"

if [[ ! -f ${WASM_FRESHNESS_LIB} ]]; then
	echo "stale-artefact-guards-test: missing '${WASM_FRESHNESS_LIB}'" >&2
	exit 3
fi

# A throwaway repo shaped like the real one. No cargo, no wasm-pack, no nix:
# the guard reads file CONTENT, so a synthetic tree exercises it exactly.
ENGINE_REPO="${TEST_ROOT}/engine-repo/codetracer"
mkdir -p "${ENGINE_REPO}/src/db-backend/src" \
	"${ENGINE_REPO}/src/db-backend/wasm-testing/pkg" \
	"${ENGINE_REPO}/ci/lib"
cp "${WASM_FRESHNESS_LIB}" "${ENGINE_REPO}/ci/lib/"
printf 'fn replay() {}\n' >"${ENGINE_REPO}/src/db-backend/src/lib.rs"
printf '[package]\nname = "db-backend"\n' >"${ENGINE_REPO}/src/db-backend/Cargo.toml"
printf '# lock\n' >"${ENGINE_REPO}/src/db-backend/Cargo.lock"
printf 'fn main() {}\n' >"${ENGINE_REPO}/src/db-backend/build.rs"
printf '#!/usr/bin/env bash\n' >"${ENGINE_REPO}/src/db-backend/build_wasm.sh"
ENGINE_PKG="${ENGINE_REPO}/src/db-backend/wasm-testing/pkg"
printf 'ENGINE-BYTES-A\n' >"${ENGINE_PKG}/db_backend_bg.wasm"
printf '// bindings\n' >"${ENGINE_PKG}/db_backend.js"

# shellcheck source=ci/lib/wasm-engine-freshness.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${WASM_FRESHNESS_LIB}"

# 1. An engine with no stamp cannot be shown to belong to any tree. This is the
#    state EVERY checkout is in before the first stamped build, and the state
#    the 19-green run above was measured in.
UNSTAMPED="$(wasm_engine_assert_fresh "${ENGINE_REPO}" 2>&1)"
assert_contains "${UNSTAMPED}" "STALE ENGINE" \
	"an unstamped engine is refused"
assert_contains "${UNSTAMPED}" "build_wasm.sh" \
	"...and the refusal names the command that builds one"

# 2. Stamped from this tree: accepted.
wasm_engine_write_stamp "${ENGINE_REPO}" >/dev/null
if wasm_engine_assert_fresh "${ENGINE_REPO}" >/dev/null 2>&1; then
	ok "an engine stamped from this tree is accepted"
else
	bad "an engine stamped from this tree is accepted" \
		"$(wasm_engine_assert_fresh "${ENGINE_REPO}" 2>&1)"
fi

# 3. THE ANTI-MTIME CONTRACT. A source newer than the engine, with identical
#    content, must NOT be refused. An mtime gate goes red here — on a tree that
#    has just built correctly — and prints a remedy that cannot clear it.
touch "${ENGINE_REPO}/src/db-backend/src/lib.rs" \
	"${ENGINE_REPO}/src/db-backend/Cargo.lock"
if wasm_engine_assert_fresh "${ENGINE_REPO}" >/dev/null 2>&1; then
	ok "a touched but unchanged source does not make the engine stale"
else
	bad "a touched but unchanged source does not make the engine stale" \
		"this is the mtime failure mode the stamp exists to avoid"
fi

# 4. A source whose CONTENT changed: refused, and the refusal says why.
printf 'fn replay() { /* changed */ }\n' >"${ENGINE_REPO}/src/db-backend/src/lib.rs"
CHANGED="$(wasm_engine_assert_fresh "${ENGINE_REPO}" 2>&1)"
assert_contains "${CHANGED}" "built from different sources than this tree has" \
	"an engine built from different sources is refused"
assert_contains "${CHANGED}" "engine built at git HEAD" \
	"...and the refusal reports the revision the engine came from"

# 5. THE REMEDY CLEARS IT. Not "a remedy is printed" — the printed remedy is
#    run, and the guard then passes. Three gates in this campaign printed
#    remedies that could not clear what they named; this contract is the reason
#    a fourth cannot be added here unnoticed. `wasm_engine_write_stamp` is the
#    last act of `build_wasm.sh`, which is what the refusal tells you to run.
wasm_engine_write_stamp "${ENGINE_REPO}" >/dev/null
if wasm_engine_assert_fresh "${ENGINE_REPO}" >/dev/null 2>&1; then
	ok "the remedy the refusal prints actually clears the refusal"
else
	bad "the remedy the refusal prints actually clears the refusal" \
		"$(wasm_engine_assert_fresh "${ENGINE_REPO}" 2>&1)"
fi

# 6. A stamp that has been separated from its binary. This is not theoretical:
#    copying `pkg/` between worktrees — how the stale engine reached the tree
#    that scored 19/19 — produces exactly this.
printf 'ENGINE-BYTES-B\n' >"${ENGINE_PKG}/db_backend_bg.wasm"
SWAPPED="$(wasm_engine_assert_fresh "${ENGINE_REPO}" 2>&1)"
assert_contains "${SWAPPED}" "the stamp does not describe the binary next to it" \
	"a stamp separated from its binary is refused"

# 7. And the plain absence of the engine, which must not be a skip.
rm -f "${ENGINE_PKG}/db_backend_bg.wasm"
MISSING_ENGINE="$(wasm_engine_assert_fresh "${ENGINE_REPO}" 2>&1)"
assert_contains "${MISSING_ENGINE}" "missing" \
	"a missing engine is refused rather than skipped"

# AND THE SITES. A guard nothing calls protects nothing.
if grep -q 'wasm_engine_assert_fresh' "${WORKER_E2E}"; then
	ok "worker-backend-wasm-e2e.sh asserts the engine is this tree's"
else
	bad "worker-backend-wasm-e2e.sh asserts the engine is this tree's" \
		"it is the gate measured at 19 passed / 0 failed on a stale engine"
fi
assert_not_contains "$(cat "${WORKER_E2E}")" '\-gt 1000000' \
	"...and no longer settles for 'the file is over a megabyte'"
if grep -q 'wasm_engine_assert_fresh' "${BUILD_DIST}"; then
	ok "build-dist.sh refuses to bundle an engine that is not this tree's"
else
	bad "build-dist.sh refuses to bundle an engine that is not this tree's" \
		"it publishes to ide.codetracer.com"
fi
if grep -q 'wasm_engine_assert_dir_fresh' "${TEST_DIST}"; then
	ok "test_dist.sh checks the bundled engine's provenance, not just its size"
else
	bad "test_dist.sh checks the bundled engine's provenance, not just its size" \
		"every other assertion in it passes for any 1-10 MB file"
fi
if grep -q 'wasm_engine_write_stamp' "${BUILD_WASM}"; then
	ok "build_wasm.sh stamps the engine it builds"
else
	bad "build_wasm.sh stamps the engine it builds" \
		"without the stamp every guard above can only report 'unstamped'"
fi

# ---------------------------------------------------------------------------
section "build-siblings reuses a sibling artefact only when its build stamp matches"
# ---------------------------------------------------------------------------
#
# `scripts/build-siblings.sh` decided "already built" with `[ -e ]` — and then,
# for a while, with an mtime comparison against the sibling's HEAD — so the
# launcher<->recorder lanes ran recorders compiled against a superseded
# `codetracer-trace-format`: the recorders' own HEADs had not moved, the trace
# format had, and ct refused every container they wrote ("meta.dat: unsupported
# version 3"). The guard is now a build stamp, kept under the CODETRACER
# checkout's `.tools/`, recording the sibling's and its trace-format
# dependencies' HEADs and tracked modifications, the build command and the
# artefact's sha256.
#
# The full case list (corrupt stamps, a failed build, `--check`, a non-git
# sibling, ...) is ci/test/sibling-artifact-freshness-test.sh. This section is
# the enrolment: the contracts that ARE the defect, seen going red here with
# the other sites, and a check that the full suite still runs in CI.
#
# Only the build itself is stubbed: `repro exec` is a pass-through and the
# builder writes the artefact. The HEADs, `git status`, the hashing and the
# stamp files are real.

BS_WS="${TEST_ROOT}/bs-ws"
BS_BIN="${TEST_ROOT}/bs-bin"
BS_SIB=codetracer-beam-recorder
BS_ART="target/debug/codetracer-beam-recorder"
BS_STAMP="${BS_WS}/codetracer/.tools/build-siblings-stamps/${BS_SIB}.stamp"
mkdir -p "${BS_WS}/codetracer/scripts" "${BS_BIN}"
cp "${BUILD_SIBLINGS}" "${BS_WS}/codetracer/scripts/"

# The stub bodies are written verbatim; the expansions in them are the stubs'.
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\n[ "$1" = exec ] && { shift 2; [ "$1" = -- ] && shift; exec "$@"; }\nexit 0\n' \
	>"${BS_BIN}/repro"
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nmkdir -p "$(dirname "$BS_ARTEFACT")" && echo built >"$BS_ARTEFACT"\n' \
	>"${BS_BIN}/just"
printf '#!/usr/bin/env bash\nexit 0\n' >"${BS_BIN}/nim"
cp "${BS_BIN}/nim" "${BS_BIN}/nimble"
cp "${BS_BIN}/nim" "${BS_BIN}/pkg-config"
chmod +x "${BS_BIN}"/*

bs_repo() { # <name>: a sibling checkout with two dated commits
	local dir="${BS_WS}/$1"
	mkdir -p "${dir}"
	git -C "${dir}" init -q
	git -C "${dir}" config user.email t@t.local
	git -C "${dir}" config user.name t
	printf 'one\n' >"${dir}/src.txt"
	git -C "${dir}" add src.txt
	GIT_COMMITTER_DATE="1577836800 +0000" git -C "${dir}" commit -qm one
	printf 'two\n' >>"${dir}/src.txt"
	GIT_COMMITTER_DATE="1577923200 +0000" git -C "${dir}" commit -qam two
}
bs_repo "${BS_SIB}"
bs_repo codetracer-trace-format
bs_repo codetracer-trace-format-nim

run_build_siblings() {
	(cd "${BS_WS}/codetracer" &&
		PATH="${BS_BIN}:${PATH}" BS_ARTEFACT="${BS_WS}/${BS_SIB}/${BS_ART}" \
			bash scripts/build-siblings.sh --only "${BS_SIB}" 2>&1)
}

run_build_siblings >/dev/null
assert_file_exists "${BS_STAMP}" "a sibling built by build-siblings.sh is stamped"
assert_contains "$(run_build_siblings)" "already built" \
	"...and is reused while nothing it was built from has changed"

# THE DEFECT. Only the dependency moves; the recorder's HEAD, tree and
# timestamps are exactly as they were.
printf 'meta.dat v4\n' >>"${BS_WS}/codetracer-trace-format/src.txt"
git -C "${BS_WS}/codetracer-trace-format" commit -qam "meta.dat v4"
assert_contains "$(run_build_siblings)" "rebuilding — dependency codetracer-trace-format moved" \
	"a recorder whose trace-format dependency moved is rebuilt, and says why"

# THE ANTI-MTIME CONTRACT. An older commit checked out after the build leaves
# the artefact NEWER than HEAD, which is what an mtime gate reads as fresh.
git -C "${BS_WS}/${BS_SIB}" checkout -q HEAD~1
assert_contains "$(run_build_siblings)" "moved since the stamped build" \
	"a sibling checked out to an older commit is rebuilt, not trusted by its mtime"

# Every artefact that predates the stamps is in this state on first run.
rm -f "${BS_STAMP}"
assert_contains "$(run_build_siblings)" "rebuilding — no build stamp" \
	"an artefact with no build stamp is rebuilt rather than assumed fresh"

# AND THE SITES. The guard is the stamp comparison; the full suite is the
# evidence it keeps working, and it is only evidence while CI runs it.
# shellcheck disable=SC2016 # the needle is source text, not an expansion
assert_contains "$(cat "${BUILD_SIBLINGS}")" 'stamp_stale_reason "$stamp"' \
	"build-siblings.sh decides reuse by comparing the build stamp"
assert_contains "$(cat "${SUITE_ROOT}/.github/workflows/codetracer.yml")" \
	"bash ci/test/sibling-artifact-freshness-test.sh" \
	"...and its full freshness suite is run by CI"

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
