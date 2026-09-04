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
if [ "${a_rc}" = 3 ]; then
	ck ok "settles the file (exit 3), so a registered red does not fail the lane"
else
	ck no "arm A exit 3 (got ${a_rc})"
fi
if grep -q "1 registered known failure" <<<"${a}"; then
	ck ok "and SAYS it did — the count is printed, never silent"
else
	ck no "arm A announces the registration"
fi

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
if [ "${b_rc}" = 1 ]; then
	ck ok "a registered test that passed FAILS the lane (exit 1)"
else
	ck no "arm B exit 1 (got ${b_rc})"
fi
if grep -q "registered red" <<<"${b}"; then
	ck ok "and names the test whose entry must be deleted"
else
	ck no "arm B names the test"
fi
if grep -qi "delete its row" <<<"${b}"; then
	ck ok "and says what to do about it"
else
	ck no "arm B says what to do"
fi

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
if [ "${c_rc}" = 1 ]; then
	ck ok "a registered test failing for an UNREGISTERED reason fails the lane"
else
	ck no "arm C exit 1 (got ${c_rc})"
fi
if grep -q "not for the registered reason" <<<"${c}"; then
	ck ok "and says so, rather than reporting a generic red"
else
	ck no "arm C explains"
fi
if grep -q "BecauseOfWidgetDefect" <<<"${c}"; then
	ck ok "and quotes the signature it expected to find"
else
	ck no "arm C quotes the expected signature"
fi

# ---------------------------------------------------------------------------
echo
echo "Arm D: a NEW failure beside a registered one — not absorbed"
# ---------------------------------------------------------------------------
d="$(printf '%s\n' \
	"  something went wrong: BecauseOfWidgetDefect" \
	"[FAILED] registered red" \
	"[FAILED] a brand new red" | run demo suite/a.nim)"
d_rc="$(printf '%s\n' "${d}" | head -1)"
if [ "${d_rc}" = 1 ]; then
	ck ok "an unregistered failure beside a registered one fails the lane"
else
	ck no "arm D exit 1 (got ${d_rc})"
fi
if grep -q "a brand new red" <<<"${d}"; then
	ck ok "and names the new one specifically"
else
	ck no "arm D names the new failure"
fi

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
if [ "${e_rc}" = 1 ]; then
	ck ok "a run with no verdict for the registered test fails the lane"
else
	ck no "arm E exit 1 (got ${e_rc})"
fi
if grep -q "no verdict for it at all" <<<"${e}"; then
	ck ok "and names that as the reason, not 'it passed'"
else
	ck no "arm E explains"
fi

# ---------------------------------------------------------------------------
echo
echo "Arm F: a file with no entries is left completely alone"
# ---------------------------------------------------------------------------
f="$(printf '%s\n' "[FAILED] some other suite's red" | run demo suite/b.nim)"
f_rc="$(printf '%s\n' "${f}" | head -1)"
if [ "${f_rc}" = 0 ]; then
	ck ok "an unregistered file is passed through untouched (exit 0)"
else
	ck no "arm F exit 0 (got ${f_rc})"
fi

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
if grep -q "must be non-empty" <<<"${g}"; then
	ck ok "a row without a signature is rejected, not treated as a wildcard"
else
	ck no "arm G rejects a signature-less row"
fi
printf 'demo\tsuite/a.nim\tonly three fields\n' >"${work}/known-test-failures.tsv"
g2="$(printf '%s\n' "[OK] x" | run demo suite/a.nim)"
if grep -q "expected 4 tab-separated fields" <<<"${g2}"; then
	ck ok "a malformed row is a hard error, not a silently dropped entry"
else
	ck no "arm G rejects a malformed row"
fi

# ---------------------------------------------------------------------------
echo
echo "Arm H: audit — an entry against a file the lane does not run"
# ---------------------------------------------------------------------------
cp "${ledger}" "${work}/known-test-failures.tsv"
h_out="$(${KF} audit demo suite/b.nim 2>&1)" && h_rc=0 || h_rc=$?
if [ "${h_rc}" = 1 ]; then
	ck ok "an entry naming a file the lane never runs fails the lane"
else
	ck no "arm H exit 1 (got ${h_rc})"
fi
if grep -q "suite/a.nim" <<<"${h_out}"; then
	ck ok "and names the unreachable entry"
else
	ck no "arm H names the entry"
fi
h2_out="$(${KF} audit demo suite/a.nim 2>&1)" && h2_rc=0 || h2_rc=$?
# QUIET IS ASSERTED, NOT ASSUMED. This control used to look only at the exit
# code while its own sentence promised silence, so an `audit` that started
# printing a complaint and still returned 0 would have read as "stays quiet".
if [ "${h2_rc}" = 0 ] && [ -z "${h2_out}" ]; then
	ck ok "and stays quiet when every entry names a file the lane runs"
else
	ck no "arm H control (exit ${h2_rc}, said: ${h2_out})"
fi

# ---------------------------------------------------------------------------
echo
echo "The real ledger parses, and every row names a real lane"
# ---------------------------------------------------------------------------
real_rows="$(grep -cvE '^\s*(#|$)' ci/lib/known-test-failures.tsv || true)"
if [ "${real_rows}" -gt 0 ]; then
	ck ok "the shipped ledger has ${real_rows} row(s)"
else
	ck no "the shipped ledger has rows"
fi
bad_fields="$(awk -F'\t' '!/^[[:space:]]*(#|$)/ && NF != 4 {n++} END {print n+0}' \
	ci/lib/known-test-failures.tsv)"
if [ "${bad_fields}" -eq 0 ]; then
	ck ok "and every row has exactly 4 tab-separated fields"
else
	ck no "the shipped ledger has ${bad_fields} malformed row(s)"
fi

echo
printf '%d check(s), %d failure(s)\n' "${checks}" "${failures}"
expect_count 20
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — the ledger excuses a registered red and reddens on a registered green"
	exit 0
fi
echo "RESULT: FAILED — ${failures} check(s)"
exit 1
