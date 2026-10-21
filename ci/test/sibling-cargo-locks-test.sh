#!/usr/bin/env bash
#
# Contract suite for scripts/test-sibling-cargo-locks.sh.
#
# The guard asserts that every committed Cargo.lock reaching the sibling
# `codetracer-trace-format` by path matches the trace-format revision that
# `repro.lock` and `flake.lock` both pin, and that it also resolves against the
# sibling checkout on disk. Its own header says why. This suite is about the
# ways such a guard is wrong while looking right:
#
#   * PASSING THE ISSUE'S OWN STATE. Sibling ahead of the pin, pins and locks
#     behind it — exactly codetracer `4062bfe2c` with trace-format `afa4dde`.
#     The guard must fail, naming both revisions.
#   * CATCHING ONLY ONE DIRECTION. A lock refreshed without moving the pins,
#     the pins moved without refreshing the lock, and repro.lock moved without
#     flake.lock are three distinct failures, each with its own arm. The
#     refreshed-lock arm is the subtle one: `cargo --locked` ACCEPTS a lock
#     carrying an edge the pinned tree no longer has, so a guard built on
#     `--locked` alone passes it. A mutation arm at the end proves the guard's
#     exact comparison is what catches it.
#   * REPORTING ON NOTHING. Zero consumer manifests, or an absent sibling, must
#     never print OK. The absent sibling is a SKIP (a failure under STRICT),
#     and the pin comparison must still run without it.
#   * ACCUSING THE WRONG THING. Missing python3 or cargo, an unparseable
#     flake.lock, or a cargo failure that is not about the lock must say so and
#     must NOT be reported as a stale lock. Those arms assert the right
#     diagnostic AND the absence of the wrong one.
#   * WRITING THE LOCK IT CHECKS. After every arm the fixture's committed locks
#     must be byte-identical to what was committed.
#
# NO MOCKS OF THE TOOLS UNDER TEST: every arm runs the real guard, real git and
# the real cargo against real (tiny) crates. The fixtures stand in for the two
# repositories only, which is unavoidable — the states under test (a sibling
# ahead of the pin, a lock refreshed against the wrong tree) must be created on
# purpose. The fixture crates have no registry dependencies, so `--offline`
# resolution needs no registry cache and no network.
#
# Needs bash, git, python3 and cargo; it fails, naming the tool, when one is
# missing. A few seconds; writes nothing outside its own mktemp.
#
# Run: bash ci/test/sibling-cargo-locks-test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="$REPO_ROOT/scripts/test-sibling-cargo-locks.sh"

[ -f "$GUARD" ] || {
	echo "FAIL: the script under test is missing: $GUARD" >&2
	exit 1
}
for tool in git python3 cargo; do
	command -v "$tool" >/dev/null 2>&1 || {
		echo "FAIL: '$tool' is required by this suite and is not on PATH; NOTHING was tested. Run inside the dev shell." >&2
		exit 1
	}
done

BASH_ABS="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

# Keep the fixtures' cargo away from the user's ~/.cargo config and caches:
# the crates need no registry, and a fresh CARGO_HOME proves it.
export CARGO_HOME="$TMP/cargo-home"
unset CT_TRACE_FORMAT_CHECKOUT CT_SIBLING_CARGO_LOCKS_STRICT CARGO

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

git_init() {
	git -C "$1" init -q
	git -C "$1" config user.email sibling-locks-test@example.invalid
	git -C "$1" config user.name "sibling locks test"
	git -C "$1" config commit.gpgsign false
}

# --- The fake trace-format repository -------------------------------------
#
# REV1: lib_a has no dependencies.
# REV2: lib_a gains a path dependency on lib_b — the same SHAPE of change as
#       afa4dde adding getrandom to codetracer_ctfs: a new edge in a sibling
#       crate, which a lock written against REV1 does not list.
# REV3: lib_a's manifest is broken, for the "not a stale lock" arm.
TF_SRC="$TMP/tf-src"
mkdir -p "$TF_SRC/lib_a/src" "$TF_SRC/lib_b/src"
git_init "$TF_SRC"
printf '[package]\nname = "lib_a"\nversion = "0.1.0"\nedition = "2021"\n' >"$TF_SRC/lib_a/Cargo.toml"
printf '[package]\nname = "lib_b"\nversion = "0.1.0"\nedition = "2021"\n' >"$TF_SRC/lib_b/Cargo.toml"
: >"$TF_SRC/lib_a/src/lib.rs"
: >"$TF_SRC/lib_b/src/lib.rs"
git -C "$TF_SRC" add -A && git -C "$TF_SRC" commit -qm rev1
REV1="$(git -C "$TF_SRC" rev-parse HEAD)"
printf '\n[dependencies]\nlib_b = { path = "../lib_b" }\n' >>"$TF_SRC/lib_a/Cargo.toml"
git -C "$TF_SRC" commit -qam rev2
REV2="$(git -C "$TF_SRC" rev-parse HEAD)"
printf 'this is [not toml\n' >"$TF_SRC/lib_a/Cargo.toml"
git -C "$TF_SRC" commit -qam rev3
REV3="$(git -C "$TF_SRC" rev-parse HEAD)"
ABSENT_REV=9999999999999999999999999999999999999999

