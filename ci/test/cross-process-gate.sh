#!/usr/bin/env bash

# Hermetic contract tests for scripts/test-cross-process.sh. Fake cargo and
# just executables validate the exact required manifests, stage order/counts,
# skip rejection, prerequisite failures, and workflow provisioning without
# recompiling the product.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
readonly REPO_ROOT
readonly GATE="$REPO_ROOT/scripts/test-cross-process.sh"
readonly EVENT_LOG_SPEC="$REPO_ROOT/src/tests/gui/tests/value-origin/event-log-correlation-markers-three-trace.spec.ts"

fail() {
	echo "cross-process shell contract test failed: $*" >&2
	exit 1
}

require_source_line() {
	local source="$1" required="$2" description="$3"
	grep -Fq -- "$required" "$source" || fail "$description"
}

# This required spec must drive the actual Electron application. The base
# Playwright `page` fixture is a blank Chromium tab and cannot prove the
# user-visible CodeTracer flow, even if its DOM assertions remain unchanged.
require_source_line "$EVENT_LOG_SPEC" \
	'from "../../lib/fixtures";' \
	"event-log spec must import the CodeTracer fixture"
require_source_line "$EVENT_LOG_SPEC" \
	'test.use({ sourcePath: fixtureDir, launchMode: "trace-folder" });' \
	"event-log spec must launch the materialized fixture through Electron"
require_source_line "$EVENT_LOG_SPEC" \
	'await readyOnEntry(ctPage);' \
	"event-log spec must wait for the launched CodeTracer renderer"
require_source_line "$EVENT_LOG_SPEC" \
	'readMarkerRow(ctPage, HTTP_BOUNDARY_ID)' \
	"event-log spec must assert the HTTP boundary in CodeTracer"
require_source_line "$EVENT_LOG_SPEC" \
	'readMarkerRow(ctPage, JS_WASM_BOUNDARY_ID)' \
	"event-log spec must assert the WASM boundary in CodeTracer"
if grep -Eq 'import[[:space:]]*\{[^}]*\btest\b[^}]*\}[[:space:]]*from[[:space:]]*"@playwright/test"' "$EVENT_LOG_SPEC"; then
	fail "event-log spec must not regress to the plain Playwright page fixture"
fi

workflow_job() {
	local job="$1"
	awk -v job="$job" '
    $0 == "  " job ":" { active = 1; print; next }
    active && $0 ~ /^  [A-Za-z0-9_-]+:$/ { exit }
    active { print }
  ' "$REPO_ROOT/.github/workflows/codetracer.yml"
}

cross_process_job="$(workflow_job cross-process-linux)"
for step in \
	"Generate CI token" \
	"Checkout" \
	"Setup db-backend siblings" \
	"Setup isonim siblings" \
	"Build frontend (needed by gated Playwright stage)" \
	"Run cross-process envelope"; do
	[ "$(printf '%s\n' "$cross_process_job" | grep -cFx -- "      - name: $step")" -eq 1 ] ||
		fail "cross-process workflow must contain '$step' exactly once"
done

previous_line=0
for step in \
	"Generate CI token" \
	"Checkout" \
	"Setup db-backend siblings" \
	"Setup isonim siblings" \
	"Build frontend (needed by gated Playwright stage)" \
	"Run cross-process envelope"; do
	line="$(printf '%s\n' "$cross_process_job" | grep -nFx -- "      - name: $step" | cut -d: -f1)"
	[ "$line" -gt "$previous_line" ] || fail "cross-process workflow stages are out of order at '$step'"
	previous_line="$line"
done

[ "$(printf '%s\n' "$cross_process_job" | grep -c 'CT_CROSS_PROCESS_REQUIRED: "1"$')" -eq 1 ] ||
	fail "cross-process workflow must enable required mode exactly once"
if printf '%s\n' "$cross_process_job" | grep -Eq 'continue-on-error:|CT_CROSS_PROCESS_REQUIRED: "0"'; then
	fail "cross-process workflow must not tolerate gate failures or disable required mode"
fi
for required_line in \
	"        uses: ./.github/actions/setup-db-backend-siblings" \
	"        uses: ./.github/actions/setup-isonim-siblings" \
	"        run: nix develop .#devShells.x86_64-linux.default --command just build-once" \
	"        run: nix develop .#devShells.x86_64-linux.default --command just test-cross-process"; do
	[ "$(printf '%s\n' "$cross_process_job" | grep -cFx -- "$required_line")" -eq 1 ] ||
		fail "cross-process workflow must contain '$required_line' exactly once"
