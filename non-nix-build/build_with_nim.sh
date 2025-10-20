#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR`
#   and nim 1.6 installed
#   and valid env `$LIBSQLITE3_PATH` at least for nixos

set -e

export GIT_ROOT=$(git rev-parse --show-toplevel)

brew install libzip

echo "==========="
echo "codetracer build: build based on nim"
echo "==========="

# TODO: The defines pointing to directories should be investigated.
#       Such defines are reasonable only for loading resources at
#       compile-time. The paths should not be used for making any
#       run-time decisions.

tools/build/build_codetracer.sh \
    --target ct \
    --profile release \
    --output "$DIST_DIR/bin/ct" \
    --extra-flag "--passL:-headerpad_max_install_names" \
    --extra-define libcPath=libc \
    --extra-define useLibzipSrc \
    --extra-define builtWithNix \
    --extra-define ctmacos \
    --extra-define ssl

install_name_tool \
  -add_rpath "@executable_path/../../Frameworks" \
  "${DIST_DIR}/bin/ct"

install_name_tool -add_rpath "@loader_path" "${DIST_DIR}/bin/ct"

codesign -s - --force --deep "${DIST_DIR}/bin/ct"

tools/build/build_codetracer.sh \
    --target db-backend-record \
    --profile release \
    --output "$DIST_DIR/bin/db-backend-record" \
    --extra-flag "--passL:-headerpad_max_install_names" \
    --extra-define libcPath=libc \
    --extra-define useLibzipSrc \
    --extra-define builtWithNix \
    --extra-define ctmacos \
    --extra-define ssl

install_name_tool \
  -add_rpath "@executable_path/../../Frameworks" \
  "${DIST_DIR}/bin/db-backend-record"

codesign -s - --force --deep "${DIST_DIR}/bin/db-backend-record"

# this works    --passL:/nix/store/f6afb4jw9g5f94ixw0jn6cl0ah4liy35-sqlite-3.45.3/lib/libsqlite3.so.0 \

    # TODO conditional for nixos?--passL:$LIBSQLITE3_PATH


# index.js
tools/build/build_codetracer.sh \
    --target js:index \
    --profile release \
    --output "$DIST_DIR/index.js" \
    --extra-define ctmacos \
    --extra-define pathToNodeModules=../node_modules
cp "$DIST_DIR/index.js" "$DIST_DIR/src/index.js"

# ui.js
tools/build/build_codetracer.sh \
    --target js:ui \
    --profile release \
    --output "$DIST_DIR/ui.js" \
    --extra-define ctmacos
cp "$DIST_DIR/ui.js" "$DIST_DIR/src/ui.js"

# subwindow.js
tools/build/build_codetracer.sh \
    --target js:subwindow \
    --profile release \
    --output "$DIST_DIR/subwindow.js" \
    --extra-define ctmacos
cp "$DIST_DIR/subwindow.js" "$DIST_DIR/src/subwindow.js"

echo "==========="