# write_repro_lock <path> <rev> — the self entry comes FIRST and names the dep
# in its `depends` string, so a grep-based reader would find it before the real
# record.
write_repro_lock() {
	cat >"$1" <<EOF
schema = "reprobuild.solved-graph-lock.v3"

[lock]
platform = "amd64-linux"
deps = [{ name = "codetracer", self = "true", revision = "0000000000000000000000000000000000000000", depends = "codetracer-trace-format,other" }, { name = "codetracer-trace-format", coord_kind = "vcs", revision = "$2" }]
EOF
}

# write_flake_lock <path> <rev> — the plain node key belongs to a NESTED
# homonym carrying a decoy rev; the root's own input sits under `_2`, the shape
# nix really writes when two flakes in the closure name an input alike.
write_flake_lock() {
	cat >"$1" <<EOF
{
  "nodes": {
    "root": { "inputs": { "codetracer-trace-format": "codetracer-trace-format_2", "other": "other" } },
    "other": { "inputs": { "codetracer-trace-format": "codetracer-trace-format" }, "locked": { "rev": "aaaa" } },
    "codetracer-trace-format": { "locked": { "rev": "$ABSENT_REV", "type": "github" } },
    "codetracer-trace-format_2": { "locked": { "rev": "$2", "type": "github" } }
  },
  "root": "root",
  "version": 7
}
EOF
}

# Lock contents for each sibling state, generated by real cargo once.
#   lock_for <rev> -> prints the Cargo.lock of the consumer crate against <rev>
gen_lock() {
	local rev="$1" dir="$TMP/gen-$1"
	mkdir -p "$dir/codetracer/src/app/src" "$dir/codetracer-trace-format"
	git -C "$TF_SRC" archive "$rev" | tar -x -C "$dir/codetracer-trace-format"
	write_app "$dir/codetracer/src/app"
	(cd "$dir/codetracer/src/app" && cargo generate-lockfile --offline -q) || return 1
	cat "$dir/codetracer/src/app/Cargo.lock"
}

write_app() {
	mkdir -p "$1/src"
	cat >"$1/Cargo.toml" <<'EOF'
[package]
name = "app"
version = "0.1.0"
edition = "2021"

[dependencies]
lib_a = { path = "../../../codetracer-trace-format/lib_a" }
EOF
	echo 'fn main() {}' >"$1/src/main.rs"
}

LOCK1="$(gen_lock "$REV1")" || {
	echo "FAIL: could not generate the fixture lock for REV1 with cargo" >&2
	exit 1
}
LOCK2="$(gen_lock "$REV2")" || {
	echo "FAIL: could not generate the fixture lock for REV2 with cargo" >&2
	exit 1
}
if [ "$LOCK1" = "$LOCK2" ]; then
	echo "FAIL: the REV1 and REV2 fixture locks are identical; the fixture no longer models a sibling edge change" >&2
	exit 1
fi

# make_ws <ws> <repro-rev> <flake-rev> <lock: 1|2> <sibling HEAD rev|none>
#   <ws>/codetracer               fake codetracer checkout (committed)
#   <ws>/codetracer-trace-format  clone of TF_SRC checked out at <sibling>
make_ws() {
	local ws="$1" repro_rev="$2" flake_rev="$3" lock="$4" sibling="$5"
	local ct="$ws/codetracer"
	mkdir -p "$ct/scripts"
	git_init "$ct"
	cp "$GUARD" "$ct/scripts/"
	write_repro_lock "$ct/repro.lock" "$repro_rev"
	write_flake_lock "$ct/flake.lock" "$flake_rev"
	write_app "$ct/src/app"
	if [ "$lock" = 1 ]; then printf '%s\n' "$LOCK1" >"$ct/src/app/Cargo.lock"; else printf '%s\n' "$LOCK2" >"$ct/src/app/Cargo.lock"; fi
	# An in-repo crate with no sibling reach must NOT be counted.
	mkdir -p "$ct/src/unrelated/src"
	printf '[package]\nname = "unrelated"\nversion = "0.1.0"\nedition = "2021"\n' >"$ct/src/unrelated/Cargo.toml"
	echo 'fn main() {}' >"$ct/src/unrelated/src/main.rs"
	git -C "$ct" add -A && git -C "$ct" commit -qm fixture
	if [ "$sibling" != none ]; then
		git clone -q "$TF_SRC" "$ws/codetracer-trace-format"
		git -C "$ws/codetracer-trace-format" checkout -q "$sibling"
	fi
}

