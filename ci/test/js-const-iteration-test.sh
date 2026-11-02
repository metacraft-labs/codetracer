#!/usr/bin/env bash
#
# js-const-iteration-test.sh — no suite a JavaScript lane compiles drives a
# `for` loop directly over a `staticRead` constant.
#
# WHY THIS EXISTS
# ---------------
# `test_platform_web.nim`'s case "a theme swap that lands on nothing is not
# reported as success" took about EIGHTEEN MINUTES under `vm-unit-js` (1068 s
# for the suite, measured at codetracer `f1f93cbaf`) and a few milliseconds
# under `vm-unit`. To an operator it looked like a hang. (codetracer-pm issue
# 2026-10-26-test-platform-web-takes-eighteen-minutes-under-vm-unit-js.)
#
# The case did
#
#     const renderer = staticRead("../../../renderer.nim")   # 104 KB
#     for line in renderer.splitLines: ...
#
# `splitLines` is an INLINE iterator. The compiler expands its body at the
# call site and substitutes the argument for its `s` parameter, and when the
# argument is a `const` it substitutes the constant's VALUE, not a variable
# holding it. The C backend emits a string literal as static data, so every
# `s[i]` is a load. The JS backend emits a string literal as an expression
# that BUILDS a fresh byte array (`makeNimstrLit("...")`, or an inline
# `[97,98,...]` for a short one) — and it does that at every `s[i]` and
# `s.len` the iterator body evaluates. One character access costs a copy of
# the whole file: the loop is O(n²) in the file's size.
#
# Measured on the JS backend under node 22: a 110 KB `const` walked with
# `splitLines` took 98.4 s; the same loop over `let s2 = src` took 0.005 s.
# The same expansion happens for any inline iterator (`split`, `items`,
# `pairs`, `tokenize`, ...) and for a `const` indexed in a loop body.
#
# The fix is a one-liner — bind the constant to a run-time `let` once and
# iterate the `let` — and a proc call (`renderer.contains(...)`) is already
# fine, because the argument is bound once at the call. What is missing is
# anything that says so before the next source scan costs a lane a quarter of
# an hour. Wall-clock limits are flaky on a shared host and would only see the
# big files; three other suites in `vm-unit-js` had the same pattern over
# 17-22 KB files and were simply slow. So the rule is checked on the SOURCE:
#
#   a `for` loop whose iterated SUBJECT is a `const` initialised from
#   `staticRead` in the same file is refused, by file and line.
#
# "Initialised from `staticRead`" means the value starts with `staticRead`,
# its alias `slurp`, or `specDocument` (src/frontend/test_support/
# spec_documents.nim, a template that expands to `staticRead` of a
# codetracer-pm document; two oracle suites walked 68 KB specs that way).
#
# The subject is the `in` expression's first identifier (`C`, `C.splitLines`,
# `C.split(',')`) or, when that is a call, its first argument
# (`splitLines(C)`, `split C, ','`). A const elsewhere in the expression is
# evaluated once and is not reported: an element of an array literal
# (`for (n, s) in [("a", C), ...]` copies each string once per element, not
# per character) or an argument of a proc whose RESULT is iterated
# (`for r in regions(parseJson(C))`).
#
# WHAT IT DOES NOT SEE, deliberately: a `staticRead` const declared in another
# module, a const built from another const, and a loop that indexes a const in
# its body without naming it in the `for` header. Names are matched without
# regard to scope (Nim's style-insensitive rule: first letter exact, the rest
# case- and underscore-insensitive), so a `let` that shadows a `staticRead`
# const's exact name elsewhere in the file reads as the const. Rename one.
#
# THE CONTRACTS
#   1. TREE — no file in a lane whose backend is `js*` (`test_lane_backend`,
#      read from ci/lib/test-lane-files.sh, never copied) has a finding. The
#      lane set must be non-empty and must include vm-unit-js's directory, or
#      the check is vacuous.
#   2. POSITIVE CONTROL — a synthetic suite carrying the pattern in each
#      spelling the scanner claims to see (top-level const, const block,
#      RHS on the next line, a typed const, a const local to a test, method,
#      call and command syntax, a style-insensitive respelling, iteration over
#      the string itself, a loop body on the header line) yields exactly those findings.
#   3. NEGATIVE CONTROL — the fixes and the look-alikes in the same file
#      (iterating a `let` bound from the const, a `let x = staticRead(...)`,
#      a const not from `staticRead`, a commented-out loop, a proc call on the
#      const, a field spelled like it, a longer name, the const inside an
#      array literal or inside an argument of a proc whose result is
#      iterated) yield none.
#
# Pure bash + awk; runs in the lint stage (ci/lint/nim.sh).
#
# Run directly:  bash ci/test/js-const-iteration-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lib="${repo_root}/ci/lib/test-lane-files.sh"

TOTAL_CONTRACTS=3
checks=0
failures=0

