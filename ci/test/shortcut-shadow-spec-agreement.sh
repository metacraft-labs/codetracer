#!/usr/bin/env bash
#
# shortcut-shadow-spec-agreement.sh — the permitted-shadow table in the spec and
# the one in the product name the same rows.
#
# WHY THIS EXISTS
# ---------------
# `GUI/Keyboard-Shortcuts-System.md` § "Hard binds are enumerated and their
# shadowing is reported" carries a table of the shadows that are ALLOWED — a
# chord a hardcoded `Mousetrap.bind` may take away from a config entry — and
# then states the rule: "Every other shadow is a defect. A chord in
# `hardBindShadowedActions` that is not listed above must be resolved by
# removing one of the two claims, never by leaving the config entry declared and
# dead."
#
# `shortcut_bindings_test.nim` enforces that rule, and it enforces it against
# `PERMITTED_HARD_BIND_SHADOWS` in `src/frontend/ui/shortcut_labels.nim`,
# because the spec repository is a SIBLING and is not checked out in any CI lane
# (`.github/workflows/codetracer.yml` clones no spec). A constant standing in
# for a spec table is a copy, and a copy is how the thing it copies goes stale:
# widening the constant by one row would make the rule permit the very shadow it
# was written to catch, and every test over it would go on passing.
#
# So the constant is not trusted; it is COMPARED. This script parses the rows
# out of the spec's markdown table and the rows out of the Nim constant and
# requires them to be the same set. Neither side is authoritative to the
# parser — a disagreement names which side has what, and a human decides which
# one is wrong.
#
# THE SHAPE (`Verification-Harness-Traps.md` 4a/4c, and the house style set by
# `chord-and-pane-uniqueness.sh`)
#   * COUNTED assertions, with the count asserted at the bottom, so an arm that
#     aborted becomes a count mismatch and not a clean summary.
#   * THE NUMBER OF ROWS IS ASSERTED ON BOTH SIDES BEFORE THEY ARE COMPARED.
#     Two empty sets are equal. A parser that silently matched nothing — a
#     renamed heading, a reformatted table, a moved file — would report perfect
#     agreement over nothing at all, which is this campaign's signature
#     instrument failure.
#   * INSTRUMENT ARMS THAT REDDEN THE ASSERTION WRITTEN FOR THEM. Arm SM
#     doctors a COPY of the spec with an extra row; arm CM doctors a COPY of the
#     Nim source with an extra row. Each must be caught, and each is caught by
#     the same comparison the green arm uses. Without them "the two agree" is
#     satisfied by two parsers that both return nothing.
#
# ABSENT SPEC REPOSITORY. Reported as a loud SKIP with a non-zero skip count and
# a RESULT line that says INCOMPLETE rather than OK — the convention
# `web-bundle-assets.sh` set for an input that is not in the repository.
#
# THIS IS THE ONE PLACE THIS GATE CAN LIE, so it is spelled out. No CI lane
# supplies the sibling today: `codetracer-specs` is not in `.github/sibling-repos`
# and no workflow clones it, so a run there compares the product against nothing.
# `CT_SPECS_REQUIRED=1` turns that state into a FAILURE, and it is what a lane
# that does provision the sibling should set — one variable is all that stands
# between this script and being enforcing, deliberately, so that provisioning the
# sibling is the only remaining work.
#
# Usage:  bash ci/test/shortcut-shadow-spec-agreement.sh
# Env:    CT_SPECS_DIR       a `codetracer-specs` checkout (default: ../codetracer-specs)
#         CT_SPECS_REQUIRED  set to 1 to fail rather than skip when it is absent

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=ci/lib/nim-cache-root.sh
# shellcheck disable=SC1091 # resolved at runtime from the checkout root
source "${repo_root}/ci/lib/nim-cache-root.sh"
cd "${repo_root}" || exit 2

cache="$(ct_nim_cache_root "${repo_root}")/shortcut-shadow-spec"
mkdir -p "${cache}"

checks=0
failures=0
skips=0
ck() {
	checks=$((checks + 1))
	if [ "$1" = "ok" ]; then
		printf '  [OK]      %s\n' "$2"
	else
		failures=$((failures + 1))
		printf '  [FAILED]  %s\n' "$2"
	fi
}
note() { printf '      %s\n' "$*"; }

