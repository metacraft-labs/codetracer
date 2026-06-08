#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build db-backend"
echo "-----------"

# Generate tree-sitter-nim parser if needed (parser.c is gitignored)
bash "$ROOT_DIR/non-nix-build/ensure_tree_sitter_nim_parser.sh"

pushd "$ROOT_DIR/src/db-backend"
# ``--features io-transport`` is required by the [[bin]] declarations in
# src/db-backend/Cargo.toml (replay-server / virtualization-layers);
# without it cargo builds just the crate library and no executables get
# emitted into target/release.
cargo build --release --features io-transport
# 2026: the crate + binary were renamed from ``db-backend`` to
# ``replay-server`` (commit 056d229c, "Phase 4 naming alignment").
# src/common/paths.nim:177 looks up ``bin/replay-server``, so bundle
# under the new name -- same fix appimage-scripts/build_db_backend.sh
# already shipped in commit 510673a5.
cp "$ROOT_DIR/src/db-backend/target/release/replay-server" "$DIST_DIR/bin/replay-server"
popd

echo "==========="
