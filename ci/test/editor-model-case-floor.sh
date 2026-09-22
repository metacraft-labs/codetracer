#!/usr/bin/env bash
#
# editor-model-case-floor.sh — the Editor Model Conformance campaign's counted
# targets, gated. One milestone per invocation.
#
#   bash ci/test/editor-model-case-floor.sh PLAT-24
#   bash ci/test/editor-model-case-floor.sh PLAT-25
#   bash ci/test/editor-model-case-floor.sh PLAT-26
#   bash ci/test/editor-model-case-floor.sh PLAT-27
#   bash ci/test/editor-model-case-floor.sh PLAT-28
#   bash ci/test/editor-model-case-floor.sh PLAT-29
#   bash ci/test/editor-model-case-floor.sh PLAT-30
#   bash ci/test/editor-model-case-floor.sh PLAT-31
#   bash ci/test/editor-model-case-floor.sh PLAT-32
#   bash ci/test/editor-model-case-floor.sh PLAT-33
#   bash ci/test/editor-model-case-floor.sh PLAT-34
#   bash ci/test/editor-model-case-floor.sh PLAT-35
#   bash ci/test/editor-model-case-floor.sh PLAT-36
#   bash ci/test/editor-model-case-floor.sh PLAT-37
#   bash ci/test/editor-model-case-floor.sh PLAT-38
#
# THIS FILE WAS `plat24-case-floor.sh` AND IT GREW AN ARGUMENT
# ===========================================================
# It was renamed rather than copied, deliberately. PLAT-25 needs the same
# gate, and a second script would be a second copy of a parser, a second
# `FLOOR:` grammar and a second place for the two to drift — which is
# Verification-Harness-Traps §30 arriving through a file copy instead of
# through a function. `just plat24-case-floor` still works and still gates
# PLAT-24 and nothing else; what changed is that the milestone is a parameter
# and the suite list is a table.
#
# Editor-Model-Conformance-Suite.md §10.1 puts TWO numbers in TWO units in TWO
# homes doing TWO different jobs:
#
#   * the exact ASSERTION count lives in the suite as `const ExpectedAssertions`
#     and is asserted by the suite against its own runtime tally. Every suite
#     named below declares it, prints `CHECKS:` and has a case comparing the
#     two.
#   * the CASE FLOOR lives in the milestone, on a line reading `FLOOR: <n>
#     cases`, and is asserted against the `[OK]` count of the milestone's
#     suites. That half is what this script is.
#
# WHY THIS IS A SCRIPT AND NOT A LINE IN `run-nim-test-lane.sh`
# ============================================================
# §10.1 states plainly that "nothing in the lane reads a `FLOOR:` line out of a
# milestone file today, so that half is a deliverable of the milestones below
# and not a mechanism to be assumed." A GENERIC floor mechanism — every lane
# discovering which milestone owns each of its files — is a campaign-wide
# change that would alter every lane's pass condition at once, and neither of
# these milestones is where that should land. This gates the milestones named
# in its own table and nothing else.
#
# THE RULES IT KEEPS
# ==================
#  * A MISSING SPEC CHECKOUT FAILS BY NAME. It does not skip and it is not
#    counted as a pass — the Silent-Self-Pass audit is why.
#  * THE PARSE IS ASSERTED. Exactly one `FLOOR:` line must be found inside the
#    milestone's section, and the section itself must be found; a parser that
#    silently read the wrong milestone's floor, or none, would otherwise
#    satisfy everything written over it.
#  * IT IS TWO-SIDED ABOUT ITS OWN INPUT. Every suite named below must
#    contribute at least one `[OK]`, so a suite that failed to compile cannot
#    be absorbed into a total the other one carries.
#  * THE UNIT IS `[OK]` BLOCKS, which is unittest's per-test-block line and the
#    same unit §1.1 measured CodeMirror's 633 in. It is deliberately NOT the
#    assertion count: a file of empty cases scores `OK (n tests)`, and that is
#    what the OTHER number is for.
#  * FOR PLAT-25 AND PLAT-26 IT ALSO RUNS THE LAW-TABLE ORACLE (§7.1). The ten
#    `LAW-A*` ids are published in §3.1 of the conformance suite and the six
#    `LAW-S*` ids in §3.2; each suite file carries a transcription. The two are
#    compared here, in BOTH directions, with the cardinality asserted — because
#    two set differences are both satisfied by two empty sets — and a killer
#    cell that is empty or an em dash fails, because "an arm with no stated
#    killer is not admitted".
#
#    THE ORACLE IS PARAMETERISED RATHER THAN COPIED. PLAT-26 needed the same
#    two-way count over a different table, a different id prefix and a
#    different cardinality; a second block would have been a second parser and
#    a second place for the grammar to drift, which is the file-copy form of
#    Verification-Harness-Traps §30. Four variables carry the difference.
#
#    PLAT-27 ADDED A FIFTH: `LAW_DEFERRED`. §3.3 publishes SEVEN `LAW-C` rows
#    and says of the seventh that it *"lands in PLAT-28, which owns widgets,
#    and is named here because it is a coordinate claim"*. A milestone that
#    implements six of seven and a milestone that silently dropped one look
#    identical to a two-way count, so the deferral is DECLARED here and
#    CHECKED in both directions: every deferred id must be published in the
#    table AND absent from the suite, and the two-way count then runs over
#    `published − deferred` against the suite with the cardinality asserted.
#    The alternative — writing `LAW_COUNT=6` and letting the seventh row fall
#    out of the comparison — is the shape where a published law stops being
#    published and nothing says so.
#
#    PLAT-28 EXPIRED THAT DEFERRAL AND THE MECHANISM THAT MADE THAT POSSIBLE IS
#    THE SIXTH VARIABLE: `LAW_SUITES` is a LIST. `LAW-C7` belongs to §3.3's
#    table and is implemented by PLAT-28's suite, not PLAT-27's, so PLAT-27's
#    two-way count now reads the union of the ids declared by BOTH suites and
#    `LAW_DEFERRED` for PLAT-27 is empty. A one-suite implementation side could
#    only have expressed this as a permanent deferral, which is the state that
#    cannot be told from "never". The deferral mechanism stays — it is how the
#    NEXT published-but-unimplemented law is declared — and the count of
#    declared deferrals is printed on every run, including when it is zero, so
#    "no deferrals" is a statement rather than a silence.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${root}"

