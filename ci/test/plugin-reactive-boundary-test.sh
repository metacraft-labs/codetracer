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
COMMON="src/common"
FIXTURES="${VM}/tests/unit/plugin_fixtures"

# THE DERIVED `system` SURFACE, COMPUTED ONCE.
#
# Check 23 ranges over the names the PINNED COMPILER puts in every plugin's
# scope, and requires each to be on `PluginDeniedSyncIo` or on
# `PluginSystemSurfaceExempt` IN THE TREE UNDER TEST. Every synthetic tree here
# carries a three-entry denied table on purpose — the gate reads whatever the
# table holds and three is readable — so without an exempt table each of the
# hundred-odd cases below would fail check 23 for a reason that has nothing to
# do with the case.
#
# So `make_tree` generates one, from the SAME sweep the gate uses. That keeps
# the baseline clean AND keeps check 23 live in every case rather than skipped:
# the two cases at the end remove a row from it and assert the check notices.
#
# COMPUTED ONCE AND NOT PER TREE: the sweep shells out to `nim dump`, and a
# hundred `make_tree` calls would have put a hundred of those in a suite that
# takes under a minute.
# Same `source=` / SC1091 pair as the `nim-imports.sh` line above, and for
# the same reason: the pre-commit hook runs shellcheck without -x and cannot
# follow a sourced file at all.
# shellcheck source=ci/lib/system-io-surface.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/system-io-surface.sh"
SYSTEM_SURFACE_ALL="$(system_surface_names 2>/dev/null || true)"
# The fixture's denied table holds `readFile`; a name on both tables would be a
# fixture that disagrees with itself, so the exempt half is the complement.
SYSTEM_SURFACE_EXEMPTABLE="$(grep -vxF -e waitFor -e readFile -e startProcess \
	<<<"${SYSTEM_SURFACE_ALL}" || true)"

# system_exempt_table [OMIT] — the fixture table, as nim source. With OMIT, that
# one name is left out, which is exactly the finding check 23 exists to make.
system_exempt_table() {
	local omit="${1:-}" n rows count
	rows=""
	while IFS= read -r n; do
		[ -n "${n}" ] || continue
		[ "${n}" != "${omit}" ] || continue
		rows="${rows}    (\"${n}\", \"fixture: the synthetic tree exempts the derived surface so a case is about its own subject\"),"$'\n'
	done <<<"${SYSTEM_SURFACE_EXEMPTABLE}"
	# THE DECLARED LENGTH IS COUNTED, NOT GUESSED. Check 24 asserts that every
	# table returns as many rows as its `array[N, …]` says it has, in whatever
	# tree the gate is pointed at — so a fixture whose header disagreed with its
	# body would fail that control rather than the case under test.
	count="$(grep -c . <<<"${rows}" || true)"
	echo "const"
	echo "  PluginSystemSurfaceExempt*: array[${count}, tuple[primitive, replacement: string]] = ["
	printf '%s' "${rows}"
	echo "  ]"
}

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
	mkdir -p "${t}/${VM}/plugin_host" "${t}/${FIXTURES}" "${t}/${COMMON}/plugin_model"

	# PLAT-8's THIRD list, and the only ALLOW-list of the three. Three entries
	# rather than twenty-one for the same reason the denied table above has
	# three: the gate reads whatever the table holds, and three is readable.
	#
	# `std/strutils` is here because check 20's NEGATIVE half needs an admitted
	# module that the SDK module below actually imports — without it that half
	# is satisfied by an import that is not there, which is
	# Verification-Harness-Traps §4 inside the control.
	cat >"${t}/${COMMON}/plugin_model/source_admission.nim" <<'EOF'
## The source-level admission policy. Its header names std/posix in prose.
const
  PluginAllowedStdlibModules*: array[3, tuple[primitive, replacement: string]] = [
    ("std/strutils", "string manipulation over values already in memory"),
    ("std/tables", "hash tables over in-memory values"),
    ("std/times", "a clock is not a mediated kind"),
  ]

  PluginDeniedFfiPragmas*: array[3, tuple[primitive, replacement: string]] = [
    ("importc", "call the SDK"),
    ("header", "call the SDK"),
    ("dynlib", "call the SDK"),
  ]
EOF

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

	# PLAT-8's second denied set, and the module the gate holds to the same
	# rule it holds a plugin to. It names every entry in a string literal (the
	# table), one of them in an `export … except` clause, and one of them in
	# real code — which is the hostOnly entry. Checks 14 to 17 all read this.
	cat >"${t}/${VM}/plugin_host/plugin_io.nim" <<'EOF'
## The I/O primitives. Its header names waitFor and readFile in prose.
import codetracer_embed
export asyncdispatch except waitFor, runForever

