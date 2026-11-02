#!/usr/bin/env bash
# Exercise the real flake graph with the Nix on PATH (the provisioned Nix
# when run from the dev-env). No input overrides or registry fixtures: those
# would hide the override-only nested input failure this guards against.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# Evaluate declarations without fetching inputs. This covers every Nix
# spelling (including quoted attributes), even when an override happens to
# resolve to the producer's current revision.
overrides_runquota=$(nix eval --json --file "$repo_root/flake.nix" --apply \
	'flake: builtins.hasAttr "runquota-src" (flake.inputs.reprobuild.inputs or {})')
if [ "$overrides_runquota" != false ]; then
	echo "FAIL: CodeTracer must not override reprobuild's runquota-src" >&2
	exit 1
fi

# Metadata does not consume submodule contents. A path flake exercises the
# complete input graph even in a checkout whose submodules are not populated.
# Refuse lock updates so success cannot come from repairing the tested graph.
nix flake metadata --no-update-lock-file --json "path:$repo_root" >/dev/null
echo 'dev-env flake metadata: PASS'

# Real, local Git flakes isolate Nix's nested-input locking from package
# compilation. They are not substitute compilers or source-library mocks:
# the packaged build separately exercises the locked compiler/API boundary.
# Moving only the producer must move the derived child too. The mutation
# demonstrates why even a currently matching nested URL is forbidden.
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
init_repo() {
	git -C "$1" init -q
	git -C "$1" config user.name 'flake input test'
	git -C "$1" config user.email 'flake-input-test@example.invalid'
}
commit_repo() {
	git -C "$1" add .
	git -C "$1" -c commit.gpgsign=false commit -qm "$2"
	git -C "$1" rev-parse HEAD
}
mkdir -p "$scratch/child" "$scratch/producer" "$scratch/consumer"
init_repo "$scratch/child"
printf '{ outputs = _: {}; }\n' >"$scratch/child/flake.nix"
printf 'first' >"$scratch/child/marker"
first=$(commit_repo "$scratch/child" first)
printf 'second' >"$scratch/child/marker"
second=$(commit_repo "$scratch/child" second)
init_repo "$scratch/producer"
producer_revision() {
	cat >"$scratch/producer/flake.nix" <<NIX
{
  inputs.runquota-src.url = "git+file://$scratch/child?rev=$1";
  outputs = _: {};
}
NIX
	nix flake lock "path:$scratch/producer" >/dev/null
	commit_repo "$scratch/producer" "$1"
}
producer_first=$(producer_revision "$first")
producer_second=$(producer_revision "$second")
consumer_flake() {
	cat >"$scratch/consumer/flake.nix" <<NIX
{
  inputs.reprobuild.url = "git+file://$scratch/producer?rev=$1";
  inputs.runquota.follows = "reprobuild/runquota-src";
  $2
  outputs = { runquota, ... }: { marker = builtins.readFile (runquota + "/marker"); };
}
NIX
	nix flake lock "path:$scratch/consumer" >/dev/null
	nix eval --raw "path:$scratch/consumer#marker"
}
[ "$(consumer_flake "$producer_first" '')" = first ]
[ "$(consumer_flake "$producer_second" '')" = second ]
# Positive control: restoring the removed consumer override must hold the
# child back even while the producer selects the newer revision.
[ "$(consumer_flake "$producer_second" \
	"inputs.reprobuild.inputs.runquota-src.url = \"git+file://$scratch/child?rev=$first\";")" = first ]
echo 'producer-owned RunQuota input update and override control: PASS'
