#!/usr/bin/env bash

set -euo pipefail

: "${ATTIC_ENDPOINT:?ATTIC_ENDPOINT is required}"
: "${ATTIC_CACHE:?ATTIC_CACHE is required}"
: "${ATTIC_TOKEN:?ATTIC_TOKEN is required}"

attic login --set-default codetracer-ci "$ATTIC_ENDPOINT" "$ATTIC_TOKEN"

###############################################################################
# builds and pushes devshell to Attic
###############################################################################
build_out=$(nix build --print-out-paths .#devShells.x86_64-linux.default)
res=$?

# Propagate error if nix build fails
if [ $res -ne 0 ]; then
	exit $res
fi

attic push "$ATTIC_CACHE" "$build_out"
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

attic push "$ATTIC_CACHE" "$build_out"
###############################################################################
