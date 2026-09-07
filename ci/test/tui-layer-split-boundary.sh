#!/usr/bin/env bash
#
# tui-layer-split-boundary.sh — PLAT-6's residue, closed: the TUI's
# decide/perform split, ENFORCED rather than described.
#
# WHY THIS EXISTS
# ---------------
# `src/frontend/tui/` is built on one rule, stated in `app/cli.nim`'s header and
# worked twice: the DECISION lives in `app/` and the EFFECT lives in `host/`.
#
#   host/capabilities.nim     performs seven `getEnv`s and an `isatty`, and hands
#                             a `TerminalEnv` VALUE to
#   app/theme/capabilities.nim  which decides what a colour depth is without ever
#                             asking the environment anything.
#
#   host/layout_store.nim     performs the `getEnv`, the `readFile`, the atomic
#                             write and the remove, and hands the BYTES to
#   app/layout/persistence.nim  which decides the document's name, what an
#                             unreadable one means, and whether there is anything
#                             to write at all.
#
# That split is not decoration. It is why the interesting half of each pair is
# assertable at Tier 1 with no filesystem — every arm a value in and a value out
# — and why `app/tests/` can hold a suite for it at all.
#
# **AND UNTIL THIS FILE EXISTED IT WAS A FACT, NOT AN ENFORCED ONE.** PLAT-6's
# verification pass recorded exactly that:
#
#     `persistence.nim`'s header says "this module imports no `std/os`" and
#     nothing checks it: `test_tui_facade_boundary.nim`'s forbidden list under
#     `app/` is `std/osproc`, `std/posix` and `host/` imports — `std/os` is
#     LEGAL there — and the persistence suite makes no source scan.
#
# The consequence of a violation is slow rather than sharp: nothing breaks on
# the day somebody adds `import std/os` and one `readFile`. What happens is that
# the decision layer stops being assertable without a filesystem, which is the
# whole reason the split exists, and the Tier-1 suite that was a table of values
# becomes a suite that needs a sandbox. By the time anyone notices, the reason is
# several commits old.
#
# WHAT THIS GATE COVERS, AND WHAT IT DOES NOT (Verification-Harness-Traps §6)
# --------------------------------------------------------------------------
# `DECIDERS` below is this gate's claim about what the population IS, and it is
# a SHORT list on purpose. It is NOT "everything under `app/`", and that is
# measured rather than assumed: `app/input/keymap.nim` genuinely imports
# `std/os` and genuinely calls `readFile`, because `loadKeymap` layers a user's
# `.cttui-keys` over the built-in table. A blanket ban under `app/` would be red
# on the day it was written, and a gate that is red on arrival gets switched off.
#
# So the subject is the DECISION HALF OF A DECLARED PAIR: a module whose own
# header says it does no I/O because a named `host/` module does it instead.
# Adding a pair to this product means adding it here by hand, and the count is
# asserted so a rename or a deletion reddens this gate rather than silently
# shrinking it.
#
# `keymap.nim` is not merely excluded — it is USED, as check 4's positive
# control. The same ban predicate is run over it and is REQUIRED to fire. A
# blocklist that has stopped matching anything passes every "must not contain"
# rule it makes (§4), and a real file under the very directory being scanned is
# the cheapest thing that can prove it still matches.
#
# THE PROSE PROBLEM, WHICH IS THE INTERESTING HALF (§4d)
# ------------------------------------------------------
# Every module on this list DOCUMENTS the I/O it does not do.
# `persistence.nim`'s header contains the sentence "that module is where
# `getEnv`, `readFile` and `removeFile` live", and the module it names is the
# performer. So a call-site scan that matched vocabulary rather than syntax
# would fire on the module's own explanation of why it is clean — the §4d shape,
# pointing the other way.
#
# Comments are therefore stripped before the call-site scan, and BOTH halves of
# that are checked (check 6): the raw text must contain the names in prose, and
# the stripped text must not. If the stripper broke, check 6's first half would
# go red rather than check 2 going quietly green over an emptied file.
#
# WHERE THE CONTROLS LIVE
# -----------------------
# `sdk-facade-boundary.sh` and `value-presentation-boundary.sh` each have a
# sibling `-test.sh` contract suite that drives them over synthetic trees. This
# gate carries its controls INSIDE it instead — checks 3, 4, 5 and 6 — because
# every one of them can be run against the real tree: `keymap.nim` really does
# import `std/os`, the two performers really do call the routines the deciders
# must not, and `persistence.nim` really does name those routines in prose. A
# control that runs on every invocation of the gate is stronger than one that
# runs in a suite somebody has to remember to run, and it cannot drift away from
# the gate it controls. `--root` is still accepted so a contract suite can be
# added later without changing this file.
#
# The four were demonstrated by planting, on 2026-09-08, rather than asserted:
# breaking the import extractor reddens 3 and 4 while 1 and 2 stay green;
# rewriting the call-site boundary into a form the engine will not match reddens
# 5 while 2 stays green. That is the §4a pairing — break the scanner and the
# positive half goes red immediately — shown rather than claimed.
#
# **AND THE PAIRING WAS NOT REAL FOR THE CALL-SITE HALF UNTIL 2026-09-08.** The
# rule (check 2) and its control (check 5) were two literal copies of one regex,
# so breaking only the RULE's copy left all eight checks green — and a `readFile`
# planted in a decider under that break was reported by nobody. §4a's requirement
# is a twin running through the SAME scanner, which is what the import half had
# all along (`forbidden_imports_in`, shared by 1, 3 and 4) and what the call-site
# half only looks like from a distance. Both now go through
# `forbidden_calls_in`; breaking it reddens 5 exactly as breaking `import_names`
# reddens 3 and 4. Found by PLAT-6's verification pass, by breaking one copy.
#
# Usage:
#   ci/test/tui-layer-split-boundary.sh
#   ci/test/tui-layer-split-boundary.sh --root DIR

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TUI="src/frontend/tui"

