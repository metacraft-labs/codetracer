#!/usr/bin/env bash
# ci/test/nim-test-lane-shard-test.sh — a sharded Nim test lane runs exactly
# the lane's files: the n shards of `NIM_TEST_LANE_SHARD=i/n` cover every file
# once, none twice, none dropped.
#
# CI runs the terminal lanes (`tui`, `tui-real-terminal`) in shards, one per
# matrix job of tui-tests.yml, because one job cannot compile their ~225 files
# within its timeout (run 43859070538 was cancelled inside Tier 1). A shard
# function that dropped a file would turn its suite silently off; one that ran
# a file twice would hide nothing but waste a runner. Both are checked against
# the lane's own list (ci/lib/test-lane-files.sh), for every n CI might use.
#
# Negative control: leaving one shard out must be detected as missing files.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2

runner=ci/lib/run-nim-test-lane.sh
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved from the repository root
source ci/lib/test-lane-files.sh

union_of() { # $1 lane, $2 n, $3 shard to leave out (0: none)
	local i
	for i in $(seq 1 "$2"); do
		[ "${i}" = "$3" ] && continue
		NIM_TEST_LANE_SHARD="${i}/$2" bash "${runner}" "$1" --list-shard || return 1
	done
}

echo "== the shards of a Nim test lane cover it exactly"
for lane in tui tui-real-terminal; do
	want="$(test_lane_files "${lane}" | grep . | sort)"
	count="$(grep -c . <<<"${want}")"
	if [ "${count}" -eq 0 ]; then
		fail "${lane}: the lane lists no files, so this check would prove nothing"
		continue
	fi
	for n in 2 4 8; do
		got="$(union_of "${lane}" "${n}" 0 | sort)"
		dups="$(uniq -d <<<"${got}")"
		if [ "${got}" != "$(sort -u <<<"${got}")" ] || [ -n "${dups}" ]; then
			fail "${lane} n=${n}: a file runs in more than one shard: ${dups}"
		elif [ "${got}" != "${want}" ]; then
			fail "${lane} n=${n}: the shards' union differs from the lane:"
			diff <(echo "${want}") <(echo "${got}") | sed 's/^/         /'
		else
			echo "  ok   ${lane} n=${n}: ${count} file(s), each in exactly one shard"
		fi
	done
	got="$(union_of "${lane}" 8 3 | sort)"
	if [ "${got}" = "${want}" ]; then
		fail "${lane}: with shard 3/8 left out the union still equals the lane (the check cannot fail)"
	else
		echo "  ok   ${lane}: with shard 3/8 left out, $(comm -23 <(echo "${want}") <(echo "${got}") | grep -c .) file(s) are missing"
	fi
done

if NIM_TEST_LANE_SHARD=9/8 bash "${runner}" tui --list-shard >/dev/null 2>&1; then
	fail "an out-of-range shard (9/8) was accepted"
else
	echo "  ok   an out-of-range shard (9/8) is refused"
fi

if [ "${failures}" -gt 0 ]; then
	echo "nim-test-lane-shard: ${failures} failure(s)"
	exit 1
fi
echo "nim-test-lane-shard: ok"
