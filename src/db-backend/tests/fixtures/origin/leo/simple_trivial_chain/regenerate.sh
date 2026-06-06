#!/usr/bin/env bash
#
# Regenerate the leo/simple_trivial_chain Value Origin fixture.
#
# Drives the real Leo recorder (`codetracer-leo-recorder`) against the
# program in `main.leo`.  The committed source program is the canonical
# fixture; the recorded trace is what later milestones load as a `.ct`
# artefact.
#
# The Leo recorder requires Aleo's `leo` CLI on PATH.  The SKIP path in
# `tests/origin_leo_dap_test.rs` handles environments without the
# recorder + Leo toolchain.
#
# Usage (after `nix develop` provides leo + the recorder on $PATH):
#     ./regenerate.sh
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

OUT_DIR="${OUT_DIR:-$HERE/trace}"
mkdir -p "$OUT_DIR"

RECORDER="${CODETRACER_LEO_RECORDER:-codetracer-leo-recorder}"

exec "$RECORDER" \
	record \
	"$HERE/main.leo" \
	--out-dir "$OUT_DIR"
