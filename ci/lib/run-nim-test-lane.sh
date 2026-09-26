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
#     compiler's own loader path.
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
#   bash ci/lib/run-nim-test-lane.sh <lane-id> [--compile-only]
#
# Environment:
#   CT_NIM_CACHE_ROOT  nimcache root (default /tmp/ct-nim-cache)
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
	echo "usage: run-nim-test-lane.sh <lane-id> [--compile-only]" >&2
	echo "lanes:" >&2
	test_lane_ids | sed 's/^/  /' >&2
	exit 2
fi
shift

compile_only=0
while [ $# -gt 0 ]; do
	case "$1" in
	--compile-only) compile_only=1 ;;
	*)
		echo "run-nim-test-lane.sh: unknown argument '$1'" >&2
		exit 2
		;;
	esac
	shift
done

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
	cache_root="/tmp/ct-nim-cache/$(basename "${_ct_checkout}")-${_ct_tag}"
fi
lane_timeout="${CT_LANE_TIMEOUT:-1800}"
backend="$(test_lane_backend "${lane}")"
read -r -a extra_flags <<<"$(test_lane_extra_flags "${lane}")"
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

echo "=== ${lane}: $(test_lane_description "${lane}") ==="
if [ "${compile_only}" -eq 1 ]; then
	echo "    (compile-only: these files are never executed — see"
	echo "     ci/lib/test-lane-files.sh for why)"
fi

failed=0
passed=0
total_oks=0
total_skips=0
total_checks=0
declared_files=0
undeclared_files=0
files=0

while read -r f; do
	[ -n "${f}" ] || continue
	files=$((files + 1))
	name="$(basename "${f}" .nim)"
	cache="${cache_root}/${lane}-${name}"
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
		# define is required by every lane that RUNS its output under node, and
		# is fatal for a browser module — `kdom`'s `createElementNS` is absent
		# under it, so the renderer does not compile at all.
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
		#   --cc:clang --clang.exe:emcc --clang.linkerexe:emcc
		#       Route Nim's C compile and link through the Emscripten
		#       wrappers. `emcc` IS clang, so `--cc:clang`'s flag vocabulary
		#       is the right one.
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
			--cc:clang --clang.exe:emcc --clang.linkerexe:emcc
			--mm:orc --threads:off
			--passL:-sSTACK_SIZE=8388608
			--passL:-sNODERAWFS=1
			--passL:-sALLOW_MEMORY_GROWTH=1
			--passL:-sEXIT_RUNTIME=1
			"${extra_flags[@]}" --nimcache:"${cache}" -o:"${cache}/${name}.js" "${f}")
		artifact="${cache}/${name}.js"
	else
		compile_cmd=(nim c --hints:off --warnings:off
			${extra_flags[@]+"${extra_flags[@]}"} --nimcache:"${cache}" -o:"${cache}/${name}" "${f}")
		artifact="${cache}/${name}"
	fi

	if ! compile_output="$(timeout "${lane_timeout}" "${compile_cmd[@]}" 2>&1)"; then
		echo "COMPILE ERROR"
		printf '%s\n' "${compile_output}" | grep -E 'Error:' | head -3 | sed 's/^/      /'
		failed=$((failed + 1))
		continue
	fi

	if [ "${compile_only}" -eq 1 ]; then
		echo "COMPILES (not executed)"
		passed=$((passed + 1))
		continue
	fi

	ct_libs="${CT_LD_LIBRARY_PATH:-${CODETRACER_LD_LIBRARY_PATH:-}}"
	if [ "${backend}" = "js" ]; then
		output="$(timeout "${lane_timeout}" node "${artifact}" 2>&1)" && rc=0 || rc=$?
	elif [ "${backend}" = "js-dom" ]; then
		# A browser-target module, run over jsdom's DOM. The runner fails
		# (exit 2) when `node_modules/jsdom` is absent rather than skipping.
		output="$(timeout "${lane_timeout}" node src/frontend/tests/jsdom-run.mjs "${artifact}" 2>&1)" && rc=0 || rc=$?
	elif [ "${backend}" = "js-chromium" ]; then
		# A browser-target module, run in a real page in headless Chromium.
		# The runner fails (exit 2) when Playwright or its Chromium is absent
		# rather than skipping, and fails (exit 1) on a `[FAILED]` line, an
		# uncaught page error, or a suite that never reports it finished.
		output="$(timeout "${lane_timeout}" node src/frontend/tests/chromium-run.mjs "${artifact}" 2>&1)" && rc=0 || rc=$?
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
		output="$(timeout "${lane_timeout}" node "${artifact}" 2>&1)" && rc=0 || rc=$?
	else
		output="$(LD_LIBRARY_PATH="${ct_libs}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			timeout "${lane_timeout}" "${artifact}" 2>&1)" && rc=0 || rc=$?
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
		failed=$((failed + 1))
		continue
	fi
	if [ "${kf_rc}" -eq 3 ]; then
		# Settled: every red is registered and failed for its registered
		# reason. Counted as passed so the lane's verdict reflects "nothing
		# here is unaccounted for" — the count of registrations is printed
		# above, so this is never silent.
		passed=$((passed + 1))
		continue
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
		failed=$((failed + 1))
		;;
	crashed)
		# What it managed to report AND how it died: the traceback in the tail
		# names the line, which is what turns "it crashed" into "here is the
		# case that crashed it".
		printf '%s\n' "${output}" | grep '\[FAILED\]' | sed 's/^/      /'
		printf '%s\n' "${output}" | tail -20 | sed 's/^/      /'
		failed=$((failed + 1))
		;;
	silent-failure)
		printf '%s\n' "${output}" |
			grep -E 'Check failed|Error|Exception|SIGSEGV' | head -20 | sed 's/^/      /'
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
		failed=$((failed + 1))
		;;
	esac
done < <(test_lane_files "${lane}")

echo ""
if [ "${total_skips}" -gt 0 ]; then
	echo "${lane}: ${passed} file(s) passed, ${failed} failed, ${total_oks} case(s)," \
		"${total_skips} SKIPPED"
else
	echo "${lane}: ${passed} file(s) passed, ${failed} failed, ${total_oks} case(s)"
fi

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

[ "${failed}" -eq 0 ]
