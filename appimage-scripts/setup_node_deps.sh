#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$NIX_CODETRACER_EXE_DIR`
# and node

set -e

echo "==========="
echo "codetracer build: setup node deps"
echo "==========="

# setup node deps
#   node modules and webpack/frontend_bundle.js
pushd "${ROOT_PATH}/node-packages"

echo y | npx yarn

popd

cp -Lr "${ROOT_PATH}/node-packages/node_modules" "${APP_DIR}/"

pushd "${ROOT_PATH}/"

node-packages/node_modules/.bin/webpack

popd

rm -rf "${ROOT_PATH}/node-packages/node_modules"

# => now we have node_modules, and $ROOT_PATH/src/public/dist/frontend_bundle.js
# <=> $NIX_CODETRACER_EXE_DIR/public/dist/frontend_bundle.js

echo "==========="
