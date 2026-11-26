#!/usr/bin/env bash
#
# run-nim-test-lane.sh — compile and run one Nim test lane, and report what
# actually happened to every file in it.
#
# WHY THIS EXISTS
# ---------------
# Six `just` recipes had each grown their own copy of "loop over some files,
# `nim c -r` each, count [OK] lines". Every copy drifted: some scored the tally
# before the exit status (the bug ci/lib/test-lane-report.sh exists to prevent),
# some threw away the one diagnostic line that named a missing shared library,
# some could not observe a non-zero exit at all. Adding a lane meant copying the
# loop a seventh time and inheriting whichever bugs the donor still had.
#
# So there is one loop, here, and lanes differ only in DATA:
# ci/lib/test-lane-files.sh says which files and which compiler flags, and this
# script says what running them means. A new lane is a one-line `just` recipe.
#
# EXCEPT FOR A RECIPE-OWNED LANE, which this script REFUSES (exit 2) by name.
# Some lanes are listed in ci/lib/test-lane-files.sh only so the coverage guard
# can see their files; their execution lives in a bespoke `just` recipe that
# does what this loop cannot — per-file defines and a `window` alias, a CLI
# that is compiled and never run, BPF capabilities, a sibling framework's
# paths, a different scoring of `MISSING-RECORDER SKIP:` output.
# `test_lane_recipe` names that recipe. Running such a lane here used to report
# red for reasons that were artefacts of this runner (3 + 1 + 4 + 10 failures
# over four lanes at codetracer `661744f2c`), indistinguishable in a sweep from
# product failures; refusing it, and printing the recipe, is the honest answer.
# ci/test/recipe-owned-lanes-test.sh holds both halves of that to account.
#
# Behaviour worth knowing:
#
#   * Compile and run are SEPARATE steps, never a single `nim c -r`. Conflating
#     them turns "the binary could not find libsqlite3" into "COMPILE ERROR",
#     and then prints only lines matching `Error:` — which that diagnostic does
#     not match, so the one line naming the missing library is discarded.
#
#   * The run inherits CT_LD_LIBRARY_PATH (the dev shell's
#     sqlite/pcre/glib/openssl/zstd set). It is applied to the RUN only, never
#     to the compile, so those libraries are not put in front of the Nim
#     compiler's own loader path. A lane that needs more run-time libraries
#     names them in `test_lane_run_library_path` (ci/lib/test-lane-files.sh);
#     they go in front of that set, for the run only as well.
#
#   * The verdict comes from ci/lib/test-lane-report.sh, which reads the exit
#     status before the [OK]/[FAILED] tally. A lane must never invent `OK (0
#     tests)` for a binary that produced nothing.
#
#   * A lane that ran zero cases fails. A glob that silently matches nothing,
#     or suites that compile but assert nothing, is not a pass — it is the same
#     invisible-coverage failure this whole area is about.
#
# Usage:
#   bash ci/lib/run-nim-test-lane.sh <lane-id> [--compile-only] [--list-shard]
#                                    [--file <path>]
#
# --file <path> runs ONE of the lane's files, with exactly the lane's flags,
# environment and scoring. A path that is not one of the lane's files is
# refused (exit 2), so the option cannot run a file under flags its lane does
# not give it. The PHP recorder's downstream lane
# (ci/test/php-recorder-consumers.sh) runs one vm-native suite this way.
#
# NIM_TEST_LANE_SHARD=i/n runs one shard of the lane: every n-th of its files,
# starting with the i-th, so the n shards together run each file exactly once
# (ci/test/nim-test-lane-shard-test.sh holds them to the lane). CI runs the
# terminal lanes in shards because one job cannot compile ~225 files within its
# timeout (run 43859070538). --list-shard prints the shard's files and exits.
#
# Environment:
#   CT_NIM_CACHE_ROOT  nimcache root (default /tmp/ct-nim-cache-<uid>/<checkout>-<tag>)
#   CT_LANE_TIMEOUT    per-file timeout in seconds (default 1800)

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}" || exit 2

# shellcheck source=ci/lib/test-lane-files.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/test-lane-files.sh"
# shellcheck source=ci/lib/test-lane-report.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/test-lane-report.sh"

lane="${1:-}"
if [ -z "${lane}" ]; then
	echo "usage: run-nim-test-lane.sh <lane-id> [--compile-only] [--list-shard]" >&2
	# Only the lanes this script will actually run; listing the recipe-owned
	# ones here would advertise an invocation the check below refuses.
	echo "lanes:" >&2
	while read -r _ct_id; do
		[ -z "$(test_lane_recipe "${_ct_id}")" ] && printf '  %s\n' "${_ct_id}" >&2
	done < <(test_lane_ids)
	echo "(recipe-owned lanes are run by their 'just' recipe; 'just test-lanes' names each one's recipe)" >&2
	exit 2
fi
shift

compile_only=0
list_shard=0
only_file=""
while [ $# -gt 0 ]; do
	case "$1" in
	--compile-only) compile_only=1 ;;
	--list-shard) list_shard=1 ;;
	--file)
		if [ $# -lt 2 ] || [ -z "$2" ]; then
			echo "run-nim-test-lane.sh: --file needs a path" >&2
			exit 2
		fi
		only_file="${2#./}"
		shift
		;;
	*)
		echo "run-nim-test-lane.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done

# The lane's files, or the shard NIM_TEST_LANE_SHARD=i/n names of them, or
# the one file --file names.
lane_run_files() {
	if [ -n "${only_file}" ]; then
		printf '%s\n' "${only_file}"
		return
	fi
	if [ -z "${NIM_TEST_LANE_SHARD:-}" ]; then
		test_lane_files "${lane}"
		return
	fi
	local i="${NIM_TEST_LANE_SHARD%%/*}" n="${NIM_TEST_LANE_SHARD##*/}" k=0 f
	case "${i}/${n}" in
	[0-9]*/[0-9]*) ;;
	*)
		echo "run-nim-test-lane.sh: NIM_TEST_LANE_SHARD must be i/n, got '${NIM_TEST_LANE_SHARD}'" >&2
		return 2
		;;
	esac
	if [ "${n}" -lt 1 ] || [ "${i}" -lt 1 ] || [ "${i}" -gt "${n}" ]; then
		echo "run-nim-test-lane.sh: NIM_TEST_LANE_SHARD ${NIM_TEST_LANE_SHARD} is out of range" >&2
		return 2
	fi
	# The lane's files into a variable first: read from a process
	# substitution, an unknown lane's error was swallowed and its shard listed
	# as empty, exit 0 (so a sharded run of it ran nothing and passed).
	local all
	all="$(test_lane_files "${lane}")" || return $?
	while read -r f; do
		[ -n "${f}" ] || continue
		[ $((k % n)) -eq $((i - 1)) ] && printf '%s\n' "${f}"
		k=$((k + 1))
	done <<<"${all}"
}
if [ -n "${only_file}" ]; then
	if [ -n "${NIM_TEST_LANE_SHARD:-}" ]; then
		echo "run-nim-test-lane.sh: --file and NIM_TEST_LANE_SHARD cannot be combined" >&2
		exit 2
	fi
	# The lane's own list is the authority: a file outside it would be run
	# under flags nobody chose for it.
	_ct_lane_all="$(test_lane_files "${lane}")" || exit 2
	if ! grep -qxF -- "${only_file}" <<<"${_ct_lane_all}"; then
		echo "run-nim-test-lane.sh: '${only_file}' is not one of lane '${lane}'s files" >&2
		exit 2
	fi
