#!/usr/bin/env bash

APP_DIR="${APP_DIR:-.}"
RUST_VERSION="${RUST_VERSION:-1.87}"

export CARGO_HOME="${APP_DIR}/usr"
export RUSTUP_HOME="${CARGO_HOME}/rustup"

# If you are using NixOS, this won't work. Use docker with normal distro or figure it out, idk.
# This probaly isn't your first time dealing with this. Probably won't be your last! Keep Yourself Positive for Nix 🙃
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- --verbose -y --profile minimal --default-toolchain "${RUST_VERSION}" --no-modify-path
CARGO_BIN="${CARGO_HOME}/bin"

RUSTUP="${CARGO_BIN}/rustup"
${RUSTUP} target add wasm32-unknown-unknown

RUSTC="${CARGO_BIN}/rustc"
CARGO="${CARGO_BIN}/cargo"

echo "${RUSTUP}"
echo "${RUSTC}"
echo "${CARGO}"
