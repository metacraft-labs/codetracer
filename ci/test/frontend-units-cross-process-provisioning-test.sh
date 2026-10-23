#!/usr/bin/env bash
# =============================================================================
# Contract: `just test-frontend-units` provisions the three tools the
# `cross-process-three-trace` recording is produced with, fails loudly when it
# cannot, and its lane keeps the reason a recording could not be produced.
#
#   bash ci/test/frontend-units-cross-process-provisioning-test.sh
#
# WHY THIS FILE EXISTS
#   codetracer-pm issues/2026-10-21-test-frontend-units-does-not-provision-the-
#   three-trace-recording-its-cross-process-suite-needs.md.
#   `cross_process_origin_vm_test.nim` replays the `cross-process-three-trace`
#   recording, which scripts/materialize-recording.sh produces from the tree on
#   first use and refuses to produce without `ct-instrument`,
#   `session-manager` and a built codetracer-js-recorder.  Measured at
#   codetracer 113b33e60 on nixos-ci-bare-002, the lane reported
#   `PARTIAL (1 OK, 3 FAILED)` because:
#     (1) nothing on the recipe's path built those tools, and
#         scripts/build-siblings.sh had no entry for
#         codetracer-wasm-instrumenter at all, so not even
#         `just build-siblings` could produce `ct-instrument`;
#     (2) the justfile's lane-deferral note blamed "an uncommitted rr/MCR
#         cross-process recording", which does not exist;
#     (3) the lane printed the 25 lines before `[FAILED]`, and the suite
#         checkpointed the helper's whole `cargo test` output there, so the
#         materialiser's "missing prerequisites" list never reached the report.
#   Cases (A)/(B) pin (1), (C)/(D) pin the recipe and (2); (3) is pinned by the
#   Nim suite itself ("dump helper failure report" in that file), which is
#   where the summary is computed.
#
# WHAT IT RUNS
#   The REAL scripts/build-siblings.sh and the REAL
#   scripts/provision-cross-process-recording.sh, copied byte-for-byte into a
#   throwaway workspace (both derive the workspace root from their own
#   location), against throwaway git repositories standing in for the two
#   siblings.  The justfile is read as text: this suite runs on a stock runner
#   (`ci-contract-suites`) that has no `just`.
#
# MOCKS, AND WHY THEY ARE JUSTIFIED
#   `repro`, `cargo`, `npm`, `just`, `nim`, `nimble` and `pkg-config` are stubs
#   on PATH.
#     * `repro exec <dir> -- <cmd…>` is a pass-through, so build-siblings' own
#       `bash -c 'cd … && eval …'` wrapper, its stamps and its summary run for
#       real.  The real one provisions a Nix dev shell per sibling: network and
#       minutes, and not what is under test.
#     * `cargo` stands in for both builds.  For `-p ct-instrument-cli` it
#       writes an executable `target/release/ct-instrument` that answers
#       `--help` (build-siblings' smoke check runs it in an empty environment),
#       and records the CARGO_TARGET_DIR it was given.  For
#       `--bin session-manager` it prints the JSON artifact record cargo
#       prints, naming an executable it creates.  STUB_CARGO_FAIL=<name> makes
#       that build exit 101.  A real Rust build is minutes and cannot fail on
#       demand.
#     * `npm` and `just` stand in for the JS recorder's
#       `npm install && just build && npm install`; `just build` writes
#       packages/cli/dist/index.js.
#     * `nim`/`nimble`/`pkg-config` only need to resolve during build-siblings'
#       up-front toolchain lookup.
#   `jq` is real: the provisioning script parses cargo's JSON with it.
#
# THE MUTATION THIS PINS
#   Against codetracer d6cbfb21a (before the fix): (A) finds no
#   codetracer-wasm-instrumenter row at all, (B) finds no provisioning script,
#   (C) finds no provisioning step in the recipe, and (D) finds the rr/MCR
#   wording.  Dropping the not-checked-out check from the provisioning script
#   (build-siblings reports such a sibling MISSING and exits 0) fails (B2).
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SIBLINGS_SRC="$ROOT_DIR/scripts/build-siblings.sh"
PROVISION_SRC="$ROOT_DIR/scripts/provision-cross-process-recording.sh"
JUSTFILE="$ROOT_DIR/justfile"

