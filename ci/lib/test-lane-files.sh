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

# _tlf_keep_matching_file PATTERN — filter stdin (a list of paths), keeping only
# files whose CONTENTS match the `grep -E` PATTERN.
#
# Selecting a lane's set by what a file DEPENDS ON rather than by what it is
# NAMED is the stronger rule wherever the dependency is what the lane is about.
# The whole point of this file is that a lane discovers its files; a filename
# convention is a discovery rule that silently stops working the moment someone
# names a file reasonably and differently.
_tlf_keep_matching_file() {
	local pat="$1" f
	while read -r f; do
		[ -n "${f}" ] || continue
		[ -f "${f}" ] || continue
		if grep -qE -- "${pat}" "${f}"; then
			printf '%s\n' "${f}"
		fi
	done
}

# _tlf_reject_matching_file PATTERN — the complement of the above.
_tlf_reject_matching_file() {
	local pat="$1" f
	while read -r f; do
		[ -n "${f}" ] || continue
		[ -f "${f}" ] || continue
		if ! grep -qE -- "${pat}" "${f}"; then
			printf '%s\n' "${f}"
		fi
	done
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
host-instantiations
renderer-electron
renderer-web
frontend-native-units
frontend-js
vm-unit
vm-unit-js
vm-collab-units
vm-collab-integration
vm-native
vm-js
vm-gui-headless
no-sidecar-manifests
cli-record
ct-test-incremental
ct-test-incremental-e2e
ct-test-certificates
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
	host-instantiations) echo "JS-backend modules no other lane compiles: the facade's host instantiations and platform_host's Electron arm (compile-checked only)" ;;
	renderer-electron) echo "the renderer entry points, BROWSER target, Electron arm (compile-checked only)" ;;
	renderer-web) echo "the renderer entry point, BROWSER target, -d:ctWeb arm (compile-checked only)" ;;
	frontend-native-units) echo "src/frontend/tests suites that compile with the C backend" ;;
	frontend-js) echo "src/frontend/tests suites that must run under node" ;;
	vm-unit) echo "ViewModel unit suites under src/frontend/viewmodel/tests/unit" ;;
	vm-unit-js) echo "the same ViewModel unit suites, JS backend via node" ;;
	vm-collab-units) echo "collaboration ViewModel unit suites" ;;
	vm-collab-integration) echo "collaboration integration + soak suites" ;;
	vm-native) echo "GUI ViewModel headless suites, native (C) backend" ;;
	vm-js) echo "GUI ViewModel headless suites, JS backend via node" ;;
	vm-gui-headless) echo "GUI suites needing headless_session / stdio_backend" ;;
	no-sidecar-manifests) echo "RS-M12 sidecar retirement, real recording per language" ;;
	cli-record) echo "ct record CLI dispatch suites" ;;
	ct-test-incremental) echo "ct-test incremental engine suites" ;;
	ct-test-incremental-e2e) echo "ct-test --incremental live-recorder e2e" ;;
	ct-test-certificates) echo "ct-test test-certificate issuance, verification and conformance vectors" ;;
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

