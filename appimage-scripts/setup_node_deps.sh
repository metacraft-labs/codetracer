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

# Build the Electron entry script so electron-builder has something to package
nim \
    --hints:on --warnings:off --sourcemap:on \
    -d:ctIndex -d:chronicles_sinks=json \
    -d:nodejs --out:index.js ../src/frontend/index.nim

popd

cp -Lr "${ROOT_PATH}/node-packages/node_modules" "${APP_DIR}/"

pushd "${ROOT_PATH}/"

node-packages/node_modules/.bin/webpack

popd
# => now we have node_modules and $ROOT_PATH/src/public/dist/frontend_bundle.js
# <=> $NIX_CODETRACER_EXE_DIR/public/dist/frontend_bundle.js

echo "==========="