fi
if [ "${list_shard}" -eq 1 ]; then
	lane_run_files
	exit $?
fi
if [ -n "${NIM_TEST_LANE_SHARD:-}" ]; then
	lane_run_files >/dev/null || exit 2
	echo "${lane}: shard ${NIM_TEST_LANE_SHARD} ($(lane_run_files | wc -l) of $(test_lane_files "${lane}" | grep -c .) file(s))"
fi

# A RECIPE-OWNED LANE IS REFUSED HERE, BEFORE ANYTHING ELSE HAPPENS — before
# the cache root, the scratch state directories, the user-state snapshot or a
# single compiler call — and with `--compile-only` too. Its file list exists
# for the coverage question only; what running it MEANS is in the recipe, and
# a partial imitation of that here is exactly the false red this refusal
# replaces (see the header and `test_lane_recipe`). Exit 2 is this script's
# usage-error status, so a sweep cannot mistake the refusal for a lane result.
_ct_lane_recipes="$(test_lane_recipe "${lane}")"
if [ -n "${_ct_lane_recipes}" ]; then
	{
		echo "run-nim-test-lane.sh: lane '${lane}' is recipe-owned; this runner does not run it."
		echo "  Its files are listed in ci/lib/test-lane-files.sh for coverage accounting"
		echo "  only. Its execution lives in the recipe below, which does what this"
		echo "  generic loop cannot (see test_lane_recipe there for what). Run:"
		for _ct_r in ${_ct_lane_recipes}; do
			echo "    just ${_ct_r}"
		done
	} >&2
	exit 2
fi

# THE SPECIFICATION CHECKOUT, FOR THE SUITES THAT READ THEIR ORACLE FROM IT.
#
# `test_support/spec_documents.nim` reads `$CT_SPECS_DIR`, else the sibling
# `../codetracer-pm`, and never searches; in a workspace the repository is
# checked out under its manifest path (`codetracer-specs`), so without this
# every suite that imports it failed to COMPILE, on every tree, in a way that
# read as a product defect. The lane resolves the checkout once
# (ci/lib/spec-checkout.sh: the override, the workspace manifest, the sibling
# names) and exports it. When the lane holds such a suite and nothing
# resolves, the lane stops HERE, before compiling anything, naming the suites
# and every place it looked — a missing oracle is a hard red, never a skip.
# shellcheck source=ci/lib/spec-checkout.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/spec-checkout.sh"
_ct_spec_readers="$(test_lane_files "${lane}" | while read -r _ct_f; do
	[ -n "${_ct_f}" ] && grep -l 'spec_documents' "${_ct_f}" 2>/dev/null
done)"
if _ct_specs_found="$(ct_resolve_specs_dir "${repo_root}" 2>"${TMPDIR:-/tmp}/ct-specs-tried.$$")"; then
	export CT_SPECS_DIR="${_ct_specs_found}"
	if [ -n "${_ct_spec_readers}" ]; then
		echo "    (specifications read from ${CT_SPECS_DIR})"
		sed 's/^/    /' "${TMPDIR:-/tmp}/ct-specs-tried.$$"
	fi
elif [ -n "${_ct_spec_readers}" ]; then
	{
		echo "ERROR: lane '${lane}' has suites that read the CodeTracer specification"
		echo "       checkout (codetracer-pm, checked out as codetracer-specs in a workspace),"
		echo "       and no checkout was found:"
		printf '%s\n' "${_ct_spec_readers}" | sed 's/^/         suite: /'
		sed 's/^/         tried: /' "${TMPDIR:-/tmp}/ct-specs-tried.$$"
		echo "       Check the repository out beside this one (repro ws enable codetracer)"
		echo "       or set CT_SPECS_DIR to a checkout holding spec/."
	} >&2
	rm -f "${TMPDIR:-/tmp}/ct-specs-tried.$$"
	exit 2
fi
rm -f "${TMPDIR:-/tmp}/ct-specs-tried.$$"

# THE CACHE ROOT IS PER-CHECKOUT, AND THAT IS THE WHOLE POINT.
#
# The default used to be a bare `/tmp/ct-nim-cache`, and the per-suite directory
# beneath it is keyed `${lane}-${name}` with NO component naming the tree it was
# compiled from. So two worktrees running the same lane at the same time compiled
# into the same directory — caught on 2026-09-03, with `/Users/zahary/m/dev/ct-gutter`
# and another worktree both writing `vm-unit-test_ns9_panes_vm`, and 295 shared
# directories sitting under that root.
#
# THE FAILURE THIS PRODUCES IS SILENT AND POINTS THE WRONG WAY. Nim reuses a cached
# artefact when it believes the inputs are unchanged, so the loser of the race can
# link objects built from a DIFFERENT TREE and still report a clean pass. The loud
# outcome is a confusing compile error; the quiet one is a green lane that measured
# someone else's source, or a mutation arm reporting SURVIVED because the mutation
# it planted was never in the bytes it graded. That reads as "this assertion does not
# detect this defect" and sends someone to strengthen a test that was already fine.
# This campaign has already lost time to exactly that, from two worktrees sharing one
# compiler cache.
#
# Keyed on the absolute path of the checkout rather than its basename: worktrees are
# siblings with distinct basenames today, but a name is not an identity, and two
# clones of the same repo in different parents would collide again. `cksum` is POSIX,
# unlike `shasum`/`sha1sum`, which differ across macOS and Linux — this script runs on
# both. The basename is kept in the path only so a human can tell the directories
# apart.
if [ -n "${CT_NIM_CACHE_ROOT:-}" ]; then
	cache_root="${CT_NIM_CACHE_ROOT}"
else
	_ct_checkout="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
	_ct_tag="$(printf '%s' "${_ct_checkout}" | cksum | awk '{print $1}')"
	# Per account too, as ci/lib/nim-cache-root.sh says: a shared /tmp root
	# created by one runner user refuses the others.
	cache_root="/tmp/ct-nim-cache-$(id -u)/$(basename "${_ct_checkout}")-${_ct_tag}"
fi
lane_timeout="${CT_LANE_TIMEOUT:-1800}"

# THE NATIVE FRONT-ENDS' STATE ROOT IS THE LANE'S OWN, not the developer's.
#
# Since PLAT-45 the terminal and the GPUI window REMEMBER their last layout by
# default (`<state root>/tui-layout.json`, `<state root>/gpui-layout.json`), and
# restore it on the next start. A suite that spawns either shipped binary
# without naming a state directory would therefore read — and, if it
# rearranged anything, write — the machine's own `~/.local/state/codetracer`,
# so its screen would depend on what a developer last did and the suite would
# change the machine it runs on. `CODETRACER_TUI_LAYOUT_DIR` is the one
# override both hosts honour (`viewmodel/host/native_state`); a suite that
# sets its own still wins, because this only fills it when it is unset.
#
# ONE DIRECTORY PER FILE, not per lane (see the loop below): a suite that docks
# a pane leaves `tui-layout.json` behind, and the next FILE would otherwise open
# that docked arrangement instead of the shared default.
#
# `XDG_STATE_HOME` too, and for the same reason: it is the fallback both hosts
# read when the override is unset, and the per-user root other tools under
# test (`ct_test`'s run store) write below. Every test program is ALSO isolated
# on its own (`src/frontend/test_support/state_isolation.nim`, force-imported
# by the `config.nims` beside each test tree), so a suite compiled by hand or
# by a mutation harness is covered; this is the lane's belt to that brace.
_ct_lane_state=""
if [ -z "${CODETRACER_TUI_LAYOUT_DIR:-}" ]; then
	_ct_lane_state="$(mktemp -d "${TMPDIR:-/tmp}/ct-lane-state.XXXXXX")"
