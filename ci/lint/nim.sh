#!/usr/bin/env bash
#
# Nim lint stage.
#
# Every check here runs through ci/lib/lint-steps.sh, which reports all of them
# from one run and decides the exit status at the end. The reason is written up
# in that file: this script used to be a flat `set -e` list whose FIRST command
# was `just test-nimsuggest`, and that command had been crashing, so the
# test-lane coverage guard below it had never executed in CI. A guard that
# cannot run is not a guard.
#
# Order is now cheapest-and-most-portable first. The lane-coverage checks are
# pure bash and git — no Nim toolchain, about a second — so their answer
# ("you added a test file and no lane will ever run it") reaches the log before
# anything that needs a compiler.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1

# The pre-commit shellcheck hook runs without -x, so it cannot follow the
# source and reports SC1091; the source= directive above still tells the -x
# runs (ci/lint/bash.sh) where the library lives.
# shellcheck source=ci/lib/lint-steps.sh disable=SC1091
source ci/lib/lint-steps.sh

# See the note in ci/lint/bash.sh: the stage names its tools before it runs, so
# a shell missing one says so by name instead of failing obscurely inside a
# contract suite. `nimsuggest` is here for ci/test/nimsuggest-check.sh, and
# python3 for ci/test/dap-command-sync.py.
lint_step "tools this stage invokes are present" \
	bash ci/lib/require-tools.sh bash git python3 nimsuggest awk diff sha256sum perl

# The contract suite runs before the guard it covers, and for the same reason
# ci/lint/bash.sh executes scripts/resolve-sibling-rev-test.sh: a guard that has
# only ever been watched printing OK is not evidence. It drives the guard
# against synthetic trees and asserts each of its checks fires by name.
lint_step "test-lane coverage guard: contract suite" \
	bash ci/test/test-lane-coverage-test.sh

# The guard itself: every test-shaped Nim file is either run by a lane or
# declares why it is not.
lint_step "test-lane coverage: every test-shaped file runs somewhere" \
	bash ci/test/test-lane-coverage.sh

# THE SAME QUESTION, ONE FILE EXTENSION OVER. `test-lane-coverage.sh` is scoped
# in its own first line to "any test-shaped **Nim** file", and `ci/test/` holds
# sixty-three SHELL gates that nothing measured. Twelve of them were reachable
# from no workflow, no recipe and no other reachable gate — several with their
# own self-tests beside them, which is work that went in and then ran nowhere.
#
# It sits here, beside its Nim sibling, because the two are one guard asking one
# question about two file types, and a reader who finds one should find the
# other. Its contract suite runs first, for the reason the block above gives.
lint_step "shell-gate coverage guard: contract suite" \
	bash ci/test/shell-gate-coverage-test.sh

lint_step "shell-gate coverage: every gate under ci/ and scripts/ is reachable from a workflow lane" \
	bash ci/test/shell-gate-coverage.sh

