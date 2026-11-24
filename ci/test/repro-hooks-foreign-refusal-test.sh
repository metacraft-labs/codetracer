#!/usr/bin/env bash
# ci/test/repro-hooks-foreign-refusal-test.sh -- when the pinned `repro hooks
# ensure --vcs` refuses hooks a different Repro build wrote, the dev shell's
# error names both builds and the commands that reconcile them.
#
# On a workstation (no GITHUB_ACTIONS) nix/git-hooks.nix runs a plain `ensure`
# in the main checkout, and since reprobuild 4c49e746a6 a plain `ensure`
# refuses a hook body whose contract token it does not generate
# ("refused-foreign-contract"). The shell then aborted with only
# "ERROR: CodeTracer could not install the Repro publication gate." and named
# neither build nor a remedy (codetracer-pm issue
# 2026-11-17-codetracer-dev-shell-aborts-on-a-workstation-whose-repro-hooks-another-build-wrote,
# seen on xps-nixos with hooks from repro 0.2.19 and on nixos-ci-bare-001 with
# hooks from repro 0.2.31 against a pinned 0.2.27).
#
# This runs that part of the shell hook, as nix/git-hooks.nix has it, in a
# scratch repository. `repro` is a fake: the real refusal needs two real Repro
# builds whose generated bodies differ, which this lint lane cannot build. The
# fake keeps the two behaviours the step relies on -- `hooks protocol` accepts
# exactly one contract token (this build's), and `hooks ensure` exits 1 and
# leaves a hook alone when its token is another one -- and records whether
# ensure ran.
#   * hooks from another build that recorded its path (REPRO_INSTALLING_BUILD):
#     the shell still aborts, and its error names the writer, the pinned build,
#     the re-anchor command for the pinned build, and moving the other pin;
#   * hooks from another build that predates REPRO_INSTALLING_BUILD: the writer
#     is reported as not recorded, with the same remedy;
#   * ensure failing for another reason (the hooks are this build's): the plain
#     error, and no foreign-build remedy that would mislead;
#   * ensure failing because the checkout is not a Git repository: the plain
#     error still prints (the scan must not stop the shell first under set -e).
set -euo pipefail
cd "$(dirname "$0")/../.."
failures=0
fail() {
	echo "  FAIL $*"
	failures=$((failures + 1))
}
ok() { echo "  ok   $*"; }
check() { # ok-message fail-message command...
	local good="$1" bad="$2"
	shift 2
	if "$@"; then ok "$good"; else fail "$bad"; fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export GIT_CONFIG_GLOBAL="$work/gitconfig" GIT_CONFIG_NOSYSTEM=1
printf '[user]\nname = t\nemail = t@t\n[init]\ndefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
git init -q "$work/main"
git -C "$work/main" commit -q --allow-empty -m init
hooks="$work/main/.git/hooks"

mkdir -p "$work/repro/bin"
cat >"$work/repro/bin/repro" <<FAKE
#!/usr/bin/env bash
this="reprobuild.managed-hook.v1.pre-push.bbbb"
case "\$1 \$2" in
"--version ") echo "repro 9.9.9" ;;
"hooks protocol")
	[ "\${4#--hook-contract=}" = "\$this" ] && exit 0
	exit 3 ;;
"hooks ensure")
	echo "ensure \$*" >>"$work/ensure.log"
	if ! grep -q "\$this" "$hooks/pre-push.repro-managed"; then
		echo "repro hooks: refused-foreign-contract: left untouched" >&2
	fi
	exit 1 ;;
esac
FAKE
chmod +x "$work/repro/bin/repro"

block() {
	sed -n '/^  ct_repro_anchor=()$/,/^  unset ct_repro_anchor/p' nix/git-hooks.nix |
		sed -e "s|''\\\${|\${|g" -e "s|\\\${repro}|$work/repro|g"
}
install_hooks() { # token-digest [writer]
	{
		printf '#!/bin/sh\n'
		[ -z "${2:-}" ] || printf 'REPRO_INSTALLING_BUILD=%s\n' "$2"
		printf '# reprobuild.managed-hook.v1.pre-push.%s\n' "$1"
	} >"$hooks/pre-push.repro-managed"
}
status=0
enter() { # [checkout]
	local checkout="${1:-$work/main}"
	rm -f "$work/ensure.log"
	snippet="$(block)"
	status=0
	# A separate bash, not a subshell: errexit is suspended in a subshell on the
	# left of `||`, and the block has to hold under `set -euo pipefail`.
	ROOT_PATH="$checkout" GITHUB_ACTIONS="" \
		bash -euo pipefail -c 'cd "$1" && eval "$2"' enter "$checkout" "$snippet" \
		>"$work/out" 2>&1 || status=$?
}
says() { grep -qF -- "$1" "$work/out"; }

if [ -z "$(block)" ]; then
	fail "nix/git-hooks.nix has no ct_repro_anchor block"
fi

writer=/nix/store/0000000000000000000000000000000-reprobuild-0.2.19/bin/.reprobuild-wrapped
install_hooks aaaa "$writer"
enter
check "foreign hooks: ensure ran" "ensure did not run" test -e "$work/ensure.log"
check "and the shell still aborts" "the shell did not abort (status $status)" test "$status" -ne 0
check "with the publication-gate error" "no publication-gate error: $(cat "$work/out")" \
	says "ERROR: CodeTracer could not install the Repro publication gate"
check "naming the build that wrote the hooks" "the writer is not named: $(cat "$work/out")" says "$writer"
check "naming the pinned build" "the pinned build is not named: $(cat "$work/out")" says "$work/repro/bin/repro (repro 9.9.9)"
check "naming the re-anchor command for the pinned build" "no re-anchor command: $(cat "$work/out")" \
	says "$work/repro/bin/repro hooks ensure --vcs --re-anchor $work/main"
check "naming the other reconciliation, moving the other build's pin" "no pin remedy: $(cat "$work/out")" \
	says "reprobuild pin"
check "naming the hooks it found foreign" "the foreign hook is not named: $(cat "$work/out")" says "pre-push"

install_hooks aaaa
enter
check "foreign hooks from a build that did not record itself: the shell aborts" \
	"the shell did not abort (status $status)" test "$status" -ne 0
check "and says the writer is not recorded" "no 'not recorded' writer: $(cat "$work/out")" \
	says "not recorded in the hook bodies"
check "with the same re-anchor command" "no re-anchor command: $(cat "$work/out")" \
	says "$work/repro/bin/repro hooks ensure --vcs --re-anchor $work/main"

install_hooks bbbb "$writer"
enter
check "ensure failing with this build's hooks: the shell aborts" "the shell did not abort (status $status)" \
	test "$status" -ne 0
check "with the plain publication-gate error" "no publication-gate error: $(cat "$work/out")" \
	says "ERROR: CodeTracer could not install the Repro publication gate"
nomisleading() { ! says "--re-anchor" && ! says "$writer"; }
check "and no foreign-build remedy" "a foreign-build remedy for this build's hooks: $(cat "$work/out")" nomisleading

mkdir -p "$work/not-a-repo"
enter "$work/not-a-repo"
check "ensure failing outside a Git repository: the shell aborts" "the shell did not abort (status $status)" \
	test "$status" -ne 0
check "with the plain publication-gate error" "no publication-gate error: $(cat "$work/out")" \
	says "ERROR: CodeTracer could not install the Repro publication gate."

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
