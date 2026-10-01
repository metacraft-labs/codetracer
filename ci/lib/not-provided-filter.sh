#!/usr/bin/env bash
#
# not-provided-filter.sh -- turn a lane's not-provided list into a nextest
# filter, and say what it leaves out.
#
# Usage: ci/lib/not-provided-filter.sh <list>
#
# <list> is a ci/test/*-not-provided.*.txt file: one
# `<nextest filterset> | <prerequisite the lane lacks> | <lane that runs it>`
# per line, `#` comments and blank lines ignored. Prints, on stdout, the
# conjunction `not <filterset> and not <filterset> ...` (or `all()` for a list
# with no entries), and on stderr one NOT RUN line per entry naming what the
# test needs and where it runs. ci/test/lane-not-provided-test.sh checks the
# lists themselves.
set -euo pipefail

list="${1:?usage: not-provided-filter.sh <list>}"
[ -f "$list" ] || {
	echo "not-provided-filter: no such list: $list" >&2
	exit 1
}

echo "NOT RUN in this lane ($list): tests whose tools it does not provide" >&2
trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}
filter=""
while IFS= read -r line || [ -n "$line" ]; do
	line="$(trim "$line")"
	case "$line" in '' | \#*) continue ;; esac
	IFS='|' read -r fset prereq lane <<<"$line"
	fset="$(trim "$fset")"
	filter="${filter:+$filter and }not $fset"
	echo "  $fset   -- needs $(trim "$prereq"); runs in: $(trim "$lane")" >&2
done <"$list"
echo "${filter:-all()}"
