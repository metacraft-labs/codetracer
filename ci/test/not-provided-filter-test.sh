#!/usr/bin/env bash
#
# not-provided-filter-test.sh -- contract suite for ci/lib/not-provided-filter.sh,
# the one place a lane's not-provided list (ci/test/*-not-provided.*.txt)
# becomes a nextest filterset.
#
# The lists name integration tests of two crates (src/db-backend and
# src/backend-manager), and each crate is a separate `cargo nextest run`.
# nextest refuses a filterset whose `binary(x)` matches no binary of the crate
# it runs in, so the filter must hand each run only the entries for its own
# crate. And the lane that DOES run an entry selects it from the same line
# (`--lane <job>`), so selection must return exactly the entries naming that
# job in that crate, and refuse -- not return an empty selection -- when
# there are none. Each of those is asserted here against fixture lists and
# fixture crate directories, then the real Linux list against the real crates.
#
# No mocks: the script under test is run as the lanes run it. Pure bash; no
# cargo, no nix. (Whether nextest itself accepts the emitted filtersets is a
# property of nextest, measured when the lists change: `cargo nextest list -E`
# in each crate.)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FILTER="$REPO_ROOT/ci/lib/not-provided-filter.sh"

assertions=0
failures=0
ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	[ -n "${2:-}" ] && printf '         %s\n' "$2"
}

fixtures="$(mktemp -d)"
trap 'rm -rf "$fixtures"' EXIT
mkdir -p "$fixtures/a" "$fixtures/b" "$fixtures/empty"
: >"$fixtures/a/alpha.rs"
: >"$fixtures/b/beta.rs"
: >"$fixtures/b/gamma.rs"
cat >"$fixtures/list.txt" <<'EOF'
# a comment, and a blank line

binary(alpha)                                  | tool one | lane-x
binary(beta) and test(/^(one|two)$/)           | tool two | lane-y (a note)
binary(gamma)                                  | tool three | lane-y
EOF
printf 'test(/^x$/) | tool | lane-x\n' >"$fixtures/bad.txt"

# run <name> <args...>: OUT, ERR and STATUS of one invocation.
run() {
	STATUS=0
	OUT="$(bash "$FILTER" "$@" 2>"$fixtures/stderr")" || STATUS=$?
	ERR="$(cat "$fixtures/stderr")"
}
expect_out() { # $1 = description, $2 = expected stdout, then the arguments
	local what="$1" want="$2"
	shift 2
	run "$@"
	if [ "$STATUS" -eq 0 ] && [ "$OUT" = "$want" ]; then
		ok "$what"
	else
		fail "$what" "exit $STATUS, stdout '$OUT', expected '$want'"
	fi
}
expect_status() { # $1 = description, $2 = expected exit status, then the arguments
	local what="$1" want="$2"
	shift 2
	run "$@"
	if [ "$STATUS" -eq "$want" ] && [ -z "$OUT" ]; then
		ok "$what"
	else
		fail "$what" "exit $STATUS (expected $want), stdout '$OUT'"
	fi
}

printf 'exclusion\n'
expect_out "with no crate, every entry is excluded (the Windows lists' form)" \
	'not (binary(alpha)) and not (binary(beta) and test(/^(one|two)$/)) and not (binary(gamma))' \
	"$fixtures/list.txt"
expect_out "with a crate, only that crate's entries are excluded" \
	'not (binary(alpha))' "$fixtures/list.txt" "$fixtures/a"
expect_out "a test() entry is parenthesised whole, so its 'and' stays inside the 'not'" \
	'not (binary(beta) and test(/^(one|two)$/)) and not (binary(gamma))' "$fixtures/list.txt" "$fixtures/b"
expect_out "a crate the list names nothing in gets all()" \
	'all()' "$fixtures/list.txt" "$fixtures/empty"
run "$fixtures/list.txt" "$fixtures/b"
if [[ $ERR == *"binary(gamma)   -- needs tool three; runs in: lane-y"* && $ERR == *"runs in: lane-y (a note)"* && $ERR != *alpha* ]]; then
	ok "each excluded entry is printed as NOT RUN with its prerequisite and lane, and only those"
else
	fail "each excluded entry is printed as NOT RUN with its prerequisite and lane, and only those" "$ERR"
fi

printf 'selection (--lane)\n'
expect_out "--lane selects the disjunction of that job's entries in the crate, note or not" \
	'(binary(beta) and test(/^(one|two)$/)) or (binary(gamma))' --lane lane-y "$fixtures/list.txt" "$fixtures/b"
expect_out "--lane leaves out the crate's entries for other jobs" \
	'(binary(alpha))' --lane lane-x "$fixtures/list.txt" "$fixtures/a"
expect_status "--lane refuses (exit 3) when the crate has no entry for the job" \
	3 --lane lane-y "$fixtures/list.txt" "$fixtures/a"
expect_status "--lane refuses a job id that is only a prefix of one in the list" \
	3 --lane lane "$fixtures/list.txt" "$fixtures/b"

printf 'usage errors\n'
expect_status "--lane without a crate tests dir is a usage error" 2 --lane lane-x "$fixtures/list.txt"
expect_status "a missing list is refused" 1 "$fixtures/no-such-list.txt"
expect_status "a missing crate tests dir is refused" 1 "$fixtures/list.txt" "$fixtures/no-such-dir"
expect_status "an entry with no leading binary() cannot be assigned to a crate" 1 "$fixtures/bad.txt" "$fixtures/a"

printf 'the real Linux non-gui list\n'
list="$REPO_ROOT/ci/test/non-gui-not-provided.linux.txt"
db="$REPO_ROOT/src/db-backend/tests"
bm="$REPO_ROOT/src/backend-manager/tests"
# Every binary() a crate's filter names must be one of that crate's test
# targets -- the property nextest enforces by refusing the filterset.
for crate in "$db" "$bm"; do
	run "$list" "$crate"
	stray=""
	while IFS= read -r target; do
		[ -f "$crate/$target.rs" ] || stray="$stray $target"
	done < <(grep -oE 'binary\([A-Za-z0-9_]+\)' <<<"$OUT" | sed 's/^binary(//; s/)$//' | sort -u)
	if [ "$STATUS" -eq 0 ] && [ "$OUT" != 'all()' ] && [ -z "$stray" ]; then
		ok "${crate#"$REPO_ROOT"/}: the exclusion names only that crate's test targets"
	else
		fail "${crate#"$REPO_ROOT"/}: the exclusion names only that crate's test targets" "exit $STATUS, strays:$stray"
	fi
done
# The selection has one disjunct per line naming the lane for a backend-manager
# target, counted here straight from the list's text.
for lane in rr-backend-tests mcr-dap-flow; do
	want=0
	while IFS= read -r line; do
		[[ $line =~ ^binary\(([A-Za-z0-9_]+)\) ]] || continue
		[ -f "$bm/${BASH_REMATCH[1]}.rs" ] || continue
		[[ $line =~ \|\ *$lane(\ |\(|$) ]] && want=$((want + 1))
	done <"$list"
	run --lane "$lane" "$list" "$bm"
	got="$(grep -o 'binary(' <<<"$OUT" | wc -l | tr -d ' ')"
	if [ "$STATUS" -eq 0 ] && [ "$want" -gt 0 ] && [ "$got" -eq "$want" ]; then
		ok "backend-manager: --lane $lane selects the $want entries the list names for it"
	else
		fail "backend-manager: --lane $lane selects the $want entries the list names for it" "exit $STATUS, $got selected: '$OUT'"
	fi
done

printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
[ "$failures" -eq 0 ]
