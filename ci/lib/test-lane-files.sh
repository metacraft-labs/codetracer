#!/usr/bin/env bash
#
# test-lane-files.sh — the single source of truth for WHICH Nim test files each
# test lane runs, and with which compiler flags.
#
# WHY THIS EXISTS
# ---------------
# Every lane used to answer "which files do I run?" inline, and almost all of
# them answered it with a hand-written list of paths in `justfile` or in
# `ci/test/*.sh`. A hand-written list omits silently: the file that nobody
# remembers to add simply never runs, and nothing anywhere says so. Measured on
# this tree before this file existed, 61 test-shaped `.nim` files carrying real
# `suite`/`test` blocks were reached by NO lane at all — every
# `src/ct_test/incremental/test_*.nim`, every
# `src/frontend/viewmodel/tests/unit/test_collab_*.nim`, all five
# `src/common/*_test.nim` (including `trace_index_test.nim`, the M-REC-8
# recording-id identity suite a shipped design decision rests on), and the ten
# `docs/book-isonim/tests/*`.
#
# The immediately preceding milestone is the proof that this is a generator and
# not an accident: it added `upload_wire_format_test.nim` to a lane BY NAME and
# missed `collab_invite_url_test.nim` sitting in the same directory — while
# rewriting a comment that asserted there was "one other `*_test.nim` file in
# that directory" when there were two.
#
# So the rule this file exists to enforce: A LANE DISCOVERS ITS FILES. Every
# lane below that can be expressed as "this directory, this pattern" is
# expressed that way, so a new file in that directory runs on the next CI run
# without anyone editing anything. Where a list genuinely has to stay
# (`m16-release-gate` needs a specific order and a per-file `GLIBC_TUNABLES`;
# `visual-replay-gate` maps each file to a report row), the list stays — and
# `ci/test/test-lane-coverage.sh` then guards it, because that guard reads THIS
# file and fails by name on any test-shaped file no lane claims.
#
# Consuming this file, rather than re-deriving the same globs, is what keeps the
# guard honest: the guard and the lanes cannot disagree about what a lane runs,
# because there is only one answer and it is here.
#
# USAGE
#   source ci/lib/test-lane-files.sh
#   test_lane_ids                    # every lane id, one per line
#   test_lane_files <id>             # the lane's files, sorted, one per line
#   test_lane_backend <id>           # "c" or "js"
#   test_lane_extra_flags <id>       # extra nim flags (may be empty)
#   test_lane_description <id>       # one-line human description
#
# All paths are repo-relative. Callers must run from the repo root.

# ---------------------------------------------------------------------------
# Shared discovery helpers
# ---------------------------------------------------------------------------

# _tlf_find DIR PATTERN... — every file under DIR matching any -name PATTERN,
# sorted. Sorting is deliberate: a lane's output must not depend on the order
# the filesystem happens to hand back, or a flaky-looking reordering shows up in
# every CI log diff.
_tlf_find() {
	local dir="$1"
	shift
	local expr=()
	local first=1
	local pat
	for pat in "$@"; do
		if [ "${first}" -eq 1 ]; then
			first=0
		else
			expr+=(-o)
		fi
		expr+=(-name "${pat}")
	done
	[ -d "${dir}" ] || return 0
	find "${dir}" -type f \( "${expr[@]}" \) | sort
}

# _tlf_glob DIR PATTERN... — like _tlf_find but ONE level deep, for lanes whose
# subdirectories belong to a different lane.
_tlf_glob() {
	local dir="$1"
	shift
	[ -d "${dir}" ] || return 0
	local pat f
	for pat in "$@"; do
		for f in "${dir}"/${pat}; do
			[ -f "${f}" ] && printf '%s\n' "${f}"
		done
	done | sort -u
}

# _tlf_reject PATTERN... — filter stdin, dropping any line matching any of the
# given `grep -E` patterns. Every call site must say WHY each pattern is there;
# an unexplained exclusion is the defect this whole file is about.
_tlf_reject() {
	local pat
	local out
	out="$(cat)"
	for pat in "$@"; do
		out="$(printf '%s\n' "${out}" | grep -Ev -- "${pat}" || true)"
	done
	printf '%s\n' "${out}" | grep -v '^$' || true
}

# ---------------------------------------------------------------------------
# The lanes
# ---------------------------------------------------------------------------

