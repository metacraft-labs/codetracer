#!/usr/bin/env bash
#
# Regenerate the d/simple_trivial_chain Value Origin fixture (M11).
#
# Compiles main.d with the LDC2 D compiler (preserves DWARF) and drives
# ct-native-replay to produce an RR-backed recording. The D fixture is
# expected to SKIP cleanly until the classifier crate adds a
# tree-sitter-d grammar.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
OUT_DIR="${OUT_DIR:-$HERE/trace}"
BUILD_DIR="${BUILD_DIR:-$HERE/build}"
mkdir -p "$OUT_DIR" "$BUILD_DIR"

DC="${DC:-ldc2}"
if ! command -v "$DC" >/dev/null 2>&1; then
	echo "SKIPPED: D compiler ($DC) not on PATH" >&2
	exit 2
fi

"$DC" -g -O0 -of="$BUILD_DIR/main" main.d

RECORDER="${CT_NATIVE_REPLAY:-${CODETRACER_NATIVE_RECORDER:-ct-native-replay}}"
if ! command -v "$RECORDER" >/dev/null 2>&1; then
	echo "SKIPPED: $RECORDER not on PATH" >&2
	exit 2
fi
exec "$RECORDER" record -o "$OUT_DIR" -- "$BUILD_DIR/main"
