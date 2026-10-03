## LAYER RULE — `src/frontend/gpui/app/` is the SDK-CONSUMING half of the GPUI
## front-end. See the `.sdk-consumer` marker beside this file.
##
## gpui/app/leaves.nim — PLAT-20. **The leaves, and this is the ONLY module of
## this front-end that imports GPUI.**
##
## ## What the split buys, said where it is paid for
##
## PLAT-20: *"the shell is `HeadlessApp` plus the layout model, and only the
## leaves are GPUI. This is the same split the TUI already demonstrates, and the
## reason a third front-end is a binding rather than a rewrite."*
##
## `shell.nim` asserts the first half — it cannot see a renderer, at compile
## time. This module is the second half, and the whole of it: everything GPUI
## in the CodeTracer GPUI front-end is one `import isonim_gpui/renderer`, below,
## and the element tree built out of a `GpuiLeafSet`. Nothing in here knows what
## a `Layout` is, what a `LayoutCommand` is, or what a session is. It is handed
## slots and ViewModels and it draws them.
##
## ## The arrangement is NOT drawn here, and that is the dock binding's job
##
## A leaf's rectangle comes from the dock, not from this module: `DockPaneSlot`
## carries a placement and a tab group and no pixels, and the pixels are in the
## document `dock_projection` hands the dock host. So this module emits one
## element subtree per leaf, tagged with the slot, and lets the container place
## it — which is exactly what makes a real `DockArea` a drop-in for the
## placeholder container below on the day gpui-kit is a dependency.
##
## ## WHAT IS A PLACEHOLDER HERE, NAMED RATHER THAN IMPLIED
##
## `gpuiKitDockAvailable` is `false`, and it is a constant rather than a
## comment. gpui-kit is not a dependency of this workspace — measured, with
## TWO independent blockers, in PLAT-20's status block — so there is no
## `DockArea` to hand this tree to and the container below is a plain flex
## `div`. That is a LAYOUT placeholder and not a model placeholder: the
## placement it draws is read from the same projected document a `DockArea`
## would be given, so replacing the container does not change a single leaf.
##
## (**It said THREE blockers until 2026-09-16.** PLAT-22 falsified the third —
## "it does not compile with the toolchain this workspace has" — by compiling
## it: `cargo check -p gpui-base` exits 0 with the stable rustc/cargo 1.96.0
## already in this host's nix store. What remains is the cargo package split,
## `gpui-pre` 0.3.x against our `gpui` 0.2.2, and the fact that the repo is in
## no manifest. The correction is dated and in place in PLAT-20's status; this
## sentence is corrected with it so that a reader who trusts the comment and a
## reader who follows the pointer are told the same thing.)
##
## ## PLAT-22 — THIS MODULE STOPPED DRAWING PANE TITLES
##
## **What was here before PLAT-22 drew a leaf's NAME**, and that is worth
## stating plainly because it is the defect this milestone was told not to let
## happen a fifth time. PLAT-21 wrote every debugger pane once in PLAT-3's
## vocabulary (`view_vocabulary/pane_views.nim`) and a third binding to render
## them (`view_vocabulary/gpui_binding.nim`), and measured both through three
## renderers on a real recording — and **nothing in the shipped
## `codetracer-gpui` binary called either.** Measured 2026-09-16:
## `grep -rn 'paneView(' src/ --include=*.nim` answered only
## `tui/tests/test_cross_renderer_panes.nim`, and `renderGpui` only that file
## and `gpui/tests/test_gpui_vocabulary_binding.nim`. The suites graded a path
## the binary never took, which is the same finding this campaign has recorded
## for `emitProtocolImage` (PLAT-14), `activatePane` (PLAT-20) and
## `gpuiRowBudget` (PLAT-21).
##
## `renderLeaf` now builds the pane's view through `pane_views.paneView` and
## renders it through `gpui_binding.renderGpui`, so the binary draws what the
## suites grade. The leaf's own `div` and its four attributes are unchanged —
## the arrangement half of PLAT-20 is untouched — and the pane's tree is
## appended INSIDE it.
##
## ## THE EDITOR IS A NATIVE VIEW AND IS DRAWN HERE, NOT THROUGH THE BINDING
##
## PLAT-3's admission test refused an `Editor` entry, PLAT-21 made the source
## pane a `nativeEscape`, and PLAT-22 keeps it one. So `paneEditor` does not go
## through `renderGpui`: it is drawn by `renderEditor` below, from the
## `EditorSurface` the host supplies — the shared row model every front-end's
## editor derives from the same ViewModels
## (`view_vocabulary/editor_surface.nim`).
##
## **AND THE ESCAPE'S MEDIUM IS CHECKED HERE RATHER THAN ASSERTED IN A SUITE.**
## PLAT-21's verification planted an arm that hardcoded the escape's
## `nativeMedium` to `"terminal"` while the `PaneView` still said `"gpui"`, and
## it SURVIVED: `grep -rn nativeMedium` over all three suites returned nothing.
## `vocabulary.nativeEscape`'s own doc comment says it is *"built deliberately
## so that a caller writing one has said which front-end it is for"*, and until
## now nothing read the answer. `renderEditor` refuses a surface or an escape
## naming another front-end and draws the refusal, so the field has a
## PRODUCTION READER and the arm has something to break.

import std/[json, strutils]

import isonim_gpui/renderer
import ./shell
import ../../view_vocabulary/pane_views
import ../../view_vocabulary/gpui_binding
import ../../view_vocabulary/editor_surface
import ../../../common/view_vocabulary
import ../../../common/value_presentation
# The native timeline's ViewModel (PLAT-41) comes through the SDK facade, like
# every other ViewModel a front-end consumes. `codetracer_embed` already
# imports and exports `timeline_vm` (for the same reason as `origin_chain_vm`),
# so naming `viewmodels/timeline_vm` here reached past the facade for nothing
# and tripped `ci/test/sdk-facade-boundary.sh` (consumer-facade-only). The
# siblings `shell.nim` and `edit_arm.nim` import it exactly this way.
import codetracer_embed
import isonim/core/[signals, computation]
# PLAT-47 B1: the editor is classified by the TERMINAL'S tokenizers (the
# tree-sitter-free half of its highlighter) and painted from the one editor
# theme — the same `TokenClass`, the same generated tokens.
import ../../tui/app/syntax/lexical
import ../../tui/app/theme/editor_theme
import ../../styles/generated/design_tokens

export shell, editor_surface
# `value_presentation` is re-exported because the BUDGETS are this medium's
# vocabulary: `GpuiPanelBudget` and `gpuiRowBudget()` are what the GPUI
# front-end passes to PLAT-2's presenter, and `main.nim` has to name the second
# one when it builds the editor's surface. Re-exporting from the medium's own
# module is what keeps the budget's spelling in one place rather than letting
# the wiring reach for `surfaces.nim` directly and, one day, for a literal.
export value_presentation

const gpuiKitDockAvailable* = false
  ## **Whether a real gpui-kit `DockArea` is hosting these leaves.**
  ##
  ## `false`, and asserted as `false` by `tests/test_gpui_shell_split.nim`
  ## rather than left as prose, so the day it becomes `true` a test has to be
  ## updated by somebody who has read why. A `when` on this constant is what a
  ## milestone that vendors gpui-kit edits; nothing else here needs to move.
  ##
  ## Verification-Harness-Traps §7a is the reason it is a value: a header
  ## sentence saying "the dock is not wired yet" is the most comfortable place
  ## for a claim that stops being true without anything going red.