# AND THE THIRD ASKING OF THE SAME QUESTION, one level down: not "does this file
# run" but "does anything reach this symbol". Its own header calls it "CI entry
# point for the exported-symbol reachability guard" and no CI root has ever
# named it — the guard against unreachable capability was itself unreachable,
# which `shell-gate-coverage.sh` above has been reporting as an UNRECORDED dark
# gate.
#
# It belongs in this stage rather than a heavier one because it is pure python3
# over the checked-out tree: no Nim toolchain, no browser, no network, under
# five seconds.
#
# THE RATCHET IS NOW ENGAGED. It was not, and that was the defect.
#
# The script is built to bite in two escalating ways — `CT_REACHABILITY_MAX=<n>`
# for a ceiling that can only fall, `CT_REACHABILITY_ENFORCE=1` for zero — and it
# documents both in its own header. Neither variable had a SETTER anywhere in
# this repository: `grep -rn CT_REACHABILITY .github/ justfile ci/ scripts/`
# returned exactly one hit, and it was the sentence that used to be on this line
# saying somebody should do it. So the guard ran on every push, printed its
# findings, and could not fail over any of them, for any number of them. A
# report is not a gate. Its ALLOW-LIST hygiene could redden this lane; its stated
# subject could not.
#
# 1228 is this tree's exact count, re-measured on 2026-09-04 after the three
# raises below. THE NUMBER IN THIS PARAGRAPH SAID 1224 FOR HALF A DAY WHILE THE
# LINE BELOW SAID 1228, and that is the defect worth recording here rather than
# only in a commit. The ceiling went 1224 -> 1226 -> 1228 in twenty-nine
# minutes, and no raising commit's SUBJECT mentioned the ratchet:
#
#   896166e27  ci(lint-nim): engage the reachability ratchet at 1224   1224
#   6954db651  ci: settle the gate-coverage merge against the tree     1226
#   9f9bbbef5  ci: clone python-recorder from `dev`, like the other 12 1228
#
# Each raise moved the `env` on the next line and left every sentence about it
# behind — this one, the step LABEL one line down, and the header of
# `frontend-reachability.sh`. A guard whose documented threshold and actual
# threshold differ by four is a guard a reader cannot check. The three are now
# asserted to agree by `assert_reachability_prose_agrees` below, so the next
# raise cannot land without touching all three.
#
# WHAT THIS BUYS, PRECISELY: the count can go down and can never go up. A new
# unreached export fails this lane by pushing the total to 1229. It does NOT ask
# anyone to clear the backlog, and deliberately so — a guard that reddens CI over
# 1228 pre-existing findings on day one is a guard that gets switched off on day
# one, which is the argument in the script's own header and is still right.
#
# IT HAS ALREADY BITTEN ONCE, and the bite was correct. `layout.mountComponent-
# Container` carried a `*` no other module used; b59186fa0 added a test that
# mentions the name, which moved it from the uncounted "only its own module
# reaches it" bucket into the counted "tested, and no product module reaches it"
# one and took the tree to 1229. The fix was to drop the `*` — the export nobody
# outside could use — and not to raise this number a fourth time.
#
# WHEN YOU DELETE OR WIRE A SYMBOL, LOWER THIS NUMBER — AND SINCE 2026-09-04
# THE GUARD MAKES YOU. That paragraph used to end "Nothing forces that yet:
# unlike the shell-gate inventory next door, `--max` is a `>` and not an `=`, so
# slack accumulates silently under it", and it was describing live slack rather
# than a hypothetical: the backlog had been brought down to 1223 by deleting
# dead entry points while this line still said 1228, so FIVE new unreached
# exports could have landed without reddening anything.
#
# `--max` was an equality from 2026-09-04 to 2026-09-12: fewer findings than the
# number failed as "lower it to what you measured", the same rule and very
# nearly the same sentence the shell-gate inventory uses for its own ceiling.
#
# IT IS A CEILING AGAIN SINCE 2026-09-12, AND THE EQUALITY IS WHAT MEASURED
# ITSELF OUT. `f274fa68` and `ab7ce4c1` (2026-09-05) carry 1225 findings against
# a ceiling of 1226 and BOTH EXIT 1 — CI was red for five hours because the tree
# had got BETTER, and went green only when an unrelated commit put the count
# back up to exactly 1226. A gate whose failure asks a developer to undo an
# improvement, or to go and edit a number in another file, is the
# guard-that-gets-switched-off this whole block is about. The slack side still
# REPORTS, loudly and with the value to lower the ceiling to; it no longer sets
# the exit code. `ci/test/reachability-ratchet-test.sh` arm 2 asserts exactly
# that, and carries the measurement.
#
# The protection was never the value; it is that the value cannot move without a
# reviewed line in a diff AND the three sentences that describe it moving too.
# A ceiling held below the tree does not make the guard stricter — it makes it
# permanently red, and a lane that is always red is a lane nobody reads.
#
#   1223  measured after the equality landed and the dead entry points went
#   1226  `viewmodel/platform/web_deployment.nim` gained three exports
#   1225  SB-1's status-bar certificate indicator, LOWERED not raised
#
# THE 1225 LOWER, AND WHY IT IS A LOWER AT ALL. SB-1 added ~40 exported
# declarations under `src/frontend` (the certificate indicator's ViewModel, its
# fact source, and the projection onto the status bar's record) and every one of
# them is reached, so none of them is a finding. The count went DOWN by one for
# a reason worth writing here, because it is a property of this guard rather
# than of that milestone: THE SCAN IS BY NAME, so a symbol added anywhere in
# `src/frontend` marks every unreached export of the same name as reached.
#
# `viewmodel/identity/token.nim:254 issuedAt` — an accessor on `IdentityClaims`
# that no product module reaches — is now masked, because the indicator's
# disclosure reads `cert.issuedAt` off a test certificate. Those are unrelated
# symbols in unrelated modules. The masking is not fixable from the milestone's
# side either: `issued_at` is the certificate standard's own field name and the
# disclosure is required to show it.
#
# A SECOND MASKING WAS FOUND THE SAME WAY AND WAS FIXED. `token.nim:234`
# exports its own `SignatureVerifier`, and SB-1's verifier seam was first
# called the same thing, which masked it and would have taken this to 1224.
# The seam is now `CertificateSignatureVerifier`, so token.nim's export is
# counted again. Two unrelated types of one name in one import graph was worth
# separating on its own terms; that it also un-masked a finding is how it was
# noticed.
#
# THE LESSON FOR THE NEXT READER: a DROP in this number is not automatically
# progress. Check whether a name went away or a name merely arrived somewhere
# else.
#
# THE 1226 RAISE, ARGUED RATHER THAN ASSUMED. The three are `bundledAssetPaths`
# and `isBundledAssetPath` (which the guard counts twice — a forward
# declaration and its definition). They are NOT dead: `web_deployment.nim`
# itself calls all three, at :367, :706 and :895, and dropping their `*` was
# tried and compiles cleanly, which proves no OTHER product module needs them.
# The export exists so `test_platform_web.nim` can assert that two declarations
# of the same four bundled assets cannot drift apart. Removing it would force
# the list to be duplicated in the test — a third copy, and a third thing to
# drift, defeating the exact check that needs the export.
#
# The allow-list was considered and refused: it names this shape under WHEN AN
# ENTRY IS WRONG, and it is right to.
#
# AND THE FINDING UNDERNEATH, WHICH WAS BIGGER THAN THE RAISE — DONE 2026-09-12.
# This paragraph used to end "Measured and recorded so the next person has the
# number; deliberately not acted on." It has now been acted on.
#
# Bucket A prints as "tested, no product module reaches it", and the sentence
# was FALSE for a large part of it: the declaring module did reach them.
# `frontend-reachability-guard.py` tested `key in tested` BEFORE `elif readers`,
# so any symbol its own module used was relabelled out of bucket C ("only its
# own module reaches it", deliberately not counted) the moment a test mentioned
# its name — the same promotion this file already records for
# `layout.mountComponentContainer`. The two are different defects with different
# repairs (wire-or-delete vs drop the `*`), so counting the second as the first
# inflated the enforced number AND printed the wrong triage advice beside most
# of its rows.
#
# The branches are swapped. Measured on this tree, before and after, with
# nothing else changed:
#
#             findings   [A]    [B]    [C]
#   before      1800     1167    633   1922
#   after       1078      445    633   2644
#
# 722 findings moved, not 355: the number in this paragraph was measured when
# the total was 1226, and the shape it names is one this repository GENERATES by
# design — a ViewModel built and tested before any front-end wires it. Bucket B
# is unchanged at 633, which is the check that the swap moved only the rows it
# was supposed to.
#
# THE CEILING WAS NOT LOWERED TO MATCH, and that is deliberate rather than an
# oversight: at 1078 against 1225 this step now PASSES with 147 slots of
# reported slack. Re-fitting the number is the ratchet-policy pass's call — see
# THE RATCHET POLICY, DECIDED in `ci/test/frontend-reachability-guard.py`'s
# header, which records (c) "no new findings in files this change touched" as
# the adopted repair and says why it is not implemented in the same diff.

