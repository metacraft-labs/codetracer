#!/usr/bin/env bash
#
# plugin-reactive-boundary.sh — a PLUGIN cannot reach a raw reactive primitive.
#
# WHY THIS EXISTS
# ---------------
# Extensibility-Model.md §5.3: "Long-running extension work is asynchronous and
# cancellable, with a declared budget for synchronous effects that the host
# **enforces rather than documents**." PLAT-7's enforcement is
# `plugin_host/plugin_api.nim`: a plugin's bodies run inside `runBudgeted`,
# measured against a monotonic clock, and a plugin that overruns is suspended
# and named.
#
# That is only enforcement while a plugin cannot create a computation the host
# did not wrap — and until this gate existed, it could. `codetracer_embed.nim`
# re-exports `isonim/core/[signals, computation, owner]`, because §4.1 makes
# IsoNim's signals part of the SDK's consumption model for Mode N consumers and
# the facade's own docs promise `createMemo` in scope. So a plugin importing
# nothing but the sanctioned §2.1 surface already had `createEffect`.
#
# MEASURED, on a plugin using only that facade, 20 ms budget, 8x burn. ONE RUN,
# two lines, re-measured 2026-09-08 — an earlier revision of this header spliced
# the first line of a different probe onto the second line of this one and
# printed a non-zero `runs=`, which contradicts the sentence underneath it:
#
#     rawRuns=1 burn=160ms runs=0 violations=0 suspended=false
#     per-write cost(ms)=@[160, 160, 160, 160, 160] rawRuns=6 runs=0
#                                       violations=0 suspended=false
#
# `runs` counts bodies entered through `runBudgeted` and it stays at ZERO in
# both lines, which is the whole finding: never entered through `runBudgeted`,
# never attributed, never suspended, 160 ms on every write for the life of the
# session — §5.3's frozen screen, unbounded, on the path §5.3 says "cannot be
# fixed later by asking authors to be careful".
#
# TWO AUDIENCES, ONE OF WHICH IS TRUSTED
# --------------------------------------
# An SDK CONSUMER embedding CodeTracer is application code and keeps
# `codetracer_embed` unchanged — this gate does not bind it. A PLUGIN is
# third-party code the product loads, consumes `codetracer_plugin.nim` instead,
# and is bound here. Narrowing the facade for everybody would have broken the
# Mode N promise; narrowing it for plugins is what the split is for.
#
# WHY A LINT AND NOT ONLY THE LANGUAGE
# ------------------------------------
# `codetracer_plugin.nim` filters the ten primitives out with `export … except`,
# and that genuinely stops the spelling a plugin author writes: a bare
# `createEffect(proc() = …)` in a module importing the plugin surface fails with
# `Error: undeclared identifier: 'createEffect'` (nim 2.2.8, measured).
#
# It does NOT stop the MODULE-QUALIFIED spelling. `computation.createEffect(…)`
# resolves through the re-export chain because qualification bypasses the
# `except` filter — measured, not assumed: the same probe rewritten that way
# compiles on the plugin surface and reproduces the 160 ms line above exactly.
# So the language half is a narrowing and THIS FILE IS THE BOUNDARY. It is the
# same kind of enforcement CodeTracer-Embed-SDK.md §3.2 already rests the facade
# on — "Enforcement is an import lint, not discipline".
#
# HOW A PLUGIN IS DECLARED
# ------------------------
# The same two spellings `ci/test/sdk-facade-boundary.sh` uses, because a second
# convention for the same idea is a second thing to learn:
#
#   a. a header comment within the file's first ${MARKER_SCAN_LINES} lines:
#          ## CT-PLUGIN: <reason>
#   b. a `.ct-plugin` file in the file's directory or any ancestor, whose
#      contents are the reason.
#
# `.ct-plugin` and `.sdk-consumer` are different claims and neither implies the
# other. `.sdk-consumer` says "may not reach past the facade into SDK
# internals"; `.ct-plugin` says "may not reach the raw reactive primitives the
# facade re-exports". A plugin carries both. The terminal front-end under
# `src/frontend/tui/app/` carries only the first, because it is the application
# rather than an extension of it.
#
# BOTH SPELLINGS ARE GRADED, and the header one is graded for a reason worth
# writing down: no file in this tree uses it. Every declared plugin today is
# enrolled by the `.ct-plugin` directory marker, so until 2026-09-08 the header
# path was documented, implemented, and measured by nothing — setting
# `head -n "${MARKER_SCAN_LINES}"` to `head -n 0` disabled it outright and left
# this gate at 15/0 with its contract suite at 48/0. A declaration mechanism no
# arm can reach is not a mechanism, it is a paragraph.
#
# It was KEPT rather than deleted, because the sibling gate's identical spelling
# `## SDK-CONSUMER:` carries 11 real files in this tree, and the whole argument
# for having two spellings here is that they are the same two — "a second
# convention for the same idea is a second thing to learn". Deleting one half of
# the parallel would create exactly that divergence. So the contract suite now
# carries the enrolment case AND the bound (a marker past line
# ${MARKER_SCAN_LINES} does not enrol), and arm G12 kills the first.
#
# THE RULE BINDS A PLUGIN'S REACHABLE CLOSURE, NOT ONLY ITS OWN FILE
# ------------------------------------------------------------------
# Until 2026-09-08 the two rules below were applied to each declared plugin FILE
# and to nothing else, and one module of indirection defeated them completely.
# Measured, with both mechanisms green and this gate reporting `12 checks, 0
# failing`:
#
#     # raw_helper.nim — not a plugin, not an SDK consumer, not declared anything
#     import isonim/core/computation as c
#     proc rawEffect*(body: proc()) = c.createEffect(body)
#
#     # the declared plugin, importing only the sanctioned surface and that
#     rawEffect(proc() = ... burn ...)
#     -> rawRuns=4  budgeted runs=0  violations=0  suspended=false
#
# So `every computation a plugin has is one the host created` was false, and a
# boundary one helper module defeats is one a plugin author defeats by accident.
# The rules now range over the plugin's REACHABLE CLOSURE: the declared file,
# plus every repository module it imports, transitively.
#
# The walk has to say three things, and each is a check rather than a comment:
#
#   * **It terminates.** A `seen` set over repo-relative paths, each file
#     enqueued at most once, over the finite set of files that EXIST ON DISK
#     under the importing file's own directory or one of `SEARCH_ROOTS` —
#     `resolve_repo_module`'s membership test is `[ -f "${candidate}" ]` and
#     nothing else. A cycle — which nim permits between modules — is visited
#     once and dropped.
#
#     **NOT "the finite set `git ls-files` reports", which is what this said
#     until 2026-09-08 and was measurably the wrong set.** `git ls-files`
#     appears in this file exactly once, in `all_nim_files`, where it discovers
#     SEEDS and is unioned with `git ls-files --others --exclude-standard`
#     precisely because the tracked set is not the set on disk. Measured on the
#     tree that carries PLAT-7: `git ls-files` reports ZERO of the four modules
#     this walk holds, and zero of the twelve `.nim` files the milestone adds.
#     A walk that genuinely ranged over that set would have walked nothing —
#     which is a stronger termination argument and a useless lint. The set that
#     bounds the walk is the on-disk one, so that is what the bound has to name.
#   * **It does not drag in the whole tree.** `codetracer_plugin.nim` is a
#     TERMINAL: it is reached, reported, and NOT walked, and it is not itself
#     bound by these two rules. It is the sanctioned door — its whole job is to
#     re-export the facade with the denied names filtered out, so a walk that
#     entered it would find `import codetracer_embed` and redden every plugin in
#     the tree for using the surface correctly. What binds the surface instead
#     is checks 3, 4 and 5 (it exists, it narrows, and its `except` clause names
#     exactly the denied set) plus `sdk-facade-boundary.sh`'s own check 4.
#   * **It says what it does at a module it cannot resolve.** A spec that
#     resolves to no repository file is a module this gate cannot read, and it
#     therefore cannot bind: `std/…` and `system` are the standard library,
#     which carries no reactive primitive and is admitted by name; ANY OTHER
#     unresolvable spec is a finding (check 11), because "I could not read it"
#     and "it is clean" are different facts and only one of them is a result.
#     That is why a bare `import strutils` is refused with the remedy `std/`:
#     the gate genuinely cannot tell that spelling from a nimble package of the
#     same name, and refusing what it cannot read is the only honest answer.
#
# THE CONTROLS RUN THROUGH THE RULE'S OWN PREDICATES
# --------------------------------------------------
# Verification-Harness-Traps §4a and §14, and the specific defect
# `ci/test/tui-layer-split-boundary.sh` records at its head: a gate whose rule
# and control were two literal copies of one regex passed while the rule was
# broken. `denied_imports_in` and `denied_names_in` below are each ONE function.
# Checks 1 and 2 assert declared plugins yield nothing from them; checks 6 and 7
# assert named real files yield a KNOWN COUNT from the same two functions.
# Breaking either scanner reddens its control.
#
# ONE PREDICATE, ONE FUNCTION — RULE AND CONTROL BOTH CALLING IT. That is the
# rule this campaign paid for three times, and it is written up as
# Verification-Harness-Traps §14. Every predicate this gate matches with is now
# a named function, so a mutation aimed at it has exactly one target:
#
#   `nim_imports`            what a file imports (ci/lib/nim-imports.sh, shared
#                            with sdk-facade-boundary.sh — re-derived here once,
#                            and the copy could not see a newline-continued
#                            import)
#   `denied_specs_matching`  whether a spec is denied (rule + check 11)
#   `denied_imports_in`      the import rule       (check 1 + control 6)
#   `identifier_pattern`     how a name is matched (the name scanner + the
#                            controls in checks 7, 8 and 10, which were four
#                            further inline copies of it)
#   `plugin_closure`         the walk              (rule + controls 12 and 13)
#
# Usage:
#   ci/test/plugin-reactive-boundary.sh
#   ci/test/plugin-reactive-boundary.sh --root DIR
#   ci/test/plugin-reactive-boundary.sh --list-plugins
#   ci/test/plugin-reactive-boundary.sh --list-closure
#
# `--root` exists so ci/test/plugin-reactive-boundary-test.sh can drive every
# check against synthetic trees. It is not used in CI.

