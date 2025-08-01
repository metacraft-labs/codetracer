#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$NIX_CODETRACER_EXE_DIR`
# and node_modules setup

set -e

echo "==========="
echo "codetracer build: build css"
echo "-----------"

pushd "$ROOT_PATH"

mkdir -p "$NIX_CODETRACER_EXE_DIR/frontend/styles/"
stylus=$ROOT_PATH/node_modules/.bin/stylus
node "$stylus" -o "$NIX_CODETRACER_EXE_DIR/frontend/styles/" src/frontend/styles/default_white_theme.styl
node "$stylus" -o "$NIX_CODETRACER_EXE_DIR/frontend/styles/" src/frontend/styles/default_dark_theme_electron.styl
node "$stylus" -o "$NIX_CODETRACER_EXE_DIR/frontend/styles/" src/frontend/styles/loader.styl
node "$stylus" -o "$NIX_CODETRACER_EXE_DIR/frontend/styles/" src/frontend/styles/subwindow.styl

popd

echo "==========="