MILESTONE_ID="${1:-PLAT-24}"

SPEC_REL="../codetracer-specs/Planned-Work/CodeTracer-Platform.milestones.org"
LAWS_REL="../codetracer-specs/Testing/Editor-Model-Conformance-Suite.md"

case "${MILESTONE_ID}" in
PLAT-24)
	MILESTONE="** PLAT-24: The text store decision"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_text_store.nim
		src/frontend/viewmodel/tests/unit/test_editor_unicode_corpus.nim
	)
	LAW_SUITES=()
	;;
PLAT-25)
	MILESTONE="** PLAT-25: The edit algebra"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_change_algebra.nim
		src/frontend/viewmodel/tests/unit/test_editor_change_examples.nim
	)
	LAW_SUITES=(src/frontend/viewmodel/tests/unit/test_editor_change_algebra.nim)
	LAW_PREFIX="LAW-A"
	LAW_SECTION="3.1"
	LAW_COUNT=10
	;;
PLAT-26)
	MILESTONE="** PLAT-26: Selections as the primitive"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_selection_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_selection_examples.nim
	)
	LAW_SUITES=(src/frontend/viewmodel/tests/unit/test_editor_selection_laws.nim)
	LAW_PREFIX="LAW-S"
	LAW_SECTION="3.2"
	LAW_COUNT=6
	;;
PLAT-27)
	MILESTONE="** PLAT-27: The coordinate model under soft wrap"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_wrap_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_wrap_examples.nim
	)
	# BOTH SUITES. §3.3 publishes seven `LAW-C` rows and the seventh —
	# `LAW-C7`, the reflow — is implemented by PLAT-28, which owns widgets.
	# PLAT-27 declared it DEFERRED; PLAT-28 implemented it and the deferral is
	# expired here rather than left standing, which is why the implementation
	# side is a list.
	LAW_SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_wrap_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_decoration_laws.nim
	)
	LAW_PREFIX="LAW-C"
	LAW_SECTION="3.3"
	LAW_COUNT=7
	;;
PLAT-28)
	MILESTONE="** PLAT-28: Ranges, anchors, and the inlay that reflows"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_decoration_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_decoration_examples.nim
	)
	LAW_SUITES=(src/frontend/viewmodel/tests/unit/test_editor_decoration_laws.nim)
	LAW_PREFIX="LAW-D"
	LAW_SECTION="3.4"
	LAW_COUNT=5
	;;
PLAT-29)
	MILESTONE="** PLAT-29: The asynchronous boundary and the document version"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_async_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_async_examples.nim
		src/frontend/viewmodel/tests/unit/test_editor_async_closure.nim
	)
	# THREE SUITES, AND THE THIRD IS NATIVE-ONLY. `test_editor_async_closure`
	# spawns the import-closure gate through `std/osproc`, so it is subtracted
	# from `vm-unit-js` and `vm-unit-wasm` by name. It is summed here because
	# the FLOOR is a claim about the milestone's cases, not about one backend's
	# lane — and because seven of its nine cases are the seven routes past a
	# text scan, which is a third of the floor's derivation.
	LAW_SUITES=(src/frontend/viewmodel/tests/unit/test_editor_async_laws.nim)
	LAW_PREFIX="LAW-V"
	LAW_SECTION="3.5"
	LAW_COUNT=5
	;;
PLAT-30)
	MILESTONE="** PLAT-30: The named operation vocabulary"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_vocabulary_oracle.nim
		src/frontend/viewmodel/tests/unit/test_editor_vocabulary_laws.nim
	)
	# NO `LAW_SUITES`, AND THAT IS NOT AN OMISSION. PLAT-30 publishes no
	# `LAW-*` row: its oracle is §2.2's own four tables, and the two-way
	# count over them is asserted INSIDE `test_editor_vocabulary_oracle.nim`
	# — ten cases, §7.1's five lines over two oracle tables — rather than by
	# this script. The reason it lives there and not here is that the parse
	# has to generate 224 names from 140 declarations by the categories' own
	# form rules, which is a program rather than an `awk` over one column.
	#
	# THE THIRD SUITE IS DELIBERATELY ABSENT FROM THIS TOTAL.
	# `src/frontend/tui/app/tests/test_edit_binding_vocabulary.nim` asserts
	# the other half of the retirement — that `applyEditKey` dispatches
	# through the table, on the real widget — and it links `isonim_tui`,
	# which needs the tree-sitter archive and `-L` flags this script does not
	# pass and should not learn. It runs in the `tui` lane, which globs its
	# directory. Its twenty cases are NOT in the floor's derivation either,
	# so the floor and this total count the same set.
	LAW_SUITES=()
	;;
