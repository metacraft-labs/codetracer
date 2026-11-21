#!/usr/bin/env bash
# ci/test/bounded-build-once-test.sh -- ci/build/bounded-build-once.sh bounds
# build-once, dumps a stall's state and retries once without the daemon.
#
# Fake `just` and `repro` on PATH. `just build-once` sleeps when its
# behaviour file says so; it logs the REPRO_DAEMON it saw. Cases:
#   * a build that finishes: one attempt, no dump, its exit status;
#   * a stall under the daemon, then a finished retry: the dump (process tree,
#     zombies, the daemon's status, sessions and log), and the retry ran with
#     REPRO_DAEMON=off;
#   * a stall in both: two dumps and exit 124;
#   * a first bound of 0 (ct-build's setting): one attempt, REPRO_DAEMON=off.
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
check() {
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "$good"; else fail "$bad"; fi
}

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/bounded-build-once.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat >"$work/bin/just" <<'EOF'
#!/usr/bin/env bash
n=$(($(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0) + 1))
echo "$n" >"$FAKE_DIR/calls"
echo "call $n REPRO_DAEMON=${REPRO_DAEMON:-unset}" >>"$FAKE_DIR/log"
behaviour="$(sed -n "${n}p" "$FAKE_DIR/plan")"
[ "$behaviour" = hang ] && exec sleep 600
exit "${behaviour:-0}"
EOF
cat >"$work/bin/repro" <<'EOF'
#!/usr/bin/env bash
echo "fake repro $*"
EOF
chmod +x "$work/bin/just" "$work/bin/repro"

run() { # run PLAN... ; sets $code, $out, $diag
	rm -f "$work/calls" "$work/log"
	printf '%s\n' "$@" >"$work/plan"
	diag="$work/diag-$RANDOM"
	code=0
	# 0.05m = 3 s per bound.
	out="$(PATH="$work/bin:$PATH" FAKE_DIR="$work" bash "$root/ci/build/bounded-build-once.sh" "$diag" 0.05 0.05 2>&1)" ||
		code=$?
}

run 0
check "a build that finishes runs once and passes" "finished build: exit $code, calls $(cat "$work/calls"): $out" \
	test "$code" = 0 -a "$(cat "$work/calls")" = 1
check "and dumps nothing" "a finished build left a dump in $diag" test -z "$(ls -A "$diag")"

run 3
check "a build that fails is not retried and keeps its status" "failed build: exit $code, calls $(cat "$work/calls")" \
	test "$code" = 3 -a "$(cat "$work/calls")" = 1

run hang 0
check "a stall under the daemon is retried, and the retry's success is the result" \
	"stall then success: exit $code, calls $(cat "$work/calls" 2>/dev/null): $out" \
	test "$code" = 0 -a "$(cat "$work/calls")" = 2
check "the retry ran with REPRO_DAEMON=off" "retry env: $(sed -n 2p "$work/log")" \
	grep -qx "call 2 REPRO_DAEMON=off" "$work/log"
check "the first attempt kept the daemon" "first env: $(sed -n 1p "$work/log")" \
	grep -qx "call 1 REPRO_DAEMON=unset" "$work/log"
for f in ps-forest.txt build-tree.txt zombies.txt repro-daemon.txt repro-daemon-log.txt; do
	check "the stall's dump has ${f}" "no ${f} in the dump" test -s "$diag/daemon-stall/$f"
done
check "the dump was taken while the stalled build was alive (its process is in build-tree.txt)" \
	"build-tree.txt: $(cat "$diag/daemon-stall/build-tree.txt" 2>/dev/null)" \
	grep -q "sleep 600" "$diag/daemon-stall/build-tree.txt"
check "the stalled build is gone after the attempt" "a 'sleep 600' from the fake build is still running" \
	bash -c "! pgrep -f '^sleep 600\$' -u \"\$(id -u)\" >/dev/null"
check "the dump holds the daemon's status and sessions" "repro-daemon.txt: $(cat "$diag/daemon-stall/repro-daemon.txt" 2>/dev/null)" \
	grep -q "fake repro daemon sessions" "$diag/daemon-stall/repro-daemon.txt"
check "each attempt's duration is printed" "no per-attempt lines: $out" \
	test "$(grep -c '^bounded-build-once: .*: exit ' <<<"$out")" = 2

# FIRST_MINUTES=0 (ct-build's setting while reprobuild-pm's daemon stall is
# open): one attempt, without the daemon.
rm -f "$work/calls" "$work/log"
printf '%s\n' 0 >"$work/plan"
diag="$work/diag-skip"
code=0
out="$(PATH="$work/bin:$PATH" FAKE_DIR="$work" bash "$root/ci/build/bounded-build-once.sh" "$diag" 0 0.05 2>&1)" || code=$?
check "a first bound of 0 builds once, without the daemon" \
	"first bound 0: exit $code, calls $(cat "$work/calls" 2>/dev/null), log: $(cat "$work/log" 2>/dev/null)" \
	test "$code" = 0 -a "$(cat "$work/calls")" = 1
check "and that build ran with REPRO_DAEMON=off" "env: $(cat "$work/log" 2>/dev/null)" \
	grep -qx "call 1 REPRO_DAEMON=off" "$work/log"
check "ct-build builds without the daemon (first bound 0)" "ct-build.yml does not pass a first bound of 0" \
	grep -qE 'bounded-build-once\.sh "\$\{RUNNER_TEMP\}/build-once-diagnostics" 0 [0-9]+$' "$root/.github/workflows/ct-build.yml"

run hang hang
check "a stall in both attempts exits 124 with both dumps" \
	"double stall: exit $code; dumps: $(find "$diag" -mindepth 1 -maxdepth 1 -printf '%f ' 2>/dev/null)" \
	test "$code" = 124 -a -d "$diag/daemon-stall" -a -d "$diag/no-daemon-stall"

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
