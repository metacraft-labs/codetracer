#!/usr/bin/env bash
#
# Regenerate the RS-M2 span-stream fixtures.
#
# The `.ct` containers in this directory are written by the CANONICAL Nim
# writer (`codetracer-trace-format-nim`, `multi_stream_writer` +
# `span_stream`), not by anything on the Rust side.  That is deliberate and is
# the whole point of the fixtures: the db-backend's Rust reader
# (`src/db-backend/src/ctfs_trace_reader/span_stream.rs`) is proved
# byte-compatible with the format by reading real writer output, exactly as
# `codetracer-trace-format-nim/tests/gen_io_event_stream_crossread_fixture.nim`
# does for `events.dat`.
#
# The generated containers are COMMITTED so that `cargo test` needs neither a
# Nim toolchain nor a sibling `codetracer-trace-format-nim` checkout.  Rerun
# this script whenever the span wire format changes; the Rust tests will fail
# loudly if the committed bytes and the reader disagree.
#
# Usage (from anywhere):
#   direnv exec <codetracer-repo-root> src/db-backend/tests/fixtures/span_stream/regenerate.sh
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

echo "[span-stream fixtures] compiling generator with the canonical Nim writer"
# Compiled from the repo root so `config.nims` is picked up: it is what adds
# ../codetracer-trace-format-nim/src (or $CODETRACER_TRACE_FORMAT_NIM_SRC) to
# the Nim path.
cd "$repo_root"
nim c -d:release --hints:off --warnings:off \
  --out:"$work/gen_span_fixtures" \
  "$here/gen_span_fixtures.nim"

echo "[span-stream fixtures] generating into $here"
"$work/gen_span_fixtures" "$here"

echo "[span-stream fixtures] done:"
ls -l "$here"/*.ct "$here"/*.jsonl