PLAT-31)
	MILESTONE="** PLAT-31: The keymap layer"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_keymap_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_keymap_differential.nim
	)
	# NO `LAW_SUITES`, FOR PLAT-30's REASON AND NOT BY OVERSIGHT.
	# `Editor-Model-Conformance-Suite.md` §3 publishes `LAW-A*` … `LAW-X*` and
	# none of them is PLAT-31's: this milestone's oracle is §8's `DIFF-4` row
	# and §4.4's coverage equality, both of which are asserted INSIDE the
	# suites, as set differences in both directions with the cardinality. A
	# `LAW_PREFIX` here would make this gate parse a table that does not exist
	# and, per §4, a parser that matches nothing satisfies everything written
	# over it.
	LAW_SUITES=()
	;;
PLAT-32)
	MILESTONE="** PLAT-32: Undo in a buffer with more than one writer"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_history_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_history_examples.nim
	)
	# THE LAW-TABLE ORACLE IS BACK, after two milestones without one.
	# PLAT-30 and PLAT-31 publish no `LAW-*` row and said so here; §3.6
	# publishes six `LAW-H` rows and this milestone implements all six, so
	# the two-way count runs again — ids in both directions, the cardinality
	# asserted, and a killer cell that is empty or an em dash fails.
	LAW_SUITES=(src/frontend/viewmodel/tests/unit/test_editor_history_laws.nim)
	LAW_PREFIX="LAW-H"
	LAW_SECTION="3.6"
	LAW_COUNT=6
	;;
PLAT-33)
	MILESTONE="** PLAT-33: Collaborative text editing as ViewOps"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_collab_laws.nim
		src/frontend/viewmodel/tests/unit/test_editor_collab_examples.nim
	)
	# §3.7 publishes five `LAW-X` rows and this milestone implements all
	# five, so the two-way count runs: ids in both directions, the
	# cardinality asserted, and a killer cell that is empty or an em dash
	# fails.
	LAW_SUITES=(src/frontend/viewmodel/tests/unit/test_editor_collab_laws.nim)
	LAW_PREFIX="LAW-X"
	LAW_SECTION="3.7"
	LAW_COUNT=5
	;;
PLAT-34)
	MILESTONE="** PLAT-34: One editing core, two front-ends"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_front_end_differential.nim
		src/frontend/tui/tests/test_editor_front_end_observed.nim
	)
	# TWO SUITES, AND THE SECOND ONE NEEDS THE `tui` LANE'S LINK FLAGS.
	#
	# `DIFF-1` has two halves (PLAT-34, and §8 of the conformance suite): the
	# model states agree — cheap, and true by construction once the milestone
	# lands — and both front-ends' OBSERVED OUTPUT changes when the model
	# changes, read from a run. The first half plus the scans that keep it
	# from being vacuous is the `vm-unit` suite above, which links neither
	# renderer and runs on C, JS and wasm32. The second half paints the
	# terminal's editor into a real `StyledGrid` and renders the GPUI editor
	# into the real Rust shadow tree, so it links `isonim_tui` AND
	# `isonim_gpui` and is native-only — PLAT-29's third suite is the same
	# shape and the reason is the same: the FLOOR is a claim about the
	# milestone's cases, not about one backend's lane.
	#
	# The flags are READ FROM `ci/lib/test-lane-files.sh`, never transcribed.
	# That file already answers "what does a `tui`-lane file need to build"
	# and a second spelling here would be a second place for the tree-sitter
	# archive path and the two `-L` flags to drift (§30). `SUITE_FLAGS` is
	# indexed by the same subscript as `SUITES`.
	SUITE_FLAGS=("" "$(
		# shellcheck source=/dev/null
		. ci/lib/test-lane-files.sh >/dev/null 2>&1 &&
			test_lane_extra_flags tui
	)")
	# NO `LAW_SUITES`, for PLAT-30's and PLAT-31's reason and not by
	# oversight. §3 publishes `LAW-A` … `LAW-X` and none of them is
	# PLAT-34's; this milestone's oracle is §8's `DIFF-1` row, whose two
	# halves are asserted inside the two suites — the operation-sequence
	# corpus's cardinality and per-family counts in the first, the
	# transaction-kind enum's span and the renderer-less control in the
	# second.
	LAW_SUITES=()
	;;
