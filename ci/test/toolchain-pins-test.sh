#!/usr/bin/env bash
# =============================================================================
# Contract suite for scripts/toolchain-pins.sh.
#
# The guard it covers answers "which compiler answered?" and refuses when the
# answer cannot be attributed to a commit. Its own header explains why that
# question needed a guard.
#
# What THIS suite is for is the failure side, because every way this guard
# could be wrong looks exactly like it working:
#
#   * PASSING OVER THE AMBIENT COMPILER. `~/.nix-profile/bin/nim` is a symlink
#     INTO the store, so a classifier that resolves symlinks before deciding
#     would call it a store path and wave through the exact 2.2.4-against-2.2.8
#     substitution this guard exists to catch. One arm below builds that shape
#     — a profile symlink pointing at a store path — and requires `ambient`.
#
#   * REPORTING ON NOTHING. `--verify` is a universal claim over the declared
#     tools. Over an empty set that claim is TRUE, so an emptied `TOOLS`, or a
#     `--require` naming a tool that is not declared, would print a clean pass
#     having compared no compilers at all. Both are arms below, and both assert
#     the COUNT rather than only the exit status.
#
#   * SKIPPING WHEN THE ANSWER IS ABSENT. A compiler that is not on PATH is the
#     most likely real-world state when the dev shell did not load, and "not
#     there" must be a hard failure for a required tool.
#
#   * ACCUSING THE WRONG THING. python3 missing, or an unparseable flake.lock,
#     must read as a tooling failure (exit 2) and never as a verdict about a
#     compiler (exit 1). A guard that answers "the toolchain is unpinned" when
#     python3 is merely absent sends the reader to edit a correct pin.
#
#   * READING THE WRONG NODE. In flake.lock the root input name and the node
#     key are not the same string — nix disambiguates same-named nodes with a
#     numeric suffix, so `nodes["fenix"]` can be a DIFFERENT input's copy and
#     the wrong rev it returns is indistinguishable from a right one. One arm
#     builds exactly that decoy and requires the resolver to see through it.
#
#   * GOING QUIET ABOUT ITS OWN SCOPE. The guard's whole warrant is that its
#     passing line names what it does not cover. An arm asserts that text is
#     still printed, because a future edit that deletes it turns a scoped check
#     into an unscoped claim without changing a single verdict.
#
# Every mutation arm reddens ITS OWN assertion: the arm is applied and the
# suite requires the specific diagnostic for that arm — not merely a non-zero
# exit, which another check could have produced for another reason.
#
# Pure bash + git + python3 over temporary fixtures. No network, no nix, no
# dev shell; it writes nothing outside its own mktemp. The store classification
# is exercised through TOOLCHAIN_PINS_STORE_PREFIX, the guard's one seam, which
# it discloses on its own RESULT line for exactly this reason.
#
# Run: bash ci/test/toolchain-pins-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/toolchain-pins.sh"
PIN_SRC="$REPO_ROOT/ci/toolchain.pin"