# THE PROSE GUARD. Three sentences name this threshold and all three drifted off
# it; the cheapest permanent fix is to make a raise that does not touch them
# fail. Pure grep over two checked-in files, no toolchain, milliseconds.
assert_reachability_prose_agrees() {
	local setter="${CT_PROSE_SETTER_FILE:-ci/lint/nim.sh}"
	local header="${CT_PROSE_HEADER_FILE:-ci/test/frontend-reachability.sh}"
	local max label hdr hdr_set hdr_fail hdr_pass rc=0

	# THE THRESHOLD ITSELF, read from the only line that decides anything.
	max="$(grep -oE 'CT_REACHABILITY_MAX=[0-9]+' "${setter}" | grep -oE '[0-9]+' | head -1)"
	if [ -z "${max}" ]; then
		echo "  [FAILED] no 'CT_REACHABILITY_MAX=<n>' setter in ${setter}." >&2
		echo "           This guard asserts prose against that line; with no line to" >&2
		echo "           read it would pass over anything, so it fails instead." >&2
		return 1
	fi

	# (1) THE STEP LABEL, which is the sentence a reader of the CI log sees.
	label="$(grep -oE 'frontend reachability: exported symbols nothing reaches \(ratchet at [0-9]+' \
		"${setter}" | grep -oE '[0-9]+$' | head -1)"
	if [ "${label}" != "${max}" ]; then
		echo "  [FAILED] ${setter}: the step label says 'ratchet at ${label:-<none>}'," >&2
		echo "           the setter says CT_REACHABILITY_MAX=${max}." >&2
		rc=1
	fi

	# (2) AND (3) THE SCRIPT'S OWN HEADER: it quotes the invocation and then
	# states both sides of the boundary. Comment markers are stripped and the
	# block is joined onto one line first, so re-wrapping the paragraph cannot
	# hide a stale number from this check.
	#
	# The quoted path below is the REPO-RELATIVE one the header names, and is
	# deliberately not `${header}`: that variable is the file being READ, which
	# the contract suite points at a copy under /tmp. Interpolating it made this
	# check silently unmatchable for every arm, which is how the suite's own
	# unmutated control caught it before it landed.
	hdr="$(sed -e 's/^#[[:space:]]\{0,1\}//' "${header}" | tr '\n' ' ')"
	hdr_set="$(printf '%s' "${hdr}" |
		grep -oE 'CT_REACHABILITY_MAX=[0-9]+ bash ci/test/frontend-reachability\.sh' |
		grep -oE '[0-9]+' | head -1)"
	hdr_fail="$(printf '%s' "${hdr}" |
		grep -oE 'so +[0-9]+ +findings fail' | grep -oE '[0-9]+' | head -1)"
	hdr_pass="$(printf '%s' "${hdr}" |
		grep -oE 'and +[0-9]+ +do not\.' | grep -oE '[0-9]+' | head -1)"
	if [ "${hdr_set}" != "${max}" ] || [ "${hdr_fail}" != "$((max + 1))" ] ||
		[ "${hdr_pass}" != "${max}" ]; then
		echo "  [FAILED] ${header}'s header describes a ratchet at ${hdr_set:-<none>}," >&2
		echo "           where ${hdr_fail:-<none>} findings fail and ${hdr_pass:-<none>} pass." >&2
		echo "           The setter says ${max}, so $((max + 1)) fails and ${max} passes." >&2
		rc=1
	fi

	if [ "${rc}" -ne 0 ]; then
		echo "           RAISING THE CEILING MEANS CORRECTING THE SENTENCES THAT" >&2
		echo "           DESCRIBE IT, IN THE SAME DIFF. The ceiling moved 1224 ->" >&2
		echo "           1226 -> 1228 in twenty-nine minutes on 2026-09-04 and none" >&2
		echo "           of the three descriptions moved with it." >&2
		return 1
	fi
	echo "  label, header and setter all say ${max} (so $((max + 1)) fails, ${max} passes)"
	return 0
}
# Its contract suite runs first, for the reason the shell-gate block above
# gives: a guard over PROSE is the easiest kind to write so that it can never
# fail, and one that has not been watched fail is not evidence. The suite proved
# its worth immediately — the first draft of the function interpolated the file
# being READ into the pattern matching the quoted invocation, so it could not
# match a copy, and the unmutated control caught that before it landed.
lint_step "reachability prose guard: contract suite" \
	bash ci/test/reachability-prose-guard-test.sh

# THE THRESHOLD ITSELF, WHICH NOTHING TESTED UNTIL 2026-09-04. The suite above
# tests the SENTENCES that describe the ceiling; this one tests the ceiling. The
# gap is how `--max` stayed a `>` while the paragraph below described the slack
# that produced, in the present tense, for as long as it was true — and then, on
# 2026-09-12, how the equality that replaced it could be reverted to a ceiling
# with the arms in this suite carrying the measurement that decided it rather
# than a preference. Four synthetic unreached exports, no Nim toolchain,
# milliseconds.
lint_step "reachability ratchet: contract suite (a ceiling, and it still bites above it)" \
	bash ci/test/reachability-ratchet-test.sh

