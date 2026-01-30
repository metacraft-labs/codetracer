#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build db-backend"
echo "-----------"

# Generate tree-sitter-nim parser if needed (parser.c is gitignored)
TREE_SITTER_NIM_DIR="$ROOT_DIR/libs/tree-sitter-nim"
if [ -d "$TREE_SITTER_NIM_DIR" ]; then
  echo "Ensuring tree-sitter-nim parser is generated..."
  pushd "$TREE_SITTER_NIM_DIR"

  # Install tree-sitter CLI if not available
  if ! command -v tree-sitter &> /dev/null; then
    echo "Installing tree-sitter CLI..."
    npm install
  fi

  # Generate parser if missing or outdated (mirrors Justfile logic)
  if [ ! -f "src/parser.c" ]; then
    echo "parser.c doesn't exist, generating..."
    npx tree-sitter generate
  elif [ "grammar.js" -nt "src/parser.c" ]; then
    echo "grammar.js is newer than parser.c, regenerating..."
    npx tree-sitter generate
  else
    echo "parser.c is up to date"
  fi

  popd
fi

pushd "$ROOT_DIR/src/db-backend"
cargo build --release
cp "$ROOT_DIR/src/db-backend/target/release/db-backend" "$DIST_DIR/bin/db-backend"
popd

echo "==========="
