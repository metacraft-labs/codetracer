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
# Return the caller to its directory and OLDPWD and remove this wrapper's
# function and variables. Runs once: explicitly after the shell hook, or from
# the RETURN trap below when the source ends early. The shell hook ends the
# source with `return 1` when it cannot finish repository setup (for instance
# when the Git checks cannot be installed); without the trap that left the
# caller inside the checkout.
# The caller's RETURN trap is restored by the top-level code that calls this
# function, never inside it: without `set -T`, Bash puts back the RETURN trap
# an untraced function was called with when it returns, so a `trap - RETURN`
# here would be undone and leave this wrapper's trap in the caller's shell.
__codetracer_capture_leave() {
    local status=0
    if ! builtin cd -- "$__codetracer_capture_caller"; then
        printf 'CodeTracer: could not return to %s after entering the captured environment\n' "$__codetracer_capture_caller" >&2
        status=1
    elif [ -n "$__codetracer_capture_oldpwd_set" ]; then
        OLDPWD=$__codetracer_capture_oldpwd
    else
        unset OLDPWD
    fi
    unset __codetracer_capture_checkout __codetracer_capture_caller __codetracer_capture_oldpwd \
        __codetracer_capture_oldpwd_set __codetracer_capture_depth
    unset -f __codetracer_capture_leave
    return "$status"
}
__codetracer_capture_depth=${#BASH_SOURCE[@]}
# Without `set -T` Bash hides the caller's RETURN trap while a file is sourced
# and restores it afterwards unless the file set one; this then reads empty and
# `trap - RETURN` below lets Bash restore it. With `set -T` the caller's trap is
# visible here and is put back explicitly.
__codetracer_capture_return_trap=$(trap -p RETURN)
# Bash runs a RETURN trap when a sourced file finishes, early `return` included
# (https://www.gnu.org/software/bash/manual/bash.html#index-trap). Under
# `set -T` it also runs when a function returns, the Nix program's and this
# wrapper's own included; those run at a BASH_SOURCE depth no lower than this
# file's, and only the end of the source, below it, is ours. Once the wrapper
# has left, the depth variable is gone and the comparison with 0 is false.
trap 'if [ "${#BASH_SOURCE[@]}" -lt "${__codetracer_capture_depth:-0}" ]; then
    __codetracer_capture_leave
    eval "${__codetracer_capture_return_trap:-trap - RETURN}"
    unset __codetracer_capture_return_trap
fi' RETURN
ENTER
cd "$repo"
nix print-dev-env --no-write-lock-file "$@" >>"$capture_tmp"
# Nix's program ends by evaluating the shell hook; only then go back.
cat >>"$capture_tmp" <<'LEAVE'

# Fail the source when the caller's directory is gone, so a
# `source … && <command>` consumer does not run its command somewhere else.
# The caller's RETURN trap goes back at top level (see __codetracer_capture_leave).
if __codetracer_capture_leave; then
    eval "${__codetracer_capture_return_trap:-trap - RETURN}"
    unset __codetracer_capture_return_trap
else
    eval "${__codetracer_capture_return_trap:-trap - RETURN}"
    unset __codetracer_capture_return_trap
    return 1
fi
LEAVE
mv -f -- "$capture_tmp" "$destination"