# THE SUBJECT. One entry per declared decide/perform pair:
#   <decision module>|<performer module>|<what the performer performs>
DECIDERS=(
	"${TUI}/app/theme/capabilities.nim|${TUI}/host/capabilities.nim|the seven getEnvs and the isatty"
	"${TUI}/app/layout/persistence.nim|${TUI}/host/layout_store.nim|the getEnv, the read, the atomic write and the remove"
)
DECIDER_COUNT=2

# A module every decider must still be able to import, one per decider, in the
# order above. Check 3 requires the extractor to FIND it — a positive twin for
# the negative scan in check 1, running through the same extraction, so a
# broken extractor goes red here instead of passing check 1 vacuously (§4a).
DECIDER_EXPECTED_IMPORT=(
	"strutils"
	"json"
)

# THE CONTROL FILE. A real module under the same `app/` directory tree that
# genuinely does the thing the deciders must not, so the ban can be shown to
# fire on something other than a planted string. `loadKeymap` layers a user's
# `.cttui-keys` file over the built-in table; the I/O is deliberate and is
# documented in that module's own header.
BAN_CONTROL="${TUI}/app/input/keymap.nim"

# Effectful stdlib modules a decision layer must not reach. `os` is the one this
# gate was written for; the rest are here because "no I/O" is the claim, not "no
# `std/os`", and a module that reached `std/streams` or `std/dynlib` instead
# would satisfy a one-name blocklist while breaking the same property.
FORBIDDEN_MODULES='os|osproc|posix|envvars|files|dirs|paths|cmdline|dynlib|net|httpclient|streams|memfiles|selectors|asyncdispatch|asyncfile'

