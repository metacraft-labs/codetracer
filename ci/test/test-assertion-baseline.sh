#!/usr/bin/env bash
# =============================================================================
# Contract: no Rust test function in this repository lacks an assertion, except
# the ones enumerated below.
#
# # The defect this closes
#
# `codetracer-specs/tools/check-test-assertions.sh` flags `#[test]` functions
# whose bodies assert nothing. It is described in its own header as "part of the
# M0 CI lint deliverable", and the specs repo runs `just
# test-check-test-assertions` against it specifically so it "could not rot into
# a no-op".
#
# This repository invoked it NOWHERE -- no reference in `justfile`, `ci/`,
# `.github/` or `scripts/`. And it could not have: the lint lives in a repo that
# is never checked out here. `lint-bash` checks out `codetracer` alone,
# `.github/sibling-repos` does not list `codetracer-specs`, and no workflow
# clones it. A guard was written, shipped, and connected to nothing, which is
# the mechanism by which assertion-less Rust tests lived inside a required gate.
#
# # Why the lint is VENDORED and not reached for in the sibling
#
# `ci/lint/bash.sh` is deliberately the lane that needs "nothing beyond the
# linter itself" -- no siblings, no network, no dev-shell closure. Making it
# clone a private repo to obtain a self-contained shell script would trade that
# property away for nothing. So `tools/check-test-assertions.sh` here is a
# BYTE-IDENTICAL copy of the specs original, and assertion 1 below compares the
# two by sha256 whenever both repos are on disk, so the copy cannot drift
# silently. When the sibling is absent that one assertion says so by name; it is
# the only part of this suite that depends on anything outside this checkout,
# and it is not the part that does the guarding.
#
# # Why a recorded baseline and not "zero violations"
#
# The tree is not at zero and this suite cannot take it there. The two entries
# below are platform-gate stubs: bodies that exist so a `#[cfg]`-excluded test
# still has a name on the platforms where the real test cannot compile. Their
# only statement is an `eprintln!("SKIPPED: ...")`. "Fixing" them means adding an
# assertion about the very `cfg` that already gated compilation -- decorating
# honest code to satisfy a checker -- so they are RECORDED, with an owner, in
# `codetracer-specs/Testing/Known-Test-Failures.md`.
#
# The record fails in BOTH directions, the shape `scripts/test-build-alignment.sh`
# uses for the tup/nix flag divergence:
#
#   * a newly added assertion-less test appears as a line the baseline does not
#     have -- the regression this exists to catch;
#   * a baseline entry that gets FIXED disappears from the actual set, so the
#     record cannot rot into a lie about a problem that is gone.
#
# Entries are `path::function`, never line numbers, which drift honestly.
#
# # Why this cannot pass vacuously
#
# The baseline is NON-EMPTY, which makes it the lint's own canary: a lint that
# rotted into a no-op finds zero violations, and zero does not equal the two
# recorded here, so this suite goes red. The census assertions below are the
# second layer -- they fail if the scan stopped reading the tree at all, which
# is how the `#\[test` pre-filter used to skip every file whose tests are all
# `#[tokio::test]`.
#
# # No mocks
#
# The committed `src/` and `tests/` trees are the input.
#
# Run: bash ci/test/test-assertion-baseline.sh
# Lane: a step of `lint-bash` (pure bash + awk, no nix, no network). Roughly
#       10-30s: it reads every .rs file in the repository twice.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly LINT="$REPO_ROOT/tools/check-test-assertions.sh"
readonly SPECS_ORIGIN="$REPO_ROOT/../codetracer-specs/tools/check-test-assertions.sh"

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

# ---------------------------------------------------------------------------
# The recorded baseline: every test function in this repository that the lint
# flags, and that we have decided not to change. `path::function`, sorted.
#
# To change it you must say why in codetracer-specs/Testing/Known-Test-Failures.md.
# ---------------------------------------------------------------------------
recorded_violations() {
	cat <<-'EOF'
		src/db-backend/tests/dap_backend_server.rs::dap_server_socket_transport_is_unix_only
		src/db-backend/tests/reprobuild_hcr_in_codetracer_test.rs::reprobuild_hcr_in_codetracer_unsupported_platform_profile
	EOF
}

# ---------------------------------------------------------------------------
# 1. The vendored lint is the specs original, byte for byte.
# ---------------------------------------------------------------------------
echo "the vendored lint matches its canonical source"

if [ ! -x "$LINT" ]; then
	fail "tools/check-test-assertions.sh is present and executable" \
		"expected at: $LINT" \
		"Without it nothing below can run and this repository has no assertion gate."
	printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
ok "tools/check-test-assertions.sh is present and executable"

