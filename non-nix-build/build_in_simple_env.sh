#!/usr/bin/env bash

set -e

# setup env (based on nix/shells/main.nix):

export CODETRACER_BUILD_PLATFORM="$1"
export CODETRACER_BUILD_OS="$2"

# =========================================

rm -rf "$DIST_DIR"
rm -rf "$ROOT_DIR/non-nix-build/CodeTracer.app"

mkdir -p $DIST_DIR/bin
mkdir -p $DIST_DIR/src

# setup node deps
bash setup_node_deps.sh

# build our css files
bash build_css.sh

cd $ROOT_DIR
# build/setup nim-based files
bash ./non-nix-build/build_with_nim.sh

cd non-nix-build

# build/setup db-backend
bash build_db_backend.sh

# for now just put them in src/
#   not great, but much easier for now as the public/static files
#   are just there, no need for special copying/linking
#   however it would be best to link to them in a separate tup-like
#   src/build-debug!

# setup/copy/link other files
cp $ROOT_DIR/resources/electron $DIST_DIR/bin/
cp $(which ruby) $DIST_DIR/bin/ruby
cp $(which ctags) $DIST_DIR/bin/ctags
cp $ROOT_DIR/libs/codetracer-ruby-recorder/src/*.rb $DIST_DIR/src/
cp $ROOT_DIR/src/helpers.js $DIST_DIR/src/helpers.js
cp $ROOT_DIR/src/helpers.js $DIST_DIR/helpers.js
cp $ROOT_DIR/src/frontend/*.html $DIST_DIR/src/
cp $ROOT_DIR/src/frontend/*.html $DIST_DIR/
rm -f $DIST_DIR/config
rm -f $DIST_DIR/public
cp -r $ROOT_DIR/config $DIST_DIR/config
cp -r $ROOT_DIR/src/public $DIST_DIR/public
cp $BIN_DIR/nargo $DIST_DIR/bin/