const
  PaneRoleAttribute* = "data-ct-pane"
  SlotPathAttribute* = "data-ct-slot-path"
  TabAttribute* = "data-ct-tab"
  StateAttribute* = "data-ct-state"
    ## The four attributes a leaf carries into the element tree. They are what
    ## `renderPlanJson` shows, so a test can assert *which pane was drawn where*
    ## without a display and without a pixel — the render-plan tier PLAT-19
    ## established for isonim-gpui, used here for the arrangement rather than
    ## for a component.
    ##
    ## **A CORRECTION MEASURED BY PLAT-20 AND RESTATED HERE, because PLAT-22
    ## adds more of them**: the render plan serialises `kind`, `tag`, `text`,
    ## `has_click_handler`, `has_input_handler`, `event_names`, `styles` and
    ## `children`, and **no attribute map at all**. So these are readable from
    ## the SHADOW TREE (`getAttribute`, the Rust-side attribute store) and are
    ## NOT in `renderPlanJson`. A reader that wants them out of the plan gets an
    ## empty answer, and an empty answer satisfies every assertion anybody would
    ## write over it (Verification-Harness-Traps §4).

  GpuiMedium* = "gpui"
    ## The name this front-end answers to, in `nativeEscape`'s and
    ## `EditorSurface.medium`'s vocabulary. ONE constant, so the escape the
    ## pane declares and the surface the host built are compared rather than
    ## both being spelled by hand at two call sites (§14).

  EditorRowAttribute* = "data-ct-row"
  EditorPointerAttribute* = "data-ct-pointer"
  EditorMarkAttribute* = "data-ct-mark"
  EditorFlowAttribute* = "data-ct-flow"
  FlowNotTakenOpacity* = "0.5"
    ## `.line-flow-skip { opacity: 0.5 }` — the Electron front-end's value,
    ## carried across rather than chosen.
  EditorHeldAttribute* = "data-ct-held"
  EditorMediumAttribute* = "data-ct-medium"
  EditorProvenanceAttribute* = "data-ct-provenance"
  EditorExecutionAttribute* = "data-ct-execution-line"
    ## What one editor row publishes about itself. Each is the ROW MODEL's own
    ## value stringified — never a glyph — so a case asserts the surface
    ## against the ViewModel rather than against an appearance, which is what
    ## PLAT-22 asks for: *"the execution pointer and per-line status come from
    ## the ViewModel and are asserted against it, so a rendering that drifts
    ## from the model fails"*.

  EditorValuesAttribute* = "data-ct-values"
    ## **PLAT-35.** The row's inline values in STRUCTURED form —
    ## `name=value|name=value`, in draw order — beside `inlineValueText`'s
    ## glyph form.
    ##
    ## It is not a duplicate of the annotation span and the distinction is the
    ## same one every other attribute here rests on: the span is what a user
    ## sees, this is what the row SAID. `Cross-Renderer-Visual-Alignment.md`
    ## §3 asks for *"inline value runs by line — count, order, and the text of
    ## each"*, and a count alone is satisfied by two front-ends that draw the
    ## same number of different values. Parsing them back out of `/* x: 1, y: 2
    ## */` would make the comparison a test of the annotation formatter.

  TextRoleAttribute* = "data-ct-text-role"
  TextMetricAttribute* = "data-ct-text-metric"
  ExecutionRowBand* = DesignTokenHex[dtEditorThemeExecutionLine][dmDark]
    ## The execution row's band, drawn as the desktop's Monaco draws its
    ## current line: `editor-theme/executionLine` (measured `#404040` in
    ## Dark), across the CODE COLUMN to the editor's right edge and NOT under
    ## the line numbers (PLAT-47 B1). Until then GPUI drew the old `.on` line
    ## class's `#4f4f4f` under the whole row, gutter included. PLAT-39's reader
    ## locates the execution line GEOMETRICALLY by a band; it now reads it on
    ## the code column (`EditorCodeColumnAttribute`).
  EditorGround* = DesignTokenHex[dtEditorThemeGround][dmDark]
    ## The editor's ground — Monaco's `editor.background` (PLAT-47 B1).
  EditorLineNumberColour* = DesignTokenHex[dtEditorThemeLineNumber][dmDark]
  EditorActiveLineNumberColour* =
    DesignTokenHex[dtEditorThemeActiveLineNumber][dmDark]
    ## The resting and the active (execution line's) line numbers.
  EditorCodeColumnAttribute* = "data-ct-code-column"
    ## Marks a row's CODE COLUMN — everything right of the gutter, grown to
    ## the pane's right edge — which is what carries the execution band.
  EditorTokenClassAttribute* = "data-ct-token-class"
    ## A code run's `TokenClass`, so a plan reader can check the class a run
    ## was painted as without re-deriving the colour.
  GutterLaneAttribute* = "data-ct-gutter-lane"
    ## **WHICH LANE OF THE GUTTER A RUN IS** — `pointer`, `mark` or `number`
    ## (`GutterRunKind`). PLAT-35 / `PLAT35-F13`, `PLAT35-F14`.
    ##
    ## The gutter is drawn as three runs rather than one text node because the
    ## MARK has to be painted a colour of its own: before this it sat inside
    ## the one gutter span and therefore took the line-number colour, which is
    ## the whole of `PLAT35-F13`'s first half. The attribute exists so that
    ## *which* run carries the mark is readable from the render plan — the
    ## structural instrument `--pixels-out` corresponds to — instead of being
    ## inferred from a glyph's position in a string.
    ##
    ## A NEW attribute NAME on purpose. Every census this tree already takes
    ## counts `data-ct-text-role`, `data-ct-text-metric` and `data-ct-token`,
    ## and all three stay on the ONE gutter span, so splitting the run moves
    ## none of those numbers (checked: `test_plat35_text_faces.nim`'s
    ## `rolesIn(pane, trGutterLineNumber) == surface.rows.len` is still the row
    ## count).
  TokenAttribute* = "data-ct-token"
    ## **PLAT-35's tier-3 rows for text metrics and token colour.**
    ##
    ## `TokenAttribute` carries a design-system TOKEN ID and never a hex value
    ## — §3.1: a token comparison is exact and survives rasterisation, a hex
    ## comparison does not, because the two renderers blend and gamma-correct
    ## differently.
    ##
    ## `TextMetricAttribute` carries `family/size/weight` in the bucket
    ## alphabet `layout_questions.nim` publishes. **On this front-end it is a
    ## DECLARED metric and not a measured one**, and that is filed as
    ## `PLAT35-VG1` rather than left implicit: the Rust shim in this workspace
    ## is built without `--features gpui-backend`, so `createWindow` opens
    ## nothing and there is no shaped glyph to measure. The Electron arm's
    ## answer to the same question IS measured, out of `getComputedStyle`, so
    ## the row is labelled `source reading` on this side and `captured` on the
    ## other — PLAT-23's tiering rule, per row.

  FocusIndexAttribute* = "data-ct-focus-index"
    ## **PLAT-35's focus-order row.** The position this leaf occupies in the
    ## front-end's focus order, stamped by `renderLeaves` from the projected
    ## document's own order.
    ##
    ## **DECLARED, NOT ENFORCED**, and filed as `PLAT35-VG4`. `PLAT21-VG3`
    ## measured that isonim-gpui has focus at the WINDOW level only — `grep -n
    ## focus` over the shim's `tree.rs` and `render_sync.rs` returns nothing —
    ## so no element can hold or refuse focus and nothing makes this order
    ## happen. It is still the right thing to publish: the Electron arm's
    ## answer is also a declaration (`tabindex` on the pane roots), so the two
    ## are comparable, and a front-end whose declared order drifts from the
    ## other's is a defect whether or not either enforces it.

  ExecutionPointerGlyph* = "▶"
  InspectionPointerGlyph* = "▷"
  BreakpointGlyph* = "●"
  BreakpointDisabledGlyph* = "○"
  TracepointGlyph* = "◆"
  EmptyLaneGlyph* = "\u00A0"
    ## **AN EMPTY LANE IS ONE NO-BREAK SPACE, and the no-break is load-bearing
    ## rather than tidy.** Each lane is drawn as its own span (see
    ## `GutterLaneAttribute`), so a lane whose whole text is one ASCII space is
    ## a span whose ONLY character is a trailing space — and the text layout
    ## drops a span's trailing ASCII spaces, which is the measurement
    ## `GutterGap` below was written from. A dropped lane is a lane of zero
    ## width, which would put the line numbers back at a different x per row
    ## and re-open `PLAT35-F16`.
  NoMarkGlyph* = EmptyLaneGlyph
    ## **THE MEDIUM'S OWN SPELLING, and it is not the terminal's.** The terminal
    ## draws its execution pointer as `-->` across three cells because a
    ## terminal's gutter is measured in cells and CTUI-5 fixed that width; a
    ## GPU surface has no cell, so it uses one glyph. The MARKS are the same
    ## three characters as the terminal's on purpose — they are the marks
    ## CodeTracer-TUI.md §3.3.2 specifies and a user who has seen one front-end
    ## should recognise the other — and the fact that the two media agree here
    ## and differ on the pointer is why the glyphs are per medium and the ROW
    ## is shared.

  EditorLoadingText* = "⋯ loading"
    ## What a visible line the window does not hold shows. **Never a blank**:
    ## `source_vm`'s second contract is that a line outside the window is a
    ## REQUEST rather than an empty string, because *"a blank pane over a
    ## working debugger is indistinguishable from a file of blank lines"*, and
    ## a medium that rendered `""` for `held == false` would throw that away at
    ## the last step.

type
  LeafRenderOutcome* = object
    root*: GpuiElement
      ## The container holding one child per leaf.
    drawn*: int
      ## How many leaves produced a subtree. Equal to `leaves.len` on every
      ## path — a leaf with no ViewModel draws its REPORT rather than nothing,
      ## which is PLAT-9's rule and the reason this number is asserted rather
      ## than trusted.
    reported*: int
      ## How many of those were a report (no ViewModel, or an unloaded
      ## extension) rather than a live pane.

proc slotPath(slot: DockPaneSlot): string =
  var parts: seq[string] = @[$slot.region]
  for i in slot.path:
    parts.add $i
  parts.join("/")

