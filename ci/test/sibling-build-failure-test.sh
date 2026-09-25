#!/usr/bin/env bash
# =============================================================================
# Contract: when a sibling build FAILS, the cause reaches the step output.
#
#   bash ci/test/sibling-build-failure-test.sh
#
# WHY THIS FILE EXISTS
#   scripts/build-siblings.sh captures each sibling's build into
#   .tools/build-siblings-logs/<key>.log and its summary only NAMED that file.
#   ci/test/launcher-recorder-e2e.sh then printed the first 80 lines of
#   build-siblings' own output.  On a CI runner the per-repo log is gone when
#   the job ends, so the ruby arm of codetracer run 36013311965 reported
#   "build exited 101 — see <path on the runner>" and nothing that said why.
#   Both halves now print the TAIL of the failed repo's log; this file pins
#   that, and pins that the failure is still a failure.
#
# WHAT IT RUNS
#   The REAL scripts/build-siblings.sh (copied byte-for-byte into a throwaway
#   workspace, because the script derives the workspace root from its own
#   location), the REAL ci/lib/sibling-build-failure.sh the driver sources, and
#   the driver's two REAL build-failure paths: `step_build_recorder` and
#   `step_build_extra_siblings` are cut out of ci/test/launcher-recorder-e2e.sh
#   verbatim and run.  The driver as a whole is not run: it needs a launcher,
#   a built desktop core and a recorder toolchain before it reaches its build
#   step.  Cutting the functions out is what pins that the driver both CALLS
#   the report and still DIES; without it, deleting either from the driver
#   passed every suite.
#
# MOCKS, AND WHY THEY ARE JUSTIFIED
#   `repro`, `just`, `nim`, `nimble` and `pkg-config` are stubs on PATH.
#     * `repro exec <dir> -- <cmd…>` is a pass-through that runs <cmd…>
#       unchanged, so build-siblings' own `bash -c 'cd … && eval …'` wrapper
#       and its log redirection are exercised for real.  The real `repro`
#       would provision a Nix/reprobuild dev shell, which needs the network
#       and minutes of work and is not what is under test.
#     * `just` stands in for the recorder's `just build-extension`: it prints a
#       numbered transcript ending in a cause line and exits 101 (cargo's exit
#       code), or builds the artifact when asked to succeed.  A real recorder
#       build cannot be made to fail on demand, deterministically, offline.
#     * `nim`/`nimble`/`pkg-config` only need to exist: build-siblings' up-front
#       toolchain lookup resolves their paths and flags before any build.
#   Nothing about the reporting code is stubbed.
# =============================================================================

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_SIBLINGS_SRC="$ROOT_DIR/scripts/build-siblings.sh"
LIB="$ROOT_DIR/ci/lib/sibling-build-failure.sh"

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
# expect_has <file> <needle> <pass-message> <fail-message>
expect_has() {
	if has "$2" "$1"; then t_pass "$3"; else t_fail "$4"; fi
}

for f in "$BUILD_SIBLINGS_SRC" "$LIB"; do
	[[ -f $f ]] || {
		echo "FAIL: $f is missing" >&2
		exit 1
	}
done
# shellcheck source=../lib/sibling-build-failure.sh
# shellcheck disable=SC1091  # resolved at run time from $ROOT_DIR
source "$LIB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WS="$TMP/ws"
mkdir -p "$WS/codetracer/scripts" "$WS/codetracer-ruby-recorder" "$TMP/bin"
cp "$BUILD_SIBLINGS_SRC" "$WS/codetracer/scripts/build-siblings.sh"

cat >"$TMP/bin/repro" <<'EOF'
#!/usr/bin/env bash
# pass-through stub: repro exec <dir> -- <cmd...>
[[ $1 == exec && $3 == -- ]] || { echo "repro stub: unexpected args: $*" >&2; exit 2; }
shift 3
exec "$@"
EOF
cat >"$TMP/bin/just" <<'EOF'
#!/usr/bin/env bash
# Stand-in for the recorder build.  STUB_BUILD=fail|pass, STUB_LINES=N.
if [[ ${STUB_BUILD:-fail} == pass ]]; then
	mkdir -p gems/codetracer-ruby-recorder/ext/native_tracer/target/release
	for f in gems/codetracer-ruby-recorder/ext/native_tracer/target/release/codetracer_ruby_recorder.{so,bundle,dll}; do : >"$f"; done
	echo "stub build ok"
	exit 0
fi
for ((i = 1; i <= ${STUB_LINES:-100}; i++)); do printf 'stub-build-line-%03d|\n' "$i"; done
echo "error: STUB-CAUSE the lock file needs to be updated but --locked was passed"
exit 101
EOF
for t in nim nimble; do printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/$t"; done
printf '#!/usr/bin/env bash\necho -I/stub\n' >"$TMP/bin/pkg-config"
chmod +x "$TMP/bin/"*

