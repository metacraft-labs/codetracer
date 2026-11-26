#!/usr/bin/env bash
# A plain `github:` flake ref brings this flake's git submodules with it.
#
# GitHub's tarballs carry no submodules, so `nix build
# github:metacraft-labs/codetracer/<rev>#codetracer` used to get empty libs/*
# submodule directories and fail (libs/tree-sitter-nim missing); only
# `git+https://...?submodules=1` worked. flake.nix now declares
# `inputs.self.submodules = true` (Nix 2.27 or later), which makes Nix refetch
# the flake with its submodules whatever URL names it.
#
# This fetches the flake from GitHub by a plain `github:` ref at the commit
# under test (GITHUB_SHA in CI, HEAD otherwise, which must then be pushed) and
# requires a file of the tree-sitter-nim submodule in its source. Negative
# control: the same check at 2887756e7ab, the last commit before the
# declaration, must find the submodule directory empty.
#
# Lane: ci/lint/nix.sh.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fail() {
	echo "flake-self-submodules: FAIL: $*" >&2
	exit 1
}
probe="libs/tree-sitter-nim/grammar.js"
before_declaration=2887756e7ab59565b21a78a82a0be954974e79aa

version="$(nix --version | grep -oE '[0-9]+\.[0-9]+' | head -n1)"
major="${version%%.*}"
minor="${version#*.}"
if [ "$major" -lt 2 ] || { [ "$major" -eq 2 ] && [ "$minor" -lt 27 ]; }; then
	fail "this Nix ($(nix --version)) predates inputs.self.submodules (2.27)"
fi

# source_has_probe REV: 0 when the flake's source at REV, fetched by a plain
# github: ref, holds the submodule file.
source_has_probe() {
	local path
	path="$(nix flake metadata --json "github:metacraft-labs/codetracer/$1" |
		python3 -c 'import json, sys; print(json.load(sys.stdin)["path"])')" ||
		fail "could not fetch github:metacraft-labs/codetracer/$1 (is the commit pushed?)"
	[ -f "$path/$probe" ]
}

rev="${GITHUB_SHA:-$(git -C "$repo" rev-parse HEAD)}"
if source_has_probe "$rev"; then
	echo "  ok   github:metacraft-labs/codetracer/$rev carries $probe"
else
	fail "github:metacraft-labs/codetracer/$rev has no $probe: the flake's submodules were not fetched"
fi
if source_has_probe "$before_declaration"; then
	fail "negative control: $before_declaration, before inputs.self.submodules, also carries $probe, so this check cannot tell"
fi
echo "  ok   negative control: before the declaration ($before_declaration) the submodule is empty"
echo "flake-self-submodules: ok"
