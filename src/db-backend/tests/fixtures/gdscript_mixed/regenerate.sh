#!/usr/bin/env bash
#
# Regenerate the mixed-trace implicit-language-switch fixture
# (`combined_trace.ct`).
#
# The container is written by the CANONICAL Nim writer
# (`codetracer-trace-format-nim`, `multi_stream_writer` + `span_stream`), not by
# anything on the Rust side — the same cross-implementation pattern the RS-M2
# span-stream fixtures use (`../span_stream/regenerate.sh`).  The generated
# `.ct` is COMMITTED so that `cargo test` needs neither a Nim toolchain nor a
# sibling `codetracer-trace-format-nim` checkout.  Rerun this whenever the span
# wire format or the fixture's step/span layout changes; `mixed_altitude_test.rs`
# will fail loudly if the committed bytes and the reader disagree.
#
# Usage (from anywhere):
#   direnv exec <codetracer-repo-root> src/db-backend/tests/fixtures/gdscript_mixed/regenerate.sh
#
# Requires: the codetracer dev shell (provides `nim` and libzstd) and a sibling
# `codetracer-trace-format-nim` checkout, which `config.nims` puts on the Nim
# path automatically.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../../../.." && pwd)"

if ! command -v nim >/dev/null 2>&1; then
  echo "regenerate.sh: no 'nim' on PATH — run this inside the codetracer dev shell:" >&2
  echo "  direnv exec $repo_root $0" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

echo "[gdscript_mixed fixture] compiling generator with the canonical Nim writer"
# Compiled from the repo root so `config.nims` is picked up: it is what adds
# ../codetracer-trace-format-nim/src (or $CODETRACER_TRACE_FORMAT_NIM_SRC) to
# the Nim path.
cd "$repo_root"
nim c -d:release --hints:off --warnings:off \
  --out:"$work/gen_combined_fixture" \
  "$here/gen_combined_fixture.nim"

echo "[gdscript_mixed fixture] generating into $here"
"$work/gen_combined_fixture" "$here"

echo "[gdscript_mixed fixture] done:"
ls -l "$here"/*.ct
