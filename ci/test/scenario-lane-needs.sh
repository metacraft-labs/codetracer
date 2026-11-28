#!/usr/bin/env bash
# ci/test/scenario-lane-needs.sh <lane> <i/n> — what one shard of a scenario lane
# records with, beyond what every shard gets, so a leg of the scenario-lanes job
# (.github/workflows/scenario-lanes.yml) builds only that. Prints, one per line,
# for $GITHUB_OUTPUT:
#
#   hcr=true|false     a scenario of the shard runs the `hcr-flame` stage (the
#                      flame demo, its patchable Godot and the coordinator,
#                      ci/test/scenario-lane-provision.sh hcr)
#   instrument=true|false  a scenario materializes the cross-process recording,
#                      which needs ct-instrument (ci/test/scenario-lane-provision.sh
#                      instrument)
#   ruby=true|false    a scenario records a Ruby program (... ruby): by its
#                      `record-program` stage, or through a Ruby launch
#                      configuration it picks from the menu
#   recorders=a,b,...  the blockchain recorders its scenarios record with
#                      (solana, polkavm, evm, cairo, leo, miden, cardano, flow,
#                      move, fuel, ton), for ci/test/scenario-lane-provision.sh
#                      recorders
#
# A scenario says what it records in its `record-program` stage's `with:`: a
# language (`lang: solana`), or its program's source file or directory; a
# scenario that records through the UI by its launch configuration's label.
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

# The pattern a scenario file matches when it needs each piece. A recorder's
# scenarios name it by their program: a language (`lang: solana`), a source
# file's extension, or a program under the recorder's own checkout.
declare -A pattern=(
	[hcr]='^[[:space:]]*-[[:space:]]*use:[[:space:]]*hcr-flame[[:space:]]*$'
	[instrument]='name:[[:space:]]*cross-process-three-trace'
	[ruby]='program:[[:space:]]*[^,}]*\.rb([[:space:]]|,|\}|$)|menu-item\[label="Ruby:'
	[solana]='lang:[[:space:]]*solana([[:space:]]|,|\}|$)'
	[polkavm]='lang:[[:space:]]*polkavm([[:space:]]|,|\}|$)'
	[evm]='program:[[:space:]]*[^,}]*\.sol([[:space:]]|,|\}|$)'
	[cairo]='program:[[:space:]]*[^,}]*\.cairo([[:space:]]|,|\}|$)'
	[leo]='program:[[:space:]]*[^,}]*\.leo([[:space:]]|,|\}|$)'
	[miden]='program:[[:space:]]*[^,}]*\.masm([[:space:]]|,|\}|$)'
	[cardano]='program:[[:space:]]*[^,}]*\.ak([[:space:]]|,|\}|$)'
	[flow]='program:[[:space:]]*[^,}]*\.cdc([[:space:]]|,|\}|$)'
	[move]='program:[[:space:]]*[^,}]*\.move([[:space:]]|,|\}|$)'
	[fuel]='program:[[:space:]]*sway_[^,}]*([[:space:]]|,|\}|$)|lang:[[:space:]]*sway([[:space:]]|,|\}|$)'
	[ton]='program:[[:space:]]*[^,}]*\.tolk([[:space:]]|,|\}|$)'
)
# The blockchain recorders, in the order they are built.
recorder_names=(solana polkavm evm cairo leo miden cardano flow move fuel ton)
declare -A needed=()
for piece in "${!pattern[@]}"; do needed[$piece]=false; done
while read -r entry; do
	[ -n "${entry}" ] || continue
	for piece in "${!pattern[@]}"; do
		if grep -Eq "${pattern[$piece]}" "${lanes}/${entry}"; then needed[$piece]=true; fi
	done
done <<<"${slice}"

echo "hcr=${needed[hcr]}"
echo "instrument=${needed[instrument]}"
echo "ruby=${needed[ruby]}"
recorders=""
for r in "${recorder_names[@]}"; do
	[ "${needed[$r]}" = true ] && recorders="${recorders:+${recorders},}${r}"
done
echo "recorders=${recorders}"
