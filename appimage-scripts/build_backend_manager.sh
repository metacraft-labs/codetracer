#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$NIX_CODETRACER_EXE_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build backend-manager"
echo "-----------"

pushd "$ROOT_PATH/src/backend-manager"
cargo build --release
popd

cp -rL "$ROOT_PATH/src/backend-manager/target/release/backend-manager" "${NIX_CODETRACER_EXE_DIR}/bin/backend-manager"

echo "==========="
