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
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"

VISUAL_CAPTURE="${REPO_ROOT}/scripts/docs/capture-visual-recording-screenshots.sh"
STORYBOOK_FRESHNESS="${REPO_ROOT}/tools/visual-review/storybook-freshness.mjs"
STORYBOOK_DEPS="${REPO_ROOT}/scripts/storybook-deps.sh"
RR_SETUP="${REPO_ROOT}/ci/setup-rr-backend.sh"
SETUP_CERTS="${REPO_ROOT}/browser-replay/setup-certs.sh"
WEBP="${REPO_ROOT}/scripts/docs/generate-webp-animations.sh"

# Every contract this suite claims to check. A suite that silently runs fewer
# assertions than it advertises is a suite that stops protecting anything, so
# the count is asserted at the end and has to be changed deliberately.
EXPECTED_ASSERTIONS=43

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
	"${RR_SETUP}" "${SETUP_CERTS}" "${WEBP}"; do
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
# this suite has variables by those names too.
rr_guard() {
	(
		export CLONE_DIR="$1"
		cd "${REPO_ROOT}" || exit 1
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

# END TO END, as a script: `main` must resolve the ref even though the directory
# is present. This is the exact thing the old code skipped, and it fails before
# `build_rr_support` so no nix, no credential and no network are involved.
# shellcheck disable=SC2031  # REPO_ROOT is only ever modified inside rr_guard's subshell
END_TO_END="$(cd "${REPO_ROOT}" && env CLONE_DIR="${BACKEND}" RR_BACKEND_REF="${REV_NEW}" \
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
