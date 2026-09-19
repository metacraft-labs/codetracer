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
# `env CT_REACHABILITY_MAX=1258 bash ci/test/frontend-reachability.sh`, so 1259
# findings fail `lint-nim` and 1258 do not.
#
# THE CEILING MOVED 1245 -> 1258 ON 2026-09-19 (PLAT-31), and its reason is the
# one worth reading first, because the GROSS was +16 and three of those were
# DELETED instead of ratcheted past. The `nothing` bucket and the
# `tested-only` bucket are not the same finding and PLAT-31 is the move that
# treated them differently: three symbols reached by nothing at all were
# removed (a public helper nobody calls is dead code, not a backlog item), and
# thirteen ordinary exports with a suite and no product caller were ratcheted.
# The full reason lives in the setter beside the invocation in `ci/lint/nim.sh`.
#
# THE CEILING MOVED 1238 -> 1245 ON 2026-09-18 (PLAT-30), and 1225 -> 1238
# earlier the same day (PLAT-29). Both reasons live in the setter beside the
# invocation in `ci/lint/nim.sh`. PLAT-30's is the more interesting of the two,
# because its GROSS is +13 and its NET is +7: the vocabulary became the first
# PRODUCT reader of six exports of `wrap.nim`, `selection.nim`,
# `selection_ops.nim` and `edit_binding.nim`, so it paid part of its own way.
#
# THE EARLIER MOVE, kept because a ceiling with one reason reads as a ceiling
# that has only ever moved once: 1225 -> 1238 on 2026-09-18, and the reason is in the
# setter beside the invocation: PLAT-29 built an asynchronous boundary whose
# two modules are exercised by their suites and reached by no product module,
# because wiring the four producers behind it is that milestone's declared
# residual. Measured both sides on one host: `origin/dev` at `421b1dcbb`
# reported 1220, the tree with PLAT-29 reports 1238, and the 19-finding
# difference is exactly `document_version.nim` and `reconcile.nim`. The number
# falls again when the producers land; it is a ceiling, so it can.
#
# IT WAS RED FOR SEVEN DAYS, AND WHY IT IS NOT RED NOW IS THE FIRST THING A
# READER NEEDS.
# ----------------------------------------------------------------------
# Measured 2026-09-11 at `422647a0`: this tree carried **1800** findings
# against a ceiling of **1226**, so the step was RED, and had been since
# `a638661447e706d95b9f8bd7e0f07886cc89f3dd` (2026-09-05 12:40, 1253
# findings). The last commit at which it was green is
# `a9e7f12d5f74a75281ef6a2f0b1426a5a3703abb` (2026-09-05 10:13), and every
# first-parent commit in that window failed it — 32 of them counting the first
# red, re-counted 2026-09-12 after this header said 44.
#
# So for those seven days: **this number was a REPORT and not a gate.** Five
# campaigns quoted "reachability N, allow-list 0/0" in their evidence tables as
# though the lane enforcing a ceiling on N had passed. It had not, and it could
# not have: an equality against a ceiling 574 below the tree fails for every
# tree.
#
# **ON 2026-09-12 THE COUNT CHANGED AND THE CEILING DID NOT.** Two repairs, in
# this order, and neither of them wires or deletes a single symbol:
#
#   1. The guard stopped labelling a symbol its own module reaches as "no
#      product module reaches it" — a bucket-order bug this lane's own header
#      had measured and left. 722 findings moved from bucket A to bucket C
#      (not counted): **1800 -> 1078**, with bucket B unchanged at 633.
#   2. `CT_REACHABILITY_MAX` went back to being a CEILING rather than an
#      equality, so a count BELOW it reports and does not fail.
#
# At 1078 against 1226 this step passes, **with 148 slots of slack reported on
# every run**. That is a real budget and it is stated here rather than left to
# be discovered: the green tick means the number is now counted correctly, not
# that the backlog has been cleared.
#
# The drift was not one bad merge. It is two campaigns landing large, tested,
# not-yet-wired subsystems: `src/frontend/tui/` went 3 -> 423 between 09-05
# and 09-08, and `src/frontend/viewmodel/plugin_host/` went 0 -> 90 between
# 09-08 and 09-11 — the shape this repository generates by design.
#
# **The remedy was deliberately NOT "raise the ceiling to 1800"**, and it is
# still not "lower it to 1078". Either re-fits the number to the tree, which
# turns a broken gate into a silent one. Three candidate repairs are costed
# with real numbers in PLAT-11's milestone section
# (`codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org`).
# **The decision is (c), "no new findings in files this change touched"**,
# recorded with its reasoning in `frontend-reachability-guard.py`'s own header.
# It is a repo-wide policy change and needs its own pass; until it lands, the
# 148 slots are the cost of not failing on an improvement.
#
# WHY THE EQUALITY WENT, MEASURED. From 2026-09-04 to 2026-09-12 the threshold
# was an EQUALITY: fewer findings than the number failed as "the ceiling has
# slack, lower it to what you measured", because slack is a budget — five slots
# had already accumulated (1223 measured against a ceiling of 1228). The cost
# was measured too. `f274fa68` and `ab7ce4c1` (2026-09-05) carry **1225**
# findings against a ceiling of 1226 and both exit 1: CI was red for five hours
# because the tree had got better, and went green when an unrelated commit put
# the count back up. A gate that fires on an improvement, and whose only remedy
# is to edit a number in another file, teaches people the lane is noise. The
# slack side still REPORTS, loudly and with the value to lower the ceiling to;
# it no longer sets the exit code. `ci/test/reachability-ratchet-test.sh` arm 2
# asserts exactly that and carries the measurement.
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
#
# ---------------------------------------------------------------------------
# THE PATH TO `--enforce`, BECAUSE A FLAG NOBODY SETS CANNOT BE TOLD APART FROM
# A FLAG THAT DOES NOT EXIST
# ---------------------------------------------------------------------------
# `CT_REACHABILITY_ENFORCE=1` is set by no caller in this repository and never
# has been. Saying "once the backlog is cleared" is not a plan, because nothing
# names who clears it or in what order. Measured on 2026-09-04, the 1226 counted
# findings are not one backlog but three, and they want three different answers:
#
#   355  BUCKET A, MISLABELLED. **DONE 2026-09-12 — and it was 722, not 355.**
#        The header printed "tested, no product module reaches it", and for
#        these the DECLARING MODULE DID reach them:
#        `frontend-reachability-guard.py` tested `key in tested` before
#        `elif readers`, so a symbol its own module uses was relabelled the
#        moment a test mentioned its name. These were never a backlog to clear;
#        they were a classification to correct, and correcting it moved them to
#        bucket C (not counted). The branches are swapped. Measured before and
#        after with nothing else changed: 1800 -> 1078 counted, bucket A
#        1167 -> 445, bucket C 1922 -> 2644, bucket B unchanged at 633 — which
#        is the check that only the intended rows moved. The 355 was measured
#        when the total was 1226; the shape grows because this repository
#        generates it, building and testing a ViewModel before any front-end
#        wires it. IT WAS STEP ONE, because every number below was wrong until
#        it was answered — so the two below are re-measured rather than quoted.
#
#   445  BUCKET A, GENUINE (was 295 at a total of 1226). A test reaches it and
#        no product code does. This is the shape the guard was written for — a
#        tested capability that is dead in the product, which is exactly the
#        false confidence its header describes. These are triage, one owner at
#        a time: wire it, delete it, or allow-list it with a reason that is not
#        "the test covers it".
#
#   633  BUCKET B (was 576 at a total of 1226). Nothing reaches it at all, not
#        even a test. Cheapest of the three to clear, because deleting an
#        unreferenced export breaks nothing by construction, and it is where
#        the 1228 -> 1223 descent came from.
#
# THE ORDER MATTERED AND IT WAS NOT "SMALLEST FIRST": step one was free and
# made the other two honest, step three is mechanical, step two needs owners.
#
# AND THE INTERIM, WHICH DOES NOT WAIT FOR ANY OF IT. Full `--enforce` over a
# four-figure backlog is the guard-that-gets-switched-off, so the useful
# intermediate is SCOPED enforcement: zero findings permitted in files added
# after a chosen commit, with everything older grandfathered by the ratchet.
# That makes the backlog strictly historical — it can only be paid down, never
# added to — and it is the same shape as the recorded-dark inventory next door,
# which is allowed to shrink and not to grow. It needs one thing this script
# does not have yet: a per-file birth date, which `git log --diff-filter=A` can
# supply and which nothing here reads today.
#
# Until one of those lands, this lane is a RATCHET and not a gate, and the
# distinction is written on the tin: `--max` fails only ABOVE the recorded
# number, reports the slack below it (since 2026-09-12 — see "WHY THE EQUALITY
# WENT" above), and `--enforce` remains unset.

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
