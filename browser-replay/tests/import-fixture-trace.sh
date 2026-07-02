#!/usr/bin/env bash
# Import a .ct fixture trace into a temporary trace folder suitable for ct host.
#
# Usage: import-fixture-trace.sh <trace.ct> [--program <name>] [--lang <lang>]
#
# Creates a trace folder with the expected layout:
#   trace_db_metadata.json  (for RR/MCR trace detection)
#   trace.ct                (the CTFS container)
#   trace_paths.json        (source file path list)
#   files/                  (source files, if found alongside the trace)
#   binaries/               (portable payload binaries, if present)
#
# Prints the path of the created trace folder to stdout.
set -euo pipefail

usage() {
	echo "Usage: $0 <trace.ct> [--program <name>] [--lang <lang>]"
	exit 1
}

if [ $# -lt 1 ]; then
	usage
fi

CT_TRACE_FILE="$1"
shift

PROGRAM_NAME="fixture_prog"
LANG="c"

while [ $# -gt 0 ]; do
	case "$1" in
	--program)
		PROGRAM_NAME="$2"
		shift 2
		;;
	--lang)
		LANG="$2"
		shift 2
		;;
	*)
		echo "Unknown option: $1" >&2
		usage
		;;
	esac
done

if [ ! -f "$CT_TRACE_FILE" ]; then
	echo "Error: trace file not found: $CT_TRACE_FILE" >&2
	exit 1
fi

# Create a temporary trace folder with a descriptive prefix
TRACE_DIR=$(mktemp -d /tmp/ct-fixture-trace-XXXXXX)

# Copy the .ct file
cp "$CT_TRACE_FILE" "$TRACE_DIR/trace.ct"

# Copy source files if available alongside the trace.
# Handle both regular files and symlinks (the example recordings repo
# may use symlinks for shared source files).
TRACE_PARENT=$(dirname "$CT_TRACE_FILE")
for src_ext in c cpp rs py rb; do
	for src_file in "$TRACE_PARENT"/source."$src_ext"; do
		if [ -e "$src_file" ]; then
			REAL_SOURCE=$(readlink -f "$src_file")
			if [ -f "$REAL_SOURCE" ]; then
				mkdir -p "$TRACE_DIR/files"
				cp "$REAL_SOURCE" "$TRACE_DIR/files/$(basename "$src_file")"
			fi
		fi
	done
done

# Copy binaries if present (portable payload for cross-platform replay)
if [ -d "$TRACE_PARENT/binaries" ]; then
	cp -r "$TRACE_PARENT/binaries" "$TRACE_DIR/binaries"
fi

# Create trace_db_metadata.json (tells ct this is an RR/MCR trace)
cat >"$TRACE_DIR/trace_db_metadata.json" <<EOF
{
  "program": "$PROGRAM_NAME",
  "args": [],
  "workdir": "$TRACE_DIR",
  "lang": "$LANG",
  "traceKind": "rr",
  "tracePath": "$TRACE_DIR/trace.ct"
}
EOF

# Create trace_paths.json (source file paths, empty for fixture traces)
cat >"$TRACE_DIR/trace_paths.json" <<'EOF'
[]
EOF

# Output the trace folder path
echo "$TRACE_DIR"