func markGlyph*(m: EditorMark): string =
  ## One function, so the glyph table and any assertion over it ask the same
  ## question, and so a fifth mark does not compile until it has one.
  case m
  of emNone: NoMarkGlyph
  of emBreakpoint: BreakpointGlyph
  of emBreakpointDisabled: BreakpointDisabledGlyph
  of emTracepoint: TracepointGlyph

func pointerGlyph*(p: EditorPointer): string =
  case p
  of eptNone: EmptyLaneGlyph
  of eptInspection: InspectionPointerGlyph
  of eptExecution: ExecutionPointerGlyph

func markColour*(m: EditorMark; inherited: string): string =
  ## **THE COLOUR THE MARK GLYPH IS PAINTED. THE VALUES ARE THE ELECTRON
  ## FRONT-END'S OWN**, read out of its gutter classes rather than chosen here
  ## — the brief's §6: *"the Electron front-end is the reference; where the
  ## reference is wrong, that is a change to the Electron front-end and to the
  ## design system, never a licence for the GPUI front-end to differ"*.
  ## Measured 2026-10-03 in `src/frontend/styles/components/text_editor.styl`:
  ##
  ##   `.gutter-breakpoint-enabled`   `background: colors-ui-text-error-primary`
  ##   `.gutter-breakpoint-disabled`  `background: colors-ui-surface-primary-tertiary`
  ##   `.gutter-trace`                `background: colors-ui-border-action`
  ##
  ## which are `dtColorsUiTextErrorPrimary`, `dtColorsUiSurfacePrimaryTertiary`
  ## and `dtColorsUiBorderAction` in the generated token table — so the hex is
  ## the design system's and this function names only the mapping. (Dark:
  ## `#fca5a5`, `#333333`, `#6366f1`.)
  ##
  ## **WHY THIS FUNCTION EXISTS AT ALL — `PLAT35-F13`.** Until 2026-10-03 the
  ## mark was one character inside the ONE gutter span, so it took the gutter's
  ## colour, which is the line-number colour. Measured off this front-end's own
  ## window plan at 1440x900 with `--replay-ops=setBreakpoint@1`: the marked
  ## row's gutter run was `#575757` — byte-identical to the unmarked rows
  ## around it — while the SAME node's `data-ct-token` already said
  ## `gutter.breakpoint.enabled`. The declaration and the ink disagreed and the
  ## declaration was the true one; this makes the ink follow it.
  ##
  ## `emNone` returns the colour the run would have INHERITED. A no-mark lane
  ## is one blank cell with no ink, so no value is observable there, and
  ## returning the inherited one keeps a run's declared colour equal to what is
  ## drawn rather than publishing a colour nothing uses. An exhaustive `case`,
  ## so a fifth mark does not compile until somebody has looked its class up.
  ##
  ## **`#333333` FOR A DISABLED BREAKPOINT IS DARKER THAN THE LINE NUMBERS
  ## (`#575757`) AND IS RECORDED HERE RATHER THAN SILENTLY CORRECTED.** It is
  ## the reference's value for a FILLED DISC on a panel ground, used here for a
  ## `○` outline on the editor's `#282828`; and no scenario in
  ## `src/tests/visual/scenarios.json` draws a disabled breakpoint or a
  ## tracepoint, so a different value here would be a choice no lane in this
  ## tree can grade. Per §6 that is a design-system question and not this
  ## front-end's to re-decide.
  case m
  of emNone: inherited
  of emBreakpoint: DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark]
  of emBreakpointDisabled:
    DesignTokenHex[dtColorsUiSurfacePrimaryTertiary][dmDark]
  of emTracepoint: DesignTokenHex[dtColorsUiBorderAction][dmDark]

const GutterGap* = "\u00A0\u00A0\u00A0\u00A0"
  ## Between the gutter and the code. A reader — a person, or PLAT-39's
  ## reader splitting the execution band into ink clusters — must be able to
  ## tell where the number ends and the code begins; `39def` could not.
  ##
  ## FOUR NO-BREAK SPACES, and the first half of that is measured on the window
  ## frames: the text layout drops a span's trailing ASCII spaces, and two
  ## no-break spaces measured ~9 px while `44` still merged into `def`. Four
  ## clear the reader's 14 px cluster gap.
  ##
  ## **THE SECOND HALF OF THIS COMMENT USED TO BE FALSE AND IS CORRECTED HERE,
  ## 2026-10-03.** It said the face drawn is *"the window's proportional
  ## default (the shim does not draw `font-family`, so `gpuiMetricFor`'s mono
  ## is declared rather than applied — `PLAT35-VG1`)"*. That stopped being true
  ## on 2026-10-02: `chrome.MonoFontFamily` plus `main.applyTextFaces` set the
  ## key `gpui_app.rs`'s `apply_styles_to_div` already read, and the gutter is
  ## drawn in `Menlo` on this platform. `chrome.MonoFontFamily`'s own header
  ## carries that measurement and names this parenthesis as the line to fix in
  ## the pass that next edits this file; this is that pass.
  ##
  ## **EDITING IT MOVES THE `*-control.sha256` DIGESTS OF SIX MUTATION
  ## HARNESSES THAT DIGEST THIS FILE BYTE-FOR-BYTE**, and each must be
  ## RE-GRADED before its digest is re-recorded
  ## (`Verification-Harness-Traps` §39). The six, measured at review on
  ## 2026-10-03 against `c05d8443a` by parsing EVERY `*-control.sha256` in the
  ## tree — not by reading the harnesses a reviewer happened to think of,
  ## which is how the two earlier counts in this comment's history were both
  ## wrong (an earlier draft said THREE, `chrome.nim`'s said FOUR; both
  ## counted only the harnesses under `src/frontend/gpui/tests/` and missed
  ## the three under `src/frontend/tui/tests/` that digest this file across
  ## the medium boundary):
  ##
  ##   * `run-plat20-mutations.py`          `plat20-mutation-control.sha256`
  ##   * `run-plat22-mutations.py`          `plat22-mutation-control.sha256`
  ##   * `run-plat35-visual-mutations.py`   `plat35-visual-…`
  ##   * `run-plat42-surface-mutations.py`  `plat42-surface-…`
  ##   * `run-plat47-parity-mutations.py`   `plat47-parity-…`
  ##   * `run-plat49-chrome-mutations.py`   `plat49-chrome-…`
  ##
  ## `run-plat21-mutations.py` does NOT, which both earlier drafts had right:
  ## its subjects are `gpui_binding` / `fact_reader` / `pane_views` /
  ## `gpui_gaps` / `mappings` / `surfaces` / `terminal_binding`.
  ##
  ## **ALL SIX WERE GREEN AT THE PARENT COMMIT, SO EVERY ONE OF THEM WAS RUN
  ## RATHER THAN REASONED ABOUT.** §39 forbids re-recording without
  ## re-grading; it does not license leaving a lane red unexamined. Graded at
  ## `c05d8443a` on aarch64-darwin, 2026-10-03:
  ##
  ##   * `plat20` — **14 of 14 KILLED.** It grades on this host, so it was
  ##     RE-GRADED against these bytes and its digest IS re-recorded in this
  ##     commit.
  ##   * `plat22` — REFUSES: *"`src/build-debug/bin/replay-server` does not
  ##     exist, so every case that spawns a replay-server would fail on an
  ##     UNMUTATED tree and every arm would score MIS-ATTRIBUTED."* The
  ##     harness is right to refuse and it mutated nothing.
  ##   * `plat35-visual` — **0 of 9 KILLED, all nine DID-NOT-COMPILE**,
  ##     including the `.md` and `.json` subjects, which no mutation could
  ##     have broken. Its suite reads
  ##     `../codetracer-specs/Testing/Cross-Renderer-Visual-Alignment.md` at
  ##     run time and the sibling now keeps that file under `spec/Testing/`.
  ##     Recording its digest would certify a harness that cannot kill
  ##     anything.
  ##   * `plat42-surface` — ABORTS: baseline
  ##     `test_gpui_editing_surface.nim` is RED on
  ##     `countedAssertions == ExpectedAssertions` (it needs `/proc/self/statm`,
  ##     which macOS has not).
  ##   * `plat47-parity`, `plat49-chrome` — *"REFUSING TO RUN:
  ##     `REPLAY_SERVER_BIN` is not exported"*. Their needle scans pass
  ##     (`0 problems`); only the environment is missing.
  ##
  ## So FIVE of the six digests are STALE AS OF THIS COMMIT, deliberately, and
  ## each is owed a re-grade by a pass that can run it: a built
  ## `src/build-debug/bin/replay-server` and an exported `REPLAY_SERVER_BIN`
  ## (plat22, plat47, plat49), the specs sibling at the path the suite reads
  ## (plat35-visual), and a green editing-surface baseline (plat42-surface).
  ## None of them is a defect in this change, and none is re-recorded blind.

