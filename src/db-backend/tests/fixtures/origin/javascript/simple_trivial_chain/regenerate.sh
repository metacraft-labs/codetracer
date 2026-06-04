#!/usr/bin/env bash
# Regenerate the javascript/simple_trivial_chain Value Origin fixture.
#
# The JS recorder has two subcommands; both are exercised here so M0
# pins the right invocation shape. The `instrument` step rewrites the
# source under build/, then `record` runs the instrumented copy.
#
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
