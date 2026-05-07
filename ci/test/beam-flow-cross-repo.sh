#!/usr/bin/env bash
# Cross-repo BEAM (Elixir + Erlang) materialized trace DAP flow runner.
#
# Subcommands:
#   e2e_cross_repo_ci_elixir_flow       Real DAP flow test for the Elixir canonical fixture
#   e2e_cross_repo_ci_erlang_flow       Real DAP flow test for the Erlang canonical fixture
#   e2e_cross_repo_ci_beam_flow         Run both Elixir and Erlang DAP flow tests
#   verify_beam_flow_zero_test_guard    Prove zero discovered tests fail the CI guard
#
# Real sibling clones, real recorder build, real db-backend, real DAP. No mocks.
# Replaces the legacy `elixir-flow-cross-repo.sh` shim during the BEAM rename
# migration window.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="$REPO_ROOT/target/beam-flow-ci-logs"
mkdir -p "$LOG_DIR"

usage() {
	cat <<'USAGE'
usage: ci/test/beam-flow-cross-repo.sh [
  e2e_cross_repo_ci_elixir_flow |
  e2e_cross_repo_ci_erlang_flow |
  e2e_cross_repo_ci_beam_flow |
  verify_beam_flow_zero_test_guard
]
USAGE
}

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

# Guard against vacuous CI passes. Cargo and the test runners both have failure
# modes where zero tests run but the exit status is 0; the BEAM CI must fail
# loudly when that happens. Caller passes the cargo output and the test name we
# expect to see in it.
guard_nonzero_tests() {
	local output="$1"
	local expected_test="$2"
	if grep -Eq 'running 0 tests|0 passed; 0 failed|0 tests, 0 benchmarks' <<<"$output"; then
		echo "$output"
		echo "ERROR: BEAM flow test command discovered zero tests (expected $expected_test)" >&2
		return 1
	fi
	if ! grep -q "$expected_test" <<<"$output"; then
		echo "$output"
		echo "ERROR: BEAM flow test output did not include $expected_test" >&2
		return 1
	fi
}

source_sibling_detection() {
	# shellcheck disable=SC1091
	source "$REPO_ROOT/scripts/detect-siblings.sh" "$REPO_ROOT" >/dev/null
}

# Resolve the beam recorder repo + binary, building it once if needed. Sets
# CODETRACER_BEAM_RECORDER_PATH and CODETRACER_BEAM_RECORDER_BIN (and the
# legacy ELIXIR aliases for the migration window).
resolve_beam_recorder() {
	source_sibling_detection

	# Prefer the BEAM-prefixed env var; fall back to the legacy alias for one
	# release cycle.
	if [[ -z ${CODETRACER_BEAM_RECORDER_PATH:-} ]]; then
		if [[ -d ${REPO_ROOT}/../codetracer-beam-recorder ]]; then
			CODETRACER_BEAM_RECORDER_PATH="${REPO_ROOT}/../codetracer-beam-recorder"
		elif [[ -n ${CODETRACER_ELIXIR_RECORDER_PATH:-} ]]; then
			CODETRACER_BEAM_RECORDER_PATH="$CODETRACER_ELIXIR_RECORDER_PATH"
		elif [[ -d ${REPO_ROOT}/../codetracer-elixir-recorder ]]; then
			CODETRACER_BEAM_RECORDER_PATH="${REPO_ROOT}/../codetracer-elixir-recorder"
		fi
	fi

	[[ -d ${CODETRACER_BEAM_RECORDER_PATH:-} ]] ||
		fail "missing codetracer-beam-recorder checkout (set CODETRACER_BEAM_RECORDER_PATH)"
	export CODETRACER_BEAM_RECORDER_PATH
	export CODETRACER_ELIXIR_RECORDER_PATH="$CODETRACER_BEAM_RECORDER_PATH"

	echo "Building codetracer-beam-recorder in $CODETRACER_BEAM_RECORDER_PATH"
	if command -v direnv >/dev/null 2>&1 && [[ -f "$CODETRACER_BEAM_RECORDER_PATH/.envrc" ]]; then
		direnv exec "$CODETRACER_BEAM_RECORDER_PATH" \
			cargo build --locked --manifest-path "$CODETRACER_BEAM_RECORDER_PATH/Cargo.toml"
	else
		cargo build --locked --manifest-path "$CODETRACER_BEAM_RECORDER_PATH/Cargo.toml"
	fi

	# Search for the binary under both the new and legacy names so the build
	# survives the migration window.
	local profile binary_name candidate
	for profile in debug release; do
		for binary_name in codetracer-beam-recorder codetracer-elixir-recorder; do
			candidate="$CODETRACER_BEAM_RECORDER_PATH/target/$profile/$binary_name"
			if [[ -x $candidate ]]; then
				export CODETRACER_BEAM_RECORDER_BIN="$candidate"
				export CODETRACER_ELIXIR_RECORDER_BIN="$candidate"
				return 0
			fi
		done
	done
	fail "recorder build succeeded but no recorder binary was found under target/{debug,release}"
}

