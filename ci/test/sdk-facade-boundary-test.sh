#!/usr/bin/env bash
#
# sdk-facade-boundary-test.sh — the contract suite for
# ci/test/sdk-facade-boundary.sh.
#
# WHY THIS EXISTS
# ---------------
# The same reason ci/test/test-lane-coverage-test.sh exists, and the same
# reason ci/lint/bash.sh runs scripts/resolve-sibling-rev-test.sh: a guard that
# has only ever been watched printing OK is not evidence. This file drives the
# boundary guard against synthetic trees and asserts that EACH of its checks
# fires, by name, on the violation it is supposed to catch — and, just as
# importantly, that it stays quiet on the clean version of the same tree.
#
# A boundary lint is exactly the kind of check that rots into decoration:
# nobody notices when it stops catching things, because the thing it catches is
# rare. So every rule below has a positive and a negative case.
#
# Usage:
#   bash ci/test/sdk-facade-boundary-test.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="${repo_root}/ci/test/sdk-facade-boundary.sh"

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

# ---------------------------------------------------------------------------
# Tree construction
#
# `make_tree NAME` builds a minimal repo-shaped tree with a facade, one SDK
# internal, and no consumers. Callers then add exactly the file whose handling
# they are testing, so each case differs from the clean baseline in one way.
# ---------------------------------------------------------------------------

make_tree() {
	local name="$1"
	local t="${work}/${name}"
	mkdir -p "${t}/src/frontend/viewmodel/store"
	cat >"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
import store/replay_data_store
export replay_data_store
const CodeTracerEmbedFacadeModule* = "codetracer_embed"
EOF
	cat >"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import std/json
const StoreVersion* = 1
EOF
	# The guard enumerates through git, exactly as test-lane-coverage.sh does,
	# so a tree that is not a repo would look empty to it.
	git -C "${t}" init -q
	git -C "${t}" config user.email t@example.invalid
	git -C "${t}" config user.name t
	printf '%s' "${t}"
}

run_guard() {
	bash "${guard}" --root "$1" 2>&1
}

# assert_fires TREE CHECK-NAME DESCRIPTION [EXPECTED-SUBSTRING...]
#
# Every trailing argument is a substring the output must contain. More than
# one matters for the `ui/` rule, where the diagnosis has to name both the
# offending module AND the allowlist that is the intended remedy.
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

echo "=== ci/test/sdk-facade-boundary.sh: contract suite ==="

# ---------------------------------------------------------------------------
# facade-present
# ---------------------------------------------------------------------------

t="$(make_tree missing-facade)"
rm "${t}/src/frontend/viewmodel/codetracer_embed.nim"
assert_fires "${t}" "facade-present" \
	"a missing facade module is reported, not ignored" \
	"does not exist"

t="$(make_tree renamed-constant)"
cat >"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
const SomeOtherName* = "codetracer_embed"
EOF
assert_fires "${t}" "facade-present" \
	"a facade that no longer declares its own name is reported" \
	"drifted apart"

# ---------------------------------------------------------------------------
# consumer-declared — the guard must refuse to pass vacuously
# ---------------------------------------------------------------------------

t="$(make_tree no-consumers)"
assert_fires "${t}" "consumer-declared" \
	"a tree with no declared consumer fails rather than passing vacuously" \
	"pass vacuously"

# ---------------------------------------------------------------------------
# consumer-facade-only — the rule BlockTracer M8a mirrors
# ---------------------------------------------------------------------------

t="$(make_tree consumer-clean)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: a pane that behaves.
import ../src/frontend/viewmodel/codetracer_embed
echo StoreVersion
EOF
assert_clean "${t}" "a consumer importing only the facade passes"

t="$(make_tree consumer-reaches-in)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: a pane that reaches past the facade.
import ../src/frontend/viewmodel/store/replay_data_store
echo StoreVersion
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a consumer reaching into an SDK internal is caught by name" \
	"That is an SDK internal"

t="$(make_tree consumer-reaches-in-bracket)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: bracket-list spelling of the same violation.
import ../src/frontend/viewmodel/[codetracer_embed, store/replay_data_store]
EOF
assert_fires "${t}" "consumer-facade-only" \
	"the bracket-list import spelling does not evade the rule" \
	"replay_data_store"

