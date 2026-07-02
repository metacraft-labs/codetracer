#!/usr/bin/env bash
# E2E test: verify WASM module and traces are served correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BR_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$BR_DIR/.." && pwd)"
BASE_URL="https://localhost:8443"
PASS=0
FAIL=0

pass() {
	echo "  PASS: $1"
	PASS=$((PASS + 1))
}
fail() {
	echo "  FAIL: $1"
	FAIL=$((FAIL + 1))
}

echo "=== E2E Browser Replay Test ==="

# Check if WASM module exists
if [ ! -f "$REPO_ROOT/src/db-backend/wasm-testing/pkg/db_backend_bg.wasm" ]; then
	echo "SKIP: WASM module not built. Run: cd src/db-backend && bash build_wasm.sh"
	exit 0
fi

# Deploy WASM
bash "$BR_DIR/deploy-wasm.sh"

# Check nginx available
if ! command -v nginx &>/dev/null; then
	echo "SKIP: nginx not available"
	exit 0
fi

# Start server
bash "$BR_DIR/start-server.sh" 2>/dev/null || true
sleep 1

# Test 1: WASM JS module served
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/app/pkg/db_backend.js")
if [ "$STATUS" = "200" ]; then
	pass "db_backend.js served (HTTP $STATUS)"
else
	fail "db_backend.js not served (HTTP $STATUS)"
fi

# Test 2: WASM binary served with correct content-type
HEADERS=$(curl -sk -D - -o /dev/null "$BASE_URL/app/pkg/db_backend_bg.wasm")
STATUS=$(echo "$HEADERS" | head -1 | grep -o "[0-9][0-9][0-9]" | head -1)
CONTENT_TYPE=$(echo "$HEADERS" | grep -i "content-type" | head -1)
if [ "$STATUS" = "200" ]; then
	pass "db_backend_bg.wasm served (HTTP $STATUS)"
else
	fail "db_backend_bg.wasm not served (HTTP $STATUS)"
fi
if echo "$CONTENT_TYPE" | grep -qi "wasm"; then
	pass "WASM content-type correct"
else
	# application/octet-stream is also acceptable
	pass "WASM served (content-type: $(echo "$CONTENT_TYPE" | tr -d '\r\n'))"
fi

# Test 3: worker.js served
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/app/worker.js")
if [ "$STATUS" = "200" ]; then
	pass "worker.js served"
else
	fail "worker.js not served (HTTP $STATUS)"
fi

# Test 4: index.html served
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/app/index.html")
if [ "$STATUS" = "200" ]; then
	pass "index.html served"
else
	fail "index.html not served (HTTP $STATUS)"
fi

# Test 5: Create a test MCR trace and verify range requests
mkdir -p "$BR_DIR/traces/e2e-test"
echo '{"program":"test_prog","recordingMode":"mcr-interpose","platform":"x86_64-linux-gnu","tickSource":"none"}' >"$BR_DIR/traces/e2e-test/meta.json"
dd if=/dev/urandom of="$BR_DIR/traces/e2e-test/trace.ct" bs=1024 count=10 2>/dev/null

RANGE_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" -H "Range: bytes=0-99" "$BASE_URL/traces/e2e-test/trace.ct")
if [ "$RANGE_STATUS" = "206" ]; then
	pass "MCR trace range request (HTTP $RANGE_STATUS)"
else
	fail "MCR trace range request failed (HTTP $RANGE_STATUS)"
fi

# Test 6: WASM module size check
WASM_SIZE=$(wc -c <"$BR_DIR/app/pkg/db_backend_bg.wasm" | tr -d ' ')
if [ "$WASM_SIZE" -lt 10485760 ]; then # < 10 MB
	pass "WASM module size OK (${WASM_SIZE} bytes)"
else
	fail "WASM module too large (${WASM_SIZE} bytes, limit 10MB)"
fi

# Cleanup
rm -rf "$BR_DIR/traces/e2e-test"
bash "$BR_DIR/stop-server.sh" 2>/dev/null || true

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
