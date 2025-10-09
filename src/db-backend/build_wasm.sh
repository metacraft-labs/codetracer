#!/usr/bin/env bash

# your sysroot layout: wasm-sysroot/{include,lib,...}
SYSROOT="$(pwd)/wasm-sysroot"

echo "SYSROOT: ${SYSROOT}"

# make sure we use LLVM tools for wasm C/AR
export CC_wasm32_unknown_unknown=clang
export AR_wasm32_unknown_unknown=llvm-ar

cargo clean

# build (just your crate, or the specific package)
cargo build --target wasm32-unknown-unknown --release --no-default-features --features browser-transport

wasm-pack build --target web --release -d ./wasm-testing/pkg -- --no-default-features --features browser-transport
