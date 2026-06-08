#!/usr/bin/env bash

# depends on env `$ROOT_DIR` and `$DIST_DIR` and cargo/rust installed

set -e

echo "==========="
echo "codetracer build: build backend-manager"
echo "-----------"

pushd "$ROOT_DIR/src/backend-manager"
cargo build --release
# 2026: backend-manager was renamed to session-manager in commit
# 056d229c.  src/common/paths.nim:178 now looks up
# ``bin/session-manager``; mirror the appimage script.
cp "target/release/session-manager" "$DIST_DIR/bin/session-manager"
popd

echo "==========="
