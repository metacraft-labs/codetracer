#!/usr/bin/env bash
set -e

# Ensure icons are available for electron-builder
iconutil -c icns "$ROOT_DIR/resources/Icon.iconset" --output "$ROOT_DIR/resources/CodeTracer.icns"

# Build the macOS application using electron-builder
pushd "$ROOT_DIR/node-packages" >/dev/null
npx electron-builder --mac dir
popd >/dev/null

# Place the resulting .app where the DMG builder expects it
rm -rf "$ROOT_DIR/non-nix-build/CodeTracer.app"
cp -R "$ROOT_DIR/node-packages/dist/mac/CodeTracer.app" "$ROOT_DIR/non-nix-build/CodeTracer.app"