set -uo pipefail

# ---------------------------------------------------------------------------
# Shared code
# ---------------------------------------------------------------------------

# THE NIM IMPORT EXTRACTOR, shared with ci/test/sdk-facade-boundary.sh. Sourced
# relative to THIS FILE rather than to `${root}`, because `--root` points at a
# synthetic tree that has no `ci/` in it.
# The path is repo-root-relative because that is where shellcheck resolves a
# `source=` from, and SC1091 is disabled for the same reason ci/lint/nim.sh
# disables it: the pre-commit hook runs shellcheck without -x and cannot
# follow the file at all.
# shellcheck source=ci/lib/nim-imports.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/nim-imports.sh"

# `nim_imports` REFUSES to analyse three shapes rather than guessing at them,
# and it writes each refusal to this file because a process substitution puts it
# in a subshell where it cannot touch `failures`. Check 11 turns a non-empty log
# into a finding.
#
# OPENING THE LOG IS A CONVENTION AND TURNING IT INTO A FINDING IS THE CALLER'S
# JOB — the library cannot make either happen and does not pretend to. What it
# does enforce is the DESTINATION: with no log open the refusals go to stderr
# rather than to /dev/null, so a third caller that forgets this line cannot
# discard them silently, only decline to count them. What holds THIS gate to
# counting them is the case in ci/test/plugin-reactive-boundary-test.sh that
# fails when a refused line is not reported, not this comment.
nim_imports_open_unanalysable_log

# ---------------------------------------------------------------------------
# Configuration — every path is repo-relative and every one of them is also
# created by the contract suite's synthetic trees, so no check is skipped there.
# ---------------------------------------------------------------------------

# Where the denied set is DEFINED. Both this gate and the plugin surface read
# it from here; nothing hardcodes the ten names.
PRIMITIVES_REL="src/frontend/viewmodel/plugin_host/plugin_api.nim"
PRIMITIVES_CONST="PluginDeniedPrimitives"

# The surface a plugin consumes, and the constant it must declare — the same
# drift guard `sdk-facade-boundary.sh` puts on `CodeTracerEmbedFacadeModule`,
# so renaming the file without renaming the constant cannot silently disarm
# this gate.
SURFACE_REL="src/frontend/viewmodel/codetracer_plugin.nim"
SURFACE_MODULE="codetracer_plugin"
SURFACE_CONST="CodeTracerPluginSurfaceModule"

# The wider facade the surface narrows. Also check 6's subject: it imports the
# denied modules, in the bracket spelling, and must therefore yield findings
# from the very predicate check 1 uses.
FACADE_REL="src/frontend/viewmodel/codetracer_embed.nim"
FACADE_MODULE="codetracer_embed"

# Check 8's subject: a declared plugin whose DOC COMMENT names denied
# primitives and whose code does not. The comment stripper has to discriminate,
# in both directions, or check 2 is either blind or permanently red on prose.
PROSE_PROBE_REL="src/frontend/viewmodel/tests/unit/plugin_fixtures/position_watch_plugin.nim"

# Module specs a declared plugin may not import, with the reason a reader needs.
# Matched against the spec with any leading `./` and `../` hops removed, so
# `../../codetracer_embed` is the same denial as `codetracer_embed`.
DENIED_IMPORTS=(
	"isonim/core/computation;it carries createEffect, createRenderEffect, createComputed, createMemo, onMount and updateComputation"
	"isonim/core/owner;it carries createRoot, runWithOwner, getOwner and onCleanup"
	"${FACADE_MODULE};the SDK facade re-exports both of those for §4.1's Mode N consumers, who are application code; a plugin is not"
)

# How far into a file the `## CT-PLUGIN:` header marker may appear.
MARKER_SCAN_LINES=40

# Where an unqualified module spec is looked up, after the importing file's own
# directory. The same list `ci/test/sdk-facade-boundary.sh` uses, for the same
# reason: it mirrors the `--path` entries the ViewModel lanes compile with
# (ci/lib/test-lane-files.sh `test_lane_extra_flags`) plus config.nims. A
# resolver that disagrees with the compiler is a resolver that binds a different
# program than the one that runs.
SEARCH_ROOTS=("src/frontend/viewmodel" "src/frontend" "src" ".")

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
list_plugins=0
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		shift
		root="$1"
		;;
	--list-plugins)
		list_plugins=1
		;;
	--list-closure)
		list_plugins=2
		;;
	*)
		echo "plugin-reactive-boundary.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done
cd "${root}" || exit 2

# ---------------------------------------------------------------------------
# Reporting — every check runs and reports; the status is decided at the end,
# for the reason written up in ci/lib/lint-steps.sh.
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Shared predicates. Rule and control call the SAME function — see the header.
# ---------------------------------------------------------------------------

