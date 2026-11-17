#!/usr/bin/env bash
#
# windows-rust-components-tests.sh -- the db-backend tests of the Windows
# `windows-rust-components` lane, with graceful skipping OFF.
#
# Run from Git Bash inside env.ps1's environment (the lane runs it through
# `dev-exec`). The integration tests whose tools this lane does not provide are
# excluded by name through ci/test/rust-components-not-provided.windows.txt,
# which names where each of them runs; every other test that finds a
# prerequisite missing FAILS here instead of passing having asserted nothing.
#
# `ct-native-replay` comes from the codetracer-native-backend sibling the lane
# builds; CT_NATIVE_REPLAY_PATH points the tests at it when it is not already
# set.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

export CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false
# A scratch CODETRACER_HOME for the tests and every binary they spawn
# (libs/ct-home): nothing lands in the runner's or a developer's profile.
# shellcheck source=ci/lib/codetracer-home.sh
source "$REPO_ROOT/ci/lib/codetracer-home.sh"
# On Linux the run happens again inside a sandbox over the user's state, so
# only its own writes can fail it (ci/lib/codetracer-home.sh). Elsewhere the
# call returns and the comparison in the EXIT trap is the guard.
ct_user_state_stage_sandbox windows-rust-components bash "$0" "$@" || :
ct_export_scratch_codetracer_home windows-rust-components
# Remove the home this run made (ct_remove_scratch_codetracer_home: it
# retries while a Windows process that is still exiting holds a file in it,
# and never fails the run for that; CT_KEEP_SCRATCH_HOME=1 keeps it), then
# fail the run if anything it ran wrote the developer's real CodeTracer state
# (ci/lib/codetracer-home.sh, the guard). Until 2026-11-11 the home was left
# in place, and every run left one in the runner's temp directory for good.
# shellcheck disable=SC2154 # _ct_rc is assigned by the trap itself, first
trap '_ct_rc=$?; ct_remove_scratch_codetracer_home windows-rust-components; ct_user_state_guard_exit windows-rust-components "$_ct_rc"' EXIT
if [ -z "${CT_NATIVE_REPLAY_PATH:-}" ]; then
	replay="$WORKSPACE_ROOT/codetracer-native-backend/target/debug/ct-native-replay.exe"
	if [ -f "$replay" ]; then
		export CT_NATIVE_REPLAY_PATH="$replay"
	fi
fi

filter="$(bash "$REPO_ROOT/ci/lib/not-provided-filter.sh" "$REPO_ROOT/ci/test/rust-components-not-provided.windows.txt" "$REPO_ROOT/src/db-backend/tests")"

cd "$REPO_ROOT/src/db-backend"
# Unit tests (library and binaries) and integration tests, in one nextest run;
# the filter only names integration-test binaries.
cargo nextest run -E "$filter"
# Doc tests, which nextest does not run.
cargo test --doc
