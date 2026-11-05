#!/usr/bin/env bash
#
# dev-shell-codex-acp-test.sh -- the `codex-acp` the dev shell puts on PATH
# starts, and answers an ACP `initialize`.
#
# `nix/shells/main.nix` adds `ourPkgs.codex-acp`, and CodeTracer's Agent
# Activity pane spawns `codex-acp` from PATH. The package linked libssl.so.3
# and libcrypto.so.3 without a RUNPATH that names openssl, so the loader exited
# before reading any request:
#
#   codex-acp: error while loading shared libraries: libssl.so.3: cannot open
#   shared object file: No such file or directory
#
# (codetracer-pm issues/2026-11-04-dev-shell-codex-acp-cannot-load-libssl.md).
# A consumer found this in its own test, not the shell's, so this test runs
# the binary the shell provides and sends it the first ACP request.
#
# Asserted, for the default dev shell (`main.nix`; the `ci` shell does not carry
# codex-acp, ci-base.nix leaves it to main.nix):
#   * `codex-acp` resolves on PATH inside the shell;
#   * an ACP `initialize` on stdin gets a JSON-RPC `result` that carries a
#     `protocolVersion`, and the process exits 0 when stdin closes;
#   * the loader's "error while loading shared libraries" line does not appear.
#
# Runs `nix develop`, so it is slow; it is not part of the in-shell test
# recipes.
#
#   bash ci/test/dev-shell-codex-acp-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

request='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}'

# Runs the probe inside dev shell <attr> ("" is the default one) and prints the
# combined output, then a final line `exit=<status>`. The single quotes are
# deliberate: the script expands inside the shell. `nix develop`'s own stderr
# is kept out of the output the assertions read; when the shell never reached
# the probe there is no `exit=` line, and the tail of that stderr is printed
# instead, so the FAIL names the real cause.
# shellcheck disable=SC2016
run_probe() {
	local attr="$1"
	local err="$SCRATCH/nix-develop-${attr:-default}.err"
	local out
	out="$(cd "$SCRATCH" && nix develop "$REPO${attr:+#$attr}" --no-write-lock-file -c bash -c '
		command -v codex-acp || { echo "codex-acp is not on PATH"; exit 127; }
		printf "%s\n" "$1" | timeout 120 codex-acp 2>&1
		echo "exit=$?"
	' _ "$request" 2>"$err")" || true
	printf '%s\n' "$out"
	if ! grep -q '^exit=' <<<"$out"; then
		echo "(nix develop never reached codex-acp; its stderr ends:)"
		tail -n 20 "$err"
	fi
}

# The status `run_probe` printed last.
status_of() { sed -n 's/^exit=//p' <<<"$1" | tail -n 1; }

out="$(run_probe "")"

grep -q 'error while loading shared libraries' <<<"$out" &&
	fail "codex-acp cannot load its shared libraries:"$'\n'"$out"
[ "$(status_of "$out")" = 0 ] ||
	fail "codex-acp did not exit 0 after answering initialize:"$'\n'"$out"
if ! grep -q '"result"' <<<"$out" || ! grep -q '"protocolVersion"' <<<"$out"; then
	fail "codex-acp did not answer initialize with a result:"$'\n'"$out"
fi
echo "ok: the dev shell's codex-acp starts and answers initialize"

echo "PASS: the dev shell's codex-acp starts"
