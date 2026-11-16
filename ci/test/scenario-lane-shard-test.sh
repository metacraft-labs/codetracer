#!/usr/bin/env bash
# ci/test/scenario-lane-shard-test.sh — a sharded scenario lane runs exactly
# the lane: for every lane and n in 2, 3, 4, 8 and 10, the shards of ci/test/scenario-lane-
# shard.py are non-empty and disjoint, and their union is the lane's
# `applicable:` list. A shard file keeps the lane's settings and renames it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shard="$root/ci/test/scenario-lane-shard.py"
failures=0
fail() { echo "  FAIL $*"; failures=$((failures + 1)); }
ok() { echo "  ok   $*"; }

for lane in "$root"/src/tests/scenarios/lanes/*.lane.yaml; do
	name="$(basename "$lane" .lane.yaml)"
	all="$(sed -n '/^applicable:/,/^[^ ]/{s/^ *- //p}' "$lane" | sort)"
	count="$(grep -c . <<<"$all" || true)"
	for n in 2 3 4 8 10; do
		[ "$count" -ge "$n" ] || continue
		union=""
		dup=0
		for i in $(seq 1 "$n"); do
			part="$(python3 "$shard" "$lane" "$i/$n" --list)"
			[ -n "$part" ] || fail "$name shard $i/$n is empty"
			if [ -n "$union" ] && [ -n "$(comm -12 <(sort <<<"$union") <(sort <<<"$part"))" ]; then
				dup=1
			fi
			union="$(printf '%s\n%s' "$union" "$part" | grep . | sort)"
		done
		[ "$dup" = 0 ] || fail "$name: the $n shards overlap"
		if [ "$union" = "$all" ]; then
			ok "$name: the $n shards cover its $count scenarios exactly"
		else
			fail "$name: the $n shards' union differs from the lane's list"
			diff <(echo "$all") <(echo "$union") | head -5 || true
		fi
	done
done

# A shard file: the lane's settings, a renamed lane, only its entries.
lane="$root/src/tests/scenarios/lanes/gpui.lane.yaml"
out="$(python3 "$shard" "$lane" 2/3)"
trap 'rm -f "$out"' EXIT
if grep -q '^name: gpui-shard-2-of-3$' "$out"; then
	ok "a shard file renames the lane"
else
	fail "the shard file does not rename the lane"
fi
for key in pack backend modes settle-timeout unsupported; do
	grep -q "^$key:" "$out" || fail "the shard file lost '$key:'"
done
if [ "$(sed -n '/^applicable:/,/^[^ ]/{s/^ *- //p}' "$out")" = "$(python3 "$shard" "$lane" 2/3 --list)" ]; then
	ok "a shard file holds exactly its shard's entries"
else
	fail "the shard file's entries differ from its --list"
fi

if [ "$failures" != 0 ]; then
	echo "scenario-lane-shard: $failures failure(s)"
	exit 1
fi
echo "scenario-lane-shard: all checks passed"