const GutterLaneGap* = " "
  ## **ONE CELL BETWEEN THE LANES AND THE NUMBER FIELD, DECLARED rather than
  ## inherited from whichever lane happens to be empty.** `PLAT35-F13`'s second
  ## half: until 2026-10-03 `●` abutted its digit with ZERO cells while `▶` had
  ## one, and the one was an accident of ordering — the mark lane sat between
  ## the pointer and the number, so an occupied POINTER lane was separated from
  ## the digits by the empty MARK lane and an occupied mark lane was separated
  ## by nothing at all. One lane, two paddings, neither of them chosen.
  ##
  ## It is the terminal's own `gutter.GutterGapCells = 1`, carried across
  ## rather than re-picked.
  ##
  ## **ONE CELL AND NOT TWO** (there is no second gap BETWEEN the two lanes),
  ## measured: the GPUI editor pane is 276 px wide at 1440x900 and a Menlo cell
  ## is ~8 px, so every gutter cell costs about one column of code — and
  ## `PLAT35-F3` (the editor clips mid-token with no ellipsis, P1, open) is
  ## already what that width costs. A second gap cell would buy separation
  ## between `▶` and `●`, which differ in shape and now in colour, at the price
  ## of one more clipped column on every row of every frame.
  ##
  ## **ASCII AND NOT NO-BREAK**, unlike `GutterGap` and `EmptyLaneGlyph`: it is
  ## the FIRST character of the number run and is followed by the padding and
  ## the digits, so it is interior rather than trailing and the layout keeps
  ## it. The byte budget is the reason to prefer the shorter spelling —
  ## `tests/plat42_gutter.MaxLaneBytes` is 12, and `▶` + `●` + this gap + the
  ## padding of a four-digit field is 3 + 3 + 1 + 3 = 10 bytes before the first
  ## digit.

type
  GutterRunKind* = enum
    ## The gutter's three runs, left to right. A KIND rather than a position,
    ## so a plan reader asks which lane a run IS instead of counting glyphs
    ## into a string.
    grkPointer = "pointer"
    grkMark = "mark"
    grkNumber = "number"

  GutterRun* = object
    ## One painted run of one row's gutter.
    kind*: GutterRunKind
    text*: string
    colour*: string
      ## The hex this run is painted in. `pointer` and `number` carry the
      ## gutter's own line-number colour — resting, or Monaco's active one on
      ## the execution row — and `mark` carries `markColour`'s.

func gutterRuns*(row: EditorRow; numberWidth: int): array[3, GutterRun] =
  ## **THE GUTTER, AS THE THREE RUNS IT IS DRAWN AS:**
  ## `<pointer><mark><lane gap><right-aligned number><GutterGap>`.
  ##
  ## `gutterText` is this function joined, so there is ONE definition of the
  ## gutter's geometry and an assertion over the string and the rendering ask
  ## the same question (`Verification-Harness-Traps` §30). It is the shape the
  ## terminal's `gutter.gutterRow` already has — styled spans, always the same
  ## ones, whatever the line — and for the same second reason: a gutter whose
  ## run count changed when a breakpoint appeared would be a different tree per
  ## row.
  ##
  ## **EACH LANE IS ONE RESERVED CELL AT A FIXED INDEX: pointer 0, mark 1.**
  ## `PLAT35-F14`. Until 2026-10-03 the padding was consumed BEFORE the lanes
  ## (`spaces(numberWidth - number.len) & pointer & mark & number`), so the
  ## lanes' cell indices moved with the line number's digit count. Measured on
  ## this front-end's own window plan, 1440x900, unstepped, with
  ## `--replay-ops=setBreakpoint@1`:
  ##
  ##     line  1 (pointer)  [' ', '▶', ' ', '1']
  ##     line  2 (mark)     [' ', ' ', '●', '2']
  ##     line 10            [' ', ' ', '1', '0']
  ##
  ## The dot and the TENS DIGIT both at cell index 2, in one frame — so the
  ## mark formed no column a reader could scan down, and on a two-digit row it
  ## moved into the cell the pointer occupies on a one-digit row. The padding
  ## now sits BETWEEN the lanes and the number, which is where the terminal
  ## puts it: `padLeft(number, numberWidth)` INSIDE the number field, with the
  ## lanes outside it.
  ##
  ## **THE LANES STAY LEFT OF THE NUMBER.** The pointer sat after the number
  ## until 2026-09-23, where it OCR'd glued to the digits (`44p`) and PLAT-39's
  ## gutter grammar — marker glyphs, then digits — rejected every execution row
  ## it had located by its band. The desktop editor's gutter (`> 44`) and the
  ## terminal's both draw the markers left of the digits. (The terminal's exact
  ## order is `mark`, number, gap, `pointer`, gap — `gutter.gutterRow` — which
  ## is NOT the `--> ● 44` this comment used to claim; the GPUI order keeps
  ## both lanes before the number because its pointer is one glyph and its
  ## gutter has no third field to spare.)
  ##
  ## **WHY THIS DOES NOT REDDEN PLAT-39 — QUOTED FROM ITS READER RATHER THAN
  ## ARGUED.** The sentence this geometry used to be justified by, *"the only
  ## wide gap on a row is `GutterGap`, the one a reader locates the gutter's
  ## end by"*, is not what that reader does.
  ## `screen_oracle/vision_producer.readGutterDigits` reads *"the shortest
  ## prefix of the band's clusters (up to `MaxGutterClusters`) that parses as
  ## `EditorGrammar`"*, with `MaxGutterClusters = 3` and its own comment
  ## reading: *"Electron's gutter is two clusters (the arrow, ~30 px left of
  ## the number, then the number); GPUI's is one (`▶ 44`). A THIRD COVERS A
  ## MARK DRAWN IN ITS OWN LANE."* So the reader already admits three, and the
  ## invariant it needs is that the gutter's ink forms AT MOST three clusters
  ## and that no admissible prefix can end mid-number. Both still hold:
  ##
  ##   * the pointer and the mark are ADJACENT cells, so they never split from
  ##     one another — the gutter's ink is at most TWO clusters (the lanes,
  ##     then the number) where it was one;
  ##   * the digits stay contiguous, so no cluster boundary falls inside a
  ##     number;
  ##   * `GutterGap` — the only thing between the number and the code — is
  ##     untouched, so the number's cluster still cannot run into the code;
  ##   * a prefix that stops at the lane cluster is REJECTED and retried,
  ##     because `pane_grammar.parseGutterDigits` strips leading marker glyphs
  ##     by CLASS (`uint8(text[i]) >= 0x80'u8`, which is every glyph in these
  ##     lanes) and then requires at least one digit.
  ##
  ## Padded to the widest line number in the surface, so every row's code still
  ## starts in one column (the gutter face is monospaced,
  ## `gpuiMetricFor(trGutterLineNumber)`), and the total width is still a
  ## constant for a surface — `2 + 1 + numberWidth + 4` cells, one more than
  ## before — which is what keeps `PLAT35-F16` closed.
  let number = $row.line
  # THE GUTTER'S OWN COLOUR, UNCHANGED: Monaco's resting line number, and its
  # active one on the execution line.
  let own = if row.pointer == eptExecution: EditorActiveLineNumberColour
            else: EditorLineNumberColour
  [GutterRun(kind: grkPointer, text: pointerGlyph(row.pointer), colour: own),
   GutterRun(kind: grkMark, text: markGlyph(row.mark),
             colour: markColour(row.mark, own)),
   GutterRun(kind: grkNumber,
             text: GutterLaneGap & spaces(max(0, numberWidth - number.len)) &
                   number & GutterGap,
             colour: own)]

func gutterText*(row: EditorRow; numberWidth: int): string =
  ## One row's whole gutter as text — `gutterRuns` joined, never a second
  ## spelling of it.
  for run in gutterRuns(row, numberWidth):
    result.add run.text

func inlineValueText*(values: openArray[EditorValue]): string =
  ## `/* x: 42, str: "ready" */`, or "" for no values.
  ##
  ## `""` rather than `/* */` for the empty case, which is the terminal's rule
  ## carried across rather than re-decided: the CLEARING case has to be
  ## observable as the ABSENCE of an annotation rather than as a different
  ## annotation, or a reader cannot tell "the debugger reported nothing" from
  ## "the formatter printed nothing".
  if values.len == 0:
    return ""
  var parts: seq[string] = @[]
  for v in values:
    parts.add v.name & ": " & v.value
  "/* " & parts.join(", ") & " */"

func structuredValues*(values: openArray[EditorValue]): string =
  ## `name=value|name=value`, in DRAW ORDER, for `EditorValuesAttribute`.
  ##
  ## Deliberately not sorted: `Cross-Renderer-Visual-Alignment.md` §3 asks for
  ## *"count, order, and the text of each"*, and sorting here would answer two
  ## thirds of the question while looking like all of it.
  var parts: seq[string] = @[]
  for v in values:
    parts.add v.name & "=" & v.value
  parts.join("|")

