#!/usr/bin/env bash
#
# Regenerate the solana/simple_trivial_chain Value Origin fixture.
#
# Drives the real Solana recorder (`codetracer-solana-recorder`) against
# the compiled sBPF binary derived from `main.rs`.  The committed source
# program is the canonical fixture; the recorded trace is what later
# milestones load as a `.ct` artefact.
#
# Solana's record pipeline requires `cargo build-sbf` plus a small
# scaffolded Cargo project; teams that rebuild this fixture rely on the
# sibling `codetracer-solana-recorder` Nix shell.  The SKIP path in
# `tests/origin_solana_dap_test.rs` handles environments without the
# recorder + sBPF toolchain.
#
# Usage (after `nix develop` provides cargo-build-sbf + the recorder
# on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_SOLANA_RECORDER:-codetracer-solana-recorder}"

exec "$RECORDER" \
	record \
	"$HERE/main.rs" \
	--out-dir "$OUT_DIR"