fi

# EVERY FILE GETS ITS OWN `CODETRACER_HOME`.
#
# `CODETRACER_HOME` relocates every per-user location CodeTracer has — the
# trace index, the recordings, config, state, caches and the tmp/socket dir —
# in every resolver (Nim `src/common/ct_home.nim`, Rust `libs/ct-home`), on
# every OS, and children inherit it. Before it existed a suite had to redirect
# HOME, USERPROFILE, APPDATA, LOCALAPPDATA, XDG_* and TMPDIR and still missed
# one: on 2026-09-23 the trace_index suites wrote a developer's real
# `trace_index.db` on Windows. One directory per file, for the same reason as
# the layout directory above. A caller's scratch `CODETRACER_HOME` (a harness
# that inspects it afterwards) is kept as the root the per-file directories
# are made under; otherwise the root is a fresh temporary directory. Every
# test program also isolates itself (`state_isolation.nim`); this is the
# lane's belt to that brace. `src/common/ct_home_isolation_test.nim` fails if
# this block goes away.
#
# "Scratch" is the rule every test program applies (state_isolation.nim,
# libs/ct-home): inside the temp directory, or marked with a
# `.codetracer-test-home` file. A CODETRACER_HOME the developer exported for
# their own use is NOT reused — the per-file directories would be created in it.
_ct_lane_home_owned=""
_ct_lane_tmp="${TMPDIR:-/tmp}"
_ct_lane_tmp="${_ct_lane_tmp%/}"
case "${CODETRACER_HOME:-}" in
"") _ct_lane_home_scratch="" ;;
"${_ct_lane_tmp}"/*) _ct_lane_home_scratch=1 ;;
*) [ -f "${CODETRACER_HOME}/.codetracer-test-home" ] &&
	_ct_lane_home_scratch=1 || _ct_lane_home_scratch="" ;;
esac
if [ -n "${_ct_lane_home_scratch}" ]; then
	_ct_lane_home="${CODETRACER_HOME}"
else
	_ct_lane_home="$(mktemp -d "${TMPDIR:-/tmp}/ct-lane-home.XXXXXX")"
	_ct_lane_home_owned="${_ct_lane_home}"
fi
# The root this lane made is removed when it ends, unless CT_KEEP_SCRATCH_HOME=1
# asks to keep it for debugging (the knob ci/lib/codetracer-home.sh's
# `ct_remove_scratch_codetracer_home` reads too).
#
# The sandbox's RunQuota relay (`ct_user_state_sandbox_enable`) ends with this
# shell anyway; stopping it here removes its directory before the lane reports.
_ct_pool_dir=""
trap 'rm -rf ${_ct_lane_state:+"${_ct_lane_state}"} ${_ct_pool_dir:+"${_ct_pool_dir}"}
if declare -F ct_user_state_sandbox_stop >/dev/null; then ct_user_state_sandbox_stop; fi
if [ "${CT_KEEP_SCRATCH_HOME:-}" = 1 ] && [ -n "${_ct_lane_home_owned}" ]; then
	echo "lane: CT_KEEP_SCRATCH_HOME=1: kept the per-file CODETRACER_HOMEs under ${_ct_lane_home_owned}" >&2
else
	rm -rf ${_ct_lane_home_owned:+"${_ct_lane_home_owned}"}
fi' EXIT

# THE GUARD: the user's own state is READ before the lane and after it — and
# around every file below — never written, and the lane FAILS if anything there
# changed: a file that APPEARED, whose bytes CHANGED, or that DISAPPEARED. A
# deletion is damage too (a suite that "cleans up" the layout file at the
# user's path destroys the arrangement the user left), so it is not excused.
# The directories (state, config, the trace index and recordings, and the
# cache) and what is compared in each are `ct_user_state_snapshot`'s, in
# ci/lib/codetracer-home.sh, so this runner and every other entry point that
# exports a scratch `CODETRACER_HOME` guard the same thing. The per-test side
# of the same property is `tests/real_terminal/test_state_isolation.nim`,
# which runs the shipped binary against a throwaway HOME and fails on any
# change there. Someone else changing CodeTracer state on this machine while a
# lane runs (using CodeTracer, or clearing stale state by hand) trips it as
# well; the message names that possibility, and the fix is to rerun on a quiet
# host.
#
# ON LINUX EACH FILE RUNS IN A SANDBOX instead, and then nobody else can trip
# it: the run reads the user's real directories through an overlay whose
# writes land in the run's own layer, and the finding is read from that layer
# (`ct_user_state_sandbox_enable` in ci/lib/codetracer-home.sh). The snapshot
# comparison is then kept only for a directory the sandbox cannot cover. It
# was the comparison alone until 2026-11-04, when another process's
# `ct-mcr record` failed two GPUI suites that never start a recorder.
# shellcheck source=ci/lib/codetracer-home.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/codetracer-home.sh"
if ct_user_state_sandbox_enable; then
	_ct_uss_note="each file runs in a sandbox over the user's state"
else
	_ct_uss_note="no sandbox on this host; the user's state is compared around each file"
fi
ct_user_state_guard_start
_ct_user_state_where="$(ct_user_state_guard_dirs_text)"
backend="$(test_lane_backend "${lane}")"
read -r -a extra_flags <<<"$(test_lane_extra_flags "${lane}")"
lane_run_libs="$(test_lane_run_library_path "${lane}")"
# Expanded below as ${extra_flags[@]+"${extra_flags[@]}"}, not
# "${extra_flags[@]}": under `set -u`, bash 3.2 -- the /bin/bash every macOS
# ships -- treats an EMPTY array's "${a[@]}" as an unbound variable and
# aborts. Most lanes declare no extra flags, so on a Mac this runner died with
#   run-nim-test-lane.sh: line 165: extra_flags[@]: unbound variable
# before compiling a single file, on almost every lane. CI is bash 5 and never
# saw it; a developer reaching for the lane locally saw nothing else.

# A browser lane is compile-only BY CONSTRUCTION, not by the caller remembering
# a flag. Its output needs a browser: run under node it would die on `document`
# — or, far worse, load far enough to report nothing and be scored `OK (0
# tests)` by a runner that only knows "exit status 0". Forcing it here means
# `just`, CI and a developer typing the command by hand cannot disagree.
if [ "${backend}" = "js-browser" ]; then
	compile_only=1
fi

# And a lane may declare the same property for itself, for the same reason.
# `test_lane_is_compile_only` in ci/lib/test-lane-files.sh carries the argument
# and the measurement that prompted it. The flag can only ADD compile-only:
# there is deliberately no way for a caller to switch it off, because the two
# lanes that declare it are a live upload to the sharing service and a probe
# that needs a running issuer and a browser.
if [ "$(test_lane_is_compile_only "${lane}")" = "1" ]; then
	compile_only=1
fi

# A WASM lane needs `emcc` ON THE PATH, and its absence must be a FAILURE
# rather than a skip.
#
# The temptation is the other way round: emscripten is a big toolchain, it is
# not on a stock runner, and "skip when absent" reads like politeness. It is
# not. This lane exists because PLAT-17's gate is a COUNT EQUALITY against the
# native lane, and a lane that answers "0 files, nothing to do, exit 0" on the
# one machine where the toolchain quietly stopped resolving satisfies every
# aggregate that runs it while measuring nothing — which is the exact shape
# (`vm-js` behind an aggregate that never reached it) this milestone was
# written to stop reproducing. So it dies here, by name, with the remedy.
if [ "${backend}" = "wasm" ] && [ "${compile_only}" -eq 0 ]; then
	if ! command -v emcc >/dev/null 2>&1; then
		echo "ERROR: lane '${lane}' needs the Emscripten toolchain and 'emcc' is not on PATH." >&2
		echo "       Run it inside this repo's dev shell (direnv exec . just test-${lane})," >&2
		echo "       which provides emscripten; see ci/lib/test-lane-files.sh for why this" >&2
		echo "       lane is Emscripten rather than wasi-sdk." >&2
		exit 1
	fi
	if ! command -v node >/dev/null 2>&1; then
		echo "ERROR: lane '${lane}' runs its wasm32 output under node and 'node' is not on PATH." >&2
		exit 1
	fi
fi

mkdir -p test-logs "${cache_root}"

# THE WASM DEVELOPER PROFILE (ci/lib/wasm-dev-profile.sh): each C file is
# compiled by Emscripten's clang directly rather than through the `emcc`
# Python driver (the same object bytes, without a Python start-up per file),
# and objects are shared between the lane's files through a content-keyed
# cache beside their nimcaches. Set up once per lane. When Emscripten cannot
# answer the questions the profile asks, the lane builds through `emcc` as
# before; the missing-`emcc` check above has already failed the lane if it
# is absent altogether. CT_WASM_CC=emcc forces the old path.
wasm_cc=emcc
if [ "${backend}" = "wasm" ]; then
	# shellcheck source=ci/lib/wasm-dev-profile.sh
	# shellcheck disable=SC1091 # resolved at runtime from $repo_root
	source "${repo_root}/ci/lib/wasm-dev-profile.sh"
	# ONE object cache per developer, not per checkout: a module's object is
	# keyed on its preprocessed source and flags (`wasm-cc.sh`), so a second
	# checkout of the same revisions — a worktree, a mirror — reuses every
	# object the first compiled. CT_WASM_OBJ_CACHE_DIR names another place.
	wasm_obj_cache="${CT_WASM_OBJ_CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/codetracer/wasm-objects}"
	if ct_wasm_dev_profile "${wasm_obj_cache}"; then
		wasm_cc="${CT_WASM_CC_FLAGS[1]#--clang.exe:}"
	fi
fi

echo "=== ${lane}: $(test_lane_description "${lane}") ==="
echo "    (${_ct_uss_note})"
if [ "${backend}" = "wasm" ]; then
	echo "    (wasm C compiler: ${wasm_cc})"
fi
if [ "${compile_only}" -eq 1 ]; then
	echo "    (compile-only: these files are never executed — see"
	echo "     ci/lib/test-lane-files.sh for why)"
fi

failed=0
passed=0
total_oks=0
total_skips=0
total_fails=0
total_checks=0
declared_files=0
undeclared_files=0
files=0
platform_skipped=0
host_platform="$(uname -s)"

# THE POOL (ci/lib/job-pool.sh). A lane that declares itself parallel-safe
# (`test_lane_parallel_safe`) runs several files at once, each in a subshell of
# its own whose report goes to a file; the reports are printed, and the
# tallies summed, in the lane's own file order, so the output reads the same
# whatever order the files finish in. Without the user-state sandbox the guard
# compares the user's state around each file, and a write could then not be
# told apart from a neighbour's, so such a host runs one file at a time.
# CT_LANE_JOBS sets the size for any lane; CT_LANE_JOBS=1 is serial.
# shellcheck source=ci/lib/job-pool.sh
# shellcheck disable=SC1091 # resolved at runtime from $repo_root
source "${repo_root}/ci/lib/job-pool.sh"
_ct_pool_size=1
if [ -n "${CT_LANE_JOBS:-}" ] || { declare -F test_lane_parallel_safe >/dev/null &&
	[ "$(test_lane_parallel_safe "${lane}")" = "1" ]; }; then
	_ct_pool_size="$(ct_pool_size 2048)" || exit 2
fi
if [ "${_ct_pool_size}" -gt 1 ] && [ -z "${CT_LANE_JOBS:-}" ] && [ -z "${_ct_uss_enabled:-}" ]; then
	_ct_pool_size=1
fi
if [ "${_ct_pool_size}" -gt 1 ]; then
	extra_flags+=("--parallelBuild:$(ct_pool_parallel_build "${_ct_pool_size}")")
fi
_ct_caller_plugin_scratch="${CT_PLUGIN_TEST_SCRATCH:-}"
_ct_pool_dir="$(mktemp -d "${TMPDIR:-/tmp}/ct-lane-pool.XXXXXX")"
_ct_timings="test-logs/${lane}${NIM_TEST_LANE_SHARD:+.shard-${NIM_TEST_LANE_SHARD%%/*}-of-${NIM_TEST_LANE_SHARD##*/}}.timings.tsv"
echo "    (${_ct_pool_size} file(s) at a time, from $(ct_pool_basis); per-file times in ${_ct_timings})"

