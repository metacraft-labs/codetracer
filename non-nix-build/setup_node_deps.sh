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
npx yarn add electron

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
