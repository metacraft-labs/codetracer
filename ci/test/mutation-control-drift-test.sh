#!/usr/bin/env bash
#
# mutation-control-drift-test.sh — does mutation-control-drift.sh bite?
#
# The convention `ci/lint/nim.sh` states for every guard it runs: "a guard that
# has only ever been watched printing OK is not evidence. It drives the guard
# against synthetic trees and asserts each of its checks fires by name."
#
# So every arm below builds a SYNTHETIC git repository — three control files,
# the subjects they digest, the harnesses that own them and a ledger — and runs
# the REAL gate against it with `--root`. Nothing in the real tree is mutated:
# the real tree's subjects are the product's sources, other work edits them
# concurrently, and an in-place edit-and-restore of a digested subject is the
# exact act the gate exists to report.
#
# What the gate is for (codetracer-pm Verification-Harness-Traps §39c): 30 of
# the 49 control files were stale on `agents` on 2026-10-21, and each stale
# entry is a commit that edited a digested subject without being told which
# harness it had just disabled. The arm that matters most is therefore KEY
# SCENARIO below — one edit to a subject two harnesses digest, and the gate
# naming both harnesses.
#
# Every failure class the gate has is an arm here, and each is asserted BY NAME
# (`NEW DRIFT`, `MOVED AGAIN`, `PAID`, ...), not by "it went red": a gate that
# goes red for the wrong reason would pass a weaker suite.
#
# Run:  bash ci/test/mutation-control-drift-test.sh
# Exit: 0 every arm killed by its own rule, 1 otherwise.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/mutation-control-drift.sh"
LEDGER_REL="ci/test/mutation-control-drift.known-stale.txt"

