#!/usr/bin/env bash
# Verify the dist directory contents and size.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/dist"
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

echo "=== Distribution Verification Tests ==="

if [ ! -d "$DIST_DIR" ]; then
	echo "SKIP: dist/ not built. Run: bash browser-replay/build-dist.sh"
	exit 0
fi

# Test 1: Required files exist
for f in index.html worker.js pkg/db_backend.js pkg/db_backend_bg.wasm serve.conf; do
	if [ -f "$DIST_DIR/$f" ]; then
		pass "$f exists"
	else
		fail "$f missing"
	fi
done

# Test 2: WASM size < 10 MB
WASM_SIZE=$(wc -c <"$DIST_DIR/pkg/db_backend_bg.wasm" | tr -d ' ')
if [ "$WASM_SIZE" -lt 10485760 ]; then
	pass "WASM size OK ($WASM_SIZE bytes)"
else
	fail "WASM too large ($WASM_SIZE bytes)"
fi

# Test 3: Total dist size < 15 MB
TOTAL_KB=$(du -sk "$DIST_DIR" | cut -f1)
if [ "$TOTAL_KB" -lt 15360 ]; then
	pass "Total dist size OK (${TOTAL_KB}KB)"
else
	fail "Dist too large (${TOTAL_KB}KB)"
fi

# Test 4: worker.js imports from correct path
if grep -q "pkg/db_backend" "$DIST_DIR/worker.js"; then
	pass "worker.js imports from pkg/"
else
	fail "worker.js import path wrong"
fi

# Test 5: traces directory exists
if [ -d "$DIST_DIR/traces" ]; then
	pass "traces/ directory exists"
else
	fail "traces/ directory missing"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then exit 1; fi
