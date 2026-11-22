#!/usr/bin/env bash
#
# Contract suite for scripts/test-reprobuild-dependency-pins.sh.
#
# The guard requires every sibling this repo's repro.lock shares with the
# reprobuild it pins (matched by repository, through reprobuild's flake.lock)
# to be pinned here at reprobuild's revision or a descendant of it. It exists
# because the reprobuild 0.2.31 bump left nim-shm-gset behind and the pre-push
# gate's develop-mode interface compile died inside reprobuild.
#
# As in ci/test/flake-pin-alignment-test.sh, every failure case asserts two
# things: that the RIGHT diagnostic appears and that the WRONG one does not. A
# guard whose failure path accuses a correct pin (python3 missing, an
# unparseable lock read as "no revision") is worse than no guard.
#
# Throwaway git repos and fixture locks only. No network, no nix, no dev
# shell; a second or two.
#
# Run: bash ci/test/reprobuild-dependency-pins-test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/test-reprobuild-dependency-pins.sh"

[ -f "$GUARD" ] || {
	echo "FAIL: the script under test is missing: $GUARD" >&2
	exit 1
}

BASH_ABS="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAILED=0

ok() {
	PASS=$((PASS + 1))
	echo "  ok   $1"
}

bad() {
	FAILED=$((FAILED + 1))
	echo "  FAIL $1" >&2
	if [ $# -gt 1 ]; then
		printf '       %s\n' "$2" >&2
	fi
}

assert_contains() {
	case "$2" in
	*"$3"*) ok "$1" ;;
	*) bad "$1" "expected to find: $3" ;;
	esac
}

assert_absent() {
	case "$2" in
	*"$3"*) bad "$1" "expected NOT to find, but did: $3" ;;
	*) ok "$1" ;;
	esac
}

assert_rc() {
	if [ "$2" -eq "$3" ]; then
		ok "$1"
	else
		bad "$1" "rc=$2, expected $3"
	fi
}

init_repo() {
	mkdir -p "$1"
	git -C "$1" init -q 2>/dev/null
	git -C "$1" config user.email pin-test@example.invalid
	git -C "$1" config user.name "pin test"
	git -C "$1" config commit.gpgsign false
}

# commit_in <dir> <msg> -> prints the new commit sha
commit_in() {
	echo "$2" >>"$1/marker"
	git -C "$1" add -A
	git -C "$1" commit -qm "$2"
	git -C "$1" rev-parse HEAD
}

# A fake sibling `gset` with history  BASE -- RB -- AHEAD  and a side branch
# BASE -- SIDE. Sets BASE, RB, AHEAD, SIDE (make_ws reads them by name,
# through `${!2}`, which shellcheck cannot follow).
# make_gset <dir>
# shellcheck disable=SC2034
make_gset() {
	init_repo "$1"
	BASE="$(commit_in "$1" base)"
	RB="$(commit_in "$1" "what reprobuild pins")"
	AHEAD="$(commit_in "$1" ahead)"
	git -C "$1" checkout -q -b side "$BASE"
	SIDE="$(commit_in "$1" side)"
}

