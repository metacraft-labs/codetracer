#!/usr/bin/env bash
# NOT-A-CI-GATE: a build step, not a check on one.
#
# It produces the grammar archive the TUI links; whether that archive is
# present, complete and fresh IS a question worth gating, and it is gated —
# by `src/frontend/tui/tests/test_tui_build_prerequisites.nim`, which asserts
# all three and names this script's recipe when one fails. That is a question
# ABOUT this script rather than one it answers.
#
# The honest second half, since `ci/test/shell-gate-coverage.sh` exists to make
# exactly this kind of claim checkable: the `tui` and `tui-real-terminal` lanes
# are not in any workflow yet either. They are in the same position as the
# thirteen discovery lanes the justfile documents at length — declared, green,
# and waiting on a pipeline — and CTUI-0's verification gate is that
# `just tui-prereqs && just build-tui && just test-tui` is green from a clean
# checkout, not that CI runs it.
#
# build-tui-grammars.sh — archive the tree-sitter grammars this repo already
# vendors into one static library the TUI links, and resolve the tree-sitter
# runtime the link line needs.
#
# WHY THIS EXISTS
# ---------------
# Linking anything that imports `isonim_tui` requires a tree-sitter grammar
# archive: `isonim_tui/syntax/treesitter_ffi.nim` carries a `{.passl.}` naming
# one, and `nim c` therefore hands the linker a path that must exist. Upstream
# builds that archive from two SIBLING repositories (`../tree-sitter-nim`,
# `../tree-sitter-aiken`), which this workspace does not have and does not want:
# codetracer already vendors TEN tree-sitter grammars as submodules under
# `libs/`, pinned at the same revisions `isonim-tui/.github/sibling-repos`
# hard-codes for its two. Building the archive from `libs/` removes the sibling
# dependency outright and gives the CTUI-5 highlighter eight more languages than
# isonim-tui has.
#
# WHAT IT PRODUCES
#
#   build/grammars/libcodetracer_tui_grammars.a   every vendored grammar
#   build/grammars/tui-link-flags.txt             the resolved `-L` / `-rpath`
#                                                 flags for `-ltree-sitter`
#   build/grammars/generated/<grammar>/           `tree-sitter generate`'s
#                                                 output for the one grammar
#                                                 that does not commit a
#                                                 parser.c
#
# and, when it is absent, a symlink at the path `treesitter_ffi.nim` bakes in.
# That last one is a FALLBACK for an isonim-tui that predates the
# `-d:isonimTuiGrammarArchive` override; it is called out where it happens, see
# `ensure_isonim_tui_archive` below.
#
# NOTHING IT PRODUCES LIVES INSIDE A SUBMODULE. That is why the generated
# parser goes under `build/` rather than into `libs/tree-sitter-nim/src/`;
# section 2 explains what the in-place form dirties and why a dirty submodule
# is a push-blocking defect rather than a cosmetic one.
#
# THREE THINGS IT REFUSES TO DO SILENTLY, each because the alternative is a
# build that looks fine and is not:
#
#   * It does not archive a PARTIAL set. The declared grammars come from
#     `.gitmodules` — the same list git initialises — and a declared grammar
#     whose submodule is empty is a hard failure naming `just tui-prereqs`.
#     A nine-of-ten archive is the failure mode Verification-Harness-Traps §4b
#     is about: every assertion it still supports is true, and it says nothing
#     about the one that vanished.
#   * It does not guess where `libtree-sitter` is. Four resolution routes are
#     tried in order and the winner is recorded in the flags file; when all
#     four fail it exits non-zero and names them, rather than emitting a flags
#     file that omits `-L` and leaves the reader with `cannot find
#     -ltree-sitter` several minutes into an unrelated compile.
#   * It does not hard-code a nix store path. A store path is correct on
#     exactly one machine for exactly as long as nothing is garbage-collected.
#
# Usage:
#   bash scripts/build-tui-grammars.sh            # build (timestamp-guarded)
#   bash scripts/build-tui-grammars.sh --force    # rebuild unconditionally
#   bash scripts/build-tui-grammars.sh --print-link-flags
#                                                 # resolve and print only
#
# Environment:
#   CT_TREE_SITTER_LIB_DIR  where libtree-sitter lives; skips resolution
#   CC / AR                 toolchain overrides (default `cc` / `ar`)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}" || exit 2

