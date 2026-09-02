#!/usr/bin/env bash
#
# known-failures-gate.sh — the ledger fails in BOTH directions.
#
# WHY THIS EXISTS
# ---------------
# A suppression mechanism that has only ever been observed suppressing failures
# is indistinguishable from one that suppresses everything. This drives
# `ci/lib/known_failures.py` over fixtures and asserts the exit code and the
# message in each direction, so "the ledger works" is a measurement rather than
# a hope.
#
# The product owner's constraint is the spec:
#
#     "We need to introduce a new category in the test suite for known failures
#      which would be tests that would signal when they go green. Don't write
#      tests that assert on the wrong behavior because this is confusing for
#      future maintainers."
#
# "Signal when they go green" is arm B. It is the half a mute button does not
# have, and the half that keeps a stale entry from laundering the next real
# regression as an expected one.
#
# Usage:  bash ci/test/known-failures-gate.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

kf="${repo_root}/ci/lib/known_failures.py"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

checks=0
failures=0
ck() {
	checks=$((checks + 1))
	if [ "$1" = ok ]; then
		printf '  [OK]      %s\n' "$2"
	else
		failures=$((failures + 1))
		printf '  [FAILED]  %s\n' "$2"
	fi
}
note() { printf '      %s\n' "$*"; }

