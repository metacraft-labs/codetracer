#!/usr/bin/env bash
#
# should-install-git-hooks.sh -- decide whether THIS checkout may (re)install
# the repository's git hooks.
#
#   exit 0  -> install; the caller runs git-hooks.nix's installationScript
#   exit 1  -> skip; hooks belong to another checkout and already work
#
# The reason is always printed on stderr. Nothing here writes to the repository.
#
# WHY THIS DECISION EXISTS AT ALL
# -------------------------------
# `git config --local` IS NOT PER-WORKTREE unless `extensions.worktreeConfig` is
# set, and this repository does not set it. It writes the COMMON config, so a
# `core.hooksPath` written from one worktree is read by every worktree and by the
# main checkout.
#
# git-hooks.nix means to write a repo-relative path, and tries to:
#
#     common_dir=$(git rev-parse --path-format=absolute --git-common-dir)
#     common_dir=${common_dir#$GIT_WC/}
#
# In a linked worktree that strip is a NO-OP. `GIT_WC` is the worktree's own
# toplevel while the common dir belongs to the main checkout, so the prefix never
# matches, the value stays absolute, and every checkout in the repository is
# pinned to one hooks directory.
#
# That alone would be survivable, because the script would at least be adding
# hooks. It is not: it first `pre-commit uninstall`s NINE hook types AND blanks
# `core.hooksPath`, then reinstalls. Entering the dev shell from a worktree
# therefore tears down and rebuilds the hooks every other worktree is relying on,
# mid-flight. The signature is visible in this repository: `pre-push` has a
# `pre-push.repro-managed` sibling and `pre-commit` has none -- two installers
# overwriting each other rather than composing. `repro hooks ensure` is the other
# one, and it owns the pre-push dispatcher this project's push protocol needs.
#
# WHY THE SKIP IS CONDITIONAL RATHER THAN FLAT
# --------------------------------------------
# A checkout with NO hooks is worse than one sharing another checkout's, because
# `--no-verify` is forbidden here and a silently absent pre-push means unverified
# pushes. So the skip applies only when the hooks the worktree would inherit
# ACTUALLY EXIST. When they do not, this returns "install" -- accepting the
# shared write, loudly -- because unprotected is the one outcome that must never
# happen quietly.
#
# Contract suite: ci/test/git-hooks-worktree-test.sh
set -euo pipefail

say() { echo "should-install-git-hooks: $*" >&2; }

if ! command -v git >/dev/null 2>&1; then
	# Matches git-hooks.nix's own behaviour in a pure shell: no git, no install.
	say "git is not on PATH; nothing to decide."
	exit 1
fi

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	say "not inside a git repository; nothing to decide."
	exit 1
fi

root_path="$(git rev-parse --show-toplevel)"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"

# A linked worktree is exactly "the common git dir is not my own .git". Comparing
# the two paths is the test git itself uses; there is no boolean to ask for.
if [ "$common_dir" = "$root_path/.git" ]; then
	say "main checkout ($root_path); installing hooks."
	exit 0
fi

hooks_dir="$(git rev-parse --path-format=absolute --git-path hooks)"

# `pre-push` is the probe rather than `pre-commit` because it is the hook this
# project cannot do without: pushes are verified through it and `--no-verify` is
# not an available escape. If it is present and executable, the worktree is
# protected and has no reason to rewrite anything.
if [ -x "$hooks_dir/pre-push" ]; then
	say "linked worktree ($root_path); hooks are owned by $hooks_dir -- skipping."
	say "reinstalling from here would rewrite them for every worktree."
	exit 1
fi

say "WARNING: linked worktree ($root_path) with no executable pre-push hook at"
say "  $hooks_dir"
say "  Installing from here, which also rewrites hooks for the other worktrees."
say "  An unhooked checkout is the worse outcome, so this is deliberate."
exit 0
