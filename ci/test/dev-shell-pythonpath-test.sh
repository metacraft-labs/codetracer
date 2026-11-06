#!/usr/bin/env bash
#
# dev-shell-pythonpath-test.sh -- in this repository's dev shells, PYTHONPATH
# carries site-packages of the declared Python minor version only, and the
# pinned interpreter imports the shell's packages from that version.
#
# Every interpreter's nixpkgs setup hook defines a function named
# `addPythonPath`, and the one sourced last replaces the others: it adds
# `lib/python3.N/site-packages` of ITS version for every input of the shell.
# devShells.default holds the pinned 3.12 and, through pre-commit, its hooks,
# awscli2 and pax-utils, nixpkgs' default 3.13, whose hook won. Its PYTHONPATH
# had 25 entries for 3.13 and none for 3.12, and `$CODETRACER_PYTHON_CMD -c
# 'import pytest'` loaded the 3.13 copy ahead of the one in the pinned env
# (codetracer-pm issues/2026-10-31-default-dev-shell-pythonpath-carries-only-
# the-3-13-site-packages.md). The shells now put such applications on PATH
# through nix/python.nix's `binariesOnly`, which drops their setup hooks.
#
# Asserted, for the default and the `ci` dev shell, entered from a scratch
# directory outside this checkout (so the hook writes nothing here):
#   * no PYTHONPATH entry names `lib/python3.N` for another N than
#     $CODETRACER_PYTHON_VERSION, and at least one names that version -- the
#     packages of the shell are still importable, as node-gyp needs distutils;
#   * $CODETRACER_PYTHON_CMD imports pytest from a `lib/python<pin>` directory;
#   * the in-shell guard's (J1) check agrees, so the fast check that runs in
#     `just test` sees what this test sees.
#
# Runs `nix develop`, so it is slow; it is not part of the in-shell test
# recipes.
#
#   bash ci/test/dev-shell-pythonpath-test.sh [shell...]   (default: default ci)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
failures=0
fail() {
	echo "FAIL: $*" >&2
	failures=$((failures + 1))
}

# What the probe prints, one `key=value` line each, read back below. It runs
# from / because `python -c` also searches the current directory.
# shellcheck disable=SC2016 # expanded inside the dev shell, not here
PROBE='
printf "version=%s\n" "${CODETRACER_PYTHON_VERSION:-}"
printf "pythonpath=%s\n" "${PYTHONPATH:-}"
printf "pytest=%s\n" "$(cd / && "$CODETRACER_PYTHON_CMD" -c "import pytest; print(pytest.__file__)" 2>&1)"
printf "guard=%s\n" "$(bash "$CT_PROBE_REPO/scripts/test-python-version-alignment.sh" 2>&1 | grep -E "\(J1?\)" | tr "\n" " ")"
'

shells=("$@")
[ "${#shells[@]}" -gt 0 ] || shells=(default ci)

for shell in "${shells[@]}"; do
	echo "== devShells.$shell"
	out="$(cd "$SCRATCH" && CT_PROBE_REPO="$REPO" nix develop "$REPO#$shell" --command bash -c "$PROBE" 2>/dev/null)" || {
		fail "$shell: nix develop failed"
		continue
	}
	value() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -n 1; }
	version="$(value version)"
	pythonpath="$(value pythonpath)"
	pytest_file="$(value pytest)"
	guard="$(value guard)"

	if [ -z "$version" ]; then
		fail "$shell: CODETRACER_PYTHON_VERSION is not exported"
		continue
	fi

	pin=0
	foreign=()
	IFS=: read -r -a entries <<<"$pythonpath"
	for entry in "${entries[@]}"; do
		v="$(printf '%s\n' "$entry" | sed -nE 's#.*/lib/python(3\.[0-9]+)(/.*)?$#\1#p')"
		if [ -z "$v" ]; then
			continue
		elif [ "$v" = "$version" ]; then
			pin=$((pin + 1))
		else
			foreign+=("$entry")
		fi
	done
	echo "   PYTHONPATH: $pin entries for $version, ${#foreign[@]} for another version"
	if [ "${#foreign[@]}" -ne 0 ]; then
		fail "$shell: PYTHONPATH carries ${#foreign[@]} entries of another minor version than $version, e.g. ${foreign[0]}"
	fi
	if [ "$pin" -eq 0 ]; then
		fail "$shell: PYTHONPATH carries no entry for $version, so the shell's packages are not importable by the pinned interpreter"
	fi

	echo "   pytest: $pytest_file"
	case "$pytest_file" in
	*/lib/python"$version"/*) ;;
	*) fail "$shell: \$CODETRACER_PYTHON_CMD imports pytest from outside lib/python$version: $pytest_file" ;;
	esac

	echo "   guard: $guard"
	case "$guard" in
	*"ok   (J1)"*) ;;
	*) fail "$shell: the in-shell guard's (J1) does not pass: $guard" ;;
	esac
done

if [ "$failures" -ne 0 ]; then
	echo "$failures failure(s)" >&2
	exit 1
fi
echo "PYTHONPATH carries only the declared minor version in: ${shells[*]}"