# Seconds, with a fraction where bash has one (EPOCHREALTIME is bash 5).
_ct_now() {
	if [ -n "${EPOCHREALTIME:-}" ]; then
		printf '%s\n' "${EPOCHREALTIME}"
	else
		date +%s
	fi
}

# A FAILING FILE'S WHOLE OUTPUT, after the excerpt its verdict prints. The
# excerpt is what a reader scans; the whole output is what a reader who has to
# find the cause needs, and with files running in parallel it is no longer
# next to anything else that might show it. Folded on GitHub Actions.
lane_full_output() {
	local file="$1" what="$2" text="$3"
	if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
		echo "::group::${file}: full ${what}"
	else
		echo "      --- ${file}: full ${what} ---"
	fi
	printf '%s\n' "${text}" | sed 's/^/      /'
	if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
		echo "::endgroup::"
	else
		echo "      --- end of ${file} ---"
	fi
}

# ONE FILE, in a subshell: its report goes to <i>.out and <i>.err, and its
# tallies (and times) to <i>.res, written when the subshell exits, whichever
# branch it leaves by -- each `exit 0` below is the old loop's `continue`.
# `lane_one_file` runs `lane_file_body` in that subshell.
lane_file_body() {
	# Not `local`: the EXIT trap reads them after the function has returned.
	idx="$1" f="$2"
	files=0 failed=0 passed=0 total_oks=0 total_skips=0 total_checks=0
	declared_files=0 undeclared_files=0 platform_skipped=0
	_ct_started="$(_ct_now)"
	_ct_compiled=""
	_ct_ended=""
	trap '_ct_ended="$(_ct_now)"
printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
	"${files}" "${passed}" "${failed}" "${total_oks}" "${total_skips}" \
	"${total_checks}" "${declared_files}" "${undeclared_files}" "${platform_skipped}" \
	"${_ct_started}" "${_ct_compiled:-${_ct_ended}}" "${_ct_ended}" \
	>"${_ct_pool_dir}/${idx}.res.tmp" && mv -f "${_ct_pool_dir}/${idx}.res.tmp" "${_ct_pool_dir}/${idx}.res"' EXIT
	files=$((files + 1))
	# Reject only a declared platform mismatch, before invoking the compiler.
	# The full discovered inventory remains intact for coverage accounting.
	skip_reason="$(test_lane_file_skip_reason "${f}" "${host_platform}")"
	if [ -n "${skip_reason}" ]; then
		printf '  %s ... SKIPPED (%s)\n' "${f}" "${skip_reason}"
		platform_skipped=$((platform_skipped + 1))
		exit 0
	fi
	name="$(basename "${f}" .nim)"
	cache="${cache_root}/${lane}-${name}"
	mkdir -p "${_ct_lane_home}/${name}"
	export CODETRACER_HOME="${_ct_lane_home}/${name}"
	# The plugin fixtures' build scratch is shared by every file that uses
	# them; files running at the same time get one each instead.
	if [ "${_ct_pool_size}" -gt 1 ] && [ -z "${_ct_caller_plugin_scratch}" ]; then
		mkdir -p "${_ct_lane_home}/${name}.plugin-scratch"
		export CT_PLUGIN_TEST_SCRATCH="${_ct_lane_home}/${name}.plugin-scratch"
	fi
	# AND THE TWO OTHER XDG ROOTS, per file, beside it: `XDG_DATA_HOME` (the
	# freedesktop trash, `ct install`'s launchers, and any tool under test that
	# keeps data by the XDG rule) and `XDG_CONFIG_HOME` (config read or written
	# by a tool that does not know `CODETRACER_HOME`). CodeTracer's own
	# resolvers take `CODETRACER_HOME` first, so for them this changes nothing;
	# it closes the route for everything else a suite starts. `XDG_STATE_HOME`
	# is set below with the layout directory. `HOME` itself is kept: the
	# toolchain (nimble's packages, git's identity, nix) reads it.
	mkdir -p "${_ct_lane_home}/${name}.xdg-data" "${_ct_lane_home}/${name}.xdg-config"
	export XDG_DATA_HOME="${_ct_lane_home}/${name}.xdg-data"
	export XDG_CONFIG_HOME="${_ct_lane_home}/${name}.xdg-config"
	if [ -n "${_ct_lane_state}" ]; then
		mkdir -p "${_ct_lane_state}/${name}"
		export CODETRACER_TUI_LAYOUT_DIR="${_ct_lane_state}/${name}"
		mkdir -p "${_ct_lane_state}/${name}.xdg-state"
		export XDG_STATE_HOME="${_ct_lane_state}/${name}.xdg-state"
	fi
	printf '  %s ... ' "${f}"

	if [ "${backend}" = "js" ]; then
		# `-d:nodejs` is load-bearing: without it `std/exitprocs
		# .setProgramResult` is undeclared on the JS target, `std/unittest`
		# substitutes a no-op, and node exits 0 even when a case fails.
		compile_cmd=(nim js -d:nodejs --hints:off --warnings:off
			${extra_flags[@]+"${extra_flags[@]}"} --nimcache:"${cache}" -o:"${cache}/${name}.js" "${f}")
		artifact="${cache}/${name}.js"
	elif [ "${backend}" = "js-browser" ] || [ "${backend}" = "js-dom" ] ||
		[ "${backend}" = "js-chromium" ]; then
		# `nim js` WITHOUT `-d:nodejs`. See test_lane_backend's header: the
		# define enables unittest exit status in the ordinary node lanes, but
		# also makes std/dom replace the page's document with a dummy object.
		# Browser lanes must keep the actual page bindings even when a node-
		# targeted compile happens to succeed.
		compile_cmd=(nim js --hints:off --warnings:off
			${extra_flags[@]+"${extra_flags[@]}"} --nimcache:"${cache}" -o:"${cache}/${name}.js" "${f}")
		artifact="${cache}/${name}.js"
	elif [ "${backend}" = "wasm" ]; then
		# THE THIRD BACKEND (PLAT-17). `nim c` to a wasm32 linear-memory
		# target through Emscripten, run under node. Every flag is
		# load-bearing; none is decoration.
		#
		#   --cpu:wasm32 --os:linux
		#       Nim's own target selection. `--cpu:wasm32` is also what
		#       defines the `wasm32` symbol that `nim_everywhere/
		#       async_compat.platformIsWasm` reads, so the WASM arm of
		#       `drainPlatformCallbacks` is selected by the TARGET rather
		#       than by a define somebody has to remember. `--os:linux`
		#       because emscripten's libc is the POSIX one; `--os:standalone`
		#       would take away `std/os` and shrink the file set, which is
		#       what the gate forbids.
		#
		#   -d:emscripten
		#       The explicit spelling of the same thing, for anything that
		#       branches on the toolchain rather than the cpu.
		#
		#   --cc:clang --clang.exe:… --clang.linkerexe:emcc
		#       Route Nim's C compile and link through Emscripten. `emcc` IS
		#       clang, so `--cc:clang`'s flag vocabulary is the right one.
		#       The compiler is `ci/lib/wasm-cc.sh` under the developer
		#       profile set up above the loop (Emscripten's clang with
		#       `emcc --cflags`, and the shared object cache), `emcc` without
		#       it; the link is `emcc` either way.
		#
		#   --mm:orc
		#       PLAT-17's deliverable, and not a default: Nim 2.x's default
		#       IS orc, but a lane that relies on a default cannot say which
		#       memory manager its numbers were taken under, and every timing
		#       or footprint claim in this area has to (Verification-Harness
		#       -Traps.md §12b).
		#
		#   --threads:off
		#       Emscripten's pthreads need SharedArrayBuffer and
		#       COOP/COEP headers in a browser, and Nim's default
		#       `--threads:on` links the `-mt` variants of emscripten's
		#       system libraries. The reactive core is single-threaded by
		#       construction, so this costs nothing and keeps the artifact
		#       loadable from an ordinary page.
		#
		#   -sSTACK_SIZE=8388608
		#       THE ONE FLAG FOUND BY A FAILURE RATHER THAN BY READING.
		#       Emscripten's default stack is 64 KB; a native thread's is
		#       8 MiB. Two suites here recurse deep enough to sit between
		#       the two — `test_verification_payload` reported
		#       `RuntimeError: memory access out of bounds` after 42 of its
		#       56 cases, with a stack trace of one wasm function calling
		#       itself. A stack overflow on this target is NOT a Nim
		#       `StackOverflowDefect`; it is an out-of-bounds linear-memory
		#       access with no Nim frame in it, so it reads as a miscompile
		#       until you count the repeats. Matching the native stack is
		#       what makes "the same suites, the same counts" a statement
		#       about the PROGRAM rather than about two different stack
		#       budgets.
		#
		#   -sNODERAWFS=1
		#       Use node's real filesystem instead of emscripten's in-memory
		#       MEMFS. This is the flag that decides the FILE SET: without
		#       it every suite that reads a fixture, writes a temporary
		#       directory or walks `src/frontend/ui/*.nim` would have to be
		#       excluded, and the lane would be `vm-unit` minus a dozen
		#       files for a reason that is about the harness rather than
		#       about the platform.
		#
		#   -sALLOW_MEMORY_GROWTH=1
		#       Linear memory starts small and grows. The reactive core's
		#       allocation shape is many small short-lived `ref`s with a
		#       per-mount peak far above its steady state; a fixed
		#       INITIAL_MEMORY large enough for the peak would make every
		#       module pay the peak.
		#
		#   -sEXIT_RUNTIME=1
		#       Run `exit()`'s handlers and PROPAGATE the status. Without
		#       it a failing suite can exit 0 — the same defect class as the
		#       missing `-d:nodejs` on the JS lane above, and the reason
		#       ci/test/vm-unit-wasm-lane-test.sh proves this one against
		#       the real toolchain instead of grepping for it.
		compile_cmd=(nim c --hints:off --warnings:off
			--cpu:wasm32 --os:linux -d:emscripten
			--cc:clang --clang.exe:"${wasm_cc}" --clang.linkerexe:emcc
			--mm:orc --threads:off
			--passL:-sSTACK_SIZE=8388608
			--passL:-sNODERAWFS=1
			--passL:-sALLOW_MEMORY_GROWTH=1
			--passL:-sEXIT_RUNTIME=1
			"${extra_flags[@]}" --nimcache:"${cache}" -o:"${cache}/${name}.js" "${f}")
		artifact="${cache}/${name}.js"
	else
		# `--mm:orc` is named here although it is Nim 2's default, so a
		# native column names the memory manager it was measured under, as
		# the wasm arm above does: the vm-unit-wasm parity gate compares this
		# arm's counts against that one's, and a comparison whose one side
		# inherits a compiler default cannot say what it compared.
		# ci/test/vm-unit-wasm-lane-test.sh asserts it. A lane whose extra
		# flags name another manager (`--mm:refc`) still gets that one: the
		# extra flags come after it, and the last `--mm` wins.
		compile_cmd=(nim c --hints:off --warnings:off --mm:orc
			${extra_flags[@]+"${extra_flags[@]}"} --nimcache:"${cache}" -o:"${cache}/${name}" "${f}")
		artifact="${cache}/${name}"
	fi

	if ! compile_output="$(timeout "${lane_timeout}" "${compile_cmd[@]}" 2>&1)"; then
		_ct_compiled="$(_ct_now)"
		echo "COMPILE ERROR"
		printf '%s\n' "${compile_output}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		lane_full_output "${f}" "compiler output" "${compile_output}"
		failed=$((failed + 1))
		exit 0
	fi
	_ct_compiled="$(_ct_now)"

	if [ "${compile_only}" -eq 1 ]; then
		echo "COMPILES (not executed)"
		passed=$((passed + 1))
		exit 0
	fi

	# THE GUARD, PER FILE: the user's state is read again around this file's
	# run, so a write is reported against the file that was running when it
	# happened (the lane-level comparison at the end can only say "this
	# lane"). The file fails. A writer elsewhere on the host at the same moment
	# (CodeTracer in use, another checkout's tests) is the other possible
	# cause, and the message says so; run the file again on a quiet host.
	_ct_file_before="$(ct_user_state_snapshot)"
	# The file's own sandbox layers (empty prefix when there is no sandbox).
	_ct_uss_root="${_ct_lane_home}/${name}.user-state-layers"
	ct_user_state_sandbox_prefix "${_ct_uss_root}"

	ct_libs="${CT_LD_LIBRARY_PATH:-${CODETRACER_LD_LIBRARY_PATH:-}}"
	# The lane's own run-time libraries (`test_lane_run_library_path`), in
	# front of the dev shell's set; each part only when non-empty, since an
	# empty element makes the loader search the current directory.
	if [ -n "${lane_run_libs}" ]; then
		ct_libs="${lane_run_libs}${ct_libs:+:${ct_libs}}"
	fi
	if [ "${backend}" = "js" ]; then
		output="$(timeout "${lane_timeout}" ${ct_uss_cmd[@]+"${ct_uss_cmd[@]}"} node "${artifact}" 2>&1)" && rc=0 || rc=$?
	elif [ "${backend}" = "js-dom" ]; then
		# A browser-target module, run over jsdom's DOM. The runner fails
		# (exit 2) when `node_modules/jsdom` is absent rather than skipping.
		output="$(timeout "${lane_timeout}" ${ct_uss_cmd[@]+"${ct_uss_cmd[@]}"} node src/frontend/tests/jsdom-run.mjs "${artifact}" 2>&1)" && rc=0 || rc=$?
	elif [ "${backend}" = "js-chromium" ]; then
		# A browser-target module, run in a real page in headless Chromium.
		# The runner fails (exit 2) when Playwright or its Chromium is absent
		# rather than skipping, and fails (exit 1) on a `[FAILED]` line, an
		# uncaught page error, or a suite that never reports it finished.
		output="$(timeout "${lane_timeout}" ${ct_uss_cmd[@]+"${ct_uss_cmd[@]}"} node src/frontend/tests/chromium-run.mjs "${artifact}" 2>&1)" && rc=0 || rc=$?
	elif [ "${backend}" = "wasm" ]; then
		# `emcc -o <name>.js` emits a JS loader beside the `.wasm`; node runs
		# the loader, which instantiates the module and calls `main`.
		#
		# No `LD_LIBRARY_PATH`: a wasm32 module links no host shared object,
		# which is one of the two reasons this lane is cheaper to run than
		# the native one (the other is that `emcc`'s output needs no
		# `CT_LD_LIBRARY_PATH` sqlite/pcre/glib set to START, so a missing
		# library cannot be mistaken here for a failing assertion).
		#
		# `2>&1` matters more than usual: emscripten writes its
		# `warning: unsupported syscall: …` diagnostics to stderr, and those
		# are the lines that say a suite reached for something the shipping
		# host has not got. Discarding them would leave the lane green over
		# a module that only works by emulation.
		output="$(timeout "${lane_timeout}" ${ct_uss_cmd[@]+"${ct_uss_cmd[@]}"} node "${artifact}" 2>&1)" && rc=0 || rc=$?
	else
		run_lib_path="${ct_libs}"
		if [ -n "${LD_LIBRARY_PATH:-}" ]; then
			run_lib_path="${run_lib_path:+${run_lib_path}:}${LD_LIBRARY_PATH}"
		fi
		output="$(LD_LIBRARY_PATH="${run_lib_path}" \
			timeout "${lane_timeout}" ${ct_uss_cmd[@]+"${ct_uss_cmd[@]}"} "${artifact}" 2>&1)" && rc=0 || rc=$?
	fi

	# What the file's own sandbox caught first: those writes were this
	# file's (or a binary it spawned), and nobody else's.
	_ct_uss_found="$(ct_user_state_sandbox_findings "${_ct_uss_root}")"
	if [ -n "${_ct_uss_found}" ]; then
		echo "TOUCHED THE USER'S STATE"
		{
			echo "      ${f} changed the user's own CodeTracer state while it ran" \
				"(a file created, rewritten or removed under ${_ct_user_state_where})." \
				"It ran in a sandbox, so these changes were this file's and were" \
				"kept out of the real directories:"
			printf '%s\n' "${_ct_uss_found}" | sed 's/^/        /'
		} >&2
		failed=$((failed + 1))
		exit 0
	fi
	_ct_file_after="$(ct_user_state_snapshot)"
	if [ "${_ct_file_after}" != "${_ct_file_before}" ]; then
		echo "TOUCHED THE USER'S STATE"
		{
			echo "      ${f} changed the user's own CodeTracer state while it ran" \
				"(a file created, rewritten or removed under ${_ct_user_state_where})." \
				"If CodeTracer was in use on this machine at the same moment, that is" \
				"the other possible cause:"
			diff <(printf '%s\n' "${_ct_file_before}") \
				<(printf '%s\n' "${_ct_file_after}") | grep '^[<>]' |
				sed 's/^</        before:/; s/^>/        after: /'
		} >&2
		failed=$((failed + 1))
		exit 0
	fi

	oks="$(printf '%s\n' "${output}" | grep -c '\[OK\]' || true)"
	fails="$(printf '%s\n' "${output}" | grep -c '\[FAILED\]' || true)"
	skips="$(printf '%s\n' "${output}" | grep -c '\[SKIPPED\]' || true)"

	# THE ASSERTION COUNT, WHEN THE FILE STATES ONE. `oks` above is a count of
	# `[OK]` lines, and `std/unittest` prints one per TEST BLOCK, never one per
	# `check` — so a file of empty cases scores `OK (n tests)`. Nothing in the
	# unittest output carries an assertion count, and no `OutputFormatter` hook
	# fires on a check that PASSES, so the number has to come from the file:
	#
	#     CHECKS: <n>
	#
	# on a line of its own. The convention already exists here by hand —
	# `test_wasm_worker.nim` compares `asyncOk + asyncFailed` against a declared
	# `expectedAsyncChecks`, and `test_opfs_volume.nim` keeps a `checksRun`
	# counter and refuses to exit 0 at zero — and this makes the lane able to
	# read it instead of each file re-implementing the refusal.
	#
	# Summed, not taken once: a file may print a count per suite.
	checks=""
	if grep -qE '^[[:space:]]*CHECKS:[[:space:]]*[0-9]+' <<<"${output}"; then
		checks="$(printf '%s\n' "${output}" |
			grep -oE '^[[:space:]]*CHECKS:[[:space:]]*[0-9]+' |
			grep -oE '[0-9]+' | awk '{s += $1} END {print s + 0}')"
		total_checks=$((total_checks + checks))
		declared_files=$((declared_files + 1))
	elif grep -qE '^[[:space:]]*const[[:space:]]+ExpectedAssertions[[:space:]]*=[[:space:]]*[0-9]+' "${f}" 2>/dev/null; then
		# THE CONVENTION THIS TREE ALREADY HAS, READ INSTEAD OF REPLACED.
		#
		# 27 files under `src/frontend/viewmodel/tests/unit/` declare
		#
		#     const ExpectedAssertions = <n>
		#
		# and ALL 27 also assert `countedAssertions == ExpectedAssertions` in a
		# case of their own. That second half is what makes the number readable
		# from here: the file is not merely claiming a count, it FAILS when its
		# own tally disagrees — so on a run that exited 0, `<n>` has been
		# validated by the file against itself.
		#
		# Reading it costs nothing and makes the tally meaningful today, for 27
		# of the 63 files in the `vm-unit` lane. Inventing `CHECKS:` and waiting
		# for adoption would have left the report at "0 declared" indefinitely,
		# which is the same shape as the flag nobody sets.
		#
		# `CHECKS:` above still wins when present: it is a RUNTIME count, and a
		# static one cannot see a case that returned early.
		checks="$(grep -oE '^[[:space:]]*const[[:space:]]+ExpectedAssertions[[:space:]]*=[[:space:]]*[0-9]+' "${f}" |
			grep -oE '[0-9]+$' | head -1)"
		total_checks=$((total_checks + checks))
		declared_files=$((declared_files + 1))
	else
		undeclared_files=$((undeclared_files + 1))
	fi

	total_oks=$((total_oks + oks))
	total_skips=$((total_skips + skips))
	total_fails=$((total_fails + fails))
	verdict="$(classify_test_run "${rc}" "${oks}" "${fails}" "${checks}")"
	test_run_headline "${verdict}" "${rc}" "${oks}" "${fails}" "${skips}"

	# THE KNOWN-FAILURE LEDGER (ci/lib/known-test-failures.tsv).
	#
	# Consulted for `ok` AND `partial`, and for NOTHING ELSE. Both directions
	# matter and the second is the one that makes this a mechanism rather than
	# a mute button:
	#
	#   partial — the reds may be exactly the registered ones, in which case
	#             the file is settled and the lane stays green;
	#   ok      — a registered test that has started PASSING must redden the
	#             lane by name, so the entry gets deleted instead of quietly
	#             outliving its defect.
	#
	# `crashed`, `no-results` and `silent-failure` are deliberately NOT offered
	# to it. A registration excuses a named case that ran and failed for a named
	# reason; it must never excuse a suite that died, reported nothing, or
	# exited non-zero with no failure to point at. That is the shape of the trap
	# a sibling repo hit — a ledger entry that went on swallowing an exit code
	# after the run had started throwing on its first line — and the guard is
	# here, at the only place that can see the process's exit status.
	kf_out=""
	kf_rc=0
	case "${verdict}" in
	ok | partial)
		kf_out="$(printf '%s\n' "${output}" |
			python3 "${repo_root}/ci/lib/known_failures.py" \
				reconcile "${lane}" "${f}" 2>&1)" || kf_rc=$?
		;;
	esac
	if [ -n "${kf_out}" ]; then
		printf '%s\n' "${kf_out}" | sed 's/^/      /'
	fi
	if [ "${kf_rc}" -eq 1 ]; then
		lane_full_output "${f}" "test output" "${output}"
		failed=$((failed + 1))
		exit 0
	fi
	if [ "${kf_rc}" -eq 3 ]; then
		# Settled: every red is registered and failed for its registered
		# reason. Counted as passed so the lane's verdict reflects "nothing
		# here is unaccounted for" — the count of registrations is printed
		# above, so this is never silent.
		passed=$((passed + 1))
		exit 0
	fi

	case "${verdict}" in
	ok)
		passed=$((passed + 1))
		# A green file that skipped cases has to say WHY, on the spot. The
		# reasons are already printed by the suites themselves — the repo's
		# `MISSING-RECORDER SKIP:` convention, CTUI-1's `MISSING-PREREQ SKIP:`
		# (a fixture can be blocked by something that is not a recorder binary,
		# see src/frontend/tui/tests/fixtures/fixture_provider.nim) and
		# `language_smoke_test`'s `SKIP: <lang> recorder not available` — but
		# the runner used to show a file's output only when it FAILED, so on a
		# green file those lines went into the log and never into the report.
		# Surfacing them here is what turns "OK (5 tests, 10 SKIPPED)" from a
		# number into something a reader can act on.
		#
		# The alternation matters more than it looks: the per-file output is
		# CAPTURED, not tee'd, so a marker this grep does not match is absent
		# from the report AND from test-logs/<lane>.log — the run reports
		# "2 SKIPPED" and no reason anywhere. Measured on `just test-tui`
		# before `MISSING-PREREQ SKIP:` was added here: `grep -c MISSING-PREREQ
		# test-logs/test-tui.log` answered 0 over a run that skipped two cases
		# for that exact reason. A new marker must be added here as well as to
		# the suite that emits it.
		if [ "${skips}" -gt 0 ]; then
			printf '%s\n' "${output}" |
				grep -E 'MISSING-(RECORDER|PREREQ) SKIP:|^[[:space:]]*SKIP:' |
				sort -u | head -10 | sed 's/^/      /'
		fi
		;;
	no-results)
		# It BUILT, so this is not a compile error: the binary could not start,
		# or ran and reported nothing. Show all of its output — the reason is in
		# there, and filtering is exactly what lost it last time (a
		# `could not load: libsqlite3.so` line that matched no `Error:` grep).
		printf '%s\n' "${output}" | head -20 | sed 's/^/      /'
		lane_full_output "${f}" "test output" "${output}"
		failed=$((failed + 1))
		;;
	crashed)
		# What it managed to report AND how it died: the traceback in the tail
		# names the line, which is what turns "it crashed" into "here is the
		# case that crashed it".
		printf '%s\n' "${output}" | grep '\[FAILED\]' | sed 's/^/      /'
		printf '%s\n' "${output}" | tail -20 | sed 's/^/      /'
		lane_full_output "${f}" "test output" "${output}"
		failed=$((failed + 1))
		;;
	silent-failure)
		printf '%s\n' "${output}" |
			grep -E 'Check failed|Error|Exception|SIGSEGV' | head -20 | sed 's/^/      /'
		lane_full_output "${f}" "test output" "${output}"
		failed=$((failed + 1))
		;;
	*)
		# `-B` is load-bearing, not decoration. Nim's `unittest` prints the
		# evidence -- `checkpoint` output, `Check failed: <expr>` and the
		# `<name> was <value>` lines -- BEFORE the `[FAILED] <test name>`
		# marker. Grepping for the marker alone therefore reports *that* a test
		# failed while showing none of *why*, which is how a real defect in this
		# repo's own trace_index migration cost a full extra
		# reproduce-from-scratch cycle: the lane said
		# `[FAILED] recording a real program produces a real container` and
		# discarded the `[codetracer] FATAL:` line immediately above it that
		# named the cause.
		#
		# Consolidating six hand-copied loops into this runner is precisely the
		# kind of change that quietly loses a lesson like that, so it is
		# recorded here rather than left to the reader of a diff.
		printf '%s\n' "${output}" |
			grep -B 25 -A 12 '\[FAILED\]' | head -120 | sed 's/^/      /'
		lane_full_output "${f}" "test output" "${output}"
		failed=$((failed + 1))
		;;
	esac
}
lane_one_file() {
	(lane_file_body "$1" "$2") >"${_ct_pool_dir}/$1.out" 2>"${_ct_pool_dir}/$1.err"
}

