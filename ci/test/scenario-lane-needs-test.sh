#!/usr/bin/env bash
# ci/test/scenario-lane-needs-test.sh — a leg of the scenario-lanes job builds the
# HCR flame demo and the blockchain recorders only where
# ci/test/scenario-lane-needs.sh says its shard needs them. This holds that to the
# scenarios: in every split .github/workflows/scenario-lanes.yml runs, each
# scenario that runs the `hcr-flame` stage or records Solana, PolkaVM or
# Solidity is on a shard flagged for it, so none of them meets a missing
# prerequisite. It also checks the workflow asks for its own shard and gates the
# builds on the answer, and that a scenario needing a piece the helper does not
# know is caught (a negative control). Needs python3.
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$root"
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
# check <ok message> <fail message> <command...>
check() {
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "${good}"; else fail "${bad}"; fi
}
lanes=src/tests/scenarios/lanes
wf=.github/workflows/scenario-lanes.yml

# The scenarios of a lane matching ERE, sorted.
users_of() {
	local lane="$1" ere="$2" e
	sed -n '/^applicable:/,/^[^ ]/{s/^ *- //p}' "${lanes}/${lane}.lane.yaml" |
		while read -r e; do
			if grep -Eq "${ere}" "${lanes}/${e}"; then echo "${e}"; fi
		done | sort
}

# Independent spellings of what each piece's scenarios look like.
declare -A ere=(
	[hcr]='use:[[:space:]]*hcr-flame'
	[solana]='lang:[[:space:]]*solana'
	[polkavm]='lang:[[:space:]]*polkavm'
	[evm]='\.sol[[:space:]]*[,}]'
)

# lane and shard count of every run the workflow has (`{leg: <run>-<i>-of-<n>,
# lane: <lane>, shard: <i>/<n>}`, or `shard: ""` for the whole lane).
splits="$(sed -n 's/.*{leg: [a-z-]*-[0-9]*-of-\([0-9]*\), lane: \([a-z-]*\),.*/\2 \1/p' "${wf}" | sort -u)"
[ -n "${splits}" ] || fail "${wf} has no lane leg"

echo "every scenario that needs a piece is on a shard flagged for it"
while read -r lane n; do
	[ -n "${lane}" ] || continue
	declare -A covered=()
	for i in $(seq 1 "${n}"); do
		part="$(python3 ci/test/scenario-lane-shard.py "${lanes}/${lane}.lane.yaml" "${i}/${n}" --list | sort)"
		out="$(bash ci/test/scenario-lane-needs.sh "${lane}" "${i}/${n}")"
		for piece in "${!ere[@]}"; do
			flagged=false
			if [ "${piece}" = hcr ]; then
				grep -qx 'hcr=true' <<<"${out}" && flagged=true
			else
				grep -Eq "^recorders=(.*,)?${piece}(,.*)?$" <<<"${out}" && flagged=true
			fi
			if [ "${flagged}" = true ]; then
				covered[$piece]+="$(comm -12 <(echo "${part}") <(users_of "${lane}" "${ere[$piece]}"))"$'\n'
			fi
		done
	done
	for piece in "${!ere[@]}"; do
		want="$(users_of "${lane}" "${ere[$piece]}")"
		got="$(printf '%s' "${covered[$piece]:-}" | sed '/^$/d' | sort)"
		if [ "${got}" = "${want}" ]; then
			ok "${lane} in ${n}: every ${piece} scenario ($(grep -c . <<<"${want}" || true)) is on a shard that builds it"
		else
			fail "${lane} in ${n}: ${piece} scenarios on no flagged shard: $(comm -23 <(echo "${want}") <(echo "${got}") | tr '\n' ' ')"
		fi
	done
	unset covered
done <<<"${splits}"

echo "the controls: the helper is not vacuous"
every_piece_has_scenarios() {
	local piece
	for piece in hcr solana polkavm evm; do
		[ -n "$(users_of electron "${ere[$piece]}")" ] || return 1
	done
}
check "the desktop lane has hcr, solana, polkavm and evm scenarios" \
	"the desktop lane lacks one of hcr, solana, polkavm, evm scenarios: the check would prove nothing" \
	every_piece_has_scenarios
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
# A copy of the tree's scenarios with one Solana scenario spelling its language
# in a way the helper does not read: the helper must then stop flagging it.
mkdir -p "${work}/ci/test" "${work}/src/tests"
cp ci/test/scenario-lane-needs.sh ci/test/scenario-lane-shard.py "${work}/ci/test/"
cp -r src/tests/scenarios "${work}/src/tests/"
victim="$(users_of electron "${ere[solana]}" | head -n 1)"
sed -i 's/lang:[[:space:]]*solana/lang: "sol" "ana"/' "${work}/${lanes}/${victim}"
flagged_any=false
for i in 1 2 3 4; do
	if bash "${work}/ci/test/scenario-lane-needs.sh" electron "${i}/4" | grep -q '^recorders=.*solana' &&
		grep -qx "${victim}" <(python3 "${work}/ci/test/scenario-lane-shard.py" "${work}/${lanes}/electron.lane.yaml" "${i}/4" --list); then
		flagged_any=true
	fi
done
if [ "${flagged_any}" = false ]; then
	ok "a Solana scenario the helper cannot read is on no Solana shard (the coverage check above would fail)"
else
	fail "the helper still flags a Solana scenario whose language it cannot read"
fi

echo "the workflow asks for its own shard and gates the builds on the answer"
hcr_gates() { [ "$(grep -cF "steps.needs.outputs.hcr == 'true'" "${wf}")" = 2 ]; }
# shellcheck disable=SC2016 # the workflow expressions, literally
check "${wf} runs the helper for the leg's lane and shard" "${wf} does not run scenario-lane-needs.sh for its shard" \
	grep -qF 'bash ci/test/scenario-lane-needs.sh "$LANE" "${SHARD:-1/1}" | tee -a "$GITHUB_OUTPUT"' "${wf}"
# shellcheck disable=SC2016 # the workflow expression, literally
check "${wf} builds the recorders the helper names" "${wf} does not pass the helper's recorders on" \
	grep -qF 'SCENARIO_LANE_RECORDERS: ${{ steps.needs.outputs.recorders }}' "${wf}"
check "${wf} restores and builds the HCR demo only on flagged shards" "${wf}: the HCR steps are not gated on steps.needs.outputs.hcr" \
	hcr_gates
echo
if [ "${failures}" -gt 0 ]; then
	echo "${failures} failure(s)"
	exit 1
fi
echo "all checks passed"
