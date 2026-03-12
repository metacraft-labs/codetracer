#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$CODETRACER_PREFIX` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build backend-manager"
echo "-----------"

pushd "$ROOT_PATH/src/backend-manager"
cargo build --release
popd

cp -rL "$ROOT_PATH/src/backend-manager/target/release/backend-manager" "${CODETRACER_PREFIX}/bin/backend-manager"

echo "==========="
