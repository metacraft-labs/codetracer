#!/usr/bin/env bash
# Entering `nix develop .#pre-commit` must not touch the repository's hooks.
#
# devShells.pre-commit used to take git-hooks.nix's devShell through
# `inputsFrom`, and mkShell concatenates every input's shellHook, so entering
# it ran upstream's installationScript: the Reprobuild dispatchers for
# pre-commit and pre-push went to `<hook>.legacy` and relative-config
# pre-commit shims took their slots (main checkout, 2026-11-26), and the
# publication gate stopped running. Hooks are installed by devShells.default
# alone, through nix/git-hooks.nix, which keeps the dispatchers.
#
# This evaluates the shell's real shellHook, runs it in a scratch repository
# whose hooks directory holds Reprobuild dispatchers, and requires every hook
# file to come out byte for byte as it went in. Positive control: the same
# check, run around a real `pre-commit install` (what upstream's
# installationScript does), must see the dispatchers displaced, or the check
# could not tell the difference.
#
# Lane: ci/lint/nix.sh.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
fail() {
	echo "pre-commit-shell-keeps-dispatchers: FAIL: $*" >&2
	exit 1
}

shell_hook="$(nix eval --raw "$repo#devShells.${system}.pre-commit.shellHook")" ||
	fail "could not evaluate devShells.${system}.pre-commit.shellHook"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/ct-pre-commit-shell.XXXXXX")"
trap 'rm -rf "${scratch:?}"' EXIT

# make_repo DIR: a repository whose pre-commit and pre-push slots hold
# Reprobuild dispatchers, as `repro hooks ensure --vcs` leaves them.
make_repo() {
	git init -q "$1"
	local hook
	for hook in pre-commit pre-push; do
		printf '#!/usr/bin/env sh\n# reprobuild hook dispatcher protocol=2\n# %s fixture\nexit 0\n' "$hook" >"$1/.git/hooks/$hook"
		chmod +x "$1/.git/hooks/$hook"
	done
}
# hooks_digest DIR: every hook file's name and content.
hooks_digest() {
	(cd "$1/.git/hooks" && for f in *; do [ -f "$f" ] && printf '%s %s\n' "$f" "$(sha256sum <"$f" | cut -d' ' -f1)"; done)
}
# run_hook DIR TEXT: run a shellHook TEXT from DIR, as `nix develop` would.
run_hook() {
	(cd "$1" && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 PRE_COMMIT_HOME="$scratch/pc-home" bash -c "$2" >"$scratch/hook.log" 2>&1) || true
}

# --- the shell itself -------------------------------------------------------
make_repo "$scratch/repo"
before="$(hooks_digest "$scratch/repo")"
run_hook "$scratch/repo" "$shell_hook"
after="$(hooks_digest "$scratch/repo")"
[ "$before" = "$after" ] || {
	cat "$scratch/hook.log" >&2
	fail "entering devShells.pre-commit changed the hooks:
before:
$before
after:
$after"
}
echo "  ok   devShells.pre-commit leaves the Reprobuild dispatchers and every other hook as they were"

# --- positive control ---------------------------------------------------------
# A real installer around the same check must be seen to displace them.
command -v pre-commit >/dev/null 2>&1 || {
	echo "pre-commit-shell-keeps-dispatchers: pre-commit is not on PATH; the positive control needs it (exit 3)" >&2
	exit 3
}
make_repo "$scratch/control"
printf 'repos: []\n' >"$scratch/control/.pre-commit-config.yaml"
before="$(hooks_digest "$scratch/control")"
run_hook "$scratch/control" "pre-commit install --hook-type pre-commit --hook-type pre-push"
after="$(hooks_digest "$scratch/control")"
[ "$before" != "$after" ] && [ -f "$scratch/control/.git/hooks/pre-commit.legacy" ] ||
	fail "positive control: a real 'pre-commit install' did not displace the dispatchers, so this check cannot see the defect"
echo "  ok   positive control: 'pre-commit install' moves a dispatcher to .legacy, and the check sees it"
echo "pre-commit-shell-keeps-dispatchers: ok"
