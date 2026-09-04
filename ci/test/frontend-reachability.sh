#!/usr/bin/env bash
#
# frontend-reachability.sh — CI entry point for the exported-symbol
# reachability guard.
#
# WHAT THIS LANE IS FOR
# ---------------------
# One defect shape has now been found twelve times in this frontend: a
# correct, tested capability that nothing reaches. The call trace, the event
# log, locals' origin summary, the origin chain, the `tasks.json` parser, five
# zero-caller storage sites, `setBreakpoints` sent zero times,
# `CalltraceVM.selectedEntry` read and never written, a 1043-line edit-mode
# toolbar viewmodel imported by nothing, a settings dialog whose toggle could
# never open it, `build-clickable` as a row that looked clickable and did
# nothing, and `BuildLocationScanner` — the reader written to stop `nargo`
# warnings being reported as errors, reached only from its own unit test.
#
# Every one of them passed a structural check. Twelve is enough to stop
# finding them one user report at a time.
#
# THIS LANE IS GREEN BY DESIGN UNTIL THE BACKLOG IS CLEARED
# ---------------------------------------------------------
# The first run reports 1180 findings. A guard that reddens CI on day one is a
# guard that gets disabled on day one, so the DEFAULT here is REPORT: the lane
# prints the findings, groups them by module, and exits 0.
#
# Two ways to make it bite, in the order they should be adopted:
#
#   CT_REACHABILITY_MAX=<n>   ratchet. Fails only above a recorded ceiling, so
#                             the number can go down and never up.
#   CT_REACHABILITY_ENFORCE=1 fails on any finding. For after the backlog.
#
# THE RATCHET IS ENGAGED, AND FOR TWO YEARS OF READERS' SAKE: IT WAS NOT.
# --------------------------------------------------------------------------
# `ci/lint/nim.sh` now invokes this script as
# `env CT_REACHABILITY_MAX=1226 bash ci/test/frontend-reachability.sh`, so 1227
# findings fail `lint-nim` and 1226 do not.
#
# AND SO DOES 1222, SINCE 2026-09-04: the threshold is an EQUALITY, not a
# ceiling with room under it. Fewer findings than the number fails as "the
# ceiling has slack, lower it to what you measured", because slack is a budget —
# five slots had already accumulated (1223 measured against a ceiling of 1228)
# and five new unreached exports could have landed unremarked. Only the exact
# count passes, which means this number TRACKS THE TREE in both directions and
# every move is a reviewed line in a diff. The sentence above is phrased in the one direction the prose
# guard parses; both directions are asserted by the contract suite.
#
# THAT SENTENCE SAID 1224 AND 1225 WHILE THE INVOCATION SAID 1228, from 04:04
# to 18:00 on 2026-09-04. The ceiling was raised three times in twenty-nine
# minutes (1224 -> 1226 -> 1228) by commits whose subjects were about other
# things, and each raise moved the `env` and left this paragraph, and the step
# LABEL beside it, behind. `ci/lint/nim.sh` now runs a step that fails when the
# three disagree, so the numbers above cannot go stale again without a red.
#
# Before 2026-09-04 neither variable had a setter anywhere in the repository.
# The paragraph above described a design; `grep -rn CT_REACHABILITY` over
# `.github/`, `justfile`, `ci/` and `scripts/` returned one hit, and it was a
# comment in `nim.sh` recommending that somebody engage it. This lane ran on
# every push, printed its findings, and could not fail over any number of them.
# The allow-list hygiene below could redden CI; the twelve-times-found defect
# this whole file exists for could not.
#
# That is worth stating in the file rather than only in the commit, because the
# gap was invisible from HERE: everything on this side of the boundary was
# correct, tested, and documented. A capability nothing invokes is exactly the
# shape of defect this script was written to find, and it was one.
#
# The allow-list's own hygiene is enforced in ALL modes: an entry without a
# reason, or naming a symbol that no longer exists, fails this lane today. That
# is not part of the backlog — it is the check that keeps the allow-list from
# becoming the thing it was meant to prevent.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

args=()
if [[ -n ${CT_REACHABILITY_MAX:-} ]]; then
	args+=(--max "${CT_REACHABILITY_MAX}")
fi
if [[ ${CT_REACHABILITY_ENFORCE:-0} == "1" ]]; then
	args+=(--enforce)
fi
if [[ ${CT_REACHABILITY_INCLUDE_OWN_MODULE:-0} == "1" ]]; then
	args+=(--include-own-module)
fi
if [[ -n ${CT_REACHABILITY_JSON:-} ]]; then
	args+=(--json "${CT_REACHABILITY_JSON}")
fi

exec python3 "${here}/frontend-reachability-guard.py" \
	--repo-root "${repo_root}" \
	"${args[@]+"${args[@]}"}"