# A fake reprobuild whose HEAD carries a flake.lock with root inputs:
#   nim-shm-gset-src -> github metacraft-labs/nim-shm-gset @ <gset-rev>
#                       (under node key `nim-shm-gset-src_2`, shadowed by a
#                        nested homonym at <decoy>, the real reprobuild shape)
#   nim-stew-src     -> github status-im/nim-stew      @ <stew-rev>
#   bearssl-src      -> git https://github.com/status-im/nim-bearssl @ 1111…
#   codetracer-src   -> github metacraft-labs/codetracer @ ffff… (reprobuild
#                       really has one; it must not be compared with this
#                       repo's own `self` entry)
# make_reprobuild <dir> <gset-rev> <stew-rev> <decoy> -> prints the commit sha
make_reprobuild() {
	init_repo "$1"
	cat >"$1/flake.lock" <<EOF
{
  "nodes": {
    "root": { "inputs": {
      "nim-shm-gset-src": "nim-shm-gset-src_2",
      "nim-stew-src": "nim-stew-src",
      "bearssl-src": "bearssl-src",
      "codetracer-src": "codetracer-src"
    } },
    "nim-shm-gset-src": {
      "locked": { "rev": "$4", "type": "github", "owner": "metacraft-labs", "repo": "nim-shm-gset" }
    },
    "nim-shm-gset-src_2": {
      "locked": { "rev": "$2", "type": "github", "owner": "metacraft-labs", "repo": "nim-shm-gset" }
    },
    "nim-stew-src": {
      "locked": { "rev": "$3", "type": "github", "owner": "status-im", "repo": "nim-stew" }
    },
    "bearssl-src": {
      "locked": { "rev": "1111111111111111111111111111111111111111", "type": "git", "url": "https://github.com/status-im/nim-bearssl" }
    },
    "codetracer-src": {
      "locked": { "rev": "ffffffffffffffffffffffffffffffffffffffff", "type": "github", "owner": "metacraft-labs", "repo": "codetracer" }
    }
  },
  "root": "root",
  "version": 7
}
EOF
	git -C "$1" add flake.lock
	git -C "$1" commit -qm "pin gset at $2"
	git -C "$1" rev-parse HEAD
}

write_flake_lock() { # <path> <reprobuild-rev>
	cat >"$1" <<EOF
{
  "nodes": {
    "root": { "inputs": { "reprobuild": "reprobuild" } },
    "reprobuild": {
      "locked": { "rev": "$2", "type": "github", "owner": "metacraft-labs", "repo": "reprobuild" }
    }
  },
  "root": "root",
  "version": 7
}
EOF
}

# write_repro_lock <path> <gset-rev> <stew-rev>
# The self entry names the repository reprobuild's `codetracer-src` pins, so
# it WOULD be compared (and skip, having no checkout) if self were not
# excluded; "the self entry is never compared" below is therefore live.
write_repro_lock() {
	cat >"$1" <<EOF
schema = "reprobuild.solved-graph-lock.v3"

[lock]
platform = "amd64-linux"
deps = [{ name = "codetracer", self = "true", coord_kind = "vcs", url = "https://github.com/metacraft-labs/codetracer", revision = "2222222222222222222222222222222222222222", integrity = "" }, { name = "nim-shm-gset", coord_kind = "vcs", url = "https://github.com/metacraft-labs/nim-shm-gset", revision = "$2", integrity = "git-sha1:$2" }, { name = "nim-stew", coord_kind = "vcs", url = "https://github.com/metacraft-labs/nim-stew", revision = "$3", integrity = "" }]
EOF
}

STEW_CT=cccccccccccccccccccccccccccccccccccccccc
STEW_RB=dddddddddddddddddddddddddddddddddddddddd
DECOY=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

# make_ws <ws> <which of BASE|RB|AHEAD|SIDE codetracer pins>
# <ws>/repo is the fake codetracer, <ws>/reprobuild and <ws>/nim-shm-gset its
# siblings. Reprobuild always pins RB. Sets RB_REV (the reprobuild commit).
make_ws() {
	local ws="$1" pick
	mkdir -p "$ws/repo/scripts"
	cp "$GUARD" "$ws/repo/scripts/"
	make_gset "$ws/nim-shm-gset"
	pick="${!2}"
	RB_REV="$(make_reprobuild "$ws/reprobuild" "$RB" "$STEW_RB" "$DECOY")"
	write_flake_lock "$ws/repo/flake.lock" "$RB_REV"
	write_repro_lock "$ws/repo/repro.lock" "$pick" "$STEW_CT"
}

run_guard() { # <ws> [env...]
	local ws="$1"
	shift
	env "$@" bash "$ws/repo/scripts/test-reprobuild-dependency-pins.sh" 2>&1
}

