#!/usr/bin/env bash
#
# Regenerate the Stylus DAP-test fixture in CTFS (.ct) format.
#
# Background
# ----------
# The fixture under tests/fixtures/stylus-fund-trace was originally a
# legacy 3-file bundle (trace.json + trace_metadata.json + trace_paths.json)
# emitted by an older version of `wazero -stylus`. db-backend now loads
# materialized traces only from CTFS (.ct) containers, so the legacy
# fixture was deleted and must be regenerated as a CTFS bundle.
#
# Prerequisites (all off-machine for the typical agent harness; that is
# why this script is run manually rather than from `cargo test`):
#
#   - A running Arbitrum devnode at http://localhost:8547 (e.g. nitro-testnode)
#   - cargo-stylus on PATH
#   - cast (Foundry) on PATH
#   - wazero binary on PATH or via CODETRACER_WASM_VM_PATH
#   - rustup target add wasm32-unknown-unknown
#
# Usage:
#
#   src/db-backend/tests/fixtures/regenerate-stylus-fixture.sh
#
# Effect:
#
#   - Builds the Stylus contract under test-programs/stylus_fund_tracker
#   - Deploys it, sends a fund(2) tx, fetches the EVM trace via cargo stylus trace
#   - Records the WASM execution with `wazero run -stylus <evm_trace>`
#   - Copies the resulting <program>.ct into
#     src/db-backend/tests/fixtures/stylus-fund-trace/
#
# After regeneration, run:
#
#   cd src/db-backend && cargo test --test stylus_flow_dap_test
#
# to verify the fixture is loadable.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FIXTURE_DIR="$REPO_ROOT/src/db-backend/tests/fixtures/stylus-fund-trace"

export STYLUS_FIXTURE_OUTPUT_DIR="$FIXTURE_DIR"

cd "$REPO_ROOT/src/db-backend"
exec cargo test --test stylus_flow_integration -- \
    --include-ignored \
    --nocapture \
    test_stylus_trace_analysis
