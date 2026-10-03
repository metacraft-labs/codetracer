#!/usr/bin/env bash
# build-once.sh sources the cached dev-shell profile with THIS repository as
# the current directory, whatever directory it is invoked from.
#
# When tup or nim is not on PATH, build-once.sh sources
# `.direnv/flake-profile-*.rc`, nix-direnv's cached evaluation of the dev
# shell. That file carries the shell's whole shellHook, which prepares "the
# current checkout" (`node_modules` link, `.pre-commit-config.yaml`, git hooks)
# from `git rev-parse --show-toplevel`. Invoked as
# `bash /path/to/codetracer/scripts/build-once.sh` from another repository, the
# hook used to prepare THAT repository: it planted a `node_modules` link at the
# workspace root and installed this repository's hooks into a sibling.
#
# The real build-once.sh runs from a scratch git repository with a PATH that
# has no tup/nim, against a copy of this repository's layout whose profile
# records the directory it was sourced in and then ends the run. Asserted: the
# profile was sourced in this repository's top level, and the scratch
# repository is untouched.
#
#   bash scripts/test-build-once-profile-cwd.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail() {
	echo "FAIL: $*" >&2
	exit 1
}

CT="$WORK/codetracer"
mkdir -p "$CT/scripts" "$CT/.direnv" "$WORK/bin"
cp "$REPO/scripts/build-once.sh" "$CT/scripts/"
MARK="$WORK/sourced-in"
cat >"$CT/.direnv/flake-profile-test.rc" <<RC
pwd -P >"$MARK"
exit 0
RC

# A PATH with the basic tools build-once.sh needs before the profile, and
# without tup or nim, so the profile branch is taken.
for tool in bash dirname cat; do
	ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done

OTHER="$WORK/other"
mkdir -p "$OTHER"
git -C "$OTHER" init -q
(cd "$OTHER" && PATH="$WORK/bin" bash "$CT/scripts/build-once.sh") ||
	fail "build-once.sh did not reach the profile"
[ -f "$MARK" ] || fail "the cached profile was not sourced"
sourced_in="$(cat "$MARK")"
expected="$(cd "$CT" && pwd -P)"
[ "$sourced_in" = "$expected" ] ||
	fail "the cached profile was sourced in '$sourced_in', not in this repository ('$expected')"
[ -z "$(git -C "$OTHER" status --porcelain --ignored)" ] ||
	fail "the calling repository was modified"

echo "PASS: build-once.sh sources the cached dev-shell profile inside this repository"