t="$(make_tree consumer-reaches-in-from)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: `from x import y` spelling of the same violation.
from ../src/frontend/viewmodel/store/replay_data_store import StoreVersion
EOF
assert_fires "${t}" "consumer-facade-only" \
	"the 'from X import Y' spelling does not evade the rule" \
	"replay_data_store"

t="$(make_tree consumer-reaches-in-indented)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: an import hidden inside a `when` branch.
when defined(js):
  import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"an import inside a 'when defined(js)' branch does not evade the rule" \
	"replay_data_store"

# ---------------------------------------------------------------------------
# consumer-facade-only, THE QUOTED SPELLINGS
#
# A module spec may be written as a string literal, and that is not a curiosity
# of the grammar: `import "a/b"` is joined onto each search root exactly as
# `import a/b` is. Until the extractor unquoted them, every "must not import X"
# rule in this repository — this one, and the TUI's own
# `src/frontend/tui/tests/test_tui_facade_boundary.nim` — was evadable by one
# pair of quotation marks. It was demonstrated rather than theorised: planting
# `import "tui/host/native_host"` in the real `src/frontend/tui/app/tui_app.nim`
# compiled, reached the host layer, and left BOTH guards green, while six other
# spellings of the same import went red by name.
#
# So the spellings below are the compiler's list, not a plausible-looking one:
# each was compiled against nim 2.2.8 and resolved to the store module before it
# was written here. Each lives in its own consumer FILE so the guard's output
# has to name every one of them — a single file would let one spelling being
# reported stand in for the rest.
# ---------------------------------------------------------------------------

t="$(make_tree consumer-reaches-in-quoted)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: the quoted spelling of the same violation.
import "../src/frontend/viewmodel/store/replay_data_store"
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a quoted import spec does not evade the rule" \
	"replay_data_store"

t="$(make_tree consumer-reaches-in-quoted-variants)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_as.nim" <<'EOF'
## SDK-CONSUMER: quoted, with an alias.
import "../src/frontend/viewmodel/store/replay_data_store" as store
EOF
cat >"${t}/consumer/pane_from.nim" <<'EOF'
## SDK-CONSUMER: quoted, in a `from` statement.
from "../src/frontend/viewmodel/store/replay_data_store" import StoreVersion
EOF
cat >"${t}/consumer/pane_include.nim" <<'EOF'
## SDK-CONSUMER: quoted, in an `include` statement.
include "../src/frontend/viewmodel/store/replay_data_store"
EOF
cat >"${t}/consumer/pane_raw.nim" <<'EOF'
## SDK-CONSUMER: quoted as a raw string literal, whose `r` is part of the
## syntax and not part of the module name.
import r"../src/frontend/viewmodel/store/replay_data_store"
EOF
cat >"${t}/consumer/pane_triple.nim" <<'EOF'
## SDK-CONSUMER: quoted as a triple-quoted string literal.
import """../src/frontend/viewmodel/store/replay_data_store"""
EOF
cat >"${t}/consumer/pane_partial.nim" <<'EOF'
## SDK-CONSUMER: only one segment in the middle of the path is quoted.
import ../src/frontend/"viewmodel"/store/replay_data_store
EOF
cat >"${t}/consumer/pane_bracket.nim" <<'EOF'
## SDK-CONSUMER: a quoted prefix in front of a bracket list. The facade is
## allowed; the internal beside it in the same list is not.
import "../src/frontend/viewmodel"/[codetracer_embed, store/replay_data_store]
EOF
cat >"${t}/consumer/pane_mixed.nim" <<'EOF'
## SDK-CONSUMER: one bare spec and one quoted spec on the same line, so the
## comma split has to survive the quotation marks.
import ../src/frontend/viewmodel/codetracer_embed, "../src/frontend/viewmodel/store/replay_data_store"
EOF
# The module name here ENDS IN `r`, and that is the whole point of the file.
# The `r` of a raw string literal belongs to the quote that OPENS one; a strip
# that drops `r` whenever a quote follows it eats the last letter of every
# quoted spec ending in `r` — `store/replay_tracker` becomes
# `store/replay_tracke`, which matches nothing and resolves to nothing, and the
# quoted form is once again the way past this rule.
# `src/frontend/viewmodel` alone holds 21 modules named that way
# (`request_tracker`, `front_end_adapter`, `reducer`, `sync_publisher`, …), so
# this is the common case, not a corner of one.
cat >"${t}/src/frontend/viewmodel/store/replay_tracker.nim" <<'EOF'
const TrackerVersion* = 1
EOF
cat >"${t}/consumer/pane_tracker.nim" <<'EOF'
## SDK-CONSUMER: quoted, and the module name ends in `r`.
import "../src/frontend/viewmodel/store/replay_tracker"
EOF
assert_fires "${t}" "consumer-facade-only" \
	"every quoted spelling nim accepts is caught, not only the bare one" \
	"pane_as.nim" "pane_from.nim" "pane_include.nim" "pane_raw.nim" \
	"pane_triple.nim" "pane_partial.nim" "pane_bracket.nim" "pane_mixed.nim" \
	"pane_tracker.nim" "replay_tracker"

