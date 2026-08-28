#!/usr/bin/env bash
# =============================================================================
# CLI smoke test: exercises `ct record` for every supported language.
#
# This test uses the SAME code path end users hit (ct record → language
# detection → recorder dispatch → importTrace). It catches:
# - PATH lookup issues (recorder binary not found)
# - Language detection regressions (.sh → LangBash, etc.)
# - Format default regressions (should produce trace.bin, not trace.json)
# - Missing dispatch in db_backend_record.nim
#
# Usage:
#   ci/test/cli-record-smoke.sh [language ...]
#
# When no arguments are given, all languages with available recorders and
# test programs are tested. Pass language names to test a subset:
#   ci/test/cli-record-smoke.sh ruby python bash
#
# Prerequisites:
#   - ct binary built (src/build-debug/bin/ct or CODETRACER_E2E_CT_PATH)
#   - Recorder binaries on PATH (via detect-siblings or nix shell)
#   - Test programs in test-programs/ or db-backend/test-programs/
# =============================================================================

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
CT_BIN="${CODETRACER_E2E_CT_PATH:-${CODETRACER_BUILD_DIR:-$ROOT_DIR/src/build-debug}/bin/ct}"

if [[ ! -x $CT_BIN ]]; then
	echo "error: ct binary not found at $CT_BIN"
	echo "  Build with: just build-once"
	echo "  Or set CODETRACER_E2E_CT_PATH to a pre-built binary."
	exit 1
fi

TRACE_BASE=$(mktemp -d -t ct-cli-smoke-XXXXXX)
trap 'rm -rf "$TRACE_BASE"' EXIT

PASSED=0
FAILED=0
SKIPPED=0
FAILURES=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

smoke_test() {
	local lang="$1"
	local program="$2"
	shift 2
	local extra_args=("$@")

	if [[ ! -f $program ]]; then
		echo "  SKIP $lang — test program not found: $program"
		((SKIPPED++)) || true
		return
	fi

	local trace_dir="$TRACE_BASE/$lang"
	mkdir -p "$trace_dir"

	echo -n "  TEST $lang ($program) ... "

	local output
	if output=$("$CT_BIN" record -o "$trace_dir" "${extra_args[@]}" "$program" 2>&1); then
		# Verify trace was produced — prefer trace.bin (binary/CTFS), accept trace.json
		if [[ -f "$trace_dir/trace.bin" ]]; then
			echo "OK (trace.bin produced)"
			((PASSED++)) || true
		elif [[ -f "$trace_dir/trace.json" ]]; then
			echo "WARN (trace.json produced — expected binary format)"
			((PASSED++)) || true
		elif ls "$trace_dir"/*.ct 1>/dev/null 2>&1; then
			echo "OK (.ct container produced)"
			((PASSED++)) || true
		# Some recorders treat --out-dir as the PARENT of the recording:
		# codetracer-js-recorder writes `<out-dir>/trace-<n>/` and the PHP
		# extension writes `<out-dir>/worker_<pid>/` in its multi-worker form.
		# importTrace searches one level down for exactly this reason (see
		# findCtFileInFolder in src/ct/trace/storage_and_import.nim), so the
		# smoke check has to look where the container really lands rather
		# than reporting a successful recording as a missing trace.
		elif ls "$trace_dir"/*/*.ct 1>/dev/null 2>&1; then
			echo "OK (.ct container produced, one level below --out-dir)"
			((PASSED++)) || true
		else
			echo "FAIL (no trace file found in $trace_dir)"
			echo "    Files: $(ls "$trace_dir" 2>/dev/null || echo "(empty)")"
			((FAILED++)) || true
			FAILURES="${FAILURES}  - $lang: no trace file produced\n"
		fi
	else
		local exit_code=$?
		echo "FAIL (exit code $exit_code)"
		echo "    Output: $(echo "$output" | tail -5)"
		((FAILED++)) || true
		FAILURES="${FAILURES}  - $lang: ct record exited with code $exit_code\n"
	fi
}

# ---------------------------------------------------------------------------
# Language definitions: (name, program_path, extra_ct_record_args...)
# ---------------------------------------------------------------------------

declare -A LANG_TESTS

# DB-based recorders
LANG_TESTS[ruby]="$ROOT_DIR/test-programs/rb_checklist/variables_and_constants.rb"
LANG_TESTS[python]="$ROOT_DIR/test-programs/py_console_logs/main.py"
LANG_TESTS[bash]="$ROOT_DIR/src/db-backend/test-programs/bash/bash_flow_test.sh"
LANG_TESTS[javascript]="$ROOT_DIR/src/db-backend/test-programs/javascript/javascript_flow_test.js"
LANG_TESTS[noir]="$ROOT_DIR/test-programs/noir_example"

