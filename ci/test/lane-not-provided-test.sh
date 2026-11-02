#!/usr/bin/env bash
#
# lane-not-provided-test.sh -- contract suite for the lists of tests a lane
# declares it does not provide the tools for (ci/test/*-not-provided.*.txt).
#
# A lane that runs with CODETRACER_ALLOW_GRACEFUL_TEST_SKIPPING=false excludes
# those tests by name. An entry that names a test binary that no longer exists
# excludes nothing and says nothing, and one that is misspelled leaves the real
# test in the lane, where it fails for a missing tool the lane was never meant
# to have. So every entry must be well formed and name tests that exist:
#
#   * its filterset is `binary(<target>)` or `binary(<target>) and
#     test(/<regex>/)` -- the two forms ci/lib/not-provided-filter.sh can
#     assign to a crate;
#   * <target> is an integration test of exactly ONE crate,
#     src/db-backend/tests/<target>.rs or src/backend-manager/tests/<target>.rs.
#     In neither, it excludes nothing; in both, the filter cannot tell which
#     crate's nextest run it belongs to;
#   * a test() regex is anchored (`^...$`), uses only the syntax POSIX ERE and
#     Rust's regex crate agree on (so this suite, in bash, evaluates it the way
#     nextest will), and matches at least one `fn` in <target>.rs.
#
# Every entry must also name the lane that DOES run the test, as the id of a
# job in .github/workflows/ (optionally followed by a parenthesised note), and
# no entry may say `NO LANE`. Excluding a test from one lane is only honest
# when another lane runs it; a test that no lane runs has stopped being a test.
# A backend-manager entry's lane must select it from the list
# (`not-provided-filter.sh --lane <job>` in the justfile, scripts/ or ci/):
# that is how those lanes run them, and an entry no lane selects runs nowhere.
#
# THE PROBES. Being well formed does not make a list complete. The issue this
# suite was extended for (codetracer-pm issues/2026-10-06-non-gui-lane-runs-
# backend-manager-recorder-tests-it-does-not-provide-tools-for.md): the
# non-gui lane ran backend-manager's rr and ct-mcr tests with no filter at all,
# so they failed there on tools the lane deliberately lacks, and no lane ran
# them with the tools. So, for the non-gui lists, every test that calls a
# prerequisite probe the lane lacks (PROBES below) must be excluded by an
# entry naming the lane that provides it, and those entries must not exclude a
# test that does not call the probe -- the second half is what keeps a broad
# `^test_real_rr_` from hiding a test that needs no rr. A test whose
# `#[cfg(... target_os = "linux" ...)]` does not compile it on the list's
# platform is not required there. Only direct calls in the test's own body are
# seen; a probe reached through a helper is not.
#
# THE JUSTFILE. The list only works where it is applied: `just test-rust` must
# hand every not-provided-filter.sh call the crate its nextest run covers, and
# must apply the lane's filter to every backend-manager nextest run.
#
# Pure bash and awk; no cargo, no nix.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORKFLOWS_DIR="${CT_LANE_WORKFLOWS_DIR:-$REPO_ROOT/.github/workflows}"
JUSTFILE="${CT_LANE_JUSTFILE:-$REPO_ROOT/justfile}"
# The crates whose integration tests a list may name (overridable so the
# negative controls can build a target that exists in both).
if [ -n "${CT_LANE_CRATE_TEST_DIRS:-}" ]; then
	read -r -a CRATE_TEST_DIRS <<<"$CT_LANE_CRATE_TEST_DIRS"
else
	CRATE_TEST_DIRS=("$REPO_ROOT/src/db-backend/tests" "$REPO_ROOT/src/backend-manager/tests")
fi
BACKEND_MANAGER_TESTS="${CRATE_TEST_DIRS[1]:-$REPO_ROOT/src/backend-manager/tests}"
# The test() regex syntax this suite accepts: what POSIX ERE (bash `=~`) and
# Rust's regex crate (nextest) read the same way. No backslash at all, so no
# `\d` / `\w` / `\b` classes that one of them lacks; inside the bracket
# expression `]` comes first and `-` last, so both are literal.
PORTABLE_REGEX='^[][A-Za-z0-9_^$|().*+?-]+$'