# test_lane_backend ID — "c" (compile a binary and run it), "js" (compile with
# `nim js -d:nodejs` and run under node), or "js-browser".
#
# `js-browser` EXISTS BECAUSE `-d:nodejs` IS NOT A NEUTRAL FLAG. The `js`
# backend above passes it, and must: without it `std/exitprocs
# .setProgramResult` is undeclared on the JS target, `std/unittest` substitutes
# a no-op, and node exits 0 even when a case fails (`vm-js-lane-test.sh` proves
# that against the real toolchain rather than asserting it).
#
# But the renderer is a BROWSER module, and under `-d:nodejs` it does not
# compile at all — `kdom`'s `createElementNS` is absent, because node is not a
# browser. That is why the earlier attempt to put `renderer.nim` in
# `host-instantiations` failed, and the note there correctly refused to force
# it: compiling the renderer under `-d:nodejs` would gate it in a configuration
# nothing ships.
#
# The resolution is a third backend rather than an exception inside the second.
# `js-browser` is `nim js` with no `-d:nodejs`, and it is ALWAYS compile-only —
# see run-nim-test-lane.sh, which forces that rather than trusting a caller to
# pass `--compile-only`. There is nothing to run: a browser bundle needs a
# browser, and running it under node would either crash on `document` or, worse,
# appear to pass while executing none of it.
test_lane_backend() {
	case "$1" in
	frontend-js | vm-js | vm-unit-js | host-instantiations) echo "js" ;;
	renderer-electron | renderer-web) echo "js-browser" ;;
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
	vm-unit | vm-unit-js | vm-collab-units | vm-collab-integration | vm-native | vm-js | vm-gui-headless | vm-recorder-gated | host-instantiations)
		# The ViewModel suites import their subjects by bare module name.
		echo "--path:src/frontend/viewmodel"
		;;
	renderer-electron)
		# The product's own renderer defines, from `RendererDefines` in
		# repro.nim (the tup `!nim_js` macro carries the same pair). They are
		# load-bearing, not decoration:
		#
		#   -d:ctRenderer            selects the browser/renderer arm in
		#                            `lib/misc_lib.nim`, `lib/electron_lib.nim`
		#                            and `ui/menu.nim`. Without it this compiles
		#                            the module set the Electron MAIN process
		#                            uses, which is a different product.
		#   -d:chronicles_enabled=off the renderer does not link the logging
		#                            sinks; with them on, chronicles pulls
		#                            `std/os` file sinks into a browser bundle.
		#
		# Deliberately NOT `-d:ctInExtension`: that is the VS Code extension
		# build, a third product, and this lane's subject is what SHIPS as
		# CodeTracer.
		#
		# This note used to end "and it is currently broken for an unrelated
		# reason", which was true and then stayed true for as long as nobody
		# compiled it — the extension arm was broken twice over (an internal
		# `nim js` codegen error in `ui/trace.nim` and an identifier M49 added
		# to only one of `dap.nim`'s arms) and no gate could see it. It is
		# fixed, and `ci/test/renderer-extension-build.sh` (`just
		# test-renderer-extension-build`) compiles it now, in the exact
		# configuration `just build-ui-js` uses, so the sentence cannot rot
		# back into a description of a build nobody runs.
		echo "-d:chronicles_enabled=off -d:ctRenderer"
		;;
	renderer-web)
		# The same renderer, plus `-d:ctWeb` — the define `platform_host.nim`'s
		# three-way switch reads. This arm must link NO Electron host module,
		# which is what `ci/test/renderer-browser-build.sh` goes on to assert
		# about the bundle this lane compiles.
		echo "-d:chronicles_enabled=off -d:ctRenderer -d:ctWeb"
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

	host-instantiations)
		# NOT test files. Production modules of the platform facade, compiled
		# on the backend they actually ship on. Four are echoed at the bottom
		# of this arm; read that list, not a count written here.
		#
		# WHY THIS LANE EXISTS, and it is not a hypothetical. The argument is
		# about the two host INSTANTIATIONS — `desktop_electron.nim` and
		# `web_browser.nim`. Both are `{.error.}` on the C backend by design,
		# so `vm-unit` cannot see them; and neither is imported by any suite in
		# `vm-unit-js`, because the whole point of
		# `platform/web_platform.nim` is that it reaches no browser API and can
		# therefore be tested without these. The result was a hole exactly the
		# shape of those two files: NOTHING IN CI COMPILED THEM AT ALL.
		#
		# The other two in the list are here for their own reasons, not this
		# one. `platform_host.nim` is here for its Electron arm (spelled out
		# below). `opfs_volume.nim` is the web instantiation's OPFS volume: it
		# is also `{.error.}` on C, but unlike the two above it IS driven by a
		# suite — `test_opfs_volume.nim`, added to `vm-unit-js` against a fake
		# `navigator.storage` — so for it this lane is a second compile rather
		# than the only one.
		#
		# It was not theoretical for long. `web_browser.nim` reached `dev` at
		# ed9d6021 with a doc comment after the closing paren of an object
		# constructor — `Error: invalid indentation`, the module would not
		# build for anyone — and every lane stayed green, because every lane
		# was looking somewhere else. That is the same failure
		# `online-sharing-live` above was created for, in the same week, one
		# directory over.
		#
		# Compile-only, like that lane: `web_browser.nim` needs a browser and
		# `desktop_electron.nim` needs Electron, so neither can RUN here. A
		# compile is the weakest check that catches what actually broke, and
		# it costs seconds.
		#
		# Listed explicitly rather than discovered. A glob over `host/` would
		# pull in `desktop_native.nim` and `remote_stub.nim`, which are C-backend
		# modules `vm-unit` already compiles, and a lane that compiles a module
		# on the wrong backend reports a green that means nothing.
		# `platform_host.nim` is here for its ELECTRON arm specifically. It is
		# a three-way switch (`js`+`ctWeb`, `js`, native) and each arm needs a
		# gate, or the switch acquires a hole the shape of whichever arm is
		# newest — which is exactly how `web_browser.nim` came to sit
		# unparseable on `dev` for days. The three arms and their gates:
		#
		#   native            frontend-native-units, via
		#                     tests/platform_bootstrap_test.nim, which imports
		#                     platform_host and runs on the C backend
		#   js (Electron)     THIS LANE — nothing else compiles it. The
		#                     renderer entry `ui_js.nim` does, but only in the
		#                     tup build, which CI does not run for this job
		#   js + ctWeb        ci/test/web-bundle-smoke.sh, which builds
		#                     web_main.nim with -d:ctWeb and additionally
		#                     asserts the bundle links no host bindings
		#
		# The lane's flags carry no `-d:ctWeb`, so the file compiles here on
		# its Electron arm. That is deliberate and is the arm with no other
		# gate; do not add the define to this lane without giving the Electron
		# arm one somewhere else.
		# `renderer.nim` IS NOT HERE, and the reason is worth recording because
		# it was tried. No lane compiles it either — a third instance of this
		# same hole, found while migrating its facade call sites — but it
		# CANNOT go in this lane: `run-nim-test-lane.sh` passes `-d:nodejs` to
		# every JS lane, which is load-bearing there (without it
		# `std/exitprocs.setProgramResult` is undeclared and node exits 0 even
		# when a case fails), and under `-d:nodejs` the renderer does not
		# compile at all — `kdom`'s `createElementNS` is absent, because the
		# renderer is a BROWSER module and node is not a browser. Forcing it in
		# would compile it in a configuration nothing ships, which is exactly
		# what the note below warns against.
		#
		# What DOES compile it is the tup product build, transitively through
		# `ui_js.nim`. So it is better covered than `web_browser.nim` ever was
		# — but not by this CI job, and a change to its facade call sites is
		# therefore checked at package time rather than on push. That gap is
		# real and is recorded in the milestone file rather than papered over
		# with a lane that would lie.
		echo src/frontend/platform_host.nim
		echo src/frontend/viewmodel/host/desktop_electron.nim
		echo src/frontend/viewmodel/host/opfs_volume.nim
		echo src/frontend/viewmodel/host/web_browser.nim
		;;

	renderer-electron)
		# THE RENDERER ENTRY POINTS, on the backend and in the configuration
		# they actually ship on. This lane and `renderer-web` below are what
		# close the hole the note in `host-instantiations` describes: until
		# they existed, NOTHING IN CI COMPILED THE RENDERER, and the only gate
		# was the tup product build at package time.
		#
		# THAT HOLE WAS NOT HYPOTHETICAL, and the cost is the reason these
		# lanes are worth their minutes. Commit 333ec709 removed
		# `ui_imports`' blanket re-export of `electron_lib` after auditing its
		# 14 exported symbols for uses "anywhere under `ui/`". `ui_js.nim` is
		# at `src/frontend/`, not under `ui/`, and it read `inElectron` from
		# that re-export. The renderer entry point stopped compiling, `dev`
		# carried it that way, and every suite stayed green — the same shape
		# as `web_browser.nim` sitting unparseable for days, one directory
		# over, in the same week.
		#
		# WHY THE ENTRY POINT AND NOT THE MODULES UNDER IT. `renderer.nim` and
		# `ui/menu.nim` are the two modules people reach for when they think of
		# "the renderer", and neither belongs here AS ITS OWN SUBJECT:
		#
		#   * both are compiled transitively by `ui_js.nim`, which imports
		#     `renderer` directly and `menu` through its `ui/[...]` list, so
		#     this lane already type-checks every line of them;
		#   * `menu.nim` does not compile STANDALONE, and did not before any of
		#     this work — it fails in `session_switch.nim` at an undeclared
		#     `rewireDebugControlsBridgeForActiveSession`. That is an artefact
		#     of the entry module, not a gap: `debug.nim` exports the proc,
		#     `session_switch.nim` imports `debug`, and the two sit in an
		#     import cycle with `menu` that Nim resolves in a different order
		#     when `menu.nim` is itself the main module. Compiled from
		#     `ui_js.nim` — the way the product builds it — it resolves and the
		#     whole graph type-checks.
		#
		# So listing `menu.nim` here would gate it in a configuration nothing
		# ships and fail red on unmodified `dev`, which is the exact mistake
		# the `-d:nodejs` note in `host-instantiations` warns against. The
		# entry point is the honest subject.
		#
		# `subwindow.nim` is the second renderer entry point (Electron's
		# install subwindow) and is Electron-only by its own `{.error.}` guard,
		# so it appears in this lane and NOT in `renderer-web`.
		#
		# PREREQUISITE, and it fails opaquely without it: `ui_js.nim` reaches
		# `isonim/dsl/tailwind`, which `staticRead`s
		# `<isonim>/build/tailwind-styles.json` at compile time. A missing file
		# is an UNCATCHABLE Nim compile error several minutes in, naming
		# neither this lane nor the file's purpose. CI seeds a `{}` placeholder
		# in `.github/actions/setup-isonim-siblings`; locally
		# `scripts/build-tailwind.sh` (or `just build-tailwind`) generates the
		# real one. `ci/test/renderer-browser-build.sh` checks for it up front
		# and says so by name.
		echo src/frontend/subwindow.nim
		echo src/frontend/ui_js.nim
		;;

	renderer-web)
		# The same entry point with `-d:ctWeb`. NS2's
		# `test_one_codebase_two_platforms` asks that one codebase produce two
		# builds; `ci/test/web-bundle-smoke.sh` covers the web INSTANTIATION
		# (`web_main.nim`) and explicitly disclaims the renderer, because at the
		# time the renderer's import graph still reached `electron_lib`
		# through `lib/misc_lib.nim`. That edge is cut, so the renderer now has
		# a web arm and this lane is what keeps it.
		#
		# ONE FILE, and the omissions are the point rather than an oversight:
		# `subwindow.nim`, `ui/panel_transfer.nim`,
		# `ui/agentic_worktree_test_hooks.nim` and `lib/electron_lib.nim` each
		# carry a `when defined(ctWeb): {.error: ...}` naming the capability
		# they need and the web profile lacks. They are ABSENT from this arm by
		# design. Adding one here would not test the web build; it would
		# assert that a module which declares itself impossible is possible.
		echo src/frontend/ui_js.nim
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
				'^src/frontend/tests/ipc_registry_test\.nim$' \
				'^src/frontend/tests/target_axes_js_test\.nim$'
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
		#
		# `target_axes_js_test.nim` is the JS half of the four-axis domain
		# types' PLACEMENT requirement: `src/common/target_axes.nim` and
		# `src/common/target_assessment.nim` must be reachable from every front
		# end, so they have to compile on both backends and the compiling is
		# itself part of the assertion (a stray `std/jsffi` or `os` import fails
		# on one side and nowhere else).  It was previously claimed only by the
		# C-backend `frontend-native-units` lane, which is the wrong backend for
		# the property it exists to prove, and by `just test-frontend-js`, which
		# no lane knew about — the "registered in only one place runs nowhere"
		# shape.  Its C-backend counterpart is
		# `src/tests/cli/target_axes_test.nim`, in the `cli-record` lane.
		#
		# `shortcut_bindings_test.nim` asserts that the SHIPPED
		# `default_config.yaml` actually binds the chords it names, and that
		# nothing landed in `conflictList` — where `initShortcutMap` silently
		# drops a second claim on a chord. It is JS-only because
		# `frontend/config.nim` is built on `std/jsffi`'s `JsAssoc`, and it
		# needs the same `globalThis.window` shim the scratchpad suite does.
		# `debug_toolbar_tooltips_test.nim` is the same shape one level up: the
		# debug toolbar's tooltips must NAME the chord that is bound rather than
		# restate it as a literal, so it asserts the shipped table drives all 13
		# controls and that rebinding one changes the answer. JS-only for the
		# same `JsAssoc` reason.
		# `component_registry_binding_test.nim` is JS-only for the reason its
		# subject is: `Component.data` matters because every `self.data.<x>` in
		# `ui/` expands to `data.sessions[data.activeSessionIndex].<x>`, and
		# that forwarding only exists on the JS side (`std/jsffi`'s `JsAssoc`,
		# and the `{.emit.}`ed getters in `types.nim`). It is also the only
		# lane that RUNS `registerComponent` rather than compile-checking it.
		# `run_to_cursor_test.nim` is the Nim half of a cross-language
		# coupling: *Run to Cursor* is `ct/source-line-jump` with
		# `behaviour = ForwardJump`, and that enum crosses as its ORDINAL, so
		# the number leaving Nim has to equal the discriminant Rust decodes.
		# JS-only because the ordinal is a property of the JS backend's enum
		# representation — on the C backend the question does not arise. Its
		# Rust half is `the_wire_form_of_jump_behaviour_is_the_nim_ordinal` in
		# `src/db-backend/src/dap_handler.rs`.
		# `dap_refusal_surfaces_test.nim` asserts that a request the backend
		# REFUSES becomes text in the status bar, and that the text differs
		# from the one a timeout produces. JS-only twice over: the code under
		# test is dap.nim's `when not defined(ctInExtension)` arm — the
		# extension arm correlates responses through VS Code's own client and
		# has no `pendingResponses` table — and `types.nim`'s `Data` is
		# `std/jsffi`-based. It is also the ONLY suite in this lane compiled
		# WITHOUT `-d:ctInExtension`, for that first reason.
		printf '%s\n' \
			src/frontend/tests/component_registry_binding_test.nim \
			src/frontend/tests/dap_refusal_surfaces_test.nim \
			src/frontend/tests/debug_toolbar_tooltips_test.nim \
			src/frontend/tests/frontend_lang_test.nim \
			src/frontend/tests/ipc_registry_test.nim \
			src/frontend/tests/run_to_cursor_test.nim \
			src/frontend/tests/scratchpad_add_dispatch_test.nim \
			src/frontend/tests/shortcut_bindings_test.nim \
			src/frontend/tests/shortcut_dialog_test.nim \
			src/frontend/tests/shortcut_presets_test.nim \
			src/frontend/tests/stop_command_test.nim \
			src/frontend/tests/target_axes_js_test.nim
		;;

	vm-unit)
		# Discovery over the ViewModel unit directory, minus the two families
		# that have their own lanes for their own reasons:
		#   * the recorder-gated suites, which need a built recorder sibling
		#     (`vm-recorder-gated`);
		#   * the collab suites, which need the collab signalling stack.
		# Anything else added to this directory lands here automatically.
		#
		# The recorder-gated set is subtracted BY DEPENDENCY, not by filename
		# family, and the difference was a live defect rather than a
		# refinement. The rejections here used to be three filename globs
		# (`test_column_*_vm`, `test_formatted_view_step_*_vm`,
		# `test_statement_step_*_vm`), and
		# `test_js_subdir_trace_vm.nim` — which imports `recorder_gate`, drives
		# the real `codetracer-js-recorder` sibling and skips without it —
		# matches none of the three. So it ran in THIS lane, skipped its only
		# case for want of a recorder, produced no `[OK]` line, and the runner
		# scored the whole file `DID NOT RUN`. That is the one red in `vm-unit`
		# on `dev`: a suite in a lane that does not provide what it needs.
		#
		# `test_opfs_volume` (NS2) is the one rejection that runs in the JS
		# lane and NOT here — the mirror image of `test_platform_desktop_native`
		# below. Its subject, `viewmodel/host/opfs_volume.nim`, is the browser's
		# origin-private filesystem and is a hard `{.error.}` on the C target,
		# exactly as the native desktop instantiation is on the JS one. So it is
		# subtracted here and ADDED to `vm-unit-js`, which is the only lane that
		# can run it.
		# `headless_session` joins `recorder_gate` in the subtraction for the
		# same reason, one dependency further down: importing it means the
		# suite SPAWNS a real `replay-server`, and this lane's recipe
		# (`just test-vm-unit`) does not build one. Every such suite happened
		# to import `recorder_gate` too until `test_row_click_jump_vm.nim`,
		# which needs the replay-server but no recorder — so matching only on
		# `recorder_gate` would have left it here, failed `findReplayServer`,
		# produced no `[OK]` line and scored `DID NOT RUN`. That is exactly
		# the shape described above for `test_js_subdir_trace_vm.nim`; naming
		# the second dependency keeps it from recurring.
		_tlf_find src/frontend/viewmodel/tests/unit 'test_*.nim' |
			_tlf_reject_matching_file '^[[:space:]]*import[[:space:]]+((\.\./)*recorder_gate|(\.\./)*headless_session)([[:space:],]|$)' |
			_tlf_reject '/test_collab_[a-z0-9_]*\.nim$' \
				'/test_opfs_volume\.nim$'
		;;

	vm-unit-js)
		# The Tier-1 ViewModel suites, on the backend BlockTracer actually
		# ships.
		#
		# WHY THIS LANE EXISTS. Front-End-Architecture.md §6 asks for the test
		# pyramid "run on both the C and JS backends", and until this lane
		# existed Tier 1 ran on C only: `vm-unit` is a C lane, and `vm-js`
		# reaches `src/tests/gui/tests` and nothing else, so every suite under
		# `viewmodel/tests/unit` — including the Embed SDK's own conformance
		# suite and M2b's §14 degraded-state assertions — was exercised on one
		# backend of the two.
		#
		# It was not a theoretical gap. Adding this lane immediately failed:
		# `DebuggerSession.launch` reported `dspReady` for a launch the backend
		# had answered `success: false`, because
		# `nim_everywhere/async_compat.onComplete` queues even a synchronously
		# resolved future's callback on the JS target while running it inline on
		# native. CodeTracer-Embed-SDK.md §6.3's whole error taxonomy was inert
		# on the backend the web debugger runs on.
		#
		# The set is `vm-unit` minus what cannot compile under `nim js`, and
		# each rejection says what breaks:
		test_lane_files vm-unit |
			_tlf_reject \
				'/test_editor_test_controls_m4\.nim$' \
				'/test_test_explorer_vm\.nim$' \
				'/test_sdk_facade_boundary\.nim$' \
				'/test_project_action_runner\.nim$' \
				'/test_platform_desktop_native\.nim$' \
				'/test_pane_mount_markers_are_released\.nim$'
		# `test_pane_mount_markers_are_released` walks `src/frontend/ui/*.nim`
		# with `std/os`'s `walkFiles` and reads each file, because its subject
		# is a property of the SOURCE TREE — which panes declare a mount marker
		# and which release it — and not of any running program. `walkFiles` is
		# an `{.error.}` on the JS target, so this suite has never compiled in
		# this lane: it fails at the `nim js` step, before a single case runs.
		#
		# THAT IS WHY THE REJECTION IS THE FIX AND NOT A `when defined(js)`
		# GUARD. Compiling the file under `nim js` with its scan elided would
		# leave a suite that reports green having asserted nothing about the
		# tree — a vacuous pass, which is worse than an honest absence, since
		# the whole point of the file is a counted debt list. A structural scan
		# has one correct backend, and it already runs there: `vm-unit` covers
		# it on native, where the filesystem exists.
		#
		# It was added to this lane by discovery — `vm-unit-js` is `vm-unit`
		# minus explicit rejections, so a new file lands here without an edit,
		# which is the property this lane wants and the reason this rejection
		# has to be written down rather than assumed.
		# `test_platform_desktop_native` (NS1) exercises the platform facade's
		# NATIVE desktop instantiation against the real host — `std/os`,
		# `std/osproc`, real child processes. Its subject,
		# `viewmodel/host/desktop_native.nim`, is a hard `{.error.}` on the JS
		# target by design: the Electron renderer has its own instantiation
		# (`host/desktop_electron.nim`) reaching node and Electron APIs, and
		# one module pretending to be both is the drift NS1 exists to prevent.
		# The BACKEND-INDEPENDENT half of the same milestone —
		# `test_platform_facade.nim`, which covers the capability model, the
		# topbar's capability-driven action set, the remote instantiation and
		# the path arithmetic — carries no host dependency and DOES run here,
		# on both backends. That split is the same one drawn for
		# `test_project_action_runner` above, and for the same reason.
		# `test_project_action_runner` (VN-M3) launches real child processes
		# through `runquota_process`, a POSIX launcher, and reads a project's
		# `tasks.json` off disk with `std/os`. Neither has a `nim js`
		# equivalent. The split is deliberate and matches the rejections
		# above: the *pure* half of the same milestone — the classifier, the
		# six-outcome vocabulary, the marker builder, the render plan and the
		# no-replay property — lives in `test_verification_vm.nim` and
		# `test_project_actions.nim`, which carry no host dependency and DO
		# run in this lane on both backends.
		#
		# `test_editor_test_controls_m4` and `test_test_explorer_vm` call
		# `os.getCurrentProcessId` to name a per-run temporary directory of real
		# fixture files, and that proc is an `{.error.}` on the NimScript/JS
		# target. They are filesystem-fixture suites rather than pure ViewModel
		# ones; they run in `vm-unit`.
		#
		# `test_sdk_facade_boundary` runs `ci/test/sdk-facade-boundary.sh`
		# through `std/osproc` (`cannot export: quoteShell` on JS). It exists as
		# a file at all because splitting it out of `test_sdk_facade.nim` is
		# what let the SDK's conformance suite into this lane — which is where
		# the `launch` defect above was found.
		#
		# Every OTHER suite in the directory runs here. Four of them
		# (`test_sync`, `test_event_log_marker_vm`, `test_origin_chain_vm`,
		# `test_state_value_history_toggle`) could not, until each swapped a
		# private `poll(0)` for `async_compat.drainPlatformCallbacks`:
		# `std/asyncdispatch` pulls in `std/nativesockets`, which does not
		# compile on JS. That was a test-harness import, not a subject
		# limitation, and rejecting the four would have been recording the
		# harness's habit as a fact about the product.
		#
		# And ONE file this lane has that `vm-unit` does not. `test_opfs_volume`
		# (NS2) drives `viewmodel/host/opfs_volume.nim` — the browser's
		# origin-private filesystem — against a fake `navigator.storage`
		# installed into the global object, so every `{.importjs.}` body in that
		# module runs unmodified under node. Its subject is a hard `{.error.}`
		# on the C target, so it is subtracted from `vm-unit` above and added
		# here rather than being derived. This is the only lane that can run it,
		# and the only place in the tree where the WEB instantiation's
		# browser-facing half is exercised at all.
		printf '%s\n' src/frontend/viewmodel/tests/unit/test_opfs_volume.nim
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
				'/welcome-screen/welcome_screen_recent_folders_test\.nim$' \
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
		# on the JS target. `welcome_screen_recent_folders_test.nim` is the same
		# error through `src/common/trace_index` (osproc + db_sqlite), and it
		# exists as a separate file precisely so this rejection costs one
		# genuinely-native case instead of the 44 headless `WelcomeScreenVM`
		# cases that used to share its binary — see that file's header.
		# The request-panel suites read real `.ct` container
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

	ct-test-certificates)
		# Globbed on the prefix, not enumerated, so a new certificate suite
		# runs on the next CI run without anyone editing this file — which is
		# the rule the whole file exists to enforce. The conformance-vector
		# walker in this lane needs the `test-certificates-spec` sibling repo
		# and fails loudly without it, rather than passing vacuously.
		_tlf_glob src/ct_test 'certificate*_test.nim'
		;;

	vm-recorder-gated)
		# The mirror image of `vm-unit`'s subtraction, and expressed the same
		# way so the two cannot disagree: a suite is recorder-gated iff it
		# imports `recorder_gate`, which is the module that exists to make the
		# missing-recorder outcome uniform and greppable. Selecting on the
		# dependency rather than on three filename families is what puts
		# `test_js_subdir_trace_vm.nim` in the lane whose runner builds a
		# recorder — see the note in `vm-unit`.
		# Extended to `headless_session` alongside `recorder_gate` so this stays
		# the exact complement of `vm-unit`'s subtraction — the two predicates
		# are one string, and a suite that needs a spawned `replay-server` but
		# no recorder still lands in the only lane whose recipe builds one.
		_tlf_find src/frontend/viewmodel/tests/unit 'test_*.nim' |
			_tlf_keep_matching_file '^[[:space:]]*import[[:space:]]+((\.\./)*recorder_gate|(\.\./)*headless_session)([[:space:],]|$)'
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
			src/ct_test/noir_providers_test.nim \
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