expect_count() {
	local want="$1"
	if [ "${checks}" -ne "${want}" ]; then
		printf '\nRESULT: FAILED — %d assertion(s) ran, %d were written.\n' \
			"${checks}" "${want}"
		printf 'An assertion that did not run is not an assertion that passed.\n'
		exit 1
	fi
}

echo "=== the permitted-shadow table: spec and product agree ==="
echo

labels="src/frontend/ui/shortcut_labels.nim"
[ -s "${labels}" ] || {
	echo "${labels} is missing; nothing to compare" >&2
	exit 2
}

specs_dir="${CT_SPECS_DIR:-${repo_root}/../codetracer-specs}"
spec_rel="GUI/Keyboard-Shortcuts-System.md"
spec_file="${specs_dir}/${spec_rel}"

# ---------------------------------------------------------------------------
# THE TWO PARSERS.
#
# Each prints one `CHORD<TAB>ACTION` row per line, sorted. Written in Python and
# not in `sed`/`awk` because both have to REFUSE rather than return nothing when
# their anchor is missing: a parser that cannot find its table exits non-zero and
# the arm that called it becomes a FAILED check, rather than an empty set that
# compares equal to the other empty set.
# ---------------------------------------------------------------------------
cat >"${cache}/parse_spec.py" <<'PY'
"""Rows of the permitted-shadow table in GUI/Keyboard-Shortcuts-System.md.

The table is located by the SENTENCE that introduces it -- "The one permitted
shadow:" / "The permitted shadows:" -- rather than by a line number or by "the
first table with a Chord column", because the document has several tables with a
Chord column and a line number is a thing that rots silently.
"""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
lines = text.splitlines()

# The anchor is matched ACROSS newlines. Markdown prose is hard-wrapped, so
# "The one permitted shadow:" can arrive as "...The one permitted" / "shadow:" —
# and a parser that only looked at single lines would report "table not found"
# for a reflow, which is a false red on a document nobody changed the meaning of.
m = re.search(r"permitted\s+shadows?:", text, re.IGNORECASE)
if m is None:
    sys.stderr.write(
        "the permitted-shadow table's introducing sentence was not found; "
        "expected the words 'permitted shadow:' or 'permitted shadows:'\n")
    sys.exit(3)
anchor = text.count("\n", 0, m.end())

# The table is the next contiguous run of pipe rows, minus its header and its
# `---` separator.
rows = []
seen_table = False
for line in lines[anchor + 1:]:
    s = line.strip()
    if not s:
        if seen_table:
            break
        continue
    if not s.startswith("|"):
        if seen_table:
            break
        continue
    seen_table = True
    cells = [c.strip() for c in s.strip("|").split("|")]
    if len(cells) < 2:
        continue
    if set(cells[0]) <= set("-: "):          # the separator row
        continue
    if cells[0].lower() == "chord":          # the header row
        continue
    chord = cells[0].strip("`").upper()
    action = cells[1].strip().strip("`")
    rows.append((chord, action))

if not rows:
    sys.stderr.write("the permitted-shadow table was found but parsed to no rows\n")
    sys.exit(3)

for chord, action in sorted(rows):
    print("%s\t%s" % (chord, action))
PY

cat >"${cache}/parse_const.py" <<'PY'
"""Rows of PERMITTED_HARD_BIND_SHADOWS in src/frontend/ui/shortcut_labels.nim.

Read as TEXT rather than by compiling and printing the constant, on purpose.
Compiling it would prove the constant equals itself; the question here is
whether the source a reviewer reads says what the spec says. The extractor is
anchored on the declaration and refuses when it finds no rows.
"""
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"const\s+PERMITTED_HARD_BIND_SHADOWS\*?\s*:", text)
if m is None:
    sys.stderr.write("PERMITTED_HARD_BIND_SHADOWS is not declared in this file\n")
    sys.exit(3)

# From the declaration to the closing bracket of the sequence literal.
# `start` is the `@`; scanning begins AFTER its `[` so that opening bracket is
# not counted as a nested one.
start = text.index("@[", m.end())
depth = 0
end = None
for i in range(start + 2, len(text)):
    if text[i] == "[":
        depth += 1
    elif text[i] == "]":
        if depth == 0:
            end = i
            break
        depth -= 1
