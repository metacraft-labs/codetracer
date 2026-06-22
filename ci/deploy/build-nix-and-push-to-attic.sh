#!/usr/bin/env bash

set -e

attic_cache="${ATTIC_CACHE:-metacraft-codetracer}"
attic_endpoint="${ATTIC_ENDPOINT:-https://cache.metacraft-labs.com/}"

: "${ATTIC_TOKEN:?ATTIC_TOKEN is required to push to Attic}"
nix shell nixpkgs#attic-client -c attic login --set-default ci "$attic_endpoint" "$ATTIC_TOKEN"

###############################################################################
# builds and pushes devshell to Attic
###############################################################################
build_out=$(nix build --print-out-paths .#devShells.x86_64-linux.default)
res=$?

# Propagate error if nix build fails
if [ $res -ne 0 ]; then
	exit $res
fi

nix shell nixpkgs#attic-client -c attic push --jobs 1 --ignore-upstream-cache-filter "$attic_cache" "$build_out"
###############################################################################

###############################################################################
# builds and pushes it to Attic
###############################################################################
build_out=$(nix build --print-out-paths ".?submodules=1#codetracer")
res=$?

# Propagate error if nix build fails
if [ $res -ne 0 ]; then
	exit $res
fi

nix shell nixpkgs#attic-client -c attic push --jobs 1 --ignore-upstream-cache-filter "$attic_cache" "$build_out"
###############################################################################
