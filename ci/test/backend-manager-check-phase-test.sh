#!/usr/bin/env bash
# =============================================================================
# backend-manager-check-phase-test.sh — contract suite for the ``checkPhase``
# of the ``backend-manager`` derivation in nix/packages/default.nix.
#
# WHY THIS EXISTS
# ---------------
# That checkPhase excludes two things from the nix build sandbox:
#
#   1. one unit test  — browser_stream_host::tests::verify_reframing_...
#   2. one whole test TARGET — tests/real_recording_integration.rs
#
# Both are excluded because the sandbox cannot supply what they need, not
# because they are unimportant. An exclusion like that has one characteristic
# failure mode: it quietly grows, until "the build is green" means "the tests
# stopped running". The checkPhase carries guards against exactly that. Guards
# that are never exercised are decoration, so this suite exercises them.
#
# WHAT IT TESTS AGAINST
# ---------------------
# Not a copy of the checkPhase — the REAL one, read out of the flake with
#
#   nix eval --raw .#packages.<system>.backend-manager.checkPhase
#
# so this suite cannot drift from the string nix actually runs. It is then
# executed against a stub ``cargo`` on PATH which models the real crate's
# targets and test counts (measured from CI run 32995542998, job nix-build).
# No rustc, no 86-crate compile, no network: the whole suite is seconds.
#
# HOW IT TESTS THEM
# -----------------
# Each guard gets a MUTATION: the extracted checkPhase is edited to reintroduce
# the specific defect the guard exists to catch, and the suite asserts the guard
# fails the phase and says why. A guard that survives its mutation is reported
# as a failure here, because it would not have caught the real thing either.
#
# Run: bash ci/test/backend-manager-check-phase-test.sh
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT" || exit 1

PASS=0
FAIL=0

pass() {
	PASS=$((PASS + 1))
	printf '  ok    %s\n' "$1"
}

fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL  %s\n' "$1" >&2
	if [ -n "${2:-}" ]; then
		printf '        %s\n' "$2" >&2
	fi
}

# -----------------------------------------------------------------------------
# Skip loudly, never silently -- and never at all in CI.
#
# This suite's one external dependency is `nix`. On a developer machine without
# it, skipping is right: the alternative is a failure that says nothing about
# the change being made. In CI it is the opposite. `lint-bash` runs this file
# through `nix develop .#devShells.x86_64-linux.default`, so nix is present by
# construction; if it is missing or the flake will not evaluate, the lane is
# broken and "skip" would turn that into a green tick on a check that verified
# nothing. That is the same failure mode -- a pass that means the tests stopped
# running -- that the guards below exist to catch, so it is not tolerated here
# either.
# -----------------------------------------------------------------------------
in_ci() { [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }

bail_or_skip() { # reason
	if in_ci; then
		cat >&2 <<-EOF
			ERROR: ci/test/backend-manager-check-phase-test.sh cannot run.
			Reason: $1
			This is a hard failure in CI: lint-bash runs this suite inside
			'nix develop', so nix is present by construction. Skipping here
			would report a green tick for a check that verified nothing.
		EOF
		exit 1
	fi
	cat >&2 <<-EOF
		=============================================================
		SKIPPED: ci/test/backend-manager-check-phase-test.sh
		Reason:  $1
		Effect:  The backend-manager checkPhase exclusion guards are
		         NOT verified in this run.
		=============================================================
	EOF
	exit 0
}

if ! command -v nix >/dev/null 2>&1; then
	# Reading nix/packages/default.nix as text instead would assert against a
	# different string than the one nix runs, which is the drift this suite
	# exists to rule out. Better to decline than to test a lookalike.
	bail_or_skip "'nix' is not on PATH, and this suite asserts against the checkPhase as nix evaluates it."
fi

NIX_SYSTEM="$(nix eval --raw --impure --expr 'builtins.currentSystem' 2>/dev/null)"
if [ -z "$NIX_SYSTEM" ]; then
	bail_or_skip "could not determine the nix current system."
fi

echo "backend-manager checkPhase contract suite (system: $NIX_SYSTEM)"

CHECK_PHASE_FILE="$(mktemp)"
if ! nix eval --raw ".#packages.$NIX_SYSTEM.backend-manager.checkPhase" \
	>"$CHECK_PHASE_FILE" 2>"$CHECK_PHASE_FILE.err"; then
	sed 's/^/         /' "$CHECK_PHASE_FILE.err" >&2
	rm -f "$CHECK_PHASE_FILE" "$CHECK_PHASE_FILE.err"
	bail_or_skip "could not evaluate the backend-manager checkPhase (see above)."
fi
rm -f "$CHECK_PHASE_FILE.err"

BROWSER_TEST=browser_stream_host::tests::verify_reframing_a_real_browser_recording_reproduces_it_byte_for_byte
EXCLUDED_TARGET=real_recording_integration

# -----------------------------------------------------------------------------
# The stub crate.  Target names and test counts mirror the real crate as
# observed in CI run 32995542998 (job nix-build):
#
#   unittests src/main.rs            204 passed, 1 filtered out  (= 205 listed)
#   tests/dive_in_url_fetch_test.rs    1 passed
#   tests/mcp_origin_test.rs          12 passed
#   tests/meta_dat_metadata_loading   21 passed
#   tests/real_recording_integration   4 passed; 75 failed; 7 ignored  -> exit 101
#
# The crate is binary-only (no [lib], no src/lib.rs), which is why the phase
# selects --bins and not --lib.
# -----------------------------------------------------------------------------
make_stub_crate() {
	local dir="$1"
	mkdir -p "$dir/tests" "$dir/src" "$dir/bin"
	: >"$dir/src/main.rs"
	for t in dive_in_url_fetch_test mcp_origin_test meta_dat_metadata_loading "$EXCLUDED_TARGET"; do
		: >"$dir/tests/$t.rs"
	done

	cat >"$dir/bin/cargo" <<STUB
#!/usr/bin/env bash
# Stub cargo. Models target selection and per-target test counts.
set -u

declare -a SELECTED=()
want_bins=0
listing=0
skip_name=""
saw_ddash=0
explicit_target_selection=0

while [ \$# -gt 0 ]; do
	case "\$1" in
	--) saw_ddash=1 ;;
	--bins) want_bins=1; explicit_target_selection=1 ;;
	--lib)
		# The real crate has no library target; asserting it here keeps the
		# phase honest about the crate shape it is written against.
		echo "error: no library targets found in package \\\`session-manager\\\`" >&2
		exit 101
		;;
	--test) shift; SELECTED+=("\$1"); explicit_target_selection=1 ;;
	--list) [ "\$saw_ddash" = 1 ] && listing=1 ;;
	--skip) shift; skip_name="\$1" ;;
	esac
	shift