# ---------------------------------------------------------------------------
# consumer-facade-only, THE SPELLINGS THAT NEED NO SPACE — and the one that
# needs two
#
# A STRING LITERAL SELF-TERMINATES, so once the spec is quoted the space before
# `as`, before `except` and before the `import` of a `from` is optional.
# `import "a/b"as c` compiles (nim 2.2.8, verified). An extractor that splits on
# a SPACED keyword sees `a/bas c` — no module, no finding — so these forms sat
# squarely inside "the quoted spellings" while evading the fix for them.
#
# And the mirror-image case: `/` is an ordinary infix operator, so
# `import a / b / c` compiles and means `a/b/c`. That one is not quoted at all;
# it evaded the extractor at HEAD too, and 26 files in this repository already
# write imports that way — measured, by diffing the extractor's output over all
# 998 tracked Nim files before and after the fix, not counted by eye.
# ---------------------------------------------------------------------------

t="$(make_tree consumer-reaches-in-tight-keywords)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_as_tight.nim" <<'EOF'
## SDK-CONSUMER: quoted, aliased, and with no space before `as`.
import "../src/frontend/viewmodel/store/replay_data_store"as store
EOF
cat >"${t}/consumer/pane_except_tight.nim" <<'EOF'
## SDK-CONSUMER: quoted, with no space before `except`.
import "../src/frontend/viewmodel/store/replay_data_store"except StoreVersion
EOF
cat >"${t}/consumer/pane_from_as_tight.nim" <<'EOF'
## SDK-CONSUMER: quoted, aliased and imported-from, with no space anywhere.
from "../src/frontend/viewmodel/store/replay_data_store"as store import StoreVersion
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a quoted spec followed immediately by 'as' or 'except' does not evade the rule" \
	"pane_as_tight.nim" "pane_except_tight.nim" "pane_from_as_tight.nim"

t="$(make_tree consumer-reaches-in-spaced-separator)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_spaced.nim" <<'EOF'
## SDK-CONSUMER: `/` written as the infix operator it is.
import .. / src / frontend / viewmodel / store / replay_data_store
EOF
cat >"${t}/consumer/pane_spaced_quoted.nim" <<'EOF'
## SDK-CONSUMER: spaced separators AND quoted segments together.
import ".." / "src" / "frontend" / "viewmodel" / "store" / "replay_data_store"
EOF
cat >"${t}/consumer/pane_spaced_bracket.nim" <<'EOF'
## SDK-CONSUMER: a spaced separator in front of a bracket list, which is how
## src/frontend/ui/ui_imports.nim already writes its imports.
import .. / src / frontend / viewmodel / [codetracer_embed, store / replay_data_store]
EOF
assert_fires "${t}" "consumer-facade-only" \
	"whitespace around the '/' separator does not evade the rule" \
	"pane_spaced.nim" "pane_spaced_quoted.nim" "pane_spaced_bracket.nim"

# ---------------------------------------------------------------------------
# consumer-facade-only, THE CHARACTERS THAT ARE SYNTAX OUTSIDE A LITERAL AND
# FILENAME INSIDE ONE
#
# Nim requires only the BASENAME of a module path to be a valid identifier, so a
# `#` or a `[` in a DIRECTORY component is legal and both forms below compile
# (nim 2.2.8, verified). Inside the quotes they are filename characters; the
# extractor must not read them as a comment marker or as a bracket list.
#
# Each is a MISS if got wrong, not an over-report — which is why they are here:
#
#   `#`  cut at the first one and `import "h#d/../…"` becomes `import "h`,
#        naming nothing at all.
#   `[`  counted as an unbalanced bracket and the import statement is never
#        finished, so every following line is glued onto the same buffer and the
#        SECOND import — the violating one — is never seen as a statement.
# ---------------------------------------------------------------------------