# Languages whose dispatch was added by the recorder-wiring work. Their
# runtimes live in their own recorder siblings' dev shells rather than in
# codetracer's, so they are skipped here unless the runtime is on PATH — the
# Nim lane (`just test-cli-record`) is what covers them without one.
LANG_TESTS[php]="$ROOT_DIR/test-programs/php_hello/hello.php"
LANG_TESTS[elixir]="$ROOT_DIR/test-programs/elixir_hello/hello.exs"

# Blockchain/VM recorders (require dedicated recorder binaries)
LANG_TESTS[masm]="$ROOT_DIR/test-programs/masm_example"
LANG_TESTS[move]="$ROOT_DIR/test-programs/move_example"
LANG_TESTS[solana]="$ROOT_DIR/test-programs/solana_example"
LANG_TESTS[sway]="$ROOT_DIR/test-programs/sway_example"
LANG_TESTS[solidity]="$ROOT_DIR/test-programs/solidity_example"

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "CLI record smoke tests"
echo "  ct binary: $CT_BIN"
echo "  trace dir: $TRACE_BASE"
echo ""

# Filter to requested languages if arguments provided.
if [[ $# -gt 0 ]]; then
	SELECTED=("$@")
else
	SELECTED=("${!LANG_TESTS[@]}")
fi

for lang in "${SELECTED[@]}"; do
	program="${LANG_TESTS[$lang]:-}"
	if [[ -z $program ]]; then
		# A language named on the command line that has no definition is a
		# caller error (a typo, or a language removed from LANG_TESTS), not
		# something to skip: skipping it is how `cli-record-smoke.sh ruby`
		# misspelled as `rubby` reports success having recorded nothing.
		# Only the no-argument form enumerates LANG_TESTS itself, and every
		# key it yields is defined by construction, so this can only be hit
		# by an explicit argument.
		echo "error: unknown language '$lang' — no test definition"
		echo "  Known languages: ${!LANG_TESTS[*]}"
		exit 1
	fi

	# Check if the recorder is available on PATH before attempting.
	case "$lang" in
	ruby) command -v codetracer-ruby-recorder &>/dev/null || {
		echo "  SKIP $lang — recorder not on PATH"
		((SKIPPED++)) || true
		continue
	} ;;
	bash) command -v codetracer-bash-recorder &>/dev/null || {
		echo "  SKIP $lang — recorder not on PATH"
		((SKIPPED++)) || true
		continue
	} ;;
	javascript) command -v codetracer-js-recorder &>/dev/null || {
		echo "  SKIP $lang — recorder not on PATH"
		((SKIPPED++)) || true
		continue
	} ;;
	noir) command -v nargo &>/dev/null || {
		echo "  SKIP $lang — nargo not on PATH"
		((SKIPPED++)) || true
		continue
	} ;;
	php)
		# The PHP recorder is a Zend extension, not an executable: both the
		# php binary and the built codetracer.so have to be present.
		command -v php &>/dev/null || {
			echo "  SKIP $lang — php not on PATH"
			((SKIPPED++)) || true
			continue
		}
		[[ -f ${CODETRACER_PHP_RECORDER_EXTENSION:-} ]] || {
			echo "  SKIP $lang — CODETRACER_PHP_RECORDER_EXTENSION not set/built"
			((SKIPPED++)) || true
			continue
		}
		;;
	elixir)
		command -v elixir &>/dev/null || {
			echo "  SKIP $lang — elixir not on PATH"
			((SKIPPED++)) || true
			continue
		}
		[[ -x ${CODETRACER_BEAM_RECORDER_BIN:-} ]] || {
			echo "  SKIP $lang — CODETRACER_BEAM_RECORDER_BIN not set/built"
			((SKIPPED++)) || true
			continue
		}
		;;
	esac

	smoke_test "$lang" "$program"
done

echo ""
echo "Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"

if [[ $FAILED -gt 0 ]]; then
	echo ""
	echo "Failures:"
	echo -e "$FAILURES"
	exit 1
fi

# Zero-test guard: an all-skipped run is how a broken dispatch hides. Without
# this, every language skipping its prerequisite check leaves
# "0 passed, 0 failed" and exit 0 — a gate reporting success having recorded
# nothing. Mirrors the guard in
# src/tests/cli/record_dispatch_e2e_test.nim:188-195.
if [[ $PASSED -eq 0 ]]; then
	echo ""
	echo "error: no language was recorded end-to-end ($SKIPPED skipped)."
	echo "  A run in which every language skips is not a passing smoke test."
	echo "  The Ruby and JavaScript recorders are expected to be built in the"
	echo "  CodeTracer dev shell — see scripts/detect-siblings.sh and"
	echo "  codetracer-specs/Testing/Cross-Repo-CI-Integration.md."
	exit 1
fi
