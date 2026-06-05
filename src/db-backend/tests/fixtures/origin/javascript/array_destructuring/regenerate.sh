#!/usr/bin/env bash
# Regenerate the javascript/array_destructuring Value Origin fixture.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"
RECORDER="${CODETRACER_JS_RECORDER:-codetracer-js-recorder}"
"$RECORDER" instrument --out-dir "$BUILD_DIR" main.js
exec "$RECORDER" record --out-dir "$OUT_DIR" -- "$BUILD_DIR/main.js"