out_dir="${repo_root}/build/grammars"
archive="${out_dir}/libcodetracer_tui_grammars.a"
flags_file="${out_dir}/tui-link-flags.txt"

force=0
print_link_flags_only=0
while [ $# -gt 0 ]; do
	case "$1" in
	--force) force=1 ;;
	--print-link-flags) print_link_flags_only=1 ;;
	*)
		echo "build-tui-grammars.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done

# ---------------------------------------------------------------------------
# The declared grammar set
#
# Read from `.gitmodules` rather than written here, so this script and
# `just tui-prereqs` cannot disagree about which submodules the TUI links —
# they are reading one list. A hand-written copy would drift the first time a
# grammar is added, and the drift would present as a smaller archive rather
# than as an error.
# ---------------------------------------------------------------------------
declared_grammars() {
	git config -f "${repo_root}/.gitmodules" --get-regexp '^submodule\..*\.path$' 2>/dev/null |
		awk '{print $2}' | grep '^libs/tree-sitter-' | sort
}

# ---------------------------------------------------------------------------
# Where is libtree-sitter?
#
# `treesitter_ffi.nim`'s `{.passl.}` ends in `-ltree-sitter`, so the linker
# needs a `-L`, and the produced binary needs the same directory on its RPATH —
# the runtime is a shared object and this repo's dev shell does not put it on
# LD_LIBRARY_PATH.
#
# Route 4 is the one that works outside a dev shell and is worth explaining:
# nixpkgs' `tree-sitter` derivation ships `bin/tree-sitter`, `lib/` and
# `include/` in ONE output, so resolving the CLI on PATH through its symlinks
# and stepping up one directory lands on the library. That is a property of the
# package layout, not a guess about the filesystem — it is checked by looking
# for the file, and reported as "not found" when it is not there.
# ---------------------------------------------------------------------------
tree_sitter_lib_dir=""
tree_sitter_lib_route=""

_probe_lib_dir() {
	# A directory counts only when it actually holds the runtime.
	local d="$1"
	[ -n "${d}" ] || return 1
	local f
	for f in libtree-sitter.so libtree-sitter.dylib libtree-sitter.a; do
		if [ -e "${d}/${f}" ]; then
			printf '%s' "$(cd "${d}" && pwd)"
			return 0
		fi
	done
	return 1
}

resolve_tree_sitter_lib_dir() {
	local d entry cli prefix

	# 1. Explicit override. The escape hatch for a host whose packaging this
	#    script has never seen; it is validated like every other route rather
	#    than trusted, so a stale value fails here instead of at link time.
	if [ -n "${CT_TREE_SITTER_LIB_DIR:-}" ]; then
		if d="$(_probe_lib_dir "${CT_TREE_SITTER_LIB_DIR}")"; then
			tree_sitter_lib_dir="${d}"
			tree_sitter_lib_route="CT_TREE_SITTER_LIB_DIR"
			return 0
		fi
		echo "build-tui-grammars.sh: CT_TREE_SITTER_LIB_DIR=${CT_TREE_SITTER_LIB_DIR}" \
			"holds no libtree-sitter" >&2
		return 1
	fi

	# 2. pkg-config, when the host has both it and a .pc file.
	if command -v pkg-config >/dev/null 2>&1; then
		if pkg-config --exists tree-sitter 2>/dev/null; then
			if d="$(_probe_lib_dir "$(pkg-config --variable=libdir tree-sitter 2>/dev/null)")"; then
				tree_sitter_lib_dir="${d}"
				tree_sitter_lib_route="pkg-config"
				return 0
			fi
		fi
	fi

	# 3. The linker search paths this environment already sets — a dev shell
	#    that provides the package has it here.
	local IFS=:
	for entry in ${LIBRARY_PATH:-} ${LD_LIBRARY_PATH:-} ${DYLD_LIBRARY_PATH:-}; do
		if d="$(_probe_lib_dir "${entry}")"; then
			tree_sitter_lib_dir="${d}"
			tree_sitter_lib_route="LIBRARY_PATH/LD_LIBRARY_PATH"
			return 0
		fi
	done
	unset IFS

	# 4. The `tree-sitter` CLI's own prefix. `tui-prereqs` needs the CLI
	#    anyway (tree-sitter-nim's parser.c is generated), so on a host that
	#    can build the grammars at all this route is usually available.
	cli="$(command -v tree-sitter 2>/dev/null)"
	if [ -n "${cli}" ]; then
		# `readlink -f` is GNU; `python3 -c os.path.realpath` is not, and this
		# script runs on macOS too.
		cli="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "${cli}" 2>/dev/null || printf '%s' "${cli}")"
		prefix="$(dirname "$(dirname "${cli}")")"
		if d="$(_probe_lib_dir "${prefix}/lib")"; then
			tree_sitter_lib_dir="${d}"
			tree_sitter_lib_route="tree-sitter CLI prefix (${prefix})"
			return 0
		fi
	fi

	return 1
}

