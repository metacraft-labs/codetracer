#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$CODETRACER_PREFIX`
# and node_modules setup

set -e

echo "==========="
echo "codetracer build: build css"
echo "-----------"

pushd "$ROOT_PATH"

mkdir -p "$CODETRACER_PREFIX/frontend/styles/"
stylus=$ROOT_PATH/node_modules/.bin/stylus
node "$stylus" -o "$CODETRACER_PREFIX/frontend/styles/" src/frontend/styles/default_white_theme.styl
node "$stylus" -o "$CODETRACER_PREFIX/frontend/styles/" src/frontend/styles/default_dark_theme_electron.styl
node "$stylus" -o "$CODETRACER_PREFIX/frontend/styles/" src/frontend/styles/loader.styl
node "$stylus" -o "$CODETRACER_PREFIX/frontend/styles/" src/frontend/styles/subwindow.styl

popd

echo "==========="
