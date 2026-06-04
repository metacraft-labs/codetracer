#!/usr/bin/env bash
#
# Regenerate the c/simple_trivial_chain Value Origin fixture.
#
# The native recorder (`codetracer-native-recorder`) records native
# binaries via the MCR pipeline. We compile `main.c` with `-O0 -g` so
# DWARF gives the classifier real local-variable extents.
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"

CC="${CC:-gcc}"
"$CC" -O0 -g -no-pie -o "$BUILD_DIR/main" main.c

RECORDER="${CODETRACER_NATIVE_RECORDER:-codetracer-native-recorder}"
# TODO(M3): native recorder's `record` subcommand surface for one-shot
# materialized recording is still being finalised (see
# Recorder-CLI-Conventions.md — native recorder currently exposes
# `index` / `seek` / `requests` / `discover`). The invocation below
# uses the `record` subcommand alias documented as the user-facing
# entry point; this script will need a follow-up once M11 lands the
# materialized DB ingestion path for the native recorder.
exec "$RECORDER" record --out-dir "$OUT_DIR" -- "$BUILD_DIR/main"