t="$(make_tree consumer-reaches-in-punctuated-dir)"
mkdir -p "${t}/consumer/h#d" "${t}/consumer/a[b"
cat >"${t}/consumer/pane_hash.nim" <<'EOF'
## SDK-CONSUMER: the path traverses a directory whose name contains `#`.
import "h#d/../../src/frontend/viewmodel/store/replay_data_store"
EOF
cat >"${t}/consumer/pane_bracket_dir.nim" <<'EOF'
## SDK-CONSUMER: the FIRST import traverses a directory whose name contains an
## unbalanced `[`. It is allowed — it names the facade. The violation is on the
## line below it, which a naive bracket count never reaches.
import "a[b/../../src/frontend/viewmodel/codetracer_embed"
import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a '#' or '[' inside a quoted spec is a filename character, not syntax" \
	"pane_hash.nim" "pane_bracket_dir.nim"

# ---------------------------------------------------------------------------
# consumer-facade-only, A LINE IS NOT A STATEMENT
#
# The extractor was line-oriented, and Nim is not. Two shapes put an import
# somewhere other than at the start of its own line, both compile (nim 2.2.8,
# verified), and both yielded NOTHING AT ALL at HEAD — a miss, not an
# over-report:
#
#   `;`      separates statements, so `import a; import b` is two imports. Read
#            as one, the whole line becomes the spec `a;importb`, which names no
#            module, matches no pattern and resolves to no file. BOTH imports
#            disappear. `echo 1; import a` is the same shape without an import
#            in front.
#   `when`   may carry its statement on the condition's own line:
#            `when not defined(js): import a` is idiomatic and is ONE line, so
#            the indented-continuation handling — which covers the multi-line
#            spelling of exactly this — never saw it. The line did not begin
#            with `import`, so it was skipped outright. `elif`, `else` and the
#            spaceless `when(true):import a` compile too.
#
# Measured at codetracer@f274fa68, each planted alone in the real declared
# consumer src/frontend/tui/app/tui_app.nim: both left the guard at
# `6 check(s), 0 failing`.
# ---------------------------------------------------------------------------

t="$(make_tree consumer-reaches-in-semicolon)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_semi_second.nim" <<'EOF'
## SDK-CONSUMER: two statements on one line; the SECOND one is the violation,
## so the split has to reach past the first.
import ../src/frontend/viewmodel/codetracer_embed; import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_semi_first.nim" <<'EOF'
## SDK-CONSUMER: the mirror image — the FIRST statement is the violation, so a
## split that kept only the tail would miss it.
import ../src/frontend/viewmodel/store/replay_data_store; import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/consumer/pane_semi_after_expr.nim" <<'EOF'
## SDK-CONSUMER: the statement in front of the `;` is not an import at all, so
## the line does not begin with a keyword this guard was looking for.
echo 1; import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a ';'-separated import on a shared line does not evade the rule" \
	"pane_semi_second.nim" "pane_semi_first.nim" "pane_semi_after_expr.nim"

t="$(make_tree consumer-reaches-in-one-line-when)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_when.nim" <<'EOF'
## SDK-CONSUMER: the idiomatic one-liner.
when not defined(js): import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_elif.nim" <<'EOF'
## SDK-CONSUMER: the same thing on an `elif` branch.
when defined(js):
  discard
elif true: import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_else.nim" <<'EOF'
## SDK-CONSUMER: and on an `else` branch, which carries no condition at all.
when defined(js):
  discard
else: import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_when_tight.nim" <<'EOF'
## SDK-CONSUMER: no space anywhere — `when(cond):import x` compiles.
when(true):import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_when_semi.nim" <<'EOF'
## SDK-CONSUMER: both shapes at once. The facade is allowed; the internal after
## the `;`, inside the same one-line branch, is not.
when true: import ../src/frontend/viewmodel/codetracer_embed; import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_when_colon_in_cond.nim" <<'EOF'
## SDK-CONSUMER: the condition CONTAINS a colon, so "the first colon ends the
## condition" is wrong and the guard has to decide by what follows it.
when {1: 2}.len > 0: import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"an import carried on a one-line 'when'/'elif'/'else' does not evade the rule" \
	"pane_when.nim" "pane_elif.nim" "pane_else.nim" "pane_when_tight.nim" \
	"pane_when_semi.nim" "pane_when_colon_in_cond.nim"