echo
echo "equal and descendant pins pass"

WS="$TMP/equal"
make_ws "$WS" RB
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an equal pin exits 0" "$RC" 0
assert_contains "an equal pin is reported as equal" "$OUT" "equal to reprobuild's nim-shm-gset-src"
assert_contains "the run says it verified" "$OUT" "OK: all 1 sibling pin(s)"
# The fixture's flake.lock hands the plain node key to a nested homonym; the
# root's input is `_2`. An equal verdict proves the root edge was read.
assert_absent "the nested homonym is not what was compared" "$OUT" "$DECOY"

WS="$TMP/ahead"
make_ws "$WS" AHEAD
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a descendant pin exits 0" "$RC" 0
assert_contains "a descendant pin is reported as such" "$OUT" "descends from reprobuild's nim-shm-gset-src $RB"

echo
echo "behind and diverged pins fail, naming the repo, both revisions and the remedy"

WS="$TMP/behind"
make_ws "$WS" BASE
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a pin behind reprobuild's exits 1" "$RC" 1
assert_contains "it is called BEHIND" "$OUT" "nim-shm-gset (github.com/metacraft-labs/nim-shm-gset) is BEHIND reprobuild's pin"
assert_contains "it names this repo's revision" "$OUT" "repro.lock here:                     $BASE"
assert_contains "it names reprobuild's revision" "$OUT" "nim-shm-gset-src: $RB"
assert_contains "it gives the paste-ready remedy" "$OUT" "repro lock update nim-shm-gset --repo-root=$WS/repo --to $RB"
assert_absent "it is not called diverged" "$OUT" "DIVERGED"
assert_absent "it does not claim a pass" "$OUT" "OK:"
assert_absent "it does not blame the unrelated stew" "$OUT" "nim-stew (github.com"

WS="$TMP/diverged"
make_ws "$WS" SIDE
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a diverged pin exits 1" "$RC" 1
assert_contains "it is called DIVERGED" "$OUT" "has DIVERGED from reprobuild's pin"
assert_contains "it names this repo's revision" "$OUT" "$SIDE"
assert_absent "it is not called BEHIND" "$OUT" "BEHIND"

echo
echo "a sibling that names a different repository is not compared (nim-stew)"

WS="$TMP/stew"
make_ws "$WS" RB
OUT="$(run_guard "$WS")"
assert_absent "metacraft-labs/nim-stew is not matched to status-im/nim-stew" "$OUT" "nim-stew"
assert_absent "the self entry is never compared" "$OUT" "codetracer (github.com"

# Positive control for the exclusion: the SAME repo name under status-im is
# compared, and with a revision the fixture has no checkout for it skips.
sed -i "s#https://github.com/metacraft-labs/nim-stew#https://github.com/Status-IM/nim-stew.git#" "$WS/repo/repro.lock"
OUT="$(run_guard "$WS")"
RC=$?
assert_contains "the same repository (case/.git normalised) IS compared" "$OUT" "nim-stew (github.com/status-im/nim-stew)"
assert_rc "and an uncheckable sibling is a skip, not a failure" "$RC" 0

echo
echo "missing checkouts skip loudly, keep checking the rest, and STRICT fails"

WS="$TMP/nosibling"
make_ws "$WS" RB
sed -i "s#https://github.com/metacraft-labs/nim-stew#https://github.com/status-im/nim-stew#" "$WS/repo/repro.lock"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an absent sibling checkout skips with exit 0" "$RC" 0
assert_contains "the skip names the missing checkout" "$OUT" "no checkout at $WS/nim-stew"
assert_contains "the skip states it did not verify everything" "$OUT" "NOT fully verified by this run"
assert_contains "the other sibling was still checked" "$OUT" "ok   nim-shm-gset"
assert_absent "the skip does not claim a pass" "$OUT" "OK:"
OUT="$(run_guard "$WS" CT_REPROBUILD_DEPENDENCY_PINS_STRICT=1)"
RC=$?
assert_rc "STRICT=1 turns that skip into exit 1" "$RC" 1
assert_contains "STRICT=1 says why it is a failure" "$OUT" "CT_REPROBUILD_DEPENDENCY_PINS_STRICT=1"