print_pin_summary() {
	local pins="$REPO_ROOT/.github/sibling-pins"
	if [[ -f $pins ]]; then
		grep -E '^(codetracer-beam-recorder|codetracer-elixir-recorder|codetracer-trace-format) ' "$pins" || true
	fi
	if [[ -d "$CODETRACER_BEAM_RECORDER_PATH/.git" ]]; then
		echo "codetracer-beam-recorder HEAD: $(git -C "$CODETRACER_BEAM_RECORDER_PATH" rev-parse HEAD)"
	fi
	if [[ -d "$REPO_ROOT/libs/codetracer-trace-format/.git" ]]; then
		echo "codetracer-trace-format HEAD: $(git -C "$REPO_ROOT/libs/codetracer-trace-format" rev-parse HEAD)"
	fi
}

run_one_flow() {
	# usage: run_one_flow <test_binary_name> <expected_test_function> <log_basename>
	local test_binary="$1"
	local expected_test="$2"
	local log_basename="$3"
	resolve_beam_recorder
	print_pin_summary
	export TMPDIR="${TMPDIR:-/tmp/codetracer-beam-flow}"
	mkdir -p "$TMPDIR"

	local log_file="$LOG_DIR/$log_basename.log"
	local output status
	set +e
	output="$(
		cd "$REPO_ROOT/src/db-backend" &&
			cargo test --test "$test_binary" "$expected_test" -- --nocapture 2>&1
	)"
	status=$?
	set -e
	printf '%s\n' "$output" | tee "$log_file"
	[[ $status -eq 0 ]] || exit "$status"
	guard_nonzero_tests "$output" "$expected_test" || exit 1
}

run_elixir_flow() {
	run_one_flow "elixir_flow_dap_test" "e2e_codetracer_elixir_flow_dap" "e2e_cross_repo_ci_elixir_flow"
}

run_erlang_flow() {
	run_one_flow "erlang_flow_dap_test" "e2e_codetracer_erlang_flow_dap" "e2e_cross_repo_ci_erlang_flow"
}

run_beam_flow() {
	run_elixir_flow
	run_erlang_flow
}

verify_zero_test_guard() {
	# Run a non-existent test name against the elixir test binary and prove
	# the guard rejects the resulting "0 tests" output.
	resolve_beam_recorder
	local output status
	set +e
	output="$(
		cd "$REPO_ROOT/src/db-backend" &&
			cargo test --test elixir_flow_dap_test __codetracer_beam_no_such_test__ -- --nocapture 2>&1
	)"
	status=$?
	set -e
	if [[ $status -ne 0 ]]; then
		printf '%s\n' "$output"
		fail "zero-test guard setup failed before guard could inspect cargo output"
	fi
	if guard_nonzero_tests "$output" "e2e_codetracer_elixir_flow_dap" >/dev/null 2>&1; then
		printf '%s\n' "$output"
		fail "zero-test guard accepted a vacuous cargo test run"
	fi
	# Also exercise the guard against the erlang binary so a regression in
	# either test target is caught.
	set +e
	output="$(
		cd "$REPO_ROOT/src/db-backend" &&
			cargo test --test erlang_flow_dap_test __codetracer_beam_no_such_test__ -- --nocapture 2>&1
	)"
	status=$?
	set -e
	if [[ $status -ne 0 ]]; then
		printf '%s\n' "$output"
		fail "zero-test guard setup (erlang) failed before guard could inspect cargo output"
	fi
	if guard_nonzero_tests "$output" "e2e_codetracer_erlang_flow_dap" >/dev/null 2>&1; then
		printf '%s\n' "$output"
		fail "zero-test guard (erlang) accepted a vacuous cargo test run"
	fi
	printf '%s\n' "$output" >"$LOG_DIR/verify_beam_flow_zero_test_guard.log"
	echo "verify_beam_flow_zero_test_guard: guard rejected zero discovered tests for both Elixir and Erlang"
}

case "${1:-e2e_cross_repo_ci_beam_flow}" in
e2e_cross_repo_ci_beam_flow)
	run_beam_flow
	;;
e2e_cross_repo_ci_elixir_flow)
	run_elixir_flow
	;;
e2e_cross_repo_ci_erlang_flow)
	run_erlang_flow
	;;
verify_beam_flow_zero_test_guard)
	verify_zero_test_guard
	;;
-h | --help)
	usage
	;;
*)
	usage >&2
	exit 2
	;;
esac
