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

# Provide Electron from Nix so electron-builder doesn't attempt network access
ROOT_PATH=$(git rev-parse --show-toplevel)
CURRENT_NIX_SYSTEM=$(nix eval --impure --raw --expr 'builtins.currentSystem')
nix build "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.electron" >/dev/null
ELECTRON_PATH=$(nix eval --raw "${ROOT_PATH}#packages.${CURRENT_NIX_SYSTEM}.electron.out")
export ELECTRON_SKIP_BINARY_DOWNLOAD=1
export ELECTRON_OVERRIDE_DIST_PATH="${ELECTRON_PATH}/lib/electron"

node_modules/.bin/webpack

pushd node-packages >/dev/null
npx electron-builder --linux dir
popd >/dev/null
ln -sf "$(pwd)/node-packages/dist/linux-unpacked/codetracer-electron" src/links/electron

pushd src

# Use tup generate, because FUSE may not be supported on the runners
TUP_OUTPUT_SCRIPT=tup-generated-build-once.sh
tup generate --config build-debug/tup.config "$TUP_OUTPUT_SCRIPT"
./"$TUP_OUTPUT_SCRIPT"
rm "$TUP_OUTPUT_SCRIPT"

popd
