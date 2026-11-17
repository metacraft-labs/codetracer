#!/usr/bin/env bash
# =============================================================================
# Contract: when `build-siblings.sh`'s toolchain lookup stalls, the script
# names the stage it is waiting in, and it gives up after a bounded time
# instead of holding its caller until the caller's own limit.
#
#   bash ci/test/build-siblings-toolchain-stage-bounded-test.sh
#
# WHY THIS FILE EXISTS
#   launcher-recorder-e2e's `Build ct-print` step ran for 2 h 8 min after
#   printing three lines, then was cancelled by the job's 180-minute limit
#   (codetracer-pm issues/2026-11-06-launcher-recorder-e2e-build-ct-print-
#   hangs-silently-until-the-job-timeout.md). Every line of
#   `build-siblings.sh` that the step could have printed before the stall was
#   printed. The silence is structural: `resolve_toolchain` runs
#   `repro exec <codetracer>` with its stdout and stderr captured into temp
#   files, prints nothing before it, and has no bound, so while that call
#   runs the step's log says nothing at all.
#
# WHAT IT DOES
#   Runs the real `scripts/build-siblings.sh --force --only
#   codetracer-trace-format-nim/ct-print` with a `repro` on PATH that starts
#   and never returns, and `BUILD_SIBLINGS_TOOLCHAIN_TIMEOUT=5`. It requires
#     1. the script to finish within 120 s (the outer bound; an unfixed script
#        does not finish, and the test fails by saying so),
#     2. a non-zero exit, because the lookup did not complete,
#     3. a line announcing the toolchain stage before the lookup starts, so a
#        stall in the log names its stage,
#     4. an error line that names the toolchain lookup and the bound it hit,
#     5. the stalled `repro` to be gone afterwards, so the bound really ended
#        the wait rather than leaving the process running.
#   It needs the sibling at ../codetracer-trace-format-nim (the script checks
#   that the repo exists, and it refuses to run without it) and nothing else:
#   no Nix, no network, no build.
#
# Mocks: one. `repro` is replaced by a stub that stalls. A real `repro exec`
#   stall cannot be produced on demand. On the landing branch the same lookup
#   fails within seconds (7 s pristine, 15 s with the fix, measured 2026-11-07
#   at codetracer 1604471c8), and the one stall this file exists for was
#   observed only in CI. The stub stands in for exactly the call that stalls, and
#   nothing else in the script is faked.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-siblings.sh"
SIBLING="$WS_ROOT/codetracer-trace-format-nim"

failures=0
pass() { echo "  ok   $*"; }
fail() {
	echo "  FAIL $*" >&2
	failures=$((failures + 1))
}

if [ ! -d "$SIBLING" ]; then
	echo "FAIL: the sibling $SIBLING is not checked out; this test needs it" >&2
	exit 1
fi

SCRATCH="$(mktemp -d)"
cleanup() {
	# A stub that outlived the test would hold a process for an hour.
	if [ -s "$SCRATCH/stub.pid" ]; then
		kill "$(cat "$SCRATCH/stub.pid")" 2>/dev/null || true
	fi
	rm -rf "$SCRATCH"
}
trap cleanup EXIT

mkdir -p "$SCRATCH/bin"
# The stub records its pid, then stalls the way the real call did: it never
# exits on its own. `exec` makes the recorded pid the stalled process itself.
cat >"$SCRATCH/bin/repro" <<EOF
#!/usr/bin/env bash
echo \$\$ >"$SCRATCH/stub.pid"
exec sleep 3600
EOF
chmod +x "$SCRATCH/bin/repro"

out="$SCRATCH/out"
PATH="$SCRATCH/bin:$PATH" BUILD_SIBLINGS_TOOLCHAIN_TIMEOUT=5 \
	timeout 120 bash "$SCRIPT" --force --only codetracer-trace-format-nim/ct-print >"$out" 2>&1
rc=$?

if [ "$rc" -eq 124 ]; then
	fail "build-siblings.sh did not finish within 120 s while its toolchain lookup was stalled; the wait is unbounded and nothing in its output names the stage: $(tail -n 3 "$out" | tr '\n' ' ')"
else
	pass "build-siblings.sh finished within 120 s (exit $rc)"
fi

if [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ]; then
	pass "exit is non-zero, because the lookup did not complete"
else
	fail "expected a non-zero exit from a stalled toolchain lookup, got $rc"
fi

if grep -q 'resolving the toolchain' "$out"; then
	pass "the toolchain stage is announced before the lookup starts"
else
	fail "no line announces the toolchain stage before the lookup starts; a stall would be silent: $(cat "$out")"
fi

if grep -q 'toolchain lookup did not finish within 5 s' "$out"; then
	pass "the bound that ended the lookup is named in the error"
else
	fail "no error names the toolchain lookup and its 5 s bound: $(cat "$out")"
fi

if [ -s "$SCRATCH/stub.pid" ]; then
	stub_pid="$(cat "$SCRATCH/stub.pid")"
	if kill -0 "$stub_pid" 2>/dev/null; then
		fail "the stalled repro (pid $stub_pid) is still running after build-siblings.sh gave up"
	else
		pass "the stalled repro was terminated when the bound ended the lookup"
	fi
else
	fail "the stub was never started, so the test did not reach the toolchain lookup"
fi

echo
if [ "$failures" -ne 0 ]; then
	echo "build-siblings toolchain-stage bound: $failures check(s) failed" >&2
	exit 1
fi
echo "build-siblings toolchain-stage bound: all checks passed"
