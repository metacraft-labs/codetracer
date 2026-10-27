#!/usr/bin/env bash
#
# not-provided-filter.sh -- turn a lane's not-provided list into a nextest
# filter, and say what it leaves out (or, for the lane that runs those tests,
# what it selects).
#
# Usage:
#   ci/lib/not-provided-filter.sh <list> [<crate tests dir>]
#   ci/lib/not-provided-filter.sh --lane <job id> <list> <crate tests dir>
#
# <list> is a ci/test/*-not-provided.*.txt file: one
# `<nextest filterset> | <prerequisite the lane lacks> | <lane that runs it>`
# per line, `#` comments and blank lines ignored; the separators are the last
# two `|`s, since a regex may contain `|`. Each filterset is
# `binary(<target>)` or `binary(<target>) and test(/<regex>/)`, and <target>
# is an integration test of exactly one crate: src/db-backend/tests/<target>.rs
# or src/backend-manager/tests/<target>.rs (ci/test/lane-not-provided-test.sh
# checks the lists themselves).
#
# EXCLUSION (the lane that lacks the tools). Prints, on stdout, the conjunction
# `not (<filterset>) and not (<filterset>) ...` -- or `all()` when no entry
# applies -- and, on stderr, one NOT RUN line per entry naming what the test
# needs and where it runs. Each filterset is parenthesised because it may
# itself contain `and`.
#
# WHY THE CRATE ARGUMENT. One list names the tests of two crates, and each
# crate is a separate `cargo nextest run`. nextest REFUSES a filterset whose
# `binary(x)` matches no binary of the crate it runs in ("no binary names
# matched this", then "failed to parse filterset"; measured with
# cargo-nextest 0.9.114), so a list cannot be handed verbatim to both. Given
# <crate tests dir>, only the entries whose <target>.rs lives in that directory
# are emitted. Without it every entry is emitted, which is right only for a
# list that names a single crate's tests (the Windows lists, db-backend only).
#
# SELECTION (`--lane <job id>`: the lane that does run them). Prints the
# disjunction `(<filterset>) or (<filterset>) ...` of the entries in <crate
# tests dir> whose lane is <job id>, and lists each on stderr as RUN. The lane
# that runs a test reads the SAME line the lane that excludes it reads, so the
# two cannot drift apart: a test moved into, out of or between entries moves
# in both lanes at once. Exits 3, printing nothing on stdout, when no entry
# applies -- a lane asked to run a list's tests that finds none must not report
# green having run nothing.
set -euo pipefail

usage() {
	echo "usage: not-provided-filter.sh <list> [<crate tests dir>]" >&2
	echo "       not-provided-filter.sh --lane <job id> <list> <crate tests dir>" >&2
	exit 2
}

lane=""
if [ "${1:-}" = "--lane" ]; then
	[ "$#" -eq 4 ] || usage
	lane="$2"
	shift 2
fi
[ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage
list="$1"
crate_dir="${2:-}"
[ -f "$list" ] || {
	echo "not-provided-filter: no such list: $list" >&2
	exit 1
}
if [ -n "$crate_dir" ] && [ ! -d "$crate_dir" ]; then
	echo "not-provided-filter: no such crate tests directory: $crate_dir" >&2
	exit 1
fi
if [ -n "$lane" ] && [ -z "$crate_dir" ]; then
	usage
fi

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}

where="$list${crate_dir:+, tests in $crate_dir}"
if [ -n "$lane" ]; then
	echo "RUN in this lane ($lane, from $where): tests other lanes do not provide the tools for" >&2
else
	echo "NOT RUN in this lane ($where): tests whose tools it does not provide" >&2
fi
filter=""
while IFS= read -r line || [ -n "$line" ]; do
	line="$(trim "$line")"
	case "$line" in '' | \#*) continue ;; esac
	# The separators are the line's LAST two `|`s: a test() regex may itself
	# contain `|` (an alternation), a prerequisite or a lane never does.
	runs_in="$(trim "${line##*|}")"
	rest="${line%|*}"
	prereq="$(trim "${rest##*|}")"
	fset="$(trim "${rest%|*}")"
	if [ -n "$crate_dir" ]; then
		# The target is the leading `binary(<target>)` of every accepted form.
		if [[ ! $fset =~ ^binary\(([A-Za-z0-9_]+)\) ]]; then
			echo "not-provided-filter: $list: '$fset' does not start with binary(<test target>); cannot tell which crate it belongs to" >&2
			exit 1
		fi
		[ -f "$crate_dir/${BASH_REMATCH[1]}.rs" ] || continue
	fi
	if [ -n "$lane" ]; then
		# The lane field is a job id, optionally followed by a note.
		[ "${runs_in%%[ (]*}" = "$lane" ] || continue
		filter="${filter:+$filter or }($fset)"
		echo "  $fset   -- needs $prereq" >&2
	else
		filter="${filter:+$filter and }not ($fset)"
		echo "  $fset   -- needs $prereq; runs in: $runs_in" >&2
	fi
done <"$list"
if [ -n "$lane" ] && [ -z "$filter" ]; then
	echo "not-provided-filter: $list names no test in $crate_dir for lane '$lane'; refusing to select nothing" >&2
	exit 3
fi
[ -n "$lane" ] || [ -n "$filter" ] || echo "  (none)" >&2
echo "${filter:-all()}"
