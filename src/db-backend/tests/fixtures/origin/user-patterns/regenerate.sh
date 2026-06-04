#!/usr/bin/env bash
#
# Regenerate the user-patterns Value Origin fixture.
#
# The recorder discovers `.codetracer/origin-patterns.toml` inside the
# program's dependency roots and embeds them in the recorded trace at
# `meta_dat/origin-patterns/<library_id>/`. M0 does NOT yet require the
# recorder to perform that embedding; this script captures the
# canonical invocation shape.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_PYTHON_RECORDER:-codetracer-python-recorder}"

# The faux library lives at $HERE/faux-library and ships
# `.codetracer/origin-patterns.toml`. We pass `--origin-patterns-include`
# explicitly so the recorder picks it up even when site-packages
# resolution doesn't see it (the fixture extends sys.path inside the
# program).
# TODO(M2/M3): the `--origin-patterns-include` flag is documented in
# spec §7.4 but not yet wired in the recorder CLI; the flag is included
# here so the script becomes runnable as soon as the recorder lands.
exec "$RECORDER" \
	--out-dir "$OUT_DIR" \
	--origin-patterns-include "$HERE/faux-library/.codetracer/origin-patterns.toml" \
	-- \
	program/main.py
