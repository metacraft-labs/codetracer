#!/usr/bin/env bash
# =============================================================================
# Contract: the `ct-native-replay` that `build-siblings.sh` reports as built
# STARTS.
#
#   bash ci/test/build-siblings-native-backend-runs-test.sh
#
# WHY THIS FILE EXISTS
#   `build-siblings.sh` used to build the native backend itself: `cargo
#   build` in codetracer's dev shell, with LLVM/LLDB from
#   `nix build nixpkgs#lldb`. A bare `nixpkgs#` is the machine's flake
#   REGISTRY, not a lock, so on a host whose registry had moved on it linked
#   LLDB 21.1.8 (built against glibc 2.42) into a binary whose interpreter is
#   codetracer's pinned glibc 2.40. The script printed
#     PASS    codetracer-native-backend   built target/debug/ct-native-replay
#   and the binary died before `main`:
#     …/glibc-2.40-224/lib/libc.so.6: version `GLIBC_2.42' not found
#     (required by …/lldb-21.1.8/lib/liblldb.so.21.1)
#   Every GUI spec that records a native trace then failed inside `ct record`,
#   naming the recording rather than the build.
#
#   A check that the artifact EXISTS is exactly what passed there, so this
#   holds the artifact to running: `--help` must exit 0 and print its usage
#   with an EMPTY environment (no dev shell, no LD_LIBRARY_PATH). Everything
#   it loads must come from its own interpreter and runpath.
#
# WHAT IT DOES
#   1. Static: `build-siblings.sh` names no bare `nixpkgs#` package. That is
#      cheap, and it catches the specific mistake coming back.
#   2. End to end, against the real sibling checkout: moves any existing
#      binary aside (restored afterwards whatever happens), runs
#      `build-siblings.sh --force --only codetracer-native-backend`, requires a
#      PASS row for it, and runs the result with `env -i`.
#   Step 2 needs the sibling at ../codetracer-native-backend and Nix. Without
#   them it FAILS by name rather than skipping, because a skipped run of this
#   test is how the defect stayed invisible.
#
# Mocks: none. The real script, the real sibling, the real toolchain.
# =============================================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WS_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/build-siblings.sh"
SIBLING="$WS_ROOT/codetracer-native-backend"
BIN="$SIBLING/target/debug/ct-native-replay"

failures=0
pass() { echo "  ok   $*"; }
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}

echo "== build-siblings: the native backend it builds can start"

# 1. No bare registry nixpkgs reference. Comments are allowed to name the
#    spelling (they explain why it is gone), so only non-comment lines count.
if grep -nE '^[^#]*nixpkgs#' "$SCRIPT" >/dev/null; then
	fail "build-siblings.sh resolves a package from the unpinned flake registry:"
	grep -nE '^[^#]*nixpkgs#' "$SCRIPT" | sed 's/^/         /'
else
	pass "build-siblings.sh names no bare nixpkgs# package"
fi

# 2. End to end.
if [ ! -d "$SIBLING" ]; then
	fail "codetracer-native-backend is not checked out at $SIBLING"
elif ! command -v nix >/dev/null 2>&1; then
	fail "nix is not on PATH; the native backend builds in its Nix dev shell"
else
	saved=""
	if [ -e "$BIN" ]; then
		saved="$(mktemp -d)/ct-native-replay"
		mv "$BIN" "$saved"
	fi
	restore() {
		# Put the previous binary back only if this run did not produce one,
		# so a passing run leaves the fresh build in place.
		if [ -n "$saved" ] && [ ! -e "$BIN" ]; then mv "$saved" "$BIN"; fi
	}
	trap restore EXIT

	out="$(bash "$SCRIPT" --force --only codetracer-native-backend 2>&1)"
	rc=$?
	if echo "$out" | grep -qE 'PASS +codetracer-native-backend +built target/debug/ct-native-replay'; then
		pass "build-siblings reports codetracer-native-backend built"
	else
		fail "build-siblings did not report a PASS for codetracer-native-backend (exit $rc):"
		echo "$out" | tail -20 | sed 's/^/         /'
	fi

	if [ -x "$BIN" ]; then
		run_out="$(env -i PATH=/usr/bin:/bin "$BIN" --help 2>&1)"
		run_rc=$?
		if [ "$run_rc" -eq 0 ] && echo "$run_out" | grep -q '^Usage: ct-native-replay'; then
			pass "ct-native-replay --help runs with an empty environment"
		else
			fail "ct-native-replay --help did not run with an empty environment (exit $run_rc):"
			echo "$run_out" | head -5 | sed 's/^/         /'
		fi
	else
		fail "no executable at $BIN after the build"
	fi
fi

if [ "$failures" -gt 0 ]; then
	echo "build-siblings-native-backend-runs: $failures failure(s)"
	exit 1
fi
echo "build-siblings-native-backend-runs: all checks passed"