# Print every finished report that is next in file order, and add its
# tallies to the lane's.
_ct_next=0
lane_flush() {
	local r res_files res_passed res_failed res_oks res_skips res_checks
	local res_declared res_undeclared res_platform t0 t1 t2 outcome
	while [ "${_ct_next}" -lt "${_ct_count}" ] && [ -f "${_ct_pool_dir}/${_ct_next}.res" ]; do
		r="${_ct_pool_dir}/${_ct_next}"
		cat "${r}.out"
		cat "${r}.err" >&2
		IFS=$'\t' read -r res_files res_passed res_failed res_oks res_skips res_checks \
			res_declared res_undeclared res_platform t0 t1 t2 <"${r}.res"
		files=$((files + res_files))
		passed=$((passed + res_passed))
		failed=$((failed + res_failed))
		total_oks=$((total_oks + res_oks))
		total_skips=$((total_skips + res_skips))
		total_checks=$((total_checks + res_checks))
		declared_files=$((declared_files + res_declared))
		undeclared_files=$((undeclared_files + res_undeclared))
		platform_skipped=$((platform_skipped + res_platform))
		if [ "${res_failed}" -gt 0 ]; then
			outcome=failed
		elif [ "${res_platform}" -gt 0 ]; then
			outcome=skipped
		else
			outcome=passed
		fi
		awk -v f="${_ct_files[${_ct_next}]}" -v o="${outcome}" -v a="${t0}" -v b="${t1}" -v c="${t2}" \
			'BEGIN { printf "%s\t%s\t%.1f\t%.1f\n", f, o, b - a, c - b }' >>"${_ct_timings}"
		rm -f "${r}.out" "${r}.err" "${r}.res"
		_ct_next=$((_ct_next + 1))
	done
}

