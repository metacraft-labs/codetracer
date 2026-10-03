#!/usr/bin/env bash
#
# dev-shell-writes-nothing-elsewhere-test.sh -- entering this repository's dev
# shell from ANOTHER git repository writes nothing into that repository.
#
# The shell's hook prepares a CodeTracer checkout: it links `node_modules` to the
# Nix-built frontend modules, links `.pre-commit-config.yaml`, installs git hooks
# and points the build at `src/build-<config>`. The checkout used to be whatever
# `git rev-parse --show-toplevel` reported for the directory the shell was
# entered from, so `nix develop /path/to/codetracer` run elsewhere (the
# workspace root, a sibling repository) planted a `node_modules` symlink and a
# hook config there. A `node_modules` at the workspace root is resolved upwards
# by node and tsc from every repository below it, silently satisfying imports
# those repositories never declared.
#
# Asserted, from a scratch git repository and a subdirectory of it:
#   * nothing appears there (no file, link or directory), no hook is installed,
#     `core.hooksPath` is untouched;
#   * CODETRACER_REPO_ROOT_PATH is not the scratch repository.
# Positive control, entered from this repository's `src/` directory:
#   * CODETRACER_REPO_ROOT_PATH is this repository's top level;
#   * `node_modules` and `.pre-commit-config.yaml` are links at that top level,
#     and none was created in `src/`.
#
# Runs `nix develop` on the default dev shell, so it is slow; it is not part of
# the in-shell test recipes.
#
#   bash ci/test/dev-shell-writes-nothing-elsewhere-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Prints CODETRACER_REPO_ROOT_PATH as seen inside the shell entered from <dir>.
# The single quotes are deliberate: the variable expands inside that shell.
# shellcheck disable=SC2016
enter() {
	(cd "$1" && nix develop "$REPO" --no-write-lock-file \
		-c sh -c 'printf %s "${CODETRACER_REPO_ROOT_PATH:-}"' 2>/dev/null)
}

git -C "$SCRATCH" init -q
git -C "$SCRATCH" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$SCRATCH/sub"
hooks_before="$(ls "$SCRATCH/.git/hooks")"

for dir in "$SCRATCH" "$SCRATCH/sub"; do
	root="$(enter "$dir")" || fail "the dev shell did not start from $dir"
	case "$root" in
	"$SCRATCH"*) fail "entered from $dir: CODETRACER_REPO_ROOT_PATH is the other repository ($root)" ;;
	esac
	[ -z "$(git -C "$SCRATCH" status --porcelain --ignored)" ] ||
		fail "entered from $dir: files were written into the other repository: $(git -C "$SCRATCH" status --porcelain --ignored | tr '\n' ' ')"
	# git status does not list empty directories.
	extra="$(cd "$SCRATCH" && find . -mindepth 1 -path ./.git -prune -o ! -path ./sub -print)"
	[ -z "$extra" ] || fail "entered from $dir: entries were created in the other repository: $(echo "$extra" | tr '\n' ' ')"
	[ "$(ls "$SCRATCH/.git/hooks")" = "$hooks_before" ] ||
		fail "entered from $dir: git hooks were installed into the other repository"
	[ -z "$(git -C "$SCRATCH" config --local --get core.hooksPath || true)" ] ||
		fail "entered from $dir: the other repository's core.hooksPath was changed"
done

[ ! -e "$REPO/src/node_modules" ] && [ ! -e "$REPO/src/.pre-commit-config.yaml" ] ||
	fail "precondition: $REPO/src already holds node_modules or .pre-commit-config.yaml"
root="$(enter "$REPO/src")" || fail "the dev shell did not start from this repository"
[ "$root" = "$REPO" ] || fail "control: entered from src/, CODETRACER_REPO_ROOT_PATH is '$root', not '$REPO'"
[ -L "$REPO/node_modules" ] || fail "control: entered from src/, $REPO/node_modules is not a link"
[ -L "$REPO/.pre-commit-config.yaml" ] || fail "control: entered from src/, $REPO/.pre-commit-config.yaml is not a link"
[ ! -e "$REPO/src/node_modules" ] && [ ! -e "$REPO/src/.pre-commit-config.yaml" ] ||
	fail "control: entered from src/, links were created in src/"

echo "PASS: the dev shell prepares only this repository; entered elsewhere it writes nothing"
