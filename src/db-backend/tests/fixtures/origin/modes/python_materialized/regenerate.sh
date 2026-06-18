#!/usr/bin/env bash
#
# Regenerate the modes/python_materialized benchmark fixture.
#
# Drives the Python recorder twice — once with
# `--origin-metadata=off` (Mode 2 baseline) and once with
# `--origin-metadata=on` (Mode 3) — so the benchmark suite can
# compare the per-mode artefacts.
#
# This script SKIPs cleanly when the prereq toolchain is missing —
# the benchmark suite is deferred to the recorder-integration
# follow-on per the M19 landed-artefacts block, so dev-shell runs
# don't need a recorder to land the fixture skeleton.
#
# Usage (after `nix develop` provides the recorder on $PATH):
#     ./regenerate.sh
#
# Exit codes:
#   0 — both recordings landed under ./trace/{mode2,mode3}/.
#   2 — recorder not on PATH (precise SKIP sentinel emitted).
#   non-zero — recording failed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

RECORDER="${CODETRACER_PYTHON_RECORDER:-codetracer-python-recorder}"
if ! command -v "$RECORDER" >/dev/null 2>&1; then
	echo "SKIPPED: $RECORDER not on PATH (modes/python_materialized requires the Python recorder)" >&2
	exit 2
fi

OUT_BASE="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_BASE/mode2" "$OUT_BASE/mode3"

echo "==> modes/python_materialized: Mode 2 baseline"
"$RECORDER" --out-dir "$OUT_BASE/mode2" --origin-metadata=off -- main.py

echo "==> modes/python_materialized: Mode 3 indexed"
"$RECORDER" --out-dir "$OUT_BASE/mode3" --origin-metadata=on -- main.py

echo "modes/python_materialized: both recordings regenerated."
