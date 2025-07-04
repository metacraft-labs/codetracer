#!/usr/bin/env bash

# build_extension_files.sh <ui_js_output_path> <ct_vscode_js_output_path>
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
