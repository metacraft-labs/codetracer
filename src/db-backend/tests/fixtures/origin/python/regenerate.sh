#!/usr/bin/env bash
#
# Per-language orchestrator: regenerate every Python origin fixture.
#
# Iterates over each canonical scenario directory and invokes its
# `regenerate.sh`. Per-scenario failures are surfaced but do not abort
# the entire run — M0 ships the scripts; individual scenarios may not
# yet record cleanly. The top-level orchestrator
# `tests/fixtures/origin/regenerate-fixtures.sh` calls this in turn.
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

SCENARIOS=(
	simple_trivial_chain
	computational_origin
	parameter_pass
	return_capture
	destructuring_or_index
)

failures=0
for sc in "${SCENARIOS[@]}"; do
	script="$HERE/$sc/regenerate.sh"
	if [[ ! -x $script ]]; then
		echo "SKIP (not executable): $script" >&2
		failures=$((failures + 1))
		continue
	fi
	echo "==> python/$sc"
	if ! (cd "$HERE/$sc" && "$script"); then
		echo "FAIL python/$sc" >&2
		failures=$((failures + 1))
	fi
done

if ((failures > 0)); then
	echo "python: $failures scenario(s) failed (M0: regenerate scripts are not yet required to succeed)" >&2
	exit "$failures"
fi
echo "python: all ${#SCENARIOS[@]} scenarios regenerated."
