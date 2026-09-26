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
#     which carries no reactive primitive and is admitted BY SPELLING here (see
#     `is_stdlib_spec`, and note that admitting the spelling is a statement
#     about check 11 only — check 19's ALLOW-LIST is what decides whether a
#     given `std/` module may be imported at all, and it refuses `std/posix`
#     while check 11 goes on being satisfied that it knew what it was); ANY OTHER
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
#   `stdlib_admitted`        whether a std module is admitted (the allow-list
#                            rule, check 19, and both halves of control 20)
#   `unadmitted_stdlib_in`   the allow-list rule   (check 19 + control 20)
#
# WHAT AN ALLOW-LIST IS DOING IN A FILE OF DENYLISTS
# -------------------------------------------------
# Checks 1, 2 and 15 are three denylists — two over module specs, one over
# identifiers — and each answers "did the plugin name one of the things we
# thought of". Check 19 answers the complement. It is here because the denied
# lists were measured losing, on 2026-09-09, over a plugin that simply declined
# to use the SDK: `## CT-PLUGIN:` plus `import codetracer_plugin` plus
# `import std/posix` read `/etc/hostname` with no `fs:read` grant and
# fork+exec'd `/bin/sh` with no `process` grant, while this script printed
# `19 check(s), 0 failing`. Seven more names on `PluginDeniedSyncIo` would not
# have reached it: `read` and `write` are the SDK's own spellings, so denying
# them denies the sanctioned path.
#
# The membership rule, the reason each refused module is refused, and the one
# thing the allow-list cannot reach (`system`, which is auto-imported and so has
# no import to refuse) are in `src/common/plugin_model/source_admission.nim`.
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
# shellcheck source=ci/lib/nim-closure.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/nim-closure.sh"

# The DERIVED half of PLAT-8's second denied set. `system` is auto-imported
# into every nim module and ends with `export syncio`, so its surface is in
# every plugin's scope with no import to refuse and no scope to filter — and it
# is therefore the one surface this file cannot decide by reading the
# repository. `system_surface_names` reads the PINNED COMPILER instead. Check
# 23 below requires every name it derives to be accounted for.
#
# Sourced by `BASH_SOURCE` and not by `${root}`, deliberately: with `--root` on
# a synthetic tree the library must still be the REAL one, or the contract
# suite would grade a copy.
# Same `source=` / SC1091 pair as the `nim-imports.sh` line above, and for
# the same reason: the pre-commit hook runs shellcheck without -x and cannot
# follow a sourced file at all.
# shellcheck source=ci/lib/system-io-surface.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/system-io-surface.sh"

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

# Where PLAT-8's SECOND denied set is defined: the synchronous I/O primitives.
# Read from the table the same way `PluginDeniedPrimitives` is, by the same
# function, so this gate has one parser rather than two.
SYNC_IO_REL="src/frontend/viewmodel/plugin_host/plugin_io.nim"
SYNC_IO_CONST="PluginDeniedSyncIo"

# The companion table in the same file: the names `system` puts in every
# plugin's scope that are deliberately NOT denied, each with the reason.
#
# IT IS A TABLE RATHER THAN AN ABSENCE, and that is the whole repair. Before
# 2026-09-09 an exemption WAS an absence from `PluginDeniedSyncIo`, which is
# indistinguishable from an oversight — and that is exactly what `open`,
# `readBuffer` and `writeBuffer` were, while the residual paragraph claimed
# nine of ten names covered. Check 23 makes the two tables partition the
# derived surface, so an oversight is now a red check instead of a hole.
SYSTEM_EXEMPT_CONST="PluginSystemSurfaceExempt"

# Where PLAT-8's THIRD list is defined, and it is the only one of the three
# that is an ALLOW-list. Read by the same `table_names` parser, for the same
# reason: one parser over three tables.
#
# WHY AN ALLOW-LIST AND NOT A FOURTH DENIED SET. Measured 2026-09-09, with a
# DECLARED plugin, against this gate: a module carrying `## CT-PLUGIN:` and
# importing `codetracer_plugin` and `std/posix` read `/etc/hostname` with no
# `fs:read` grant and fork+exec'd `/bin/sh` with no `process` grant, while this
# script printed `19 check(s), 0 failing` — including `plugin-names-no-sync-io:
# 6 module(s) in the plugin closure, no synchronous I/O primitive named in
# code`. `PluginDeniedSyncIo` is a list of NAMES and `std/posix` spells the
# same operations `open`, `read`, `write`, `socket`, `connect`, `fork` and
# `execv` — and `read` and `write` are the SDK's own spellings, so they cannot
# be denied by name without denying the sanctioned path.
#
# The membership rule, the refusals and the `system` residual are all written
# up in ALLOWLIST_REL's own header. This file is the enforcement.
ALLOWLIST_REL="src/common/plugin_model/source_admission.nim"
ALLOWLIST_CONST="PluginAllowedStdlibModules"

# PLAT-8's FOURTH list, in the same file, and it closes the route the ALLOW-list
# does not reach: an FFI pragma needs no import, so refusing every module in the
# world would leave it open. Measured on 2026-09-09 by attacking the allow-list
# on the day it was written — a module whose entire content is
# `import codetracer_plugin` plus one `{.importc: "system", header:
# "<stdlib.h>".}` declaration ran a shell and created its sentinel.
FFI_CONST="PluginDeniedFfiPragmas"

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
# table_names FILE CONST [ONLY-HOST-ONLY] — the primitive names in a
# `("name", "replacement"[, hostOnly])` table declared as CONST in FILE.
#
# ONE PARSER FOR BOTH DENIED SETS. PLAT-7 has `PluginDeniedPrimitives` and
# PLAT-8 has `PluginDeniedSyncIo`; a second copy of this awk would be a second
# place for the "the table moved and the gate did not notice" defect, and the
# whole reason the tables exist in the code rather than here is that there is
# one source of truth.
#
# With a third argument of `host-only`, only the entries whose third tuple
# field is `true` are printed — the entries the HOST is allowed to call on a
# plugin's behalf. See `PluginDeniedSyncIo`'s own comment for why that flag is
# in the data.
table_names() {
	local file="$1" const_name="$2" mode="${3:-all}"
	[ -f "${file}" ] || return 0
	awk -v const_name="${const_name}" -v mode="${mode}" '
	$0 ~ ("^[[:space:]]*" const_name "\\*?[[:space:]]*[:*]") { inside = 1; next }
	inside && /^[[:space:]]*\]/ { inside = 0 }
	inside {
		# The `/` IS IN THE CHARACTER CLASS FOR THE THIRD TABLE, whose left
		# column is a module spec (`std/strutils`) rather than an identifier.
		# It is meaning-preserving for the two identifier tables — no nim
		# identifier carries a `/` — so widening it moved no count in either of
		# their controls, which is the reason it was widened rather than
		# copied.
		#
		# The `&` and `=` ARE IN IT FOR THE FIFTH TABLE, on the same argument
		# and measured the same way. `PluginSystemSurfaceExempt` has to name
		# `&=`, because that is a name `system` exports and check 23 requires
		# every derived name to be on one of the two tables; an operator that
		# the parser could not read would have had to become a hardcoded
		# exemption in this file, which is the drift the tables exist to
		# prevent. No nim identifier carries `&` or `=` either, so the four
		# older tables keep their counts — asserted by check 24.
		#
		# NO APOSTROPHE ANYWHERE IN THIS awk PROGRAM. The whole thing is one
		# single-quoted shell word, so an apostrophe in a COMMENT ends it and
		# bash parses the rest of the awk source as shell. The error it then
		# prints names a token forty lines away that nobody wrote, which is why
		# this is worth a comment rather than a second lesson.
		if (match($0, /\("[A-Za-z_&][A-Za-z0-9_\/&=]*"/)) {
			s = substr($0, RSTART + 2, RLENGTH - 3)
			if (mode == "host-only") {
				if ($0 ~ /,[[:space:]]*true\)[[:space:]]*,?[[:space:]]*$/) print s
			} else {
				print s
			}
		}
	}
	' "${file}" | sort -u
}