_ct_files=()
while read -r f; do
	[ -n "${f}" ] && _ct_files+=("${f}")
done < <(lane_run_files)
_ct_count="${#_ct_files[@]}"
printf 'file\toutcome\tcompile_s\trun_s\n' >"${_ct_timings}"
_ct_pids=""
_ct_i=0
while [ "${_ct_i}" -lt "${_ct_count}" ]; do
	if [ "${_ct_pool_size}" -le 1 ]; then
		lane_one_file "${_ct_i}" "${_ct_files[${_ct_i}]}"
	else
		ct_pool_wait_for_slot "${_ct_pool_size}" "${_ct_pids}"
		lane_one_file "${_ct_i}" "${_ct_files[${_ct_i}]}" &
		_ct_pids="${_ct_pids} $!"
	fi
	lane_flush
	_ct_i=$((_ct_i + 1))
done
wait
lane_flush
# A file whose subshell died before it could write its report (killed from
# outside) has no verdict; that is a failure of the lane, never a gap in it.
if [ "${_ct_next}" -lt "${_ct_count}" ]; then
	echo "ERROR: lane '${lane}': no report for ${_ct_files[${_ct_next}]} (its run was killed?)" >&2
	exit 1
fi

echo ""
if [ "${total_skips}" -gt 0 ]; then
	echo "${lane}: ${passed} file(s) passed, ${failed} failed, ${total_oks} case(s)," \
		"${total_skips} SKIPPED"