[ -f "$GUARD" ] || {
	echo "FAIL: the script under test is missing: $GUARD" >&2
	exit 1
}
[ -f "$PIN_SRC" ] || {
	echo "FAIL: the declaration under test is missing: $PIN_SRC" >&2
	exit 1
}

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '  ok    %s\n' "$1"
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$1" >&2
	[ $# -gt 1 ] && printf '        %s\n' "$2" >&2
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/toolchain-pins-test.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT
# CANONICALISE IT, and this is not tidiness. On macOS `$TMPDIR` is
# `/var/folders/…`, which is a SYMLINK to `/private/var/folders/…`, and it ends
# in a slash so `mktemp` returns a path containing `//`. The guard classifies a
# tool by its unresolved `command -v` path and then resolves symlinks to name
# the store path — so an uncanonicalised fixture root makes the two disagree
# for reasons that have nothing to do with the code under test, and every
# store/worktree arm below silently degrades to `unknown` while still failing.
# That is a fixture defect that would read as a guard defect.
TMP="$(cd "$TMP" && pwd -P)"

# -----------------------------------------------------------------------------
# The fixture.
#
# A whole synthetic workspace: <root>/ws/repo is the "codetracer" checkout and
# <root>/ws/noir is a sibling. The fake store, the fake profile and the fake
# tools all live under it, so nothing on the real machine is read except the
# guard itself.
# -----------------------------------------------------------------------------
FIX_N=0
make_fixture() {
	FIX_N=$((FIX_N + 1))
	FIX="$TMP/fix$FIX_N"
	WS="$FIX/ws"
	REPO="$WS/repo"
	STORE="$FIX/store"
	FAKEHOME="$FIX/home"
	mkdir -p "$REPO/scripts" "$REPO/ci" "$STORE" "$FAKEHOME/.nix-profile/bin" "$FIX/bin"
	cp "$GUARD" "$REPO/scripts/toolchain-pins.sh"
	cp "$PIN_SRC" "$REPO/ci/toolchain.pin"
	write_lock "$REPO/flake.lock" "$@"
}

# A minimal flake.lock with the three toolchain-determining root inputs and a
# nim-fork-src node reachable only from reprobuild — the real shape.
#
# Arguments, all optional:  fork_owner=<root input that reaches nim-fork-src>
write_lock() {
	local out="$1"
	shift
	local fork_owner="reprobuild"
	local arg
	for arg in "$@"; do
		case "$arg" in
		fork_owner=*) fork_owner="${arg#fork_owner=}" ;;
		esac
	done
	python3 - "$out" "$fork_owner" <<'PY'
import json, sys

out, fork_owner = sys.argv[1], sys.argv[2]

nodes = {
    "root": {
        "inputs": {
            # The node KEYS deliberately differ from the input NAMES for two of
            # the three. A resolver that looks nodes up by input name lands on
            # the decoys below.
            "codetracer-toolchains": "codetracer-toolchains_7",
            "fenix": "fenix_4",
            "noir": "noir",
            "reprobuild": "reprobuild",
        }
    },
    # THE NEXT THREE REVS ARE NOT FREE FIXTURE VALUES. `make_fixture` copies
    # the REAL `ci/toolchain.pin` into the fixture repository, so a rev here
    # that disagrees with the corresponding `LOCK_*` line in that file makes
    # the baseline "a matching pin passes" arm fail for a reason that has
    # nothing to do with the arm — the guard would be correctly reporting a
    # declaration that lags its lock, in a fixture that meant to say neither.
    # They move together with `ci/toolchain.pin` or not at all.
    "codetracer-toolchains_7": {"locked": {"rev": "942c995a36469853351af605da90025314ffc58e"}},
    "fenix_4": {"locked": {"rev": "dd2c80d0b88463ccc0402c86e9e72dbb354ac091"}},
    "noir": {"locked": {"rev": "ca080a58b05106e37a7b5178a11a8f4503951a2b"}},
    "reprobuild": {"inputs": {"nim-fork-src": "nim-fork-src"}, "locked": {"rev": "2f124aebbc8a9e61e87de1aa13e15298a83f88c6"}},
    "nim-fork-src": {"locked": {"rev": "0b5b5ec507d2d9c731d222184c625851377a02c8"}},
    # The decoys: same NAME as a root input, different rev. Reading these
    # instead of the root-referenced nodes is the wrong-node defect.
    "codetracer-toolchains": {"locked": {"rev": "dddddddddddddddddddddddddddddddddddddddd"}},
    "fenix": {"locked": {"rev": "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"}},
}
if fork_owner != "reprobuild":
    nodes["reprobuild"]["inputs"] = {}
    nodes[nodes["root"]["inputs"][fork_owner]].setdefault("inputs", {})["nim-fork-src"] = "nim-fork-src"

with open(out, "w") as handle:
    json.dump({"root": "root", "nodes": nodes}, handle, indent=2)
PY
}

# A fake compiler that prints a fixed --version block.
make_tool() {
	local path="$1" body="$2"
	mkdir -p "$(dirname "$path")"
	{
		printf '#!/usr/bin/env bash\n'
		printf 'cat <<'"'"'VERSION_EOF'"'"'\n%s\nVERSION_EOF\n' "$body"
	} >"$path"
	chmod +x "$path"
}

