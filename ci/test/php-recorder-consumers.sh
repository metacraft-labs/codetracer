#!/usr/bin/env bash
#
# php-recorder-consumers.sh -- run CodeTracer's PHP consumers against
# recordings made with the codetracer-php-recorder checkout beside this one.
#
# WHAT THIS IS
#   The body of the PHP recorder's downstream lane. A change to the recorder
#   (its C extension, its span records, its step model) is consumed directly
#   by this repository: the db-backend replays what the extension writes, and
#   the Request Panel ViewModel reads the span stream out of the same
#   container. Those consumers run in this repository's CI against whatever
#   recorder revision codetracer pins, so without this lane a recorder change
#   is first checked against them when codetracer next picks it up.
#
#   The recorder calls this through the reusable workflow
#   .github/workflows/php-recorder-downstream.yml, with the recorder checked
#   out at the commit under test and this repository at the revision the
#   recorder's committed lock pins. It runs the same way locally:
#
#     just test-php-recorder-consumers
#
#   from a codetracer checkout inside its dev shell, with
#   ../codetracer-php-recorder, ../codetracer-trace-format-nim (and the
#   db-backend siblings ../codetracer-trace-format, ../codetracer-native-recorder)
#   beside it.
#
# WHAT IT RUNS
#   1. Builds the recorder's C extension in the RECORDER'S OWN dev shell,
#      through ci/test/build-recorder-siblings.sh (which also builds the
#      trace writer's shared library from ../codetracer-trace-format-nim, as
#      the extension links it). This script never says how the recorder is
#      built.
#   2. Records ONE fresh `php -S` request session with that extension, through
#      the recorder's own `just record-request-panel-fixture <dir>` -- the
#      recipe that produced the checked-in fixture -- into a temporary
#      directory. The checked-in fixture is never touched.
#   3. `cargo test --test php_flow_dap_test` in src/db-backend: records its own
#      PHP program with the freshly built extension
#      (CODETRACER_PHP_RECORDER_EXTENSION) and the recorder shell's `php` (the
#      only PHP the extension loads into), then drives a DAP stepping session
#      over the recording. Graceful skipping is OFF.
#   4. The Request Panel ViewModel suite
#      src/tests/gui/tests/request-panel/php_request_panel_vm_test.nim, through
#      ci/lib/run-nim-test-lane.sh --file in its own lane (vm-native), so its
#      flags, paths and scoring are the lane's, with
#      CODETRACER_PHP_REQUEST_PANEL_FIXTURE naming the fresh container -- and
#      once more with it naming a missing file, which must fail, so the green
#      run is known to have read the fresh container and not the checked-in
#      fixture.
#
# HOW IT FAILS
#   It prints one final line,
#
#     TEST-COUNTS: executed=N passed=N failed=N skipped=N
#
#   (the format of codetracer-specs Testing/Cross-Repo-Test-Catalog.md), and
#   exits non-zero when a test failed, a test was skipped (the db-backend
#   harness's CODETRACER_TEST_SKIP_REPORT, a cargo `ignored` test or a Nim
#   [SKIPPED] case), no test ran, a part could not be run at all, or a count
#   could not be read. A required downstream gate may never degrade into a
#   zero-test or skipped run (Cross-Repo-CI-Integration.md, "Downstream
#   Breakage Responsibility").
#
# Environment:
#   PHP_RECORDER_CONSUMERS_KEEP=1  keep the temporary recording directory.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
PHP_DIR="$WORKSPACE_ROOT/codetracer-php-recorder"
NIM_DIR="$WORKSPACE_ROOT/codetracer-trace-format-nim"
VM_SUITE="src/tests/gui/tests/request-panel/php_request_panel_vm_test.nim"
VM_LANE="vm-native"

die() {
	echo "php-recorder-consumers: $*" >&2
	echo "TEST-COUNTS: executed=0 passed=0 failed=0 skipped=0"
	exit 1
}

cd "$REPO_ROOT" || die "cannot enter $REPO_ROOT"
for d in "$PHP_DIR" "$NIM_DIR" "$WORKSPACE_ROOT/codetracer-trace-format" "$WORKSPACE_ROOT/codetracer-native-recorder"; do
	[ -d "$d" ] || die "required sibling checkout $d is missing (every repository this lane spans sits beside $REPO_ROOT)"
done
for tool in direnv just cargo nim; do
	command -v "$tool" >/dev/null 2>&1 || die "'$tool' is not on PATH; run inside codetracer's dev shell"
done
echo "php-recorder-consumers: codetracer $(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || echo '?')"
for d in "$PHP_DIR" "$NIM_DIR" "$WORKSPACE_ROOT/codetracer-trace-format" "$WORKSPACE_ROOT/codetracer-native-recorder"; do
	echo "php-recorder-consumers: $(basename "$d") $(git -C "$d" rev-parse HEAD 2>/dev/null || echo '?')$(git -C "$d" diff --quiet HEAD 2>/dev/null || echo ' (+ uncommitted changes)')"
done

