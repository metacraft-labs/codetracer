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
    unset -f __codetracer_capture_leave __codetracer_capture_action_of
    return "$status"
}
# Print the action of a RETURN trap given as `trap -p` prints it,
# `trap -- 'ACTION' RETURN`, by evaluating that text with the builtin shadowed.
# Call it only in a subshell whose RETURN trap is cleared: under `set -T` a
# subshell inherits the RETURN trap, which would run when the shadow returns
# (printing into the result), and the shadow must not outlive the subshell.
__codetracer_capture_action_of() {
    trap() { printf '%s' "$2"; }
    eval "$1"
}
__codetracer_capture_depth=${#BASH_SOURCE[@]}
# The caller's RETURN trap, as `trap -p` prints it (empty when it has none), and
# the action alone. A sourced file sees the caller's trap. Bash would run that
# action when this source ends, and under `set -T` also when a function the
# Nix program calls returns; this wrapper's trap stands in for it meanwhile, so
# the trap below runs the action at those same points.
__codetracer_capture_return_trap=$(trap -p RETURN)
__codetracer_capture_return_action=$(
    builtin trap - RETURN
    __codetracer_capture_action_of "$__codetracer_capture_return_trap"
)
# Bash runs a RETURN trap when a sourced file finishes, early `return` included
# (https://www.gnu.org/software/bash/manual/bash.html#index-trap). Under
# `set -T` it also runs when a function returns, the Nix program's and this
# wrapper's own included; those run at a BASH_SOURCE depth no lower than this
# file's, and only the end of the source, below it, is ours. Once the wrapper
# has left, the depth variable is gone and the comparison with 0 is false.
# On the early-return path Bash does not run the caller's restored trap for
# this source, so it is run here; on the normal path the end-of-file block
# restores it before the source ends and Bash runs it itself.
# For a function return the caller's action runs with the `$?` Bash gives the
# trap ((exit N) sets it without tripping `set -e`: only the last command of an
# `||` list can). The action may itself change the RETURN trap (a one-shot
# `trap - RETURN`, say), which replaces this one; the change is then taken as
# the caller's trap, for later returns and for the end of the source, and this
# trap is put back, or a later early return would strand the caller.
# Commands called from inside a RETURN trap do not run it again.
trap '__codetracer_capture_status=$?
if [ "${#BASH_SOURCE[@]}" -lt "${__codetracer_capture_depth:-0}" ]; then
    __codetracer_capture_leave
    eval "${__codetracer_capture_return_trap:-trap - RETURN}"
    unset __codetracer_capture_status __codetracer_capture_self __codetracer_capture_return_now
    eval "${__codetracer_capture_return_action-}"
    unset __codetracer_capture_return_trap __codetracer_capture_return_action
elif [ -n "${__codetracer_capture_return_action-}" ] && [ "${FUNCNAME[0]-}" != __codetracer_capture_leave ]; then
    if [ "$__codetracer_capture_status" -eq 0 ]; then
        eval "$__codetracer_capture_return_action"
    else
        (exit "$__codetracer_capture_status") || eval "$__codetracer_capture_return_action"
    fi
    __codetracer_capture_return_now=$(trap -p RETURN)
    if [ "$__codetracer_capture_return_now" != "$__codetracer_capture_self" ]; then
        __codetracer_capture_return_trap=$__codetracer_capture_return_now
        __codetracer_capture_return_action=$(
            builtin trap - RETURN
            __codetracer_capture_action_of "$__codetracer_capture_return_now"
        )
        eval "$__codetracer_capture_self"
    fi
fi' RETURN
# This wrapper's trap as `trap -p` prints it, to tell it from a replacement.
__codetracer_capture_self=$(trap -p RETURN)
ENTER
cd "$repo"
nix_program=$(mktemp "${destination}.tmp.XXXXXX")
trap 'rm -f -- "$capture_tmp" "$nix_program"' EXIT
nix print-dev-env --no-write-lock-file "$@" >"$nix_program"
# The wrapper returns the caller to its directory through its RETURN trap when
# the shell hook ends the source early; a RETURN trap set by the Nix program
# would replace it and silently lose that. Refuse such a program at capture
# time rather than publish a capture that would strand its caller.
# The check reads lines, so it matches `trap … RETURN` on one line (the signal
# quoted or not) and the closing line of a multi-line action, `…' RETURN`;
# Bash also accepts the signal name in lowercase, so it is matched in any case.
return_signal='[Rr][Ee][Tt][Uu][Rr][Nn]([^[:alnum:]_]|$)'
return_trap_pattern="(^|[^[:alnum:]_])trap[[:space:]].*[[:space:]]['\"]?$return_signal"
return_trap_pattern+="|['\"][[:space:]]+['\"]?$return_signal"
if grep -nE "$return_trap_pattern" "$nix_program" >&2; then
	printf '%s\n' 'capture-dev-env: the development shell sets a RETURN trap (lines above); the captured environment needs that trap to restore its caller, so it was not written' >&2
	exit 1
fi
cat "$nix_program" >>"$capture_tmp"
# Nix's program ends by evaluating the shell hook; only then go back.
cat >>"$capture_tmp" <<'LEAVE'

# Fail the source when the caller's directory is gone, so a
# `source … && <command>` consumer does not run its command somewhere else.
# The caller's RETURN trap goes back at top level (see __codetracer_capture_leave).
if __codetracer_capture_leave; then
    eval "${__codetracer_capture_return_trap:-trap - RETURN}"
    unset __codetracer_capture_return_trap __codetracer_capture_return_action \
        __codetracer_capture_status __codetracer_capture_self __codetracer_capture_return_now
else
    eval "${__codetracer_capture_return_trap:-trap - RETURN}"
    unset __codetracer_capture_return_trap __codetracer_capture_return_action \
        __codetracer_capture_status __codetracer_capture_self __codetracer_capture_return_now
    return 1
fi
LEAVE
mv -f -- "$capture_tmp" "$destination"
