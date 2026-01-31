#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$NIX_CODETRACER_EXE_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build db-backend"
echo "-----------"

pushd "$ROOT_PATH/src/db-backend"
cargo build --release
popd

cp -rL "$ROOT_PATH/src/db-backend/target/release/db-backend" "${NIX_CODETRACER_EXE_DIR}/bin/db-backend"

echo "==========="
