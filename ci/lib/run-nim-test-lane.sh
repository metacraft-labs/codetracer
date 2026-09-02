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

# A browser lane is compile-only BY CONSTRUCTION, not by the caller remembering
# a flag. Its output needs a browser: run under node it would die on `document`
# — or, far worse, load far enough to report nothing and be scored `OK (0
# tests)` by a runner that only knows "exit status 0". Forcing it here means
# `just`, CI and a developer typing the command by hand cannot disagree.
if [ "${backend}" = "js-browser" ]; then
	compile_only=1
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
			"${extra_flags[@]}" --nimcache:"${cache}" -o:"${cache}/${name}.js" "${f}")
		artifact="${cache}/${name}.js"
	elif [ "${backend}" = "js-browser" ]; then
		# `nim js` WITHOUT `-d:nodejs`. See test_lane_backend's header: the
		# define is required by every lane that RUNS its output under node, and
		# is fatal for a browser module — `kdom`'s `createElementNS` is absent
		# under it, so the renderer does not compile at all.
		compile_cmd=(nim js --hints:off --warnings:off
			"${extra_flags[@]}" --nimcache:"${cache}" -o:"${cache}/${name}.js" "${f}")
		artifact="${cache}/${name}.js"
	else
		compile_cmd=(nim c --hints:off --warnings:off
			"${extra_flags[@]}" --nimcache:"${cache}" -o:"${cache}/${name}" "${f}")
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
	else
		output="$(LD_LIBRARY_PATH="${ct_libs}${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
			timeout "${lane_timeout}" "${artifact}" 2>&1)" && rc=0 || rc=$?
	fi

	oks="$(printf '%s\n' "${output}" | grep -c '\[OK\]' || true)"
	fails="$(printf '%s\n' "${output}" | grep -c '\[FAILED\]' || true)"
	skips="$(printf '%s\n' "${output}" | grep -c '\[SKIPPED\]' || true)"
	total_oks=$((total_oks + oks))
	total_skips=$((total_skips + skips))
	verdict="$(classify_test_run "${rc}" "${oks}" "${fails}")"
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
		# `MISSING-RECORDER SKIP:` convention and `language_smoke_test`'s
		# `SKIP: <lang> recorder not available` — but the runner used to show
		# a file's output only when it FAILED, so on a green file those lines
		# went into the log and never into the report. Surfacing them here is
		# what turns "OK (5 tests, 10 SKIPPED)" from a number into something a
		# reader can act on.
		if [ "${skips}" -gt 0 ]; then
			printf '%s\n' "${output}" |
				grep -E 'MISSING-RECORDER SKIP:|^[[:space:]]*SKIP:' |
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