PASSED=0
FAILED=0
FAILURES=""
t_pass() {
	PASSED=$((PASSED + 1))
	echo "  ok   $1"
}
t_fail() {
	FAILED=$((FAILED + 1))
	FAILURES="$FAILURES"$'\n'"  - $1"
	echo "  FAIL $1"
}
has() { grep -qF -- "$1" "$2"; }

command -v jq >/dev/null 2>&1 || {
	echo "FAIL: jq is required (the provisioning script parses cargo's JSON with it)" >&2
	exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"
BIN="$TMP/bin"
mkdir -p "$WS/codetracer/scripts" "$WS/codetracer/src/backend-manager" "$BIN"
[[ -f $BUILD_SIBLINGS_SRC ]] && cp "$BUILD_SIBLINGS_SRC" "$WS/codetracer/scripts/"
[[ -f $PROVISION_SRC ]] && cp "$PROVISION_SRC" "$WS/codetracer/scripts/"

# make_sibling <name>: a committed throwaway git repository.
make_sibling() {
	local dir="$WS/$1"
	rm -rf "$dir"
	mkdir -p "$dir"
	git -C "$dir" init -q
	printf 'target/\npackages/*/dist/\nnode_modules/\n' >"$dir/.gitignore"
	echo "$1" >"$dir/README"
	git -C "$dir" add -A
	git -C "$dir" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -qm init
}

cat >"$BIN/repro" <<'EOF'
#!/usr/bin/env bash
# pass-through stub: repro exec <dir> -- <cmd...>
[[ $1 == exec && $3 == -- ]] || { echo "repro stub: unexpected args: $*" >&2; exit 2; }
shift 3
exec "$@"
EOF
cat >"$BIN/cargo" <<'EOF'
#!/usr/bin/env bash
case " $* " in
*" -p ct-instrument-cli "*)
	[[ ${STUB_CARGO_FAIL:-} == ct-instrument ]] && { echo "error: STUB ct-instrument build failed" >&2; exit 101; }
	echo "${CARGO_TARGET_DIR:-<unset>}" >"$STUB_LOG_DIR/ct-instrument-target-dir"
	out="${CARGO_TARGET_DIR:-target}/release"
	mkdir -p "$out"
	printf '#!/bin/sh\n[ "$1" = --help ] && echo "Usage: ct-instrument" && exit 0\nexit 2\n' >"$out/ct-instrument"
	chmod +x "$out/ct-instrument"
	;;
*" --bin session-manager "*)
	[[ ${STUB_CARGO_FAIL:-} == session-manager ]] && { echo "error: STUB session-manager build failed" >&2; exit 101; }
	exe="$STUB_LOG_DIR/cargo-target/release/session-manager"
	mkdir -p "$(dirname "$exe")"
	printf '#!/bin/sh\nexit 0\n' >"$exe"
	chmod +x "$exe"
	echo '{"reason":"compiler-artifact","executable":null}'
	printf '{"reason":"compiler-artifact","executable":"%s"}\n' "$exe"
	echo '{"reason":"build-finished","success":true}'
	;;
*)
	echo "cargo stub: unexpected args: $*" >&2
	exit 2
	;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/npm"
cat >"$BIN/just" <<'EOF'
#!/usr/bin/env bash
[[ $1 == build ]] || { echo "just stub: unexpected args: $*" >&2; exit 2; }
mkdir -p packages/cli/dist && echo '// stub' >packages/cli/dist/index.js
EOF
for t in nim nimble; do printf '#!/usr/bin/env bash\nexit 0\n' >"$BIN/$t"; done
printf '#!/usr/bin/env bash\necho -I/stub\n' >"$BIN/pkg-config"
chmod +x "$BIN/"*
mkdir -p "$TMP/logs"

