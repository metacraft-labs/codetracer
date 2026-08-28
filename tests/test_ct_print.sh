#!/bin/bash
set -e

# Test the ct print command against a mock JSONL span manifest.

MANIFEST=$(mktemp /tmp/ct_print_test_XXXX.jsonl)
trap 'rm -f "$MANIFEST"' EXIT

cat >"$MANIFEST" <<'EOF'
{"span_type":"web-request","metadata":{"http.method":"GET","http.url":"/api/users","http.status_code":"200","http.duration_ms":"12"},"status":"ok"}
{"span_type":"web-request","metadata":{"http.method":"POST","http.url":"/api/users","http.status_code":"201","http.duration_ms":"45"},"status":"ok"}
{"span_type":"web-request","metadata":{"http.method":"GET","http.url":"/error","http.status_code":"500","http.duration_ms":"8"},"status":"error"}
EOF

CT=${CT_BIN:-src/build-debug/bin/ct}
if [ ! -x "$CT" ]; then
	# A missing prerequisite is a hard failure, not a silent pass: exiting 0
	# here made "ct print is untested" and "ct print works" indistinguishable
	# for as long as the binary happened to be absent. Set
	# CT_PRINT_ALLOW_MISSING=1 for local iteration before a build; it is
	# never set in a CI gate.
	if [ "${CT_PRINT_ALLOW_MISSING:-0}" = "1" ]; then
		echo "SKIP: ct binary not found at $CT (CT_PRINT_ALLOW_MISSING=1)" >&2
		exit 0
	fi
	echo "error: ct binary not found or not executable at $CT" >&2
	echo "  Build with: just build-once" >&2
	echo "  Or set CT_BIN to a pre-built binary." >&2
	echo "  Set CT_PRINT_ALLOW_MISSING=1 to skip locally (never in CI)." >&2
	exit 1
fi

echo "=== Test: ct print with span manifest ==="
"$CT" print "$MANIFEST"
echo ""

echo "=== Test: ct print with --filter errors ==="
"$CT" print "$MANIFEST" --filter errors
echo ""

echo "=== Test: ct print with --format json ==="
"$CT" print "$MANIFEST" --format json
echo ""

echo "=== Test: ct print with --limit 1 ==="
"$CT" print "$MANIFEST" --limit 1
echo ""

echo "=== Test: ct print with --function /error ==="
"$CT" print "$MANIFEST" --function /error
echo ""

echo "=== Test: ct print with --format csv ==="
"$CT" print "$MANIFEST" --format csv
echo ""

echo "=== Test: ct print --verify (valid manifest) ==="
if "$CT" print "$MANIFEST" --verify; then
	echo "PASS: verify passed"
else
	echo "FAIL: verify should pass"
	exit 1
fi
echo ""

echo "=== Test: ct print --verify (empty file) ==="
EMPTY=$(mktemp /tmp/ct_empty_XXXX.jsonl)
touch "$EMPTY"
# Verify should fail for an empty file (exit code 1)
set +e
"$CT" print "$EMPTY" --verify
VERIFY_EXIT=$?
set -e
if [ "$VERIFY_EXIT" -eq 1 ]; then
	echo "PASS: verify correctly failed for empty"
else
	echo "FAIL: verify should fail for empty"
	exit 1
fi
rm -f "$EMPTY"
echo ""

# ---------------------------------------------------------------------------
# RS-M2 — request spans come from the container's span stream, not a sidecar.
#
# The fixtures under src/db-backend/tests/fixtures/span_stream/ are written by
# the canonical Nim writer (see the regenerate.sh next to them), so these cases
# also exercise `ct print`'s Nim reader against real writer bytes.
# ---------------------------------------------------------------------------

SPAN_FIXTURES=src/db-backend/tests/fixtures/span_stream
WITH_SPANS="$SPAN_FIXTURES/web_session.ct"
WITHOUT_SPANS="$SPAN_FIXTURES/no_spans.ct"

if [ ! -f "$WITH_SPANS" ]; then
	echo "SKIP: span-stream fixtures not found at $SPAN_FIXTURES"