report_unresolved_runtime() {
	echo "" >&2
	echo "build-tui-grammars.sh: could not locate the tree-sitter runtime." >&2
	echo "  The TUI link line ends in '-ltree-sitter' (isonim_tui/syntax/" >&2
	echo "  treesitter_ffi.nim), so without it nothing that imports isonim_tui" >&2
	echo "  can link. Four routes were tried and none answered:" >&2
	# The variable names are written WITHOUT a leading `$` on purpose: with one
	# they need either an escape (which `shfmt` rewrites to single quotes) or
	# single quotes (which `shellcheck` flags as SC2016), and the two hooks then
	# reject each other's fix forever. They are environment variables either
	# way, and the header of this file lists them as such.
	echo "    1. the CT_TREE_SITTER_LIB_DIR env var (unset or wrong)" >&2
	echo "    2. pkg-config --variable=libdir tree-sitter" >&2
	echo "    3. the LIBRARY_PATH / LD_LIBRARY_PATH env vars" >&2
	echo "    4. the prefix of the 'tree-sitter' CLI on PATH" >&2
	echo "  Remedies, in order of preference: enter the dev shell that provides" >&2
	echo "  the tree-sitter package; install it; or set CT_TREE_SITTER_LIB_DIR" >&2
	echo "  to the directory holding libtree-sitter.so/.dylib." >&2
}

if [ "${print_link_flags_only}" -eq 1 ]; then
	if ! resolve_tree_sitter_lib_dir; then
		report_unresolved_runtime
		exit 1
	fi
	printf -- '-L%s -Wl,-rpath,%s\n' "${tree_sitter_lib_dir}" "${tree_sitter_lib_dir}"
	exit 0
fi

# ---------------------------------------------------------------------------
# 1. Every declared grammar must be on disk.
# ---------------------------------------------------------------------------
# `while read` rather than `mapfile`: `mapfile` is a bash-4 builtin and macOS
# ships /bin/bash 3.2, which is the exact trap ci/test/sdk-facade-boundary.sh
# documents at length — a checker that "runs" and silently establishes nothing.
grammars=()
while read -r g; do
	[ -n "${g}" ] || continue
	grammars+=("${g}")
done < <(declared_grammars)

if [ "${#grammars[@]}" -eq 0 ]; then
	echo "build-tui-grammars.sh: .gitmodules declares no libs/tree-sitter-* submodule." >&2
	echo "  This script would otherwise archive nothing and report success — an" >&2
	echo "  empty subject satisfies every check downstream of it." >&2
	exit 1
fi

missing=()
for g in "${grammars[@]}"; do
	if [ ! -f "${repo_root}/${g}/src/grammar.json" ] && [ ! -f "${repo_root}/${g}/src/parser.c" ]; then
		missing+=("${g}")
	fi
