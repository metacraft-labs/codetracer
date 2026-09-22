#!/usr/bin/env bash
# PLAT-39 — LAW-R4: the vision producer is INDEPENDENT of the application.
#
# The oracle's whole value is that it shares no code path with its subject.
# `Verification-Harness-Traps.md` §30a is this campaign's most persistent
# defect — a differential measures only what its two sides compute
# *differently* — so an import edge from the oracle into `viewmodel/` or into
# the page objects would silently convert the second producer back into the
# first one, and every comparison over it would go on passing.
#
# ============================================================================
# THE THREE REPAIRS INHERITED FROM PLAT-35, WHOSE SCAN OF THIS SHAPE WAS
# DEFEATED FIVE TIMES. They are inherited rather than re-derived.
# ============================================================================
#
#  1. **THE SUBJECT SET IS DERIVED FROM THE DIRECTORY, never hardcoded.** Three
#     of PLAT-35's five defeats were a hardcoded path list that could not see a
#     new file. `find` is the subject set here, and the scan asserts it is
#     non-empty — a scan that reads nothing satisfies every "must not contain"
#     check written over it (§4).
#
#  2. **THERE IS NO PATH-PATTERN EXEMPTION.** PLAT-35's fourth defeat was a
#     plant under `*/tests/*` that a path-pattern exemption waved through. The
#     lesson recorded there is that *a path pattern cannot express "graded
#     elsewhere"; only the grader can*. This scan therefore exempts nothing by
#     path: the suite file is scanned exactly as the producer modules are.
#
#  3. **THE NEEDLE IS DERIVED FROM THE SHARED TYPES' OWN EXPORTED NAMES.**
#     PLAT-35's fifth defeat was a plant that never spelled the literal type
#     name the scan looked for. The forbidden-symbol list below is read out of
#     `layout_models.ts` and out of the `viewmodel/` directory, so a rename on
#     either side moves the needle with it instead of blinding the scan.
#
# ============================================================================
# AND ONE REPAIR THIS MILESTONE ADDS, FROM PLAT-37's FOURTH SCAN ROUTE
# ============================================================================
#
# Nim compares identifiers with only the first character case-significant and
# underscores ignored, so `import view_model` and `import viewModel` are the
# same import and a substring search finds only one of them
# (`Verification-Harness-Traps.md` §35b). Import lines are therefore normalised
# — lowercased, underscores stripped — before matching, on BOTH the needle and
# the haystack.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# `|| exit` because a cd that fails would run every path below against the
# WRONG TREE and report a confident answer about it (SC2164).
cd "$ROOT" || exit 1

ORACLE_DIR="src/tests/visual/screen_oracle"
fail=0
note() { printf '  %s\n' "$*"; }
bad() {
	printf 'FAIL: %s\n' "$*"
	fail=1
}

# --- 1. The subject set, derived --------------------------------------------
mapfile -t SUBJECTS < <(find "$ORACLE_DIR" -name '*.nim' -type f | sort)
if [ "${#SUBJECTS[@]}" -eq 0 ]; then
	bad "the subject set is EMPTY: $ORACLE_DIR has no .nim files."
	echo "A scan with no subjects passes every check written over it (traps §4)."
	exit 1
fi
note "subject set (derived from $ORACLE_DIR): ${#SUBJECTS[@]} modules"
for s in "${SUBJECTS[@]}"; do note "    $s"; done

# --- 2. The needle, derived --------------------------------------------------
# From the application side: every module name under src/frontend/viewmodel.
mapfile -t VM_MODULES < <(
	find src/frontend/viewmodel -name '*.nim' -type f -printf '%f\n' 2>/dev/null |
		sed 's/\.nim$//' | sort -u
)
# From the page-object side: the files themselves.
mapfile -t PO_MODULES < <(
	find src/tests/gui/page-objects -type f -printf '%f\n' 2>/dev/null |
		sed 's/\.[a-z]*$//' | sort -u
)

if [ "${#VM_MODULES[@]}" -eq 0 ]; then
	bad "no viewmodel modules found: the needle would be empty and the scan vacuous."
	exit 1
