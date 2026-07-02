#!/usr/bin/env bash
# Run all browser replay tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0

run_test() {
	local name="$1"
	local script="$2"
	echo ""
	echo ">>> $name"
	if bash "$script"; then
		PASS=$((PASS + 1))
	else
		FAIL=$((FAIL + 1))
	fi
}

echo "=== Browser Replay Test Suite ==="

run_test "Transport Infrastructure" "$SCRIPT_DIR/test_transport.sh"
run_test "Emulator WASM API (native)" "$SCRIPT_DIR/test_emulator_api_native.sh"
run_test "E2E WASM Module Serving" "$SCRIPT_DIR/test_wasm_e2e.sh"
run_test "Distribution Contents" "$SCRIPT_DIR/test_dist.sh"
run_test "Cross-Platform Trace Replay" "$SCRIPT_DIR/test_cross_platform_replay.sh"

echo ""
echo "=========================================="
echo "  Test suites: $PASS passed, $FAIL failed"
echo "=========================================="

if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
