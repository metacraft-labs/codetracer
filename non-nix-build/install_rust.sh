#!/usr/bin/env bash

set -e

WANTED_RUST_VERSION="1.87.0-nightly" # This should be relaxed a bit somehow

if command -v rustc &> /dev/null; then
  RUST_VERSION=$(rustc --version | cut -d' ' -f2)
  if [ "$RUST_VERSION" == "$WANTED_RUST_VERSION" ]; then
    echo "Rust $RUST_VERSION is already installed"
    exit 0
  else
    echo "Rust $RUST_VERSION present, but we need $WANTED_RUST_VERSION! installing..."
  fi
else
  echo rust is missing! installing...
fi

: "${DEPS_DIR:=$PWD/deps}"

export RUSTUP_INIT_SKIP_PATH_CHECK=yes

curl --proto '=https' --tlsv1.2 -sf https://sh.rustup.rs | sh -s -- --no-modify-path -y --default-toolchain nightly

source "$CARGO_HOME"/env # adds rustc to our PATH

