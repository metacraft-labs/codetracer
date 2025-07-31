#!/usr/bin/env bash

# build_for_extension.sh <ui_js_output_path> <ct_vscode_js_output_path> <db_backend_path>
set -e

nim \
    -d:chronicles_enabled=off \
    -d:ctRenderer \
    -d:ctInExtension \
    --debugInfo:on \
    --lineDir:on \
    --hotCodeReloading:on \
    --out:"$1" \
    js src/frontend/ui_js.nim

nim \
  -d:ctInExtension \
  -d:ctInCentralExtensionContext \
  --out:"$2" \
  js src/frontend/middleware.nim

just build-once

cd ./src/db-backend
cargo build
cd ../..
mv ./src/db-backend/target/debug/db-backend "$3"
