#!/usr/bin/env bash
#
# Regenerate the aiken/simple_trivial_chain Value Origin fixture.
#
# Drives the real Cardano recorder (`codetracer-cardano-recorder`)
# against the compiled UPLC derived from `main.ak`.  The committed
# source program is the canonical fixture; the recorded trace is what
# later milestones load as a `.ct` artefact.
#
# The Aiken pipeline (`aiken build` → UPLC → recorder replay) requires
# the sibling `codetracer-cardano-recorder` Nix shell to provide `aiken`
# on PATH plus the Plutus parameter database the recorder bundles.  The
# SKIP path in `tests/origin_aiken_dap_test.rs` handles environments
# without the recorder + Aiken toolchain.
#
# Usage (after `nix develop` provides aiken + the recorder on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_AIKEN_RECORDER:-codetracer-cardano-recorder}"

exec "$RECORDER" \
	record \
	"$HERE/main.ak" \
	--out-dir "$OUT_DIR"