else
	echo "=== Test: ct print reads request spans out of a .ct container ==="
	STREAM_OUT=$("$CT" print "$WITH_SPANS")
	echo "$STREAM_OUT"
	if echo "$STREAM_OUT" | grep -q "Total: 9 requests"; then
		echo "PASS: 9 requests read from the span stream"
	else
		echo "FAIL: expected 9 requests from the span stream"
		exit 1
	fi
	# Spot-check one row end to end: method, URL, status and duration.
	if echo "$STREAM_OUT" | grep -qE "GET .*/api/users .*200 .*12ms"; then
		echo "PASS: request columns rendered from the stream"
	else
		echo "FAIL: expected a 'GET /api/users 200 12ms' row"
		exit 1
	fi
	# The process-descriptor span shares the stream but is not a request row.
	if echo "$STREAM_OUT" | grep -q "php-fpm"; then
		echo "FAIL: the process span must not be printed as a request"
		exit 1
	fi
	echo ""

	echo "=== Test: ct print --filter errors against the span stream ==="
	ERR_OUT=$("$CT" print "$WITH_SPANS" --filter errors)
	echo "$ERR_OUT"
	# Spans 6 (404), 7 (500) and 10 (502) carry status=error.
	if echo "$ERR_OUT" | grep -q "Total: 3 requests"; then
		echo "PASS: error filter narrowed the stream rows"
	else
		echo "FAIL: expected 3 error requests"
		exit 1
	fi
	echo ""

	echo "=== Test: ct print --verify counts span-stream requests ==="
	VERIFY_OUT=$("$CT" print "$WITH_SPANS" --verify)
	echo "$VERIFY_OUT"
	if echo "$VERIFY_OUT" | grep -qE "HTTP requests: +9"; then
		echo "PASS: --verify reports the span-stream request count"
	else
		echo "FAIL: --verify should report 9 HTTP requests"
		exit 1
	fi
	echo ""

	echo "=== Test: the container wins over a stale sidecar next to it ==="
	SESSION=$(mktemp -d /tmp/ct_print_session_XXXX)
	trap 'rm -rf "$SESSION"' EXIT
	cp "$WITH_SPANS" "$SESSION/trace.ct"
	# A stale sidecar describing a DIFFERENT session.  The stream must win.
	cat >"$SESSION/session_manifest.jsonl" <<'EOF'
{"span_type":"web-request","metadata":{"http.method":"GET","http.url":"/stale","http.status_code":"200","http.duration_ms":"1"},"status":"ok"}
EOF
	PREFER_OUT=$("$CT" print "$SESSION")
	echo "$PREFER_OUT"
	if echo "$PREFER_OUT" | grep -q "/stale"; then
		echo "FAIL: ct print used the stale sidecar instead of the span stream"
		exit 1
	fi
	if echo "$PREFER_OUT" | grep -q "Total: 9 requests"; then
		echo "PASS: the container's span stream took precedence over the sidecar"
	else
		echo "FAIL: expected the 9 span-stream requests"
		exit 1
	fi
	echo ""

	echo "=== Test: a container without spans falls back to the sidecar ==="
	LEGACY=$(mktemp -d /tmp/ct_print_legacy_XXXX)
	cp "$WITHOUT_SPANS" "$LEGACY/trace.ct"
	cat >"$LEGACY/session_manifest.jsonl" <<'EOF'
{"span_type":"web-request","metadata":{"http.method":"GET","http.url":"/legacy","http.status_code":"200","http.duration_ms":"7"},"status":"ok"}
EOF
	LEGACY_OUT=$("$CT" print "$LEGACY")
	echo "$LEGACY_OUT"
	if echo "$LEGACY_OUT" | grep -q "/legacy"; then
		echo "PASS: a span-free container still prints its legacy sidecar"
	else
		echo "FAIL: expected the sidecar row for a span-free container"
		rm -rf "$LEGACY"
		exit 1
	fi
	rm -rf "$LEGACY"
	echo ""
fi

echo "PASS: all ct print tests completed"