# Every lane id. Order is the order a full local sweep would sensibly run them:
# cheap pure-Nim units first, toolchain- and sibling-dependent lanes last.
test_lane_ids() {
	cat <<'EOF'
common-units
ct-cli-units
ct-trace-units
mcr-enrichment-units
online-sharing-live
frontend-native-units
frontend-js
vm-unit
vm-collab-units
vm-collab-integration
vm-native
vm-js
vm-gui-headless
no-sidecar-manifests
cli-record
ct-test-incremental
ct-test-incremental-e2e
vm-recorder-gated
m16-release-gate
ct-providers
visual-replay-gate
agentic-headless
agent-api-contract
bpf
book-isonim
EOF
}

test_lane_description() {
	case "$1" in
	common-units) echo "src/common unit suites (recording ids, paths, wire format)" ;;
	ct-cli-units) echo "ct CLI unit suites outside src/ct/trace (launch, sourcemap, zip)" ;;
	ct-trace-units) echo "ct trace-layer unit suites" ;;
	mcr-enrichment-units) echo "ct upload / MCR-enrichment unit suites" ;;
	online-sharing-live) echo "live sharing round-trip (compile-checked only, never executed)" ;;
	frontend-native-units) echo "src/frontend/tests suites that compile with the C backend" ;;
	frontend-js) echo "src/frontend/tests suites that must run under node" ;;
	vm-unit) echo "ViewModel unit suites under src/frontend/viewmodel/tests/unit" ;;
	vm-collab-units) echo "collaboration ViewModel unit suites" ;;
	vm-collab-integration) echo "collaboration integration + soak suites" ;;
	vm-native) echo "GUI ViewModel headless suites, native (C) backend" ;;
	vm-js) echo "GUI ViewModel headless suites, JS backend via node" ;;
	vm-gui-headless) echo "GUI suites needing headless_session / stdio_backend" ;;
	no-sidecar-manifests) echo "RS-M12 sidecar retirement, real recording per language" ;;
	cli-record) echo "ct record CLI dispatch suites" ;;
	ct-test-incremental) echo "ct-test incremental engine suites" ;;
	ct-test-incremental-e2e) echo "ct-test --incremental live-recorder e2e" ;;
	vm-recorder-gated) echo "recorder-gated column/formatted-view/statement-step suites" ;;
	m16-release-gate) echo "M16 ct-test release gate" ;;
	ct-providers) echo "cross-language ct-test provider suites" ;;
	visual-replay-gate) echo "visual-replay regression gate (codetracer-side files)" ;;
	agentic-headless) echo "agentic CodeTracer headless matrix" ;;
	agent-api-contract) echo "agent session API contract" ;;
	bpf) echo "BPF monitor unit / native / integration suites" ;;
	book-isonim) echo "docs/book-isonim SSG suites" ;;
	*)
		echo "unknown lane '$1'" >&2
		return 1
		;;
	esac
}

# test_lane_backend ID — "c" (compile a binary and run it) or "js" (compile
# with `nim js -d:nodejs` and run under node).
test_lane_backend() {
	case "$1" in
	frontend-js | vm-js) echo "js" ;;
	*) echo "c" ;;
	esac
}

# test_lane_extra_flags ID — extra `nim` flags the lane's files need. Each
# non-empty answer must say what breaks without it.
test_lane_extra_flags() {
	case "$1" in
	mcr-enrichment-units | online-sharing-live)
		# api_client.nim pulls in std/net's `newContext`, which does not
		# compile without an SSL backend selected. Nothing here opens a TLS
		# connection; the define is a link-time requirement only.
		echo "-d:ssl -d:useOpenssl3"
		;;
	ct-cli-units)
		# src/ct/sourcemap.nim calls `GC_disable`, which only exists under the
		# refc memory manager; with Nim 2.x's default ORC it is an undeclared
		# identifier and `test_sourcemap.nim` does not compile at all.
		echo "--mm:refc"
		;;
	ct-test-incremental | ct-test-incremental-e2e)
		# test_incremental_adapter_seam.nim imports `ct_incremental_adapter`,
		# which lives at src/ct_incremental_adapter.nim (deliberately outside
		# the incremental/ subtree, because `ct-test` ships it as a standalone
		# process seam).
		echo "--path:src"
		;;
	vm-unit | vm-collab-units | vm-collab-integration | vm-native | vm-js | vm-gui-headless | vm-recorder-gated)
		# The ViewModel suites import their subjects by bare module name.
		echo "--path:src/frontend/viewmodel"
		;;
	*) echo "" ;;
	esac
}

