#!/usr/bin/env bash
# Playwright trace inspection tool
# Usage: ./trace-inspect.sh <trace.zip> [command] [args]
#
# Commands:
#   info          - Show trace file info and contents summary (default)
#   screenshots   - Extract and list screenshots
#   actions       - Parse and display action timeline (requires jq)
#   network       - Show network request summary
#   extract       - Extract full trace to a directory
#   view          - Open trace in browser (requires npx playwright)

set -e

TRACE_FILE="${1:-}"
COMMAND="${2:-info}"
ARG="${3:-}"

if [[ -z $TRACE_FILE ]]; then
	echo "Playwright Trace Inspection Tool"
	echo "================================="
	echo ""
	echo "Usage: $0 <trace.zip> [command] [args]"
	echo ""
	echo "Commands:"
	echo "  info          - Show trace file info and contents summary (default)"
	echo "  screenshots   - Extract screenshots and show paths"
	echo "  actions       - Parse and display action timeline"
	echo "  network       - Show network request summary"
	echo "  extract <dir> - Extract full trace to a directory"
	echo "  view          - Open trace in Playwright trace viewer"
	echo ""
	echo "Examples:"
	echo "  $0 test.trace.zip info"
	echo "  $0 test.trace.zip screenshots"
	echo "  $0 test.trace.zip view"
	exit 1
fi

if [[ ! -f $TRACE_FILE ]]; then
	echo "Error: File not found: $TRACE_FILE"
	exit 1
fi

# Create temp directory for extraction
TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

case "$COMMAND" in
info)
	echo "Trace File: $TRACE_FILE"
	echo "Size: $(du -h "$TRACE_FILE" | cut -f1)"
	echo ""
	echo "Contents:"
	unzip -l "$TRACE_FILE" 2>/dev/null | head -50
	echo ""
	echo "File types:"
	unzip -l "$TRACE_FILE" 2>/dev/null | awk '{print $4}' | grep -oE '\.[^.]+$' | sort | uniq -c | sort -rn | head -20
	;;

screenshots)
	echo "Extracting screenshots from: $TRACE_FILE"
	unzip -q "$TRACE_FILE" -d "$TEMP_DIR"

	# Find all image files
	IMAGES=$(find "$TEMP_DIR" -type f \( -name "*.png" -o -name "*.jpg" -o -name "*.jpeg" \) 2>/dev/null)

	if [[ -z $IMAGES ]]; then
		echo "No screenshots found in trace."
		exit 0
	fi

	# Create output directory
	OUTPUT_DIR="${TRACE_FILE%.zip}_screenshots"
	mkdir -p "$OUTPUT_DIR"

	echo "Found screenshots:"
	COUNT=0
	while IFS= read -r img; do
		COUNT=$((COUNT + 1))
		BASENAME=$(basename "$img")
		cp "$img" "$OUTPUT_DIR/$BASENAME"
		SIZE=$(du -h "$img" | cut -f1)
		echo "  [$COUNT] $BASENAME ($SIZE)"
	done <<<"$IMAGES"

	echo ""
	echo "Screenshots extracted to: $OUTPUT_DIR/"
	echo "Total: $COUNT screenshot(s)"
	;;

actions)
	echo "Parsing actions from: $TRACE_FILE"
	unzip -q "$TRACE_FILE" -d "$TEMP_DIR"

	# Look for trace event files (JSON format)
	TRACE_EVENTS=$(find "$TEMP_DIR" -name "*.trace" -o -name "*.json" 2>/dev/null | head -5)

	if [[ -z $TRACE_EVENTS ]]; then
		echo "No parseable trace events found."
		echo ""
		echo "Trace files present:"
		find "$TEMP_DIR" -type f -name "trace*" | head -10
		exit 0
	fi

	for EVENT_FILE in $TRACE_EVENTS; do
		BASENAME=$(basename "$EVENT_FILE")
		echo ""
		echo "=== $BASENAME ==="

		# Try to parse as JSON (Playwright trace format)
		if command -v jq &>/dev/null; then
			if jq -e '.' "$EVENT_FILE" >/dev/null 2>&1; then
				# Extract action names and timestamps if available
				jq -r '
                        if type == "array" then
                            .[] | select(.type == "action" or .name != null) |
                            "\(.timestamp // .time // "?")ms: \(.type // "event") - \(.name // .method // .apiName // "unknown")"
                        elif type == "object" and .events then
                            .events[] | select(.type == "action") |
                            "\(.time // "?")ms: \(.method // .apiName // "action")"
                        else
                            "Unrecognized trace format"
                        end
                    ' "$EVENT_FILE" 2>/dev/null | head -50 || echo "(Could not parse JSON structure)"
			else
				echo "(Binary or non-JSON format)"
				file "$EVENT_FILE"
			fi
		else
			echo "(Install jq for JSON parsing: apt install jq)"
			head -c 500 "$EVENT_FILE" | strings | head -20
		fi
	done
	;;

network)
	echo "Parsing network requests from: $TRACE_FILE"
	unzip -q "$TRACE_FILE" -d "$TEMP_DIR"

	# Look for network files
	NETWORK_FILES=$(find "$TEMP_DIR" -name "*network*" -o -name "*.har" 2>/dev/null)

	if [[ -z $NETWORK_FILES ]]; then
		echo "No dedicated network files found."
		echo ""
		echo "Searching for URLs in trace data..."
		find "$TEMP_DIR" -type f -exec strings {} \; 2>/dev/null | grep -oE 'https?://[^"'\''[:space:]]+' | sort | uniq -c | sort -rn | head -30
		exit 0
	fi

	for NET_FILE in $NETWORK_FILES; do
		echo ""
		echo "=== $(basename "$NET_FILE") ==="
		if command -v jq &>/dev/null && jq -e '.' "$NET_FILE" >/dev/null 2>&1; then
			jq -r '.entries[]? | "\(.request.method) \(.request.url) -> \(.response.status)"' "$NET_FILE" 2>/dev/null | head -30 ||
				jq -r 'keys' "$NET_FILE" 2>/dev/null | head -10
		else
			head -c 1000 "$NET_FILE" | strings | head -20
		fi
	done
	;;

extract)
	OUTPUT_DIR="${ARG:-${TRACE_FILE%.zip}_extracted}"
	echo "Extracting trace to: $OUTPUT_DIR"
	mkdir -p "$OUTPUT_DIR"
	unzip -o "$TRACE_FILE" -d "$OUTPUT_DIR"
	echo ""
	echo "Done. Contents:"
	find "$OUTPUT_DIR" -type f | head -30
	;;

view)
	echo "Opening trace in Playwright viewer..."
	echo "File: $TRACE_FILE"
	echo ""
	if command -v npx &>/dev/null; then
		npx playwright show-trace "$TRACE_FILE"
	else
		echo "npx not found. Install Node.js or open manually:"
		echo "  1. Go to https://trace.playwright.dev/"
		echo "  2. Drag and drop: $TRACE_FILE"
	fi
	;;

*)
	echo "Unknown command: $COMMAND"
	echo "Run without arguments for usage."
	exit 1
	;;
esac