# I/O the deciders must not perform, as CALL SITES rather than as imports — a
# module reached through a re-export would satisfy check 1 and fail the
# property. POSIX ERE, with the boundary spelled `[^[:alnum:]_]` rather than
# `\b` for the reason §4 gives: the engine is part of the scanner.
#
# THE LEADING BOUNDARY ADMITS A DOT, because `path.readFile` and
# `path.fileExists` are the ordinary Nim call spellings and excluding `.` would
# leave the gate catching only the form nobody writes — the exact defect
# `value-presentation-boundary.sh`'s contract suite found in its own blocklist.
FORBIDDEN_CALLS=(
	'getEnv'
	'putEnv'
	'existsEnv'
	'readFile'
	'writeFile'
	'removeFile'
	'moveFile'
	'copyFile'
	'fileExists'
	'dirExists'
	'createDir'
	'removeDir'
	'walkDir'
	'walkDirRec'
	'getHomeDir'
	'getCurrentDir'
	'open'
	'execCmd'
	'execCmdEx'
	'startProcess'
)

# The names check 6 requires to be present in PROSE and absent from CODE, in the
# decider that documents them. Both halves are asserted; see the header.
PROSE_PROBE_FILE="${TUI}/app/layout/persistence.nim"
PROSE_PROBE_NAMES=('getEnv' 'readFile' 'removeFile')

# ---------------------------------------------------------------------------

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		shift
		root="$1"
		;;
	*)
		echo "tui-layer-split-boundary.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done
cd "${root}" || exit 2

failures=0
checks_run=0

check_ok() {
	checks_run=$((checks_run + 1))
	echo "  OK        $1"
}

check_failed() {
	checks_run=$((checks_run + 1))
	failures=$((failures + 1))
	echo "  VIOLATION $1"
}

detail() { echo "              $1"; }

# code_lines FILE — the file with `#[ … ]#` blocks, doc comments and trailing
# comments removed, so a rule naming an I/O routine does not fire on the
# module's own explanation of why it does not call it (§4d).
code_lines() {
	sed -e 's/#\[.*\]#//g' -e 's/[[:space:]]*##\?.*$//' "$1" 2>/dev/null
}

# import_names FILE — every module name an `import` / `from` / `include` line
# names, one per line. `std/[a, b]`, `std/a`, `./rel`, `../up/mod` all reduce to
# their last path component, which is what the blocklists are written against;
# `from std/os import readFile` reduces to `os`, and `import std/os as myos` to
# `os`, so neither spelling is a way past check 1. Each of those four forms is
# exercised by check 3's expected-import assertion or by check 4's control.
import_names() {
	grep -hE '^[[:space:]]*(import|from|include)[[:space:]]' "$1" 2>/dev/null |
		sed -e 's/[[:space:]]*#.*$//' \
			-e 's/^[[:space:]]*\(import\|from\|include\)[[:space:]]*//' \
			-e 's/[[:space:]]\+import[[:space:]].*$//' |
		tr '[],' '\n' |
		sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
			-e 's#.*/##' \
			-e 's/[[:space:]].*$//' |
		grep -vE '^$'
}

# forbidden_imports_in FILE — the forbidden module names FILE imports, if any.
forbidden_imports_in() {
	import_names "$1" | grep -xE "${FORBIDDEN_MODULES}" || true
}

# forbidden_calls_in FILE — every forbidden I/O call site in FILE's CODE, as
# `<line>:<routine>`, one per line.
#
# **ONE FUNCTION, CALLED BY THE RULE AND BY ITS CONTROL, and that is the whole
# reason it is a function.** Check 2 asserts the deciders yield nothing here and
# check 5 asserts the performers yield something; §4a's rule is that a
# "must not contain" is only self-controlling when its positive twin runs
# through the SAME scanner. Written as two copies of this regex — one in each
# check — the gate passed a planted `readFile` in a decider with all eight
# checks green, because breaking the rule's copy left the control's copy intact
# and agreeing with itself. Measured on 2026-09-08 by PLAT-6's verification
# pass; the two copies are now this one.
forbidden_calls_in() {
	local body
	body="$(code_lines "$1")"
	local name
	for name in "${FORBIDDEN_CALLS[@]}"; do
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			printf '%s:%s\n' "${hit%%:*}" "${name}"
		done < <(grep -nE "(^|[^[:alnum:]_])${name}[[:space:]]*\(" <<<"${body}" || true)
	done
}

