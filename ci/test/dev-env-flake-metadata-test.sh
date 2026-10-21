#!/usr/bin/env bash
# Exercise the real flake graph with the Nix on PATH (the provisioned Nix
# when run from the dev-env). No input overrides or registry fixtures: those
# would hide the override-only nested input failure this guards against.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# Metadata does not consume submodule contents. A path flake exercises the
# complete input graph even in a checkout whose submodules are not populated.
# Refuse lock updates so success cannot come from repairing the tested graph.
nix flake metadata --no-update-lock-file --json "path:$repo_root" >/dev/null
echo 'dev-env flake metadata: PASS'