done

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-cross-process-self-test.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT
fake_root="$tmp_dir/repo"
fake_bin="$tmp_dir/bin"
stage_log="$tmp_dir/stages.log"
fixture="$fake_root/src/db-backend/tests/fixtures/cross_process/account-balance-with-wasm"
mkdir -p \
	"$fake_bin" \
	"$fake_root/src/build-debug/bin" \
	"$fake_root/src/db-backend" \
	"$fake_root/src/tests/gui/tests/value-origin" \
	"$fake_root/ci/test" \
	"$fixture"

for container in frontend.ct frontend-wasm.ct backend.ct; do
	mkdir -p "$fixture/$container"
	for payload in trace.json trace_metadata.json trace_paths.json; do
		printf '{}\n' >"$fixture/$container/$payload"
	done
done
printf '[[trace]]\n' >"$fixture/session.toml"
printf '[[trace]]\n' >"$fixture/session.toml.template"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture/regenerate.sh"
chmod +x "$fixture/regenerate.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_root/src/build-debug/bin/ct"
chmod +x "$fake_root/src/build-debug/bin/ct"
for spec in \
	cross-tracer-three-recording.spec.ts \
	event-log-correlation-markers-three-trace.spec.ts; do
	printf '// required fake spec\n' >"$fake_root/src/tests/gui/tests/value-origin/$spec"
done

fake_cargo="$fake_bin/cargo"
cat >"$fake_cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${3-}"
mode="${5-}"
echo "cargo:${mode#--}:$target" >>"$FAKE_STAGE_LOG"

case "$target:$mode" in
cross_process_origin_test:--list)
	cat <<'LIST'
test_origin_cross_process_ambiguous_correlation_terminates_cleanly: test
test_origin_cross_process_fixture_a_python_aiohttp_mode1: test
test_origin_cross_process_fixture_a_python_aiohttp_mode3: test
test_origin_cross_process_missing_correlation_terminates_cleanly: test
test_origin_cross_process_serialisation_aware_json_collapses_to_trivial_copy: test
test_origin_three_trace_chain_balance_to_frontend_expression: test
test_parity_origin_cross_process_fixture_a_python_aiohttp: test

7 tests, 0 benchmarks
LIST
	if [ "${FAKE_RUST_MANIFEST_DRIFT:-0}" = "1" ]; then
		echo "unexpected_cross_process_test: test"
	fi
	;;
cross_process_origin_test:--nocapture)
	if [ "${FAKE_RUST_SKIP:-0}" = "1" ]; then
		echo "SKIPPED: required three-trace fixture"
	fi
	count="${FAKE_RUST_COUNT:-7}"
	echo "test result: ok. $count passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"
	;;
dap_server_list_processes_event_test:--list)
	cat <<'LIST'
dap_server_emits_idempotent_list_processes_on_session_reload: test
dap_server_emits_list_processes_for_single_trace_session: test
dap_server_emits_list_processes_for_three_trace_wasm_fixture: test
dap_server_emits_list_processes_on_session_load: test
dap_server_list_processes_event_falls_back_to_recording_id_when_path_empty: test

5 tests, 0 benchmarks
LIST
	;;
dap_server_list_processes_event_test:--nocapture)
	if [ "${FAKE_DAP_SKIP:-0}" = "1" ]; then
		echo "SKIPPED: required list-processes fixture"
	fi
	count="${FAKE_DAP_COUNT:-5}"
	echo "test result: ok. $count passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.01s"
	;;
*)
	echo "unexpected fake cargo arguments: $*" >&2
	exit 64
	;;
esac
EOF
chmod +x "$fake_cargo"

fake_just="$fake_bin/just"
cat >"$fake_just" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'just' >>"$FAKE_STAGE_LOG"
printf ':%s' "$@" >>"$FAKE_STAGE_LOG"
printf '\n' >>"$FAKE_STAGE_LOG"

if [ "$#" -ne 4 ] || [ "$1" != "test-gui-prebuilt" ] || \
	[ "$2" != "tests/value-origin/cross-tracer-three-recording.spec.ts" ] || \
	[ "$3" != "tests/value-origin/event-log-correlation-markers-three-trace.spec.ts" ] || \
	[ "$4" != "--reporter=json" ]; then
	echo "unexpected fake just arguments: $*" >&2
	exit 64
fi