# Every run starts from no stamps and no logs, and without the ambient
# overrides the provisioning script honours.
run_in_ws() {
	rm -rf "$WS/codetracer/.tools"
	env -u CARGO_TARGET_DIR -u CT_INSTRUMENT_BIN -u CODETRACER_WASM_INSTRUMENTER_PATH \
		-u CODETRACER_JS_RECORDER_PATH -u CODETRACER_RECORD_WEB_BIN \
		PATH="$BIN:$PATH" STUB_LOG_DIR="$TMP/logs" "$@"
}

echo "(A) build-siblings.sh has a codetracer-wasm-instrumenter entry"
make_sibling codetracer-wasm-instrumenter
run_in_ws bash "$WS/codetracer/scripts/build-siblings.sh" --check \
	--only codetracer-wasm-instrumenter >/dev/null 2>"$TMP/a-check.err"
if grep -qE '^  MISSING +codetracer-wasm-instrumenter +would build → target/release/ct-instrument' "$TMP/a-check.err"; then
	t_pass "--check names the entry and its artifact target/release/ct-instrument"
else
	t_fail "--check has no codetracer-wasm-instrumenter row for target/release/ct-instrument"
fi
run_in_ws env CARGO_TARGET_DIR="$TMP/shared-target" \
	bash "$WS/codetracer/scripts/build-siblings.sh" --only codetracer-wasm-instrumenter \
	>/dev/null 2>"$TMP/a-build.err"
rc=$?
if [[ $rc -eq 0 ]] && grep -qE '^  PASS +codetracer-wasm-instrumenter +built target/release/ct-instrument' "$TMP/a-build.err" &&
	[[ -x $WS/codetracer-wasm-instrumenter/target/release/ct-instrument ]]; then
	t_pass "a build produces target/release/ct-instrument in the sibling and reports PASS"
else
	t_fail "the build did not produce the sibling's target/release/ct-instrument (rc=$rc)"
fi
# A runner-wide CARGO_TARGET_DIR must not move the binary off the artifact path.
if [[ "$(cat "$TMP/logs/ct-instrument-target-dir" 2>/dev/null)" == "$WS/codetracer-wasm-instrumenter/target" ]]; then
	t_pass "the build pins CARGO_TARGET_DIR to the sibling's own target/"
else
	t_fail "the build used CARGO_TARGET_DIR=$(cat "$TMP/logs/ct-instrument-target-dir" 2>/dev/null || echo '<none>'), not the sibling's target/"
fi

echo "(B) provision-cross-process-recording.sh builds all three, or fails naming what it could not"
PROVISION="$WS/codetracer/scripts/provision-cross-process-recording.sh"
if [[ ! -f $PROVISION ]]; then
	t_fail "scripts/provision-cross-process-recording.sh does not exist"