work="$(mktemp -d "${TMPDIR:-/tmp}/php-recorder-consumers.XXXXXX")" || die "mktemp failed"
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
	if [ "${PHP_RECORDER_CONSUMERS_KEEP:-}" = 1 ]; then
		echo "php-recorder-consumers: kept $work" >&2
	else
		rm -rf "$work"
	fi
}
trap cleanup EXIT

# --- 1. the recorder under test ----------------------------------------------
echo "=== php-recorder-consumers: build the recorder (its own dev shell)"
bash "$REPO_ROOT/ci/test/build-recorder-siblings.sh" codetracer-php-recorder ||
	die "building codetracer-php-recorder failed (output above)"
EXT="$PHP_DIR/ext/modules/codetracer.so"
[ -f "$EXT" ] || die "the recorder build left no $EXT"

# The PHP the extension was built against, which is the only one it loads into.
php_bin="$(direnv exec "$PHP_DIR" bash -c 'command -v php')" ||
	die "the recorder's dev shell provides no php"
[ -x "$php_bin" ] || die "the recorder's dev shell names '$php_bin' as php, which is not executable"
echo "php-recorder-consumers: php $php_bin, extension $EXT"

# --- 2. one fresh php -S request session --------------------------------------
echo "=== php-recorder-consumers: record a php -S request session with this extension"
fixture_dir="$work/php_builtin"
direnv exec "$PHP_DIR" just --justfile "$PHP_DIR/Justfile" --working-directory "$PHP_DIR" \
	record-request-panel-fixture "$fixture_dir" ||
	die "the recorder's record-request-panel-fixture failed (output above)"
FRESH="$fixture_dir/app.ct"
[ -s "$FRESH" ] || die "record-request-panel-fixture wrote no $FRESH"
echo "php-recorder-consumers: fresh container $FRESH ($(wc -c <"$FRESH") bytes)"

executed=0 passed=0 failed=0 skipped=0
broken=()

# --- 3. the db-backend's PHP flow test ----------------------------------------
echo "=== php-recorder-consumers: cargo test --test php_flow_dap_test"
skip_report="$work/skips.txt"
: >"$skip_report"
cargo_log="$work/cargo.log"
(
	# A scratch CODETRACER_HOME under the temporary directory, for the test
	# and everything it spawns (the db-backend harness also isolates itself).
	export CODETRACER_HOME="$work/codetracer-home"
	mkdir -p "$CODETRACER_HOME"
	export CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false
	export CODETRACER_TEST_SKIP_REPORT="$skip_report"
	export CODETRACER_PHP_RECORDER_EXTENSION="$EXT"
	php_path="$(dirname "$php_bin")"
	export PATH="$php_path:$PATH"
	# ct_emulator's syscall_replay.nim imports stew/endians2, which
	# ct_emulator.nimble does not declare; codetracer's pinned libs supply it,
	# as for every other db-backend build (scripts/build-once.sh, the
	# recorder-tests job of cross-repo-tests.yml). The standalone `results`
	# must come LAST (see build-once.sh).
	if [ -z "${CT_EMULATOR_EXTRA_NIM_PATHS:-}" ]; then
		export CT_EMULATOR_EXTRA_NIM_PATHS="$REPO_ROOT/libs/nim-stew/stew:$REPO_ROOT/libs/nim-stew:$REPO_ROOT/libs/nim-result"
	fi
	cd src/db-backend && cargo test --no-fail-fast --test php_flow_dap_test -- --nocapture
) 2>&1 | tee "$cargo_log"
cargo_rc="${PIPESTATUS[0]}"

# `test result: ok. 1 passed; 0 failed; 0 ignored; ...` once per test binary.
c_pass=0 c_fail=0 c_ign=0 c_results=0
while IFS= read -r line; do
	if [[ "$line" =~ ([0-9]+)\ passed\;\ ([0-9]+)\ failed\;\ ([0-9]+)\ ignored ]]; then
		c_pass=$((c_pass + BASH_REMATCH[1]))
		c_fail=$((c_fail + BASH_REMATCH[2]))
		c_ign=$((c_ign + BASH_REMATCH[3]))
		c_results=$((c_results + 1))
	fi
done < <(grep -E '^test result: ' "$cargo_log")
c_skip_reported="$(sort -u "$skip_report" | grep -c . || true)"
if [ "$c_results" -eq 0 ]; then
	broken+=("cargo printed no 'test result:' line (exit $cargo_rc): php_flow_dap_test did not build or did not run")
	[ "$cargo_rc" -ne 0 ] && c_fail=$((c_fail + 1))
fi
if [ "$cargo_rc" -ne 0 ] && [ "$c_fail" -eq 0 ]; then
	broken+=("cargo exited $cargo_rc with no failed test counted")
	c_fail=1
fi
# A test that reported a skip returned early and was tallied as passed: it is
# a skip, not a pass.
c_skip=$((c_ign + c_skip_reported))
c_pass=$((c_pass - c_skip_reported))
[ "$c_pass" -ge 0 ] || c_pass=0
if [ -s "$skip_report" ]; then
	echo "SKIPPED (NOT VERIFIED):"
	sort -u "$skip_report" | sed 's/^/  /'
