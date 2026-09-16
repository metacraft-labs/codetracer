#!/usr/bin/env bash
# Documentation asset conversion, not a check on the product. It no longer
# carries the not-a-CI-gate marker because its video-count refusal IS exercised from CI
# by `ci/test/stale-artefact-guards-test.sh`, against a copy of this script in a
# throwaway tree.
#
# Playwright recordings to WebP for the book. No human caller in the tree.

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

names=("omniscience" "tracepoint" "calltrace" "state-and-history" "eventlog" "terminal")

# THE NAMES BELOW ARE ASSIGNED BY POSITION, so the video directory has to hold
# exactly this run's videos and nothing else.
#
# `test-results/videos/` was never cleaned. Playwright writes one
# `<guid>.webm` per recorded test and never removes an old one, so
# `ls -1tr .../*.webm` returned this run's videos MIXED WITH every previous
# run's — and the sixth-oldest file, whatever it was, became `terminal.webp` in
# the book. A filtered run (`$1` is passed to `-g`) made it certain: three
# videos recorded, six names, three of the book's animations silently sourced
# from an earlier product. Same consequence as the rest of this sweep by a
# different mechanism -- a directory's contents standing in for this run's
# output -- so it is fixed the same way: make the correspondence checkable, then
# check it.
rm -rf "$TEST_RESULTS_DIR/videos"

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

# A positional mapping is only meaningful when the two lists are the same
# length. Fewer videos than names means some book animation would keep whatever
# WebP is already sitting in $OUTPUT_DIR from a previous run -- the same
# staleness through the back door -- and more videos than names means a
# `animation-6.webp` nothing in the book references.
if [ "${#videos[@]}" -ne "${#names[@]}" ]; then
	{
		echo "generate-webp-animations: recorded ${#videos[@]} video(s) but this script names ${#names[@]}:"
		printf '    %s\n' "${names[@]}"
		echo
		echo "  The names are assigned BY POSITION, so a mismatch means the book would"
		echo "  get an animation of the wrong thing, or keep a stale one from a previous"
		echo "  run. Re-run without a filter (this run used '-g ${TEST_FILTER:-<none>}'),"
		echo "  or update the name list to match the spec."
	} >&2
	exit 1
fi

for i in "${!videos[@]}"; do
	video_path="${videos[$i]}"
	name="${names[$i]}"

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
