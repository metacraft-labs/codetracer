#!/usr/bin/env bash
# Capture Nix's Bash program without exposing a partially written environment.
# The guard must precede every Nix assignment: a shellHook guard is too late
# for zsh, which stops at Nix's assignment to its read-only LINENO parameter.
# The capture is also pinned to this checkout: the shell hook picks the checkout
# it prepares from the working directory, so the Nix program runs with the
# checkout as its working directory and the caller's directory is restored
# afterwards. Sourced anywhere, it gives this checkout's PATH (node_modules/.bin
# included) and build directory, not a hook that skipped repository setup.
# NOT-A-CI-GATE: developer capture helper, exercised by test-captured-dev-env.sh.
set -euo pipefail
if [ "$#" -lt 1 ] || [ -z "$1" ]; then
	printf '%s\n' 'usage: capture-dev-env.sh OUTPUT [nix print-dev-env arguments...]' >&2
	exit 2
fi
destination=$1
shift
case "$destination" in
/*) ;;
*) destination="$PWD/$destination" ;;
esac
if [ -d "$destination" ]; then
	printf 'capture destination is a directory: %s\n' "$destination" >&2
	exit 2
fi
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
capture_tmp=$(mktemp "${destination}.tmp.XXXXXX")
trap 'rm -f -- "$capture_tmp"' EXIT
cat >"$capture_tmp" <<'GUARD'
# Nix print-dev-env produces Bash code. Refuse before evaluating any of it.
if [ -z "${BASH_VERSION:-}" ]; then
    printf '%s\n' 'CodeTracer: source this captured environment from bash; use bash -c '\''source "$1" && <command>'\'' captured-env /path/to/env.sh' >&2
    return 1
fi
GUARD
# The checkout path is data, quoted for Bash. The test rewrites exactly this
# one line to simulate a removed checkout, so keep it a single assignment.
printf '__codetracer_capture_checkout=%q\n' "$repo" >>"$capture_tmp"
cat >>"$capture_tmp" <<'ENTER'
__codetracer_capture_caller=$PWD
# Entering the checkout and leaving it again would leave OLDPWD naming the
# checkout (and Nix's program itself assigns OLDPWD=''), so a later `cd -`
# would not go where the caller expects; give the caller its own back.
__codetracer_capture_oldpwd=${OLDPWD-}
__codetracer_capture_oldpwd_set=${OLDPWD+x}
if ! builtin cd -- "$__codetracer_capture_checkout" 2>/dev/null; then
    printf 'CodeTracer: the checkout this environment was captured in is missing: %s; capture it again with just capture-dev-env\n' "$__codetracer_capture_checkout" >&2
    unset __codetracer_capture_checkout __codetracer_capture_caller __codetracer_capture_oldpwd __codetracer_capture_oldpwd_set
    return 1
fi
ENTER
cd "$repo"
nix print-dev-env --no-write-lock-file "$@" >>"$capture_tmp"
# Nix's program ends by evaluating the shell hook; only then go back.
cat >>"$capture_tmp" <<'LEAVE'

if ! builtin cd -- "$__codetracer_capture_caller"; then
    # Fail the source so a `source … && <command>` consumer does not run its
    # command in a directory it did not choose.
    printf 'CodeTracer: could not return to %s after entering the captured environment\n' "$__codetracer_capture_caller" >&2
    unset __codetracer_capture_checkout __codetracer_capture_caller __codetracer_capture_oldpwd __codetracer_capture_oldpwd_set
    return 1
fi
if [ -n "$__codetracer_capture_oldpwd_set" ]; then
    OLDPWD=$__codetracer_capture_oldpwd
else
    unset OLDPWD
fi
unset __codetracer_capture_checkout __codetracer_capture_caller __codetracer_capture_oldpwd __codetracer_capture_oldpwd_set
LEAVE
mv -f -- "$capture_tmp" "$destination"