echo "=== tui-layer-split-boundary: the decision layer does no I/O ==="
echo ""

# ---------------------------------------------------------------------------
# 0. The subject exists, and it is the size this gate claims (§6, §4b).
# ---------------------------------------------------------------------------

subject_seen=0
subject_missing=()
for entry in "${DECIDERS[@]}"; do
	decider="${entry%%|*}"
	rest="${entry#*|}"
	performer="${rest%%|*}"
	if [ -f "${decider}" ] && [ -f "${performer}" ]; then
		subject_seen=$((subject_seen + 1))
	else
		[ -f "${decider}" ] || subject_missing+=("decider ${decider}")
		[ -f "${performer}" ] || subject_missing+=("performer ${performer}")
	fi
done
if [ "${subject_seen}" -eq "${DECIDER_COUNT}" ]; then
	check_ok "subject-complete: all ${DECIDER_COUNT} declared decide/perform pairs exist"
else
	check_failed "subject-complete: ${subject_seen} of ${DECIDER_COUNT} declared pairs exist"
	for m in "${subject_missing[@]}"; do detail "missing: ${m}"; done
	detail "A gate that scans fewer files than it claims answers a smaller question than it appears to."
fi

if [ -f "${BAN_CONTROL}" ]; then
	check_ok "control-present: ${BAN_CONTROL} is available as the positive control"
else
	check_failed "control-present: ${BAN_CONTROL} is missing"
	detail "Checks 4 and 5 cannot run, so checks 1 and 2 establish nothing: an empty scan passes every 'must not contain' rule."
fi

# ---------------------------------------------------------------------------
# 1. No decider imports an effectful module, or reaches across into `host/`.
# ---------------------------------------------------------------------------

import_findings=()
scanned_imports=0
for entry in "${DECIDERS[@]}"; do
	decider="${entry%%|*}"
	[ -f "${decider}" ] || continue
	scanned_imports=$((scanned_imports + 1))
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		import_findings+=("${decider}: imports \`${name}\` -- the effect belongs in the performer")
	done < <(forbidden_imports_in "${decider}")
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		import_findings+=("${decider}:${hit} -- reaches into host/, which inverts the split")
	done < <(grep -nE '^[[:space:]]*(import|from|include)[[:space:]].*(^|[^[:alnum:]_])host/' \
		"${decider}" || true)
done
if [ "${scanned_imports}" -ne "${DECIDER_COUNT}" ]; then
	check_failed "no-io-import: scanned ${scanned_imports} of ${DECIDER_COUNT} deciders"
	detail "Universal quantification over a reduced set is satisfied by every member it still has (§4b)."
elif [ "${#import_findings[@]}" -eq 0 ]; then
	check_ok "no-io-import: ${scanned_imports} decider(s), no effectful import, no host/ import"
else
	check_failed "no-io-import: ${#import_findings[@]} finding(s) over ${scanned_imports} decider(s)"
	for f in "${import_findings[@]}"; do detail "${f}"; done
	detail "The decision layer's whole value is that it is assertable with no filesystem."
fi

# ---------------------------------------------------------------------------
# 2. No decider CALLS an I/O routine, over comment-stripped source.
# ---------------------------------------------------------------------------

call_findings=()
scanned_calls=0
for entry in "${DECIDERS[@]}"; do
	decider="${entry%%|*}"
	[ -f "${decider}" ] || continue
	scanned_calls=$((scanned_calls + 1))
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		call_findings+=("${decider}: \`${hit#*:}\` on line ${hit%%:*}")
	done < <(forbidden_calls_in "${decider}")
