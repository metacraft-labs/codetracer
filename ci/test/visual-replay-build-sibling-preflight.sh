#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="${1:-$(cd "$(dirname "$0")/../../.." && pwd)}"

# These are the concrete sibling sources consumed while CodeTracer's build
# prerequisites compile. Keep this list aligned with the lock-resolved
# `visual-replay-regression-gate` sibling inventory. Checking the imported
# module or manifest (rather than only the repository directory) catches an
# incomplete or incompatible checkout before Tup fans out the real build.
REQUIRED_BUILD_SIBLING_FILES=(
	"isonim/src/isonim/core/platform.nim"
	"nim-everywhere/src/nim_everywhere/platform.nim"
	"nim-acp/src/nim_acp.nim"
	"nim-agent-harbor/src/nim_agent_harbor.nim"
	"nim-agents/src/nim_agents.nim"
	"codetracer-trace-format/codetracer_ctfs/Cargo.toml"
	"codetracer-trace-format-nim/src/codetracer_trace_writer/new_trace_reader.nim"
	"io-mon/src/io_mon.nim"
	"nim-shm-queue/src/shm_queue/ring.nim"
	"nim-stackable-hooks/src/stackable_hooks/propagation.nim"
)

for required_file in "${REQUIRED_BUILD_SIBLING_FILES[@]}"; do
	if [[ ! -f $WORKSPACE_ROOT/$required_file ]]; then
		echo "Missing required visual replay build sibling source: ../$required_file" >&2
		exit 1
	fi
done
