#!/usr/bin/env bash
# ci/test/scenario-lane-shard-test.sh — a sharded scenario lane runs exactly
# the lane: for every lane and n in 2, 3, 4, 8 and 10, the shards of ci/test/scenario-lane-
# shard.py are non-empty and disjoint, and their union is the lane's
# `applicable:` list: no scenario is in no shard, and none in two. A lane split
# by measured time (`<name>.timings.tsv`) has shards within 25% of the mean
# time, and its timings name only the lane's entries. A shard file keeps the
# lane's settings and renames it.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
shard="$root/ci/test/scenario-lane-shard.py"
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

for lane in "$root"/src/tests/scenarios/lanes/*.lane.yaml; do
	name="$(basename "$lane" .lane.yaml)"
	timed=0
	[ -f "${lane%.lane.yaml}.timings.tsv" ] && timed=1
	all="$(sed -n '/^applicable:/,/^[^ ]/{s/^ *- //p}' "$lane" | sort)"
	count="$(grep -c . <<<"$all" || true)"
	for n in 2 3 4 8 10 20; do
		[ "$count" -ge "$n" ] || continue
		union=""
		dup=0
		first=0
		heavier=1
		for i in $(seq 1 "$n"); do
			part="$(python3 "$shard" "$lane" "$i/$n" --list)"
			[ -n "$part" ] || fail "$name shard $i/$n is empty"
			size="$(grep -c . <<<"$part" || true)"
			# Shard 1 also carries the whole-lane checks and the captures,
			# so its slice must be no larger than any other shard's.
			# (A lane split by time runs in jobs of its own: no shard is lighter.)
			if [ "$timed" = 1 ]; then :; elif [ "$i" = 1 ]; then first="$size"; elif [ "$size" -lt "$first" ]; then heavier=0; fi
			if [ -n "$union" ] && [ -n "$(comm -12 <(sort <<<"$union") <(sort <<<"$part"))" ]; then
				dup=1
			fi
			union="$(printf '%s\n%s' "$union" "$part" | grep . | sort)"
		done
		[ "$dup" = 0 ] || fail "$name: the $n shards overlap"
		[ "$heavier" = 1 ] || fail "$name: shard 1/$n ($first) is larger than another shard"
		if [ "$timed" = 1 ]; then
			if python3 "$shard" "$lane" "1/$n" --weights | awk '{ t += $1; if ($1 > m) m = $1 } END { exit !(m <= 1.25 * t / NR) }'; then
				ok "$name: its $n shards are balanced by time (each within 25% of the mean)"
			else
				fail "$name: a shard of $n is more than 25% over the mean time" "$(python3 "$shard" "$lane" "1/$n" --weights | tr '\n' ' ')"
			fi
		fi
		if [ "$union" = "$all" ]; then
			ok "$name: the $n shards cover its $count scenarios exactly"
		else
			fail "$name: the $n shards' union differs from the lane's list"
			diff <(echo "$all") <(echo "$union") | head -5 || true
		fi
	done
done

# The legs scenario-lanes runs (its matrix in .github/workflows/scenario-lanes.yml:
# `leg: <run>-<i>-of-<n>, lane: <lane>, shard: <i>/<n>`, a run being one lane
# run, as the desktop lane's with each editor): every scenario of the lane is in
# exactly one leg of each run. A leg with no shard runs the whole lane.
legs="$(sed -n 's/.*{leg: \([a-z-]*\)-[0-9]*-of-[0-9]*, lane: \([a-z-]*\), shard: \([0-9]*\/[0-9]*\|""\).*/\1 \2 \3/p' \
	"$root/.github/workflows/scenario-lanes.yml" | sed 's| ""$| 1/1|')"
[ -n "$legs" ] || fail "scenario-lanes.yml has no scenario lane leg"
while read -r run lane_name n; do
	lane="$root/src/tests/scenarios/lanes/$lane_name.lane.yaml"
	[ -f "$lane" ] || { fail "scenario-lanes.yml: leg $run runs no lane ($lane_name)"; continue; }
	all="$(sed -n '/^applicable:/,/^[^ ]/{s/^ *- //p}' "$lane" | sort)"
	got=""
	for i in $(seq 1 "$n"); do
		grep -qx "$run $lane_name $i/$n" <<<"$legs" || fail "scenario-lanes.yml: the $run run has no leg $i/$n"
		got="$(printf '%s\n%s' "$got" "$(python3 "$shard" "$lane" "$i/$n" --list)" | grep . | sort)"
	done
	if [ "$got" = "$all" ]; then
		ok "scenario-lanes' $run legs ($n) run each scenario of the $lane_name lane once"
	else
		fail "scenario-lanes' $run legs leave out or repeat a scenario of the $lane_name lane" \
			"$(diff <(echo "$all") <(echo "$got") | head -5)"
	fi
done < <(awk '{split($3, a, "/"); print $1, $2, a[2]}' <<<"$legs" | sort -u)

# A timings line that names no entry of the lane is refused, by name.
tmpl="$(mktemp -d)"
cp "$root/src/tests/scenarios/lanes/electron.lane.yaml" "$tmpl/probe.lane.yaml"
printf '../no-such/scenario.yaml\t30\n' >"$tmpl/probe.timings.tsv"
if msg="$(python3 "$shard" "$tmpl/probe.lane.yaml" 1/2 --list 2>&1)"; then
	fail "a timings line naming no lane entry was accepted"
elif grep -q "no-such/scenario.yaml' is no entry" <<<"$msg"; then
	ok "a timings line naming no lane entry is refused"
else
	fail "a stale timings line was refused for another reason" "$msg"
fi
rm -rf "$tmpl"

# A shard file: the lane's settings, a renamed lane, only its entries.
lane="$root/src/tests/scenarios/lanes/gpui.lane.yaml"
out="$(python3 "$shard" "$lane" 2/3)"
trap 'rm -f "$out"' EXIT
if grep -q '^name: gpui-shard-2-of-3$' "$out"; then
	ok "a shard file renames the lane"
else
	fail "the shard file does not rename the lane"
fi
for key in pack backend modes settle-timeout stage-timeout unsupported; do
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
