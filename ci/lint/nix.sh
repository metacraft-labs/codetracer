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
	# `.?submodules=1`, as every package build is: the packages read their
	# submodule libraries (libs/tree-sitter-*), and without it the evaluation
	# stopped on "path '.../libs/tree-sitter-aiken' does not exist" (lint-nix,
	# run 44269676398).
	NIXPKGS_ALLOW_UNFREE=1 nix flake check '.?submodules=1' --impure \
		${override_args[@]+"${override_args[@]}"}
}

# Check the package's actual source and check tools in a Nix sandbox, before
# paying for the Rust build. Missing ct-home or Python must fail packaging.
lint_step "backend-manager sandbox package inputs" \
	nix build --impure --no-link --max-jobs 2 --cores 2 \
	--expr 'import ./ci/test/backend-manager-package-inputs.nix { }'

# db-backend builds from an explicit file set (nix/packages/default.nix): it
# must hold every path dependency its manifests reach, and a commit outside it
# must leave its derivation (and so its cached output) unchanged.
lint_step "db-backend package inputs" \
	nix build --impure --no-link --max-jobs 2 --cores 2 \
	--expr 'import ./ci/test/db-backend-package-inputs.nix { }'
# The other packages build from an explicit list that leaves out src/tests/,
# ci/, docs/ and .github/: it must hold every file their modules embed.
lint_step "the packages' source holds every file their modules embed" \
	nix build --impure --no-link --max-jobs 2 --cores 2 \
	--expr 'import ./ci/test/package-src-completeness.nix { }'
lint_step "a commit outside a package's inputs leaves its derivation alone" \
	bash ci/test/package-src-invariance-test.sh

# Every flake package is built by a CI job, built as an input of one, or a
# named exception, so a change that breaks one fails a job rather than going
# unnoticed (#codetracer-tui did).
lint_step "every flake package is built by a CI job or excepted" \
	bash ci/test/flake-packages-built-test.sh

# Requires the host's Nix daemon and real local bare repositories, so this
# belongs to the Nix lane rather than the lightweight shell-only lint lane.
lint_step "Nix Git hooks in fresh worktrees" bash ci/test/nix-git-hooks-test.sh

lint_step "nix flake check" flake_check

lint_summary