# THE NEGATIVE HALF, and it is not decoration. Both fixes above widen what
# counts as a statement, and a widening is exactly the change that starts
# reporting imports nobody wrote — a commented-out line, or a `;` inside a
# module name. A guard that reports those is a guard people switch off.
t="$(make_tree one-line-statements-do-not-over-report)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_commented.nim" <<'EOF'
## SDK-CONSUMER: the violating spellings, every one of them COMMENTED OUT.
# when true: import ../src/frontend/viewmodel/store/replay_data_store
# import ../src/frontend/viewmodel/codetracer_embed; import ../src/frontend/viewmodel/store/replay_data_store
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/consumer/pane_when_facade.nim" <<'EOF'
## SDK-CONSUMER: a one-line `when` around an import of exactly what it may.
when true: import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/consumer/pane_semi_quoted.nim" <<'EOF'
## SDK-CONSUMER: the `;` is INSIDE the quoted spec, so it is a filename
## character and not a statement separator. The module does not exist, which is
## the point: the guard must read one spec here, not two statements.
import "../src/frontend/viewmodel/no;such;module"
EOF
assert_clean "${t}" \
	"a commented-out import, a permitted one-line 'when', and a ';' inside a quoted spec are all quiet"

# ---------------------------------------------------------------------------
# import-specs-analysable, THE BLOCK COMMENT
#
# `import #[c]# a/b` and `import a/b #[c]#` compile (nim 2.2.8), and a comment
# stripper that cuts at the first `#` loses the spec of the first one entirely.
# So block comments are REMOVED, with their nesting, when they open and close on
# the same line — and the case below proves the import behind one is still
# graded.
#
# When the comment spans lines there is no honest lexical answer: tracking
# cross-line comment state would let a `#[` inside a multi-line string literal
# swallow the rest of a file, which is a MISS of everything after it. So those
# two shapes are refused by name instead, the same way an escaped spec is.
# ---------------------------------------------------------------------------

t="$(make_tree consumer-block-comment-same-line)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: a block comment sits between the keyword and the spec.
import #[ which store? ]# ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a block comment that opens and closes on the line is removed, not treated as a line comment" \
	"replay_data_store"

t="$(make_tree consumer-block-comment-spans-lines)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_open.nim" <<'EOF'
## SDK-CONSUMER: the statement runs into a block comment that closes later.
import ../src/frontend/viewmodel/codetracer_embed #[ why this one
and not the other ]#
EOF
assert_fires "${t}" "import-specs-analysable" \
	"an import statement running into a multi-line block comment is refused, not guessed at" \
	"pane_open.nim" "multi-line block comment"

t="$(make_tree consumer-block-comment-resumes)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_resume.nim" <<'EOF'
## SDK-CONSUMER: the import RESUMES after a block comment opened on the line
## above it. Cutting this line at its first `#` yields `]`, and the import is
## gone; so it is refused instead.
#[ a comment
]#import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "import-specs-analysable" \
	"an import resuming after a multi-line block comment is refused, not silently dropped" \
	"pane_resume.nim" "multi-line block comment"

# ---------------------------------------------------------------------------
# import-specs-analysable, THE ONE-LINE CONDITIONAL THE LEXER CANNOT READ
#
# A `when` condition is arbitrary nim; this is a lexer. The extractor models
# double-quoted strings and nothing else, so a CHARACTER LITERAL holding a `#`,
# a `;` or a `"` lands the comment cut, the statement split or the quote parity
# inside itself, and all three compile (nim 2.2.8). Teaching the scans about
# character literals would mean teaching them that `1'u8` is not one, which is a
# new way to be wrong — so instead the extractor asserts on ITSELF: a line that
# visibly carries an import and yielded none is refused by name.
#
# This is the boundary of the claim rather than a curiosity, and it is why the
# caveat in test_tui_facade_boundary.nim is bounded: what is left over is loud,
# not silent.
# ---------------------------------------------------------------------------

