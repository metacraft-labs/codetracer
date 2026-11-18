#!/usr/bin/env bash
# ci/test/repro-hooks-worktree-check-test.sh -- a linked worktree's dev shell
# never rewrites the hooks it shares with its main checkout.
#
# nix/git-hooks.nix's shell hook ran `repro hooks ensure --vcs` on every shell
# entry, linked worktrees included, and a worktree whose flake pins a different
# Repro build rewrote the managed hooks the main checkout and every other
# worktree share (11-18: worktrees on reprobuild 0.2.24 and a765c3e79d4; every
# other shell then refused "could not install the Repro publication gate").
# This runs that part of the shell hook, as nix/git-hooks.nix has it, with a
# fake `repro` whose `hooks protocol` accepts one contract token and whose
# `hooks ensure` rewrites every managed hook and logs that it ran:
#   * linked worktree, hooks from another build: hooks byte-identical, ensure
#     never runs, the mismatch and its remedy on stderr;
#   * linked worktree, hooks from this build: nothing written, nothing said;
#   * linked worktree with CT_REPRO_HOOKS_WRITE=1, and the main checkout: ensure
#     runs, as before.
# Negative control: the block as it was (no worktree check) rewrites the shared
# hooks from the linked worktree.
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
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
git -C "$work/main" worktree add -q --detach "$work/wt" HEAD
hooks="$work/main/.git/hooks"

mkdir -p "$work/repro/bin"
cat >"$work/repro/bin/repro" <<FAKE
#!/usr/bin/env bash
case "\$1 \$2" in
"hooks protocol")
	[ "\${4#--hook-contract=}" = "reprobuild.managed-hook.v1.pre-push.\$(cat "$work/this-build")" ] && exit 0
	exit 3 ;;
"hooks ensure")
	echo "ensure \$*" >>"$work/ensure.log"
	for f in "$hooks"/*.repro-managed; do echo rewritten >>"\$f"; done ;;
esac
FAKE
chmod +x "$work/repro/bin/repro"
echo bbbb >"$work/this-build"

# block FILE: the shell hook's Repro step from FILE, Nix escapes undone and
# `${repro}` pointed at the fake.
block() {
	sed -n '/^  ct_repro_anchor=()$/,/^  unset ct_repro_anchor/p' "$1" |
		sed -e "s|''\\\${|\${|g" -e "s|\\\${repro}|$work/repro|g"
}
install_hooks() { # token-digest
	printf '#!/bin/sh\n# reprobuild.managed-hook.v1.pre-push.%s\n' "$1" >"$hooks/pre-push.repro-managed"
	cp "$hooks/pre-push.repro-managed" "$work/before"
}
enter() { # dir block-file [env...]
	local dir="$1" file="$2"
	shift 2
	rm -f "$work/ensure.log"
	snippet="$(block "$file")"
	(
		cd "$dir"
		export ROOT_PATH="$dir" GITHUB_ACTIONS=""
		for kv in "$@"; do export "${kv?}"; done
		eval "$snippet"
	) >"$work/out" 2>&1 || true
}
unchanged() { cmp -s "$work/before" "$hooks/pre-push.repro-managed"; }

current=nix/git-hooks.nix
install_hooks aaaa
enter "$work/wt" "$current"
check "linked worktree, hooks from another build: the shared hooks are byte-identical" \
	"a linked worktree rewrote the shared hooks" unchanged
check "and repro hooks ensure never ran" "ensure ran from a linked worktree: $(cat "$work/ensure.log" 2>/dev/null)" \
	test ! -e "$work/ensure.log"
reported() { grep -q "different Repro build" "$work/out" && grep -q "CT_REPRO_HOOKS_WRITE=1" "$work/out"; }
check "and the mismatch is reported with its remedy" "no mismatch report: $(cat "$work/out")" reported

install_hooks bbbb
enter "$work/wt" "$current"
quiet() { unchanged && [ ! -e "$work/ensure.log" ] && [ ! -s "$work/out" ]; }
check "linked worktree, hooks from this build: nothing written, nothing said" \
	"hooks from this build: ensure.log '$(cat "$work/ensure.log" 2>/dev/null)', out '$(cat "$work/out")'" quiet

install_hooks aaaa
enter "$work/wt" "$current" CT_REPRO_HOOKS_WRITE=1
check "CT_REPRO_HOOKS_WRITE=1 opts a linked worktree back in" "CT_REPRO_HOOKS_WRITE=1 did not run ensure" \
	test -e "$work/ensure.log"

install_hooks aaaa
enter "$work/main" "$current"
check "the main checkout still runs repro hooks ensure" "the main checkout no longer runs ensure" \
	test -e "$work/ensure.log"

# Negative control: the step as it was, from the linked worktree.
git -C "$root" show HEAD:nix/git-hooks.nix >"$work/old-git-hooks.nix"
install_hooks aaaa
enter "$work/wt" "$work/old-git-hooks.nix"
if unchanged; then
	fail "control: the previous step left the shared hooks alone, so this test cannot see the defect"
else
	ok "control: the previous step rewrites the shared hooks from a linked worktree"
fi

echo
if [ "$failures" -gt 0 ]; then
	echo "$failures failure(s)"
	exit 1
fi
echo "all checks passed"
