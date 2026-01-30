#!/usr/bin/env bash
set -e

cd "$DIST_DIR"

mkdir -p "$DIST_DIR"/../Resources/
iconutil -c icns "$ROOT_DIR"/resources/Icon.iconset --output "$DIST_DIR"/../Resources/CodeTracer.icns

YEAR=$(grep "CodeTracerYear\*" "$ROOT_DIR"/src/ct/version.nim | sed "s/.*CodeTracerYear\* = //g")
MONTH=$(printf '%02d' "$(grep "CodeTracerMonth\*" "$ROOT_DIR"/src/ct/version.nim | sed "s/.*CodeTracerMonth\* = //g")")
BUILD=$(grep "CodeTracerBuild\*" "$ROOT_DIR"/src/ct/version.nim | sed "s/.*CodeTracerBuild\* = //g")

# macOS uses core utils from FreeBSD so the additional "" is needed to execute this sed call.
sed -i "" "s/CFBundleShortVersionString.*/CFBundleShortVersionString<\/key><string>$YEAR.$MONTH.$BUILD<\/string>/g" "$ROOT_DIR"/resources/Info.plist
sed -i "" "s/CFBundleVersion.*/CFBundleVersion<\/key><string>$YEAR.$MONTH.$BUILD<\/string>/g" "$ROOT_DIR"/resources/Info.plist

cp "$ROOT_DIR"/resources/Info.plist "$DIST_DIR"/..

# In the `public` folder, we have some symlinks to this awkwardly placed directory
cd "$DIST_DIR"/..
ln -s MacOS/node_modules ./

# Hack because basically every OS-level string is labeled as Electron instead CodeTracer. Can be resolved by using a bundler
cp "$ROOT_DIR"/resources/Info.plist "$(realpath MacOS/node_modules)"/electron/dist/Electron.app/Contents/Info.plist
cp "$DIST_DIR"/../Resources/CodeTracer.icns "$(realpath MacOS/node_modules)"/electron/dist/Electron.app/Contents/Resources/

# macOS uses core utils from FreeBSD so the additional "" is needed to execute this sed call.
#
# This sed call is needed because even though we replaced the entire plist file, the CodeTracer icon will not be displayed correctly
# in the auto-generated about menu, if the correct executable isn't listed here. If it was left as "bin/ct" a big disabled icon would
# be overlayed on top of the app icon
sed -i "" "s/\<string\>bin\/ct/\<string\>Electron/g" "$(realpath MacOS/node_modules)"/electron/dist/Electron.app/Contents/Info.plist
