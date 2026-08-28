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

# Where an unqualified module spec is looked up, after the importing file's own
# directory. Mirrors the `--path` entries the ViewModel lanes compile with
# (ci/lib/test-lane-files.sh `test_lane_extra_flags`) plus config.nims.
SEARCH_ROOTS=("${SDK_SUBTREE}" "src/frontend" "src" ".")

# How far into a file the `## SDK-CONSUMER:` header marker may appear.
MARKER_SCAN_LINES=40

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
while [ $# -gt 0 ]; do
	case "$1" in
	--root)
		shift
		root="$1"
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
# ---------------------------------------------------------------------------

nim_imports() {
	[ -f "$1" ] || return 0
	awk '
	function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
	function count(s, ch,   n, i) {
		n = 0
		for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
		return n
	}
	function emit_spec(spec) {
		spec = trim(spec)
		sub(/[ \t]+as[ \t]+.*$/, "", spec)
		spec = trim(spec)
		if (spec != "") print spec
	}
	function emit_list(body,   depth, i, ch, item, pre, inner, n, parts, j) {
		# Split on top-level commas (commas outside [ ]).
		depth = 0; item = ""
		body = body ","
		for (i = 1; i <= length(body); i++) {
			ch = substr(body, i, 1)
			if (ch == "[") depth++
			else if (ch == "]") depth--
			if (ch == "," && depth == 0) {
				item = trim(item)
				if (item != "") {
					if (item ~ /\[.*\]$/) {
						# `std / [a, b]` and `a/[b, c]` are the same
						# statement with different whitespace habits, so
						# trim before AND after dropping the separator.
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
	function flush(stmt,   p) {
		if (stmt ~ /^from[ \t]/) {
			sub(/^from[ \t]+/, "", stmt)
			p = index(stmt, " import ")
			if (p > 0) stmt = substr(stmt, 1, p - 1)
		} else {
			sub(/^import[ \t]+/, "", stmt)
			sub(/^include[ \t]+/, "", stmt)
		}
		sub(/[ \t]+except[ \t]+.*$/, "", stmt)
		emit_list(stmt)
	}
	{
		line = $0
		# Strip a trailing comment. Import statements never carry a `#`
		# inside a string, so this is safe for the lines we act on, and a
		# mangled non-import line simply fails the prefix test below.
		h = index(line, "#")
		if (h > 0) line = substr(line, 1, h - 1)
		t = trim(line)
		if (collecting == 0) {
			# A bare `import` on its own line is the other common spelling
			# in this repo (src/frontend/ui/flow.nim opens that way); the
			# module list follows on the indented lines beneath it.
			if (t ~ /^import[ \t]/ || t ~ /^from[ \t]/ || t ~ /^include[ \t]/ ||
			    t == "import" || t == "include") {
				buf = t
				collecting = 1
			} else {
				next
			}
		} else {
			if (t == "") next
			buf = buf " " t
		}
		if (buf ~ /^(import|from|include)$/) next
		if (count(buf, "[") == count(buf, "]") && buf !~ /,$/ && buf !~ /\[$/) {
			flush(buf)
			collecting = 0
			buf = ""
		}
	}
	END { if (collecting == 1) flush(buf) }
	' "$1"
}

# normpath PATH — collapse `.` and `..` textually. No filesystem access, so it
# works for paths that do not exist yet (which is what the synthetic-tree tests
# need).
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
	local joined="${out[*]}"
	printf '%s' "${joined}"
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
	for r in "${SEARCH_ROOTS[@]}"; do
		candidate="$(normpath "${r}/${spec}.nim")"
		if [ -f "${candidate}" ]; then
			printf '%s' "${candidate}"
			return 0
		fi
	done
	return 0
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

	echo "  (facade graph: ${#sdk_closure[@]} repo modules, ${#sdk_externals[@]} external specs)"

	render_violations=0
	for entry in "${FORBIDDEN_PATTERNS[@]}"; do
		pattern="${entry%%;*}"
		reason="${entry#*;}"
		for item in "${sdk_closure[@]}" "${sdk_externals[@]}"; do
			if printf '%s' "${item}" | grep -qE "${pattern}"; then
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
		consumer_violations=$((consumer_violations + 1))
		violation_detail "${c} imports '${spec}' -> ${resolved}"
		violation_detail "  That is an SDK internal. A consumer may import only '${FACADE_MODULE}'."
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
# Verdict
# ---------------------------------------------------------------------------

echo "--- ${checks_run} check(s), ${failures} failing"
if [ "${failures}" -gt 0 ]; then
	exit 1
fi
exit 0
