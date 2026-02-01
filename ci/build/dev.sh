#!/usr/bin/env bash

set -e

function stop_processes {
	# stop processes: it seems they can remain hanging
	# copied from `justfile`: `just stop`
	killall -9 virtualization-layers db-backend node .electron-wrapped || true
}

echo '###############################################################################'
echo "Cleanup:"
echo '###############################################################################'

# stop processes: make sure none of those processes left from last build
stop_processes

git clean -xfd src/build-debug

mv src/links links
git clean -xfd src/
mv links src/links

echo '###############################################################################'
echo "Build:"
echo '###############################################################################'

node_modules/.bin/webpack

pushd src

# Use tup generate, because FUSE may not be supported on the runners
TUP_OUTPUT_SCRIPT=tup-generated-build-once.sh
tup generate --config build-debug/tup.config "$TUP_OUTPUT_SCRIPT"
./"$TUP_OUTPUT_SCRIPT"
rm "$TUP_OUTPUT_SCRIPT"

# TODO: this is not really working, problems with variants: generated script produce
#   files directly in src/, instead of in src/build-debug, and so it can't run well
#   we need to see if we can generate it in a better way, or to wrap/restructure the resulting folders
#   to make possible to test the dev build in CI

popd
