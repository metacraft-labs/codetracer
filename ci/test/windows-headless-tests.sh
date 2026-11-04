#!/usr/bin/env bash
#
# windows-headless-tests.sh -- the db-backend DAP tests of the Windows
# `windows-headless-test` lane (MCR backend), with graceful skipping OFF.
#
# Run from Git Bash in env.ps1's environment, after the lane has built
# ct_mcr.exe (CODETRACER_CT_MCR_CMD names it). The DAP tests whose tools this
# lane does not provide are excluded by name through
# ci/test/headless-not-provided.windows.txt, which names where each runs.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

export CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false
# A scratch CODETRACER_HOME for the tests and every binary they spawn
# (libs/ct-home): nothing lands in the runner's or a developer's profile.
# shellcheck source=ci/lib/codetracer-home.sh
source "$REPO_ROOT/ci/lib/codetracer-home.sh"
ct_export_scratch_codetracer_home windows-headless
# Fail the run if anything it ran wrote the developer's real CodeTracer
# state (ci/lib/codetracer-home.sh, the guard). The scratch home is left in
# place, as it always was here: a Windows process still holding a file in it
# would make its removal fail the run for a reason that is not a test's.
# shellcheck disable=SC2154 # _ct_rc is assigned by the trap itself, first
trap '_ct_rc=$?; ct_user_state_guard_exit windows-headless "$_ct_rc"' EXIT
filter="$(bash "$REPO_ROOT/ci/lib/not-provided-filter.sh" "$REPO_ROOT/ci/test/headless-not-provided.windows.txt" "$REPO_ROOT/src/db-backend/tests")"

cd "$REPO_ROOT/src/db-backend"
cargo nextest run --release --test '*' -E "test(~dap) and ($filter)"