run_guard() {
	OUT="$("$BASH_ABS" "$1/codetracer/scripts/test-sibling-cargo-locks.sh" 2>&1)"
	RC=$?
}

# The committed locks are never touched by the guard.
assert_locks_untouched() {
	if git -C "$1/codetracer" diff --quiet -- '*Cargo.lock' &&
		[ -z "$(git -C "$1/codetracer" status --porcelain -- '*Cargo.lock')" ]; then
		ok "$2: the committed Cargo.lock is unchanged"
	else
		bad "$2: the guard MODIFIED a committed Cargo.lock" "$(git -C "$1/codetracer" status --porcelain)"
	fi
}

echo
echo "consistent: pins, lock and sibling all at REV1"
WS="$TMP/consistent"
make_ws "$WS" "$REV1" "$REV1" 1 "$REV1"
run_guard "$WS"
assert_rc "consistent exits 0" "$RC" 0
assert_contains "consistent prints OK" "$OUT" "OK: repro.lock and flake.lock pin codetracer-trace-format@$REV1"
assert_contains "the root input is read through the _2 homonym" "$OUT" "flake.lock  codetracer-trace-format = $REV1"
assert_contains "the self entry's depends string is not mistaken for the dep" "$OUT" "repro.lock  codetracer-trace-format = $REV1"
assert_contains "exactly one consumer lock is found (unrelated crate excluded)" "$OUT" "consumer locks: 1"
assert_locks_untouched "$WS" consistent

echo
echo "the issue's state: sibling at REV2, pins and lock at REV1"
WS="$TMP/issue"
make_ws "$WS" "$REV1" "$REV1" 1 "$REV2"
run_guard "$WS"
assert_rc "sibling ahead of the pin exits 1" "$RC" 1
assert_contains "it is reported against the checkout on disk" "$OUT" "do not match the sibling checkout"
assert_contains "it names the pinned revision" "$OUT" "= $REV1"
assert_contains "it names the checkout's revision" "$OUT" "HEAD $REV2"
assert_contains "it offers the pin-moving remedy" "$OUT" "repro lock update codetracer-trace-format --to $REV2"
assert_contains "it offers putting the sibling back" "$OUT" "checkout $REV1"
assert_absent "it does not blame the pin/lock pairing, which is consistent" "$OUT" "do not match the codetracer-trace-format revision"
assert_locks_untouched "$WS" issue

echo
echo "pins moved to REV2, lock NOT refreshed"
WS="$TMP/pins-only"
make_ws "$WS" "$REV2" "$REV2" 1 "$REV2"
run_guard "$WS"
assert_rc "pins moved alone exits 1" "$RC" 1
assert_contains "it is reported against the pinned revision" "$OUT" "do not match the codetracer-trace-format revision"
assert_contains "it names the pin" "$OUT" "pin  codetracer-trace-format = $REV2"
assert_locks_untouched "$WS" pins-only

echo
echo "lock refreshed to REV2, pins NOT moved (sibling back on the pin)"
WS="$TMP/lock-only"
make_ws "$WS" "$REV1" "$REV1" 2 "$REV1"
run_guard "$WS"
assert_rc "lock refreshed alone exits 1" "$RC" 1
assert_contains "it is reported against the pinned revision" "$OUT" "do not match the codetracer-trace-format revision"
assert_locks_untouched "$WS" lock-only

echo
echo "lock refreshed to REV2 with the sibling at REV2, pins NOT moved"
WS="$TMP/lock-only-sibling-ahead"
make_ws "$WS" "$REV1" "$REV1" 2 "$REV2"
run_guard "$WS"
assert_rc "a build-green but unpinned refresh exits 1" "$RC" 1
assert_contains "the pinned check catches it although the build would pass" "$OUT" "do not match the codetracer-trace-format revision"
assert_absent "the checkout check does not, correctly" "$OUT" "do not match the sibling checkout"