fi
# Each consumer must run at least one test of its own: the lane-wide
# `executed` alone would let one part pass vacuously beside the other.
if [ $((c_pass + c_fail + c_skip)) -eq 0 ]; then
	broken+=("php_flow_dap_test ran no test")
fi
echo "php-recorder-consumers: db-backend php_flow_dap_test: passed=$c_pass failed=$c_fail skipped=$c_skip (cargo exit $cargo_rc)"
executed=$((executed + c_pass + c_fail))
passed=$((passed + c_pass))
failed=$((failed + c_fail))
skipped=$((skipped + c_skip))

# --- 4. the Request Panel ViewModel on the fresh container ---------------------
echo "=== php-recorder-consumers: $VM_SUITE on the fresh container"
just vm-test-prereqs || broken+=("just vm-test-prereqs failed")
vm_log="$work/vm.log"
CODETRACER_PHP_REQUEST_PANEL_FIXTURE="$FRESH" \
	bash "$REPO_ROOT/ci/lib/run-nim-test-lane.sh" "$VM_LANE" --file "$VM_SUITE" 2>&1 | tee "$vm_log"
vm_rc="${PIPESTATUS[0]}"
counts="$(grep -E '^NIM-LANE-COUNTS: ' "$vm_log" | tail -1)"
field() { sed -nE "s/.* $1=([0-9]+).*/\\1/p" <<<"$counts"; }
if [ -z "$counts" ]; then
	broken+=("run-nim-test-lane.sh printed no NIM-LANE-COUNTS line (exit $vm_rc)")
	n_ok=0 n_fail=1 n_skip=0
else
	n_ok="$(field case-ok)" n_fail="$(field case-failed)" n_skip="$(field case-skipped)"
	n_files_failed="$(field files-failed)"
	# A file that crashed or failed to compile may print no [FAILED] marker.
	if [ "${n_files_failed:-0}" -gt 0 ] && [ "$n_fail" -eq 0 ]; then n_fail="$n_files_failed"; fi
	n_plat="$(field files-platform-skipped)"
	[ "${n_plat:-0}" -eq 0 ] || n_skip=$((n_skip + n_plat))
fi
if [ "$vm_rc" -ne 0 ] && [ "$n_fail" -eq 0 ]; then
	broken+=("run-nim-test-lane.sh exited $vm_rc with no failure counted")
	n_fail=1
fi
# THE OVERRIDE IS HONOURED, NOT ASSUMED. The lane prints a passing file's
# output only when it fails, so the suite's own "reading <path>" line is not
# visible here. Instead the same suite is run once more with the override
# naming a file that does not exist, and that run must FAIL: a binary that
# ignored CODETRACER_PHP_REQUEST_PANEL_FIXTURE would read the checked-in
# fixture, pass, and make the green above a statement about the wrong
# recording. (The second compile is a nimcache hit.)
echo "=== php-recorder-consumers: control -- the suite must refuse an override naming no file"
if CODETRACER_PHP_REQUEST_PANEL_FIXTURE="$work/no-such-recording/app.ct" \
	bash "$REPO_ROOT/ci/lib/run-nim-test-lane.sh" "$VM_LANE" --file "$VM_SUITE" >"$work/vm-control.log" 2>&1; then
	broken+=("$VM_SUITE passed with CODETRACER_PHP_REQUEST_PANEL_FIXTURE naming a missing file, so it does not read the override and the run above did not test the fresh container")
elif ! grep -qF "CODETRACER_PHP_REQUEST_PANEL_FIXTURE is set to '$work/no-such-recording/app.ct'" "$work/vm-control.log"; then
	broken+=("the control run of $VM_SUITE failed, but not by refusing the missing override:")
	broken+=("$(tail -20 "$work/vm-control.log")")
else
	echo "php-recorder-consumers: control ok -- the suite refused a missing override, so the run above read $FRESH"
fi
if [ $((n_ok + n_fail + n_skip)) -eq 0 ]; then
	broken+=("$VM_SUITE ran no test case")
fi
echo "php-recorder-consumers: $VM_SUITE: passed=$n_ok failed=$n_fail skipped=$n_skip (lane exit $vm_rc)"
executed=$((executed + n_ok + n_fail))
passed=$((passed + n_ok))
failed=$((failed + n_fail))
skipped=$((skipped + n_skip))

# --- verdict ---------------------------------------------------------------------
rc=0
for b in ${broken[@]+"${broken[@]}"}; do
	echo "php-recorder-consumers: ERROR: $b" >&2
	rc=1
done
if [ "$failed" -gt 0 ]; then
	echo "php-recorder-consumers: ERROR: $failed test(s) failed" >&2
	rc=1
fi
if [ "$skipped" -gt 0 ]; then
	echo "php-recorder-consumers: ERROR: $skipped test(s) skipped; a required downstream gate may not skip" >&2
	rc=1
fi
if [ "$executed" -eq 0 ]; then
	echo "php-recorder-consumers: ERROR: no test ran" >&2
	rc=1
fi
echo "TEST-COUNTS: executed=$executed passed=$passed failed=$failed skipped=$skipped"
exit "$rc"
