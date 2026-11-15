#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo "Build:"
echo '###############################################################################'

node_modules/.bin/webpack

# The roots src/Tuprules.tup imports and refuses to parse without: the Cargo
# target base and the per-checkout Nim cache root, from one command.
# `tup generate` bakes them into the generated script, so they must be set
# here, before the generate. The helper creates the Cargo base before the
# generated script's cargo commands need it, refuses one it cannot prove
# belongs to this checkout and compiler, and (`--reap`, a build) removes this
# checkout's older-compiler bases.
ct_tup_cargo_env="$(bash ci/lib/tup-cargo-target.sh --reap --export "$PWD")"
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
