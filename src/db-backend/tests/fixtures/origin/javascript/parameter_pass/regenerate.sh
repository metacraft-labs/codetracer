#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"
RECORDER="${CODETRACER_JS_RECORDER:-codetracer-js-recorder}"
# TODO(M3): wire `--origin-patterns-include` once project-pattern files land.
"$RECORDER" instrument --out-dir "$BUILD_DIR" main.js
exec "$RECORDER" record --out-dir "$OUT_DIR" -- "$BUILD_DIR/main.js"