WS="$TMP/behind-plus-skip"
make_ws "$WS" BASE
sed -i "s#https://github.com/metacraft-labs/nim-stew#https://github.com/status-im/nim-stew#" "$WS/repo/repro.lock"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a skip elsewhere does not hide a real failure" "$RC" 1
assert_contains "the failure is still named" "$OUT" "is BEHIND reprobuild's pin"

WS="$TMP/lacksrev"
make_ws "$WS" RB
write_repro_lock "$WS/repo/repro.lock" 3333333333333333333333333333333333333333 "$STEW_CT"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a sibling checkout lacking the pinned rev skips with exit 0" "$RC" 0
assert_contains "that skip names the fetch that fixes it" "$OUT" "fetch origin 3333333333333333333333333333333333333333"
assert_absent "a missing revision is not called BEHIND" "$OUT" "BEHIND"

WS="$TMP/noreprobuild"
make_ws "$WS" BASE
rm -rf "$WS/reprobuild"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an absent reprobuild checkout skips with exit 0" "$RC" 0
assert_contains "the skip names the reprobuild checkout" "$OUT" "no reprobuild checkout at"
assert_contains "the skip states it verified nothing" "$OUT" "were NOT verified by this run"
OUT="$(run_guard "$WS" CT_REPROBUILD_DEPENDENCY_PINS_STRICT=1)"
RC=$?
assert_rc "STRICT=1 turns the reprobuild skip into exit 1" "$RC" 1

WS="$TMP/stalereprobuild"
make_ws "$WS" RB
write_flake_lock "$WS/repo/flake.lock" 4444444444444444444444444444444444444444
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a reprobuild checkout without the pinned rev skips with exit 0" "$RC" 0
assert_contains "that skip names the fetch that fixes it" "$OUT" "fetch origin 4444444444444444444444444444444444444444"

echo
echo "checkouts may be linked worktrees, and may live elsewhere"

WS="$TMP/worktrees"
make_ws "$WS" BASE
mv "$WS/nim-shm-gset" "$TMP/gset-main"
git -C "$TMP/gset-main" worktree add -q --detach "$WS/nim-shm-gset" HEAD
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a linked-worktree sibling is read" "$RC" 1
assert_contains "and the ancestry check really ran" "$OUT" "is BEHIND reprobuild's pin"

WS="$TMP/envdir"
make_ws "$WS" AHEAD
mkdir -p "$TMP/elsewhere"
mv "$WS/nim-shm-gset" "$TMP/elsewhere/nim-shm-gset"
mv "$WS/reprobuild" "$TMP/elsewhere-reprobuild"
OUT="$(run_guard "$WS" CT_WORKSPACE_ROOT="$TMP/elsewhere" CT_REPROBUILD_CHECKOUT="$TMP/elsewhere-reprobuild")"
RC=$?
assert_rc "out-of-tree checkouts are used and pass" "$RC" 0
assert_contains "and the comparison really ran" "$OUT" "OK: all 1 sibling pin(s)"

echo
echo "the workspace root is found when the checkout is not its direct child"
# The real failure this guards: a linked worktree at <workspace>/fixes/<name>
# took "the parent directory" as the workspace, found no reprobuild there, and
# `just test` reported the resulting whole-check SKIP as success.

WS="$TMP/marked"
make_ws "$WS" BASE
touch "$WS/repro-workspace.toml"
mkdir -p "$WS/fixes"
mv "$WS/repo" "$WS/fixes/repo"
OUT="$(env -u CT_WORKSPACE_ROOT bash "$WS/fixes/repo/scripts/test-reprobuild-dependency-pins.sh" 2>&1)"
RC=$?
assert_rc "a nested checkout under a repro-workspace.toml root is checked" "$RC" 1
assert_contains "it names the marked workspace root" "$OUT" "workspace root: $WS"
assert_contains "and the ancestry check really ran" "$OUT" "is BEHIND reprobuild's pin"
assert_absent "it did not skip for want of a reprobuild" "$OUT" "no reprobuild checkout at"

