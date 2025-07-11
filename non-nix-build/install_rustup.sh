#!/usr/bin/env bash

RUST_VERSION="${RUST_VERSION:-1.87}"

export CARGO_HOME="${DIST_DIR}/.."
export RUSTUP_HOME="${CARGO_HOME}/rustup"

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --verbose -y --profile minimal --default-toolchain "${RUST_VERSION}" --no-modify-path
CARGO_BIN="${CARGO_HOME}/bin"

RUSTUP="${CARGO_BIN}/rustup"
${RUSTUP} target add wasm32-unknown-unknown

RUSTC="${CARGO_BIN}/rustc"
CARGO="${CARGO_BIN}/cargo"
echo "${RUSTUP}"
echo "${RUSTC}"
echo "${CARGO}"