# The three store-resident tools every fixture needs to get past the required
# set. Versions match ci/toolchain.pin, so a fixture is green unless an arm
# breaks something specific.
seed_store_tools() {
	local nimdir="$STORE/aaaaaaaa-nim-2.2.8/bin"
	local rustdir="$STORE/bbbbbbbb-rust-mixed/bin"
	make_tool "$nimdir/nim" "Nim Compiler Version 2.2.8 [Linux: amd64]"
	make_tool "$rustdir/rustc" "rustc 1.96.0 (ac68faa20 2026-05-25)"
	make_tool "$rustdir/cargo" "cargo 1.96.0 (ac68faa20 2026-05-25)"
	FIX_PATH="$nimdir:$rustdir:$FIX/bin"
}

# Run the guard inside a fixture with a hermetic PATH. `/usr/bin` and `/bin`
# come last so bash's own dependencies (`cut`, `sed`, `git`, `python3`) resolve
# while the fake tools win.
run_guard() {
	OUT="$(
		cd "$REPO" 2>/dev/null &&
			env -i \
				HOME="$FAKEHOME" \
				PATH="${FIX_PATH:-$FIX/bin}:/usr/bin:/bin:/usr/local/bin" \
				IN_NIX_SHELL="${GUARD_IN_NIX_SHELL-impure}" \
				TOOLCHAIN_PINS_STORE_PREFIX="$STORE" \
				TMPDIR="$TMP" \
				bash "$REPO/scripts/toolchain-pins.sh" "$@" 2>&1
	)"
	RC=$?
}

expect_rc() {
	local want="$1" what="$2"
	if [ "$RC" -eq "$want" ]; then
		pass "$what (exit $RC)"
	else
		fail "$what: expected exit $want, got $RC" "$(printf '%s' "$OUT" | tail -6)"
	fi
}

expect_says() {
	local needle="$1" what="$2"
	if grep -qF -- "$needle" <<<"$OUT"; then
		pass "$what"
	else
		fail "$what: output does not contain '$needle'" "$(printf '%s' "$OUT" | tail -8)"
	fi
}

expect_silent_on() {
	local needle="$1" what="$2"
	if grep -qF -- "$needle" <<<"$OUT"; then
		fail "$what: output wrongly contains '$needle'" "$(printf '%s' "$OUT" | tail -8)"
	else
		pass "$what"
	fi
}

echo "toolchain-pins guard contract"

# -----------------------------------------------------------------------------
# 1. The happy path, so every later arm's redness is attributable to the arm.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
run_guard --verify
expect_rc 0 "a fully store-resident toolchain matching the declaration verifies"
expect_says "nim 2.2.8" "the pass names the Nim it checked"
expect_says "RESULT: PASSED" "and reports PASSED"

# -----------------------------------------------------------------------------
# 2. THE HONESTY ARM. The passing line must keep naming what it does not cover.
#    Deleting that text turns a scoped guard into an unscoped claim without
#    changing a single verdict, which is why it is asserted here and not left
#    to review.
# -----------------------------------------------------------------------------
expect_says "SCOPE, and what is NOT covered" "the passing line still declares its scope"
expect_says "4 tool(s) verified: nim rustc cargo nargo" "and counts the tools THIS RUN verified"
expect_silent_on "DECLARED BUT NOT VERIFIED" "with nothing left over on an unscoped run"
expect_says "A VERSION STRING IS NOT AN IDENTITY" "and names the version-vs-identity gap"
expect_says "NIM SELF-REPORTS NO REVISION" "and names the weaker evidence available for Nim"
expect_says "not a claim that the" "and refuses to be read as a reproducibility claim"
expect_says "THE STORE WAS REDEFINED for this run" "and discloses that its one seam was used"

# -----------------------------------------------------------------------------
# 3. THE AMBIENT ARM — the defect that cost the most.
#    `~/.nix-profile/bin/nim` is a SYMLINK INTO THE STORE. A classifier that
#    resolved it first would call it store-resident and pass.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
make_tool "$STORE/cccccccc-nim-2.2.4/bin/nim" "Nim Compiler Version 2.2.4 [Linux: amd64]"
ln -s "$STORE/cccccccc-nim-2.2.4/bin/nim" "$FAKEHOME/.nix-profile/bin/nim"
FIX_PATH="$FAKEHOME/.nix-profile/bin:$FIX_PATH"
run_guard --verify
expect_rc 1 "a profile nim that resolves into the store is still refused"
expect_says "an ambient install" "the diagnostic names it as ambient"
expect_says "RESOLVES INTO the store" "and says out loud why a store test would have missed it"
expect_says "2.2.4-against-2.2.8" "and names the measured case it reproduces"

