#!/usr/bin/env bash
# =============================================================================
# Contract suite for ci/test/desktop-bundle-self-contained.sh, and for the
# stager it guards (scripts/stage-desktop-node-modules.py).
#
# The guard says one thing: every path inside a shipped bundle resolves inside
# it. Every way that guard could be wrong looks exactly like it working, and
# each of the following was a real state of this tree, not a hypothetical:
#
#   * PASSING A /nix/store SYMLINK BECAUSE THE STORE EXISTS HERE. This is the
#     defect, and it is the reason it shipped: the builder and the
#     `dmg-lib-check` runner are the same aarch64-darwin host, so
#     `Contents/MacOS/node_modules -> /nix/store/dfpgz…` is NOT BROKEN there.
#     A guard written as "find broken symlinks" is green on the exact artefact
#     that is broken for every user. One arm plants an absolute store symlink
#     whose target EXISTS and requires refusal.
#
#   * PASSING A RELATIVE LINK THAT ESCAPES. The other six bad links in the
#     published dmg are relative (`../../../../node_modules/xterm`). An arm
#     plants one and requires it BY NAME.
#
#   * ACCEPTING A SYMLINKED node_modules THAT HAPPENS TO RESOLVE. Pointing
#     `node_modules` at a sibling directory inside the bundle satisfies "every
#     link resolves inside" while still not being the tree; the check that the
#     payload is REAL is separate, and an arm covers it.
#
#   * CALLING A BUNDLE SELF-CONTAINED WITH NO RUNTIME TO RUN. A dereferenced,
#     pruned `node_modules` removes every dangling symlink and leaves the GUI
#     unable to start if `bin/electron` execs something absent — which is the
#     macOS bundle's SECOND, independent defect (the Nix node_modules
#     derivation contains no `electron` package at all). An arm removes the
#     runtime and requires refusal.
#
#   * A STATIC CHECK THAT FAILS ON ITS OWN DOCUMENTATION. The fix for this
#     defect quotes the line it replaced, in a Nim comment. A pattern that
#     cannot tell prose from code goes red forever and gets disabled. One arm
#     plants the pattern in a comment and requires a PASS; another plants it in
#     code and requires a FAIL.
#
#   * A PRUNER THAT DOES NOT PRUNE, OR PRUNES A RUNTIME DEPENDENCY. Two arms
#     run the stager itself over a fixture node_modules whose symlinks point
#     outside it, and require: the dev-only package gone, the production
#     package present, and ZERO symlinks left in the result.
#
# Every arm reddens ITS OWN assertion — the specific diagnostic, not merely a
# non-zero exit. Fixtures are throwaway trees under mktemp; the real repository
# is never written to.
# =============================================================================

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PASS=0
FAIL=0
OUT=""
RC=0
FIX=""