else
	make_sibling codetracer-wasm-instrumenter
	make_sibling codetracer-js-recorder
	run_in_ws bash "$PROVISION" >"$TMP/b1.out" 2>"$TMP/b1.err"
	rc=$?
	if [[ $rc -eq 0 ]] && [[ "$(cat "$TMP/b1.out")" == "$TMP/logs/cargo-target/release/session-manager" ]]; then
		t_pass "(B1) success prints exactly the session-manager path cargo reported"
	else
		t_fail "(B1) rc=$rc, stdout='$(cat "$TMP/b1.out")'"
	fi
	if [[ -x $WS/codetracer-wasm-instrumenter/target/release/ct-instrument ]] &&
		[[ -f $WS/codetracer-js-recorder/packages/cli/dist/index.js ]]; then
		t_pass "(B1) ct-instrument and the JS recorder's dist/index.js were built"
	else
		t_fail "(B1) a sibling artifact is missing after a successful provisioning run"
	fi

	for absent in codetracer-wasm-instrumenter codetracer-js-recorder; do
		make_sibling codetracer-wasm-instrumenter
		make_sibling codetracer-js-recorder
		rm -rf "${WS:?}/$absent"
		run_in_ws bash "$PROVISION" >"$TMP/b2.out" 2>"$TMP/b2.err"
		rc=$?
		if [[ $rc -ne 0 ]] && [[ ! -s $TMP/b2.out ]] &&
			grep -qF -- "- $absent (not checked out" "$TMP/b2.err"; then
			t_pass "(B2) $absent not checked out: exit $rc, named, nothing on stdout"
		else
			t_fail "(B2) $absent not checked out: rc=$rc, or it is not named in the failure list"
		fi
	done

	make_sibling codetracer-wasm-instrumenter
	make_sibling codetracer-js-recorder
	run_in_ws env STUB_CARGO_FAIL=ct-instrument bash "$PROVISION" >"$TMP/b3.out" 2>"$TMP/b3.err"
	rc=$?
	if [[ $rc -ne 0 ]] && has "- codetracer-wasm-instrumenter (build failed" "$TMP/b3.err" &&
		has "STUB ct-instrument build failed" "$TMP/b3.err"; then
		t_pass "(B3) a failed instrumenter build fails provisioning and shows its cause"
	else
		t_fail "(B3) a failed instrumenter build: rc=$rc, or not named, or its cause is not shown"
	fi

	run_in_ws env STUB_CARGO_FAIL=session-manager bash "$PROVISION" >"$TMP/b4.out" 2>"$TMP/b4.err"
	rc=$?
	if [[ $rc -ne 0 ]] && [[ ! -s $TMP/b4.out ]] && has "- session-manager (cargo build" "$TMP/b4.err"; then
		t_pass "(B4) a failed session-manager build fails provisioning, naming it"
	else
		t_fail "(B4) a failed session-manager build: rc=$rc, or it is not named"
	fi
fi

echo "(C) the test-frontend-units recipe provisions before the lane runs"
# The recipe body: from its header line to the next unindented line.
recipe="$(awk '/^test-frontend-units:/ {on = 1; next} on && /^[^[:space:]]/ {exit} on' "$JUSTFILE")"
# A literal $( to match, not an expansion.
# shellcheck disable=SC2016
prov_line="$(grep -nF 'CODETRACER_RECORD_WEB_BIN="$(bash scripts/provision-cross-process-recording.sh)"' <<<"$recipe" | head -1 | cut -d: -f1)"
export_line="$(grep -n '^[[:space:]]*export CODETRACER_RECORD_WEB_BIN[[:space:]]*$' <<<"$recipe" | head -1 | cut -d: -f1)"
lane_line="$(grep -n 'bash ci/lib/run-nim-test-lane.sh frontend-native-units' <<<"$recipe" | head -1 | cut -d: -f1)"
if [[ -n $prov_line && -n $export_line && -n $lane_line ]] &&
	((prov_line < export_line && export_line < lane_line)); then
	t_pass "the recipe captures and exports CODETRACER_RECORD_WEB_BIN before run-nim-test-lane.sh"
else
	t_fail "the recipe does not provision and export CODETRACER_RECORD_WEB_BIN before the lane (provision=${prov_line:-none} export=${export_line:-none} lane=${lane_line:-none})"
fi
if grep -qE '^[[:space:]]*set -euo pipefail' <<<"$recipe"; then
	t_pass "the recipe runs under set -e, so a provisioning failure stops it"
else
	t_fail "the recipe lost set -euo pipefail; a provisioning failure would not stop it"
fi

echo "(D) the lane-deferral note names the real prerequisites"
note="$(awk '/^#   test-frontend-units / {on = 1} on && /^#   [(a-z]/ && !/test-frontend-units/ {exit} on' "$JUSTFILE")"
if [[ -n $note ]] && ! grep -q 'uncommitted rr/MCR' <<<"$note" &&
	grep -q 'ct-instrument' <<<"$note" && grep -q 'session-manager' <<<"$note" &&
	grep -q 'codetracer-js-recorder' <<<"$note"; then
	t_pass "the note names ct-instrument, session-manager and codetracer-js-recorder, not rr/MCR"
else
	t_fail "the note still blames an uncommitted rr/MCR recording, or omits a prerequisite"
fi

echo ""
echo "frontend-units-cross-process-provisioning: $PASSED passed, $FAILED failed"
if [[ $FAILED -gt 0 ]]; then
	echo "failures:$FAILURES"
	exit 1
fi