if [ "${FAKE_PLAYWRIGHT_SKIP:-0}" = "1" ]; then
	cat >"$PLAYWRIGHT_JSON_OUTPUT_NAME" <<'JSON'
{"suites":[{"specs":[{"title":"e2e_origin_cross_tracer_three_recording_balance_chain","ok":true,"tests":[{"results":[{"status":"skipped"}]}]},{"title":"e2e_event_log_jump_renders_in_codetracer_electron — both boundary markers render with chip badges","ok":true,"tests":[{"results":[{"status":"passed"}]}]}]}],"stats":{"expected":1,"skipped":1,"unexpected":0,"flaky":0}}
JSON
	exit 0
fi

if [ "${FAKE_PLAYWRIGHT_TITLE_DRIFT:-0}" = "1" ]; then
	cat >"$PLAYWRIGHT_JSON_OUTPUT_NAME" <<'JSON'
{"suites":[{"specs":[{"title":"unexpected replacement test","ok":true,"tests":[{"results":[{"status":"passed"}]}]},{"title":"e2e_event_log_jump_renders_in_codetracer_electron — both boundary markers render with chip badges","ok":true,"tests":[{"results":[{"status":"passed"}]}]}]}],"stats":{"expected":2,"skipped":0,"unexpected":0,"flaky":0}}
JSON
	exit 0
fi

cat >"$PLAYWRIGHT_JSON_OUTPUT_NAME" <<'JSON'
{"suites":[{"specs":[{"title":"e2e_origin_cross_tracer_three_recording_balance_chain","ok":true,"tests":[{"results":[{"status":"passed"}]}]},{"title":"e2e_event_log_jump_renders_in_codetracer_electron — both boundary markers render with chip badges","ok":true,"tests":[{"results":[{"status":"passed"}]}]}]}],"stats":{"expected":2,"skipped":0,"unexpected":0,"flaky":0}}
JSON
EOF
chmod +x "$fake_just"

fake_xvfb="$fake_bin/Xvfb"
printf '#!/usr/bin/env bash\nexit 0\n' >"$fake_xvfb"
chmod +x "$fake_xvfb"

run_gate() {
	DISPLAY='' \
		CT_CROSS_PROCESS_REQUIRED=1 \
		CROSS_PROCESS_SKIP_GATE_SELF_TESTS=1 \
		CROSS_PROCESS_REPO_ROOT="$fake_root" \
		CROSS_PROCESS_CARGO_BIN="$fake_cargo" \
		CROSS_PROCESS_JUST_BIN="$fake_just" \
		CROSS_PROCESS_PYTHON_BIN="$(command -v python3)" \
		CROSS_PROCESS_UNAME_S=Linux \
		CROSS_PROCESS_XVFB_BIN="$fake_xvfb" \
		FAKE_STAGE_LOG="$stage_log" \
		"$GATE"
}

expect_failure() {
	local description="$1" fragment="$2" output status
	shift 2
	set +e
	output="$("$@" 2>&1)"
	status=$?
	set -e
	[ "$status" -ne 0 ] || fail "$description unexpectedly succeeded"
	printf '%s\n' "$output" | grep -Fq "$fragment" ||
		fail "$description did not report '$fragment': $output"
}

: >"$stage_log"
success_output="$(run_gate 2>&1)" || fail "strict fake gate failed: $success_output"
printf '%s\n' "$success_output" |
	grep -Fq 'cross-process Rust summary: expected=12 executed=12 skipped=0' ||
	fail "strict fake gate omitted the exact Rust completion summary"
printf '%s\n' "$success_output" |
	grep -Fq 'cross-process Playwright summary: expected=2 executed=2 skipped=0' ||
	fail "strict fake gate omitted the exact Playwright completion summary"

expected_stages=$'cargo:list:cross_process_origin_test\ncargo:nocapture:cross_process_origin_test\ncargo:list:dap_server_list_processes_event_test\ncargo:nocapture:dap_server_list_processes_event_test\njust:test-gui-prebuilt:tests/value-origin/cross-tracer-three-recording.spec.ts:tests/value-origin/event-log-correlation-markers-three-trace.spec.ts:--reporter=json'
actual_stages="$(cat "$stage_log")"
[ "$actual_stages" = "$expected_stages" ] ||
	fail "required stage order/arguments drifted; got: $actual_stages"

mv "$fixture/frontend.ct/trace.json" "$fixture/frontend.ct/trace.json.off"
expect_failure "missing fixture payload" "required trace payload is missing or empty" run_gate
mv "$fixture/frontend.ct/trace.json.off" "$fixture/frontend.ct/trace.json"

mv "$fake_root/src/build-debug/bin/ct" "$fake_root/src/build-debug/bin/ct.off"
expect_failure "missing CodeTracer executable" "built CodeTracer executable is missing" run_gate
mv "$fake_root/src/build-debug/bin/ct.off" "$fake_root/src/build-debug/bin/ct"

