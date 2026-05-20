#!/usr/bin/env bash
#
# Regenerate the Stylus DAP-test fixture in CTFS (.ct) format.
#
# Background
# ----------
# The fixture under tests/fixtures/stylus-fund-trace was originally a
# legacy 3-file bundle (trace.json + trace_metadata.json + trace_paths.json)
# emitted by an older version of `wazero -stylus`. db-backend now loads
# materialized traces only from CTFS (.ct) containers.
#
# The recorded Stylus trace data itself is deterministic (a `fund(2)`
# transaction against the `stylus_fund_tracker` contract) and is committed
# in this repo as:
#
#   tests/fixtures/stylus-fund-trace/trace.events.json   (event stream)
#   tests/fixtures/stylus-fund-trace/trace_metadata.json (program/args/workdir)
#   tests/fixtures/stylus-fund-trace/trace_paths.json    (source paths)
#
# This script repacks that committed data into the canonical
# `stylus_fund_tracking_demo.ct` container the DAP tests load. It needs
# no devnode and no blockchain toolchain — it is purely offline.
#
# Usage:
#
#   src/db-backend/tests/fixtures/regenerate-stylus-fixture.sh
#
# Re-recording from scratch (only needed when the contract or recorder
# changes)
# --------------------------------------------------------------------
# To capture a *fresh* trace rather than repack the committed one, run
# the recording-tier integration test with the full Arbitrum toolchain:
#
#   - A running Arbitrum devnode at http://localhost:8547 (nitro-testnode)
#   - cargo-stylus, cast (Foundry), and wazero on PATH
#   - rustup target add wasm32-unknown-unknown
#
#   cd src/db-backend && \
#     STYLUS_FIXTURE_OUTPUT_DIR=tests/fixtures/stylus-fund-trace \
#     cargo test --test stylus_flow_integration -- \
#       --include-ignored --nocapture test_stylus_trace_analysis
#
# then re-export trace.events.json from the recorded `.ct` and re-run
# this script.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"

cd "$REPO_ROOT/src/db-backend"
exec cargo test --test stylus_fixture_rebuild -- \
    --ignored \
    --nocapture \
    rebuild_stylus_ctfs_fixture
