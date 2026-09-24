#!/usr/bin/env bash
#
# editor-import-closure.sh — PLAT-29's verification gate: THE EDITOR MODEL'S
# TRANSITIVE IMPORT CLOSURE CONTAINS NO ASYNC, NO I/O, NO PROCESS, NO SOCKET
# AND NO CLOCK.
#
# WHY THIS EXISTS, AND WHY IT IS A CLOSURE RATHER THAN A SCAN
# -----------------------------------------------------------
# codetracer-specs/Architecture/Editor-ViewModel.md §11: *"The model never
# waits. It has no `Future`, no callback, no clock."* Until this milestone that
# claim was checked, where it was checked at all, by a TEXT SCAN over the
# editor modules' own source.
#
# **A scan over a module's own text cannot see an `await` reached through a
# transitive import.** One module of indirection defeats it completely, and
# that is not a hypothetical: `plugin-reactive-boundary.sh` shipped with
# exactly that bound and PLAT-7 measured a helper-module escape walking past it
# with the gate printing `15 checks, 0 failing`. The repair there was to bind
# the closure; this is the same repair for a different subject.
#
# THE SCANNER IS NOT A NEW ONE, AND THAT IS THE POINT
# --------------------------------------------------
# PLAT-29's own milestone text: *"PLAT-8's allow-list check is the instrument,
# and the six routes past it that PLAT-7's five verification passes found — a
# newline-continued import, a block comment, the module-qualified spelling
# `export … except` cannot filter, nim's foreign-function pragmas, and the call
# site rather than the rendering — are ALREADY CLOSED there. Writing a new
# scanner re-opens all six."*
#
# So the import extractor here is `nim_imports` from `ci/lib/nim-imports.sh`,
# unmodified, sourced — the same function `plugin-reactive-boundary.sh` and
# `sdk-facade-boundary.sh` call. Every route that library closes is closed here
# for free, and `test_editor_async_closure.nim` plants each of them against a
# synthetic tree and requires this gate to redden.
#
# WHAT IS SHARED AND WHAT IS NOT, stated rather than implied
# ---------------------------------------------------------
#   SHARED  `nim_imports` (ci/lib/nim-imports.sh) — the extractor, where all
#           six routes live.
#   SHARED  `normpath` (ci/lib/nim-closure.sh) — hoisted 2026-09-23. It
#           was a THIRD copy until then (PLAT-29's verification pass found
#           this entry claiming a hoist that had not happened); both older
#           gates now source it and carry no copy of their own.
#   NOT     the table parser, the stdlib-spec test and the BFS. Four functions
#           in `plugin-reactive-boundary.sh` have mutation arms quoting their
#           bodies (P31, A1, A7 in PLAT-8's harness; G9, G10, G11 in PLAT-7's),
#           so hoisting them re-aims six arms across two harnesses, and §32a
#           requires a re-aimed arm to be RE-RUN rather than only re-recorded.
#           The measurement is in `ci/lib/nim-closure.sh`'s header and the
#           residual is recorded in PLAT-29's status.
#
# THE TABLES ARE READ, NEVER TRANSCRIBED
# --------------------------------------
# The allow-list, the denied identifiers and the denied FFI pragmas live in Nim
# — `src/common/editor_core_admission.nim` and
# `src/common/plugin_model/source_admission.nim` — and are parsed out of those
# files at run time, by the name the Nim module publishes. A rename that did
# not carry this gate with it leaves the parse empty, and an empty allow-list
# refuses every module loudly rather than admitting one silently. Check 0 is
# what makes that true rather than hopeful.
#
# USAGE
#   bash ci/test/editor-import-closure.sh
#   bash ci/test/editor-import-closure.sh --editor-dir=DIR [--search-root=DIR]…
#   bash ci/test/editor-import-closure.sh --list-closure
#
# `--editor-dir` and `--search-root` exist for the contract suite, which builds
# a synthetic tree per planted route. They do not change what is checked; they
# change what is checked OVER.

set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}" || exit 1

