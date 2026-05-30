#!/usr/bin/env bash

# depends on env `$ROOT_PATH` and `$CODETRACER_PREFIX` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build db-backend"
echo "-----------"

pushd "$ROOT_PATH/src/db-backend"
# `--features io-transport` is required by the [[bin]] declarations in
# src/db-backend/Cargo.toml (replay-server / virtualization-layers);
# without it Cargo builds just the crate library and no executables get
# emitted into target/release.
cargo build --release --features io-transport
popd

# 2026: the crate + binary were renamed from `db-backend` to
# `replay-server` (commit 056d229c, "Phase 4 naming alignment").  The Nim
# launcher in src/common/paths.nim looks up `bin/replay-server`, so we
# bundle under that name and let the legacy name stay retired.
cp -rL "$ROOT_PATH/src/db-backend/target/release/replay-server" "${CODETRACER_PREFIX}/bin/replay-server"

echo "==========="