lint_step "frontend reachability: the ratchet's prose agrees with its threshold" \
	assert_reachability_prose_agrees

# THIS STEP WAS RED FROM 2026-09-05 TO 2026-09-12, AND IT PASSES NOW FOR A
# REASON THAT IS NOT "THE CEILING WAS RAISED". SAID HERE SO THAT NOBODY READS
# THE GREEN TICK AS THE BACKLOG HAVING BEEN CLEARED.
#
# The history: last green commit a9e7f12d (2026-09-05 10:13, exactly 1226);
# first red a6386614 (2026-09-05 12:40, 1253); every first-parent commit since
# was red — 32 of them counting a6386614 itself, sampled across the window and
# monotonically worse (1253, 1283, 1608, 1684, 1800). The allow-list has never
# had an entry and has never been the failing arm.
#
# What changed on 2026-09-12 is the COUNT and not the ceiling. The bucket-A
# reclassification above stopped labelling a symbol its own module reaches as
# "no product module reaches it", which took the counted total 1800 -> 1078;
# and `--max` went back to being a ceiling, so 1078 against the ceiling is a
# report rather than a failure. Nothing was wired, nothing was deleted, and no
# `*` came off: 1078 is the same tree, counted correctly.
#
# THE CEILING IS 1225 AND NOT 1226 BECAUSE ONE FINDING WAS WIRED UP ON THE
# OTHER SIDE OF THIS MERGE, while the count was being corrected on this one.
# A ratchet only ever moves down, so the tighter of the two numbers is the one
# that survives, and `ci/test/frontend-reachability.sh`'s header — which the
# prose guard above checks against this line — already says 1225.
#
# SO THE LANE NOW CARRIES 147 SLOTS OF SLACK, which is a real budget and is
# reported on every run. THE CEILING IS STILL DELIBERATELY NOT BEING MOVED FAR —
# neither up to 1800, which would convert a broken gate into a silent one, nor
# down to 1078, which is the ratchet-policy pass's call rather than this one's.
# Three repairs that would make the number mean something again were costed —
# per-directory ratchets, a checked-in baseline, and "no new findings in files
# this change touched" — in PLAT-11's milestone section of
# codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org.
# **THE DECISION IS (c)**, recorded with its reasoning in
# ci/test/frontend-reachability-guard.py's header, beside the instrument it
# changes. It is not implemented here: it is a repo-wide policy change and
# needs its own pass, with its own contract suite.
# 1225 -> 1238 on 2026-09-18, and the raise is recorded rather than quietly
# taken. PLAT-29 added `viewmodel/editor/document_version.nim` and
# `viewmodel/editor/reconcile.nim`, whose exports are reached by their suites
# and by no product module — because PLAT-29's own main residual is that NO
# REAL PRODUCER IS BEHIND THE BOUNDARY YET. The two modules contribute 19
# findings across buckets A and B and the total moved 1220 -> 1238, measured
# against `origin/dev` at `421b1dcbb` on the same host.
#
# THIS IS BUCKET A'S "wire it, delete it, or allow-list it" ANSWERED WITH
# "WIRE IT, LATER", WHICH IS THE ONE ANSWER THE ALLOW-LIST MUST NOT CARRY:
# its documented reasons are for symbols reached by something that is not a
# Nim name, and these are not that. A ratchet raise says "the backlog grew and
# here is why"; an allow-list entry would say "this is permanently fine", which
# is false. When the four producers are wired the number falls on its own and
# the ratchet follows it down.
#
# 1238 -> 1245 on 2026-09-18, PLAT-30, and the NET is smaller than the GROSS
# because the vocabulary wires things. Measured both sides on one host, against
# the same tree minus this milestone:
#
#   + 13  `viewmodel/editor/editor_state.nim` (7) and
#         `viewmodel/editor/operations.nim` (6) — the 140-declaration table and
#         the state its operations are pure over. Reached by their two suites
#         and by no product module, because both front-ends still edit through
#         `isonim_tui`'s TextArea; PLAT-31's resolver and PLAT-34's
#         differential are what put a product caller behind them.
#   -  6  `wrap.nim` (2), `selection.nim` (2), `selection_ops.nim` (1) and
#         `tui/app/edit_binding.nim` (1) — exports that had NO product reader
#         until `operations.nim` became one. PLAT-26's and PLAT-27's own
#         backlog, paid down by a consumer rather than by an allow-list.
#
# Net +7. **NOT ALLOW-LISTED**, for the reason the paragraph above gives: an
# allow-list entry claims a symbol is permanently unreachable by a Nim name,
# and these are ordinary exports waiting for a caller.
#
# 1245 -> 1258 ON 2026-09-19 (PLAT-31), AND THE GROSS WAS +16 BEFORE THREE WERE
# DELETED RATHER THAN RATCHETED PAST.
# ----------------------------------------------------------------------------
# PLAT-31 added `src/frontend/viewmodel/keymap/` — four modules, the resolver
# and three keymap models — plus two symbols on `editor_state.nim`
# (`PendingChords`'s `==` and `PendingTimeoutMsDefault`). The whole package is
# exercised by its two suites and reached by NO product module, because the
# shipped terminal binary still dispatches Edit mode through `TuiEditBindings`
# against a `TextAreaWidget`. Wiring it is PLAT-34's substrate migration, and
# the milestone is recorded `partial` for exactly that reason.
#
# THE TWO BUCKETS WERE TREATED DIFFERENTLY, WHICH IS THE POINT:
#
#   * **`nothing` — 3 findings, DELETED.** `editing_keymap.anyScope`,
#     `editing_keymap.inModes` and `kakoune_keymap.kakouneFiled` were reached by
#     nothing at all, not even a case. A public helper nobody calls is not a
#     backlog item waiting for a caller; it is coverage-shaped dead code, and
#     raising a ceiling past it would have preserved it forever. 1261 -> 1258.
#   * **`tested-only` — 13 findings, RATCHETED.** `resolve`, `trieFor`,
#     `driveKeys`, `conflictsIn`, `loadEditingKeymap`, `coverageGaps`,
#     `vimKeymap`, `kakouneKeymap`, `productKeymap` and the rest are ordinary
#     exports with a suite and no product caller yet — the same situation
#     PLAT-29's move above describes, and the same remedy.
#
# It is a CEILING, so it falls again when PLAT-34 wires the layer in.
# **NOT ALLOW-LISTED**: an allow-list entry claims a symbol is permanently
# unreachable by name, and every one of these thirteen is waiting for a caller
# that a named milestone will add.
#
# 1258 -> 1263 ON 2026-09-19 (PLAT-32). NET +5, AND THE FOUR MOVEMENTS BEHIND
# IT ARE ENUMERATED BECAUSE A NET IS NOT AN ACCOUNT.
# ----------------------------------------------------------------------------
# PLAT-32 added `src/frontend/viewmodel/editor/history.nim` — the event
# history that replaced PLAT-30's snapshot undo stack. Its two branches, its
# mapping and its four `pop*` routines ARE reached by the product: `undo`,
# `redo`, `undo-selection` and `redo-selection` are four of the 224 published
# operations and `operations.nim` calls them. What is not reached is the part
# above that: the session surface a front-end will hold, and the two depth
# queries a status line will read.
#
# THE ACCOUNT IS A DIFF OF TWO RUNS OF THIS SCRIPT — the tree at the merge
# base and the tree with PLAT-32 in it — rather than a recollection, because
# a ceiling's justification is the one number in this file nothing re-takes
# (Verification-Harness-Traps §36b). Both runs report `allow-listed: 0`.
#
#   ADDED, +7, all of them in `history.nim`:
#     * `[A]` tested-and-unreached, 5: `initSession`, `undoSelection`,
#       `redoSelection`, `undoDepth`, `redoDepth` — the `HistorySession`
#       surface and the branch-depth queries, exercised by both PLAT-32
#       suites and reached by no product module because the front-ends still
#       drive the vocabulary directly. PLAT-34 gives them a caller.
#     * `[B]` reached-by-nothing, 2: the two `==` operators, on `HistEvent`
#       and on `HistoryState`. This scanner does not see an operator reached
#       through `a == b`, and `test_editor_history_examples.nim` does exactly
#       that (`counted s.history == before`). They are in the same bucket and
#       for the same reason as `editor_state.nim`'s five surviving `==`, and
#       deleting them would delete a structural equality two suites use.
#
#   REMOVED, -2, NEITHER OF THEM A DELETION — both are findings that stopped
#   being findings because this milestone landed:
#     * `[A]` `change_set.sameMapping` — PLAT-25 exported it with a suite and
#       no product caller. `history.nim`'s `==` on `HistEvent` is its FIRST
#       product caller, so it left the bucket by being used.
#     * `[B]` one `==` on `editor_state.nim` — it went with the snapshot
#       stack, whose four fields are gone.
#
# NOTHING WAS DELETED TO MAKE THIS NUMBER, and nothing needed to be: the
# gross is +7 and every one of the seven is either a named milestone's
# backlog or an operator this scanner structurally cannot see.
#
# It is a CEILING, so it falls again when PLAT-34 wires the editing core into
# the two front-ends. **NOT ALLOW-LISTED**: an allow-list entry claims a symbol
# is permanently unreachable by name, and all five `[A]` findings are waiting
# for a caller a named milestone will add.
# ----------------------------------------------------------------------------
# 1263 -> 1276 ON 2026-09-20 (PLAT-33). NET +13, GROSS +15 AND -2, AND TWO
# EXPORTS WERE DELETED RATHER THAN CARRIED.
# ----------------------------------------------------------------------------
# PLAT-33 added `editor/collab_text.nim` (§12.2's rebase-against-an-authority
# algorithm) and `collab/text_ops.nim` (its bridge to the ViewOp stream). The
# reducer's text arms, `applyRemoteChange`, `refusedBy` and
# `mapPositionTables` are all reached by the product; what is not reached is
# the surface a FRONT-END will hold, which is the same shape PLAT-32 recorded
# one milestone ago and which PLAT-34 gives a caller.
#
# THE ACCOUNT IS A DIFF OF TWO RUNS OF THIS SCRIPT — a `git worktree` at the
# merge base against the tree with PLAT-33 in it — rather than a recollection
# (Verification-Harness-Traps §36b). Both runs report `allow-listed: 0`.
#
# *A note on HOW it was diffed, because the first attempt was wrong by one.* A
# set difference keyed on `(file, symbol)` reported +14; the per-file COUNTS
# reported +15. The missing one is an `==` operator, and `transaction.nim` now
# has three of them: **a set keyed on a NAME cannot see a change in the
# MULTIPLICITY of an overloaded one.** The per-file counts are the account.
#
#   ADDED, +15:
#     * `editor/collab_text.nim`, 5: `initPeerSession`, `recordLocal`,
#       `receiveInto`, `acceptConcurrent`, `divergenceMessage`. The peer
#       surface a front-end will drive, plus the offline message a front-end
#       will show. `acceptConcurrent` is the one worth naming twice: it
#       carries the authority's stated tie-break, it is what `LAW-X3` is
#       about, and nothing in the product batches submissions yet — recorded
#       as a residual in PLAT-33's status rather than left to be found here.
#     * `collab/text_ops.nim`, 4: `submitTextUpdateOp`, `setTextSelectionOp`,
#       `mappedAnchors`, `canEditSharedText` — the envelope constructors a
#       peer calls, the remote-caret reader a view renders, and the predicate
#       a front-end greys an editor out with.
#     * `collab/reducer.nim`, 5: `MergeFamily`, `MergeFamilyIds`,
#       `PublishedMergeFamilyCount`, `mergeFamilyOf`, `committedVersion`. The
#       first four exist to BE COMPARED against `Editor-ViewModel.md` §12.1a's
#       published table — an oracle's implementation side has a suite for a
#       caller by construction, and wiring it to a product module would be
#       inventing a reader.
#     * `editor/transaction.nim`, 1: a third `==`, on `TransactionFilter`.
#       This scanner does not see an operator reached through `seq[T]`'s own
#       `==`, and `EditorState.==` compares `a.filters == b.filters`. Same
#       bucket and same reason as the two already there.
#
#   REMOVED, -2, AND NEITHER IS A DELETION — both stopped being findings
#   because this milestone landed:
#     * `change_set.encodeChangeSet` and `decodeChangeSet`. PLAT-25 wrote them
#       under the comment *"because PLAT-33 puts change sets on a wire"* and
#       they have sat tested-and-unreached ever since. PLAT-33 put them there.
#
#   DELETED, 2, RATHER THAN RATCHETED:
#     * `collab_text.logEntries` and `transaction.FilterKindCount` were
#       written, measured as reached by nothing at all, and removed. A derived
#       cardinality earns its place by being a sweep's multiplier and no sweep
#       runs over the two filter kinds; an accessor earns its place by having
#       a reader. Carrying either would have been +2 for the shape of a
#       neighbour rather than for a use.
#
# It is a CEILING, so it falls again when PLAT-34 wires the editing core into
# the two front-ends — nine of the fifteen are waiting for exactly that.
# **NOT ALLOW-LISTED**, for the reason PLAT-32 gave: an allow-list entry claims
# a symbol is permanently unreachable by name, and these are waiting for a
# caller a named milestone will add.
# ----------------------------------------------------------------------------
# 1276 -> 1274 ON 2026-09-20 (PLAT-34). **THE FIRST TIME THIS NUMBER HAS GONE
# DOWN ON A FEATURE MILESTONE**, and it went down because three milestones
# predicted in this file that it would.
# ----------------------------------------------------------------------------
# PLAT-31, PLAT-32 and PLAT-33 each closed with the same sentence — *"it is a
# CEILING, so it falls again when PLAT-34 wires the editing core into the two
# front-ends"* — and each ratcheted UP to carry a layer that had a suite and no
# product caller. PLAT-34 is the caller.
#
# THE ACCOUNT IS A DIFF OF TWO RUNS OF THIS SCRIPT — a `git worktree` at the
# merge base against the tree with PLAT-34 in it — rather than a recollection
# (Verification-Harness-Traps §36b). GROSS +8 and -10.
#
#   -10, ALL OF THEM PREDICTED, AND ALL OF THEM BY THE SAME ROUTE:
#       `editor_state.initEditorState` and `editor_state.primaryHead`, reached
#       through `editing_core`; `vimKeymap`, `kakouneKeymap` and
#       `productKeymap`, reached through `editing_core.keymapOf`;
#       `EditingScope`, built by `tui/app/edit_binding.editingScope`;
#       `collab_text.initPeerSession`, `receiveInto` and `recordLocal`,
#       reached by `collab/projection`'s editor arm — which is PLAT-33's
#       second residual closing.
#
#   +8: the editing core's own surface (`applyKey`, `applyNamed`,
#       `folded=` on both the core and the binding) and the editor
#       projection's (`newEditorProjection`, `installEditorProjection`,
#       `commitLocalChange`, `appliedVersion`).
#
# FOUR EXPORTS WERE DELETED RATHER THAN CARRIED, and the reason is PLAT-31's
# rule quoted back: *"a public helper nobody calls is not a backlog item
# waiting for a caller; it is coverage-shaped dead code, and a raised ceiling
# would have preserved it indefinitely."* They were `editing_core.applyKeys`
# (a fold of `applyKey` nothing folded), `editing_core.caretDisplayColumn` (a
# real distinction, recorded in `caretColumn`'s docstring instead),
# `editing_core.editingScopeOf` (a second spelling of the scope the front-end
# builds — §30 in eight lines) and `projection.sendableSubmission`. Without
# the deletions the net would have been +2 and the ceiling would have risen
# for four symbols nothing reaches.
#
# WHAT IS STILL TESTED-AND-UNREACHED, NAMED RATHER THAN ALLOW-LISTED:
# `installEditorProjection` and `commitLocalChange`. The projection is
# graded — `tests/unit/test_collab_editor_projection.nim` drives it against
# the real authority and the real reducer — and no shipped route INSTALLS one,
# because installing it is a session-layer decision the collaboration campaign
# owns. It is the same shape PLAT-33 recorded for `acceptConcurrent` and it is
# recorded the same way. **NOT ALLOW-LISTED**: an allow-list entry claims a
# symbol is permanently unreachable by name, and this is waiting for a caller.
# ----------------------------------------------------------------------------
# 1274 -> 1295 ON 2026-09-23 (PLAT-35 .. PLAT-44, TAKEN AFTER THE FACT). Those
# milestones landed without moving this number, so the step was RED on `dev`
# from their first commit and nobody's evidence table could have quoted it as
# passing. This entry is the account they owed, and a clean-up besides.
# ----------------------------------------------------------------------------
# THE ACCOUNT IS A DIFF OF TWO RUNS OF THIS SCRIPT — a `git worktree` at
# 6852a7791 (where 1274 was set) against this tree — per §36b. GROSS +38 and
# -8 on `dev`, and 9 of the +38 removed here before the ceiling was moved.
#
#   -8, reached since 1274: `layout_model.restoreLayout`,
#       `decoration.decorationSet`, `row_projection.decorationsForRow`,
#       `RowProjection`, `headless_session.continueForward`,
#       `requestAndLoadCalltrace` (PLAT-40's own headline defect, fixed),
#       `pane_views.PaneNativePanes` and `PaneVocabularyPanes`.
#
#   DELETED OR UN-EXPORTED, 9, RATHER THAN RATCHETED — each measured as reached
#   by NOTHING, PLAT-31's rule applied:
#     * deleted: `renderer.langs` (a wrapper over `lang.langPickerOptions` with
#       no caller), `layout_store.StateHomeEnvVar` and
#       `tui_session.MaxEventsForBounds` (aliases nothing read; the latter's
#       CTUI-8 note moved onto `native_host.RecordingEventWindow`, the constant
#       it aliased), `headless_session.breakpointLinesIn` and
#       `gpui_layout_answers.answerSetToJson` (the GPUI arm computes its
#       answers live and never serialises them);
#     * un-exported: `keymap_selection.KeymapSourceCommand` (a default
#       argument, read in its own module) and `vim_import`'s four published
#       counts, which PLAT-36's harness reads by regex (`\*?` already admits
#       the unexported spelling) and no module imports.
#     Deleting `langs` moved `langPickerOptions` into the tested-only bucket:
#     its one product caller was the wrapper nothing called.
#
#   +29 CARRIED, NAMED RATHER THAN ALLOW-LISTED:
#     * tested, no product caller (25): `chrome.contrastRatio`,
#       `MinimumContrastRatio` (PLAT-37); `layout_store.LayoutDirEnvVar`;
#       `selection_ops.initOpCtx`, `wrap.initDisplayCtx` (PLAT-34's contexts);
#       ten `vim_import` report accessors and `MapArgumentDecisions`
#       (PLAT-36/43's import report, which no front-end displays yet);
#       `flow_vm.FlowWireNotTakenOrdinal` (PLAT-42); `gpui_binding`'s
#       `DisabledFactName`, `focusNode`, `focusedNodeId` (PLAT-44);
#       `gpui_layout_answers`' `gpuiLayoutAnswers`, `answerSetFromJson`,
#       `unknownQuestionKeys` (PLAT-35's comparison, run by its suite);
#       `pane_views.PaneAccountedFor` (PLAT-41); `lang.langPickerOptions`.
#     * reached by no other module, but not dead (4): `chrome.ChromeRole` and
#       `native_host.PaneLoad` are the types of exported routines' parameters
#       and results, and `vim_import.ArgumentDecision` is
#       `MapArgumentDecisions`' element type; `registerPointListComponent` is
#       an `{.exportc.}` entry point in the same pattern as
#       `registerCalltraceComponent`, called from JavaScript.
#
# It is a CEILING, so it falls when the import report gets a view and PLAT-44's
# focus arm gets a front-end caller — fourteen of the twenty-nine are those two.
#
# 1295 -> 1296 ON 2026-09-25, REBASING THE ABOVE ONTO dev: gross +5 and -4 from
# commits that landed on 2026-09-24 in the meantime, measured the same way.
#   -4, reached now: `document_version.initVersionedDocument`, `lengthAt`,
#       `reconcile.producerChange`, `producerResult` (PLAT-29's producers,
#       wired, as its entry predicted).
#   +5, none of them dead: `file_conflicts.RecordLaunchPlan` (the result type
#       of the exported `planRecordLaunch`); `traces.onNewFile` (an IPC
#       handler); `welcome_screen_vm.unreachableStartOptions` and
#       `reasonlessDisabledStartOptions` (asserted by
#       `welcome_screen_vm_test.nim`); `flow_vm.FlowWireTakenOrdinal` (the
#       sibling of the `FlowWireNotTakenOrdinal` carried above).
lint_step "frontend reachability: exported symbols nothing reaches (ratchet at 1296 + allow-list hygiene)" \
	env CT_REACHABILITY_MAX=1296 bash ci/test/frontend-reachability.sh

