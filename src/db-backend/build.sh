#!/usr/bin/env bash

# your sysroot layout: wasm-sysroot/{include,lib,...}
SYSROOT="$(pwd)/wasm-sysroot"

echo "SYSROOT: ${SYSROOT}"

# make sure we use LLVM tools for wasm C/AR
export CC_wasm32_unknown_unknown=/usr/bin/clang
export AR_wasm32_unknown_unknown=/usr/bin/llvm-ar

# minimal flags: use your sysroot and the wasm target
# export CFLAGS_wasm32_unknown_unknown="--target=wasm32 --sysroot=$SYSROOT -isystem $SYSROOT/include -Wno-unused-command-line-argument"
export CPPFLAGS_wasm32_unknown_unknown="--target=wasm32 --sysroot=$SYSROOT -isystem $SYSROOT/include"
export CFLAGS_wasm32_unknown_unknown="-I$(pwd)/wasm-sysroot/include -DNDEBUG -Wbad-function-cast -Wcast-function-type -fno-builtin"

# build (just your crate, or the specific package)
cargo build --target wasm32-unknown-unknown --release

wasm-pack build --target web --release
