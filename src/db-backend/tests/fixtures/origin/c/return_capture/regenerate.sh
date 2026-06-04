#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"
CC="${CC:-gcc}"
"$CC" -O0 -g -no-pie -o "$BUILD_DIR/main" main.c
RECORDER="${CODETRACER_NATIVE_RECORDER:-codetracer-native-recorder}"
# TODO(M11): native-recorder materialized record path not yet wired.
exec "$RECORDER" record --out-dir "$OUT_DIR" -- "$BUILD_DIR/main"
