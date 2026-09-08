#!/usr/bin/env bash
#
# ci/lib/nim-imports.sh — THE Nim import extractor. One function, sourced by
# every gate that has to answer "what does this file import".
#
# WHY THIS IS A LIBRARY AND NOT A THING EACH GATE WRITES
# -----------------------------------------------------
# It was two copies for one day, and the second copy was wrong on the second
# spelling anybody tried.
#
# `ci/test/plugin-reactive-boundary.sh` shipped with its own `import_specs`,
# derived independently from the same set of examples. Its keyword test was
# `/^(import|from|include)[ \t]/` — whitespace REQUIRED after the keyword — so
# nim's newline-continued form was invisible to it:
#
#     import
#       ../../../raw_helper_probe
#
# Measured in the real repository on 2026-09-08, running PLAT-7's own
# helper-module exploit twice with everything else identical:
#
#   | spelling                              | gate                   | runtime   |
#   | import ../../../raw_helper_probe      | 15 checks, 3 FAILING   | rawRuns=6 |
#   | import <newline> ../../../raw_helper… | 15 checks, 0 failing   | rawRuns=6 |
#
# Same program, same escape, and the gate had no opinion about the second — its
# `--list-closure` reported `0 reached by import` and `closure-is-readable`
# printed OK, because the gate never saw the import and therefore never had
# anything to refuse. The form is idiomatic and prevalent: 138 files in
# `src/` and 31 in `../isonim/` are written that way.
#
# (THREE and not two because the plant is in `position_watch_plugin.nim`,
# which is also check 12's subject, so a third check reddens with it. Planted
# in a fixture that is not, the same escape gives 2. The number that matters
# is the OTHER column: zero, over an identical runtime.)
#
# `nim_imports` — the version below, from `sdk-facade-boundary.sh` — had the
# form right from the start (`([ \t]|$)`, and a `collecting` buffer that spans
# lines). So the defect was not that the problem is hard; it was that the
# problem was SOLVED, in this repository, in a file the second author had read,
# and re-derivation threw the solution away.
#
# > **ONE PREDICATE, ONE FUNCTION.** See Verification-Harness-Traps §14. A
# > second copy of a predicate is a second thing that can be wrong while its
# > twin goes on agreeing with itself.
#
# WHAT A CALLER OWES THIS FUNCTION, AND WHAT IS ENFORCED RATHER THAN ASKED FOR
# ---------------------------------------------------------------------------
# `nim_imports` refuses to analyse three shapes rather than guessing at them
# (see the block comment on the function). It cannot report a refusal itself:
# every call site reads it through a process substitution, so it runs in a
# subshell and cannot touch the caller's failure counter. A FILE is the one
# channel that crosses that boundary.
#
# So call `nim_imports_open_unanalysable_log` once, before the first extraction,
# and turn a non-empty log into a finding. Both current callers do:
# `sdk-facade-boundary.sh`'s `import-specs-analysable`, and
# `plugin-reactive-boundary.sh`'s `closure-is-readable`.
#
# **BE PRECISE ABOUT WHICH HALF OF THAT IS ENFORCED**, because an earlier
# revision of this header was not, and a convention described in the register of
# a mechanism is a convention nobody notices they have dropped:
#
#   * DESTINATION — enforced. Until 2026-09-08 an unopened log meant the awk
#     program appended its refusals to `/dev/null`, so a third caller got them
#     discarded in total silence: exactly the outcome the refusal exists to
#     prevent, arriving through the default value of one shell parameter. The
#     fallback is `/dev/stderr` now, so refusals cannot be discarded by
#     omission — at worst they are printed and not counted.
#   * FINDING — NOT enforced, and it cannot be from here. Nothing in this file
#     can make a caller fail; the caller owns its own failure counter and this
#     function runs in a subshell of it. What holds the two current callers to
#     it is not this paragraph but a case in each of their contract suites,
#     asserting that a refused line becomes a named finding.
#
# A THIRD CALLER therefore owes two things: the `nim_imports_open_unanalysable_log`
# call, and a case in its own suite that fails when a refused line is not
# reported. Neither is inferable from a green run of this library.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/nim-imports.sh"
#   nim_imports_open_unanalysable_log
#   nim_imports path/to/file.nim        # one module spec per line

# nim_imports_open_unanalysable_log — create ${IMPORT_UNANALYSABLE_LOG} and
# arrange for it to be removed on exit.
#
# INSTALLS AN EXIT TRAP, stated here because a library that installs one behind
# a caller's back is how a caller's own EXIT trap silently disappears. Neither
# current caller has another; a third that does must merge them rather than let
# this run last.
nim_imports_open_unanalysable_log() {
	IMPORT_UNANALYSABLE_LOG="$(mktemp)"
	# shellcheck disable=SC2064
	trap "rm -f '${IMPORT_UNANALYSABLE_LOG}'" EXIT
}