# ONE CHAIN, ENFORCED, BECAUSE THE RATCHET ABOVE CANNOT ENFORCE IT.
#
# The ratchet is the right instrument for a 1228-finding backlog and the wrong
# one for a specific feature: a chain that breaks INSIDE the ceiling reddens
# nothing, and the Show Generated Code chain was inside it — `produceAnchors`
# and `readArtefactJson` were reported as unreached, in report mode, exiting 0,
# among twelve hundred other lines.
#
# So the operation a developer invokes to see what their code compiled to gets
# its own check, at --enforce, with no ceiling and no allow-list. It is proved
# able to fail: against `origin/dev` at a861f5b7b it exits 1 on 22 of its 24
# links, and its header records that measurement -- including WHICH four were
# tested-but-unreached -- rather than a claim about it. The number lives in the
# guard's own header too, which is the only place worth updating it; this
# sentence is a pointer and will go stale if it is treated as the record.
lint_step "Show Generated Code: the operation's chain is reached from production" \
	python3 ci/test/generated-code-operation-guard.py

# The Embed SDK's boundary, in both directions: a consumer may reach the SDK
# only through `codetracer_embed`, and the SDK's own import graph carries no
# rendering and no chain concept. CodeTracer-Embed-SDK.md §3.2 says in as many
# words that "enforcement is an import lint, not discipline", and
# BlockTracer/Client-SDK.md §1.1 asks for the mirror of the same rule.
#
# Same order as above and for the same reason: the contract suite runs before
# the guard it covers, because a guard nobody has watched fail is not evidence.
lint_step "SDK facade boundary: contract suite" \
	bash ci/test/sdk-facade-boundary-test.sh