if end is None:
    sys.stderr.write("the PERMITTED_HARD_BIND_SHADOWS literal is not closed\n")
    sys.exit(3)

body = text[start + 2:end]
# Comment lines are not rows. A commented-out row is not a permission.
body = "\n".join(l for l in body.splitlines() if not l.strip().startswith("#"))

rows = re.findall(
    r'\(\s*cstring"([^"]+)"\s*,\s*ClientAction\.([A-Za-z_][A-Za-z0-9_]*)\s*\)', body)
if not rows:
    sys.stderr.write("PERMITTED_HARD_BIND_SHADOWS was found but parsed to no rows\n")
    sys.exit(3)

for chord, action in sorted((c.upper(), a) for c, a in rows):
    print("%s\t%s" % (chord, action))
PY

# `parse <script> <file> <out>` — prints rows to <out>, returns non-zero on a
# parser that found nothing.
parse() {
	/usr/bin/python3 "$1" "$2" >"$3" 2>"$3.err"
}

# ---------------------------------------------------------------------------
# THE PRODUCT SIDE, which is always available.
# ---------------------------------------------------------------------------
if parse "${cache}/parse_const.py" "${labels}" "${cache}/const.rows"; then
	ck ok "PERMITTED_HARD_BIND_SHADOWS parsed out of ${labels}"
else
	ck fail "PERMITTED_HARD_BIND_SHADOWS parsed out of ${labels}"
	head -3 "${cache}/const.rows.err" | sed 's/^/      /'
	expect_count 1
	printf 'RESULT: FAILED\n'
	exit 1
fi

const_rows="$(/usr/bin/python3 -c 'import sys; print(sum(1 for l in open(sys.argv[1]) if l.strip()))' "${cache}/const.rows")"
ck "$([ "${const_rows}" -ge 1 ] && echo ok || echo fail)" \
	"the constant declares ${const_rows} permitted shadow(s), so the comparison below has subjects"
while IFS=$'\t' read -r chord action; do
	[ -n "${chord}" ] && note "product: ${chord} may shadow ${action}"
done <"${cache}/const.rows"

# ---------------------------------------------------------------------------
# THE SPEC SIDE, which may not be.
# ---------------------------------------------------------------------------
if [ ! -s "${spec_file}" ]; then
	if [ "${CT_SPECS_REQUIRED:-0}" = "1" ]; then
		ck fail "the spec table was required and is not present at ${spec_file}"
		note "CT_SPECS_REQUIRED=1 was set, so an unread spec is a failure and not a skip."
		expect_count 3
		printf 'RESULT: FAILED\n'
		exit 1
	fi
	skips=$((skips + 1))
	echo
	printf '  [SKIPPED] the spec table could not be compared: %s is not present\n' \
		"${spec_file}"
	note "This run did NOT verify that the product's permitted-shadow list"
	note "matches ${spec_rel}. Set CT_SPECS_DIR to a codetracer-specs"
	note "checkout, or place one beside this repository, to compare them."
	note "Set CT_SPECS_REQUIRED=1 to make this state a failure instead."
	echo
	printf '%d check(s), %d failure(s), %d skipped\n' "${checks}" "${failures}" "${skips}"
	expect_count 2
	[ "${failures}" -eq 0 ] || exit 1
	echo "RESULT: INCOMPLETE — the product side is well-formed; the spec side was not read"
	exit 0
fi

if parse "${cache}/parse_spec.py" "${spec_file}" "${cache}/spec.rows"; then
	ck ok "the permitted-shadow table parsed out of ${spec_rel}"
else
	ck fail "the permitted-shadow table parsed out of ${spec_rel}"
	head -3 "${cache}/spec.rows.err" | sed 's/^/      /'
	expect_count 3
	printf 'RESULT: FAILED\n'
	exit 1
fi

spec_rows="$(/usr/bin/python3 -c 'import sys; print(sum(1 for l in open(sys.argv[1]) if l.strip()))' "${cache}/spec.rows")"
ck "$([ "${spec_rows}" -ge 1 ] && echo ok || echo fail)" \
	"${spec_rel} declares ${spec_rows} permitted shadow(s), so the comparison is not over an empty table"