# <list basename glob>|<test file relative to the repo>|<probe call>|<lane job id>
#
# The probe is a fixed string matched in the test's body. One row per
# (test file, lane): the "excludes only probe callers" half is checked per row.
PROBES=(
	'non-gui-not-provided.*.txt|src/backend-manager/tests/real_recording_integration.rs|check_rr_prerequisites()|rr-backend-tests'
	'non-gui-not-provided.*.txt|src/backend-manager/tests/real_recording_integration.rs|find_ct_mcr()|mcr-dap-flow'
	'non-gui-not-provided.*.txt|src/backend-manager/tests/meta_dat_real_mcr_recording.rs|find_ct_mcr()|mcr-dap-flow'
)

assertions=0
failures=0
ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}
fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
}

shopt -s nullglob globstar

# Job ids: the two-space-indented keys under a workflow's `jobs:` map.
declare -A JOBS=()
for wf in "$WORKFLOWS_DIR"/*.yml "$WORKFLOWS_DIR"/*.yaml; do
	in_jobs=0
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
		jobs:*) in_jobs=1 ;;
		[!\ \#]*) in_jobs=0 ;;
		'  '[A-Za-z0-9_-]*:*)
			if [ "$in_jobs" -eq 1 ]; then
				case "$line" in
				'   '*) ;;
				*)
					id="${line#  }"
					JOBS["${id%%:*}"]=1
					;;
				esac
			fi
			;;
		esac
	done <"$wf"
done
if [ "${#JOBS[@]}" -eq 0 ]; then
	printf 'FAIL: no job ids found under %s; the lane check would accept nothing\n' "$WORKFLOWS_DIR"
	exit 1
fi

# The files a lane's `--lane` selection may live in.
if [ -n "${CT_LANE_SELECT_SOURCES:-}" ]; then
	read -r -a SELECT_SOURCES <<<"$CT_LANE_SELECT_SOURCES"
else
	SELECT_SOURCES=("$JUSTFILE" "$REPO_ROOT"/scripts/*.sh "$REPO_ROOT"/ci/**/*.sh)
fi

