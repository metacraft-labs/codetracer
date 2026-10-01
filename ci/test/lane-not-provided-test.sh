#!/usr/bin/env bash
#
# lane-not-provided-test.sh -- contract suite for the lists of tests a lane
# declares it does not provide the tools for (ci/test/*-not-provided.*.txt).
#
# A lane that runs with CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false excludes
# those tests by name. An entry that names a test binary that no longer exists
# excludes nothing and says nothing, and one that is misspelled leaves the real
# test in the lane, where it fails for a missing tool the lane was never meant
# to have. So every entry must be well formed and name a binary that exists.
#
# Every entry must also name the lane that DOES run the test, as the id of a
# job in .github/workflows/ (optionally followed by a parenthesised note), and
# no entry may say `NO LANE`. Excluding a test from one lane is only honest
# when another lane runs it; a test that no lane runs has stopped being a test.
# Pure bash; no cargo, no nix.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/src/db-backend/tests"
WORKFLOWS_DIR="${CT_LANE_WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"

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
}

shopt -s nullglob

# Job ids: the two-space-indented keys under a workflow's `jobs:` map.
declare -A JOBS=()
for wf in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
	in_jobs=0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		jobs:*) in_jobs=1 ;;
		[!\ \#]*) in_jobs=0 ;;
		'  '[A-Za-z0-9_-]*:*)
			if [ "$in_jobs" -eq 1 ]; then
				case "$line" in
				'   '*) ;;
				*)
					id="${line#  }"
					JOBS["${id%%:*}"]=1
					;;
				esac
			fi
			;;
		esac
	done <"$wf"
done
if [ "${#JOBS[@]}" -eq 0 ]; then
	printf 'FAIL: no job ids found under %s; the lane check would accept nothing\n' "$WORKFLOWS_DIR"
	exit 1
fi

if [ -n "${CT_LANE_NOT_PROVIDED_LISTS:-}" ]; then
	read -r -a lists <<<"$CT_LANE_NOT_PROVIDED_LISTS"
else
	lists=("$REPO_ROOT"/ci/test/*-not-provided.*.txt)
fi
if [ "${#lists[@]}" -eq 0 ]; then
	printf 'FAIL: no ci/test/*-not-provided.*.txt list found; this suite would check nothing\n'
	exit 1
fi

for list in "${lists[@]}"; do
	printf '%s\n' "${list#"$REPO_ROOT"/}"
	entries=0
	while IFS= read -r line; do
		case "$line" in '' | \#*) continue ;; esac
		entries=$((entries + 1))
		IFS='|' read -r fset prereq lane <<<"$line"
		fset="$(echo "$fset" | xargs)"
		prereq="$(echo "$prereq" | xargs)"
		lane="$(echo "$lane" | xargs)"
		if [ -z "$prereq" ] || [ -z "$lane" ]; then
			fail "$fset: names both the missing prerequisite and the lane that runs it"
			continue
		fi
		lane_job="${lane%%[ (]*}"
		case "$lane" in
		[Nn][Oo]\ [Ll][Aa][Nn][Ee]*)
			fail "$fset: no lane runs it (NO LANE); provision its prerequisite in a lane, then name that lane"
			;;
		*)
			if [ -n "${JOBS[$lane_job]:-}" ]; then
				ok "$fset runs in $lane_job"
			else
				fail "$fset: lane '$lane_job' is not a job id in .github/workflows/"
			fi
			;;
		esac
		if [[ $fset =~ ^binary\(([A-Za-z0-9_]+)\)$ ]]; then
			binary="${BASH_REMATCH[1]}"
			if [ -f "$TESTS_DIR/$binary.rs" ]; then
				ok "$binary exists"
			else
				fail "$fset: src/db-backend/tests/$binary.rs does not exist"
			fi
		else
			fail "$fset: expected binary(<test target>)"
		fi
	done <"$list"
	if [ "$entries" -eq 0 ]; then
		fail "${list#"$REPO_ROOT"/} has no entries"
	fi
done

# The checks above must be able to fail. Run this suite against fixture lists
# that each break one rule and require that every one of them is refused, so a
# check that silently stopped matching cannot keep reporting green.
if [ -z "${CT_LANE_NOT_PROVIDED_LISTS:-}" ]; then
	printf 'negative controls\n'
	fixtures="$(mktemp -d)"
	trap 'rm -rf "$fixtures"' EXIT
	any_binary="$(cd "$TESTS_DIR" && for f in *.rs; do
		printf '%s\n' "${f%.rs}"
		break
	done)"
	any_job="$(printf '%s\n' "${!JOBS[@]}" | sort | head -n 1)"
	printf 'binary(%s) | some tool | NO LANE\n' "$any_binary" >"$fixtures/no-lane.txt"
	printf 'binary(%s) | some tool | no-such-job-anywhere\n' "$any_binary" >"$fixtures/unknown-job.txt"
	printf 'binary(no_such_test_binary) | some tool | %s\n' "$any_job" >"$fixtures/unknown-binary.txt"
	printf 'binary(%s) | | %s\n' "$any_binary" "$any_job" >"$fixtures/no-prereq.txt"
	printf 'binary(%s) | some tool | %s (a note)\n' "$any_binary" "$any_job" >"$fixtures/valid.txt"
	for bad in no-lane unknown-job unknown-binary no-prereq; do
		if CT_LANE_NOT_PROVIDED_LISTS="$fixtures/$bad.txt" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
			fail "a list with a $bad entry is refused"
		else
			ok "a list with a $bad entry is refused"
		fi
	done
	if CT_LANE_NOT_PROVIDED_LISTS="$fixtures/valid.txt" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
		ok "a well-formed entry naming a real job with a note is accepted"
	else
		fail "a well-formed entry naming a real job with a note is accepted"
	fi
fi

printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
[ "$failures" -eq 0 ]