lint_step "SDK facade boundary: no reach past the facade, no chain concept inside it" \
	bash ci/test/sdk-facade-boundary.sh

# PLAT-7's verification gate, and it sits HERE rather than anywhere else because
# it is the other half of the guard above: the facade that
# `sdk-facade-boundary.sh` holds a consumer to is the same facade that
# re-exports `isonim/core/[signals, computation, owner]` for §4.1's Mode N
# consumers — which is how a PLUGIN, a declared consumer of that same facade,
# ended up with `createEffect` in scope and could run 160 ms on every write
# without the host budgeting, attributing or suspending it.
# Extensibility-Model.md §5.3 requires that budget to be "enforced rather than
# documented"; this is the enforcement.
#
# Same order as above and for the same reason: the contract suite runs before
# the guard it covers, because a guard nobody has watched fail is not evidence.
lint_step "Plugin reactive boundary: contract suite" \
	bash ci/test/plugin-reactive-boundary-test.sh

lint_step "Plugin reactive boundary: a plugin cannot reach a raw reactive primitive" \
	bash ci/test/plugin-reactive-boundary.sh

# PLAT-29's verification gate: THE EDITOR MODEL'S TRANSITIVE IMPORT CLOSURE
# CONTAINS NO ASYNC, NO I/O, NO PROCESS, NO SOCKET AND NO CLOCK.
#
# It sits HERE because it is the third consumer of the same instrument: the
# import extractor `ci/lib/nim-imports.sh` that the two guards above call. Every
# route past a naive import scan those two paid for — the newline-continued
# import, the block comment, the call site rather than the rendering, the
# trailing carriage return — is closed for this one too, and a gate that derived
# its own extractor would have re-opened all of them.
#
# Editor-ViewModel.md §11: *"The model never waits. It has no Future, no
# callback, no clock."* That was a source scan over the editor modules' own text
# until PLAT-29, and a scan over a module's own text cannot see an `await`
# reached through a transitive import.
#
# Its contract suite is a NIM suite rather than a shell one —
# `test_editor_async_closure.nim`, which plants each of the seven routes against
# a synthetic tree and requires this gate to redden — so it runs in the
# `vm-unit` lane rather than here. That is the one place this step's shape
# differs from the two above it, and the reason is that the planted trees need a
# builder rather than a fixture directory.
lint_step "Editor import closure: no async, no I/O, no clock in the editor model" \
	bash ci/test/editor-import-closure.sh