# -----------------------------------------------------------------------------
# 4. A REQUIRED TOOL THAT IS ABSENT IS A FAILURE, NEVER A SKIP.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
rm -f "$STORE/aaaaaaaa-nim-2.2.8/bin/nim"
run_guard --verify
expect_rc 1 "an absent required compiler fails"
expect_says "is not on PATH at all" "and is reported as absent rather than skipped"
expect_says "An absent compiler is not a skip" "and the diagnostic says why that matters"

# -----------------------------------------------------------------------------
# 5. THE DECLARATION MUST MATCH THE COMPILER.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
make_tool "$STORE/aaaaaaaa-nim-2.2.8/bin/nim" "Nim Compiler Version 2.2.9 [Linux: amd64]"
run_guard --verify
expect_rc 1 "a Nim that is not the declared version fails"
expect_says "but ci/toolchain.pin expects 2.2.8" "and the diagnostic names both sides"

# -----------------------------------------------------------------------------
# 6. SAME VERSION, DIFFERENT BUILD. rustc's upstream commit is the one identity
#    it self-reports, and a version-only comparison passes over a swap.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
make_tool "$STORE/bbbbbbbb-rust-mixed/bin/rustc" "rustc 1.96.0 (0000feed 2026-05-25)"
run_guard --verify
expect_rc 1 "a rustc with the declared version but a different upstream commit fails"
expect_says "Same version string, different build" "and the diagnostic says exactly that"

# -----------------------------------------------------------------------------
# 7. THE DECLARATION MUST NOT LAG THE LOCK.
#    A restatement that can silently fall behind what it restates asserts a
#    compiler nobody ships — the defect class this guard belongs to.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
python3 - "$REPO/flake.lock" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
data["nodes"]["fenix_4"]["locked"]["rev"] = "1111111111111111111111111111111111111111"
with open(path, "w") as handle:
    json.dump(data, handle)
PY
run_guard --verify
expect_rc 1 "a flake.lock that moved past ci/toolchain.pin fails"
expect_says "but flake.lock now says 1111111111" "and the diagnostic names the new revision"
expect_says "Re-measure rather than editing the LOCK_ lines alone" "and the remedy is re-measurement, not a rubber stamp"

# -----------------------------------------------------------------------------
# 8. THE WRONG-NODE ARM. Every fixture's lock stores the real revisions under
#    `fenix_4` / `codetracer-toolchains_7` and puts DECOYS at the bare names.
#    Arm 1 already passed against that lock, which is only possible if the
#    resolver went through root.inputs. This arm proves the decoys are load-
#    bearing: point root at the decoy and the guard must notice.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
python3 - "$REPO/flake.lock" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    data = json.load(handle)
data["nodes"]["root"]["inputs"]["fenix"] = "fenix"
with open(path, "w") as handle:
    json.dump(data, handle)
PY
run_guard --verify
expect_rc 1 "reading fenix's decoy node instead of the root-referenced one is detected"
expect_says "eeeeeeeeeeee" "and the decoy's revision is what gets named"

# -----------------------------------------------------------------------------
# 9. THE FORK QUESTION, AS A LIVE ASSERTION.
#    `nim-fork-src` reachable only from `reprobuild` is the measured reality and
#    must pass. Reachable from `codetracer-toolchains` — the input that supplies
#    Nim — must FAIL while ci/toolchain.pin still says EXPECT_NIM_SOURCE=upstream,
#    because at that point the file asserts a source nothing supports.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
run_guard --verify
expect_says "reachable only from: reprobuild" "nim-fork-src reachable only from reprobuild is reported, not refused"

make_fixture fork_owner=codetracer-toolchains
seed_store_tools
run_guard --verify
expect_rc 1 "nim-fork-src becoming reachable from the input that supplies Nim fails"
expect_says "declares EXPECT_NIM_SOURCE=upstream" "and the diagnostic names the claim it can no longer support"