echo
echo "everything moved together to REV2"
WS="$TMP/fixed"
make_ws "$WS" "$REV2" "$REV2" 2 "$REV2"
run_guard "$WS"
assert_rc "moved together exits 0" "$RC" 0
assert_contains "moved together prints OK" "$OUT" "OK: repro.lock and flake.lock pin codetracer-trace-format@$REV2"

echo
echo "repro.lock moved, flake.lock not"
WS="$TMP/pins-disagree"
make_ws "$WS" "$REV2" "$REV1" 2 "$REV2"
run_guard "$WS"
assert_rc "disagreeing pins exit 1" "$RC" 1
assert_contains "disagreeing pins are named" "$OUT" "pin DIFFERENT codetracer-trace-format revisions"
assert_contains "the repro.lock rev is shown" "$OUT" "revision   = $REV2"
assert_contains "the flake.lock rev is shown" "$OUT" "locked.rev = $REV1"
assert_absent "no cargo verdict is drawn from disagreeing pins" "$OUT" "consumer locks:"

echo
echo "sibling absent: a loud SKIP, never OK; STRICT makes it a failure"
WS="$TMP/no-sibling"
make_ws "$WS" "$REV1" "$REV1" 1 none
run_guard "$WS"
assert_rc "absent sibling exits 0 (skip)" "$RC" 0
assert_contains "absent sibling says SKIP" "$OUT" "SKIP: no codetracer-trace-format checkout at"
assert_contains "absent sibling says what was not verified" "$OUT" "were NOT fully verified"
assert_absent "absent sibling never prints OK" "$OUT" "OK: "
OUT="$(CT_SIBLING_CARGO_LOCKS_STRICT=1 "$BASH_ABS" "$WS/codetracer/scripts/test-sibling-cargo-locks.sh" 2>&1)"
RC=$?
assert_rc "absent sibling under STRICT exits 1" "$RC" 1
assert_contains "STRICT names itself" "$OUT" "CT_SIBLING_CARGO_LOCKS_STRICT=1"

WS="$TMP/no-sibling-pins-disagree"
make_ws "$WS" "$REV1" "$REV2" 1 none
run_guard "$WS"
assert_rc "disagreeing pins fail even with no sibling" "$RC" 1
assert_contains "and are named as such" "$OUT" "pin DIFFERENT"

echo
echo "pinned revision missing from the sibling's objects: SKIP with the fetch remedy"
WS="$TMP/rev-not-fetched"
make_ws "$WS" "$ABSENT_REV" "$ABSENT_REV" 1 "$REV1"
run_guard "$WS"
assert_contains "it names the fetch that fixes it" "$OUT" "fetch origin $ABSENT_REV"
assert_absent "it never prints OK" "$OUT" "OK: "

echo
echo "a cargo failure that is NOT a stale lock is not reported as one"
WS="$TMP/broken-sibling-manifest"
make_ws "$WS" "$REV3" "$REV3" 1 "$REV3"
run_guard "$WS"
assert_rc "broken sibling manifest exits 1" "$RC" 1
assert_contains "it is called what it is" "$OUT" "for a reason that is NOT a stale lock"
assert_absent "it does not accuse the lock" "$OUT" "STALE"

echo
echo "missing tools name themselves and do not accuse the locks"
WS="$TMP/no-cargo"
make_ws "$WS" "$REV1" "$REV1" 1 "$REV1"
OUT="$(CARGO="$TMP/no/such/cargo" "$BASH_ABS" "$WS/codetracer/scripts/test-sibling-cargo-locks.sh" 2>&1)"
RC=$?
assert_rc "missing cargo exits 1" "$RC" 1
assert_contains "missing cargo is named" "$OUT" "is required to resolve the Cargo.locks"
assert_absent "missing cargo is not a stale-lock verdict" "$OUT" "do not match"
assert_absent "missing cargo never prints OK" "$OUT" "OK: "
mkdir -p "$TMP/emptybin"
OUT="$(PATH="$TMP/emptybin" "$BASH_ABS" "$WS/codetracer/scripts/test-sibling-cargo-locks.sh" 2>&1)"
RC=$?
assert_rc "missing python3 exits 1" "$RC" 1
assert_contains "missing python3 is named" "$OUT" "python3 is required"
assert_absent "missing python3 does not accuse a lock" "$OUT" "has no"