while IFS=$'\t' read -r chord action; do
	[ -n "${chord}" ] && note "spec:    ${chord} may shadow ${action}"
done <"${cache}/spec.rows"

# THE COMPARISON. Set equality, reported as the two one-sided differences so a
# disagreement names which side carries the extra row.
diff_out="$(diff "${cache}/spec.rows" "${cache}/const.rows" 2>&1)"
if [ -z "${diff_out}" ]; then
	ck ok "the spec's permitted-shadow table and PERMITTED_HARD_BIND_SHADOWS name the same rows"
else
	ck fail "the spec's permitted-shadow table and PERMITTED_HARD_BIND_SHADOWS DISAGREE"
	printf '%s\n' "${diff_out}" | sed 's/^/      /'
fi

# ---------------------------------------------------------------------------
# THE INSTRUMENT ARMS. Both run against COPIES; neither touches a tracked file.
#
# A comparison of two lists is exactly the shape that passes when both parsers
# have quietly stopped finding anything, so each side is doctored in turn and
# the SAME comparison must catch it.
# ---------------------------------------------------------------------------
echo

mkdir -p "${cache}/arm-sm/GUI"
cp "${spec_file}" "${cache}/arm-sm/${spec_rel}"
/usr/bin/python3 - "${cache}/arm-sm/${spec_rel}" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
m = re.search(r"permitted\s+shadows?:", text, re.IGNORECASE)
if m is None:
    sys.exit(3)
anchor = text.count("\n", 0, m.end())
lines = text.splitlines()
out = lines[:anchor + 1]
inserted = False
for line in lines[anchor + 1:]:
    out.append(line)
    if not inserted and line.strip().startswith("|") and "CTRL+B" in line:
        out.append("| ALT+9  | `zoomIn`     | Planted by arm SM   |")
        inserted = True
open(path, "w", encoding="utf-8").write("\n".join(out) + "\n")
if not inserted:
    sys.exit(3)
PY
sm_planted=$?
if [ "${sm_planted}" -ne 0 ]; then
	ck fail "arm SM: a row could be planted in a copy of the spec table"
else
	parse "${cache}/parse_spec.py" "${cache}/arm-sm/${spec_rel}" "${cache}/sm.rows"
	if diff -q "${cache}/sm.rows" "${cache}/const.rows" >/dev/null 2>&1; then
		ck fail "arm SM: a spec table with one extra row is NOT flagged — the comparison above is vacuous"
	else
		ck ok "arm SM: a spec table with one extra row IS flagged, so the comparison distinguishes the two lists"
		note "planted: $(diff "${cache}/sm.rows" "${cache}/const.rows" | tr '\n' ' ')"
	fi
fi

cp "${labels}" "${cache}/arm-cm-labels.nim"
/usr/bin/python3 - "${cache}/arm-cm-labels.nim" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
needle = '(cstring"CTRL+B", ClientAction.build),'
if needle not in text:
    sys.exit(3)
text = text.replace(
    needle, needle + '\n    (cstring"ALT+9", ClientAction.zoomIn),', 1)
open(path, "w", encoding="utf-8").write(text)
PY
cm_planted=$?
if [ "${cm_planted}" -ne 0 ]; then
	ck fail "arm CM: a row could be planted in a copy of the Nim constant"
else
	parse "${cache}/parse_const.py" "${cache}/arm-cm-labels.nim" "${cache}/cm.rows"
	if diff -q "${cache}/spec.rows" "${cache}/cm.rows" >/dev/null 2>&1; then
		ck fail "arm CM: a constant with one extra row is NOT flagged — the comparison above is vacuous"
	else
		ck ok "arm CM: a constant with one extra row IS flagged, so a quietly widened permission cannot pass"
		note "planted: $(diff "${cache}/spec.rows" "${cache}/cm.rows" | tr '\n' ' ')"
	fi
fi

echo
if [ "${failures}" -ne 0 ]; then
	printf 'RESULT: FAILED — %d of %d check(s)\n' "${failures}" "${checks}"
	expect_count 7
	exit 1
fi
printf '%d check(s), 0 failure(s)\n' "${checks}"
expect_count 7
echo "RESULT: OK — the spec and the product permit the same shadows"