# test_lane_files ID — the files the lane runs, repo-relative and sorted.
test_lane_files() {
	case "$1" in

	common-units)
		# Discovery. src/common holds no test helpers, so the glob is the
		# whole rule.
		_tlf_find src/common '*_test.nim'
		;;

	ct-cli-units)
		# Discovery over the `ct` CLI's non-trace unit suites. src/ct/trace has
		# its own lane (different flags), and src/ct/online_sharing and
		# src/ct/ci likewise, so those three subtrees are pruned here rather
		# than named file by file.
		_tlf_find src/ct '*_test.nim' 'test_*.nim' |
			_tlf_reject \
				'^src/ct/trace/' \
				'^src/ct/online_sharing/' \
				'^src/ct/ci/' \
				'^src/ct/agent_session_api_contract_test\.nim$' \
				'^src/ct/cli/e2e_tests\.nim$'
		;;

	ct-trace-units)
		_tlf_find src/ct/trace '*_test.nim'
		;;

	mcr-enrichment-units)
		# Discovery minus exactly one file. `online_sharing_test.nim` performs
		# a live upload/download/delete round-trip against the sharing service
		# and says so in its own header; it has its own compile-only lane
		# below. Naming it here (rather than listing the four files that DO
		# belong) is what makes a new suite in this directory run by default —
		# the previous, inverted spelling of this rule is what left
		# `collab_invite_url_test.nim` dark.
		_tlf_find src/ct/online_sharing '*_test.nim' 'test_*.nim' |
			_tlf_reject '^src/ct/online_sharing/online_sharing_test\.nim$'
		;;

	online-sharing-live)
		# Compile-checked, never executed: running it would upload a real
		# recording to the sharing service. Compile-checking it is still worth
		# a lane — the file rotted into a non-compiling state precisely
		# because nothing ever looked at it.
		echo src/ct/online_sharing/online_sharing_test.nim
		;;

	frontend-native-units)
		# Discovery over EVERY unittest suite in the directory, not just the
		# `*_test.nim` ones: `agentic_coding_test_plan.nim` (5 suites, 25 cases,
		# 60 assertions, last edited three days before this lane existed) is a
		# real suite whose name simply does not end in `_test`.
		#
		# Minus the suites that are ABOUT the JS frontend and only compile for
		# it (they are the `frontend-js` lane below).
		_tlf_find src/frontend/tests '*_test.nim' '*_test_plan.nim' |
			_tlf_reject \
				'^src/frontend/tests/frontend_lang_test\.nim$' \
				'^src/frontend/tests/scratchpad_add_dispatch_test\.nim$' \
				'^src/frontend/tests/ipc_registry_test\.nim$'
		;;

	frontend-js)
		# `just test-frontend-js` runs these through `nim js` + node, alongside
		# its .mjs suites. Listed rather than globbed because the recipe gives
		# each one a bespoke node invocation (the scratchpad one needs a
		# `globalThis.window` shim).
		#
		# `ipc_registry_test.nim` imports `std/jsffi`, which is a hard compile
		# error on the C backend ("Module jsFFI is designed to be used with the
		# JavaScript backend") — it belongs here and nowhere else.
		printf '%s\n' \
			src/frontend/tests/frontend_lang_test.nim \
			src/frontend/tests/ipc_registry_test.nim \
			src/frontend/tests/scratchpad_add_dispatch_test.nim
		;;

	vm-unit)
		# Discovery over the ViewModel unit directory, minus the two families
		# that have their own lanes for their own reasons:
		#   * the recorder-gated column / formatted-view / statement-step
		#     suites, which need a built JS recorder sibling;
		#   * the collab suites, which need the collab signalling stack.
		# Anything else added to this directory lands here automatically.
		_tlf_find src/frontend/viewmodel/tests/unit 'test_*.nim' |
			_tlf_reject \
				'/test_column_[a-z0-9_]*_vm\.nim$' \
				'/test_formatted_view_step_[a-z0-9_]*_vm\.nim$' \
				'/test_statement_step_[a-z0-9_]*_vm\.nim$' \
				'/test_collab_[a-z0-9_]*\.nim$'
		;;

	vm-collab-units)
		_tlf_find src/frontend/viewmodel/tests/unit 'test_collab_*.nim'
		;;

	vm-collab-integration)
		# Both directories, one lane: the soak suite is a long-running variant
		# of the integration ones and shares their environment.
		{
			_tlf_find src/frontend/viewmodel/tests/integration 'test_collab_*.nim'
			_tlf_find src/frontend/viewmodel/tests/soak 'test_collab_*.nim'
		} | sort
		;;

	vm-native)
		# Discovery over the whole GUI ViewModel tree. The rejections are the
		# lane's real constraints, each with its reason:
		_tlf_find src/tests/gui/tests '*_test.nim' |
			_tlf_reject \
				'/vm_test_helpers\.nim$' \
				'/integration/real_backend_test\.nim$' \
				'/integration/language_smoke_test\.nim$' \
				'/multi-replay/' \
				'/noir-space-ship/' \
				'/request-panel/no_sidecar_manifests_test\.nim$'
		# real_backend_test / language_smoke_test / multi-replay /
		# noir-space-ship need `headless_session` or `stdio_backend` (a real
		# spawned backend process) — they are the `vm-gui-headless` lane.
		# no_sidecar_manifests_test drives six recorder toolchains — it is the
		# `no-sidecar-manifests` lane.
		;;

	vm-js)
		# The native lane's set, minus what cannot compile or run under
		# `nim js`:
		test_lane_files vm-native |
			_tlf_reject \
				'/agentic-coding/' \
				'/request-panel/demo_recipe_vm_test\.nim$' \
				'/request-panel/python_request_panel_vm_test\.nim$' \
				'/request-panel/ruby_request_panel_vm_test\.nim$' \
				'/request-panel/php_request_panel_vm_test\.nim$' \
				'/request-panel/elixir_request_panel_vm_test\.nim$' \
				'/request-panel/js_request_panel_vm_test\.nim$' \
				'/request-panel/native_request_panel_vm_test\.nim$' \
				'/request-panel/remote_request_panel_vm_test\.nim$' \
				'/request-panel/request_span_conformance_test\.nim$'
		# agentic-coding/* import std/osproc, whose `quoteShell` does not exist
		# on the JS target. The request-panel suites read real `.ct` container
		# bytes through a zstd C FFI (and, for the remote one, `std/os` file
		# reads) that `nim js` has no equivalent for. All of them run in
		# `vm-native` and are registered in release_gate.nim's
		# CoreViewModelGateTests.
		;;

	vm-gui-headless)
		# The GUI suites that spawn a real backend process. Discovered from the
		# same tree as vm-native, keeping exactly what that lane rejects for
		# the headless_session / stdio_backend reason.
		{
			_tlf_find src/tests/gui/tests/integration '*_test.nim' |
				_tlf_reject '/language_smoke_mock_test\.nim$'
			_tlf_find src/tests/gui/tests/multi-replay '*_test.nim'
			_tlf_find src/tests/gui/tests/noir-space-ship '*_test.nim'
		} | sort
		;;

	no-sidecar-manifests)
		echo src/tests/gui/tests/request-panel/no_sidecar_manifests_test.nim
		;;

	cli-record)
		_tlf_find src/tests/cli '*_test.nim'
		;;

	ct-test-incremental)
		# BOTH prefixes. `test_*.nim` alone left the three `e2e_*.nim` suites
		# (12 cases, 52 assertions) dark: they are ordinary `unittest` suites
		# named after what they exercise rather than after the convention. That
		# is the failure mode this whole file exists to remove, so the glob
		# follows the directory, not the naming habit.
		_tlf_find src/ct_test/incremental 'test_*.nim' 'e2e_*.nim'
		;;

	ct-test-incremental-e2e)
		# Separate from the lane above because these record with a real
		# recorder sibling; the incremental unit suites need no sibling at all.
		# One level deep on purpose: src/ct_test/incremental/e2e_*.nim are the
		# sibling-free unit suites and belong to the lane above.
		{
			echo src/ct_test/incremental_e2e_test.nim
			_tlf_glob src/ct_test 'e2e_*.nim'
		} | sort -u
		;;

	vm-recorder-gated)
		_tlf_find src/frontend/viewmodel/tests/unit \
			'test_column_*_vm.nim' \
			'test_formatted_view_step_*_vm.nim' \
			'test_statement_step_*_vm.nim'
		;;

	m16-release-gate)
		# ENUMERATED ON PURPOSE, and this is the one place that is defensible:
		# ci/test/m16-release-gate.sh runs these in a fixed order, wraps
		# `run_orchestration_test.nim` in a per-file `GLIBC_TUNABLES` override,
		# and gates the last two behind CT_M16_HEAVY. A glob cannot express
		# any of that. The list here must mirror that script; the coverage
		# guard's existence check is what catches the two drifting apart.
		printf '%s\n' \
			src/ct_test/release_gate_test.nim \
			src/ct_test/ct_test.nim \
			src/ct_test/contracts_test.nim \
			src/ct_test/discovery_test.nim \
			src/ct_test/run_store_test.nim \
			src/ct_test/run_orchestration_test.nim \
			src/ct_test/nim_lexer_test.nim \
			src/ct_test/nim_unittest_provider_test.nim \
			src/ct_test/python_providers_test.nim \
			src/ct_test/rust_libtest_provider_test.nim \
			src/ct_test/playwright_provider_test.nim \
			src/frontend/viewmodel/tests/unit/test_test_explorer_vm.nim \
			src/frontend/viewmodel/tests/unit/test_editor_test_controls_m4.nim \
			src/ct_test/m13_smart_contract_harnesses_test.nim \
			src/tests/gui/tests/integration/language_smoke_test.nim
		;;

	ct-providers)
		# Enumerated: ci/test/ct-providers.sh interleaves these with sibling
		# recorder builds and per-language environment setup.
		printf '%s\n' \
			src/ct_test/cpp_providers_test.nim \
			src/ct_test/m11_native_languages_test.nim \
			src/ct_test/m12_fallback_languages_test.nim \
			src/ct_test/js_providers_test.nim \
			src/ct_test/ruby_providers_test.nim \
			src/ct_test/contracts_test.nim \
			src/ct_test/discovery_test.nim \
			src/ct_test/run_orchestration_test.nim \
			src/ct_test/release_gate_test.nim
		;;

	visual-replay-gate)
		# Enumerated: ci/test/visual-replay-gate-report.py maps each of these
		# paths to a specific row of the published gate report, so the set is
		# part of a contract with the report and not merely a directory.
		# (The gate also runs seven `tests/test_*.nim` files inside the
		# codetracer-visual-replay SIBLING repo; those are that repo's files
		# and are not part of this repo's coverage question.)
		printf '%s\n' \
			src/tests/gui/tests/frame-viewer/frame_viewer_vm_test.nim \
			src/tests/gui/tests/frame-viewer/visual_replay_layout_test.nim \
			src/tests/gui/tests/frame-viewer/visual_player_lifecycle_test.nim \
			src/tests/gui/tests/frame-viewer/video_player_vm_test.nim \
			src/tests/gui/tests/frame-viewer/video_player_polish_test.nim \
			src/tests/gui/tests/debug-controls/live_mcr_debug_controls_test.nim
		;;

	agentic-headless)
		# Enumerated: scripts/test-codetracer-agentic-headless.sh runs these
		# interleaved with Agent Harbor's own contract E2E tests.
		printf '%s\n' \
			src/tests/gui/tests/agentic-coding/agent_service_m3_test.nim \
			src/tests/gui/tests/agentic-coding/agentic_vm_m4_test.nim \
			src/tests/gui/tests/agentic-coding/agentic_deepreview_m5_test.nim \
			src/tests/gui/tests/agentic-coding/agentic_headless_m6_test.nim \
			src/tests/gui/tests/agentic-coding/agentic_provider_mode_m8_test.nim \
			src/tests/gui/tests/agent-activity/agent_activity_vm_test.nim \
			src/tests/gui/tests/agent-workspace/agent_workspace_vm_test.nim \
			src/tests/gui/tests/vcs/vcs_vm_test.nim \
			src/tests/gui/tests/deepreview/deepreview_vm_test.nim \
			src/tests/gui/tests/agent-activity-deepreview/agent_activity_rollup_removal_test.nim \
			src/frontend/viewmodel/tests/unit/test_collab_signal_registry.nim
		;;

	agent-api-contract)
		echo src/ct/agent_session_api_contract_test.nim
		;;

	bpf)
		# `just test-bpf` fans out to four recipes, one per file; each needs
		# different capabilities, so they stay separate recipes. Discovery over
		# the directory keeps the SET honest even though the recipes are named.
		_tlf_find src/ct/ci '*_test.nim'
		;;

	book-isonim)
		_tlf_find docs/book-isonim/tests 'test_*.nim'
		;;

	*)
		echo "test_lane_files: unknown lane '$1'" >&2
		return 1
		;;
	esac
}

# test_lane_all_files — the union of every lane's files, deduplicated.
test_lane_all_files() {
	local id
	while read -r id; do
		[ -n "${id}" ] || continue
		test_lane_files "${id}"
	done < <(test_lane_ids) | sort -u
}