done
if [ "${scanned_calls}" -ne "${DECIDER_COUNT}" ]; then
	check_failed "no-io-callsite: scanned ${scanned_calls} of ${DECIDER_COUNT} deciders"
elif [ "${#call_findings[@]}" -eq 0 ]; then
	check_ok "no-io-callsite: ${scanned_calls} decider(s), none of ${#FORBIDDEN_CALLS[@]} I/O routines is called"
else
	check_failed "no-io-callsite: ${#call_findings[@]} finding(s) over ${scanned_calls} decider(s)"
	for f in "${call_findings[@]}"; do detail "${f}"; done
	detail "An import lint alone would miss a routine reached through a re-export."
fi

# ---------------------------------------------------------------------------
# 3. THE EXTRACTOR READS CODE — the positive twin for check 1 (§4a).
#
# Each decider's import set must be non-empty AND must contain the module named
# in `DECIDER_EXPECTED_IMPORT`. An extractor that had stopped parsing import
# lines would produce an empty set, and an empty set satisfies check 1
# completely.
# ---------------------------------------------------------------------------

extractor_findings=()
extractor_seen=0
for i in "${!DECIDERS[@]}"; do
	entry="${DECIDERS[$i]}"
	decider="${entry%%|*}"
	want="${DECIDER_EXPECTED_IMPORT[$i]}"
	[ -f "${decider}" ] || continue
	extractor_seen=$((extractor_seen + 1))
	names="$(import_names "${decider}")"
	# HERE-STRINGS, NOT PIPELINES, into `grep`: `ci/test/grep-q-pipefail-gate.sh`
	# bans a producer piped into `grep -q` because a successful match can be
	# reported as a failure when the producer is still writing as grep exits.
	n="$(grep -c . <<<"${names}" || true)"
	if [ "${n}" -eq 0 ]; then
		extractor_findings+=("${decider}: the import extractor found NOTHING")
	elif ! grep -qxF -- "${want}" <<<"${names}"; then
		extractor_findings+=("${decider}: extracted ${n} import(s) but not \`${want}\`; got: $(tr '\n' ' ' <<<"${names}")")
	fi
done
if [ "${extractor_seen}" -ne "${DECIDER_COUNT}" ]; then
	check_failed "import-extractor-reads-code: reached ${extractor_seen} of ${DECIDER_COUNT} deciders"
elif [ "${#extractor_findings[@]}" -eq 0 ]; then
	check_ok "import-extractor-reads-code: every decider's imports were extracted and the expected one was found"
else
	check_failed "import-extractor-reads-code: ${#extractor_findings[@]} finding(s)"
	for f in "${extractor_findings[@]}"; do detail "${f}"; done
	detail "Without this, check 1 is a negative assertion over a set the scanner never built."
fi

# ---------------------------------------------------------------------------
# 4. THE BAN FIRES ON A REAL FILE — the positive control for check 1.
#
# `keymap.nim` genuinely imports `std/os`. The same predicate check 1 uses is
# run over it and is REQUIRED to report a violation. If a future edit made the
# blocklist, the extractor or the boundary form stop matching, this check goes
# red and check 1's silence stops being evidence.
# ---------------------------------------------------------------------------

if [ ! -f "${BAN_CONTROL}" ]; then
	check_failed "ban-fires: the control file is missing, so nothing was demonstrated"
else
	control_hits="$(forbidden_imports_in "${BAN_CONTROL}")"
	control_n="$(grep -c . <<<"${control_hits}" || true)"
	if [ "${control_n}" -ge 1 ]; then
		check_ok "ban-fires: the same predicate reports ${control_n} forbidden import(s) in ${BAN_CONTROL} ($(tr '\n' ' ' <<<"${control_hits}"))"
	else
		check_failed "ban-fires: the predicate found NO forbidden import in ${BAN_CONTROL}"
		detail "That file imports std/os and calls readFile; a predicate that cannot see it cannot see one in a decider either."
		detail "Check 1's clean result is not evidence while this is red."
	fi
fi

