#!/usr/bin/env bash

set -e

WANTED_NARGO_REVISION=ad2f0701d32edb91592fcca37ce98d3c491cde77

if command -v nargo &> /dev/null; then
  echo nargo is already installed
  exit 0
else
  echo nargo is missing! building...
fi

: ${DEPS_DIR:=$PWD/deps}
cd "$DEPS_DIR"

rm -rf noir
git clone https://github.com/blocksense-network/noir
cd noir
git checkout $WANTED_NARGO_REVISION
cargo build --release
cp ./target/release/nargo $BIN_DIR/

