#!/usr/bin/env bash

# Shared execution wrappers for the real visual-replay gate and its hermetic
# contract. Both paths use the same fail-closed report validator.

VISUAL_REPLAY_GATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly VISUAL_REPLAY_GATE_LIB_DIR
VISUAL_REPLAY_GATE_REPORT_VALIDATOR="${VISUAL_REPLAY_GATE_LIB_DIR}/visual-replay-gate-report.py"
readonly VISUAL_REPLAY_GATE_REPORT_VALIDATOR
VISUAL_REPLAY_NIM_COMPLETION_SENTINEL="@@CODETRACER_VISUAL_REPLAY_NIM_COMMAND_COMPLETED@@"
readonly VISUAL_REPLAY_NIM_COMPLETION_SENTINEL

visual_replay_gate_die() {
	echo "visual-replay gate error: $*" >&2
	return 1
}

visual_replay_gate_python() {
	local resolved
	resolved="$(type -P python3 2>/dev/null || true)"
	if [[ -z $resolved ]]; then
		visual_replay_gate_die "Python 3 executable was not found on PATH"
		return
	fi
	printf '%s\n' "$resolved"
}

visual_replay_run_playwright_stage() {
	local kind="$1" report="$2"
	shift 2
	if [[ $# -eq 0 ]]; then
		visual_replay_gate_die "Playwright command is empty"
		return
	fi
	rm -f "$report"

	# Do not inherit CI/local retry policy. Every required test must pass on its
	# first and only execution.
	CI=1 \
		CODETRACER_VISUAL_REPLAY_GATE_JSON="$report" \
		PLAYWRIGHT_RETRIES=0 \
		"$@"

	if [[ ! -s $report ]]; then
		visual_replay_gate_die "Playwright JSON report is missing or empty: $report"
		return
	fi
	"$(visual_replay_gate_python)" -I "$VISUAL_REPLAY_GATE_REPORT_VALIDATOR" \
		playwright --kind "$kind" --report "$report"
}

visual_replay_run_nim_suite() {
	local label="$1"
	shift
	if [[ $# -eq 0 ]]; then
		visual_replay_gate_die "Nim command is empty for $label"
		return
	fi

	local output exit_status
	output="$(mktemp "${TMPDIR:-/tmp}/visual-replay-nim.XXXXXX.log")"
	if "$@" >"$output" 2>&1; then
		exit_status=0
		# This line is emitted by the wrapper, never by the Nim process, and only
		# after that process exits successfully. The validator requires it once
		# as the final complete line so a truncated log cannot prove success.
		printf '%s\n' "$VISUAL_REPLAY_NIM_COMPLETION_SENTINEL" >>"$output"
	else
		exit_status=$?
	fi
	cat "$output"
	if [[ $exit_status -ne 0 ]]; then
		rm -f "$output"
		visual_replay_gate_die \
			"Nim suite failed before report validation: $label (exit $exit_status)"
		return
	fi
	if ! "$(visual_replay_gate_python)" -I "$VISUAL_REPLAY_GATE_REPORT_VALIDATOR" \
		nim --log "$output" --label "$label"; then
		rm -f "$output"
		return 1
	fi
	rm -f "$output"
}
