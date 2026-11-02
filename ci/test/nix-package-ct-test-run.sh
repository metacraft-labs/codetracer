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
# Needs `nix`, `git`, `go`, `nix-shell` and `python3` on PATH (the dev shell has
# all of them). The second half runs a D project (its toolchain through
# the provider's nix-shell fallback) under the io-mon monitor
# the package ships and requires the untracked-input rule to act on it (CTC-3g).
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
# A fixture commit, unsigned whatever the runner's own git config says: a
# persistent runner with `commit.gpgsign` set and no key failed this lane at
# "gpg failed to sign the data", a property of the host and not of `ct test`.
git -C "$workspace" -c user.email=ct@example.invalid -c user.name=ct \
	-c commit.gpgsign=false commit -qm fixture

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

# -----------------------------------------------------------------------------
# CTC-3g from the package: the io-mon monitor it ships captures what the tests
# read. The D fixture, plus a unittest reading `scratch_input.txt` when it
# exists. dub, the compiler and the test binary are dynamically linked and load
# no JIT, so the capture is complete; `go test`
# (static, the shim cannot enter it) and `node --test` (V8's writable
# executable memory, which io-mon reports as an incomplete capture) honestly
# read `not-captured` instead. With the file untracked, the default `reads`
# mode must WITHHOLD and name it; with only an untracked file nobody reads, the
# run issues with `untracked = true`. Both with `read_set = captured`.
#
# The monitor must be the PACKAGE'S: `$IO_MON` and `$REPRO_MONITOR_SHIM_LIB`
# are unset and every `PATH` directory holding an `io-mon` is removed, so a
# dev-shell `io-mon` cannot answer.
# -----------------------------------------------------------------------------
[ -x "$BIN/io-mon" ] || {
	echo "FAIL: the package has no bin/io-mon beside bin/ct-test" >&2
	exit 1
}
if ! ls "$WORK/package/lib/"librepro_monitor_shim.* >/dev/null 2>&1; then
	echo "FAIL: the package has no lib/librepro_monitor_shim" >&2
	exit 1
fi
echo "ok   the package ships io-mon and its shim"

dws="$WORK/d-workspace"
cp -r "$REPO_ROOT/src/ct_test/fixtures/d_unittest_project" "$dws"
chmod -R u+w "$dws"
cat >"$dws/source/reads_input.d" <<'D'
module reads_input;

import std.file : exists, read;

unittest {
    if (exists("scratch_input.txt")) {
        cast(void) read("scratch_input.txt");
    }
}
D
printf '.dub\n*-test-*\ndub.selections.json\n' >"$dws/.gitignore"
git -C "$dws" init -q
git -C "$dws" add -A
git -C "$dws" -c user.email=ct@example.invalid -c user.name=ct \
	-c commit.gpgsign=false commit -qm fixture

narrow_path=""
IFS=: read -r -a path_dirs <<<"$PATH"
for dir in "${path_dirs[@]}"; do
	[ -e "$dir/io-mon" ] || narrow_path="${narrow_path:+$narrow_path:}$dir"
done

# run_d_case <label> -> the summary in "$WORK/<label>.json"
run_d_case() {
	local label="$1" code=0
	(cd "$dws" && env -u IO_MON -u REPRO_MONITOR_SHIM_LIB PATH="$narrow_path" \
		"$BIN/ct" test run --workspace .) >"$WORK/$label.json" 2>"$WORK/$label.err" || code=$?
	if [ "$code" -ne 0 ]; then
		echo "FAIL: ct test run ($label) exited $code" >&2
		cat "$WORK/$label.json" "$WORK/$label.err" >&2
		exit 1
	fi
}

printf 'read by a test\n' >"$dws/scratch_input.txt"
printf 'read by nobody\n' >"$dws/unread.txt"
run_d_case reads-untracked
python3 - "$WORK/reads-untracked.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
cert = summary["certificate"]
assert summary["verdict"] == "passed", summary
assert cert["read_set"] == "captured", cert
assert cert["issued"] is False, cert
assert cert["withheld_reason"] == "wrUntrackedInput", cert
assert cert["untracked_inputs"] == ["scratch_input.txt"], cert
PY
echo "ok   an untracked file a test read withholds, read by the package's io-mon"

rm "$dws/scratch_input.txt"
run_d_case reads-tracked
python3 - "$WORK/reads-tracked.json" <<'PY'
import json, sys
summary = json.load(open(sys.argv[1]))
cert = summary["certificate"]
assert cert["read_set"] == "captured", cert
assert cert["issued"] is True, cert
assert cert["untracked"] is True, cert
PY
echo "ok   an untracked file nobody read issues, with untracked = true"