# PLAT-2's verification gate: no surface formats a value by a path that
# bypasses the one presenter, and the presenter is pure.
# CodeTracer-Platform.milestones.org asks for it "in the shape
# sdk-facade-boundary.sh already uses", which is why it sits here, in that
# order: the contract suite runs before the guard it covers, because a guard
# nobody has watched fail is not evidence.
lint_step "Value presentation boundary: contract suite" \
	bash ci/test/value-presentation-boundary-test.sh

lint_step "Value presentation boundary: one pipeline, pure, with no surface bypassing it" \
	bash ci/test/value-presentation-boundary.sh

# PLAT-6's residue: the TUI's decide/perform split was a FACT and not an
# ENFORCED one. `app/layout/persistence.nim`'s header says it imports no
# `std/os` and nothing checked it — `test_tui_facade_boundary.nim` forbids
# `std/osproc`, `std/posix` and `host/` imports under `app/`, and `std/os` is
# legal there. Same shape as the two guards above, and in the same place for the
# same reason: the answer arrives in the lint stage rather than after a build.
lint_step "TUI layer split: the decision half of each decide/perform pair does no I/O" \
	bash ci/test/tui-layer-split-boundary.sh

# PLAT-39's LAW-R4 and PLAT-40's production-caller gate. Both are source scans
# with their own positive and negative controls, need no build and no
# toolchain beyond coreutils, grep and sed, and were wired into no lane — which
# `shell-gate-coverage.sh` reported by name. They sit with the other boundary
# scans for the reason those do: the answer arrives in the lint stage rather
# than after a build.
lint_step "PLAT-39 oracle independence: the vision producer imports nothing from the application" \
	bash ci/test/plat39-oracle-independence.sh

