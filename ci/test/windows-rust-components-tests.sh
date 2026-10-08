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
if [ -z "${CT_NATIVE_REPLAY_PATH:-}" ]; then
	replay="$WORKSPACE_ROOT/codetracer-native-backend/target/debug/ct-native-replay.exe"
	if [ -f "$replay" ]; then
		export CT_NATIVE_REPLAY_PATH="$replay"
	fi
fi

filter="$(bash "$REPO_ROOT/ci/lib/not-provided-filter.sh" "$REPO_ROOT/ci/test/rust-components-not-provided.windows.txt")"

cd "$REPO_ROOT/src/db-backend"
# Unit tests (library and binaries) and integration tests, in one nextest run;
# the filter only names integration-test binaries.
cargo nextest run -E "$filter"
# Doc tests, which nextest does not run.
cargo test --doc