pass() {
	PASS=$((PASS + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$1" >&2
	if [ -n "${2:-}" ]; then
		printf '%s\n' "$2" | sed 's/^/       | /' >&2
	fi
}

cleanup() {
	[ -n "${FIX}" ] && rm -rf "${FIX}"
}
trap cleanup EXIT

# -----------------------------------------------------------------------------
# The fixture: a repository skeleton holding exactly the files the guard reads,
# plus a bundle shaped like the macOS `.app` it is pointed at.
# -----------------------------------------------------------------------------
make_fixture() {
	[ -n "${FIX}" ] && rm -rf "${FIX}"
	FIX="$(mktemp -d)"

	mkdir -p "${FIX}/repo/ci/test" "${FIX}/repo/scripts"
	cp "${REPO_ROOT}/ci/test/desktop-bundle-self-contained.sh" "${FIX}/repo/ci/test/"
	cp "${REPO_ROOT}/scripts/stage-desktop-node-modules.py" "${FIX}/repo/scripts/"
	cp "${REPO_ROOT}/ci/test/electron-supply-chain-closure.py" "${FIX}/repo/ci/test/"

	# A repro.nim with the shape the guard greps, in its FIXED form.
	cat >"${FIX}/repo/repro.nim" <<'EOF'
# staging notes: `cp -a node_modules` used to sit here, and it shipped a link.
"python3 scripts/stage-desktop-node-modules.py stage node_modules \"$MACOS/node_modules\"\n" &
"fs.cpSync(src,dst,{recursive:true,dereference:false});" &
EOF

	# The `.app`. `Contents/node_modules -> MacOS/node_modules` is the real
	# bundle's own relative link and must stay legal.
	local app="${FIX}/CodeTracer.app"
	mkdir -p "${app}/Contents/MacOS/bin" \
		"${app}/Contents/MacOS/node_modules/electron/dist/Electron.app/Contents/MacOS" \
		"${app}/Contents/MacOS/node_modules/xterm" \
		"${app}/Contents/MacOS/public/third_party"
	: >"${app}/Contents/MacOS/node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"
	: >"${app}/Contents/MacOS/node_modules/xterm/index.js"
	ln -s MacOS/node_modules "${app}/Contents/node_modules"
	ln -s ../../node_modules/xterm "${app}/Contents/MacOS/public/third_party/xterm"
	cat >"${app}/Contents/MacOS/bin/electron" <<'EOF'
#!/usr/bin/env bash
../node_modules/electron/dist/Electron.app/Contents/MacOS/Electron "$@"
EOF
	chmod +x "${app}/Contents/MacOS/bin/electron"
}

run_guard() {
	OUT="$(cd "${FIX}/repo" && bash ci/test/desktop-bundle-self-contained.sh "$@" 2>&1)"
	RC=$?
}

# Arms assert on NAMED verdicts rather than on the exit status. The guard runs
# every check and decides its status at the end, so "exit 1" tells a reader that
# something failed and not which thing — and an arm that only checked the exit
# status would pass while the guard failed for an unrelated reason.
expect_line() {
	# expect_line <substring> <label>
	if grep -qF "$1" <<<"${OUT}"; then
		pass "$2"
	else
		fail "$2" "${OUT}"
	fi
}

expect_no_line() {
	if grep -qF "$1" <<<"${OUT}"; then
		fail "$2" "${OUT}"
	else
		pass "$2"
	fi
}

echo "=== desktop-bundle-self-contained.sh contract suite"
echo

# -----------------------------------------------------------------------------
echo "--- baseline: a clean bundle"
make_fixture
run_guard "${FIX}/CodeTracer.app"
expect_line "PASSED: every symlink in the bundle resolves inside it" "clean bundle: symlinks accepted"
expect_line "PASSED: the bundle's node_modules is a real directory" "clean bundle: node_modules accepted"
expect_line "PASSED: the Electron launcher's exec target exists in the bundle" "clean bundle: launcher accepted"
expect_line "PASSED: every directory in the bundle is owner-writable" "clean bundle: writability accepted"
expect_line "PASSED: repro.nim stages node_modules with the contents, not the link" "clean repro.nim accepted despite the comment quoting the old line"

# -----------------------------------------------------------------------------
echo
echo "--- arm: a bundle carrying store permissions (0555 directories)"
# The shape `dmg-build` left on m3-mcl-003: `shutil.copytree` preserved the Nix
# store's 0555 on the staged `node_modules`, the gitignored `.app` survived into
# the next job, and that job's checkout could not unlink anything inside it.
# A 0444 FILE is planted alongside deliberately: it must NOT be counted, because
# read-only files are ordinary (git's pack files are 0444) and do not block
# unlink. A guard that counted them would be red on every clean bundle.
make_fixture
: >"${FIX}/CodeTracer.app/Contents/MacOS/node_modules/xterm/README"
chmod 0444 "${FIX}/CodeTracer.app/Contents/MacOS/node_modules/xterm/README"
chmod 0555 "${FIX}/CodeTracer.app/Contents/MacOS/node_modules/xterm"
run_guard "${FIX}/CodeTracer.app"
chmod -R u+w "${FIX}/CodeTracer.app"
expect_line "[UNWRITABLE DIR] Contents/MacOS/node_modules/xterm" "the unwritable directory is named"
expect_line "FAILED: the bundle has directories the owner cannot write" "the read-only bundle is refused"
expect_line "not owner-writable: 1" "exactly the directory is counted, not the 0444 file beside it"
if [ "${RC}" -ne 0 ]; then
	pass "read-only bundle: non-zero exit"
else
	fail "read-only bundle: non-zero exit" "${OUT}"
fi

# -----------------------------------------------------------------------------
echo
echo "--- arm: an ABSOLUTE symlink whose target EXISTS on this machine"
# The published defect. The target is a real directory here, so a
# "find broken symlinks" guard would be green — which is exactly what happened
# on the aarch64-darwin builder.
make_fixture
mkdir -p "${FIX}/fake-store/node_modules"
rm -rf "${FIX}/CodeTracer.app/Contents/MacOS/node_modules"
ln -s "${FIX}/fake-store/node_modules" "${FIX}/CodeTracer.app/Contents/MacOS/node_modules"
test -d "${FIX}/CodeTracer.app/Contents/MacOS/node_modules" ||
	fail "arm precondition: the planted absolute symlink resolves" ""
run_guard "${FIX}/CodeTracer.app"
expect_line "[ESCAPES] Contents/MacOS/node_modules" "absolute escaping symlink is named"
expect_line "FAILED: the bundle contains symlinks that do not resolve inside it" "absolute escaping symlink is refused"
expect_line "FAILED: the bundle's node_modules is a symlink, not the tree" "symlinked node_modules is refused"
if [ "${RC}" -ne 0 ]; then
	pass "absolute escaping symlink: non-zero exit"
else
	fail "absolute escaping symlink: non-zero exit" "${OUT}"
fi

# -----------------------------------------------------------------------------
echo
echo "--- arm: a /nix/store symlink is called out as such"
make_fixture
ln -s /nix/store/deadbeef-node-modules/bin/node_modules \
	"${FIX}/CodeTracer.app/Contents/MacOS/planted"
run_guard "${FIX}/CodeTracer.app"
expect_line "[NIX STORE] Contents/MacOS/planted" "store symlink is reported as a store symlink"

# -----------------------------------------------------------------------------
echo
echo "--- arm: a RELATIVE symlink that escapes the bundle"
make_fixture
ln -s ../../../../node_modules/xterm \
	"${FIX}/CodeTracer.app/Contents/MacOS/public/third_party/escaper"
run_guard "${FIX}/CodeTracer.app"
expect_line "Contents/MacOS/public/third_party/escaper" "relative escaping symlink is named"
expect_line "FAILED: the bundle contains symlinks that do not resolve inside it" "relative escaping symlink is refused"

# -----------------------------------------------------------------------------
echo
echo "--- arm: node_modules is a symlink that DOES resolve inside the bundle"
# Legal by the symlink rule, illegal by the payload rule. Without the second
# rule a bundle could point node_modules at an empty sibling and pass.
make_fixture
# Moved rather than emptied: the arm is about the payload rule alone, so every
# other check has to still pass. An empty `real_modules` would also break the
# third_party link and the launcher, and the arm would then be asserting
# nothing in particular.
mv "${FIX}/CodeTracer.app/Contents/MacOS/node_modules" \
	"${FIX}/CodeTracer.app/Contents/MacOS/real_modules"
ln -s real_modules "${FIX}/CodeTracer.app/Contents/MacOS/node_modules"
run_guard "${FIX}/CodeTracer.app"
expect_line "PASSED: every symlink in the bundle resolves inside it" "inward symlink still satisfies the symlink rule"
expect_line "FAILED: the bundle's node_modules is a symlink, not the tree" "inward-symlinked node_modules is still refused"

# -----------------------------------------------------------------------------
echo
echo "--- arm: no Electron runtime behind the launcher"
make_fixture
rm -rf "${FIX}/CodeTracer.app/Contents/MacOS/node_modules/electron"
run_guard "${FIX}/CodeTracer.app"
expect_line "FAILED: the Electron launcher execs a path that is not in the bundle" "absent runtime is refused"
expect_line "ABSENT" "absent runtime prints the path it looked for"

# -----------------------------------------------------------------------------
echo
echo "--- arm: repro.nim reintroduces the link-preserving copy"
make_fixture
cat >>"${FIX}/repo/repro.nim" <<'EOF'
          "if [ -d node_modules ]; then cp -a node_modules \"$MACOS/node_modules\"; fi\n" &
EOF
run_guard "${FIX}/CodeTracer.app"
expect_line "FAILED: repro.nim stages node_modules without dereferencing" "reintroduced 'cp -a node_modules' is refused"
expect_line "cp -a node_modules" "the offending line is quoted"

# -----------------------------------------------------------------------------
echo
echo "--- arm: repro.nim reintroduces dereference:false FOR node_modules"
make_fixture
cat >>"${FIX}/repo/repro.nim" <<'EOF'
            "fs.cpSync('node_modules',path.join(APP_ROOT,'node_modules'),{recursive:true,dereference:false});" &
EOF
run_guard "${FIX}/CodeTracer.app"
expect_line "FAILED: repro.nim stages node_modules without dereferencing" "reintroduced windows dereference:false is refused"

# -----------------------------------------------------------------------------
echo
echo "--- arm: the tracked-in-git check, against the real repository"
# The mktemp fixture has no git repository, so this one assertion is made where
# it can be true. `.gitignore` swallowing a file the guard reads is not
# hypothetical — it happened to appimage-scripts/electron/package-lock.json.
OUT="$(cd "${REPO_ROOT}" && bash ci/test/desktop-bundle-self-contained.sh 2>&1)"
expect_line "PASSED: scripts/stage-desktop-node-modules.py exists and is tracked" \
	"the stager is tracked by git in the real repository"
expect_line "PASSED: repro.nim stages node_modules with the contents, not the link" \
	"the real repro.nim passes the static check"

# -----------------------------------------------------------------------------
echo
echo "--- the stager: prunes, dereferences, and keeps what the product loads"
make_fixture
SRC="${FIX}/src_node_modules"
# `prod-root/lib/inner` is nested rather than flat so the read-only arm further
# down measures a count, not a boolean: a one-directory fixture cannot tell
# "chmodded the tree" apart from "chmodded the root and stopped".
mkdir -p "${SRC}/prod-root/lib/inner" "${SRC}/dev-only" "${SRC}/.bin" \
	"${FIX}/outside/target"
: >"${SRC}/prod-root/lib/inner/deep.js"
cat >"${SRC}/prod-root/package.json" <<'EOF'
{ "name": "prod-root", "version": "1.0.0" }
EOF
cat >"${SRC}/dev-only/package.json" <<'EOF'
{ "name": "dev-only", "version": "1.0.0" }
EOF
: >"${FIX}/outside/target/payload.js"
# A symlink INSIDE a kept package that points outside the tree: dereferencing
# has to turn it into bytes, or the staged bundle inherits the escape.
ln -s "${FIX}/outside/target" "${SRC}/prod-root/vendored"

mkdir -p "${FIX}/repo/node-packages"
cat >"${FIX}/repo/node-packages/package.json" <<'EOF'
{
  "name": "codetracer",
  "dependencies": { "prod-root": "^1.0.0" },
  "devDependencies": { "dev-only": "^1.0.0" }
}
EOF
cat >"${FIX}/repo/node-packages/yarn.lock" <<'EOF'
# yarn lockfile v1
__metadata:
  version: 8

"codetracer@workspace:.":
  version: 0.0.0-use.local

"prod-root@npm:^1.0.0":
  version: 1.0.0

"dev-only@npm:^1.0.0":
  version: 1.0.0
EOF

STAGE_OUT="$(cd "${FIX}/repo" && python3 scripts/stage-desktop-node-modules.py \
	stage "${SRC}" "${FIX}/staged" 2>&1)"
STAGE_RC=$?

if [ "${STAGE_RC}" -eq 0 ]; then
	pass "stager exits 0 on a resolvable lockfile"
else
	fail "stager exits 0 on a resolvable lockfile" "${STAGE_OUT}"
fi

if [ -d "${FIX}/staged/prod-root" ]; then
	pass "stager keeps the production package"
else
	fail "stager keeps the production package" "${STAGE_OUT}"
fi

if [ -e "${FIX}/staged/dev-only" ]; then
	fail "stager drops the dev-only package" "${STAGE_OUT}"
else
	pass "stager drops the dev-only package"
fi

if [ -f "${FIX}/staged/prod-root/vendored/payload.js" ] &&
	[ ! -L "${FIX}/staged/prod-root/vendored" ]; then
	pass "stager dereferences an escaping symlink into real bytes"
else
	fail "stager dereferences an escaping symlink into real bytes" "${STAGE_OUT}"
fi

staged_links="$(find "${FIX}/staged" -type l | wc -l | tr -d ' ')"
if [ "${staged_links}" -eq 0 ]; then
	pass "stager leaves zero symlinks in the staged tree"
else
	fail "stager leaves zero symlinks in the staged tree" "${staged_links} link(s)"
fi

# -----------------------------------------------------------------------------
echo
echo "--- the stager: a store-shaped (read-only) source must not produce a"
echo "    read-only bundle"
# THE THIRD CHECKOUT FAILURE MODE ON THE SELF-HOSTED RUNNERS.
#
# In a Nix dev shell the stager's source IS the store: 0555 directories, 0444
# files. `shutil.copytree` preserves mode, so the staged `node_modules` inside
# `non-nix-build/CodeTracer.app` inherited directories nobody could write. The
# `.app` is gitignored, so on a persistent runner it survived into the next job
# and `git clean -ffdx` could not unlink one file inside it — unlink needs write
# on the PARENT DIRECTORY. Run 33734457928, job 100581650873, runner m3-mcl-003:
# 31,307 "Permission denied" warnings, then checkout gave up and died with
# EACCES unlinking `.../node_modules/abbrev/LICENSE`.
#
# The source arm is here rather than only in the pre-checkout sweep because a
# sweep cleans a poisoned host; only this stops the host being poisoned.
chmod -R a-w "${SRC}/prod-root"

STAGE_OUT="$(cd "${FIX}/repo" && python3 scripts/stage-desktop-node-modules.py \
	stage "${SRC}" "${FIX}/staged-ro" 2>&1)"
STAGE_RC=$?

if [ "${STAGE_RC}" -eq 0 ]; then
	pass "stager exits 0 on a read-only (store-shaped) source"
else
	fail "stager exits 0 on a read-only (store-shaped) source" "${STAGE_OUT}"
fi

# THE INSTRUMENT MUST HAVE SEEN SOMETHING. A `chmod` over a tree that needed
# nothing prints the same "after: 0" as one that never ran, and this campaign
# has been misled by exactly that three separate times. So the BEFORE count is
# asserted NON-ZERO: if the fixture stopped being read-only, this arm fails
# rather than passing vacuously.
ro_before="$(printf '%s' "${STAGE_OUT}" |
	sed -n 's/^read-only dirs  *: \([0-9][0-9]*\) before.*/\1/p')"
if [ -n "${ro_before}" ] && [ "${ro_before}" -gt 0 ]; then
	pass "stager reports a NON-ZERO read-only directory count before its chmod (${ro_before})"
else
	fail "stager reports a NON-ZERO read-only directory count before its chmod" \
		"parsed '${ro_before:-<nothing>}' from:
${STAGE_OUT}"
fi

# Measured independently of what the stager printed: the tree it left behind.
ro_after="$(find "${FIX}/staged-ro" -type d ! -perm -u+w | wc -l | tr -d ' ')"
if [ "${ro_after}" -eq 0 ]; then
	pass "the staged tree contains zero directories the owner cannot write"
else
	fail "the staged tree contains zero directories the owner cannot write" \
		"${ro_after} unwritable directory(ies)
${STAGE_OUT}"
fi

# The local-developer face of the same defect: `stage` begins by removing
# `dest`, and plain `shutil.rmtree` over 0555 directories raises PermissionError.
# Before the fix, a second build on a machine that had already built once died
# here.
STAGE_OUT="$(cd "${FIX}/repo" && python3 scripts/stage-desktop-node-modules.py \
	stage "${SRC}" "${FIX}/staged-ro" 2>&1)"
STAGE_RC=$?
if [ "${STAGE_RC}" -eq 0 ]; then
	pass "stager restages over its own previous output"
else
	fail "stager restages over its own previous output" "${STAGE_OUT}"
fi

# THE RED PATH. Everything above is green with the fix in place, and would be
# just as green if `restore_owner_write` had been deleted and the fixture had
# quietly stopped being read-only. So: neuter the chmod in a COPY of the stager
# and require the run to go red. A guard whose failing path has never executed
# is a guard nobody has tested.
python3 - "${FIX}/repo/scripts/stage-desktop-node-modules.py" \
	"${FIX}/repo/scripts/stager-no-chmod.py" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding="utf-8").read()
