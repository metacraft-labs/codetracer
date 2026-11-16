#!/usr/bin/env bash
# Build the CI dev shells and the codetracer package, and push their closures to
# the Attic cache that the runner hosts substitute from. Run by
# .github/workflows/cache-push.yml, inside `.#ci` (which carries attic-client).
#
# A shell is pushed as its `inputDerivation`: that derivation's output
# references every input of the shell, so its closure is exactly what
# `nix develop` would otherwise build on a cold runner (780 paths, 15.1 GiB for
# `.#ci`, measured 2026-11-16).

set -euo pipefail

: "${ATTIC_ENDPOINT:?ATTIC_ENDPOINT is required}"
: "${ATTIC_CACHE:?ATTIC_CACHE is required}"
: "${ATTIC_TOKEN:?ATTIC_TOKEN is required}"

attic login --set-default codetracer-ci "$ATTIC_ENDPOINT" "$ATTIC_TOKEN"

for target in \
	.#devShells.x86_64-linux.ci.inputDerivation \
	.#devShells.x86_64-linux.default.inputDerivation \
	".?submodules=1#codetracer"; do
	echo "== building ${target}"
	out="$(nix build --no-link --print-out-paths "${target}")"
	echo "== pushing ${out}"
	# shellcheck disable=SC2086 # one store path per line
	attic push "$ATTIC_CACHE" ${out}
done
