#!/usr/bin/env bash
#
# Orchestrator: regenerate every modes/* benchmark fixture.
#
# Per spec §6.8.6.4 the benchmark needs a per-TraceKind fixture
# matrix; this script iterates over each fixture and re-records.
# Per-scenario SKIPs (exit 2) do NOT abort the orchestration — they
# print to stderr and the runner reports the per-fixture status.
#
# Usage:
#     src/db-backend/tests/fixtures/origin/modes/regenerate.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

SCENARIOS=(
	python_materialized
	c_recreator
	browser_replay_emulator
)

skipped=0
failed=0
ran=0
for sc in "${SCENARIOS[@]}"; do
	script="$HERE/$sc/regenerate.sh"
	if [[ ! -x $script ]]; then
		echo "SKIP (not executable): $script" >&2
		skipped=$((skipped + 1))
		continue
	fi
	echo "==> modes/$sc"
	rc=0
	(cd "$HERE/$sc" && "$script") || rc=$?
	case $rc in
	0)
		ran=$((ran + 1))
		;;
	2)
		echo "  modes/$sc skipped (prereq missing — see stderr above)" >&2
		skipped=$((skipped + 1))
		;;
	*)
		echo "  modes/$sc FAILED (exit $rc)" >&2
		failed=$((failed + 1))
		;;
	esac
done

echo "modes: $ran ran, $skipped skipped, $failed failed (of ${#SCENARIOS[@]})"
if ((failed > 0)); then
	exit 1
fi
