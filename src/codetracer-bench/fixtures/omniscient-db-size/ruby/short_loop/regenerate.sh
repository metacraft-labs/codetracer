#!/usr/bin/env bash
# Regenerate the ruby/short_loop omniscient-db-size fixture.
# Narrow SKIP probe per M3 review.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"
RECORDER="${RECORDER:-codetracer-ruby-recorder}"
if ! command -v "$RECORDER" >/dev/null 2>&1; then
	echo "SKIPPED: $RECORDER not on PATH" >&2
	exit 2
fi
exec "$RECORDER" --out-dir "$OUT_DIR" -- main.rb
