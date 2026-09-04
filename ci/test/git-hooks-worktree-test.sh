#!/usr/bin/env bash
#
# git-hooks-worktree-test.sh -- contract suite for ci/dev/should-install-git-hooks.sh.
#
# WHAT IS BEING PINNED, AND WHY IT IS NOT "each worktree keeps its own hooks".
# `core.hooksPath` in this repository is COMMON state: `extensions.worktreeConfig`
# is unset, so `git config --local` writes the shared config and every checkout
# reads one value. Giving each worktree its own path would mean turning that
# extension on and populating a hooks directory per worktree -- and a worktree
# whose directory failed to populate has NO pre-push hook, which is the one
# outcome this project cannot absorb, since `--no-verify` is forbidden.
#
# So the invariant asserted here is the reachable one:
#
#   entering the dev shell from a linked worktree must not tear down, rewrite, or
#   repoint the hooks that the other checkouts are using -- UNLESS doing nothing
#   would leave this worktree with no pre-push hook at all, in which case it must
#   install and say so.
#
# Every case below builds a real repository with a real `git worktree`, because
# the defect is entirely about what `git rev-parse` reports in a linked worktree
# and a mock would encode the belief under test.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DECIDE="$REPO_ROOT/ci/dev/should-install-git-hooks.sh"

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

if [ ! -f "$DECIDE" ]; then
	printf 'FAIL: %s is missing; the dev shell would install hooks unconditionally\n' "$DECIDE"
	exit 1
fi

tmp_root="$(mktemp -d)"
cleanup() { rm -rf "$tmp_root"; }
trap cleanup EXIT

# A repository with a main checkout, one linked worktree, and a pre-push hook in
# the common hooks directory -- i.e. the live shape of this campaign's tree.
build_fixture() {
	local root="$1" with_pre_push="$2"
	rm -rf "$root"
	mkdir -p "$root"
	git -C "$root" init -q --initial-branch=main main
	git -C "$root/main" config user.email t@example.com
	git -C "$root/main" config user.name t
	git -C "$root/main" commit -q --allow-empty -m init
	git -C "$root/main" worktree add -q "$root/wt" -b wt >/dev/null 2>&1
	if [ "$with_pre_push" = "yes" ]; then
		printf '#!/bin/sh\nexit 0\n' >"$root/main/.git/hooks/pre-push"
		chmod +x "$root/main/.git/hooks/pre-push"
	else
		rm -f "$root/main/.git/hooks/pre-push"
	fi
}

echo "the decision script"

# --- Case 1: linked worktree, hooks present -> must SKIP -------------------
build_fixture "$tmp_root/c1" yes
if (cd "$tmp_root/c1/wt" && bash "$DECIDE" >/dev/null 2>&1); then
	fail "a linked worktree with working hooks skips installation" \
		"it returned 'install', so entering the dev shell there would run" \
		"git-hooks.nix's uninstall-nine-hooks-then-reinstall against the" \
		"hooks directory every other worktree is using."
else
	ok "a linked worktree with working hooks skips installation"
fi

# The reason must be on stderr. A guard that skips silently is indistinguishable
# from one that never ran, and this one changes behaviour developers rely on.
reason="$(cd "$tmp_root/c1/wt" && bash "$DECIDE" 2>&1 >/dev/null || true)"
case "$reason" in
*"linked worktree"*"skipping"*) ok "the skip says why, on stderr" ;;
*) fail "the skip says why, on stderr" "got: $reason" ;;
esac

# --- Case 2: main checkout -> must INSTALL ---------------------------------
# The guard must not overshoot into "never install anywhere", which would leave
# a fresh clone with no hooks at all.
build_fixture "$tmp_root/c2" yes
if (cd "$tmp_root/c2/main" && bash "$DECIDE" >/dev/null 2>&1); then
	ok "the main checkout still installs"
else
	fail "the main checkout still installs" \
		"the guard has overshot: no checkout would ever install hooks, and a" \
		"fresh clone would be left unprotected."
fi

# --- Case 3: linked worktree, NO pre-push -> must INSTALL ------------------
# Unprotected must never be the quiet outcome.
build_fixture "$tmp_root/c3" no
if (cd "$tmp_root/c3/wt" && bash "$DECIDE" >/dev/null 2>&1); then
	ok "a linked worktree with no pre-push installs rather than stay unhooked"
else
	fail "a linked worktree with no pre-push installs rather than stay unhooked" \
		"skipping here would leave the worktree with no pre-push hook, and" \
		"--no-verify is not an available escape in this project."
fi

reason="$(cd "$tmp_root/c3/wt" && bash "$DECIDE" 2>&1 >/dev/null || true)"
case "$reason" in
*WARNING*"no executable pre-push"*) ok "the install-anyway path warns that it rewrites shared hooks" ;;
*) fail "the install-anyway path warns that it rewrites shared hooks" "got: $reason" ;;
esac

# --- Case 4: the defect itself, demonstrated -------------------------------
# Proof that the thing being guarded against is real: reproduce git-hooks.nix's
# path computation verbatim in a linked worktree and show the strip is a no-op,
# so the value written to COMMON config is an absolute path into another
# checkout. If this ever stops holding, the guard is solving a dead problem and
# should be revisited rather than kept out of habit.
build_fixture "$tmp_root/c4" yes
observed="$(
	cd "$tmp_root/c4/wt"
	GIT_WC="$(git rev-parse --show-toplevel)"
	common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
	echo "${common_dir#"$GIT_WC"/}"
)"
case "$observed" in
/*)
	if [ "$observed" != "$tmp_root/c4/wt/.git" ]; then
		ok "git-hooks.nix's relative-path strip is a no-op in a worktree (yields $observed)"
	else
		fail "git-hooks.nix's relative-path strip is a no-op in a worktree" \
			"expected a path belonging to another checkout, got the worktree's own"
	fi
	;;
*)
	fail "git-hooks.nix's relative-path strip is a no-op in a worktree" \
		"the strip produced the relative path '$observed', so upstream may be" \
		"fixed and this guard's premise no longer holds."
	;;
esac

# --- Case 5: the guard is wired into the dev shell -------------------------
# The script passing its own tests is worth nothing if nothing calls it.
shell_nix="$REPO_ROOT/nix/shells/main.nix"
if grep -q 'should-install-git-hooks.sh' "$shell_nix" &&
	grep -q 'installationScript' "$shell_nix"; then
	# Here-string rather than a pipe: a pipeline ending in `grep -q` can report a
	# successful match as failure under `pipefail`, because grep exits on the
	# first hit and the producer takes SIGPIPE. ci/test/grep-q-pipefail-gate.sh
	# exists to catch exactly this and prescribes this form.
	gate_context="$(grep -B2 'installationScript' "$shell_nix")"
	if grep -q 'should-install-git-hooks.sh' <<<"$gate_context"; then
		ok "nix/shells/main.nix gates installationScript on the decision script"
	else
		fail "nix/shells/main.nix gates installationScript on the decision script" \
			"both strings are present but the guard does not immediately precede" \
			"the installer, so the installer may still run unconditionally."
	fi
else
	fail "nix/shells/main.nix gates installationScript on the decision script" \
		"the dev shell does not reference $DECIDE; hooks are installed" \
		"unconditionally and this whole suite is decorative."
fi

echo
if [ "$assertions" -ne 7 ]; then
	printf 'FAIL: ran %d assertions, expected 7\n' "$assertions"
	failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
	printf '%d of %d assertions failed\n' "$failures" "$assertions"
	exit 1
fi
printf 'all %d assertions passed\n' "$assertions"
