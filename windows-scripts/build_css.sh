#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$NIX_CODETRACER_EXE_DIR`
# and node_modules setup

set -e

echo "==========="
echo "codetracer build: build css"
echo "-----------"

pushd "$GIT_ROOT"

mkdir -p "$NIX_CODETRACER_EXE_DIR/frontend/styles/"
stylus=$GIT_ROOT/node_modules/.bin/stylus
node "$stylus" -o "${APP_DIR}/frontend/styles/" src/frontend/styles/default_white_theme.styl
node "$stylus" -o "${APP_DIR}/frontend/styles/" src/frontend/styles/default_dark_theme.styl
node "$stylus" -o "${APP_DIR}/frontend/styles/" src/frontend/styles/loader.styl
node "$stylus" -o "${APP_DIR}/frontend/styles/" src/frontend/styles/subwindow.styl

popd

echo "==========="
