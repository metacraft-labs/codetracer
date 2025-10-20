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


    # --passL:"${APP_DIR}/lib/libsqlite3.so.0" \

# codetracer
tools/build/build_codetracer.sh \
    --target ct \
    --profile release \
    --output "${APP_DIR}/bin/ct_unwrapped" \
    --extra-define builtWithNix \
    --extra-define linksPathConst=.. \
    --extra-define libcPath=libc \
    --extra-define pathToNodeModules=../node_modules \
    --extra-flag "--dynlibOverride:std" \
    --extra-flag "-d:staticStd" \
    --extra-flag "--dynlibOverride:sqlite3" \
    --extra-flag "--dynlibOverride:pcre" \
    --extra-flag "--dynlibOverride:libzip" \
    --extra-flag "--dynlibOverride:libcrypto" \
    --extra-flag "--dynlibOverride:libssl" \
    --extra-flag "--passL:-Wl,-Bstatic -lsqlite3 -Wl,-Bdynamic" \
    --extra-flag "--passL:${APP_DIR}/lib/libpcre.so.1" \
    --extra-flag "--passL:${APP_DIR}/lib/libzip.so.5" \
    --extra-flag "--passL:${APP_DIR}/lib/libcrypto.so" \
    --extra-flag "--passL:${APP_DIR}/lib/libcrypto.so.3" \
    --extra-flag "--passL:${APP_DIR}/lib/libssl.so"

tools/build/build_codetracer.sh \
    --target db-backend-record \
    --profile release \
    --output "${APP_DIR}/bin/db-backend-record" \
    --extra-define builtWithNix \
    --extra-define linksPathConst=.. \
    --extra-define libcPath=libc \
    --extra-flag "--dynlibOverride:libsqlite3" \
    --extra-flag "--dynlibOverride:sqlite3" \
    --extra-flag "--dynlibOverride:pcre" \
    --extra-flag "--dynlibOverride:libzip" \
    --extra-flag "--passL:-Wl,-Bstatic -lsqlite3 -Wl,-Bdynamic" \
    --extra-flag "--passL:${APP_DIR}/lib/libpcre.so.1" \
    --extra-flag "--passL:${APP_DIR}/lib/libzip.so.5"

# index.js bundles
tools/build/build_codetracer.sh \
    --target js:index \
    --profile release \
    --output "${APP_DIR}/index.js" \
    --extra-define pathToNodeModules=../node_modules
cp "${APP_DIR}/index.js" "${APP_DIR}/src/index.js"

tools/build/build_codetracer.sh \
    --target js:server-index \
    --profile release \
    --output "${APP_DIR}/server_index.js" \
    --extra-define pathToNodeModules=../node_modules
cp "${APP_DIR}/server_index.js" "${APP_DIR}/src/server_index.js"

# renderer bundles
tools/build/build_codetracer.sh \
    --target js:ui \
    --profile release \
    --output "${APP_DIR}/ui.js"
cp "${APP_DIR}/ui.js" "${APP_DIR}/src/ui.js"

tools/build/build_codetracer.sh \
    --target js:subwindow \
    --profile release \
    --output "${APP_DIR}/subwindow.js"
cp "${APP_DIR}/subwindow.js" "${APP_DIR}/src/subwindow.js"

popd

echo "==========="