expect_count() {
	if [ "${checks}" -ne "$1" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "$1"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

# A ledger of our own, so this gate does not depend on what the real one
# happens to contain today.
ledger="${work}/ledger.tsv"
cat >"${ledger}" <<'TSV'
# fixture ledger
demo	suite/a.nim	registered red	BecauseOfWidgetDefect
TSV

# `known_failures.py` reads the ledger beside itself, so the fixture is fed in
# by copying the script next to it. Copying rather than adding a
# `--ledger` flag on purpose: a test-only input path is one more thing the
# real run does not exercise.
cp "${kf}" "${work}/known_failures.py"
cp "${ledger}" "${work}/known-test-failures.tsv"
KF="python3 ${work}/known_failures.py"

run() { # stdin = suite output; $1 lane, $2 file -> prints rc then output
	local lane="$1" file="$2" out rc
	out="$(${KF} reconcile "${lane}" "${file}" 2>&1)" && rc=0 || rc=$?
	printf '%s\n' "${rc}"
	printf '%s\n' "${out}"
}

echo "=== the known-failure ledger fails in both directions ==="
echo

# ---------------------------------------------------------------------------
echo "Arm A: a registered failure, failing as registered — the lane stays green"
# ---------------------------------------------------------------------------
a="$(printf '%s\n' \
	"  something went wrong: BecauseOfWidgetDefect" \
	"[FAILED] registered red" \
	"[OK] an unrelated case" | run demo suite/a.nim)"
a_rc="$(printf '%s\n' "${a}" | head -1)"
[ "${a_rc}" = 3 ] &&
	ck ok "settles the file (exit 3), so a registered red does not fail the lane" ||
	ck no "arm A exit 3 (got ${a_rc})"
printf '%s\n' "${a}" | grep -q "1 registered known failure" &&
	ck ok "and SAYS it did — the count is printed, never silent" ||
	ck no "arm A announces the registration"

# ---------------------------------------------------------------------------
echo
echo "Arm B: a registered test that PASSES — the lane goes red, by name"
#
# The direction the product owner asked for. Without it this file is a mute
# button.
# ---------------------------------------------------------------------------
b="$(printf '%s\n' \
	"[OK] registered red" \
	"[OK] an unrelated case" | run demo suite/a.nim)"
b_rc="$(printf '%s\n' "${b}" | head -1)"
[ "${b_rc}" = 1 ] &&
	ck ok "a registered test that passed FAILS the lane (exit 1)" ||
	ck no "arm B exit 1 (got ${b_rc})"
printf '%s\n' "${b}" | grep -q "registered red" &&
	ck ok "and names the test whose entry must be deleted" ||
	ck no "arm B names the test"
printf '%s\n' "${b}" | grep -qi "delete its row" &&
	ck ok "and says what to do about it" ||
	ck no "arm B says what to do"

# ---------------------------------------------------------------------------
echo
echo "Arm C: the SAME test failing a DIFFERENT way — not absorbed"
#
# THE TRAP THIS MECHANISM EXISTS TO CLOSE. An entry keyed only on a test's
# identity swallows any failure of that test. A sibling repo's journey ledger
# did exactly this: the journey began throwing on its first line after a schema
# bump, and the entry went on absorbing the exit code, so a failure nobody had
# ever reviewed was green-lit indefinitely.
# ---------------------------------------------------------------------------
c="$(printf '%s\n' \
	"  something went wrong: a totally different explosion" \
	"[FAILED] registered red" \
	"[OK] an unrelated case" | run demo suite/a.nim)"
c_rc="$(printf '%s\n' "${c}" | head -1)"
[ "${c_rc}" = 1 ] &&
	ck ok "a registered test failing for an UNREGISTERED reason fails the lane" ||
	ck no "arm C exit 1 (got ${c_rc})"
printf '%s\n' "${c}" | grep -q "not for the registered reason" &&
	ck ok "and says so, rather than reporting a generic red" ||
	ck no "arm C explains"
printf '%s\n' "${c}" | grep -q "BecauseOfWidgetDefect" &&
	ck ok "and quotes the signature it expected to find" ||
	ck no "arm C quotes the expected signature"

# ---------------------------------------------------------------------------
echo
echo "Arm D: a NEW failure beside a registered one — not absorbed"
# ---------------------------------------------------------------------------
d="$(printf '%s\n' \
	"  something went wrong: BecauseOfWidgetDefect" \
	"[FAILED] registered red" \
	"[FAILED] a brand new red" | run demo suite/a.nim)"
d_rc="$(printf '%s\n' "${d}" | head -1)"
[ "${d_rc}" = 1 ] &&
	ck ok "an unregistered failure beside a registered one fails the lane" ||
	ck no "arm D exit 1 (got ${d_rc})"
printf '%s\n' "${d}" | grep -q "a brand new red" &&
	ck ok "and names the new one specifically" ||
	ck no "arm D names the new failure"

# ---------------------------------------------------------------------------
echo
echo "Arm E: a suite that never reached its cases — never excused"
#
# A compile error or a crash before the first case produces no verdicts at all.
# `run-nim-test-lane.sh` additionally refuses to consult the ledger for
# `crashed` / `no-results` / `silent-failure`, so this is the second of two
# independent guards.
# ---------------------------------------------------------------------------
e="$(printf '%s\n' "Error: cannot open file: widget" | run demo suite/a.nim)"
e_rc="$(printf '%s\n' "${e}" | head -1)"
[ "${e_rc}" = 1 ] &&
	ck ok "a run with no verdict for the registered test fails the lane" ||
	ck no "arm E exit 1 (got ${e_rc})"
printf '%s\n' "${e}" | grep -q "no verdict for it at all" &&
	ck ok "and names that as the reason, not 'it passed'" ||
	ck no "arm E explains"

# ---------------------------------------------------------------------------
echo
echo "Arm F: a file with no entries is left completely alone"
# ---------------------------------------------------------------------------
f="$(printf '%s\n' "[FAILED] some other suite's red" | run demo suite/b.nim)"
f_rc="$(printf '%s\n' "${f}" | head -1)"
[ "${f_rc}" = 0 ] &&
	ck ok "an unregistered file is passed through untouched (exit 0)" ||
	ck no "arm F exit 0 (got ${f_rc})"

# ---------------------------------------------------------------------------
echo
echo "Arm G: an entry with no signature is refused at load time"
#
# An entry that pins nothing would absorb any failure of its test — the very
# thing arm C exists to prevent. It is rejected rather than treated as a
# wildcard.
# ---------------------------------------------------------------------------
printf 'demo\tsuite/a.nim\tregistered red\t\n' >"${work}/known-test-failures.tsv"
g="$(printf '%s\n' "[OK] x" | run demo suite/a.nim)"
printf '%s\n' "${g}" | grep -q "must be non-empty" &&
	ck ok "a row without a signature is rejected, not treated as a wildcard" ||
	ck no "arm G rejects a signature-less row"
printf 'demo\tsuite/a.nim\tonly three fields\n' >"${work}/known-test-failures.tsv"
g2="$(printf '%s\n' "[OK] x" | run demo suite/a.nim)"
printf '%s\n' "${g2}" | grep -q "expected 4 tab-separated fields" &&
	ck ok "a malformed row is a hard error, not a silently dropped entry" ||
	ck no "arm G rejects a malformed row"

# ---------------------------------------------------------------------------
echo
echo "Arm H: audit — an entry against a file the lane does not run"
# ---------------------------------------------------------------------------
cp "${ledger}" "${work}/known-test-failures.tsv"
h_out="$(${KF} audit demo suite/b.nim 2>&1)" && h_rc=0 || h_rc=$?
[ "${h_rc}" = 1 ] &&
	ck ok "an entry naming a file the lane never runs fails the lane" ||
	ck no "arm H exit 1 (got ${h_rc})"
printf '%s\n' "${h_out}" | grep -q "suite/a.nim" &&
	ck ok "and names the unreachable entry" ||
	ck no "arm H names the entry"
h2_out="$(${KF} audit demo suite/a.nim 2>&1)" && h2_rc=0 || h2_rc=$?
[ "${h2_rc}" = 0 ] &&
	ck ok "and stays quiet when every entry names a file the lane runs" ||
	ck no "arm H control (got ${h2_rc})"

# ---------------------------------------------------------------------------
echo
echo "The real ledger parses, and every row names a real lane"
# ---------------------------------------------------------------------------
real_rows="$(grep -cvE '^\s*(#|$)' ci/lib/known-test-failures.tsv || true)"
[ "${real_rows}" -gt 0 ] &&
	ck ok "the shipped ledger has ${real_rows} row(s)" ||
	ck no "the shipped ledger has rows"
bad_fields="$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF != 4 {n++} END {print n+0}' \
	ci/lib/known-test-failures.tsv)"
[ "${bad_fields}" -eq 0 ] &&
	ck ok "and every row has exactly 4 tab-separated fields" ||
	ck no "the shipped ledger has ${bad_fields} malformed row(s)"

echo
printf '%d check(s), %d failure(s)\n' "${checks}" "${failures}"
expect_count 20
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the ledger excuses a registered red and reddens on a registered green"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