t="$(make_tree consumer-conditional-unreadable)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane_hash_char.nim" <<'EOF'
## SDK-CONSUMER: a `#` inside a character literal, so the comment cut lands
## inside the condition.
when '#' == '#': import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_semi_char.nim" <<'EOF'
## SDK-CONSUMER: a `;` inside a character literal, so the statement split lands
## inside the condition.
when ';' == ';': import ../src/frontend/viewmodel/store/replay_data_store
EOF
cat >"${t}/consumer/pane_quote_char.nim" <<'EOF'
## SDK-CONSUMER: ONE double-quote inside a character literal, so every
## quote-aware scan on this line is inverted.
when '"' == 'x': import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "import-specs-analysable" \
	"a one-line conditional whose condition defeats the lexer is refused, not skipped" \
	"pane_hash_char.nim" "pane_semi_char.nim" "pane_quote_char.nim" \
	"character literal"

# ---------------------------------------------------------------------------
# import-specs-analysable — the refusal, and why it is a failure and not a shrug
#
# `import "a\x2Fb"` compiles and imports `a/b`: `\x2F` is a Nim string escape
# for `/`. This guard is lexical and does not decode escapes, because decoding
# them WRONGLY — `r"..."` and `"""..."""` do not interpret escapes at all — is a
# silent MISS, the one outcome a boundary lint may not produce. So it says so
# and goes red. The negative case matters just as much: a backslash-free tree
# must not trip it, or the refusal becomes noise everyone learns to ignore.
# ---------------------------------------------------------------------------

t="$(make_tree consumer-escaped-spec)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: the separators of this path are written as hex escapes.
import "..\x2Fsrc\x2Ffrontend\x2Fviewmodel\x2Fstore\x2Freplay_data_store"
EOF
assert_fires "${t}" "import-specs-analysable" \
	"a spec carrying string escapes is refused loudly, not emitted raw" \
	"pane.nim" "carries Nim string escapes"

# The other half of unquoting, and the reason it is a normalisation rather than
# a ban: a quoted spec that names the FACADE still resolves to the facade and is
# still allowed. Without this, "the guard now sees quoted imports" would be
# satisfied just as well by an extractor that reported every quoted spec.
t="$(make_tree consumer-quoted-facade-is-allowed)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: quoted, and importing exactly what it may.
import "../src/frontend/viewmodel/codetracer_embed"
echo StoreVersion
EOF
assert_clean "${t}" \
	"a quoted spec naming the facade resolves to the facade and stays allowed"

t="$(make_tree consumer-dir-marker)"
mkdir -p "${t}/panes/debugger"
echo "BlockTracer's debugger panes." >"${t}/panes/.sdk-consumer"
cat >"${t}/panes/debugger/calltrace.nim" <<'EOF'
import ../../src/frontend/viewmodel/store/replay_data_store
EOF
assert_fires "${t}" "consumer-facade-only" \
	"a .sdk-consumer directory marker covers files beneath it" \
	"calltrace.nim"

t="$(make_tree undeclared-is-not-a-consumer)"
mkdir -p "${t}/consumer" "${t}/other"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: the declared one.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/other/internal_tool.nim" <<'EOF'
import ../src/frontend/viewmodel/store/replay_data_store
EOF
assert_clean "${t}" \
	"an undeclared file may still import internals (nothing is a consumer by accident)"

# ---------------------------------------------------------------------------
# facade-graph-no-rendering
# ---------------------------------------------------------------------------

t="$(make_tree render-direct)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
import karax/karaxdsl
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a rendering import in the facade itself is caught" \
	"karax"

t="$(make_tree render-transitive)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import dom
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a DOM import two hops from the facade is caught transitively" \
	"dom"

t="$(make_tree render-behind-when)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
when defined(js):
  import kdom
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a DOM import behind 'when defined(js)' is still in the graph" \
	"kdom"

t="$(make_tree process-spawn)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import std/osproc
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"an embeddable library spawning processes is caught" \
	"osproc"

