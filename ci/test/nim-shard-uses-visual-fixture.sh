#!/usr/bin/env bash
# ci/test/nim-shard-uses-visual-fixture.sh <i/n> <lane>... — does shard i/n of
# any of these Nim lanes run a suite that opens the visual recording? Prints
# `needed=true` or `needed=false`, for a workflow step's $GITHUB_OUTPUT.
#
# The Visual Replay suites (every suite importing `fixtures/visual_fixture`,
# PLAT-59's) need the visual replay player, ct_gfx_player. tui-tests.yml built
# it only for the shard whose SCENARIO slice uses `visual-recording`
# (ci/test/scenario-slice-uses-stage.sh), and only after the Nim lanes, so
# test_plat59_visual_replay.nim (shard 8/8) and
# test_plat59_visual_replay_pty.nim (shard 2/8) skipped every case in CI: "OK
# (1 tests, 1 SKIPPED)", "MISSING-PREREQ SKIP: the visual replay player
# (ct_gfx_player) is not installed" (agents run 45471393785). The shard is
# decided from its own file list (run-nim-test-lane.sh --list-shard), so a
# rebalance moves the player with the suites.
# ci/test/nim-shard-uses-visual-fixture-test.sh holds it to that.
set -euo pipefail
cd "$(dirname "$0")/../.."
shard="${1:?usage: nim-shard-uses-visual-fixture.sh <i/n> <lane>...}"
shift
[ "$#" -gt 0 ] || {
	echo "usage: nim-shard-uses-visual-fixture.sh <i/n> <lane>..." >&2
	exit 2
}
needed=false
for lane in "$@"; do
	# Into a variable first, so a failure to list the shard fails this script
	# rather than reading as an empty slice and `needed=false`.
	files="$(NIM_TEST_LANE_SHARD="${shard}" bash ci/lib/run-nim-test-lane.sh "${lane}" --list-shard)"
	while read -r f; do
		[ -n "${f}" ] || continue
		if grep -Eq '^[[:space:]]*import[[:space:]].*visual_fixture' "${f}"; then
			needed=true
		fi
	done <<<"${files}"
done
echo "needed=${needed}"
