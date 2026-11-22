#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR` and cargo/rust + nim installed
#
# The WebAssembly plugin host (Extensibility-Model.md §11.9), into the
# bundle's bin/: the front-ends find it there (src/common/plugin_host_path.nim).

set -e

echo "==========="
echo "codetracer build: build ct-plugin-host"
echo "-----------"

bash "$ROOT_DIR/src/plugin-host/build.sh" --engine wasmi --out "$DIST_DIR/bin"

echo "==========="