# ---------------------------------------------------------------------------
# facade-graph-no-rendering, the `src/frontend/ui/` path rule
#
# The case the suite was missing, and the reason a CSS module could have
# shipped inside the SDK graph. A module under `ui/` that imports NOTHING is
# invisible to every other rule here — they all match a module spec someone
# imported — so if the path rule does not catch it, nothing does. This is the
# real shape: `ui/flow_line_styles.nim` exports `FlowLineHitClass` and
# `flowLineStyleClass()`, has zero imports, and sits in the same directory as
# `ui/flow_loop_math.nim`, which `viewmodels/flow_vm.nim` already imports — so
# in the real tree it is one `import` line away from the SDK graph. The
# synthetic trees below hang it off the store module instead, for the same
# reason every other transitive case here does: it is the one internal the
# baseline tree has.
# ---------------------------------------------------------------------------

t="$(make_tree ui-zero-import-presentation)"
mkdir -p "${t}/consumer" "${t}/src/frontend/ui"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/src/frontend/ui/flow_line_styles.nim" <<'EOF'
## One inline CSS class per source line. No imports at all.
const
  FlowLineHitClass* = "line-flow-hit"
  FlowLineSkipClass* = "line-flow-skip"

func flowLineStyleClass*(hit: bool): string =
  if hit: FlowLineHitClass else: FlowLineSkipClass
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import ../../ui/flow_line_styles
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"a zero-import presentation module under ui/ reachable from the facade is caught" \
	"src/frontend/ui/flow_line_styles.nim" \
	"UI_PATH_ALLOWLIST"

t="$(make_tree ui-allowlisted-arithmetic)"
mkdir -p "${t}/consumer" "${t}/src/frontend/ui"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/src/frontend/ui/flow_loop_math.nim" <<'EOF'
## Pure loop-iteration arithmetic. No imports at all.
proc activeIterationForTicks*(rrTicksForIterations: openArray[int];
                              locationTicks: int): int =
  result = 0
  for i, tick in rrTicksForIterations:
    if tick <= locationTicks: result = i
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import ../../ui/flow_loop_math
EOF
assert_clean "${t}" \
	"the allowlisted ui/flow_loop_math.nim is exempt by exact name, not by softening the rule"

t="$(make_tree ui-allowlist-is-exact)"
mkdir -p "${t}/consumer" "${t}/src/frontend/ui"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >"${t}/src/frontend/ui/flow_loop_math_helpers.nim" <<'EOF'
## Named to look like the allowlisted module. It is not it.
const FlowLoopMarkerClass* = "loop-marker"
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
import ../../ui/flow_loop_math_helpers
EOF
assert_fires "${t}" "facade-graph-no-rendering" \
	"the allowlist matches exact paths, so a neighbouring ui/ module does not inherit the exemption" \
	"flow_loop_math_helpers"

# ---------------------------------------------------------------------------
# facade-graph-no-chain-concept — spec §3.2's newest and most load-bearing row
# ---------------------------------------------------------------------------

t="$(make_tree chain-field)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
type TraceMeta* = object
  blockNumber*: int
EOF
assert_fires "${t}" "facade-graph-no-chain-concept" \
	"a chain field added 'just for BlockTracer' is caught" \
	"blockNumber"

t="$(make_tree chain-param)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/codetracer_embed.nim" <<'EOF'
proc openTransactionTrace*(chainId: int; txHash: string) = discard
EOF
assert_fires "${t}" "facade-graph-no-chain-concept" \
	"a chain-aware entry point on the facade is caught" \
	"chainId"

t="$(make_tree chain-in-a-comment)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
## Resolving a chainId or a blockNumber to a trace is BlockTracer's job,
## one layer up — see Client-SDK.md. This module knows none of it.
EOF
assert_clean "${t}" \
	"citing the chain layer in a comment is allowed (a comment has no ABI)"

t="$(make_tree origin-chain-is-not-a-blockchain)"
mkdir -p "${t}/consumer"
cat >"${t}/consumer/pane.nim" <<'EOF'
## SDK-CONSUMER: fine.
import ../src/frontend/viewmodel/codetracer_embed
EOF
cat >>"${t}/src/frontend/viewmodel/store/replay_data_store.nim" <<'EOF'
type OriginChain* = object
  sourceGeneration*: int
  blockSourceName*: string
EOF
assert_clean "${t}" \
	"origin chains, sourceGeneration and BlockSource are not chain concepts"

# ---------------------------------------------------------------------------
# The real repository
# ---------------------------------------------------------------------------