echo
echo "an unparseable flake.lock is a PARSE failure, and stops there"
WS="$TMP/bad-flake-lock"
make_ws "$WS" "$REV1" "$REV1" 1 "$REV1"
printf 'not json\n' >"$WS/codetracer/flake.lock"
run_guard "$WS"
assert_rc "unparseable flake.lock exits 1" "$RC" 1
assert_contains "it is called a parse failure" "$OUT" "NOT a statement about any pin"
assert_absent "the false accusation does not follow it" "$OUT" "flake.lock has no locked rev"

echo
echo "discovery: transitive consumers count, and zero consumers is a failure"
WS="$TMP/transitive"
make_ws "$WS" "$REV1" "$REV1" 1 "$REV1"
mkdir -p "$WS/codetracer/src/wrap/src"
cat >"$WS/codetracer/src/wrap/Cargo.toml" <<'EOF'
[package]
name = "wrap"
version = "0.1.0"
edition = "2021"

[dev-dependencies]
app = { path = "../app" }
EOF
: >"$WS/codetracer/src/wrap/src/lib.rs"
# Its lock is generated against the CURRENT sibling (REV1), so it is valid.
(cd "$WS/codetracer/src/wrap" && cargo generate-lockfile --offline -q)
git -C "$WS/codetracer" add -A && git -C "$WS/codetracer" commit -qm wrap
run_guard "$WS"
assert_rc "a valid transitive consumer passes" "$RC" 0
assert_contains "the transitive consumer is found" "$OUT" "src/wrap/Cargo.toml (via src/app)"
assert_contains "and both locks are checked" "$OUT" "consumer locks: 2"

WS="$TMP/no-consumers"
make_ws "$WS" "$REV1" "$REV1" 1 "$REV1"
git -C "$WS/codetracer" rm -q -r src/app
git -C "$WS/codetracer" commit -qm "drop the consumer"
run_guard "$WS"
assert_rc "zero consumers exits 1" "$RC" 1
assert_contains "zero consumers is named, not passed" "$OUT" "no git-tracked Cargo.toml reaches ../codetracer-trace-format"
assert_absent "zero consumers never prints OK" "$OUT" "OK: "

echo
echo "mutation: the checkout check is LIVE"
# Without check 3 the issue's state passes (pins and lock agree with each
# other). Neutralise the call and the issue arm must go green — proving that
# arm's red comes from check 3 and nothing else.
WS="$TMP/mutant"
make_ws "$WS" "$REV1" "$REV1" 1 "$REV2"
MUTANT="$WS/codetracer/scripts/test-sibling-cargo-locks.sh"
sed 's/^\tresolve_against disk /\ttrue /' "$GUARD" >"$MUTANT"
if cmp -s "$GUARD" "$MUTANT"; then
	bad "the mutation changed nothing — update it to match how the guard invokes check 3"
else
	ok "the mutation removed check 3"
	OUT="$("$BASH_ABS" "$MUTANT" 2>&1)"
	assert_absent "without check 3 the issue's state is NOT caught" "$OUT" "do not match the sibling checkout"
fi

echo
echo "mutation: the EXACT comparison is live — '--locked' alone would miss a refreshed lock"
# cargo's `--locked` accepts a lock carrying an edge the tree no longer has
# (the guard's header records the measurement). Replace the exact comparison
# with "cargo exited 0" and the lock-refreshed-pins-not-moved state must go
# green, proving the arm above is red because of the comparison.
WS="$TMP/mutant-exact"
make_ws "$WS" "$REV1" "$REV1" 2 "$REV1"
MUTANT="$WS/codetracer/scripts/test-sibling-cargo-locks.sh"
# The dollar signs are sed pattern text, not shell expansions.
# shellcheck disable=SC2016
sed 's/^\t\tif cmp -s "\$REPO_ROOT\/\$lockdir\/Cargo.lock"/\t\tif true || cmp -s "$REPO_ROOT\/$lockdir\/Cargo.lock"/' "$GUARD" >"$MUTANT"
if cmp -s "$GUARD" "$MUTANT"; then
	bad "the mutation changed nothing — update it to match how the guard compares locks"
else
	ok "the mutation removed the exact comparison"
	OUT="$("$BASH_ABS" "$MUTANT" 2>&1)"
	RC=$?
	assert_rc "without it a refreshed lock with unmoved pins passes" "$RC" 0
fi

echo
if [ "$FAILED" -gt 0 ]; then
	echo "sibling-cargo-locks contract: $FAILED failed, $PASS passed" >&2
	exit 1
fi
echo "sibling-cargo-locks contract: all $PASS passed"