# NINE UNADMITTED MODULES AND ONE ADMITTED ONE. This is check 20's subject: the
# SDK module that reaches the operating system SO THAT A PLUGIN NEED NOT, which
# makes it the file guaranteed to carry unadmitted imports. The count matches
# `ALLOWLIST_CONTROL_UNADMITTED` in the gate, and `std/strutils` is the
# admitted import the control's negative half needs.
import std/strutils
import std/[asyncdispatch, asyncfile, asyncnet, nativesockets, net, os,
            osproc, posix, strtabs]

const
  PluginDeniedSyncIo*: array[3,
      tuple[primitive, replacement: string, hostOnly: bool]] = [
    ("waitFor",      "await",            false),
    ("readFile",     "ctx.readPath",     false),
    ("startProcess", "ctx.spawnProcess", true),
  ]

proc spawnProcess*(name: string) =
  discard startProcess(name)

# Check 22's POSITIVE subject: the SDK legitimately binds a C constant, so the
# scan has something to find. `plugin_api.nim` beside it carries no pragma at
# all and is the same control's NEGATIVE subject.
let O_NOFOLLOW_CT {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
EOF

	# Check 23's other table, generated from the same sweep the gate reads.
	# See `system_exempt_table` above for why it is here rather than written
	# out: without it every case in this file would fail check 23 for a reason
	# that has nothing to do with the case.
	system_exempt_table >>"${t}/${VM}/plugin_host/plugin_io.nim"

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
## `std/times` is on the allow-list, so the clean baseline exercises check 19's
## ADMITTED path rather than only its empty one — a rule graded only on files
## that import no std module at all is a rule nothing has ever let through.
import std/times

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
discard 1; when not defined(js): import std/strutils
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
discard 1; #[c]# when not defined(js): import std/strutils
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
	printf '  codetracer_plugin; when not defined(js): import std/strutils\n'
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
import std/[strutils, times]
proc activate*() = discard "x".strip()
EOF
assert_clean "${t}" \
	"the SAME import spelled 'std/…' AND on the allow-list is clean — check 11 stops asking and check 19 says yes"

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
# PLAT-8: sync-io-set-nonempty, plugin-names-no-sync-io, sdk-does-not-block
#
# The same three shapes PLAT-7's set gets: the set can be empty (§4/§6a), the
# rule can be broken in the declared file OR in a helper one hop away, and the
# scanner must tell code from prose, from a string literal and from an
# `export … except` clause.
# ---------------------------------------------------------------------------

t="$(make_tree sync-io-module-missing)"
rm -f "${t}/${VM}/plugin_host/plugin_io.nim"
assert_fires "${t}" "sync-io-set-nonempty" \
	"a tree with no plugin_io.nim is a finding, not a silently skipped check" \
	"plugin_io.nim does not exist"

t="$(make_tree sync-io-table-empty)"
cat >"${t}/${VM}/plugin_host/plugin_io.nim" <<'EOF'
import codetracer_embed

# The imports and the pragma are carried over from the baseline UNCHANGED, so
# this case still differs from it in exactly one way. Without them checks 20 and
# 22 lose their subject and fire alongside check 14, and a case that trips three
# checks is a case that has stopped saying which one it is about.
import std/strutils
import std/[asyncdispatch, asyncfile, asyncnet, nativesockets, net, os,
            osproc, posix, strtabs]

const
  PluginDeniedSyncIo*: array[0,
      tuple[primitive, replacement: string, hostOnly: bool]] = [
  ]

let O_NOFOLLOW_CT {.importc: "O_NOFOLLOW", header: "<fcntl.h>".}: cint
EOF
assert_fires "${t}" "sync-io-set-nonempty" \
	"an empty denied-sync-io table is a finding rather than a vacuous pass" \
	"no primitive parsed"

t="$(make_tree sync-io-in-plugin)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin

proc activate*() =
  let text = readFile("/etc/hosts")
  discard text
EOF
assert_fires "${t}" "plugin-names-no-sync-io" \
	"a plugin calling readFile is caught — system's readFile cannot be filtered from any scope" \
	"readFile" "ctx.readPath"

t="$(make_tree sync-io-qualified)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin

proc activate*() =
  discard system.readFile("/etc/hosts")
EOF
assert_fires "${t}" "plugin-names-no-sync-io" \
	"the module-qualified spelling is caught too — it is what a scope filter cannot reach" \
	"readFile"

t="$(make_tree sync-io-in-helper)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../blocking_helper
EOF
cat >"${t}/${VM}/blocking_helper.nim" <<'EOF'
proc slurp*(path: string): string =
  readFile(path)
EOF
assert_fires "${t}" "plugin-names-no-sync-io" \
	"a helper module blocking on the plugin's behalf is the same finding" \
	"blocking_helper" "readFile"

t="$(make_tree sync-io-in-prose)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
## This plugin does not call readFile, execProcess or waitFor anywhere.
import codetracer_plugin

proc activate*() = discard
EOF
assert_clean "${t}" \
	"a plugin naming every sync-I/O primitive in PROSE is clean"

t="$(make_tree sync-io-in-string)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin

const Advice* = "do not call readFile or waitFor from a plugin"

proc activate*() = discard
EOF
assert_clean "${t}" \
	"a plugin naming a sync-I/O primitive inside a STRING is clean — a literal calls nothing"

t="$(make_tree sdk-blocks)"
cat >>"${t}/${VM}/plugin_host/plugin_io.nim" <<'EOF'

proc slurp*(path: string): string =
  readFile(path)
EOF
assert_fires "${t}" "sdk-does-not-block" \
	"the SDK blocking on every plugin's behalf is caught, though every plugin is clean" \
	"readFile"

t="$(make_tree sdk-exempts-itself)"
sed -i 's/("startProcess", "ctx.spawnProcess", true)/("startProcess", "ctx.spawnProcess", false)/' \
	"${t}/${VM}/plugin_host/plugin_io.nim"
assert_fires "${t}" "sdk-does-not-block" \
	"the hostOnly exemption is read from the TABLE, so clearing it reddens the gate" \
	"startProcess"

t="$(make_tree sdk-marks-a-second-entry)"
sed -i 's/("waitFor",      "await",            false)/("waitFor",      "await",            true)/' \
	"${t}/${VM}/plugin_host/plugin_io.nim"
assert_clean "${t}" \
	"marking an entry hostOnly in the table is what exempts it, and the gate says which"

# ---------------------------------------------------------------------------
# THE IMPORT ALLOW-LIST — checks 18, 19 and 20
#
# The three denied lists above answer "did the plugin name one of the things we
# thought of". These answer the complement, and they exist because the denied
# lists were MEASURED LOSING on 2026-09-09: a declared plugin importing
# `codetracer_plugin` and `std/posix` read `/etc/hostname` with no `fs:read`
# grant and fork+exec'd `/bin/sh` with no `process` grant, over a gate printing
# `19 check(s), 0 failing`.
#
# THE ACCEPTANCE CASE IS FIRST AND IT IS THE REAL EXPLOIT'S OWN BYTES. The
# probe is a committed file (`plugin_probes/posix_raw_plugin.nim.probe`) that
# `test_plugin_source_admission.nim` COMPILES AND RUNS: it reads the file and
# reaches the shell, and both effects are asserted there against sentinels
# rather than against anything either instrument printed. Copying the same
# bytes here rather than paraphrasing them is Verification-Harness-Traps §14 —
# a second copy of an exploit is a second thing that can drift while each half
# goes on agreeing with itself, and the half that would drift is the one nobody
# runs.
# ---------------------------------------------------------------------------

t="$(make_tree the-posix-probe)"
cp "${repo_root}/src/frontend/viewmodel/tests/unit/plugin_probes/posix_raw_plugin.nim.probe" \
	"${t}/${FIXTURES}/posix_raw_plugin.nim"
assert_fires "${t}" "plugin-imports-allow-listed" \
	"THE PROBE: a declared plugin importing std/posix is refused, naming the module and the import" \
	"posix_raw_plugin.nim imports std/posix" \
	"which is not in PluginAllowedStdlibModules"

# The same exploit one hop out. A boundary an undeclared helper module defeats
# is a boundary a plugin author defeats by accident — the defect PLAT-7 paid
# for on checks 1 and 2, asked of check 19 before it can be found the same way.
t="$(make_tree unadmitted-in-a-helper)"
cat >"${t}/${VM}/os_helper.nim" <<'EOF'
import std/posix
proc pid*(): int = int(getpid())
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import ../../../os_helper
proc activate*() = discard pid()
EOF
assert_fires "${t}" "plugin-imports-allow-listed" \
	"the same import ONE HOP OUT, in an undeclared helper, is refused and the HELPER is named" \
	"os_helper.nim imports std/posix"

# THE SDK'S OWN INTERNALS ARE BOUND TOO, and this is the case that says so.
# The allow-list is over `std/` specs; what keeps an SDK internal from being a
# way around it is the CLOSURE WALK, which enters every repository module a
# plugin reaches and applies the same rule there. The two TERMINALS
# (`codetracer_plugin` and `plugin_host/plugin_io`) are the deliberate
# exception — they are reached and not entered, because they are what a plugin
# calls INSTEAD of the operating system, and the case above them asserts that.
t="$(make_tree plugin-reaching-an-sdk-internal)"
cat >"${t}/${VM}/plugin_host/handles.nim" <<'EOF'
import std/os
proc handleCount*(): int = paramCount()
EOF
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import plugin_host/handles
proc activate*() = discard handleCount()
EOF
assert_fires "${t}" "plugin-imports-allow-listed" \
	"an SDK INTERNAL reached from a plugin is bound by the same rule — the walk enters it" \
	"handles.nim imports std/os"

# `std/asyncdispatch` is the one a reader will think is already handled. It is
# not: the SDK re-exports it with `waitFor`, `runForever`, `poll` and `drain`
# filtered out, and a plugin importing it ITSELF gets all four back. An
# `export … except` narrows one path and cannot narrow a second one the plugin
# opens for itself.
t="$(make_tree unadmitted-asyncdispatch)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import std/asyncdispatch
proc activate*() = discard
EOF
assert_fires "${t}" "plugin-imports-allow-listed" \
	"importing std/asyncdispatch DIRECTLY is refused — the export-except filter binds one path only" \
	"std/asyncdispatch"

# THE POSITIVE TWIN. Verification-Harness-Traps §4a: a rule that refuses
# everything passes every "is it refused" case ever written, so the case that a
# permitted import is PERMITTED is what makes the refusals above mean anything.
t="$(make_tree admitted-imports-are-clean)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import std/[strutils, tables, times]
proc activate*() = discard
EOF
assert_clean "${t}" \
	"a plugin importing only allow-listed modules is clean — the rule permits as well as refuses"

# AND THE LIST IS READ FROM THE TABLE. The pair below is the whole argument for
# the table living in nim rather than in this script: the same plugin, refused
# under the baseline list and clean once the table names the module. A gate with
# the list hardcoded passes the first case and fails the second.
t="$(make_tree unadmitted-monotimes)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import std/monotimes
proc activate*() = discard
EOF
assert_fires "${t}" "plugin-imports-allow-listed" \
	"a std module absent from the table is refused, whatever anybody thinks of it" \
	"std/monotimes"

t="$(make_tree admitted-monotimes)"
sed -i 's|("std/times", "a clock is not a mediated kind"),|("std/times", "a clock is not a mediated kind"),\n    ("std/monotimes", "a monotonic counter is not a mediated kind either"),|' \
	"${t}/${COMMON}/plugin_model/source_admission.nim"
sed -i '0,/array\[3, tuple/s//array[4, tuple/' \
	"${t}/${COMMON}/plugin_model/source_admission.nim"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import std/monotimes
proc activate*() = discard
EOF
assert_clean "${t}" \
	"the SAME module becomes clean once the TABLE names it — the gate reads it, it does not hold it"

# `system` is admitted and cannot be anything else: it is auto-imported, so
# there is no import to refuse. The case exists so the special-case in
# `stdlib_admitted` is graded rather than assumed, and so the residual has a
# line in a suite instead of only a line in a header.
t="$(make_tree system-import-is-admitted)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
import system
proc activate*() = discard
EOF
assert_clean "${t}" \
	"'import system' is admitted — it is auto-imported anyway, so refusing the spelling would buy nothing"

t="$(make_tree allow-list-table-empty)"
cat >"${t}/${COMMON}/plugin_model/source_admission.nim" <<'EOF'
const
  PluginAllowedStdlibModules*: array[0, tuple[primitive, replacement: string]] = [
  ]
  PluginDeniedFfiPragmas*: array[1, tuple[primitive, replacement: string]] = [
    ("importc", "call the SDK"),
  ]
EOF
assert_fires "${t}" "stdlib-allow-list-nonempty" \
	"an empty allow-list table is a NAMED finding, not twenty unexplained refusals" \
	"no module parsed"

t="$(make_tree allow-list-entry-misspelled)"
sed -i 's|("std/tables", "hash tables over in-memory values"),|("tables", "hash tables over in-memory values"),|' \
	"${t}/${COMMON}/plugin_model/source_admission.nim"
assert_fires "${t}" "stdlib-allow-list-nonempty" \
	"an entry not spelled 'std/<module>' is refused with the spelling in the remedy" \
	"not spelled 'std/<module>'"

# THE CONTROL'S OWN TWO HALVES, broken one at a time. Check 20 is what stops
# check 19 from being satisfied by a scanner that reads nothing, so a suite that
# never breaks it has taken the control on trust.
t="$(make_tree control-loses-its-admitted-import)"
sed -i '/^import std\/strutils$/d' "${t}/${VM}/plugin_host/plugin_io.nim"
assert_fires "${t}" "allow-list-scan-discriminates" \
	"the control's NEGATIVE half needs a real admitted import, and says so when it has none" \
	"does not import std/strutils"

t="$(make_tree control-count-moves)"
sed -i 's|("std/times", "a clock is not a mediated kind"),|("std/times", "a clock is not a mediated kind"),\n    ("std/os", "PLANTED: this is what admitting an operating-system module looks like"),|' \
	"${t}/${COMMON}/plugin_model/source_admission.nim"
sed -i '0,/array\[3, tuple/s//array[4, tuple/' \
	"${t}/${COMMON}/plugin_model/source_admission.nim"
assert_fires "${t}" "allow-list-scan-discriminates" \
	"admitting an operating-system module moves the control's pinned count, and the gate says by how much" \
	"expected 9"

# ---------------------------------------------------------------------------
# THE FOREIGN-FUNCTION PRAGMA — checks 21 and 22
#
# The attack on the allow-list, run on the day it was written. An FFI pragma
# needs NO import, so refusing every module in the world would not reach it.
# Measured, compiled and run against the real surface: a module whose entire
# content is `import codetracer_plugin` plus one `{.importc: "system",
# header: "<stdlib.h>".}` declaration created its sentinel.
# ---------------------------------------------------------------------------

t="$(make_tree ffi-importc-in-a-plugin)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc c_system(cmd: cstring): cint {.importc: "system", header: "<stdlib.h>".}
proc activate*() = discard c_system("true")
EOF
assert_fires "${t}" "plugin-binds-no-foreign-function" \
	"one importc line is arbitrary code execution with no grant, and it is refused by name" \
	"p.nim binds a foreign function with 'importc'"

# The multi-line spelling. A per-line regex reads the first line and loses the
# rest in SILENCE, which is the failure mode this gate's own import extractor
# was repaired for seven times; the span accumulator is why this is caught.
t="$(make_tree ffi-pragma-across-lines)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
proc c_execv(path: cstring; argv: cstringArray): cint {.
  importc: "execv",
  header: "<unistd.h>".}
proc activate*() = discard
EOF
assert_fires "${t}" "plugin-binds-no-foreign-function" \
	"a pragma split ACROSS LINES is read too — the scan accumulates the span, it does not match a line" \
	"p.nim binds a foreign function with 'importc'"

# `{.push.}` carries no routine at all, so a scan keyed on a proc declaration
# would miss it entirely.
t="$(make_tree ffi-push-pragma)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
{.push dynlib: "libc.so.6".}
proc c_fork(): cint
{.pop.}
proc activate*() = discard
EOF
assert_fires "${t}" "plugin-binds-no-foreign-function" \
	"a '{.push dynlib.}' with no routine on it is read too" \
	"p.nim binds a foreign function with 'dynlib'"

# THE NEGATIVE TWIN, and it is the one that decides whether this check is usable
# at all. `header`, `link`, `compile` and `emit` are ordinary English words. A
# scan for them as bare identifiers would refuse a plugin with a variable called
# `header`, and the remedy would be to rename the variable — which is
# Verification-Harness-Traps §4d's smell pointed at code instead of at prose.
t="$(make_tree ffi-words-outside-a-pragma-are-clean)"
cat >"${t}/${FIXTURES}/p.nim" <<'EOF'
import codetracer_plugin
type Row = object
  header*: string
  link*: string
proc compile(r: Row): string = r.header & r.link
proc activate*() =
  var emit = Row(header: "h", link: "l")
  discard compile(emit)
EOF
assert_clean "${t}" \
	"the same WORDS outside a pragma are clean — the finding is a pragma, not a vocabulary"

t="$(make_tree ffi-table-empty)"
cat >"${t}/${COMMON}/plugin_model/source_admission.nim" <<'EOF'
const
  PluginAllowedStdlibModules*: array[3, tuple[primitive, replacement: string]] = [
    ("std/strutils", "string manipulation over values already in memory"),
    ("std/tables", "hash tables over in-memory values"),
    ("std/times", "a clock is not a mediated kind"),
  ]

  PluginDeniedFfiPragmas*: array[0, tuple[primitive, replacement: string]] = [
  ]
EOF
assert_fires "${t}" "ffi-pragma-set-nonempty" \
	"an empty FFI-pragma table is a finding rather than a vacuous pass" \
	"no pragma parsed"

t="$(make_tree ffi-control-loses-its-subject)"
sed -i '/O_NOFOLLOW_CT/d' "${t}/${VM}/plugin_host/plugin_io.nim"
assert_fires "${t}" "ffi-scan-reads-pragmas" \
	"the FFI control says so when its positive subject is gone, rather than reporting a clean scan" \
	"expected 2"

t="$(make_tree ffi-control-loses-its-span-bound)"
cat >>"${t}/${VM}/plugin_host/plugin_api.nim" <<'EOF'

# A pragma word in ORDINARY CODE, in the file check 22 requires to be quiet.
# If the scan ever loses its `{. … .}` bound this line is what reports it.
proc headerOf(s: string): string = s
var header = "not a pragma"
EOF
assert_clean "${t}" \
	"a pragma WORD in the control's quiet subject keeps it quiet — the bound is asserted, not assumed"

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
# THE DERIVED `system` SURFACE — checks 23 and 24
#
# The fifth list, and the only one not written down in this repository:
# `system.nim` ends with `export syncio`, so what a plugin can name with no
# import and no pragma is whatever the compiler on PATH exports there. The
# check requires the two tables to PARTITION that set.
#
# It exists because the hand-kept version lost three times, and the third time
# a plugin whose entire import list was `import codetracer_plugin` read and
# wrote any file the user could, with nineteen checks green above it: the
# residual named ten routines, `open` was among them and denied nowhere, and
# `readBuffer` / `writeBuffer` were not among them at all.
# ---------------------------------------------------------------------------

# A NAME ON NEITHER TABLE IS THE FINDING, and `open` is the right one to drop:
# it is the name the old residual DID write down and did not deny.
t="$(make_tree system-surface-name-unaccounted)"
io_fixture="${t}/${VM}/plugin_host/plugin_io.nim"
grep -v '("open", "fixture' "${io_fixture}" >"${io_fixture}.trimmed"
mv "${io_fixture}.trimmed" "${io_fixture}"
assert_fires "${t}" "system-surface-enumerated" \
	"a name the compiler puts in every plugin's scope, on neither table, is a NAMED finding" \
	"open — exported by system, on neither table"

# THE SWEEP ITSELF IS THE THING THAT CAN BE WRONG, so it is controlled in both
# directions on the real repository rather than argued about: `readFile` is
# `system`'s and must be derived; `fork` is `std/posix`'s and must not be,
# because that is the ALLOW-list's mechanism and not this one's. A sweep that
# had drifted onto the wrong module, or that had started reading the whole
# stdlib, fails one of the two.
if [ -n "${SYSTEM_SURFACE_ALL}" ] &&
	grep -qxF readFile <<<"${SYSTEM_SURFACE_ALL}" &&
	! grep -qxF fork <<<"${SYSTEM_SURFACE_ALL}"; then
	ok "the sweep derives system's own names and not std/posix's ($(grep -c . <<<"${SYSTEM_SURFACE_ALL}") name(s))"
else
	bad "the sweep derives system's own names and not std/posix's" "${SYSTEM_SURFACE_ALL}"
fi

# AND IT FAILS CLOSED. A sweep that derived nothing must be a FAILURE and not a
# clean surface — Verification-Harness-Traps §4, which is the trap this whole
# check was written to escape. Asserted by pointing the gate at a PATH with no
# nim on it, which is the real way the sweep goes empty.
# Only `nim` is taken away — an empty PATH would break `grep`, `awk` and `git`
# too, and the case would then pass for a reason that is not the one it claims.
t="$(make_tree system-surface-sweep-empty)"
no_nim="${work}/no-nim"
mkdir -p "${no_nim}"
printf '#!/bin/sh\nexit 127\n' >"${no_nim}/nim"
chmod +x "${no_nim}/nim"
empty_output="$(PATH="${no_nim}:${PATH}" bash "${guard}" --root "${t}" 2>&1 || true)"
if grep -q "VIOLATION system-surface-enumerated" <<<"${empty_output}" &&
	grep -q "derived NO name" <<<"${empty_output}"; then
	ok "a sweep that derives nothing is a FAILURE, not a clean surface"
else
	bad "a sweep that derives nothing is a FAILURE, not a clean surface" "${empty_output}"
fi

# AND THE FAILURE SAYS WHY. Until 2026-09-10 the gate discarded nim's exit code
# and its stderr (`2>/dev/null`) and then printed three guesses, so "nim is not
# on PATH" was indistinguishable in the transcript from "nim was killed" and
# from "the stdlib moved". That is not a nicety: this check firing once, for a
# reason nobody could read off the run, cost this campaign two verification
# passes. The stub above exits 127, and the transcript has to say so.
if grep -q 'dump` exited 127' <<<"${empty_output}"; then
	ok "the empty sweep NAMES its reason — nim's own exit code reaches the transcript"
else
	bad "the empty sweep NAMES its reason — nim's own exit code reaches the transcript" "${empty_output}"
fi

# A COMPILER THAT IS PRESENT BUT CANNOT BE RUN IS NOT AN EMPTY SURFACE.
#
# The case above and this one are the two halves of the same question and they
# must answer it differently, which is why they sit together. Both have a `nim`
# on PATH that exits non-zero and prints nothing; they differ in ONE fact —
# whether a Nim standard library is sitting next to that executable.
#
# WHY THE DIFFERENCE IS THE RIGHT ONE. Nothing in this sweep needs nim to
# execute: it reads the stdlib's SOURCE off disk, and `nim dump` is asked only
# because the library's location is not guessable across the nix and source
# layouts. So when `dump` cannot be read but the executable is sitting beside a
# library that carries `std/syncio.nim`, the sweep that follows is the SAME
# sweep over the SAME files, and refusing it would report "this repository has
# an unaccounted surface" when the true statement is "this machine could not
# start a process". That is not hypothetical: on 2026-09-11 a host at load ~1200
# with two gigabytes free — 1250 orphaned processes from an unrelated runaway —
# reddened check 23 inside the ViewModel suite (`vm-unit`,
# `test_plugin_source_admission.nim`, three VIOLATIONs where the case pins two),
# and the finding was the host.
#
# THE STUB EXITS 137 — SIGKILL — because that is the shape the real failure had.
# `lib` is a symlink to the pinned compiler's real library, which is also the
# nix layout's own shape (`<prefix>/lib -> nim/lib`), so `pwd -P` resolving it
# is exercised rather than assumed.
t="$(make_tree system-surface-lib-from-exe)"
fallback_nim="${work}/fallback-nim"
mkdir -p "${fallback_nim}/bin"
printf '#!/bin/sh\nexit 137\n' >"${fallback_nim}/bin/nim"
chmod +x "${fallback_nim}/bin/nim"
ln -s "$(system_surface_lib)" "${fallback_nim}/lib"
fallback_output="$(PATH="${fallback_nim}/bin:${PATH}" bash "${guard}" --root "${t}" 2>&1 || true)"
if ! grep -q "VIOLATION system-surface-enumerated" <<<"${fallback_output}" &&
	grep -qE "OK        system-surface-enumerated: [1-9][0-9]* derived name" <<<"${fallback_output}"; then
	ok "a nim that cannot be RUN but sits beside its library still yields the full surface"
else
	bad "a nim that cannot be RUN but sits beside its library still yields the full surface" \
		"${fallback_output}"
fi

# AND THE FALLBACK SAYS SO, ON THE PATH WHERE IT SUCCEEDS. A lookup that
# silently changed which directory it swept would be indistinguishable in a
# transcript from one that did not, and "the compiler could not be executed" is
# exactly the environment fact whose absence from the transcript cost this
# campaign two verification passes when the FAILING spelling of it arrived.
# Asserted under the OK, because that is the path on which silence is tempting.
if grep -q "derived from where the nim on PATH SITS" <<<"${fallback_output}" &&
	grep -q 'dump` exited 137' <<<"${fallback_output}"; then
	ok "the executable-relative fallback NAMES itself and nim's exit code, under the OK"
else
	bad "the executable-relative fallback NAMES itself and nim's exit code, under the OK" \
		"${fallback_output}"
fi

# THE FALLBACK'S OWN CONTROL (Verification-Harness-Traps §15). A repair that
# adds a second derivation owes the case in which the two must AGREE, written as
# the case that must keep passing — otherwise the day they diverge, the sweep
# quietly describes a stdlib the compiler does not use, and the only evidence
# would be a comment claiming they cannot.
#
# The comparison is a plain string equality because both sides resolve symlinks:
# `nim dump` names the real directory and `system_surface_lib_from_exe` runs
# `pwd -P`. On the pinned 2.2.8 that is `<prefix>/nim/lib` from both, reached
# through `<prefix>/lib` on the second; under nixpkgs' wrapped nim (the lint
# devShell) the second first follows the wrapper to `<unwrapped>/nim/bin/nim`.
exe_lib="$(cd "${repo_root}" && system_surface_lib_from_exe 2>/dev/null || true)"
dump_lib="$(cd "${repo_root}" && system_surface_lib 2>/dev/null || true)"
if [ -n "${exe_lib}" ] && [ "${exe_lib}" = "${dump_lib}" ]; then
	ok "the fallback's derivation agrees with \`nim dump\` (${exe_lib})"
else
	# THE LABEL CARRIES AN APOSTROPHE ON PURPOSE, and it is not a style choice:
	# `shfmt -s` rewrites a double-quoted literal that needs no expansion into a
	# single-quoted one, and a single-quoted literal containing a BACKTICK PAIR
	# is SC2016 to shellcheck. Both run as pre-commit hooks, so a label of
	# `"... \`nim dump\`"` cannot satisfy them both. The sibling case below
	# ("the sweep's compiler lookup …") is already immune for the same reason.
	bad "the fallback's derivation agrees with \`nim dump\`" \
		"dump: ${dump_lib}
exe:  ${exe_lib}"
fi

# AND IT IS VALIDATED, NOT GUESSED. The directory is returned only once a root
# has been looked at — the same list the sweep then reads
# (`SYSTEM_SURFACE_ROOTS_REL`), so the directory a lookup ACCEPTS and the files
# the sweep READS cannot come apart. Driven with the real library minus one
# root, which is the shape a repackaged or half-installed distribution has and
# the shape an unvalidated guess would accept.
partial_nim="${work}/partial-nim"
mkdir -p "${partial_nim}/bin" "${partial_nim}/lib/std"
printf '#!/bin/sh\nexit 137\n' >"${partial_nim}/bin/nim"
chmod +x "${partial_nim}/bin/nim"
ln -s "$(system_surface_lib)/std/syncio.nim" "${partial_nim}/lib/std/syncio.nim"
partial_lib="$(PATH="${partial_nim}/bin:${PATH}" bash -c '
	. "'"${repo_root}"'/ci/lib/system-io-surface.sh"
	system_surface_lib_from_exe 2>/dev/null || true')"
if [ -z "${partial_lib}" ]; then
	ok "a library directory missing one of the sweep's roots is NOT accepted"
else
	bad "a library directory missing one of the sweep's roots is NOT accepted" "${partial_lib}"
fi

# A WRAPPER SCRIPT IS FOLLOWED TO THE COMPILER IT EXECS. nixpkgs' `nim` — the
# one the lint devShell carries — is a `makeWrapper` script in a prefix holding
# only `bin/` and `etc/`, whose last line hands off to the real compiler by
# absolute path. Walking up from the SCRIPT finds no library, which is how the
# agreement control above went red in CI while `nim dump` was answering fine.
# Driven with that exact shape: a wrapper prefix with no `lib/`, exec'ing (via
# `-a "$0"`, the other spelling makeWrapper emits) the unrunnable nim that sits
# beside the real library.
wrapped_nim="${work}/wrapped-nim"
mkdir -p "${wrapped_nim}/bin" "${wrapped_nim}/etc/nim"
# The `$0` and `$@` are the WRAPPER's own text, written literally on purpose.
# shellcheck disable=SC2016
printf '#! /bin/sh -e\nexport NIM_CONFIG_PATH=%s\nexec -a "$0" "%s"  "$@"\n' \
	"${wrapped_nim}/etc/nim" "${fallback_nim}/bin/nim" >"${wrapped_nim}/bin/nim"
chmod +x "${wrapped_nim}/bin/nim"
wrapped_lib="$(PATH="${wrapped_nim}/bin:${PATH}" bash -c '
	. "'"${repo_root}"'/ci/lib/system-io-surface.sh"
	system_surface_lib_from_exe 2>/dev/null || true')"
if [ -n "${wrapped_lib}" ] && [ "${wrapped_lib}" = "$(cd "$(system_surface_lib)" && pwd -P)" ]; then
	ok "a wrapper script is followed to the compiler it execs, and to that compiler's library"
else
	bad "a wrapper script is followed to the compiler it execs, and to that compiler's library" \
		"got: ${wrapped_lib}"
fi

# A LOOKUP THAT LANDS SOMEWHERE PLAUSIBLE BUT WRONG IS A NAMED REFUSAL, not an
# empty sweep. This is the other half of failing closed, and it is a different
# failure from the case above: there `nim` is gone, which is the loud way to
# derive nothing; here `nim` answers, and answers with a library directory that
# has no `std/syncio.nim` under it — the shape a moved stdlib, a repackaged
# distribution or a mis-read dump line actually has. Before the root check the
# sweep opened no file, emitted no name, and said nothing anywhere about having
# missed one: Verification-Harness-Traps §4, arriving through the scan's INPUT
# rather than through its pattern.
t="$(make_tree system-surface-lib-has-no-roots)"
wrong_nim="${work}/wrong-nim"
mkdir -p "${wrong_nim}"
printf '#!/bin/sh\necho /nonexistent/lib/pure\n' >"${wrong_nim}/nim"
chmod +x "${wrong_nim}/nim"
wrong_output="$(PATH="${wrong_nim}:${PATH}" bash "${guard}" --root "${t}" 2>&1 || true)"
if grep -q "VIOLATION system-surface-enumerated" <<<"${wrong_output}" &&
	grep -q "/nonexistent/lib/std/syncio.nim" <<<"${wrong_output}"; then
	ok "a compiler lookup that lands on a library with no roots NAMES the missing root"
else
	bad "a compiler lookup that lands on a library with no roots NAMES the missing root" "${wrong_output}"
fi

# THE REPAIR'S OWN CONTROL (Verification-Harness-Traps §15). `system_surface_lib`
# asks nim with `--skipUserCfg --skipParentCfg --skipProjCfg`, so its answer is
# a property of the COMPILER and not of whatever tree `--root` happens to name —
# the reason being that a plain `nim dump` evaluates the project configuration
# of the directory the gate is standing in, which for the ViewModel suite is a
# synthetic tree inside this repository, so `codetracer/config.nims` runs in
# full for a question about where the stdlib lives.
#
# What makes that safe rather than merely six times cheaper is that the two
# spellings resolve to the SAME directory. A configuration that redirected
# `--lib` would be swept differently by the two, and this repository has no
# `--lib` anywhere; the day one arrives, this case goes red instead of the
# sweep quietly describing a stdlib the compiler does not use. A repair that
# normalises one side of a comparison owes the case in which the other side
# needed no treatment, written as the case that must keep passing.
plain_dump_lib="$(cd "${repo_root}" && nim dump 2>&1 | grep -E '/lib/pure$' || true)"
plain_dump_lib="${plain_dump_lib%%$'\n'*}"
swept_lib="$(cd "${repo_root}" && system_surface_lib 2>/dev/null || true)"
if [ -n "${swept_lib}" ] && [ "${plain_dump_lib%/pure}" = "${swept_lib}" ]; then
	ok "the sweep's compiler lookup agrees with a plain \`nim dump\` (${swept_lib})"
else
	bad "the sweep's compiler lookup agrees with a plain \`nim dump\`" \
		"plain: ${plain_dump_lib}
swept: ${swept_lib}"
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
