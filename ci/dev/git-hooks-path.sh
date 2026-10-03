#!/usr/bin/env bash
#
# git-hooks-path.sh -- keep `core.hooksPath` from silently disabling hooks in
# linked worktrees.
#
#   bash ci/dev/git-hooks-path.sh anchor   repair the relative value git-hooks.nix writes
#   bash ci/dev/git-hooks-path.sh check    exit 1 if the effective value is relative
#
# THE PROBLEM. git-hooks.nix's installationScript, run from the main checkout,
# writes `core.hooksPath=.git/hooks` with `git config --local`. Without
# `extensions.worktreeConfig` that is the COMMON config, read by every worktree.
# git resolves a relative hooks path against the toplevel of whichever worktree
# runs the hook; in a linked worktree `.git` is a file, so the path names nothing
# and git runs no hook at all -- no error, no warning. Commits and pushes from
# that worktree go out unchecked.
#
# ANCHOR. A relative local value that resolves, from the main checkout, to the
# common hooks directory is removed: unset, git uses `$GIT_COMMON_DIR/hooks`
# from every worktree -- the directory the relative value meant. It is not made
# absolute, because a checkout shared between Windows and a Nix shell (WSL on
# the same disk) reads one config, and an absolute path is spelled for one OS
# only. The exception: when a global or system core.hooksPath exists, unsetting
# the local value would let that one win, so the absolute path is written
# instead, to keep outranking it. A relative value that means anything else is
# somebody's deliberate choice and is left alone (and `check` reports it).
# Prints what it did on stderr; never fails the caller.
#
# CHECK. Refuses a RELATIVE effective core.hooksPath from any scope. Every
# checkout of this repository uses the common hooks directory; a relative value
# can only be a path that resolves differently per worktree, which is the
# defect above.
#
# Contract suite: ci/test/git-hooks-path-test.sh
set -euo pipefail

say() { echo "git-hooks-path: $*" >&2; }

is_absolute() {
	case "$1" in
	/* | [A-Za-z]:[\\/]* | '~'*) return 0 ;;
	*) return 1 ;;
	esac
}

anchor() {
	local current common main_wt resolved wanted
	current=$(git config --local --get core.hooksPath) || return 0
	if is_absolute "$current"; then
		return 0
	fi
	common=$(git rev-parse --path-format=absolute --git-common-dir)
	main_wt=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
	wanted=$(CDPATH='' cd -- "$common/hooks" 2>/dev/null && pwd -P) || return 0
	resolved=$(CDPATH='' cd -- "$main_wt" && CDPATH='' cd -- "$current" 2>/dev/null && pwd -P) || resolved=
	if [ "$resolved" != "$wanted" ]; then
		say "core.hooksPath is the relative '$current', which is not this repository's"
		say "  common hooks directory; leaving it as it is."
		return 0
	fi
	if git config --global --get core.hooksPath >/dev/null 2>&1 ||
		git config --system --get core.hooksPath >/dev/null 2>&1; then
		wanted=$(CDPATH='' cd -- "$wanted" && { pwd -W 2>/dev/null || pwd; })
		git config --local core.hooksPath "$wanted"
		say "core.hooksPath: the relative '$current' ran no hooks in linked worktrees;"
		say "  a global/system core.hooksPath exists, so it is now the absolute $wanted"
	else
		git config --local --unset-all core.hooksPath
		say "core.hooksPath: removed the relative '$current', which ran no hooks in"
		say "  linked worktrees. Unset, every worktree uses $common/hooks."
	fi
}

check() {
	local current origin
	current=$(git config --get core.hooksPath) || return 0
	if is_absolute "$current"; then
		return 0
	fi
	origin=$(git config --show-origin --get core.hooksPath | cut -f1)
	say "ERROR: core.hooksPath is the relative '$current' ($origin)."
	say "  git resolves it per worktree; in a linked worktree it names nothing and"
	say "  git runs NO hooks there -- commits and pushes go out unchecked."
	say "  Remedy, from $(git rev-parse --show-toplevel):"
	say "    bash ci/dev/git-hooks-path.sh anchor"
	say "  (or: git config --local --unset core.hooksPath)"
	return 1
}

if ! git rev-parse --git-dir >/dev/null 2>&1; then
	say "not inside a git repository; nothing to do."
	exit 0
fi

case "${1:-}" in
anchor) anchor ;;
check) check ;;
*)
	say "usage: $0 anchor|check"
	exit 2
	;;
esac