done

# A bare \`cargo test\` (no --bins / --test) selects every target. This is the
# PRE-FIX behaviour, and modelling it is what makes the red test red.
if [ "\$explicit_target_selection" = 0 ]; then
	want_bins=1
	SELECTED=(dive_in_url_fetch_test mcp_origin_test meta_dat_metadata_loading $EXCLUDED_TARGET)
fi

count_for() {
	case "\$1" in
	dive_in_url_fetch_test) echo 1 ;;
	mcp_origin_test) echo 12 ;;
	meta_dat_metadata_loading) echo 21 ;;
	$EXCLUDED_TARGET) echo 86 ;;
	*) echo 0 ;;
	esac
}

if [ "\$listing" = 1 ]; then
	if [ "\$want_bins" = 1 ]; then
		echo "$BROWSER_TEST: test"
		for i in \$(seq 1 204); do echo "bin_unit_\$i: test"; done
	fi
	for t in "\${SELECTED[@]:-}"; do
		[ -z "\$t" ] && continue
		n=\$(count_for "\$t")
		for i in \$(seq 1 "\$n"); do echo "\${t}_case_\$i: test"; done
	done
	exit 0
fi

rc=0

emit_ok() { # name, passed, ignored, filtered
	echo "     Running \$1"
	echo "test result: ok. \$2 passed; 0 failed; \$3 ignored; 0 measured; \$4 filtered out; finished in 0.01s"
}

if [ "\$want_bins" = 1 ]; then
	if [ -n "\$skip_name" ]; then
		emit_ok "unittests src/main.rs" 204 0 1
	else
		emit_ok "unittests src/main.rs" 205 0 0
	fi
fi