run_bs() {
	# run_bs <stderr-file> [ENV=VAL…] -- runs the copied build-siblings.sh
	local err="$1"
	shift
	rm -rf "$WS/codetracer/.tools" \
		"$WS/codetracer-ruby-recorder/gems"
	env PATH="$TMP/bin:$PATH" "$@" \
		bash "$WS/codetracer/scripts/build-siblings.sh" --only codetracer-ruby-recorder \
		>"$TMP/stdout" 2>"$err"
}

echo "build-siblings.sh: a failed build prints the tail of its log"
run_bs "$TMP/fail.err" STUB_BUILD=fail STUB_LINES=100
rc=$?
if [[ $rc -ne 0 ]]; then t_pass "a failed sibling build still exits non-zero ($rc)"; else t_fail "a failed sibling build exited 0"; fi
expect_has "$TMP/fail.err" "FAIL    codetracer-ruby-recorder" \
	"the summary still has the FAIL row" \
	"no FAIL row in the summary"
expect_has "$TMP/fail.err" "build exited 101" \
	"the FAIL row carries the child's exit code" \
	"the FAIL row lost the exit code"
expect_has "$TMP/fail.err" "  | error: STUB-CAUSE" \
	"the cause line at the END of the log is printed" \
	"the cause line is not in the output"
# 101 log lines (100 numbered + cause); the default tail of 60 starts at 042.
if has "stub-build-line-042|" "$TMP/fail.err" && ! has "stub-build-line-041|" "$TMP/fail.err"; then
	t_pass "exactly the last 60 lines are printed by default"
else
	t_fail "the default tail is not the last 60 lines"
fi

run_bs "$TMP/fail5.err" STUB_BUILD=fail STUB_LINES=100 BUILD_SIBLINGS_FAIL_TAIL_LINES=5
if has "stub-build-line-097|" "$TMP/fail5.err" && ! has "stub-build-line-096|" "$TMP/fail5.err"; then
	t_pass "BUILD_SIBLINGS_FAIL_TAIL_LINES bounds the tail"
else
	t_fail "BUILD_SIBLINGS_FAIL_TAIL_LINES=5 did not print exactly the last 5 lines"
fi

# Verbose mode streams the build and writes no log.  A leftover log from an
# earlier run must NOT be presented as this run's cause.
mkdir -p "$WS/codetracer/.tools/build-siblings-logs"
echo "STALE-LOG-FROM-AN-EARLIER-RUN" >"$WS/codetracer/.tools/build-siblings-logs/codetracer-ruby-recorder.log"
rm -rf "$WS/codetracer-ruby-recorder/gems"
env PATH="$TMP/bin:$PATH" STUB_BUILD=fail STUB_LINES=3 BUILD_SIBLINGS_VERBOSE=1 \
	bash "$WS/codetracer/scripts/build-siblings.sh" --only codetracer-ruby-recorder >/dev/null 2>"$TMP/verbose.err"
rc=$?
if [[ $rc -ne 0 ]] && ! has "STALE-LOG-FROM-AN-EARLIER-RUN" "$TMP/verbose.err" &&
	has "streamed above" "$TMP/verbose.err"; then
	t_pass "verbose mode fails hard and does not tail a stale log"
else
	t_fail "verbose mode: rc=$rc, or a stale log was tailed, or no 'streamed above' note"
fi

run_bs "$TMP/pass.err" STUB_BUILD=pass
rc=$?
if [[ $rc -eq 0 ]] && ! has "last 60 lines" "$TMP/pass.err"; then
	t_pass "a passing build exits 0 and prints no log tail"
else
	t_fail "a passing build: rc=$rc or a log tail was printed"
fi

echo "ci/lib/sibling-build-failure.sh: what the e2e driver prints"
run_bs "$TMP/bs-out.log" STUB_BUILD=fail STUB_LINES=100
report_sibling_build_failure "$TMP/bs-out.log" 2>"$TMP/report.err"
expect_has "$TMP/report.err" "FAIL    codetracer-ruby-recorder" \
	"the driver prints the summary row" \
	"the driver did not print the summary row"
expect_has "$TMP/report.err" "  | error: STUB-CAUSE" \
	"the driver prints the cause from the per-repo log" \
	"the cause did not reach the driver's output"
expect_has "$TMP/report.err" "  | [build-siblings] codetracer-ruby-recorder: building" \
	"the driver keeps what build-siblings said before its summary" \
	"the driver dropped build-siblings' own pre-summary output"
expect_has "$TMP/report.err" "last 60 lines of $WS/codetracer/.tools/build-siblings-logs/codetracer-ruby-recorder.log" \
	"the driver found the per-repo log from the real FAIL row" \
	"the driver did not resolve the per-repo log from build-siblings' FAIL row"
# The per-repo log's first line must not be there: the driver prints the log
# once (not build-siblings' copy of it plus the log again) and only its tail.
if [[ $(grep -c "STUB-CAUSE" "$TMP/report.err") -eq 1 ]] && ! has "stub-build-line-001|" "$TMP/report.err"; then
	t_pass "the driver prints the tail once, and only the tail"
else
	t_fail "the driver printed the cause more than once or printed the head of the log"
fi