done
if [ "${#missing[@]}" -gt 0 ]; then
	echo "build-tui-grammars.sh: ${#missing[@]} declared grammar submodule(s) are not checked out:" >&2
	printf '  %s\n' "${missing[@]}" >&2
	echo "  Run 'just tui-prereqs', which initialises exactly these submodules." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# 2. Generate the parser sources that are not committed — OUTSIDE THE SUBMODULE.
#
# tree-sitter-nim gitignores `src/parser.c` and produces it from the grammar.
# Every other vendored grammar commits it.
#
# `tree-sitter generate src/grammar.json` rather than a bare `tree-sitter
# generate`: the bare form loads `grammar.js` through node, and on a host with
# no node it fails. The JSON form is the already-compiled grammar and needs
# only the CLI.
#
# `-o "${gen_dir}"` IS LOAD-BEARING AND IS THE WHOLE POINT OF THIS SECTION.
# The in-place form overwrites `src/tree_sitter/parser.h`, which the submodule
# TRACKS, on every run — measured: `src/parser.c` and that header both get a
# fresh mtime on a second consecutive run, while `src/grammar.json` does not.
# It is the same CLI writing its own bundled runtime header next to the parser
# it just emitted, so the content is whatever the CLI on PATH carries; when
# that differs from the revision the submodule pins the result is a permanent
# ` M libs/tree-sitter-nim` in `git status`. That is VERSION-DEPENDENT and both
# states were observed here: tree-sitter 0.25.3 adds
# `typedef struct TSLanguageMetadata TSLanguageMetadata;` and dirties the
# checkout, 0.25.10 writes a byte-identical header and does not. A build step
# whose cleanliness depends on which tree-sitter happens to be on PATH is not
# one to leave in place. The workspace's
# pre-push gate refuses uncommitted changes in a repo or its develop-set
# closure, so a build step that dirties a submodule blocks every push from the
# checkout that ran it — a build step must not be able to do that.
#
# Restoring the file afterwards was the other candidate and is worse: when the
# CLI *did* need to update `parser.h`, putting the pinned one back leaves a
# parser.c that was generated against a header it no longer matches, which is
# an ABI mismatch discovered at compile time or, worse, not at all. Generating
# into a scratch directory under `build/` removes the question: nothing writes
# inside the submodule, and `parser.c` travels with the `tree_sitter/*.h` the
# same run produced (see the `-I` order in section 3).
#
# Verified rather than assumed: the mtimes of `src/grammar.json`,
# `src/parser.c` and `src/tree_sitter/parser.h` are identical before and after
# a full regeneration through `-o`, and `git -C libs/tree-sitter-nim status`
# stays empty. The check below asserts it on every run, and
# `test_tui_build_prerequisites.nim` asserts it again from the outside.
# ---------------------------------------------------------------------------
gen_root="${out_dir}/generated"

# Does this grammar COMMIT its parser.c, or does it have to be generated?
#
# Asked of git rather than of the filesystem, deliberately. `[ -f src/parser.c ]`
# answers yes for a leftover from an older revision of this script, which
# generated in place — and then everything below would quietly compile that
# stale, unversioned 42 MB file instead of the one it just produced, which is
# exactly the class of "it built, from something nobody chose" this script tries
# not to be. `git ls-files` answers the question that was actually asked.
#
# The filesystem fallback is for a checkout that is not a git tree at all (a
# vendored export, a nix source drop); there, the file's presence is the only
# evidence available.
grammar_commits_parser_c() {
	local g="$1"
	if git -C "${repo_root}/${g}" rev-parse --git-dir >/dev/null 2>&1; then
		git -C "${repo_root}/${g}" ls-files --error-unmatch src/parser.c \
			>/dev/null 2>&1
	else
		[ -f "${repo_root}/${g}/src/parser.c" ]
	fi
}

# Where a grammar's parser.c actually is: committed in the submodule, or
# generated under build/. One function, because section 3's freshness guard and
# section 3's compile loop must agree with section 2 about the answer.
grammar_parser_c() {
	local g="$1"
	if grammar_commits_parser_c "${g}"; then
		printf '%s' "${repo_root}/${g}/src/parser.c"
	else
		printf '%s' "${gen_root}/${g#libs/}/parser.c"
	fi
}