chmod -x "$fixture/regenerate.sh"
expect_failure "non-executable regenerator" "fixture regenerator is not executable" run_gate
chmod +x "$fixture/regenerate.sh"

missing_spec="$fake_root/src/tests/gui/tests/value-origin/cross-tracer-three-recording.spec.ts"
mv "$missing_spec" "$missing_spec.off"
expect_failure "missing required spec" "required Playwright spec is missing or empty" run_gate
mv "$missing_spec.off" "$missing_spec"

expect_failure "missing display provider" "Xvfb display provider executable is not executable" \
	env DISPLAY= \
	CT_CROSS_PROCESS_REQUIRED=1 \
	CROSS_PROCESS_SKIP_GATE_SELF_TESTS=1 \
	CROSS_PROCESS_REPO_ROOT="$fake_root" \
	CROSS_PROCESS_CARGO_BIN="$fake_cargo" \
	CROSS_PROCESS_JUST_BIN="$fake_just" \
	CROSS_PROCESS_PYTHON_BIN="$(command -v python3)" \
	CROSS_PROCESS_UNAME_S=Linux \
	CROSS_PROCESS_XVFB_BIN="$tmp_dir/missing-Xvfb" \
	FAKE_STAGE_LOG="$stage_log" \
	"$GATE"

set +e
rust_skip_output="$(FAKE_RUST_SKIP=1 run_gate 2>&1)"
rust_skip_status=$?
set -e
[ "$rust_skip_status" -ne 0 ] || fail "Rust skip sentinel unexpectedly succeeded"
printf '%s\n' "$rust_skip_output" | grep -Fq 'emitted a skip sentinel' ||
	fail "Rust skip sentinel reported the wrong failure"

set +e
rust_count_output="$(FAKE_RUST_COUNT=6 run_gate 2>&1)"
rust_count_status=$?
set -e
[ "$rust_count_status" -ne 0 ] || fail "wrong Rust execution count unexpectedly succeeded"
printf '%s\n' "$rust_count_output" | grep -Fq 'did not report exactly 7 executed' ||
	fail "wrong Rust execution count reported the wrong failure"

set +e
rust_manifest_output="$(FAKE_RUST_MANIFEST_DRIFT=1 run_gate 2>&1)"
rust_manifest_status=$?
set -e
[ "$rust_manifest_status" -ne 0 ] || fail "Rust manifest drift unexpectedly succeeded"
printf '%s\n' "$rust_manifest_output" | grep -Fq 'manifest differs from the required test set' ||
	fail "Rust manifest drift reported the wrong failure"

set +e
dap_skip_output="$(FAKE_DAP_SKIP=1 run_gate 2>&1)"
dap_skip_status=$?
set -e
[ "$dap_skip_status" -ne 0 ] || fail "list-processes skip sentinel unexpectedly succeeded"
printf '%s\n' "$dap_skip_output" | grep -Fq 'emitted a skip sentinel' ||
	fail "list-processes skip sentinel reported the wrong failure"

set +e
dap_count_output="$(FAKE_DAP_COUNT=4 run_gate 2>&1)"
dap_count_status=$?
set -e
[ "$dap_count_status" -ne 0 ] || fail "wrong list-processes execution count unexpectedly succeeded"
printf '%s\n' "$dap_count_output" | grep -Fq 'did not report exactly 5 executed' ||
	fail "wrong list-processes execution count reported the wrong failure"

set +e
playwright_skip_output="$(FAKE_PLAYWRIGHT_SKIP=1 run_gate 2>&1)"
playwright_skip_status=$?
set -e
[ "$playwright_skip_status" -ne 0 ] || fail "skipped Playwright result unexpectedly succeeded"
printf '%s\n' "$playwright_skip_output" |
	grep -Fq 'Playwright report did not prove exactly two required passing tests with zero skips' ||
	fail "skipped Playwright result reported the wrong failure"

set +e
playwright_title_output="$(FAKE_PLAYWRIGHT_TITLE_DRIFT=1 run_gate 2>&1)"
playwright_title_status=$?
set -e
[ "$playwright_title_status" -ne 0 ] || fail "Playwright manifest drift unexpectedly succeeded"
printf '%s\n' "$playwright_title_output" |
	grep -Fq 'Playwright report did not prove exactly two required passing tests with zero skips' ||
	fail "Playwright manifest drift reported the wrong failure"

echo "cross-process shell contract tests passed"