assert_clean "${repo_root}" "the guard passes on this repository"

# ---------------------------------------------------------------------------
# The walk leaves this repository
#
# `--root` marks a synthetic tree, and a synthetic tree has no sibling
# packages, so the checks above never exercise the sibling walk at all. These
# three run the guard the way CI runs it — with no `--root` — and then break it
# deliberately, because "the lint now walks IsoNim" is a claim that is
# satisfied just as well by a walk that silently finds nothing.
# ---------------------------------------------------------------------------

repo_output="$(cd "${repo_root}" && bash "${guard}" 2>&1)"
repo_status=$?

if [ "${repo_status}" -eq 0 ] && grep -q "OK        graph-walks-siblings" <<<"${repo_output}"; then
	ok "run with no --root, the guard performs the sibling walk and passes"
else
	bad "run with no --root, the guard performs the sibling walk and passes" \
		"exit ${repo_status}" "${repo_output}"
fi

graph_output="$(cd "${repo_root}" && bash "${guard}" --list-graph 2>&1)"
if grep -qE '^/.*/isonim/(src/)?isonim/core/signals\.nim$' <<<"${graph_output}"; then
	ok "the printed graph contains IsoNim's own source files, not just its module specs"
else
	bad "the printed graph contains IsoNim's own source files" \
		"No absolute isonim/core/signals.nim in --list-graph output." \
		"If the resolver stops at the repo edge the walk is decorative: every" \
		"forbidden-module rule below would have nothing from IsoNim to match."
fi

# The mutation. Point ISONIM_SRC at a stand-in whose `isonim/core/signals`
# imports a renderer, and the rendering rule must fire. Without this, the two
# contracts above are satisfied by a walk that enters IsoNim and then examines
# nothing.
fake_isonim="${work}/fake-isonim"
mkdir -p "${fake_isonim}/isonim/core" "${fake_isonim}/isonim/testing"
for m in signals computation owner clock async_compat; do
	echo "const Stub${m}* = 1" >"${fake_isonim}/isonim/core/${m}.nim"
done
echo "const StubTestUtils* = 1" >"${fake_isonim}/isonim/testing/test_utils.nim"
echo "const StubViewModel* = 1" >"${fake_isonim}/isonim/viewmodel.nim"
# The one line under test.
echo "import isonim/web/dom_api" >>"${fake_isonim}/isonim/core/signals.nim"
mkdir -p "${fake_isonim}/isonim/web"
echo "const StubDom* = 1" >"${fake_isonim}/isonim/web/dom_api.nim"

mutant_output="$(cd "${repo_root}" && ISONIM_SRC="${fake_isonim}" bash "${guard}" 2>&1)"
mutant_status=$?
if [ "${mutant_status}" -ne 0 ] &&
	grep -q "VIOLATION facade-graph-no-rendering" <<<"${mutant_output}" &&
	grep -q "isonim/web/dom_api" <<<"${mutant_output}"; then
	ok "a renderer import added inside IsoNim's core is caught (red-before)"
else
	bad "a renderer import added inside IsoNim's core is caught" \
		"exit ${mutant_status}" "${mutant_output}" \
		"This is the gap BlockTracer.milestones.org M2a carried: before the" \
		"walk entered IsoNim, this mutation was invisible to the guard."
fi

# And a missing sibling must be loud rather than silently narrowing the rule.
missing_output="$(cd "${repo_root}" && ISONIM_SRC="${work}/nope" \
	NIM_EVERYWHERE_SRC="${work}/nope" bash "${guard}" 2>&1)"
missing_status=$?
if [ "${missing_status}" -ne 0 ] &&
	grep -q "VIOLATION graph-walks-siblings" <<<"${missing_output}"; then
	ok "a sibling package that cannot be located fails the guard, it does not shrink it"
else
	# The overrides only take effect when they point at a real tree, so a bad
	# ISONIM_SRC falls back to ../isonim. Accept either outcome, but say which.
	if [ "${missing_status}" -eq 0 ] &&
		grep -q "OK        graph-walks-siblings" <<<"${missing_output}"; then
		ok "a bogus override falls back to the checked-out sibling rather than disabling the walk"
	else
		bad "a missing sibling package is reported, not ignored" \
			"exit ${missing_status}" "${missing_output}"
	fi
fi

echo "--- ${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
