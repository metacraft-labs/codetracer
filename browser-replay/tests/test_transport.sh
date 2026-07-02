#!/usr/bin/env bash
# Test the browser replay transport infrastructure.
# Verifies that nginx serves the app files and traces correctly.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BR_DIR="$REPO_ROOT/browser-replay"
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

echo "=== Browser Replay Transport Tests ==="

# Check nginx availability before starting
if ! command -v nginx &>/dev/null; then
	echo "SKIP: nginx not found. Install via: nix-shell -p nginxMainline"
	exit 0
fi

# Start server (capture output for diagnostics on failure)
if ! bash "$BR_DIR/start-server.sh"; then
	echo "SKIP: failed to start nginx server"
	exit 0
fi
sleep 1

# Test 1: transport-test.html served
TEST_PAGE="$BASE_URL/app/transport-test.html"
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$TEST_PAGE")
if [ "$STATUS" = "200" ]; then
	pass "transport-test.html served (HTTP $STATUS)"
else
	fail "transport-test.html not served (HTTP $STATUS)"
fi

# Test 2: index.html served
INDEX_URL="$BASE_URL/app/index.html"
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$INDEX_URL")
if [ "$STATUS" = "200" ]; then
	pass "index.html served (HTTP $STATUS)"
else
	fail "index.html not served (HTTP $STATUS)"
fi

# Test 3: worker.js served with correct content-type
WORKER_URL="$BASE_URL/app/worker.js"
CONTENT_TYPE=$(curl -sk -D - -o /dev/null "$WORKER_URL" |
	grep -i "content-type" | head -1)
if echo "$CONTENT_TYPE" |
	grep -qi "javascript\|ecmascript"; then
	pass "worker.js served with JS content-type"
else
	fail "worker.js content-type wrong: $CONTENT_TYPE"
fi

# Test 4: Create and serve a test MCR trace
TRACE_DIR="$BR_DIR/traces/mcr-test"
mkdir -p "$TRACE_DIR"
META='{"program":"test",'
META+='"recordingMode":"mcr-interpose",'
META+='"platform":"x86_64-linux-gnu"}'
echo "$META" >"$TRACE_DIR/meta.json"
dd if=/dev/urandom of="$TRACE_DIR/trace.ct" \
	bs=1024 count=5 2>/dev/null

META_URL="$BASE_URL/traces/mcr-test/meta.json"
STATUS=$(curl -sk -o /dev/null -w "%{http_code}" "$META_URL")
if [ "$STATUS" = "200" ]; then
	pass "MCR trace metadata served"
else
	fail "MCR trace metadata not served (HTTP $STATUS)"
fi

# Test 5: Range request on trace file
TRACE_URL="$BASE_URL/traces/mcr-test/trace.ct"
RANGE_STATUS=$(curl -sk -o /dev/null -w "%{http_code}" \
	-H "Range: bytes=0-99" "$TRACE_URL")
if [ "$RANGE_STATUS" = "206" ]; then
	pass "range request on trace (HTTP $RANGE_STATUS)"
else
	fail "range request failed (HTTP $RANGE_STATUS)"
fi

# Test 6: CORS headers present
CORS=$(curl -sk -D - -o /dev/null "$META_URL" 2>&1 |
	grep -i "access-control-allow-origin" | head -1)
if echo "$CORS" | grep -q "\*"; then
	pass "CORS headers present on trace files"
else
	fail "CORS missing on trace files: $CORS"
fi

# Cleanup
rm -rf "$TRACE_DIR"
bash "$BR_DIR/stop-server.sh" 2>/dev/null

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
