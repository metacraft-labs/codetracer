#!/usr/bin/env bash
# ci/test/wait-for-run-artifact-test.sh -- ci/wait-for-run-artifact.sh waits
# for a run's artifact and stops waiting as soon as waiting cannot help.
#
# A stub `curl` answers the two API calls from a script of responses, one per
# poll: the artifact listing (`total_count`) and the run's jobs (the tools
# job's status and conclusion), or a failure. Cases:
#   * the artifact is already there: exit 0 at once;
#   * it appears on the third poll: exit 0;
#   * the tools job failed without it: exit 1 at once, not at the timeout;
#   * the tools job succeeded but the listing never shows it: exit 1 after
#     the catch-up polls;
#   * an API failure is polled through, not taken as a verdict;
#   * nothing ever happens: exit 1 at the timeout.
# Run by ci/lint/bash.sh.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/wait-artifact.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
# Each poll reads line N of $work/script: "<total_count|fail> <status> <conclusion>".
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
n_file="$STUB_DIR/n"
case "$url" in
*artifacts*)
	n=$(($(cat "$n_file" 2>/dev/null || echo 0) + 1))
	echo "$n" >"$n_file"
	;;
*) n=$(cat "$n_file") ;;
esac
line="$(sed -n "${n}p" "$STUB_DIR/script")"
[ -n "$line" ] || line="$(tail -1 "$STUB_DIR/script")"
read -r count status conclusion <<<"$line"
case "$url" in
*artifacts*)
	[ "$count" = fail ] && exit 22
	printf '{"total_count": %s}\n' "$count"
	;;
*jobs*)
	printf '{"jobs": [{"name": "ct-build / x", "status": "completed", "conclusion": "success"},
	  {"name": "visual-replay-tools / Build", "status": "%s", "conclusion": %s}]}\n' \
		"$status" "$([ "$conclusion" = null ] && echo null || echo "\"$conclusion\"")"
	;;
esac
EOF
chmod +x "$work/bin/curl"

run() { # run SCRIPT_LINES... ; sets $code, $polls, $out
	printf '%s\n' "$@" >"$work/script"
	rm -f "$work/n"
	code=0
	out="$(PATH="$work/bin:$PATH" STUB_DIR="$work" CT_WAIT_POLL_SECONDS=0 \
		GITHUB_REPOSITORY=o/r GITHUB_RUN_ID=1 GH_TOKEN=t \
		bash "$root/ci/wait-for-run-artifact.sh" visual-replay-tools "visual-replay-tools /" 3 2>&1)" ||
		code=$?
	polls="$(cat "$work/n")"
}
expect() { # expect CODE POLLS NAME
	if [ "$code" = "$1" ] && [ "$polls" = "$2" ]; then ok "$3"; else fail "$3 (exit $code after $polls poll(s), expected exit $1 after $2): $out"; fi
}

run "1 in_progress null"
expect 0 1 "the artifact is already there: available at once"
run "0 in_progress null" "0 in_progress null" "1 completed success"
expect 0 3 "it appears on the third poll: available then"
run "0 in_progress null" "0 completed failure"
expect 1 2 "the tools job failed without it: stop waiting at once"
run "0 completed success"
expect 1 3 "the tools job succeeded but it is never listed: stop after the catch-up polls"
run "fail in_progress null" "1 in_progress null"
expect 0 2 "an API failure is polled through"
# With a zero poll interval the 3 s bound is reached by wall clock; count only
# that it ended with exit 1 and said why.
run "0 in_progress null"
if [ "$code" = 1 ] && grep -q "not waiting longer" <<<"$out"; then ok "nothing happens: exit 1 at the timeout"; else fail "timeout case: exit $code: $out"; fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
