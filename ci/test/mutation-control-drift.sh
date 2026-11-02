#!/usr/bin/env bash
#
# mutation-control-drift.sh — every mutation harness's control digests agree
# with the tree, or the re-grade they owe is recorded in the ledger.
#
# THE DEFECT
# ----------
# Each comparator harness (`run-plat*-mutations.py`) keeps a
# `*-mutation-control.sha256` beside it: the SHA-256 of every subject its arms
# mutate and of the suite that grades them. It refuses to grade while any
# recorded digest disagrees with the tree (`check_control_hashes()`, then
# `CONTROL DIGEST MOVED ... nothing was mutated`). That refusal is correct. What
# was missing is the other end: the change that EDITS a digested subject was
# told nothing, so the staleness surfaced only when somebody next tried to run
# the harness. 6 harnesses carried stale entries on 2026-09-20; on 2026-10-21 it
# was 30 of the 49 control files, including every harness covering the native
# front-ends' parity (codetracer-pm issue 2026-10-21, "30 of 49 mutation-control
# digest files are stale on agents"). Each stale entry is a commit that disabled
# a harness without seeing it.
#
# WHAT THIS GATE DOES (codetracer-pm Verification-Harness-Traps §39c)
# -------------------------------------------------------------------
# It reads every TRACKED `*-mutation-control.sha256`, takes each digest line
# (`<sha256>  <path>`; `#` lines and blank lines are prose), and compares the
# recorded digest with the SHA-256 of the subject's raw bytes in the working
# tree — the comparison each harness's `digest()` makes. An in-repo entry whose
# file does not exist is drift too: the harness cannot read it either.
#
# An entry that names a SIBLING checkout (`isonim-gpui/…`, `../<repo>/…`,
# `<repo>:…` — a path with a '/' or ':' whose first component is not tracked
# here) depends on which checkout the harness is pointed at. It is counted as
# NOT ASSESSED, each one is printed by name, and it is not graded.
#
# THE LEDGER IS NOT A RE-RECORD, AND NOT AN EXEMPTION
# ---------------------------------------------------
# Stale entries that already exist are listed in
# ci/test/mutation-control-drift.known-stale.txt, one line per entry:
#
#     <control file><TAB><subject><TAB><recorded digest><TAB><current digest>
#
# A line asserts nothing about the subject's bytes having been reviewed; it
# records a re-grade that is OWED (§39a). It fails in BOTH directions, like
# ci/test/shell-gate-coverage.known-dark.txt and
# ci/test/grep-q-pipefail.known-remaining.txt:
#
#   NEW DRIFT    an entry is stale and no ledger line names it. The change that
#                edited the subject sees here which harnesses it owes.
#   MOVED AGAIN  a ledger line names the entry, but the subject (or the record)
#                is not at the digests the line records. Every further edit of
#                an already-stale subject is surfaced, not only the first.
#   PAID         a ledger line describes an entry that is current again (the
#                owner re-graded and re-recorded it by §39b, or the edit was
#                reverted) or that no longer exists. Delete the line, so the
#                ledger cannot outlive the debt.
#
# A change settles NEW DRIFT / MOVED AGAIN either by the harness owner's
# re-grade (§39b's order), or by adding or updating the ledger line in the same
# diff, where a reviewer sees which harnesses it left owing. NEVER by running a
# harness's `--record-control-hashes` to make this gate green: that is §39a's
# violation — an assertion that unreviewed bytes are reviewed — whichever change
# runs it.
#
# THERE IS NO WRITER. The gate never edits the ledger and has no flag to; its
# failure output prints the exact line to add, replace or delete, so every
# ledger change is a deliberate edit in a reviewed diff.
#
# NOT VACUOUS. Fewer than --min-controls tracked control files (default 40; the
# tree had 49 on 2026-10-22) fails: a discovery that lost its files would grade
# what was left and pass. Zero always fails.
#
# Run:  bash ci/test/mutation-control-drift.sh [--root DIR] [--min-controls=N]
#       (`--root` and `--min-controls` exist for the contract suite,
#       ci/test/mutation-control-drift-test.sh, which drives this script
#       against synthetic repositories.)
# Exit: 0 clean, 1 drift or a ledger problem, 2 could not run.

set -uo pipefail