PLAT-35)
	MILESTONE="** PLAT-35: Visual alignment of the GPUI front-end"
	SUITES=(
		src/frontend/gpui/tests/test_cross_renderer_visual_alignment.nim
	)
	# ONE SUITE, AND IT NEEDS THE `gpui-shell` LANE'S FLAGS.
	#
	# The flags are READ FROM `ci/lib/test-lane-files.sh`, never transcribed —
	# the same arrangement PLAT-34 established and for the same reason: that
	# file already answers "what does a `gpui-shell`-lane file need to build",
	# and a second spelling here would be a second place for it to drift (§30).
	#
	# NOT the `tui` lane's: this suite links `isonim_gpui` and not
	# `isonim_tui`, and handing it the tree-sitter archive and the two `-L`
	# flags would hide the dependency split `test_gpui_shell_split.nim`
	# asserts from the inside.
	#
	# WHY ONE SUITE RATHER THAN TWO. PLAT-34 has two because `DIFF-1`'s two
	# halves link different renderers. PLAT-35's halves are not two link
	# targets: the Electron arm is a RECORDED CAPTURE produced by a Playwright
	# lane (`just plat35-capture-electron`) and read here as JSON, so there is
	# nothing for a second Nim binary to link. The Electron half's own
	# execution is gated by that lane and by the tier-1 verdict this suite
	# reads out of the capture manifest, which is how a capture that never ran
	# fails here rather than passing quietly.
	SUITE_FLAGS=("$(
		# shellcheck source=/dev/null
		. ci/lib/test-lane-files.sh >/dev/null 2>&1 &&
			test_lane_extra_flags gpui-shell
	)")
	# NO `LAW_SUITES`, for PLAT-30's, PLAT-31's and PLAT-34's reason and not by
	# oversight. `Editor-Model-Conformance-Suite.md` §3 publishes `LAW-A` …
	# `LAW-X` and none of them is PLAT-35's. This milestone's oracle is a
	# DIFFERENT table — `Testing/Cross-Renderer-Visual-Alignment.md` §3's eight
	# layout questions — and §7.1's two-way count over it is asserted INSIDE
	# the suite, in four cases, because the parse has to apply §3.1a's
	# canonical-key grammar to a prose column rather than read an id out of a
	# backticked cell. A `LAW_PREFIX` here would make this gate parse a table
	# that does not exist, and per §4 a parser that matches nothing satisfies
	# everything written over it.
	LAW_SUITES=()
	;;
PLAT-36)
	MILESTONE="** PLAT-36: Importing a user's Vim configuration"
	SUITES=(
		src/frontend/viewmodel/tests/unit/test_editor_vim_import.nim
		src/frontend/viewmodel/tests/unit/test_editor_vim_import_differential.nim
	)
	# THIS MILESTONE PUBLISHES A FLOOR AND WAS GATED BY NEITHER FILE.
	# Verification of the PLAT-37…44 drafts found that PLAT-36 carries a
	# `FLOOR:` line, that this script had no `case` label for it, and that
	# `just editor-model-case-floors` did not call it — so the floor was a
	# number nothing read. BOTH halves are edited together, which is what the
	# recipe's own equality (milestones gated == entries in this table) exists
	# to have stopped: a milestone with an entry and no caller, or a caller
	# with no entry, fails by name.
	#
	# NO `LAW_SUITES`, for PLAT-30's, PLAT-31's, PLAT-34's and PLAT-35's
	# reason and not by oversight. `Editor-Model-Conformance-Suite.md` §3
	# publishes `LAW-A` … `LAW-X` and none of them is PLAT-36's. This
	# milestone's oracles are §6.1's twenty-two-spelling table, §6.1's five
	# map arguments and ten `set` options, and §6.3's five-member closed
	# reason set — four published lists in a DIFFERENT document
	# (`GUI/Editing-Operations-And-Keymaps.md`) — and §7.1's two-way count
	# over each is asserted INSIDE `test_editor_vim_import.nim`, which
	# `staticRead`s that document. A `LAW_PREFIX` here would make this gate
	# parse a table that does not exist, and per §4 a parser that matches
	# nothing satisfies everything written over it.
	LAW_SUITES=()
	;;
