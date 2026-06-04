#!/usr/bin/env bash
#
# Regenerate the python/simple_trivial_chain Value Origin fixture.
#
# Drives the real Python recorder (`codetracer-python-recorder`) to
# produce a CTFS `.ct` trace of `main.py`. The committed source program
# is the canonical fixture; the recorded trace is what later milestones
# (M3, M11, ...) load as a `.ct` artefact.
#
# This script is the canonical re-recording entrypoint for this
# scenario. It does NOT need to succeed in M0 (recorder wiring or CLI
# flags may still be in flux); what M0 ships is the script's existence,
# the correct invocation shape, and the canonical source program.
#
# Usage (after `nix develop` provides the recorder on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_PYTHON_RECORDER:-codetracer-python-recorder}"

# TODO(M3): once the materialized DB backend wires Value Origin support
# into the Python recorder, add `--origin-patterns-include` for any
# project-local pattern files. For M0 we use the default recorder
# invocation and rely on the built-in catalogue.
exec "$RECORDER" \
	--out-dir "$OUT_DIR" \
	-- \
	main.py
