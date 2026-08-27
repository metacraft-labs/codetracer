#!/usr/bin/env bash

# build_for_extension.sh <ui_js_output_path> <ct_vscode_js_output_path> <db_backend_path>
set -e

# `--hotCodeReloading:on` must not be added here: on the JS backend it makes
# distinct routines collide onto one function name inside the single-scope
# bundle (see the note on `ctNimJs` in repro.nim), which takes the renderer
# down at startup.  `src/frontend/tests/renderer_js_symbol_uniqueness_test.nim`
# fails if it comes back.
nim \
	-d:chronicles_enabled=off \
	-d:ctRenderer \
	-d:ctInExtension \
	--debugInfo:on \
	--lineDir:on \
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
