#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="${1:-matrix}"
log_root="${CODETRACER_AGENTIC_TEST_LOG_DIR:-${TMPDIR:-/tmp}/codetracer-agentic-headless-$(date +%Y%m%d-%H%M%S)-$$}"
mkdir -p "$log_root"

run_cmd() {
	local name="$1"
	shift
	local log="$log_root/${name}.log"
	printf '  %-58s' "$name"
	if (cd "$repo_root" && "$@") >"$log" 2>&1; then
		echo "OK"
	else
		echo "FAILED"
		echo "    log: $log" >&2
		grep -E '(^\[FAILED\]|Error:|FAILED|panicked|failures:|test result:)' "$log" | tail -20 >&2 || true
		exit 1
	fi
}

run_nim() {
	local path="$1"
	local name
	name="$(basename "$path" .nim)"
	run_cmd "$name" nim c -r --hints:off --path:src/frontend/viewmodel \
		--nimcache:"/tmp/ct-nim-cache/${name}" -o:"/tmp/ct-nim-cache/${name}/${name}" "$path"
}

run_rust() {
	local name="$1"
	local command="$2"
	if command -v cargo >/dev/null 2>&1; then
		run_cmd "$name" bash -lc "$command"
	elif [ -n "${CODETRACER_RUST_TOOLCHAIN_BIN:-}" ] && [ -x "${CODETRACER_RUST_TOOLCHAIN_BIN}/cargo" ]; then
		run_cmd "$name" bash -lc "export PATH='${CODETRACER_RUST_TOOLCHAIN_BIN}':\$PATH; $command"
	elif rust_bin="$(find /nix/store -maxdepth 1 -type d -name '*rust-mixed' -print 2>/dev/null | sort | tail -1)/bin" &&
		[ -x "$rust_bin/cargo" ]; then
		run_cmd "$name" bash -lc "export PATH='$rust_bin':\$PATH; $command"
	else
		run_cmd "$name" nix develop --command bash -lc "$command"
	fi
}

run_agent_harbor_contracts() {
	local ah_root="${AGENT_HARBOR_REPO:-$repo_root/../agent-harbor}"
	if [ ! -d "$ah_root" ]; then
		echo "Agent Harbor repo not found at $ah_root" >&2
		exit 1
	fi
	run_cmd "agent-harbor-codetracer-m0-e2e" \
		bash -lc \
		"cd '$ah_root' && ./scripts/nix-env.sh -c \"scripts/run-test-suite.sh cargo nextest run -p acp-client-runs-scenario --profile single --test codetracer_contract_m0 -E 'test(e2e_codetracer_contract_worktree_changed_files_diff_and_ct_command)'\""
	run_cmd "agent-harbor-codetracer-m1-e2e" \
		bash -lc \
		"cd '$ah_root' && ./scripts/nix-env.sh -c \"scripts/run-test-suite.sh cargo nextest run -p acp-client-runs-scenario --profile single --test codetracer_contract_m0 -E 'test(e2e_codetracer_contract_worktree_file_edges_reconnect_and_client_methods)'\""
}

run_headless_matrix() {
	echo "=== CodeTracer agentic headless matrix ==="
	run_agent_harbor_contracts
	run_nim "src/tests/gui/tests/agentic-coding/agent_service_m3_test.nim"
	run_nim "src/tests/gui/tests/agentic-coding/agentic_vm_m4_test.nim"
	run_nim "src/tests/gui/tests/agentic-coding/agentic_deepreview_m5_test.nim"
	run_nim "src/tests/gui/tests/agentic-coding/agentic_headless_m6_test.nim"
	echo "logs: $log_root"
}

run_regression_gate() {
	echo "=== CodeTracer agentic regression gate ==="
	run_headless_matrix
	run_nim "src/tests/gui/tests/agent-activity/agent_activity_vm_test.nim"
	run_nim "src/tests/gui/tests/agent-workspace/agent_workspace_vm_test.nim"
	run_nim "src/tests/gui/tests/vcs/vcs_vm_test.nim"
	run_nim "src/tests/gui/tests/deepreview/deepreview_vm_test.nim"
	run_nim "src/tests/gui/tests/agent-activity-deepreview/agent_activity_deepreview_vm_test.nim"
	run_cmd "collab-signal-registry" nim c -r src/frontend/viewmodel/tests/unit/test_collab_signal_registry.nim
	run_rust "db-backend-dap-protocol" "cd src/db-backend && cargo test --no-default-features --test dap_protocol"
	run_rust "backend-manager-routing" "cd src/backend-manager && cargo test --bin session-manager && cargo test --test real_recording_integration test_real_rr_ && cargo test --test dive_in_url_fetch_test && cargo test --test meta_dat_metadata_loading"
	echo "logs: $log_root"
}

case "$mode" in
matrix)
	run_headless_matrix
	;;
regression)
	run_regression_gate
	;;
*)
	echo "usage: $0 {matrix|regression}" >&2
	exit 2
	;;
esac
