#!/usr/bin/env bash
# Copy the built WASM module to the app directory for nginx serving.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PKG_SRC="$REPO_ROOT/src/db-backend/wasm-testing/pkg"
PKG_DST="$SCRIPT_DIR/app/pkg"

if [ ! -d "$PKG_SRC" ]; then
	echo "ERROR: WASM package not found at $PKG_SRC"
	echo "Run: cd src/db-backend && bash build_wasm.sh"
	exit 1
fi

mkdir -p "$PKG_DST"
cp "$PKG_SRC/db_backend.js" "$PKG_DST/"
cp "$PKG_SRC/db_backend_bg.wasm" "$PKG_DST/"
echo "Deployed WASM to $PKG_DST"
ls -la "$PKG_DST"
