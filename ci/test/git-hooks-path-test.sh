#!/usr/bin/env bash
#
# git-hooks-path-test.sh -- contract suite for ci/dev/git-hooks-path.sh and its
# wiring into the dev shell.
#
# THE DEFECT. git-hooks.nix's installationScript ends with
#
#     common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
#     common_dir=${common_dir#$GIT_WC/}
#     git config --local core.hooksPath "$common_dir/hooks"
#
# which, run from the main checkout, writes the RELATIVE `.git/hooks`. That key
# lives in the common config, so every linked worktree reads it too; git
# resolves it against the worktree's own toplevel, where `.git` is a file, and
# runs NO hook at all -- no error, no warning. A commit or push made from a
# worktree then skips every check.
#
# WHAT IS PINNED.
#   * The defect is real (case 1): reproduced with upstream's lines verbatim,
#     a commit in a linked worktree runs no hook while the main checkout's does.
#   * `check` refuses a relative core.hooksPath, naming the value and a remedy.
#   * `anchor` repairs the value upstream writes -- from the main checkout and
#     from a linked worktree -- after which a worktree commit runs the hook.
#   * `anchor` leaves a relative value it cannot prove means the common hooks
#     directory alone, and `check` still refuses it.
#   * nix/shells/main.nix runs `anchor` after the installer and `check` after
#     that, so entering the shell can never leave the relative value behind.
#
# No mocks: every case is a real repository with a real `git worktree` and real
# `git commit`s, because the defect is entirely about how git resolves the path
# in a linked worktree, and a mock would encode the belief under test.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOL="$REPO_ROOT/ci/dev/git-hooks-path.sh"

assertions=0
failures=0

ok() {
	assertions=$((assertions + 1))
	printf '  ok   %s\n' "$1"
}

fail() {
	assertions=$((assertions + 1))
	failures=$((failures + 1))
	printf '  FAIL %s\n' "$1"
	if [ "$#" -gt 1 ]; then
		shift
		printf '         %s\n' "$@"
	fi
}

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# Isolate from the developer's own git configuration: a global core.hooksPath
# would change what every case below observes.
export GIT_CONFIG_GLOBAL="$tmp_root/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
: >"$GIT_CONFIG_GLOBAL"

# A main checkout and one linked worktree, with a pre-commit hook in the common
# hooks directory that records which checkout it ran in.
build_fixture() {
	local root="$1"
	rm -rf "$root"
	mkdir -p "$root"
	git -C "$root" init -q --initial-branch=main main
	git -C "$root/main" config user.email t@example.com
	git -C "$root/main" config user.name t
	git -C "$root/main" commit -q --allow-empty -m init
	git -C "$root/main" worktree add -q "$root/wt" -b wt >/dev/null 2>&1
	cat >"$root/main/.git/hooks/pre-commit" <<EOF
#!/bin/sh
git rev-parse --show-toplevel >>"$root/ran"
EOF
	chmod +x "$root/main/.git/hooks/pre-commit"
	: >"$root/ran"
}

# Upstream git-hooks.nix's final three lines, verbatim, run in checkout $1.
upstream_write_hooks_path() {
	(
		cd "$1"
		GIT_WC="$(git rev-parse --show-toplevel)"
		common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
		common_dir=${common_dir#"$GIT_WC"/}
		git config --local core.hooksPath "$common_dir/hooks"
	)
}

hook_ran_in() {
	local root="$1" checkout="$2"
	grep -qx "$root/$checkout" "$root/ran"
}

commit_in() {
	git -C "$1" commit -q --allow-empty -m "c$RANDOM"
}

if [ ! -f "$TOOL" ]; then
	printf 'FAIL: %s is missing; nothing repairs or refuses a relative core.hooksPath\n' "$TOOL"
	exit 1
fi

echo "the defect, reproduced"

# --- Case 1: upstream's write from the main checkout disables worktree hooks
build_fixture "$tmp_root/c1"
upstream_write_hooks_path "$tmp_root/c1/main"
value="$(git -C "$tmp_root/c1/main" config --local --get core.hooksPath)"
commit_in "$tmp_root/c1/main"
commit_in "$tmp_root/c1/wt"
if [ "$value" = ".git/hooks" ] && hook_ran_in "$tmp_root/c1" main &&
	! hook_ran_in "$tmp_root/c1" wt; then
	ok "upstream writes '.git/hooks'; the main checkout runs the hook, the worktree silently does not"
else
	fail "upstream's relative value silently disables worktree hooks" \
		"core.hooksPath='$value'; hook ran in: $(tr '\n' ' ' <"$tmp_root/c1/ran")" \
		"if the worktree now runs the hook, upstream or git changed and this suite's premise should be revisited."
fi

echo "check"

# --- Case 2: check refuses the relative value, from either checkout --------
for where in main wt; do
	if out="$(cd "$tmp_root/c1/$where" && bash "$TOOL" check 2>&1)"; then
		fail "check refuses the relative core.hooksPath (from $where)" "it exited 0: $out"
	else
		case "$out" in
		*"relative"*".git/hooks"*"git-hooks-path.sh anchor"*)
			ok "check refuses the relative core.hooksPath, naming value and remedy (from $where)"
			;;
		*) fail "check names the value and the remedy (from $where)" "got: $out" ;;
		esac
	fi
