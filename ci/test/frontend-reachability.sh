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
# guard that gets disabled on day one, so the default here is REPORT: the lane
# prints the findings, groups them by module, and exits 0.
#
# Two ways to make it bite, in the order they should be adopted:
#
#   CT_REACHABILITY_MAX=<n>   ratchet. Fails only above a recorded ceiling, so
#                             the number can go down and never up. This is the
#                             right next step, and `n` should be set to today's
#                             count the moment someone starts triaging.
#   CT_REACHABILITY_ENFORCE=1 fails on any finding. For after the backlog.
#
# The allow-list's own hygiene is enforced in ALL modes: an entry without a
# reason, or naming a symbol that no longer exists, fails this lane today. That
# is not part of the backlog — it is the check that keeps the allow-list from
# becoming the thing it was meant to prevent.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${here}/../.." && pwd)"

args=()
if [[ -n "${CT_REACHABILITY_MAX:-}" ]]; then
	args+=(--max "${CT_REACHABILITY_MAX}")
fi
if [[ "${CT_REACHABILITY_ENFORCE:-0}" == "1" ]]; then
	args+=(--enforce)
fi
if [[ "${CT_REACHABILITY_INCLUDE_OWN_MODULE:-0}" == "1" ]]; then
	args+=(--include-own-module)
fi
if [[ -n "${CT_REACHABILITY_JSON:-}" ]]; then
	args+=(--json "${CT_REACHABILITY_JSON}")
fi

exec python3 "${here}/frontend-reachability-guard.py" \
	--repo-root "${repo_root}" \
	"${args[@]+"${args[@]}"}"
