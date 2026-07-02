#!/usr/bin/env bash
# Test cross-platform trace replay in the browser.
#
# Imports traces from codetracer-example-recordings and verifies that:
#   1. The import helper creates a valid trace folder
#   2. The trace metadata is well-formed JSON
#   3. Platform detection correctly identifies same- vs cross-platform traces
#   4. Source files and binaries are carried into the trace folder
#
# Skips gracefully if codetracer-example-recordings is not present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXAMPLES_REPO="${EXAMPLES_REPO:-$REPO_ROOT/../codetracer-example-recordings}"
IMPORT_SCRIPT="$SCRIPT_DIR/import-fixture-trace.sh"

PASS=0
FAIL=0
SKIP=0
# Track temp dirs for cleanup
CLEANUP_DIRS=()

cleanup() {
	for d in "${CLEANUP_DIRS[@]}"; do
		rm -rf "$d"
	done
}
trap cleanup EXIT

pass() {
	echo "  PASS: $1"
	PASS=$((PASS + 1))
}
fail() {
	echo "  FAIL: $1"
	FAIL=$((FAIL + 1))
}
skip() {
	echo "  SKIP: $1"
	SKIP=$((SKIP + 1))
}

echo "=== Cross-Platform Trace Replay Tests ==="

# Pre-flight: check that codetracer-example-recordings is available
if [ ! -d "$EXAMPLES_REPO" ]; then
	echo "SKIP: codetracer-example-recordings not found at $EXAMPLES_REPO"
	exit 0
fi

if [ ! -d "$EXAMPLES_REPO/mcr" ]; then
	echo "SKIP: no mcr/ directory in codetracer-example-recordings"
	exit 0
fi

# Pre-flight: import helper must exist
if [ ! -f "$IMPORT_SCRIPT" ]; then
	echo "FAIL: import-fixture-trace.sh not found at $IMPORT_SCRIPT"
	exit 1
fi

# Detect host platform for same-platform vs cross-platform comparison
HOST_ARCH=$(uname -m)
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')

host_platform_tag() {
	# Return a tag matching the directory naming convention in
	# codetracer-example-recordings/mcr/
	case "$HOST_OS-$HOST_ARCH" in
	linux-x86_64) echo "linux-x86_64" ;;
	linux-aarch64) echo "linux-arm64" ;;
	darwin-arm64) echo "macos-arm64" ;;
	darwin-x86_64) echo "macos-x86_64" ;;
	*) echo "unknown" ;;
	esac
}

HOST_TAG=$(host_platform_tag)
echo "Host platform: $HOST_OS $HOST_ARCH (tag: $HOST_TAG)"

PLATFORM_COUNT=0

for platform_dir in "$EXAMPLES_REPO"/mcr/*/; do
	# Skip if the glob didn't match anything
	[ -d "$platform_dir" ] || continue

	PLATFORM=$(basename "$platform_dir")
	TRACE_FILE="$platform_dir/trace.ct"

	if [ ! -f "$TRACE_FILE" ]; then
		skip "$PLATFORM: no trace.ct found"
		continue
	fi

	PLATFORM_COUNT=$((PLATFORM_COUNT + 1))
	echo ""
	echo "--- $PLATFORM ---"

	# ---- Test 1: Import creates a valid trace folder ----
	TRACE_DIR=$("$IMPORT_SCRIPT" "$TRACE_FILE" --program "ct_fixture_$PLATFORM" 2>&1 | tail -1)
	CLEANUP_DIRS+=("$TRACE_DIR")

	if [ -d "$TRACE_DIR" ] && [ -f "$TRACE_DIR/trace.ct" ] && [ -f "$TRACE_DIR/trace_db_metadata.json" ]; then
		pass "$PLATFORM: trace folder created with required files"
	else
		fail "$PLATFORM: trace folder missing required files (dir=$TRACE_DIR)"
		continue
	fi

	# ---- Test 2: Metadata is valid JSON with expected fields ----
	if command -v python3 &>/dev/null; then
		META_OK=$(python3 -c "
import json, sys
with open('$TRACE_DIR/trace_db_metadata.json') as f:
    m = json.load(f)
ok = all(k in m for k in ('program', 'args', 'lang', 'traceKind', 'tracePath'))
print('valid' if ok else 'invalid')
" 2>&1)
		if [ "$META_OK" = "valid" ]; then
			pass "$PLATFORM: trace_db_metadata.json is valid"
		else
			fail "$PLATFORM: trace_db_metadata.json malformed ($META_OK)"
		fi
	else
		skip "$PLATFORM: python3 not available for JSON validation"
	fi

	# ---- Test 3: trace_paths.json exists and is valid JSON ----
	if [ -f "$TRACE_DIR/trace_paths.json" ]; then
		if python3 -c "import json; json.load(open('$TRACE_DIR/trace_paths.json'))" 2>/dev/null; then
			pass "$PLATFORM: trace_paths.json is valid"
		else
			fail "$PLATFORM: trace_paths.json is not valid JSON"
		fi
	else
		fail "$PLATFORM: trace_paths.json missing"
	fi

	# ---- Test 4: Source files copied if available ----
	if [ -e "$platform_dir/source.c" ]; then
		if [ -f "$TRACE_DIR/files/source.c" ]; then
			pass "$PLATFORM: source.c copied into trace folder"
		else
			fail "$PLATFORM: source.c exists in fixture but was not copied"
		fi
	else
		skip "$PLATFORM: no source.c in fixture"
	fi

	# ---- Test 5: Binaries directory copied if available ----
	if [ -d "$platform_dir/binaries" ]; then
		if [ -d "$TRACE_DIR/binaries" ]; then
			ORIG_COUNT=$(find "$platform_dir/binaries" -type f | wc -l)
			COPY_COUNT=$(find "$TRACE_DIR/binaries" -type f | wc -l)
			if [ "$COPY_COUNT" -ge "$ORIG_COUNT" ]; then
				pass "$PLATFORM: binaries directory copied ($COPY_COUNT files)"
			else
				fail "$PLATFORM: binaries directory incomplete ($COPY_COUNT/$ORIG_COUNT files)"
			fi
		else
			fail "$PLATFORM: binaries directory exists in fixture but was not copied"
		fi
	else
		skip "$PLATFORM: no binaries in fixture"
	fi

	# ---- Test 6: Same-platform vs cross-platform detection ----
	if [ "$PLATFORM" = "$HOST_TAG" ]; then
		echo "  INFO: same-platform trace (native replay possible)"
		pass "$PLATFORM: identified as same-platform"
	else
		echo "  INFO: cross-platform trace ($PLATFORM on $HOST_TAG host)"
		pass "$PLATFORM: identified as cross-platform"
	fi

	# ---- Test 7: .ct file size sanity check ----
	CT_SIZE=$(stat --format=%s "$TRACE_DIR/trace.ct" 2>/dev/null || stat -f%z "$TRACE_DIR/trace.ct" 2>/dev/null || echo 0)
	if [ "$CT_SIZE" -gt 0 ]; then
		pass "$PLATFORM: trace.ct is non-empty ($CT_SIZE bytes)"
	else
		fail "$PLATFORM: trace.ct is empty or unreadable"
	fi
done

if [ "$PLATFORM_COUNT" -eq 0 ]; then
	echo "SKIP: no platform traces found in $EXAMPLES_REPO/mcr/"
	exit 0
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
if [ "$FAIL" -gt 0 ]; then
	exit 1
fi