# code_lines FILE — FILE with comments removed.
#
# Doc comments are where a module explains the rule, so `plugin_api.nim` and
# every fixture name the denied primitives in prose. A scanner that could not
# tell prose from code would be permanently red on the files that document it,
# and the usual repair — rewording a comment to appease a regex — is the smell
# Verification-Harness-Traps §4d names. Check 8 asserts this discriminates.
code_lines() {
	sed -e 's/#\[.*\]#//g' -e 's/[[:space:]]*##\?.*$//' "$1" 2>/dev/null
}

# denied_primitives — the primitive names, read out of PRIMITIVES_REL's
# `PluginDeniedPrimitives` table. Never hardcoded here: the whole point of that
# table is that the code, the plugin surface and this gate cannot drift.
denied_primitives() {
	[ -f "${PRIMITIVES_REL}" ] || return 0
	awk -v const_name="${PRIMITIVES_CONST}" '
	$0 ~ ("^[[:space:]]*" const_name "\\*?[[:space:]]*[:*]") { inside = 1; next }
	inside && /^[[:space:]]*\]/ { inside = 0 }
	inside {
		if (match($0, /\("[A-Za-z_][A-Za-z0-9_]*"/)) {
			s = substr($0, RSTART + 2, RLENGTH - 3)
			print s
		}
	}
	' "${PRIMITIVES_REL}" | sort -u
}

