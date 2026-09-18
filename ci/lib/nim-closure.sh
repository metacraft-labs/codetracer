#!/usr/bin/env bash
#
# ci/lib/nim-closure.sh — path normalisation for the Nim import walkers.
#
# WHY THIS EXISTS
# ---------------
# `normpath` was written twice, and by the time it was measured the two copies
# had DRIFTED — which is Verification-Harness-Traps §30 in its exact shape,
# arriving through a file copy rather than through a second `if`.
#
#   ci/test/plugin-reactive-boundary.sh   drops a leading "/" and returns a
#                                         RELATIVE path for an absolute input
#   ci/test/sdk-facade-boundary.sh        keeps it
#
# The second is the repaired one, and the repair has a measurement attached to
# it in that file: without the `lead` handling the sibling-package roots came
# back relative, every relative import inside IsoNim failed to resolve, and the
# walk silently entered only the modules reachable by absolute-root lookup. The
# plugin gate never hit it because it resolves repo-relative paths only — so
# the older copy is wrong in a way its own caller cannot reach, which is the
# most durable kind of wrong.
#
# The version below is the REPAIRED one, verbatim.
#
# **AND IT IS A THIRD COPY, NOT A HOIST — corrected 2026-09-18 by PLAT-29's
# verification pass.** Neither older gate was changed. `editor-import-closure.sh`
# is this file's only caller; `plugin-reactive-boundary.sh` still carries the
# DRIFTED spelling and `sdk-facade-boundary.sh` still carries its own copy of
# the repaired one. So this file did not reduce the number of copies of
# `normpath`, it raised it from two to three, and §30's "one predicate, one
# function" is further away than before rather than nearer.
#
# Adopting this copy in the two older gates is meaning-preserving in the plugin
# gate (it passes relative paths only) and NO mutation arm quotes `normpath`'s
# body in any harness, so the change costs a sourcing line in each and no
# re-aimed arm. It is the residual, and it is written down as one.
#
# A SECOND THING THIS FILE IS NOT COVERED BY, measured in the same pass: it is
# a behavioural input to `editor-import-closure.sh` — every module resolution
# goes through `normpath` — and it appears in NO harness's subject list and NO
# control digest. `ci/lib/nim-imports.sh`, the sibling library next door, is a
# subject of PLAT-7's harness with both a digest line and arms aimed at it.
# This one has neither, so a change to it is invisible to PLAT-29's
# control-digest guard and no arm establishes that it is load-bearing.
#
# WHAT IS NOT HERE, AND WHY — measured, 2026-09-18
# -----------------------------------------------
# The obvious next move is to hoist `table_names`, `is_stdlib_spec`,
# `stdlib_admitted` and the closure BFS out of `plugin-reactive-boundary.sh`
# too, so the three walkers share one of each. That was measured rather than
# assumed, and it is NOT done:
#
#   | function          | arms quoting its body                         |
#   | ----------------- | --------------------------------------------- |
#   | `normpath`        | none                                          |
#   | `resolve_repo_module` | none                                      |
#   | `table_names`     | `P31` (run-plat8-io-mutations.py)             |
#   | `stdlib_admitted` | `A1`, `A7` (run-plat8-io-mutations.py)        |
#   | `is_stdlib_spec`  | `G11` (run-plat7-boundary-mutations.py)       |
#   | `plugin_closure`  | `G9`, `G10` (run-plat7-boundary-mutations.py) |
#
# Moving any of the bottom four re-aims six arms across two harnesses, and §32a
# is explicit that re-aiming an arm is a reason to RE-RUN it rather than only to
# re-record its digest — two full harness runs this pass did not have. The cost
# of not moving them is recorded in PLAT-29's status as a residual with the
# measurement above, rather than left to be re-discovered.
#
# Usage:
#   . "$(dirname "${BASH_SOURCE[0]}")/../lib/nim-closure.sh"
#   normpath "a/b/../c"          # -> a/c

# normpath PATH — collapse `.` and `..` textually. No filesystem access, so it
# works for paths that do not exist yet (which is what the synthetic-tree tests
# need).
normpath() {
	local p="$1" out=() part
	# An absolute input must stay absolute. The loop below drops empty
	# components, and the leading empty component of "/a/b" is what makes it
	# absolute — so without this the sibling-package paths came back relative,
	# every relative import inside a sibling package failed to resolve, and the
	# walk silently entered only the modules that happened to be reachable by
	# absolute-root lookup.
	local lead=""
	case "${p}" in
	/*) lead="/" ;;
	esac
	local IFS='/'
	for part in $p; do
		case "${part}" in
		"" | ".") continue ;;
		"..")
			if [ "${#out[@]}" -gt 0 ] && [ "${out[-1]}" != ".." ]; then
				unset 'out[-1]'
			else
				out+=("..")
			fi
			;;
		*) out+=("${part}") ;;
		esac
	done
	local joined="${out[*]}"
	printf '%s' "${lead}${joined}"
}