# The include directory that carries the `tree_sitter/*.h` a translation unit
# must be compiled against. For a generated grammar that is the scratch
# directory, so the parser and its runtime header come from one `generate` run.
grammar_include_dir() {
	local g="$1"
	if grammar_commits_parser_c "${g}"; then
		printf '%s' "${repo_root}/${g}/src"
	else
		printf '%s' "${gen_root}/${g#libs/}"
	fi
}

# A tracked-file fingerprint of a grammar checkout, used to prove that
# generation did not write into it. `diff` only — untracked files are what
# `.gitignore` already covers, and a developer's own untracked scratch file in
# a submodule is not this script's business.
grammar_tracked_dirt() {
	git -C "${repo_root}/$1" diff --name-only 2>/dev/null
	git -C "${repo_root}/$1" diff --cached --name-only 2>/dev/null
}

generated=0
for g in "${grammars[@]}"; do
	if grammar_commits_parser_c "${g}"; then
		continue
	fi
	gen_dir="${gen_root}/${g#libs/}"
	# The generated parser is stale only against the grammar it is generated
	# from; nothing else in the submodule feeds it.
	if [ -f "${gen_dir}/parser.c" ] &&
		[ -z "$(find "${repo_root}/${g}/src/grammar.json" -newer "${gen_dir}/parser.c" 2>/dev/null)" ]; then
		echo "[tui-grammars] ${gen_dir}/parser.c is up to date"
		continue
	fi
	if ! command -v tree-sitter >/dev/null 2>&1; then
		echo "build-tui-grammars.sh: ${g} ships no src/parser.c and must be generated," >&2
		echo "  but the 'tree-sitter' CLI is not on PATH. Enter the dev shell that" >&2
		echo "  provides it, or install it, then re-run 'just tui-prereqs'." >&2
		exit 1
	fi
	dirt_before="$(grammar_tracked_dirt "${g}")"
	mkdir -p "${gen_dir}"
	echo "[tui-grammars] tree-sitter generate ${g} -> ${gen_dir}"
	if ! (cd "${repo_root}/${g}" && tree-sitter generate -o "${gen_dir}" src/grammar.json); then
		echo "build-tui-grammars.sh: 'tree-sitter generate' failed in ${g}" >&2
		exit 1
	fi
	if [ ! -f "${gen_dir}/parser.c" ]; then
		echo "build-tui-grammars.sh: 'tree-sitter generate' reported success in ${g}" >&2
		echo "  but produced no ${gen_dir}/parser.c." >&2
		exit 1
	fi
	if [ ! -f "${gen_dir}/tree_sitter/parser.h" ]; then
		echo "build-tui-grammars.sh: ${gen_dir} has no tree_sitter/parser.h." >&2
		echo "  The generated parser.c includes it, and compiling against the" >&2
		echo "  submodule's copy instead is the ABI mismatch this scratch" >&2
		echo "  directory exists to avoid." >&2
		exit 1
	fi
	# THE ASSERTION THAT THE MECHANISM WORKED, on the run that could break it.
	# Cheap, and it fires the moment a future edit drops `-o` or a future CLI
	# starts writing back into the source tree.
	dirt_after="$(grammar_tracked_dirt "${g}")"
	if [ "${dirt_before}" != "${dirt_after}" ]; then
		echo "build-tui-grammars.sh: generating ${g} modified tracked file(s) in it:" >&2
		printf '  %s\n' "${dirt_after}" >&2
		echo "  Generation must not write inside a submodule: the workspace" >&2
		echo "  pre-push gate refuses uncommitted changes, so this would block" >&2
		echo "  every push from this checkout. Restore them with" >&2
		echo "  'git -C ${g} checkout --' and report the tree-sitter version." >&2
		exit 1
	fi
	generated=$((generated + 1))
done

