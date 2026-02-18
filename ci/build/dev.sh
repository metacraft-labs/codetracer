#!/usr/bin/env bash

set -e

echo '###############################################################################'
echo "Build:"
echo '###############################################################################'

node_modules/.bin/webpack

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
