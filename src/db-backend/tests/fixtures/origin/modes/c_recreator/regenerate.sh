#!/usr/bin/env bash
#
# Regenerate the modes/c_recreator benchmark fixture.
#
# Compiles main.c at `-O2 -g` (the spec's release-shape DWARF target)
# and records two `.ct` artefacts via `ct-native-replay` — Mode 2
# (baseline) and Mode 3 (`--origin-metadata=on`).
#
# Exit codes:
#   0 — both recordings landed under ./trace/{mode2,mode3}/.
#   2 — recorder or compiler not on PATH (precise SKIP sentinel
#       emitted).
#   non-zero — recording or compilation failed.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

CC="${CC:-gcc}"
RECORDER="${CT_NATIVE_REPLAY:-ct-native-replay}"

if ! command -v "$CC" >/dev/null 2>&1; then
	echo "SKIPPED: $CC not on PATH (modes/c_recreator requires a C compiler)" >&2
	exit 2
fi
if ! command -v "$RECORDER" >/dev/null 2>&1; then
	echo "SKIPPED: $RECORDER not on PATH (modes/c_recreator requires ct-native-replay)" >&2
	exit 2
fi

BIN_DIR="$HERE/build"
mkdir -p "$BIN_DIR"
"$CC" -O2 -g -o "$BIN_DIR/main" main.c

OUT_BASE="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_BASE/mode2" "$OUT_BASE/mode3"

echo "==> modes/c_recreator: Mode 2 baseline"
"$RECORDER" --out-dir "$OUT_BASE/mode2" --origin-metadata=off -- "$BIN_DIR/main"

echo "==> modes/c_recreator: Mode 3 indexed"
"$RECORDER" --out-dir "$OUT_BASE/mode3" --origin-metadata=on -- "$BIN_DIR/main"

echo "modes/c_recreator: both recordings regenerated."
