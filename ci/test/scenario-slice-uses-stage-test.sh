#!/usr/bin/env bash
# ci/test/scenario-slice-uses-stage-test.sh — a scenario that needs the visual
# replay player always lands on a shard that builds it.
#
# tui-tests.yml builds ct_gfx_player only on the shard whose terminal-lane
# slice uses the `visual-recording` stage, decided at run time by
# ci/test/scenario-slice-uses-stage.sh. This holds, for every shard count the
# lane might be split into, that each scenario using the stage sits in a shard
# the helper flags, that the helper flags no shard without one, and that the
# workflow gates the build on the helper's answer for its own shard.
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

lanes=src/tests/scenarios/lanes
lane=terminal
stage=visual-recording
users="$(sed -n '/^applicable:/,/^[^ ]/{s/^ *- //p}' "${lanes}/${lane}.lane.yaml" |
	while read -r e; do
		if grep -Eq "^[[:space:]]*-[[:space:]]*use:[[:space:]]*${stage}[[:space:]]*\$" "${lanes}/${e}"; then echo "${e}"; fi
	done | sort)"
[ -n "${users}" ] || fail "no ${lane} scenario uses ${stage}: the check would prove nothing"

for n in 2 4 8 10 20; do
	covered=""
	for i in $(seq 1 "${n}"); do
		part="$(python3 ci/test/scenario-lane-shard.py "${lanes}/${lane}.lane.yaml" "${i}/${n}" --list | sort)"
		want=false
		if [ -n "$(comm -12 <(echo "${part}") <(echo "${users}"))" ]; then want=true; fi
		got="$(bash ci/test/scenario-slice-uses-stage.sh "${lane}" "${i}/${n}" "${stage}")"
		[ "${got}" = "needed=${want}" ] || fail "${lane} ${i}/${n}: the helper says '${got}', the slice says needed=${want}"
		if [ "${want}" = true ]; then
			covered="$(printf '%s\n%s' "${covered}" "$(comm -12 <(echo "${part}") <(echo "${users}"))")"
		fi
	done
	if [ "$(echo "${covered}" | sed '/^$/d' | sort)" = "${users}" ]; then
		ok "${lane} in ${n} shards: every ${stage} scenario is on a shard that builds the player"
	else
		fail "${lane} in ${n} shards: a ${stage} scenario is on no flagged shard"
	fi
done

wf=.github/workflows/tui-tests.yml
count="$(sed -n 's/^ *shard: \[\(.*\)\]$/\1/p' "${wf}" | tr ',' '\n' | grep -c .)"
if grep -qF "scenario-slice-uses-stage.sh ${lane} \"\${{ matrix.shard }}/${count}\" ${stage}" "${wf}"; then
	ok "${wf} asks the helper for its own shard of ${count}"
else
	fail "${wf} does not ask scenario-slice-uses-stage.sh for its shard (${lane}, \${{ matrix.shard }}/${count}, ${stage})"
fi
if grep -qF "steps.player.outputs.needed == 'true'" "${wf}"; then
	ok "${wf} builds the player only where the helper says it is needed"
else
	fail "${wf} does not gate the player's build on steps.player.outputs.needed"
fi

if grep -qF "nix develop .#devShells.x86_64-linux.default --command bash ci/test/scenario-slice-uses-stage.sh" "${wf}"; then
	ok "${wf} runs the helper in the dev shell, which has its python3"
else
	fail "${wf} runs the helper on the runner's bare PATH, which may have no python3"
fi

# Without python3 the helper must FAIL, not answer needed=false: from a process
# substitution the missing interpreter used to read as an empty slice, and TUI
# shard 6 of run 44269676398 skipped the player its scenario needed.
nopy="$(mktemp -d)"
for tool in bash dirname grep sed cat; do
	ln -s "$(command -v "${tool}")" "${nopy}/${tool}"
done
if PATH="${nopy}" bash ci/test/scenario-slice-uses-stage.sh "${lane}" "6/8" "${stage}" >/dev/null 2>&1; then
	fail "with no python3 on PATH the helper still exits 0"
else
	ok "with no python3 on PATH the helper fails instead of answering needed=false"
fi
rm -rf "${nopy}"

if [ "${failures}" -gt 0 ]; then
	echo "scenario-slice-uses-stage: ${failures} failure(s)"
	exit 1
fi
echo "scenario-slice-uses-stage: ok"
