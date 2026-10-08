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
# =============================================================================
set -euo pipefail

lock="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/repro.lock}"
if [ ! -f "$lock" ]; then
	echo "repro-lock-build-input-siblings: no lock at $lock" >&2
	exit 1
fi

depends="$(grep -o 'name = "codetracer", path = "\."[^}]*depends = "[^"]*"' "$lock" |
	sed 's/.*depends = "//; s/"$//' | head -n 1)"
if [ -z "$depends" ]; then
	echo "repro-lock-build-input-siblings: $lock declares no develop set for codetracer" >&2
	exit 1
fi

selected=()
IFS=',' read -r -a members <<<"$depends"
for member in "${members[@]}"; do
	# A solved package entry: `{ name = "<m>", version = "...", source = "<m>", ...`
	if grep -q "{ name = \"${member}\", version = \"[^\"]*\", source = \"${member}\"" "$lock"; then
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
