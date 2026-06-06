#!/usr/bin/env bash
#
# Regenerate the noir/simple_trivial_chain Value Origin fixture.
#
# Drives the Noir recorder (the `nargo`-based pipeline already used by
# the existing `noir_flow_dap_test.rs` test) against the program in
# `main.nr`.  The committed source program is the canonical fixture; the
# recorded trace is what later milestones load as a `.ct` artefact.
#
# The SKIP path in `tests/origin_noir_dap_test.rs` handles environments
# without `nargo` on PATH.
#
# Usage (after `nix develop` provides nargo on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

# Scaffold the Nargo project layout (Nargo.toml + src/) so `nargo trace`
# has the structure it expects.  Re-running this script overwrites the
# scratch project, keeping the regenerator idempotent.
SCRATCH="$HERE/build/scratch_project"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/src"
cp "$HERE/main.nr" "$SCRATCH/src/main.nr"
cat >"$SCRATCH/Nargo.toml" <<'EOF'
[package]
name = "simple_trivial_chain"
type = "bin"
authors = ["CodeTracer"]
compiler_version = ">=0.30.0"

[dependencies]
EOF
# No inputs needed for a straight-literal compute; ship an empty stub so
# `nargo trace` doesn't error on a missing Prover.toml.
cat >"$SCRATCH/Prover.toml" <<'EOF'
EOF

(
	cd "$SCRATCH"
	nargo trace --out-dir "$OUT_DIR"
)
