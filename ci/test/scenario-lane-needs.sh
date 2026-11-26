#!/usr/bin/env bash
# ci/test/scenario-lane-needs.sh <lane> <i/n> — what one shard of a scenario lane
# records with, beyond what every shard gets, so a leg of the scenario-lanes job
# (.github/workflows/scenario-lanes.yml) builds only that. Prints, one per line,
# for $GITHUB_OUTPUT:
#
#   hcr=true|false     a scenario of the shard runs the `hcr-flame` stage (the
#                      flame demo, its patchable Godot and the coordinator,
#                      ci/test/scenario-lane-provision.sh hcr)
#   recorders=a,b,...  the blockchain recorders its scenarios record with
#                      (solana, polkavm, evm), for
#                      ci/test/scenario-lane-provision.sh recorders
#
# A scenario says what it records in its `record-program` stage's `with:`:
# `lang: solana`, `lang: polkavm`, or a Solidity source (`program: <...>.sol`).
# ci/test/scenario-lane-needs-test.sh fails unless every scenario that needs a
# piece is on a shard this script flags for it, in every split the workflow uses.
# Run from anywhere; needs python3 (codetracer's dev shell has it).
set -euo pipefail
cd "$(dirname "$0")/../.."
lane="${1:?usage: scenario-lane-needs.sh <lane> <i/n>}"
shard="${2:?usage: scenario-lane-needs.sh <lane> <i/n>}"
lanes=src/tests/scenarios/lanes
slice="$(python3 ci/test/scenario-lane-shard.py "${lanes}/${lane}.lane.yaml" "${shard}" --list)"
[ -n "${slice}" ] || {
	echo "scenario-lane-needs: shard ${shard} of the ${lane} lane is empty" >&2
	exit 1
}

# The pattern a scenario file matches when it needs each piece.
declare -A pattern=(
	[hcr]='^[[:space:]]*-[[:space:]]*use:[[:space:]]*hcr-flame[[:space:]]*$'
	[solana]='lang:[[:space:]]*solana([[:space:]]|,|\}|$)'
	[polkavm]='lang:[[:space:]]*polkavm([[:space:]]|,|\}|$)'
	[evm]='program:[[:space:]]*[^,}]*\.sol([[:space:]]|,|\}|$)'
)
declare -A needed=([hcr]=false [solana]=false [polkavm]=false [evm]=false)
while read -r entry; do
	[ -n "${entry}" ] || continue
	for piece in "${!pattern[@]}"; do
		if grep -Eq "${pattern[$piece]}" "${lanes}/${entry}"; then needed[$piece]=true; fi
	done
done <<<"${slice}"

echo "hcr=${needed[hcr]}"
recorders=""
for r in solana polkavm evm; do
	[ "${needed[$r]}" = true ] && recorders="${recorders:+${recorders},}${r}"
done
echo "recorders=${recorders}"