WS="$TMP/linked"
make_ws "$WS" BASE
init_repo "$WS/repo"
git -C "$WS/repo" add -A
git -C "$WS/repo" commit -qm "fake codetracer"
mkdir -p "$TMP/linked-elsewhere/deeper"
git -C "$WS/repo" worktree add -q --detach "$TMP/linked-elsewhere/deeper/wt" HEAD
OUT="$(env -u CT_WORKSPACE_ROOT bash "$TMP/linked-elsewhere/deeper/wt/scripts/test-reprobuild-dependency-pins.sh" 2>&1)"
RC=$?
assert_rc "a linked worktree with no marker resolves siblings beside its main worktree" "$RC" 1
assert_contains "it names the main worktree's parent" "$OUT" "workspace root: $WS"
assert_contains "and the ancestry check really ran" "$OUT" "is BEHIND reprobuild's pin"

echo
echo "reprobuild's own repro.lock pins are compared too"
# reprobuild's develop set (its repro.lock) names siblings its flake.lock does
# not (reprobuild-packages, at 2f7cb5db52). Here only the repro.lock names
# nim-stew under metacraft-labs, at a revision AHEAD of this repo's.

WS="$TMP/rbrepro"
make_ws "$WS" RB
GSET_RB="$RB" # make_gset below reassigns BASE/RB/AHEAD to nim-stew's commits
make_gset "$WS/nim-stew"
cat >"$WS/reprobuild/repro.lock" <<RBLOCK
schema = "reprobuild.solved-graph-lock.v3"

[lock]
deps = [{ name = "reprobuild", self = "true", coord_kind = "vcs", url = "https://github.com/metacraft-labs/reprobuild", revision = "5555555555555555555555555555555555555555" }, { name = "nim-stew", coord_kind = "vcs", url = "https://github.com/metacraft-labs/nim-stew.git", revision = "$AHEAD" }]
RBLOCK
git -C "$WS/reprobuild" add repro.lock
git -C "$WS/reprobuild" commit -qm "add a repro.lock"
write_flake_lock "$WS/repo/flake.lock" "$(git -C "$WS/reprobuild" rev-parse HEAD)"
write_repro_lock "$WS/repo/repro.lock" "$GSET_RB" "$BASE"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a pin behind reprobuild's repro.lock exits 1" "$RC" 1
assert_contains "it is named, with the repro.lock as its source" "$OUT" "repro.lock:nim-stew: $AHEAD"
assert_contains "it is called BEHIND" "$OUT" "nim-stew (github.com/metacraft-labs/nim-stew) is BEHIND reprobuild's pin"
assert_absent "reprobuild's self entry is not compared" "$OUT" "5555555555555555555555555555555555555555"
assert_contains "the flake.lock pins are still compared" "$OUT" "ok   nim-shm-gset"

printf 'deps = [ not toml\n' >"$WS/reprobuild/repro.lock"
git -C "$WS/reprobuild" commit -qam "break the repro.lock"
write_flake_lock "$WS/repo/flake.lock" "$(git -C "$WS/reprobuild" rev-parse HEAD)"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unparseable reprobuild repro.lock exits 1" "$RC" 1
assert_contains "it is called a parse failure" "$OUT" "could not read 'reprobuild repro.lock'"
assert_absent "it does not accuse any pin" "$OUT" "BEHIND"

echo
echo "a missing python3 names ITSELF and does not accuse a lock"

