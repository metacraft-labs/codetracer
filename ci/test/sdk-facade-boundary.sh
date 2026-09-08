#!/usr/bin/env bash
#
# sdk-facade-boundary.sh — enforce the CodeTracer Embed SDK's boundary, BY
# NAME, in both directions.
#
# WHY THIS EXISTS
# ---------------
# CodeTracer-Embed-SDK.md §3.2 ends: "Enforcement is an import lint, not
# discipline." BlockTracer/Client-SDK.md §1.1 asks for the mirror of the same
# rule and says why: "a rule that depends on someone remembering it is not a
# boundary". BlockTracer's own milestone M8a carries the consumer-side test
# (`test_debugger_panes_use_only_sdk_facade`); this is the producer-side half,
# living where the package it constrains lives.
#
# Two directions, because a boundary has two sides:
#
#   OUTWARD  a consumer must reach the SDK only through the facade module
#            (`src/frontend/viewmodel/codetracer_embed.nim`). Reaching into
#            `viewmodel/store/replay_data_store` directly pins an internal as
#            public ABI, and §7's stability contract — "internal refactors
#            that do not change the facade are not breaking changes" — becomes
#            false the moment one consumer does it.
#
#   INWARD   the facade's own transitive import graph must contain no
#            rendering, no layout engine, no DOM, no process spawning
#            (§3.2 rows 1-2, and BlockTracer.milestones.org M2a's
#            `test_replay_core_has_no_render_dependencies`), and NO CHAIN
#            CONCEPT AT ALL (§3.2, last row).
#
# The chain rule is the one that will actually be tested by events, because
# BlockTracer is this SDK's first consumer and a chain concept added "just for
# BlockTracer" always looks local and reasonable. Noir Studio is the second
# consumer that needs the whole lower layer and none of the chain layer, which
# is what makes this a boundary rather than a guess (Client-SDK.md §2).
#
# HOW A CONSUMER IS DECLARED
# --------------------------
# Nothing is a consumer by accident. A file opts in, in one of two spellings,
# both committed and both visible in review — the same two spellings
# ci/test/test-lane-coverage.sh already uses, because a second convention for
# the same idea is a second thing to learn:
#
#   a. a header comment within the file's first ${MARKER_SCAN_LINES} lines:
#
#          ## SDK-CONSUMER: <reason>
#
#   b. a `.sdk-consumer` file in the file's directory or any ancestor up to
#      the repo root, whose contents are the reason. This is for a whole tree
#      of consumer code — BlockTracer's debugger panes, a headless app
#      entrypoint — where marking each file would be noise.
#
# A declared consumer may import:
#   * the facade module, by any spelling that resolves to it;
#   * anything outside the SDK's own subtree (stdlib, isonim, its own modules).
# It may not import any other module inside ${SDK_SUBTREE}.
#
# IsoNim is deliberately NOT an SDK internal. It is a peer package and §4.1
# makes its signals part of the consumption model ("signals cross no
# boundary"), so importing `isonim/core/signals` directly is allowed.
#
# WHY LEXICAL, AND WHAT THAT COSTS
# --------------------------------
# The import graph is computed by reading `import` / `from` / `include`
# statements, not by asking the Nim compiler. That keeps the guard in the
# cheap, always-runnable half of the lint stage (pure bash + awk, no
# toolchain, about a second) — the same reason ci/lint/nim.sh puts the
# lane-coverage guard ahead of anything needing a compiler.
#
# The cost is that resolution mimics Nim's rather than being Nim's: same
# directory first, then the search roots below. It was validated against
# `nim --genDeps` output for the facade when it was written; if the two ever
# disagree the resolver is what is wrong, not the rule.
#
# Usage:
#   ci/test/sdk-facade-boundary.sh
#   ci/test/sdk-facade-boundary.sh --root DIR
#
# `--root` exists so ci/test/sdk-facade-boundary-test.sh can drive every check
# against synthetic trees. It is not used in CI.

set -uo pipefail