# ---------------------------------------------------------------------------
# 3. Collect the translation units, then decide whether anything needs doing.
# ---------------------------------------------------------------------------
srcs=()
for g in "${grammars[@]}"; do
	srcs+=("$(grammar_parser_c "${g}")")
	for extra in scanner.c scanner.cc; do
		if [ -f "${repo_root}/${g}/src/${extra}" ]; then
			srcs+=("${repo_root}/${g}/src/${extra}")
		fi
	done
done

mkdir -p "${out_dir}"

# THE TIMESTAMP GUARD. `find -newer` over every input, so a warm checkout does
# no work and a grammar bump rebuilds. Deliberately not a content hash: the
# inputs total ~57 MB and hashing them costs more than the `stat` calls save.
if [ "${force}" -eq 0 ] && [ -f "${archive}" ]; then
	newer="$(find "${srcs[@]}" -newer "${archive}" 2>/dev/null)"
	if [ -z "${newer}" ]; then
		echo "[tui-grammars] ${archive} is up to date (${#grammars[@]} grammars)"
		skip_build=1
	fi
fi

if [ "${skip_build:-0}" -ne 1 ]; then
	echo "[tui-grammars] building ${archive} from ${#grammars[@]} grammar(s)"
	rm -f "${archive}"
	objs=()
	for g in "${grammars[@]}"; do
		lang="${g#libs/tree-sitter-}"
		# `-O0` deliberately, on isonim-tui's recorded measurement of the same
		# sources: generated table-driven C with no hot loops of its own, where
		# -O1 and -O2 measured 58 s and 37 s against -O0's 34 s on
		# tree-sitter-nim's 42 MB translation unit, for no movement in a
		# benchmark. `ct_ts_` prefixes the object names so members of this
		# archive can never be confused with — or collide with — members of
		# isonim-tui's.
		#
		# `-Wno-cpp` suppresses exactly one known-benign diagnostic and nothing
		# else: the nix cc wrapper injects `-D_FORTIFY_SOURCE=2`, glibc's
		# features.h answers `#warning _FORTIFY_SOURCE requires compiling with
		# optimization`, and at -O0 that is a statement of fact rather than a
		# problem with the grammar. Without it every unit prints an eight-line
		# include trace and a fresh build buries its own summary.
		# `-I` order: the generated directory FIRST when there is one, so a
		# generated parser.c and the hand-written scanner.c beside it are both
		# compiled against the `tree_sitter/*.h` that same `generate` emitted.
		# The submodule's own `src` stays on the list because scanner.c lives
		# there and may include grammar-local headers.
		inc_dir="$(grammar_include_dir "${g}")"
		for unit in parser.c scanner.c scanner.cc; do
			if [ "${unit}" = "parser.c" ]; then
				src="$(grammar_parser_c "${g}")"
			else
				src="${repo_root}/${g}/src/${unit}"
			fi
			[ -f "${src}" ] || continue
			obj="${out_dir}/ct_ts_${lang}_${unit%%.*}.o"
			if ! "${CC:-cc}" -c -O0 -fPIC -Wno-cpp \
				-I"${inc_dir}" -I"${repo_root}/${g}/src" "${src}" -o "${obj}"; then
				echo "build-tui-grammars.sh: failed to compile ${src}" >&2
				exit 1
			fi
			objs+=("${obj}")
		done
	done
	if ! "${AR:-ar}" rcs "${archive}" "${objs[@]}"; then
		echo "build-tui-grammars.sh: failed to archive ${archive}" >&2
		exit 1
	fi
	# THE COUNT IS THE CONTROL, not the existence of the file. One object per
	# grammar at minimum; anything less means a loop skipped a member and every
	# downstream check would still have passed.
	if [ "${#objs[@]}" -lt "${#grammars[@]}" ]; then
		echo "build-tui-grammars.sh: archived ${#objs[@]} object(s) for" \
			"${#grammars[@]} grammar(s) — at least one grammar contributed nothing." >&2
		exit 1
	fi
	echo "[tui-grammars] ${archive}: $(wc -c <"${archive}") bytes," \
		"${#objs[@]} object(s), ${#grammars[@]} grammar(s), ${generated} generated"
fi