# ---------------------------------------------------------------------------
# Nim import extraction
#
# Emits one module spec per line for a file. Handles the forms this repo
# actually uses:
#
#   import a                     import a, b            import a/b
#   import a/[b, c]              from a/b import c      include a
#   import a as b                import a except c
#   indented imports inside `when defined(js):`
#   bracket lists split over several lines
#
# AND EVERY ONE OF THOSE WITH THE SPEC WRITTEN AS A STRING LITERAL, which is a
# separate spelling of the same import and not a rare one to reach for:
#
#   import "a/b"                 import "a/b" as c      from "a/b" import c
#   include "a/b"                import a, "b/c"        import "a/b"/[c, d]
#   import "a"/b/c               import a/"b"/c         import r"a/b"
#   import """a/b"""             import "a/b"as c       import "a/b"except d
#   from "a/b"as c import d      import a / b / c       import "a" / "b" / "c"
#
# AND EVERY ONE OF THOSE SOMEWHERE OTHER THAN THE START OF ITS OWN LINE, because
# a LINE IS NOT A STATEMENT — the mistake that hid an import in total silence
# rather than yielding a wrong spec:
#
#   import a; import b           echo 1; import a       import a;
#   when not defined(js): import a                      when(c):import a
#   elif c: import a             else: import a         when c: import a; import b
#
# `split_statements` and `strip_conditional_prefix` below handle those. At HEAD
# `when true: import <internal>` planted in the declared consumer
# src/frontend/tui/app/tui_app.nim yielded NOTHING for the line and left this
# script at `6 check(s), 0 failing`, and `import <a>; import <b>` yielded the
# single spec `<a>;import<b>` — losing the forbidden import AND the permitted
# one, so the file appeared to import nothing at all.
#
# `normalize_spec` below is what makes those the same spec as the bare form.
# Until it existed the extractor yielded `"a/b"` with the quotation marks still
# on, so it matched no forbidden pattern and resolved to no file — every "must
# not import X" rule built on this extractor was evadable by one pair of
# quotation marks, here and in
# src/frontend/tui/tests/test_tui_facade_boundary.nim's `importSpecs`, which
# mirrors it. Demonstrated rather than reasoned about: an
# `import "../../viewmodel/store/replay_data_store"` planted in the declared
# consumer src/frontend/tui/app/tui_app.nim left this script at `6 check(s), 0
# failing`, while the same import unquoted reddened `consumer-facade-only`.
# The contract suite carries both spellings now.
#
# FIVE FACTS ABOUT NIM DRIVE THE SHAPE OF THE CODE BELOW, each confirmed by
# compiling the form against nim 2.2.8 — and, where it compiles, by then USING a
# symbol from the module it imports, so that "it parses" was never mistaken for
# "it imports":
#
#   1. A STRING LITERAL SELF-TERMINATES, so the space before `as` / `except` /
#      the `import` of a `from` is optional once the spec is quoted.
#      `import "a/b"as c` compiles. A split that insists on a SPACED keyword
#      therefore sees `a/bas c` — no such module, no finding.
#   2. `/` IS AN ORDINARY INFIX OPERATOR, so `import a / b / c` and
#      `import "a" / "b" / "c"` compile and mean `a/b/c`. (`import a /b/ c`
#      does NOT — nim requires an infix operator to be spaced consistently —
#      which is why only the symmetric form has to be handled.)
#   3. QUOTES CHANGE WHAT A CHARACTER MEANS. `#`, `,`, `[`, `]` and whitespace
#      inside a literal are part of a filename, not syntax; and nim only
#      requires the BASENAME of a module path to be a valid identifier, so
#      `import "h#d/../a/b/c"` compiles. Every scan below is therefore
#      quote-aware — comment stripping and bracket counting included, because a
#      `#` cut in the wrong place hides an import and a `[` counted in the wrong
#      place swallows the rest of the file into one unterminated statement.
#   4. `;` SEPARATES STATEMENTS, so `import a; import b` is two imports and
#      `echo 1; import a` is one behind something that is not an import at all.
#      The split has to be outside literals AND outside brackets, because
#      `when (let x = 1; x > 0): import a` compiles too.
#   5. `when` / `elif` / `else` MAY CARRY THEIR STATEMENT ON THE CONDITION'S OWN
#      LINE. `when not defined(js): import a` is idiomatic and is ONE line, so
#      the indented-continuation handling below — which covers the MULTI-LINE
#      spelling of exactly the same thing, and is what made this look covered —
#      never sees it. The colon that ends the condition is chosen by WHAT
#      FOLLOWS it, because `when F(a: 1).a == 1:` and `when {1: 2}.len > 0:`
#      compile as well.
#
# NIM ITSELF REJECTS these, so nothing here has to carry them — checked, because
# "it might compile" is how the list above kept growing: `if` / `block` /
# `static` / `for` / `case` and proc bodies carrying an import ("'import' is
# only allowed at top level"); `when a: when b: import c` ("nestable statement
# requires indentation"); `when a: (import b)`; and `import"a/b"` — the space
# AFTER the keyword is mandatory, even though the keyword after a QUOTED spec
# may be tight.
#
# WHAT IS DELIBERATELY NOT READ, AND FAILS LOUDLY INSTEAD — three shapes, each
# appended to ${IMPORT_UNANALYSABLE_LOG} and turned into a
# `VIOLATION import-specs-analysable` at the end of this script:
#
#   * a spec containing a BACKSLASH. `import "a\x2Fb\x2Fc"` compiles and names
#     `a/b/c`, and decoding it correctly would mean implementing Nim's escape
#     rules — including that `r"..."` and `"""..."""` do NOT interpret escapes —
#     in awk, and in a second dialect in the Nim mirror, where getting it subtly
#     wrong is a silent MISS;
#   * an import statement running into, or resuming after, a BLOCK COMMENT that
#     does not close on the same line (see `strip_comment`);
#   * a line carrying a one-line conditional in any of its `;`-pieces which
#     visibly opens MORE import statements than this scan read out of it (see
#     `imports_unread`).
#
# Refusing to analyse is safe for a guard; guessing is not.
#
# WHAT IS STILL A SILENT MISS, named rather than left to be found, and bounded
# BY THE PLACE rather than by the trick — an earlier draft bounded it by the
# trick ("a character literal holding a `#` or a `\"`") and was measurably too
# narrow. THE PLACE is a NON-conditional statement sharing its line with an
# import through a `;`. Anything in that leading statement which desynchronises
# the comment cut, the quote parity or the bracket depth carries the import past
# all three. Each of these compiles on nim 2.2.8, imports usably, and leaves
# this script at `6 check(s), 0 failing` with the import planted in a declared
# consumer:
#
#   * a character literal holding a HASH — the comment cut lands inside it;
#   * a character literal holding a DOUBLE-QUOTE — quote parity inverted;
#   * a character literal holding an OPENING BRACKET of any kind — the bracket
#     depth rises, so the `;` is never taken as a separator;
#   * an ESCAPED double-quote inside an ordinary string literal, which is not a
#     character literal at all;
#   * the closing triple-quote of a multi-line string literal.
#
# A character literal holding a SEMICOLON or a CLOSING bracket is read
# correctly, so the family is not "character literals" — it is "anything that
# unbalances one of the three scans".
#
# THE BOUND IS THE PLACE AND NOTHING NARROWER. Do not re-narrow it to "where the
# LEADING statement plays the trick": that is the form the earlier draft had, and
# on 2026-09-08 two further shapes were measured through it, neither of which
# desynchronises anything in its leading statement —
#
#     discard 1; when <hash-literal> == <hash-literal>: import <helper>
#     import <surface>; when <hash-literal> == <hash-literal>: import <helper>
#
# Both are inside THE PLACE (a `;` sharing a line with an import) and both are
# CAUGHT now, by `imports_unread`, which examines every `;`-piece rather than
# only the line's first token and compares counts rather than testing existence.
# Before that they compiled, imported usably, and left the plugin gate at
# `15 checks, 0 failing` with `0 reached by import` while `closure-is-readable`
# printed OK.
#
# So the self-check covers the conditional form of the five shapes above AND the
# two just named; what it does not cover is a non-conditional leading statement
# that unbalances a scan. Extending it to EVERY LINE — not to every piece, which
# is what it now does — was measured and rejected: with the gate removed
# entirely this tree yields 59 refusal lines over the 1165 tracked `.nim` files,
# every one of them prose. That measurement is about the widening nobody is
# proposing; the per-piece form above costs ONE refusal on this repository, over
# all 1180 tracked and untracked `.nim` files — 59 against 1, which is why it
# was taken. That one is named, and the reason it is recorded rather than
# exempted is given, on `imports_unread` below.
#
# **DO NOT READ "COVERS THE CONDITIONAL FORM" AS "COVERS THE CONDITIONAL
# COLUMN".** It is a claim about the five *tricks in the condition* listed
# above, and on 2026-09-08 a sixth route was measured that is not a trick in the
# condition at all: a BLOCK COMMENT BETWEEN THE `;` AND THE `when`, which
# defeated the gate rather than any of the three scans. The gate is now asked of
# three renderings of the line (see `imports_unread`), which closes that route
# and nine further constructed spellings of it — and ONE constructed line still
# passes, written out in full there.
#
# **AND THE SEVENTH ROUTE WAS NOT IN A RENDERING EITHER — IT WAS AT THE CALL
# SITE**, measured the same day by the pass that landed this milestone. The
# invocation read `collecting == 0 && imports_unread($0, line)`, so on a
# CONTINUATION LINE of a multi-line import — the spelling 138 files under `src/`
# use, named forty lines below — the self-check never ran:
#
#     import
#       <surface>; when <hash-lit> == <hash-lit>: import <helper>
#
# It is worth being exact about why that was outside both residual shapes rather
# than an instance of one. NO RENDERING WAS DESYNCHRONISED: all three see the
# conditional on that line, and any of them would have gated it. Shape 1 below
# requires a line no rendering can see a conditional on; shape 2 requires all
# three defeated at once. This required neither, and cost one ordinary
# multi-line import plus one character literal — materially cheaper than the
# survivor shape 2 names, which is three mutually-cancelling tricks on one line.
# It is closed: the gate is asked of every line, and the buffer is dropped with
# the refusal. Arms G18 / G18b put the guard back, graded by both suites.
#
# THE SAME ATTACK ON THE CALL SITE FOUND ONE MORE AND IT IS ALSO CLOSED: a
# trailing CARRIAGE RETURN, which `trim` does not remove, made a bare `import`
# on a CRLF line the string `import\r` — opening no statement and counting for
# nothing. See the `sub(/\r$/, ...)` at the top of the scan loop. Arm G19.
#
# **THE RESIDUAL IS STILL TWO SHAPES, AND BOTH ARE THE ONES ALREADY NAMED:**
# the non-conditional place named above, and a conditional line that
# desynchronises all three renderings of the gate at once. A worked instance of
# the first, constructed and measured on 2026-09-08 while attacking the call
# site, is `]# ; import <helper>` on the line closing a multi-line block comment
# opened by a non-import statement: it compiles, imports usably, and is lost in
# silence, because the `]#` desynchronises the comment cut and there is no
# conditional anywhere for the gate to see. (The conditional spelling of the
# same line, `]# ; when <hash-lit> == <hash-lit>: import <helper>`, IS refused,
# and `]# when …: import <helper>` without the `;` does not compile at all —
# nim rejects it as invalid indentation.)
# ---------------------------------------------------------------------------

