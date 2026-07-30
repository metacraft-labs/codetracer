#!/usr/bin/env bash

# Required M29 cross-process value-origin CI envelope.
#
# The three-trace fixture is committed test data. CI must therefore fail when
# the fixture, its recovery tool, a required test spec, or a display provider
# is missing; accepting a recorder-dependent skip would turn this gate into a
# false success. The shell contract is exercised hermetically by
# ci/test/cross-process-gate.sh before the real Rust and Playwright stages run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="${CROSS_PROCESS_REPO_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
readonly REPO_ROOT
FIXTURE_DIR="$REPO_ROOT/src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm"
readonly FIXTURE_DIR

readonly CROSS_PROCESS_TARGET="cross_process_origin_test"
readonly LIST_PROCESSES_TARGET="dap_server_list_processes_event_test"
readonly CROSS_PROCESS_EXPECTED_COUNT=7
readonly LIST_PROCESSES_EXPECTED_COUNT=5
readonly RUST_EXPECTED_COUNT=12
readonly PLAYWRIGHT_EXPECTED_COUNT=2

gate_tmp_dir=""

readonly -a CROSS_PROCESS_EXPECTED_TESTS=(
	test_origin_cross_process_ambiguous_correlation_terminates_cleanly
	test_origin_cross_process_fixture_a_python_aiohttp_mode1
	test_origin_cross_process_fixture_a_python_aiohttp_mode3
	test_origin_cross_process_missing_correlation_terminates_cleanly
	test_origin_cross_process_serialisation_aware_json_collapses_to_trivial_copy
	test_origin_three_trace_chain_balance_to_frontend_expression
	test_parity_origin_cross_process_fixture_a_python_aiohttp
)

readonly -a LIST_PROCESSES_EXPECTED_TESTS=(
	dap_server_emits_idempotent_list_processes_on_session_reload
	dap_server_emits_list_processes_for_single_trace_session
	dap_server_emits_list_processes_for_three_trace_wasm_fixture
	dap_server_emits_list_processes_on_session_load
	dap_server_list_processes_event_falls_back_to_recording_id_when_path_empty
)

# Paths are relative to src/tests/gui because test-e2e changes to that
# directory before invoking Playwright.
readonly -a PLAYWRIGHT_SPECS=(
	tests/value-origin/cross-tracer-three-recording.spec.ts
	tests/value-origin/event-log-correlation-markers-three-trace.spec.ts
)

die() {
	echo "cross-process gate error: $*" >&2
	exit 2
}

