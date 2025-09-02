#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build backend-manager"
echo "-----------"


pushd "$ROOT_DIR/src/backend-manager"
cargo build --release
cp "target/release/backend-manager" "$DIST_DIR/bin/backend-manager"
popd

echo "==========="