for t in "\${SELECTED[@]:-}"; do
	[ -z "\$t" ] && continue
	if [ "\$t" = "$EXCLUDED_TARGET" ]; then
		if [ "\${STUB_EXCLUDED_TARGET_PASSES:-0}" = 1 ]; then
			# Used by one mutation to prove the "did it run?" guard does not
			# depend on the target happening to fail.
			emit_ok "tests/$EXCLUDED_TARGET.rs" 79 7 0
			continue
		fi
		echo "     Running tests/$EXCLUDED_TARGET.rs"
		echo "MISSING PREREQUISITE: CODETRACER_RR_BACKEND_PATH is not set"
		echo "test result: FAILED. 4 passed; 75 failed; 7 ignored; 0 measured; 0 filtered out; finished in 0.05s"
		echo "error: test failed, to rerun pass \\\`--test $EXCLUDED_TARGET\\\`"
		rc=101
		continue
	fi
	n=\$(count_for "\$t")
	if [ "\${STUB_UNDERREPORT:-}" = "\$t" ]; then
		n=\$((n - 1))
	fi
	emit_ok "tests/\$t.rs" "\$n" 0 0
done

exit \$rc
STUB
	chmod +x "$dir/bin/cargo"
}

# Runs a (possibly mutated) checkPhase inside a fresh stub crate.
# Echoes combined output; returns the phase's exit status.
run_phase() {
	local phase_file="$1"
	shift
	local workdir
	workdir="$(mktemp -d)"
	make_stub_crate "$workdir"
	(
		cd "$workdir" || exit 1
		export PATH="$workdir/bin:$PATH"
		# ``runHook preCheck`` / ``runHook postCheck`` are nixpkgs setup-hook
		# machinery, not part of the contract under test, so they are stubbed
		# out in the same shell that runs the phase.
		env "$@" bash -c "runHook() { :; }; $(cat "$phase_file")" 2>&1
	)
	local rc=$?
	rm -rf "$workdir"
	return $rc
}

expect_pass() { # label, phase_file, [env...]
	local label="$1" phase="$2"
	shift 2
	local out rc
	out="$(run_phase "$phase" "$@")"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		printf '%s' "$out" >/dev/null
		pass "$label"
	else
		fail "$label" "expected exit 0, got $rc. Output:"
		printf '%s\n' "$out" | sed 's/^/        | /' >&2
	fi
}

expect_killed() { # label, phase_file, expected-message-substring, [env...]
	local label="$1" phase="$2" needle="$3"
	shift 3
	local out rc
	out="$(run_phase "$phase" "$@")"
	rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "$label" "MUTATION SURVIVED: the phase passed with the defect present."
		return
	fi
	if ! printf '%s' "$out" | grep -qF "$needle"; then
		fail "$label" "died (exit $rc) but not on the expected guard; wanted: $needle"
		printf '%s\n' "$out" | sed 's/^/        | /' >&2
		return
	fi
	pass "$label (killed by: $needle)"
}

mutate() { # sed-expr... -> prints path to mutated phase file
	local f
	f="$(mktemp)"
	cp "$CHECK_PHASE_FILE" "$f"
	local expr
	for expr in "$@"; do
		sed -i "$expr" "$f"
	done
	printf '%s' "$f"
}

# =============================================================================
echo
echo "-- the fix itself ------------------------------------------------------"

# THE RED TEST. Before the target exclusion existed, the checkPhase ran a bare
# `cargo test`, the stub selected every target including the unsatisfiable one,
# it reported `75 failed` and exited 101, and the phase failed. This asserts the
# phase now completes -- and, below, that it completes for the right reason.
expect_pass "checkPhase succeeds against a crate whose rr suite cannot run" \
	"$CHECK_PHASE_FILE"

out="$(run_phase "$CHECK_PHASE_FILE")"
if printf '%s' "$out" | grep -q "Running tests/$EXCLUDED_TARGET.rs"; then
	fail "the unsatisfiable target does not run in this lane" \
		"tests/$EXCLUDED_TARGET.rs still ran"
else
	pass "the unsatisfiable target does not run in this lane"
fi

# The whole point of an exclusion that is one target wide: everything else is
# still executed. This is the assertion that would catch "we fixed the build by
# switching the tests off".
missing=""
for t in dive_in_url_fetch_test mcp_origin_test meta_dat_metadata_loading; do
	printf '%s' "$out" | grep -q "Running tests/$t.rs" || missing="$missing $t"
done
printf '%s' "$out" | grep -q "Running unittests src/main.rs" || missing="$missing bins"
if [ -n "$missing" ]; then
	fail "every OTHER target still runs in this lane" "not run:$missing"
else
	pass "every OTHER target still runs in this lane"
fi

# =============================================================================
echo
echo "-- mutations: each guard must kill its own defect -----------------------"