func gpuiMetricFor*(role: TextRole): string =
  ## **THIS FRONT-END'S DECLARED TEXT METRIC for a role**, in the bucket
  ## alphabet `layout_questions.nim` publishes.
  ##
  ## Declared, and `PLAT35-VG1` is where that is filed rather than glossed: the
  ## shim in this workspace is built without `--features gpui-backend`, so
  ## nothing here has ever asked a text system how tall a glyph is. The Electron
  ## arm answers the same question out of `getComputedStyle` — measured — which
  ## is why the two rows carry different tiers and the comparison still runs.
  ##
  ## An exhaustive `case`, so a sixth role does not compile until it has a
  ## metric. A default arm would give a new role the editor's metric and the
  ## comparison would agree about a value nobody chose.
  ## **THE BUCKETS ARE THE ELECTRON FRONT-END'S MEASURED ONES**, and three of
  ## the five were changed on 2026-09-20 because the cross-renderer gate said
  ## so. Before that this front-end declared the gutter at `sm` and the pane
  ## title at `sm/medium`; `getComputedStyle` on the shipped Electron renderer
  ## measures `mono/md/regular` and `proportional/md/regular`. The Electron
  ## front-end is the reference (§6), so the declaration moved — which is the
  ## whole of what "visual alignment" means for a fact a GPU surface cannot yet
  ## measure for itself.
  case role
  of trEditorCode: $fcMono & "/" & $sbBody & "/" & $wbRegular
  of trGutterLineNumber: $fcMono & "/" & $sbBody & "/" & $wbRegular
  of trPaneTitle: $fcProportional & "/" & $sbBody & "/" & $wbRegular
  of trValueName: $fcProportional & "/" & $sbBody & "/" & $wbRegular
  of trValueText: $fcMono & "/" & $sbBody & "/" & $wbRegular

func gpuiTokenFor*(role: TextRole; row: EditorRow): string =
  ## **THE DESIGN-SYSTEM TOKEN ID this front-end resolves a role to**, given
  ## what the row says about itself. Never a hex value (§3.1).
  ##
  ## The row matters for exactly one role: a gutter on a line carrying a mark
  ## resolves to that mark's token rather than to the line-number token, which
  ## is the difference the `breakpoint-editor` scenario exists to make
  ## observable. Making it depend on the row is also what gives the token
  ## question something a mutation can move.
  case role
  of trEditorCode:
    if row.pointer == eptExecution: "editor.executionLine.background"
    else: "editor.code.foreground"
  of trGutterLineNumber:
    case row.mark
    of emBreakpoint: "gutter.breakpoint.enabled"
    of emBreakpointDisabled: "gutter.breakpoint.disabled"
    of emTracepoint: "gutter.tracepoint"
    of emNone: "editor.lineNumber.foreground"
  of trPaneTitle: "pane.title.foreground"
  of trValueName: "value.name.foreground"
  of trValueText: "value.text.foreground"

func tokenColour*(cls: TokenClass): string =
  ## The colour a code run of class `cls` is painted: the editor theme's rule
  ## for the class's Monaco scope (`editor_theme.tokenClassToken`), Dark.
  DesignTokenHex[tokenClassToken(cls)][dmDark]

proc renderEditorRow(r: GpuiRenderer; row: EditorRow; runs: seq[TokenRun];
                     numberWidth = 1): GpuiElement =
  ## One row of the source editor.
  ##
  ## Every attribute below is the ROW's own field stringified. Nothing here
  ## re-decides what the row says — `editor_surface` decided it from the
  ## ViewModels — so a rendering that drifts from the model is a rendering
  ## whose attributes stop matching the surface, which is exactly the
  ## comparison PLAT-22's second named integration test makes.
  ##
  ## `runs` is the row's text classified by the terminal's tokenizer
  ## (`lexical.tokenRuns`); each is painted in its class's theme colour.
  let el = r.createElement("div")
  r.setAttribute(el, EditorRowAttribute, $row.line)
  r.setAttribute(el, EditorPointerAttribute, $row.pointer)
  r.setAttribute(el, EditorMarkAttribute, $row.mark)
  r.setAttribute(el, EditorFlowAttribute, $row.flow)
  r.setAttribute(el, EditorHeldAttribute, (if row.held: "true" else: "false"))
  r.setAttribute(el, EditorValuesAttribute, structuredValues(row.values))
  r.setStyle(el, "display", "flex")
  # ONE SOURCE LINE IS ONE ROW. Soft wrap is off in every editor this
  # product ships (`editing_core.terminalWrapSettings`), so a long line — or a
  # long inline value, which `gpuiRowBudget` leaves unbounded in width because
  # a GPU row's capacity is pixels the surface does not know — is CLIPPED at
  # the pane's edge rather than wrapped onto rows that belong to the lines
  # below it. Until 2026-09-23 the shim did not draw these styles and a noir
  # inline value wrapped one row into twenty; the window record is what showed
  # it (`test_plat42_window.nim`).
  r.setStyle(el, "white-space", "nowrap")
  r.setStyle(el, "overflow", "hidden")
  # A ROW IS ALWAYS A FULL LINE HIGH. The host asks for the rows the pane
  # shows (`window_geometry.editorRowsOf`); should the pane shrink below them
  # later, the pane clips the last rows rather than the flex column squeezing
  # every row and cutting off descenders.
  r.setStyle(el, "flex-shrink", "0")

  let gutter = r.createElement("span")
  r.setAttribute(gutter, TextRoleAttribute, $trGutterLineNumber)
  r.setAttribute(gutter, TextMetricAttribute, gpuiMetricFor(trGutterLineNumber))
  r.setAttribute(gutter, TokenAttribute, gpuiTokenFor(trGutterLineNumber, row))
  # THE MARKER LANES ARE LEFT OF THE NUMBER, each one reserved cell at a fixed
  # index, and the geometry — with the measurements it was changed from — is
  # `gutterRuns`'. The pointer sat AFTER the number until 2026-09-23, where it
  # OCR'd as a letter glued to the digits (`44p`) and PLAT-39's gutter grammar
  # — marker glyphs, then digits — rejected every execution row it had located
  # by its band.
  #
  # THREE RUNS AND NOT ONE TEXT NODE, which is `PLAT35-F13`: the MARK has to be
  # painted its own colour and a character inside the gutter span can only take
  # the gutter's. Same pattern as the code column's classified `piece` spans
  # below — a child span per run, its own `color`, `flex-shrink: 0`, inside a
  # flex parent — so the face still comes from the ONE metric-bearing node
  # (children inherit it, which is how the code runs are monospaced) and every
  # role / metric / token census is unmoved.
  r.setStyle(gutter, "display", "flex")
  r.setStyle(gutter, "flex-shrink", "0")
  # The line numbers are Monaco's: resting, and active on the execution line.
  # Still set on the gutter itself, so a reader of the SPAN's colour reads what
  # it read before; each run then states its own, and for two of the three it
  # is this same value.
  r.setStyle(gutter, "color",
             if row.pointer == eptExecution: EditorActiveLineNumberColour
             else: EditorLineNumberColour)
  for run in gutterRuns(row, numberWidth):
    let lane = r.createElement("span")
    r.setAttribute(lane, GutterLaneAttribute, $run.kind)
    r.setStyle(lane, "color", run.colour)
    r.setStyle(lane, "flex-shrink", "0")
    r.appendChild(lane, r.createTextNode(run.text))
    r.appendChild(gutter, lane)
  r.appendChild(el, gutter)

  # THE CODE COLUMN: the rest of the row, grown to the pane's right edge, so
  # the execution band covers exactly what Monaco's current-line band covers.
  let column = r.createElement("div")
  r.setAttribute(column, EditorCodeColumnAttribute, "true")
  r.setStyle(column, "display", "flex")
  r.setStyle(column, "flex-grow", "1")
  r.setStyle(column, "white-space", "nowrap")
  r.setStyle(column, "overflow", "hidden")
  if row.pointer == eptExecution:
    r.setStyle(column, "background", ExecutionRowBand)

  let code = r.createElement("span")
  r.setAttribute(code, TextRoleAttribute, $trEditorCode)
  r.setAttribute(code, TextMetricAttribute, gpuiMetricFor(trEditorCode))
  r.setAttribute(code, TokenAttribute, gpuiTokenFor(trEditorCode, row))
  r.setStyle(code, "display", "flex")
  if row.held and runs.len > 0:
    for run in runs:
      let piece = r.createElement("span")
      r.setAttribute(piece, EditorTokenClassAttribute, $run.class)
      r.setStyle(piece, "color", tokenColour(run.class))
      r.setStyle(piece, "flex-shrink", "0")
      r.appendChild(piece, r.createTextNode(run.text))
      r.appendChild(code, piece)
  else:
    r.setStyle(code, "color", tokenColour(tcPlain))
    r.appendChild(code,
      r.createTextNode(if row.held: row.text else: EditorLoadingText))
  # THE FLOW OVERLAY, DRAWN AS THE DESKTOP EDITOR DRAWS IT: a line inside an
  # arm the run declined is dimmed to half opacity (`.line-flow-skip` in
  # `styles/components/flow.styl`), and a line that ran is left as it is
  # (`.line-flow-hit` is `opacity: 1`). `efsUnknown` claims nothing and so
  # changes nothing. The decision is `flowStateOf`'s; this only paints it.
  if row.flow == efsNotTaken:
    r.setStyle(code, "opacity", FlowNotTakenOpacity)
  r.setStyle(code, "flex-shrink", "0")
  r.appendChild(column, code)

  let annotation = inlineValueText(row.values)
  if annotation.len > 0:
    let ann = r.createElement("span")
    r.setAttribute(ann, TextRoleAttribute, $trValueText)
    r.setAttribute(ann, TextMetricAttribute, gpuiMetricFor(trValueText))
    r.setAttribute(ann, TokenAttribute, gpuiTokenFor(trValueText, row))
    # The value SHRINKS and ends in an ellipsis; the code before it never
    # does. What is clipped is the value's tail, which is also what the
    # terminal's `inline_annotations` gives up first.
    r.setStyle(ann, "min-width", "0")
    r.setStyle(ann, "overflow", "hidden")
    r.setStyle(ann, "text-overflow", "ellipsis")
    r.appendChild(ann, r.createTextNode(annotation))
    r.appendChild(column, ann)
  r.appendChild(el, column)
  el

