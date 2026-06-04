#!/usr/bin/env bash
# Per-language orchestrator: regenerate every Rust origin fixture.
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
	echo "==> rust/$sc"
	if ! (cd "$HERE/$sc" && ./regenerate.sh); then
		echo "FAIL rust/$sc" >&2
		failures=$((failures + 1))
	fi
done
if ((failures > 0)); then
	echo "rust: $failures scenario(s) failed (M0: regenerate scripts are not yet required to succeed)" >&2
	exit "$failures"
fi
echo "rust: all ${#SCENARIOS[@]} scenarios regenerated."
