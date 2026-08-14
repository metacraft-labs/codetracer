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
	# io-mon and nim-shm-gset are a MATCHED PAIR, for the same reason
	# codetracer-trace-format and codetracer-trace-format-nim are. `io_mon.nim`
	# imports `io_mon/writer` and `io_mon/fs_snoop`, both of which import
	# `shm_gset` / `shm_gset/transport` -- the grow-only shared-memory set that
	# backs io-mon's Linux dependency-capture channel. Nothing in io-mon's own
	# manifest names nim-shm-gset (io-mon resolves it as a plain sibling via its
	# `config.nims` `SHM_GSET_SRC` default), so provisioning io-mon alone looks
	# complete and is not.
	#
	# The repo-root `config.nims` threads it on with `addPathIfDir`, which is
	# SILENT when the directory is absent: the missing sibling does not surface
	# at provisioning time, it surfaces much later as
	#
	#     cannot open file: shm_gset/transport
	#
	# out of the `ct` compile. Checking it here names the real cause instead.
	"nim-shm-gset/src/shm_gset/transport.nim"
	"nim-stackable-hooks/src/stackable_hooks/propagation.nim"
)

for required_file in "${REQUIRED_BUILD_SIBLING_FILES[@]}"; do
	if [[ ! -f $WORKSPACE_ROOT/$required_file ]]; then
		echo "Missing required visual replay build sibling source: ../$required_file" >&2
		exit 1
	fi
done
