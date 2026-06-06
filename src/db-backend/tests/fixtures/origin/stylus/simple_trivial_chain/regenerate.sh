#!/usr/bin/env bash
#
# Regenerate the stylus/simple_trivial_chain Value Origin fixture.
#
# Drives the real EVM recorder (`codetracer-evm-recorder`) against the
# compiled Stylus contract derived from `main.rs`.  The committed source
# program is the canonical fixture; the recorded trace is what later
# milestones load as a `.ct` artefact.
#
# This script is the canonical re-recording entrypoint for this
# scenario. It does NOT need to succeed in CI without the recorder
# checked out as a sibling repo; what M23 ships is the script's
# existence, the correct invocation shape, and the canonical source
# program. CI runs that lack the recorder use the SKIP path in
# `tests/origin_stylus_dap_test.rs`.
#
# Usage (after `nix develop` provides the recorder + cargo-stylus on
# PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_EVM_RECORDER:-codetracer-evm-recorder}"

# The EVM recorder pipeline differs from the simpler "interpreter"
# recorders: it builds the program with cargo-stylus → WASM → on-chain
# bytecode, deploys to a local anvil instance, replays the call, and
# captures the EVM step stream.  The committed `main.rs` here only
# captures the source-level fixture; rebuilding it through that pipeline
# requires the full sibling repo + `nix develop`.
exec "$RECORDER" \
	record \
	"$HERE/main.rs" \
	--trace-dir "$OUT_DIR"
