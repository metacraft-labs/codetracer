#!/usr/bin/env bash
#
# Regenerate the go/simple_trivial_chain Value Origin fixture.
#
# `go build -gcflags=all=-N -l` disables optimisations and inlining so
# DWARF preserves the textual variable bindings the classifier needs;
# the native recorder then records the resulting binary.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"

GO="${GO:-go}"
"$GO" build -gcflags=all=-N\ -l -o "$BUILD_DIR/main" main.go

RECORDER="${CODETRACER_NATIVE_RECORDER:-codetracer-native-recorder}"
# TODO(M11): native-recorder materialized record path not yet wired for Go binaries.
exec "$RECORDER" record --out-dir "$OUT_DIR" -- "$BUILD_DIR/main"
