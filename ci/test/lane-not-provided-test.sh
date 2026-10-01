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
# Pure bash; no cargo, no nix.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTS_DIR="$REPO_ROOT/src/db-backend/tests"

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
lists=("$REPO_ROOT"/ci/test/*-not-provided.*.txt)
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

printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
[ "$failures" -eq 0 ]
