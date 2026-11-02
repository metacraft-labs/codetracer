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
#     and none was created in `src/`;
#   * `devShells.ci`, the shell CI steps capture output from
#     (`$(nix develop .#ci --command …)`), reports the same top level.
# Every value above is read from the shell's STDOUT, so nothing but the command
# may write there: a hook diagnostic on stdout arrives prepended to the value
# (codetracer-pm issues/2026-10-22-codetracer-dev-shell-hook-writes-
# diagnostics-to-stdout.md). The tree-sitter-nim helper the hooks run is also
# checked on its own, because whether a hook reaches it depends on whether the
# `libs/tree-sitter-nim` submodule is checked out.
#
# Runs `nix develop` on the default dev shell, so it is slow; it is not part of
# the in-shell test recipes.
#
#   bash ci/test/dev-shell-writes-nothing-elsewhere-test.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
# A second scratch tree for the helper check: SCRATCH itself must stay an empty
# repository for the "writes nothing" assertions.
TS_SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH" "$TS_SCRATCH"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

# Prints CODETRACER_REPO_ROOT_PATH as seen inside the shell entered from <dir>,
# using the dev shell named by the optional second argument (default: the
# default one). The single quotes are deliberate: the variable expands inside
# that shell.
# shellcheck disable=SC2016
enter() {
	(cd "$1" && nix develop "$REPO${2:+#$2}" --no-write-lock-file \
		-c sh -c 'printf %s "${CODETRACER_REPO_ROOT_PATH:-}"' 2>/dev/null)
}

# The tree-sitter-nim helper, run alone, as both shells' hooks run it. With a
# parser that is already up to date it has nothing to do, and it must say so
# on stderr only. The `tree-sitter` placeholder is the one stand-in here, and
# it is never executed: the helper only checks that a local CLI is executable
# before finding that the parser needs no regeneration. If it ever is run, it
# exits 97 and the helper fails, so this check cannot pass on a fake CLI.
ts_dir="$TS_SCRATCH/libs/tree-sitter-nim"
mkdir -p "$ts_dir/src" "$ts_dir/node_modules/.bin"
printf '{}\n' >"$ts_dir/package.json"
printf 'module.exports = grammar({});\n' >"$ts_dir/grammar.js"
printf '/* generated */\n' >"$ts_dir/src/parser.c"
touch -r "$ts_dir/grammar.js" "$ts_dir/src/parser.c"
printf '#!/bin/sh\nexit 97\n' >"$ts_dir/node_modules/.bin/tree-sitter"
chmod +x "$ts_dir/node_modules/.bin/tree-sitter"
ts_out="$(ROOT_DIR="$TS_SCRATCH" bash "$REPO/non-nix-build/ensure_tree_sitter_nim_parser.sh" 2>"$TS_SCRATCH/stderr")" ||
	fail "the tree-sitter-nim helper failed on an up-to-date parser: $(cat "$TS_SCRATCH/stderr")"
[ -z "$ts_out" ] || fail "the tree-sitter-nim helper wrote to stdout: '$ts_out'"
# Positive control: the helper really reached its "nothing to do" branch, so
# the empty stdout above describes that branch and not a script that stopped
# early.
grep -q 'src/parser.c is up to date' "$TS_SCRATCH/stderr" ||
	fail "control: the tree-sitter-nim helper did not report an up-to-date parser on stderr: $(cat "$TS_SCRATCH/stderr")"

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

root="$(enter "$REPO/src" ci)" || fail "devShells.ci did not start from this repository"
[ "$root" = "$REPO" ] || fail "control: devShells.ci entered from src/, CODETRACER_REPO_ROOT_PATH is '$root', not '$REPO'"

echo "PASS: the dev shell prepares only this repository; entered elsewhere it writes nothing"
