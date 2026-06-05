#!/usr/bin/env bash
#
# Regenerate the cpp/simple_trivial_chain Value Origin fixture (M11).
#
# Compiles main.cpp with -O0 -g and drives ct-native-replay to produce
# an RR-backed recording. The recorder's `record` subcommand still uses
# the legacy `ct-rr-support` name on some installs; the
# ${RECORDER} env var lets CI override.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"

CXX="${CXX:-g++}"
"$CXX" -O0 -g -no-pie -o "$BUILD_DIR/main" main.cpp

RECORDER="${CT_NATIVE_REPLAY:-${CODETRACER_NATIVE_RECORDER:-ct-native-replay}}"
if ! command -v "$RECORDER" >/dev/null 2>&1; then
	echo "SKIPPED: $RECORDER not on PATH" >&2
	exit 2
fi
exec "$RECORDER" record -o "$OUT_DIR" -- "$BUILD_DIR/main"
