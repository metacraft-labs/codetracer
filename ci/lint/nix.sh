#!/usr/bin/env bash
#
# Nix lint stage.
#
# One step today, but it runs through ci/lib/lint-steps.sh like every other
# ci/lint script so that the next check added here cannot be hidden behind this
# one — and so ci/test/lint-step-isolation-test.sh can assert that property for
# the whole directory rather than for a hand-maintained subset of it.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# The pre-commit shellcheck hook runs without -x, so it cannot follow the
# source and reports SC1091; the source= directive above still tells the -x
# runs (ci/lint/bash.sh) where the library lives.
# shellcheck source=ci/lib/lint-steps.sh disable=SC1091
source ci/lib/lint-steps.sh

# Allow unfree packages so that codetracer-appimage (which carries an unfree
# license) can be evaluated during the check.
# codetracer-trace-format is now a sibling repo (not a submodule).  When a
# local checkout exists, override the input to point at it; otherwise let nix
# fetch from GitHub per the flake.nix declaration.
flake_check() {
	set -e
	local override_args=()
	if [ -d ../codetracer-trace-format ]; then
		override_args+=(--override-input codetracer-trace-format path:../codetracer-trace-format)
	fi
	# The `+` expansion keeps an empty array from tripping `set -u` on the
	# older bashes this script still has to run under.
	NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure \
		${override_args[@]+"${override_args[@]}"}
}

lint_step "nix flake check" flake_check

lint_summary