# ---------------------------------------------------------------------------
# BASH >= 4 IS A HARD REQUIREMENT, AND ITS ABSENCE IS NOW REPORTED AS ABSENCE
# ---------------------------------------------------------------------------
#
# This script uses `mapfile`, a bash-4 builtin. macOS ships /bin/bash 3.2 and
# does not have it.
#
# WHAT THAT LOOKED LIKE, AND WHY IT IS WORSE THAN A RED. This script runs every
# check and decides its status at the end — `set -uo pipefail`, deliberately no
# `-e`, for the reason written up in ci/lib/lint-steps.sh. So a missing builtin
# did not stop it. Under bash 3.2 it printed `OK  facade-present`, then
# `mapfile: command not found` four times, then `unbound variable` for every
# array those four calls were supposed to fill, and exited non-zero having
# checked almost nothing.
#
# `src/frontend/viewmodel/tests/unit/test_sdk_facade_boundary.nim` shells out to
# this script and reads its exit status, so that became FOUR FAILED CONTENT
# ASSERTIONS — including `VIOLATION consumer-facade-only`, which is that
# suite's own NEGATIVE CONTROL, the case that exists to prove this guard can say
# no. A reader saw four findings. The truth was that the checker had not run.
#
# A gate that is red on every workstation and green only in CI is exactly as
# informative as one that is always green, and it costs more: it trains people
# to ignore the lane it sits in. Measured on `cloud` at ecee3b1d, this was both
# of `ci/lint/nim.sh`'s two FAILEDs and the only red in `just test-vm-unit`.
#
# So, in order:
#   1. RUN ANYWAY if a bash >= 4 is reachable. The nix dev shell supplies 5.3;
#      what hid it is a LOGIN shell, which re-sources the profile and puts /bin
#      ahead of the store paths. `bash -lc` gets 3.2, `bash -c` gets 5.3, on the
#      same machine, in the same dev shell. Re-execing means the caller does not
#      have to know that.
#   2. If there is genuinely no bash >= 4 on PATH, SAY SO BY NAME and exit 2.
#      Exit 2 is already this script's "could not run" code — see the unknown
#      argument arm and `cd "${root}" || exit 2` below. 1 is reserved for
#      findings. A caller can therefore tell "I could not run" from "I found
#      something", which is the distinction that was missing.
#
# `CT_SDK_FACADE_MIN_BASH` exists so the not-runnable path can be driven with
# this same code rather than with a fake: set it above any bash that exists and
# the search finds nothing, exactly as it would on a 3.2-only machine.
sdk_facade_min_bash="${CT_SDK_FACADE_MIN_BASH:-4}"
if [ "${BASH_VERSINFO[0]}" -lt "${sdk_facade_min_bash}" ]; then
	if [ "${CT_SDK_FACADE_REEXECED:-0}" != "1" ]; then
		for sdk_facade_candidate in $(type -aP bash 2>/dev/null); do
			# SC2016 is the point: the single quotes are what stop THIS
			# shell expanding `BASH_VERSINFO`. It has to be the candidate
			# that expands it — its version is the question.
			# shellcheck disable=SC2016
			sdk_facade_major="$("${sdk_facade_candidate}" -c \
				'echo ${BASH_VERSINFO[0]}' 2>/dev/null)"
			case "${sdk_facade_major}" in
			'' | *[!0-9]*) continue ;;
			esac
			if [ "${sdk_facade_major}" -ge "${sdk_facade_min_bash}" ]; then
				export CT_SDK_FACADE_REEXECED=1
				exec "${sdk_facade_candidate}" "${BASH_SOURCE[0]}" "$@"
			fi
		done
	fi
	# NOT RUN, said in one line with a stable token, because the Nim suite over
	# this script keys on it to report absence instead of inventing findings.
	echo "NOT RUN   bash-version: this checker needs bash >= ${sdk_facade_min_bash}" \
		"and is running under ${BASH_VERSION}; \`mapfile\` is a bash-4 builtin." \
		"No bash >= ${sdk_facade_min_bash} was found on PATH." \
		"Nothing about the SDK boundary has been established." >&2
	exit 2
fi

# ---------------------------------------------------------------------------
# Shared code
# ---------------------------------------------------------------------------

# THE NIM IMPORT EXTRACTOR, shared with ci/test/plugin-reactive-boundary.sh.
# Sourced relative to THIS FILE rather than to `${root}`, because `--root`
# points at a synthetic tree that has no `ci/` in it.
# Repo-root-relative, because that is where shellcheck resolves a `source=`
# from; SC1091 disabled for the reason ci/lint/nim.sh gives — the pre-commit
# hook runs without -x and cannot follow it.
# shellcheck source=ci/lib/nim-imports.sh disable=SC1091
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/nim-imports.sh"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The subtree the boundary protects. Everything under it is an SDK internal
# unless it is the facade itself.
SDK_SUBTREE="src/frontend/viewmodel"

# The one module a consumer may import. Its name is also asserted to appear in
# the facade's own `CodeTracerEmbedFacadeModule` constant, so renaming the file
# without renaming the constant (or vice versa) is caught rather than silently
# disarming this guard.
FACADE_REL="${SDK_SUBTREE}/codetracer_embed.nim"
FACADE_MODULE="codetracer_embed"

# THE SECOND DOOR, AND WHY IT IS NOT A SECOND FACADE.
#
# `codetracer_plugin.nim` is `codetracer_embed` with ten symbols filtered out by
# `export … except` — the raw `isonim` computation-creating and
# owner-manipulating primitives, which §4.1 puts in scope for Mode N consumers
# and which a PLUGIN must not have (Extensibility-Model.md §5.3's budget is
# enforcement only while a plugin cannot create a computation the host did not
# wrap; PLAT-7 deliverable 6). It is enforced by
# `ci/test/plugin-reactive-boundary.sh`, which is where that rule lives.
#
# It is admitted here as a permitted import and NOTHING ELSE about this guard
# changes. Every other check stays computed over ${FACADE_REL} alone, and that
# is correct rather than an omission: the plugin surface's import graph is a
# SUBSET of the facade's, because its only import is the facade. That is not
# taken on trust — the file carries a `## SDK-CONSUMER:` header marker, so
# check 4 below holds it to the same facade-only rule as every other consumer,
# and a plugin surface that started importing an SDK internal would redden here
# by the ordinary path rather than needing a rule of its own.
#
# `facade-present` deliberately does NOT gain a twin for it. This file's subject
# is the SDK's public surface; a missing plugin surface is
# plugin-reactive-boundary.sh's `surface-present`, and duplicating it would put
# the same finding in two gates with two names.
PLUGIN_SURFACE_REL="${SDK_SUBTREE}/codetracer_plugin.nim"
PLUGIN_SURFACE_MODULE="codetracer_plugin"

# Where an unqualified module spec is looked up, after the importing file's own
# directory. Mirrors the `--path` entries the ViewModel lanes compile with
# (ci/lib/test-lane-files.sh `test_lane_extra_flags`) plus config.nims.
SEARCH_ROOTS=("${SDK_SUBTREE}" "src/frontend" "src" ".")