else
	echo "${lane}: ${passed} file(s) passed, ${failed} failed, ${total_oks} case(s)"
fi

if [ "${platform_skipped}" -gt 0 ]; then
	echo "${lane}: ${platform_skipped} file(s) SKIPPED (platform eligibility)"
fi

# The same tally once more, as one machine-readable line, for a caller that
# aggregates lanes into a TEST-COUNTS report (ci/test/php-recorder-consumers.sh).
# `case-failed` counts [FAILED] markers, so a file that crashed or failed to
# compile shows in `files-failed` and may print no case marker at all; a caller
# must read both.
echo "NIM-LANE-COUNTS: lane=${lane} files=${files} files-failed=${failed}" \
	"case-ok=${total_oks} case-failed=${total_fails} case-skipped=${total_skips}" \
	"files-platform-skipped=${platform_skipped}"

# HOW MUCH OF THAT TALLY IS AN ASSERTION COUNT, AND HOW MUCH IS CASE MARKERS.
#
# `${total_oks} case(s)` above is a count of `[OK]` lines, and one of those is
# printed per test BLOCK that did not fail — including a block that asserted
# nothing. Reporting the split is the same remedy `[SKIPPED]` gets: a number
# that cannot be scored today is still worth putting in front of the reader,
# because the alternative is a lane that looks fully measured and is not.
#
# This is a REPORT, deliberately, and it is the honest half of a two-part fix.
# The other half — requiring the declaration — cannot land until the files carry
# it, and turning absence into a failure now would redden every lane at once.
if [ "${declared_files}" -gt 0 ]; then
	echo "${lane}: ${total_checks} assertion(s) declared by ${declared_files} file(s);" \
		"${undeclared_files} file(s) declared none — for those, the case count above" \
		"is the only evidence, and a case marker is not an assertion"