usage() {
	echo "usage: $0 [--root DIR] [--min-controls=N]" >&2
}

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
min_controls=40
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		[ $# -ge 2 ] || {
			usage
			exit 2
		}
		root="$2"
		shift 2
		;;
	--root=*)
		root="${1#--root=}"
		shift
		;;
	--min-controls=*)
		min_controls="${1#--min-controls=}"
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "mutation-control-drift: unknown argument '$1' — refusing (this gate has no writer mode)" >&2
		usage
		exit 2
		;;
	esac
done

if ! [[ ${min_controls} =~ ^[1-9][0-9]*$ ]]; then
	echo "mutation-control-drift: --min-controls must be a positive integer, got '${min_controls}'" >&2
	exit 2
fi

cd "${root}" || exit 2
if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
	echo "mutation-control-drift: ${root} is not a git work tree" >&2
	exit 2
fi

LEDGER="ci/test/mutation-control-drift.known-stale.txt"
HEX64='^[0-9a-f]{64}$'

failures=0
n_new=0
n_moved=0
n_paid=0
n_format=0

ok() { echo "  [OK]     $*"; }
bad() {
	echo "  [FAILED] $*"
	failures=$((failures + 1))
}
detail() { echo "             $*"; }

echo "=== mutation-harness control digests agree with the tree, or the owed re-grade is ledgered ==="
echo

# ---------------------------------------------------------------------------
# STEP 1: discovery, and the floor that keeps it from passing vacuously.
# ---------------------------------------------------------------------------
echo "Step 1: there are control files to read"

controls=()
while IFS= read -r c; do
	[ -n "${c}" ] && controls+=("${c}")
done < <(git -c core.quotePath=false ls-files -- '*-mutation-control.sha256')

if [ "${#controls[@]}" -lt "${min_controls}" ]; then
	bad "found only ${#controls[@]} control file(s); expected at least ${min_controls}"
	detail "A discovery that lost its files would grade what is left and pass, so this is"
	detail "a failure, not a clean tree. (git ls-files -- '*-mutation-control.sha256')"
	echo
	echo "RESULT: FAILED — the control-file list is implausible, so nothing below is evidence"
	exit 1
fi
ok "${#controls[@]} tracked control file(s)"
echo

# The first path components git tracks here. An entry whose first component is
# not one of them names a sibling checkout.
declare -A tracked_top=()
while IFS= read -r p; do
	tracked_top["${p%%/*}"]=1
done < <(git -c core.quotePath=false ls-files)

