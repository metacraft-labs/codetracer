#!/usr/bin/env bash

set -e

###############################################################################
# builds and pushes devshell to cachix
###############################################################################
build_out=$(nix build --print-out-paths .#devShells.x86_64-linux.default)
res=$?

# Propagate error if nix build fails
if [ $res -ne 0 ]; then
  exit $res
fi

cachix push metacraft-labs-codetracer "$build_out"
###############################################################################

###############################################################################
# builds and pushes it to cachix
###############################################################################
build_out=$(nix build --print-out-paths ".?submodules=1#codetracer")
res=$?

# Propagate error if nix build fails
if [ $res -ne 0 ]; then
  exit $res
fi

cachix push metacraft-labs-codetracer "$build_out"
###############################################################################
