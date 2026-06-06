#!/usr/bin/env bash
#
# Regenerate the cairo/simple_trivial_chain Value Origin fixture.
#
# Drives the real Cairo recorder (`codetracer-cairo-recorder`) to
# produce a CTFS `.ct` trace of `main.cairo`. The committed source
# program is the canonical fixture; the recorded trace is what later
# milestones (M23 origin DAP tests, M19 indexer fixtures) load as a
# `.ct` artefact.
#
# This script is the canonical re-recording entrypoint for this
# scenario. It does NOT need to succeed in CI without the recorder
# checked out as a sibling repo; what M23 ships is the script's
# existence, the correct invocation shape, and the canonical source
# program. CI runs that lack the recorder use the SKIP path in
# `tests/origin_cairo_dap_test.rs`.
#
# Usage (after `nix develop` provides the recorder on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_CAIRO_RECORDER:-codetracer-cairo-recorder}"

exec "$RECORDER" \
	record \
	"$HERE/main.cairo" \
	--out-dir "$OUT_DIR"