# M1 — the excluded target is renamed or deleted, so the exclusion filters
# nothing and silently stops being an exclusion at all.
m1="$(mutate "s/^excludedTarget=.*/excludedTarget=a_target_that_does_not_exist/")"
expect_killed "M1 exclusion names a target that does not exist" \
	"$m1" "does not exist"

# M2 — the exclusion is defeated: the kept-target loop stops skipping the
# excluded one, so the unsatisfiable suite is back in the sandbox.
m2="$(mutate "s/if \[ \"\$testTarget\" = \"\$excludedTarget\" \]; then/if false; then/")"
expect_killed "M2 excluded target is put back into the run" \
	"$m2" "error: test failed"

# M3 — same defect as M2, but with a stub in which the excluded target PASSES.
# Without the dedicated "did it run?" guard, M2 is only caught because the
# target fails; this proves the guard catches the target RUNNING, which is the
# property that actually matters (a suite that self-passes here is the exact
# lie its prerequisite gate was written to prevent).
expect_killed "M3 excluded target runs and passes (the false green)" \
	"$m2" "ran in this lane after all" STUB_EXCLUDED_TARGET_PASSES=1

# M4 — the single-test exclusion goes stale (test renamed upstream), which
# would make --skip a no-op and quietly reintroduce a test that cannot run.
m4="$(mutate "s/^excluded=browser_stream_host.*/excluded=browser_stream_host::tests::renamed_upstream/")"
expect_killed "M4 single-test exclusion no longer matches any test" \
	"$m4" "is not in this crate's test list"

# M5 — the accounting guard's reason for existing: a kept target silently stops
# being run (here, by narrowing the discovery glob), so coverage shrinks while
# the build stays green.
#
# NOTE: the accounting guard alone does NOT catch this, and did not when this
# suite was first written. It compares the run against the listing of the SAME
# selection, so narrowing the selection shrinks both sides and they stay
# consistent. That is why the checkPhase also checks the selection against
# tests/*.rs on disk. M5 is the mutation that found that hole.
m5="$(mutate "s|for testFile in tests/\*.rs; do|for testFile in tests/dive_in_url_fetch_test.rs; do|")"
expect_killed "M5 a kept target silently drops out of the run" \
	"$m5" "dropped out of the selection"

# M6 — a target still runs but reports fewer tests than it listed.
expect_killed "M6 a kept target under-reports its test count" \
	"$CHECK_PHASE_FILE" "Coverage in" STUB_UNDERREPORT=mcp_origin_test

# M7 — the accounting guard is neutered outright.
m7="$(mutate "s/if \[ \"\$accounted\" -ne \"\$((listed - 1))\" \]; then/if false; then/")"
if run_phase "$m7" STUB_UNDERREPORT=mcp_origin_test >/dev/null; then
	pass "M7 control: with the accounting guard removed, M6's defect goes unnoticed"
else
	fail "M7 control" "expected the un-guarded phase to accept the defect"
fi

# M8 — the crate's own unit tests (the 204 in src/main.rs, the bulk of what
# this lane really does cover) drop out of the selection entirely.
#
# Killed by the single-test-exclusion guard rather than the '--bins' guard: with
# --bins gone the browser test is absent from the LISTING too, and that guard
# runs first. Recorded here as the guard that actually kills it, not the one
# that was expected to -- M9 below is the mutation that isolates the '--bins'
# guard on its own.
m8="$(mutate "s/^cargoTestTargets=\"--bins\"/cargoTestTargets=\"\"/")"
expect_killed "M8 the crate's unit tests drop out of listing and run" \
	"$m8" "is not in this crate's test list"

# M9 — subtler than M8, and the reason the '--bins' guard is not redundant: the
# unit tests are still LISTED (so M4's guard is satisfied and sees the browser
# test) but are no longer RUN. 204 of the 238 tests this lane covers vanish
# while every earlier guard is happy.
m9="$(mutate "s/\$cargoTestTargets -- --skip/--test dive_in_url_fetch_test --test mcp_origin_test --test meta_dat_metadata_loading -- --skip/")"
expect_killed "M9 unit tests are listed but silently not run" \
	"$m9" "unit tests did not run"

rm -f "$CHECK_PHASE_FILE" "$m1" "$m2" "$m4" "$m5" "$m7" "$m8" "$m9"

# =============================================================================
echo
printf 'backend-manager checkPhase contract suite: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