#
# A path with neither '/' nor ':' (`justfile`) cannot name a sibling checkout —
# every sibling spelling has a repository component — so it is always in-repo.
# Without that rule, deleting a top-level subject would make its first component
# untracked and quietly turn the entry into "not assessed" instead of drift.
is_sibling() {
	local p="$1"
	case "${p}" in
	/* | ../* | */../* | .. | */..) return 0 ;;
	*/* | *:*) ;;
	*) return 1 ;;
	esac
	[ -z "${tracked_top["${p%%/*}"]+x}" ]
}

# The harness that owns a control file: every `run-plat*-mutations.py` in the
# same directory whose source names the control file. Looked up by NAME rather
# than by directory, because one directory holds dozens of harnesses.
declare -A harness_of=()
harness_for() {
	local c="$1" dir base h found=""
	dir="$(dirname "${c}")"
	base="$(basename "${c}")"
	for h in "${dir}"/run-plat*-mutations.py; do
		[ -f "${h}" ] || continue
		if grep -qF -- "${base}" "${h}"; then
			found="${found:+${found}, }${h}"
		fi
	done
	if [ -z "${found}" ]; then
		found="(no run-plat*-mutations.py in ${dir} names this control file)"
	fi
	harness_of["${c}"]="${found}"
}

declare -A digest_cache=()
current_digest() {
	local p="$1"
	if [ -z "${digest_cache["${p}"]+x}" ]; then
		if [ -f "${p}" ]; then
			digest_cache["${p}"]="$(sha256sum -- "${p}" | cut -d' ' -f1)"
		else
			digest_cache["${p}"]="absent"
		fi
	fi
	printf '%s' "${digest_cache["${p}"]}"
}

# ---------------------------------------------------------------------------
# STEP 2: read every control file.
# ---------------------------------------------------------------------------
echo "Step 2: every control file parses"

# Keyed `<control><TAB><subject>`, in-repo entries only.
declare -A entry_recorded=()
declare -A entry_current=()
declare -A sibling_key=()
sibling_list=()
entry_keys=()
n_sibling=0
TAB=$'\t'

for c in "${controls[@]}"; do
	harness_for "${c}"
	if [ ! -f "${c}" ]; then
		bad "UNPARSEABLE CONTROL LINE: ${c} is tracked but missing from the working tree"
		n_format=$((n_format + 1))
		continue
	fi
	lineno=0
	while IFS= read -r line || [ -n "${line}" ]; do
		lineno=$((lineno + 1))
		line="${line%$'\r'}"
		[[ ${line} =~ ^[[:space:]]*$ ]] && continue
		[[ ${line} =~ ^[[:space:]]*# ]] && continue
		if ! [[ ${line} =~ ^([0-9a-f]{64})[[:space:]]+(.*[^[:space:]])[[:space:]]*$ ]]; then
			bad "UNPARSEABLE CONTROL LINE: ${c}:${lineno}"
			detail "${line}"
			detail "A line is prose ('#'), blank, or '<sha256>  <path>'. Anything else is an"
			detail "entry nothing can grade."
			n_format=$((n_format + 1))
			continue
		fi
		recorded="${BASH_REMATCH[1]}"
		subject="${BASH_REMATCH[2]}"
		key="${c}${TAB}${subject}"
		if is_sibling "${subject}"; then
			sibling_key["${key}"]=1
			sibling_list+=("${c}: ${subject}")
			n_sibling=$((n_sibling + 1))
			continue
		fi
		if [ -n "${entry_recorded["${key}"]+x}" ]; then
			bad "UNPARSEABLE CONTROL LINE: ${c}:${lineno} digests ${subject} a second time"
			n_format=$((n_format + 1))
			continue
		fi
		entry_recorded["${key}"]="${recorded}"
		entry_current["${key}"]="$(current_digest "${subject}")"
		entry_keys+=("${key}")
	done <"${c}"
done
if [ "${n_format}" -eq 0 ]; then
	ok "${#entry_keys[@]} in-repo entries, ${n_sibling} sibling entries not assessed"
fi
# Named, not only counted: an in-repo subject misread as a sibling (its whole
# top-level directory deleted, say) would otherwise vanish into the count.
for s in "${sibling_list[@]}"; do
	detail "not assessed: ${s}"
done
echo

# ---------------------------------------------------------------------------
# STEP 3: read the ledger.
# ---------------------------------------------------------------------------
echo "Step 3: the ledger parses"

declare -A ledger_recorded=()
declare -A ledger_current=()
declare -A ledger_line=()
ledger_keys=()
if [ -f "${LEDGER}" ]; then
	lineno=0
	while IFS= read -r line || [ -n "${line}" ]; do
		lineno=$((lineno + 1))
		line="${line%$'\r'}"
		[[ ${line} =~ ^[[:space:]]*$ ]] && continue
		[[ ${line} =~ ^[[:space:]]*# ]] && continue
		tabs="${line//[^$'\t']/}"
		IFS="${TAB}" read -r l_control l_subject l_recorded l_current <<<"${line}"
		if [ "${#tabs}" -ne 3 ] || [ -z "${l_control}" ] || [ -z "${l_subject}" ] ||
			! [[ ${l_recorded} =~ ${HEX64} ]] ||
			! [[ ${l_current} =~ ${HEX64} || ${l_current} == "absent" ]]; then
			bad "MALFORMED LEDGER LINE: ${LEDGER}:${lineno}"
			detail "${line}"
			detail "Wanted: <control><TAB><subject><TAB><recorded sha256><TAB><current sha256 | absent>"
			n_format=$((n_format + 1))
			continue
		fi
		key="${l_control}${TAB}${l_subject}"
		if [ -n "${ledger_line["${key}"]+x}" ]; then
			bad "DUPLICATE LEDGER LINE: ${LEDGER}:${lineno} names ${l_subject} in ${l_control} again"
			detail "Keep one line per entry; delete this one."
			n_format=$((n_format + 1))
			continue
		fi
		ledger_recorded["${key}"]="${l_recorded}"
		ledger_current["${key}"]="${l_current}"
		ledger_line["${key}"]="${line}"
		ledger_keys+=("${key}")
	done <"${LEDGER}"
	ok "${LEDGER} records ${#ledger_keys[@]} owed re-grade(s)"
else
	ok "${LEDGER} does not exist — no stale entry is ledgered"
fi
echo

# `report CLASS KEY` prints the control, its harness and the subject.
report() {
	local class="$1" key="$2" c s
	c="${key%%"${TAB}"*}"
	s="${key#*"${TAB}"}"
	bad "${class}"
	detail "control: ${c}"
	detail "harness: ${harness_of["${c}"]:-(control file not tracked)}"
	detail "subject: ${s}"
}

# ---------------------------------------------------------------------------
# STEP 4: every stale in-repo entry is ledgered at exactly its digests.
# ---------------------------------------------------------------------------
echo "Step 4: every in-repo entry is current, or its owed re-grade is ledgered"

n_ledgered=0
declare -A ledgered_controls=()
for key in "${entry_keys[@]}"; do
	recorded="${entry_recorded["${key}"]}"
	current="${entry_current["${key}"]}"
	[ "${recorded}" = "${current}" ] && continue
	want="${key}${TAB}${recorded}${TAB}${current}"
	if [ -z "${ledger_line["${key}"]+x}" ]; then
		report "NEW DRIFT" "${key}"
		detail "recorded ${recorded}"
		detail "tree now ${current}"
		detail "This change leaves that harness owing a re-grade. Either its owner re-grades"
		detail "it in §39b's order, or add this line to ${LEDGER}:"
		printf '%s\n' "${want}"
		detail "Do NOT run --record-control-hashes to clear this (§39a)."
		n_new=$((n_new + 1))
	elif [ "${ledger_recorded["${key}"]}" != "${recorded}" ] ||
		[ "${ledger_current["${key}"]}" != "${current}" ]; then
		report "MOVED AGAIN" "${key}"
		detail "The ledgered subject (or its record) moved since the line was written."
		detail "A re-grade must re-run the arms whose needles sit in it. Replace the line"
		detail "in ${LEDGER}:"
		printf -- '- %s\n' "${ledger_line["${key}"]}"
		printf -- '+ %s\n' "${want}"
		n_moved=$((n_moved + 1))
	else
		n_ledgered=$((n_ledgered + 1))
		ledgered_controls["${key%%"${TAB}"*}"]=1
	fi
done
if [ "${n_new}" -eq 0 ] && [ "${n_moved}" -eq 0 ]; then
	ok "no unledgered drift; ${n_ledgered} stale entr(y/ies) ledgered at their exact digests"
fi
echo

# ---------------------------------------------------------------------------
# STEP 5: every ledger line still describes a debt.
# ---------------------------------------------------------------------------
echo "Step 5: every ledger line is still owed"

for key in "${ledger_keys[@]}"; do
	if [ -n "${sibling_key["${key}"]+x}" ]; then
		report "PAID — the line names a sibling entry, which this gate does not assess" "${key}"
	elif [ -z "${entry_recorded["${key}"]+x}" ]; then
		report "PAID — no tracked control file has this entry any more" "${key}"
	elif [ "${entry_recorded["${key}"]}" = "${entry_current["${key}"]}" ]; then
		report "PAID — the entry is current again (re-graded and re-recorded, or reverted)" "${key}"
	else
		continue
	fi
	detail "Delete this line from ${LEDGER}:"
	printf -- '- %s\n' "${ledger_line["${key}"]}"
	n_paid=$((n_paid + 1))
done
if [ "${n_paid}" -eq 0 ]; then
	ok "every ledger line names an entry that is still stale"
fi

# ---------------------------------------------------------------------------
echo
if [ "${failures}" -eq 0 ]; then
	echo "RESULT: OK — ${#controls[@]} control file(s), ${#entry_keys[@]} in-repo entries," \
		"${n_ledgered} stale-and-ledgered over ${#ledgered_controls[@]} control file(s)," \
		"${n_sibling} sibling entries not assessed"
	exit 0
fi
echo "RESULT: FAILED — ${n_new} new drift, ${n_moved} moved again, ${n_paid} paid," \
	"${n_format} unparseable/malformed/duplicate line(s)"
exit 1