# Sibling PACKAGE roots, searched after SEARCH_ROOTS and resolved to absolute
# paths so the walk can leave this repository.
#
# WHY THIS EXISTS. Until it did, the walk stopped at the repository boundary,
# so "the facade's graph contains no renderer" meant "contains no renderer *in
# codetracer*, and none at IsoNim's seven entry points". IsoNim is the UI
# framework the whole renderer is written against; if `isonim/core/signals`
# ever grew an import of `isonim/web/dom_api`, the rule below would have had
# nothing to match and the guard would have gone on printing OK.
# BlockTracer.milestones.org M2a carried that as a known gap — "the import lint
# does not walk IsoNim ... benign as measured but unguarded, and IsoNim is on
# someone else's cadence". The second half of that sentence is the argument for
# closing it rather than for leaving it: a dependency on someone else's cadence
# is exactly the one a lint has to hold.
#
# Each entry is `<probe-relative-to-root>|<env-override>|<fallback-suffix>`.
# Both packages are REQUIRED siblings of this repo already
# (scripts/require-siblings.sh), which is what makes it legitimate for this
# guard to fail rather than shrug when one is missing — see the
# `graph-walks-siblings` check below.
SIBLING_PACKAGES=(
	"isonim|isonim/core/signals.nim|ISONIM_SRC|../isonim/src"
	"nim-everywhere|nim_everywhere/async_compat.nim|NIM_EVERYWHERE_SRC|../nim-everywhere/src"
)

# Filled by resolve_sibling_roots.
SIBLING_ROOTS=()
SIBLING_MISSING=()

# How far into a file the `## SDK-CONSUMER:` header marker may appear.
MARKER_SCAN_LINES=40

# ---------------------------------------------------------------------------
# THE CODETRACER TUI's TWO DIRECTORIES — one declared consumer, one EXEMPT.
# ---------------------------------------------------------------------------
#
# `src/frontend/tui/` (CTUI-0, codetracer-specs/Front-Ends/
# CodeTracer-TUI.milestones.org) is deliberately split in two, and the split is
# the reason the terminal front-end lives in this repository at all:
#
#   app/   DECLARED CONSUMER. Carries a `.sdk-consumer` directory marker, so
#          every module beneath it is covered by the outward half of this
#          guard exactly as `headless_app/` is. Views, layout projection,
#          input, panes.
#
#   host/  EXEMPT, ON PURPOSE, AND RECORDED HERE RATHER THAN INFERRED. It is
#          the only part of the TUI allowed to import `backend/stdio_backend`
#          and `viewmodel/headless_session` — the two modules `codetracer_embed`
#          deliberately withholds, and the only ones that spawn a local
#          `replay-server` for a `.ct` folder on disk. A front-end that lived
#          outside this repo could therefore not open a local trace through the
#          sanctioned surface AT ALL; the capability is not smuggled in, it is
#          isolated in one named directory on the far side of this line.
#
# THE EXEMPTION IS THE ABSENCE OF A MARKER, WHICH IS WHY IT IS CHECKED.
# Nothing is a consumer by accident here — but nothing is exempt by accident
# either, and "exempt" spelled as "we did not write a file" is indistinguishable
# from "somebody forgot". A `.sdk-consumer` placed one directory up, at
# `src/frontend/tui/`, would silently enrol `host/` and turn this guard red for
# a reason no reader would connect to the TUI's layering. So the `tui-layers`
# check below asserts both halves: that `app/` IS discovered, and that `host/`
# is NOT. The complementary rule — that no `app/` module reaches `host/` or a
# host capability — is enforced from the other side, structurally and with a
# mutation arm, by `src/frontend/tui/tests/test_tui_facade_boundary.nim`.
TUI_CONSUMER_DIR="src/frontend/tui/app"
TUI_EXEMPT_DIR="src/frontend/tui/host"

# The desktop UI tree. Held in its own variable because it is the one
# forbidden pattern with an allowlist, and both the exemption check and the
# remedy message below have to name the same rule.
UI_PATH_PATTERN="^src/frontend/ui/"

# The ONLY modules under `src/frontend/ui/` the SDK graph may contain, by exact
# repo-relative path, each with the reason it is exempt.
#
# An allowlist rather than a softened rule, deliberately: see the NOTE below.
UI_PATH_ALLOWLIST=(
	# Zero imports, and nothing in it but integer arithmetic over
	# `rrTicksForIterations` — which loop iteration a tick falls inside. No
	# class name, no style string, no component, nothing a renderer would
	# recognise. It lives under `ui/` only because it was factored out of
	# `ui/flow.nim` to be testable on the C backend, which its own docstring
	# says. `viewmodels/flow_vm.nim` imports it.
	"src/frontend/ui/flow_loop_math.nim"
)

# Modules the SDK's graph must not contain, as POSIX ERE over the module spec
# (for anything outside the repo) or the repo-relative path (for anything
# inside it), each with the reason a reader needs.
FORBIDDEN_PATTERNS=(
	"(^|/)karax(/|$)|(^|/)kdom(\.nim)?$|(^|/)vdom(\.nim)?$;a renderer (spec §3.2: any rendering, any component)"
	"(^|/)dom(\.nim)?$;DOM access (spec §3.2: any rendering)"
	"(^|/)(karax_dom|jsdom)(\.nim)?$;a DOM shim (spec §3.2: any rendering)"
	"(^|/)isonim/(ui|dsl|renderers|web|components|theming|layout|editor|native|ssr|ssr_nginx|accessibility)(/|$);an IsoNim rendering or layout module (spec §3.2)"
	"[Mm]onaco;Monaco (spec §3.2, row 2)"
	"[Gg]olden[Ll]?ayout|golden_layout;GoldenLayout (spec §3.2, row 2)"
	"^src/frontend/viewmodel/views/;the SDK's own IsoNim views (spec §3.2: including it would fork the panes)"
	"^src/frontend/(renderer|index)/;the legacy Electron renderer (spec §3.2)"
	"${UI_PATH_PATTERN};the desktop UI tree (spec §3.2 row 1: any rendering, any CSS, any component) — exempt it by name in UI_PATH_ALLOWLIST if it is genuinely none of those"
	"^src/frontend/types\.nim$;the desktop types module — ReplaySession.savedLayoutConfig is GoldenLayoutResolvedConfig (BlockTracer M2a: the shell is the renderer-bound part)"
	"(^|/)electron|ipc_renderer|ipcRenderer;Electron IPC (spec §3.2)"
	"(^|/)osproc(\.nim)?$;spawns processes — an embeddable library cannot (spec §8: the SDK creates a worker, not a child process)"
)

