#!/usr/bin/env bash
# =============================================================================
# Contract: no Rust test function in this repository lacks an assertion, except
# the ones enumerated below.
#
# # The defect this closes
#
# `codetracer-pm/tools/check-test-assertions.sh` flags `#[test]` functions
# whose bodies assert nothing. It is described in its own header as "part of the
# M0 CI lint deliverable", and the specs repo runs `just
# test-check-test-assertions` against it specifically so it "could not rot into
# a no-op".
#
# Originally this repository invoked it NOWHERE -- no reference in `justfile`, `ci/`,
# `.github/` or `scripts/`. And it could not have: the lint lives in a repo that
# was never checked out here. `lint-bash` checked out `codetracer` alone,
# `.github/sibling-repos` does not list `codetracer-specs`, and no workflow
# cloned it. A guard was written, shipped, and connected to nothing, which is
# the mechanism by which assertion-less Rust tests lived inside a required gate.
#
# # Why the lint is vendored and its canonical copy is required here
#
# `tools/check-test-assertions.sh` remains a BYTE-IDENTICAL copy of the specs
# original so the lint itself can run without a sibling. This suite also proves
# that copy has not drifted: assertion 1 requires the canonical source from
# `$CT_SPECS_DIR`, else `../codetracer-pm`. CI provisions that checkout before
# running this suite. A missing source is a failure, since no comparison was
# made; it cannot certify the copy as current.
#
# # Why a recorded baseline and not "zero violations"
#
# When this was written the tree was not at zero and this suite could not take
# it there. The two entries it started with were platform-gate stubs: bodies
# that existed so a `#[cfg]`-excluded test still had a name on the platforms
# where the real test cannot compile, whose only statement was an
# `eprintln!("SKIPPED: ...")`. "Fixing" them meant adding an assertion about the
# very `cfg` that already gated compilation -- decorating honest code to satisfy
# a checker -- so they were RECORDED, with an owner, in
# `codetracer-pm/spec/Testing/Known-Test-Failures.md`. Both have since gone
# (see recorded_violations), and the record is kept so the next honest
# exception has a place to go that is not "turn the gate off".
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
# The vendored lint's own repository was renamed from `codetracer-specs` to
# `codetracer-pm` (its Known-Test-Failures record now sits under `spec/`), and
# this suite kept looking for `../codetracer-specs`, so assertion 1 silently
# reported "not on disk" on every workspace that had the renamed sibling.
#
# # Why this cannot pass vacuously
#
# The baseline USED to be the canary: while it was non-empty, a lint that
# rotted into a no-op found zero violations, zero did not equal the record, and
# this suite went red. The last entry left on 2026-10-01 (dd5b3f6bf deleted the
# non-Unix stub `dap_server_socket_transport_is_unix_only`), so the baseline is
# now empty and an empty scan would MATCH it. The canary is therefore explicit:
# section 3 runs the lint over a two-test fixture and requires it to flag the
# assertion-less test and only that one. The census assertions are the second
# layer -- they fail if the scan stopped reading the tree at all, which is how
# the `#\[test` pre-filter used to skip every file whose tests are all
# `#[tokio::test]`.
#
# # No mocks
#
# The committed `src/` and `tests/` trees are the input.
#
# Run: bash ci/test/test-assertion-baseline.sh
# Lane: a step of `lint-nim` (bash + awk, with codetracer-pm on disk). Roughly
#       10-30s: it reads every .rs file in the repository twice.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
readonly REPO_ROOT
readonly LINT="$REPO_ROOT/tools/check-test-assertions.sh"
readonly SPECS_ORIGIN="${CT_SPECS_DIR:-$REPO_ROOT/../codetracer-pm}/tools/check-test-assertions.sh"

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
# To change it you must say why in codetracer-pm/spec/Testing/Known-Test-Failures.md.
# ---------------------------------------------------------------------------
#
# Empty since dap_backend_server.rs::dap_server_socket_transport_is_unix_only
# was deleted (dd5b3f6bf). An entry goes between the EOF markers, one per line.
recorded_violations() {
	cat <<-'EOF'
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
		ok "vendored copy is byte-identical to codetracer-pm (sha256 $vendored_sha)"
	else
		fail "vendored copy is byte-identical to codetracer-pm" \
			"vendored: $vendored_sha" \
			"specs:    $origin_sha" \
			"Edit codetracer-pm/tools/check-test-assertions.sh, then re-copy it here." \
			"Its self-test (just test-check-test-assertions, in that repo) is what proves" \
			"a change to it still works; this copy has no self-test of its own."
	fi
else
	fail "canonical test-assertion lint is missing" \
		"expected at: $SPECS_ORIGIN" \
		"Provide the codetracer-pm sibling, or set CT_SPECS_DIR to its checkout."
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

check_floor ".rs files scanned" "$files_scanned" 300
check_floor "files carrying tests" "$files_with_tests" 200
check_floor "test functions examined" "$tests_examined" 1200

# THE CANARY. The census above proves the scan READ the tree; it cannot prove
# the scan can still FLAG anything, and with an empty baseline a lint that
# flags nothing would match the record in section 3. So run it over a fixture
# with exactly one assertion-less test beside one assertive test and require
# that one, and only that one. This is a fixture input, not a mock: the real
# vendored lint runs on a real .rs file, written to a temp dir at run time so
# no repository scan (this one, cargo's, the pre-commit hooks') ever sees it.
canary_dir="$(mktemp -d "${TMPDIR:-/tmp}/test-assertion-canary.XXXXXX")" || exit 1
trap 'rm -rf "$canary_dir"' EXIT
mkdir -p "$canary_dir/tests"
cat >"$canary_dir/tests/canary.rs" <<'RS'
#[test]
fn canary_asserts_nothing() {
    let _ = 1 + 1;
}

#[test]
fn canary_asserts() {
    assert_eq!(1 + 1, 2);
}
RS
canary_out="$(cd "$canary_dir" && bash "$LINT" tests 2>&1)"
canary_status=$?
# shellcheck disable=SC2016  # the backticks are the lint's own output format
canary_flagged="$(printf '%s\n' "$canary_out" |
	sed -n 's/^\(.*\):[0-9][0-9]*: test `\([^`]*\)`.*/\1::\2/p' | LC_ALL=C sort -u)"
