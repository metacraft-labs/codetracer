#!/usr/bin/env bash
# Exercise the real Linux CodeTracer Nix environment in clean Bash and zsh processes.
# The Bash consumer must reach PATH and the shellHook; zsh must refuse before
# any Nix assignment, with a useful diagnostic and its original PATH intact.
# Sourced outside the checkout, the capture must give the same environment as
# inside it and return the caller to its directory; a capture whose checkout
# is gone must refuse before any Nix assignment.
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

# A capture is the environment of its checkout wherever it is sourced. The
# shell hook picks its checkout from the working directory, so a capture
# sourced outside one used to drop node_modules/.bin (and stylus with it) from
# PATH; a wrapper that sourced first and cd'd afterwards then handed Tup a
# changed PATH, and the re-run stylesheet rules failed and lost their outputs.
# $scratch is outside every git repository. Volatile per-source variables
# (the hook's mktemp NIX_BUILD_TOP and its TMP aliases, the shell's own
# bookkeeping) are excluded; everything else must match byte for byte.
outside="$scratch/outside dir"
mkdir -p "$outside"
# shellcheck disable=SC2016
dump_env='
    OLDPWD=/caller-oldpwd
    source "$1" 2>"$2" >/dev/null || exit 21
    [ "$PWD" = "$3" ] || { printf "cwd not restored: %s\n" "$PWD" >&2; exit 22; }
    command -v stylus || exit 23
    printf "%s\n" "${OLDPWD-<unset>}" >"$4"
    printf "CODETRACER_REPO_ROOT_PATH=%s\n" "${CODETRACER_REPO_ROOT_PATH:-}"
    env -0 | sort -z | tr "\0" "\n" |
        grep -Ev "^(NIX_BUILD_TOP|TMP|TMPDIR|TEMP|TEMPDIR|PWD|OLDPWD|SHLVL|_)="
'
source_capture_in() {
	(cd "$1" && env -i HOME="$HOME" PATH="$base_path" CODETRACER_HOME="$scratch/ct-home" \
		NIX_CONFIG="${NIX_CONFIG:-}" "$bash_bin" --noprofile --norc -c "$dump_env" \
		captured-env-test "$capture" "$2" "$1" "$2.oldpwd")
}
source_capture_in "$repo" "$scratch/inside.err" >"$scratch/inside.env" ||
	{
		cat "$scratch/inside.err" >&2
		fail 'sourcing inside the checkout failed'
	}
if ! source_capture_in "$outside" "$scratch/outside.err" >"$scratch/outside.env"; then
	cat "$scratch/outside.err" >&2
	fail 'sourcing outside the checkout did not give the checkout environment (stylus missing or cwd not restored)'
fi
[ "$(head -n 1 "$scratch/outside.env")" = "$repo/node_modules/.bin/stylus" ] ||
	fail "stylus did not resolve from the captured checkout: $(head -n 1 "$scratch/outside.env")"
grep -Fx "CODETRACER_REPO_ROOT_PATH=$repo" "$scratch/outside.env" >/dev/null ||
	fail 'CODETRACER_REPO_ROOT_PATH is not the captured checkout outside it'
if grep -F 'not inside a CodeTracer checkout' "$scratch/outside.err"; then
	fail 'the shell hook skipped repository setup when sourced outside the checkout'
fi
if ! diff -u "$scratch/inside.env" "$scratch/outside.env" >"$scratch/env.diff"; then
	cat "$scratch/env.diff" >&2
	fail 'the capture gives a different environment outside its checkout'
fi
# Entering the checkout and leaving it must not leave OLDPWD naming it (Nix's
# program also assigns OLDPWD=''), or a later `cd -` goes somewhere unexpected.
[ "$(cat "$scratch/outside.err.oldpwd")" = /caller-oldpwd ] ||
	fail "the caller's OLDPWD was not restored: $(cat "$scratch/outside.err.oldpwd")"

