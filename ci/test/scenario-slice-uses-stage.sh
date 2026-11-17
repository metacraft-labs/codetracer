#!/usr/bin/env bash
# ci/test/scenario-slice-uses-stage.sh <lane> <i/n> <stage> — does shard i/n
# of a scenario lane run a scenario that uses <stage>? Prints `needed=true` or
# `needed=false`, for a workflow step's $GITHUB_OUTPUT.
#
# A sharded job provisions what only some scenarios need (the visual replay
# player for `visual-recording`) on the shard whose slice holds them, decided
# here from the slice itself, so a rebalance of the shards moves the
# provisioning with the scenario. ci/test/scenario-slice-uses-stage-test.sh
# holds it to that.
set -euo pipefail
cd "$(dirname "$0")/../.."
lane="${1:?usage: scenario-slice-uses-stage.sh <lane> <i/n> <stage>}"
shard="${2:?usage: scenario-slice-uses-stage.sh <lane> <i/n> <stage>}"
stage="${3:?usage: scenario-slice-uses-stage.sh <lane> <i/n> <stage>}"
lanes=src/tests/scenarios/lanes
needed=false
while read -r entry; do
	[ -n "${entry}" ] || continue
	if grep -Eq "^[[:space:]]*-[[:space:]]*use:[[:space:]]*${stage}[[:space:]]*\$" "${lanes}/${entry}"; then
		needed=true
	fi
done < <(python3 ci/test/scenario-lane-shard.py "${lanes}/${lane}.lane.yaml" "${shard}" --list)
echo "needed=${needed}"
