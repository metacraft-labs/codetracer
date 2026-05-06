#!/usr/bin/env bash
# Cross-repo Elixir materialized trace DAP flow runner.
#
# Subcommands:
#   e2e_cross_repo_ci_elixir_flow      Build/use sibling recorder and run the real DAP flow test
#   verify_elixir_flow_zero_test_guard Prove zero discovered tests fail the CI guard
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LOG_DIR="$REPO_ROOT/target/elixir-flow-ci-logs"
mkdir -p "$LOG_DIR"

usage() {
	cat <<'USAGE'
usage: ci/test/elixir-flow-cross-repo.sh [e2e_cross_repo_ci_elixir_flow|verify_elixir_flow_zero_test_guard]
USAGE
}

fail() {
	echo "ERROR: $*" >&2
	exit 1
}

guard_nonzero_tests() {
	local output="$1"
	if grep -Eq 'running 0 tests|0 passed; 0 failed|0 tests, 0 benchmarks' <<<"$output"; then
		echo "$output"
		echo "ERROR: Elixir flow test command discovered zero tests" >&2
		return 1
	fi
	if ! grep -q 'e2e_codetracer_elixir_flow_dap' <<<"$output"; then
		echo "$output"
		echo "ERROR: Elixir flow test output did not include e2e_codetracer_elixir_flow_dap" >&2
		return 1
	fi
}

source_sibling_detection() {
	# shellcheck disable=SC1091
	source "$REPO_ROOT/scripts/detect-siblings.sh" "$REPO_ROOT" >/dev/null
}

resolve_elixir_recorder() {
	source_sibling_detection
	: "${CODETRACER_ELIXIR_RECORDER_PATH:=${REPO_ROOT}/../codetracer-elixir-recorder}"
	[[ -d $CODETRACER_ELIXIR_RECORDER_PATH ]] ||
		fail "missing codetracer-elixir-recorder checkout: $CODETRACER_ELIXIR_RECORDER_PATH"

	local debug_bin="$CODETRACER_ELIXIR_RECORDER_PATH/target/debug/codetracer-elixir-recorder"
	local release_bin="$CODETRACER_ELIXIR_RECORDER_PATH/target/release/codetracer-elixir-recorder"

	echo "Building codetracer-elixir-recorder in $CODETRACER_ELIXIR_RECORDER_PATH"
	if command -v direnv >/dev/null 2>&1 && [[ -f "$CODETRACER_ELIXIR_RECORDER_PATH/.envrc" ]]; then
		direnv exec "$CODETRACER_ELIXIR_RECORDER_PATH" \
			cargo build --locked --manifest-path "$CODETRACER_ELIXIR_RECORDER_PATH/Cargo.toml"
	else
		cargo build --locked --manifest-path "$CODETRACER_ELIXIR_RECORDER_PATH/Cargo.toml"
	fi
	if [[ -x $debug_bin ]]; then
		export CODETRACER_ELIXIR_RECORDER_BIN="$debug_bin"
	elif [[ -x $release_bin ]]; then
		export CODETRACER_ELIXIR_RECORDER_BIN="$release_bin"
	else
		fail "recorder build succeeded but no recorder binary was found"
	fi
}

print_pin_summary() {
	local pins="$REPO_ROOT/.github/sibling-pins"
	if [[ -f $pins ]]; then
		grep -E '^(codetracer-elixir-recorder|codetracer-trace-format) ' "$pins" || true
	fi
	if [[ -d "$CODETRACER_ELIXIR_RECORDER_PATH/.git" ]]; then
		echo "codetracer-elixir-recorder HEAD: $(git -C "$CODETRACER_ELIXIR_RECORDER_PATH" rev-parse HEAD)"
	fi
	if [[ -d "$REPO_ROOT/libs/codetracer-trace-format/.git" ]]; then
		echo "codetracer-trace-format HEAD: $(git -C "$REPO_ROOT/libs/codetracer-trace-format" rev-parse HEAD)"
	fi
}

run_elixir_flow() {
	resolve_elixir_recorder
	print_pin_summary
	export TMPDIR="${TMPDIR:-/home/zahary/tmp/codex-work}"
	mkdir -p "$TMPDIR"

	local log_file="$LOG_DIR/e2e_cross_repo_ci_elixir_flow.log"
	local output status
	set +e
	output="$(
		cd "$REPO_ROOT/src/db-backend" &&
			cargo test --test elixir_flow_dap_test e2e_codetracer_elixir_flow_dap -- --nocapture 2>&1
	)"
	status=$?
	set -e
	printf '%s\n' "$output" | tee "$log_file"
	[[ $status -eq 0 ]] || exit "$status"
	guard_nonzero_tests "$output" || exit 1
}

verify_zero_test_guard() {
	local output status
	set +e
	output="$(
		cd "$REPO_ROOT/src/db-backend" &&
			cargo test --test elixir_flow_dap_test __codetracer_elixir_no_such_test__ -- --nocapture 2>&1
	)"
	status=$?
	set -e
	if [[ $status -ne 0 ]]; then
		printf '%s\n' "$output"
		fail "zero-test guard setup failed before guard could inspect cargo output"
	fi
	if guard_nonzero_tests "$output" >/dev/null 2>&1; then
		printf '%s\n' "$output"
		fail "zero-test guard accepted a vacuous cargo test run"
	fi
	printf '%s\n' "$output" >"$LOG_DIR/verify_elixir_flow_zero_test_guard.log"
	echo "verify_elixir_flow_zero_test_guard: guard rejected zero discovered tests"
}

case "${1:-e2e_cross_repo_ci_elixir_flow}" in
e2e_cross_repo_ci_elixir_flow)
	run_elixir_flow
	;;
verify_elixir_flow_zero_test_guard)
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
