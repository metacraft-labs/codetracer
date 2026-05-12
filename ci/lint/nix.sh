#!/usr/bin/env bash

set -e

# Allow unfree packages so that codetracer-appimage (which carries an unfree
# license) can be evaluated during the check.
# codetracer-trace-format is now a sibling repo (not a submodule).  When a
# local checkout exists, override the input to point at it; otherwise let nix
# fetch from GitHub per the flake.nix declaration.
override_args=()
if [ -d ../codetracer-trace-format ]; then
	override_args+=(--override-input codetracer-trace-format path:../codetracer-trace-format)
fi

NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure "${override_args[@]}"
