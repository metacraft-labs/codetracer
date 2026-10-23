#!/usr/bin/env bash
# =============================================================================
# Build the three tools scripts/materialize-recording.sh needs to produce the
# `cross-process-three-trace` recording, and print the session-manager path.
#
#   CODETRACER_RECORD_WEB_BIN="$(bash scripts/provision-cross-process-recording.sh)"
#
# The recording (the JS + WASM + Node `account-balance-with-wasm` demo) is not
# committed: test_harness::materialized_recording produces it from the tree
# when a suite first asks for it, and refuses — loudly, correctly — when a tool
# is missing.  Nothing on `just test-frontend-units`' path used to build those
# tools, so cross_process_origin_vm_test failed 3 of 4 cases on every host
# that had not built them by hand, and the lane note blamed an "uncommitted
# rr/MCR recording" that does not exist (codetracer-pm
# issues/2026-10-21-test-frontend-units-does-not-provision-the-three-trace-
# recording-its-cross-process-suite-needs.md).  The three tools:
#
#   ct-instrument          codetracer-wasm-instrumenter, via build-siblings.sh
#   codetracer-js-recorder its packages/cli/dist/index.js, via build-siblings.sh
#   session-manager        this repo's src/backend-manager, built here
#
# A required sibling that is not checked out, or whose build fails, FAILS this
# script (exit 1) and names it.  build-siblings.sh itself reports a sibling
# that is not checked out as MISSING and exits 0, so that is checked here, as
# ci/test/ct-providers.sh does for its recorders.  Failing is the point: the
# suites that replay this recording must not run against no recording.
#
# Callers that supply a tool themselves keep it.  The materialiser resolves
# CT_INSTRUMENT_BIN, CODETRACER_WASM_INSTRUMENTER_PATH,
# CODETRACER_JS_RECORDER_PATH and CODETRACER_RECORD_WEB_BIN before the sibling
# checkouts, so when one is set, building the sibling it overrides would build
# something the recording does not use; it is skipped, and the skip is said.
#
# stdout carries exactly one line, the session-manager executable; everything
# else goes to stderr.  The path is printed rather than assumed because cargo
# puts it under CARGO_TARGET_DIR when that is set (the CI runners set one),
# not under src/backend-manager/target where the materialiser looks — the
# reason `just test-rust` hands it over the same way.
#
# Tested by ci/test/frontend-units-cross-process-provisioning-test.sh.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WS_ROOT="$(cd "$CT_ROOT/.." && pwd)"

failures=()

# provision_sibling <repo> <override-description-or-empty>
provision_sibling() {
	local repo="$1" override="$2"
	if [ -n "$override" ]; then
		echo "provision-cross-process-recording: $repo: not built — $override" >&2
		return 0
	fi
	if [ ! -d "$WS_ROOT/$repo" ]; then
		echo "provision-cross-process-recording: ERROR: required sibling '$repo' is not checked out at $WS_ROOT/$repo" >&2
		failures+=("$repo (not checked out at $WS_ROOT/$repo; \`repro ws enable codetracer\` checks it out)")
		return 0
	fi
	# build-siblings.sh writes its summary to stderr; its stdout is not ours.
	if ! bash "$SCRIPT_DIR/build-siblings.sh" --only "$repo" >&2; then
		failures+=("$repo (build failed; see the build-siblings summary above)")
	fi
}

instrumenter_override=""
if [ -n "${CT_INSTRUMENT_BIN:-}" ]; then
	instrumenter_override="CT_INSTRUMENT_BIN is set ($CT_INSTRUMENT_BIN)"
elif [ -n "${CODETRACER_WASM_INSTRUMENTER_PATH:-}" ]; then
	instrumenter_override="CODETRACER_WASM_INSTRUMENTER_PATH is set ($CODETRACER_WASM_INSTRUMENTER_PATH)"
fi
js_override=""
if [ -n "${CODETRACER_JS_RECORDER_PATH:-}" ]; then
	js_override="CODETRACER_JS_RECORDER_PATH is set ($CODETRACER_JS_RECORDER_PATH)"
fi

provision_sibling codetracer-wasm-instrumenter "$instrumenter_override"
provision_sibling codetracer-js-recorder "$js_override"

session_manager=""
if [ -n "${CODETRACER_RECORD_WEB_BIN:-}" ]; then
	echo "provision-cross-process-recording: session-manager: not built — CODETRACER_RECORD_WEB_BIN is set ($CODETRACER_RECORD_WEB_BIN)" >&2
	session_manager="$CODETRACER_RECORD_WEB_BIN"
else
	echo "provision-cross-process-recording: building session-manager (src/backend-manager)" >&2
	# Rendered diagnostics go to stderr; the JSON artifact records go to stdout,
	# and the executable is the last one with a path.
	# https://doc.rust-lang.org/cargo/reference/external-tools.html#json-messages
	if ! session_manager="$(cd "$CT_ROOT/src/backend-manager" &&
		cargo build --release --bin session-manager --message-format=json-render-diagnostics |
		jq -r 'select(.reason == "compiler-artifact" and .executable != null) | .executable' |
			tail -n 1)"; then
		session_manager=""
		failures+=("session-manager (cargo build in $CT_ROOT/src/backend-manager failed; see above)")
	elif [ -z "$session_manager" ]; then
		failures+=("session-manager (cargo build reported no executable)")
	fi
fi
if [ -n "$session_manager" ] && [ ! -x "$session_manager" ]; then
	failures+=("session-manager ($session_manager is not an executable)")
fi

if [ "${#failures[@]}" -gt 0 ]; then
	{
		echo ""
		echo "provision-cross-process-recording: cannot provision the 'cross-process-three-trace' recording:"
		printf '  - %s\n' "${failures[@]}"
		echo "scripts/materialize-recording.sh refuses to record without these, and"
		echo "the suites that replay the recording would fail on its absence."
	} >&2
	exit 1
fi

printf '%s\n' "$session_manager"