needle = "os.chmod(path, (mode & 0o7777) | 0o200)"
if needle not in text:
    sys.exit(f"the arm cannot neuter what it cannot find: {needle!r}")
open(dst, "w", encoding="utf-8").write(text.replace(needle, "pass"))
PY

NOCHMOD_OUT="$(cd "${FIX}/repo" && python3 scripts/stager-no-chmod.py \
	stage "${SRC}" "${FIX}/staged-red" 2>&1)"
NOCHMOD_RC=$?
if [ "${NOCHMOD_RC}" -ne 0 ]; then
	pass "a stager that does not restore owner-write FAILS"
else
	fail "a stager that does not restore owner-write FAILS" "${NOCHMOD_OUT}"
fi
if grep -q 'UNWRITABLE DIRS' <<<"${NOCHMOD_OUT}"; then
	pass "the failing stager names the unwritable directories as the reason"
else
	fail "the failing stager names the unwritable directories as the reason" \
		"${NOCHMOD_OUT}"
fi
red_ro="$(find "${FIX}/staged-red" -type d ! -perm -u+w | wc -l | tr -d ' ')"
if [ "${red_ro}" -gt 0 ]; then
	pass "the neutered stager really does leave ${red_ro} unwritable directory(ies)"
else
	fail "the neutered stager really does leave unwritable directories" \
		"found 0 -- the fixture is no longer read-only and every arm above is vacuous"