PLAT-37)
	MILESTONE="** PLAT-37: A =codetracer-gpui= window that opens"
	SUITES=(
		src/frontend/gpui/tests/test_gpui_window_frame.nim
	)
	# ONE SUITE, AND IT NEEDS THE `gpui-shell` LANE'S FLAGS — WHICH PLAT-37
	# WIDENED BY ONE PATH.
	#
	# The flags are READ FROM `ci/lib/test-lane-files.sh`, never transcribed:
	# the arrangement PLAT-34 established and PLAT-35 inherited, for the
	# reason both of them give — that file already answers "what does a
	# `gpui-shell`-lane file need to build", and a second spelling here would
	# be a second place for it to drift (§30). What changed is that the answer
	# now includes `--path:../GuiAssert/src`, because this milestone's gate
	# reads pixels and GuiAssert is where `decodeGray`, `computeSsim`,
	# `edgeChangeRatio` and `runOcr` live. Reading the flags rather than
	# copying them is what made that a ONE-LINE change instead of a two-place
	# one.
	#
	# **WHAT THIS ENTRY MAKES THIS GATE DEPEND ON, SAID BEFORE IT SURPRISES
	# ANYBODY.** PLAT-37's floor counts eighteen vision cases plus four
	# compositor configurations, so its suite is about PIXELS — and pixels
	# come from a capture that needs a headless compositor. The suite does not
	# need one: it reads `src/tests/visual/plat37-measurements.json`, a
	# recorded capture committed exactly as PLAT-35 commits its Electron
	# answers, and re-measures from `build/plat37/` only when those frames
	# happen to be on the disk. That is what lets this entry run in
	# `viewmodel-tests` beside the other thirteen. The recorded record carries
	# its own provenance and the suite prints it, because a recorded capture
	# with no date is a capture nobody can age.
	#
	# NO `LAW_SUITES`, for PLAT-30's, PLAT-31's, PLAT-34's, PLAT-35's and
	# PLAT-36's reason and not by oversight. `Editor-Model-Conformance-
	# Suite.md` §3 publishes `LAW-A` … `LAW-X` and none of them is PLAT-37's.
	# This milestone's oracle is its OWN instrument contract — the two-row
	# table in `CodeTracer-Platform.milestones.org` §"The two instruments" —
	# and `DIFF-6`, both of which are asserted INSIDE the suite, because the
	# claim is about which TIER a case is on and that is not an id in a
	# backticked cell. A `LAW_PREFIX` here would make this gate parse a table
	# that does not exist, and per §4 a parser that matches nothing satisfies
	# everything written over it.
	SUITE_FLAGS=("$(
		# shellcheck source=/dev/null
		. ci/lib/test-lane-files.sh >/dev/null 2>&1 &&
			test_lane_extra_flags gpui-shell
	)")
	LAW_SUITES=()
	;;
PLAT-38)
	MILESTONE="** PLAT-38: Key delivery and element focus"
	SUITES=(
		src/frontend/gpui/tests/test_gpui_key_delivery.nim
	)
	# ONE SUITE, AND IT NEEDS THE `gpui-shell` LANE'S FLAGS — the arrangement
	# PLAT-34 established, PLAT-35 inherited and PLAT-37 widened by one path.
	# Read, never transcribed: `ci/lib/test-lane-files.sh` already answers
	# "what does a `gpui-shell`-lane file need to build", and a second
	# spelling here would be a second place for it to drift (§30).
	#
	# **WHAT THIS ENTRY DEPENDS ON, SAID BEFORE IT SURPRISES ANYBODY.** Nine
	# of PLAT-38's forty-six cases are about a key that entered through a
	# COMPOSITOR, and a compositor is not something this gate can have. The
	# suite does not need one: it reads
	# `src/tests/visual/plat38-keystrokes.json`, a recorded capture committed
	# exactly as PLAT-35 commits its Electron answers and PLAT-37 its frame
	# measurements, and re-measures from `build/plat38/` only when that
	# manifest happens to be on the disk. The record carries its own
	# provenance and the suite PRINTS it, because a recorded capture with no
	# date is a capture nobody can age. A record that is on NEITHER path is a
	# named failure rather than a skip.
	#
	# The other thirty-seven link the real Rust shim and drive it directly —
	# the tier PLAT-19 established and PLAT-21 used. They are the reason this
	# entry cannot join the portable `vm-unit` lanes.
	#
	# NO `LAW_SUITES`, for PLAT-30's, PLAT-31's, PLAT-34's, PLAT-35's,
	# PLAT-36's and PLAT-37's reason and not by oversight.
	# `Editor-Model-Conformance-Suite.md` §3 publishes `LAW-A` … `LAW-X` and
	# none of them is PLAT-38's. This milestone's laws are published in its
	# own "Laws, corpus and generators" section — the focus partition, the
	# key identity, and the population — and each is asserted INSIDE the
	# suite, because the claim is about a COUNT taken over the element store
	# and that is not an id in a backticked cell. A `LAW_PREFIX` here would
	# make this gate parse a table that does not exist, and per §4 a parser
	# that matches nothing satisfies everything written over it.
	SUITE_FLAGS=("$(
		# shellcheck source=/dev/null
		. ci/lib/test-lane-files.sh >/dev/null 2>&1 &&
			test_lane_extra_flags gpui-shell
	)")
	LAW_SUITES=()
	;;
