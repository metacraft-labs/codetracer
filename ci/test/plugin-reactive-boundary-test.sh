#!/usr/bin/env bash
#
# plugin-reactive-boundary-test.sh — the contract suite over
# ci/test/plugin-reactive-boundary.sh.
#
# The same reason ci/test/sdk-facade-boundary-test.sh exists: a guard that has
# only ever been watched printing OK is not evidence
# (Verification-Harness-Traps §4 — "a scanner that finds nothing passes every
# 'must not contain' check you write"). This file drives the boundary gate
# against synthetic trees and asserts that EACH of its checks fires, by name, on
# the violation it is supposed to catch — and, just as importantly, that it
# stays quiet on the clean version of the same tree.
#
# The gate itself carries its POSITIVE CONTROLS inline (checks 6, 7 and 8), the
# way ci/test/tui-layer-split-boundary.sh does, because each of them can run
# against real files. What it cannot do against real files is fail: this suite is
# the half that shows it can say no. Cases 20-23 below are the ones that matter
# most — they break the gate's own controls and assert the gate reddens, which is
# what stops "check 1 is clean" from being satisfied by a scanner that reads
# nothing.
#
# Usage: ci/test/plugin-reactive-boundary-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/plugin-reactive-boundary.sh"

pass=0
fail=0

ok() {
	pass=$((pass + 1))
	echo "  ok   $1"
}