# ---------------------------------------------------------------------------
# 4. The path isonim-tui bakes into its link line — now a FALLBACK.
#
# `isonim-tui/src/isonim_tui/syntax/treesitter_ffi.nim` computes an archive
# path from `currentSourcePath` and emits it as `{.passl.}`, so every binary
# that imports `isonim_tui` — this repo's included — hands the linker
#
#     <workspace>/isonim-tui/build/grammars/libisonim_tui_grammars.a
#
# and fails with `cannot find <path>` when it is absent. Verified by removing
# the file and re-linking.
#
# THE DURABLE FIX NOW EXISTS UPSTREAM: that `const` is
# `isonimTuiGrammarArchive {.strdefine.}`, defaulting to exactly the path
# above, so a build that says
#
#     -d:isonimTuiGrammarArchive=<repo>/build/grammars/libcodetracer_tui_grammars.a
#
# hands the linker THIS repo's ten-grammar archive and never reads the sibling
# path at all. `justfile`'s `build-tui` and `ci/lib/test-lane-files.sh`'s two
# TUI lanes both pass it.
#
# The symlink stays as a fallback because Nim SILENTLY IGNORES a `-d:` naming a
# constant the compiled sources do not declare. A workspace whose `isonim-tui`
# predates the override therefore gets no error from the define; it gets the
# baked default, and without the symlink that is `ld: cannot find <path>` at
# the end of a multi-minute compile. One symlink is a cheaper answer than that
# cliff.
#
# WHAT THE SYMLINK COSTS, RECORDED BECAUSE IT IS NOT ZERO: isonim-tui's own
# `just grammars` tests the same path with `[ -f "$archive" ]`, which FOLLOWS a
# symlink. Running it there either adopts this repo's archive (skipping its own
# build) or `rm -f`s the link and writes a TWO-grammar archive in its place —
# after which the `[ -e ]` guard below sees a file and leaves it. For a build
# that passes the define that is harmless; for one that does not it is a silent
# degradation from ten grammars to two, so
# `src/frontend/tui/tests/test_tui_build_prerequisites.nim` asserts the member
# count at THIS path as well as at ours, and a dangling link fails it rather
# than satisfying a `symlinkExists`.
# ---------------------------------------------------------------------------
ensure_isonim_tui_archive() {
	local sibling="${repo_root}/../isonim-tui"
	[ -d "${sibling}" ] || return 0
	sibling="$(cd "${sibling}" && pwd)"
	local target="${sibling}/build/grammars/libisonim_tui_grammars.a"
	# `-e` is false for a DANGLING symlink, which is the state isonim-tui's own
	# `rm -f` + interrupted build leaves behind and the one state that must not
	# be treated as "already provisioned": the linker resolves the link, not the
	# name. Remove it and re-link.
	if [ -L "${target}" ] && [ ! -e "${target}" ]; then
		echo "[tui-grammars] ${target} is a dangling symlink; replacing it"
		rm -f "${target}"
	fi
	if [ -e "${target}" ]; then
		return 0
	fi
	mkdir -p "$(dirname "${target}")"
	if ln -s "${archive}" "${target}" 2>/dev/null; then
		echo "[tui-grammars] linked ${target}"
		echo "               -> ${archive}"
		echo "               (fallback for an isonim-tui without"
		echo "                -d:isonimTuiGrammarArchive; see this script's section 4)"
	else
		echo "build-tui-grammars.sh: could not create ${target}" >&2
		return 1
	fi
}
ensure_isonim_tui_archive || exit 1

# ---------------------------------------------------------------------------
# 5. The runtime, and the flags file every TUI compile reads.
# ---------------------------------------------------------------------------
if ! resolve_tree_sitter_lib_dir; then
	report_unresolved_runtime
	exit 1
fi

printf -- '-L%s -Wl,-rpath,%s\n' "${tree_sitter_lib_dir}" "${tree_sitter_lib_dir}" >"${flags_file}"
echo "[tui-grammars] tree-sitter runtime: ${tree_sitter_lib_dir}"
echo "[tui-grammars]   resolved via ${tree_sitter_lib_route}"
echo "[tui-grammars] link flags: ${flags_file}"
