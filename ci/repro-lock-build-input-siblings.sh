#!/usr/bin/env bash
# =============================================================================
# Print, comma-separated, the members of codetracer's develop set that are
# BUILD INPUTS: the sibling repos the build compiles from source.
#
#   usage: ci/repro-lock-build-input-siblings.sh [path/to/repro.lock]
#
# `repro.lock` answers two questions for the `codetracer` node:
#
#   * `depends` -- the develop set: every sibling repo this commit is built
#     AND tested against, each pinned by a `deps` entry. It includes the
#     recorders, the native backend and the trace-format crates the test
#     lanes provision through `clone-siblings`, some of which are private.
#   * `packages` -- the solved build graph: what `repro.nim` `uses`. A sibling
#     repo appears here when the build consumes it from source (`isonim`,
#     `nim-acp`, ... -- the libraries `config.nims` puts on the Nim path).
#
# The members of the first set that are also in the second are the siblings
# a Nim build needs checked out next to codetracer, and that is what
# `.github/actions/provision-repro-lock-siblings` clones. Deriving the list
# here keeps the lock the only source of the answer: declaring a new from-
# source dependency in `repro.nim` and relocking adds it, with no list to
# edit. `ci/test/sibling-provisioning-test.sh` pins the current output so a
# change to it is a visible decision.
#
# Exits non-zero, printing nothing on stdout, when the lock cannot be read or
# yields no build-input sibling at all: provisioning nothing is never right.
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

# The `codetracer` node of `deps`: `self = "true"` in a v3 lock, `path = "."`
# in a v2 one. `[^}]*` keeps the match inside that one inline table, and the
# leftmost match is the node itself -- the same entry the grep|head pipeline
# this replaces selected.
codetracer_node='name = "codetracer", (self = "true"|path = "\.")[^}]*depends = "([^"]*)"'
if [[ $lock_text =~ $codetracer_node ]]; then
	depends="${BASH_REMATCH[2]}"
else
	depends=""
fi
if [ -z "$depends" ]; then
	echo "repro-lock-build-input-siblings: $lock declares no develop set for codetracer" >&2
	exit 1
fi

selected=()
IFS=',' read -r -a members <<<"$depends"
for member in "${members[@]}"; do
	# A solved package entry: `{ name = "<m>", version = "...", source = "<m>", ...`
	# The quoted parts of the pattern match literally, so a `.` in a member
	# name is not a wildcard.
	if [[ $lock_text =~ "{ name = \"${member}\", version = \""[^\"]*"\", source = \"${member}\"" ]]; then
		selected+=("$member")
	fi
done

if [ "${#selected[@]}" -eq 0 ]; then
	echo "repro-lock-build-input-siblings: none of $lock's develop set ($depends) is a build input" >&2
	exit 1
fi

(
	IFS=','
	echo "${selected[*]}"
)
