#!/usr/bin/env bash

# build_for_extension.sh <ui_js_output_path> <ct_vscode_js_output_path> <db_backend_path>
set -e

tools/build/build_codetracer.sh \
  --target js:ui \
  --output "$1" \
  --extra-define ctInExtension

tools/build/build_codetracer.sh \
  --target js:middleware \
  --output "$2" \
  --extra-define ctInExtension \
  --extra-define ctInCentralExtensionContext

just build-once

cd ./src/db-backend
cargo build
cd ../..
mv ./src/db-backend/target/debug/db-backend "$3"