# -----------------------------------------------------------------------------
# 10. THE STALE-BINARY ARM — measured on this workstation: a nargo built five
#     commits before its own checkout's HEAD.
# -----------------------------------------------------------------------------
make_sibling_noir() {
	local head_rev built_rev dirty="${3:-clean}"
	mkdir -p "$WS/noir/target/release"
	git -C "$WS/noir" init -q 2>/dev/null
	git -C "$WS/noir" config user.email t@t
	git -C "$WS/noir" config user.name t
	# `target/` is ignored, exactly as it is in the real noir checkout. Without
	# this the built binary itself is an untracked file, every fixture reads as
	# a dirty tree, and the dirty arm below would pass for the wrong reason.
	printf 'target/\n' >"$WS/noir/.gitignore"
	printf 'one\n' >"$WS/noir/a.txt"
	git -C "$WS/noir" add -A && git -C "$WS/noir" commit -qm one
	built_rev="$(git -C "$WS/noir" rev-parse HEAD)"
	printf 'two\n' >"$WS/noir/a.txt"
	git -C "$WS/noir" add -A && git -C "$WS/noir" commit -qm two
	head_rev="$(git -C "$WS/noir" rev-parse HEAD)"
	[ "$1" = fresh ] && built_rev="$head_rev"
	make_tool "$WS/noir/target/release/nargo" \
		"nargo version = 1.0.0-beta.26
noirc version = 1.0.0-beta.26+$built_rev
(git version hash: $built_rev, is dirty: ${2:-false})"
	[ "$dirty" = dirty ] && printf 'scratch\n' >"$WS/noir/uncommitted.txt"
	FIX_PATH="$FIX_PATH:$WS/noir/target/release"
	return 0
}

make_fixture
seed_store_tools
make_sibling_noir stale false clean
run_guard --verify
expect_rc 1 "a nargo built from a commit its own checkout has moved past fails"
expect_says "is STALE" "and is named as stale"
expect_says "not any commit of the tree you are reading" "and the diagnostic says what that means"

# -----------------------------------------------------------------------------
# 11. THE DIRTY ARM.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
make_sibling_noir fresh false dirty
run_guard --verify
expect_rc 1 "a nargo whose checkout has uncommitted changes fails"
expect_says "uncommitted change" "and the diagnostic counts them"
expect_says "A dirty tree is not any commit" "and says why a revision cannot describe it"

# -----------------------------------------------------------------------------
# 12. THE SELF-REPORTED DIRTY BIT. A binary can be built from a modified tree
#     that has since been committed, so the checkout is clean and the BINARY is
#     still not any revision. Only the binary knows.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
make_sibling_noir fresh true clean
run_guard --verify
expect_rc 1 "a nargo that self-reports 'is dirty: true' fails even over a clean checkout"
expect_says "was built from a modified tree" "and the diagnostic distinguishes the binary from the tree"

# -----------------------------------------------------------------------------
# 13. DIVERGENCE IS REPORTED BY --verify AND REFUSED BY --require.
#     The fixture's noir sibling shares no history with the flake pin, which is
#     the strongest form of the divergence the real workspace has.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
make_sibling_noir fresh false clean
run_guard --verify
expect_rc 0 "--verify passes over a sibling that diverges from the flake pin"
expect_says "DIVERGED from the flake" "and reports the divergence rather than hiding it"
expect_says "REPORTED, NOT REFUSED" "and says explicitly that it did not fail on it"
expect_says "divergence(s) were REPORTED and not refused" "and the RESULT line repeats it"

run_guard --require nargo
expect_rc 1 "--require refuses the same divergence"
expect_says "--require refuses this because a number produced by it" "and says why the measurement arm is stricter"
expect_silent_on "TOOLCHAIN:" "and prints NO stamp — there is no path to the line without the refusal"

# ...and the other side of that branch, which is the one a healthy workspace is
# in: a sibling AHEAD of the flake pin but descended from it. It must pass with
# no divergence note at all, or the arms above would be satisfied by a guard
# that simply always complains.
make_fixture
seed_store_tools
make_sibling_noir fresh false clean
# Both files, together. Moving flake.lock alone would trip the declaration
# cross-check instead -- correctly, which is arm 7's subject -- and this arm
# would then redden for a reason that has nothing to do with what it is testing.
python3 - "$REPO/flake.lock" "$REPO/ci/toolchain.pin" "$(git -C "$WS/noir" rev-parse HEAD~1)" <<'PY'
import json, re, sys
lock, pin, rev = sys.argv[1], sys.argv[2], sys.argv[3]
with open(lock) as handle:
    data = json.load(handle)