ok() {
	checks=$((checks + 1))
	echo "  [OK] $1"
}
bad() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	echo "  [FAILED] $1"
	shift
	local line
	for line in "$@"; do printf '        %s\n' "${line}"; done
}

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# const_iteration_findings FILE LABEL — print `LABEL:LINE: ...` for each `for`
# loop in FILE whose iterated subject is a `staticRead` const of FILE.
#
# Pass 1 collects the const names. A declaration counts when it is in a const
# context — `const NAME = ...` on the line, or an entry of a `const` block (a
# bare `const` line and the more-indented lines under it) — and its value
# starts with `staticRead` / `slurp` / `specDocument`, on the same line or,
# when the line ends at `=`, on the next non-blank one. Pass 2 reads every
# one-line `for ... in EXPR:` header and matches the SUBJECT of EXPR (see
# below) against those names.
# The awk program is single-quoted on purpose: its `$0` is awk's.
# shellcheck disable=SC2016
const_iteration_findings() {
	awk -v label="$2" '
		# Nim identifier equality: the first character exactly, the rest
		# case-insensitively and ignoring underscores.
		function canon(id,   r) { r = tolower(substr(id, 2)); gsub(/_/, "", r); return substr(id, 1, 1) r }
		function indent(s) { match(s, /^[ \t]*/); return RLENGTH }
		function strip_comment(s) { sub(/[ \t]*#.*$/, "", s); return s }
		FNR == NR {
			raw = $0
			line = strip_comment(raw)
			if (line ~ /^[ \t]*$/) next
			ind = indent(line)
			if (pending != "") {
				rhs = line; sub(/^[ \t]+/, "", rhs)
				if (rhs ~ /^(staticRead|slurp|specDocument)[ \t(]/) { names[canon(pending)] = pending_line }
				pending = ""
			}
			if (in_block && ind <= block_ind) in_block = 0
			if (line ~ /^[ \t]*const[ \t]*$/) { in_block = 1; block_ind = ind; next }
			decl = line
			ctx = 0
			if (decl ~ /^[ \t]*const[ \t]+/) { sub(/^[ \t]*const[ \t]+/, "", decl); ctx = 1 }
			else if (in_block) { sub(/^[ \t]+/, "", decl); ctx = 1 }
			if (!ctx) next
			if (!match(decl, /^[A-Za-z_][A-Za-z0-9_]*/)) next
			name = substr(decl, 1, RLENGTH)
			rest = substr(decl, RLENGTH + 1)
			sub(/^\*/, "", rest)
			sub(/^[ \t]*\{\.[^}]*\.\}/, "", rest)
			sub(/^[ \t]*:[^=]*/, "", rest)
			if (rest !~ /^[ \t]*=/ || rest ~ /^[ \t]*==/) next
			sub(/^[ \t]*=[ \t]*/, "", rest)
			if (rest == "") { pending = name; pending_line = FNR; next }
			if (rest ~ /^(staticRead|slurp|specDocument)[ \t(]/) names[canon(name)] = FNR
			next
		}
		{
			line = strip_comment($0)
			if (line !~ /^[ \t]*for[ \t]/) next
			if (!match(line, /[ \t]in[ \t]/)) next
			expr = substr(line, RSTART + RLENGTH)
			sub(/:[ \t]*$/, "", expr)
			sub(/^[ \t]+/, "", expr)
			# The SUBJECT is what the iterator walks: the first
			# identifier (`C`, `C.splitLines`, `C.split(sep)`), or, when that
			# is a call (`splitLines(C)`, `split C, sep`), its first argument.
			# A const anywhere else — an element of an array literal, an
			# argument of a proc whose result is iterated
			# (`regions(parseJson(C))`) — is evaluated once, not per access.
			if (!match(expr, /^[A-Za-z_][A-Za-z0-9_]*/)) next
			id = substr(expr, 1, RLENGTH)
			after = substr(expr, RLENGTH + 1)
			if (!(canon(id) in names) && match(after, /^(\(|[ \t]+)[ \t]*[A-Za-z_][A-Za-z0-9_]*/)) {
				arg = substr(after, 1, RLENGTH)
				sub(/^[( \t]+/, "", arg)
				id = arg
				after = substr(after, RLENGTH + 1)
			}
			if (!(canon(id) in names)) next
			# What may follow the subject: a method call (`.`), the end of an
			# argument (`,` `)`), a space, or the `:` ending the header when the loop
			# body shares the line (`for ch in C: inc n`).
			if (after != "" && after !~ /^[.,): \t]/) next
			printf "%s:%d: `for ... in %s` iterates const %s (staticRead at line %d); bind it to a `let` first\n", label, FNR, expr, id, names[canon(id)]
		}
	' "$1" "$1"
}

# js_lane_files TREE — every file of every lane whose backend is JS, from the
# lib as run in TREE, sorted and unique.
js_lane_files() {
	(
		cd "$1" || exit 2
		# shellcheck source=ci/lib/test-lane-files.sh
		source "${lib}"
		local lane
		for lane in $(test_lane_ids); do
			case "$(test_lane_backend "${lane}")" in
			js*) test_lane_files "${lane}" ;;
			esac
		done | sort -u
	)
}

echo "=== JS lanes: no for-loop iterates a staticRead const ==="

# ---------------------------------------------------------------------------
# 1. The real tree.
# ---------------------------------------------------------------------------
files="$(js_lane_files "${repo_root}")"
nfiles="$(printf '%s\n' "${files}" | grep -c . || true)"
if [ "${nfiles}" -eq 0 ] ||
	! grep -q '^src/frontend/viewmodel/tests/unit/test_.*\.nim$' <<<"${files}"; then
	bad "tree: the JS lanes list no vm-unit-js suite (${nfiles} files); the lane lookup is broken"
else
	findings=""
	while read -r f; do
		[ -n "${f}" ] && [ -f "${repo_root}/${f}" ] || continue
		findings+="$(const_iteration_findings "${repo_root}/${f}" "${f}")"$'\n'
	done <<<"${files}"
	findings="$(printf '%s' "${findings}" | grep -v '^$' || true)"
	if [ -z "${findings}" ]; then
		ok "tree: none of the ${nfiles} files the JS lanes compile iterates a staticRead const"
	else
		mapfile -t lines <<<"${findings}"
		bad "tree: ${#lines[@]} loop(s) over a staticRead const in JS-lane files (O(n^2) under node)" "${lines[@]}"
	fi
fi

# ---------------------------------------------------------------------------
# 2 + 3. Synthetic suite.
# ---------------------------------------------------------------------------
fx="${work}/test_fx.nim"
cat >"${fx}" <<'EOF'
import std/[strutils, unittest]

const TopLevel = staticRead("a.nim")
const
  InBlock* = staticRead("b.nim") & staticRead("c.nim")
  NextLine =
    staticRead("d.nim")
  Typed: string = staticRead("e.nim")
  Spec = specDocument("GUI/X.md")
  Slurped = slurp("h.nim")
  NotRead = "a\nb"

test "positives":
  var n = 0
  for line in TopLevel.splitLines:  # P1
    discard
  for line in splitLines(InBlock):  # P2
    discard
  for w in NextLine.split('\n'):  # P3
    discard
  for ch in Typed:  # P4
    discard
  for line in Top_level.splitLines():  # P5
    discard
  const Local = staticRead("f.nim")
  for i, line in pairs(Local.splitLines.toSeq):  # P6
    discard
  for part in split InBlock, ',':  # P7
    discard
  for line in Spec.splitLines():  # P8
    discard
  for line in Slurped.splitLines:  # P9
    discard
  for ch in TopLevel: inc n  # P10: the body on the header line

test "negatives":
  let topLevel = TopLevel
  for line in topLevel.splitLines:  # N1: lower-case first letter is another name
    discard
  let bound = InBlock
  for line in bound.splitLines:  # N2
    discard
  let readAtRuntime = staticRead("g.nim")
  for line in readAtRuntime.splitLines:  # N3
    discard
  for line in NotRead.splitLines:  # N4
    discard
  # for line in TopLevel.splitLines:  # N5
  check TopLevel.contains("x")  # N6
  for x in bound.Typed:  # N7: a field named like the const
    discard
  for (name, src) in [("a", TopLevel), ("b", InBlock)]:  # N8: array literal, built once per element
    discard
  for row in parseRows(parseJson(TopLevel)):  # N9: a proc's result
    discard
  for row in OtherSeq & @[TopLevel]:  # N10
    discard
  for l in TopLevelish.splitLines:  # N11: a longer name
    discard
EOF
got="$(const_iteration_findings "${fx}" fx | sed -n 's/^fx:\([0-9]*\):.*/\1/p' | tr '\n' ' ')"
want="$(grep -n '# P[0-9]' "${fx}" | cut -d: -f1 | tr '\n' ' ')"
negatives="$(grep -n '# N[0-9]' "${fx}" | cut -d: -f1 | tr '\n' ' ')"
if [ "${got}" = "${want}" ]; then
	ok "positive control: all $(wc -w <<<"${want}" | tr -d ' ') planted loops found, at lines ${want}"
	ok "negative control: none of the look-alikes at lines ${negatives}is reported"
else
	missed="" extra=""
	for n in ${want}; do grep -qw "${n}" <<<"${got}" || missed+="${n} "; done
	for n in ${got}; do grep -qw "${n}" <<<"${want}" || extra+="${n} "; done
	if [ -z "${missed}" ]; then
		ok "positive control: all planted loops found"
	else
		bad "positive control: planted loops not reported, at fixture lines ${missed}"
	fi
	if [ -z "${extra}" ]; then
		ok "negative control: no look-alike reported"
	else
		bad "negative control: look-alikes reported, at fixture lines ${extra}"
	fi
fi

echo
if [ "${checks}" -ne "${TOTAL_CONTRACTS}" ]; then
	echo "js-const-iteration: ran ${checks}, expected ${TOTAL_CONTRACTS} contracts" >&2
	exit 1
fi
if [ "${failures}" -ne 0 ]; then
	echo "js-const-iteration: ${failures} of ${checks} contract(s) FAILED" >&2
	exit 1
fi
echo "js-const-iteration: ${checks} contract(s) passed"