proc editorRunsOf*(surface: EditorSurface): seq[seq[TokenRun]] =
  ## Every row's text classified as the terminal classifies it: the path's
  ## Monaco tokenizer (`lexical.lexerForPath`; a tree-sitter language or an
  ## unknown one is left plain), the state running on from row to row from
  ## the surface's `entryContext`. A row still loading is empty and leaves
  ## the state where it was.
  let lexer = if grammarForPath(surface.path) != giNone: lxNone
              else: lexerForPath(surface.path)
  var context = if surface.entryContext.len > 0: surface.entryContext
                else: initialContext(lexer)
  for row in surface.rows:
    if lexer == lxNone or not row.held:
      result.add @[]
    else:
      result.add tokenRuns(lexer, row.text, context)

proc renderEditor*(r: GpuiRenderer; parent: GpuiElement;
                   escape: ViewNode; surface: EditorSurface): bool =
  ## Draw the source editor into `parent`. Answers whether it drew ROWS.
  ##
  ## **THE MEDIUM IS CHECKED FIRST, AND A MISMATCH IS A REFUSAL RATHER THAN A
  ## ROUNDING.** `escape` is what `pane_views.sourcePaneView` declared and
  ## `surface` is what the host built; if either names another front-end, this
  ## front-end is about to draw somebody else's native view, which is the one
  ## thing `nativeEscape` exists to make impossible to do silently. Drawing it
  ## anyway would be the failure `dock_projection`'s `leTop` refusal is written
  ## against, one layer up: a value quietly moved rather than a problem named.
  if escape.isNil or escape.nativeMedium != GpuiMedium or
     surface.medium != GpuiMedium:
    let detail = "the source pane's native view is declared for '" &
      (if escape.isNil: "<none>" else: escape.nativeMedium) &
      "' and its surface for '" & surface.medium & "'; this front-end is '" &
      GpuiMedium & "'"
    r.appendChild(parent, r.createTextNode(detail))
    return false
  r.setAttribute(parent, EditorMediumAttribute, surface.medium)
  r.setAttribute(parent, EditorProvenanceAttribute, $surface.provenance)
  r.setAttribute(parent, EditorExecutionAttribute, $surface.executionLine)
  if surface.report.len > 0:
    # `report` REPLACES the rows: there is nothing to draw. `notice` below
    # ACCOMPANIES them. The two were one field for the length of one test run;
    # `EditorSurface.notice`'s own comment carries the measurement.
    r.appendChild(parent, r.createTextNode(surface.report))
    return false
  # THE STATEMENT IS DRAWN ALWAYS, which is §2's Requirement rather than this
  # module's taste: *"the Source pane states which mode's source it is showing,
  # always — not only when they differ, because 'only when it matters' requires
  # the user to know when it matters"*.
  if surface.sourceStatement.len > 0:
    let statement = r.createElement("div")
    r.appendChild(statement, r.createTextNode(surface.sourceStatement))
    r.appendChild(parent, statement)
  if surface.notice.len > 0:
    let note = r.createElement("div")
    r.appendChild(note, r.createTextNode(surface.notice))
    r.appendChild(parent, note)
  if surface.degradedMessage.len > 0:
    let msg = r.createElement("div")
    r.appendChild(msg, r.createTextNode(surface.degradedMessage))
    r.appendChild(parent, msg)
  var widest = 1
  for row in surface.rows:
    widest = max(widest, len($row.line))
  # PLAT-47 B1: the editor's own ground, Monaco's `editor.background`.
  r.setStyle(parent, "background-color", EditorGround)
  let runs = editorRunsOf(surface)
  for i, row in surface.rows:
    r.appendChild(parent, renderEditorRow(r, row, runs[i], widest))
  surface.rows.len > 0

const
  TimelineBarWidthPx* = 400
    ## The scrubber's track. A fixed track rather than the pane's width: the
    ## pane's width is the dock's to decide and a track that re-measured it
    ## would be a second layout owner (`admission.nim`'s rule).
  TimelineBarHeightPx = 6
  TimelineTrackColor = "#3a3a3a"
  TimelineFillColor = "#4fb3a9"

proc timelineText*(current, first, last: uint64): string =
  ## `tick <current> / <last> [<percent>%]` — the terminal header's spelling.
  let span = if last > first: last - first else: 0'u64
  let done = if current > first: current - first else: 0'u64
  let pct = if span == 0: 0.0 else: 100.0 * float(done) / float(span)
  "tick " & $current & " / " & $last & " [" & formatFloat(pct, ffDecimal, 1) & "%]"

proc renderTimeline(r: GpuiRenderer; parent: GpuiElement; vm: TimelineVM) =
  ## The recording's extent and where the debugger is in it: a line of text
  ## (what a reader and PLAT-39's reader parse) and a track filled to the
  ## current tick (what an eye reads).
  let marks = vm.bounds.val
  let first = if marks.len > 0: marks[0] else: 0'u64
  let last = if marks.len > 1: marks[1] else: first
  let current = vm.currentPosition.val
  let label = r.createElement("div")
  r.appendChild(label, r.createTextNode(timelineText(current, first, last)))
  r.appendChild(parent, label)
  let track = r.createElement("div")
  r.setStyle(track, "width", $TimelineBarWidthPx & "px")
  r.setStyle(track, "height", $TimelineBarHeightPx & "px")
  r.setStyle(track, "background", TimelineTrackColor)
  let fill = r.createElement("div")
  let span = if last > first: last - first else: 0'u64
  let done = if current > first: min(current - first, span) else: 0'u64
  let filled = if span == 0: 0 else: int(TimelineBarWidthPx.float * float(done) / float(span))
  r.setStyle(fill, "width", $filled & "px")
  r.setStyle(fill, "height", $TimelineBarHeightPx & "px")
  r.setStyle(fill, "background", TimelineFillColor)
  r.appendChild(track, fill)
  r.appendChild(parent, track)

const
  CallRowAttribute* = "data-call-index"
    ## PLAT-49 part B: a call-trace row's trace index.
  CallToggleAttribute* = "data-call-toggle"
    ## Its toggle state (`leaf`, `expanded`, `collapsed`).
  CallPartAttribute* = "data-call-part"
    ## A row part's `CallSegmentKind` (`callee`, `argName`, `argValue`, …).
  CallSelectedAttribute* = "data-call-selected"
  CallRowPx* = 26
    ## A row's height: the window's row pitch (`window_geometry
    ## .GpuiEditorRowPx`), fixed, so a press is mapped to the row it is on
    ## (`main.clickCalltrace`).
  CallIndentPx* = 16
    ## The desktop's depth offset per level (`paddingForDepth(item, 16)`).
  CallArgsColour* = DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
    ## CALLTRACE_ARGS_COLOR (#BBF7D0) — the token the terminal's `srCallArgs`
    ## paints.
  CallReturnColour* = DesignTokenHex[dtColorsUiTextInformationOnColor][dmDark]
    ## CALLTRACE_RETURN_COLOR (#BFDBFE, Dark) exactly: the window is Dark.
    ## (The terminal's `srCallReturn` takes information-primary, the token
    ## with a legible Light value.)
  CallToggleColour* = DesignTokenHex[dtColorsUiTextPrimaryCaptionSubtle][dmDark]
  CallTextColour* = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  CallSelectedBackground* =
    DesignTokenHex[dtColorsUiSurfacePrimarySecondaryHover][dmDark]
    ## The selected row's ground (`.event-selected`): the design system's
    ## active-row token (the desktop's `.active-step-line`), the terminal's
    ## `srSurfaceActiveRow`.

