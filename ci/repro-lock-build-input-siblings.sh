#!/usr/bin/env bash
# =============================================================================
# Print, comma-separated, the members of codetracer's develop set that
# `.github/actions/provision-repro-lock-siblings` clones: every sibling repo the
# lock pins that is also a solved package.
#
#   usage: ci/repro-lock-build-input-siblings.sh [path/to/repro.lock]
#
# `repro.lock` answers two questions:
#
#   * `deps` -- the develop set: every sibling repo this commit is built AND
#     tested against, each pinned by its own entry. Since reprobuild 5a1326957
#     the lock records a GRAPH: the `codetracer` entry's `depends` lists only
#     its DIRECT dependencies (what `repro.nim` `uses:`), and the entries
#     below it hold the whole transitive set its recipes derive. So the develop
#     set is every `deps` entry other than codetracer's own, not the root's
#     `depends` field.
#   * `packages` -- the solved build graph. Every sibling a `uses:` entry names
#     is solved as a package (a sibling that builds nothing carries a minimal
#     `repro.nim` so it can be named), whether the build compiles it or only a
#     test lane reads it.
#
# The lock therefore no longer separates Nim build inputs from test-lane
# siblings, and the owner's decision (2026-11-16) is to provision the whole
# declared set: every develop-set member that is a solved package. The one
# member that is not -- `reprobuild-packages`, reached through a source
# `import` in `repro.nim` rather than a `uses:` -- is the package catalog,
# which the jobs pin and fetch on their own. Deriving the list here keeps the
# lock the only source of the answer: declaring a dependency in `repro.nim`
# and relocking adds it, with no list to edit. Several members are private,
# so the action clones with the job's minted token.
#
# Exits non-zero, printing nothing on stdout, when the lock cannot be read or
# yields no sibling at all: provisioning nothing is never right.
#
# BASH BUILTINS ONLY. `.github/actions/provision-repro-lock-siblings` runs this
# in a raw `shell: bash` step, BEFORE `nix develop`, and a nix-darwin runner's
# PATH there has neither `grep` nor `sed` (infra's runner `extraPackages`
# lists neither; the NixOS runners have them only through systemd's default
# service PATH). Written with them, this script died on macOS with
#
#   ci/repro-lock-build-input-siblings.sh: line 38: grep: command not found
#
# and took test-non-gui and test-ui-tests with it (codetracer-pm
# issues/2026-10-22-provision-repro-lock-siblings-runs-grep-and-sed-outside-
# the-dev-shell-on-darwin.md). So the lock is read with `$(<file)` and matched
# with `[[ =~ ]]`, and no external command is run at all.
# `ci/test/sibling-provisioning-test.sh` runs it under a PATH holding nothing
# but bash and compares the result with the normal run.
# =============================================================================
set -euo pipefail

if [ "$#" -ge 1 ]; then
	lock="$1"
else
	# `dirname` without `dirname`: this file lives in ci/, the lock one up.
	script_dir="${BASH_SOURCE[0]%/*}"
	[ "$script_dir" != "${BASH_SOURCE[0]}" ] || script_dir=.
	lock="$(cd "$script_dir/.." && pwd -P)/repro.lock"
fi
if [ ! -f "$lock" ]; then
	echo "repro-lock-build-input-siblings: no lock at $lock" >&2
	exit 1
fi

lock_text="$(<"$lock")"

# Every `deps` entry other than codetracer's own, in lock order. An entry
# opens `{ name = "<n>", ` followed by `self = "true", ` (codetracer, v3),
# `path = "<p>", ` (v2) or directly by `coord_kind`. `[[ =~ ]]` has no global
# match, so the text is consumed one entry at a time.
deps_entry='\{ name = "([^"]+)", (self = "true", |path = "([^"]*)", )?coord_kind = '
members=()
rest="$lock_text"
while [[ $rest =~ $deps_entry ]]; do
	name="${BASH_REMATCH[1]}"
	if [ "${BASH_REMATCH[2]}" != 'self = "true", ' ] && [ "${BASH_REMATCH[3]}" != "." ]; then
		members+=("$name")
	fi
	rest="${rest#*"${BASH_REMATCH[0]}"}"
done
if [ "${#members[@]}" -eq 0 ]; then
	echo "repro-lock-build-input-siblings: $lock declares no develop set for codetracer" >&2
	exit 1
fi

selected=()
for member in "${members[@]}"; do
	# A solved package entry: `{ name = "<m>", version = "...", source = "<m>", ...`
	# The quoted parts of the pattern match literally, so a `.` in a member
	# name is not a wildcard.
	if [[ $lock_text =~ "{ name = \"${member}\", version = \""[^\"]*"\", source = \"${member}\"" ]]; then
		selected+=("$member")
	fi
done

if [ "${#selected[@]}" -eq 0 ]; then
	echo "repro-lock-build-input-siblings: none of $lock's develop set (${members[*]}) is a solved package" >&2
	exit 1
fi

(
	IFS=','
	echo "${selected[*]}"
)
