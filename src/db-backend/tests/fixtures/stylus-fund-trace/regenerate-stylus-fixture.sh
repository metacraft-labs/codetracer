#!/usr/bin/env bash
#
# Regenerate the Stylus DAP-test fixture in CTFS (.ct) format via
# the M27 generic WASM instrumentation pipeline (the M28 deliverable
# that replaces the legacy Stylus-node-only path).
#
# Background
# ----------
# The fixture under this directory was originally recorded by the
# hand-written Stylus host module at
# codetracer-wasm-recorder/internal/stylus/. M28 retires that path
# in favour of:
#
#   * The TOML host-module config at
#     codetracer-evm-recorder/stylus/codetracer.toml — the single
#     source of truth for the `vm_hooks` import list.
#   * The M27 generic host-module framework
#     (codetracer-wasm-host-module-framework) which reads that TOML
#     and emits a PassThroughPlan the wazero recorder consumes.
#   * The M27 `ct instrument` bytecode-rewriter for the browser /
#     embedder cases.
#
# The recorded EVM trace data itself is deterministic (a `fund(2)`
# transaction against the `stylus_fund_tracker` contract) and is
# committed in this repo as:
#
#   trace.events.json   (event stream)
#   trace_metadata.json (program/args/workdir)
#   trace_paths.json    (source paths)
#
# This script repacks that committed data into the canonical
# `stylus_fund_tracking_demo.ct` container the DAP tests load. It
# routes through the M27 `stylus_fixture_rebuild` test harness — a
# deterministic packer that produces byte-equivalent output across
# reruns (fixed UUIDv7 recording_id, CBOR-streamed events with no
# wall-clock timestamps).
#
# This script needs no devnode and no blockchain toolchain — it is
# purely offline.
#
# Usage:
#
#   src/db-backend/tests/fixtures/stylus-fund-trace/regenerate-stylus-fixture.sh
#
# Re-recording from scratch (only needed when the contract or
# recorder changes)
# ------------------------------------------------------------------
# To capture a *fresh* trace rather than repack the committed one,
# run the full M27 recording pipeline:
#
#   1. Build the contract with cargo-stylus (debug profile, DWARF
#      preserved).
#   2. Either:
#      (a) Run the instrumented module through `ct instrument` and
#          the recorder-runtime/host_runtime.js batcher, or
#      (b) Run the original module through the wazero recorder
#          configured with the PassThroughPlan derived from
#          codetracer-evm-recorder/stylus/codetracer.toml.
#   3. Re-export trace.events.json from the recorded `.ct` and re-run
#      this script.
#
# Both routes (a) and (b) must produce equivalent traces per M28
# deliverable #2. The parity test at
# codetracer-wasm-instrumenter/crates/codetracer-wasm-host-module-framework/tests/stylus_parity.rs
# pins the structural contract.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"

cd "$REPO_ROOT/src/db-backend"

# Delegate to the M27-aware Rust harness (stylus_fixture_rebuild).
# That harness reads codetracer-evm-recorder/stylus/codetracer.toml
# via the M27 PassThroughPlan factory + writes the .ct via the
# production CTFS packer. The `--ignored` flag opts into the
# heavyweight regeneration path that normal `cargo test` skips.
exec cargo test --test stylus_fixture_rebuild -- \
	--ignored \
	--nocapture \
	rebuild_stylus_ctfs_fixture
