#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$CODETRACER_PREFIX` and cargo/rust + nim installed
#
# The WebAssembly plugin host (Extensibility-Model.md §11.9), into the
# AppImage's bin/: the desktop and `ct host` find it under the prefix
# (src/common/plugin_host_path.nim).

set -e

echo "==========="
echo "codetracer build: build ct-plugin-host"
echo "-----------"

bash "$ROOT_PATH/src/plugin-host/build.sh" --engine wasmi --out "${CODETRACER_PREFIX}/bin"

echo "==========="
