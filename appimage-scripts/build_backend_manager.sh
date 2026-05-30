#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$CODETRACER_PREFIX` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build backend-manager"
echo "-----------"

pushd "$ROOT_PATH/src/backend-manager"
cargo build --release
popd

# 2026: the crate + binary were renamed from `backend-manager` to
# `session-manager` (matches Cargo.toml's `name` field and what the Nim
# launcher looks up via paths.nim:backendManagerExe).  The script
# filename keeps the legacy name to preserve build-pipeline ordering;
# only the binary path changed.
cp -rL "$ROOT_PATH/src/backend-manager/target/release/session-manager" "${CODETRACER_PREFIX}/bin/session-manager"

echo "==========="