lint_step "PLAT-40 production callers: every pane producer has a caller a user can reach" \
	bash ci/test/plat40-production-callers.sh

# `VALID_DAP_COMMANDS` against the tables it mirrors, in BOTH directions. The
# allow-list is hand-written but no longer hand-CHECKED: the guard derives the
# engine's dispatch from `src/db-backend/src/dap_server.rs` and the event
# mapping from `src/frontend/dap.nim`. It had drifted in the direction nothing
# looked at — ten engine-implemented commands missing, two of them already in
# `EVENT_KIND_TO_DAP_MAPPING`.
#
# Contract suite first, same order and same reason as the two guards above. It
# matters more here than usual: every check the guard makes is a SUBSET test,
# and a subset test against an empty set passes, so a broken extraction regex
# would turn this guard green rather than red.
lint_step "DAP command sync: contract suite" \
	bash ci/test/dap-command-sync-test.sh

lint_step "DAP command sync: the allow-list names everything the engine dispatches" \
	python3 ci/test/dap-command-sync.py

# Canary for the chronicles/distinct-type breakage that takes every editor in
# the project down. Currently QUARANTINED against an upstream nimsuggest crash;
# ci/test/nimsuggest-check.sh carries the diagnosis, tells a toolchain defect
# apart from a real regression in src/lsp.nim, and re-arms itself automatically.
lint_step "nimsuggest starts on src/lsp.nim" \
	bash ci/test/nimsuggest-check.sh

# TODO: nim check

lint_summary