data["nodes"]["noir"]["locked"]["rev"] = rev
with open(lock, "w") as handle:
    json.dump(data, handle)
text = open(pin).read()
new, n = re.subn(r"^LOCK_NOIR=.*$", "LOCK_NOIR=%s" % rev, text, count=1, flags=re.M)
if n != 1:
    sys.exit("could not rewrite LOCK_NOIR in the fixture declaration")
open(pin, "w").write(new)
PY
run_guard --require nargo
expect_rc 0 "a sibling descended FROM the flake pin passes even the measurement arm"
expect_says "a descendant of the flake 'noir' pin" "and is described as a descendant"
expect_silent_on "DIVERGED" "with no divergence reported"
expect_says "TOOLCHAIN: nargo=" "and the stamp is printed"

# -----------------------------------------------------------------------------
# 14. THE SCOPED STAMP MUST NOT VOUCH FOR WHAT IT DID NOT CHECK.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
make_sibling_noir fresh false clean
run_guard --require rustc cargo
expect_rc 0 "--require can be scoped to the tools a measurement actually used"
expect_says "TOOLCHAIN: rustc=1.96.0" "and prints the stamp for those"
expect_says "not-verified:" "and lists the tools it did NOT hold to anything"
expect_says "not-verified: nim=" "naming nim among them"
# --require implies --strict, and the strict arm is nim-specific. It must
# respect the scope too: refusing a caller that never invokes nim, over nim,
# would be the guard reporting on an input outside its own stated scope.
expect_says "not applicable: nim is outside this run's scope" "and the nim-specific strict arm stands down rather than judging out of scope"
# The scope line must count what THIS run verified. Printing the declared list
# beside the word PASSED names compilers the run never looked at -- measured:
# `--require nim rustc cargo` once said "4 tools (nim rustc cargo nargo)".
expect_says "2 tool(s) verified: rustc cargo" "and the passing line counts only what this run verified"
expect_says "DECLARED BUT NOT VERIFIED BY THIS RUN: nim nargo" "and names the declared tools it did not hold to anything"

# -----------------------------------------------------------------------------
# 15. THE VACUITY ARMS. A universal claim over an empty set is TRUE.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
run_guard --require nosuchtool
expect_rc 1 "--require naming an undeclared tool fails instead of verifying nothing"
expect_says "matched the declared set" "and the diagnostic counts what matched"
expect_says "Declared:" "and lists what it could have been given"

make_fixture
seed_store_tools
if ! python3 - "$REPO/scripts/toolchain-pins.sh" <<'PY'; then
import re, sys
path = sys.argv[1]
text = open(path).read()
new, n = re.subn(r"^TOOLS=\(\n(?:.*\n)*?\)$", "TOOLS=(\n)", text, count=1, flags=re.M)
if n != 1:
    sys.exit("could not empty TOOLS; the mutation arm is no longer applying")
open(path, "w").write(new)
PY
	# A mutation that silently stopped applying would leave this arm asserting
	# nothing, which is the same defect the arm exists to catch.
	fail "the empty-TOOLS mutation could not be applied" "the arm below would pass vacuously"
else
	run_guard --verify
	expect_rc 1 "an emptied TOOLS list fails instead of passing over nothing"
	expect_says "0 tools were verified" "and says it asserted nothing about any compiler"
fi

# -----------------------------------------------------------------------------
# 16. TOOLING FAILURES ARE NOT VERDICTS. Exit 2, and never the word that would
#     send a reader to edit a correct pin.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
rm -f "$REPO/ci/toolchain.pin"
run_guard --verify
expect_rc 2 "a missing ci/toolchain.pin is a tooling failure, not a compiler verdict"
expect_says "there is nothing to hold a compiler to" "and the diagnostic refuses to invent an expectation"

make_fixture
seed_store_tools
printf 'not json at all\n' >"$REPO/flake.lock"
run_guard --verify
expect_rc 2 "an unparseable flake.lock is a tooling failure"
expect_says "did not parse as JSON" "and is reported as a parse failure"
expect_silent_on "is not on PATH" "and does not also accuse a compiler that is present"

