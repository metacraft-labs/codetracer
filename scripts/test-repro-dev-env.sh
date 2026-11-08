#!/usr/bin/env bash
# The reprobuild dev env must not export CODETRACER_PREFIX, and must name the
# active build dir in CODETRACER_BUILD_DIR. With CODETRACER_PREFIX unset, `ct`
# resolves its prefix from its own location, so a `ct` run in the env uses the
# assets of the tree it was built in (Build-Outputs-And-Path-Resolution.md §3.1,
# §4.1). An export of CODETRACER_PREFIX here pointed every `ct` at one tree.
#
# Host integration test, Linux only: it activates the real reprobuild dev env
# through `repro exec`, which evaluates the Nix flake, so it needs repro and nix.
# The expected build dir is the Linux tup default, src/build-debug.
# CI runs it in the reprobuild-linux-smoke lane; locally: `just test-repro-dev-env`.
# Usage: bash scripts/test-repro-dev-env.sh
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

command -v repro >/dev/null || fail 'repro is required'
# The caller's values must not leak into the capture: the test asserts what
# the dev env itself sets.
if ! (cd "$repo" && env -u CODETRACER_PREFIX -u CODETRACER_BUILD_DIR repro exec . -- env) \
	>"$scratch/env.out" 2>"$scratch/env.err"; then
	cat "$scratch/env.err" >&2
	fail 'repro exec . -- env failed'
fi

if grep -q '^CODETRACER_PREFIX=' "$scratch/env.out"; then
	fail "the dev env exports CODETRACER_PREFIX: $(grep -m1 '^CODETRACER_PREFIX=' "$scratch/env.out")"
fi
build_dir=$(sed -n 's/^CODETRACER_BUILD_DIR=//p' "$scratch/env.out" | head -1)
[ -n "$build_dir" ] || fail 'the dev env does not export CODETRACER_BUILD_DIR'
if [ "$build_dir" != "$repo/src/build-debug" ]; then
	fail "CODETRACER_BUILD_DIR is $build_dir, not $repo/src/build-debug"
fi
# The Nix shell already puts the active bin on PATH, so presence alone proves
# nothing. What the reprobuild env decides is which build's bin wins: the other
# reprobuild tree must not sit ahead of the active one.
path=$(sed -n 's/^PATH=//p' "$scratch/env.out" | head -1)
active_bin="$build_dir/bin"
other_bin="$repo/src/build-debug-repro/bin"
active_at=$(awk -v RS=: -v want="$active_bin" '$0 == want { print NR; exit }' <<<"$path")
other_at=$(awk -v RS=: -v want="$other_bin" '$0 == want { print NR; exit }' <<<"$path")
[ -n "$active_at" ] || fail "PATH does not carry \$CODETRACER_BUILD_DIR/bin ($active_bin)"
if [ -n "$other_at" ] && [ "$other_at" -lt "$active_at" ]; then
	fail "PATH puts $other_bin ahead of $active_bin"
fi
echo 'PASS: the reprobuild dev env exports CODETRACER_BUILD_DIR=src/build-debug, puts its bin on PATH, and leaves CODETRACER_PREFIX unset'