PLAT-39)
	MILESTONE="** PLAT-39: Screen-to-domain reconstruction"
	SUITES=(
		src/tests/visual/screen_oracle/test_screen_oracle.nim
	)
	# ONE SUITE, AND IT NEEDS ONLY GuiAssert — no compositor, no shim, no
	# renderer. That is not a convenience, it is the milestone's whole claim:
	# the oracle reads COMMITTED PNGs and shares no code path with the
	# application. If this entry ever needed the `gpui-shell` flags, the
	# independence it exists to assert would already be gone.
	#
	# **THIS ENTRY HAS A PREREQUISITE THAT IS NOT IN THE REPOSITORY, AND SAYS
	# SO RATHER THAN DISCOVERING IT IN CI.** The six frames under
	# `src/tests/visual/captures/electron/` are GITIGNORED — `.gitignore`
	# records PLAT-35's reason, that a committed baseline *"pins whichever run
	# happened to produce it"*. They exist only where `plat35-capture-electron`
	# has run, so on a fresh checkout this milestone's suite has nothing to
	# read and its first case fails BY NAME with that remedy.
	#
	# That is deliberate and it is not a skip: a prerequisite that is absent
	# must be loud. But it does mean this gate is not yet portable, and the
	# question of whether the captures should be committed is the OWNER'S —
	# PLAT-35 declined because they would be baselines, while this milestone
	# uses them as fixtures, which may not carry the same objection.
	#
	# **WHAT IT READS, AND WHY THAT IS NOT A MOCK.** The six frames were
	# captured from the REAL Electron front-end under Xvfb by
	# `plat35-capture-electron`. A frame is not a mock of a screen; it IS the
	# screen. The
	# milestone forbids SYNTHETIC frames — "a reading exercised on an image the
	# test drew is a test of the drawing" — and the only images this suite
	# draws itself are the deliberately BLANK controls for `LAW-R3`, whose
	# entire content is the absence of content.
	#
	# NO `LAW_SUITES`, for the reason PLAT-30 … PLAT-38 each record:
	# `Editor-Model-Conformance-Suite.md` §3 publishes `LAW-A` … `LAW-X` and
	# none of them is PLAT-39's. Its laws — `LAW-R1` … `LAW-R6` — are published
	# in its own milestone section and asserted inside the suite. Pointing
	# `LAW_PREFIX` at a table that does not contain them would make this gate
	# parse nothing, and a parser that matches nothing satisfies everything
	# written over it (traps §4).
	SUITE_FLAGS=("--path:../GuiAssert/src")
	LAW_SUITES=()
	;;
PLAT-41)
	MILESTONE="** PLAT-41: The eight panes with no view"
	SUITES=(
		src/frontend/tui/tests/test_plat41_pane_coverage.nim
	)
	# ONE SUITE, AND IT COUNTS ONLY THIS MILESTONE'S OWN CASES.
	#
	# PLAT-41 also grew `test_cross_renderer_panes.nim` by 24 assertions —
	# five panes gained real ViewModels there, the timeline joined the native
	# escapes, and one flow assertion became a loop over the accepted
	# exceptions. That suite is NOT listed here and the omission is deliberate:
	# it is PLAT-21's, its 21 cases are PLAT-21's work, and counting them under
	# PLAT-41 would be this campaign's own §28b defect — attributing a
	# measurement to whoever ran it last. The growth is recorded in the
	# milestone instead.
	#
	# It needs the `tui` lane's flags because `pane_views.nim` reaches the
	# product's ViewModels, and the data-path cases construct five of them over
	# a mock backend. Read from `ci/lib/test-lane-files.sh` rather than spelled
	# again here (§30).
	SUITE_FLAGS=("$(
		# shellcheck source=/dev/null
		. ci/lib/test-lane-files.sh >/dev/null 2>&1 &&
			test_lane_extra_flags tui
	)")
	LAW_SUITES=()
	;;
*)
	echo "FAIL: this gate has no table entry for '${MILESTONE_ID}'."
	echo "      Known: PLAT-24 … PLAT-41. A milestone gates"
	echo "      its own floor; adding one here is a deliberate edit, which is"
	echo "      the point."
	exit 1
	;;
esac
LAW_DEFERRED="${LAW_DEFERRED:-}"
LAW_SUITES=("${LAW_SUITES[@]:-}")
# PER-SUITE COMPILE FLAGS, defaulted to empty for every milestone that
# declares none. Added by PLAT-34, whose second suite links two renderers; it
# is an ARRAY PARALLEL TO `SUITES` rather than one string for the milestone,
# because a milestone with one native-only suite beside portable ones is the
# shape PLAT-29 already has and a single string would have applied the
# renderer's link flags to a file that links neither.
SUITE_FLAGS=("${SUITE_FLAGS[@]:-}")

if [ ! -f "${SPEC_REL}" ]; then
	echo "FAIL: the milestone file is not here: ${SPEC_REL}"
	echo "      The floor is published in codetracer-specs and read at run"
	echo "      time, never transcribed. A missing sibling checkout fails BY"
	echo "      NAME rather than skipping: a check that detects a missing"
	echo "      prerequisite, returns early and is counted PASSED is the defect"
	echo "      (Silent-Self-Pass-Audit-2026-08-23.md)."
	exit 1
fi

# The milestone's section: from its heading to the next top-level heading.
section="$(awk -v start="${MILESTONE}" '
	index($0, start) == 1 { inside = 1; print; next }
	inside && /^\*\* / { exit }
	inside { print }
' "${SPEC_REL}")"

if [ -z "${section}" ]; then
	echo "FAIL: no section in ${SPEC_REL} begins with:"
	echo "      ${MILESTONE}"
	exit 1
fi

mapfile -t floor_lines < <(grep -oE '^[[:space:]]*FLOOR: [0-9]+ cases' <<<"${section}" || true)
if [ "${#floor_lines[@]}" -ne 1 ]; then
	echo "FAIL: ${MILESTONE_ID}'s section holds ${#floor_lines[@]} FLOOR lines, expected exactly 1."
	echo "      §10.2: one spelling, at one indent, one per milestone — the total"
	echo "      is computed from those lines, so a second one silently doubles a"
	echo "      term of it and a missing one silently drops a milestone."
	exit 1