trim() {
	local s="$1"
	s="${s#"${s%%[![:space:]]*}"}"
	printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# Split an entry into FSET / PREREQ / LANE. The separators are the LAST two
# `|`s: a test() regex may itself contain `|`, a prerequisite or lane never
# does. A line with a field missing yields a fragment that the form check
# below refuses.
split_entry() {
	local line="$1" rest
	LANE="$(trim "${line##*|}")"
	rest="${line%|*}"
	PREREQ="$(trim "${rest##*|}")"
	FSET="$(trim "${rest%|*}")"
	if [ "$rest" = "$line" ] || [ "${rest%|*}" = "$rest" ]; then
		PREREQ=""
	fi
}

# Parse FSET into TARGET and REGEX (empty for the whole-binary form). Returns
# 1 when FSET is neither accepted form.
parse_fset() {
	TARGET=""
	REGEX=""
	if [[ $1 =~ ^binary\(([A-Za-z0-9_]+)\)$ ]]; then
		TARGET="${BASH_REMATCH[1]}"
	elif [[ $1 =~ ^binary\(([A-Za-z0-9_]+)\)\ and\ test\(/(.+)/\)$ ]]; then
		TARGET="${BASH_REMATCH[1]}"
		REGEX="${BASH_REMATCH[2]}"
	else
		return 1
	fi
}

# The test functions of a Rust file, one per line:
#   <name> TAB <1 if a cfg attribute names target_os = "linux"> TAB <1 if its body contains PROBE>
# Top-level `#[test]` / `#[tokio::test]` functions only; that is where the
# integration tests these lists name are declared.
test_fns() { # $1 = file, $2 = probe (fixed string; may be empty)
	awk -v probe="$2" '
		function flush() {
			if (name != "" && is_test) print name "\t" linux "\t" calls
			name = ""
		}
		/^#\[(tokio::)?test/ { pend_test = 1; next }
		/^#\[cfg\(/ {
			if ($0 ~ /target_os = "linux"/ && $0 !~ /not\(/) pend_linux = 1
			next
		}
		/^#\[/ { next }
		/^(pub )?(async )?fn [A-Za-z0-9_]+/ {
			flush()
			match($0, /fn [A-Za-z0-9_]+/)
			name = substr($0, RSTART + 3, RLENGTH - 3)
			is_test = pend_test; linux = pend_linux; calls = 0
			pend_test = 0; pend_linux = 0
			next
		}
		/^[A-Za-z}]/ { flush(); pend_test = 0; pend_linux = 0 }
		{ if (name != "" && probe != "" && index($0, probe) > 0) calls = 1 }
		END { flush() }
	' "$1"
}

if [ -n "${CT_LANE_NOT_PROVIDED_LISTS:-}" ]; then
	read -r -a lists <<<"$CT_LANE_NOT_PROVIDED_LISTS"
else
	lists=("$REPO_ROOT"/ci/test/*-not-provided.*.txt)
fi
if [ "${#lists[@]}" -eq 0 ]; then
	printf 'FAIL: no ci/test/*-not-provided.*.txt list found; this suite would check nothing\n'
	exit 1
fi

for list in "${lists[@]}"; do
	printf '%s\n' "${list#"$REPO_ROOT"/}"
	entries=0
	# The well-formed entries, for the probe check below.
	e_target=()
	e_regex=()
	e_lane=()
	while IFS= read -r line; do
		case "$line" in '' | \#*) continue ;; esac
		entries=$((entries + 1))
		split_entry "$line"
		if [ -z "$PREREQ" ] || [ -z "$LANE" ]; then
			fail "$FSET: names both the missing prerequisite and the lane that runs it"
			continue
		fi
		lane_job="${LANE%%[ (]*}"
		case "$LANE" in
		[Nn][Oo]\ [Ll][Aa][Nn][Ee]*)
			fail "$FSET: no lane runs it (NO LANE); provision its prerequisite in a lane, then name that lane"
			;;
		*)
			if [ -n "${JOBS[$lane_job]:-}" ]; then
				ok "$FSET runs in $lane_job"
			else
				fail "$FSET: lane '$lane_job' is not a job id in .github/workflows/"
			fi
			;;
		esac
		if ! parse_fset "$FSET"; then
			fail "$FSET: expected binary(<test target>) or binary(<test target>) and test(/<regex>/)"
			continue
		fi
		found=()
		for dir in "${CRATE_TEST_DIRS[@]}"; do
			[ -f "$dir/$TARGET.rs" ] && found+=("$dir/$TARGET.rs")
		done
		case "${#found[@]}" in
		0)
			fail "$FSET: $TARGET.rs is in none of ${CRATE_TEST_DIRS[*]#"$REPO_ROOT"/}"
			continue
			;;
		1) ok "$TARGET exists (${found[0]#"$REPO_ROOT"/})" ;;
		*)
			fail "$FSET: $TARGET.rs is in more than one crate (${found[*]#"$REPO_ROOT"/}); the filter cannot tell which nextest run it belongs to"
			continue
			;;
		esac
		if [ -n "$REGEX" ]; then
			if [[ ! $REGEX =~ ^\^.*\$$ ]]; then
				fail "$FSET: the test() regex is not anchored with ^...\$"
				continue
			fi
			if [[ ! $REGEX =~ $PORTABLE_REGEX ]]; then
				fail "$FSET: the test() regex uses syntax outside what POSIX ERE and Rust's regex agree on (letters, digits, _ ^ \$ | ( ) [ ] - . * + ?)"
				continue
			fi
			matched=0
			while IFS= read -r fn_name; do
				if [[ $fn_name =~ $REGEX ]]; then
					matched=1
					break
				fi
			done < <(grep -oE '\bfn [A-Za-z0-9_]+' "${found[0]}" | sed 's/^fn //')
			if [ "$matched" -eq 1 ]; then
				ok "$FSET matches a fn in $TARGET.rs"
			else
				fail "$FSET: the test() regex matches no fn in ${found[0]#"$REPO_ROOT"/}"
				continue
			fi
		fi
		if [ "${found[0]}" = "$BACKEND_MANAGER_TESTS/$TARGET.rs" ]; then
			selected=0
			for src in "${SELECT_SOURCES[@]}"; do
				[ -f "$src" ] || continue
				if grep -qE "not-provided-filter\.sh\"? +--lane +\"?$lane_job\"?( |$)" "$src"; then
					selected=1
					break
				fi
			done
			if [ "$selected" -eq 1 ]; then
				ok "$FSET is selected by lane $lane_job (not-provided-filter.sh --lane)"
			else
				fail "$FSET: no script selects lane $lane_job's tests from the list (not-provided-filter.sh --lane $lane_job), so it runs nowhere"
			fi
		fi
		e_target+=("$TARGET")
		e_regex+=("$REGEX")
		e_lane+=("$lane_job")
	done <"$list"
	if [ "$entries" -eq 0 ]; then
		fail "${list#"$REPO_ROOT"/} has no entries"
	fi

	# The probes this list's lane lacks.
	base="$(basename "$list")"
	case "$base" in
	*.linux.*) platform=linux ;;
	*.macos.*) platform=macos ;;
	*.windows.*) platform=windows ;;
	*) platform=unknown ;;
	esac
	for row in "${PROBES[@]}"; do
		IFS='|' read -r glob file probe probe_lane <<<"$row"
		# shellcheck disable=SC2254 # the glob is the pattern
		case "$base" in $glob) ;; *) continue ;; esac
		target="$(basename "$file" .rs)"
		if [ ! -f "$REPO_ROOT/$file" ]; then
			fail "PROBES names $file, which does not exist"
			continue
		fi
		probed=0
		while IFS=$'\t' read -r name linux_only calls; do
			by_lane=0
			for i in "${!e_target[@]}"; do
				[ "${e_target[$i]}" = "$target" ] && [ "${e_lane[$i]}" = "$probe_lane" ] || continue
				if [ -z "${e_regex[$i]}" ] || [[ $name =~ ${e_regex[$i]} ]]; then
					by_lane=1
					break
				fi
			done
			if [ "$calls" = 1 ]; then
				probed=$((probed + 1))
				if [ "$linux_only" = 1 ] && [ "$platform" != linux ]; then
					continue
				fi
				if [ "$by_lane" -eq 0 ]; then
					fail "$target::$name calls $probe, which this lane lacks, but $base does not exclude it naming $probe_lane"
				fi
			elif [ "$by_lane" -eq 1 ]; then
				fail "$target::$name does not call $probe, but $base excludes it naming $probe_lane; it would run nowhere for no reason"
			fi
		done < <(test_fns "$REPO_ROOT/$file" "$probe")
		if [ "$probed" -eq 0 ]; then
			fail "no test in $file calls $probe; the PROBES row checks nothing (update it)"
		else
			ok "$base: the $probed test(s) in $target.rs that call $probe are excluded naming $probe_lane, and nothing else is"
		fi
	done
done

# THE JUSTFILE: the list is applied, per crate, to the backend-manager runs.
printf '%s test-rust\n' "${JUSTFILE#"$REPO_ROOT"/}"
recipe="$(awk '
	/^test-rust:/ { inside = 1; next }
	inside && /^[^ \t]/ { exit }
	inside { print }
' "$JUSTFILE")"
if [ -z "$recipe" ]; then
	fail "no test-rust recipe in ${JUSTFILE#"$REPO_ROOT"/}"
else
	calls="$(grep -v '^ *#' <<<"$recipe" | grep 'not-provided-filter\.sh' || true)"
	if [ -z "$calls" ]; then
		fail "test-rust never calls not-provided-filter.sh"
	fi
	while IFS= read -r call; do
		[ -n "$call" ] || continue
		if [[ $call =~ not-provided-filter\.sh\ +\"[^\"]*\"\ +[^\ \)]+ ]]; then
			ok "test-rust passes not-provided-filter.sh the crate it filters: $(trim "$call")"
		else
			fail "test-rust calls not-provided-filter.sh without a crate tests dir; nextest refuses the other crate's binary() names: $(trim "$call")"
		fi
	done <<<"$calls"
	section="$(awk '
		/^ *pushd src\/backend-manager/ { inside = 1; next }
		inside && /^ *popd/ { exit }
		inside && !/^ *#/ { print }
	' <<<"$recipe")"
	var="$(sed -nE 's/^ *([A-Za-z_][A-Za-z0-9_]*)="\$\(bash [^ ]*not-provided-filter\.sh .*/\1/p' <<<"$section" | head -n 1)"
	runs="$(grep 'cargo nextest run' <<<"$section" || true)"
	if [ -z "$runs" ]; then
		fail "test-rust runs no backend-manager nextest (no 'pushd src/backend-manager' section with 'cargo nextest run')"
	elif [ -z "$var" ]; then
		fail "test-rust runs backend-manager's tests without the lane's not-provided list (no not-provided-filter.sh call in its backend-manager section)"
	else
		while IFS= read -r run; do
			if [[ $run == *"\$$var"* || $run == *"\${$var}"* ]]; then
				ok "backend-manager nextest applies \$$var: $(trim "$run")"
			else
				fail "backend-manager nextest runs without the lane's not-provided filter \$$var: $(trim "$run")"
			fi
		done <<<"$runs"
	fi
fi

# The checks above must be able to fail. Run this suite against fixtures that
# each break one rule and require that every one of them is refused, so a
# check that silently stopped matching cannot keep reporting green.
if [ -z "${CT_LANE_NOT_PROVIDED_LISTS:-}" ]; then
	printf 'negative controls\n'
	fixtures="$(mktemp -d)"
	trap 'rm -rf "$fixtures"' EXIT
	db_tests="${CRATE_TEST_DIRS[0]}"
	any_binary="$(cd "$db_tests" && for f in *.rs; do
		printf '%s\n' "${f%.rs}"
		break
	done)"
	any_job="$(printf '%s\n' "${!JOBS[@]}" | sort | head -n 1)"
	any_fn="$(grep -oE '\bfn [A-Za-z0-9_]+' "$db_tests/$any_binary.rs" | head -n 1 | sed 's/^fn //')"
	bm_test=test_real_rr_query_prints_hello
	# A select source naming $any_job, so a backend-manager fixture entry
	# naming that job is selected; an empty one, so it is not.
	# shellcheck disable=SC2016 # "$list" is the fixture's text, not expanded here
	printf 'bash ci/lib/not-provided-filter.sh --lane %s "$list" src/backend-manager/tests\n' "$any_job" >"$fixtures/select.sh"
	: >"$fixtures/no-select.sh"
	# A target in both crates, for the "exactly one crate" rule.
	mkdir -p "$fixtures/crate-a" "$fixtures/crate-b"
	printf 'fn dup_test() {}\n' >"$fixtures/crate-a/dup_target.rs"
	printf 'fn dup_test() {}\n' >"$fixtures/crate-b/dup_target.rs"
	# A test-rust that runs backend-manager unfiltered, as before this fix.
	cat >"$fixtures/justfile" <<'EOF'
test-rust:
  pushd src/db-backend
  filter="$filter and ($(bash ../../ci/lib/not-provided-filter.sh "$not_provided" "$PWD/tests"))"
  cargo nextest run --release --test '*' -E "$filter"
  popd
  pushd src/backend-manager
  cargo nextest run --release
  popd
EOF
	# A test-rust that hands the filter no crate.
	# shellcheck disable=SC2016 # the justfile's text, not expanded here
	sed 's|"$not_provided" "$PWD/tests"|"$not_provided"|' "$fixtures/justfile" >"$fixtures/justfile-no-crate"
	# The real Linux list with the backend-manager rr entries dropped, and
	# with them widened to every `test_real_rr_` test.
	real_linux="$REPO_ROOT/ci/test/non-gui-not-provided.linux.txt"
	mkdir -p "$fixtures/rr-missing" "$fixtures/rr-wide"
	grep -v 'test_real_rr_\|test_cli_trace_\|test_rr_trace_' "$real_linux" >"$fixtures/rr-missing/non-gui-not-provided.linux.txt"
	sed 's|test(/^test_real_rr_(session[^/]*/)|test(/^test_real_rr_[a-z0-9_]+$/)|' "$real_linux" >"$fixtures/rr-wide/non-gui-not-provided.linux.txt"

	printf 'binary(%s) | some tool | NO LANE\n' "$any_binary" >"$fixtures/no-lane.txt"
	printf 'binary(%s) | some tool | no-such-job-anywhere\n' "$any_binary" >"$fixtures/unknown-job.txt"
	printf 'binary(no_such_test_binary) | some tool | %s\n' "$any_job" >"$fixtures/unknown-binary.txt"
	printf 'binary(%s) | | %s\n' "$any_binary" "$any_job" >"$fixtures/no-prereq.txt"
	printf 'binary(%s) or binary(%s) | some tool | %s\n' "$any_binary" "$any_binary" "$any_job" >"$fixtures/bad-form-or.txt"
	printf 'binary(%s) and not test(/^%s$/) | some tool | %s\n' "$any_binary" "$any_fn" "$any_job" >"$fixtures/bad-form-not.txt"
	printf 'test(/^%s$/) | some tool | %s\n' "$any_fn" "$any_job" >"$fixtures/bad-form-test-only.txt"
	printf 'binary(%s) and test(/%s/) | some tool | %s\n' "$any_binary" "$any_fn" "$any_job" >"$fixtures/unanchored-regex.txt"
	printf 'binary(%s) and test(/^\\w+$/) | some tool | %s\n' "$any_binary" "$any_job" >"$fixtures/non-portable-regex.txt"
	printf 'binary(%s) and test(/^no_such_fn_anywhere$/) | some tool | %s\n' "$any_binary" "$any_job" >"$fixtures/regex-matches-nothing.txt"
	printf 'binary(dup_target) | some tool | %s\n' "$any_job" >"$fixtures/target-in-both.txt"
	printf 'binary(real_recording_integration) and test(/^%s$/) | some tool | %s\n' "$bm_test" "$any_job" >"$fixtures/bm-entry.txt"
	printf 'binary(%s) | some tool | %s (a note)\n' "$any_binary" "$any_job" >"$fixtures/valid.txt"
	printf 'binary(%s) and test(/^(%s|no_such_fn)$/) | some tool | %s\n' "$any_binary" "$any_fn" "$any_job" >"$fixtures/valid-regex.txt"

	refused() { # $1 = description; the rest = env assignments for the run
		local what="$1"
		shift
		if env "$@" CT_LANE_SELECT_SOURCES="${sel:-$fixtures/select.sh}" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
			fail "$what is refused"
		else
			ok "$what is refused"
		fi
	}
	accepted() {
		local what="$1"
		shift
		if env "$@" CT_LANE_SELECT_SOURCES="${sel:-$fixtures/select.sh}" bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
			ok "$what is accepted"
		else
			fail "$what is accepted"
		fi
	}
	for bad in no-lane unknown-job unknown-binary no-prereq bad-form-or bad-form-not \
		bad-form-test-only unanchored-regex non-portable-regex regex-matches-nothing; do
		refused "a list with a $bad entry" CT_LANE_NOT_PROVIDED_LISTS="$fixtures/$bad.txt"
	done
	refused "a target present in both crates" CT_LANE_NOT_PROVIDED_LISTS="$fixtures/target-in-both.txt" \
		CT_LANE_CRATE_TEST_DIRS="$fixtures/crate-a $fixtures/crate-b"
	sel="$fixtures/no-select.sh" refused "a backend-manager entry no lane selects with --lane" \
		CT_LANE_NOT_PROVIDED_LISTS="$fixtures/bm-entry.txt"
	refused "a Linux non-gui list that leaves backend-manager's rr tests in the lane" \
		CT_LANE_NOT_PROVIDED_LISTS="$fixtures/rr-missing/non-gui-not-provided.linux.txt"
	refused "a Linux non-gui list whose rr entry also excludes a test that needs no rr" \
		CT_LANE_NOT_PROVIDED_LISTS="$fixtures/rr-wide/non-gui-not-provided.linux.txt"
	refused "a test-rust that runs backend-manager without the lane's filter" \
		CT_LANE_NOT_PROVIDED_LISTS="$fixtures/valid.txt" CT_LANE_JUSTFILE="$fixtures/justfile"
	refused "a test-rust that gives not-provided-filter.sh no crate" \
		CT_LANE_NOT_PROVIDED_LISTS="$fixtures/valid.txt" CT_LANE_JUSTFILE="$fixtures/justfile-no-crate"
	accepted "a well-formed entry naming a real job with a note" CT_LANE_NOT_PROVIDED_LISTS="$fixtures/valid.txt"
	accepted "an anchored test() entry with an alternation" CT_LANE_NOT_PROVIDED_LISTS="$fixtures/valid-regex.txt"
	accepted "a backend-manager test() entry its lane selects" CT_LANE_NOT_PROVIDED_LISTS="$fixtures/bm-entry.txt"
fi

printf '\n%d of %d assertions failed\n' "$failures" "$assertions"
[ "$failures" -eq 0 ]