WS="$TMP/nopython"
make_ws "$WS" RB
mkdir -p "$TMP/emptybin"
OUT="$(PATH="$TMP/emptybin" "$BASH_ABS" "$WS/repo/scripts/test-reprobuild-dependency-pins.sh" 2>&1)"
RC=$?
assert_rc "missing python3 exits 1" "$RC" 1
assert_contains "missing python3 is named" "$OUT" "python3 is required to read flake.lock"
assert_contains "missing python3 says nothing was established" "$OUT" "NOTHING about the pins has been established"
assert_absent "missing python3 does not accuse the lock" "$OUT" "has no locked rev for input"
assert_absent "missing python3 does not claim a verdict" "$OUT" "OK:"

echo
echo "an unparseable lock reports a PARSE failure, not a pin accusation"

WS="$TMP/badflake"
make_ws "$WS" RB
printf 'this is not json\n' >"$WS/repo/flake.lock"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unparseable flake.lock exits 1" "$RC" 1
assert_contains "it is called a parse failure" "$OUT" "NOT a statement about any pin"
assert_absent "it does not then accuse the reprobuild input" "$OUT" "has no locked rev for input"

WS="$TMP/badrepro"
make_ws "$WS" BASE
printf 'deps = [ this is not toml\n' >"$WS/repo/repro.lock"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unparseable repro.lock exits 1" "$RC" 1
assert_contains "it names repro.lock" "$OUT" "as a repro.lock"
assert_contains "it is called a parse failure" "$OUT" "NOT a statement about any pin"
assert_absent "it does not accuse any pin" "$OUT" "BEHIND"
assert_absent "it does not claim the layout changed" "$OUT" "no sibling in repro.lock"

WS="$TMP/badrbflake"
make_ws "$WS" RB
printf '{ "nodes": ' >"$WS/reprobuild/flake.lock"
git -C "$WS/reprobuild" commit -qam "break the lock"
write_flake_lock "$WS/repo/flake.lock" "$(git -C "$WS/reprobuild" rev-parse HEAD)"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "an unparseable reprobuild flake.lock exits 1" "$RC" 1
assert_contains "it is called a parse failure" "$OUT" "could not read 'reprobuild flake.lock'"

echo
echo "a lock that really has lost the reprobuild input says THAT"

WS="$TMP/noinput"
make_ws "$WS" RB
printf '{ "nodes": { "root": { "inputs": {} } }, "root": "root", "version": 7 }\n' >"$WS/repo/flake.lock"
OUT="$(run_guard "$WS")"
RC=$?
assert_rc "a dropped reprobuild input exits 1" "$RC" 1
assert_contains "it is reported as such" "$OUT" "has no locked rev for input 'reprobuild'"
assert_absent "it is not called a parse failure" "$OUT" "NOT a statement about any pin"

echo
echo "mutation: the BEHIND verdict comes from the ancestry test, not decoration"
# Swap the two ancestry probes' argument order: the guard would then call a
# descendant pin BEHIND and a behind pin a descendant. The healthy guard
# passed both cases above, so the mutant MUST get both wrong.
WS="$TMP/mutant"
make_ws "$WS" BASE
MUTANT="$WS/repo/scripts/test-reprobuild-dependency-pins.sh"
# shellcheck disable=SC2016 # the $ are literal text in a sed program
sed 's/--is-ancestor "\$rb_rev" "\$ct_rev"/--is-ancestor "$ct_rev" "$rb_rev"/' "$GUARD" >"$MUTANT"
if cmp -s "$GUARD" "$MUTANT"; then
	bad "the mutation changed nothing" "update this mutation to match the guard's ancestry probe"
else
	ok "the mutation swapped the ancestry probe"
	OUT="$(bash "$MUTANT" 2>&1)"
	RC=$?
	assert_rc "the mutant passes a pin that is behind" "$RC" 0
fi

echo
if [ "$FAILED" -ne 0 ]; then
	echo "$PASS assertion(s) passed, $FAILED FAILED" >&2
	exit 1
fi
echo "all $PASS assertions passed"