bad() {
	fail=$((fail + 1))
	echo "  FAIL $1"
	shift
	while [ $# -gt 0 ]; do
		echo "         $1"
		shift
	done
}

work="$(mktemp -d)"
cleanup() { rm -rf "${work}"; }
trap cleanup EXIT

VM="src/frontend/viewmodel"
FIXTURES="${VM}/tests/unit/plugin_fixtures"

# make_tree NAME — a CLEAN baseline on which every check passes.
#
# It carries, at the real repo-relative paths the gate is configured with: the
# primitives table, the narrowed plugin surface, the wider SDK facade (which
# imports the denied modules in the bracket spelling, so the gate's own import
# control has something to find), the prose probe, and one well-behaved plugin.
#
# Callers then change exactly one thing, so each case differs from the baseline
# in one way. The denied set is three names rather than ten because the gate
# reads whatever the table holds and three is readable.
make_tree() {
	local name="$1"
	local t="${work}/${name}"
	mkdir -p "${t}/${VM}/plugin_host" "${t}/${FIXTURES}"

	cat >"${t}/${VM}/plugin_host/plugin_api.nim" <<'EOF'
## The wrapped API. Its header names createEffect in prose, deliberately.
import isonim/core/computation as isonim_computation

const
  PluginDeniedPrimitives*: array[3, tuple[primitive, replacement: string]] = [
    ("createEffect", "ctx.pluginEffect"),
    ("createRoot",   "ctx.pluginRoot"),
    ("getOwner",     "ctx.scope"),
  ]

proc pluginEffect*(name: string; body: proc()) =
  isonim_computation.createEffect(body)
EOF

	cat >"${t}/${VM}/codetracer_embed.nim" <<'EOF'
import isonim/core/[signals, computation, owner]
export signals, computation, owner
import plugin_host/plugin_api
export plugin_api
const CodeTracerEmbedFacadeModule* = "codetracer_embed"
EOF

	cat >"${t}/${VM}/codetracer_plugin.nim" <<'EOF'
import codetracer_embed
export codetracer_embed except
  createEffect, createRoot, getOwner
const CodeTracerPluginSurfaceModule* = "codetracer_plugin"
EOF

	cat >"${t}/${FIXTURES}/.ct-plugin" <<'EOF'
These are plugins.
EOF

	# The prose probe. It NAMES every denied primitive in a doc comment and
	# calls none of them, which is what check 8 needs in both directions.
	cat >"${t}/${FIXTURES}/position_watch_plugin.nim" <<'EOF'
## There is no createEffect, no createRoot and no getOwner in this file's code.
import codetracer_plugin

proc activate*() =
  pluginEffect("watch", proc() = discard)
EOF

	# The `compiles` probe. It NAMES every denied primitive in CODE and calls
	# none of them, because `compiles` is the one nim form that names a routine
	# without the possibility of calling it. Check 10's subject, and the reason
	# check 2 has a form-shaped exemption rather than a file-shaped one.
	cat >"${t}/${FIXTURES}/surface_probe_plugin.nim" <<'EOF'
import codetracer_plugin

const
  RawEffectInScope* = compiles(createEffect(proc() = discard))
  RawRootInScope* = compiles(createRoot(proc(dispose: proc()) = discard))
  RawGetOwnerInScope* = compiles(getOwner())
  WrappedEffectInScope* = compiles(pluginEffect("n", proc() = discard))
EOF

	git -C "${t}" init -q
	git -C "${t}" config user.email t@example.invalid
	git -C "${t}" config user.name t
	printf '%s' "${t}"
}

run_guard() {
	bash "${guard}" --root "$1" 2>&1
}

# assert_fires TREE CHECK-NAME DESCRIPTION [EXPECTED-SUBSTRING...]
assert_fires() {
	local tree="$1" check="$2" desc="$3"
	shift 3
	local output status needle
	output="$(run_guard "${tree}")"
	status=$?
	if [ "${status}" -eq 0 ]; then
		bad "${desc}" "guard exited 0; expected a failure" "${output}"
		return
	fi
	if ! grep -q "VIOLATION ${check}" <<<"${output}"; then
		bad "${desc}" "no 'VIOLATION ${check}' line in the output" "${output}"
		return
	fi
	for needle in "$@"; do
		[ -n "${needle}" ] || continue
		if ! grep -qF "${needle}" <<<"${output}"; then
			bad "${desc}" "output did not name '${needle}'" "${output}"
			return
		fi
	done
	ok "${desc}"
}

# assert_clean TREE DESCRIPTION
assert_clean() {
	local tree="$1" desc="$2"
	local output status
	output="$(run_guard "${tree}")"
	status=$?
	if [ "${status}" -ne 0 ]; then
		bad "${desc}" "guard exited ${status}; expected 0" "${output}"
		return
	fi
	ok "${desc}"
}

echo "=== ci/test/plugin-reactive-boundary.sh: contract suite ==="

# ---------------------------------------------------------------------------
# The baseline. If this is not clean, every assert_fires below could be passing
# for the wrong reason.
# ---------------------------------------------------------------------------

t="$(make_tree clean-baseline)"
assert_clean "${t}" "the clean baseline passes every check"

# ---------------------------------------------------------------------------
# plugin-imports-narrow
#
# One case per import SPELLING, each in its own file so the gate's output has to
# name every one of them — a single file would let one spelling being reported
# stand in for the rest.
# ---------------------------------------------------------------------------

t="$(make_tree import-computation)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import isonim/core/computation
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a plugin importing isonim/core/computation is caught" \
	"isonim/core/computation" "createEffect, createRenderEffect"

t="$(make_tree import-owner)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a plugin importing isonim/core/owner is caught" \
	"isonim/core/owner" "createRoot, runWithOwner"

t="$(make_tree import-facade)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_embed
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a plugin importing the WIDER SDK facade is caught — this is the defect PLAT-7 shipped" \
	"codetracer_embed"

t="$(make_tree import-relative)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../codetracer_embed
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"the relative spelling of the facade import does not evade the rule" \
	"codetracer_embed"

t="$(make_tree import-bracket)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import isonim/core/[computation, owner]
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"the bracket-list spelling does not evade the rule" \
	"isonim/core/computation" "isonim/core/owner"

t="$(make_tree import-from)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
from isonim/core/computation import createEffect
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"the 'from X import Y' spelling does not evade the rule" \
	"isonim/core/computation"

t="$(make_tree import-when-one-line)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
when not defined(js): import isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a one-line 'when cond: import X' does not hide the import" \
	"isonim/core/owner"

t="$(make_tree import-aliased)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import isonim/core/computation as reactive
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"an aliased import does not evade the rule" \
	"isonim/core/computation"

# ---------------------------------------------------------------------------
# NIM'S NEWLINE-CONTINUED `import`, IN EVERY PLACE IT CAN HIDE SOMETHING
#
# The spelling that walked straight past this gate on 2026-09-08:
#
#     import
#       ../../../raw_helper_probe
#
# The gate had its own extractor, re-derived from the same examples as
# `sdk-facade-boundary.sh`'s, and its keyword test required whitespace after the
# keyword. Measured on the real repository, the milestone's own helper-module
# exploit, twice, everything else identical: `import <helper>` gave `15 checks,
# 3 failing` and the newline form gave `15 checks, 0 failing`, over an IDENTICAL
# runtime — `rawRuns=6 runs=0 violations=0 suspended=false`. Under the newline
# form `--list-closure` said `0 reached by import` and `closure-is-readable`
# printed OK: the gate never reported failing to read anything, because it never
# saw the import.
#
# The form is idiomatic and prevalent (138 files under `src/`, 31 under
# `../isonim/`) and every spelling below was COMPILED AND RUN on nim 2.2.8 with
# a proc called out of the imported module, so "it parses" was not mistaken for
# "it imports".
#
# The fix was not a better regex here: both gates now call `nim_imports` out of
# ci/lib/nim-imports.sh. These cases are what makes that load-bearing.
# ---------------------------------------------------------------------------

t="$(make_tree import-newline-continued)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import
  isonim/core/computation
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a DENIED import written newline-continued does not evade the rule" \
	"isonim/core/computation" "createEffect, createRenderEffect"

t="$(make_tree import-newline-continued-list)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import
  isonim/core/computation,
  isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a newline-continued COMMA LIST names both denied modules, not one" \
	"isonim/core/computation" "isonim/core/owner"

t="$(make_tree import-newline-when-block)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
when not defined(js):
  import
    isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a newline-continued import INSIDE a 'when' block is caught (the verifier's variant)" \
	"isonim/core/owner"

t="$(make_tree import-newline-when-same-line)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
when not defined(js): import
  isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a 'when cond: import' whose module list is on the NEXT line is caught" \
	"isonim/core/owner"

t="$(make_tree import-newline-from)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
from
  isonim/core/computation import createEffect
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a newline-continued 'from X import Y' is caught — this one was missed by BOTH extractors" \
	"isonim/core/computation"

t="$(make_tree import-newline-include)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
include
  isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a newline-continued 'include' is caught" \
	"isonim/core/owner"

# THE ONE THAT MATTERS. The two cases above are a denied module named directly;
# this is the exploit itself — an ordinary helper module carrying the primitive,
# REACHED THROUGH a newline-continued import. It is the case whose failure was
# invisible: nothing about the plugin's own text is a violation, so the only way
# the gate can say no is by walking an edge it must first be able to see.
t="$(make_tree helper-reached-through-a-newline-import)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import
  ../../../raw_helper
proc activate*() = rawEffect(proc() = discard)
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"the helper-module exploit REACHED THROUGH a newline-continued import is caught — the spelling the gate could not see" \
	"raw_helper.nim" "isonim/core/computation"

t="$(make_tree helper-reached-through-a-newline-import-names)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import
  ../../../raw_helper
proc activate*() = rawEffect(proc() = discard)
EOF
assert_fires "${t}" "plugin-names-no-raw-primitive" \
	"the same newline-reached helper is caught by the NAME rule too" \
	"raw_helper.nim:2:createEffect"

t="$(make_tree closure-unreadable-through-a-newline-import)"
cat >"${t}/${VM}/quiet_helper.nim" <<'EOF'
import somepackage/reactive
proc h*() = discard
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import
  ../../../quiet_helper
proc activate*() = h()
EOF
assert_fires "${t}" "closure-is-readable" \
	"an UNRESOLVABLE spec one newline-continued hop away is still a finding" \
	"quiet_helper.nim" "somepackage/reactive"

t="$(make_tree closure-unreadable-spelled-newline)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import
  strutils
proc activate*() = discard
EOF
assert_fires "${t}" "closure-is-readable" \
	"an unresolvable spec written newline-continued is refused, not silently skipped" \
	"imports 'strutils'" "resolves to no file"

# THE EXTRACTOR'S OWN REFUSALS ARE FINDINGS, and this is what makes that true
# rather than documented. `nim_imports` declines to analyse three shapes rather
# than guessing at them, and it writes each to a log because a process
# substitution puts it in a subshell. A caller that never reads the log gets the
# refusals in /dev/null, which is the silent miss the refusal exists to avoid.
#
# The condition below is a real evasion, not a curiosity: a character literal
# holding a `#` desynchronises the comment cut, so the import after the colon is
# carried past every scan. It compiles on nim 2.2.8.
t="$(make_tree closure-import-refused-as-unanalysable)"
{
	printf 'import codetracer_plugin\n'
	printf 'when true and %s == %s: import isonim/core/owner\n' "'#'" "'#'"
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "closure-is-readable" \
	"a line the extractor REFUSES to analyse is a finding rather than a silence" \
	"REFUSED to analyse"

# ---------------------------------------------------------------------------
# THE SELF-CHECK IS PER `;`-PIECE AND BY COUNT — the two routes past it that
# were measured on 2026-09-08, and the two shapes that show the fix costs
# nothing.
#
# Until that date `nim_imports`' self-check asked two questions, and each was
# too weak in its own way:
#
#   1. it fired only when the LINE'S FIRST TOKEN was `when`/`elif`/`else`, so a
#      conditional in a later `;`-piece was never examined;
#   2. once fired, it cleared as soon as ANY piece yielded an import, so a line
#      carrying one readable import beside one lost import passed on the
#      strength of the readable one.
#
# Measured against this gate, this fixture and a real helper module, both
# shapes compiling and importing usably on nim 2.2.8:
#
#   discard 1; when <hash> == <hash>: import <helper>          15 checks, 0 failing
#   import <surface>; when <hash> == <hash>: import <helper>   15 checks, 0 failing
#   control: import <helper>                                   15 checks, 2 failing
#
# with `0 reached by import` and `closure-is-readable` printing OK in both —
# the fingerprint of a gate that did not report failing to read something.
# Arms G14, G14b and G15 are those two weakenings, put back one at a time.
# ---------------------------------------------------------------------------

t="$(make_tree closure-import-refused-in-a-later-piece)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
{
	printf 'import codetracer_plugin\n'
	printf 'discard 1; when %s == %s: import ../../../raw_helper\n' "'#'" "'#'"
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "closure-is-readable" \
	"a conditional in a LATER ;-piece is examined too — the self-check is not keyed on the first token of the line" \
	"REFUSED to analyse" "discard 1;"

# The same route with a READABLE import sharing the line. Under an existence
# test this passes on the strength of `quiet_helper` — which is real, and clean,
# so a gate that stops refusing here goes green rather than failing some other
# way and looking like a pass for the right reason.
t="$(make_tree closure-import-refused-beside-a-readable-one)"
cat >"${t}/${VM}/quiet_helper.nim" <<'EOF'
proc h*() = discard
EOF
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
{
	printf 'import codetracer_plugin\n'
	printf 'import ../../../quiet_helper; when %s == %s: import ../../../raw_helper\n' "'#'" "'#'"
	printf 'proc activate*() = h()\n'
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "closure-is-readable" \
	"a line carrying ONE readable import and ONE lost import is refused — the self-check counts, it does not test existence" \
	"REFUSED to analyse" "quiet_helper"

# THE POSITIVE TWIN, on the same PLACE. Take the character literal away and the
# import in the later `;`-piece is genuinely READ, so the real rule reports it
# by name rather than the self-check refusing the line. Without this, "the
# self-check fires" would be satisfied just as well by a self-check that refused
# every later-piece conditional it met.
t="$(make_tree import-in-a-later-piece-conditional-is-read)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
discard 1; when not defined(js): import isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a denied import in a later ;-piece conditional is READ and reported by the rule, not merely refused" \
	"isonim/core/owner"

t="$(make_tree later-piece-conditional-is-not-a-refusal)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
discard 1; when not defined(js): import std/os
proc activate*() = discard
EOF
assert_clean "${t}" \
	"the same shape carrying a READABLE import is clean — examining every ;-piece costs nothing"

# AND THE WIDENING THAT WAS REJECTED IS STILL REJECTED. Extending the self-check
# from "some `;`-piece opens a conditional" to EVERY LINE was measured and
# refused: six real prose comments in this repository carry a `;` before the
# word `from` and eleven more carry a `:` before `import` or `from`, and all
# seventeen would go red for nothing. This case is that bound, so the next
# author to reach for the wider form finds out from a suite rather than from a
# tree full of red.
t="$(make_tree prose-semicolon-before-from-is-not-a-refusal)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
## Read the manifest first; from there the resolution order follows.
## The rule is simple: import only through the surface.
import codetracer_plugin
proc activate*() = discard
EOF
assert_clean "${t}" \
	"prose carrying ';' before 'from' or ':' before 'import' is not a refusal — the self-check is per ;-piece, not per line"

# ---------------------------------------------------------------------------
# THE GATE ON THE SELF-CHECK IS ASKED OF THREE RENDERINGS OF THE LINE — the
# SIXTH route past this boundary, measured on 2026-09-08.
#
# The two routes above were closed by making the self-check per-piece and
# counted. Neither touched the GATE that decides whether the self-check runs at
# all, and that gate was a plain regex over the RAW line requiring only
# whitespace between the `;` and the `when`. A BLOCK COMMENT is legal there:
#
#   discard 1; #[c]# when <hash> == <hash>: import <helper>
#
# `strip_comment` removes `#[c]#`, so the shape is invisible in the raw text and
# present in the stripped text — the gate returned 0, the character-literal
# desync then hid the import, and the gate printed `15 checks, 0 failing` with
# `closure-is-readable` OK. Both compile on nim 2.2.8 and import usably.
#
# THE OBVIOUS REPAIR WAS A TRADE AND IS PINNED AGAINST HERE. Moving the gate
# from the raw line to the stripped line catches those two and REOPENS
# `discard <hash-literal>; when <hash> == <hash>: import <helper>`, which the
# raw gate caught: `strip_comment` cuts at the `#` inside that leading literal,
# so the stripped line has neither a `;` nor a `when` on it. The two renderings
# resolve a `#` in opposite directions, so the gate now asks BOTH, plus a
# third — quote-blind, block-comments-only. The four cases below are the two
# routes, the reopened one, and the positive twin that stops "the gate fires"
# being satisfied by a gate that refuses every line carrying a `#[`.
# ---------------------------------------------------------------------------

t="$(make_tree closure-block-comment-between-semicolon-and-when)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
{
	printf 'import codetracer_plugin\n'
	printf 'discard 1; #[c]# when %s == %s: import ../../../raw_helper\n' "'#'" "'#'"
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "closure-is-readable" \
	"a BLOCK COMMENT between the ';' and the 'when' does not switch the self-check off — the gate reads the stripped line too" \
	"REFUSED to analyse" "discard 1;"

t="$(make_tree closure-block-comment-with-inverted-quote-parity)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
{
	printf 'import codetracer_plugin\n'
	printf 'discard 1; #[c]# when %s != %s: import ../../../raw_helper\n' "'\"'" "'x'"
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "closure-is-readable" \
	"the same route with the quote parity inverted instead of the comment cut is refused too" \
	"REFUSED to analyse"

# THE ONE A GATE READING ONLY THE STRIPPED LINE WOULD LOSE. This case is the
# reason the gate is a disjunction rather than a substitution: it passed on the
# tree this repair started from, and the one-line "read the stripped line
# instead" fix reopened it. Without this case nothing would have said so.
t="$(make_tree closure-leading-hash-literal-truncates-the-strip)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
{
	printf 'import codetracer_plugin\n'
	printf 'discard %s; when %s == %s: import ../../../raw_helper\n' "'#'" "'#'" "'#'"
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "closure-is-readable" \
	"a leading character literal that truncates the comment strip is still refused — the gate reads the RAW line too" \
	"REFUSED to analyse"

# THE POSITIVE TWIN. A block comment on the line, a later-piece conditional, and
# an import the scans CAN read: the rule must report it BY NAME rather than the
# self-check refusing the line. A gate that reddened every line carrying a `#[`
# would satisfy the three cases above and fail this one.
t="$(make_tree block-comment-line-with-a-readable-import-is-read)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
discard 1; #[c]# when not defined(js): import isonim/core/owner
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a denied import behind a block comment and a later-piece conditional is READ and reported by name, not merely refused" \
	"isonim/core/owner"

t="$(make_tree block-comment-line-with-a-clean-import-is-clean)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
discard 1; #[c]# when not defined(js): import std/os
proc activate*() = discard
EOF
assert_clean "${t}" \
	"the same shape carrying a READABLE import is clean — the three-rendering gate costs nothing"

# ---------------------------------------------------------------------------
# THE SEVENTH ROUTE WAS AT THE CALL SITE, NOT IN ANY RENDERING — 2026-09-08.
#
# Five passes hardened `imports_unread` and none of them touched how it is
# INVOKED. It was called as `collecting == 0 && imports_unread($0, line)`, so on
# a CONTINUATION LINE of a multi-line import — the spelling 138 files under
# `src/` use — the self-check did not run at all:
#
#   import
#     <surface>; when <hash-lit> == <hash-lit>: import <helper>
#
# NO RENDERING IS DESYNCHRONISED HERE. All three see the conditional; the gate
# is simply never asked. That is what puts this outside both documented residual
# shapes — shape 1 needs a line no rendering can see a conditional on, shape 2
# needs all three defeated at once — and it is materially cheaper than either:
# one ordinary multi-line import plus one character literal.
#
# Measured against this gate, this fixture and a real helper module, both
# spellings compiling on nim 2.2.8 and importing usably:
#
#   import <surface>; when <hash> == <hash>: import <helper>   REFUSED (control)
#   import ⏎ <surface>; when <hash> == <hash>: import <helper> read, ZERO specs
#
# The `from`-continuation is the same route and is graded beside it.
# ---------------------------------------------------------------------------

t="$(make_tree closure-conditional-on-an-import-continuation-line)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
{
	printf 'import\n'
	printf '  codetracer_plugin; when %s == %s: import ../../../raw_helper\n' "'#'" "'#'"
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "closure-is-readable" \
	"a desynchronised conditional on the CONTINUATION LINE of a multi-line import is refused — the self-check is asked of every line, not only of a line that starts a statement" \
	"REFUSED to analyse" "codetracer_plugin;"

t="$(make_tree closure-conditional-on-a-from-continuation-line)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
{
	printf 'import codetracer_plugin\n'
	printf 'from\n'
	printf '  ../../../quiet_helper import h; when %s == %s: import ../../../raw_helper\n' "'#'" "'#'"
} >"${t}/${FIXTURES}/p.nim"
cat >"${t}/${VM}/quiet_helper.nim" <<'EOF'
proc h*() = discard
EOF
assert_fires "${t}" "closure-is-readable" \
	"the same route reached through a 'from' continuation is refused too" \
	"REFUSED to analyse"

# THE POSITIVE TWIN FOR THE CALL SITE. Take the character literal away and the
# continuation line is genuinely READ: both the module the continuation names
# AND the import in its later `;`-piece come out, so the real rule reports the
# denied one by name. Without this, "the self-check now runs on continuation
# lines" would be satisfied just as well by one that refused every continuation
# line — which would make the 138 multi-line imports under `src/` unreadable.
t="$(make_tree import-continuation-line-with-a-readable-conditional-is-read)"
{
	printf 'import\n'
	printf '  codetracer_plugin; when not defined(js): import isonim/core/owner\n'
} >"${t}/${FIXTURES}/p.nim"
assert_fires "${t}" "plugin-imports-narrow" \
	"a denied import in a later ;-piece of a CONTINUATION line is READ and reported by the rule, not merely refused" \
	"isonim/core/owner"

t="$(make_tree import-continuation-line-with-a-clean-import-is-clean)"
{
	printf 'import\n'
	printf '  codetracer_plugin; when not defined(js): import std/os\n'
	printf 'proc activate*() = discard\n'
} >"${t}/${FIXTURES}/p.nim"
assert_clean "${t}" \
	"the same continuation shape carrying a READABLE import is clean — asking the self-check on every line costs nothing"

# ---------------------------------------------------------------------------
# HOW A PLUGIN IS DECLARED — the `## CT-PLUGIN:` HEADER path
#
# Both spellings are documented; until 2026-09-08 only one was measured. Setting
# `head -n "${MARKER_SCAN_LINES}"` to `head -n 0` disabled the header path
# entirely and left the gate at 15/0 and this suite at 48/0 — a declaration
# mechanism nothing could reach. It was kept rather than deleted because the
# sibling gate's identical `## SDK-CONSUMER:` carries 11 real files, and the
# argument for two spellings here is that they are the SAME two. So it is graded
# instead: enrolment, and the bound on it. Arm G12 kills the first.
# ---------------------------------------------------------------------------

t="$(make_tree header-marker-declares-a-plugin)"
mkdir -p "${t}/${VM}/loose"
cat >"${t}/${VM}/loose/header_plugin.nim" <<'EOF'
## CT-PLUGIN: declared by header marker, in a directory with no .ct-plugin file.
import codetracer_plugin
import isonim/core/computation
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a '## CT-PLUGIN:' HEADER declares a plugin outside any .ct-plugin tree, and the rules bind it" \
	"loose/header_plugin.nim" "isonim/core/computation"

# THE BOUND ON THE SAME PATH. `MARKER_SCAN_LINES` is a claim — a marker further
# in is not a declaration — and a bound nothing tests is a number that can drift
# to zero without anything noticing, which is exactly how the path went
# unmeasured in the first place. The file below is byte-for-byte the case above
# with the marker pushed past line 40, and it must NOT be enrolled.
t="$(make_tree header-marker-past-the-scan-bound)"
mkdir -p "${t}/${VM}/loose"
{
	for i in $(seq 1 45); do echo "# filler line ${i}"; done
	echo '## CT-PLUGIN: too far in to count as a declaration.'
	echo 'import codetracer_plugin'
	echo 'import isonim/core/computation'
} >"${t}/${VM}/loose/header_plugin.nim"
assert_clean "${t}" \
	"the same marker past line 40 does NOT declare a plugin — the scan bound is a rule, not a habit"

# ---------------------------------------------------------------------------
# plugin-names-no-raw-primitive
#
# The module-qualified case is the one this whole rule exists for: `export …
# except` filters unqualified lookup only, so `computation.createEffect(…)`
# COMPILES on the plugin surface. Measured on nim 2.2.8, and it reproduces the
# unbudgeted 160 ms run exactly.
# ---------------------------------------------------------------------------

t="$(make_tree qualified-call)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc activate*() =
  computation.createEffect(proc() = discard)
EOF
assert_fires "${t}" "plugin-names-no-raw-primitive" \
	"the MODULE-QUALIFIED call the surface cannot filter is caught" \
	"createEffect" "use ctx.pluginEffect instead"

t="$(make_tree unqualified-call)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc activate*() =
  createEffect(proc() = discard)
EOF
assert_fires "${t}" "plugin-names-no-raw-primitive" \
	"the unqualified call is caught too, so the gate does not rely on the compiler" \
	"createEffect"

t="$(make_tree facade-qualified-call)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc activate*() =
  codetracer_embed.createRoot(proc(dispose: proc()) = discard)
EOF
assert_fires "${t}" "plugin-names-no-raw-primitive" \
	"qualifying through the FACADE's own name is caught as well" \
	"createRoot" "use ctx.pluginRoot instead"

t="$(make_tree prose-only-mention)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
## This plugin does not call createEffect or createRoot; it uses the wrappers.
import codetracer_plugin
proc activate*() =
  pluginEffect("x", proc() = discard)
EOF
assert_clean "${t}" \
	"a denied primitive named only in a DOC COMMENT is not a finding (prose has no ABI)"

t="$(make_tree substring-is-not-a-word)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc myCreateEffectHelper*() = discard
proc activate*() =
  pluginEffect("x", proc() = myCreateEffectHelper())
EOF
assert_clean "${t}" \
	"an identifier merely CONTAINING a denied name is not a finding"

t="$(make_tree undeclared-file)"
mkdir -p "${work}/undeclared-file/other"
cat >"${work}/undeclared-file/other/tool.nim" <<'EOF'
import isonim/core/computation
proc go*() = createEffect(proc() = discard)
EOF
assert_clean "${t}" \
	"an undeclared file NO PLUGIN IMPORTS may still use the raw primitives (nothing is a plugin by accident)"

t="$(make_tree undeclared-file-used-by-undeclared-file)"
mkdir -p "${work}/undeclared-file-used-by-undeclared-file/other"
cat >"${work}/undeclared-file-used-by-undeclared-file/other/tool.nim" <<'EOF'
import isonim/core/computation
proc go*() = createEffect(proc() = discard)
EOF
cat >"${work}/undeclared-file-used-by-undeclared-file/other/app.nim" <<'EOF'
import tool
proc main*() = go()
EOF
assert_clean "${t}" \
	"the closure is rooted at DECLARED plugins: an undeclared consumer of a raw helper is not a finding"

# ---------------------------------------------------------------------------
# THE HELPER-MODULE EXPLOIT — the reason checks 1 and 2 range over the closure
#
# Measured on the real tree before this rule existed, with both mechanisms green
# and the gate reporting `12 check(s), 0 failing`:
#
#     rawRuns=4  budgeted runs=0  violations=0  suspended=false
#
# The plugin imported nothing but the sanctioned surface. One ordinary,
# undeclared helper module gave it a raw `createEffect` anyway, and §5.4's
# "every computation a plugin has is one the host created" was false.
# ---------------------------------------------------------------------------

t="$(make_tree helper-imports-the-primitive)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../raw_helper
proc activate*() = rawEffect(proc() = discard)
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a plugin reaching the primitive through ONE undeclared helper module is caught" \
	"raw_helper.nim" "isonim/core/computation"

t="$(make_tree helper-names-the-primitive)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../raw_helper
proc activate*() = rawEffect(proc() = discard)
EOF
assert_fires "${t}" "plugin-names-no-raw-primitive" \
	"the same helper is caught by the NAME rule too, not only by the import rule" \
	"raw_helper.nim:2:createEffect" "use ctx.pluginEffect instead"

# TWO HOPS, because one hop is not the rule. A helper's helper is as reachable
# as a helper, and a walk that stopped at depth one would pass this while
# printing exactly the same line for the case above.
t="$(make_tree helper-of-a-helper)"
cat >"${t}/${VM}/raw_helper.nim" <<'EOF'
import isonim/core/computation as c
proc rawEffect*(body: proc()) = c.createEffect(body)
EOF
cat >"${t}/${VM}/polite_helper.nim" <<'EOF'
import raw_helper
proc politely*(body: proc()) = rawEffect(body)
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../polite_helper
proc activate*() = politely(proc() = discard)
EOF
assert_fires "${t}" "plugin-imports-narrow" \
	"a plugin reaching the primitive through TWO helper modules is caught (the walk is transitive)" \
	"raw_helper.nim" "isonim/core/computation"

# TERMINATION. Nim permits a cycle between modules and the walk must visit each
# file once rather than spin. A hang here is a hang of the whole lint, so this
# case is a bound on the walk and not only a correctness check.
t="$(make_tree helper-cycle)"
cat >"${t}/${VM}/helper_a.nim" <<'EOF'
import helper_b
proc a*() = b()
EOF
cat >"${t}/${VM}/helper_b.nim" <<'EOF'
import helper_a
proc b*() = discard
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../helper_a
proc activate*() = a()
EOF
assert_clean "${t}" \
	"a CYCLE between two helper modules terminates and is clean (neither reaches a primitive)"

# THE SURFACE IS A TERMINAL, and that is load-bearing rather than an
# optimisation: `codetracer_plugin.nim` imports `codetracer_embed`, which is a
# DENIED import. A walk that entered it would report every plugin in the tree
# for consuming the surface exactly as it is supposed to.
t="$(make_tree surface-is-a-terminal)"
assert_clean "${t}" \
	"the sanctioned surface is reached and NOT walked, so its own facade import is not a finding"

# ---------------------------------------------------------------------------
# closure-is-readable — the boundary of the walk, stated as a rule
# ---------------------------------------------------------------------------

t="$(make_tree closure-unreadable-import)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import strutils
proc activate*() = discard "x".strip()
EOF
assert_fires "${t}" "closure-is-readable" \
	"a spec that resolves to no repository file is a finding: the gate cannot bind what it cannot read" \
	"imports 'strutils'" "resolves to no file"

t="$(make_tree closure-stdlib-import)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import std/[strutils, monotimes]
proc activate*() = discard "x".strip()
EOF
assert_clean "${t}" \
	"the SAME import spelled 'std/…' is admitted — the standard library carries no reactive primitive"

t="$(make_tree closure-unreadable-in-a-helper)"
cat >"${t}/${VM}/quiet_helper.nim" <<'EOF'
import somepackage/reactive
proc h*() = discard
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../quiet_helper
proc activate*() = h()
EOF
assert_fires "${t}" "closure-is-readable" \
	"the readability rule binds the whole closure, not only the declared file" \
	"quiet_helper.nim" "somepackage/reactive"

# ---------------------------------------------------------------------------
# THE CLOSURE WALK'S OWN CONTROLS, BROKEN ON PURPOSE.
#
# Checks 12 and 13 are what make "the closure is clean" mean something. Break
# what each is asserted over and the gate must redden — otherwise they are two
# more lines that have only ever been watched printing OK.
# ---------------------------------------------------------------------------

t="$(make_tree control-plugin-imports-no-surface)"
cat >"${t}/${FIXTURES}/position_watch_plugin.nim" <<'EOF'
## There is no createEffect, no createRoot and no getOwner in this file's code.
proc activate*() = discard
EOF
assert_fires "${t}" "closure-walks-past-its-seed" \
	"the one-hop control reddens when its seed stops reaching anything" \
	"expected 2"

t="$(make_tree control-surface-does-not-reach-the-facade)"
cat >"${t}/${VM}/codetracer_plugin.nim" <<'EOF'
export codetracer_embed except
  createEffect, createRoot, getOwner
const CodeTracerPluginSurfaceModule* = "codetracer_plugin"
EOF
assert_fires "${t}" "closure-walks-transitively" \
	"the transitive control reddens when the second hop disappears" \
	"stops after one hop"

# ---------------------------------------------------------------------------
# subject-declared / denied-set-nonempty — the vacuity floors
# ---------------------------------------------------------------------------

t="$(make_tree no-plugins)"
rm "${t}/${FIXTURES}/.ct-plugin"
assert_fires "${t}" "subject-declared" \
	"a tree with no declared plugin fails rather than passing vacuously" \
	"pass vacuously"

t="$(make_tree empty-denied-set)"
cat >"${t}/${VM}/plugin_host/plugin_api.nim" <<'EOF'
## No table at all.
proc pluginEffect*(name: string; body: proc()) = discard
EOF
assert_fires "${t}" "denied-set-nonempty" \
	"an empty primitives table fails rather than making check 2 scan for nothing" \
	"check 2 scans for nothing"

# ---------------------------------------------------------------------------
# surface-present / surface-narrows / denied-list-agrees
# ---------------------------------------------------------------------------

t="$(make_tree surface-missing)"
rm "${t}/${VM}/codetracer_plugin.nim"
assert_fires "${t}" "surface-present" \
	"a missing plugin surface is reported, not ignored" \
	"does not exist"

t="$(make_tree surface-constant-drifted)"
cat >"${t}/${VM}/codetracer_plugin.nim" <<'EOF'
import codetracer_embed
export codetracer_embed except
  createEffect, createRoot, getOwner
const SomeOtherName* = "codetracer_plugin"
EOF
assert_fires "${t}" "surface-present" \
	"a surface that no longer declares its own name is reported" \
	"drifted apart"

t="$(make_tree surface-exports-whole)"
cat >"${t}/${VM}/codetracer_plugin.nim" <<'EOF'
import codetracer_embed
export codetracer_embed
const CodeTracerPluginSurfaceModule* = "codetracer_plugin"
EOF
assert_fires "${t}" "surface-narrows" \
	"a surface that re-exports the facade WHOLE is caught, though checks 1 and 2 stay green" \
	"re-exports codetracer_embed WHOLE"

t="$(make_tree surface-drops-one)"
cat >"${t}/${VM}/codetracer_plugin.nim" <<'EOF'
import codetracer_embed
export codetracer_embed except
  createEffect, createRoot
const CodeTracerPluginSurfaceModule* = "codetracer_plugin"
EOF
assert_fires "${t}" "denied-list-agrees" \
	"a primitive in the table but NOT filtered by the surface is caught" \
	"getOwner" "NOT filtered by the surface"

t="$(make_tree surface-filters-extra)"
cat >"${t}/${VM}/codetracer_plugin.nim" <<'EOF'
import codetracer_embed
export codetracer_embed except
  createEffect, createRoot, getOwner, createMemo
const CodeTracerPluginSurfaceModule* = "codetracer_plugin"
EOF
assert_fires "${t}" "denied-list-agrees" \
	"a name filtered by the surface but NOT in the table is caught (check 2 would not scan for it)" \
	"createMemo" "does not scan for it"

# ---------------------------------------------------------------------------
# THE GATE'S OWN CONTROLS, BROKEN ON PURPOSE.
#
# Checks 6, 7 and 8 exist so that "check 1 is clean" and "check 2 is clean" mean
# something. These four cases are the evidence that they do: each removes the
# thing a control is asserted over and requires the gate to redden. Without
# them, a control is a line that has only ever been watched printing OK — the
# very thing this suite exists to reject.
# ---------------------------------------------------------------------------

t="$(make_tree control-facade-has-no-denied-import)"
cat >"${t}/${VM}/codetracer_embed.nim" <<'EOF'
import plugin_host/plugin_api
export plugin_api
const CodeTracerEmbedFacadeModule* = "codetracer_embed"
EOF
assert_fires "${t}" "import-scan-reads-code" \
	"the import control reddens when its subject stops importing the denied modules" \
	"Check 1's clean result is not evidence"

t="$(make_tree control-facade-imports-only-one)"
cat >"${t}/${VM}/codetracer_embed.nim" <<'EOF'
import isonim/core/computation
export computation
import plugin_host/plugin_api
export plugin_api
const CodeTracerEmbedFacadeModule* = "codetracer_embed"
EOF
assert_fires "${t}" "import-scan-reads-code" \
	"the import control asserts the COUNT, so finding one of two denied imports is not enough" \
	"expected 2"

# THE NAME CONTROL CAN SAY NO, and this is what it takes to make it.
#
# Its subject cannot stop naming the primitives — the table IS the list, so the
# two move together — which would make it a control that never fires
# (Verification-Harness-Traps §10: a check no input can fail is documentation
# with a call site). What CAN break is the scanner beneath it. Here the table's
# rows are commented out: `denied_primitives` still parses three names from
# them, `code_lines` correctly strips them, and `denied_names_in` therefore
# finds nothing in code — exactly the shape a broken comment-stripper or a
# broken word-boundary would produce, and the gate must redden.
t="$(make_tree control-primitives-named-only-in-prose)"
cat >"${t}/${VM}/plugin_host/plugin_api.nim" <<'EOF'
const
  PluginDeniedPrimitives*: array[3, tuple[primitive, replacement: string]] = [
    ## ("createEffect", "ctx.pluginEffect"),
    ## ("createRoot",   "ctx.pluginRoot"),
    ## ("getOwner",     "ctx.scope"),
  ]
EOF
assert_fires "${t}" "name-scan-reads-code" \
	"the name control reddens when the scanner can no longer find the primitives in code" \
	"Check 2's clean result is not evidence"

t="$(make_tree control-prose-probe-says-nothing)"
cat >"${t}/${FIXTURES}/position_watch_plugin.nim" <<'EOF'
import codetracer_plugin
proc activate*() =
  pluginEffect("watch", proc() = discard)
EOF
assert_fires "${t}" "prose-is-not-code" \
	"the comment-stripper control reddens when its subject names no denied primitive at all" \
	"names no denied primitive at all"

t="$(make_tree control-prose-probe-has-it-in-code)"
cat >"${t}/${FIXTURES}/position_watch_plugin.nim" <<'EOF'
## Mentions createEffect in prose AND calls it.
import codetracer_plugin
proc activate*() =
  createEffect(proc() = discard)
EOF
assert_fires "${t}" "prose-is-not-code" \
	"a denied primitive surviving the stripper is reported as a control failure too" \
	"survived comment stripping"

# ---------------------------------------------------------------------------
# compiles-is-not-a-call — the one form-shaped exemption, in three directions
#
# `compiles(createEffect(…))` is a compile-time boolean whose argument is never
# instantiated, so it names the routine without any possibility of calling it —
# and it is how the denial is ASSERTED, in a fixture built out of twenty-one of
# them. A rule that could not tell that form from a call would redden on its own
# evidence. The exemption is on the FORM and not on a named file, because a
# named file is an exemption a second file can quietly join and a form cannot be
# abused.
# ---------------------------------------------------------------------------

t="$(make_tree compiles-only-is-clean)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
const AsksTheCompiler* = compiles(createEffect(proc() = discard))
EOF
assert_clean "${t}" \
	"a plugin that only ASKS whether a primitive resolves is not a finding"

# BOTH ORDERINGS, and they are not the same case. A strip that cut from
# `compiles(` to the end of the line passes the first and MISSES the second —
# which is what a mutation arm found, over a fixture that only had the first.
t="$(make_tree compiles-call-before)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc activate*() =
  createRoot(proc(d: proc()) = discard); discard compiles(createEffect(nil))
EOF
assert_fires "${t}" "plugin-names-no-raw-primitive" \
	"a real call BEFORE a compiles() on the same line is still caught" \
	"createRoot"

t="$(make_tree compiles-call-after)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc activate*() =
  discard compiles(createEffect(nil)); createRoot(proc(d: proc()) = discard)
EOF
assert_fires "${t}" "plugin-names-no-raw-primitive" \
	"a real call AFTER a compiles() on the same line is still caught — the strip is balanced, not to end-of-line" \
	"createRoot"

t="$(make_tree compiles-probe-names-too-few)"
cat >"${t}/${FIXTURES}/surface_probe_plugin.nim" <<'EOF'
import codetracer_plugin
const RawEffectInScope* = compiles(createEffect(proc() = discard))
EOF
assert_fires "${t}" "compiles-is-not-a-call" \
	"a probe that asks about fewer primitives than the rule denies is caught" \
	"of 3 denied primitive(s) in code"

t="$(make_tree compiles-probe-actually-calls)"
cat >"${t}/${FIXTURES}/surface_probe_plugin.nim" <<'EOF'
import codetracer_plugin
const RawEffectInScope* = compiles(createEffect(proc() = discard))
const RawRootInScope* = compiles(createRoot(proc(dispose: proc()) = discard))
proc activate*() =
  discard getOwner()
EOF
assert_fires "${t}" "compiles-is-not-a-call" \
	"a probe with a denied name surviving the strip is reported as a control failure" \
	"survived strip_compiles"

# ---------------------------------------------------------------------------
# plugin-uses-the-surface — the positive twin of check 1
# ---------------------------------------------------------------------------

t="$(make_tree plugin-imports-nothing)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
proc activate*() = discard
EOF
assert_fires "${t}" "plugin-uses-the-surface" \
	"a plugin that imports NOTHING satisfies every 'must not import' rule and is still caught" \
	"imports nothing satisfies every rule above vacuously"

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

# THE STATUS IS CAPTURED INTO A VARIABLE FIRST, and that is a fix rather than a
# lint concession (SC2319). Inside the inner `else`, `$?` is the status of the
# `[ ... ]` test that just ran — always 1 — not the guard's, so the failure
# message reported `got exit 1` whatever the guard had actually done. A
# diagnostic that cannot name the number it exists to report is trap 4's shape
# one level down: it would still have failed, and it would have said nothing
# useful about why.
bash "${guard}" --nonsense >/dev/null 2>&1
guard_arg_status=$?
if [ "${guard_arg_status}" -eq 0 ]; then
	bad "an unknown argument is refused with exit 2" "the guard exited 0"
elif [ "${guard_arg_status}" -eq 2 ]; then
	ok "an unknown argument is refused with exit 2, not with a finding"
else
	bad "an unknown argument is refused with exit 2" "got exit ${guard_arg_status}"
fi

t="$(make_tree list-plugins-mode)"
listed="$(bash "${guard}" --root "${t}" --list-plugins 2>&1)"
if grep -qF "${FIXTURES}/position_watch_plugin.nim" <<<"${listed}"; then
	ok "--list-plugins names the declared plugins it would check"
else
	bad "--list-plugins names the declared plugins it would check" "${listed}"
fi

t="$(make_tree list-closure-mode)"
cat >"${t}/${VM}/quiet_helper.nim" <<'EOF'
proc h*() = discard
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../quiet_helper
proc activate*() = h()
EOF
listed="$(bash "${guard}" --root "${t}" --list-closure 2>&1)"
if grep -qF "${VM}/quiet_helper.nim" <<<"${listed}" &&
	grep -qF "${FIXTURES}/p.nim" <<<"${listed}" &&
	! grep -qF "${VM}/codetracer_plugin.nim" <<<"${listed}"; then
	ok "--list-closure names the reached helper, the declared plugin, and NOT the terminal surface"
else
	bad "--list-closure names the reached helper, the declared plugin, and NOT the terminal surface" "${listed}"
fi

# ---------------------------------------------------------------------------
# The real repository
# ---------------------------------------------------------------------------

real_output="$(cd "${repo_root}" && bash "${guard}" 2>&1)"
real_status=$?
if [ "${real_status}" -eq 0 ]; then
	ok "the guard passes on this repository"
else
	bad "the guard passes on this repository" "${real_output}"
fi

echo "--- ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