if [ "$canary_status" -eq 1 ] && [ "$canary_flagged" = "tests/canary.rs::canary_asserts_nothing" ]; then
	ok "the lint flags the canary's assertion-less test, and only that one"
else
	fail "the lint flags the canary's assertion-less test, and only that one" \
		"expected exit 1 flagging exactly tests/canary.rs::canary_asserts_nothing;" \
		"got exit $canary_status flagging: '${canary_flagged:-<nothing>}'" \
		"A lint that flags nothing would match an empty baseline below and pass." \
		"$canary_out"
fi

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

# One entry per line, and NOTHING for an empty set. `printf '%s\n' ""` prints a
# blank line, so diffing an empty side against a non-empty one used to report
# that blank line as an entry -- an "NEW assertion-less test: " with no name
# after it, which is how an emptied actual set read when the last baseline
# entry was fixed.
as_lines() { [ -z "$1" ] || printf '%s\n' "$1"; }

if [ "$actual" = "$recorded" ]; then
	ok "flagged set matches the baseline ($(as_lines "$recorded" | grep -c .) entr(y/ies))"
else
	delta="$(diff <(as_lines "$recorded") <(as_lines "$actual") |
		sed -n 's/^< /  FIXED — remove it from the baseline: /p;s/^> /  NEW assertion-less test: /p')"
	fail "flagged set matches the baseline" \
		"A test that asserts nothing reports success for work it never did." \
		"$delta" \
		"Baseline lives in recorded_violations() in this file; the reasons live in" \
		"codetracer-pm/spec/Testing/Known-Test-Failures.md."
fi

echo
readonly EXPECTED_ASSERTIONS=8
if [ "$assertions" -ne "$EXPECTED_ASSERTIONS" ]; then
	printf 'FAIL: ran %d assertions, expected %d\n' "$assertions" "$EXPECTED_ASSERTIONS"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
