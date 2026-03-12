#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$CODETRACER_PREFIX` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build db-backend"
echo "-----------"

pushd "$ROOT_PATH/src/db-backend"
cargo build --release
popd

cp -rL "$ROOT_PATH/src/db-backend/target/release/db-backend" "${CODETRACER_PREFIX}/bin/db-backend"

echo "==========="