# table_declared_len FILE CONST — the `N` in `CONST*: array[N, …]`.
#
# THE SECOND READER OF THE SAME DECLARATION, and it exists so check 24 can ask
# a question that is true in ANY tree: does the parser return every row the
# table SAYS it has? Pinning the real repository's 10/21/13 there instead was
# tried and was wrong — the contract suite's synthetic trees carry three-entry
# tables on purpose, so twenty-two cases failed on a check that had nothing to
# do with them. `parsed == declared` is the property that actually characterises
# a working parser, and it holds for a three-row fixture and a forty-one-row
# table alike.
table_declared_len() {
	local file="$1" const_name="$2"
	[ -f "${file}" ] || return 0
	awk -v const_name="${const_name}" '
	$0 ~ ("^[[:space:]]*" const_name "\\*?[[:space:]]*[:*]") {
		if (match($0, /array\[[0-9]+,/)) {
			print substr($0, RSTART + 6, RLENGTH - 7)
			exit
		}
	}
	' "${file}"
}

denied_primitives() {
	table_names "${PRIMITIVES_REL}" "${PRIMITIVES_CONST}"
}

# denied_sync_io — PLAT-8's set: the routines that block the calling thread.
denied_sync_io() {
	table_names "${SYNC_IO_REL}" "${SYNC_IO_CONST}"
}

# sync_io_host_only — the subset the SDK itself may call.
sync_io_host_only() {
	table_names "${SYNC_IO_REL}" "${SYNC_IO_CONST}" host-only
}

# allowed_stdlib_modules — PLAT-8's THIRD list, and the only allow-list of the
# three: the `std/` module specs a plugin's closure may import.
allowed_stdlib_modules() {
	table_names "${ALLOWLIST_REL}" "${ALLOWLIST_CONST}"
}

# denied_ffi_pragmas — PLAT-8's FOURTH list: the pragmas by which a plugin would
# bind a foreign function without importing anything.
denied_ffi_pragmas() {
	table_names "${ALLOWLIST_REL}" "${FFI_CONST}"
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
# blank_strings — replace the CONTENTS of every double-quoted literal with
# nothing, leaving the quotes.
#
# WITHOUT THIS, THE DENIED TABLES REPORT THEMSELVES. `PluginDeniedSyncIo` names
# `waitFor` and `execProcess` in string literals on CODE lines, so a scan of
# `plugin_io.nim` for those names would find them and the `sdk-does-not-block`
# check below could never pass. The general form of the same problem is a
# plugin with a diagnostic message quoting the name of the thing it must not
# call — refusing that would be Verification-Harness-Traps §4d's "reword the
# prose until the regex is happy".
#
# It is not a hole in check 2. A nim string literal cannot call anything; the
# only way a name inside quotes runs is through a macro that evaluates it, and
# there is none in a plugin's closure. Check 17 asserts the blanking
# discriminates, in both directions, on a real file.
blank_strings() {
	sed -e 's/"[^"]*"/""/g'
}

# strip_export_except — blank the identifier list of an `export … except …`
# clause.
#
# THE SAME SHAPE AS `strip_compiles`, AND FOR THE SAME REASON. `export X except
# waitFor` names a routine in order to REMOVE it from the scope every importer
# gets; it is the opposite of calling it, and a scanner that read it as a call
# would report the narrowing mechanism as a violation of the rule the narrowing
# enforces. Check 17 asserts this discriminates on a real file: the names it
# blanks here are present in the raw bytes.
#
# The continuation form is handled because nim permits it: a clause whose line
# ends in a comma continues onto the next line.
strip_export_except() {
	awk '
	{
		line = $0
		if (continuing) {
			had_comma = (line ~ /,[[:space:]]*$/)
			sub(/[^[:space:]].*$/, "", line)
			continuing = had_comma
			print line
			next
		}
		if (line ~ /^[[:space:]]*export[[:space:]].*[[:space:]]except([[:space:]]|$)/) {
			had_comma = (line ~ /,[[:space:]]*$/) || (line ~ /except[[:space:]]*$/)
			sub(/[[:space:]]except([[:space:]].*)?$/, " except", line)
			continuing = had_comma
			print line
			next
		}
		print line
	}
	'
}

# names_in FILE NAMES — every NAME (one per line) that appears as a whole
# identifier in FILE's CODE, as `<line>:<name>`.
#
# ONE FUNCTION FOR BOTH DENIED SETS AND FOR EVERY CONTROL OVER THEM. PLAT-7's
# check 2 and check 7 already shared one scanner for exactly this reason; PLAT-8
# adds a second SET rather than a second scanner, so a mutation of this function
# reddens four checks at once.
names_in() {
	local file="$1" names="$2" mode="${3:-code-only}" body name hit
	body="$(code_lines "${file}" | strip_compiles)"
	# PLAT-8's set is scanned with two further filters, and PLAT-7's is not.
	# That is a difference in the SUBJECT rather than in the predicate: PLAT-8's
	# denied names are DECLARED, as string literals, in the very file check 16
	# scans, and they are NARROWED, in an `export … except` clause, in the very
	# module that provides the async vocabulary. Scanning either as a call would
	# report the mechanism as the violation.
	if [ "${mode}" = "declaration-aware" ]; then
		body="$(blank_strings <<<"${body}" | strip_export_except)"
	fi
	# PLAT-8's FOURTH set is scanned inside PRAGMA SPANS ONLY, and that
	# narrowing is the check rather than an optimisation. `header`, `link`,
	# `compile` and `emit` are ordinary English words and perfectly ordinary nim
	# identifiers; a scan for them as bare names would refuse a plugin with a
	# variable called `header`, which is the "reword the code until the regex is
	# happy" smell Verification-Harness-Traps §4d names, pointed at code instead
	# of at prose. Bounding the scan to `{. … .}` makes the finding a PRAGMA
	# rather than a word, and check 22 asserts the bound in both directions.
	if [ "${mode}" = "pragma-only" ]; then
		body="$(blank_strings <<<"${body}" | pragma_spans)"
	fi
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			printf '%s:%s\n' "${hit%%:*}" "${name}"
		done < <(grep -nE "$(identifier_pattern "${name}")" <<<"${body}" || true)
	done <<<"${names}"
}

denied_names_in() {
	names_in "$1" "$(denied_primitives)"
}

# sync_io_names_in FILE — PLAT-8's set, through the same scanner.
sync_io_names_in() {
	names_in "$1" "$(denied_sync_io)" declaration-aware
}

# pragma_spans — stdin is nim source with comments removed and string contents
# blanked; stdout is one `{. … .}` pragma span per line, brace markers removed.
#
# WHY THE SPAN AND NOT THE LINE. A pragma may span lines
# (`{.importc: "x",`↵`  header: "<y.h>".}`), a line may carry a pragma and
# ordinary code, and `{.push dynlib: "libc.so".}` is a pragma with no routine
# on it at all. Accumulating from `{.` to `.}` across lines reads all three; a
# per-line regex reads the first and loses the other two, and losing them is
# SILENT — the exact failure mode this gate's own extractor was repaired for
# seven times.
#
# The input is already string-blanked, so a `.}` inside a literal cannot close a
# span and a `{.` inside one cannot open one.
pragma_spans() {
	awk '
	{
		line = $0
		while (length(line) > 0) {
			if (inside == 0) {
				p = index(line, "{.")
				if (p == 0) break
				line = substr(line, p + 2)
				inside = 1
				span = ""
			}
			q = index(line, ".}")
			if (q == 0) {
				span = span " " line
				line = ""
				break
			}
			span = span " " substr(line, 1, q - 1)
			print span
			inside = 0
			span = ""
			line = substr(line, q + 2)
		}
	}
	END { if (inside == 1 && span != "") print span }
	'
}

# ffi_names_in FILE — every denied FFI pragma named inside a pragma span in the
# file's code, through the SAME scanner as the other two sets.
#
# ONE FUNCTION, CALLED BY THE RULE (check 21) AND BY BOTH HALVES OF ITS CONTROL
# (check 22). Third set, still one scanner: a mutation of `names_in` or of
# `identifier_pattern` now reddens six checks at once.
ffi_names_in() {
	names_in "$1" "$(denied_ffi_pragmas)" pragma-only
}

# ---------------------------------------------------------------------------
# The reachable closure — the subject checks 1 and 2 range over
# ---------------------------------------------------------------------------

# normpath — SHARED, from `ci/lib/nim-closure.sh` (sourced beside
# `nim-imports.sh` above). This gate carried its own copy until 2026-09-23,
# and the copies had DRIFTED: `plugin-reactive-boundary.sh`'s returned a
# RELATIVE path for an absolute input. One predicate, one function
# (Verification-Harness-Traps §30).

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

# stdlib_admitted SPEC — true when SPEC is a standard-library spec a PLUGIN's
# closure may import.
#
# THIS IS A DIFFERENT QUESTION FROM `is_stdlib_spec` AND THE TWO ARE KEPT
# APART DELIBERATELY. `is_stdlib_spec` is a SPELLING test: "is this the
# standard library, so that failing to resolve it to a repository file is not a
# finding". It answers for check 11, whose remedy line is *spell it `std/`* —
# which is the wrong remedy for `std/posix`, a spec the gate resolves and
# understands perfectly and refuses on purpose. Folding the two would print
# that remedy under check 11 and lose the reason.
#
# `system` is admitted here and cannot be anything else: it is auto-imported
# into every nim module, so there is no import statement to refuse and no scope
# to filter it out of. What still stands in front of it is check 15's
# NAME-based scan over `PluginDeniedSyncIo`'s nine `system` entries — a
# denylist, which is the mechanism this allow-list exists because it lost, and
# the only one `system` leaves available. It is a residual, not a closed hole,
# and ALLOWLIST_REL's header says so in those words.
stdlib_admitted() {
	case "$1" in
	system) return 0 ;;
	std/*) ;;
	*) return 1 ;;
	esac
	local allowed
	while IFS= read -r allowed; do
		[ "${allowed}" = "$1" ] && return 0
	done < <(allowed_stdlib_modules)
	return 1
}

# unadmitted_stdlib_in FILE — every standard-library spec FILE imports that is
# NOT on the allow-list, one per line.
#
# ONE FUNCTION, CALLED BY THE RULE (check 18) AND BY ITS CONTROL (check 19) —
# Verification-Harness-Traps §14. Written as two copies, breaking the rule's
# copy would leave the control's copy intact and agreeing with itself, which is
# the defect this file's header records three times over.
unadmitted_stdlib_in() {
	local file="$1" spec
	while IFS= read -r spec; do
		[ -n "${spec}" ] || continue
		is_stdlib_spec "${spec}" || continue
		stdlib_admitted "${spec}" && continue
		printf '%s\n' "${spec}"
	done < <(nim_imports "${file}")
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
	# TERMINALS is a space-separated LIST, and it became one under PLAT-8 rather
	# than staying a single path. The plugin surface now re-exports two things —
	# `codetracer_embed` and `plugin_host/plugin_io` — so a control that stopped
	# the walk at the facade alone would follow the second edge and range over
	# the whole plugin model, and its exact counts (§4b) would have become large
	# numbers nobody could justify. Stopping at both is the same claim about the
	# same one hop.
	local terminals="$1"
	shift
	local -a queue=("$@")
	local -A seen=()
	local -A stop=()
	local cur spec resolved t
	for t in ${terminals}; do
		[ -n "${t}" ] && stop["${t}"]=1
	done
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
			[ -n "${stop[${resolved}]+x}" ] && continue
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
# SAME function with the surface's own two re-exports as the terminals instead,
# so the walk must step through the surface it normally stops at. The result is
# exactly two modules — the plugin and the surface — and feeding them to
# check 1's own predicate must yield exactly ONE finding: the surface's
# `import codetracer_embed`.
#
# The second terminal is PLAT-8's: `codetracer_plugin.nim` re-exports
# `plugin_host/plugin_io` beside the facade, and a control that stopped only at
# the facade would follow that edge into the whole plugin model and turn its
# two exact counts into thirteen and three. Same one hop, same claim, both
# doors closed.
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
	control_closure="$(plugin_closure "${FACADE_REL} ${SYNC_IO_REL}" "${PROSE_PROBE_REL}" | sort -u)"
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
	# HERE-STRING, NOT A PIPE — see the note on check 20's control. This site is
	# one of the four `ci/test/grep-q-pipefail-gate.sh` was written for and was
	# still outstanding; it is in this file, so it is repaired here. Under
	# `pipefail` a producer still writing when `grep -q` exits makes a SUCCESSFUL
	# MATCH read as a failure, so this check could report "does not import
	# codetracer_plugin" about a plugin that does.
	if grep -qxF "${SURFACE_MODULE}" <<<"$(nim_imports "${f}" | sed 's|.*/||')"; then
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
# Check 14: PLAT-8's second denied set is not empty
#
# Verification-Harness-Traps §4/§6a again, and for the same reason check 0
# exists: with nothing parsed out of `PluginDeniedSyncIo`, checks 15 and 16
# scan for nothing and print OK forever.
# ---------------------------------------------------------------------------

sync_io="$(denied_sync_io)"
sync_io_count="$(grep -c . <<<"${sync_io}" || true)"
sync_host_only="$(sync_io_host_only)"

if [ ! -f "${SYNC_IO_REL}" ]; then
	check_failed "sync-io-set-nonempty: ${SYNC_IO_REL} does not exist"
	detail "PLAT-8's I/O primitives are what make §8.1.3's 'no synchronous form'"
	detail "enforceable. Without the module there is no denied set to enforce."
elif [ "${sync_io_count}" -eq 0 ]; then
	check_failed "sync-io-set-nonempty: no primitive parsed out of ${SYNC_IO_REL}"
	detail "Expected a '${SYNC_IO_CONST}' table of (\"primitive\", \"replacement\", hostOnly) entries."
	detail "With an empty set, checks 15 and 16 scan for nothing and report OK."
else
	check_ok "sync-io-set-nonempty: ${sync_io_count} denied synchronous-I/O primitive(s) ($(tr '\n' ' ' <<<"${sync_io}"))"
fi

# ---------------------------------------------------------------------------
# Check 15: NOTHING IN A DECLARED PLUGIN'S CLOSURE names a synchronous I/O
# primitive in code
#
# §8.1.3: "the I/O API has no synchronous form at all". The plugin surface
# filters `waitFor`, `runForever`, `poll` and `drain` out of the async
# vocabulary it re-exports, and that is the half a plugin author trips over.
# This is the half that catches the rest — including `readFile`, which lives in
# `system` and therefore cannot be filtered out of ANY scope. Measured on the
# tree that carries PLAT-7's surface: `compiles(readFile("x"))` inside a plugin
# is **true**.
#
# Same subject as check 2 — the reachable closure, not the declared file — for
# the same reason: a helper module doing the blocking call on the plugin's
# behalf is the same defect one module further out.
# ---------------------------------------------------------------------------

sync_findings=""
scanned_sync=0
if [ "${sync_io_count}" -gt 0 ]; then
	while IFS= read -r f; do
		[ -n "${f}" ] || continue
		scanned_sync=$((scanned_sync + 1))
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			sync_findings="${sync_findings}${f}:${hit}"$'\n'
		done < <(sync_io_names_in "${f}")
	done <<<"${plugin_scope}"

	if [ -n "${sync_findings}" ]; then
		check_failed "plugin-names-no-sync-io: a declared plugin names a synchronous I/O primitive in code"
		while IFS= read -r finding; do
			[ -n "${finding}" ] || continue
			detail "${finding}"
			prim="${finding##*:}"
			while IFS= read -r pair; do
				case "${pair}" in
				"${prim} "*) detail "  use ${pair#* } instead — it returns a future and is a deadline checkpoint" ;;
				esac
			done < <(awk '{ if (match($0, /\("[A-Za-z_][A-Za-z0-9_]*",[[:space:]]*"[^"]*"/)) {
					s = substr($0, RSTART, RLENGTH); gsub(/[()"]/, "", s); n = index(s, ",")
					printf "%s %s\n", substr(s, 1, n - 1), substr(s, n + 1)
				} }' "${SYNC_IO_REL}" 2>/dev/null | sed 's/ \+/ /')
		done <<<"${sync_findings}"
		detail "A blocking call inside a plugin freezes the front-end for as long as the"
		detail "peer feels like taking, and PLAT-7's budget cannot stop it: that budget's"
		detail "own stated claim is 'one overrun, attributed, then never again'."
		detail "Comments and string literals are removed before this scan, so a finding is code."
	else
		check_ok "plugin-names-no-sync-io: ${scanned_sync} module(s) in the plugin closure, no synchronous I/O primitive named in code"
	fi
fi

# ---------------------------------------------------------------------------
# Check 16: THE SDK DOES NOT BLOCK EITHER
#
# An SDK whose own implementation blocked would satisfy check 15 for every
# plugin and break §8.1.3 on all of their behalf — the plugin would be clean
# and the front-end would still freeze. So the same scanner is turned on
# `plugin_io.nim` itself.
#
# The one exception is DATA rather than a second list here: `startProcess` is
# marked `hostOnly` in the table, because it does not block and because
# wrapping the child's pipes as `AsyncFile`s is precisely the host's job. An
# exemption the gate hardcoded could drift from the SDK; one the SDK declares
# cannot.
# ---------------------------------------------------------------------------

if [ -f "${SYNC_IO_REL}" ] && [ "${sync_io_count}" -gt 0 ]; then
	sdk_findings=""
	while IFS= read -r hit; do
		[ -n "${hit}" ] || continue
		name="${hit##*:}"
		if grep -qxF "${name}" <<<"${sync_host_only}"; then continue; fi
		sdk_findings="${sdk_findings}${hit}"$'\n'
	done < <(sync_io_names_in "${SYNC_IO_REL}")
	if [ -n "${sdk_findings}" ]; then
		check_failed "sdk-does-not-block: ${SYNC_IO_REL} names a blocking primitive in code"
		while IFS= read -r finding; do
			[ -n "${finding}" ] || continue
			detail "${SYNC_IO_REL}:${finding}"
		done <<<"${sdk_findings}"
		detail "Every entry point in that module must reach the OS through an async"
		detail "primitive. A blocking call here breaks §8.1.3 for every plugin at once,"
		detail "and check 15 would still be green for all of them."
		detail "If the host genuinely must call it, mark the entry hostOnly in the table."
	else
		check_ok "sdk-does-not-block: ${SYNC_IO_REL} names none of the ${sync_io_count} blocking primitive(s) except $(tr '\n' ' ' <<<"${sync_host_only}")"
	fi
fi

# ---------------------------------------------------------------------------
# Check 17: POSITIVE CONTROL for the scanner's two filters, on a real file
#
# Check 16 passing means the scanner found nothing. Verification-Harness-Traps
# §4: a scanner that finds nothing passes every "must not contain". So the same
# file is asked the same question with the filters removed, and it must answer
# differently — `${SYNC_IO_REL}` names every denied primitive in its own table
# and in its own header prose, so a scanner that could still see either would
# have to report them.
#
# TWO FILTERS, TWO DIRECTIONS, and the check names which one is dead.
# ---------------------------------------------------------------------------

if [ -f "${SYNC_IO_REL}" ] && [ "${sync_io_count}" -gt 0 ]; then
	raw_hits=0
	stripped_only=0
	# Captured rather than piped into `grep -q`: with `pipefail` set, `grep -q`
	# closing the pipe early kills the upstream `awk` with SIGPIPE and the whole
	# pipeline reports failure, which would make this control read "found
	# nothing" no matter what the file held. That is exactly the shape it
	# exists to detect, so it must not be its own implementation.
	sync_io_stripped="$(code_lines "${SYNC_IO_REL}" | strip_compiles)"
	while IFS= read -r name; do
		[ -n "${name}" ] || continue
		if grep -qE "$(identifier_pattern "${name}")" "${SYNC_IO_REL}"; then
			raw_hits=$((raw_hits + 1))
		fi
		if grep -qE "$(identifier_pattern "${name}")" <<<"${sync_io_stripped}"; then
			stripped_only=$((stripped_only + 1))
		fi
	done <<<"${sync_io}"
	if [ "${raw_hits}" -lt "${sync_io_count}" ]; then
		check_failed "sync-io-scan-discriminates: only ${raw_hits} of ${sync_io_count} name(s) are present in ${SYNC_IO_REL} at all"
		detail "That file declares the table and describes every entry in its header,"
		detail "so every name must be findable in the raw bytes. If they are not, this"
		detail "control cannot tell a working scanner from a dead one."
	elif [ "${stripped_only}" -le 1 ]; then
		check_failed "sync-io-scan-discriminates: with strings left in place the scan still found ${stripped_only} name(s)"
		detail "The comment stripper alone should leave the TABLE's own string literals,"
		detail "which name every entry. Finding at most one means the comment stripper is"
		detail "eating code, and check 15 is scanning something close to nothing."
	else
		check_ok "sync-io-scan-discriminates: ${raw_hits} name(s) in the raw file, ${stripped_only} surviving the comment strip, 0 surviving the string blank (except hostOnly)"
	fi
fi

# ---------------------------------------------------------------------------
# Check 18: PLAT-8's THIRD list is not empty, and every entry is a `std/` spec
#
# The non-vacuity floor, and it points the OTHER WAY from checks 0 and 14 —
# which is worth saying, because reading it as "the same floor again" is how it
# would get deleted as boilerplate. An empty DENIED set makes its scan find
# nothing and print OK forever; an empty ALLOW-list refuses every plugin, loudly
# and by name. So this check is not protecting against a vacuous pass in check
# 19 — the failure falls the safe way on its own. It is protecting against the
# OTHER thing an unparseable table produces: a gate that has stopped reading
# ALLOWLIST_REL and is refusing every plugin for a reason nobody can act on. A
# renamed constant, a moved file and a reformatted table all land here, and the
# remedy names the file rather than leaving somebody to infer it from twenty
# refusals.
#
# The `std/` spelling assertion is the second half and it is not decoration:
# `stdlib_admitted` compares whole specs, so an entry written `strutils` would
# admit nothing, and the symptom would be a plugin refused for importing the
# module the table says is fine.
# ---------------------------------------------------------------------------

allowed_stdlib="$(allowed_stdlib_modules)"
allowed_stdlib_count="$(grep -c . <<<"${allowed_stdlib}" || true)"
allowed_stdlib_malformed="$(grep -v '^std/' <<<"${allowed_stdlib}" | grep -c . || true)"

if [ ! -f "${ALLOWLIST_REL}" ]; then
	check_failed "stdlib-allow-list-nonempty: ${ALLOWLIST_REL} does not exist"
	detail "That file is the SOURCE-LEVEL admission policy: which std modules a"
	detail "plugin's closure may import. Without it check 19 refuses every plugin"
	detail "that imports any std module at all."
elif [ "${allowed_stdlib_count}" -eq 0 ]; then
	check_failed "stdlib-allow-list-nonempty: no module parsed out of ${ALLOWLIST_REL}"
	detail "Expected a '${ALLOWLIST_CONST}' table of (\"std/<module>\", \"reason\") entries."
	detail "With an empty list every declared plugin is refused, which is the safe"
	detail "direction and an unusable gate: fix the table rather than the plugins."
elif [ "${allowed_stdlib_malformed}" -gt 0 ]; then
	check_failed "stdlib-allow-list-nonempty: ${allowed_stdlib_malformed} entr(y|ies) in ${ALLOWLIST_CONST} are not spelled 'std/<module>'"
	while IFS= read -r bad_spec; do
		[ -n "${bad_spec}" ] || continue
		detail "${bad_spec} — write it as the plugin writes the import, 'std/${bad_spec}'"
	done < <(grep -v '^std/' <<<"${allowed_stdlib}")
else
	check_ok "stdlib-allow-list-nonempty: ${allowed_stdlib_count} admitted std module(s) ($(tr '\n' ' ' <<<"${allowed_stdlib}"))"
fi

# ---------------------------------------------------------------------------
# Check 19: NOTHING IN A DECLARED PLUGIN'S CLOSURE IMPORTS A std MODULE THAT IS
# NOT ON THE ALLOW-LIST
#
# THE RULE. Checks 1, 2 and 15 are three denylists — two over module specs and
# one over identifiers — and each of them answers "did the plugin NAME one of
# the things we thought of". This one answers the complement, which is the only
# form of the question that survives a language surface:
#
#     a plugin's closure may import what the allow-list holds, and nothing else.
#
# It was measured, not supposed. With checks 1-17 green, a declared plugin
# importing `codetracer_plugin` and `std/posix` read `/etc/hostname` with no
# `fs:read` grant and fork+exec'd `/bin/sh` with no `process` grant, and this
# script printed `19 check(s), 0 failing`. The whole of §8.1 is bypassed by a
# plugin that declines to use the SDK, and no number of further denied NAMES
# reaches that — `read` and `write` are the SDK's own spellings.
#
# Same subject as checks 1, 2 and 15 — the reachable CLOSURE, not the declared
# file — and for the same reason those have it: a helper module importing
# `std/posix` on the plugin's behalf is the identical defect one module out.
#
# WHAT THIS CHECK IS NOT. It is not a claim that an admitted module is safe in
# some absolute sense, and it is not a claim about `system`, which is
# auto-imported and therefore has no import to refuse. Both bounds are on
# `stdlib_admitted` and in ALLOWLIST_REL's header, in those words.
# ---------------------------------------------------------------------------

allowlist_findings=""
scanned_allowlist=0
if [ "${allowed_stdlib_count}" -gt 0 ]; then
	while IFS= read -r f; do
		[ -n "${f}" ] || continue
		scanned_allowlist=$((scanned_allowlist + 1))
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			allowlist_findings="${allowlist_findings}${f}:${hit}"$'\n'
		done < <(unadmitted_stdlib_in "${f}")
	done <<<"${plugin_scope}"

	if [ -n "${allowlist_findings}" ]; then
		check_failed "plugin-imports-allow-listed: a module in a declared plugin's closure imports a std module that is not admitted"
		while IFS= read -r finding; do
			[ -n "${finding}" ] || continue
			detail "${finding%:*} imports ${finding##*:}, which is not in ${ALLOWLIST_CONST}"
		done <<<"${allowlist_findings}"
		detail "A plugin composes the SDK's primitives; it does not open the operating"
		detail "system itself. ${ALLOWLIST_REL}"
		detail "carries the membership rule and the reason each refused module is refused."
		detail "If the module is genuinely inert, add it there WITH ITS REASON and a probe"
		detail "arm in src/common/plugin_source_admission_test.nim — that is the review the"
		detail "rule asks for, and it is one line plus one line."
	else
		check_ok "plugin-imports-allow-listed: ${scanned_allowlist} module(s) in the plugin closure, every std import admitted"
	fi
fi

# ---------------------------------------------------------------------------
# Check 20: POSITIVE CONTROL for check 19 — the same predicate, in BOTH
# directions, on a real file
#
# Verification-Harness-Traps §4a: check 19 passing means the scan found
# nothing, and a scan that cannot find anything reports exactly that. The
# subject is `${SYNC_IO_REL}` — the SDK module that reaches the operating
# system SO THAT A PLUGIN NEED NOT — which makes it the one file in the tree
# guaranteed to carry unadmitted imports for as long as the SDK does its job.
#
# BOTH DIRECTIONS, because one is not enough. §4a's own postscript is that a
# scan reporting EVERYTHING passes a "must contain" control just as easily as a
# blind one passes a "must not contain": so the check asserts that the
# unadmitted modules are reported AND that the admitted one this same file
# imports is NOT. A predicate that had stopped consulting the allow-list would
# pass the first half and fail the second.
#
# The count is pinned rather than "at least one" (§4b). The pin is a coupling
# and it is the intended kind: adding an operating-system module to the SDK
# reddens this line and asks for the number to be moved deliberately.
# ---------------------------------------------------------------------------

ALLOWLIST_CONTROL_UNADMITTED=9
ALLOWLIST_CONTROL_ADMITTED="std/strutils"

if [ -f "${SYNC_IO_REL}" ]; then
	control_unadmitted="$(unadmitted_stdlib_in "${SYNC_IO_REL}")"
	control_unadmitted_n="$(printf '%s\n' "${control_unadmitted}" | sort -u | grep -c . || true)"
	control_imports_admitted=0
	# HERE-STRING, NOT A PIPE. `ci/test/grep-q-pipefail-gate.sh` caught this the
	# first time it was run over this pass: under `pipefail`, a producer still
	# writing when `grep -q` exits makes a SUCCESSFUL MATCH read as a failure —
	# so the negative half of this control would have reported "the file does
	# not import std/strutils" intermittently, which is a red gate for a reason
	# that is not in the code.
	if grep -qxF "${ALLOWLIST_CONTROL_ADMITTED}" <<<"$(nim_imports "${SYNC_IO_REL}")"; then
		control_imports_admitted=1
	fi
	control_admitted_leaked=0
	if grep -qxF "${ALLOWLIST_CONTROL_ADMITTED}" <<<"${control_unadmitted}"; then
		control_admitted_leaked=1
	fi

	if [ "${control_imports_admitted}" -ne 1 ]; then
		check_failed "allow-list-scan-discriminates: ${SYNC_IO_REL} does not import ${ALLOWLIST_CONTROL_ADMITTED}"
		detail "The negative half of this control needs an ADMITTED std import in the same"
		detail "file, or 'the scan did not report it' is satisfied by an import that is not"
		detail "there — Verification-Harness-Traps §4, in the control itself."
	elif [ "${control_admitted_leaked}" -eq 1 ]; then
		check_failed "allow-list-scan-discriminates: the scan reported ${ALLOWLIST_CONTROL_ADMITTED}, which IS on the allow-list"
		detail "The predicate is reporting std imports without consulting the allow-list,"
		detail "so check 19 would refuse every plugin that imports anything at all."
	elif [ "${control_unadmitted_n}" -ne "${ALLOWLIST_CONTROL_UNADMITTED}" ]; then
		check_failed "allow-list-scan-discriminates: the predicate reports ${control_unadmitted_n} unadmitted std module(s) in ${SYNC_IO_REL}, expected ${ALLOWLIST_CONTROL_UNADMITTED}"
		detail "$(printf '%s' "${control_unadmitted}" | sort -u | tr '\n' ' ')"
		detail "If the SDK genuinely gained or lost an operating-system module, move"
		detail "ALLOWLIST_CONTROL_UNADMITTED and say so. If it did not, check 19 is blind."
	else
		check_ok "allow-list-scan-discriminates: ${control_unadmitted_n} unadmitted std module(s) in ${SYNC_IO_REL} ($(printf '%s' "${control_unadmitted}" | sort -u | tr '\n' ' ')), and ${ALLOWLIST_CONTROL_ADMITTED} not among them"
	fi
else
	check_failed "allow-list-scan-discriminates: ${SYNC_IO_REL} is missing, so check 19 has no control"
fi

# ---------------------------------------------------------------------------
# Check 21: NOTHING IN A DECLARED PLUGIN'S CLOSURE BINDS A FOREIGN FUNCTION
#
# THE ATTACK ON CHECK 19, AND ITS REPAIR. Check 19 refuses `std/posix`; this
# refuses the plugin declaring posix's routines for itself, which needs no
# import and would therefore have walked past an allow-list over every module
# in the world. Measured, compiled and run against the real surface on
# 2026-09-09 — the whole module:
#
#     import codetracer_plugin
#     proc c_system(cmd: cstring): cint
#       {.importc: "system", header: "<stdlib.h>".}
#     discard c_system("printf FFI-REACHED > /tmp/ct-plat8-ffi.txt")
#
# and the sentinel was there. One pragma is `system(3)`, which is every grant
# at once and none of them declared.
#
# THIS ONE IS A DENYLIST AND THAT IS DELIBERATE. The argument against a
# denylist is that the set is open; nim's foreign-function pragmas are closed,
# enumerable and fixed by the compiler's grammar, so this is a different object
# from a denylist over library identifiers. The residual is exact: a pragma nim
# ADDS in a future release is not on the list. See ALLOWLIST_REL's header.
# ---------------------------------------------------------------------------

ffi_pragmas="$(denied_ffi_pragmas)"
ffi_pragma_count="$(grep -c . <<<"${ffi_pragmas}" || true)"

if [ "${ffi_pragma_count}" -eq 0 ]; then
	check_failed "ffi-pragma-set-nonempty: no pragma parsed out of ${ALLOWLIST_REL}"
	detail "Expected a '${FFI_CONST}' table of (\"pragma\", \"replacement\") entries."
	detail "With an empty set this scan finds nothing and prints OK forever, which is"
	detail "the vacuous pass checks 0 and 14 exist to refuse for the other two sets."
else
	ffi_findings=""
	scanned_ffi=0
	while IFS= read -r f; do
		[ -n "${f}" ] || continue
		scanned_ffi=$((scanned_ffi + 1))
		while IFS= read -r hit; do
			[ -n "${hit}" ] || continue
			ffi_findings="${ffi_findings}${f}:${hit}"$'\n'
		done < <(ffi_names_in "${f}")
	done <<<"${plugin_scope}"

	if [ -n "${ffi_findings}" ]; then
		check_failed "plugin-binds-no-foreign-function: a declared plugin's closure carries a foreign-function pragma"
		# `names_in` yields `<file>:<n>:<name>`, and in this mode `<n>` counts
		# PRAGMA SPANS rather than source lines — the scan reads a span, not a
		# line, which is the whole reason it sees the multi-line spelling. It
		# is dropped rather than printed, because a number that looks like a
		# line number and is not is worse than no number: a reader would go to
		# that line and find something else.
		while IFS= read -r finding; do
			[ -n "${finding}" ] || continue
			detail "${finding%%:*} binds a foreign function with '${finding##*:}'"
		done < <(sed -E 's/:[0-9]+:/:/' <<<"${ffi_findings}" | sort -u | grep -v '^$')
		detail "A plugin composes the SDK's primitives. One '{.importc: \"system\".}' is"
		detail "arbitrary code execution with no grant, no declared executable and no"
		detail "disclosure, and it needs no import at all — which is why refusing modules"
		detail "does not reach it. ${ALLOWLIST_REL} carries the list and the reason."
	else
		check_ok "plugin-binds-no-foreign-function: ${scanned_ffi} module(s) in the plugin closure, no foreign-function pragma in code (${ffi_pragma_count} refused)"
	fi
fi

# ---------------------------------------------------------------------------
# Check 22: POSITIVE CONTROL for check 21 — the same predicate, on two real
# files, one of which must yield and one of which must not
#
# Verification-Harness-Traps §4a's pairing, and it needs BOTH files because the
# two ways this scan can be wrong point in opposite directions. A scan that
# reads nothing passes check 21 vacuously; a scan that has lost its
# pragma-span bound matches the word `header` in ordinary code and refuses
# every plugin that has one. The first is caught by `${SYNC_IO_REL}`, which
# declares `O_NOFOLLOW` with `{.importc: … header: ….}` for the symlink repair
# F2 landed; the second is caught by `${PRIMITIVES_REL}`, which carries no
# pragma at all and must yield zero.
#
# The count is pinned rather than "at least one" (§4b).
# ---------------------------------------------------------------------------

FFI_CONTROL_EXPECTED=2

if [ "${ffi_pragma_count}" -gt 0 ] && [ -f "${SYNC_IO_REL}" ] && [ -f "${PRIMITIVES_REL}" ]; then
	ffi_control_hits="$(ffi_names_in "${SYNC_IO_REL}" | cut -d: -f2- | sort -u)"
	ffi_control_n="$(grep -c . <<<"${ffi_control_hits}" || true)"
	ffi_quiet_n="$(ffi_names_in "${PRIMITIVES_REL}" | grep -c . || true)"
	if [ "${ffi_control_n}" -ne "${FFI_CONTROL_EXPECTED}" ]; then
		check_failed "ffi-scan-reads-pragmas: the predicate found ${ffi_control_n} pragma(s) in ${SYNC_IO_REL}, expected ${FFI_CONTROL_EXPECTED}"
		detail "$(tr '\n' ' ' <<<"${ffi_control_hits}")"
		detail "That file declares O_NOFOLLOW with importc and header. Finding fewer means"
		detail "check 21 is scanning something close to nothing."
	elif [ "${ffi_quiet_n}" -ne 0 ]; then
		check_failed "ffi-scan-reads-pragmas: the predicate found ${ffi_quiet_n} pragma(s) in ${PRIMITIVES_REL}, which has none"
		detail "The scan has lost its pragma-span bound and is matching bare identifiers,"
		detail "so a plugin with a variable called 'header' would now be refused."
	else
		check_ok "ffi-scan-reads-pragmas: ${ffi_control_n} pragma(s) in ${SYNC_IO_REL} ($(tr '\n' ' ' <<<"${ffi_control_hits}")), 0 in ${PRIMITIVES_REL}"
	fi
fi

# ---------------------------------------------------------------------------
# Check 23: THE `system` SURFACE IS ENUMERATED, AND THE ENUMERATION IS DERIVED
#
# THE FIFTH LIST, AND IT IS THE ONLY ONE NOT WRITTEN DOWN IN THIS REPOSITORY.
# The other four are tables in nim files. This one is swept off the pinned
# compiler's own source by `ci/lib/system-io-surface.sh`, because the subject is
# not ours: `system.nim` ends with `export syncio`, so what a plugin can name
# with no import and no pragma is whatever `std/syncio` exports in the compiler
# that happens to be on PATH.
#
# WHY IT IS DERIVED RATHER THAN LISTED. Three passes wrote the residual down by
# hand and all three were short. The third is the one that cost something: the
# list said ten names, `open` was on it and denied nowhere, and the buffer
# family around `open` was not on it at all — so a plugin whose entire import
# list was `import codetracer_plugin` read and wrote any file the user could,
# with nineteen checks green above it. Sweeping for the repair then turned up
# `reopen` and `lines`, which no list had either, and `reopen` needs no `open`
# at all — so even denying the name that WAS written down would not have closed
# it.
#
# WHAT THIS CHECK ASSERTS is therefore not "the names we thought of are
# denied". It is that the DERIVED SET is partitioned by the two tables: every
# name is refused (`PluginDeniedSyncIo`) or exempted with a reason
# (`PluginSystemSurfaceExempt`). A nim release that adds a routine to `syncio`
# reddens this check on the next run, which is the property no enumeration
# maintained here can have.
#
# IT FAILS CLOSED. A sweep that derived nothing — no nim on PATH, a moved
# stdlib, a parser that stopped parsing — is reported as a FAILURE and not as a
# clean surface, for the reason `sync-io-set-nonempty` above gives: a scan that
# finds nothing passes every "must not contain".
# ---------------------------------------------------------------------------

# THE DIAGNOSIS IS KEPT, NOT DISCARDED. This line read `2>/dev/null` until
# 2026-09-10, so nim's exit code and its stderr went in the bin and every way
# the sweep can fail arrived below as one sentence and three guesses. "nim is
# not on PATH", "nim exited 137 because something killed it" and "the stdlib
# moved" are three different facts, exactly one of which is a finding about this
# repository, and a check that cannot tell them apart hands the next reader an
# investigation instead of a result — which is what it did, twice.
system_surface_diag="$(mktemp)"
system_surface="$(system_surface_names 2>"${system_surface_diag}" || true)"
system_surface_n="$(grep -c . <<<"${system_surface}" || true)"
system_exempt="$(table_names "${SYNC_IO_REL}" "${SYSTEM_EXEMPT_CONST}")"
system_exempt_n="$(grep -c . <<<"${system_exempt}" || true)"

if [ "${system_surface_n}" -eq 0 ]; then
	check_failed "system-surface-enumerated: the sweep derived NO name from the compiler's system/syncio surface"
	# THE SWEEP'S OWN REASON, verbatim, before any prose of ours. It names the
	# command, its exit code and what it printed, so the three ways this fires
	# are told apart from the transcript rather than by a second run.
	while IFS= read -r system_surface_line; do
		[ -n "${system_surface_line}" ] || continue
		detail "${system_surface_line}"
	done <"${system_surface_diag}"
	detail "ci/lib/system-io-surface.sh found nothing. This is reported as a"
	detail "FAILURE rather than as an empty surface: with nothing derived, this check"
	detail "would otherwise pass by scanning for nothing, which is exactly how the"
	detail "residual it replaces went three passes without being noticed."
else
	system_accounted="$(printf '%s\n%s\n' "${sync_io}" "${system_exempt}" | grep -v '^$' | LC_ALL=C sort -u)"
	system_unaccounted="$(LC_ALL=C comm -23 <(printf '%s\n' "${system_surface}") <(printf '%s\n' "${system_accounted}"))"
	system_unaccounted_n="$(grep -c . <<<"${system_unaccounted}" || true)"
	if [ "${system_unaccounted_n}" -gt 0 ]; then
		check_failed "system-surface-enumerated: ${system_unaccounted_n} name(s) that ARE in every plugin's scope are on neither table"
		while IFS= read -r nm; do
			[ -n "${nm}" ] || continue
			detail "${nm} — exported by system, on neither table"
		done <<<"${system_unaccounted}"
		detail "Each is exported by std/syncio or system/compilation.nim on the nim in use,"
		detail "so a plugin can name it with no import and no pragma. Put it on"
		detail "${SYNC_IO_CONST} if it reaches the operating system, or on"
		detail "${SYSTEM_EXEMPT_CONST} WITH THE REASON if it does not. Do not"
		detail "narrow the sweep: the sweep is the only part of this that a nim upgrade"
		detail "cannot make quietly wrong."
	else
		check_ok "system-surface-enumerated: ${system_surface_n} derived name(s), all accounted for (${system_exempt_n} exempt with a reason)"
	fi
	# THE LOOKUP'S OWN NOTE, WHEN IT HAD ONE — under the OK as well as under the
	# VIOLATION. A NON-EMPTY sweep can still have something to say:
	# `system_surface_lib` derives the library directory from where the nim on
	# PATH sits when `nim dump` could not be read, and that happens when the
	# compiler is present but cannot be RUN — a starved or OOM-killed `nim` on a
	# loaded host, measured 2026-09-11. The sweep that follows is complete, so
	# this is not a finding and must not redden the check; but a fallback that
	# only ever spoke on the path where it failed would be a fallback nobody
	# could audit from a transcript, which is the shape of the 2026-09-10 repair
	# above that put nim's exit code in front of the reader in the first place.
	# Silent on a normal run: every command in the sweep captures its own
	# output, so this file is empty unless the lookup wrote to it.
	while IFS= read -r system_surface_line; do
		[ -n "${system_surface_line}" ] || continue
		detail "${system_surface_line}"
	done <"${system_surface_diag}"
fi

# ---------------------------------------------------------------------------
# Check 24: POSITIVE CONTROL for check 23 — the sweep discriminates, and
# widening `table_names` moved no other table's count
#
# Two independent ways check 23 can be green for the wrong reason, so two
# controls (Verification-Harness-Traps §4a, §4b — the counts are pinned rather
# than "at least one"):
#
#   * THE SWEEP READS THE RIGHT MODULE. `readFile` must be derived — it is the
#     name the whole residual was written about — and `fork` must NOT be, because
#     `fork` is `std/posix`, which is refused by the ALLOW-list and is a
#     different mechanism. A sweep that had drifted onto the wrong file, or that
#     had started reading every module in the stdlib, fails one of the two.
#   * WIDENING THE PARSER CHANGED NOTHING ELSE. `table_names` grew `&` and `=`
#     for this table's `&=` row. The other four tables are parsed by the same
#     awk, so their counts are asserted here rather than argued.
# ---------------------------------------------------------------------------

SYSTEM_SURFACE_PRESENT="readFile"
SYSTEM_SURFACE_ABSENT="fork"

if [ "${system_surface_n}" -gt 0 ]; then
	surface_ctl=""
	grep -qxF "${SYSTEM_SURFACE_PRESENT}" <<<"${system_surface}" ||
		surface_ctl="${surface_ctl}the sweep did not derive '${SYSTEM_SURFACE_PRESENT}', which system exports; "
	if grep -qxF "${SYSTEM_SURFACE_ABSENT}" <<<"${system_surface}"; then
		surface_ctl="${surface_ctl}the sweep derived '${SYSTEM_SURFACE_ABSENT}', which is std/posix and not system; "
	fi
	# EVERY DECLARED ROW COMES BACK, from all five tables, through the one awk
	# that now carries `&` and `=` for `PluginSystemSurfaceExempt`'s `&=` row.
	# A widening that had started swallowing or inventing rows moves one of
	# these five, in whatever tree the gate is pointed at.
	for tbl in "${PRIMITIVES_REL}:${PRIMITIVES_CONST}" \
		"${SYNC_IO_REL}:${SYNC_IO_CONST}" \
		"${SYNC_IO_REL}:${SYSTEM_EXEMPT_CONST}" \
		"${ALLOWLIST_REL}:${ALLOWLIST_CONST}" \
		"${ALLOWLIST_REL}:${FFI_CONST}"; do
		tbl_file="${tbl%:*}"
		tbl_const="${tbl##*:}"
		[ -f "${tbl_file}" ] || continue
		tbl_declared="$(table_declared_len "${tbl_file}" "${tbl_const}")"
		[ -n "${tbl_declared}" ] || continue
		tbl_parsed="$(table_names "${tbl_file}" "${tbl_const}" | grep -c . || true)"
		if [ "${tbl_parsed}" -ne "${tbl_declared}" ]; then
			surface_ctl="${surface_ctl}${tbl_const} declares ${tbl_declared} row(s) and the parser returned ${tbl_parsed}; "
		fi
	done
	# THE `open` EXEMPTION IS ONE LINE, AND THAT IS THE ASSERTION.
	#
	# `open` is `hostOnly`, so check 16 does not hold the SDK to it — and an
	# exemption nobody measures is an exemption that grows. It covers ONE
	# occurrence, `posix.open` inside `openVerified`, the mediated open taken
	# after `decide`. It covered SIX until 2026-09-09, when `handles.open` —
	# which opened nothing and was the entire reason `open` was said to be
	# undeniable — was renamed to `registerHandle`. Pinning the count here is
	# what stops the rename being undone by a call site at a time.
	# ONLY IF THE SDK CLAIMS THE EXEMPTION. In a synthetic tree `open` is not
	# on the table at all, and asserting a repo-specific line count there would
	# be this check failing for a reason the case under test never touched.
	if grep -qxF open <<<"${sync_host_only}"; then
		sdk_open_hits="$(sync_io_names_in "${SYNC_IO_REL}" | grep ':open$' || true)"
		sdk_open_n="$(grep -c . <<<"${sdk_open_hits}" || true)"
		if [ "${sdk_open_n}" -ne 1 ]; then
			surface_ctl="${surface_ctl}${SYNC_IO_REL} names 'open' ${sdk_open_n} time(s), expected exactly 1 (posix.open in openVerified); "
		else
			sdk_open_line="$(sed -n "${sdk_open_hits%%:*}p" "${SYNC_IO_REL}")"
			case "${sdk_open_line}" in
			*posix.open*) ;;
			*) surface_ctl="${surface_ctl}the one 'open' in ${SYNC_IO_REL} is not posix.open: ${sdk_open_line}; " ;;
			esac
		fi
	fi
	if [ -n "${surface_ctl}" ]; then
		check_failed "system-surface-control: ${surface_ctl}"
		detail "Check 23 is only evidence if the sweep reads the right module and the"
		detail "parser it shares with four other tables still reads them the same way."
	else
		check_ok "system-surface-control: the sweep has '${SYSTEM_SURFACE_PRESENT}' and not '${SYSTEM_SURFACE_ABSENT}'; all five tables return every declared row; the SDK names 'open' once (posix.open)"
	fi
fi

# Removed here rather than in an EXIT trap: `nim_imports_open_unanalysable_log`
# already owns this script's only trap, and a second one would silently replace
# it (see that function's header).
rm -f "${system_surface_diag}"

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

if [ "${failures}" -eq 0 ]; then
	echo "plugin-reactive-boundary: ${checks_run} check(s), 0 failing"
	exit 0
fi
echo "plugin-reactive-boundary: ${checks_run} check(s), ${failures} failing"
exit 1
