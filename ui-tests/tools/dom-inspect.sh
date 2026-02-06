#!/usr/bin/env bash
# Simple DOM inspection tool for test diagnostics
# Usage: ./dom-inspect.sh <html-file> [command] [args]
#
# Commands:
#   ids           - List all element IDs
#   classes       - List all unique class names (top 50)
#   components    - Find CodeTracer components (eventLog, callTrace, editor, etc.)
#   search <text> - Search for text/pattern in the HTML
#   inputs        - Find all input/textarea elements
#   buttons       - Find all buttons
#   hidden        - Find elements with display:none or visibility:hidden
#   stats         - Show quick statistics

set -e

HTML_FILE="${1:-}"
COMMAND="${2:-stats}"
ARG="${3:-}"

if [[ -z $HTML_FILE ]]; then
	echo "Usage: $0 <html-file> [command] [args]"
	echo ""
	echo "Commands:"
	echo "  ids           - List all element IDs"
	echo "  classes       - List all unique class names (top 50)"
	echo "  components    - Find CodeTracer components"
	echo "  search <text> - Search for text/pattern in the HTML"
	echo "  inputs        - Find all input/textarea elements"
	echo "  buttons       - Find all buttons"
	echo "  hidden        - Find elements with display:none"
	echo "  stats         - Show quick statistics (default)"
	exit 1
fi

if [[ ! -f $HTML_FILE ]]; then
	echo "Error: File not found: $HTML_FILE"
	exit 1
fi

case "$COMMAND" in
ids)
	echo "Elements with IDs:"
	grep -oP 'id="[^"]*"' "$HTML_FILE" | sort | uniq -c | sort -rn | head -100
	;;

classes)
	echo "Top 50 class names:"
	grep -oP 'class="[^"]*"' "$HTML_FILE" |
		sed 's/class="//;s/"$//' |
		tr ' ' '\n' |
		grep -v '^$' |
		sort | uniq -c | sort -rn | head -50
	;;

components)
	echo "CodeTracer Components:"
	echo ""
	echo "Event Log:"
	grep -oP 'id="[^"]*eventLog[^"]*"' "$HTML_FILE" 2>/dev/null | head -10 || echo "  (none found)"
	echo ""
	echo "Call Trace:"
	grep -oP 'id="[^"]*callTrace[^"]*"' "$HTML_FILE" 2>/dev/null | head -10 || echo "  (none found)"
	echo ""
	echo "Editor:"
	grep -oP 'id="[^"]*editor[^"]*"' "$HTML_FILE" 2>/dev/null | head -10 || echo "  (none found)"
	echo ""
	echo "Source:"
	grep -oP 'id="[^"]*source[^"]*"' "$HTML_FILE" 2>/dev/null | head -10 || echo "  (none found)"
	echo ""
	echo "Trace Log:"
	grep -oP 'id="[^"]*traceLog[^"]*"' "$HTML_FILE" 2>/dev/null | head -10 || echo "  (none found)"
	echo ""
	echo "Variables:"
	grep -oP 'id="[^"]*variables[^"]*"' "$HTML_FILE" 2>/dev/null | head -10 || echo "  (none found)"
	echo ""
	echo "Monaco Editors:"
	grep -c 'class="[^"]*monaco-editor' "$HTML_FILE" 2>/dev/null || echo "0"
	;;

search)
	if [[ -z $ARG ]]; then
		echo "Usage: $0 <html-file> search <pattern>"
		exit 1
	fi
	echo "Searching for: $ARG"
	grep -n -i "$ARG" "$HTML_FILE" | head -50
	;;

inputs)
	echo "Input elements:"
	grep -oP '<(input|textarea)[^>]*>' "$HTML_FILE" | head -30
	;;

buttons)
	echo "Button elements:"
	grep -oP '<button[^>]*>[^<]*</button>' "$HTML_FILE" | head -30
	;;

hidden)
	echo "Hidden elements (display:none in style attribute):"
	grep -oP '<[^>]*style="[^"]*display:\s*none[^"]*"[^>]*>' "$HTML_FILE" | head -20
	;;

stats)
	echo "DOM Statistics for: $HTML_FILE"
	echo "================================"
	echo "File size: $(du -h "$HTML_FILE" | cut -f1)"
	echo "Total lines: $(wc -l <"$HTML_FILE")"
	echo ""
	echo "Element counts:"
	echo "  <div>: $(grep -c '<div' "$HTML_FILE" 2>/dev/null || echo 0)"
	echo "  <span>: $(grep -c '<span' "$HTML_FILE" 2>/dev/null || echo 0)"
	echo "  <input>: $(grep -c '<input' "$HTML_FILE" 2>/dev/null || echo 0)"
	echo "  <textarea>: $(grep -c '<textarea' "$HTML_FILE" 2>/dev/null || echo 0)"
	echo "  <button>: $(grep -c '<button' "$HTML_FILE" 2>/dev/null || echo 0)"
	echo "  <svg>: $(grep -c '<svg' "$HTML_FILE" 2>/dev/null || echo 0)"
	echo ""
	echo "CodeTracer components:"
	echo "  eventLog: $(grep -c 'eventLog' "$HTML_FILE" 2>/dev/null || echo 0) occurrences"
	echo "  callTrace: $(grep -c 'callTrace' "$HTML_FILE" 2>/dev/null || echo 0) occurrences"
	echo "  editorComponent: $(grep -c 'editorComponent' "$HTML_FILE" 2>/dev/null || echo 0) occurrences"
	echo "  monaco-editor: $(grep -c 'monaco-editor' "$HTML_FILE" 2>/dev/null || echo 0) occurrences"
	echo ""
	echo "Elements with IDs: $(grep -oP 'id="[^"]+"' "$HTML_FILE" | wc -l)"
	;;

*)
	echo "Unknown command: $COMMAND"
	echo "Run without arguments for usage."
	exit 1
	;;
esac