else
	echo "${lane}: NO file declared an assertion count (${undeclared_files} file(s))." \
		"The case count above counts [OK] lines, which unittest prints per test" \
		"block — a block that asserts nothing prints one too. Emit 'CHECKS: <n>'" \
		"to make a file's assertions countable."
fi

# Vacuous-pass guards. A lane whose file list is empty, or whose files all
# compiled and asserted nothing, must not read as green: that is the same
# invisible-coverage failure the lane exists to prevent, one level up.
if [ "${files}" -eq 0 ]; then
	echo "ERROR: lane '${lane}' matched no files at all." >&2
	exit 1
fi
if [ "${compile_only}" -eq 0 ] && [ "${total_oks}" -eq 0 ]; then
	echo "ERROR: lane '${lane}' ran ${files} file(s) but reported no test cases." >&2
	exit 1
fi

# A registration against a file this lane does not run is unreachable: nothing
# will ever observe it going green, so it can never be retired, and it sits
# there implying somebody is watching a red that nobody runs. The per-file
# reconciliation above cannot see this — it only ever looks at files that ran —
# so the whole-lane view is checked once, here.
if [ "${compile_only}" -eq 0 ]; then
	if ! kf_audit="$(test_lane_files "${lane}" |
		xargs python3 "${repo_root}/ci/lib/known_failures.py" audit "${lane}" 2>&1)"; then
		printf '%s\n' "${kf_audit}" >&2
		exit 1
	fi
fi

# The lane as a whole, once more: a write between files (or by a process a
# file left running) is reported against the lane.
ct_user_state_guard_check "lane '${lane}'" || exit 1

[ "${failed}" -eq 0 ]