fi
floor="$(grep -oE '[0-9]+' <<<"${floor_lines[0]}" | head -1)"
echo "FLOOR, read from ${SPEC_REL}: ${floor} cases"

# ---------------------------------------------------------------------------
# THE LAW-TABLE ORACLE — §7.1's two-way count, for the milestones that have one
# ---------------------------------------------------------------------------
if [ -n "${LAW_SUITES[0]:-}" ]; then
	if [ ! -f "${LAWS_REL}" ]; then
		echo "FAIL: the conformance suite spec is not here: ${LAWS_REL}"
		echo "      §${LAW_SECTION}'s law table is an ORACLE and is read at run time."
		exit 1
	fi
	# The table rows: `| \`LAW-X1\` | statement | [population |] killer |`
	law_section="$(awk -v sect="### ${LAW_SECTION} " '
		index($0, sect) == 1 { inside = 1; next }
		inside && /^### / { exit }
		inside { print }
	' "${LAWS_REL}")"
	if [ -z "${law_section}" ]; then
		echo "FAIL: §${LAW_SECTION} was not found in ${LAWS_REL}."
		echo "      A parser that matched nothing satisfies every check written"
		echo "      over what it read (§4)."
		exit 1
	fi
	spec_ids=()
	missing_killers=()
	# The ids are spelled in MARKDOWN backticks, and a backtick inside a
	# single-quoted pattern is what shellcheck reports SC2016 for. Hoisting it
	# into a variable removes the report rather than suppressing it — the
	# pattern this repo's `nix/pre-commit.nix` asks for is to accept the
	# formatter's form rather than widen an exclusion.
	bt='`'
	while IFS= read -r row; do
		id="$(sed -E "s/^\\| *${bt}([^${bt}]+)${bt}.*/\\1/" <<<"${row}")"
		killer="$(awk -F'|' '{print $(NF-1)}' <<<"${row}" | sed -E 's/^ +| +$//g')"
		spec_ids+=("${id}")
		# An em dash in that column means the law is not admitted. Seven laws
		# in that document held one until 2026-09-18.
		if [ -z "${killer}" ] || [ "${killer}" = "—" ] || [ "${killer}" = "-" ] ||
			[ "${#killer}" -lt 15 ]; then
			missing_killers+=("${id}: '${killer}'")
		fi
	done < <(grep -E "^\\| *${bt}${LAW_PREFIX}[0-9]+${bt} *\\|" <<<"${law_section}" || true)

	echo "LAW TABLE, read from ${LAWS_REL} §${LAW_SECTION}: ${#spec_ids[@]} rows"
	if [ "${#spec_ids[@]}" -ne "${LAW_COUNT}" ]; then
		echo "FAIL: §${LAW_SECTION} published ${#spec_ids[@]} ${LAW_PREFIX} rows, expected ${LAW_COUNT}."
		exit 1
	fi

	# THE DECLARED DEFERRALS. Each must be PUBLISHED (or the deferral is about
	# a row that no longer exists) and must be ABSENT from the suite (or the
	# milestone implemented it and the deferral is stale). Both directions,
	# because either alone is satisfied by an empty set.
	deferred_ids=()
	if [ -n "${LAW_DEFERRED}" ]; then
		read -r -a deferred_ids <<<"${LAW_DEFERRED}"
		for d in "${deferred_ids[@]}"; do
			found=0
			for id in "${spec_ids[@]}"; do
				[ "${id}" = "${d}" ] && found=1
			done
			if [ "${found}" -ne 1 ]; then
				echo "FAIL: ${d} is declared DEFERRED by this gate and is not published"
				echo "      in §${LAW_SECTION}. A deferral about a row that does not exist"
				echo "      is a deferral nothing can expire."
				exit 1
			fi
		done
	fi
	# PRINTED EVEN WHEN IT IS ZERO. A deferral that is never mentioned when it
	# is absent is indistinguishable from one nobody looked for.
	echo "LAW TABLE: ${#deferred_ids[@]} row(s) declared deferred${LAW_DEFERRED:+: ${LAW_DEFERRED}}"
	expected_impl=$((LAW_COUNT - ${#deferred_ids[@]}))
	if [ "${#missing_killers[@]}" -ne 0 ]; then
		echo "FAIL: ${#missing_killers[@]} law(s) in §${LAW_SECTION} carry no killing mutation:"
		printf '      %s\n' "${missing_killers[@]}"
		echo "      §3: 'an arm with no stated killer is not admitted'."
		exit 1
	fi

	# The implementation's side, read out of the suites' own declarations. Every
	# `const LawName*` block of every named suite contributes; the union is what
	# is compared, because one published table can be implemented by more than
	# one milestone's suite and `LAW-C7` is the case that proved it.
	impl_ids=()
	for law_suite in "${LAW_SUITES[@]}"; do
		if [ ! -f "${law_suite}" ]; then
			echo "FAIL: the law suite ${law_suite} is not in the tree"
			exit 1
		fi
		mapfile -t suite_ids < <(sed -n '/^const LawName/,/\]/p' "${law_suite}" |
			grep -oE "${LAW_PREFIX}[0-9]+" || true)
		echo "LAW TABLE, read from ${law_suite}: ${#suite_ids[@]} ${LAW_PREFIX} id(s)"
		for id in "${suite_ids[@]:-}"; do
			[ -z "${id}" ] && continue
			impl_ids+=("${id}")
		done
	done
	echo "LAW TABLE, implementation side: ${#impl_ids[@]} ids across ${#LAW_SUITES[@]} suite(s)"
	if [ "${#impl_ids[@]}" -ne "${expected_impl}" ]; then
		echo "FAIL: the suite declares ${#impl_ids[@]} ${LAW_PREFIX} ids, expected ${expected_impl}"
		echo "      (${LAW_COUNT} published minus ${#deferred_ids[@]} declared deferred)."
		exit 1
	fi
	for d in "${deferred_ids[@]:-}"; do
		[ -z "${d}" ] && continue
		for id in "${impl_ids[@]:-}"; do
			if [ "${id}" = "${d}" ]; then
				echo "FAIL: ${d} is declared DEFERRED by this gate and the suite runs it."
				echo "      A stale deferral hides the only difference between 'not yet'"
				echo "      and 'never'."
				exit 1
			fi
		done
	done
	# Both directions, separately, and then the cardinality — the last line is
	# the one usually omitted, and without it the two differences are both
	# satisfied by two empty sets.
	# The published set MINUS the declared deferrals is what the suite is
	# compared against. The subtraction is the only thing `LAW_DEFERRED`
	# changes; both directions and the cardinality are unchanged.
	expected_sorted="$(printf '%s\n' "${spec_ids[@]}" | sort -u)"
	for d in "${deferred_ids[@]:-}"; do
		[ -z "${d}" ] && continue
		expected_sorted="$(grep -vxF "${d}" <<<"${expected_sorted}" || true)"
	done
	impl_sorted="$(printf '%s\n' "${impl_ids[@]}" | sort -u)"
	only_spec="$(comm -23 <(echo "${expected_sorted}") <(echo "${impl_sorted}"))"
	only_impl="$(comm -13 <(echo "${expected_sorted}") <(echo "${impl_sorted}"))"
	if [ -n "${only_spec}" ]; then
		echo "FAIL: published in §${LAW_SECTION} and not run by the suite: ${only_spec}"
		exit 1
	fi
	if [ -n "${only_impl}" ]; then
		echo "FAIL: run by the suite and not published in §${LAW_SECTION}: ${only_impl}"
		exit 1
	fi
	if [ "$(wc -l <<<"${expected_sorted}")" -ne "${expected_impl}" ] ||
		[ "$(wc -l <<<"${impl_sorted}")" -ne "${expected_impl}" ]; then
		echo "FAIL: the two law sets agree but are not ${expected_impl} distinct ids."
		exit 1
	fi
	echo "OK: ${LAW_COUNT} laws published, ${#deferred_ids[@]} deferred, ${expected_impl} run, both directions, no duplicates."
fi

total=0
for i in "${!SUITES[@]}"; do
	suite="${SUITES[$i]}"
	if [ ! -f "${suite}" ]; then
		echo "FAIL: ${suite} is not in the tree"
		exit 1
	fi
	bin="${TMPDIR:-/tmp}/editor-model-floor-$(basename "${suite}" .nim)"
	# Word-splitting on the flag string is intended: `test_lane_extra_flags`
	# emits a whitespace-separated flag list and each element has to reach
	# `nim` as its own argument.
	# shellcheck disable=SC2086
	out="$(nim c -r --hints:off ${SUITE_FLAGS[$i]:-} -o:"${bin}" "${suite}" 2>&1)" || {
		echo "FAIL: ${suite} did not run green"
		printf '%s\n' "${out}" | tail -30
		exit 1
	}
	# `[OK]` blocks, the same unit §1.1 counted the reference suite in.
	n="$(grep -cE '^[[:space:]]*\[OK\]' <<<"${out}" || true)"
	failed="$(grep -cE '^[[:space:]]*\[FAILED\]' <<<"${out}" || true)"
	checks="$(grep -oE '^[[:space:]]*CHECKS: [0-9]+' <<<"${out}" | grep -oE '[0-9]+' | head -1 || true)"
	if [ "${failed}" -ne 0 ]; then
		echo "FAIL: ${suite} reported ${failed} failing case(s)"
		exit 1
	fi
	if [ "${n}" -eq 0 ]; then
		echo "FAIL: ${suite} produced NO [OK] lines."
		echo "      A run that prints nothing looks exactly like a run in which"
		echo "      every case passed, if the only signal read is an exit status."
		exit 1
	fi
	echo "  ${suite}: ${n} cases, CHECKS: ${checks:-none}"
	total=$((total + n))
done

echo "TOTAL: ${total} cases across ${#SUITES[@]} suites; floor is ${floor}"
if [ "${total}" -lt "${floor}" ]; then
	echo "FAIL: the suite shrank below its published floor."
	echo "      §10.1: the floor moves only UPWARD, and only by a deliberate"
	echo "      edit to the milestone. If these cases are genuinely gone, that"
	echo "      is an edit somebody makes on purpose and defends."
	exit 1
fi
echo "OK: ${MILESTONE_ID}'s suites meet the floor published in the milestone."
