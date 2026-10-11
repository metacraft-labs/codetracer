#!/usr/bin/env bash
# =============================================================================
# `ct test run` from the Nix package's own `bin/` (CTC-3i).
#
# Every package ships the ORC `ct-test` beside the refc `ct`, and `ct test run`
# hands the run to it. This check builds the package's `bin/` with the
# package's own commands (ci/test/nix-package-bin-slice.nix, which also asserts
# on the evaluated derivation that `ct-test` is compiled --mm:orc and installed
# to $out/bin), then runs `ct test run` through the package's `ct` wrapper on a
# committed copy of the Go fixture, and requires:
#
#   * exit 0 and a passing summary that issued a certificate,
#   * the certificate published to a scratch TEST_CERTIFICATES_DIR,
#   * `ct test verify --worktree` from the same `ct` reporting it covered.
#
# Needs `nix`, `git`, `go` and `python3` on PATH (the dev shell has all four).
# Touches no real state: CODETRACER_HOME and TEST_CERTIFICATES_DIR are scratch.
#
# Run:  bash ci/test/nix-package-ct-test-run.sh   (or: just test-nix-package-ct-test-run)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ct-nix-package-ct-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for tool in nix git go python3; do
	command -v "$tool" >/dev/null || {
		echo "nix-package-ct-test-run: '$tool' is not on PATH" >&2
		exit 1
	}
done

echo "building the codetracer package's bin/ (ct + ct-test) ..."
nix build --impure -L \
	--expr "import $REPO_ROOT/ci/test/nix-package-bin-slice.nix { repo = \"$REPO_ROOT\"; }" \
	--out-link "$WORK/package"
BIN="$WORK/package/bin"
[ -x "$BIN/ct" ] || {
	echo "FAIL: the package has no bin/ct" >&2
	exit 1
}
[ -x "$BIN/ct-test" ] || {
	echo "FAIL: the package has no bin/ct-test beside bin/ct" >&2
	exit 1
}
echo "ok   the package's bin/ holds ct and ct-test"

workspace="$WORK/workspace"
cp -r "$REPO_ROOT/src/ct_test/fixtures/go_test_project" "$workspace"
chmod -R u+w "$workspace"
git -C "$workspace" init -q
git -C "$workspace" add -A
git -C "$workspace" -c user.email=ct@example.invalid -c user.name=ct commit -qm fixture

export CODETRACER_HOME="$WORK/home"
export TEST_CERTIFICATES_DIR="$WORK/certificates"
mkdir -p "$CODETRACER_HOME" "$TEST_CERTIFICATES_DIR"

status=0
(cd "$workspace" && "$BIN/ct" test run --workspace .) >"$WORK/stdout" 2>"$WORK/stderr" || status=$?
if [ "$status" -ne 0 ]; then
	echo "FAIL: ct test run exited $status" >&2
	cat "$WORK/stdout" "$WORK/stderr" >&2
	exit 1
fi
python3 - "$WORK/stdout" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
assert summary["verdict"] == "passed", summary
assert summary["passed"] > 0, summary
assert summary["certificate"]["issued"] is True, summary["certificate"]
PY
echo "ok   ct test run from the package exits 0 and issues a certificate"

if ! find "$TEST_CERTIFICATES_DIR" -name '*.toml' | grep . >/dev/null; then
	echo "FAIL: no certificate was published to $TEST_CERTIFICATES_DIR" >&2
	exit 1
fi
echo "ok   the certificate is in the scratch store"

(cd "$workspace" && "$BIN/ct" test verify --worktree)
echo "ok   ct test verify --worktree reports the working tree covered"