nim_imports() {
	[ -f "$1" ] || return 0
	# THE FALLBACK IS STDERR, NOT /dev/null — see the header. A caller that
	# never opened the log used to have its refusals discarded in silence,
	# which is the one outcome the refusal exists to prevent; it now cannot
	# discard them, only decline to turn them into a finding.
	awk -v unan="${IMPORT_UNANALYSABLE_LOG:-/dev/stderr}" '
	function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
	# Occurrences of CH outside a string literal.
	#
	# Quote-aware because this counts the brackets that decide whether an
	# import statement is finished, and `import "a[b/../c"` is ONE module whose
	# name contains a bracket. Counted naively, that bracket never closes: the
	# statement is never flushed, every later line is glued onto the same buffer
	# and the file yields no specs at all — a whole file made invisible to every
	# rule downstream by one character inside quotation marks.
	function count(s, ch,   n, i, c, inq) {
		n = 0; inq = 0
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\"") { inq = 1 - inq; continue }
			if (inq == 0 && c == ch) n++
		}
		return n
	}
	# Strip comments, judging "comment" OUTSIDE string literals.
	#
	# Nim only requires the BASENAME of a module path to be a valid identifier,
	# so `import "h#d/../a/b/c"` compiles and imports `a/b/c`. Cut at the first
	# `#` regardless of quoting and that statement becomes `import "h`, which
	# names nothing — the forbidden module is reached and no rule ever sees it.
	#
	# BLOCK COMMENTS ARE REMOVED RATHER THAN TREATED AS A LINE COMMENT, because
	# `import #[c]# a/b` and `import a/b #[c]#` both compile (nim 2.2.8) and a
	# cut at the first `#` loses the spec of the first one entirely. They nest
	# (`#[ #[x]# ]#`), so this counts depth, and `##[ … ]##` — the doc spelling —
	# opens one too.
	#
	# WHEN THE BLOCK COMMENT DOES NOT CLOSE ON THIS LINE the rest of the
	# statement is on a line this function will never see in the same call, so
	# it sets `stripped_at_block_comment` instead of guessing. The caller turns
	# that into a refusal when the line was carrying an import — see the
	# `unan` block below. Refusing to analyse is safe for a guard; guessing is
	# not.
	function strip_comment(s,   i, n, c, inq, depth, out) {
		stripped_at_block_comment = 0
		inq = 0
		out = ""
		i = 1
		n = length(s)
		while (i <= n) {
			c = substr(s, i, 1)
			if (c == "\"") { inq = 1 - inq; out = out c; i++; continue }
			if (inq == 1) { out = out c; i++; continue }
			if (c == "#") {
				if (substr(s, i + 1, 1) == "[" || substr(s, i + 1, 2) == "#[") {
					depth = 1
					i += (substr(s, i + 1, 1) == "[") ? 2 : 3
					while (i <= n && depth > 0) {
						if (substr(s, i, 2) == "#[") { depth++; i += 2; continue }
						if (substr(s, i, 2) == "]#") { depth--; i += 2; continue }
						i++
					}
					if (depth > 0) { stripped_at_block_comment = 1; return out }
					continue
				}
				return out
			}
			out = out c
			i++
		}
		return out
	}
	# True when a block comment CLOSES on this line and an import statement
	# follows it: `]# import a/b` is an import, and `strip_comment` above —
	# which starts each line outside any comment — cuts it at the `#` and yields
	# `]`, so the statement would vanish. Cross-line comment state is not
	# tracked (a `#[` inside a multi-line string literal would then swallow the
	# rest of the file), so this shape is refused rather than parsed.
	function resumes_after_block_comment(s,   i, rest) {
		for (i = 1; i <= length(s) - 1; i++) {
			if (substr(s, i, 2) != "]#") continue
			rest = trim(substr(s, i + 2))
			if (rest ~ /^(import|from|include)([ \t]|$)/) return 1
		}
		return 0
	}
	# Split S into the statements a `;` separates, ignoring a `;` inside a
	# string literal or inside brackets of any kind.
	#
	# `import a; import b` is TWO imports on one line and compiles (nim 2.2.8);
	# so does `echo 1; import a`. Read as one statement the whole line yields
	# `a/b/c;importa/b/d` — a module nobody has, so BOTH imports are lost and
	# nothing is reported. The bracket depth is what keeps
	# `when (let x = 1; x > 0): import a` — which also compiles — in one piece.
	function split_statements(s, arr,   i, c, inq, depth, cur, n) {
		n = 0; inq = 0; depth = 0; cur = ""
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\"") { inq = 1 - inq; cur = cur c; continue }
			if (inq == 0) {
				if (c == "(" || c == "[" || c == "{") depth++
				else if (c == ")" || c == "]" || c == "}") depth--
				else if (c == ";" && depth <= 0) { arr[++n] = cur; cur = ""; continue }
			}
			cur = cur c
		}
		arr[++n] = cur
		return n
	}
	# Drop trailing `)` that closes nothing in S, counting outside literals.
	#
	# Only reachable from `strip_conditional_prefix`, and only for the one
	# nested spelling nim accepts: `when a: (when b: import x)` compiles, and
	# the statement found inside it ends with the paren that closes the outer
	# one.
	function drop_unmatched_close(s) {
		while (s ~ /\)$/ && count(s, "(") < count(s, ")"))
			s = trim(substr(s, 1, length(s) - 1))
		return s
	}
	# starts_conditional T — T (ALREADY TRIMMED) begins a one-line
	# `when` / `elif` / `else`.
	#
	# ONE PREDICATE, ONE FUNCTION (Verification-Harness-Traps §14). Until
	# 2026-09-08 this test was written out twice: once in
	# `strip_conditional_prefix`, which decides whether a piece carries a
	# conditional it must reduce, and once in `imports_unread`, which decides
	# whether the line is worth self-checking at all. They are the same
	# question and a second copy is a second thing that can be wrong while its
	# twin goes on agreeing with itself.
	function starts_conditional(u) {
		return (u ~ /^(when|elif)[ \t(]/ || u ~ /^else[ \t]*:/)
	}
	# conditional_here S — some rendering S of one source line visibly begins a
	# one-line conditional, either at the start of the line or after a `;`.
	#
	# `;` is the only place a second statement can begin on a line, so those
	# are the only two positions worth asking about.
	function conditional_here(s) {
		if (starts_conditional(trim(s))) return 1
		return (s ~ /;[ \t]*(when|elif)[ \t(]/ || s ~ /;[ \t]*else[ \t]*:/)
	}
	# Remove BALANCED `#[ … ]#` spans, counting depth and IGNORING QUOTES.
	#
	# This is deliberately a SECOND, WORSE comment stripper standing beside
	# `strip_comment`, and the point is that it is wrong in a DIFFERENT
	# DIRECTION. `strip_comment` is quote-aware and cuts at a bare `#`;
	# this one is quote-blind and never cuts. The gate in `imports_unread` asks
	# its question of both renderings plus the raw line, so a line has to
	# desynchronise all three at once to get past it — see the block comment
	# on `imports_unread`.
	#
	# ON AN UNTERMINATED `#[` IT RETURNS THE REST VERBATIM rather than
	# truncating, because truncating is what `strip_comment` already does and a
	# disjunction of two renderings that fail the same way is one rendering.
	function strip_block_comments_blind(s,   i, n, depth, out, start) {
		out = ""; i = 1; n = length(s)
		while (i <= n) {
			if (substr(s, i, 2) == "#[") {
				start = i; depth = 1; i += 2
				while (i <= n && depth > 0) {
					if (substr(s, i, 2) == "#[") { depth++; i += 2; continue }
					if (substr(s, i, 2) == "]#") { depth--; i += 2; continue }
					i++
				}
				if (depth > 0) return out substr(s, start)
				out = out " "
				continue
			}
			out = out substr(s, i, 1); i++
		}
		return out
	}
	# A ONE-LINE `when` / `elif` / `else`, reduced to the statement it carries.
	#
	# `when not defined(js): import a/b` is idiomatic nim, compiles, and is ONE
	# LINE — so the indented-continuation handling below, which covers the
	# multi-line spelling of the same thing, never sees it. At HEAD the line did
	# not start with `import`, so it was skipped outright and the import was
	# invisible to every rule. `elif`, `else`, `when(cond):` and `else:import a`
	# (no space anywhere) all compile too.
	#
	# WHICH COLON ENDS THE CONDITION is decided by what FOLLOWS it, not by
	# counting brackets, because a colon can legally appear inside the condition
	# in more ways than a lexer this size can enumerate — `when F(a: 1).a == 1:`,
	# `when {1: 2}.len > 0:` and a comparison of two colon character literals
	# all compile. The first colon whose remainder starts an import statement is
	# the answer for every one of them, and for `when true: import "a:b"` as
	# well, since a colon inside a literal is skipped.
	function strip_conditional_prefix(t,   i, c, inq, rest) {
		if (!starts_conditional(t)) return t
		inq = 0
		for (i = 1; i <= length(t); i++) {
			c = substr(t, i, 1)
			if (c == "\"") { inq = 1 - inq; continue }
			if (inq == 1 || c != ":") continue
			rest = trim(substr(t, i + 1))
			if (rest ~ /^(import|from|include)([ \t]|$)/)
				return drop_unmatched_close(rest)
		}
		return t
	}
	# opens_import PIECE — true when `handle_stmt` would take PIECE as the start
	# of an import statement.
	#
	# ONE PREDICATE, ONE FUNCTION (Verification-Harness-Traps §14). The
	# self-check below has to ask exactly the question `handle_stmt` asks, on
	# two different renderings of the same line, and asking it twice in two
	# spellings is how a self-check comes to disagree with the scan it is
	# checking. The bare-keyword arm is here for the same reason it is there:
	# `import` alone on a line opens a statement the following lines finish.
	function opens_import(t,   frag) {
		frag = strip_conditional_prefix(t)
		if (frag ~ /^(import|from|include)[ \t]/) return 1
		if (frag == "import" || frag == "include" || frag == "from") return 1
		return 0
	}
	# THE SELF-CHECK ON THE RULE ABOVE: the RAW text of this line visibly
	# carries MORE import statements than the scan managed to read out of it.
	#
	# It exists because a condition is arbitrary nim and this is a lexer, not a
	# parser. A CHARACTER LITERAL is the concrete way to break it: the scans
	# here model double-quoted strings and nothing else, so a condition that
	# compares a character literal holding a HASH, a SEMICOLON or a single
	# DOUBLE-QUOTE lands the comment cut, the statement split or the quote
	# parity inside that literal. All three compile (nim 2.2.8) and all three
	# were a silent MISS. They are written out, characters and all, in the
	# mirror of this function in
	# src/frontend/tui/tests/test_tui_facade_boundary.nim — an apostrophe
	# cannot appear inside this single-quoted awk program, which is why they
	# are described here rather than shown.
	#
	# Rather than teach three scans about character literals — which would then
	# have to know that a numeric suffix like 1-quote-u8 is not one — the
	# extractor notices that it read LESS out of a line than the line plainly
	# has on it, and refuses. A guard may fail to read; it may not fail to read
	# QUIETLY.
	#
	# TWO THINGS HERE ARE A REPAIR OF 2026-09-08, and both were measured on the
	# real gate rather than reasoned about. The earlier form asked whether the
	# FIRST TOKEN OF THE LINE was `when`/`elif`/`else`, and then whether ANY
	# piece of the line yielded an import:
	#
	#   1. KEYED ON THE FIRST TOKEN, a conditional in a later `;`-piece was
	#      never examined at all —
	#          discard 1; when <hash-literal> == <hash-literal>: import <helper>
	#      compiles on nim 2.2.8, imports usably, and left the plugin gate at
	#      `15 checks, 0 failing` with `0 reached by import` and
	#      `closure-is-readable` printing OK: the exact fingerprint of a gate
	#      that did not report having failed to read something.
	#   2. TESTED FOR EXISTENCE, one readable import cleared the whole line —
	#          import <surface>; when <hash-literal> == <hash-literal>: import <helper>
	#      passed on the strength of the FIRST import while the second was lost.
	#      (A `when`-first spelling of this gap does not compile, so it was only
	#      ever reachable through gap 1.)
	#
	# The verdict is a COUNT rather than an existence test: `wanted` is how many
	# import statements the RAW line visibly opens, `read` is how many the scan
	# will actually take out of the stripped line, and fewer read than wanted is
	# a refusal.
	#
	# `wanted` AND THE CONDITIONAL TEST ARE BOTH PLAIN REGEXES OVER THE RAW
	# LINE, and that is not laziness — it is the only thing that can work here.
	# The raw line is by construction the text that DESYNCHRONISES the
	# quote-aware, bracket-aware scans; asking one of them where the statements
	# begin gives an answer built on the very confusion being detected. Measured
	# rather than reasoned about: a first version of this counted `wanted` by
	# running `split_statements` over the raw line, and `when <semicolon-literal>
	# == <semicolon-literal>: import x` split INSIDE the character literal, so
	# `wanted` came out 0 and the refusal that had caught that shape since the
	# extractor was written silently stopped firing. Its contract case in
	# sdk-facade-boundary-test.sh went red on the spot, which is what a contract
	# case is for. `read` is quote-aware because `read` must be exactly what
	# `handle_stmt` will do; `wanted` must not be.
	#
	# WHY THE GATE IS STILL A CONDITIONAL SOMEWHERE ON THE LINE, and not "every
	# line": widening it to every line was measured and rejected — real prose
	# comments in this repository carry a `;` before the word `from` or a `:`
	# before `import`/`from` and would go red for nothing. Measured on this
	# tree with the gate removed entirely: **59 refusal lines** over the 1165
	# tracked `.nim` files, all of them prose. So the gate stays.
	#
	# THE GATE IS ASKED OF THREE RENDERINGS OF THE LINE, AND THAT IS THE WHOLE
	# REPAIR OF THIS ROUND. Until 2026-09-08 it was a plain regex over the RAW
	# line only, and a BLOCK COMMENT BETWEEN THE `;` AND THE `when` walked
	# through it: `strip_comment` removes the comment, so the scan below reads
	# the line correctly-ish, but the gate never fired and the line was never
	# self-checked. Measured against the real gate, planted in a real fixture,
	# reaching a real helper module — each compiles on nim 2.2.8 and imports
	# usably (the probe calls a proc out of the imported module):
	#
	#   | plant                                                | gate                        |
	#   | discard 1; when <hash-lit> == <hash-lit>: import <h>  | REFUSED (control)           |
	#   | discard 1; #[c]# when <hash-lit> == <hash-lit>: …     | read, ZERO specs — LOST     |
	#   | discard 1; #[c]# when <dquote-lit> != <x-lit>: …      | read, ZERO specs — LOST     |
	#
	# **THE OBVIOUS ONE-LINE REPAIR IS A TRADE, NOT A FIX, and it was measured
	# before it was rejected.** Moving the gate from `raw` to the stripped
	# `line` catches both shapes above and REOPENS one the raw gate caught:
	#
	#   discard <hash-lit>; when <hash-lit> == <hash-lit>: import <h>
	#
	# `strip_comment` cuts at the `#` inside that leading character literal, so
	# the stripped line is `discard <quote>` — no `;`, no `when`, gate silent —
	# while the raw line plainly carries both. The two renderings resolve a `#`
	# in OPPOSITE directions, so neither alone is the answer: the gate asks
	# BOTH, plus a third, quote-blind, block-comment-only rendering
	# (`strip_block_comments_blind`) which is what defeats a block comment
	# carrying a `]` inside it. A line must desynchronise ALL THREE to pass.
	#
	# COST, MEASURED, AND THE NUMBER IS NOT ZERO ANY MORE — say so rather than
	# quote a figure the tree has moved past. Swept over all **1180** tracked
	# and untracked `.nim` files on 2026-09-08, the disjunction yields
	# **exactly ONE refusal line**, and it is this one:
	#
	#   src/frontend/tui/tests/test_tui_facade_boundary.nim, in a `##` doc
	#   comment that WRITES OUT `discard 1; when <hash-lit> == <hash-lit>:
	#   import <helper>` as prose describing this very shape.
	#
	# It is RECORDED RATHER THAN EXEMPTED, deliberately, and the reason is that
	# it is a correct refusal and not a false one: the extractor genuinely
	# cannot read that line, and saying so is the whole contract of this
	# channel. It costs nothing — no gate has that file in its subject set, so
	# neither `import-specs-analysable` nor `closure-is-readable` sees it, and
	# both gates are green with it present. Exempting it by name would add a
	# suppression mechanism this library does not have, to silence the one
	# instance in the tree of the thing it is for. The number to check this
	# against is the sweep, not this comment: 1180 files, 8975 specs, 1 refusal.
	# (The gate was **0 refusals** when it was written; the refusal arrived with
	# the prose above, not with a code change.)
	#
	# WHAT STILL GETS PAST IT — ONE constructed line, which compiles and imports
	# usably:
	#
	#   discard <dquote>#[<dquote> & <hash-lit>; #[c]# when <hash-lit> == <hash-lit>: import <h>
	#
	# It pays for all three at once: the `#[` inside the string literal
	# desynchronises the quote-blind depth count, the character literal
	# truncates the quote-aware strip, and the real block comment breaks the raw
	# regex. **This is the standing evidence that the gate is a heuristic and
	# not a decision procedure** — SEVEN routes past this boundary have now been
	# found by seven passes, and the seventh was not in this function or its
	# gate at all but at the CALL SITE that invokes them (see the header, and
	# the comment on the `imports_unread` call in the scan loop below). The
	# assessment of replacing the extractor with the import graph the nim
	# compiler itself computes is recorded in
	# CodeTracer-Platform.milestones.org under the FIFTH verification.
	#
	# (NO APOSTROPHE MAY APPEAR ANYWHERE BELOW THE OPENING QUOTE OF THIS awk
	# PROGRAM. Two crept into this comment block when it was written and the
	# whole extractor returned nothing for every line, silently; the sweep in
	# this pass caught it only because it runs a POSITIVE CONTROL first —
	# Verification-Harness-Traps §4.)
	function imports_unread(raw, line,   i, m, spieces, t, tmp, wanted, read) {
		t = trim(raw)
		if (!conditional_here(raw) && !conditional_here(line) &&
		    !conditional_here(strip_block_comments_blind(raw)))
			return 0
		tmp = raw
		wanted = gsub(/[;:][ \t]*(import|from|include)([ \t]|$)/, "&", tmp)
		if (t ~ /^(import|from|include)([ \t]|$)/) wanted++
		if (wanted == 0) return 0
		m = split_statements(line, spieces)
		read = 0
		for (i = 1; i <= m; i++)
			if (opens_import(trim(spieces[i]))) read++
		return read < wanted
	}
	# Truncate S before the first top-level occurrence of any keyword in KWS
	# (a space-separated list).
	#
	# "Top-level" is outside a string literal, so a module whose name contains
	# ` as ` is not cut in half. The keyword may be preceded by whitespace OR BY
	# A CLOSING QUOTE, and that second case is the one a spaced-keyword regex
	# misses: a string literal self-terminates, so `import "a/b"as c`,
	# `import "a/b"except d` and `from "a/b"as c import d` are all legal nim
	# (compiled, 2.2.8) and all resolve to `a/b`. Split only on ` as ` and the
	# extractor yields `a/bas c` — no such module, no finding, evasion complete.
	function cut_kw(s, kws,   kw, n, i, j, c, inq, prev, nxt, len) {
		n = split(kws, kw, " ")
		inq = 0
		len = length(s)
		for (i = 1; i <= len; i++) {
			c = substr(s, i, 1)
			if (c == "\"") { inq = 1 - inq; continue }
			if (inq == 1) continue
			# inq is 0 here, so a preceding quote is necessarily a CLOSING one.
			prev = (i == 1) ? "" : substr(s, i - 1, 1)
			if (prev != "" && prev != " " && prev != "\t" && prev != "\"") continue
			for (j = 1; j <= n; j++) {
				if (substr(s, i, length(kw[j])) != kw[j]) continue
				# A keyword is only a keyword when it ends the word, which is
				# what keeps `import a/exceptions` and `import a, ascii` whole.
				# END OF STRING counts: `from ../ui/shortcut_labels import`
				# with the symbol list on the lines below is how 43 tracked
				# files in this repo are written, and requiring a trailing
				# space left the spec as `../ui/shortcut_labels import` —
				# resolving to nothing, silently, at HEAD.
				nxt = substr(s, i + length(kw[j]), 1)
				if (nxt == "" || nxt == " " || nxt == "\t") return substr(s, 1, i - 1)
			}
		}
		return s
	}
	# A module spec reduced to the one spelling every rule downstream sees.
	#
	# TWO NORMALISATIONS, both of them the same module to nim and neither of
	# them cosmetic:
	#
	#   QUOTES COME OFF. `import "a/b"` is joined onto each --path root exactly
	#   as `import a/b` is (verified against nim 2.2.8 by compiling both,
	#   together with the partly quoted `"a"/b/c` and `a/"b"/c`, the raw
	#   `r"a/b"` and the triple-quoted `"""a/b"""`).
	#
	#   WHITESPACE AROUND `/` GOES. `/` is an ordinary infix operator, so
	#   `import a / b / c` and `import "a" / "b" / "c"` compile and mean
	#   `a/b/c`. Left alone the spec is `a / b / c`, which matches no pattern
	#   and resolves to no file. (Only the symmetric spacing needs handling:
	#   `import a /b/ c` is rejected by nim as `invalid module name`.)
	#
	# Sets spec_unanalysable when it meets a backslash inside a literal — see
	# the block comment above for why that is refused rather than decoded.
	function normalize_spec(s,   out, i, c, inq) {
		spec_unanalysable = 0
		out = ""; inq = 0
		for (i = 1; i <= length(s); i++) {
			c = substr(s, i, 1)
			if (c == "\"") { inq = 1 - inq; continue }
			if (inq == 1) {
				if (c == "\\") { spec_unanalysable = 1; return "" }
				out = out c
				continue
			}
			# The `r` of a raw string literal goes with the quote it
			# INTRODUCES. The `inq == 0` test is what makes that precise:
			# the quote after an `r` is an opening quote only outside a
			# literal. Without it, the closing quote of `"a/b/tracker"`
			# qualifies too and the spec becomes `a/b/tracke` — a miss, and
			# not a rare one: `src/frontend/viewmodel` alone holds 21
			# modules whose names end in `r`.
			if ((c == "r" || c == "R") && substr(s, i + 1, 1) == "\"") continue
			if (c == " " || c == "\t") continue
			out = out c
		}
		return out
	}
	function emit_spec(spec,   raw) {
		# The alias comes off HERE, per emitted spec, and not before the bracket
		# test in emit_list: `import ../[ types, config as frontend_config ]`
		# aliases ONE ELEMENT OF THE LIST, and cutting the statement at that
		# `as` would leave `../[ types, config`, which is no longer a bracket
		# list, is never expanded, and hides both modules.
		# src/frontend/index/window.nim is written exactly that way.
		raw = trim(spec)
		spec = normalize_spec(cut_kw(raw, "as"))
		if (spec_unanalysable) {
			# NOT emitted, and deliberately not guessed at. Printing the raw
			# text would be a miss dressed up as a finding-free line.
			print FILENAME "\t" raw >> unan
			return
		}
		if (spec != "") print spec
	}
	function emit_list(body,   depth, inq, i, ch, item, pre, inner, n, parts, j) {
		# Split on top-level commas: commas outside [ ] AND outside a string
		# literal, because `import "a,b"` is one module whose name contains a
		# comma, not two modules.
		depth = 0; inq = 0; item = ""
		body = body ","
		for (i = 1; i <= length(body); i++) {
			ch = substr(body, i, 1)
			if (ch == "\"") inq = !inq
			else if (inq == 0) {
				if (ch == "[") depth++
				else if (ch == "]") depth--
			}
			if (ch == "," && depth == 0 && inq == 0) {
				item = trim(item)
				if (item != "") {
					if (item ~ /\[.*\]$/) {
						# `std / [a, b]` and `a/[b, c]` are the same
						# statement with different whitespace habits, so
						# trim before AND after dropping the separator.
						# The test is anchored at the end for a second
						# reason now: `import "a/[b]"` ends in a QUOTE,
						# so it is one module whose name contains
						# brackets — which nim then fails to open —
						# rather than a bracket list. Expanding it would
						# invent a module nobody imported. `"a/b"/[c, d]`
						# does end in `]` and is expanded, with the
						# quotes coming off in emit_spec afterwards.
						pre = item; sub(/\[.*$/, "", pre); pre = trim(pre)
						sub(/\/$/, "", pre); pre = trim(pre)
						inner = item; sub(/^[^[]*\[/, "", inner); sub(/\][^]]*$/, "", inner)
						n = split(inner, parts, ",")
						for (j = 1; j <= n; j++) {
							# A trailing comma inside the bracket list is
							# legal Nim and yields an empty part; emitting
							# `prefix/` for it would invent a module.
							if (trim(parts[j]) != "") emit_spec(pre "/" trim(parts[j]))
						}
					} else {
						emit_spec(item)
					}
				}
				item = ""
			} else {
				item = item ch
			}
		}
	}
	function flush(stmt) {
		if (stmt ~ /^from[ \t]/) {
			sub(/^from[ \t]+/, "", stmt)
			# `from "a/b"import c` needs no space either, so the `import`
			# that ends the module part is found the same way `as` is.
			stmt = cut_kw(stmt, "import")
		} else {
			sub(/^import[ \t]+/, "", stmt)
			sub(/^include[ \t]+/, "", stmt)
		}
		stmt = cut_kw(stmt, "except")
		emit_list(stmt)
	}
	# One statement, fed either from a whole line or from one `;`-separated
	# piece of it. Owns the multi-line buffering: `collecting` and `buf` say
	# whether a bracket list or a bare `import` is still waiting for the lines
	# beneath it.
	function handle_stmt(t) {
		if (collecting == 0) {
			t = strip_conditional_prefix(t)
			# A bare `import` on its own line is the other common spelling
			# in this repo (src/frontend/ui/flow.nim opens that way); the
			# module list follows on the indented lines beneath it. It is
			# not a niche form: 138 files under `src/` and 31 under
			# `../isonim/` are written that way, and it is the spelling
			# the re-derived extractor in the plugin gate could not see.
			#
			# `from` continues the same way and was missed here until
			# 2026-09-08, found while measuring that re-derivation defect
			# against this function. Compiled AND RUN on nim 2.2.8 — the
			# probe calls a proc out of the module, so "it parses" was not
			# mistaken for "it imports":
			#
			#     from
			#       dep/helper import depHello
			#
			# THE TEST IS `opens_import` AND NOT A REGEX WRITTEN HERE, because
			# `imports_unread` above has to ask the same question about the
			# same piece and a second spelling of it is a second thing that
			# can be wrong while its twin goes on agreeing with itself
			# (Verification-Harness-Traps §14). One edit to that function
			# therefore reddens the extraction AND the self-check over it,
			# which is what makes each of them evidence about the other —
			# arms G13 / G13b are that edit, graded by both contract suites.
			if (opens_import(t)) {
				buf = t
				collecting = 1
			} else {
				return
			}
		} else {
			if (t == "") return
			buf = buf " " t
		}
		if (buf ~ /^(import|from|include)$/) return
		if (count(buf, "[") == count(buf, "]") && buf !~ /,$/ && buf !~ /\[$/) {
			flush(buf)
			collecting = 0
			buf = ""
		}
	}
	{
		# A TRAILING CARRIAGE RETURN IS STRIPPED BEFORE ANYTHING ELSE READS
		# THE LINE, and this was a silent MISS until 2026-09-08, found by
		# attacking the CALL SITE rather than the renderings. `trim` removes
		# spaces and tabs, not a CR, so on a CRLF-terminated file a bare
		# `import` line is the string `import\r`: `opens_import` does not
		# recognise it, so the statement never opens, and `imports_unread`
		# does not count it either, so nothing is refused. Measured on
		# nim 2.2.8 — the same file, twice, differing only in line endings:
		#
		#   LF    import <newline>   dep/helper   -> specs: surface, helper
		#   CRLF  the identical bytes plus CRs    -> specs: surface ONLY, 0 refusals
		#
		# Both compile and both import usably (the probe calls a proc out of
		# the helper and prints from it). It is stripped rather than refused
		# because a CR is a line terminator and carries no meaning here, and
		# because the fix is free: ZERO of the 1180 tracked and untracked
		# `.nim` files in this repository carry CR line endings, so nothing
		# in the tree changes. Only a TRAILING one goes — a CR inside a
		# string literal spec would be an escape, which `normalize_spec`
		# already refuses.
		sub(/\r$/, "", $0)
		line = strip_comment($0)
		t = trim(line)
		# THE TWO BLOCK-COMMENT SHAPES THAT WOULD OTHERWISE HIDE AN IMPORT.
		# Both are refused rather than parsed, for the reason the backslash
		# case is: a wrong guess here is a silent MISS.
		if (stripped_at_block_comment &&
		    (collecting == 1 || t ~ /^(import|from|include)([ \t]|$)/)) {
			print FILENAME "\t" trim($0) >> unan
			collecting = 0; buf = ""
			next
		}
		if (resumes_after_block_comment($0)) {
			print FILENAME "\t" trim($0) >> unan
			collecting = 0; buf = ""
			next
		}
		# THE SELF-CHECK IS ASKED OF EVERY LINE, INCLUDING A
		# CONTINUATION LINE. Until 2026-09-08 this read
		# `collecting == 0 && imports_unread(...)`, and that guard
		# was the SEVENTH route past this boundary — at the CALL
		# SITE rather than in any of the three renderings. A
		# multi-line import (the spelling 138 files under `src/`
		# use) leaves `collecting == 1`, so a desynchronised
		# conditional riding on its continuation line was never
		# gated, never counted and never refused. NO RENDERING WAS
		# DESYNCHRONISED — the check simply did not run:
		#
		#     import
		#       <surface>; when <hash-lit> == <hash-lit>: import <helper>
		#
		# compiles on nim 2.2.8, imports usably, and yielded only
		# `<surface>` with ZERO refusals, while the one-line
		# spelling of the same thing is refused. The `from`
		# continuation is the same route.
		#
		# THE BUFFER IS DROPPED WITH THE REFUSAL, as it is in the
		# two block-comment arms above: this branch is now reachable
		# with `collecting == 1`, and a `buf` left behind would be
		# flushed by END — `flush("import")` emits the literal spec
		# `import`, a module nobody has, which is a fabricated
		# finding rather than a refusal.
		if (imports_unread($0, line)) {
			print FILENAME "\t" trim($0) >> unan
			collecting = 0; buf = ""
			next
		}
		nstmts = split_statements(line, stmts)
		for (si = 1; si <= nstmts; si++) handle_stmt(trim(stmts[si]))
	}
	END { if (collecting == 1) flush(buf) }
	' "$1"
}