# python3 removed from PATH. The guard must say so, and must not report on pins.
make_fixture
seed_store_tools
mkdir -p "$FIX/nopy"
for t in bash sed cut tr git awk grep wc uname basename dirname mktemp cat head env printf; do
	src="$(command -v "$t" 2>/dev/null)" && ln -sf "$src" "$FIX/nopy/$t"
done
OUT="$(
	cd "$REPO" && env -i HOME="$FAKEHOME" \
		PATH="$STORE/aaaaaaaa-nim-2.2.8/bin:$STORE/bbbbbbbb-rust-mixed/bin:$FIX/nopy" \
		IN_NIX_SHELL=impure TOOLCHAIN_PINS_STORE_PREFIX="$STORE" \
		bash "$REPO/scripts/toolchain-pins.sh" --verify 2>&1
)"
RC=$?
expect_rc 2 "python3 being absent is a tooling failure"
expect_says "parse/tooling failure" "and is named as one"
expect_says "do not read it" "and the diagnostic warns against reading it as a pin verdict"

# -----------------------------------------------------------------------------
# 17. THE SHELL ARM — the one command that would have closed the nine-hour
#     renderer investigation.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
GUARD_IN_NIX_SHELL="" run_guard --verify
expect_rc 1 "a run outside any dev shell fails even when the compilers happen to be right"
expect_says "IN_NIX_SHELL is unset" "and names the condition"
expect_says "direnv allow" "and names the remedy that a fresh worktree needs"
unset GUARD_IN_NIX_SHELL

make_fixture
seed_store_tools
OUT="$(
	cd "$REPO" && env -i HOME="$FAKEHOME" PATH="$FIX_PATH:/usr/bin:/bin" \
		IN_NIX_SHELL=impure DIRENV_FILE="$WS/somewhere-else/.envrc" \
		TOOLCHAIN_PINS_STORE_PREFIX="$STORE" \
		bash "$REPO/scripts/toolchain-pins.sh" --verify 2>&1
)"
RC=$?
expect_rc 1 "a dev shell belonging to a DIFFERENT checkout fails"
expect_says "belongs to a different checkout" "and says whose shell it is"

# -----------------------------------------------------------------------------
# 18. THE DEV-SHELL-INITIALISATION ARM. A fresh `git worktree` has no
#     devshell-generated .pre-commit-config.yaml and no initialised submodules,
#     because `.envrc` creates both and is blocked until `direnv allow` runs
#     there. Measured, before and after, in the worktree this guard was written
#     in.
# -----------------------------------------------------------------------------
make_fixture
seed_store_tools
: >"$REPO/.envrc"
run_guard --devshell-init
expect_rc 1 "a checkout with an .envrc but no devshell side effects fails"
expect_says ".pre-commit-config.yaml" "and names the generated file that is missing"
expect_says "direnv allow" "and names the remedy"

ln -s /dev/null "$REPO/.pre-commit-config.yaml"
# The generated tree-sitter parser: only asked about when its directory exists,
# because CI clones with `submodules: false` and skips the regen on purpose.
mkdir -p "$REPO/libs/tree-sitter-nim/src"
run_guard --devshell-init
expect_rc 1 "an initialised tree-sitter-nim submodule with no generated parser.c fails"
expect_says "libs/tree-sitter-nim/src/parser.c" "and names the generated file"

rm -rf "$REPO/libs"
run_guard --devshell-init
expect_rc 0 "and does NOT ask about it where the directory is absent (the CI shape)"
expect_says "the dev shell has initialised this checkout" "reporting a pass instead"

mkdir -p "$REPO/libs/tree-sitter-nim/src"
: >"$REPO/libs/tree-sitter-nim/src/parser.c"
run_guard --devshell-init
expect_rc 0 "once the generated symlink and the parser are there, it passes"
expect_says "It does not say the shell is entered NOW" "and its passing line refuses to be read as --verify"

# -----------------------------------------------------------------------------
echo
if [ "$FAIL" -ne 0 ]; then
	printf 'RESULT: FAILED — %d of %d assertion(s) failed.\n' "$FAIL" "$((PASS + FAIL))" >&2
	exit 1
fi
if [ "$PASS" -eq 0 ]; then
	printf 'RESULT: FAILED — 0 assertions ran; this suite proved nothing.\n' >&2
	exit 1
fi
printf 'RESULT: PASSED — %d assertion(s).\n' "$PASS"
