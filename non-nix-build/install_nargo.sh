#!/usr/bin/env bash

set -e

WANTED_NARGO_REVISION=e47c24d418436e6c0cf148b16477efc31bbaad5c

if command -v nargo &> /dev/null; then
  echo nargo is already installed
  exit 0
else
  echo nargo is missing! building...
fi

: ${DEPS_DIR:=$PWD/deps}
cd "$DEPS_DIR"

rm -rf noir
git clone https://github.com/metacraft-labs/noir
cd noir
git checkout $WANTED_NARGO_REVISION
cargo build --release
cp ./target/release/nargo $BIN_DIR/