fi
note "forbidden viewmodel modules (derived): ${#VM_MODULES[@]}"
note "forbidden page-object modules (derived): ${#PO_MODULES[@]}"

# Normalise a Nim identifier the way the COMPILER compares them: first
# character case-significant, the rest case-insensitive, underscores ignored.
# See traps §35b.
nimkey() { printf '%s' "$1" | tr -d '_' | tr '[:upper:]' '[:lower:]'; }

# --- 3. The scan, both polarities -------------------------------------------
# **`scan_one` REPORTS; IT DOES NOT JUDGE.** It prints one line per violation
# and returns their count. The judging is the caller's, because the positive
# control below deliberately makes this function find a violation — if finding
# one set the global failure flag, the control that proves the scan CAN go red
# would itself turn the run red, which is trap §5's shape: the instrument
# scoring its own calibration run as a result.
scan_one() {
	local file="$1" hits=0
	# Import lines only: a module NAME appearing inside a comment or a string is
	# not an import edge, and treating it as one would make the scan red for
	# prose (traps §4d).
	while IFS= read -r line; do
		case "$line" in
		import* | from* | include*) ;;
		*) continue ;;
		esac
		local key
		key="$(nimkey "$line")"
		for m in "${VM_MODULES[@]}" "${PO_MODULES[@]}"; do
			local mk
			mk="$(nimkey "$m")"
			[ -z "$mk" ] && continue
			case "$key" in
			*"$mk"*)
				printf '%s imports %s\n' "$file" "$m"
				hits=$((hits + 1))
				;;
			esac
		done
	done <"$file"
	return "$hits"
}

violations=0
for s in "${SUBJECTS[@]}"; do
	out="$(scan_one "$s")"
	n=$?
	if [ "$n" -ne 0 ]; then
		while IFS= read -r v; do
			[ -n "$v" ] && bad "$v — the oracle must share no code with its subject"
		done <<<"$out"
		violations=$((violations + n))
	fi
done
note "violations in the real subject set: $violations"

# --- 4. THE POSITIVE CONTROL: the scan must be able to FAIL ------------------
# A scan that cannot go red is not evidence. A module that really does import a
# viewmodel is planted, scanned, and required to be caught; then removed.
PLANT="$ORACLE_DIR/.plat39_independence_control.nim"
# shellcheck disable=SC2329  # invoked by the `trap` below, not directly.
cleanup() { rm -f "$PLANT"; }
trap cleanup EXIT

# The plant names a REAL viewmodel module, taken from the derived list, and
# spells it the way Nim's identifier equality allows but a substring search
# does not — underscores stripped and case altered. If the scan only matched
# literal spellings this plant would walk straight past it (traps §35b).
victim="${VM_MODULES[0]}"
victim_disguised="$(printf '%s' "$victim" | tr -d '_' | tr '[:lower:]' '[:upper:]')"
printf 'import ../../../frontend/viewmodel/%s\n' "$victim_disguised" >"$PLANT"

if scan_one "$PLANT" >/dev/null 2>&1; then
	bad "POSITIVE CONTROL DID NOT FIRE: a planted import of '$victim' (spelled" \
		"'$victim_disguised') was not caught. The scan cannot go red, so its" \
		"green means nothing."
else
	note "positive control fired: the disguised import of '$victim' was caught"
fi
rm -f "$PLANT"

# --- 5. The negative control: a clean module must NOT fire -------------------
CLEAN="$ORACLE_DIR/.plat39_independence_clean.nim"
printf 'import std/[strutils, os]\nimport gui_assert/ocr\n' >"$CLEAN"
if scan_one "$CLEAN" >/dev/null 2>&1; then
	note "negative control silent: a clean module is not flagged"
else
	bad "NEGATIVE CONTROL FIRED: a module importing only std/ and gui_assert was" \
		"flagged. The scan is matching something it should not, so its reds are" \
		"not evidence either."
fi
rm -f "$CLEAN"

echo
if [ "$fail" -eq 0 ]; then
	echo "OK: the vision producer imports nothing from viewmodel/ or the page objects."
	echo "    ${#SUBJECTS[@]} modules scanned, both polarities controlled."
	exit 0
fi
echo "PLAT-39 LAW-R4 FAILED"
exit 1
