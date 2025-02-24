#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR`
# and node_modules setup

set -e

echo "==========="
echo "codetracer build: build css"
echo "-----------"

pushd "$ROOT_DIR"

mkdir -p "$DIST_DIR/frontend/styles/"
stylus="$ROOT_DIR/node_modules/.bin/stylus"
node $stylus -o "$DIST_DIR/frontend/styles/" src/frontend/styles/default_white_theme.styl
node $stylus -o "$DIST_DIR/frontend/styles/" src/frontend/styles/default_dark_theme.styl
node $stylus -o "$DIST_DIR/frontend/styles/" src/frontend/styles/loader.styl
node $stylus -o "$DIST_DIR/frontend/styles/" src/frontend/styles/subwindow.styl

popd

echo "==========="
