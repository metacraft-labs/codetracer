#!/usr/bin/env bash

set -euo pipefail

# This script runs Playwright tests to record animations and converts them to WebP.
# It mimics the workflow for capturing screenshots for the CodeTracer book.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/docs/book/src/generated/animations"
TEST_RESULTS_DIR="${REPO_ROOT}/test-results"

mkdir -p "$OUTPUT_DIR"
mkdir -p "$TEST_RESULTS_DIR"

echo "Running Playwright tests to capture animations..."

# Run the specific test file
# We force video recording on for these tests.
TEST_FILTER="${1:-}"

echo "Running Playwright tests..."
export RECORD_VIDEO=1
(cd src/tests/gui && npm run test -- tests/docs/generate-webp-animations.spec.ts \
	--project=chromium \
	--workers=1 \
	-g "$TEST_FILTER")

# Playwright saves videos in test-results/videos/<guid>.webm
# We need to find them and convert them.
echo "Searching for recorded videos in $TEST_RESULTS_DIR/videos..."

# Get videos sorted by creation time
mapfile -t videos < <(ls -1tr "$TEST_RESULTS_DIR"/videos/*.webm 2>/dev/null)
names=("omniscience" "tracepoint" "calltrace" "state-and-history" "eventlog" "terminal")

for i in "${!videos[@]}"; do
	video_path="${videos[$i]}"
	name="${names[$i]}"

	if [ -z "$name" ]; then
		name="animation-$i"
	fi

	output_webp="${OUTPUT_DIR}/${name}.webp"

	echo "Converting $video_path to $output_webp..."

	ffmpeg -y -i "$video_path" \
		-vcodec libwebp \
		-filter:v fps=fps=15 \
		-lossless 0 \
		-compression_level 6 \
		-q:v 70 \
		-loop 0 \
		-preset default \
		-an \
		"$output_webp"
done

echo "Done! Animations generated in $OUTPUT_DIR"
