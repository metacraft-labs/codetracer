#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build db-backend"
echo "-----------"

# Generate tree-sitter-nim parser if needed (parser.c is gitignored)
bash "$ROOT_DIR/non-nix-build/ensure_tree_sitter_nim_parser.sh"

pushd "$ROOT_DIR/src/db-backend"
cargo build --release
cp "$ROOT_DIR/src/db-backend/target/release/db-backend" "$DIST_DIR/bin/db-backend"
popd

echo "==========="