checks=0
failures=0
ok() {
	checks=$((checks + 1))
	printf '  [OK]     %s\n' "$*"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	printf '  [FAILED] %s\n' "$*"
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

ZEROS="0000000000000000000000000000000000000000000000000000000000000000"
C1="src/a/plat1-alpha-mutation-control.sha256"
C2="src/b/plat2-beta-mutation-control.sha256"
C3="src/c/plat3-orphan-mutation-control.sha256"
H1="src/a/run-plat1-alpha-mutations.py"
H2="src/b/run-plat2-beta-mutations.py"

sha() { sha256sum "$1" | cut -d' ' -f1; }

# The tree every arm starts from. Each part is there because some arm needs it
# to be able to fail:
#
#   * C1 and C2 both digest `justfile`, so one edit owes two harnesses (KEY
#     SCENARIO);
#   * C1 carries a comment line holding a WRONG digest-shaped token, a blank
#     line, and three sibling entries with wrong digests in the three spellings
#     the real tree uses (`isonim-gpui/…`, `../<repo>/…`, `<repo>:…`). None of
#     them may be graded, so the control being green is itself the assertion;
#   * C3 has no harness naming it, and `src/c/` holds a harness that names a
#     DIFFERENT control file — so the gate must look the harness up by the
#     control file's name, not by the directory it sits in.
stage() {
	local d="$1"
	rm -rf "${d}"
	mkdir -p "${d}/src/a" "${d}/src/b" "${d}/src/c" "${d}/ci/test"
	printf 'proc one*() = discard\n' >"${d}/src/a/subj1.nim"
	printf 'proc two*() = discard\n' >"${d}/src/a/subj2.nim"
	printf 'proc three*() = discard\n' >"${d}/src/b/subj3.nim"
	printf 'proc four*() = discard\n' >"${d}/src/c/subj4.nim"
	printf 'build:\n  echo build\n' >"${d}/justfile"
	printf 'CONTROL_HASHES = HERE / "%s"\n' "$(basename "${C1}")" >"${d}/${H1}"
	printf 'CONTROL_HASHES = HERE / "%s"\n' "$(basename "${C2}")" >"${d}/${H2}"
	printf 'CONTROL_HASHES = HERE / "plat3-other-mutation-control-v2.sha256"\n' \
		>"${d}/src/c/run-plat3-other-mutations.py"
	{
		printf '# Control digests for run-plat1-alpha-mutations.py.\n'
		printf '#\n'
		printf '# A prose line holding a digest-shaped token is prose, not an entry:\n'
		printf '# %s  src/a/subj1.nim\n' "${ZEROS}"
		printf '%s  src/a/subj1.nim\n' "$(sha "${d}/src/a/subj1.nim")"
		printf '%s  src/a/subj2.nim\n' "$(sha "${d}/src/a/subj2.nim")"
		printf '\n'
		printf '%s  justfile\n' "$(sha "${d}/justfile")"
		printf '%s  isonim-gpui/src/isonim_gpui/renderer.nim\n' "${ZEROS}"
		printf '%s  ../isonim/src/isonim/core/boundary_meter.nim\n' "${ZEROS}"
		printf '%s  specs:spec/GUI/CUA-Keymap.md\n' "${ZEROS}"
	} >"${d}/${C1}"
	{
		printf '%s  src/b/subj3.nim\n' "$(sha "${d}/src/b/subj3.nim")"
		printf '%s  justfile\n' "$(sha "${d}/justfile")"
	} >"${d}/${C2}"
	printf '%s  src/c/subj4.nim\n' "$(sha "${d}/src/c/subj4.nim")" >"${d}/${C3}"
	printf '# synthetic ledger header\n#\n# <control>\t<subject>\t<recorded>\t<current>\n\n' \
		>"${d}/${LEDGER_REL}"
	git -C "${d}" init -q
	git -C "${d}" add -A
}

# The synthetic tree has 3 control files; the real one has 49 and the gate's
# default floor is far above 3. Arm FLOOR runs without this override.
#
# Every run ends with a `GUARD-EXIT: <rc>` line, and expect_red / expect_green
# assert it: ci/lint/nim.sh judges the gate by its EXIT STATUS, so a gate that
# printed FAILED and exited 0 would be green in CI while every text match here
# still held.
run_guard() {
	bash "${guard}" --root "$1" --min-controls=1 2>&1
	echo "GUARD-EXIT: $?"
}
# The same, with the gate's default floor (no --min-controls override).
run_guard_default() {
	bash "${guard}" --root "$1" 2>&1
	echo "GUARD-EXIT: $?"
}

# `ledger_line CONTROL SUBJECT` — the exact line the gate must tell a developer
# to add, computed here independently from the arm's tree.
ledger_line() {
	local d="$1" control="$2" subject="$3" recorded current
	recorded="$(awk -v p="${subject}" '$1 ~ /^[0-9a-f]{64}$/ && $2 == p { print $1 }' "${d}/${control}")"
	if [ -f "${d}/${subject}" ]; then current="$(sha "${d}/${subject}")"; else current="absent"; fi
	printf '%s\t%s\t%s\t%s' "${control}" "${subject}" "${recorded}" "${current}"
}

# EVERY MATCH BELOW IS A HERE-STRING, NOT `printf | grep -q` — the reason is in
# ci/test/grep-q-pipefail-gate.sh: under pipefail, a pipe into `grep -q` can
# report a present match as absent, which here would read as a SURVIVED arm.
expect_red() {
	local name="$1" out="$2" needle
	shift 2
	if grep -q 'RESULT: OK' <<<"${out}"; then
		bad "${name}: SURVIVED — the gate is green with the defect in place"
		return
	fi
	if ! grep -qx 'GUARD-EXIT: 1' <<<"${out}"; then
		bad "${name}: SURVIVED — the gate printed a failure but did not exit 1 ($(grep '^GUARD-EXIT:' <<<"${out}"))"
		return
	fi
	for needle in "$@"; do
		if ! grep -qF -- "${needle}" <<<"${out}"; then
			bad "${name}: went red, but did not say: ${needle}"
			grep -E '\[FAILED\]|RESULT' <<<"${out}" | head -4 | sed 's/^/           /'
			return
		fi
	done
	ok "${name}: killed, by name"
}
expect_green() {
	local name="$1" out="$2" needle
	shift 2
	if ! grep -q 'RESULT: OK' <<<"${out}" || ! grep -qx 'GUARD-EXIT: 0' <<<"${out}"; then
		bad "${name}: the gate is red on a tree it must accept"
		grep -E '\[FAILED\]|RESULT|^GUARD-EXIT' <<<"${out}" | head -5 | sed 's/^/           /'
		return
	fi
	for needle in "$@"; do
		if ! grep -qF -- "${needle}" <<<"${out}"; then
			bad "${name}: green, but did not say: ${needle}"
			grep -E 'RESULT' <<<"${out}" | sed 's/^/           /'
			return
		fi
	done
	ok "${name}"
}

echo "=== mutation-control-drift selftest — one arm per failure class ==="
echo

if [ ! -f "${guard}" ]; then
	bad "the gate ${guard#"${repo_root}"/} does not exist — nothing to test"
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED"
	exit 1
fi

# ---------------------------------------------------------------------------
# THE CONTROL. Without a green baseline every red below is unattributable. It
# is also the comment and sibling arm: C1 carries a wrong digest on a `#` line
# and on three sibling entries, so a gate that graded any of them is red here.
# ---------------------------------------------------------------------------
B="${work}/base"
stage "${B}"
base_out="$(run_guard "${B}")"
expect_green "CONTROL: a current tree is green; comment lines and sibling entries are not graded" \
	"${base_out}" \
	"3 control file(s), 6 in-repo entries, 0 stale-and-ledgered over 0 control file(s), 3 sibling entries not assessed"
if [ "${failures}" -gt 0 ]; then
	printf '%s\n' "${base_out}" | sed 's/^/           /'
	echo
	echo "${checks} check(s), ${failures} failure(s)"
	echo "RESULT: FAILED — the control is red, so no arm below can demonstrate anything"
	exit 1
fi
echo

A="${work}/arm"

# --- NEW DRIFT --------------------------------------------------------------
stage "${A}"
printf '# edited\n' >>"${A}/src/a/subj1.nim"
expect_red "NEW DRIFT: a digested subject is edited and no ledger line names it" \
	"$(run_guard "${A}")" \
	"NEW DRIFT" "control: ${C1}" "harness: ${H1}" "subject: src/a/subj1.nim" \
	"$(ledger_line "${A}" "${C1}" src/a/subj1.nim)"

# --- KEY SCENARIO -----------------------------------------------------------
# The issue's own case: a change edits a subject and must see WHICH HARNESSES it
# leaves owing a re-grade. `justfile` is digested by two controls, so both
# harnesses must be named, each with the line that records its debt.
stage "${A}"
printf 'test:\n  echo test\n' >>"${A}/justfile"
expect_red "KEY SCENARIO: one edit to a subject two harnesses digest names BOTH harnesses" \
	"$(run_guard "${A}")" \
	"harness: ${H1}" "harness: ${H2}" \
	"$(ledger_line "${A}" "${C1}" justfile)" \
	"$(ledger_line "${A}" "${C2}" justfile)" \
	"2 new drift"

# --- NEW DRIFT, no harness --------------------------------------------------
stage "${A}"
printf '# edited\n' >>"${A}/src/c/subj4.nim"
expect_red "NEW DRIFT on a control no harness names: the gate says there is none" \
	"$(run_guard "${A}")" \
	"NEW DRIFT" "control: ${C3}" "no run-plat*-mutations.py in src/c names this control file"

# --- NEW DRIFT, subject absent ----------------------------------------------
stage "${A}"
rm "${A}/src/b/subj3.nim"
expect_red "NEW DRIFT: an in-repo entry whose file no longer exists" \
	"$(run_guard "${A}")" \
	"NEW DRIFT" "harness: ${H2}" "$(ledger_line "${A}" "${C2}" src/b/subj3.nim)"

# --- NEW DRIFT, top-level subject deleted -----------------------------------
# `git rm justfile` leaves no tracked path whose first component is `justfile`.
# A gate that classified siblings by "first component not tracked" alone would
# then count both entries as NOT ASSESSED and pass.
stage "${A}"
git -C "${A}" rm -qf -- justfile
expect_red "NEW DRIFT: a top-level subject is deleted from the index, not misread as a sibling" \
	"$(run_guard "${A}")" \
	"harness: ${H1}" "harness: ${H2}" \
	"$(ledger_line "${A}" "${C1}" justfile)" \
	"$(ledger_line "${A}" "${C2}" justfile)" \
	"2 new drift"

# --- LEDGERED ---------------------------------------------------------------
stage "${A}"
printf '# edited\n' >>"${A}/src/a/subj1.nim"
printf '%s\n' "$(ledger_line "${A}" "${C1}" src/a/subj1.nim)" >>"${A}/${LEDGER_REL}"
expect_green "LEDGERED: a stale entry with an exact ledger line is accepted and counted" \
	"$(run_guard "${A}")" \
	"3 control file(s), 6 in-repo entries, 1 stale-and-ledgered over 1 control file(s), 3 sibling entries not assessed"

# --- MOVED AGAIN ------------------------------------------------------------
# Same tree as LEDGERED, then the already-stale subject is edited once more.
first="$(ledger_line "${A}" "${C1}" src/a/subj1.nim)"
printf '# edited again\n' >>"${A}/src/a/subj1.nim"
expect_red "MOVED AGAIN: a ledgered subject is edited again" \
	"$(run_guard "${A}")" \
	"MOVED AGAIN" "harness: ${H1}" "subject: src/a/subj1.nim" \
	"${first}" "$(ledger_line "${A}" "${C1}" src/a/subj1.nim)"

# --- PAID: restored ---------------------------------------------------------
# The ledger line is from an edit that has since been reverted: the entry is
# current again, and the line must go.
stage "${A}"
printf '# edited\n' >>"${A}/src/a/subj1.nim"
paid="$(ledger_line "${A}" "${C1}" src/a/subj1.nim)"
printf '%s\n' "${paid}" >>"${A}/${LEDGER_REL}"
git -C "${A}" checkout -q -- src/a/subj1.nim 2>/dev/null ||
	printf 'proc one*() = discard\n' >"${A}/src/a/subj1.nim"
expect_red "PAID: a ledger line for an entry that is current again" \
	"$(run_guard "${A}")" \
	"PAID" "harness: ${H1}" "${paid}"

# --- PAID: no such control file ---------------------------------------------
stage "${A}"
gone="$(printf 'src/a/plat9-gone-mutation-control.sha256\tsrc/a/subj1.nim\t%s\t%s' "${ZEROS}" "${ZEROS}")"
printf '%s\n' "${gone}" >>"${A}/${LEDGER_REL}"
expect_red "PAID: a ledger line naming a control file that is not tracked" \
	"$(run_guard "${A}")" "PAID" "${gone}"

# --- PAID: no such entry ----------------------------------------------------
stage "${A}"
gone="$(printf '%s\tsrc/a/never.nim\t%s\t%s' "${C1}" "${ZEROS}" "${ZEROS}")"
printf '%s\n' "${gone}" >>"${A}/${LEDGER_REL}"
expect_red "PAID: a ledger line naming an entry its control file does not have" \
	"$(run_guard "${A}")" "PAID" "${gone}"

# --- PAID: a sibling entry --------------------------------------------------
# The gate does not grade sibling entries, so a ledger line for one records a
# debt the gate cannot see paid. It is refused rather than carried forever.
stage "${A}"
gone="$(printf '%s\tisonim-gpui/src/isonim_gpui/renderer.nim\t%s\t%s' "${C1}" "${ZEROS}" "${ZEROS}")"
printf '%s\n' "${gone}" >>"${A}/${LEDGER_REL}"
expect_red "PAID: a ledger line naming a sibling entry, which the gate does not assess" \
	"$(run_guard "${A}")" "PAID" "${gone}"

# --- MALFORMED --------------------------------------------------------------
stage "${A}"
printf '%s\tsrc/a/subj1.nim\t%s\n' "${C1}" "${ZEROS}" >>"${A}/${LEDGER_REL}"
expect_red "MALFORMED: a ledger line with three fields" \
	"$(run_guard "${A}")" "MALFORMED LEDGER LINE"

stage "${A}"
printf '%s\tsrc/a/subj1.nim\tnot-a-digest\t%s\n' "${C1}" "${ZEROS}" >>"${A}/${LEDGER_REL}"
expect_red "MALFORMED: a ledger line whose recorded digest is not 64 hex digits" \
	"$(run_guard "${A}")" "MALFORMED LEDGER LINE"

# --- DUPLICATE --------------------------------------------------------------
stage "${A}"
printf '# edited\n' >>"${A}/src/a/subj1.nim"
dup="$(ledger_line "${A}" "${C1}" src/a/subj1.nim)"
printf '%s\n%s\n' "${dup}" "${dup}" >>"${A}/${LEDGER_REL}"
expect_red "DUPLICATE: the same entry ledgered twice" \
	"$(run_guard "${A}")" "DUPLICATE LEDGER LINE"

# --- UNPARSEABLE CONTROL LINE -----------------------------------------------
# A line that is neither prose nor a digest line would be silently skipped,
# and an entry a typo hides is an entry nothing grades.
stage "${A}"
printf 'deadbeef  src/a/subj1.nim\n' >>"${A}/${C1}"
expect_red "UNPARSEABLE: a control line that is neither '#', blank, nor '<sha256>  <path>'" \
	"$(run_guard "${A}")" "UNPARSEABLE CONTROL LINE" "${C1}"

# --- EMPTY DISCOVERY --------------------------------------------------------
stage "${A}"
git -C "${A}" rm -q --cached -- "${C1}" "${C2}" "${C3}"
expect_red "EMPTY: no tracked control file is a failure, not a clean tree" \
	"$(run_guard "${A}")" "found only 0 control file(s)"

# --- FLOOR ------------------------------------------------------------------
# The real invocation passes no override, and the default floor must reject a
# tree with three: a discovery that quietly lost most of its files would
# otherwise grade the rest and pass.
expect_red "FLOOR: the default floor rejects a tree with three control files" \
	"$(run_guard_default "${B}")" "found only 3 control file(s)"

# --- DISCOVERY IS BY TRACKED FILE -------------------------------------------
stage "${A}"
mkdir -p "${A}/src/d"
printf '%s  src/a/subj1.nim\n' "${ZEROS}" >"${A}/src/d/plat4-scratch-mutation-control.sha256"
expect_green "UNTRACKED: an untracked control file is not read" \
	"$(run_guard "${A}")" "3 control file(s)"

# --- NO WRITER --------------------------------------------------------------
# The ledger is edited by a person, deliberately, in the diff a reviewer reads.
# A red run must leave it byte-for-byte as it was, and there is no flag to make
# the gate write it.
stage "${A}"
printf '# edited\n' >>"${A}/src/a/subj1.nim"
before="$(sha "${A}/${LEDGER_REL}")"
run_guard "${A}" >/dev/null
if [ "$(sha "${A}/${LEDGER_REL}")" = "${before}" ]; then
	ok "NO WRITER: a red run leaves the ledger untouched"
else
	bad "NO WRITER: the gate modified the ledger"
fi
bash "${guard}" --root "${A}" --update-ledger >/dev/null 2>&1
rc=$?
if [ "${rc}" -eq 2 ] && [ "$(sha "${A}/${LEDGER_REL}")" = "${before}" ]; then
	ok "NO WRITER: an unknown flag (--update-ledger) is refused with exit 2"
else
	bad "NO WRITER: --update-ledger was not refused with exit 2 (rc=${rc})"
fi

echo
echo "${checks} check(s), ${failures} failure(s)"
if [ "${failures}" -gt 0 ]; then
	echo "RESULT: FAILED — every arm must be killed by the rule written for it"
	exit 1
fi
echo "RESULT: OK"
