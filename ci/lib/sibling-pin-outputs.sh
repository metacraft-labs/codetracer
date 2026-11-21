#!/usr/bin/env bash
# sibling-pin-outputs.sh KEY=SOURCE:REPO... -- write each KEY=<40-hex revision>
# to $GITHUB_OUTPUT (and stdout), for a workflow step to clone REPO at.
#
#   SOURCE flake  the single revision flake.lock locks metacraft-labs/REPO at
#                 (the private siblings, which the public repro.lock cannot pin)
#   SOURCE lock   the revision repro.lock pins REPO at
#
# Run from the codetracer checkout inside its dev shell: a raw step on the
# nix-darwin runners has no jq, grep or sed. Moved here from the workflow
# steps that each spelled it inline, which took codetracer.yml past GitHub's
# 512,000-byte limit (ci/test/workflow-file-size-test.sh).
set -euo pipefail
out="${GITHUB_OUTPUT:-/dev/null}"
for spec in "$@"; do
	key="${spec%%=*}"
	rest="${spec#*=}"
	source="${rest%%:*}"
	repo="${rest#*:}"
	case "$source" in
	flake)
		rev="$(jq -er --arg r "$repo" '[.nodes[] | .locked? | select(.owner? == "metacraft-labs" and .repo? == $r) | .rev] | unique | if length == 1 then .[0] else error("\($r): \(length) revisions in flake.lock") end' flake.lock)"
		;;
	lock)
		rev="$(grep -oE "\\{ name = \"${repo}\"[^}]*" repro.lock | grep -oE 'revision = "[0-9a-f]{40}"' | grep -oE '[0-9a-f]{40}' || true)"
		;;
	*)
		echo "sibling-pin-outputs: '$spec': the source must be flake or lock" >&2
		exit 2
		;;
	esac
	[[ "$rev" =~ ^[0-9a-f]{40}$ ]] || {
		echo "::error::sibling-pin-outputs: no 40-hex revision for ${repo} in ${source}" >&2
		exit 1
	}
	echo "${key}=${rev}" | tee -a "$out"
done
