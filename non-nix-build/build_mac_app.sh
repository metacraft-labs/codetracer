#!/usr/bin/env bash

cd $DIST_DIR

mkdir -p $DIST_DIR/../Resources/
iconutil -c icns $ROOT_DIR/resources/Icon.iconset --output $DIST_DIR/../Resources/CodeTracer.icns
cp $ROOT_DIR/resources/Info.plist $DIST_DIR/..

# In the `public` folder, we have some symlinks to this awkwardly placed directory
cd $DIST_DIR/..
ln -s MacOS/node_modules ./

# Hack because basically every OS-level string is labeled as Electron instead CodeTracer. Can be resolved by using a bundler
#
# Btw macOS uses the FreeBSD coreutils so sed -i has to be called with an empty string argument to work
sed -i "" "s/Electron/CodeTracer/g" "$(realpath MacOS/node_modules)"/electron/dist/Electron.app/Contents/Info.plist
