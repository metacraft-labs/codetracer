#!/usr/bin/env bash
# Regenerate the python/short_loop omniscient-db-size fixture.
# Mirrors the M3 SKIP-discipline review's "narrow probe" bar: the
# script exits 2 with a precise sentinel when the recorder is missing
# so the ct-bench driver can surface it as a SKIP.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"
RECORDER="${CODETRACER_PYTHON_RECORDER:-codetracer-python-recorder}"
if ! command -v "$RECORDER" >/dev/null 2>&1; then
	echo "SKIPPED: $RECORDER not on PATH" >&2
	exit 2
fi
exec "$RECORDER" --out-dir "$OUT_DIR" -- main.py
