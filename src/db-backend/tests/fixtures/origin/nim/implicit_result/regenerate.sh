#!/usr/bin/env bash
#
# Regenerate the nim/implicit_result Value Origin fixture.
#
# ``nim c -d:debug --debugger:native`` keeps optimisations off and emits
# DWARF so the classifier can see the textual variable bindings; the
# native recorder then records the resulting binary.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"

NIM="${NIM:-nim}"
"$NIM" c -d:debug --debugger:native --opt:none -o:"$BUILD_DIR/main" main.nim

RECORDER="${CODETRACER_NATIVE_RECORDER:-codetracer-native-recorder}"
exec "$RECORDER" record --out-dir "$OUT_DIR" -- "$BUILD_DIR/main"
