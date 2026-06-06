#!/usr/bin/env bash
#
# Regenerate the sway/simple_trivial_chain Value Origin fixture.
#
# Drives the real Fuel recorder (`codetracer-fuel-recorder`) against the
# compiled Sway script derived from `main.sw`.  The committed source
# program is the canonical fixture; the recorded trace is what later
# milestones load as a `.ct` artefact.
#
# Sway's `forc build` pipeline expects a project directory with a
# `Forc.toml` and `src/main.sw` layout; this script provisions a tiny
# scratch project around `main.sw` so a stand-alone bash invocation
# stays self-contained.  Real CI runs invoke the recorder against the
# sibling `codetracer-fuel-recorder/test-programs/flow_test/` project
# instead — the SKIP path in `tests/origin_sway_dap_test.rs` ensures
# environments without the recorder + `forc` toolchain skip cleanly.
#
# Usage (after `nix develop` provides forc + the recorder on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_FUEL_RECORDER:-codetracer-fuel-recorder}"

# Provision a scratch Forc project so `forc build` has the layout it
# expects.  The script is idempotent — re-running it overwrites the
# scratch directory.
SCRATCH="$HERE/build/scratch_project"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH/src"
cp "$HERE/main.sw" "$SCRATCH/src/main.sw"
cat >"$SCRATCH/Forc.toml" <<'EOF'
[project]
name = "simple_trivial_chain"
authors = ["CodeTracer"]
entry = "main.sw"
license = "Apache-2.0"

[dependencies]
EOF

(
	cd "$SCRATCH"
	forc build
)

exec "$RECORDER" \
	record \
	--bytecode "$SCRATCH/out/debug/simple_trivial_chain.bin" \
	--out-dir "$OUT_DIR"