proc renderCallTrace*(r: GpuiRenderer; parent: GpuiElement;
                      vm: CalltraceVM): bool =
  ## PLAT-49 part B (finding 8): THE CALL TRACE, ROW BY ROW FROM THE
  ## VIEWMODEL'S `CallRow`s — indented by depth, the toggle, the callee and
  ## its index, the arguments with their values in the arguments' colour and
  ## ` => value` in the return's, the selected row on its own ground — the
  ## desktop's row (`isonim_calltrace_view.renderCallLineRowWeb`) from the
  ## same parts the terminal paints (`calltrace_vm.callRowSegments`). False
  ## when there are no rows (the fallback and the reports stay
  ## `pane_views`').
  let rows = vm.callRows()
  if rows.len == 0:
    return false
  let list = r.createElement("div")
  r.setAttribute(list, "data-calltrace", "rows")
  r.setStyle(list, "display", "flex")
  r.setStyle(list, "flex-direction", "column")
  for row in rows:
    let el = r.createElement("div")
    r.setAttribute(el, CallRowAttribute, $row.index)
    r.setAttribute(el, CallToggleAttribute, $row.toggle)
    let selected = crfSelected in row.flags
    r.setAttribute(el, CallSelectedAttribute,
                   (if selected: "true" else: "false"))
    # A call row is one line, its parts side by side.
    for (key, value) in [("display", "flex"), ("white-space", "nowrap")]:
      r.setStyle(el, key, value)
    r.setStyle(el, "overflow", "hidden")
    r.setStyle(el, "flex-shrink", "0")
    r.setStyle(el, "height", $CallRowPx & "px")
    r.setStyle(el, "items", "center")
    r.setStyle(el, "padding-left", $(row.depth * CallIndentPx) & "px")
    if selected:
      r.setStyle(el, "background", CallSelectedBackground)
    for seg in row.callRowSegments(indent = false):
      let piece = r.createElement("span")
      r.setAttribute(piece, CallPartAttribute, $seg.kind)
      r.setStyle(piece, "flex-shrink", "0")
      r.setStyle(piece, "color",
        case seg.kind
        of csToggle:
          # On the selected row the toggle is the desktop's `active` icon,
          # in the body colour — the muted one is not legible on that ground.
          (if selected: CallTextColour else: CallToggleColour)
        of csPunct, csArgName, csArgValue: CallArgsColour
        of csReturnArrow, csReturnValue: CallReturnColour
        else: CallTextColour)
      if selected and seg.kind in {csCallee, csIndex}:
        r.setStyle(piece, "font-weight", "bold")
      r.appendChild(piece, r.createTextNode(seg.text))
      r.appendChild(el, piece)
    r.appendChild(list, el)
  r.appendChild(parent, list)
  true

proc renderPaneView(r: GpuiRenderer; parent: GpuiElement;
                    leaf: GpuiLeaf; budget: Budget): bool =
  ## Draw a builtin pane's vocabulary tree into `parent`. Answers whether the
  ## pane rendered DATA rather than a report.
  ##
  ## `pane_views.paneView` is the ONE door, and its `case` is exhaustive over
  ## `PaneKind`, so a pane added to the enum without a view does not compile
  ## rather than becoming a name nothing renders.
  ##
  ## PLAT-49 part B: the call trace's ROWS are drawn natively from its
  ## semantic rows (`renderCallTrace`) — a vocabulary `List` option is one
  ## label and could not carry the parts the desktop styles apart.
  if leaf.builtin == paneCalltrace and not leaf.vm.isNil and
     renderCallTrace(r, parent, CalltraceVM(leaf.vm)):
    return true
  let pv = paneView(leaf.builtin, leaf.vm, budget, GpuiMedium)
  let binding = renderGpui(r, pv.root)
  r.appendChild(parent, binding.root)
  pv.report.len == 0

proc paneTitleElement(r: GpuiRenderer; leaf: GpuiLeaf): GpuiElement =
  ## A leaf's title, carrying its TEXT ROLE, its metric and its token.
  ##
  ## PLAT-35. ONE function rather than the two identical spellings that stood
  ## here — the editor branch and the generic branch built the same heading two
  ## screens apart, which is §30's shape inside one `case`, and is the reason
  ## the role was about to be stamped on one of them and not the other.
  result = r.createElement("div")
  r.setAttribute(result, TextRoleAttribute, $trPaneTitle)
  r.setAttribute(result, TextMetricAttribute, gpuiMetricFor(trPaneTitle))
  r.setAttribute(result, TokenAttribute, gpuiTokenFor(trPaneTitle,
                                                      EditorRow()))
  r.appendChild(result, r.createTextNode(
    if leaf.title.len > 0: leaf.title else: leaf.paneId))

proc renderLeaf(r: GpuiRenderer; leaf: GpuiLeaf;
                surface: EditorSurface): (GpuiElement, bool) =
  ## One leaf's subtree, and whether it is a REPORT rather than a live pane.
  ##
  ## Three states and not two, which is PLAT-9's `PaneRefKind` arriving at a
  ## renderer: a live pane, a pane whose session has not launched, and a
  ## contributed pane from an extension that is not loaded. The third keeps its
  ## slot and names the extension — *"the layout keeps the slot, the front-end
  ## renders a report naming the extension, and reinstalling it restores the
  ## pane where it was"* — and none of the three is a blank region.
  let node = r.createElement("div")
  # Every leaf clips, not only a top-level column: two leaves stacked in one
  # column must not draw into each other either (PLAT-41).
  r.setStyle(node, "overflow", "hidden")
  r.setAttribute(node, PaneRoleAttribute, leaf.paneId)
  r.setAttribute(node, SlotPathAttribute, slotPath(leaf.slot))
  r.setAttribute(node, TabAttribute,
                 $leaf.slot.tabIndex & "/" & $leaf.slot.tabCount &
                 "@" & $leaf.slot.activeIndex)
  case leaf.kind
  of glkUnloadedExtension:
    r.setAttribute(node, StateAttribute, "unloaded-extension")
    let text = r.createTextNode(
      "This pane is provided by an extension that is not loaded: " &
      leaf.paneId)
    r.appendChild(node, text)
    return (node, true)
  of glkBuiltin, glkContributed:
    # **THE EDITOR IS DECIDED BY THE SURFACE, NOT BY `leaf.live`**, and this
    # ordering is a repair rather than a preference. `live` asks whether a
    # REPLAY SESSION built a ViewModel for the pane, and in EDIT mode there is
    # deliberately no replay session at all — `product_mode.sourceContractFor
    # (pmEdit)` says the source is the working tree. Checked the other way
    # round, `ct edit --ui=gpui <project>` drew *"Editor — waiting for the
    # session to launch"* over a project it had already read off the disk:
    # measured on the shipped binary, and it is the same shape as the `adopt`
    # defect one layer up — a pane reporting an absence while the data sat in
    # the process.
    #
    # The surface reports for itself when it has nothing (`EditorSurface
    # .report`), so moving the decision here loses no honesty: it moves it to
    # the value that actually knows.
    if leaf.kind == glkBuiltin and leaf.builtin == paneEditor:
      r.setAttribute(node, StateAttribute,
                     if surface.report.len > 0: "editor-report" else: "live")
      let heading = paneTitleElement(r, leaf)
      r.appendChild(node, heading)
      let drewRows = renderEditor(r, node, sourcePaneView(GpuiMedium).root,
                                  surface)
      return (node, not drewRows)
    # **AN ACCEPTED EXCEPTION SAYS WHICH EXCEPTION IT IS** (PLAT-41's LAW-P3),
    # in every product mode. `fileTree` and `buildOutput` have no replay
    # ViewModel by DECISION, so the generic not-live sentence below — "waiting
    # for the session to launch" — was a promise the session would never keep,
    # drawn on a real run of the shipped binary. `paneView` names the
    # exception and its reason without a ViewModel.
    # **THE TIMELINE IS THIS FRONT-END'S OWN VIEW**, as the editor is: PLAT-3
    # refused a Timeline entry in the vocabulary (`timelinePaneView` is a
    # native escape), which obliges each medium to draw one natively. Until
    # PLAT-41 GPUI drew nothing there — the escape node has no text — while
    # the terminal and the desktop draw a scrubber.
    if leaf.kind == glkBuiltin and leaf.builtin == paneTimeline and leaf.live:
      r.setAttribute(node, StateAttribute, "live")
      r.appendChild(node, paneTitleElement(r, leaf))
      renderTimeline(r, node, TimelineVM(leaf.vm))
      return (node, false)
    if leaf.kind == glkBuiltin and leaf.builtin in PaneAcceptedExceptions:
      r.setAttribute(node, StateAttribute, "pane-report")
      r.appendChild(node, paneTitleElement(r, leaf))
      discard renderPaneView(r, node, leaf, GpuiPanelBudget)
      return (node, true)
    if not leaf.live:
      r.setAttribute(node, StateAttribute, "not-launched")
      # **THE SENTENCE NAMES THE PRODUCT MODE**, because "waiting for the
      # session to launch" is a promise in DEBUG mode and a falsehood in EDIT
      # mode: edit mode has no session and is not waiting for one. Two states
      # behind one string is §5a's merge, and the one that is wrong is the one
      # a user would act on by waiting.
      let text = r.createTextNode(
        (if leaf.title.len > 0: leaf.title else: leaf.paneId) &
        (if surface.productMode == pmEdit:
           " — a DEBUG-mode pane; EDIT mode shows " & surface.sourceStatement
         else:
           " — waiting for the session to launch"))
      r.appendChild(node, text)
      return (node, true)
    r.setAttribute(node, StateAttribute, "live")
    # THE TITLE IS STILL DRAWN, AND IT IS NOW A HEADING RATHER THAN THE PANE.
    # Before PLAT-22 this text WAS the whole leaf; keeping it as the first
    # child means the arrangement assertions PLAT-20 wrote — which read the
    # plan's text nodes in plan order — still have something to read, and the
    # pane's own tree follows it.
    let heading = paneTitleElement(r, leaf)
    r.appendChild(node, heading)
    if leaf.kind == glkBuiltin:
      let drewData = renderPaneView(r, node, leaf, GpuiPanelBudget)
      if not drewData:
        r.setAttribute(node, StateAttribute, "pane-report")
        return (node, true)
      return (node, false)
    # A CONTRIBUTED pane that IS loaded has no `PaneKind` and therefore no
    # entry in `pane_views`' exhaustive `case`. It keeps the title it had,
    # which is what a plugin's pane was before PLAT-22 and still is: PLAT-9
    # owns what a plugin surface renders, and inventing a tree for it here
    # would be this front-end deciding a question that milestone owns.
    return (node, false)

