#!/usr/bin/env bash
set -euo pipefail

# Verifies that build.sh and build-once.sh have aligned reprobuild detection.
echo "Checking build script alignment..."
if grep -q "ct_reprobuild_host" scripts/build.sh && grep -q "ct_reprobuild_host" scripts/build-once.sh; then
	echo "Alignment test passed: Both scripts detect reprobuild hosts."
	exit 0
else
	echo "Alignment test failed: Missing reprobuild host detection."
	exit 1
fi
