#!/usr/bin/env bash
set -e

# Define the absolute path to the non-nix-build directory to ensure paths are correct
NON_NIX_BUILD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The final output directory for the .app bundle
APP_DIR="$NON_NIX_BUILD_DIR"/CodeTracer.app

# 1. Start with a clean Electron app
ELECTRON_APP_PATH="$ROOT_DIR"/node_modules/electron/dist/Electron.app
rm -rf "$APP_DIR"
cp -R "$ELECTRON_APP_PATH" "$APP_DIR"
mv "$APP_DIR"/Contents/MacOS/Electron "$APP_DIR"/Contents/MacOS/CodeTracer

# 2. Create the app resources directory
RESOURCES_DIR="$APP_DIR"/Contents/Resources
APP_RESOURCES_DIR="$RESOURCES_DIR"/app
mkdir -p "$APP_RESOURCES_DIR"

# 3. Copy our application source code and assets from the build dir
# The DIST_DIR (e.g., non-nix-build/dist_macos) contains all the compiled assets
cp -R "$DIST_DIR"/* "$APP_RESOURCES_DIR"/

# 4. Rebrand the app
INFO_PLIST="$APP_DIR"/Contents/Info.plist

# Set the executable name
plutil -replace CFBundleExecutable -string "CodeTracer" "$INFO_PLIST"

# Set the app name and display name
plutil -replace CFBundleName -string "CodeTracer" "$INFO_PLIST"
plutil -replace CFBundleDisplayName -string "CodeTracer" "$INFO_PLIST"

# Set the bundle identifier
plutil -replace CFBundleIdentifier -string "com.codetracer.CodeTracer" "$INFO_PLIST"

# Set the icon
iconutil -c icns "$ROOT_DIR"/resources/Icon.iconset --output "$RESOURCES_DIR"/CodeTracer.icns
plutil -replace CFBundleIconFile -string "CodeTracer.icns" "$INFO_PLIST"

echo "Successfully created and rebranded CodeTracer.app"
