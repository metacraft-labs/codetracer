#!/usr/bin/env bash
# Regenerate the javascript/simple_trivial_chain Value Origin fixture.
#
# Record the source directly so trace paths and line numbers match the
# fixture file consumed by DAP/WDIO. The recorder owns instrumentation
# internally.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"
RECORDER="${CODETRACER_JS_RECORDER:-codetracer-js-recorder}"
# TODO(M3): wire `--origin-patterns-include` once project-pattern files land.
exec "$RECORDER" record main.js --out-dir "$OUT_DIR"
