#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$NIX_CODETRACER_EXE_DIR`
#   and nim 1.6 installed
#   and valid env `$LIBSQLITE3_PATH` at least for nixos

set -e

echo "==========="
echo "codetracer build: build based on nim"
echo "-----------"

pushd "$ROOT_PATH"

echo "links path const:"
echo "${APP_DIR}"

# codetracer
nim -d:release \
    --d:asyncBackend=asyncdispatch \
    --dynlibOverride:std -d:staticStd \
    --gc:refc --hints:on --warnings:off \
    --dynlibOverride:"sqlite3" \
    --dynlibOverride:"pcre" \
    --dynlibOverride:"libzip" \
    --dynlibOverride:"libssl" \
    --passL:"${APP_DIR}/lib/libsqlite3.so.0" \
    --passL:"${APP_DIR}/lib/libpcre.so.1" \
    --passL:"${APP_DIR}/lib/libzip.so.5" \
    --passL:"${APP_DIR}/lib/libssl.so.3" \
    --boundChecks:on \
    -d:chronicles_sinks=json -d:chronicles_line_numbers=true \
    -d:chronicles_timestamps=UnixTime \
    -d:ctTest -d:testing --hint"[XDeclaredButNotUsed]":off \
    -d:builtWithNix \
    -d:ctEntrypoint \
    -d:linksPathConst=.. \
    -d:libcPath=libc \
    -d:pathToNodeModules=../node_modules \
    --nimcache:nimcache \
    --out:"${APP_DIR}/bin/ct_unwrapped" c ./src/ct/codetracer.nim



    # --passL:"-lsqlite3" \
    #--passL:"${APPDIR}/lib/libcrypto.so.3" \
    #--passL:"${APPDIR}/lib/libssl.so.3" \
    # --passL:"${APP_DIR}/lib/libz.so.1" \

# this works    --passL:/nix/store/f6afb4jw9g5f94ixw0jn6cl0ah4liy35-sqlite-3.45.3/lib/libsqlite3.so.0 \

    # TODO conditional for nixos?--passL:$LIBSQLITE3_PATH
    #
# patchelf --set-rpath ${APP_DIR}/lib ${APP_DIR}/bin/ct


# index.js
nim \
    --hints:on --warnings:off --sourcemap:on \
    -d:ctIndex -d:chronicles_sinks=json \
    -d:nodejs --out:"${APP_DIR}/index.js" js src/frontend/index.nim
cp "${APP_DIR}/index.js" "${APP_DIR}/src/index.js"

# ui.js
nim \
    --hints:off --warnings:off \
    -d:chronicles_enabled=off  \
    -d:ctRenderer \
    --out:"${APP_DIR}/ui.js" js src/frontend/ui_js.nim
cp "${APP_DIR}/ui.js" "${APP_DIR}/src/ui.js"

# subwindow.js
nim \
    --hints:off --warnings:off \
    -d:chronicles_enabled=off  \
    -d:ctRenderer \
    --out:"${APP_DIR}/subwindow.js" js src/frontend/subwindow.nim
cp "${APP_DIR}/subwindow.js" "${APP_DIR}/src/subwindow.js"

popd

echo "==========="