if [ -f "$SPECS_ORIGIN" ]; then
	vendored_sha="$(sha256sum <"$LINT" | cut -d' ' -f1)"
	origin_sha="$(sha256sum <"$SPECS_ORIGIN" | cut -d' ' -f1)"
	if [ "$vendored_sha" = "$origin_sha" ]; then
		ok "vendored copy is byte-identical to codetracer-specs (sha256 $vendored_sha)"
	else
		fail "vendored copy is byte-identical to codetracer-specs" \
			"vendored: $vendored_sha" \
			"specs:    $origin_sha" \
			"Edit codetracer-specs/tools/check-test-assertions.sh, then re-copy it here." \
			"Its self-test (just test-check-test-assertions, in that repo) is what proves" \
			"a change to it still works; this copy has no self-test of its own."
	fi
else
	# Not a skip of the guarding: everything below still runs. This one
	# assertion cannot be evaluated without the sibling, and says so.
	ok "codetracer-specs not on disk — drift comparison not evaluated here (lint still runs below)"
fi

# ---------------------------------------------------------------------------
# 2. The scan actually read the tree.
# ---------------------------------------------------------------------------
echo
echo "the scan read the repository"

cd "$REPO_ROOT" || exit 1
lint_out="$(bash "$LINT" src tests 2>&1)"
lint_status=$?

# The lint exits 1 whenever it finds anything, and it is EXPECTED to find the
# recorded entries, so its exit code is not this suite's verdict -- the
# comparison below is. Exit 2 (usage) and 3 (nothing scanned) are still fatal:
# they mean it never judged the tree.
case "$lint_status" in
0 | 1)
	ok "lint ran and judged the tree (exit $lint_status)"
	;;
*)
	fail "lint ran and judged the tree" \
		"exit $lint_status -- 2 is a usage error, 3 is 'nothing was scanned'." \
		"$lint_out"
	;;
esac

# Floors, not equalities: these numbers grow as the repository does, and a
# hard equality would redden on every added test. They are set to catch the
# failure that matters -- a scan that stopped reading files -- with room for
# ordinary churn. Measured at 374 / 283 / 1628 when this was written.
files_scanned="$(printf '%s\n' "$lint_out" | sed -n 's/.*, \([0-9]*\) \.rs file(s).*/\1/p' | head -1)"
files_with_tests="$(printf '%s\n' "$lint_out" | sed -n 's/.*, \([0-9]*\) with #\[test\].*/\1/p' | head -1)"
tests_examined="$(printf '%s\n' "$lint_out" | sed -n 's/.*, \([0-9]*\) test function(s) examined.*/\1/p' | head -1)"

check_floor() {
	local label="$1" got="$2" floor="$3"
	if [ -n "$got" ] && [ "$got" -ge "$floor" ] 2>/dev/null; then
		ok "$label: $got (floor $floor)"
	else
		fail "$label: got '${got:-<unparsed>}', expected at least $floor" \
			"A scan that suddenly reads far less of the tree is reporting on code it" \
			"never opened. If the drop is legitimate, lower the floor deliberately." \
			"$lint_out"
	fi
}

check_floor ".rs files scanned"          "$files_scanned"   300
check_floor "files carrying tests"       "$files_with_tests" 200
check_floor "test functions examined"    "$tests_examined"  1200

# ---------------------------------------------------------------------------
# 3. The violations are exactly the recorded ones.
# ---------------------------------------------------------------------------
echo
echo "flagged tests match the recorded baseline"

# `path:LINE: test `name` has ...`  ->  `path::name`. Line numbers are dropped
# on purpose: they drift with every edit above them and would make the record
# unmaintainable without saying anything about the defect.
actual_violations() {
	# shellcheck disable=SC2016  # the backticks are the lint's own output
	# format, matched literally; single quotes are exactly what is wanted.
	printf '%s\n' "$lint_out" |
		sed -n 's/^\(.*\):[0-9][0-9]*: test `\([^`]*\)`.*/\1::\2/p' |
		LC_ALL=C sort -u
}

actual="$(actual_violations)"
recorded="$(recorded_violations | sed 's/^[[:space:]]*//' | grep -v '^$' | LC_ALL=C sort -u)"

if [ "$actual" = "$recorded" ]; then
	ok "flagged set matches the baseline ($(printf '%s\n' "$recorded" | grep -c . ) entr(y/ies))"
else
	delta="$(diff <(printf '%s\n' "$recorded") <(printf '%s\n' "$actual") |
		sed -n 's/^< /  FIXED — remove it from the baseline: /p;s/^> /  NEW assertion-less test: /p')"
	fail "flagged set matches the baseline" \
		"A test that asserts nothing reports success for work it never did." \
		"$delta" \
		"Baseline lives in recorded_violations() in this file; the reasons live in" \
		"codetracer-specs/Testing/Known-Test-Failures.md."
fi

echo
readonly EXPECTED_ASSERTIONS=7
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
