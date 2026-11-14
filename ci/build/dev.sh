#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo "Build:"
echo '###############################################################################'

node_modules/.bin/webpack

# The per-checkout Nim cache root src/Tuprules.tup imports. `tup generate`
# bakes it into the generated script at generate time, so it must be set
# here, before the generate, not only when the script runs.
CT_TUP_NIM_CACHE_ROOT="$(bash ci/lib/nim-cache-root.sh --tup "$PWD")"
export CT_TUP_NIM_CACHE_ROOT
# The Cargo target base, likewise baked in at generate time. The helper creates
# the base before the generated script's cargo commands need it, and refuses
# one it cannot prove belongs to this checkout and compiler.
ct_tup_cargo_env="$(bash ci/lib/tup-cargo-target.sh --export "$PWD")"
eval "$ct_tup_cargo_env"

pushd src

# Use tup generate, because FUSE may not be supported on the CI runners.
# tup build-debug requires FUSE for its dependency tracking, but tup generate
# produces a standalone shell script that runs the same build commands without FUSE.
if [ ! -d .tup ]; then
	tup init
fi

TUP_OUTPUT_SCRIPT=tup-generated-build-once.sh
tup generate --config build-debug/tup.config "$TUP_OUTPUT_SCRIPT"
./"$TUP_OUTPUT_SCRIPT"
rm "$TUP_OUTPUT_SCRIPT"

popd
