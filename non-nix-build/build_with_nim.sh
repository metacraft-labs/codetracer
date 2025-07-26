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

# codetracer
nim -d:release \
    -d:asyncBackend=asyncdispatch \
    --passL:"-headerpad_max_install_names" \
    --gc:refc --hints:on --warnings:off \
    --debugInfo --lineDir:on \
    --boundChecks:on --stacktrace:on --linetrace:on \
    -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
    -d:chronicles_timestamps=UnixTime \
    -d:ctTest -d:ssl -d:testing "--hint[XDeclaredButNotUsed]:off" \
    -d:libcPath=libc \
    -d:useLibzipSrc \
    -d:builtWithNix \
    -d:ctEntrypoint \
    --nimcache:nimcache \
    -d:ctmacos \
    --out:"$DIST_DIR/bin/ct" c ./src/ct/codetracer.nim

install_name_tool \
  -add_rpath "@executable_path/../../Frameworks" \
  "${DIST_DIR}/bin/ct"

install_name_tool -add_rpath "@loader_path" "${DIST_DIR}/bin/ct"

codesign -s - --force --deep "${DIST_DIR}/bin/ct"

nim -d:release \
    -d:asyncBackend=asyncdispatch \
    --passL:"-headerpad_max_install_names" \
    --gc:refc --hints:on --warnings:off \
    --debugInfo --lineDir:on \
    --boundChecks:on --stacktrace:on --linetrace:on \
    -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
    -d:chronicles_timestamps=UnixTime \
    -d:ctTest -d:ssl -d:testing "--hint[XDeclaredButNotUsed]:off" \
    -d:libcPath=libc \
    -d:useLibzipSrc \
    -d:builtWithNix \
    -d:ctEntrypoint \
    --nimcache:nimcache \
    -d:ctmacos \
    --out:"$DIST_DIR/bin/db-backend-record" c ./src/ct/db_backend_record.nim

install_name_tool \
  -add_rpath "@executable_path/../../Frameworks" \
  "${DIST_DIR}/bin/db-backend-record"

codesign -s - --force --deep "${DIST_DIR}/bin/db-backend-record"

# this works    --passL:/nix/store/f6afb4jw9g5f94ixw0jn6cl0ah4liy35-sqlite-3.45.3/lib/libsqlite3.so.0 \

    # TODO conditional for nixos?--passL:$LIBSQLITE3_PATH


# index.js
nim \
    --hints:on --warnings:off --sourcemap:on \
    -d:ctIndex -d:chronicles_sinks=json \
    -d:ctmacos \
    -d:nodejs --out:"$DIST_DIR/index.js" js src/frontend/index.nim
cp "$DIST_DIR/index.js" "$DIST_DIR/src/index.js"

# ui.js
nim \
    --hints:off --warnings:off \
    -d:chronicles_enabled=off  \
    -d:ctRenderer \
    -d:ctmacos \
    --out:"$DIST_DIR/ui.js" js src/frontend/ui_js.nim
cp "$DIST_DIR/ui.js" "$DIST_DIR/src/ui.js"

# subwindow.js
nim \
    --hints:off --warnings:off \
    -d:chronicles_enabled=off  \
    -d:ctRenderer \
    -d:ctmacos \
    --out:"$DIST_DIR/subwindow.js" js src/frontend/subwindow.nim
cp "$DIST_DIR/subwindow.js" "$DIST_DIR/src/subwindow.js"

echo "==========="
