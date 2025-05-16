#!/usr/bin/env bash

set -e

WANTED_WAZERO_REVISION=e347615557a19e4cbf6ae210a0d745014613e4a0

: ${DEPS_DIR:=$PWD/deps}
cd "$DEPS_DIR"

rm -rf codetracer-wasm-recorder
git clone https://github.com/metacraft-labs/codetracer-wasm-recorder.git
cd codetracer-wasm-recorder
git checkout $WANTED_WAZERO_REVISION
go build cmd/wazero/wazero.go
cp ./wazero $BIN_DIR/