# NOTE on `std/jsffi`, which is deliberately NOT banned.
#
# It was, in the first draft, on the grounds of being "Electron/browser FFI".
# That was wrong: `jsffi` is how any Nim library reaches JavaScript at all —
# IsoNim's own core uses it — and §3.2 bans rendering, components, CSS,
# Monaco, GoldenLayout and the desktop layout engine, not the FFI. A guard
# that bans the target language's FFI would be un-satisfiable by a package
# whose whole point is to be consumed from JavaScript.
#
# What §3.2 actually forbids on that path is the DOM, and `dom` / `kdom` /
# `karax` below are exactly that.

# NOTE on `src/frontend/ui/`, which IS a blanket ban, with an allowlist.
#
# The ban fired once on `src/frontend/ui/flow_loop_math.nim` — a module with
# ZERO imports whose docstring exists to say it is not the renderer ("factored
# out so it is testable on the C backend"). That was a real false positive, and
# the first attempt at a fix was to delete the rule on the argument that the
# import graph subsumes it: `ui/flow.nim`, the genuinely renderer-bound module
# in that directory, imports `../renderer`, `isonim/web/dom_api`,
# `viewmodel/views/isonim_flow_view` and Monaco bindings, so four patterns
# above catch it transitively.
#
# THAT ARGUMENT IS FALSE, and its own counter-example is already in the tree.
# `src/frontend/ui/flow_line_styles.nim` has zero imports too, and exports
#
#     const FlowLineHitClass* = "line-flow-hit"
#     func flowLineStyleClass*(kind: FlowLineStyleKind): string
#
# — its docstring calls itself "the decision that turns a loaded flow window
# into one inline CSS class per source line". §3.2's first row bans "any
# rendering, ANY CSS, any component". An import-graph rule cannot see it,
# precisely BECAUSE it has no imports: it presents to the graph exactly as
# `flow_loop_math` does. And it is one `import` away from this graph, since
# `viewmodels/flow_vm.nim` already imports its sibling from that directory.
# The same holds for `trace_redraw_policy` and `editor_decoration_layers`:
# zero imports, and presentation policy rather than arithmetic.
#
# So the path stays banned and the exemption is per-module, by exact name, in
# UI_PATH_ALLOWLIST above. The point of an allowlist rather than a softened
# rule is that a SECOND exemption is a visible review event — someone has to
# write down which `ui/` module they are pulling into an embeddable,
# render-free package, and why. A correction one module wide gets a fix one
# module wide.

# Chain concepts. §3.2's last row bans "transaction, block, chain id,
# generation" from this package outright.
#
# The tokens below are chain-SPECIFIC spellings, matched case-insensitively as
# whole words. Three deliberate exclusions, because a lint that cries wolf gets
# switched off:
#
#   * bare `chain` is NOT a token. `origin_chain_vm` / `CrossProcessSpan` are
#     Value Origin Tracking chains — a chain of *causes*, not of blocks.
#   * bare `block` is NOT a token. `BlockSource` is spec §3.1's own name for
#     the custom trace-source escape hatch, and a block is a byte range of a
#     CTFS container.
#   * bare `generation` is NOT a token, because `sourceGeneration` /
#     `sourceDigest` are recompilation identity (store/types.nim) and predate
#     this rule by a long way. `chainGeneration` is a token.
#
# What is left is unambiguous: nothing in a debugger over a trace has a
# reason to say `blockNumber`.
CHAIN_TOKENS=(
	"chainid"
	"chain_id"
	"chaingeneration"
	"chain_generation"
	"blocknumber"
	"block_number"
	"blockhash"
	"block_hash"
	"blockheight"
	"block_height"
	"blocktimestamp"
	"blockexplorer"
	"blocktracer"
	"txhash"
	"tx_hash"
	"transactionhash"
	"transaction_hash"
	"transactionindex"
	"transaction_index"
	"transactionreceipt"
)

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
list_graph=0
# Whether we are checking THIS repository, as opposed to one of the synthetic
# trees ci/test/sdk-facade-boundary-test.sh builds. A synthetic tree has no
# sibling packages and needs none; the real repo does, and the difference is
# what keeps `graph-walks-siblings` from being either vacuous or impossible.
root_is_repo=1
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		shift
		root="$1"
		root_is_repo=0
		;;
	--list-graph)
		# Print the facade's transitive import graph and exit. For working out
		# WHICH edge dragged a forbidden module in, and for checking this
		# script's lexical resolution against `nim c --genDeps`.
		list_graph=1
		;;
	*)
		echo "sdk-facade-boundary.sh: unknown argument '$1'" >&2
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

violation_detail() {
	echo "              $1"
}

# WHERE `nim_imports` PUTS THE SPECS IT REFUSES TO ANALYSE.
#
# It cannot report them itself: every call site reads it through a process
# substitution, so it runs in a subshell and cannot touch `failures`. A file is
# the one channel that crosses that boundary, and it is read once, below the
# checks, where a finding can still be turned into a non-zero exit.
#
# Empty is the normal case and costs no check line — see the `import-specs-
# analysable` block near the verdict for why this is an abort condition rather
# than a standing check.
#
# The log is opened by the library that writes to it, so a caller cannot forget
# it and get the refusals in /dev/null instead.
nim_imports_open_unanalysable_log