# ---------------------------------------------------------------------------
# 5. THE CALL-SITE SCANNER READS CODE — the positive control for check 2.
#
# Run over the PERFORMER of each pair, which exists precisely to make these
# calls. Every performer must yield at least one hit, and the count is asserted
# against the number of performers rather than "at least one somewhere", for
# the reason §4b gives: an existential control is satisfied by one member of a
# set of any size.
# ---------------------------------------------------------------------------

performers_hit=0
performers_seen=0
performer_misses=()
for entry in "${DECIDERS[@]}"; do
	rest="${entry#*|}"
	performer="${rest%%|*}"
	[ -f "${performer}" ] || continue
	performers_seen=$((performers_seen + 1))
	# THROUGH `forbidden_calls_in`, the same function check 2 uses. See its
	# header: a control that is a second copy of the rule's regex is not a
	# control at all.
	hits="$(grep -c . <<<"$(forbidden_calls_in "${performer}")" || true)"
	if [ "${hits}" -ge 1 ]; then
		performers_hit=$((performers_hit + 1))
	else
		performer_misses+=("${performer}: the call-site scanner found no I/O call in the module that performs it")
	fi
done
if [ "${performers_seen}" -eq "${DECIDER_COUNT}" ] &&
	[ "${performers_hit}" -eq "${DECIDER_COUNT}" ]; then
	check_ok "callsite-scanner-reads-code: all ${DECIDER_COUNT} performers yield I/O call sites"
else
	check_failed "callsite-scanner-reads-code: ${performers_hit} of ${DECIDER_COUNT} performers yielded a hit (${performers_seen} scanned)"
	for f in "${performer_misses[@]}"; do detail "${f}"; done
	detail "Check 2's clean result is not evidence while this is red."
fi

# ---------------------------------------------------------------------------
# 6. PROSE IS NOT CODE, IN BOTH DIRECTIONS (§4d).
#
# `persistence.nim`'s header names `getEnv`, `readFile` and `removeFile` while
# explaining that a different module calls them. The raw file must contain each
# of those names — otherwise the discrimination below is being demonstrated over
# a file that has nothing to discriminate — and the comment-stripped file must
# contain none of them.
# ---------------------------------------------------------------------------

if [ ! -f "${PROSE_PROBE_FILE}" ]; then
	check_failed "prose-is-not-code: ${PROSE_PROBE_FILE} is missing"
else
	raw_missing=()
	stripped_present=()
	stripped="$(code_lines "${PROSE_PROBE_FILE}")"
	for name in "${PROSE_PROBE_NAMES[@]}"; do
		if ! grep -qE "(^|[^[:alnum:]_])${name}([^[:alnum:]_]|$)" "${PROSE_PROBE_FILE}"; then
			raw_missing+=("${name}")
		fi
		if grep -qE "(^|[^[:alnum:]_])${name}([^[:alnum:]_]|$)" <<<"${stripped}"; then
			stripped_present+=("${name}")
		fi
	done
	if [ "${#raw_missing[@]}" -eq 0 ] && [ "${#stripped_present[@]}" -eq 0 ]; then
		check_ok "prose-is-not-code: ${#PROSE_PROBE_NAMES[@]} name(s) present in ${PROSE_PROBE_FILE}'s prose and absent from its code"
	else
		check_failed "prose-is-not-code: the comment stripper does not discriminate"
		for n in "${raw_missing[@]}"; do
			detail "\`${n}\` is not in ${PROSE_PROBE_FILE} at all -- this control demonstrates nothing"
		done
		for n in "${stripped_present[@]}"; do
			detail "\`${n}\` survives comment stripping -- either the stripper is broken or the module really calls it"
		done
	fi
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

echo ""
if [ "${failures}" -eq 0 ]; then
	echo "tui-layer-split-boundary: ${checks_run} check(s), 0 failing"
	exit 0
fi
echo "tui-layer-split-boundary: ${checks_run} check(s), ${failures} failing"
exit 1