# THE EXTRACTOR, SOURCED RATHER THAN RE-DERIVED — see the header. SC1091 is
# disabled for the reason `ci/lint/nim.sh` gives and the two sibling gates
# repeat: the pre-commit hook runs shellcheck WITHOUT `-x` and cannot follow
# the file at all.
# shellcheck source=ci/lib/nim-imports.sh disable=SC1091
. "${root}/ci/lib/nim-imports.sh"
# shellcheck source=ci/lib/nim-closure.sh disable=SC1091
. "${root}/ci/lib/nim-closure.sh"

ADMISSION_REL="src/common/editor_core_admission.nim"
FFI_REL="src/common/plugin_model/source_admission.nim"
ALLOW_CONST="EditorCoreAllowedStdlibModules"
DENIED_CONST="EditorCoreDeniedNames"
FFI_CONST="PluginDeniedFfiPragmas"

EDITOR_DIR="src/frontend/viewmodel/editor"
SEARCH_ROOTS=()
LIST_ONLY=0

# Sibling PACKAGE roots. The editor model imports `isonim_tui/text/width` — the
# grapheme segmenter the entire coordinate model rests on — so a walk that
# stopped at this repository's boundary would be checking a closure with its
# most load-bearing dependency cut out of it. `sdk-facade-boundary.sh` records
# the same argument for IsoNim: *"a dependency on someone else's cadence is
# exactly the one a lint has to hold."*
#
# Each entry is `<name>|<probe>|<env-override>|<fallback>`.
SIBLING_PACKAGES=(
	"isonim-tui|isonim_tui/text/width.nim|ISONIM_TUI_SRC|../isonim-tui/src"
	"isonim|isonim/core/signals.nim|ISONIM_SRC|../isonim/src"
	"nim-everywhere|nim_everywhere/async_compat.nim|NIM_EVERYWHERE_SRC|../nim-everywhere/src"
)
SIBLING_ROOTS=()
SIBLING_MISSING=()

while [ $# -gt 0 ]; do
	case "$1" in
	--editor-dir=*)
		EDITOR_DIR="${1#*=}"
		shift
		;;
	--search-root=*)
		SEARCH_ROOTS+=("${1#*=}")
		shift
		;;
	--admission=*)
		ADMISSION_REL="${1#*=}"
		shift
		;;
	--list-closure)
		LIST_ONLY=1
		shift
		;;
	-h | --help)
		sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	*)
		echo "ERROR: unknown argument: $1" >&2
		exit 2
		;;
	esac
done

if [ "${#SEARCH_ROOTS[@]}" -eq 0 ]; then
	# Mirrors the `--path` entries the ViewModel lanes compile with
	# (ci/lib/test-lane-files.sh `test_lane_extra_flags`) plus config.nims.
	SEARCH_ROOTS=("src/frontend/viewmodel" "src/frontend" "src" ".")
fi

nim_imports_open_unanalysable_log

checks=0
failures=0

check_ok() {
	checks=$((checks + 1))
	echo "OK  $1"
}

check_failed() {
	checks=$((checks + 1))
	failures=$((failures + 1))
	echo "VIOLATION $1"
}

detail() { echo "              $1"; }

# ---------------------------------------------------------------------------
# Table parsing. ONE awk program over every table, by the const name the Nim
# module publishes.
# ---------------------------------------------------------------------------
table_names() {
	local file="$1" const_name="$2"
	[ -f "${file}" ] || return 0
	awk -v const_name="${const_name}" '
	$0 ~ ("^[[:space:]]*" const_name "\\*?[[:space:]]*[:*]") { inside = 1; next }
	inside && /^[[:space:]]*\]/ { inside = 0 }
	inside {
		if (match($0, /\("[A-Za-z_][A-Za-z0-9_\/]*"/)) {
			print substr($0, RSTART + 2, RLENGTH - 3)
		}
	}
	' "${file}" | sort -u
}

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
			SIBLING_MISSING+=("${name} (set ${envvar}, or check it out beside this repo)")
		fi
	done
}
resolve_sibling_roots

