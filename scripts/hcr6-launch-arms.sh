#!/usr/bin/env bash
# H6 — run every arm of `e2e_codetracer_launches_flame_under_hcr`, then grade
# the SET of them.
#
# Milestone: codetracer-specs/Marketing/Home-Demo-Screencast.milestones.org, H6.
# Spec:      src/tests/gui/tests/hcr-live-edit/flame_launch_under_hcr.spec.ts
#
# The gate is one Playwright spec parameterised by `CT_H6_ARM`. Each arm asserts
# its OWN claim and writes `observations.json`; this script runs all six and then
# hands every observation file to the flame demo's
# `hcr6_discrimination_matrix.py`, which requires two things the arms cannot
# check individually:
#
#   * every arm satisfies its own expectation, and
#   * NO arm's expectation is satisfied by any other arm's run.
#
# The second is what "these arms discriminate" means made checkable. "Five arms,
# all red" says nothing: H5 shipped two arms that both went red for reasons
# neither claimed (Verification-Harness-Traps.md §20) and one that passed with
# its subject absent (§1b).
#
# Every arm must PASS as a Playwright test — a falsifier arm passes by producing
# the named failure it exists to produce, and an arm that fails here is an arm
# whose feature-removal did not have the effect it claims.
#
# Usage: scripts/hcr6-launch-arms.sh [arm …]     (default: all six)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "$REPO/.." && pwd)"
FLAME_REPO="${CODETRACER_FLAME_DEMO_REPO:-$WORKSPACE/codetracer-flame-demo}"
SPEC="tests/hcr-live-edit/flame_launch_under_hcr.spec.ts"

ALL_ARMS=(
	green
	no-hcr-block
	harness-launches
	coordinator-not-a-coordinator
	target-exits-immediately
	agent-never-dials
)
if [[ $# -gt 0 ]]; then
	ARMS=("$@")
else
	ARMS=("${ALL_ARMS[@]}")
fi

log() { printf '[h6] %s\n' "$*"; }
die() {
	printf '[h6] FATAL: %s\n' "$*" >&2
	exit 1
}

[[ -d $FLAME_REPO ]] || die "flame demo checkout not found: $FLAME_REPO"
MATRIX="$FLAME_REPO/scripts/hcr6_discrimination_matrix.py"
[[ -f $MATRIX ]] || die "the discrimination matrix script is missing: $MATRIX"

failed=()
for arm in "${ARMS[@]}"; do
	log "=== arm $arm"
	start=$(date +%s)
	if CT_H6_ARM="$arm" just --justfile "$REPO/justfile" test-gui-prebuilt "$SPEC"; then
		log "arm $arm: the spec passed in $(($(date +%s) - start))s"
	else
		log "arm $arm: THE SPEC FAILED after $(($(date +%s) - start))s"
		failed+=("$arm")
	fi
done

if [[ ${#failed[@]} -gt 0 ]]; then
	die "arm(s) failed: ${failed[*]}"
fi

# The matrix needs EVERY arm, and says so rather than grading a subset: an arm
# that was not run is not an arm that discriminated.
if [[ ${#ARMS[@]} -ne ${#ALL_ARMS[@]} ]]; then
	log "only ${#ARMS[@]} of ${#ALL_ARMS[@]} arms were run; skipping the matrix"
	log "RESULT: the arms that ran passed, and the SET was NOT graded"
	exit 0
fi

args=()
for arm in "${ALL_ARMS[@]}"; do
	obs="$FLAME_REPO/artifacts/h6-launch/$arm/observations.json"
	[[ -f $obs ]] || die "arm $arm produced no observations at $obs"
	args+=(--observations "$arm=$obs")
done

log "grading the set"
python3 "$MATRIX" "${args[@]}" \
	--json-out "$FLAME_REPO/artifacts/h6-launch/discrimination.json" ||
	die "the arms do not discriminate; see the matrix above"

log "RESULT: PASS — ${#ALL_ARMS[@]} arms, each satisfied only by its own run"
