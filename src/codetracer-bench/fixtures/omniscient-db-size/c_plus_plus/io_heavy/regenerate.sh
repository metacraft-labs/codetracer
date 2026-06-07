#!/usr/bin/env bash
# Regenerate the c_plus_plus/short_loop omniscient-db-size fixture.
# Mirrors src/db-backend/tests/fixtures/origin/cpp/simple_trivial_chain/regenerate.sh.
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
