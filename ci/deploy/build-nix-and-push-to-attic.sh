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

# test-ui-tests builds ct-mcr in codetracer-native-recorder's own dev shell
# (`nix develop` in the sibling, which sits at the revision codetracer's
# flake.lock pins). That shell is the same derivation as the flake input's at
# that revision (checked 2026-11-16: both evaluate to one .drv), so it is
# pushed from there.
recorder_node="$(jq -r '.nodes.root.inputs["codetracer-native-recorder"]' flake.lock)"
recorder_rev="$(jq -r --arg n "$recorder_node" '.nodes[$n].locked.rev' flake.lock)"
case "$recorder_rev" in
[0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
*)
	echo "build-nix-and-push-to-attic: cannot read codetracer-native-recorder's revision from flake.lock (got '${recorder_rev}')" >&2
	exit 1
	;;
esac

for target in \
	.#devShells.x86_64-linux.ci.inputDerivation \
	.#devShells.x86_64-linux.default.inputDerivation \
	"github:metacraft-labs/codetracer-native-recorder/${recorder_rev}#devShells.x86_64-linux.default.inputDerivation" \
	".?submodules=1#codetracer"; do
	echo "== building ${target}"
	out="$(nix build --no-link --print-out-paths "${target}")"
	echo "== pushing ${out}"
	# shellcheck disable=SC2086 # one store path per line
	attic push "$ATTIC_CACHE" ${out}
done

# The flake's inputs too. A cold runner fetched them one by one from GitHub,
# codeberg and releases.nixos.org: 11 of the 29 minutes its provisioning took
# (run 43935388749, GPUI shard 2), plus 5 waiting on one nixexprs tarball.
# A locked input is a store path with a known NAR hash, so a runner whose
# substituters hold it copies it instead of fetching it.
echo "== pushing the flake's inputs"
# The builds above fetched every input they read; flake-input-paths.py names
# them from flake.lock's NAR hashes (`nix flake archive` refuses the whole
# flake on one unlocked node).
mapfile -t inputs < <(python3 ci/deploy/flake-input-paths.py --existing flake.lock)
echo "== ${#inputs[@]} input source(s) present"
if [ "${#inputs[@]}" -gt 0 ]; then
	attic push "$ATTIC_CACHE" "${inputs[@]}"
fi
