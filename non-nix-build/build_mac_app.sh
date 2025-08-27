#!/usr/bin/env bash
set -e

ROOT_DIR=$(git rev-parse --show-toplevel)

# Ensure icons are available for electron-builder
iconutil -c icns "$ROOT_DIR/resources/Icon.iconset" --output "$ROOT_DIR/resources/CodeTracer.icns"

# Install dependencies and build entry script
pushd "$ROOT_DIR/node-packages" >/dev/null
yarn install >/dev/null
nim \
    --hints:on --warnings:off --sourcemap:on \
    -d:ctIndex -d:chronicles_sinks=json \
    -d:nodejs --out:index.js js ../src/frontend/index.nim
npx electron-builder --mac dir
popd >/dev/null

# Place the resulting .app where the DMG builder expects it
rm -rf "$ROOT_DIR/non-nix-build/CodeTracer.app"
cp -R "$ROOT_DIR/node-packages/dist/mac/CodeTracer.app" "$ROOT_DIR/non-nix-build/CodeTracer.app"
