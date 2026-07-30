#!/usr/bin/env bash

# Strict router and execution contract for the materialized origin-DAP suites.
# Keep selection here rather than in the Just recipe so it can be exercised
# directly with a fake cargo executable by ci/test/origin-dap-gate.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
readonly REPO_ROOT
readonly REQUIRED_ENV="CT_ORIGIN_DAP_REQUIRED"

die() {
	echo "origin-DAP gate error: $*" >&2
	exit 2
}

trim() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
}

want_python=0
want_ruby=0
want_javascript=0
selected_count=0

parse_selectors() {
	local raw token lowered saw_all=0

	if [ "${CT_TEST_LANGS+x}" = "x" ]; then
		raw="$CT_TEST_LANGS"
		[ -n "$(trim "$raw")" ] || die "CT_TEST_LANGS was explicitly empty"
	else
		raw="all"
	fi

	case "$raw" in
	*$'\n'* | *$'\r'*) die "CT_TEST_LANGS must be a single comma-separated line" ;;
	esac

	while IFS= read -r token; do
		token="$(trim "$token")"
		[ -n "$token" ] || die "CT_TEST_LANGS contains an empty selector token"
		lowered="$(printf '%s' "$token" | tr '[:upper:]' '[:lower:]')"
		case "$lowered" in
		all) saw_all=1 ;;
		python | py) want_python=1 ;;
		ruby | rb) want_ruby=1 ;;
		javascript | js | node) want_javascript=1 ;;
		*) die "unknown CT_TEST_LANGS selector '$token'" ;;
		esac
	done < <(printf '%s\n' "$raw" | awk -F, '{ for (i = 1; i <= NF; i++) print $i }')

	selected_count=$((want_python + want_ruby + want_javascript))
	if [ "$saw_all" -eq 1 ]; then
		[ "$selected_count" -eq 0 ] || die "selector 'all' cannot be mixed with language selectors"
		want_python=1
		want_ruby=1
		want_javascript=1
		selected_count=3
	fi
	[ "$selected_count" -gt 0 ] || die "CT_TEST_LANGS routed zero origin-DAP suites"
}

print_plan() {
	[ "$want_python" -eq 1 ] && echo "origin_python_dap_test"
	[ "$want_ruby" -eq 1 ] && echo "origin_ruby_dap_test"
	[ "$want_javascript" -eq 1 ] && echo "origin_javascript_dap_test"
	return 0
}

required_mode=0
gate_tmp_dir=""
parse_required_mode() {
	local value="${CT_ORIGIN_DAP_REQUIRED-0}"
	case "$value" in
	0) required_mode=0 ;;
	1) required_mode=1 ;;
	*) die "$REQUIRED_ENV must be unset, '0', or '1'; got '$value'" ;;
	esac
}

run_python_suite() {
	local cargo_bin="$1" tmp_dir="$2"
	local list_log="$tmp_dir/python-list.log"
	local expected_names="$tmp_dir/python-expected.txt"
	local actual_names="$tmp_dir/python-actual.txt"
	local test_log="$tmp_dir/python-test.log"
	local status

	cat >"$expected_names" <<'EOF'
test_origin_python_augmented_assignment
test_origin_python_computational_origin
test_origin_python_destructuring_or_index
test_origin_python_parameter_pass
test_origin_python_return_capture
test_origin_python_simple_trivial_chain
test_origin_python_walrus_in_condition
EOF

	echo "Verifying the exact seven-test Python origin-DAP manifest..."
	set +e
	"$cargo_bin" test --test origin_python_dap_test -- --list 2>&1 | tee "$list_log"
	status=${PIPESTATUS[0]}
	set -e
	[ "$status" -eq 0 ] || die "cargo could not list origin_python_dap_test (exit $status)"

	sed -n 's/: test$//p' "$list_log" | LC_ALL=C sort >"$actual_names"
	if ! diff -u "$expected_names" "$actual_names"; then
		die "origin_python_dap_test must contain exactly the documented seven tests"
	fi

	echo "Running all seven materialized Python origin-DAP tests..."
	set +e
	"$cargo_bin" test --test origin_python_dap_test -- --nocapture 2>&1 | tee "$test_log"
	status=${PIPESTATUS[0]}
	set -e
	[ "$status" -eq 0 ] || die "origin_python_dap_test failed (exit $status)"

	grep -Eq '^test result: ok\. 7 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out;' "$test_log" ||
		die "origin_python_dap_test did not report seven executed, passing, non-ignored tests"

	if [ "$required_mode" -eq 1 ]; then
		if grep -Fq 'SKIPPED:' "$test_log"; then
			die "required Python origin-DAP gate emitted a SKIPPED sentinel"
		fi
		echo "origin-DAP required summary: expected=7 executed=7 skipped=0"
	fi
}

main() {
	local cargo_bin status suite

	parse_selectors
	parse_required_mode

	if [ "$required_mode" -eq 1 ] &&
		{ [ "$want_python" -ne 1 ] || [ "$selected_count" -ne 1 ]; }; then
		die "$REQUIRED_ENV=1 is the strict Python-only per-PR contract"
	fi

	if [ "${1-}" = "--plan" ]; then
		[ "$#" -eq 1 ] || die "--plan accepts no additional arguments"
		print_plan
		return
	fi
	[ "$#" -eq 0 ] || die "unknown argument '$1'"

	if [ "${ORIGIN_DAP_SKIP_GATE_SELF_TESTS:-0}" != "1" ]; then
		"$REPO_ROOT/ci/test/origin-dap-gate.sh"
	fi

	cargo_bin="${ORIGIN_DAP_CARGO_BIN:-cargo}"
	[ -n "$cargo_bin" ] || die "ORIGIN_DAP_CARGO_BIN was explicitly empty"
	if [[ $cargo_bin == */* ]]; then
		[ -x "$cargo_bin" ] || die "cargo test executable '$cargo_bin' is not executable"
	else
		command -v "$cargo_bin" >/dev/null 2>&1 || die "cargo test executable '$cargo_bin' was not found"
	fi

	gate_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/codetracer-origin-dap.XXXXXX")"
	trap 'rm -rf "$gate_tmp_dir"' EXIT

	cd "$REPO_ROOT/src/db-backend"
	if [ "$want_python" -eq 1 ]; then
		echo "Running origin-DAP required-mode policy tests..."
		"$cargo_bin" test --test origin_dap_gate_test
		run_python_suite "$cargo_bin" "$gate_tmp_dir"
	fi

	for suite in \
		"$([ "$want_ruby" -eq 1 ] && echo origin_ruby_dap_test)" \
		"$([ "$want_javascript" -eq 1 ] && echo origin_javascript_dap_test)"; do
		[ -n "$suite" ] || continue
		echo "Running materialized origin-DAP suite: $suite"
		set +e
		"$cargo_bin" test --test "$suite" -- --nocapture
		status=$?
		set -e
		[ "$status" -eq 0 ] || die "$suite failed (exit $status)"
	done

	echo "Selected Value Origin Tracking DAP suites passed."
}

main "$@"