# surface_except_names — the identifiers SURFACE_REL filters out of its
# re-export, read off the `export … except` clause itself rather than out of a
# comment beside it.
surface_except_names() {
	[ -f "${SURFACE_REL}" ] || return 0
	awk '
	function emit(s,   n, i, parts, t) {
		sub(/#.*/, "", s)
		n = split(s, parts, ",")
		for (i = 1; i <= n; i++) {
			t = parts[i]
			gsub(/[[:space:]]/, "", t)
			if (t != "") { print t; emitted++ }
		}
	}
	{
		line = $0
		if (collecting == 0) {
			if (line !~ /^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+except([[:space:]]|$)/) next
			sub(/^[[:space:]]*export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+except/, "", line)
			collecting = 1
		}
		emit(line)
		stripped = line
		sub(/#.*/, "", stripped)
		sub(/^[[:space:]]+/, "", stripped)
		sub(/[[:space:]]+$/, "", stripped)
		# `export m except` may end its own line with the list indented
		# beneath it, which is how SURFACE_REL is written and how nim reads
		# it — so an EMPTY remainder continues the statement rather than
		# ending it. Ending on the first empty line once something has been
		# emitted is what stops the scan running off into the rest of the
		# file if the clause is ever written some third way.
		if (stripped != "") {
			if (stripped !~ /,$/) collecting = 0
		} else if (emitted > 0) {
			collecting = 0
		}
	}
	' "${SURFACE_REL}" | sort -u
}

# THE IMPORT EXTRACTOR IS `nim_imports`, FROM ci/lib/nim-imports.sh
#
# It is not re-derived here, and that is a repair rather than a preference.
# This gate shipped with its own `import_specs`, written from the same set of
# examples, and it required whitespace after the keyword
# (`/^(import|from|include)[ \t]/`). Nim's newline-continued form was therefore
# invisible to it:
#
#     import
#       ../../../raw_helper_probe
#
# Measured in this repository on 2026-09-08, running the helper-module exploit
# from the section above twice with everything else identical:
#
#     import ../../../raw_helper_probe      -> 15 check(s), 3 failing
#     import <newline> ../../../raw_helper… -> 15 check(s), 0 failing
#
# The runtime was identical in both — `rawRuns=6 runs=0 violations=0
# suspended=false`, the same unbudgeted escape §5.4 says cannot exist. Under the
# newline spelling `--list-closure` reported `0 reached by import` and
# `closure-is-readable` printed OK: the gate did not report that it had failed
# to read something, because it never saw the import at all. The form is
# idiomatic and prevalent — 138 files under `src/` and 31 under `../isonim/`.
#
# `sdk-facade-boundary.sh` had the form right from the start, so the fix is not
# a better regex here but ONE function in ci/lib/nim-imports.sh that both gates
# call. See Verification-Harness-Traps §14: one predicate, one function.

# normalize_spec SPEC — leading `./` and `../` hops removed, so a relative
# reach at `../../codetracer_embed` is the same denial as the bare name.
normalize_spec() {
	local s="$1"
	while :; do
		case "${s}" in
		./*) s="${s#./}" ;;
		../*) s="${s#../}" ;;
		*) break ;;
		esac
	done
	printf '%s' "${s}"
}

# denied_specs_matching SPEC — every DENIED_IMPORTS entry SPEC matches, one per
# line, empty when it matches none.
#
# THE DENIAL TEST ITSELF, IN ONE PLACE. `denied_imports_in` below is the rule,
# and check 11's `unreadable_specs_in` has to ask the same question in order to
# stay quiet about a spec check 1 is already reporting. Written as two copies of
# the test they could disagree about what "denied" means, and the mutation arm
# aimed at the test would have two targets and hit neither — which is exactly
# how it was first written, and the harness reported
# `pattern occurs 2 times, expected 1` rather than scoring a kill.
denied_specs_matching() {
	local norm entry denied
	norm="$(normalize_spec "$1")"
	for entry in "${DENIED_IMPORTS[@]}"; do
		denied="${entry%%;*}"
		# The inner expansion is QUOTED (SC2295): unquoted, `${denied}` is a
		# glob pattern rather than a literal suffix. No entry in DENIED_IMPORTS
		# carries a metacharacter today, so this is meaning-preserving now and
		# is the difference between a literal match and a pattern match the day
		# one does.
		if [ "${norm}" = "${denied}" ] || [ "${norm%/"${denied}"}" != "${norm}" ]; then
			printf '%s\n' "${denied}"
		fi
	done
}

# denied_imports_in FILE — every denied module spec FILE imports, as
# `<spec>|<denied>`, one per line.
#
# ONE FUNCTION, CALLED BY THE RULE (check 1) AND BY ITS CONTROL (check 6).
# That is the whole reason it is a function: written as two copies of one
# pattern, breaking the rule's copy would leave the control's copy intact and
# agreeing with itself, which is the defect `tui-layer-split-boundary.sh`
# records at its head and Verification-Harness-Traps §4a generalises.
denied_imports_in() {
	local file="$1" spec denied
	while IFS= read -r spec; do
		[ -n "${spec}" ] || continue
		while IFS= read -r denied; do
			[ -n "${denied}" ] || continue
			printf '%s|%s\n' "${spec}" "${denied}"
		done < <(denied_specs_matching "${spec}")
	done < <(nim_imports "${file}")
}

# strip_compiles — remove every balanced `compiles( … )` span from stdin.
#
# THE ONE NIM FORM THAT NAMES A ROUTINE WITHOUT THE POSSIBILITY OF CALLING IT.
# `compiles(createEffect(proc() = discard))` is a compile-time boolean; the
# expression inside is never instantiated and never runs, and the answer this
# gate wants — "can a plugin reach it" — is precisely what such an expression
# is asking. `plugin_fixtures/surface_probe_plugin.nim` is built out of
# twenty-one of them, and it is the file that ASSERTS the denial, so a rule
# that could not tell that form from a call would redden on its own evidence.
#
# This is an exemption on a FORM rather than on a FILE, deliberately. A named
# file would be an exemption a second file could quietly join; a form cannot be
# abused, because there is no way to make `compiles` execute its argument.
#
# The parens are BALANCED rather than cut to end-of-line: `discard compiles(1)`
# followed by a real call on the same line would otherwise take the call with
# it, which is a silent MISS. Check 10 asserts this discriminates in both
# directions.
strip_compiles() {
	awk '
	{
		line = $0
		out = ""
		i = 1
		n = length(line)
		while (i <= n) {
			if (substr(line, i, 9) == "compiles(") {
				depth = 1
				i += 9
				while (i <= n && depth > 0) {
					c = substr(line, i, 1)
					if (c == "(") depth++
					else if (c == ")") depth--
					i++
				}
				continue
			}
			out = out substr(line, i, 1)
			i++
		}
		print out
	}
	'
}

# identifier_pattern NAME — the ERE this gate matches an identifier with.
#
# ONE PREDICATE, ONE FUNCTION — Verification-Harness-Traps §14. It was written
# out FIVE TIMES: once in `denied_names_in` below (the rule's scanner, which
# check 7 controls) and four times inline in checks 8 and 10. Those four were a
# second, third, fourth and fifth copy that could drift from the rule while
# going on agreeing with each other, and a mutation aimed at "the way this gate
# matches a name" had five targets and would have hit whichever one the arm
# happened to quote. Two copies of one predicate had already produced a false
# pass three times in this campaign — the TUI layer-split gate, the
# value-presentation gate, and this file's own `unreadable_specs_in` — which is
# why the rule is now written down rather than re-learned.
#
# THE PATTERN ITSELF. POSIX classes rather than `\b`, because the engine is part
# of the scanner (§4, and `git grep` does not speak GNU). The leading boundary
# is `[^[:alnum:]_]`, which ADMITS `.` — so `computation.createEffect(` matches.
# That is not incidental: the module-qualified spelling is the one
# `export … except` cannot filter and is therefore the only spelling this gate
# is the sole defence against.
identifier_pattern() {
	printf '(^|[^[:alnum:]_])%s([^[:alnum:]_]|$)' "$1"
}

# text_names TEXT NAME — true when NAME appears as a whole identifier in TEXT.
text_names() {
	grep -qE "$(identifier_pattern "$2")" <<<"$1"
}

# file_names FILE NAME — the same question asked of a file on disk.
file_names() {
	grep -qE "$(identifier_pattern "$2")" "$1"
}

# denied_names_in FILE — every denied primitive named in FILE's CODE, as
# `<line>:<primitive>`, one per line.
#
# ONE FUNCTION, CALLED BY THE RULE (check 2) AND BY ITS CONTROL (check 7), for
# the reason above. It reaches the pattern through `identifier_pattern`, and so
# do checks 8 and 10 — so a mutation of that one function reddens the rule and
# every control over it at once, which is what makes each of them evidence
# about the other.
denied_names_in() {
	local file="$1" body name hit
	body="$(code_lines "${file}" | strip_compiles)"
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			printf '%s:%s\n' "${hit%%:*}" "${name}"
		done < <(grep -nE "$(identifier_pattern "${name}")" <<<"${body}" || true)
	done < <(denied_primitives)
}

# ---------------------------------------------------------------------------
# The reachable closure — the subject checks 1 and 2 range over
# ---------------------------------------------------------------------------

# normpath PATH — collapse `.` and `..` textually. No filesystem access, so it
# works for paths that do not exist, which is what the contract suite's
# synthetic trees need.
normpath() {
	local p="$1" out=() part
	local IFS='/'
	for part in $p; do
		case "${part}" in
		"" | ".") continue ;;
		"..")
			if [ "${#out[@]}" -gt 0 ] && [ "${out[-1]}" != ".." ]; then
				unset 'out[-1]'
			else
				out+=("..")
			fi
			;;
		*) out+=("${part}") ;;
		esac
	done
	printf '%s' "${out[*]}"
}

# resolve_repo_module SPEC IMPORTER — the repo-relative path SPEC resolves to,
# or empty when it resolves to no file in this repository.
#
# DELIBERATELY REPO-ONLY. `sdk-facade-boundary.sh` resolves into sibling
# packages because its subject is what the facade's graph CONTAINS; this gate's
# subject is what a plugin author WRITES, and the two isonim modules that carry
# the raw primitives are refused by spec name at the import site (check 1)
# rather than by being read. Walking into isonim would add thousands of modules
# to bind and would not answer a question this gate asks.
resolve_repo_module() {
	local spec="$1" importer="$2" dir candidate r
	dir="$(dirname "${importer}")"
	candidate="$(normpath "${dir}/${spec}.nim")"
	if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
		printf '%s' "${candidate}"
		return 0
	fi
	# An explicitly relative spec is only ever the importer's own directory.
	case "${spec}" in
	./* | ../*) return 0 ;;
	esac
	for r in "${SEARCH_ROOTS[@]}"; do
		candidate="$(normpath "${r}/${spec}.nim")"
		if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
			printf '%s' "${candidate}"
			return 0
		fi
	done
	return 0
}

# is_stdlib_spec SPEC — true for the standard library, which is admitted at the
# unresolvable boundary because it carries no reactive primitive. `isonim` is
# not in it; nor is any nimble package.
is_stdlib_spec() {
	case "$1" in
	std/* | system) return 0 ;;
	esac
	return 1
}

# plugin_closure TERMINAL SEED... — every repository module reachable from the
# SEEDs by imports, one per line, INCLUDING the seeds and EXCLUDING TERMINAL.
#
# ONE FUNCTION, CALLED BY THE RULE (the closure checks 1 and 2 range over) AND
# BY ITS CONTROL (check 12), which is the whole reason `TERMINAL` is a parameter
# rather than a constant read from the environment: a control that walked with a
# second copy of this loop would agree with itself while the rule was broken,
# which is the defect `tui-layer-split-boundary.sh` records at its head.
#
# TERMINAL is reached and then not expanded, and is left out of the result
# because it is bound by other checks. Pass "" for no terminal.
#
# TERMINATION: `seen` is keyed on the repo-relative path, every file is enqueued
# at most once, and the set a path can resolve to is finite because
# `resolve_repo_module` only ever returns a candidate that satisfies
# `[ -f "${candidate}" ]`. A cycle costs one visit. (The bound is the ON-DISK
# set, not `git ls-files` — see the header.)
plugin_closure() {
	local terminal="$1"
	shift
	local -a queue=("$@")
	local -A seen=()
	local cur spec resolved
	for cur in "$@"; do seen["${cur}"]=1; done
	while [ "${#queue[@]}" -gt 0 ]; do
		cur="${queue[0]}"
		queue=("${queue[@]:1}")
		[ -n "${cur}" ] || continue
		printf '%s\n' "${cur}"
		while IFS= read -r spec; do
			[ -n "${spec}" ] || continue
			resolved="$(resolve_repo_module "${spec}" "${cur}")"
			[ -n "${resolved}" ] || continue
			[ "${resolved}" = "${terminal}" ] && continue
			if [ -z "${seen[${resolved}]+x}" ]; then
				seen["${resolved}"]=1
				queue+=("${resolved}")
			fi
		done < <(nim_imports "${cur}")
	done
}

# unreadable_specs_in FILE — every module spec FILE imports that this gate can
# neither resolve to a repository file nor admit as standard library, as
# `<spec>`, one per line. Specs already denied by name are left out: check 1
# reports those, with the reason, and one line is one finding.
unreadable_specs_in() {
	local file="$1" spec
	while IFS= read -r spec; do
		[ -n "${spec}" ] || continue
		is_stdlib_spec "${spec}" && continue
		[ -n "$(resolve_repo_module "${spec}" "${file}")" ] && continue
		# `denied_specs_matching` rather than a second copy of the test — see
		# its header. Check 1 reports these, with the reason and the
		# replacement; one line is one finding.
		[ -n "$(denied_specs_matching "${spec}")" ] && continue
		printf '%s\n' "${spec}"
	done < <(nim_imports "${file}")
}

# ---------------------------------------------------------------------------
# Plugin discovery
# ---------------------------------------------------------------------------

all_nim_files() {
	{
		git ls-files '*.nim' 2>/dev/null
		git ls-files --others --exclude-standard '*.nim' 2>/dev/null
	} | sort -u
}

# plugin_files — every declared plugin .nim file, repo-relative. Both marker
# spellings, exactly as `sdk-facade-boundary.sh` resolves `.sdk-consumer`.
plugin_files() {
	local list header_hits marker d f
	list="$(mktemp)"
	all_nim_files >"${list}"
	{
		if [ -s "${list}" ]; then
			header_hits="$(tr '\n' '\0' <"${list}" |
				xargs -0 grep -lE '^[[:space:]]*##[[:space:]]*CT-PLUGIN:' 2>/dev/null)"
			while IFS= read -r f; do
				[ -n "${f}" ] || continue
				if head -n "${MARKER_SCAN_LINES}" "${f}" 2>/dev/null |
					grep -qE '^[[:space:]]*##[[:space:]]*CT-PLUGIN:'; then
					printf '%s\n' "${f}"
				fi
			done <<<"${header_hits}"
		fi
		while IFS= read -r marker; do
			[ -n "${marker}" ] || continue
			d="$(dirname "${marker}")"
			if [ "${d}" = "." ]; then
				cat "${list}"
			else
				grep -E "^${d}/" "${list}" || true
			fi
		done < <(find . -name .ct-plugin -not -path './.git/*' 2>/dev/null | sed 's|^\./||')
	} | sort -u
	rm -f "${list}"
}

plugins="$(plugin_files)"
plugin_count="$(grep -c . <<<"${plugins}" || true)"

if [ "${list_plugins}" -eq 1 ]; then
	printf '%s\n' "${plugins}"
	exit 0
fi

# THE SUBJECT OF CHECKS 1, 2 AND 11: the declared plugins and everything they
# reach. One call to `plugin_closure`, over all the seeds at once, so a module
# two plugins share is bound once.
plugin_scope=""
if [ "${plugin_count}" -gt 0 ]; then
	mapfile -t plugin_seeds < <(printf '%s\n' "${plugins}")
	plugin_scope="$(plugin_closure "${SURFACE_REL}" "${plugin_seeds[@]}" | sort -u)"
fi
scope_count="$(grep -c . <<<"${plugin_scope}" || true)"
helper_count=$((scope_count - plugin_count))

if [ "${list_plugins}" -eq 2 ]; then
	printf '%s\n' "${plugin_scope}"
	exit 0
fi

echo "=== plugin-reactive-boundary: a plugin cannot reach a raw reactive primitive ==="
echo "    (Extensibility-Model.md §5.3, §5.4; PLAT-7 deliverable 6)"

# ---------------------------------------------------------------------------
# Check 0: the subject is not empty, and the denied set is not empty either
#
# Verification-Harness-Traps §4/§6a. Universal quantification over an empty set
# is a pass, and it is the cheapest false green in this file: with no declared
# plugin, or with no primitive parsed out of the table, checks 1 and 2 would
# print OK forever while asserting nothing at all.
# ---------------------------------------------------------------------------

primitives="$(denied_primitives)"
primitive_count="$(grep -c . <<<"${primitives}" || true)"

if [ "${plugin_count}" -eq 0 ]; then
	check_failed "subject-declared: no file declares itself a plugin"
	detail "This gate would pass vacuously. At least PLAT-7's own fixtures must be"
	detail "declared plugins, or every rule below is asserted about nobody."
	detail "Remedy: a '.ct-plugin' marker on the tree, or a '## CT-PLUGIN:' header."
elif [ "${scope_count}" -lt "${plugin_count}" ]; then
	# The closure contains the seeds, so it can never legitimately be smaller.
	# A walk that lost one is a walk that would silently stop binding it.
	check_failed "subject-declared: the closure holds ${scope_count} module(s) for ${plugin_count} declared plugin(s)"
	detail "plugin_closure returns the seeds themselves, so this is the walk"
	detail "dropping a file rather than a tree that has none."
else
	check_ok "subject-declared: ${plugin_count} declared plugin file(s), ${scope_count} module(s) in their closure (${helper_count} reached by import)"
fi

if [ "${primitive_count}" -eq 0 ]; then
	check_failed "denied-set-nonempty: no primitive parsed out of ${PRIMITIVES_REL}"
	detail "Expected a '${PRIMITIVES_CONST}' table of (\"primitive\", \"replacement\") pairs."
	detail "With an empty set, check 2 scans for nothing and reports OK."
else
	check_ok "denied-set-nonempty: ${primitive_count} denied primitive(s) ($(tr '\n' ' ' <<<"${primitives}"))"
fi

# ---------------------------------------------------------------------------
# Check 1: NOTHING IN A DECLARED PLUGIN'S CLOSURE imports a module carrying a
# raw primitive
#
# The subject is the closure rather than the declared file, because one
# undeclared helper module defeated the file-scoped form completely — see "THE
# RULE BINDS A PLUGIN'S REACHABLE CLOSURE" at the head of this file for the
# measurement.
# ---------------------------------------------------------------------------

import_findings=""
scanned_imports=0
while IFS= read -r f; do
	[ -n "${f}" ] || continue
	scanned_imports=$((scanned_imports + 1))
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		import_findings="${import_findings}${f}|${hit}"$'\n'
	done < <(denied_imports_in "${f}")
done <<<"${plugin_scope}"

if [ -n "${import_findings}" ]; then
	check_failed "plugin-imports-narrow: a declared plugin imports a module carrying a raw reactive primitive"
	while IFS= read -r finding; do
		[ -n "${finding}" ] || continue
		f="${finding%%|*}"
		rest="${finding#*|}"
		spec="${rest%%|*}"
		denied="${rest#*|}"
		detail "${f} imports '${spec}' -> ${denied}"
		for entry in "${DENIED_IMPORTS[@]}"; do
			if [ "${entry%%;*}" = "${denied}" ]; then
				detail "  ${entry#*;}"
			fi
		done
	done <<<"${import_findings}"
	detail "A plugin imports '${SURFACE_MODULE}'. It is '${FACADE_MODULE}' with the"
	detail "computation-creating and owner-manipulating symbols filtered out, and every"
	detail "one of them has a wrapped replacement on PluginContext."
	detail "This rule binds the plugin's whole reachable closure, so a helper module"
	detail "that imports the primitive on the plugin's behalf is the same finding."
else
	check_ok "plugin-imports-narrow: ${scanned_imports} module(s) in the plugin closure, none importing a raw primitive's module"
fi

# ---------------------------------------------------------------------------
# Check 2: a declared plugin does not NAME a raw primitive in code
#
# This is the half `export … except` cannot do. Qualification bypasses the
# filter, so `computation.createEffect(…)` compiles on the plugin surface —
# measured, and it reproduces the 160 ms line in this file's header exactly.
# ---------------------------------------------------------------------------

name_findings=""
scanned_names=0
while IFS= read -r f; do
	[ -n "${f}" ] || continue
	scanned_names=$((scanned_names + 1))
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		name_findings="${name_findings}${f}:${hit}"$'\n'
	done < <(denied_names_in "${f}")
done <<<"${plugin_scope}"

if [ -n "${name_findings}" ]; then
	check_failed "plugin-names-no-raw-primitive: a declared plugin names a raw reactive primitive in code"
	while IFS= read -r finding; do
		[ -n "${finding}" ] || continue
		detail "${finding}"
		prim="${finding##*:}"
		while IFS= read -r pair; do
			case "${pair}" in
			"${prim} "*) detail "  use ${pair#* } instead — it is owned by the activation scope and budgeted" ;;
			esac
		done < <(awk '{ if (match($0, /\("[A-Za-z_][A-Za-z0-9_]*",[[:space:]]*"[^"]*"\)/)) {
				s = substr($0, RSTART, RLENGTH); gsub(/[()"]/, "", s); n = index(s, ",")
				printf "%s %s\n", substr(s, 1, n - 1), substr(s, n + 1)
			} }' "${PRIMITIVES_REL}" 2>/dev/null | sed 's/ \+/ /')
	done <<<"${name_findings}"
	detail "Comments are stripped before this scan, so a finding is code. The"
	detail "module-qualified spelling is the one the plugin surface cannot filter,"
	detail "which is why this rule exists beside the surface rather than instead of it."
	detail "The subject is the plugin's whole reachable closure, so a finding may be"
	detail "in a helper module rather than in the declared file itself."
else
	check_ok "plugin-names-no-raw-primitive: ${scanned_names} module(s) in the plugin closure, no raw primitive named in code"
fi

# ---------------------------------------------------------------------------
# Check 3: the plugin surface exists and knows its own name
# ---------------------------------------------------------------------------

surface_ok=0
if [ ! -f "${SURFACE_REL}" ]; then
	check_failed "surface-present: ${SURFACE_REL} does not exist"
	detail "A plugin has nowhere narrower than the SDK facade to import from, so"
	detail "checks 1 and 2 are asking plugins to do something impossible."
elif ! grep -q "${SURFACE_CONST}\* = \"${SURFACE_MODULE}\"" "${SURFACE_REL}"; then
	check_failed "surface-present: ${SURFACE_REL} does not declare ${SURFACE_CONST}* = \"${SURFACE_MODULE}\""
	detail "The surface file and the name this gate enforces have drifted apart."
else
	check_ok "surface-present"
	surface_ok=1
fi

# ---------------------------------------------------------------------------
# Check 4: the surface's filtered set is EXACTLY the denied set
#
# Nim cannot splice a `const` into an `except` clause, so the ten names are
# genuinely typed out twice. A checked duplication is the honest answer to
# that; an unchecked one is how the surface stops filtering something the gate
# still believes it filters.
# ---------------------------------------------------------------------------

if [ "${surface_ok}" -eq 1 ] && [ "${primitive_count}" -gt 0 ]; then
	excepts="$(surface_except_names)"
	only_const="$(comm -23 <(printf '%s\n' "${primitives}") <(printf '%s\n' "${excepts}"))"
	only_surface="$(comm -13 <(printf '%s\n' "${primitives}") <(printf '%s\n' "${excepts}"))"
	if [ -n "${only_const}" ] || [ -n "${only_surface}" ]; then
		check_failed "denied-list-agrees: ${PRIMITIVES_REL} and ${SURFACE_REL} name different sets"
		while IFS= read -r n; do
			[ -n "${n}" ] || continue
			detail "${n}: in ${PRIMITIVES_CONST} but NOT filtered by the surface — a plugin can still call it unqualified"
		done <<<"${only_const}"
		while IFS= read -r n; do
			[ -n "${n}" ] || continue
			detail "${n}: filtered by the surface but NOT in ${PRIMITIVES_CONST} — check 2 does not scan for it"
		done <<<"${only_surface}"
	else
		check_ok "denied-list-agrees: ${primitive_count} name(s), identical in both places"
	fi
fi

# ---------------------------------------------------------------------------
# Check 5: the surface narrows the facade rather than re-exporting it whole
# ---------------------------------------------------------------------------

if [ "${surface_ok}" -eq 1 ]; then
	surface_body="$(code_lines "${SURFACE_REL}")"
	if grep -qE "^[[:space:]]*export[[:space:]]+${FACADE_MODULE}[[:space:]]*\$" <<<"${surface_body}"; then
		check_failed "surface-narrows: ${SURFACE_REL} re-exports ${FACADE_MODULE} WHOLE"
		detail "An unfiltered 'export ${FACADE_MODULE}' puts every raw primitive back in"
		detail "scope, and checks 1 and 2 would still pass — a plugin importing only the"
		detail "surface would compile a bare createEffect again."
	elif ! grep -qE "^[[:space:]]*export[[:space:]]+${FACADE_MODULE}[[:space:]]+except([[:space:]]|\$)" <<<"${surface_body}"; then
		check_failed "surface-narrows: ${SURFACE_REL} has no 'export ${FACADE_MODULE} except' clause"
		detail "The surface is supposed to be the facade minus the denied set."
	else
		check_ok "surface-narrows: ${SURFACE_REL} re-exports ${FACADE_MODULE} with an except clause"
	fi
fi

# ---------------------------------------------------------------------------
# Check 6: POSITIVE CONTROL for check 1 — the same predicate, on a file that
# does import the denied modules.
#
# `codetracer_embed.nim` imports them in the BRACKET spelling
# (`import isonim/core/[signals, computation, owner]`), which is the hardest
# form this gate's extractor has to read. If it cannot, check 1's clean result
# is not evidence.
#
# The count is asserted rather than "at least one": the facade imports TWO
# denied modules, and Verification-Harness-Traps §4b is that "at least one" is
# satisfied by one member of two.
# ---------------------------------------------------------------------------

CONTROL_IMPORT_EXPECTED=2

if [ -f "${FACADE_REL}" ]; then
	control_imports="$(denied_imports_in "${FACADE_REL}")"
	control_import_n="$(grep -c . <<<"${control_imports}" || true)"
	if [ "${control_import_n}" -eq "${CONTROL_IMPORT_EXPECTED}" ]; then
		check_ok "import-scan-reads-code: the same predicate reports ${control_import_n} denied import(s) in ${FACADE_REL} ($(tr '\n' ' ' <<<"${control_imports}"))"
	else
		check_failed "import-scan-reads-code: the predicate reports ${control_import_n} denied import(s) in ${FACADE_REL}, expected ${CONTROL_IMPORT_EXPECTED}"
		detail "That file is written 'import isonim/core/[signals, computation, owner]'."
		detail "A predicate that cannot see both of them there cannot see one in a plugin."
		detail "Check 1's clean result is not evidence while this is red."
	fi
else
	check_failed "import-scan-reads-code: ${FACADE_REL} is missing, so check 1 has no control"
fi

# ---------------------------------------------------------------------------
# Check 7: POSITIVE CONTROL for check 2 — the same predicate, on a file that
# names every denied primitive in code.
#
# `plugin_api.nim` wraps six of them by calling them and names all ten in the
# `PluginDeniedPrimitives` table, which is code and not a comment. The
# assertion is on the DISTINCT count, so a scanner that found one primitive and
# missed nine cannot pass — §4b again, and R6 in §4a: what gets emptied is the
# variety, not the total.
# ---------------------------------------------------------------------------

if [ -f "${PRIMITIVES_REL}" ] && [ "${primitive_count}" -gt 0 ]; then
	control_names="$(denied_names_in "${PRIMITIVES_REL}" | cut -d: -f2 | sort -u)"
	control_name_n="$(grep -c . <<<"${control_names}" || true)"
	if [ "${control_name_n}" -eq "${primitive_count}" ]; then
		check_ok "name-scan-reads-code: the same predicate finds all ${control_name_n} denied primitive(s) in ${PRIMITIVES_REL}'s code"
	else
		check_failed "name-scan-reads-code: the predicate found ${control_name_n} of ${primitive_count} denied primitive(s) in ${PRIMITIVES_REL}"
		detail "missing: $(comm -23 <(printf '%s\n' "${primitives}") <(printf '%s\n' "${control_names}") | tr '\n' ' ')"
		detail "Every one of them is named in that file's ${PRIMITIVES_CONST} table, which is"
		detail "code. Check 2's clean result is not evidence while this is red."
	fi
fi

# ---------------------------------------------------------------------------
# Check 8: the comment stripper discriminates, in BOTH directions
#
# Check 2 scans code, not prose, and every plugin's header explains the rule by
# naming the primitive it does not call. If `code_lines` stopped stripping,
# check 2 would be red on documentation; if it stripped too much, check 2 would
# be blind. Neither failure is visible from check 2's own output.
# ---------------------------------------------------------------------------

if [ -f "${PROSE_PROBE_REL}" ] && [ "${primitive_count}" -gt 0 ]; then
	prose_raw_missing=""
	prose_still_present=""
	prose_stripped="$(code_lines "${PROSE_PROBE_REL}")"
	prose_seen=0
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		if file_names "${PROSE_PROBE_REL}" "${name}"; then
			prose_seen=$((prose_seen + 1))
			if text_names "${prose_stripped}" "${name}"; then
				prose_still_present="${prose_still_present}${name} "
			fi
		else
			prose_raw_missing="${prose_raw_missing}${name} "
		fi
	done <<<"${primitives}"
	if [ "${prose_seen}" -eq 0 ]; then
		check_failed "prose-is-not-code: ${PROSE_PROBE_REL} names no denied primitive at all"
		detail "This control needs a file whose DOC COMMENT names one and whose code"
		detail "does not. With none, it asserts nothing in either direction."
	elif [ -n "${prose_still_present}" ]; then
		check_failed "prose-is-not-code: ${prose_still_present}survived comment stripping in ${PROSE_PROBE_REL}"
		detail "Either the stripper is broken, or that plugin genuinely calls it — and"
		detail "check 2 should have said so. Both are findings."
	else
		check_ok "prose-is-not-code: ${prose_seen} denied primitive(s) named in ${PROSE_PROBE_REL}'s prose, 0 surviving the stripper"
	fi
fi

# ---------------------------------------------------------------------------
# Check 10: POSITIVE CONTROL for the `compiles` exemption, in BOTH directions
#
# `strip_compiles` is the one place this gate deliberately declines to report a
# denied name, so it is the one place a plugin could be smuggled through. The
# subject is the fixture that exists to name all ten and call none: every one of
# them must be visible in its code BEFORE the strip and none after it.
#
# A stripper that had stopped stripping would redden check 2 on that fixture; a
# stripper that stripped everything would make check 2 blind, and neither is
# visible from check 2's own output. `ci/test/plugin-reactive-boundary-test.sh`
# carries the third direction — a real call sharing a line with a `compiles`,
# which must still be reported.
# ---------------------------------------------------------------------------

COMPILES_PROBE_REL="src/frontend/viewmodel/tests/unit/plugin_fixtures/surface_probe_plugin.nim"

if [ -f "${COMPILES_PROBE_REL}" ] && [ "${primitive_count}" -gt 0 ]; then
	before_strip=0
	after_strip=0
	probe_code="$(code_lines "${COMPILES_PROBE_REL}")"
	probe_stripped="$(strip_compiles <<<"${probe_code}")"
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		if text_names "${probe_code}" "${name}"; then
			before_strip=$((before_strip + 1))
		fi
		if text_names "${probe_stripped}" "${name}"; then
			after_strip=$((after_strip + 1))
		fi
	done <<<"${primitives}"
	if [ "${before_strip}" -ne "${primitive_count}" ]; then
		check_failed "compiles-is-not-a-call: ${COMPILES_PROBE_REL} names ${before_strip} of ${primitive_count} denied primitive(s) in code"
		detail "That fixture exists to ask the compiler about every one of them."
		detail "With fewer, the exemption below is being asserted over a smaller set"
		detail "than the rule it exempts from — and check 2 would look clean for it."
	elif [ "${after_strip}" -ne 0 ]; then
		check_failed "compiles-is-not-a-call: ${after_strip} denied primitive(s) survived strip_compiles in ${COMPILES_PROBE_REL}"
		detail "Either the stripper is broken, or that fixture genuinely calls one"
		detail "outside a compiles(). Both are findings."
	else
		check_ok "compiles-is-not-a-call: all ${before_strip} denied primitive(s) named in ${COMPILES_PROBE_REL}'s code, 0 surviving the compiles() strip"
	fi
fi

# ---------------------------------------------------------------------------
# Check 11: nothing in the closure imports a module this gate cannot read
#
# THE BOUNDARY OF THE CLOSURE, STATED AS A RULE RATHER THAN AS A CAVEAT. The
# walk binds what it can resolve; a spec that resolves to no repository file is
# a module whose source this gate never saw, and such a module could re-export
# `createEffect` exactly as the helper-module exploit did. "I could not read it"
# and "it is clean" are different facts, so the unreadable case is a finding.
#
# `std/…` and `system` are admitted by name: the standard library carries no
# reactive primitive, and `isonim` is not in it. A bare `import strutils` is
# NOT admitted, because this gate cannot tell that spelling from a nimble
# package of the same name — the remedy is the `std/` prefix, which is one
# character of honesty and is how every file in this closure already spells it.
#
# THE SECOND HALF OF THE SAME RULE, and it arrived with the shared extractor:
# `nim_imports` REFUSES to analyse three shapes rather than guessing at them (a
# backslash inside a quoted spec, an import running into an unterminated block
# comment, and a line carrying a one-line conditional in any of its `;`-pieces
# that visibly opens more imports than the scan read out of it). "I could not
# read the SPEC" is the same fact as "I could not read the MODULE" one step
# earlier, and it belongs in the same check under the same name — a refusal
# reported nowhere is the silent miss twice over.
# ---------------------------------------------------------------------------

if [ "${plugin_count}" -gt 0 ]; then
	unreadable_findings=""
	scanned_unreadable=0
	while IFS= read -r f; do
		[ -n "${f}" ] || continue
		scanned_unreadable=$((scanned_unreadable + 1))
		while IFS= read -r spec; do
			[ -n "${spec}" ] || continue
			unreadable_findings="${unreadable_findings}${f}|${spec}"$'\n'
		done < <(unreadable_specs_in "${f}")
	done <<<"${plugin_scope}"
	# The refusals `nim_imports` logged WHILE THE CLOSURE WAS BEING WALKED, kept
	# to the files the closure holds: the log is process-wide, so an entry for a
	# file no plugin reaches is not this gate's finding.
	refusal_findings=""
	if [ -s "${IMPORT_UNANALYSABLE_LOG}" ]; then
		while IFS=$'\t' read -r rf rline; do
			[ -n "${rf}" ] || continue
			grep -qxF "${rf}" <<<"${plugin_scope}" || continue
			refusal_findings="${refusal_findings}${rf}|${rline}"$'\n'
		done < <(sort -u "${IMPORT_UNANALYSABLE_LOG}")
	fi
	if [ -n "${unreadable_findings}" ] || [ -n "${refusal_findings}" ]; then
		check_failed "closure-is-readable: a module in the plugin closure imports something this gate cannot resolve"
		while IFS= read -r finding; do
			[ -n "${finding}" ] || continue
			detail "${finding%%|*} imports '${finding#*|}', which resolves to no file in this repository"
		done <<<"${unreadable_findings}"
		while IFS= read -r finding; do
			[ -n "${finding}" ] || continue
			detail "${finding%%|*} has a line the import extractor REFUSED to analyse: ${finding#*|}"
		done <<<"${refusal_findings}"
		detail "Checks 1 and 2 bind what they can read. A module outside this repository"
		detail "is one they cannot bind, and it could re-export a raw primitive exactly"
		detail "as an in-repo helper would."
		detail "Remedy: spell a stdlib import 'std/<name>', or bring the module into"
		detail "this repository so the closure can hold it; and write an import the"
		detail "extractor can read — ci/lib/nim-imports.sh names the three refused shapes."
	else
		check_ok "closure-is-readable: ${scanned_unreadable} module(s) in the plugin closure, every import resolved in-repo or admitted as std/"
	fi
fi

# ---------------------------------------------------------------------------
# Check 12: POSITIVE CONTROL for the closure walk — ONE HOP PAST THE SEED,
# through `plugin_closure` itself and through `denied_imports_in` itself.
#
# The rule calls `plugin_closure "${SURFACE_REL}" <plugins>`; this calls the
# SAME function with the FACADE as the terminal instead, so the walk must step
# through the surface it normally stops at. The result is exactly two modules —
# the plugin and the surface — and feeding them to check 1's own predicate must
# yield exactly ONE finding: the surface's `import codetracer_embed`.
#
# That finding is one the rule itself can never produce, which is the point: it
# is produced by the walk having gone somewhere. A walk that returned only its
# seeds drops this to 1 module and 0 findings and reddens here while check 1
# goes on printing OK — Verification-Harness-Traps §4a, the positive twin on the
# same code path.
#
# The counts are exact rather than "at least one" (§4b).
# ---------------------------------------------------------------------------

CLOSURE_CONTROL_MODULES=2
CLOSURE_CONTROL_FINDINGS=1

if [ -f "${PROSE_PROBE_REL}" ] && [ -f "${SURFACE_REL}" ] && [ -f "${FACADE_REL}" ]; then
	control_closure="$(plugin_closure "${FACADE_REL}" "${PROSE_PROBE_REL}" | sort -u)"
	control_closure_n="$(grep -c . <<<"${control_closure}" || true)"
	control_closure_findings=""
	while IFS= read -r f; do
		[ -n "${f}" ] || continue
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			control_closure_findings="${control_closure_findings}${f}|${hit}"$'\n'
		done < <(denied_imports_in "${f}")
	done <<<"${control_closure}"
	control_closure_findings_n="$(grep -c . <<<"${control_closure_findings}" || true)"
	if [ "${control_closure_n}" -eq "${CLOSURE_CONTROL_MODULES}" ] &&
		[ "${control_closure_findings_n}" -eq "${CLOSURE_CONTROL_FINDINGS}" ]; then
		check_ok "closure-walks-past-its-seed: the same walk returns ${control_closure_n} module(s) from ${PROSE_PROBE_REL} and the same predicate reports ${control_closure_findings_n} denied import in them"
	else
		check_failed "closure-walks-past-its-seed: ${control_closure_n} module(s) (expected ${CLOSURE_CONTROL_MODULES}) and ${control_closure_findings_n} denied import(s) (expected ${CLOSURE_CONTROL_FINDINGS})"
		detail "walked: $(tr '\n' ' ' <<<"${control_closure}")"
		detail "found:  $(tr '\n' ' ' <<<"${control_closure_findings}")"
		detail "That plugin imports '${SURFACE_MODULE}' and nothing else in this repo,"
		detail "and the surface imports '${FACADE_MODULE}'. A walk that cannot see one"
		detail "step past its seed cannot see a helper module either, and checks 1 and 2"
		detail "would then be exactly the file-scoped rules the helper exploit defeated."
	fi
else
	check_failed "closure-walks-past-its-seed: a subject file is missing, so the closure walk has no control"
fi

# ---------------------------------------------------------------------------
# Check 13: POSITIVE CONTROL for the closure walk — TRANSITIVELY, past two hops
#
# Check 12 proves one hop. One hop is not the rule: the exploit's helper could
# itself have been reached through another helper. With NO terminal at all, the
# same walk from the same declared plugin must reach `${FACADE_REL}`, which is
# TWO hops away (plugin -> surface -> facade) and is not imported by the plugin
# at all. Membership by name, so a walk that returned a large wrong set cannot
# satisfy it by size.
# ---------------------------------------------------------------------------

if [ -f "${PROSE_PROBE_REL}" ] && [ -f "${FACADE_REL}" ]; then
	deep_closure="$(plugin_closure "" "${PROSE_PROBE_REL}")"
	if grep -qxF "${FACADE_REL}" <<<"${deep_closure}"; then
		check_ok "closure-walks-transitively: the same walk reaches ${FACADE_REL}, two hops from ${PROSE_PROBE_REL}"
	else
		check_failed "closure-walks-transitively: the walk did not reach ${FACADE_REL} from ${PROSE_PROBE_REL}"
		detail "The path is ${PROSE_PROBE_REL} -> ${SURFACE_REL} -> ${FACADE_REL}."
		detail "A walk that stops after one hop binds a plugin's helper but not the"
		detail "helper's helper, and says nothing about the difference."
	fi
fi

# ---------------------------------------------------------------------------
# Check 9: every declared plugin actually goes through the surface
#
# The complement of check 1, and not implied by it: a plugin that imported
# NOTHING would satisfy every "must not import" rule above. This is the
# positive twin Verification-Harness-Traps §4a asks for, on the same specs.
# ---------------------------------------------------------------------------

through_surface=0
not_through=""
while IFS= read -r f; do
	[ -n "${f}" ] || continue
	if nim_imports "${f}" | sed 's|.*/||' | grep -qxF "${SURFACE_MODULE}"; then
		through_surface=$((through_surface + 1))
	else
		not_through="${not_through}${f} "
	fi
done <<<"${plugins}"

if [ "${plugin_count}" -gt 0 ] && [ "${through_surface}" -eq "${plugin_count}" ]; then
	check_ok "plugin-uses-the-surface: all ${plugin_count} declared plugin(s) import '${SURFACE_MODULE}'"
elif [ "${plugin_count}" -gt 0 ]; then
	check_failed "plugin-uses-the-surface: ${not_through}do not import '${SURFACE_MODULE}'"
	detail "A plugin that imports nothing satisfies every rule above vacuously."
	detail "The surface is where PluginContext, pluginEffect and pluginMemo come from."
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

if [ "${failures}" -eq 0 ]; then
	echo "plugin-reactive-boundary: ${checks_run} check(s), 0 failing"
	exit 0
fi
echo "plugin-reactive-boundary: ${checks_run} check(s), ${failures} failing"
exit 1