# ui_path_exempt PATTERN ITEM — true when ITEM matched the `src/frontend/ui/`
# rule but is named in UI_PATH_ALLOWLIST. Exact paths only: a prefix or a glob
# would let the next module in silently, which is the whole thing this
# allowlist exists to prevent.
ui_path_exempt() {
	local pattern="$1" item="$2" allowed
	[ "${pattern}" = "${UI_PATH_PATTERN}" ] || return 1
	for allowed in "${UI_PATH_ALLOWLIST[@]}"; do
		[ "${item}" = "${allowed}" ] && return 0
	done
	return 1
}

# ---------------------------------------------------------------------------
# Nim import extraction — `nim_imports`, from ci/lib/nim-imports.sh
#
# THE EXTRACTOR IS SHARED, and that is a fix rather than a tidy-up. It lived
# here, and `ci/test/plugin-reactive-boundary.sh` was written with a second,
# independently derived copy that could not see nim's newline-continued
# `import` — measured, with the milestone's own exploit walking straight past
# the gate. The library's header carries the measurement and the rule it comes
# from (Verification-Harness-Traps §14, "one predicate, one function").
#
# Nothing about the function changed in the move: it is the same bytes, with
# `ci/test/sdk-facade-boundary-test.sh` and this script's own
# `import-specs-analysable` check grading it exactly as before.
# ---------------------------------------------------------------------------

