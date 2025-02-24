#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build db-backend"
echo "-----------"


pushd "$ROOT_DIR/src/db-backend"
cargo build --release
cp "$ROOT_DIR/src/db-backend/target/release/db-backend" "$DIST_DIR/bin/db-backend"
popd

echo "==========="
