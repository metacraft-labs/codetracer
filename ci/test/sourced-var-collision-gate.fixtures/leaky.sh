#!/usr/bin/env bash
# FIXTURE — every assignment here is a real leak. ci/test/sourced-var-collision-gate.sh
# asserts its detector finds each one. This file is never sourced and never run;
# it exists so that a detector which has rotted into a no-op fails loudly instead
# of reporting a clean repository.
#
# It deliberately carries NO `ct-leaks:` declaration: the gate must find these.

# The shape from 3c7b257ed.
REPO_ROOT="$(pwd)"

# The shape from 295f36835.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# `export` does not make it any less of a collision — it makes it worse.
export ROOT_DIR="${SCRIPT_DIR}/.."

# A GUARD ON THE WRONG SENTINEL. This is the exact shape
# `non-nix-build/windows/setup-codetracer-runtime-env.sh` carried: three
# fallbacks in one block, all keyed on whether ROOT_DIR is set, so a caller who
# had resolved BASE_DIR and not ROOT_DIR had BASE_DIR silently rewritten. A
# detector that accepts any `-z` guard would call this safe.
if [[ -z ${ROOT_DIR:-} ]]; then
	BASE_DIR="$(pwd)"
fi

echo "${REPO_ROOT} ${ROOT_DIR} ${BASE_DIR}"