# normpath PATH — collapse `.` and `..` textually. No filesystem access, so it
# works for paths that do not exist yet (which is what the synthetic-tree tests
# need).
normpath() {
	local p="$1" out=() part
	# An absolute input must stay absolute. The loop below drops empty
	# components, and the leading empty component of "/a/b" is what makes it
	# absolute — so without this the sibling-package paths came back relative,
	# every relative import inside IsoNim (`../core/clock`, `batch`, `graph`)
	# failed to resolve, and the walk silently entered only the modules that
	# happened to be reachable by absolute-root lookup.
	local lead=""
	case "${p}" in
	/*) lead="/" ;;
	esac
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
	local joined="${out[*]}"
	printf '%s' "${lead}${joined}"
}

# resolve_module SPEC IMPORTER_PATH — repo-relative path of the module SPEC
# resolves to, or empty when it is external (stdlib, isonim, a sibling
# package).
resolve_module() {
	local spec="$1" importer="$2"
	case "${spec}" in
	std/* | system | macros | unittest) return 0 ;;
	esac
	local dir candidate
	dir="$(dirname "${importer}")"
	candidate="$(normpath "${dir}/${spec}.nim")"
	if [ -f "${candidate}" ]; then
		printf '%s' "${candidate}"
		return 0
	fi
	case "${spec}" in
	./* | ../*) return 0 ;;
	esac
	local r
	# The repo-relative search roots apply ONLY to importers inside this repo.
	#
	# Applying them to a sibling package's file is not a nuance, it is a wrong
	# answer with a worked example: `isonim/viewmodel.nim` imports `vscode`,
	# and resolving that against `src/frontend/` yields
	# `src/frontend/vscode.nim` — an Electron/VS Code bridge full of `txHash`.
	# The walk then reported three chain-token violations in modules the facade
	# does not depend on at all. A sibling resolves against its own directory
	# and the sibling roots, exactly as `nim` would with that package's own
	# `--path` set.
	if [ "${importer#/}" = "${importer}" ]; then
		for r in "${SEARCH_ROOTS[@]}"; do
			candidate="$(normpath "${r}/${spec}.nim")"
			if [ -f "${candidate}" ]; then
				printf '%s' "${candidate}"
				return 0
			fi
		done
	fi
	# Sibling packages last, and only for specs that actually name one, so a
	# stdlib or unknown spec is still reported as external rather than being
	# probed against every sibling on disk.
	for r in "${SIBLING_ROOTS[@]}"; do
		candidate="${r}/${spec}.nim"
		if [ -f "${candidate}" ]; then
			printf '%s' "${candidate}"
			return 0
		fi
	done
	return 0
}

# resolve_sibling_roots — populate SIBLING_ROOTS / SIBLING_MISSING from
# SIBLING_PACKAGES. Absolute paths, because these are outside the repo.
resolve_sibling_roots() {
	SIBLING_ROOTS=()
	SIBLING_MISSING=()
	local entry name probe envvar fallback base override
	for entry in "${SIBLING_PACKAGES[@]}"; do
		IFS='|' read -r name probe envvar fallback <<<"${entry}"
		base=""
		override="${!envvar:-}"
		if [ -n "${override}" ] && [ -f "${override}/${probe}" ]; then
			base="${override}"
		elif [ -f "${fallback}/${probe}" ]; then
			base="$(cd "${fallback}" && pwd)"
		fi
		if [ -n "${base}" ]; then
			SIBLING_ROOTS+=("${base}")
		else
			SIBLING_MISSING+=("${name} (set ${envvar}, or check out beside this repo)")
		fi
	done
}

# closure_of FILE — every repo file reachable from FILE by imports, one per
# line, including FILE itself. External specs are reported separately by
# external_specs_of.
closure_of() {
	local start="$1"
	local -a queue=("${start}")
	local -A seen=(["${start}"]=1)
	local cur spec resolved
	while [ "${#queue[@]}" -gt 0 ]; do
		cur="${queue[0]}"
		queue=("${queue[@]:1}")
		printf '%s\n' "${cur}"
		while read -r spec; do
			[ -n "${spec}" ] || continue
			resolved="$(resolve_module "${spec}" "${cur}")"
			[ -n "${resolved}" ] || continue
			if [ -z "${seen[${resolved}]+x}" ]; then
				seen["${resolved}"]=1
				queue+=("${resolved}")
			fi
		done < <(nim_imports "${cur}")
	done
}

# external_specs_of FILES... — the module specs reached from a set of files
# that do not resolve inside the repo. These are what a forbidden-module rule
# has to match for `karax`, `isonim/ui` and friends.
external_specs_of() {
	local f spec
	for f in "$@"; do
		while read -r spec; do
			[ -n "${spec}" ] || continue
			if [ -z "$(resolve_module "${spec}" "${f}")" ]; then
				printf '%s\n' "${spec}"
			fi
		done < <(nim_imports "${f}")
	done | sort -u
}

# ---------------------------------------------------------------------------
# Consumer discovery
# ---------------------------------------------------------------------------

# all_nim_files — every tracked or newly-added .nim file, repo-relative.
# Enumeration goes through git for the same three reasons
# ci/test/test-lane-coverage.sh does it: vendored `libs/` submodules, recorded
# example traces and build output are all outside this repo's index.
all_nim_files() {
	{
		git ls-files '*.nim' 2>/dev/null
		git ls-files --others --exclude-standard '*.nim' 2>/dev/null
	} | sort -u
}

# consumer_files — every declared consumer .nim file, repo-relative.
#
# Both marker spellings, resolved in bulk rather than file-by-file: one grep
# for the header marker, and one prefix match per `.sdk-consumer` directory.
consumer_files() {
	local list header_hits marker d
	list="$(mktemp)"
	all_nim_files >"${list}"
	{
		# a. Header marker. `grep -l` narrows to candidates; the
		#    ${MARKER_SCAN_LINES} window is then applied to each, so a
		#    mention buried in the middle of a file does not count.
		if [ -s "${list}" ]; then
			header_hits="$(tr '\n' '\0' <"${list}" |
				xargs -0 grep -lE '^[[:space:]]*##[[:space:]]*SDK-CONSUMER:' 2>/dev/null)"
			while read -r f; do
				[ -n "${f}" ] || continue
				if head -n "${MARKER_SCAN_LINES}" "${f}" 2>/dev/null |
					grep -qE '^[[:space:]]*##[[:space:]]*SDK-CONSUMER:'; then
					printf '%s\n' "${f}"
				fi
			done <<<"${header_hits}"
		fi
		# b. Directory marker, covering the whole subtree beneath it.
		while read -r marker; do
			[ -n "${marker}" ] || continue
			d="$(dirname "${marker}")"
			if [ "${d}" = "." ]; then
				cat "${list}"
			else
				grep -E "^${d}/" "${list}" || true
			fi
		done < <(find . -name .sdk-consumer -not -path './.git/*' 2>/dev/null | sed 's|^\./||')
	} | sort -u
	rm -f "${list}"
}

# ---------------------------------------------------------------------------
# Check 1: the facade exists and knows its own name
# ---------------------------------------------------------------------------

# Resolved here, after the helpers above are defined and after `cd "${root}"`,
# because the fallback paths are relative to the tree being checked, and BEFORE
# the --list-graph early exit so that the printed graph is the same graph the
# checks below run on.
resolve_sibling_roots

if [ "${list_graph}" -eq 1 ]; then
	mapfile -t graph < <(closure_of "${FACADE_REL}" | sort -u)
	printf '%s\n' "${graph[@]}"
	external_specs_of "${graph[@]}" | sed 's/^/external: /'
	exit 0
fi

echo "=== SDK facade boundary (CodeTracer-Embed-SDK.md §3.2, Client-SDK.md §1.1) ==="

facade_ok=0
if [ ! -f "${FACADE_REL}" ]; then
	check_failed "facade-present"
	violation_detail "${FACADE_REL} does not exist — the SDK has no public surface"
elif ! grep -q "CodeTracerEmbedFacadeModule\* = \"${FACADE_MODULE}\"" "${FACADE_REL}"; then
	check_failed "facade-present"
	violation_detail "${FACADE_REL} does not declare CodeTracerEmbedFacadeModule* = \"${FACADE_MODULE}\";"
	violation_detail "the facade file and the name this guard enforces have drifted apart"
else
	check_ok "facade-present"
	facade_ok=1
fi

# ---------------------------------------------------------------------------
# Checks 2 and 3: the SDK's own graph
# ---------------------------------------------------------------------------

if [ "${facade_ok}" -eq 1 ]; then
	mapfile -t sdk_closure < <(closure_of "${FACADE_REL}" | sort -u)
	mapfile -t sdk_externals < <(external_specs_of "${sdk_closure[@]}")

	echo "  (facade graph: ${#sdk_closure[@]} modules, ${#sdk_externals[@]} external specs)"

	# The walk must actually have left the repository. A missing sibling would
	# otherwise silently restore the old, weaker meaning of every rule below —
	# "no renderer in codetracer" instead of "no renderer anywhere the facade
	# reaches" — while still printing OK, which is the precise failure mode
	# this whole file exists to prevent one level down.
	if [ "${root_is_repo}" -eq 1 ]; then
		if [ "${#SIBLING_MISSING[@]}" -gt 0 ]; then
			check_failed "graph-walks-siblings"
			for miss in "${SIBLING_MISSING[@]}"; do
				violation_detail "cannot locate sibling package: ${miss}"
			done
			violation_detail "Both are REQUIRED siblings (scripts/require-siblings.sh), so this is a"
			violation_detail "broken workspace rather than an optional extra. Without them the graph"
			violation_detail "stops at this repo's edge and the rules below assert much less than"
			violation_detail "they appear to."
		else
			sibling_modules=0
			for item in "${sdk_closure[@]}"; do
				case "${item}" in
				/*) sibling_modules=$((sibling_modules + 1)) ;;
				esac
			done
			if [ "${sibling_modules}" -eq 0 ]; then
				check_failed "graph-walks-siblings"
				violation_detail "the sibling roots resolved but the walk entered none of them."
				violation_detail "The facade imports isonim/core/* directly, so zero means the"
				violation_detail "resolver stopped working, not that the dependency went away."
			else
				check_ok "graph-walks-siblings (${sibling_modules} module(s) outside this repo)"
			fi
		fi
	fi

	render_violations=0
	for entry in "${FORBIDDEN_PATTERNS[@]}"; do
		pattern="${entry%%;*}"
		reason="${entry#*;}"
		for item in "${sdk_closure[@]}" "${sdk_externals[@]}"; do
			if grep -qE "${pattern}" <<<"${item}"; then
				ui_path_exempt "${pattern}" "${item}" && continue
				render_violations=$((render_violations + 1))
				violation_detail "${item} — ${reason}"
				if [ "${pattern}" = "${UI_PATH_PATTERN}" ]; then
					violation_detail "  If this module is genuinely free of rendering, CSS, components and"
					violation_detail "  layout, the remedy is to add its exact path to UI_PATH_ALLOWLIST in"
					violation_detail "  ci/test/sdk-facade-boundary.sh with the reason — NOT to widen or drop"
					violation_detail "  the rule. Zero imports is not evidence: ui/flow_line_styles.nim has"
					violation_detail "  zero imports and exports CSS class names."
				fi
			fi
		done
	done
	if [ "${render_violations}" -eq 0 ]; then
		check_ok "facade-graph-no-rendering (spec §3.2 rows 1-2; M2a test_replay_core_has_no_render_dependencies)"
	else
		check_failed "facade-graph-no-rendering: ${render_violations} forbidden module(s) reachable from the facade"
	fi

	# Comment lines are excluded from the chain scan. A comment has no ABI and
	# no behaviour, and the SDK's own modules must be able to cite
	# Client-SDK.md and name BlockTracer as the consumer on the other side of
	# the boundary — that citation is how a maintainer learns the rule. A
	# chain concept that reached the code would still be caught, because the
	# field, type or call carrying it is not a comment.
	chain_violations=0
	for token in "${CHAIN_TOKENS[@]}"; do
		while read -r hit; do
			[ -n "${hit}" ] || continue
			chain_violations=$((chain_violations + 1))
			violation_detail "${hit}"
			violation_detail "  '${token}' is a chain concept; spec §3.2's last row bans it from this package."
			violation_detail "  Resolving a chain's data to a trace belongs one layer up, in Client-SDK.md."
		done < <(grep -rinE "(^|[^a-zA-Z0-9_])${token}([^a-zA-Z0-9_]|$)" "${sdk_closure[@]}" 2>/dev/null |
			awk -F: '{ rest = $0; sub(/^[^:]*:[0-9]+:/, "", rest); if (rest !~ /^[ \t]*#/) print }' |
			head -20)
	done
	if [ "${chain_violations}" -eq 0 ]; then
		check_ok "facade-graph-no-chain-concept (spec §3.2, last row)"
	else
		check_failed "facade-graph-no-chain-concept: ${chain_violations} chain reference(s) in the SDK graph"
	fi
fi

# ---------------------------------------------------------------------------
# Check 4: declared consumers reach the SDK only through the facade
# ---------------------------------------------------------------------------

mapfile -t consumers < <(consumer_files)

consumer_violations=0
for c in "${consumers[@]}"; do
	while read -r spec; do
		[ -n "${spec}" ] || continue
		resolved="$(resolve_module "${spec}" "${c}")"
		[ -n "${resolved}" ] || continue
		case "${resolved}" in
		"${SDK_SUBTREE}"/*) ;;
		*) continue ;;
		esac
		[ "${resolved}" = "${FACADE_REL}" ] && continue
		# The narrowed surface a plugin consumes. See PLUGIN_SURFACE_REL above
		# for why admitting it changes nothing else about this guard.
		[ "${resolved}" = "${PLUGIN_SURFACE_REL}" ] && continue
		consumer_violations=$((consumer_violations + 1))
		violation_detail "${c} imports '${spec}' -> ${resolved}"
		violation_detail "  That is an SDK internal. A consumer may import '${FACADE_MODULE}', or"
		violation_detail "  '${PLUGIN_SURFACE_MODULE}' if it is a plugin, and nothing else here."
		violation_detail "  Spec §7: anything not exported from the facade is private, and an"
		violation_detail "  internal refactor that does not change the facade is not a breaking change."
	done < <(nim_imports "${c}")
done

if [ "${#consumers[@]}" -eq 0 ]; then
	check_failed "consumer-declared: no file declares itself an SDK consumer"
	violation_detail "This guard would pass vacuously. At least the SDK's own conformance"
	violation_detail "suite must be a declared consumer, or the outward half of the boundary"
	violation_detail "is being asserted about nobody."
elif [ "${consumer_violations}" -eq 0 ]; then
	check_ok "consumer-facade-only: ${#consumers[@]} declared consumer file(s), no reach past the facade"
else
	check_failed "consumer-facade-only: ${consumer_violations} import(s) past the facade"
fi

# ---------------------------------------------------------------------------
# Check 5: the TUI's declared half is declared, and its exempt half is exempt
#
# Repo-specific, so it is skipped for the synthetic trees
# ci/test/sdk-facade-boundary-test.sh builds — those have no TUI, and a check
# that failed on them would be asserting something about the harness rather
# than about the boundary. See the TUI_CONSUMER_DIR / TUI_EXEMPT_DIR block
# above for what this is and why the exemption is checked rather than assumed.
# ---------------------------------------------------------------------------

if [ "${root_is_repo}" -eq 1 ] && [ -d "${TUI_CONSUMER_DIR}" ]; then
	tui_app_consumers=0
	tui_host_consumers=0
	for c in "${consumers[@]}"; do
		case "${c}" in
		"${TUI_CONSUMER_DIR}"/*) tui_app_consumers=$((tui_app_consumers + 1)) ;;
		"${TUI_EXEMPT_DIR}"/*) tui_host_consumers=$((tui_host_consumers + 1)) ;;
		esac
	done
	# The POSITIVE half first. `tui_host_consumers -eq 0` is satisfied for free
	# by a marker that stopped being discovered at all — the same empty-set
	# pass this file's own consumer check guards against — so the two are
	# asserted together and the positive one is what fails when discovery
	# breaks.
	if [ "${tui_app_consumers}" -eq 0 ]; then
		check_failed "tui-layers: ${TUI_CONSUMER_DIR} declares no SDK consumer"
		violation_detail "Expected a '.sdk-consumer' marker covering that tree (CTUI-0)."
		violation_detail "Without it the TUI's app/ layer is outside this guard entirely,"
		violation_detail "and the only thing keeping it inside the facade is review."
	elif [ "${tui_host_consumers}" -ne 0 ]; then
		check_failed "tui-layers: ${tui_host_consumers} file(s) under ${TUI_EXEMPT_DIR} are declared consumers"
		violation_detail "That directory is EXEMPT by design: it is the only place allowed to"
		violation_detail "import backend/stdio_backend and viewmodel/headless_session, which the"
		violation_detail "facade deliberately withholds. Declaring it a consumer cannot be"
		violation_detail "satisfied — the remedy is to remove the marker that covers it, most"
		violation_detail "likely one placed at src/frontend/tui/ rather than at app/."
	else
		check_ok "tui-layers: ${tui_app_consumers} consumer file(s) under ${TUI_CONSUMER_DIR}, ${TUI_EXEMPT_DIR} exempt"
	fi
fi

# ---------------------------------------------------------------------------
# import-specs-analysable — the extractor met something it will not guess at
#
# REPORTED ONLY WHEN IT HAPPENS, and that is the intent rather than a shortcut.
# This is not a property of the SDK boundary, which is what the numbered checks
# above are about; it is the extractor beneath them saying it could not read a
# statement. Every one of those checks silently assumed it could. So it is
# raised where it belongs — as a failure that makes the whole run red — and is
# invisible on the overwhelmingly normal path where no such spec exists.
#
# The alternative, emitting the raw text of the spec, is what makes this worth
# a rule: `import "a\x2Fb\x2Fc"` compiles and imports `a/b/c`, and a guard that
# printed `a\x2Fb\x2Fc` would match no forbidden pattern, resolve to no file
# and report nothing. That is a MISS, and a miss is the one outcome a boundary
# lint may not produce quietly.
# ---------------------------------------------------------------------------

if [ -s "${IMPORT_UNANALYSABLE_LOG}" ]; then
	# DEDUPLICATED, because the log is APPENDED PER `nim_imports` CALL and the
	# checks above deliberately overlap: a file can be walked as part of the
	# facade's closure AND as a declared consumer, and `external_specs_of` walks
	# the closure a second time. One refused statement in
	# `src/frontend/viewmodel/codetracer_embed.nim` therefore reported
	# "2 import spec(s)" with the same line printed twice — an over-count, not a
	# miss, but a reader has no way to tell those apart from the output. Nothing
	# asserts on the number, so `sort -u` at the read site is the whole fix.
	mapfile -t unanalysable_entries < <(sort -u "${IMPORT_UNANALYSABLE_LOG}")
	check_failed "import-specs-analysable: ${#unanalysable_entries[@]} import statement(s) could not be read lexically"
	for unanalysable_entry in "${unanalysable_entries[@]}"; do
		IFS=$'\t' read -r unanalysable_file unanalysable_spec <<<"${unanalysable_entry}"
		[ -n "${unanalysable_file}" ] || continue
		violation_detail "${unanalysable_file}: ${unanalysable_spec}"
	done
	violation_detail "This guard is LEXICAL, and two shapes cannot be read that way:"
	violation_detail '  * a spec containing a backslash carries Nim string escapes —'
	violation_detail '    import "a\x2Fb" is an import of a/b — and decoding them WRONGLY'
	violation_detail "    would hide an import rather than over-report one;"
	violation_detail "  * an import statement running into, or resuming after, a"
	violation_detail "    multi-line block comment. Cross-line comment state is not"
	violation_detail "    tracked here, because a block-comment opener inside a"
	violation_detail "    multi-line string literal would then swallow the file;"
	violation_detail "  * a one-line when/elif/else that plainly carries an import"
	violation_detail "    which this scan could not read out of it. The usual cause"
	violation_detail "    is a character literal in the condition holding a hash, a"
	violation_detail "    semicolon or a double-quote."
	violation_detail "Everything above this in the run assumed the extractor could read"
	violation_detail "every statement, so the run is red rather than quietly incomplete."
	violation_detail "Remedy: write the import in its plain form, on a line of its own."
fi

# ---------------------------------------------------------------------------
# Verdict
# ---------------------------------------------------------------------------

echo "--- ${checks_run} check(s), ${failures} failing"
if [ "${failures}" -gt 0 ]; then
	exit 1
fi
exit 0