proc setHeadingText*(r: GpuiRenderer; node: GpuiElement; text: string) =
  ## Replace a leaf's heading text (its first child's text).
  if node.isNil or childCount(node) == 0:
    return
  let heading = nthChild(node, 0)
  if heading.isNil or getAttribute(heading, TextRoleAttribute) != $trPaneTitle:
    return
  while childCount(heading) > 0:
    r.removeChild(heading, nthChild(heading, 0))
  r.appendChild(heading, r.createTextNode(text))

proc redrawLeafBody*(r: GpuiRenderer; node: GpuiElement; leaf: GpuiLeaf;
                     heading = "") =
  ## PLAT-47 B3: draw a live pane's view again, in place — everything after
  ## its heading removed and rebuilt by `renderPaneView`, the function that
  ## drew it the first time — after its ViewModel moved (a scrolled call
  ## trace). `heading`, when given, replaces the title's text.
  if node.isNil or leaf.kind != glkBuiltin:
    return
  while childCount(node) > 1:
    r.removeChild(node, nthChild(node, childCount(node) - 1))
  discard renderPaneView(r, node, leaf, GpuiPanelBudget)
  if heading.len > 0:
    setHeadingText(r, node, heading)

const NoSurfaceSuppliedReport* =
  "no editor surface was supplied to renderLeaves; the host builds one from " &
  "SourceVM and this call did not pass it"
  ## **The default surface's report, and it is DELIBERATELY NOT
  ## `NoSessionReport`.**
  ##
  ## Verification-Harness-Traps §5a: giving an existing value a second reason
  ## merges two events, and the caller then cannot act on either. "This session
  ## has not launched" and "this call site forgot the surface" are different
  ## facts with different remedies, and the second is the one that would
  ## otherwise hide — a defaulted parameter reading as an ordinary unlaunched
  ## session is precisely how `sourcePaneModelFor`'s `points` and `variables`
  ## came to be unfed in the shipped terminal without anything going red.

proc renderLeaves*(r: GpuiRenderer; leafSet: GpuiLeafSet;
                   surface = EditorSurface(medium: GpuiMedium,
                                           report: NoSurfaceSuppliedReport)):
                   LeafRenderOutcome =
  ## Build the element tree for one window.
  ##
  ## A REFUSED projection draws its refusal. It does not draw an empty window
  ## and it does not fall back to a default arrangement: the terminal's
  ## `ppDegrade` exists because a terminal must paint something on a real
  ## screen the user is already looking at, and a host that has not opened a
  ## window yet has no such obligation.
  let root = r.createElement("div")
  r.setAttribute(root, "data-ct-window", $int(leafSet.windowId))
  r.setAttribute(root, "data-ct-dock",
                 if gpuiKitDockAvailable: "gpui-kit" else: "flex-placeholder")
  r.setStyle(root, "display", "flex")
  result = LeafRenderOutcome(root: root, drawn: 0, reported: 0)
  if leafSet.refused.len > 0:
    r.setAttribute(root, StateAttribute, "refused")
    let text = r.createTextNode("layout refused: " &
                                describe(leafSet.refused))
    r.appendChild(root, text)
    return
  for leaf in leafSet.leaves:
    let (node, reported) = renderLeaf(r, leaf, surface)
    # PLAT-35's focus-order row. The index is the leaf's position in the
    # projected document's own order — the order this front-end would move
    # focus in — stamped so the question can be answered from the RENDERED
    # tree rather than re-derived from `leafSet`, which would be reading the
    # input and calling it an observation (Verification-Harness-Traps §4a).
    r.setAttribute(node, FocusIndexAttribute, $result.drawn)
    r.appendChild(root, node)
    inc result.drawn
    if reported:
      inc result.reported

proc leafPlanJson*(r: GpuiRenderer; outcome: LeafRenderOutcome): string =
  ## The render plan GPUI would execute, as JSON. The verification tier
  ## PLAT-19 built for isonim-gpui, pointed at PLAT-20's arrangement.
  r.renderPlanJson(outcome.root)

proc leafPlanIsValid*(r: GpuiRenderer; outcome: LeafRenderOutcome): bool =
  r.verifyRenderPlan(outcome.root)

proc drawnPaneIds*(r: GpuiRenderer; outcome: LeafRenderOutcome): seq[string] =
  ## Which pane each child of the container is for, read back out of the
  ## shadow tree rather than out of the input. A test asserting the input
  ## would be asserting its own fixture.
  result = @[]
  let n = childCount(outcome.root)
  for i in 0 ..< n:
    let child = nthChild(outcome.root, i)
    if child.isNil: continue
    let id = getAttribute(child, PaneRoleAttribute)
    if id.len > 0:
      result.add id

proc planLeafTexts*(planJson: string): seq[string] =
  ## Every text node of the render plan, in plan order.
  ##
  ## **A SECOND READING OF THE SAME TREE THROUGH A DIFFERENT CODE PATH**, and
  ## it is the plan that GPUI would execute rather than the shadow tree this
  ## module wrote. `drawnPaneIds` reads what we put in; this reads what comes
  ## out of the shim's own plan builder, so a leaf that was appended to the
  ## wrong parent, or a container the plan builder dropped, is visible to one
  ## reader and not the other.
  ##
  ## **IT READS `text` AND NOT AN ATTRIBUTE, AND THAT IS MEASURED RATHER THAN
  ## PREFERRED.** The first version of this function read
  ## `attributes["data-ct-pane"]` out of the plan, which would have been the
  ## direct reading — and the shim's plan serialises `kind`, `tag`, `text`,
  ## `has_click_handler`, `has_input_handler`, `event_names`, `styles` and
  ## `children`, and no attribute map at all. Every call would have returned an
  ## empty seq, and an empty seq satisfies every assertion anybody would write
  ## over it (Verification-Harness-Traps §4). Measured on a real recording
  ## through a real `replay-server` before this comment was written; the plan
  ## printed by `codetracer-gpui --report-plan` is the evidence.
  var texts: seq[string] = @[]
  if planJson.len == 0:
    return texts
  var doc: JsonNode
  try:
    doc = parseJson(planJson)
  except CatchableError:
    return texts
  proc walk(n: JsonNode; acc: var seq[string]) =
    if n.isNil: return
    case n.kind
    of JObject:
      let t = n{"text"}
      if not t.isNil and t.kind == JString and t.getStr.len > 0:
        acc.add t.getStr
      let kids = n{"children"}
      if not kids.isNil:
        walk(kids, acc)
    of JArray:
      for v in n:
        walk(v, acc)
    else: discard
  walk(doc, texts)
  texts