fi
chmod -R u+w "${FIX}/staged-red"

chmod -R u+w "${SRC}/prod-root"

# -----------------------------------------------------------------------------
echo
echo "--- the relinker: re-aims escaping node_modules links, refuses the rest"
make_fixture
ln -s ../../../../node_modules/xterm \
	"${FIX}/CodeTracer.app/Contents/MacOS/public/third_party/escaper"
RELINK_OUT="$(cd "${FIX}/repo" && python3 scripts/stage-desktop-node-modules.py relink \
	"${FIX}/CodeTracer.app" "${FIX}/CodeTracer.app/Contents/MacOS/node_modules" 2>&1)"
RELINK_RC=$?
if [ "${RELINK_RC}" -eq 0 ]; then
	pass "relink exits 0 when every escape is fixable"
else
	fail "relink exits 0 when every escape is fixable" "${RELINK_OUT}"
fi
if grep -q 'symlinks relinked   : 1' <<<"${RELINK_OUT}"; then
	pass "relink reports the count it rewrote"
else
	fail "relink reports the count it rewrote" "${RELINK_OUT}"
fi
run_guard "${FIX}/CodeTracer.app"
expect_line "PASSED: every symlink in the bundle resolves inside it" \
	"the bundle passes the guard after relinking"

echo
echo "--- arm: relink REFUSES an escape it cannot re-aim"
make_fixture
ln -s ../../../../../../etc/passwd "${FIX}/CodeTracer.app/Contents/MacOS/stray"
RELINK_OUT="$(cd "${FIX}/repo" && python3 scripts/stage-desktop-node-modules.py relink \
	"${FIX}/CodeTracer.app" "${FIX}/CodeTracer.app/Contents/MacOS/node_modules" 2>&1)"
RELINK_RC=$?
if [ "${RELINK_RC}" -ne 0 ]; then
	pass "relink fails on an escape outside any node_modules"
else
	fail "relink fails on an escape outside any node_modules" "${RELINK_OUT}"
fi
if grep -q 'Contents/MacOS/stray' <<<"${RELINK_OUT}"; then
	pass "relink names the escape it could not fix"
else
	fail "relink names the escape it could not fix" "${RELINK_OUT}"
fi

# -----------------------------------------------------------------------------
echo
echo "=== summary"
echo "  passed: ${PASS}"
echo "  failed: ${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
	echo
	echo "RESULT: FAILED (${FAIL} of $((PASS + FAIL)))"
	exit 1
fi
echo
echo "RESULT: PASSED (${PASS}/${PASS})"
