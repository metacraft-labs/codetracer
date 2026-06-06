#!/usr/bin/env bash
#
# Regenerate the circom/simple_trivial_chain Value Origin fixture.
#
# Drives the real Circom recorder (`codetracer-circom-recorder`) against
# the circuit in `main.circom`.  The committed source program is the
# canonical fixture; the recorded trace is what later milestones load
# as a `.ct` artefact.
#
# Circom needs `circom` on PATH plus a tiny input.json fed to the
# recorder.  The SKIP path in `tests/origin_circom_dap_test.rs` handles
# environments without the recorder + Circom toolchain.
#
# Usage (after `nix develop` provides circom + the recorder on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_CIRCOM_RECORDER:-codetracer-circom-recorder}"

# The circuit takes no external inputs; the recorder still expects an
# input.json so we ship a minimal stub alongside the trace artefact.
cat >"$HERE/input.json" <<'EOF'
{}
EOF

exec "$RECORDER" \
	record \
	"$HERE/main.circom" \
	--input "$HERE/input.json" \
	--out-dir "$OUT_DIR"
