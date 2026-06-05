#!/usr/bin/env bash
# Regenerate the ruby/block_arg_pass Value Origin fixture.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"
RECORDER="${CODETRACER_RUBY_RECORDER:-codetracer-ruby-recorder}"
# TODO(M3): wire `--origin-patterns-include` once project-pattern files land.
exec "$RECORDER" --out-dir "$OUT_DIR" -- main.rb
