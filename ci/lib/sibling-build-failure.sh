# shellcheck shell=bash
# =============================================================================
# Report a failed `scripts/build-siblings.sh` run so its CAUSE reaches the
# step output.
#
# WHY
#   The launcher <-> recorder gate (ci/test/launcher-recorder-e2e.sh) captures
#   build-siblings.sh's output into a work-dir file and, on failure, used to
#   print that file's first 80 lines.  Those are build-siblings' own warnings
#   and its summary row -- "FAIL <key> build exited 101 — see <log>" -- while
#   the recorder's real build output sits in <log>, a file under
#   .tools/build-siblings-logs on a CI runner that nobody can open once the job
#   ends.  The ruby arm of codetracer run 36013311965 failed exactly like that:
#   the Actions log said "build exited 101" and nothing else.
#
#   So on failure the driver prints what build-siblings said before its
#   summary, the summary rows, and then the TAIL of each failed repo's own log (a cargo/compiler failure ends with its cause), and
#   falls back to the tail of the captured build-siblings output when no
#   per-repo log can be found.  Diagnostics only: the caller still fails hard.
#
#   It is a library, not a function inside the driver, so that
#   ci/test/sibling-build-failure-test.sh can drive the shipped code against
#   the output of the REAL build-siblings.sh without a launcher, a desktop core
#   or a recorder toolchain.
# =============================================================================

# report_sibling_build_failure <build-siblings-output> [tail-lines]
#
# <build-siblings-output> is the file the caller redirected
# `bash scripts/build-siblings.sh --only <key>` into.  Everything is written to
# stderr.  Returns 0; the caller decides whether the failure is fatal.
report_sibling_build_failure() {
	local out="$1" lines="${2:-60}" row log
	case "$lines" in
	'' | *[!0-9]* | 0) lines=60 ;;
	esac

	if [[ ! -s $out ]]; then
		echo "  (build-siblings.sh produced no output at $out)" >&2
		return 0
	fi

	# The FAIL row's detail ends in "— see <log>" (build_sibling in
	# scripts/build-siblings.sh); the test pins that coupling against the real
	# script's output.  In BUILD_SIBLINGS_VERBOSE=1 mode the row names no log,
	# because the build was streamed into <build-siblings-output> itself.
	local -a logs=()
	while IFS= read -r row; do
		log="${row##* — see }"
		[[ $log != "$row" && -s $log ]] || continue
		logs+=("$log")
	done < <(grep -E '^\s+FAIL\s' "$out" || true)

	if [[ ${#logs[@]} -eq 0 ]]; then
		echo "---- last $lines lines of $out (no per-repo build log found) ----" >&2
		tail -n "$lines" "$out" | sed 's/^/  | /' >&2
		echo "---- end of $out ----" >&2
		return 0
	fi

	# What build-siblings said before its summary (which repo it built, any
	# submodule initialisation), then the summary rows, then each log's tail.
	sed '/^==== build-siblings summary ====$/,$d' "$out" | tail -n "$lines" | sed 's/^/  | /' >&2
	grep -E '^\s+(PASS|SKIP|FAIL|MISSING)\s' "$out" | sed 's/^/  | /' >&2 || true
	for log in "${logs[@]}"; do
		echo "---- last $lines lines of $log ----" >&2
		tail -n "$lines" "$log" | sed 's/^/  | /' >&2
		echo "---- end of $log ----" >&2
	done
	return 0
}