if [ "$#" -eq 0 ]; then
	# The recorded checkout is gone: refuse before any Nix assignment.
	# shellcheck disable=SC2016
	sed 's|^__codetracer_capture_checkout=.*$|__codetracer_capture_checkout='"'$scratch/removed-checkout'"'|' \
		"$capture" >"$scratch/moved.sh"
	grep -Fx "__codetracer_capture_checkout='$scratch/removed-checkout'" "$scratch/moved.sh" >/dev/null ||
		fail 'the capture does not record its checkout'
	# shellcheck disable=SC2016
	if ! (cd "$outside" && env -i HOME="$HOME" PATH="$base_path" "$bash_bin" --noprofile --norc -c '
        original_path=$PATH
        source "$1" >/dev/null
        [ $? -eq 1 ] || exit 31
        [ "$PATH" = "$original_path" ] || exit 32
        [ -z "${IN_NIX_SHELL+x}" ] || exit 33
        [ "$PWD" = "$2" ] || exit 34
    ' captured-env-test "$scratch/moved.sh" "$outside") 2>"$scratch/moved.err"; then
		cat "$scratch/moved.err" >&2
		fail 'a capture of a missing checkout did not refuse before changing the environment'
	fi
	grep -F "CodeTracer: the checkout this environment was captured in is missing: $scratch/removed-checkout" \
		"$scratch/moved.err" >/dev/null || fail 'the missing-checkout refusal does not name the checkout'

	# The shell hook ends the source early with `return 1` when it cannot finish
	# repository setup (the Git checks it installs, see nix/shells/ci-base.nix).
	# That path cannot be provoked here without breaking this checkout's Git
	# configuration, so the hook is made to end exactly that way: the copy
	# appends the hook's own `return 1 2>/dev/null || exit 1` to it, just before
	# Nix evaluates it. Both copies also append a function that returns 3, so
	# that a RETURN trap under `set -T` sees a non-zero `$?` (every function of
	# the real hook returns 0). Whether the hook fails or finishes, the caller must get
	# its directory, OLDPWD and RETURN trap back (none when it had none), with
	# or without `set -T`, and no function, variable or trap of the capture may
	# be left behind to fire on a later source or function return. A caller
	# without a RETURN trap is the common case and must be covered: without
	# `set -T` Bash undoes a RETURN-trap change made inside an untraced
	# function, so a capture that reset its trap there would leave it behind.
	# shellcheck disable=SC2016
	[ "$(grep -cFx 'eval "${shellHook:-}"' "$capture")" -eq 1 ] ||
		fail 'Nix no longer ends the capture by evaluating the shell hook once'
	# Print capture $1 with shell code $2 (no single quotes) appended to its
	# shell hook, on a line of its own.
	with_hook_tail() {
		awk -v tail="$2" '
			$0 == "eval \"${shellHook:-}\"" { printf "shellHook=\"${shellHook:-}\"$%c\\n%c%c%s%c\n", 39, 39, 39, tail, 39 }
			{ print }
		' "$1"
	}
	status_probe='ct_test_status() { (exit 3); }; ct_test_status || :'
	with_hook_tail "$capture" "$status_probe" >"$scratch/hook-finishes.sh"
	with_hook_tail "$capture" "$status_probe"'; echo "simulated shell-hook failure" >&2; return 1 2>/dev/null || exit 1' \
		>"$scratch/hook-fails.sh"
	# The caller's own RETURN trap must fire exactly where it fires for the
	# bare Nix program: at the end of the source (early return included) and,
	# under `set -T`, on every function return inside it, never on the
	# wrapper's, and with the `$?` Bash gives it there. A one-shot trap that
	# removes itself must stay removed, and the wrapper must still return the
	# caller when that happens before an early return. The bare program is the
	# capture without the wrapper's lines, between the end of its trap setup
	# and its end-of-file block, sourced inside the checkout so that the hook
	# takes the same path.
	# shellcheck disable=SC2016 # expands in the trap, inside the child
	marking_trap='printf "%s %s %s\n" "$?" "${FUNCNAME[0]:-<source end>}" "${#BASH_SOURCE[@]}" >>"$CT_TEST_MARKS"'
	oneshot_trap="$marking_trap; trap - RETURN"
	# shellcheck disable=SC2016 # a line of the capture, matched literally
	wrapper_end='__codetracer_capture_self=$(trap -p RETURN)'
	bare_program() {
		awk -v found=0 -v start="$wrapper_end" '
			$0 == "# Fail the source when the caller'"'"'s directory is gone, so a" { exit }
			found { print }
			$0 == start { found = 1 }
		' "$1"
	}
	for marker in "$wrapper_end" "# Fail the source when the caller's directory is gone, so a"; do
		[ "$(grep -cFx "$marker" "$capture")" -eq 1 ] ||
			fail "the capture's wrapper boundary is not unique: $marker"
	done
	bare_program "$scratch/hook-finishes.sh" >"$scratch/bare-finishes.sh"
	bare_program "$scratch/hook-fails.sh" >"$scratch/bare-fails.sh"
	for hook in fails finishes; do
		case "$hook" in
		fails) sourced="$scratch/hook-fails.sh" expected_status=1 ;;
		finishes) sourced="$scratch/hook-finishes.sh" expected_status=0 ;;
		esac
		for tracing in +T -T; do
			for caller_trap in "$marking_trap" "$oneshot_trap" ''; do
				expected_trap=$caller_trap
				if [ -n "$caller_trap" ]; then
					: >"$scratch/marks-bare"
					# shellcheck disable=SC2016
					(cd "$repo" && env -i HOME="$HOME" PATH="$base_path" CODETRACER_HOME="$scratch/ct-home" \
						NIX_CONFIG="${NIX_CONFIG:-}" CT_TEST_MARKS="$scratch/marks-bare" "$bash_bin" --noprofile --norc -c '
                    set "$2"
                    trap "$3" RETURN
                    source "$1" >/dev/null 2>&1
                    trap -p RETURN >"$CT_TEST_MARKS.trap"
                ' captured-env-test "$scratch/bare-$hook.sh" "$tracing" "$caller_trap")
					grep -E '^[0-9]+ <source end> 0$' "$scratch/marks-bare" >/dev/null ||
						[ "$caller_trap" = "$oneshot_trap" ] ||
						fail "the reference run recorded no end of source (hook $hook, set $tracing)"
					[ -s "$scratch/marks-bare" ] ||
						fail "the reference run recorded no RETURN trap at all (hook $hook, set $tracing)"
					[ "$tracing" = +T ] || [ "$caller_trap" = "$oneshot_trap" ] ||
						grep -E '^3 ct_test_status [0-9]+$' "$scratch/marks-bare" >/dev/null ||
						fail "the reference run did not see the probe function return 3 (hook $hook, set $tracing)"
					expected_trap=$(cat "$scratch/marks-bare.trap")
				fi
				: >"$scratch/marks"
				# shellcheck disable=SC2016
				if ! (cd "$outside" && env -i HOME="$HOME" PATH="$base_path" CODETRACER_HOME="$scratch/ct-home" \
					NIX_CONFIG="${NIX_CONFIG:-}" CT_TEST_MARKS="$scratch/marks" "$bash_bin" --noprofile --norc -c '
                set "$3"
                [ -z "$5" ] || trap "$5" RETURN
                OLDPWD=/caller-oldpwd
                source "$1" >/dev/null
                status=$?
                [ "$status" -eq "$4" ] || { printf "source returned %s\n" "$status" >&2; exit 41; }
                [ "$PWD" = "$2" ] || { printf "cwd not restored: %s\n" "$PWD" >&2; exit 42; }
                [ "$OLDPWD" = /caller-oldpwd ] || { printf "OLDPWD not restored: %s\n" "$OLDPWD" >&2; exit 43; }
                [ "$(trap -p RETURN)" = "$6" ] || { printf "RETURN trap not restored: %s\n" "$(trap -p RETURN)" >&2; exit 44; }
                ! declare -F | grep -F __codetracer_capture >&2 || exit 45
                ! compgen -v | grep -F __codetracer_capture >&2 || exit 46
            ' captured-env-test "$sourced" "$outside" "$tracing" "$expected_status" "$caller_trap" "$expected_trap") 2>"$scratch/hook.err"; then
					cat "$scratch/hook.err" >&2
					fail "a shell hook that $hook (set $tracing, caller RETURN trap '$caller_trap') left the caller outside its directory or state"
				fi
				if grep -F __codetracer_capture "$scratch/hook.err"; then
					fail "the capture's own trap ran outside it (hook $hook, set $tracing, caller RETURN trap '$caller_trap')"
				fi
				if [ "$hook" = fails ]; then
					grep -F 'simulated shell-hook failure' "$scratch/hook.err" >/dev/null ||
						fail 'the simulated shell-hook failure did not run'
				fi
				if [ -n "$caller_trap" ] && ! diff -u "$scratch/marks-bare" "$scratch/marks" >"$scratch/marks.diff"; then
					cat "$scratch/marks.diff" >&2
					fail "the caller's RETURN trap fired differently from the bare Nix program (hook $hook, set $tracing, caller RETURN trap '$caller_trap')"
				fi
			done
		done
	done

	# A development shell that sets its own RETURN trap would replace the
	# wrapper's, and a hook failure would then strand the caller in the
	# checkout. The capture must refuse such a shell and leave the destination
	# alone. A real Nix evaluation of a minimal flake whose shell hook sets one;
	# it takes nixpkgs from this checkout's lock, so nothing is fetched.
	# Bash accepts the signal name in either case, so both spellings are tried.
	for signal in RETURN return; do
		mkdir -p "$scratch/return-trap-flake-$signal"
		sed "s/@SIGNAL@/$signal/" >"$scratch/return-trap-flake-$signal/flake.nix" <<'FLAKE'
{
  outputs = { self, nixpkgs }: {
    devShells = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ] (system: {
      default = nixpkgs.legacyPackages.${system}.mkShellNoCC {
        shellHook = "trap 'echo shell hook trap' @SIGNAL@";
      };
    });
  };
}
FLAKE
		grep -F "trap 'echo shell hook trap' $signal\"" "$scratch/return-trap-flake-$signal/flake.nix" >/dev/null ||
			fail "the $signal-trap flake was not written"
		printf '%s\n' 'previous capture' >"$scratch/return-trap.sh"
		if bash "$repo/scripts/capture-dev-env.sh" "$scratch/return-trap.sh" --inputs-from "$repo" \
			"path:$scratch/return-trap-flake-$signal" >"$scratch/return-trap.out" 2>"$scratch/return-trap.err"; then
			fail "a development shell that sets a $signal trap was captured"
		fi
		grep -F 'the development shell sets a RETURN trap' "$scratch/return-trap.err" >/dev/null || {
			cat "$scratch/return-trap.err" >&2
			fail "the $signal-trap refusal did not explain itself"
		}
		[ "$(cat "$scratch/return-trap.sh")" = 'previous capture' ] ||
			fail "the $signal-trap refusal replaced the previous capture"
	done

	cp "$capture" "$scratch/expected"
	if bash "$repo/scripts/capture-dev-env.sh" "$capture" "$scratch/missing-flake" >"$scratch/failed.out" 2>"$scratch/failed.err"; then
		fail 'a missing flake unexpectedly produced a capture'
	fi
	[ -s "$scratch/failed.err" ] || fail 'capture failure hid the Nix diagnostic'
	cmp "$scratch/expected" "$capture" || fail 'failed capture replaced the previous environment'
	[ -z "$(find "$scratch" -name '*.tmp.*' -print)" ] || fail 'failed capture left a temporary file'
fi
printf '%s\n' 'PASS: captured dev environment enters Bash fully from any directory and restores the caller after a failing hook, and refuses zsh and a missing checkout before assignments'