resolve_command() {
	local configured="$1" description="$2" resolved
	[ -n "$configured" ] || die "$description executable was explicitly empty"
	if [[ $configured == */* ]]; then
		[ -x "$configured" ] || die "$description executable is not executable: $configured"
		(cd "$(dirname "$configured")" && printf '%s/%s\n' "$PWD" "$(basename "$configured")")
		return
	fi
	resolved="$(command -v "$configured" 2>/dev/null || true)"
	[ -n "$resolved" ] || die "$description executable was not found on PATH: $configured"
	printf '%s\n' "$resolved"
}

require_file() {
	local path="$1" description="$2"
	[ -s "$path" ] || die "$description is missing or empty: $path"
}

require_fixture() {
	local container payload
	[ -d "$FIXTURE_DIR" ] || die "three-trace fixture directory is missing: $FIXTURE_DIR"

	local regenerator="$FIXTURE_DIR/regenerate.sh"
	[ -f "$regenerator" ] || die "fixture regenerator is missing: $regenerator"
	[ -x "$regenerator" ] || die "fixture regenerator is not executable: $regenerator"

	for container in frontend.ct frontend-wasm.ct backend.ct; do
		[ -d "$FIXTURE_DIR/$container" ] ||
			die "required trace container is missing: $FIXTURE_DIR/$container"
		for payload in trace.json trace_metadata.json trace_paths.json; do
			require_file "$FIXTURE_DIR/$container/$payload" "required trace payload"
		done
	done

	require_file "$FIXTURE_DIR/session.toml" "materialized three-trace session manifest"
	require_file "$FIXTURE_DIR/session.toml.template" "three-trace session manifest template"

	local ct_bin="$REPO_ROOT/src/build-debug/bin/ct"
	[ -x "$ct_bin" ] || die "built CodeTracer executable is missing: $ct_bin"
}

require_specs() {
	local spec
	for spec in "${PLAYWRIGHT_SPECS[@]}"; do
		require_file "$REPO_ROOT/src/tests/gui/$spec" "required Playwright spec"
	done
}

select_gui_recipe() {
	local platform="${CROSS_PROCESS_UNAME_S:-$(uname -s)}"
	case "$platform" in
	MINGW* | MSYS* | CYGWIN* | *_NT* | Darwin)
		printf '%s\n' test-e2e
		;;
	Linux)
		if [ -n "${DISPLAY:-}" ]; then
			printf '%s\n' test-e2e
			return
		fi
		local xvfb_bin="${CROSS_PROCESS_XVFB_BIN:-Xvfb}"
		resolve_command "$xvfb_bin" "Xvfb display provider" >/dev/null
		printf '%s\n' test-gui-prebuilt
		;;
	*)
		die "unsupported platform for the required Playwright stage: $platform"
		;;
	esac
}

reject_skip_sentinel() {
	local log="$1" stage="$2"
	if grep -Eiq '(^|[^[:alpha:]])SKIP(PED)?:' "$log"; then
		die "$stage emitted a skip sentinel"
	fi
}

write_expected_manifest() {
	local path="$1"
	shift
	printf '%s\n' "$@" | LC_ALL=C sort >"$path"
}

run_rust_target() {
	local cargo_bin="$1" target="$2" expected_count="$3" expected_manifest="$4" tmp_dir="$5"
	local list_log="$tmp_dir/$target-list.log"
	local test_log="$tmp_dir/$target-test.log"
	local actual_manifest="$tmp_dir/$target-actual.txt"
	local status

	echo "[cross-process] Verifying exact Rust manifest: $target ($expected_count tests)"
	set +e
	(
		cd "$REPO_ROOT/src/db-backend"
		"$cargo_bin" test --test "$target" -- --list
	) >"$list_log" 2>&1
	status=$?
	set -e
	cat "$list_log"
	[ "$status" -eq 0 ] || die "cargo could not list $target (exit $status)"

	sed -n 's/: test$//p' "$list_log" | LC_ALL=C sort >"$actual_manifest"
	if ! diff -u "$expected_manifest" "$actual_manifest"; then
		die "$target manifest differs from the required test set"
	fi

	echo "[cross-process] Running complete Rust target: $target"
	set +e
	(
		cd "$REPO_ROOT/src/db-backend"
		"$cargo_bin" test --test "$target" -- --nocapture
	) >"$test_log" 2>&1
	status=$?
	set -e
	cat "$test_log"
	[ "$status" -eq 0 ] || die "$target failed (exit $status)"
	reject_skip_sentinel "$test_log" "$target"
	grep -Eq "^test result: ok\\. $expected_count passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;" "$test_log" ||
		die "$target did not report exactly $expected_count executed, passing, non-ignored tests"
}

verify_playwright_report() {
	local python_bin="$1" report="$2"
	"$python_bin" - "$report" <<'PYTHON'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as report_file:
    report = json.load(report_file)

expected_titles = sorted(
    [
        "e2e_event_log_jump_renders_in_codetracer_electron — both boundary markers render with chip badges",
        "e2e_origin_cross_tracer_three_recording_balance_chain",
    ]
)

specs = []


def walk_suites(suites):
    for suite in suites or []:
        specs.extend(suite.get("specs", []))
        walk_suites(suite.get("suites", []))


walk_suites(report.get("suites", []))
actual_titles = sorted(spec.get("title") for spec in specs)
if actual_titles != expected_titles:
    raise RuntimeError(f"required Playwright manifest mismatch: {actual_titles!r}")

tests = [test for spec in specs for test in spec.get("tests", [])]
results = [result for test in tests for result in test.get("results", [])]
if (len(specs), len(tests), len(results)) != (2, 2, 2):
    raise RuntimeError(
        "expected exactly 2 specs/tests/results; "
        f"got {len(specs)}/{len(tests)}/{len(results)}"
    )
if any(spec.get("ok") is not True for spec in specs):
    raise RuntimeError("one or more required Playwright specs did not report ok=true")
non_passing = [result.get("status") for result in results if result.get("status") != "passed"]
if non_passing:
    raise RuntimeError(f"required Playwright result was not passed: {non_passing!r}")

stats = report.get("stats", {})
actual_stats = {key: stats.get(key) for key in ("expected", "skipped", "unexpected", "flaky")}
expected_stats = {"expected": 2, "skipped": 0, "unexpected": 0, "flaky": 0}
if actual_stats != expected_stats:
    raise RuntimeError(f"unexpected Playwright stats: {actual_stats!r}")
PYTHON
}

main() {
	local cargo_bin just_bin python_bin gui_recipe playwright_log playwright_report status

	case "${CT_CROSS_PROCESS_REQUIRED:-1}" in
	1) ;;
	*) die "CT_CROSS_PROCESS_REQUIRED must be '1' for this fail-closed gate" ;;
	esac

	if [ "${CROSS_PROCESS_SKIP_GATE_SELF_TESTS:-0}" != "1" ]; then
		"$REPO_ROOT/ci/test/cross-process-gate.sh"
	fi

	require_fixture
	require_specs
	gui_recipe="$(select_gui_recipe)"
	cargo_bin="$(resolve_command "${CROSS_PROCESS_CARGO_BIN:-cargo}" "cargo")"
	just_bin="$(resolve_command "${CROSS_PROCESS_JUST_BIN:-just}" "just")"
	python_bin="$(resolve_command "${CROSS_PROCESS_PYTHON_BIN:-python3}" "Python")"

	gate_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-cross-process.XXXXXX")"
	trap 'rm -rf "$gate_tmp_dir"' EXIT

	write_expected_manifest "$gate_tmp_dir/$CROSS_PROCESS_TARGET-expected.txt" \
		"${CROSS_PROCESS_EXPECTED_TESTS[@]}"
	write_expected_manifest "$gate_tmp_dir/$LIST_PROCESSES_TARGET-expected.txt" \
		"${LIST_PROCESSES_EXPECTED_TESTS[@]}"

	echo "=== M29 required cross-process value-origin envelope ==="
	run_rust_target "$cargo_bin" "$CROSS_PROCESS_TARGET" "$CROSS_PROCESS_EXPECTED_COUNT" \
		"$gate_tmp_dir/$CROSS_PROCESS_TARGET-expected.txt" "$gate_tmp_dir"
	run_rust_target "$cargo_bin" "$LIST_PROCESSES_TARGET" "$LIST_PROCESSES_EXPECTED_COUNT" \
		"$gate_tmp_dir/$LIST_PROCESSES_TARGET-expected.txt" "$gate_tmp_dir"
	echo "cross-process Rust summary: expected=$RUST_EXPECTED_COUNT executed=$RUST_EXPECTED_COUNT skipped=0"

	playwright_log="$gate_tmp_dir/playwright.log"
	playwright_report="$gate_tmp_dir/playwright-report.json"
	echo "[cross-process] Running both required Playwright specs through $gui_recipe"
	set +e
	(
		cd "$REPO_ROOT"
		PLAYWRIGHT_JSON_OUTPUT_NAME="$playwright_report" \
			"$just_bin" "$gui_recipe" "${PLAYWRIGHT_SPECS[@]}" --reporter=json
	) >"$playwright_log" 2>&1
	status=$?
	set -e
	cat "$playwright_log"
	[ "$status" -eq 0 ] || die "required Playwright stage failed (exit $status)"
	reject_skip_sentinel "$playwright_log" "required Playwright stage"
	require_file "$playwright_report" "Playwright JSON report"
	verify_playwright_report "$python_bin" "$playwright_report" ||
		die "Playwright report did not prove exactly two required passing tests with zero skips"
	echo "cross-process Playwright summary: expected=$PLAYWRIGHT_EXPECTED_COUNT executed=$PLAYWRIGHT_EXPECTED_COUNT skipped=0"

	echo "=== M29 required cross-process value-origin envelope passed ==="
}

main "$@"
