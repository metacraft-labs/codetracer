#!/usr/bin/env bash
#
# Regenerate the rust/simple_trivial_chain Value Origin fixture.
#
# Native-binary recording via the native recorder; `rustc -g -O0`
# preserves enough DWARF for the classifier to see each `let` binding.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"

RUSTC="${RUSTC:-rustc}"
"$RUSTC" -g -C opt-level=0 -o "$BUILD_DIR/main" main.rs

RECORDER="${CODETRACER_NATIVE_RECORDER:-codetracer-native-recorder}"
# TODO(M11): native-recorder materialized record path not yet wired.
exec "$RECORDER" record --out-dir "$OUT_DIR" -- "$BUILD_DIR/main"
