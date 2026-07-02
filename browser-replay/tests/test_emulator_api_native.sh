#!/usr/bin/env bash
# Test the emulator WASM API procs work correctly (native execution).
# This validates the C API before cross-compiling to WASM.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REC="$SCRIPT_DIR/../../../codetracer-native-recorder"
NATIVE_RECORDER="${NATIVE_RECORDER:-$(cd "$DEFAULT_REC" && pwd)}"

echo "=== Emulator WASM API Test (native) ==="
echo "  Native recorder: $NATIVE_RECORDER"

if [ ! -d "$NATIVE_RECORDER" ]; then
	echo "SKIP: codetracer-native-recorder not found at $NATIVE_RECORDER"
	exit 0
fi

if ! command -v direnv &>/dev/null; then
	echo "SKIP: direnv not found (needed for Nim dev shell)"
	exit 0
fi

TEST_NIM="$NATIVE_RECORDER/ct_emulator/tests/test_wasm_api.nim"
direnv exec "$NATIVE_RECORDER" nim c -r "$TEST_NIM" \
	2>&1 | tail -15

echo ""
echo "=== Emulator WASM API test complete ==="
