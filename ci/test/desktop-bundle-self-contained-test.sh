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
	if printf '%s' "${OUT}" | grep -qF "$1"; then
		pass "$2"
	else
		fail "$2" "${OUT}"
	fi
}

expect_no_line() {
	if printf '%s' "${OUT}" | grep -qF "$1"; then
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
expect_line "PASSED: repro.nim stages node_modules with the contents, not the link" "clean repro.nim accepted despite the comment quoting the old line"

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
mkdir -p "${SRC}/prod-root" "${SRC}/dev-only" "${SRC}/.bin" "${FIX}/outside/target"
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
if printf '%s' "${RELINK_OUT}" | grep -q 'symlinks relinked   : 1'; then
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
if printf '%s' "${RELINK_OUT}" | grep -q 'Contents/MacOS/stray'; then
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
