#!/usr/bin/env bash
# Test that the nginx server is running and supports range requests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

echo "=== Browser Replay Server Tests ==="

# Create a test trace file
mkdir -p "$SCRIPT_DIR/traces/test"
echo '{"program":"test","recordingMode":"mcr-interpose","platform":"x86_64-linux-gnu"}' \
	>"$SCRIPT_DIR/traces/test/meta.json"
dd if=/dev/urandom of="$SCRIPT_DIR/traces/test/trace.ct" bs=1024 count=10 2>/dev/null

# Test 1: Health check
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/health")
if [ "$STATUS" = "200" ]; then
	pass "health check (HTTP $STATUS)"
else
	fail "health check (HTTP $STATUS, expected 200)"
fi

# Test 2: Fetch trace metadata
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$BASE_URL/traces/test/meta.json")
if [ "$STATUS" = "200" ]; then
	pass "fetch trace metadata (HTTP $STATUS)"
else
	fail "fetch trace metadata (HTTP $STATUS, expected 200)"
fi

# Test 3: Range request
RANGE_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" -H "Range: bytes=0-99" "$BASE_URL/traces/test/trace.ct")
if [ "$RANGE_STATUS" = "206" ]; then
	pass "range request (HTTP $RANGE_STATUS)"
else
	fail "range request (HTTP $RANGE_STATUS, expected 206)"
fi

# Test 4: CORS headers
CORS=$(curl -sk -D - -o /dev/null "$BASE_URL/traces/test/meta.json" | grep -i "access-control-allow-origin" | head -1)
if grep -q "\*" <<<"$CORS"; then
	pass "CORS header present"
else
	fail "CORS header missing: $CORS"
fi

# Test 5: Alt-Svc header (HTTP/3 advertisement)
ALT_SVC=$(curl -sk -D - -o /dev/null "$BASE_URL/health" | grep -i "alt-svc" | head -1)
if grep -qi "h3" <<<"$ALT_SVC"; then
	pass "Alt-Svc header advertises HTTP/3"
else
	fail "Alt-Svc header missing or no h3: $ALT_SVC"
fi

# Test 6: Accept-Ranges header
ACCEPT_RANGES=$(curl -sk -D - -o /dev/null "$BASE_URL/traces/test/trace.ct" | grep -i "accept-ranges" | head -1)
if grep -qi "bytes" <<<"$ACCEPT_RANGES"; then
	pass "Accept-Ranges: bytes header present"
else
	fail "Accept-Ranges header missing: $ACCEPT_RANGES"
fi

# Cleanup test trace
rm -rf "$SCRIPT_DIR/traces/test"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
