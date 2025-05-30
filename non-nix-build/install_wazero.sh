#!/usr/bin/env bash

set -e

WANTED_WAZERO_REVISION=5518cc044b584963d6494100371875f3422242f3

: ${DEPS_DIR:=$PWD/deps}
cd "$DEPS_DIR"

rm -rf codetracer-wasm-recorder
git clone https://github.com/metacraft-labs/codetracer-wasm-recorder.git
cd codetracer-wasm-recorder
git checkout $WANTED_WAZERO_REVISION
go build cmd/wazero/wazero.go
cp ./wazero $BIN_DIR/

