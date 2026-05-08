#!/usr/bin/env bash

set -e

echo "==========="
echo "codetracer build: setup node deps"
echo "-----------"

# Generate tree-sitter-nim parser BEFORE yarn install
# (yarn will try to build tree-sitter-nim which needs parser.c)
bash "$ROOT_DIR/non-nix-build/ensure_tree_sitter_nim_parser.sh"

# setup node deps
#   node modules and webpack/frontend_bundle.js
pushd "$ROOT_DIR"/node-packages
echo y | npx yarn

# Explicitly invoke the electron binary installer in case the postinstall
# script was skipped or the download failed during 'yarn install'.
# This downloads the platform-specific Electron binary to node_modules/electron/dist/.
node node_modules/electron/install.js

if [ ! -d "node_modules/electron/dist/Electron.app" ] && [ ! -f "node_modules/electron/dist/electron" ]; then
	echo "ERROR: Electron binary download failed. Check your network connection and try again."
	echo "You can also set ELECTRON_MIRROR to use a custom download mirror."
	exit 1
fi

pushd "$ROOT_DIR"
node_modules/.bin/webpack

rm -rf "$ROOT_DIR"/node_modules
rm -rf "$DIST_DIR"/node_modules
ln -s "$ROOT_DIR"/node-packages/node_modules "$ROOT_DIR"/node_modules
cp -r "$ROOT_DIR"/node-packages/node_modules "$DIST_DIR"/node_modules

# => now we have node_modules, and $ROOT_DIR/src/public/dist/frontend_bundle.js
# <=> $DIST_DIR/public/dist/frontend_bundle.js

popd
popd

echo "==========="