# No per-repo log (e.g. the toolchain lookup failed before any build): fall
# back to the tail of build-siblings' own output.
printf 'build-siblings.sh: ERROR: required toolchain lookup failed; see /x\n' >"$TMP/early.log"
report_sibling_build_failure "$TMP/early.log" 2>"$TMP/early.err"
expect_has "$TMP/early.err" "required toolchain lookup failed" \
	"with no per-repo log the driver shows build-siblings' own output" \
	"the fallback did not show build-siblings' output"

# Verbose mode through the driver's path: build-siblings' output (including the
# streamed build) is captured into one file, as the driver does, and a stale
# per-repo log is lying around.  The FAIL row must not name that log, so the
# driver falls back to the captured output, which holds this run's cause.
mkdir -p "$WS/codetracer/.tools/build-siblings-logs"
echo "STALE-LOG-FROM-AN-EARLIER-RUN" >"$WS/codetracer/.tools/build-siblings-logs/codetracer-ruby-recorder.log"
rm -rf "$WS/codetracer-ruby-recorder/gems"
env PATH="$TMP/bin:$PATH" STUB_BUILD=fail STUB_LINES=3 BUILD_SIBLINGS_VERBOSE=1 \
	bash "$WS/codetracer/scripts/build-siblings.sh" --only codetracer-ruby-recorder >"$TMP/verbose-out.log" 2>&1
report_sibling_build_failure "$TMP/verbose-out.log" 2>"$TMP/verbose-report.err"
if ! has "STALE-LOG-FROM-AN-EARLIER-RUN" "$TMP/verbose-report.err" && has "  | error: STUB-CAUSE" "$TMP/verbose-report.err"; then
	t_pass "verbose mode: the driver shows this run's streamed cause, not a stale log"
else
	t_fail "verbose mode: the driver tailed a stale per-repo log or lost the streamed cause"
fi

echo "ci/test/launcher-recorder-e2e.sh: the driver's build-failure paths"
DRIVER="$ROOT_DIR/ci/test/launcher-recorder-e2e.sh"
# cut_fn <name>: the definition of <name> exactly as the driver spells it.
cut_fn() {
	awk -v n="$1" 'index($0, n "() {") == 1 { p = 1 } p { print } p && /^}/ { exit }' "$DRIVER"
}
RUBY_ART="gems/codetracer-ruby-recorder/ext/native_tracer/target/release/codetracer_ruby_recorder.so"
mkdir -p "$TMP/drv"
printf 'build.also.0.repo=codetracer-ruby-recorder\nbuild.also.0.sibling-key=codetracer-ruby-recorder\nbuild.also.0.artifact=%s\n' \
	"$RUBY_ART" >"$TMP/drv/fixture.flat"
# run_driver_step <step-function> <stderr-file>: the step, with the driver's
# own die/note/fixture reader and the globals it reads.  A `die` exits the
# subshell, so reaching the marker means the failure was swallowed.
run_driver_step() {
	rm -rf "$WS/codetracer/.tools" "$WS/codetracer-ruby-recorder/gems"
	(
		for f in die note fx_key_re fx_get "$1"; do
			def="$(cut_fn "$f")"
			[[ -n $def ]] || {
				echo "the driver has no function '$f'" >&2
				exit 3
			}
			eval "$def"
		done
		# shellcheck disable=SC2034  # read by the eval'd driver functions
		{
			SKIP_BUILDS=0 ALLOW_MISSING=0 WS_ROOT="$WS" WORK_DIR="$TMP/drv"
			FLAT="$TMP/drv/fixture.flat" RECORDER_DIR="$WS/codetracer-ruby-recorder"
			FX_SIBLING_KEY=codetracer-ruby-recorder FX_ARTIFACT="$RUBY_ART"
			BUILD_SIBLINGS="$WS/codetracer/scripts/build-siblings.sh"
		}
		export PATH="$TMP/bin:$PATH" STUB_BUILD=fail STUB_LINES=100
		"$1"
		echo "DRIVER-STEP-RETURNED"
	) >"$TMP/drv/$1.out" 2>"$2"
}
for step in "step_build_recorder:A recorder that does not build cannot be tested" \
	"step_build_extra_siblings:It is part of this edge's recording toolchain"; do
	fn="${step%%:*}" why="${step#*:}"
	run_driver_step "$fn" "$TMP/drv/$fn.err"
	rc=$?
	if [[ $rc -ne 0 ]] && ! has "DRIVER-STEP-RETURNED" "$TMP/drv/$fn.out" &&
		has "$why" "$TMP/drv/$fn.err" && has "  | error: STUB-CAUSE" "$TMP/drv/$fn.err"; then
		t_pass "$fn: a failed build prints its cause and dies on the build failure"
	else
		t_fail "$fn: rc=$rc; the cause was not printed, or the step did not die on the build failure"
	fi
done

echo
echo "assertions: $((PASSED + FAILED))   passed: $PASSED   failed: $FAILED"
if [[ $FAILED -ne 0 ]]; then
	echo "FAILURES:$FAILURES" >&2
	exit 1
fi
echo "PASS"
