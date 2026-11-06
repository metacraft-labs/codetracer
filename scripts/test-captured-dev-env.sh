#!/usr/bin/env bash
# Exercise the real Linux CodeTracer Nix environment in clean Bash and zsh processes.
# The Bash consumer must reach PATH and the shellHook; zsh must refuse before
# any Nix assignment, with a useful diagnostic and its original PATH intact.
# No shell/Nix mocks: a supplied capture lets the same assertions demonstrate
# the original LINENO failure against raw `nix print-dev-env` output.
# Default mode also checks that a real Nix evaluation failure preserves an
# existing destination. Missing tools or a failed capture fail this test.
# NOT-A-CI-GATE: host integration test, needs zsh and evaluates/sources the full
# development shell; run explicitly with `just test-captured-dev-env`.
# Usage: bash scripts/test-captured-dev-env.sh [--capture /absolute/env.sh]
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

bash_bin=$(command -v bash) || fail 'bash is required'
zsh_bin=$(command -v zsh) || fail 'zsh is required'
base_path=$PATH
capture="$scratch/captured environment.sh"
if [ "$#" -eq 2 ] && [ "$1" = --capture ]; then
	capture=$2
	[ -s "$capture" ] || fail "capture is missing or empty: $capture"
elif [ "$#" -eq 0 ]; then
	bash "$repo/scripts/capture-dev-env.sh" "$capture"
else
	fail 'usage: test-captured-dev-env.sh [--capture /absolute/env.sh]'
fi

# Shell strings intentionally expand only in the clean child, after sourcing.
# shellcheck disable=SC2016
if ! env -i HOME="$HOME" PATH="$base_path" "$zsh_bin" -f -c '
    original_path=$PATH
    source "$1" >/dev/null
    result=$?
    [[ $result -eq 1 ]] || exit 11
    [[ $PATH = "$original_path" ]] || exit 12
    [[ -z ${IN_NIX_SHELL+x} ]] || exit 13
' captured-env-test "$capture" >"$scratch/zsh.out" 2>"$scratch/zsh.err"; then
	cat "$scratch/zsh.err" >&2
	fail 'zsh did not refuse before changing the environment'
fi
if ! grep -F 'CodeTracer: source this captured environment from bash' "$scratch/zsh.err"; then
	cat "$scratch/zsh.err" >&2
	fail 'zsh did not explain that this capture requires Bash'
fi
if grep -F 'LINENO' "$scratch/zsh.err"; then
	fail 'zsh reached the Bash-only Nix assignments'
fi

# && is essential: the requested command must not run after a failed source.
# shellcheck disable=SC2016
env -i HOME="$HOME" PATH="$base_path" CODETRACER_HOME="$scratch/ct-home" \
	GOMAXPROCS=2 CARGO_BUILD_JOBS=2 NIX_CONFIG="${NIX_CONFIG:-}" "$bash_bin" --noprofile --norc -c '
    source "$1" >/dev/null &&
    test -n "${CODETRACER_BUILD_DIR:-}" &&
    command -v node && command -v npm && command -v Xvfb
' captured-env-test "$capture" >"$scratch/bash.out" || fail 'Bash did not enter the full environment'
for tool in node npm Xvfb; do
	grep -E "^/nix/store/[^/]+/bin/$tool$" "$scratch/bash.out" ||
		fail "Bash did not resolve $tool from the captured Nix PATH"
done

if [ "$#" -eq 0 ]; then
	cp "$capture" "$scratch/expected"
	if bash "$repo/scripts/capture-dev-env.sh" "$capture" "$scratch/missing-flake" >"$scratch/failed.out" 2>"$scratch/failed.err"; then
		fail 'a missing flake unexpectedly produced a capture'
	fi
	[ -s "$scratch/failed.err" ] || fail 'capture failure hid the Nix diagnostic'
	cmp "$scratch/expected" "$capture" || fail 'failed capture replaced the previous environment'
	[ -z "$(find "$scratch" -name '*.tmp.*' -print)" ] || fail 'failed capture left a temporary file'
fi
printf '%s\n' 'PASS: captured dev environment enters Bash fully and refuses zsh before assignments'