# resolve_module SPEC IMPORTER — the file SPEC resolves to, or empty.
#
# Repo-relative roots apply only to importers inside this repository: a sibling
# package resolves against its own directory and the sibling roots, exactly as
# `nim` would with that package's own `--path` set. Applying this repository's
# roots to a sibling's file is not a nuance, it is a wrong answer — the
# sdk-facade gate records the worked example.
resolve_module() {
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
	if [ "${importer#/}" = "${importer}" ]; then
		for r in "${SEARCH_ROOTS[@]}"; do
			candidate="$(normpath "${r}/${spec}.nim")"
			if [ -n "${candidate}" ] && [ -f "${candidate}" ]; then
				printf '%s' "${candidate}"
				return 0
			fi
		done
	fi
	for r in "${SIBLING_ROOTS[@]}"; do
		candidate="${r}/${spec}.nim"
		if [ -f "${candidate}" ]; then
			printf '%s' "${candidate}"
			return 0
		fi
	done
	return 0
}

is_stdlib_spec() {
	case "$1" in
	std/* | system) return 0 ;;
	esac
	return 1
}

# editor_closure ROOT... — every module reachable from the ROOTs by import.
#
# TERMINATION: `seen` is keyed on the resolved path, every file is enqueued at
# most once, and the set a path can resolve to is finite because
# `resolve_module` only ever returns a candidate that satisfies `[ -f … ]`. A
# cycle costs one visit.
editor_closure() {
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
			resolved="$(resolve_module "${spec}" "${cur}")"
			[ -n "${resolved}" ] || continue
			if [ -z "${seen[${resolved}]+x}" ]; then
				seen["${resolved}"]=1
				queue+=("${resolved}")
			fi
		done < <(nim_imports "${cur}")
	done
}

# code_lines FILE — FILE with comments removed. Every module in this closure
# DISCUSSES `await`, clocks and file reads in its header — `reconcile.nim`'s
# own doc comment names six of the denied identifiers — so a scanner that could
# not tell prose from code would be permanently red on the files that document
# the rule. Check 5 asserts this discriminates.
code_lines() {
	sed -e 's/#\[.*\]#//g' -e 's/[[:space:]]*##\?.*$//' "$1" 2>/dev/null
}

identifier_pattern() {
	printf '(^|[^[:alnum:]_.])%s([^[:alnum:]_]|$)' "$1"
}

# pragma_spans FILE — the `{. … .}` spans of FILE's code lines, one per line.
# Matching the FFI names inside a pragma span rather than anywhere in the file
# is what keeps an ordinary variable called `header` from being a finding.
pragma_spans() {
	code_lines "$1" | grep -oE '\{\.[^}]*\.\}' || true
}

# ---------------------------------------------------------------------------
# The root set — THE DIRECTORY, not a list (§35), and ALL of it
#
# EVERY `.nim` UNDER THE EDITOR DIRECTORY, FOLLOWING SYMLINKS (`find -L`). Two
# ways the first spelling (`find -maxdepth 1 -type f`) was narrower than the
# sentence above were MEASURED by PLAT-29's verification pass on 2026-09-18
# against synthetic trees, and both are closed here and planted by
# `test_editor_async_closure.nim` (routes 8 and 9):
#
#   * `-type f` IS FALSE FOR A SYMLINK, so `editor/linked.nim ->
#     ../lib/sneaky.nim` carrying `import std/asyncdispatch` was never a root
#     and the gate was green. `-L` makes `-type f` true of a link to a file,
#     and descends into a symlinked directory too.
#   * `-maxdepth 1` stopped at the directory's own files, so a module under
#     `editor/<sub>/` reached only from OUTSIDE `editor/` was in neither the
#     root set nor the closure. The scope decision the pass left open —
#     whether `editor/<sub>/x.nim` is part of the model — is taken: a file in
#     the editor directory's tree is the model's, wherever it is imported
#     from. A module that is not the model's does not belong in that tree.
#
# `-L` cannot loop: `find` detects a symlink cycle and reports it rather than
# walking it (and the report goes to /dev/null with the rest of `find`'s
# stderr, so a cycle costs a skipped directory, never a hang).
# ---------------------------------------------------------------------------
roots=()
while IFS= read -r f; do
	[ -n "${f}" ] && roots+=("${f}")
done < <(find -L "${EDITOR_DIR}" -type f -name '*.nim' 2>/dev/null | sort)

mapfile -t closure < <(
	if [ "${#roots[@]}" -gt 0 ]; then editor_closure "${roots[@]}" | sort -u; fi
)

if [ "${LIST_ONLY}" -eq 1 ]; then
	printf '%s\n' "${closure[@]}"
	exit 0
fi

echo "editor-import-closure: root dir ${EDITOR_DIR}"
echo "              ${#roots[@]} root module(s), ${#closure[@]} in the closure"
if [ "${#SIBLING_MISSING[@]}" -gt 0 ]; then
	echo "              sibling packages NOT resolved: ${SIBLING_MISSING[*]}"
fi

# ---------------------------------------------------------------------------
# Check 0 — THE INSTRUMENT ITSELF, before anything is asserted with it.
#
# §4: a scan that matches nothing passes every "must not contain" check you
# write. Every population this gate ranges over is asserted non-empty FIRST,
# and each table is compared against the length its own Nim declaration states
# — `parsed == declared` is the property that characterises a working parser,
# and it holds for a synthetic three-row fixture and a real eighteen-row table
# alike.
# ---------------------------------------------------------------------------
mapfile -t allowed < <(table_names "${ADMISSION_REL}" "${ALLOW_CONST}")
mapfile -t denied_names < <(table_names "${ADMISSION_REL}" "${DENIED_CONST}")
mapfile -t denied_pragmas < <(table_names "${FFI_REL}" "${FFI_CONST}")
allow_declared="$(table_declared_len "${ADMISSION_REL}" "${ALLOW_CONST}")"
denied_declared="$(table_declared_len "${ADMISSION_REL}" "${DENIED_CONST}")"
pragma_declared="$(table_declared_len "${FFI_REL}" "${FFI_CONST}")"

vacuity_ok=1
[ "${#roots[@]}" -gt 0 ] || vacuity_ok=0
[ "${#closure[@]}" -ge "${#roots[@]}" ] || vacuity_ok=0
[ "${#allowed[@]}" -gt 0 ] || vacuity_ok=0
[ "${#denied_names[@]}" -gt 0 ] || vacuity_ok=0
[ "${#denied_pragmas[@]}" -gt 0 ] || vacuity_ok=0
[ "${#allowed[@]}" = "${allow_declared}" ] || vacuity_ok=0
[ "${#denied_names[@]}" = "${denied_declared}" ] || vacuity_ok=0
[ "${#denied_pragmas[@]}" = "${pragma_declared}" ] || vacuity_ok=0
if [ "${vacuity_ok}" -eq 1 ]; then
	check_ok "closure-instrument-is-non-vacuous: ${#roots[@]} root(s), ${#closure[@]} closure module(s), ${#allowed[@]}/${allow_declared} allow-list, ${#denied_names[@]}/${denied_declared} denied name(s), ${#denied_pragmas[@]}/${pragma_declared} denied pragma(s)"
else
	check_failed "closure-instrument-is-non-vacuous"
	detail "roots=${#roots[@]} closure=${#closure[@]}"
	detail "allow-list parsed ${#allowed[@]}, declared '${allow_declared}' in ${ADMISSION_REL}"
	detail "denied names parsed ${#denied_names[@]}, declared '${denied_declared}'"
	detail "denied pragmas parsed ${#denied_pragmas[@]}, declared '${pragma_declared}'"
	detail "A parse that came back empty satisfies every rule written over it (§4)."
fi

# ---------------------------------------------------------------------------
# Check 1 — every import in the closure RESOLVES or is standard library.
#
# An unresolvable spec is not a pass. It is a module this gate could not read,
# and a module it could not read is a module whose imports it did not check.
# ---------------------------------------------------------------------------
unreadable=()
for f in "${closure[@]}"; do
	while IFS= read -r spec; do
		[ -n "${spec}" ] || continue
		is_stdlib_spec "${spec}" && continue
		[ -n "$(resolve_module "${spec}" "${f}")" ] && continue
		unreadable+=("${f}: ${spec}")
	done < <(nim_imports "${f}")
done
if [ "${#unreadable[@]}" -eq 0 ]; then
	check_ok "closure-is-readable: every non-stdlib import in the closure resolves to a file"
else
	check_failed "closure-is-readable: ${#unreadable[@]} spec(s) could not be resolved"
	printf '              %s\n' "${unreadable[@]}"
	detail "A module this gate cannot read is a module whose imports it did not check."
fi

# ---------------------------------------------------------------------------
# Check 2 — THE ALLOW-LIST, over the whole closure.
# ---------------------------------------------------------------------------
unadmitted=()
for f in "${closure[@]}"; do
	while IFS= read -r spec; do
		[ -n "${spec}" ] || continue
		is_stdlib_spec "${spec}" || continue
		[ "${spec}" = "system" ] && continue
		ok=0
		for a in "${allowed[@]}"; do
			[ "${a}" = "${spec}" ] && ok=1 && break
		done
		[ "${ok}" -eq 1 ] && continue
		unadmitted+=("${f}: ${spec}")
	done < <(nim_imports "${f}")
done
if [ "${#unadmitted[@]}" -eq 0 ]; then
	check_ok "editor-core-imports-allow-listed: ${#closure[@]} module(s) in the closure, every std/ import on the list"
else
	check_failed "editor-core-imports-allow-listed: ${#unadmitted[@]} unadmitted std import(s)"
	printf '              %s\n' "${unadmitted[@]}"
	detail "The list is ${ADMISSION_REL}'s ${ALLOW_CONST}; adding a row is a"
	detail "deliberate edit with a reason column, which is the review the rule asks for."
fi

# ---------------------------------------------------------------------------
# Check 3 — THE FFI PRAGMAS, which need no import at all.
# ---------------------------------------------------------------------------
ffi_found=()
for f in "${closure[@]}"; do
	while IFS= read -r span; do
		[ -n "${span}" ] || continue
		for p in "${denied_pragmas[@]}"; do
			if grep -qE "(^|[^[:alnum:]_])${p}([^[:alnum:]_]|$)" <<<"${span}"; then
				ffi_found+=("${f}: ${p} in ${span}")
			fi
		done
	done < <(pragma_spans "${f}")
done
if [ "${#ffi_found[@]}" -eq 0 ]; then
	check_ok "editor-core-binds-no-foreign-function: no denied pragma in ${#closure[@]} closure module(s)"
else
	check_failed "editor-core-binds-no-foreign-function: ${#ffi_found[@]} finding(s)"
	printf '              %s\n' "${ffi_found[@]}"
	detail "One line of pragma is a syscall, and it needs no import to refuse."
fi

# ---------------------------------------------------------------------------
# Check 4 — THE NAMES, for what `system` puts in scope with no import.
# ---------------------------------------------------------------------------
name_found=()
for f in "${closure[@]}"; do
	body="$(code_lines "${f}")"
	for n in "${denied_names[@]}"; do
		if grep -qE "$(identifier_pattern "${n}")" <<<"${body}"; then
			name_found+=("${f}: ${n}")
		fi
	done
done
if [ "${#name_found[@]}" -eq 0 ]; then
	check_ok "editor-core-names-no-async-primitive: no denied identifier in the closure's code"
else
	check_failed "editor-core-names-no-async-primitive: ${#name_found[@]} finding(s)"
	printf '              %s\n' "${name_found[@]}"
	detail "§11: the model has no Future, no callback and no clock."
fi

# ---------------------------------------------------------------------------
# Check 5 — THE CONTROL FOR CHECK 4's COMMENT STRIPPER.
#
# Every module in this closure names denied identifiers IN PROSE —
# `reconcile.nim`'s header alone names six — so check 4 passing is evidence
# only if the stripper really is discriminating. Two-sided: the same needle is
# found in the raw file and not found in its code lines. Without this, a
# `code_lines` that returned nothing would make check 4 green for free (§4).
# ---------------------------------------------------------------------------
probe_file=""
probe_name=""
for f in "${closure[@]}"; do
	for n in "${denied_names[@]}"; do
		if grep -qE "$(identifier_pattern "${n}")" "${f}" 2>/dev/null; then
			probe_file="${f}"
			probe_name="${n}"
			break 2
		fi
	done
done
if [ -z "${probe_file}" ]; then
	check_failed "comment-stripper-discriminates: no closure module names a denied identifier even in prose"
	detail "The control has nothing to be a control over, so check 4 is unfalsified (§7b)."
elif grep -qE "$(identifier_pattern "${probe_name}")" <<<"$(code_lines "${probe_file}")"; then
	check_failed "comment-stripper-discriminates: '${probe_name}' survives the strip in ${probe_file}"
else
	check_ok "comment-stripper-discriminates: '${probe_name}' is in ${probe_file} and not in its code lines"
fi

# ---------------------------------------------------------------------------
# Check 6 — the import extractor's own refusals become findings.
#
# `ci/lib/nim-imports.sh`'s header: *"A THIRD CALLER therefore owes two things:
# the `nim_imports_open_unanalysable_log` call, and a case in its own suite that
# fails when a refused line is not reported."* This is the first half; the
# second is `test_editor_async_closure.nim`'s route-5 case.
# ---------------------------------------------------------------------------
refusals=0
if [ -n "${IMPORT_UNANALYSABLE_LOG:-}" ] && [ -s "${IMPORT_UNANALYSABLE_LOG}" ]; then
	# SORTED AND DEDUPLICATED. The extractor runs over each closure module
	# several times — once for the walk and once for each rule — so a raw line
	# count reports one refused line as three and turns a finding's own number
	# into an artefact of how many checks happen to read the file.
	refusals="$(sort -u <"${IMPORT_UNANALYSABLE_LOG}" | wc -l | tr -d ' ')"
fi
if [ "${refusals}" -eq 0 ]; then
	check_ok "import-specs-analysable: the extractor refused no line in the closure"
else
	check_failed "import-specs-analysable: the extractor refused ${refusals} distinct line(s)"
	sort -u <"${IMPORT_UNANALYSABLE_LOG}" | sed 's/^/              /'
	detail "Refusing to analyse is safe for a guard; guessing is not. A refused"
	detail "line is a line whose imports were NOT checked, so it is a finding."
fi

# ---------------------------------------------------------------------------
# Check 7 — PLAT-31: NO KEYMAP MODULE IN THE EDITING CORE'S CLOSURE.
#
# `Editing-Operations-And-Keymaps.md` §1: *"An external keymap layer reads
# input, resolves it against a loaded configuration, and executes a NAMED
# OPERATION over the ViewModel."* **External** is the load-bearing word, and
# the dependency it describes runs one way: the keymap imports the editor, the
# editor knows nothing about keys.
#
# That is checked HERE rather than by a new scanner for PLAT-29's own stated
# reason — *"writing a new scanner re-opens all six"* routes past a text scan.
# The closure is already computed above, by the shared extractor, over the same
# roots; this check is one grep over a list that exists.
#
# THE RULE IS THE PACKAGE, NOT A LIST OF FOUR FILES. A fifth keymap module
# added next year is covered without an edit, which is the difference between
# a rule and a transcription. `src/common/key_names.nim` is deliberately NOT
# matched: it is a pure `string -> string` decoder in `src/common/`, shared by
# both keymaps, and nothing in the editing core imports it either — but if the
# core ever did, that would be admissible, because a canonical key NAME is not
# a key TYPE and the milestone's gate is about the type.
# ---------------------------------------------------------------------------
KEYMAP_PACKAGE="${KEYMAP_PACKAGE:-src/frontend/viewmodel/keymap}"
keymap_in_closure=()
for m in "${closure[@]}"; do
	case "${m}" in
	*"${KEYMAP_PACKAGE}"/*) keymap_in_closure+=("${m}") ;;
	esac
done
if [ "${#keymap_in_closure[@]}" -eq 0 ]; then
	check_ok "editor-core-imports-no-keymap: no module of ${KEYMAP_PACKAGE}/ in ${#closure[@]} closure module(s)"
else
	check_failed "editor-core-imports-no-keymap: ${#keymap_in_closure[@]} keymap module(s) in the editing core's closure"
	printf '              %s\n' "${keymap_in_closure[@]}"
	detail "§1: the keymap layer is EXTERNAL. The dependency runs one way —"
	detail "the keymap imports the editor, and the editor knows nothing about"
	detail "keys. A module of the keymap package reached from the core means a"
	detail "key type is now in the editing model's closure."
fi

echo "editor-import-closure: ${checks} check(s), ${failures} failing"
[ "${failures}" -eq 0 ]
