#!/usr/bin/env bash
# Regenerate the python/augmented_assignment Value Origin fixture.
# See origin/python/simple_trivial_chain/regenerate.sh for full context.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"
RECORDER="${CODETRACER_PYTHON_RECORDER:-codetracer-python-recorder}"
# TODO(M3): wire `--origin-patterns-include` once project-pattern files land.
exec "$RECORDER" --out-dir "$OUT_DIR" -- main.py
