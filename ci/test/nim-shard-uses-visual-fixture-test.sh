#!/usr/bin/env bash
# ci/test/nim-shard-uses-visual-fixture-test.sh — a Nim suite that opens the
# visual recording always runs on a TUI shard that has the visual replay player
# by then.
#
# tui-tests.yml provisions ct_gfx_player on the shard whose scenario slice uses
# `visual-recording` OR whose Nim slice (the `tui` and `tui-real-terminal`
# lanes) holds a suite importing `fixtures/visual_fixture`, decided by
# ci/test/nim-shard-uses-visual-fixture.sh, and it must do so BEFORE those
# lanes run. Before this, the player came after them and only for scenarios,
# and both PLAT-59 terminal suites skipped every case in CI (agents run
# 45471393785, shards 2/8 and 8/8).
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

wf=.github/workflows/tui-tests.yml
lanes=(tui tui-real-terminal)
imports_fixture() { grep -Eq '^[[:space:]]*import[[:space:]].*visual_fixture' "$1"; }

users="$(for lane in "${lanes[@]}"; do
	bash ci/lib/run-nim-test-lane.sh "${lane}" --list-shard
done | while read -r f; do
	if [ -n "${f}" ] && imports_fixture "${f}"; then echo "${f}"; fi
done | sort)"
[ -n "${users}" ] || fail "no ${lanes[*]} suite imports visual_fixture: the check would prove nothing"

for n in 2 4 8 10; do
	covered=""
	for i in $(seq 1 "${n}"); do
		part="$(for lane in "${lanes[@]}"; do
			NIM_TEST_LANE_SHARD="${i}/${n}" bash ci/lib/run-nim-test-lane.sh "${lane}" --list-shard
		done | sort)"
		mine="$(comm -12 <(echo "${part}") <(echo "${users}") | sed '/^$/d')"
		want=false
		if [ -n "${mine}" ]; then want=true; fi
		got="$(bash ci/test/nim-shard-uses-visual-fixture.sh "${i}/${n}" "${lanes[@]}")"
		[ "${got}" = "needed=${want}" ] || fail "${i}/${n}: the helper says '${got}', the slice says needed=${want}"
		if [ -n "${mine}" ]; then covered="$(printf '%s\n%s' "${covered}" "${mine}")"; fi
	done
	if [ "$(echo "${covered}" | sed '/^$/d' | sort)" = "${users}" ]; then
		ok "${n} shards: every visual-fixture suite is on a shard that gets the player"
	else
		fail "${n} shards: a visual-fixture suite is on no flagged shard"
	fi
done

count="$(sed -n 's/^ *shard: \[\(.*\)\]$/\1/p' "${wf}" | tr ',' '\n' | grep -c .)"
if grep -qF "nix develop .#devShells.x86_64-linux.default --command bash ci/test/nim-shard-uses-visual-fixture.sh \"\${{ matrix.shard }}/${count}\" ${lanes[*]}" "${wf}"; then
	ok "${wf} asks the helper for its own shard of ${count}, in the dev shell"
else
	fail "${wf} does not ask nim-shard-uses-visual-fixture.sh for its shard (\${{ matrix.shard }}/${count}, ${lanes[*]})"
fi

# The player is decided and built before the Nim lanes that need it.
line_of() { grep -n -F -- "$1" "${wf}" | head -1 | cut -d: -f1; }
decide="$(line_of 'id: player')"
build="$(line_of '- name: Build the visual replay player')"
tier1="$(line_of '- name: TUI Tier 1')"
tier2="$(line_of '- name: TUI Tier 2')"
if [ -n "${decide}" ] && [ -n "${build}" ] && [ -n "${tier1}" ] && [ -n "${tier2}" ] &&
	[ "${decide}" -lt "${tier1}" ] && [ "${build}" -lt "${tier1}" ] && [ "${build}" -lt "${tier2}" ]; then
	ok "${wf} decides on and builds the player before TUI Tier 1 and Tier 2"
else
	fail "${wf}: the player (decided at line ${decide:-?}, built at ${build:-?}) does not come before Tier 1 (${tier1:-?}) and Tier 2 (${tier2:-?})"
fi

# A lane that cannot be listed fails the helper; it does not read as needed=false.
if bash ci/test/nim-shard-uses-visual-fixture.sh 1/8 no-such-lane >/dev/null 2>&1; then
	fail "the helper answered for a lane it could not list"
else
	ok "the helper fails when a lane cannot be listed"
fi

if [ "${failures}" -gt 0 ]; then
	echo "nim-shard-uses-visual-fixture-test: ${failures} failure(s)"
	exit 1
fi
echo "nim-shard-uses-visual-fixture-test: OK"