done

# --- Case 3: check accepts unset and absolute values -----------------------
build_fixture "$tmp_root/c3"
if (cd "$tmp_root/c3/wt" && bash "$TOOL" check >/dev/null 2>&1); then
	ok "check accepts an unset core.hooksPath"
else
	fail "check accepts an unset core.hooksPath"
fi
git -C "$tmp_root/c3/main" config --local core.hooksPath "$tmp_root/c3/main/.git/hooks"
if (cd "$tmp_root/c3/wt" && bash "$TOOL" check >/dev/null 2>&1); then
	ok "check accepts an absolute core.hooksPath"
else
	fail "check accepts an absolute core.hooksPath"
fi

echo "anchor"

# --- Case 4: anchor from the main checkout repairs it, and worktree hooks run
for where in main wt; do
	root="$tmp_root/c4-$where"
	build_fixture "$root"
	upstream_write_hooks_path "$root/main"
	(cd "$root/$where" && bash "$TOOL" anchor >/dev/null 2>&1) || true
	commit_in "$root/wt"
	if (cd "$root/wt" && bash "$TOOL" check >/dev/null 2>&1) && hook_ran_in "$root" wt; then
		ok "anchor (run from $where) repairs the value; a worktree commit runs the hook"
	else
		fail "anchor (run from $where) repairs the value; a worktree commit runs the hook" \
			"core.hooksPath=$(git -C "$root/main" config --local --get core.hooksPath || echo '<unset>')" \
			"hook ran in: $(tr '\n' ' ' <"$root/ran")"
	fi
done

# --- Case 5: anchor is idempotent and leaves a repaired state alone --------
if (cd "$tmp_root/c4-main/main" && bash "$TOOL" anchor >/dev/null 2>&1) &&
	(cd "$tmp_root/c4-main/wt" && bash "$TOOL" check >/dev/null 2>&1); then
	ok "anchor on an already-repaired repository is a no-op"
else
	fail "anchor on an already-repaired repository is a no-op"
fi

# --- Case 6: a relative value naming something else is not rewritten ------
build_fixture "$tmp_root/c6"
git -C "$tmp_root/c6/main" config --local core.hooksPath somewhere-else
(cd "$tmp_root/c6/main" && bash "$TOOL" anchor >/dev/null 2>&1) || true
kept="$(git -C "$tmp_root/c6/main" config --local --get core.hooksPath || true)"
if [ "$kept" = "somewhere-else" ] && ! (cd "$tmp_root/c6/main" && bash "$TOOL" check >/dev/null 2>&1); then
	ok "anchor leaves a relative value it cannot attribute alone, and check still refuses it"
else
	fail "anchor leaves a relative value it cannot attribute alone, and check still refuses it" \
		"core.hooksPath is now '$kept'"
fi

echo "the dev shell"

# --- Case 7: main.nix anchors after the installer, then checks -------------
shell_nix="$REPO_ROOT/nix/shells/main.nix"
order="$(grep -n -e 'installationScript}' -e 'git-hooks-path.sh" anchor' -e 'git-hooks-path.sh" check' "$shell_nix" | cut -d: -f1 | tr '\n' ' ')"
read -r l_install l_anchor l_check _ <<<"$order $(printf ' x x x')"
if [ "$(grep -c 'git-hooks-path.sh" anchor' "$shell_nix")" -ge 1 ] &&
	[ "$(grep -c 'git-hooks-path.sh" check' "$shell_nix")" -ge 1 ] &&
	[ "$l_install" -lt "$l_anchor" ] 2>/dev/null && [ "$l_anchor" -lt "$l_check" ] 2>/dev/null; then
	ok "nix/shells/main.nix runs anchor after the installer, then check"
else
	fail "nix/shells/main.nix runs anchor after the installer, then check" \
		"line numbers (installer anchor check): $order" \
		"without this, entering the shell in the main checkout writes '.git/hooks' back."
fi

echo
if [ "$assertions" -ne 10 ]; then
	printf 'FAIL: ran %d assertions, expected 10\n' "$assertions"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
