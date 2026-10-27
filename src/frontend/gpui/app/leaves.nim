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

import std/[json, math, options, os, sets, strutils, tables]
from std/unicode import runeLen, runeSubstr, Rune, toUTF8

import isonim_gpui/renderer
# `PLAT35-F3`: the pane's own padding, so the scrollbar's track covers
# exactly the span the rows do. `chrome.ChromePaddingPx`'s own comment says
# why the number lives there — "two spellings of one number is §30" — and an
# absolutely-placed overlay has to subtract the same one `stylePaneBox` adds.
import ../chrome
import ./shell
import ../../view_vocabulary/pane_views
import ../../view_vocabulary/gpui_binding
# `PLAT35-F4` x PLAT-50: the two attributes `window_clicks` dispatches a
# VARIABLE press on. Imported from where the vocabulary declares them rather
# than spelled again here, so this renderer and the binding cannot drift
# about what a `Tree` row is called (§30) — see `renderState`'s `table`.
from ../../view_vocabulary/fact_reader import ViewIdAttribute,
                                              ViewKindAttribute
import ../../view_vocabulary/editor_surface
import ../../../common/view_vocabulary
import ../../../common/value_presentation
# Every ViewModel comes through the SDK facade, like every other ViewModel a
# front-end consumes (`ci/test/sdk-facade-boundary.sh`, consumer-facade-only).
# The siblings `shell.nim` and `edit_arm.nim` import it exactly this way.
import codetracer_embed
import isonim/core/[signals, computation]
# PLAT-47 B1: the editor is classified by the TERMINAL'S tokenizers (the
# tree-sitter-free half of its highlighter) and painted from the one editor
# theme — the same `TokenClass`, the same generated tokens.
import ../../tui/app/syntax/lexical
import ../../tui/app/theme/editor_theme
import ../../styles/generated/design_tokens
import ../devicon_marks
from std/hashes import hash

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
  EditorTextColour* = DesignTokenHex[dtEditorThemeRuleDefault][dmDark]
    ## The editor's default foreground (PLAT-51: the omnibox's text in every
    ## state — Commands-And-Omnibox.md, "Omnibox colours on every front-end").
  EditorSelectionColour* = DesignTokenHex[dtEditorThemeSelection][dmDark]
  FindMatchColour* = DesignTokenHex[dtColorsUiSurfaceAlertWarning][dmDark]
    ## PLAT-70 Part C: every find match — the terminal's
    ## `srSurfaceFindMatch` token (`theme/roles.nim` records why: the design
    ## system has no find-match token).
  FindMatchCurrentColour* =
    DesignTokenHex[dtColorsUiSurfaceAlertInformation][dmDark]
    ## The current match — the terminal's `srSurfaceFindMatchCurrent`.
    ## The editor's selection ground (the omnibox's selected result).
  EditorActiveLineNumberColour* =
    DesignTokenHex[dtEditorThemeActiveLineNumber][dmDark]
    ## The resting and the active (execution line's) line numbers.
  EditorCodeColumnAttribute* = "data-ct-code-column"
    ## Marks a row's CODE COLUMN — everything right of the gutter, grown to
    ## the pane's right edge — which is what carries the execution band.
  EditorTokenClassAttribute* = "data-ct-token-class"
    ## A code run's `TokenClass`, so a plan reader can check the class a run
    ## was painted as without re-deriving the colour.
  InlineTextRunsAttribute* = inlineTextRunsAttribute
    ## `data-inline-text-runs`: the renderer draws this element's coloured
    ## spans as ONE piece of text (`isonim_gpui/renderer`).
    ##
    ## A highlighted code row is split into one span per token run AND one
    ## per bracket character, so a row can carry a dozen of them. Drawn as a
    ## dozen text elements, each one's width is rounded up to a whole logical
    ## pixel and each starts from the inflated total of the ones before it,
    ## so the row's text creeps right of where the same characters land in
    ## the browser front-end — measured as a per-row drift growing to several
    ## device pixels across a window (PLAT-37). Monaco has no such step: a
    ## browser accumulates inline runs at 1/64 px and rounds once.
    ##
    ## This asks for the same thing: one rounding for the whole row.
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

  ExecutionPointerGlyph* = "▸"
    ## PLAT-51: the execution pointer's TEXT spelling (what a plan reader
    ## reads in the lane's `data-ct-pointer-mark` row); the window DRAWS the
    ## desktop's own mark there (`ExecutionMarkSvg`, below), as
    ## Native-Front-End-Parity.md §3 asks — "GPUI draws the desktop's mark
    ## itself". It was `▶`.
  InspectionPointerGlyph* = "▷"
  ExecutionMarkSvg* = staticRead("../../../public/resources/shared/highlight_line_arrow.svg")
    ## The desktop's execution mark (`.gutter-highlight-active:before`'s
    ## `HIGHLIGHT_LINE_ARROW`), byte for byte.
  ExecutionMarkPx* = (w: 7, h: 9)
    ## Drawn at the gutter's size: the desktop paints it `0.47em` across in a
    ## ~14 px gutter row (`background-size: 0.47em`), keeping the SVG's
    ## 8 : 10.13 proportion.
  EditorCaretAttribute* = "data-ct-caret"
    ## PLAT-51: on the read-only editor's caret, `<line>:<column>`.
  EditorSelectionAttribute* = "data-ct-selection"
  FindMatchAttribute* = "data-ct-find-match"
    ## PLAT-70 Part C: a find highlight's band, `line:from-to` (1-based cell
    ## columns, `find_vm.FindMark`'s).
  FindCurrentAttribute* = "data-ct-find-current"
    ## On the current match's band.
  FindWidgetAttribute* = "data-ct-find-widget"
    ## The in-document find widget (its field, count and toggles).
    ## PLAT-68: on a selected span of an editor row,
    ## `<line>:<fromColumn>-<toColumn>` (1-based display columns, `to`
    ## exclusive).
  EditorSourceStatementAttribute* = "data-ct-source-statement"
    ## On the editor pane: which source it shows (`sourceStatement`, §2's
    ## Requirement), stated always.
  PointerMarkAttribute* = "data-ct-pointer-mark"
    ## On the pointer lane of the execution line: what the lane draws
    ## (`highlight_line_arrow.svg`), so a plan reader can tell the desktop's
    ## mark from a text glyph.
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

proc slotPath(leaf: GpuiLeaf): string =
  ## Where the leaf sits, as `<region>/<path…>` — or `top/<index>` for a pane
  ## of the window's own top strip, which the document gives no region
  ## (`GpuiLeaf.topStrip`).
  if leaf.topStrip:
    return "top/" & $leaf.slot.tabIndex
  var parts: seq[string] = @[$leaf.slot.region]
  for i in leaf.slot.path:
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

var executionMarkFile {.threadvar.}: string

const
  InlineValuesAttribute* = "data-ct-inline-values"
    ## On a row's inline values: `inlineValueText`'s spelling of them.
  InlineChipGround = DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark]
    ## `.ct-omni-value`'s ground (#1b1b1b).
  InlineMoreGround = DesignTokenHex[dtColorsUiSurfacePrimaryTertiary][dmDark]
    ## The "view more" button's (#333333).
  InlineNameColour = DesignTokenHex[dtColorsUiTextPrimaryLabelSubtle][dmDark]
    ## `.ct-omni-name` (#919191).
  InlineValueColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
    ## `.flow-parallel-value-box` (#f3f3f3, bold).
  InlineValueMaxCols = 30
  InlineChipCh = 10.18
    ## The flow container's `ch` (`flowLeftStyle`'s unit), measured.
    ## `ui/flow.nim`'s `max-width: 30ch` on a long value.
  FlowHideSvg = staticRead("../../../public/resources/shared/flow_hide_dark.svg")

var flowHideFile {.threadvar.}: string

proc flowHidePath(): string =
  if flowHideFile.len == 0 or not fileExists(flowHideFile):
    let dir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(dir)
    flowHideFile = dir / "flow-hide.svg"
    writeFile(flowHideFile, FlowHideSvg)
  flowHideFile

const FoldChevronSvg = """<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 16 16"><path fill="#c5c5c5" fill-rule="evenodd" clip-rule="evenodd" d="M7.976 10.072l4.357-4.357.62.618L8.284 11h-.618L3 6.333l.619-.618 4.357 4.357z"/></svg>"""
  ## Monaco's `codicon-folding-expanded` (the codicon chevron-down), in the
  ## colour the desktop draws it (#c5c5c5).

const
  StickyGround = "#2c2c2c"
    ## The sticky header's margin ground (`.sticky-widget-line-numbers`).

const StickyChevronSvg = FoldChevronSvg.replace("#c5c5c5", "#717171")
  ## The same chevron as a sticky header draws it: dimmed, its ink #717171
  ## (measured 2026-10-17).

var foldChevronFile {.threadvar.}: string
var stickyChevronFile {.threadvar.}: string

proc stickyChevronPath(): string =
  if stickyChevronFile.len == 0 or not fileExists(stickyChevronFile):
    let dir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(dir)
    stickyChevronFile = dir / "fold-sticky.svg"
    writeFile(stickyChevronFile, StickyChevronSvg)
  stickyChevronFile

proc foldChevronPath*(): string =
  ## The fold chevron written once to a file the shim's `img` can load.
  if foldChevronFile.len == 0 or not fileExists(foldChevronFile):
    let dir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(dir)
    foldChevronFile = dir / "fold-expanded.svg"
    writeFile(foldChevronFile, FoldChevronSvg)
  foldChevronFile

func indentOf(text: string): int =
  for c in text:
    if c == ' ': inc result
    elif c == '\t': result += 4
    else: return
  -1

func foldableRows*(rows: openArray[EditorRow]): seq[bool] =
  ## Which rows open an indented block — Monaco's indentation folding: a
  ## non-blank line whose next non-blank line is indented deeper.
  result = newSeq[bool](rows.len)
  for i in 0 ..< rows.len:
    if not rows[i].held: continue
    let own = indentOf(rows[i].text)
    if own < 0: continue
    for j in i + 1 ..< rows.len:
      if not rows[j].held: break
      let next = indentOf(rows[j].text)
      if next < 0: continue
      result[i] = next > own
      break

proc executionMarkPath*(): string =
  ## The desktop's mark written once to a file the shim's `img` can load.
  if executionMarkFile.len == 0 or not fileExists(executionMarkFile):
    let dir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
    createDir(dir)
    executionMarkFile = dir / "highlight_line_arrow.svg"
    writeFile(executionMarkFile, ExecutionMarkSvg)
  executionMarkFile

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
  ## measured: every gutter cell costs about one column of code, and
  ## `PLAT35-F3` (the editor clipped mid-token with no ellipsis) is what that
  ## width cost. A second gap cell would buy separation between `▶` and `●`,
  ## which differ in shape and now in colour, at the price of one more clipped
  ## column on every row of every frame.
  ##
  ## **THE TWO NUMBERS THIS PARAGRAPH USED TO CARRY WERE BOTH WRONG AND ARE
  ## CORRECTED HERE, 2026-10-03.** It said *"the GPUI editor pane is 276 px
  ## wide at 1440x900 and a Menlo cell is ~8 px"*. Measured on the frames and
  ## against `window_geometry` (see `EditorColumnPx` below for the method):
  ## the editor pane is 348 px (body) / 324 px (inner) at 1440x900, and the
  ## cell is 9.70 px. The CONCLUSION is unchanged — 324 / 9.70 is 33 columns,
  ## so one gutter cell is still about one column — which is why
  ## `PLAT35-F13` and `PLAT35-F14` are not reopened; their entries quote the
  ## old figures and the ledger's `gate.iteration5` says so.
  ##
  ## `PLAT35-F3` is now CLOSED, by a horizontal scrollbar rather than by a
  ## narrower gutter: the clipped columns are reachable, so the cell this gap
  ## costs is no longer a column of text nobody can see.
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

# ---------------------------------------------------------------------------
# `PLAT35-F3` — THE EDITOR'S HORIZONTAL SCROLLBAR
# ---------------------------------------------------------------------------
#
# **THE FINDING.** The editor clipped a source line mid-token at the pane's
# right edge with no ellipsis, no wrap and no horizontal scrollbar, so the
# rest of the statement was unrecoverable. Measured on this front-end's own
# captures: every row carried `nowrap; overflow: hidden` and no
# `text_overflow`, and no node anywhere was a scrollbar — 68 of 68
# role-bearing nodes at 1920x1080 and 54 of 54 at 1440x900.
#
# **THE REFERENCE IS ELECTRON, AND IT ALREADY HAS ONE.** The ledger attributed
# this to `PLAT35-PD1` and parked it as "one decision for both front-ends".
# That attribution is wrong, read off the spec:
# `Cross-Renderer-Visual-Alignment.md`'s `PLAT35-PD1` row is about *"the state
# and call-trace panes"* and says *"the value text has neither an ellipsis nor
# a horizontal scrollbar"* — not the editor. The same document's §4.1 reads
# the Electron EDITOR's own horizontal scrollbar off the live DOM at every
# probed run: *"the content height passes through — 2574 for the lines, 2586
# with the horizontal scrollbar, 2607 with the view zone"*, and *"it is not a
# race with the horizontal scrollbar — its 12px is in the content height of
# every probed run"*. So the Electron arm is correct here and this one simply
# did not match it; `tools/visual-review-brief.md` says what follows from
# that — *"the Electron front-end is the reference"*.
#
# No ellipsis and no wrap: the desktop editor has neither
# (`editing_core.terminalWrapSettings` turns soft wrap off in every editor
# this product ships), and inventing one here would be the divergence the
# brief forbids.
#
# **THE DIGEST DEBT THIS EDIT INCURS, named here as `GutterGap`'s header
# names iteration 4's.** Editing this file, `gpui/main.nim`,
# `gpui/window_geometry.nim`, `tests/test_cross_renderer_visual_alignment.nim`
# and `tests/test_plat48_gpui_plan.nim` moves the `*-control.sha256` of **TEN**
# mutation harnesses: the six that digest this file (plat20, plat22,
# plat35-visual, plat42-surface, plat47-parity, plat49-chrome) plus
# plat44-editing, plat45-layout, plat48-topbar AND **plat34-front-end**, which
# digest `main.nim`.
#
# **THE COUNT WAS NINE AND IS TEN, and the tenth is the same mistake one
# directory further out.** Iteration 4's count read only
# `src/frontend/gpui/tests/` and was corrected to six for this file; the first
# draft of this paragraph widened the scan to `src/frontend/tui/tests/` and
# still missed `src/frontend/viewmodel/tests/unit/`, where
# `plat34-front-end-mutation-control.sha256` carries `gpui/main.nim` — at the
# digest it had at `524acca27`, so this change is what moves it. Found at the
# adversarial review of 2026-10-03 by scanning EVERY `*-control.sha256` in the
# tree for the four edited paths rather than the directories somebody expected
# them in.
#
# All ten were run. **plat20 (14 of 14 KILLED) and plat44-editing (8 KILLED,
# 1 declared survivor, 0 arms not as required) grade on this host, were
# re-graded against the committed bytes and their digests are re-recorded in
# this change.** The other eight refuse, and their digests are deliberately
# LEFT STALE (§39: a digest re-recorded without a re-grade is an expectation
# re-recorded without one). The verdicts and the verbatim refusals are in
# `src/tests/visual/tier4-gpui-readings.json`'s `gate.iteration5digests`.
#
# **AND TWO ARMS WERE UNAIMED BY THIS EDIT AND ARE RE-AIMED**, because an arm
# whose needle no longer occurs cannot be killed: plat22's `E7` (the
# placeholder decision moved into `drawnCodeText`) and plat35-visual's `M1`
# (the row-append loop gained the scroll argument). Both needle scans caught
# them by name.

const
  EditorColumnPx* = 9.792
    ## SINCE 2026-10-17 THE DESIGN FACE'S OWN ADVANCE: Space Mono at 16 px,
    ## 612 / 1000 em (its one `hmtx` advance), which the desktop's
    ## spans measure too ("def" is 29 px). The history below is of 9.70, the
    ## advance measured off frames set in the platform's monospace.
    ## **ONE COLUMN OF THE EDITOR'S MONOSPACED FACE, IN PIXELS — MEASURED, not
    ## declared, and that distinction is `PLAT35-VG1`'s.**
    ##
    ## The shim in this workspace is built without `--features gpui-backend`,
    ## so nothing in this process can ask a text system how wide a glyph is
    ## (see `gpuiMetricFor`). The number below is therefore read off the
    ## FRAMES this front-end produces, the same way `window_geometry
    ## .GpuiEditorRowPx = 26` was read off the row pitch.
    ##
    ## **How, and on what.** All seven `build/plat35/gpui/*.png` captures of
    ## 2026-10-03, decoded, the editor pane located by its ground
    ## (`EditorGround`, `#282828`), every inked run on every text row
    ## collected, and the advance taken as the period that maximises the
    ## concentration of those run-start x positions modulo it (the circular
    ## resultant). A monospaced grid has a sharp maximum there and a
    ## proportional one has none. The seven answers:
    ##
    ##     shell 9.650  editor 9.670  gutterLanes 9.670  state 9.710
    ##     calltrace 9.720  editorWithMark 9.730  eventLog 9.735
    ##
    ## mean 9.698, spread 0.085 px (0.9%), 183–387 run starts per frame.
    ## 9.70 is that mean to the nearest hundredth. The same decoding returns
    ## the row pitch as 26 px on the same frames, which is `GpuiEditorRowPx`
    ## independently re-measured and is why the method is trusted here.
    ##
    ## **IT CORRECTS A NUMBER THIS FILE ALREADY CARRIED.** `GutterLaneGap`'s
    ## comment says *"the GPUI editor pane is 276 px wide at 1440x900 and a
    ## Menlo cell is ~8 px"*. Both halves are wrong on the frames: the editor
    ## pane is 346 px wide at 1440x900 (302..647) and the cell is 9.70 px.
    ## The conclusion that comment drew — one gutter cell costs about one
    ## column of code — survives the correction, so the gap stays at one.
  EditorScrollbarPx* = 12
    ## **THE SCROLLBAR'S THICKNESS, AND IT IS THE REFERENCE'S OWN NUMBER.**
    ##
    ## Monaco's `horizontalScrollbarSize` default, which the desktop editor
    ## takes because `ui/editor.nim`'s `createMonacoEditor` call for the main
    ## editor passes no `scrollbar` bag at all:
    ## `node_modules/monaco-editor/esm/vs/editor/common/config/editorOptions.js`
    ## line 1903, `horizontalScrollbarSize: 12`. It is the SAME 12 px
    ## `Cross-Renderer-Visual-Alignment.md` §4.1 measured in the Electron
    ## editor's content height (`2574` -> `2586`), which is two independent
    ## readings of one value and the reason this is not a guess.
    ##
    ## (The reference's stylesheet overrides the drawn slider to `0.875rem`
    ## in `styles/components/text_editor.styl`. That is the painted height,
    ## not the height Monaco RESERVES in layout; the reserved one is what a
    ## second front-end has to match to leave the same room, and it is the
    ## one the live DOM's arithmetic exposed.)
  EditorScrollbarMinThumbPx* = 20
    ## Monaco's `MINIMUM_SLIDER_SIZE`, quoted from
    ## `node_modules/monaco-editor/esm/vs/base/browser/ui/scrollbar/scrollbarState.js`
    ## line 8. Without it a file whose longest line is far past the pane draws
    ## a thumb a few pixels wide, which reads as no thumb.
  EditorScrollbarThumbColour* = "#79797966"
    ## Monaco's `scrollbarSlider.background` for a dark theme, quoted from
    ## `.../platform/theme/common/colors/miscColors.js`:
    ## `Color.fromHex('#797979').transparent(0.4)`. `0.4 * 255 = 102 = 0x66`,
    ## and the shim parses `#rrggbbaa` (`gpui_app.parse_color`), so the alpha
    ## is carried rather than pre-composited against a ground this element
    ## does not own.
    ##
    ## **NOT A DESIGN-SYSTEM TOKEN, and that is said rather than hidden.**
    ## `design_tokens.nim` publishes no scrollbar colour — `grep -ci croll`
    ## over `styles/generated/design_tokens.nim` answers 0 — and neither
    ## custom Monaco theme publishes one either: `codetracerDark.json` carries
    ## 46 entries under `colors` and `codetracerWhite.json` 10, and NONE of
    ## the 56 matches `croll`. (An earlier draft of this paragraph said those
    ## two files "carry no `colors` block". They both do; the true statement
    ## is the one above, and it is the one the conclusion needs. Corrected at
    ## the adversarial review of 2026-10-03, measured.) So the reference's own
    ## default is the only published value, and §3.1's "never a hex" rule is
    ## about the `data-ct-token` attribute, which this element deliberately
    ## does not claim to carry.
  EditorScrollbarThumbRadiusPx* = 3
    ## Both bars' thumbs are drawn with corners this round. Named (rather
    ## than a `"3px"` literal at each thumb) because the window's geometry
    ## reports it (`main.writeGeometry`): the rows a thumb's rounded ends
    ## leave partly uncovered are where a capture must not read the
    ## thumb-over-band colour (Scrollbar-Scrubbers.md §4.1, PLAT-47 B1).
  EditorScrollbarAttribute* = "data-ct-editor-scrollbar"
    ## **THE SCROLLBAR'S TRACK.** Present on exactly one node, and only on
    ## frames whose content is wider than the pane. Its value is the axis
    ## (`horizontal`) rather than `"true"`, so a vertical one can be added
    ## later without a reader of this one silently counting it.
  EditorScrollbarThumbAttribute* = "data-ct-editor-scrollbar-thumb"
  EditorScrollbarMarkAttribute* = "data-ct-editor-scrollbar-mark"
    ## PLAT-70: the caret's display column on the track (§4.2's mark).
  EditorScrollbarMarkPx* = 3
  EditorScrollbarMarkColour* = DesignTokenHex[dtColorsEditorActionSecondary][dmDark]
    ## The execution pointer's colour, as every scrubber's mark is drawn.
  EditorVScrollbarPx* = 14
    ## M73 (#840): THE VERTICAL SCRUBBER'S WIDTH — Monaco's
    ## `verticalScrollbarSize` default, beside the `horizontalScrollbarSize:
    ## 12` above in the same options bag (`editorOptions.js`). It lies over
    ## the editor's right edge, where the overview ruler's border is drawn, as
    ## Monaco's vertical slider lies over its overview ruler.
  EditorVScrollbarAttribute* = "data-ct-editor-vscrollbar"
    ## M73: the VERTICAL track — a node of its own rather than a second
    ## `EditorScrollbarAttribute` value, because every reader of that one
    ## counts it as THE editor's (horizontal) bar.
  EditorVScrollbarThumbAttribute* = "data-ct-editor-vscrollbar-thumb"
  EditorVScrollbarMarkAttribute* = "data-ct-editor-vscrollbar-mark"
    ## Its value is the execution line the mark stands for (§3.5).
  EditorVScrollMetricAttribute* = "data-ct-editor-vscroll"
    ## The vertical extent, stamped on the track as `EditorScrollMetricAttribute`
    ## stamps the horizontal one: `total`, `first`, `visible` (lines),
    ## `trackTop`, `trackPx`, `corner` (the horizontal bar's height it leaves
    ## free, 0 without one) and `paneH` (px).
  EditorScrollMetricAttribute* = "data-ct-editor-scroll"
    ## **WHAT THE EDITOR'S HORIZONTAL EXTENT ACTUALLY IS**, stamped on the
    ## editor's own node on EVERY frame — including the frames with no
    ## scrollbar, where it reads `content=<px>;viewport=<px>` with the content
    ## no wider. That is deliberate: a reader can tell "this pane has nothing
    ## to scroll" from "this pane was never asked" (`viewport=0`, the width
    ## no caller supplied), which is Verification-Harness-Traps §5a — two
    ## states behind one absence is the merge that makes a probe unfalsifiable.

type
  EditorHScroll* = object
    ## **The editor's horizontal extent, and the scrollbar that follows from
    ## it.** A value rather than a drawing, so the predicate "is there
    ## anything off the right-hand edge" is one function a suite can call with
    ## no renderer (`editorHScrollOf`), and the drawing below has no second
    ## opinion about it (§30).
    viewportPx*: int
      ## The editor pane's own INNER width — its box less its chrome padding.
      ## Zero means no caller supplied one; see `EditorScrollMetricAttribute`.
    contentPx*: int
      ## Gutter plus the widest drawn code line, at `EditorColumnPx`.
    gutterCols*: int
    codeCols*: int
    leftCols*: int
      ## How many code columns are scrolled off to the left. Clamped into
      ## `0 .. maxLeftCols`, so a caller cannot scroll past the end.
    maxLeftCols*: int
    present*: bool
      ## Whether a scrollbar is drawn at all. **False whenever the content
      ## fits**, which is Monaco's `horizontal: 'auto'` — the reference's own
      ## default, `editorOptions.js` line 1900 — and is the half of this that
      ## a bare existence check would not notice was missing.
    thumbPx*: int
    thumbLeftPx*: int
    view*: HorizontalView
      ## PLAT-70: the horizontal view the bar is drawn over (zero while the
      ## content fits) — what a press on the bar is handed back to.
    trackPx*: int
      ## M73: the bar's own length — `viewportPx`, less the vertical
      ## scrubber's width while that one is drawn too, so the corner cell is
      ## neither bar's (Scrollbar-Scrubbers.md §6). The thumb is measured on it.

  EditorVScroll* = object
    ## M73 (#840): the editor's VERTICAL scrubber — Scrollbar-Scrubbers.md §3
    ## over the WHOLE file's lines, as the terminal's source pane draws it
    ## (`views/source_pane.sourcePaneLayout`). A value, as `EditorHScroll` is,
    ## so the drawing and the window's hit-test (`main.editorVBarRect`) read
    ## one decision.
    present*: bool
      ## Only while the file has more lines than the editor shows (Monaco's
      ## `vertical: 'auto'`).
    model*: ScrubberModel
    trackTopPx*: int
    trackPx*: int
      ## The track's top inside the editor and its height.
    cornerPx*: int
      ## The horizontal bar's height the track stops short of (0 without it).
    paneHeightPx*: int
    thumbTopPx*: int
    thumbPx*: int
    markTopPx*: int
      ## The execution line's mark, -1 when the pointer is not in this file.

func columnsPx*(cols: int): int =
  ## `cols` columns of the editor's face, in whole pixels.
  int(round(float(cols) * EditorColumnPx))

func editorNumberWidth*(rows: openArray[EditorRow]): int =
  ## The gutter's number-field width for a surface: the widest DRAWN line
  ## number. `renderEditor`'s own derivation, lifted out of it so the window
  ## can ask for it without re-deriving it beside it (§30).
  result = 1
  for row in rows:
    result = max(result, len($row.line))

const
  EditorGutterPx* = 110
    ## The editor's left margin, the desktop's Monaco `line-numbers` box
    ## (measured 2026-10-17): the execution mark's lane (13 px), the line
    ## number right-aligned in 40, a 2 px gap, the diff lane (5), 2, the
    ## breakpoint lane (9), 2, the trace lane (10), and the fold chevron's
    ## lane to the end. The code starts here.
  GutterPointerPx* = 13
  GutterNumberPx* = 38
    ## Monaco's 40 less the 2 px its digits end short of the box: the last
    ## digit's ink ends 49 px into the margin (measured 2026-10-17), where
    ## this lane's right-aligned text ends with no bearing.
  GutterBreakpointX* = 62
    ## The breakpoint lane's left, from the margin's.
  GutterBreakpointPx* = 9
  GutterFoldX* = 84
    ## The fold chevron's box's left (`codicon-folding-expanded`, its ink
    ## 2.6 px into the 14 px box).
  StickyFoldX* = 56
    ## A sticky header's chevron's left: Monaco's sticky widget draws the
    ## fold icon right after its line-number box, its ink 60–67 px into the
    ## margin (measured 2026-10-17), and no number.
  GutterNumberSize* = "14px"
  GutterNumberWeight* = "300"

func editorGutterColumns*(numberWidth: int): int =
  ## How many columns the gutter occupies, **asked of `gutterRuns` rather
  ## than recomputed from `2 + 1 + numberWidth + 4`**: a second spelling of
  ## the geometry is a second chance to get it wrong, and the lanes have
  ## already moved once this week.
  gutterText(EditorRow(line: 1), numberWidth).runeLen

func drawnCodeText*(row: EditorRow): string =
  ## The text a row's CODE span actually draws — the source line, or the
  ## loading placeholder for a line the window does not hold yet. Not the
  ## inline value: that is a separate span, and it is the one thing in this
  ## subtree that already elides (`text-overflow: ellipsis`, below), so
  ## counting it as content the scrollbar promises to reveal would promise
  ## something the ellipsis has already given up.
  if row.held: row.text else: EditorLoadingText

func editorCodeColumns*(rows: openArray[EditorRow]): int =
  ## The widest drawn code line, in columns.
  for row in rows:
    result = max(result, drawnCodeText(row).runeLen)

func editorViewCols*(viewportPx: int): int =
  ## How many CODE columns an editor pane `viewportPx` wide shows: its width
  ## less the gutter (`EditorGutterPx`, which does not scroll, as the
  ## desktop's line-number margin does not), in whole columns of the face.
  let visibleCodePx = max(0, viewportPx - EditorGutterPx)
  int(floor(float(visibleCodePx) / EditorColumnPx))

func editorHScrollOf*(rows: openArray[EditorRow]; numberWidth: int;
                      viewportPx: int; leftCols = 0;
                      contentCols = -1; reservePx = 0): EditorHScroll =
  ## **THE WHOLE DECISION, IN ONE PLACE.** Given the rows as drawn, the
  ## gutter's width, the pane's inner width and — when the window holds the
  ## document — its exact content width (PLAT-70, Horizontal-Overflow.md
  ## §4.1: the widest line of the WHOLE document, `editing_core.contentCols`;
  ## the drawn rows' widest when no document is open): whether anything is
  ## off the right-hand edge, how far it can be scrolled, and the thumb that
  ## says so.
  ##
  ## **The bar is the shared scrubber model on the column axis** (§4.2,
  ## `horizontal_scroll.barModel`): the thumb is `viewportCols / contentCols`
  ## of the track, at least Monaco's 20 px (`EditorScrollbarMinThumbPx`), at
  ## `leftCol / contentCols` along it. It replaced Monaco's own slider
  ## formula here (PLAT35-F3), so every bar in the product — the list
  ## scrubbers, the terminal's eighth blocks, this one — is one arithmetic.
  ## `leftCols` is clamped by the model: to `0 .. maxLeftCols`, and the one
  ## column past it that only the caret's follow reaches.
  result.viewportPx = max(0, viewportPx)
  result.trackPx = max(0, result.viewportPx - max(0, reservePx))
  result.gutterCols = editorGutterColumns(numberWidth)
  result.codeCols = if contentCols >= 0: contentCols
                    else: editorCodeColumns(rows)
  result.contentPx = EditorGutterPx + columnsPx(result.codeCols)
  var view = HorizontalView(leftCol: max(0, leftCols),
                            contentCols: result.codeCols)
  # Nobody passing a width means NO SCROLLBAR, not a guessed one; neither
  # does a surface with no rows. (Content first, then the width: the view
  # is settled once, with both known.)
  view.setViewport(if rows.len == 0 or result.viewportPx <= 0: 0
                   else: editorViewCols(result.viewportPx))
  if not view.overflows:
    return
  result.present = true
  result.maxLeftCols = view.maxLeftCol
  result.leftCols = view.leftCol
  let span = view.barModel.thumbSpan(result.trackPx,
                                     EditorScrollbarMinThumbPx)
  result.thumbPx = span.length
  result.thumbLeftPx = span.start
  result.view = view

const EditorTopPadPx* = 4
  ## The editor's top inset at rest (`window_geometry.EditorPadTopPx`).
  ## Declared here (M73) because the vertical scrubber's track starts at it.

func editorVScrollOf*(surface: EditorSurface; paneHeightPx: int;
                      horizontalShown: bool): EditorVScroll =
  ## M73 (#840): the vertical scrubber of the editor drawing `surface` in a
  ## body `paneHeightPx` high — whether it is drawn, the track (from the
  ## editor's top inset down to the pane's bottom, less the horizontal bar's
  ## height while that one is drawn: the corner is neither's, §6), and the
  ## thumb and the mark the SHARED scrubber model puts on it
  ## (`scrollbar_scrubber`: `visible / total` long, at least Monaco's 20 px,
  ## `(first - 1) / total` along). The window it reads is `SourceVM`'s, as
  ## the surface carries it (`viewportTop`, the rows drawn, `totalLineCount`).
  let total = surface.totalLineCount
  let visible = min(surface.rows.len, max(0, total))
  result.paneHeightPx = max(0, paneHeightPx)
  result.markTopPx = -1
  if surface.report.len > 0 or total <= 0 or visible <= 0 or
     total <= visible or paneHeightPx <= 0:
    return
  result.cornerPx = if horizontalShown: EditorScrollbarPx else: 0
  result.trackTopPx = EditorTopPadPx
  result.trackPx = paneHeightPx - EditorTopPadPx - result.cornerPx
  if result.trackPx < EditorScrollbarMinThumbPx:
    return
  result.present = true
  result.model = scrubberModel(
    total, max(0, surface.viewportTop - 1), visible,
    (if surface.executionLine > 0: surface.executionLine - 1 else: -1))
  let span = result.model.thumbSpan(result.trackPx, EditorScrollbarMinThumbPx)
  result.thumbTopPx = span.start
  result.thumbPx = span.length
  let f = result.model.currentFraction
  if f >= 0.0:
    result.markTopPx = min(result.trackPx - EditorScrollbarMarkPx,
                           int(f * float(result.trackPx)))

func vscrollMetricText*(v: EditorVScroll): string =
  ## `EditorVScrollMetricAttribute`'s value.
  "total=" & $v.model.total & ";first=" & $(v.model.firstVisible + 1) &
  ";visible=" & $v.model.visible & ";trackTop=" & $v.trackTopPx &
  ";trackPx=" & $v.trackPx & ";corner=" & $v.cornerPx &
  ";paneH=" & $v.paneHeightPx

func scrollMetricText*(scroll: EditorHScroll): string =
  ## `EditorScrollMetricAttribute`'s value.
  "content=" & $scroll.contentPx & ";viewport=" & $scroll.viewportPx &
  ";gutterCols=" & $scroll.gutterCols & ";codeCols=" & $scroll.codeCols &
  ";leftCols=" & $scroll.leftCols & ";maxLeftCols=" & $scroll.maxLeftCols

func dropColumns*(text: string; skip: int): string =
  ## `text` with its first `skip` COLUMNS gone. Columns and not bytes: the
  ## face is monospaced, so a column is a rune, and a byte slice would cut a
  ## multi-byte glyph in half.
  if skip <= 0: return text
  let n = text.runeLen
  if skip >= n: "" else: text.runeSubstr(skip)

func dropColumns*(runs: seq[TokenRun]; skip: int): seq[TokenRun] =
  ## The same, over classified runs: the runs of a line concatenate to the
  ## line (`lexical.TokenRun`'s own contract), so dropping `skip` columns
  ## from the front of the line is dropping them from the front of the run
  ## sequence. A run emptied by the cut is DROPPED rather than kept empty —
  ## an empty span is a node with no ink and the censuses count nodes.
  if skip <= 0: return runs
  var left = skip
  for run in runs:
    let n = run.text.runeLen
    if left >= n:
      left -= n
    elif left == 0:
      result.add run
    else:
      result.add TokenRun(text: run.text.runeSubstr(left), class: run.class)
      left = 0

var editorPaneHeightPx* = 0
  ## The editor pane's body height, set by the window: where its overview
  ## ruler's marks go.

var editorScrollbarShown* = false
  ## Whether the editor's scrollbar is shown — the window sets it while the
  ## pointer is over the editor.

proc renderEditorScrollbar(r: GpuiRenderer; scroll: EditorHScroll;
                           caretMark = -1): GpuiElement =
  ## The track, and the thumb inside it at its offset.
  ##
  ## **THE TRACK IS NOT FILLED**, which is the reference's own look: Monaco's
  ## horizontal scrollbar paints a slider over the editor's ground and no
  ## track behind it. The track element still exists, carries the full width
  ## and is what `EditorScrollbarAttribute` marks, because the thing a reader
  ## has to be able to measure is the slider's share of the PANE and that
  ## needs both numbers present.
  ##
  ## The thumb is offset with `padding-left` on the track rather than a
  ## margin: `gpui_app.apply_styles_to_div` reads per-side padding and reads
  ## no per-side margin, so a `margin-left` here would be a style nothing
  ## draws — the defect `GutterGap`'s comment was corrected for.
  ##
  ## **IT IS AN OVERLAY AND NOT A ROW, AND THAT IS MEASURED RATHER THAN
  ## PREFERRED.** The first version appended it to the editor's flex column.
  ## On the 1920x1080 frames that worked; on all three 1440x900 frames the
  ## rows already fill the pane, so the bar landed past the bottom edge and
  ## the pane's own `overflow: hidden` ate it — `build/plat35/gpui/
  ## gutterLanes.png` showed exactly ONE scanline of it at y=851 against the
  ## twelve at 1920. The remedy is the reference's own structure rather than
  ## a taller pane or a row fewer: Monaco draws `.monaco-scrollable-element
  ## > .scrollbar.horizontal` ABSOLUTELY at the bottom of the editor, over
  ## the content, which is why its 12 px shows up in the content height and
  ## not in the line count. Reserving a row instead would have moved this
  ## front-end's `editor-row-count` on every scenario, which `corpus-pins
  ## .json` grades as a set.
  result = r.createElement("div")
  r.setAttribute(result, EditorScrollbarAttribute, "horizontal")
  # Monaco's scrollbars FADE: the slider is invisible at rest and shown while
  # the pointer is over the editor (`editorScrollbarShown`, which the window
  # sets) — so a frame of the desktop's editor at rest has none.
  r.setAttribute(result, "data-ct-scrollbar-visible", $editorScrollbarShown)
  r.setStyle(result, "display", "flex")
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left", $EditorPadSidePx & "px")
  r.setStyle(result, "bottom", "0px")
  r.setStyle(result, "width", $scroll.trackPx & "px")
  r.setStyle(result, "height", $EditorScrollbarPx & "px")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "padding-left", $scroll.thumbLeftPx & "px")
  let thumb = r.createElement("div")
  r.setAttribute(thumb, EditorScrollbarThumbAttribute, "true")
  r.setStyle(thumb, "width", $scroll.thumbPx & "px")
  r.setStyle(thumb, "height", $EditorScrollbarPx & "px")
  r.setStyle(thumb, "flex-shrink", "0")
  r.setStyle(thumb, "background-color", EditorScrollbarThumbColour)
  r.setStyle(thumb, "rounded", $EditorScrollbarThumbRadiusPx & "px")
  if not editorScrollbarShown:
    r.setStyle(thumb, "opacity", "0")
  r.appendChild(result, thumb)
  # PLAT-70 (Horizontal-Overflow.md §4.2): THE CARET'S COLUMN, marked on the
  # track as the vertical scrubber marks "now" — absolutely placed, so the
  # thumb's flow is untouched. It fades with the thumb.
  if caretMark >= 0:
    let f = scroll.view.barModel(caretMark).currentFraction
    if f >= 0.0:
      let mark = r.createElement("div")
      r.setAttribute(mark, EditorScrollbarMarkAttribute, $caretMark)
      r.setStyle(mark, "position", "absolute")
      r.setStyle(mark, "left", $min(scroll.trackPx - EditorScrollbarMarkPx,
                                    int(f * float(scroll.trackPx))) & "px")
      r.setStyle(mark, "top", "0px")
      r.setStyle(mark, "width", $EditorScrollbarMarkPx & "px")
      r.setStyle(mark, "height", $EditorScrollbarPx & "px")
      r.setStyle(mark, "background-color", EditorScrollbarMarkColour)
      if not editorScrollbarShown:
        r.setStyle(mark, "opacity", "0")
      r.appendChild(result, mark)

proc renderEditorVScrollbar(r: GpuiRenderer; v: EditorVScroll;
                            viewportPx: int): GpuiElement =
  ## M73 (#840): the vertical scrubber — the horizontal bar's drawing on the
  ## other axis (`renderEditorScrollbar`): an unfilled track ABSOLUTELY over
  ## the editor's right edge (Monaco's vertical slider over its overview
  ## ruler), the thumb inside it at its offset, the execution line marked in
  ## the pointer's colour (§3.5), all fading with the horizontal bar
  ## (`editorScrollbarShown`). Children are placed with `top` rather than a
  ## padding, as the horizontal bar's mark is.
  result = r.createElement("div")
  r.setAttribute(result, EditorVScrollbarAttribute, "vertical")
  r.setAttribute(result, EditorVScrollMetricAttribute, vscrollMetricText(v))
  r.setAttribute(result, "data-ct-scrollbar-visible", $editorScrollbarShown)
  r.setStyle(result, "position", "absolute")
  r.setStyle(result, "left",
             $(EditorPadSidePx + max(0, viewportPx - EditorVScrollbarPx)) & "px")
  r.setStyle(result, "top", $v.trackTopPx & "px")
  r.setStyle(result, "width", $EditorVScrollbarPx & "px")
  r.setStyle(result, "height", $v.trackPx & "px")
  let thumb = r.createElement("div")
  r.setAttribute(thumb, EditorVScrollbarThumbAttribute, "true")
  r.setStyle(thumb, "position", "absolute")
  r.setStyle(thumb, "left", "0px")
  r.setStyle(thumb, "top", $v.thumbTopPx & "px")
  r.setStyle(thumb, "width", $EditorVScrollbarPx & "px")
  r.setStyle(thumb, "height", $v.thumbPx & "px")
  r.setStyle(thumb, "background-color", EditorScrollbarThumbColour)
  r.setStyle(thumb, "rounded", $EditorScrollbarThumbRadiusPx & "px")
  if not editorScrollbarShown:
    r.setStyle(thumb, "opacity", "0")
  r.appendChild(result, thumb)
  if v.markTopPx >= 0:
    let mark = r.createElement("div")
    r.setAttribute(mark, EditorVScrollbarMarkAttribute,
                   $(v.model.current + 1))
    r.setStyle(mark, "position", "absolute")
    r.setStyle(mark, "left", "0px")
    r.setStyle(mark, "top", $v.markTopPx & "px")
    r.setStyle(mark, "width", $EditorVScrollbarPx & "px")
    r.setStyle(mark, "height", $EditorScrollbarMarkPx & "px")
    r.setStyle(mark, "background-color", EditorScrollbarMarkColour)
    if not editorScrollbarShown:
      r.setStyle(mark, "opacity", "0")
    r.appendChild(result, mark)

proc markRuns(runs: seq[TokenRun]; view: HorizontalView;
              width: int): seq[TokenRun] =
  ## PLAT-70 (Horizontal-Overflow.md §4.6): the runs of a row drawn from the
  ## view's left column, cut at its right edge, with `‹` / `›` replacing the
  ## first / last shown character when the line continues past that edge.
  let marks = overflowMarkers(width, view)
  var left = view.viewportCols
  for run in runs:
    if left <= 0: break
    let n = run.text.runeLen
    let take = min(n, left)
    result.add TokenRun(text: run.text.runeSubstr(0, take), class: run.class)
    left -= take
  if result.len == 0: return
  if marks.precedes:
    result[0].text = "‹" & result[0].text.runeSubstr(1)
  if marks.extends and left == 0:
    let t = result[^1].text
    result[^1].text = t.runeSubstr(0, t.runeLen - 1) & "›"

const
  BracketColours = ["#EAB308", "#8B5CF6", "#3B82F6"]
    ## `editorBracketHighlight.foreground1..3` of the desktop's Monaco theme
    ## (`codetracerDark.json`), which cycles them.
  BracketFreeClasses = {tcString, tcStringEscape, tcComment, tcCommentDoc,
                        tcRegexp}
  IndentUnitCols = 4
    ## One indentation level, the desktop editor's tab size.
  IndentGuideColour = "#4f4f4f"
    ## `editorIndentGuide` as it lands on the editor's ground (measured on the
    ## desktop, 2026-10-17: a function's body)…
  IndentGuideInBracketsColour = "#313131"
    ## …and inside an open bracket (the `OPERATIONS` table's rows).
  IndentGuideInsetPx = 3.0
    ## The guide sits 3 px into its column (measured: 502 for code at 499,
    ## 406 for code at 403).

func bracketDepths*(rows: openArray[EditorRow];
                    runs: openArray[seq[TokenRun]]): seq[int] =
  ## Each row's bracket nesting depth at its start, counted from the window's
  ## first row (brackets opened above the window are not known).
  var depth = 0
  for i in 0 ..< rows.len:
    result.add depth
    if i < runs.len:
      for run in runs[i]:
        if run.class in BracketFreeClasses: continue
        for ch in run.text:
          if ch in {'(', '[', '{'}: inc depth
          elif ch in {')', ']', '}'}: depth = max(0, depth - 1)

func indentGuides*(rows: openArray[EditorRow]): seq[int] =
  ## How many indent guides each row draws: its indentation levels, a blank
  ## line taking the smaller of its neighbours' (Monaco runs a block's guide
  ## through the blank lines inside it).
  var own = newSeq[int](rows.len)
  for i, row in rows:
    var n = 0
    var blank = true
    for c in row.text:
      if c == ' ': inc n
      elif c == '\t': n += IndentUnitCols
      else:
        blank = false
        break
    own[i] = if blank or not row.held: -1 else: n div IndentUnitCols
  result = newSeq[int](rows.len)
  for i in 0 ..< rows.len:
    if own[i] >= 0:
      result[i] = own[i]
    else:
      var above, below = 0
      for j in countdown(i - 1, 0):
        if own[j] >= 0: above = own[j]; break
      for j in i + 1 ..< rows.len:
        if own[j] >= 0: below = own[j]; break
      result[i] = min(above, below)

proc renderEditorRow(r: GpuiRenderer; row: EditorRow; runs: seq[TokenRun];
                     numberWidth = 1; skipCols = 0;
                     caretColumn = 0;
                     selected: openArray[tuple[fromColumn, toColumn: int]] = [];
                     findMarks: openArray[tuple[fromColumn, toColumn: int;
                                                current: bool]] = [];
                     foldable = false; bracketDepth = 0;
                     guides = 0; stickyHeader = false;
                     markersView = HorizontalView()):
                     GpuiElement =
  ## One row of the source editor. `stickyHeader`: drawn as Monaco's sticky
  ## widget draws a scope's first line — no number, a dim chevron after the
  ## number's box, the margin on the sticky ground.
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
  # Monaco's line (`chrome.EditorLinePx`: 24 px on macOS, 22 px elsewhere,
  # derived by `chrome.monacoLineHeightPx`), its text in the line box's
  # middle.
  r.setStyle(el, "height", $EditorLinePx & "px")
  r.setStyle(el, "line-height", $EditorLinePx & "px")

  # A `div`, as its lanes are: the shim draws a `span` as a text container,
  # which does not hold its children to the widths the lanes are given.
  let gutter = r.createElement("div")
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
  # 2026-10-17: THE DESKTOP'S MARGIN, lane by lane at its measured offsets
  # (`EditorGutterPx`): the execution mark at the left edge, the number
  # right-aligned in its 40 px in the gutter face (14 px, light), the
  # breakpoint lane right of the number, the trace lane beside it, and the
  # fold chevron before the code. The three runs keep their attributes
  # (`GutterLaneAttribute`), so a reader of the plan reads the same lanes.
  r.setStyle(gutter, "display", "flex")
  r.setStyle(gutter, "flex-shrink", "0")
  r.setStyle(gutter, "width", $EditorGutterPx & "px")
  r.setStyle(gutter, "height", $EditorLinePx & "px")
  r.setStyle(gutter, "items", "center")
  r.setStyle(gutter, "font-size", GutterNumberSize)
  r.setStyle(gutter, "font-weight", GutterNumberWeight)
  # The line numbers are Monaco's: resting, and active on the execution line.
  r.setStyle(gutter, "color",
             if row.pointer == eptExecution: EditorActiveLineNumberColour
             else: EditorLineNumberColour)
  let runs3 = gutterRuns(row, numberWidth)
  # The desktop's order: the mark's lane is right of the number.
  for run in [runs3[0], runs3[2], runs3[1]]:
    let lane = r.createElement("div")
    r.setAttribute(lane, GutterLaneAttribute, $run.kind)
    r.setStyle(lane, "color", run.colour)
    r.setStyle(lane, "flex-shrink", "0")
    r.setStyle(lane, "display", "flex")
    r.setStyle(lane, "items", "center")
    r.setStyle(lane, "height", $EditorLinePx & "px")
    case run.kind
    of grkPointer:
      r.setStyle(lane, "width", $GutterPointerPx & "px")
      if row.pointer == eptExecution:
        # PLAT-51: THE DESKTOP'S MARK, drawn — not a glyph that approximates
        # it (`.gutter-highlight-active:before`, at the margin's left edge).
        r.setAttribute(lane, PointerMarkAttribute, "highlight_line_arrow.svg")
        let mark = r.createElement("img")
        r.setAttribute(mark, "src", executionMarkPath())
        r.setStyle(mark, "width", $ExecutionMarkPx.w & "px")
        r.setStyle(mark, "height", $ExecutionMarkPx.h & "px")
        r.setStyle(mark, "flex-shrink", "0")
        r.appendChild(lane, mark)
      elif row.pointer != eptNone:
        r.appendChild(lane, r.createTextNode(run.text))
    of grkNumber:
      r.setStyle(lane, "width", $GutterNumberPx & "px")
      r.setStyle(lane, "justify", "end")
      if not stickyHeader:
        r.appendChild(lane, r.createTextNode($row.line))
    of grkMark:
      # Right of the number: the breakpoint lane, or the trace lane beside
      # it — a disc in the mark's colour (`.gutter-breakpoint-enabled`,
      # 1.1ch; `.gutter-trace`, 1.2ch).
      let lead = GutterBreakpointX - GutterPointerPx - GutterNumberPx +
                 (if row.mark == emTracepoint: 11 else: 0)
      # Held to the fold lane's left, so the chevron after it is at
      # `GutterFoldX` whatever the lane holds.
      r.setStyle(lane, "width",
                 $(GutterFoldX - GutterPointerPx - GutterNumberPx - lead) & "px")
      r.setStyle(lane, "padding-left", $lead & "px")
      if row.mark != emNone:
        let side = if row.mark == emTracepoint: 10 else: GutterBreakpointPx
        let disc = r.createElement("div")
        r.setAttribute(disc, "data-ct-mark-glyph", run.text)
        r.setStyle(disc, "width", $side & "px")
        r.setStyle(disc, "height", $side & "px")
        r.setStyle(disc, "rounded", $(side div 2 + 1) & "px")
        r.setStyle(disc, "background-color", run.colour)
        r.setStyle(disc, "flex-shrink", "0")
        r.appendChild(lane, disc)
    r.appendChild(gutter, lane)
  if stickyHeader:
    r.setStyle(gutter, "position", "relative")
    r.setStyle(gutter, "background-color", StickyGround)
    let holder = r.createElement("div")
    r.setStyle(holder, "position", "absolute")
    r.setStyle(holder, "left", $StickyFoldX & "px")
    r.setStyle(holder, "top", "6px")
    r.setStyle(holder, "width", "14px")
    r.setStyle(holder, "height", "14px")
    let chevron = r.createElement("img")
    r.setAttribute(chevron, "data-ct-fold", "sticky")
    r.setAttribute(chevron, "src", stickyChevronPath())
    r.setStyle(chevron, "width", "14px")
    r.setStyle(chevron, "height", "14px")
    r.appendChild(holder, chevron)
    r.appendChild(gutter, holder)
  elif foldable:
    # Monaco's fold chevron (`.codicon-folding-expanded`), always shown on a
    # line that opens an indented block (`alwaysShowFoldIcons`): 14 px,
    # placed so its ink is 86–94 px into the margin and 8–12 px down the row
    # as the desktop's glyph is (measured 2026-10-17) — absolutely, as the
    # lanes' flow does not put it there.
    r.setStyle(gutter, "position", "relative")
    let holder = r.createElement("div")
    r.setStyle(holder, "position", "absolute")
    r.setStyle(holder, "left", $GutterFoldX & "px")
    r.setStyle(holder, "top", "3px")
    r.setStyle(holder, "width", "14px")
    r.setStyle(holder, "height", "14px")
    let chevron = r.createElement("img")
    r.setAttribute(chevron, "data-ct-fold", "expanded")
    r.setAttribute(chevron, "src", foldChevronPath())
    r.setStyle(chevron, "width", "14px")
    r.setStyle(chevron, "height", "14px")
    r.appendChild(holder, chevron)
    r.appendChild(gutter, holder)
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
  for span in selected:
    # PLAT-68: THE SELECTION, Monaco's `editor.selectionBackground`
    # (`editor-theme/selection`) behind the text — before the caret, which is
    # drawn over it.
    let fromCol = max(span.fromColumn, skipCols + 1)
    if span.toColumn <= fromCol: continue
    r.setStyle(column, "position", "relative")
    let band = r.createElement("div")
    r.setAttribute(band, EditorSelectionAttribute,
                   $row.line & ":" & $span.fromColumn & "-" & $span.toColumn)
    r.setStyle(band, "position", "absolute")
    r.setStyle(band, "left", formatFloat(float(fromCol - 1 - skipCols) *
                                         EditorColumnPx, ffDecimal, 1) & "px")
    r.setStyle(band, "top", "0px")
    r.setStyle(band, "width", formatFloat(float(span.toColumn - fromCol) *
                                          EditorColumnPx, ffDecimal, 1) & "px")
    r.setStyle(band, "height", "100%")
    r.setStyle(band, "background", EditorSelectionColour)
    r.appendChild(column, band)
  for m in findMarks:
    # PLAT-70 Part C: THE FIND HIGHLIGHTS (Find-And-Incremental-Search.md
    # §3.3 step 4), Monaco's `editor.findMatchHighlightBackground` for every
    # match and `editor.findMatchBackground` for the current one — over the
    # selection (the current match is the selection), under the caret.
    let fromCol = max(m.fromColumn, skipCols + 1)
    if m.toColumn <= fromCol: continue
    r.setStyle(column, "position", "relative")
    let band = r.createElement("div")
    r.setAttribute(band, FindMatchAttribute,
                   $row.line & ":" & $m.fromColumn & "-" & $m.toColumn)
    if m.current: r.setAttribute(band, FindCurrentAttribute, "true")
    r.setStyle(band, "position", "absolute")
    r.setStyle(band, "left", formatFloat(float(fromCol - 1 - skipCols) *
                                         EditorColumnPx, ffDecimal, 1) & "px")
    r.setStyle(band, "top", "0px")
    r.setStyle(band, "width", formatFloat(float(m.toColumn - fromCol) *
                                          EditorColumnPx, ffDecimal, 1) & "px")
    r.setStyle(band, "height", "100%")
    r.setStyle(band, "background", (if m.current: FindMatchCurrentColour
                                    else: FindMatchColour))
    r.appendChild(column, band)
  if caretColumn > 0 and caretColumn > skipCols:
    # PLAT-51: THE CARET of the read-only debugging editor — a thin bar
    # before its column, in the editor's foreground (Monaco's cursor),
    # distinct from the execution band and from the inspection pointer.
    r.setStyle(column, "position", "relative")
    let caret = r.createElement("div")
    r.setAttribute(caret, EditorCaretAttribute, $row.line & ":" & $caretColumn)
    r.setStyle(caret, "position", "absolute")
    r.setStyle(caret, "left", formatFloat(float(caretColumn - 1 - skipCols) *
                                          EditorColumnPx, ffDecimal, 1) & "px")
    r.setStyle(caret, "top", "0px")
    r.setStyle(caret, "width", "2px")
    r.setStyle(caret, "height", "100%")
    r.setStyle(caret, "background", EditorTextColour)
    r.appendChild(column, caret)

  if guides > 0:
    # Monaco's indent guides (`editorIndentGuide`): a 1 px line at the start
    # of each indentation level the line sits inside.
    r.setStyle(column, "position", "relative")
    for level in 0 ..< guides:
      let x = float(level * IndentUnitCols - skipCols) * EditorColumnPx
      if x < 0: continue
      let g = r.createElement("div")
      r.setAttribute(g, "data-ct-indent-guide", $level)
      r.setStyle(g, "position", "absolute")
      r.setStyle(g, "left", formatFloat(x + IndentGuideInsetPx, ffDecimal, 1) & "px")
      r.setStyle(g, "top", "0px")
      r.setStyle(g, "width", "1px")
      r.setStyle(g, "height", "100%")
      r.setStyle(g, "background", if bracketDepth > 0: IndentGuideInBracketsColour
                                  else: IndentGuideColour)
      r.appendChild(column, g)
  let code = r.createElement("span")
  r.setAttribute(code, TextRoleAttribute, $trEditorCode)
  r.setAttribute(code, TextMetricAttribute, gpuiMetricFor(trEditorCode))
  r.setAttribute(code, TokenAttribute, gpuiTokenFor(trEditorCode, row))
  r.setStyle(code, "display", "flex")
  # `skipCols` IS THE HORIZONTAL SCROLL, and it is applied to the CODE and
  # not to the row: the gutter does not move, exactly as the desktop editor's
  # line-number margin does not. Zero on every frame nobody has scrolled, so
  # the drawn tree is byte-identical to the one before `PLAT35-F3` until the
  # wheel is turned.
  # PLAT-70: with the overflow markers on (Horizontal-Overflow.md §4.6) the
  # shown runs are cut at the view's right edge and carry `‹` / `›`.
  let markers = markersView.viewportCols > 0 and row.held
  if row.held and (runs.len > 0 or markers):
    # ONE TEXT ELEMENT FOR THE WHOLE ROW, not one per span. The loop below
    # emits a span per token run and a further one per bracket character,
    # and the renderer would otherwise round each one's width up to a whole
    # logical pixel and start the next from the inflated running total. The
    # attribute asks it to fuse them and round once, as Monaco's inline
    # layout does; the spans, their classes and their colours are unchanged,
    # and so is the render plan a test reads.
    r.setAttribute(code, InlineTextRunsAttribute, "1")
    let shownRuns =
      if not markers: dropColumns(runs, skipCols)
      else: markRuns(dropColumns(
              (if runs.len > 0: runs
               else: @[TokenRun(text: row.text, class: tcPlain)]), skipCols),
              markersView, row.text.runeLen)
    # Monaco's bracket-pair colours (`editorBracketHighlight.foreground1..3`,
    # by nesting depth from the window's first row), outside strings and
    # comments; every other character keeps its class's colour.
    var depth = bracketDepth
    for run in shownRuns:
      var pending = ""
      proc flush(r: GpuiRenderer; cls: TokenClass) =
        if pending.len == 0: return
        let piece = r.createElement("span")
        r.setAttribute(piece, EditorTokenClassAttribute, $cls)
        r.setStyle(piece, "color", tokenColour(cls))
        r.setStyle(piece, "flex-shrink", "0")
        r.appendChild(piece, r.createTextNode(pending))
        r.appendChild(code, piece)
        pending = ""
      if run.class in BracketFreeClasses:
        pending = run.text
        flush(r, run.class)
        continue
      for ch in run.text:
        if ch in {'(', '[', '{', ')', ']', '}'}:
          flush(r, run.class)
          if ch in {')', ']', '}'}: depth = max(0, depth - 1)
          let piece = r.createElement("span")
          r.setAttribute(piece, EditorTokenClassAttribute, "bracket")
          r.setStyle(piece, "color", BracketColours[depth mod BracketColours.len])
          r.setStyle(piece, "flex-shrink", "0")
          r.appendChild(piece, r.createTextNode($ch))
          r.appendChild(code, piece)
          if ch in {'(', '[', '{'}: inc depth
        else:
          pending.add ch
      flush(r, run.class)
  else:
    r.setStyle(code, "color", tokenColour(tcPlain))
    r.appendChild(code,
      r.createTextNode(dropColumns(drawnCodeText(row), skipCols)))
  # THE FLOW OVERLAY, DRAWN AS THE DESKTOP EDITOR DRAWS IT: a line inside an
  # arm the run declined is dimmed to half opacity (`.line-flow-skip` in
  # `styles/components/flow.styl`), and a line that ran is left as it is
  # (`.line-flow-hit` is `opacity: 1`). `efsUnknown` claims nothing and so
  # changes nothing. The decision is `flowStateOf`'s; this only paints it.
  if row.flow == efsNotTaken:
    r.setStyle(code, "opacity", FlowNotTakenOpacity)
  r.setStyle(code, "flex-shrink", "0")
  r.appendChild(column, code)

  # THE INLINE VALUES, AS THE DESKTOP'S FLOW DRAWS THEM (`ui/flow.nim`,
  # `components/flow.styl`; measured 2026-10-17): 18 px after the code, one
  # chip per value on the bar's ground — the name in the subdued label tier,
  # the value bold in the body tier, a long value clipped at 30ch with an
  # ellipsis and given the "view more" button before its name. The string
  # `inlineValueText` spells stays on the row's element for a plan reader.
  let annotation = inlineValueText(row.values)
  if annotation.len > 0:
    let ann = r.createElement("div")
    r.setAttribute(ann, TextRoleAttribute, $trValueText)
    r.setAttribute(ann, TextMetricAttribute, gpuiMetricFor(trValueText))
    r.setAttribute(ann, TokenAttribute, gpuiTokenFor(trValueText, row))
    r.setAttribute(ann, InlineValuesAttribute, annotation)
    r.setStyle(ann, "display", "flex")
    r.setStyle(ann, "items", "center")
    r.setStyle(ann, "gap", "7px")
    # AT `calc(<line length>ch + 1ch)` FROM THE CODE'S LEFT, as `ui/flow.nim`'s
    # `flowLeftStyle` places it — in the flow container's `ch`, not the
    # code's advance: 10.18 px, which every chip of the six reference states
    # sits at to the pixel (measured 2026-10-17) — and 2 px down the row.
    r.setStyle(column, "position", "relative")
    r.setStyle(ann, "position", "absolute")
    r.setStyle(ann, "left", $(int(round(float(row.text.runeLen + 1) *
                                       InlineChipCh -
                                       float(skipCols) * EditorColumnPx))) & "px")
    r.setStyle(ann, "top", "2px")
    r.setStyle(ann, "font-size", "14px")
    r.setStyle(ann, "flex-shrink", "0")
    for v in row.values:
      let chip = r.createElement("div")
      # EACH CHIP IS A ONE-LINE INLINE FORMATTING CONTEXT, so its name and
      # its value are drawn as ONE text run and rounded once. Drawn as two
      # text elements they rounded twice, once per span, and a row of chips
      # accumulated the residue (the chip rows were the editor rows still
      # drifting from the desktop after the code itself was fused). The 7 px
      # between name and value is the value's own `padding-left`, and the
      # renderer keeps it exactly: a span's horizontal padding fuses as an
      # inset only in a context that declares `white-space: nowrap` and no
      # `text-overflow` (the renderer's `inlineTextRunsAttribute` rule),
      # which is why `nowrap` is declared HERE, on the chip, and not on the
      # value. White-space is inherited by the text inside, so the value is
      # still drawn on one line; a value that set it itself would no longer
      # be plain text and would keep its own element. The "view more" box
      # is a sized box and keeps its own element in front of the run.
      r.setAttribute(chip, InlineTextRunsAttribute, "1")
      r.setStyle(chip, "white-space", "nowrap")
      r.setStyle(chip, "display", "flex")
      r.setStyle(chip, "items", "center")
      r.setStyle(chip, "flex-shrink", "0")
      r.setStyle(chip, "height", "18px")
      r.setStyle(chip, "line-height", "18px")
      r.setStyle(chip, "background-color", InlineChipGround)
      r.setStyle(chip, "rounded", "4px")
      r.setStyle(chip, "padding-left", "7px")
      r.setStyle(chip, "padding-right", "7px")
      # The desktop gives a value its "view more" button when the value is
      # long — longer than the chip shows, or already elided by the presenter.
      let long = v.value.runeLen >= InlineValueMaxCols or v.value.endsWith("…")
      if long:
        let more = r.createElement("div")
        r.setAttribute(more, "data-ct-inline-more", v.name)
        r.setStyle(more, "width", "30px")
        r.setStyle(more, "height", "18px")
        r.setStyle(more, "flex-shrink", "0")
        r.setStyle(more, "display", "flex")
        r.setStyle(more, "items", "center")
        r.setStyle(more, "justify", "center")
        r.setStyle(more, "background-color", InlineMoreGround)
        r.setStyle(more, "border-top-left-radius", "4px")
        r.setStyle(more, "border-bottom-left-radius", "4px")
        let eye = r.createElement("img")
        r.setAttribute(eye, "src", flowHidePath())
        r.setStyle(eye, "width", "14px")
        r.setStyle(eye, "height", "14px")
        r.appendChild(more, eye)
        r.appendChild(chip, more)
      let name = r.createElement("div")
      # An event's chip (`<stdout>`, `flowEventValue`) names it in the
      # desktop's `.ct-omni-name-std` cyan.
      r.setStyle(name, "color",
                 if v.name.startsWith("<") and v.name.endsWith(">"): "#67e8f9"
                 else: InlineNameColour)
      r.setStyle(name, "flex-shrink", "0")
      r.appendChild(name, r.createTextNode(v.name))
      r.appendChild(chip, name)
      let value = r.createElement("div")
      r.setStyle(value, "color", InlineValueColour)
      r.setStyle(value, "font-weight", "600")
      r.setStyle(value, "padding-left", "7px")
      r.setStyle(value, "flex-shrink", "0")
      r.appendChild(value, r.createTextNode(
        if long: v.value.runeSubstr(0, InlineValueMaxCols - 1) & "…"
        else: v.value))
      r.appendChild(chip, value)
      r.appendChild(ann, chip)
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

func stickyScopeLines*(lines: openArray[string]; firstRow, offset: int;
                       maxLines = 5): seq[tuple[line, top: int]] =
  ## **MONACO'S STICKY SCROLL** (`editor.stickyScroll`, on by default in the
  ## desktop's editor): the first lines of the indentation scopes around the
  ## line under the headers already pinned, outermost first, each answered
  ## with the y (from the viewport's top) it is drawn at. The view's first
  ## whole row is `firstRow`, drawn `offset` px down. At each step the line
  ## at the stack's foot is asked for the next deeper scope around it — one
  ## starting at that very line counts, its header being hidden under the
  ## stack — and a header is pushed up as its scope's last line rises under
  ## it (Monaco's `StickyScrollController`). Its scopes are its indentation
  ## folds, which read no strings: an indented run inside a docstring is a
  ## scope too. `file` is the whole text.
  let file = @lines
  func indent(s: string): int =
    for c in s:
      if c == ' ': inc result
      elif c == '\t': result += 4
      else: return
    -1
  func scopeEnd(start: int): int =
    let own = indent(file[start - 1])
    result = start
    for j in start + 1 .. file.len:
      let n = indent(file[j - 1])
      if n < 0: continue
      if n <= own: break
      result = j
  func opens(j: int): bool =
    j >= 1 and j <= file.len and indent(file[j - 1]) >= 0 and
      scopeEnd(j) > j
  func lineAtY(y: int): int =
    firstRow + int(floor(float(y - offset) / float(EditorLinePx)))
  func lineTop(line: int): int = (line - firstRow) * EditorLinePx + offset
  var deepest = -1
    ## The indentation of the last header pinned.
  while result.len < maxLines:
    let natural = result.len * EditorLinePx
    let under = lineAtY(natural)
    if under < 1 or under > file.len: break
    # The scopes around `under`, innermost first (one starting at it too).
    var around: seq[int] = @[]
    var limit = high(int)
    if opens(under):
      around.add under
      limit = indent(file[under - 1])
    else:
      var probe = under
      while probe >= 1 and indent(file[probe - 1]) < 0: dec probe
      if probe >= 1: limit = indent(file[probe - 1])
      if probe >= 1 and opens(probe) and probe == under: around.add probe
    for j in countdown(under - 1, 1):
      let n = indent(file[j - 1])
      if n < 0 or n >= limit: continue
      if opens(j) and scopeEnd(j) >= under:
        around.add j
        limit = n
      if n == 0: break
    # The outermost of them deeper than what is pinned.
    var next = -1
    for k in countdown(around.high, 0):
      if indent(file[around[k] - 1]) > deepest:
        next = around[k]
        break
    if next < 0: break
    let last = scopeEnd(next)
    if last < under: break
    let top = min(natural, lineTop(last + 1) - EditorLinePx)
    if top + EditorLinePx <= 0: break
    result.add (next, top)
    deepest = indent(file[next - 1])

proc stateIconPath(name, svg, ink: string): string
  ## Forward-declared: an icon written once in `ink` (defined with the state
  ## pane's controls).

const
  LoopZonePx* = 21
    ## The flow's loop control above a loop's first line (`flow-view-zone`,
    ## a Monaco view zone 21 px high).

type
  LoopZone* = object
    ## One loop's control: drawn above `line`, saying `iteration` of `count`.
    line*: int
    iteration*: int
    count*: int

var editorLoopZones*: seq[LoopZone] = @[]
  ## The loop controls the editor draws, set by the window from the flow
  ## (`main.loopZonesOf`) and read by its row hit-test too.

proc zonesAbove*(line: int): int =
  ## How many loop zones are drawn above `line` in the editor's window.
  for z in editorLoopZones:
    if z.line <= line: inc result

const
  LoopBackSvg = staticRead("../../../public/resources/shared/omniscience_backward_dark.svg")
  LoopForwardSvg = staticRead("../../../public/resources/shared/omniscience_forward_dark.svg")
    ## The loop control's arrows (`ct-images-omni-backward`/`-forward`).

proc loopZoneElement(r: GpuiRenderer; z: LoopZone): GpuiElement =
  ## The desktop's loop control (`ui/flow.nim`'s `makeLoopLine`, measured
  ## 2026-10-17) at the code's column: the backward button, the
  ## `iteration [N] from M` chip — M the last iteration's index — the forward
  ## button, and — past the first iteration — the iteration slider
  ## (`.flow-loop-slider`).
  let last = max(0, z.count - 1)
  result = r.createElement("div")
  r.setAttribute(result, "data-ct-loop-zone", $z.line)
  r.setStyle(result, "display", "flex")
  r.setStyle(result, "items", "center")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "height", $LoopZonePx & "px")
  r.setStyle(result, "padding-left", $EditorGutterPx & "px")
  r.setStyle(result, "font-family", WindowFontFamily)
  r.setStyle(result, "font-size", "14px")
  proc button(r: GpuiRenderer; name, svg: string; enabled: bool): GpuiElement =
    result = r.createElement("div")
    r.setStyle(result, "display", "flex")
    r.setStyle(result, "items", "center")
    r.setStyle(result, "justify", "center")
    r.setStyle(result, "flex-shrink", "0")
    r.setStyle(result, "width", "21px")
    r.setStyle(result, "height", "21px")
    r.setStyle(result, "rounded", "6px")
    r.setStyle(result, "border-width", "1px")
    r.setStyle(result, "border-color", DesignTokenHex[dtColorsUiBorderSecondary][dmDark])
    r.setStyle(result, "background-color", DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark])
    # `.flow-loop-button`: its arrow 6 x 12 px, the whole button at half
    # opacity when it cannot move (measured 2026-10-17).
    let icon = r.createElement("img")
    r.setAttribute(icon, "src", stateIconPath(name, svg, "#f3f3f3"))
    r.setStyle(icon, "width", "12px")
    r.setStyle(icon, "height", "12px")
    r.appendChild(result, icon)
    if not enabled:
      r.setStyle(result, "opacity", "0.5")
  r.appendChild(result, button(r, "loop-back", LoopBackSvg, z.iteration > 0))
  let chip = r.createElement("div")
  r.setStyle(chip, "display", "flex")
  r.setStyle(chip, "items", "center")
  r.setStyle(chip, "flex-shrink", "0")
  r.setStyle(chip, "height", "18px")
  r.setStyle(chip, "margin-left", "11px")
  r.setStyle(chip, "margin-right", "11px")
  r.setStyle(chip, "padding-left", "4px")
  r.setStyle(chip, "padding-right", "4px")
  r.setStyle(chip, "rounded", "4px")
  r.setStyle(chip, "border-width", "1px")
  r.setStyle(chip, "border-color", DesignTokenHex[dtColorsUiBorderPrimary][dmDark])
  r.setStyle(chip, "background-color", DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark])
  r.setStyle(chip, "color", EditorTextColour)
  r.appendChild(chip, r.createTextNode("iteration "))
  let n = r.createElement("div")
  r.setStyle(n, "display", "flex")
  r.setStyle(n, "items", "center")
  r.setStyle(n, "height", "16px")
  r.setStyle(n, "width", "18px")
  r.setStyle(n, "padding-left", "4px")
  r.setStyle(n, "background-color", DesignTokenHex[dtColorsUiSurfacePrimaryTertiary][dmDark])
  r.setStyle(n, "color", DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
  # `.flow-loop-textarea`: the field at 0.7 opacity, its digit regular.
  r.setStyle(n, "opacity", "0.7")
  r.setStyle(n, "font-weight", "400")
  r.appendChild(n, r.createTextNode($z.iteration))
  r.appendChild(chip, n)
  r.appendChild(chip, r.createTextNode(" from " & $last))
  r.appendChild(result, chip)
  r.appendChild(result, button(r, "loop-forward", LoopForwardSvg, z.iteration < last))
  if z.iteration <= 0:
    # At the first iteration the desktop draws no slider (measured
    # 2026-10-17: none after `stepIn=21,stepOut=1`, one at the last).
    return
  # The slider: a 101 px track, filled to the iteration, its handle at the end.
  let track = r.createElement("div")
  r.setAttribute(track, "data-ct-loop-slider", $z.iteration)
  r.setStyle(track, "display", "flex")
  r.setStyle(track, "items", "center")
  r.setStyle(track, "flex-shrink", "0")
  r.setStyle(track, "margin-left", "21px")
  r.setStyle(track, "width", "105px")
  r.setStyle(track, "height", "14px")
  let fillPx = if last > 0: int(round(101.0 * float(z.iteration) / float(last))) else: 0
  let filled = r.createElement("div")
  r.setStyle(filled, "flex-shrink", "0")
  r.setStyle(filled, "width", $fillPx & "px")
  r.setStyle(filled, "height", "2px")
  r.setStyle(filled, "background-color", "#818cf8")
  r.appendChild(track, filled)
  let handle = r.createElement("div")
  r.setStyle(handle, "flex-shrink", "0")
  r.setStyle(handle, "width", "4px")
  r.setStyle(handle, "height", "14px")
  r.setStyle(handle, "rounded", "2px")
  r.setStyle(handle, "background-color", DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
  r.appendChild(track, handle)
  let rest = r.createElement("div")
  r.setStyle(rest, "flex-shrink", "0")
  r.setStyle(rest, "width", $(101 - fillPx) & "px")
  r.setStyle(rest, "height", "2px")
  r.setStyle(rest, "background-color", DesignTokenHex[dtColorsUiSurfacePrimaryTertiary][dmDark])
  r.appendChild(track, rest)
  r.appendChild(result, track)

proc renderEditor*(r: GpuiRenderer; parent: GpuiElement;
                   escape: ViewNode; surface: EditorSurface;
                   viewportPx = 0; scrollLeftCols = 0; contentCols = -1;
                   caretMark = -1; overflowMarkers = false;
                   sticky: seq[tuple[line: int; text: string; top: int]] = @[]): bool =
  ## Draw the source editor into `parent`. Answers whether it drew ROWS.
  ##
  ## `viewportPx` is the editor pane's INNER width in pixels and
  ## `scrollLeftCols` how far right the code is scrolled — `PLAT35-F3`. The
  ## width is a parameter rather than something read here because this
  ## module is handed slots and ViewModels and no pixels (see the header):
  ## the pane's rectangle belongs to the window's geometry, and the window
  ## passes it (`main.editorBodyWidthFor` / `window_geometry
  ## .editorBodyWidthOf`). **Nobody passing it means NO SCROLLBAR, not a
  ## guessed one** — a default width here would be this front-end inventing
  ## a pane size, and every suite that draws an editor without a window
  ## would then be grading a number nothing measured.
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
  #
  # Since 2026-10-17 it is stated ON THE PANE, as an attribute a reader of
  # the plan and the pane's tab read, not as a row above the code: the
  # desktop's editor — the reference — draws no such row, and the row cost
  # the window a line of source.
  if surface.sourceStatement.len > 0:
    r.setAttribute(parent, EditorSourceStatementAttribute,
                   surface.sourceStatement)
  if surface.notice.len > 0:
    let note = r.createElement("div")
    r.setAttribute(note, "data-ct-editor-notice", surface.notice)
    r.appendChild(note, r.createTextNode(surface.notice))
    r.appendChild(parent, note)
  if surface.degradedMessage.len > 0:
    let msg = r.createElement("div")
    r.appendChild(msg, r.createTextNode(surface.degradedMessage))
    r.appendChild(parent, msg)
  let widest = editorNumberWidth(surface.rows)
  # PLAT-47 B1: the editor's own ground, Monaco's `editor.background`.
  r.setStyle(parent, "background-color", EditorGround)
  # `PLAT35-F3`. The extent is decided ONCE, before the rows are drawn, and
  # both the rows' scroll offset and the scrollbar come out of that one
  # value — so a clamped offset and the thumb that reports it cannot
  # disagree (§30).
  # M73: the vertical scrubber is decided against the horizontal bar's
  # presence (which does not depend on it), and then the horizontal bar is
  # measured on the track the vertical one leaves it — one decision each, so
  # the corner is neither's (Scrollbar-Scrubbers.md §6).
  let hasH = editorHScrollOf(surface.rows, widest, viewportPx, scrollLeftCols,
                             contentCols).present
  let vscroll = editorVScrollOf(surface, editorPaneHeightPx, hasH)
  let scroll = editorHScrollOf(surface.rows, widest, viewportPx,
                               scrollLeftCols, contentCols,
                               reservePx = (if vscroll.present:
                                              EditorVScrollbarPx else: 0))
  r.setAttribute(parent, EditorScrollMetricAttribute, scrollMetricText(scroll))
  let runs = editorRunsOf(surface)
  let folds = foldableRows(surface.rows)
  let depths = bracketDepths(surface.rows, runs)
  let guideCounts = indentGuides(surface.rows)
  if editorPaneHeightPx > 0 and viewportPx > 15:
    # Monaco's overview ruler's left border (`editorOverviewRuler.border`,
    # #353535), 15 px in from the editor's right edge, the pane's height —
    # drawn first, under the rows' inline values as the desktop's is.
    r.setStyle(parent, "position", "relative")
    let rule = r.createElement("div")
    r.setAttribute(rule, "data-ct-overview-border", "true")
    r.setStyle(rule, "position", "absolute")
    r.setStyle(rule, "left", $(viewportPx - 15) & "px")
    r.setStyle(rule, "top", $EditorTopPadPx & "px")
    r.setStyle(rule, "width", "1px")
    r.setStyle(rule, "height", $(editorPaneHeightPx - EditorTopPadPx) & "px")
    r.setStyle(rule, "background-color", "#353535")
    r.appendChild(parent, rule)
  for i, row in surface.rows:
    for z in editorLoopZones:
      if z.line == row.line:
        r.appendChild(parent, loopZoneElement(r, z))
    var selected: seq[tuple[fromColumn, toColumn: int]] = @[]
    for cell in surface.selection:
      if cell.line == row.line: selected.add (cell.fromColumn, cell.toColumn)
    var found: seq[tuple[fromColumn, toColumn: int; current: bool]] = @[]
    for m in surface.findMarks:
      if m.line == row.line: found.add (m.fromColumn, m.toColumn, m.current)
    r.appendChild(parent, renderEditorRow(r, row, runs[i], widest,
                                          scroll.leftCols,
                                          (if row.line == surface.caretLine:
                                             surface.caretColumn else: 0),
                                          selected, found, folds[i], depths[i],
                                          guideCounts[i],
                                          markersView =
                                            (if overflowMarkers and
                                                scroll.present: scroll.view
                                             else: HorizontalView())))
  if scroll.present:
    r.appendChild(parent, renderEditorScrollbar(r, scroll, caretMark))
  if editorPaneHeightPx > 0 and viewportPx > 0:
    # The editor's top inset is ground: a row scrolled partly above the
    # viewport is cut at its top edge, as Monaco's lines are, rather than
    # drawn into the inset.
    r.setStyle(parent, "position", "relative")
    let inset = r.createElement("div")
    r.setStyle(inset, "position", "absolute")
    r.setStyle(inset, "left", "0px")
    r.setStyle(inset, "top", "0px")
    r.setStyle(inset, "width", $viewportPx & "px")
    r.setStyle(inset, "height", $EditorTopPadPx & "px")
    r.setStyle(inset, "background-color", EditorGround)
    r.appendChild(parent, inset)
  if sticky.len > 0:
    # The sticky scope headers, over the top rows, each a full editor row
    # on the sticky ground.
    r.setStyle(parent, "position", "relative")
    let widest = editorNumberWidth(surface.rows)
    let lexer = if grammarForPath(surface.path) != giNone: lxNone
                else: lexerForPath(surface.path)
    # Clipped to the viewport's top edge, as Monaco's sticky widget is: a
    # header pushed up shows only its bottom.
    var stickyBottom = 0
    for (_, _, top) in sticky: stickyBottom = max(stickyBottom, top + EditorLinePx)
    let clip = r.createElement("div")
    r.setStyle(clip, "position", "absolute")
    r.setStyle(clip, "left", "0px")
    r.setStyle(clip, "top", $EditorTopPadPx & "px")
    r.setStyle(clip, "width", $max(1, viewportPx) & "px")
    r.setStyle(clip, "height", $max(1, stickyBottom) & "px")
    r.setStyle(clip, "overflow", "hidden")
    for k, (line, text, top) in sticky:
      var context = initialContext(lexer)
      let runs = if lexer == lxNone: @[] else: tokenRuns(lexer, text, context)
      let el = renderEditorRow(r, EditorRow(line: line, text: text, held: true),
                               runs, widest, scrollLeftCols,
                               stickyHeader = true)
      r.setAttribute(el, "data-ct-sticky-line", $line)
      r.setStyle(el, "position", "absolute")
      r.setStyle(el, "left", "0px")
      r.setStyle(el, "top", $top & "px")
      r.setStyle(el, "width", $max(1, viewportPx) & "px")
      r.setStyle(el, "background-color", EditorGround)
      r.appendChild(clip, el)
    r.appendChild(parent, clip)
  if editorPaneHeightPx > 0 and viewportPx > 0:
    r.setStyle(parent, "position", "relative")
    # Monaco's overview ruler (`.decorationsOverviewRuler`, 14 px along the
    # editor's right edge): the execution line's mark at its share of the
    # file, a 2 px dash in the cursor's #B6B9BB.
    if surface.executionLine > 0 and surface.totalLineCount > 0:
      let body = editorPaneHeightPx - EditorTopPadPx
      let y = EditorTopPadPx + int(round(float(surface.executionLine - 1) /
                                         float(surface.totalLineCount) *
                                         float(body)))
      let mark = r.createElement("div")
      r.setAttribute(mark, "data-ct-overview-mark", $surface.executionLine)
      r.setStyle(mark, "position", "absolute")
      r.setStyle(mark, "left", $(viewportPx - 14) & "px")
      r.setStyle(mark, "top", $y & "px")
      r.setStyle(mark, "width", "12px")
      r.setStyle(mark, "height", "2px")
      r.setStyle(mark, "background-color", "#b6b9bb")
      r.appendChild(parent, mark)
    # Scrolled, Monaco's shadow under the top edge (`.scroll-decoration`,
    # 6 px from #161616 to the ground) — or, under sticky headers, the
    # sticky widget's own shadow below them: 5 px from #020202 under whole
    # headers, a lighter 4 px under one pushed up (measured 2026-10-17 over
    # the #282828 ground, drawn as the black it is laid over that ground).
    if surface.viewportTop > 1:
      var below = 0
      # The scroll decoration lies over the code alone (`.scroll-decoration`
      # in the scrollable element: from the margin's edge to the overview
      # ruler's border); the sticky widget's shadow spans the whole editor.
      var left = EditorGutterPx
      var width = viewportPx - EditorGutterPx - 15
      var alphas = @[0.45, 0.325, 0.225, 0.15, 0.1, 0.05]
      if sticky.len > 0:
        below = sticky[^1].top + EditorLinePx
        left = 0
        width = viewportPx
        alphas = if sticky[^1].top < (sticky.len - 1) * EditorLinePx:
                   @[0.225, 0.475, 0.225, 0.075]
                 else: @[0.95, 0.7, 0.325, 0.075, 0.025]
      for i, alpha in alphas:
        let band = r.createElement("div")
        r.setAttribute(band, "data-ct-scroll-shadow", $i)
        r.setStyle(band, "position", "absolute")
        r.setStyle(band, "left", $left & "px")
        r.setStyle(band, "top", $(EditorTopPadPx + max(0, below) + i) & "px")
        r.setStyle(band, "width", $max(1, width) & "px")
        r.setStyle(band, "height", "1px")
        r.setStyle(band, "background-color",
                   "#000000" & toHex(int(round(alpha * 255)), 2).toLowerAscii)
        r.appendChild(parent, band)
  # M73: the vertical scrubber LAST, over the sticky headers and the
  # shadow, as Monaco's slider is over its sticky widget.
  if vscroll.present and viewportPx > EditorVScrollbarPx:
    r.setStyle(parent, "position", "relative")
    r.appendChild(parent, renderEditorVScrollbar(r, vscroll, viewportPx))
  surface.rows.len > 0

const
  CallRowAttribute* = "data-call-index"
    ## PLAT-49 part B: a call-trace row's trace index.
  CallToggleAttribute* = "data-call-toggle"
    ## Its toggle state (`leaf`, `expanded`, `collapsed`).
  CallPartAttribute* = "data-call-part"
    ## A row part's `CallSegmentKind` (`callee`, `argName`, `argValue`, …).
  CallSelectedAttribute* = "data-call-selected"
  CallArgAttribute* = "data-call-arg"
    ## PLAT-50: the argument a row part belongs to (0-based into `args`).
  CallRowToggleEmRatio* = 1.5625
    ## `.toggle-call`'s `height`, VERBATIM from the stylesheet that draws the
    ## desktop's call trace (`styles/components/calltrace.styl`, compiled to
    ## `.calltrace-view .toggle-call { height: 1.5625em }`).
    ##
    ## **THIS, NOT THE ROW'S OWN `min-height`, IS WHAT SETS THE ROW BOX.** A
    ## row is `display: inline-flex` with `min-height: 1.55em` (24.8 px), and
    ## every row carries a toggle: the chain
    ## `.calltrace-row > .calltrace-child > .call-child-box > .toggle-call`
    ## hands the row a flex item 1.5625em (25 px) tall, which is the taller of
    ## the two, so the row box is the TOGGLE's height and the `min-height`
    ## never binds. Both lengths are `em` against the SAME inherited
    ## font-size (nothing between `.calltrace-view` and `.toggle-call` sets
    ## one), so the ratio 1.5625 : 1.55 is fixed and the toggle wins at every
    ## font size — the `min-height` is dead weight, not a rival that takes
    ## over once the text grows.

  CallRowPitch* = CallRowToggleEmRatio * float(CodeFontPx)
    ## The desktop's row pitch — one row's top to the next — at the root font
    ## size the desktop sets on `documentElement` (`ui_js.nim`'s
    ## `style.fontSize = "{data.ui.fontSize}px"`, and `data.ui.fontSize` is
    ## `CodeFontPx`): 1.5625 x 16 = 25 px.
    ##
    ## **THE ADVANCE IS THE ROW BOX**, because nothing in a row may lay out
    ## taller than the toggle that sets it. The one part that did — `.return`,
    ## whose arrow (SpaceGrotesk) and value (SpaceMono) shared one
    ## baseline-aligned line box that two faces' metrics made ~0.05em taller
    ## than the toggle — now holds one full-height face: `calltrace.styl` sets
    ## `.return`'s strut in SpaceMono and the arrow at `line-height: 1`
    ## (codetracer-pm issue
    ## 2026-10-18-electron-calltrace-row-advance-exceeds-its-own-row-box).
    ## `ci/test/calltrace-row-box-in-browser.sh` holds every row of the
    ## desktop at exactly 1.5625em at 12, 13, 16 and 20 px roots, so this is
    ## derived from the stylesheet with no fitted residual. Positions still
    ## accumulate in float and round once (`callRowTopPx`), so a pitch that
    ## is not a whole number of pixels at another root size tiles the way the
    ## desktop's does.

  CallRowPx* = int(round(CallRowPitch))
    ## A row's height, as an integer, so a press is mapped to the row it is on
    ## (`main.clickCalltrace`). Derived from the pitch rather than restated:
    ## it was a standalone `26` while the pitch said 25.78, and the two
    ## disagreeing is what a reader had to notice by hand.
  CallIndentPx* = CallRowIndentPx
    ## The desktop's depth offset per level (`.call-depth`, measured 8 px a
    ## level 2026-10-17: toggles at 1053, 1061, 1069 …; 16 until then) —
    ## `calltrace_vm.CallRowIndentPx`, the one the web view draws too.
  CallArgsColour* = DesignTokenHex[dtColorsUiTextSuccessPrimary][dmDark]
    ## CALLTRACE_ARGS_COLOR (#BBF7D0) — the token the terminal's `srCallArgs`
    ## paints.
  CallReturnColour* = DesignTokenHex[dtColorsUiTextInformationOnColor][dmDark]
    ## CALLTRACE_RETURN_COLOR (#BFDBFE, Dark) exactly: the window is Dark.
    ## (The terminal's `srCallReturn` takes information-primary, the token
    ## with a legible Light value.)
  CallTextColour* = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  CallSelectedBackground* =
    DesignTokenHex[dtColorsEditorSurfaceSelect][dmDark]
    ## The selected row's ground (`.event-selected`, #3E3E3B): the editor
    ## theme's selection surface, as measured on the desktop 2026-10-17 (the
    ## active-row token, #333333, until then).

const
  SearchGlassSvg = staticRead(
    "../../../public/resources/shared/input_empty_search_icon_dark.svg")
    ## A find field's magnifier (`ct-images-empty-search-icon`).

const
  CallSearchAttribute* = "data-ct-call-search"
    ## The call trace's search field: a press opens the omnibox on `:calls `.
  CallSearchPx* = 26
    ## The search field's height (`.calltrace-search-input`), 4 px in from
    ## either side of the pane.
  CallRowsTopPx* = CallSearchPx + 8
    ## The first row below the pane's content top: the field and its 8 px.
  CallToggleLeftPx* = 6
    ## The toggle icon's left at depth 0 (`.collapse-call-img`, 14 px), and the
    ## text 20 px after it.
  CallConnectorColour = "#585858"
    ## The tree's connector lines (`CALLTRACE_TRACE_LINE_COLOR`, #E8E8E8 at
    ## 0.5 px, as it lands: 2 px of #585858, measured).
  CallIcons = [
    ("collapse", staticRead("../../../public/resources/calltrace/collapse-call-calltrace-dark.svg")),
    ("expand", staticRead("../../../public/resources/calltrace/expand-call-calltrace-dark.svg")),
    ("dot", staticRead("../../../public/resources/calltrace/dot-call-calltrace-dark.svg")),
    ("collapse-active", staticRead("../../../public/resources/calltrace/collapse-active-call-calltrace-dark.svg")),
    ("expand-active", staticRead("../../../public/resources/calltrace/expand-active-call-calltrace-dark.svg")),
    ("dot-active", staticRead("../../../public/resources/calltrace/dot-active-call-calltrace-dark.svg"))]

var callIconFiles {.threadvar.}: Table[string, string]

# ---------------------------------------------------------------------------
# PLAT-70 Part B — the table panes' cut cells (Horizontal-Overflow.md §5)
# ---------------------------------------------------------------------------

const
  GpuiMonoCellPx* = EditorColumnPx
    ## (= Space Mono's advance, 612 units per em, at 16 px.)
    ## One character of the code face at the window's text size (Space Mono,
    ## 16 px): a table cell's "cell" in this window. A column's pixels are
    ## turned into the cells `table_overflow.fitCell` fits a text to.

const
  EventSeparatorAttribute* = "data-ct-column-separator"
    ## An Event Log column separator's grip — the column a drag on it
    ## resizes.
  TableCutAttribute* = "data-ct-cut"
    ## On a table cell drawn CUT (its text ends in `…`) — the column's name.
    ## A cell that fits carries none (HO-8).
  TableDetailAttribute* = "data-ct-detail"
    ## On each line of a row's full text open under it — the row's key.
  StateDetailPane* = VariablesTablePane
    ## The state pane's name in a `DetailToggle` (the terminal's).

const TableScrollbarPx* = 8
  ## The vertical scrollbar a list pane keeps at its right edge (the
  ## desktop's 8 px `::-webkit-scrollbar`): not room for text.

func cellsInPx*(px: int): int =
  ## How many whole characters fit `px` pixels.
  max(0, int(floor(float(px) / GpuiMonoCellPx)))

func pxOfText*(cells: int): int =
  ## How wide `cells` characters are drawn (GPUI rounds a text run up).
  int(ceil(float(cells) * GpuiMonoCellPx))

var tableDetail*: DetailToggle
  ## The row whose full text is open under it (`list.show-detail`, a `…`
  ## click) — one, across the three table panes. Set by the window.
var tableCopyChord*: string
  ## The resolved `list.copy` chord the detail's hint names (KL-8).
var stateCuts*, eventCuts*, callCuts*: seq[CutCell]
  ## The cells each table pane drew CUT, in pixels from its pane BODY's
  ## top-left — what the window hit-tests a hover and a `…` click against.
var callTraceSlots*: seq[int]
  ## The call trace's drawn lines, top to bottom: the index into `callRows`
  ## of a call's row, -1 for a line of an open detail.

# ---------------------------------------------------------------------------
# PLAT-70 Part I — the table panes fit or scroll (Horizontal-Overflow.md §5.5)
# ---------------------------------------------------------------------------

var callTraceHView*, eventLogHView*: HorizontalView
  ## The Call Trace's and the Event Log's horizontal views, in PIXELS — the
  ## shared model's units are the caller's (`table_fit`). Settled over each
  ## frame's fit by the pane's render; the window's wheel and bar move them.
var callTracePaneHeightPx* = 0
  ## The call trace pane body's height, set by the window (its bar's row).
var eventLogTableHeightPx* = 0
  ## The Event Log's header and drawn rows, in pixels — where its sideways
  ## bar starts below the toolbar (the window's hit test reads it).
var eventLogWidestPx*: array[EventLogColumn, int]
  ## Each Event Log column's widest cell over the rows last drawn, in pixels
  ## — what the window's separator hit-test lays the columns out from too.

const
  TableHBarPx* = 8
    ## The table panes' horizontal scrollbar: the desktop's 8 px
    ## `::-webkit-scrollbar`, the State pane's (`StateScrollbarPx`).
  TableHBarAttribute* = "data-ct-hscroll"
    ## On a table pane's horizontal bar: `<leftPx>,<contentPx>,<viewportPx>`.
  TableHBarMinThumbPx* = 20

func gpuiCellUnits*(): int =
  ## One cell of the code face in whole pixels (the solver's `unit`).
  pxOfText(1)

proc tableHBar*(r: GpuiRenderer; parent: GpuiElement; view: HorizontalView;
                left, top: int; pane: string) =
  ## §5.5.4: a table pane's horizontal bar while its columns SCROLL — the
  ## shared scrubber model's thumb on an 8 px track from `left` along the
  ## view's width, at `top` (absolute in `parent`).
  if not view.overflows:
    return
  let track = r.createElement("div")
  r.setAttribute(track, TableHBarAttribute, $view.leftCol & "," &
                 $view.contentCols & "," & $view.viewportCols)
  r.setAttribute(track, "data-ct-hscroll-pane", pane)
  r.setStyle(track, "position", "absolute")
  r.setStyle(track, "left", $left & "px")
  r.setStyle(track, "top", $top & "px")
  r.setStyle(track, "width", $view.viewportCols & "px")
  r.setStyle(track, "height", $TableHBarPx & "px")
  let span = view.barModel.thumbSpan(view.viewportCols, TableHBarMinThumbPx)
  let thumb = r.createElement("div")
  r.setAttribute(thumb, "data-ct-hscroll-thumb", $span.start & "," & $span.length)
  r.setStyle(thumb, "position", "absolute")
  r.setStyle(thumb, "left", $span.start & "px")
  r.setStyle(thumb, "top", "0px")
  r.setStyle(thumb, "width", $max(1, span.length) & "px")
  r.setStyle(thumb, "height", $TableHBarPx & "px")
  r.setStyle(thumb, "background-color", "#333333")
  r.appendChild(track, thumb)
  r.appendChild(parent, track)


proc callIconPath(name: string): string =
  if callIconFiles.hasKey(name) and fileExists(callIconFiles[name]):
    return callIconFiles[name]
  let dir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
  createDir(dir)
  let path = dir / ("call-" & name & ".svg")
  for (n, svg) in CallIcons:
    if n == name: writeFile(path, svg)
  callIconFiles[name] = path
  path

func callRowTopPx*(i: int): int =
  ## Row `i`'s top below the first row's, at the desktop's pitch — which is
  ## its row box (`CallRowPitch`). Multiplied in float and rounded once, so a
  ## pitch that is not a whole number of pixels never accumulates rounding.
  int(round(float(i) * CallRowPitch))

func callRowAtPx*(dy: int): int =
  ## The row a point `dy` px below the first row's top is on.
  int(floor(float(dy) / CallRowPitch))

const CallTraceDetailPane* = CallTraceTablePane
  ## The call trace's name in a `DetailToggle` (the terminal's).

var callTracePaneWidthPx* = 0
  ## The call trace pane body's width, set by the window: a row's text is
  ## fitted to what is left of it.

func callTextLeftPx*(depth: int): int =
  ## Where a call row's text starts: the toggle's left at its depth, the
  ## 14 px toggle and the 8 px gap after it.
  CallToggleLeftPx + max(depth, 0) * CallIndentPx + 14 + 8

proc callTraceFit*(rows: openArray[CallRow]; paneW: int): TableFit =
  ## §5.5.3 in pixels: each row's floor is its text's left (indent and
  ## toggle), its callee's name and a `…`; its preferred width its whole
  ## text — over the rows drawn, in the pane less its vertical scrubber.
  var composite: seq[CompositeRow]
  for row in rows:
    composite.add callFitRow(callTextLeftPx(row.depth),
                             row.callee.runeLen, row.callRowText.runeLen,
                             unit = gpuiCellUnits())
  compositeFit(composite, max(0, paneW - TableScrollbarPx), "call")

proc renderCallTrace*(r: GpuiRenderer; parent: GpuiElement;
                      vm: CalltraceVM): bool =
  ## PLAT-49 part B (finding 8): THE CALL TRACE, ROW BY ROW FROM THE
  ## VIEWMODEL'S `CallRow`s — since 2026-10-17 as the desktop draws it
  ## (`isonim_calltrace_view`, `components/calltrace.styl`; measured): the
  ## search field, then each call 8 px a level in from its parent, its
  ## boxed toggle (the active, yellow one on the selected call), `callee #i`
  ## in the code face, the arguments in the arguments' colour and ` => value`
  ## in the return's, the selected row on the editor's selection ground, and
  ## the connector lines that join a call to its children. The parts are
  ## `calltrace_vm.callRowSegments`, the terminal's. False when there are no
  ## rows (the fallback and the reports stay `pane_views`').
  let rows = vm.callRows()
  if rows.len == 0:
    return false
  # PLAT-70 Part I (Horizontal-Overflow.md §5.5.5): the rows' column fits the
  # pane while every drawn row's indent and callee name do, else the rows are
  # laid out at the widest floor and scroll sideways (`callTraceHView`).
  let fit = callTraceFit(rows, callTracePaneWidthPx)
  if callTracePaneWidthPx > 0:
    callTraceHView.settle(fit)
  else:
    callTraceHView = HorizontalView()
  let layoutW = if fit.overflows: fit.compositeWidth
                else: callTracePaneWidthPx - TableScrollbarPx
  let hLeft = callTraceHView.leftCol
  let pane = r.createElement("div")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  if fit.overflows:
    r.setAttribute(pane, "data-ct-fit", $fit.mode)
    r.setStyle(pane, "position", "relative")
    r.setStyle(pane, "height", "100%")
    r.setStyle(pane, "overflow", "hidden")
  # The search field.
  let field = r.createElement("div")
  r.setAttribute(field, CallSearchAttribute, "true")
  r.setStyle(field, "display", "flex")
  r.setStyle(field, "items", "center")
  r.setStyle(field, "flex-shrink", "0")
  r.setStyle(field, "height", $CallSearchPx & "px")
  r.setStyle(field, "margin-left", "4px")
  r.setStyle(field, "margin-right", "4px")
  r.setStyle(field, "padding-left", "7px")
  r.setStyle(field, "rounded", "6px")
  r.setStyle(field, "border-width", "1px")
  r.setStyle(field, "border-color", DesignTokenHex[dtColorsUiBorderSecondary][dmDark])
  r.setStyle(field, "background-color", DesignTokenHex[dtColorsUiSurfaceBasePanel][dmDark])
  r.setStyle(field, "font-family", WindowFontFamily)
  r.setStyle(field, "font-size", "14px")
  r.setStyle(field, "white-space", "nowrap")
  r.setStyle(field, "overflow", "hidden")
  let query = vm.searchQuery.val
  # `.ct-input-search-image`: the magnifier at 0.5em, the text from 1.875em.
  let glass = r.createElement("img")
  r.setAttribute(glass, "src", stateIconPath("search", SearchGlassSvg,
    DesignTokenHex[dtColorsUiIconPrimarySubtle][dmDark]))
  r.setStyle(glass, "width", "14px")
  r.setStyle(glass, "height", "14px")
  r.setStyle(glass, "flex-shrink", "0")
  r.appendChild(field, glass)
  let text = r.createElement("div")
  r.setStyle(text, "padding-left", "5px")
  r.setStyle(text, "color", DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark])
  r.appendChild(text, r.createTextNode(if query.len > 0: query else: "Search"))
  r.appendChild(field, text)
  r.appendChild(pane, field)

  let list = r.createElement("div")
  r.setAttribute(list, "data-calltrace", "rows")
  r.setStyle(list, "display", "flex")
  r.setStyle(list, "flex-direction", "column")
  r.setStyle(list, "margin-top", "8px")
  r.setStyle(list, "position", "relative")
  r.setStyle(list, "font-family", MonoFontFamily)
  if fit.overflows:
    # SCROLL: the rows are as wide as the widest floor, and the view moves
    # them (the pane clips).
    r.setStyle(list, "width", $layoutW & "px")
    r.setStyle(list, "min-width", $layoutW & "px")
    r.setStyle(list, "flex-shrink", "0")
  if hLeft > 0:
    r.setStyle(list, "margin-left", $(-hLeft) & "px")
  # PLAT-70 Part B (Horizontal-Overflow.md §5.3): the lines, top to bottom —
  # each call's row and, under the one whose detail is open, its full text —
  # so every y below (the rows, the connectors, the window's hit-tests) is a
  # line's, not a call's.
  var slotOf = newSeq[int](rows.len)
  callTraceSlots = @[]
  var detailLines: Table[int, seq[string]]
  let bodyRows = max(1, rows.len)
  for k, row in rows:
    slotOf[k] = callTraceSlots.len
    callTraceSlots.add k
    if tableDetail.isOpen(CallTraceDetailPane, $row.index):
      let textX = callTextLeftPx(row.depth)
      let lines = detailView(row.callRowText,
                             max(1, cellsInPx(layoutW - textX)),
                             bodyRows, tableCopyChord).lines
      detailLines[k] = lines
      for _ in lines:
        callTraceSlots.add -1
  # THE CONNECTOR LINES (`.calltrace-svg-line`): down each row through its
  # toggle's centre and, at the row's foot, across to the next row's.
  if rows.len >= 2:
    for k, row in rows:
      let x = CallToggleLeftPx + 7 + max(row.depth, 0) * CallIndentPx
      let top = callRowTopPx(slotOf[k])
      # The line runs on through the call's open detail to the next call.
      let foot = if k < rows.high: callRowTopPx(slotOf[k + 1])
                 else: callRowTopPx(slotOf[k] + 1)
      let centre = top + 13
      let y0 = if k == 0: centre else: top
      let y1 = if k == rows.high: centre else: foot
      # Drawn BEFORE the rows, so a row's toggle and the selected row's ground
      # cover it, as they do on the desktop.
      for (a, b) in [(y0, y1)]:
        if b > a:
          let v = r.createElement("div")
          r.setAttribute(v, "data-ct-call-connector", "v")
          r.setStyle(v, "position", "absolute")
          r.setStyle(v, "left", $x & "px")
          r.setStyle(v, "top", $a & "px")
          r.setStyle(v, "width", "2px")
          r.setStyle(v, "height", $(b - a) & "px")
          r.setStyle(v, "background-color", CallConnectorColour)
          r.appendChild(list, v)
      if k < rows.high:
        let nx = CallToggleLeftPx + 7 + max(rows[k + 1].depth, 0) * CallIndentPx
        if nx != x:
          let h = r.createElement("div")
          r.setAttribute(h, "data-ct-call-connector", "h")
          r.setStyle(h, "position", "absolute")
          r.setStyle(h, "left", $min(x, nx) & "px")
          r.setStyle(h, "top", $foot & "px")
          r.setStyle(h, "width", $(abs(nx - x) + 1) & "px")
          r.setStyle(h, "height", "2px")
          r.setStyle(h, "background-color", CallConnectorColour)
          r.appendChild(list, h)
  callCuts = @[]
  for k, row in rows:
    let el = r.createElement("div")
    r.setAttribute(el, CallRowAttribute, $row.index)
    r.setAttribute(el, CallToggleAttribute, $row.toggle)
    let selected = crfSelected in row.flags
    r.setAttribute(el, CallSelectedAttribute,
                   (if selected: "true" else: "false"))
    r.setStyle(el, "display", "flex")
    r.setStyle(el, "white-space", "nowrap")
    r.setStyle(el, "overflow", "hidden")
    r.setStyle(el, "flex-shrink", "0")
    r.setStyle(el, "height", $(callRowTopPx(slotOf[k] + 1) -
                               callRowTopPx(slotOf[k])) & "px")
    r.setStyle(el, "items", "center")
    r.setStyle(el, "padding-left", $(CallToggleLeftPx + row.depth * CallIndentPx) & "px")
    # ONE ROUNDING PER RUN OF TEXT, not one per span. GPUI rounds every text
    # element's width up to a whole logical pixel, so a row built as one
    # element per coloured segment accumulates that rounding segment by
    # segment and drifts right of where the browser puts the same text —
    # measured at +2.55 device px across this pane, growing left to right.
    # The renderer draws each maximal run of adjacent plain spans as a single
    # piece of text (`isonim_gpui/renderer`), which rounds the run once.
    #
    # The row is NOT fusable end to end, and does not need to be: the toggle
    # icon, the 8 px spacer and the `=>` in the interface face each keep
    # their own element, so their spacing and their face are preserved
    # exactly. Only the text spans between them fuse. The `(` carrying
    # `.call-args`' 5 px fuses WITH its neighbours: the row declares
    # `white-space: nowrap` and no `text-overflow`, so the renderer carries
    # a span's own horizontal padding as an inset of the run (the
    # `inlineTextRunsAttribute` rule) and the 5 px is kept exactly. Nor does fusing cost per-span identity — it happens in the render
    # plan's CONSUMER, so every segment, with its `data-call-part` and its
    # `data-call-arg`, is still in the plan for hit-testing to resolve.
    r.setAttribute(el, InlineTextRunsAttribute, "1")
    if selected:
      r.setStyle(el, "background", CallSelectedBackground)
    var afterIndex = false
    # PLAT-70 Part B (§5.1): THE ROW IS ONE CELL — its text after the toggle,
    # fitted to the pane in characters of the code face; a cut row keeps
    # its parts up to `keep` characters, then `…`.
    let textX = callTextLeftPx(row.depth)
    let full = row.callRowText
    # (No width yet — a plan drawn before the window laid out — fits all.)
    let fitted = if callTracePaneWidthPx <= 0: fitCell(full, high(int) div 2)
                 else: fitCell(full, cellsInPx(layoutW - textX))
    let keep = if fitted.truncated: fitted.text.runeLen - 1 else: high(int)
    var used = 0
    var lastColour = CallTextColour
    for seg in row.callRowSegments(indent = false):
      if seg.kind != csToggle and used >= keep:
        break
      if seg.kind == csToggle:
        let icon = r.createElement("div")
        r.setAttribute(icon, CallPartAttribute, $seg.kind)
        r.setStyle(icon, "width", "14px")
        r.setStyle(icon, "height", "14px")
        r.setStyle(icon, "flex-shrink", "0")
        r.setStyle(icon, "display", "flex")
        r.setStyle(icon, "items", "center")
        r.setStyle(icon, "justify", "center")
        let kind = case row.toggle
                   of crtExpanded: "collapse"
                   of crtCollapsed: "expand"
                   of crtLeaf: "dot"
        let img = r.createElement("img")
        r.setAttribute(img, "src", callIconPath(kind &
                                                (if selected: "-active" else: "")))
        let side = if row.toggle == crtLeaf: 4 else: 14
        r.setStyle(img, "width", $side & "px")
        r.setStyle(img, "height", $side & "px")
        r.appendChild(icon, img)
        r.appendChild(el, icon)
        let gap = r.createElement("div")
        r.setStyle(gap, "width", "8px")
        r.setStyle(gap, "flex-shrink", "0")
        r.appendChild(el, gap)
        continue
      if seg.kind == csPunct and seg.text == " " and not afterIndex:
        # The toggle's own space: the gap above stands for it.
        continue
      let piece = r.createElement("span")
      r.setAttribute(piece, CallPartAttribute, $seg.kind)
      # PLAT-50 (K23): an argument's parts name it, for its right-click menu.
      if seg.arg > 0:
        r.setAttribute(piece, CallArgAttribute, $(seg.arg - 1))
      r.setStyle(piece, "flex-shrink", "0")
      if seg.kind == csPunct and seg.text == "(" and afterIndex and seg.arg == 0:
        # `.call-args { margin-left: 0.3125em }`.
        r.setStyle(piece, "padding-left", "5px")
      if seg.kind == csReturnArrow:
        # `.return-arrow`: `=>` in the interface face, 5 px after the `)`
        # and the value directly after it — no spaces in the code face.
        r.setStyle(piece, "font-family", WindowFontFamily)
        r.setStyle(piece, "padding-left", "5px")
        r.setStyle(piece, "padding-right", "4px")
        r.setStyle(piece, "color", CallReturnColour)
        let arrow = seg.text.strip()
        let shown = arrow.runeSubstr(0, max(0, keep - used))
        used += seg.text.runeLen
        r.appendChild(piece, r.createTextNode(shown))
        r.appendChild(el, piece)
        lastColour = CallReturnColour
        continue
      lastColour =
        case seg.kind
        of csPunct, csArgName, csArgValue: CallArgsColour
        of csReturnArrow, csReturnValue: CallReturnColour
        else: CallTextColour
      r.setStyle(piece, "color", lastColour)
      let shown = seg.text.runeSubstr(0, max(0, keep - used))
      used += seg.text.runeLen
      r.appendChild(piece, r.createTextNode(shown))
      r.appendChild(el, piece)
      if seg.kind == csIndex: afterIndex = true
    if fitted.truncated:
      let mark = r.createElement("span")
      r.setAttribute(mark, CallPartAttribute, "ellipsis")
      r.setStyle(mark, "flex-shrink", "0")
      r.setStyle(mark, "color", lastColour)
      r.appendChild(mark, r.createTextNode(Ellipsis))
      r.appendChild(el, mark)
      r.setAttribute(el, TableCutAttribute, "call")
      let rowTop = 8 + CallRowsTopPx + callRowTopPx(slotOf[k])
      callCuts.add CutCell(row: rowTop,
                           height: callRowTopPx(slotOf[k] + 1) -
                                   callRowTopPx(slotOf[k]),
                           col: textX - hLeft,
                           width: layoutW - textX,
                           ellipsisCol: textX - hLeft + pxOfText(keep) + 5,
                           ellipsisWidth: pxOfText(2),
                           key: $row.index, column: "call", full: full)
    r.appendChild(list, el)
    for j, text in detailLines.getOrDefault(k):
      let at = slotOf[k] + 1 + j
      let d = r.createElement("div")
      r.setAttribute(d, TableDetailAttribute, $row.index)
      r.setStyle(d, "display", "flex")
      r.setStyle(d, "items", "center")
      r.setStyle(d, "flex-shrink", "0")
      r.setStyle(d, "white-space", "nowrap")
      r.setStyle(d, "height", $(callRowTopPx(at + 1) - callRowTopPx(at)) & "px")
      r.setStyle(d, "padding-left", $textX & "px")
      r.setStyle(d, "color", CallTextColour)
      r.appendChild(d, r.createTextNode(text))
      r.appendChild(list, d)
  r.appendChild(pane, list)
  if fit.overflows and callTracePaneHeightPx > TableHBarPx:
    tableHBar(r, pane, callTraceHView, 0, callTracePaneHeightPx - TableHBarPx,
              $paneCalltrace)
  r.appendChild(parent, pane)
  true

const
  StateColumnAttribute* = "data-column"
    ## **`PLAT35-F4`. WHICH COLUMN A STATE-PANE CELL IS**, `name` or `value`,
    ## on every cell of every row INCLUDING the header's.
    ##
    ## The finding this answers: *"the state pane's rows are flat
    ## `name: value` strings … no column structure, so name and value cannot
    ## be distinguished and nothing aligns vertically"* — measured as ZERO
    ## occurrences of this attribute anywhere in the pane, over all seven
    ## `scenarios.json` plans, at `73e8c3dc4` and again at `42655fd72`.
    ##
    ## It is the attribute a reader can ask the shipped binary for
    ## (`--report-window-plan`), which is why the structure is published here
    ## rather than left to be inferred from text and pixels.
  StateRowAttribute* = "data-state-row"
    ## A body row's index among the pane's VISIBLE rows. The header has none,
    ## so "the rows" and "the header" are separable by a reader without
    ## counting children.
  StateHeaderAttribute* = "data-state-header"
    ## `"true"` on the header row, and on nothing else.
  StateDepthAttribute* = "data-state-depth"
    ## A row's depth in the variable tree. Published because the INDENT lives
    ## inside the name cell (see `renderState`) — so a reader can check that
    ## an indented row still ends its name field where every other row does,
    ## which is the whole of the alignment claim.
  StateSelectedAttribute* = "data-state-selected"
    ## Whether this row is `StateVM.selectedPath`'s. Carried so the fact the
    ## vocabulary `Tree` published as `data-cursor` is not LOST by drawing the
    ## rows here; nothing paints it yet, and a selected-row ground is not
    ## `PLAT35-F4`'s to add.
  StateAlignAttribute* = "data-state-value-x"
    ## **THE ONE X EVERY VALUE CELL STARTED AT**, in px, on the table, while
    ## the pane was a two-column table. Since the 2026-10-17 redesign the
    ## pane draws the desktop's `name:value` and publishes no such x; the
    ## name is kept so `test_plat40_state_pane_columns.nim` can assert that
    ## it is ABSENT, i.e. that the fixed column has not come back.
  StateChangedAttribute* = "data-ct-changed"
    ## PLAT-51: `"true"` on a row whose value the step changed.
  StateChangedColour* = DesignTokenHex[dtColorsUiTextInformationPrimaryHover][dmDark]
    ## PLAT-51: the shared changed-value accent (the desktop's
    ## `.value-changed`, the terminal's `srValueModified`).
  StateControlAttribute* = "data-ct-state-control"
    ## PLAT-51: on a row's value controls — `history:<path>` (K40, the
    ## history button), `origin:<path>` (K41, the origin badge),
    ## `unwatch:<expression>` (a watch's remove control).
  StateHistoryEntryAttribute* = "data-ct-history-entry"
    ## PLAT-51: on a value-history row under its variable — `<ticks>`; a
    ## click goes to that moment.
  StateOriginHopAttribute* = "data-ct-origin-hop"
    ## PLAT-51: on a value-origin hop under its variable.
  StateAddWatchAttribute* = "data-ct-add-watch"
    ## PLAT-51: the Watches tab's "Add watch expression…" row.
  StateNameColumn* = "name"
  StateValueColumn* = "value"
  StateTableAttribute* = "data-state-table"
  # (HISTORY — SUPERSEDED 2026-10-17: the pane now draws the desktop's
  # `name:value`, with no column rule and no resize drag; the rule's element
  # and the drag were removed. The spec reading below is kept as the record.)
  #
  # **THE NAME/VALUE COLUMN RULE IS DRAWN, AND THE SPEC DOES PUBLISH IT.**
  # The element is `StateSeparatorAttribute`'s, below; this is the spec
  # reading, because the text that stood here said the opposite.
  #
  # **THE CENSUS THAT SETTLES IT**, taken by CODEPOINT and COLUMN INDEX over
  # **all five** fenced wireframes of `Variable-State-Pane.md`. Measured at
  # the THIRD adversarial review of 2026-10-04 — the one that read the
  # wireframes; three reviews share that date and are distinguished here by
  # what each measured, because "adversarial review, 2026-10-04" on its own
  # names no instrument. Re-measured from this pass before being written
  # down:
  #
  #   | block   | section               | rows with an interior U+007C      | col |
  #   | 47–56   | Value Expansion       | 0 — AND NO OUTER FRAME AT ALL     | —   |
  #   | 75–82   | Value History         | 0                                 | —   |
  #   | 92–98   | Column Resizing       | 2 (header 94, body 96)            | 14  |
  #   | 191–214 | ## Wireframe (ASCII …) | 10 (header 197, body 199–206, 208) | 26 |
  #   | 254–263 | Desired Future Design | 1 (256)                           | 28  |
  #
  # THIRTEEN wireframed rows carry the bar at a CONSTANT column, the ASCII
  # Reference's outer frame being at 0 and 67. Block 47–56 draws NO `|` at
  # all, outer or interior — it is a frameless tree diagram — so its silence
  # about an interior rule is not a statement about one, and the earlier text
  # built its whole case on that silence.
  #
  # **THREE READINGS ARE RETRACTED, IN THE WORDS THEY WERE PUBLISHED IN.**
  # The record of the error is worth more than a clean file.
  #  1. RETRACTED: *"the `+---...---+` rules above and below (lines 95, 97,
  #     198) are unbroken dashes with no `+` at the column position, which is
  #     what a published column boundary would have put there."* **THAT PROBE
  #     FAILS ITS OWN POSITIVE CONTROL.** §"Column Resizing"'s prose
  #     guarantees the subject outright — *"The Name/Value column separator
  #     can be dragged to resize"* — and its rules (93, 95, 97) carry `+` at
  #     columns 0 and 28 and **none at column 14**, which is where both of
  #     its rows put the bar. A probe that answers "no boundary" where the
  #     boundary is textually guaranteed is measuring the wrong thing
  #     (`Verification-Harness-Traps` §67). The same probe would deny the
  #     OUTER frame of the ASCII Reference, whose rules carry `+` at 0 and 67
  #     only because the dashes run between them.
  #  2. RETRACTED as evidence: *"`State.ColumnResize` is ranked **`Low`** in
  #     that same document's test-scenario table."* True, and it ranks the
  #     DRAG's test priority. Its own description — *"Drag column separator
  #     to resize"* — names the separator as a thing that exists, so the row
  #     is evidence FOR the rule and against only the drag's urgency.
  #  3. RETRACTED as evidence: the *"Fixed flex tracks with no separator
  #     element"* row at line 148. It is the **BlockTracer** column of
  #     §"Applicability: this pane is CodeTracer-only", whose opening
  #     sentence excludes it from this pane — *"Everything above describes
  #     the CodeTracer desktop/web pane"*, *"BlockTracer implements none of
  #     value expansion, 'load more', or column resizing"*.
  #
  # **WHAT STANDS FROM THE EARLIER PASSES, BECAUSE IT WAS MEASURED AND
  # RIGHT**: the rule paints iff it declares its own height, and the colour
  # the framebuffer holds is not the declared token. Both were carried on
  # `StateSeparatorAttribute` while the rule was drawn.
  #
  # **THE DRAG IS STILL NOT DRAWN, AND STAYS NAMED RESIDUE**
  # (`PLAT35-F4.residue` 1): it needs a persisted width and a
  # pointer-capture model, it is the `Low`-ranked row above, and the
  # governing clause is the one `PLAT35-F7`'s remedy turns on — *"A rendered
  # affordance must do the thing it advertises, or not be rendered"*. So the
  # rule carries NO `cursor` and NO click handler, and a case asserts that: a
  # static rule is not an affordance, and a `col-resize` cursor over no drag
  # would be.
  StateSeparatorAttribute* = "data-state-separator"
    ## The 1 px name/value column rule the two-column state pane drew (and a
    ## press on it started a column-resize drag). Since the 2026-10-17
    ## redesign the pane draws the desktop's `name:value`, which has no
    ## column rule and nothing to drag, so nothing sets this attribute; the
    ## name is kept so `test_plat40_state_pane_columns.nim` can assert the
    ## rule has not come back. (The measurements of why the rule painted, and
    ## of its rendered colour, are in the tier-4 ledger's history.)
  StateTreeViewId* = "state.root"
    ## `pane_views.statePaneView`'s id for the variables `Tree`. The ONE node
    ## this renderer takes over from the vocabulary; everything else the pane
    ## view answers — the `Collapsible` and the `Tabs` over §3.3.4's three
    ## roots — is still drawn by `gpui_binding`, so `Locals` / `Globals` /
    ## `Watches` keep ONE owner and one spelling.
  StateHeaderNameLabel* = "Name"
  StateHeaderValueLabel* = "Value"
    ## `Variable-State-Pane.md` §"Variable Display" publishes a table of
    ## **TWO** columns and these are its two headings — `Name` (*"Variable or
    ## expression name"*) and `Value` (*"Current value (expandable for
    ## complex types)"*) — and §"Column Resizing" draws the same two over a
    ## `| Name | Value |` header.
    ##
    ## **THERE IS NO TYPE COLUMN, AND ITS ABSENCE IS A READING OF THE SPEC
    ## RATHER THAN AN OMISSION.** `tools/visual-review-brief.md`'s `editor`
    ## block asks for *"name, type and value per row"* and the spec does not;
    ## the brief is the review instrument and the spec is the published
    ## specification. `store_types.Variable.typeName` is in reach here and is
    ## deliberately not drawn. Changing that is a spec change — it would move
    ## Electron and the design system too — and is recorded in
    ## `PLAT35-F4.specCorrection`, not taken here.
  StateNameColour* = DesignTokenHex[dtColorsUiTextPrimaryActive][dmDark]
    ## `.value-name { color: colors-ui-text-primary-active }` —
    ## `styles/components/state.styl:232`, the Electron front-end's own
    ## choice, carried across rather than picked (§6: the desktop is the
    ## reference).
  StateValueColour* = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]

type
  StateRow* = object
    ## One VISIBLE row of the state pane, flattened.
    path*: string      ## `StateVM.expandedPaths`' and `selectedPath`'s spelling
    name*: string
    value*: string     ## the presenter's answer at the caller's budget
    typeName*: string  ## carried, NOT drawn — see `StateHeaderValueLabel`
    presented*: PValue ## PLAT-70 Part B: the value itself, so the row asks
                       ## the presenter for what fits ITS cell
    whole*: string     ## the store's own rendering, when there is no value
    depth*: int
    hasChildren*: bool
    expanded*: bool
    selected*: bool
    isWatch*: bool     ## a watched expression's row (top level only)
    watchInvalid*: bool ## the stop cannot answer this watch; `value` says why

proc appendStateRows(v: Variable; path: string; depth: int;
                     budget: Budget; expanded: HashSet[string];
                     selected: string; acc: var seq[StateRow]) =
  ## `v` and, when `v` is expanded, its descendants, in draw order.
  ##
  ## **THE PATH SPELLING AND THE EXPANSION RULE ARE
  ## `pane_views.variableRow`'s, and that agreement is GATED rather than
  ## trusted**: `test_plat40_state_pane_columns.nim` compares the paths this
  ## produces against the ids of `statePaneView`'s own visible `Tree` rows,
  ## for the same ViewModel, and fails if they differ. Two derivations of one
  ## rule is §30; a derivation the suite compares against the other is the
  ## shape this file can have without publishing a `stateRows` on `StateVM`
  ## (which is the durable answer, and would move two more harnesses').
  let rendered =
    if v.presented.isNil: v.value
    else: presentText(v.presented, budget)
  acc.add StateRow(path: path, name: v.name, value: rendered,
                   typeName: v.typeName, presented: v.presented,
                   whole: v.value, depth: depth,
                   hasChildren: v.hasChildren or v.children.len > 0,
                   expanded: path in expanded,
                   selected: path == selected,
                   isWatch: depth == 0 and v.isWatch,
                   watchInvalid: depth == 0 and v.isInvalidWatch)
  if path in expanded:
    for c in v.children:
      appendStateRows(c, path & "." & c.name, depth + 1, budget, expanded,
                      selected, acc)

proc stateRows*(vm: StateVM; budget: Budget): seq[StateRow] =
  ## The pane's visible rows, from the ViewModel the other two front-ends read.
  ##
  ## `MaxTreeRows` caps the TOP-LEVEL loop, which is where
  ## `statePaneView` caps it too — the same cap in the same place, so the two
  ## renderings cannot show different numbers of variables.
  result = @[]
  if vm.isNil:
    return
  let expanded = vm.expandedPaths.val
  let selected = vm.selectedPath.val
  let vars = vm.currentVariables.val
  for i, v in vars:
    if i >= MaxTreeRows: break
    appendStateRows(v, v.name, 0, budget, expanded, selected, result)

const
  StateInsetPx* = 8
    ## The state pane's content inset (`.state-component` at 8 px in from the
    ## panel, measured on the Electron front-end 2026-10-17).
  StateWatchFieldPx* = 300
    ## The watch field beside it (`.ct-input-panel`), 6 px after it.
  StateCodeLineGround = "#3a3a3ab3"
    ## `.code-state-line`'s `rgba(58, 58, 58, 0.7)`.
  StateValueRowPx* = 24
    ## A value row (`.value-expanded`), the code line too.
  StateRowIndentPx* = 16
    ## A child row's offset per level.
  StateTypeColour = DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark]
  StateValueTextColour = DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark]
    ## `.value-expanded-text { color: colors-ui-text-warning-primary }`.
  StateEmptyColour = "#a2a2a2"
    ## `.empty-overlay`'s text as it lands (body text at 0.6, measured).
  StateControlBorder = DesignTokenHex[dtColorsUiBorderSecondary][dmDark]
  FileTreeFolderSvg = staticRead(
    "../../../public/resources/shared/filesystem/filesystem_default_folder.svg")
  FileTreeFileSvg = staticRead(
    "../../../public/resources/shared/filesystem/filesystem_default_file.svg")
  FileTreeOpenSvg = staticRead(
    "../../../public/resources/shared/filesystem/filesystem_close_toggle_dark.svg")
  FileTreeClosedSvg = staticRead(
    "../../../public/resources/shared/filesystem/filesystem_open_toggle_dark.svg")
  HistoryToggleSvg = staticRead(
    "../../../public/resources/shared/history_value_view_toggle_dark.svg")

const
  OriginIconSvgs = [
    ("sigma", staticRead("../../../public/resources/origin-icons/sigma.svg")),
    ("quotation", staticRead("../../../public/resources/origin-icons/quotation.svg")),
    ("door", staticRead("../../../public/resources/origin-icons/door.svg")),
    ("globe", staticRead("../../../public/resources/origin-icons/globe.svg")),
    ("clock-rewind", staticRead("../../../public/resources/origin-icons/clock-rewind.svg")),
    ("question", staticRead("../../../public/resources/origin-icons/question.svg")),
    ("hourglass", staticRead("../../../public/resources/origin-icons/hourglass.svg"))]
    ## The origin badge's marks (`.ct-origin-icon-*`, `components/button.styl`).

func originIconSvg(name: string): string =
  for (n, svg) in OriginIconSvgs:
    if n == name: return svg
  OriginIconSvgs[5][1]

var stateIconFiles {.threadvar.}: Table[string, string]

proc stateIconPath(name, svg, ink: string): string =
  ## A state-pane icon written once in `ink` — the desktop paints these as
  ## masks in `colors-ui-icon-primary-default`.
  let key = name & ink
  if stateIconFiles.hasKey(key) and fileExists(stateIconFiles[key]):
    return stateIconFiles[key]
  let dir = getTempDir() / ("codetracer-gpui-marks-" & $getCurrentProcessId())
  createDir(dir)
  let path = dir / ("state-" & name & ".svg")
  var body = svg.replace("currentColor", ink)
  for fill in ["#DDDDDD", "#dddddd", "#F3F3F3", "#919191", "white", "#fff"]:
    body = body.replace("\"" & fill & "\"", "\"" & ink & "\"")
  writeFile(path, body)
  stateIconFiles[key] = path
  path

proc stateText(r: GpuiRenderer; text, colour: string; sizePx = 16;
               weight = ""; mono = true): GpuiElement =
  result = r.createElement("div")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "white-space", "nowrap")
  r.setStyle(result, "color", colour)
  if sizePx != 16: r.setStyle(result, "font-size", $sizePx & "px")
  if weight.len > 0: r.setStyle(result, "font-weight", weight)
  r.setStyle(result, "font-family", if mono: MonoFontFamily else: WindowFontFamily)
  r.appendChild(result, r.createTextNode(text))

proc stateIconButton(r: GpuiRenderer; attr, iconName, svg: string;
                     lit: bool): GpuiElement =
  ## A value control (`.value-history-button`, `.ct-origin-badge`): a 20 px
  ## square on the bar's ground in a 1 px border, its 12–16 px mark centred.
  result = r.createElement("div")
  r.setAttribute(result, StateControlAttribute, attr)
  r.setStyle(result, "width", "20px")
  r.setStyle(result, "height", "20px")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "display", "flex")
  r.setStyle(result, "items", "center")
  r.setStyle(result, "justify", "center")
  r.setStyle(result, "rounded", "6px")
  r.setStyle(result, "border-width", "1px")
  r.setStyle(result, "border-color", if lit: StateChangedColour
                                     else: StateControlBorder)
  r.setStyle(result, "background-color",
             DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark])
  let icon = r.createElement("img")
  r.setAttribute(icon, "src", stateIconPath(iconName, svg,
    DesignTokenHex[dtColorsUiIconPrimaryDefault][dmDark]))
  let side = if iconName == "history": 12 else: 16
  r.setStyle(icon, "width", $side & "px")
  r.setStyle(icon, "height", $side & "px")
  r.appendChild(result, icon)

var statePaneSizePx*: tuple[w, h: int] = (0, 0)
  ## The state pane body's size, set by the window: its scrollbars are drawn
  ## from it (`stateScrollbars`).
var stateFitContentPx* = 0
  ## PLAT-70 Part I: the rows' width while they SCROLL (the widest floor), 0
  ## while they fit the pane.

var stateScroll*: tuple[top, left: int] = (0, 0)
  ## How far the state pane's scroll box is scrolled, in pixels — moved by
  ## the wheel (`main.windowPointer`), clamped to the content when drawn.
var stateScrollMax*: tuple[top, left: int] = (0, 0)
  ## The furthest it can scroll, as last drawn.
var stateVerticalBar*: tuple[track, content: int] = (0, 0)
  ## M71 (#838): the vertical scrollbar as last drawn — its track's height
  ## (from `StateRowsTopPx` below the pane body's top, at its right edge)
  ## and the rows' whole height, in pixels; (0, 0) when the rows fit. What
  ## the window's §3 press and drag on the bar are read against.

const
  StateRowsTopPx* = 78
    ## The rows' scroll box's top below the pane body's (the 8 px inset, the
    ## controls, the code line, the 12 px gap — 144 - 66 at 1920x1080).
  StateScrollbarPx* = 8
    ## The desktop's `::-webkit-scrollbar` (8 px, its thumb #333333, no track).
  StateScrollTrackAttribute* = "data-ct-state-scroll-track"
    ## M71: on the vertical bar's track — its height in pixels.

proc stateVerticalThumb*(): tuple[start, length: int] =
  ## M71 (#838): the vertical thumb as `stateScrollbars` last drew it, in
  ## pixels down its track — at the scroll's share of the track, as long as
  ## the visible share of the rows. (0, 0) while the rows fit. The one
  ## arithmetic the drawing and the window's press on the bar both read.
  let bar = stateVerticalBar
  if bar.track <= 0 or bar.content <= 0:
    return (0, 0)
  let top = min(stateScroll.top, stateScrollMax.top)
  (int(round(float(bar.track) * float(top) / float(bar.content))),
   int(round(float(bar.track) * float(bar.track) / float(bar.content))))

proc stateScrollbars(r: GpuiRenderer; parent: GpuiElement;
                     rows: openArray[StateRow]; drawnRows: int) =
  ## The desktop's state scroll box's scrollbars, at rest at its origin: a
  ## vertical thumb when its rows are taller than the box, a horizontal one
  ## when a row is wider — each `track * visible / content` long, the track
  ## and the visible extent both short of the other bar's 8 px when both
  ## show (measured 2026-10-17: 328 px over 19 rows in a 395 px box; 19 px
  ## for a 14 076 px row in a 522 px one).
  let (w, h) = statePaneSizePx
  stateVerticalBar = (0, 0)
  if w <= 0 or h <= StateRowsTopPx:
    return
  let boxH = h - StateRowsTopPx
  let contentH = drawnRows * StateValueRowPx
  # PLAT-70 Part B (Horizontal-Overflow.md §5, Variable-State-Pane Decision 3):
  # a TABLE PANE DOES NOT SCROLL SIDEWAYS while its rows' floors fit — every
  # row is fitted to the pane and a cut value ends in `…`. PLAT-70 Part I
  # (§5.5): when they do not, the rows are as wide as the widest floor.
  let contentW = stateFitContentPx
  var vertical = contentH > boxH
  let horizontal = contentW > w - (if vertical: StateScrollbarPx else: 0)
  vertical = vertical or (horizontal and contentH > boxH - StateScrollbarPx)
  let visibleH = boxH - (if horizontal: StateScrollbarPx else: 0)
  let visibleW = w - (if vertical: StateScrollbarPx else: 0)
  stateScrollMax = (max(0, contentH - visibleH), max(0, contentW - visibleW))
  r.setStyle(parent, "position", "relative")
  if horizontal:
    # The box's rows end above its horizontal scrollbar (its client height
    # is the box's less the bar): a row reaching under the bar is not drawn.
    let cover = r.createElement("div")
    r.setStyle(cover, "position", "absolute")
    r.setStyle(cover, "left", "0px")
    r.setStyle(cover, "top", $(h - StateScrollbarPx) & "px")
    r.setStyle(cover, "width", $w & "px")
    r.setStyle(cover, "height", $StateScrollbarPx & "px")
    r.setStyle(cover, "background-color", chromeOf(crPaneBackground))
    r.appendChild(parent, cover)
  proc thumb(r: GpuiRenderer; x, y, tw, th: int; axis: string) =
    let t = r.createElement("div")
    r.setAttribute(t, "data-ct-state-scrollbar", axis)
    r.setStyle(t, "position", "absolute")
    r.setStyle(t, "left", $x & "px")
    r.setStyle(t, "top", $y & "px")
    r.setStyle(t, "width", $max(1, tw) & "px")
    r.setStyle(t, "height", $max(1, th) & "px")
    r.setStyle(t, "background-color", "#333333")
    r.appendChild(parent, t)
  # The thumbs at the scroll's share of the track.
  if vertical:
    let track = visibleH
    stateVerticalBar = (track, contentH)
    # M71 (#838): the bar's column is a track a press lands on (the §3
    # click centres the rows there, the thumb drags — `main
    # .pressListScrubber`), drawn with no fill: the desktop's box shows its
    # thumb only.
    let t = r.createElement("div")
    r.setAttribute(t, StateScrollTrackAttribute, $track)
    r.setStyle(t, "position", "absolute")
    r.setStyle(t, "left", $(w - StateScrollbarPx) & "px")
    r.setStyle(t, "top", $StateRowsTopPx & "px")
    r.setStyle(t, "width", $StateScrollbarPx & "px")
    r.setStyle(t, "height", $max(1, track) & "px")
    r.appendChild(parent, t)
    let thumb = stateVerticalThumb()
    r.thumb(w - StateScrollbarPx, StateRowsTopPx + thumb.start,
            StateScrollbarPx, thumb.length, "vertical")
  if horizontal:
    let track = visibleW
    let left = min(stateScroll.left, stateScrollMax.left)
    r.thumb(int(round(float(track) * float(left) / float(contentW))),
            h - StateScrollbarPx,
            int(round(float(track) * float(track) / float(contentW))),
            StateScrollbarPx, "horizontal")

proc stateFixedPx(vm: StateVM; row: StateRow): int =
  ## A state row's width less its value — the indent, the caret, `name:`,
  ## the type, the controls and the gaps — as `renderState` lays it out.
  let watchControl = row.isWatch
  let controlsPx = 20 + 20 + (if watchControl: pxOfText(1) else: 0)
  let gaps = 8 * (2 + (if row.typeName.len > 0: 1 else: 0) +
                  (if watchControl: 1 else: 0))
  let caretPx = if row.hasChildren: 15 else: 0
  StateInsetPx + row.depth * StateRowIndentPx + caretPx +
    pxOfText((row.name & ":").runeLen) + controlsPx + gaps +
    StateScrollbarPx +
    (if row.typeName.len > 0: pxOfText(row.typeName.runeLen) else: 0)

proc renderState*(r: GpuiRenderer; parent: GpuiElement; vm: StateVM;
                  pv: var PaneView; budget: Budget): bool =
  ## **THE STATE PANE AS THE DESKTOP DRAWS IT** (`isonim_state_view`,
  ## `components/state.styl`; measured on the Electron front-end 2026-10-17):
  ## the Locals / Globals / Watches control with the watch field beside it,
  ## the stop's code line on its band (the execution mark, the line number,
  ## the source), then one 24 px monospace row per value — the indigo
  ## `name:`, the value, its type, and the history and origin controls — or
  ## the tab's empty-state sentence centred in the pane.
  ##
  ## Drawn from `StateVM`, the ViewModel the other front-ends read. The rows
  ## keep the click model's attributes (`ViewKindAttribute` / `ViewIdAttribute`
  ## under `state.root`, `data-option-index` under `state.tabs`,
  ## `StateControlAttribute`, `StateAddWatchAttribute`), so a press does what
  ## it did when this pane was the vocabulary's two-column table (PLAT35-F4,
  ## superseded: the desktop draws no table).
  if vm.isNil:
    return false
  let rows = stateRows(vm, budget)
  let body = r.createElement("div")
  r.setAttribute(body, "data-ct-state", "desktop")
  r.setStyle(body, "display", "flex")
  r.setStyle(body, "flex-direction", "column")
  r.setStyle(body, "flex-grow", "1")
  r.setStyle(body, "height", "100%")
  r.setStyle(body, "font-family", MonoFontFamily)

  # The tabs and the watch field.
  let head = r.createElement("div")
  r.setStyle(head, "display", "flex")
  r.setStyle(head, "items", "center")
  r.setStyle(head, "flex-shrink", "0")
  r.setStyle(head, "height", "26px")
  r.setStyle(head, "padding-left", $StateInsetPx & "px")
  r.setStyle(head, "gap", "6px")
  # ONE LIST, NO TABS (Variable-State-Pane.md § Decisions, 2026-10-24). The
  # head offers "Hide watches from other processes" only when some watch was
  # added in another process (or while it is on).
  var otherProcess = vm.hideOtherProcessWatches.val
  if not otherProcess and vm.recordingId.len > 0:
    for _, origin in vm.watchOrigins.val:
      if origin.len > 0 and origin != vm.recordingId:
        otherProcess = true
        break
  if otherProcess:
    let hide = vm.hideOtherProcessWatches.val
    let t = stateText(r, (if hide: "◉ " else: "○ ") &
                         "Hide watches from other processes",
                      StateEmptyColour, 12, mono = false)
    r.setAttribute(t, StateControlAttribute, "hide-other-process-watches:" &
                                             (if hide: "off" else: "on"))
    r.appendChild(head, t)
  # The watch field: a press opens the omnibox on `:watch ` (the window's
  # one text field), as this pane's watch row did.
  let field = r.createElement("div")
  r.setAttribute(field, StateAddWatchAttribute, "true")
  r.setStyle(field, "display", "flex")
  r.setStyle(field, "items", "center")
  r.setStyle(field, "flex-shrink", "1")
  r.setStyle(field, "flex-grow", "1")
  r.setStyle(field, "max-width", $StateWatchFieldPx & "px")
  r.setStyle(field, "margin-right", "11px")
  r.setStyle(field, "height", "26px")
  r.setStyle(field, "padding-left", "11px")
  r.setStyle(field, "padding-right", "12px")
  r.setStyle(field, "rounded", "6px")
  r.setStyle(field, "border-width", "1px")
  r.setStyle(field, "border-color", StateControlBorder)
  r.setStyle(field, "background-color", DesignTokenHex[dtColorsUiSurfaceBasePanel][dmDark])
  r.setStyle(field, "overflow", "hidden")
  let ph = stateText(r, "Enter a watch expression",
                     DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark], 14,
                     mono = false)
  # Clipped at the CONTENT edge, as an `input` clips its text — the field's
  # own `overflow` clips at its padding edge, 12 px further right.
  let clip = r.createElement("div")
  r.setStyle(clip, "display", "flex")
  r.setStyle(clip, "items", "center")
  r.setStyle(clip, "flex-grow", "1")
  r.setStyle(clip, "flex-shrink", "1")
  r.setStyle(clip, "min-width", "0px")
  r.setStyle(clip, "height", "100%")
  r.setStyle(clip, "overflow", "hidden")
  r.appendChild(clip, ph)
  r.appendChild(field, clip)
  r.appendChild(head, field)
  r.appendChild(body, head)

  # The stop's code line.
  let formatted = vm.codeStateLine.val
  let sep = formatted.find(CodeStateLineSeparator)
  let (number, source) =
    if sep < 0: ("", formatted)
    else: (formatted[0 ..< sep], formatted[sep + CodeStateLineSeparator.len .. ^1])
  let code = r.createElement("div")
  r.setAttribute(code, "data-ct-code-state-line", formatted)
  r.setStyle(code, "display", "flex")
  r.setStyle(code, "items", "center")
  r.setStyle(code, "flex-shrink", "0")
  r.setStyle(code, "height", $StateValueRowPx & "px")
  r.setStyle(code, "margin-top", "8px")
  r.setStyle(code, "padding-left", $StateInsetPx & "px")
  r.setStyle(code, "white-space", "nowrap")
  r.setStyle(code, "overflow", "hidden")
  r.setStyle(code, "background-color", StateCodeLineGround)
  if vm.hasCodeState.val:
    let arrow = r.createElement("img")
    r.setAttribute(arrow, "src", executionMarkPath())
    r.setStyle(arrow, "width", "7px")
    r.setStyle(arrow, "height", "10px")
    r.setStyle(arrow, "flex-shrink", "0")
    r.appendChild(code, arrow)
    let n = stateText(r, number, DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark],
                      14, GutterNumberWeight)
    r.setStyle(n, "padding-left", "6px")
    r.appendChild(code, n)
    let src = stateText(r, source, DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
    r.setStyle(src, "padding-left", "12px")
    r.appendChild(code, src)
  r.appendChild(body, code)

  let table = r.createElement("div")
  r.setAttribute(table, StateTableAttribute, "rows")
  r.setAttribute(table, ViewIdAttribute, StateTreeViewId)
  r.setStyle(table, "display", "flex")
  r.setStyle(table, "flex-direction", "column")
  r.setStyle(table, "overflow", "hidden")
  r.setStyle(table, "margin-top", "12px")
  r.setStyle(table, "padding-left", $StateInsetPx & "px")
  # The rows, moved by the box's scroll (`stateScroll`): the table clips.
  let scroller = r.createElement("div")
  r.setAttribute(scroller, "data-ct-state-scroll",
                 $stateScroll.top & "," & $stateScroll.left)
  r.setStyle(scroller, "display", "flex")
  r.setStyle(scroller, "flex-direction", "column")
  r.setStyle(scroller, "flex-shrink", "0")
  # Each row its natural width, so a long value reaches past the pane and
  # the horizontal scroll brings the rest in.
  r.setStyle(scroller, "items", "start")
  r.setStyle(scroller, "margin-top", $(-stateScroll.top) & "px")
  r.setStyle(scroller, "margin-left", $(-stateScroll.left) & "px")
  if rows.len == 0:
    # The tab's empty state, centred in what is left of the pane.
    r.setStyle(table, "flex-grow", "1")
    r.setStyle(table, "items", "center")
    r.setStyle(table, "justify", "center")
    let msg = stateText(r, stateEmptyText(), StateEmptyColour,
                        14, mono = false)
    r.setAttribute(msg, "data-ct-state-empty", "variables")
    r.appendChild(table, msg)
  # PLAT-70 Part B (Horizontal-Overflow.md §5): EACH ROW FITS THE PANE. The
  # value takes what the row has left after the name, the type and the
  # controls, in characters of the code face; the presenter returns what fits
  # that budget and says whether it cut (`Presentation.truncated`), and a cut
  # value ends in `…` and is reported in `stateCuts` for the window's hover
  # and `…` click. The rows' y is the scroll box's, slot by slot.
  stateCuts = @[]
  let paneW0 = statePaneSizePx.w
  let bodyRows = max(1, (statePaneSizePx.h - StateRowsTopPx) div
                        StateValueRowPx)
  # PLAT-70 Part I (Horizontal-Overflow.md §5.5.3): the rows are one
  # composite column — each row's floor its fixed parts (indent, caret,
  # `name:`, type, controls, gaps) and the first cells of its value; its
  # preferred width the whole value. While every drawn row's floor fits, the
  # rows are fitted to the pane (Part B); else they are laid out at the widest
  # floor and the scroll box scrolls sideways (`stateScroll.left`).
  var composite: seq[CompositeRow]
  for row in rows:
    composite.add variableFitRow(stateFixedPx(vm, row),
                                 oneLine(row.whole).runeLen,
                                 unit = gpuiCellUnits())
  let fit = compositeFit(composite, max(0, paneW0), "row")
  stateFitContentPx = if paneW0 > 0 and fit.overflows: fit.compositeWidth
                      else: 0
  # The width the rows are laid out in: the pane's, or the widest floor.
  let paneW = if stateFitContentPx > 0: stateFitContentPx else: paneW0
  var slot = 0
  template slotTop(): int =
    StateRowsTopPx + slot * StateValueRowPx - stateScroll.top
  for i, row in rows:
    let el = r.createElement("div")
    r.setAttribute(el, StateRowAttribute, $i)
    r.setAttribute(el, StateDepthAttribute, $row.depth)
    r.setAttribute(el, StateSelectedAttribute,
                   (if row.selected: "true" else: "false"))
    r.setAttribute(el, ViewKindAttribute, vocabularyName(pkTree))
    r.setAttribute(el, ViewIdAttribute, row.path)
    r.setStyle(el, "display", "flex")
    r.setStyle(el, "items", "center")
    r.setStyle(el, "flex-shrink", "0")
    r.setStyle(el, "height", $StateValueRowPx & "px")
    r.setStyle(el, "white-space", "nowrap")
    r.setStyle(el, "overflow", "hidden")
    r.setStyle(el, "gap", "8px")
    if row.depth > 0:
      r.setStyle(el, "padding-left", $(row.depth * StateRowIndentPx) & "px")
    # The name: the caret of a compound value, then `name:` in indigo.
    let name = r.createElement("div")
    r.setAttribute(name, StateColumnAttribute, StateNameColumn)
    r.setStyle(name, "display", "flex")
    r.setStyle(name, "items", "center")
    r.setStyle(name, "flex-shrink", "0")
    if row.hasChildren:
      # `.caret-collapse` / `.caret-expand`: the desktop's chevrons
      # (`SHARED_OPEN_FA_ICON`, `SHARED_CLOSE_FA_ICON`) in an 8 px box.
      let box = r.createElement("div")
      r.setStyle(box, "display", "flex")
      r.setStyle(box, "items", "center")
      r.setStyle(box, "justify", "center")
      r.setStyle(box, "width", "8px")
      r.setStyle(box, "height", "8px")
      r.setStyle(box, "flex-shrink", "0")
      let caret = r.createElement("img")
      r.setAttribute(caret, "src", stateIconPath(
        if row.expanded: "caret-open" else: "caret-closed",
        if row.expanded: FileTreeOpenSvg else: FileTreeClosedSvg, "#dddddd"))
      r.setStyle(caret, "width", if row.expanded: "8px" else: "5px")
      r.setStyle(caret, "height", if row.expanded: "5px" else: "8px")
      r.appendChild(box, caret)
      r.appendChild(name, box)
      let gap = r.createElement("div")
      r.setStyle(gap, "width", "7px")
      r.setStyle(gap, "flex-shrink", "0")
      r.appendChild(name, gap)
    r.appendChild(name, stateText(r, row.name & ":", StateNameColour))
    # `name:value` with nothing between (`.value-name` then `.value-view`).
    let pair = r.createElement("div")
    r.setStyle(pair, "display", "flex")
    r.setStyle(pair, "items", "center")
    r.setStyle(pair, "flex-shrink", "0")
    r.appendChild(pair, name)
    r.appendChild(el, pair)
    let changed = vm.isChanged(row.path)
    r.setAttribute(el, StateChangedAttribute, (if changed: "true" else: "false"))
    # The value's cells: the pane less the row's indent, the caret, the
    # `name:`, the type, the controls and the gaps between them.
    let watchControl = row.isWatch
    let controlsPx = 20 + 20 + (if watchControl: pxOfText(1) else: 0)
    let gaps = 8 * (2 + (if row.typeName.len > 0: 1 else: 0) +
                    (if watchControl: 1 else: 0))
    let caretPx = if row.hasChildren: 15 else: 0
    let valueX = StateInsetPx + row.depth * StateRowIndentPx + caretPx +
                 pxOfText((row.name & ":").runeLen)
    let roomPx = paneW - valueX - controlsPx - gaps - StateScrollbarPx -
                 (if row.typeName.len > 0: pxOfText(row.typeName.runeLen)
                  else: 0)
    # (No pane size yet — a plan drawn before the window laid out — fits all.)
    let cells = if paneW <= 0: high(int) div 2 else: cellsInPx(roomPx)
    let fitted =
      if row.presented.isNil:
        # PLAT-71 (§9.2): a number is never cut silently.
        fitCellAs(row.whole, cells,
                  (if isNumberText(row.whole): ckNumber else: ckEnd))
      else:
        var b = budget
        if paneW > 0: b.cells = max(1, cells)
        let p = present(row.presented, b)
        presentedCell(oneLine(p.root.text),
                      (if p.truncated: fullValueText(row.presented, row.whole)
                       else: p.root.text),
                      p.truncated)
    # One line, as the desktop's `white-space: nowrap` collapses a value's
    # newlines and runs of space; in the warning tier (`.value-expanded-text`),
    # the changed accent when the step changed it.
    let value = stateText(r, oneLine(fitted.text),
                          if changed: StateChangedColour else: StateValueTextColour)
    r.setAttribute(value, StateColumnAttribute, StateValueColumn)
    if fitted.truncated:
      r.setAttribute(value, TableCutAttribute, StateValueColumn)
      let drawn = fitted.text.runeLen
      stateCuts.add CutCell(row: slotTop(), height: StateValueRowPx,
                            col: valueX, width: pxOfText(drawn),
                            ellipsisCol: valueX + pxOfText(drawn - 1),
                            ellipsisWidth: pxOfText(1),
                            key: row.path, column: StateValueColumn,
                            full: fitted.full)
    r.appendChild(pair, value)
    if row.typeName.len > 0:
      r.appendChild(el, stateText(r, row.typeName, StateTypeColour))
    let historyOpen = row.path in vm.expandedHistories.val
    let originOpen = row.path in vm.originLines.val
    r.appendChild(el, stateIconButton(r, "history:" & row.path, "history",
                                      HistoryToggleSvg, historyOpen))
    let summary = vm.originSummaryFor(row.name)
    let icon = if summary.isSome:
                 iconClassForTerminator(summary.get.terminatorKind).replace(
                   "ct-origin-icon-", "")
               else: "question"
    r.appendChild(el, stateIconButton(r, "origin:" & row.path, icon,
                                      originIconSvg(icon), originOpen))
    if row.isWatch:
      let c = stateText(r, "×", StateEmptyColour, mono = false)
      r.setAttribute(c, StateControlAttribute, "unwatch:" & row.name)
      r.appendChild(el, c)
    r.appendChild(scroller, el)
    inc slot
    # The full value under the row, wrapped in the value's column (§5.3).
    if tableDetail.isOpen(StateDetailPane, row.path):
      let full = fullValueText(row.presented, row.whole)
      for line in detailView(full, max(1, cells), bodyRows,
                             tableCopyChord).lines:
        let d = r.createElement("div")
        r.setAttribute(d, TableDetailAttribute, row.path)
        r.setStyle(d, "flex-shrink", "0")
        r.setStyle(d, "height", $StateValueRowPx & "px")
        r.setStyle(d, "padding-left", $valueX & "px")
        r.setStyle(d, "white-space", "nowrap")
        r.appendChild(d, stateText(r, line, StateValueTextColour))
        r.appendChild(scroller, d)
        inc slot
    if historyOpen:
      for e in vm.valueHistory.val.getOrDefault(row.path):
        let h = r.createElement("div")
        r.setAttribute(h, StateHistoryEntryAttribute, $e.locationTicks)
        r.setStyle(h, "display", "flex")
        r.setStyle(h, "flex-shrink", "0")
        r.setStyle(h, "height", $StateValueRowPx & "px")
        r.setStyle(h, "items", "center")
        r.setStyle(h, "gap", "8px")
        r.setStyle(h, "padding-left", $((row.depth + 1) * StateRowIndentPx) & "px")
        r.appendChild(h, stateText(r, "tick " & $e.locationTicks, StateEmptyColour))
        r.appendChild(h, stateText(r, e.valueText, StateValueColour))
        r.appendChild(scroller, h)
        inc slot
    if originOpen:
      for i, hop in vm.originLines.val.getOrDefault(row.path):
        let o = r.createElement("div")
        r.setAttribute(o, StateOriginHopAttribute, $i)
        r.setStyle(o, "flex-shrink", "0")
        r.setStyle(o, "height", $StateValueRowPx & "px")
        r.setStyle(o, "padding-left", $((row.depth + 1) * StateRowIndentPx) & "px")
        r.appendChild(o, stateText(r, "⇠ " & hop, StateEmptyColour))
        r.appendChild(scroller, o)
        inc slot
  if childCount(scroller) > 0:
    r.appendChild(table, scroller)
  r.appendChild(body, table)
  r.appendChild(parent, body)
  stateScrollbars(r, parent, rows, childCount(scroller))
  true

# ---------------------------------------------------------------------------
# The event log's FOOTER and its HEADER ROW — `PLAT35-F5` and `PLAT35-F12`
# ---------------------------------------------------------------------------

const
  EventLogFooterAttribute* = "data-event-log-footer"
    ## **THE ROW-COUNT FOOTER** (`PLAT35-F5`). The pane drew none at all:
    ## measured at `3e2a5c5ba`, the body was ONE vocabulary `Table` whose
    ## children are the header texts and six `data-row-index` rows, with no
    ## footer node and no count-bearing attribute anywhere in the subtree
    ## (`grep -i footer src/frontend/gpui/app/leaves.nim` returned nothing).
    ##
    ## **IT CARRIES NO `data-column-index`, AND THAT IS LOAD-BEARING RATHER
    ## than cosmetic.** `window_clicks` classifies a press inside the
    ## `eventLog` context as a HEADER CELL when the element has a
    ## `data-column-index` and its parent has no `data-row-index`
    ## (`window_clicks.nim:211-217`) — which is exactly the shape a footer
    ## built out of column cells would have. Such a footer would re-sort the
    ## log when clicked, which is `PLAT35-F7`'s clause in reverse: an element
    ## that does a thing it does not advertise. The footer is a plain `div`
    ## appended AFTER the table element for the same reason, so the table's
    ## own subtree — every `data-row-index`, `data-column-index` and
    ## `data-cell` the vocabulary binding wrote, and the column arithmetic in
    ## `tableColumnWidthsPx` — is left BYTE-FOR-BYTE as it was.
  EventLogTotalAttribute* = "data-event-log-total"
    ## The number the footer's `of N` was computed from, published so a test
    ## can assert WHICH number it is rather than that a number is present.
    ##
    ## **THE DISTINCTION THIS ATTRIBUTE EXISTS TO MAKE.** A footer that
    ## counted the rows it holds would read `6` on a recording with thousands
    ## of events, and `Event-Log-Pane.md`'s Requirement says why it cannot be
    ## computed that way: the counts come from `ct/update-table`'s
    ## `recordsTotal` / `recordsFiltered`, and *"no single window can supply
    ## them: they describe the whole log and the whole filtered log, not the
    ## rows in hand"*. `rows` is ONE WINDOW — `store.eventLog.loadedStart`
    ## says which — so `rows.len` is wrong outright once the pane has paged.
  EventLogHeaderAttribute* = "data-event-log-header"
    ## **THE HEADER ROW, MARKED AND STYLED AS ONE** (`PLAT35-F12`, the two
    ## sub-claims that are grounded). Measured at `3e2a5c5ba`: all six
    ## `data-row-index` rows and the header share ONE style object,
    ## `{gap: 12px, display: flex, white_space: nowrap}` — `layOutRow` in
    ## `gpui_binding.nim:486` applies the same three declarations to `head`
    ## and to every body `tr` — so the header was the same weight and colour
    ## as a data row. Since 2026-10-17 `renderEventLog` draws the header as
    ## the desktop does: its own 25 px row in the code face's bold.

proc eventLogTotalOf*(windowStart, shown, total: int): int =
  ## **THE NUMBER THE FOOTER'S `of N` IS, DECIDED ONCE.** The drawn string and
  ## the published `EventLogTotalAttribute` both read it from here, so the
  ## attribute a test asserts on and the text a user reads cannot disagree —
  ## the shape `data-state-value-x` took one pane over when the state pane
  ## was a two-column table (§30). The clamp below was written out twice — once for the
  ## string and once for the attribute — until it was written here once.
  ##
  ## THE FLOOR IS THE STORE'S OWN ARITHMETIC, NOT A COUNT OF THE ROWS IN HAND.
  ## `recordsTotal` is a high-water mark, and the store raises it exactly this
  ## way when a producer supplies none (`replay_data_store.nim:1640-1641`). It
  ## can only lift `N` to something already known to have ARRIVED, and on any
  ## window whose total is larger it does nothing at all.
  max(total, windowStart + shown)

proc eventLogFooterText*(windowStart, shown, total: int): string =
  ## **`Rows N to M of T`** — the desktop's own footer, to the byte.
  ##
  ## `PLAT35-PD2` records the Electron pane's footer as **`Rows 1 to 6 of 6`**
  ## and §6 makes the desktop the reference, so the shape is carried across
  ## rather than chosen. The web front-end builds the same three fields out of
  ## DataTables — `viewmodel/views/isonim_event_log_view.nim:399-411` nests
  ## `Rows` / `to` / `of` around a `data-tables-footer-input`, a
  ## `data-tables-footer-end-row` and a `data-tables-footer-rows-count` — so
  ## this spelling CONVERGES on the two front-ends that have a footer instead
  ## of adding a third. (PD2's complaint about Electron is a different one —
  ## no column headers, and one row drawn six times — and neither defect is
  ## imported here: the columns and headers are already right in GPUI, which
  ## is the half of the finding that passed.)
  ##
  ## A PURE FUNCTION OF THREE INTEGERS, so the formula is asserted without a
  ## renderer, a window or a session.
  ##
  ## **WHY `T` IS FLOORED BY THE WINDOW.** `store.eventLog.recordsTotal` is
  ## documented as a HIGH-WATER MARK rather than the engine's count —
  ## *"`ct/event-load`'s response body carries `events`, `content` and
  ## `markers` and no total, so the only honest total available here is
  ## derived from what has arrived"* (`replay_data_store.nim:212-219`) — and
  ## the store itself floors it exactly this way when the producer supplies
  ## none: `recordsTotal.val = max(recordsTotal.val, start + rows.len)`
  ## (`replay_data_store.nim:1640-1641`). So the floor is the store's own
  ## arithmetic repeated at the last moment, NOT a count of the rows in hand:
  ## it can only raise `T` to something already known to have arrived, and on
  ## every window where the total is larger — every paged or `update-table`
  ## window — it does nothing at all. Without it a pane whose total had not
  ## been published yet would print `Rows 1 to 6 of 0`, a footer visibly
  ## disagreeing with the rows above it.
  let first = windowStart + 1
  let last = windowStart + shown
  result = "Rows " & $first & " to " & $last & " of " &
           $eventLogTotalOf(windowStart, shown, total)

const
  EventToolbarPx* = 30
    ## The event log's toolbar row (`.ct-flex`): the menu button, the find
    ## field and the column picker, 26 px high.
  EventHeaderPx* = 25
    ## The column header row (`.eventLog-column-header`).
  EventRowPitch* = 27.5
    ## A row (`tr`, 28 / 27 px alternating): the tick over its progress bar.
  EventFooterPx* = 33
    ## The pager (`.data-tables-footer`), pinned to the pane's foot.
  EventTickColPx = 105
  EventIndexColPx = 49
  EventKindColPx = 23
  EventTextLeadPx = 14
  EventBarFill = DesignTokenHex[dtColorsUiBorderAction][dmDark]
  EventBarTrack = "#38393a"
  EventSelectedGround = DesignTokenHex[dtColorsEditorSurfaceSelect][dmDark]

var
  eventLogNowTicks* = 0'u64
    ## The debugger's tick, set by the window before it draws the event log:
    ## an event after it is a FUTURE event, drawn at half strength
    ## (`tr.future`), and the first event at or after it is the selected row.
  eventLogPaneWidthPx* = 0
    ## The event log body's width, set by the window: the tick column is a
    ## tenth of it (measured 105 of 1047 px, 78 of 783 px).

func eventRowTopPx*(i: int): int =
  ## Row `i`'s top below the first row's, at the desktop's pitch.
  int(round(float(i) * EventRowPitch))

proc eventCell(r: GpuiRenderer; widthPx: int; padLeft = 0): GpuiElement =
  result = r.createElement("div")
  r.setStyle(result, "display", "flex")
  r.setStyle(result, "items", "center")
  r.setStyle(result, "flex-shrink", "0")
  r.setStyle(result, "white-space", "nowrap")
  r.setStyle(result, "overflow", "hidden")
  if widthPx > 0:
    r.setStyle(result, "width", $widthPx & "px")
  else:
    r.setStyle(result, "flex-grow", "1")
    r.setStyle(result, "min-width", "0")
  if padLeft > 0:
    r.setStyle(result, "padding-left", $padLeft & "px")

proc eventField(r: GpuiRenderer; widthPx, heightPx: int): GpuiElement =
  ## A bordered box on the panel surface (`.ct-input-panel`).
  result = r.createElement("div")
  r.setStyle(result, "display", "flex")
  r.setStyle(result, "items", "center")
  r.setStyle(result, "flex-shrink", "0")
  if widthPx > 0: r.setStyle(result, "width", $widthPx & "px")
  r.setStyle(result, "height", $heightPx & "px")
  r.setStyle(result, "rounded", "6px")
  r.setStyle(result, "border-width", "1px")
  r.setStyle(result, "border-color", DesignTokenHex[dtColorsUiBorderSecondary][dmDark])
  r.setStyle(result, "background-color", DesignTokenHex[dtColorsUiSurfaceBasePanel][dmDark])

const
  FileTreeRowPx* = 24
    ## A file-tree row (`.jstree-wholerow`, 1.5em).
  FileTreeIndentPx* = 8
    ## A child's offset per level.
  FileTreeTwistyLeft = 16
    ## The disclosure chevron's left at depth 0, from the pane's content edge.
  FileTreeIconLeft = 33
  FileTreeTextLeft = 55
  DeviconPythonColour = "#46788d"
    ## The Python mark's colour in the desktop's tree (measured 2026-10-17).

proc fileTreeRows(vm: FilesystemVM; e: FilesystemEntryNode; path: string;
                  depth: int; acc: var seq[tuple[node: FilesystemEntryNode;
                                                  path: string; depth: int;
                                                  open: bool]]) =
  let open = e.children.len > 0 and vm.isExpanded(e.path)
  acc.add (e, path, depth, open)
  if open:
    for i, c in e.children:
      fileTreeRows(vm, c, path & "." & $i, depth + 1, acc)

# ---------------------------------------------------------------------------
# M71 (#838): the panes whose whole content is in hand — Files and VCS (and
# the state pane, whose own scroll box is above) — keep an ORDINARY scrollbar
# (Scrollbar-Scrubbers.md §2): they scroll by rows with the wheel, and the
# window draws them the list scrubber (`list_scrubber`, its §3 press and
# drag) while their rows overflow. The window measures how many rows each
# body holds and keeps the reader's place here, as it does `stateScroll`.
# ---------------------------------------------------------------------------

const
  VcsRowPx* = 24
    ## The VCS pane's row pitch: every caption and every row one line this
    ## high (`pinVcsRowPitch`), so its rows and its scrollbar agree.
  FileTreeFirstAttribute* = "data-ct-file-tree-first"
    ## On the file tree's view: the index of its first row drawn.
  FilesFieldAttribute* = "data-ct-files-field"
    ## On the Files pane's open name field: `create` or `rename`.
  FilesFieldTextAttribute* = "data-ct-files-field-text"
    ## On it, too: the name typed so far.
  FilesFieldErrorAttribute* = "data-ct-files-field-error"
    ## On the line under the field: why the name typed was refused.
  FilesQuestionAttribute* = "data-ct-files-question"
    ## On Delete's question: the path it asks about.
  VcsScrollAttribute* = "data-ct-vcs-scroll"
    ## On the VCS pane's scroll box: the index of the first row shown.

var fileTreeScroll*: tuple[top, rows: int] = (0, 0)
  ## The Files pane: the first row the reader scrolled to, and how many rows
  ## its body holds (set by the window from its geometry; 0 — not measured —
  ## draws every row).
var vcsScroll*: tuple[top, rows, total: int] = (0, 0, 0)
  ## The VCS pane's, likewise — and (`total`) how many rows it listed
  ## when last drawn (`vocabularyRows` of its view), which its scrollbar
  ## spans.

func inHandTop*(top, total, rows: int): int =
  ## `top` kept inside a list of `total` rows of which `rows` show.
  if rows <= 0: 0 else: max(0, min(top, total - rows))

type
  FileTreeLineKind* = enum
    ## What one drawn line of the Files pane is.
    ftlEntry      ## A row of the tree.
    ftlField      ## Create's name field: the first child of its folder.
    ftlReason     ## Why the name typed was refused, under the field.
    ftlQuestion   ## Delete's question, under the entry it asks about.

  FileTreeLine = tuple[kind: FileTreeLineKind; row: int; depth: int]
    ## `row`: the tree row the line belongs to (`fileTreeRows`' index).

proc fileTreeLines(vm: FilesystemVM;
                   rows: seq[tuple[node: FilesystemEntryNode; path: string;
                                   depth: int; open: bool]]):
    seq[FileTreeLine] =
  ## The pane's lines: the tree's rows, with the model's open name field
  ## (Filesystem-Pane.md § "Create and Rename": Create's as the first child
  ## of its folder, Rename's in place of the row's label), the reason a name
  ## was refused under it, and Delete's question under its entry.
  let edit = vm.nameEdit.val
  for i, row in rows:
    result.add (ftlEntry, i, row.depth)
    let p = row.node.path
    if p.len == 0:
      continue
    if edit.kind == fneCreate and p == edit.folder:
      result.add (ftlField, i, row.depth + 1)
      if edit.error.len > 0:
        result.add (ftlReason, i, row.depth + 1)
    elif edit.kind == fneRename and p == edit.path and edit.error.len > 0:
      result.add (ftlReason, i, row.depth)
    if vm.pendingDelete.len > 0 and p == vm.pendingDelete:
      result.add (ftlQuestion, i, row.depth)

proc fileTreeRowCount*(vm: FilesystemVM): int =
  ## Every line the Files pane lists at its expansion (what `renderFileTree`
  ## draws a window of): the rows, and an open name field or question.
  if vm.isNil:
    return 0
  let root = vm.rootEntry.val
  if root.children.len == 0:
    return 0
  var rows: seq[tuple[node: FilesystemEntryNode; path: string; depth: int;
                      open: bool]] = @[]
  fileTreeRows(vm, root, "fileTree", 0, rows)
  fileTreeLines(vm, rows).len

proc vocabularyRows*(v: ViewNode): int =
  ## The lines a vocabulary subtree draws at one line each (the VCS pane's
  ## pitch, `pinVcsRowPitch`): a caption or a text is one, a list one per
  ## option, a collapsed section its caption alone.
  if v.isNil:
    return 0
  case v.kind
  of pkList, pkSelect, pkMenu:
    return v.options.len
  of pkText, pkMarkdown:
    return 1
  else: discard
  if v.label.len > 0:
    result = 1
  if v.kind != pkCollapsible or v.expanded:
    for c in v.children:
      result += vocabularyRows(c)

const VcsCommitOptionPrefix = "commit-"
  ## The id of a commit's row in the VCS view's `vcs.commits.list`
  ## (`pane_views.vcsPaneView`); an opened commit's file rows are
  ## `commitfile-…`, which this prefix does not match.

proc commitRowsAbove(v: ViewNode; line: int; at: var int): int =
  ## The commit rows `v` draws above pane line `line`, walking the view in
  ## `vocabularyRows`'s order and arithmetic; `at` is the line `v` starts on
  ## and leaves the line after it.
  if v.isNil:
    return 0
  case v.kind
  of pkList, pkSelect, pkMenu:
    for o in v.options:
      if at < line and o.id.startsWith(VcsCommitOptionPrefix):
        inc result
      inc at
    return
  of pkText, pkMarkdown:
    inc at
    return
  else: discard
  if v.label.len > 0:
    inc at
  if v.kind != pkCollapsible or v.expanded:
    for c in v.children:
      result += commitRowsAbove(c, line, at)

proc vcsHistoryWindow*(view: ViewNode; top, rows: int):
    tuple[rows, firstRow: int] =
  ## What the VCS pane drawn from `view` gives its commit history
  ## (Viewport-Driven-Loading V6): the `rows` its body holds, and how many
  ## commits are listed above the first row shown at the reader's `top` (as
  ## `renderVcsScrolled` clamps it) — the history list's viewport, which the
  ## window reports through `gpui_host.followGpuiVcsViewport`. Commit ROWS
  ## are counted, so the captions, the working tree and an opened commit's
  ## files are not mistaken for history. `(0, 0)` for an unmeasured body.
  if rows <= 0 or view.isNil:
    return (0, 0)
  let shownTop = inHandTop(top, vocabularyRows(view), rows)
  var at = 0
  (rows, commitRowsAbove(view, shownTop, at))

proc pinVcsRowPitch(r: GpuiRenderer; el: GpuiElement) =
  ## Every element of the VCS pane's vocabulary tree on one `VcsRowPx` line:
  ## a caption's text and an option's row alike, never wrapped, so the
  ## pane's row index and its pixels are one arithmetic.
  if el.isNil:
    return
  r.setStyle(el, "line-height", $VcsRowPx & "px")
  r.setStyle(el, "white-space", "nowrap")
  r.setStyle(el, "flex-shrink", "0")
  if getAttribute(el, "data-option-index").len > 0:
    r.setStyle(el, "height", $VcsRowPx & "px")
    r.setStyle(el, "overflow", "hidden")
  for i in 0 ..< childCount(el):
    r.pinVcsRowPitch(nthChild(el, i))

proc renderVcsScrolled(r: GpuiRenderer; parent, content: GpuiElement;
                       view: ViewNode) =
  ## The VCS pane's vocabulary tree in a clipping box, moved up by the rows
  ## the reader scrolled past.
  r.pinVcsRowPitch(content)
  let total = vocabularyRows(view)
  vcsScroll.total = total
  let top = inHandTop(vcsScroll.top, total,
                      if vcsScroll.rows > 0: vcsScroll.rows else: total)
  let box = r.createElement("div")
  r.setAttribute(box, VcsScrollAttribute, $top)
  r.setStyle(box, "display", "flex")
  r.setStyle(box, "flex-direction", "column")
  r.setStyle(box, "flex-grow", "1")
  r.setStyle(box, "overflow", "hidden")
  let scroller = r.createElement("div")
  r.setStyle(scroller, "display", "flex")
  r.setStyle(scroller, "flex-direction", "column")
  r.setStyle(scroller, "flex-shrink", "0")
  r.setStyle(scroller, "margin-top", $(-top * VcsRowPx) & "px")
  r.appendChild(scroller, content)
  r.appendChild(box, scroller)
  r.appendChild(parent, box)

proc renderFileTree*(r: GpuiRenderer; parent: GpuiElement;
                     vm: FilesystemVM): bool =
  ## **THE FILE TREE AS THE DESKTOP DRAWS IT** (`isonim_filesystem_view`'s
  ## jstree markup, measured 2026-10-17): a 24 px row per entry, 8 px a level,
  ## the folder's chevron, its outlined folder icon or the file's type mark
  ## (the `devicon` glyph its extension maps to), and the name in the body
  ## face. The rows carry the vocabulary `Tree`'s ids (`fileTree`,
  ## `fileTree.0`, …) under a `fileTree` root, so a press opens and closes a
  ## folder or opens a file as it did. False when nothing is loaded.
  if vm.isNil:
    return false
  let root = vm.rootEntry.val
  if root.children.len == 0:
    return false
  var rows: seq[tuple[node: FilesystemEntryNode; path: string; depth: int;
                      open: bool]] = @[]
  fileTreeRows(vm, root, "fileTree", 0, rows)
  let tree = r.createElement("div")
  r.setAttribute(tree, ViewIdAttribute, "fileTree.view")
  r.setStyle(tree, "display", "flex")
  r.setStyle(tree, "flex-direction", "column")
  let rootMark = r.createElement("div")
  r.setAttribute(rootMark, ViewIdAttribute, "fileTree")
  r.setStyle(rootMark, "display", "flex")
  r.setStyle(rootMark, "flex-direction", "column")
  # M71 (#838): THE ROWS THE BODY HOLDS, from the reader's place — the tree
  # scrolls (the wheel, its scrollbar: `main.drawListScrubbers`) instead of
  # clipping every row past the pane's foot. Unmeasured (no window: the leaf
  # plan), every row.
  let lines = fileTreeLines(vm, rows)
  let shown = if fileTreeScroll.rows > 0: fileTreeScroll.rows else: lines.len
  let top = inHandTop(fileTreeScroll.top, lines.len, shown)
  r.setAttribute(tree, FileTreeFirstAttribute, $top)
  let edit = vm.nameEdit.val
  proc fieldText(): string =
    vm.nameEditDraft & "▏"
  for k in top ..< min(lines.len, top + shown):
    let line = lines[k]
    let row = rows[line.row]
    if line.kind != ftlEntry:
      # The model's name field, its refusal, or Delete's question: a line of
      # the tree's height, at its depth, NOT a `Tree` row (no click is wired
      # to it, and no row id names it).
      let el = r.createElement("div")
      r.setStyle(el, "display", "flex")
      r.setStyle(el, "items", "center")
      r.setStyle(el, "flex-shrink", "0")
      r.setStyle(el, "height", $FileTreeRowPx & "px")
      r.setStyle(el, "white-space", "nowrap")
      r.setStyle(el, "padding-left",
                 $(line.depth * FileTreeIndentPx + FileTreeIconLeft) & "px")
      r.setStyle(el, "font-family", WindowFontFamily)
      case line.kind
      of ftlField:
        let box = r.createElement("div")
        r.setAttribute(box, FilesFieldAttribute, "create")
        r.setAttribute(box, FilesFieldTextAttribute, vm.nameEditDraft)
        r.setStyle(box, "border-width", "1px")
        r.setStyle(box, "border-color",
                   DesignTokenHex[dtColorsUiBorderAction][dmDark])
        r.setStyle(box, "padding-left", "4px")
        r.setStyle(box, "padding-right", "4px")
        r.setStyle(box, "line-height", "20px")
        r.setStyle(box, "color",
                   DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
        r.appendChild(box, r.createTextNode(fieldText()))
        r.appendChild(el, box)
      of ftlReason:
        r.setAttribute(el, FilesFieldErrorAttribute, edit.error)
        r.setStyle(el, "color",
                   DesignTokenHex[dtColorsUiTextErrorPrimary][dmDark])
        r.appendChild(el, r.createTextNode(edit.error))
      of ftlQuestion:
        r.setAttribute(el, FilesQuestionAttribute, vm.pendingDelete)
        r.setStyle(el, "color",
                   DesignTokenHex[dtColorsUiTextWarningPrimary][dmDark])
        r.appendChild(el, r.createTextNode(deletePrompt(vm.pendingDelete) &
          "  Enter moves it to the trash, Escape keeps it"))
      of ftlEntry: discard
      r.appendChild(rootMark, el)
      continue
    let el = r.createElement("div")
    r.setAttribute(el, ViewKindAttribute, vocabularyName(pkTree))
    r.setAttribute(el, ViewIdAttribute, row.path)
    r.setStyle(el, "display", "flex")
    r.setStyle(el, "items", "center")
    r.setStyle(el, "flex-shrink", "0")
    r.setStyle(el, "height", $FileTreeRowPx & "px")
    r.setStyle(el, "white-space", "nowrap")
    r.setStyle(el, "position", "relative")
    let indent = row.depth * FileTreeIndentPx
    let folder = row.node.children.len > 0
    proc place(child: GpuiElement; left, top, w, h: int) =
      # In a positioned box of its own: the shim places a `div`, not an `img`.
      let slot = r.createElement("div")
      r.setStyle(slot, "position", "absolute")
      r.setStyle(slot, "left", $(indent + left) & "px")
      r.setStyle(slot, "top", $top & "px")
      r.setStyle(slot, "width", $w & "px")
      r.setStyle(slot, "height", $h & "px")
      r.setStyle(child, "width", $w & "px")
      r.setStyle(child, "height", $h & "px")
      r.appendChild(slot, child)
      r.appendChild(el, slot)
    if folder:
      let tw = r.createElement("img")
      r.setAttribute(tw, "src", stateIconPath(
        if row.open: "tree-open" else: "tree-closed",
        if row.open: FileTreeOpenSvg else: FileTreeClosedSvg, "#999999"))
      if row.open: place(tw, FileTreeTwistyLeft, 10, 8, 4)
      else: place(tw, FileTreeTwistyLeft + 2, 8, 4, 8)
      let icon = r.createElement("img")
      r.setAttribute(icon, "src", stateIconPath("tree-folder", FileTreeFolderSvg,
                                                "#cccccc"))
      place(icon, FileTreeIconLeft, 4, 16, 16)
    else:
      let mark = deviconSvgFor(row.node.text)
      let icon = r.createElement("img")
      if mark.len > 0:
        r.setAttribute(icon, "data-ct-file-icon", row.node.text)
        let ink = if mark == deviconSvgFor("x.py"): DeviconPythonColour
                  else: DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark]
        r.setAttribute(icon, "src", stateIconPath(
          "devicon-" & $hash(mark), mark, ink))
        place(icon, FileTreeIconLeft + 1, 4, 14, 15)
      else:
        r.setAttribute(icon, "src", stateIconPath("tree-file", FileTreeFileSvg,
                                                  "#cccccc"))
        place(icon, FileTreeIconLeft + 1, 4, 16, 16)
    let label = r.createElement("div")
    r.setStyle(label, "font-family", WindowFontFamily)
    r.setStyle(label, "color", DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
    r.setStyle(label, "position", "absolute")
    r.setStyle(label, "left", $(indent + FileTreeTextLeft + (if folder: 0 else: 1)) & "px")
    r.setStyle(label, "top", "0px")
    r.setStyle(label, "line-height", "24px")
    r.setStyle(label, "white-space", "nowrap")
    if edit.kind == fneRename and row.node.path.len > 0 and
       row.node.path == edit.path:
      # Rename's field in place of the label, holding the name typed so far.
      r.setAttribute(label, FilesFieldAttribute, "rename")
      r.setAttribute(label, FilesFieldTextAttribute, vm.nameEditDraft)
      r.setStyle(label, "border-width", "1px")
      r.setStyle(label, "border-color",
                 DesignTokenHex[dtColorsUiBorderAction][dmDark])
      r.setStyle(label, "line-height", "22px")
      r.setStyle(label, "padding-left", "4px")
      r.setStyle(label, "padding-right", "4px")
      r.appendChild(label, r.createTextNode(fieldText()))
    else:
      r.appendChild(label, r.createTextNode(row.node.text))
    r.appendChild(el, label)
    r.appendChild(rootMark, el)
  r.appendChild(tree, rootMark)
  r.appendChild(parent, tree)
  true

var eventLogPaneHeightPx* = 0
  ## The event log body's height, set by the window (the open detail's cap).

const
  EventRowsTopPx* = 8 + EventToolbarPx + EventHeaderPx
    ## The first event row's top below the pane body's: the body's 8 px inset,
    ## the toolbar, the header.
  EventHeaderTopPx* = 8 + EventToolbarPx
  EventSeparatorPx* = 6
    ## PLAT-70 Part B: a column separator's grip, at the right edge of its
    ## header cell (the cursor is `col-resize` there, Pointer-Affordances).
  EventDetailPane* = EventLogTablePane
    ## The event log's name in a `DetailToggle` (the terminal's).

proc eventCellTextOf*(ev: EventLogRow; col: EventLogColumn): string =
  ## What `col` says about `ev`, whole — the cell before it is fitted.
  case col
  of elcIndex: $ev.eventIndex
  of elcKind: ""
  of elcLocation:
    (if ev.file.len == 0: ""
     else: ev.file.rsplit('/', maxsplit = 1)[^1] & ":" & $ev.line)
  of elcOutput: eventLogText(ev)
  of elcTick: $ev.rrTicks

func eventCellPad(col: EventLogColumn): int =
  case col
  of elcTick: 8
  of elcOutput: EventTextLeadPx
  else: 0

proc eventLogFitPx*(c: EventLogColumns; paneW: int): TableFit =
  ## PLAT-70 Part I (Horizontal-Overflow.md §5.5): the Event Log's columns in
  ## PIXELS, laid out by the shared solver over the pane less its vertical
  ## scrubber — each column's widest drawn cell (`eventLogWidestPx`), the
  ## desktop's default widths as the number columns' least preferred widths,
  ## the minimums in cells of the code face, a width the user set in cells of
  ## `ColumnCellPx`.
  var defaults: array[EventLogColumn, int]
  defaults[elcTick] = if paneW > 0: paneW div 10 else: EventTickColPx
  defaults[elcIndex] = EventIndexColPx
  defaults[elcKind] = EventKindColPx
  fitTable(c.eventLogFitColumns(eventLogWidestPx, defaults,
                                unit = gpuiCellUnits(), userUnit = ColumnCellPx),
           max(0, paneW - TableScrollbarPx), gap = 0)

proc eventColumnsPx*(c: EventLogColumns; paneW: int):
    seq[tuple[col: EventLogColumn; x, w: int]] =
  ## PLAT-70 Part B / Part I: each visible column's left and width in pixels
  ## from the pane body's left, as the solver laid them out
  ## (`eventLogFitPx`) — the ONE layout the header, the rows and the
  ## window's hit-tests read. In SCROLL the columns run past the pane and
  ## the view (`eventLogHView`) moves them; these are the TABLE's
  ## coordinates.
  if paneW <= 0:
    # No width yet (a plan drawn before the window laid out): each column at
    # its preferred width.
    var x = 0
    for f in c.eventLogFitColumns(eventLogWidestPx, (block:
        var d: array[EventLogColumn, int]
        d[elcTick] = EventTickColPx
        d[elcIndex] = EventIndexColPx
        d[elcKind] = EventKindColPx
        d), unit = gpuiCellUnits(), userUnit = ColumnCellPx):
      let (ok, col) = parseEventLogColumn(f.name)
      if ok:
        result.add (col, x, f.preferredOf)
        x += f.preferredOf
    return
  let fit = c.eventLogFitPx(paneW)
  let shown = c.visibleColumns
  for k, col in shown:
    if k < fit.widths.len:
      result.add (col, fit.starts[k], fit.widths[k])

proc eventSeparatorAt*(c: EventLogColumns; paneW, x, y: int):
    tuple[found: bool; col: EventLogColumn; left, right: int] =
  ## PLAT-70 Part B: the column whose separator a press at `(x, y)` (from the
  ## pane body's top-left) holds — the grip at the right edge of each header
  ## cell but the last — and that column's left and right edges.
  if y < EventHeaderTopPx or y >= EventRowsTopPx:
    return
  # PLAT-70 Part I: the columns are drawn from the view's `leftCol`.
  let shift = eventLogHView.leftCol
  let cols = c.eventColumnsPx(paneW)
  for k in 0 ..< cols.len - 1:
    let edge = cols[k].x + cols[k].w - shift
    if x >= edge - EventSeparatorPx and x < edge + 2:
      return (true, cols[k].col, cols[k].x - shift, edge)

proc renderEventLog*(r: GpuiRenderer; parent: GpuiElement; vm: EventLogVM;
                     pv: var PaneView): bool =
  ## **THE EVENT LOG AS THE DESKTOP DRAWS IT** (`ui/event_log.nim`'s dense
  ## table, `components/event_log.styl`; measured 2026-10-17): the toolbar —
  ## the menu button, the find field, the column picker — then the header in
  ## the code face's bold, then one row per event: the tick over its progress
  ## bar (the event's share of the recording), the event's number, its kind's
  ## cell and its text (`eventLogText`, `stdout: …`), the current event on
  ## the editor's selection ground; and the pager at the pane's foot,
  ## `Rows [first] to last of total`. Drawn from `EventLogVM`, with the
  ## vocabulary table's own attributes (`data-view-id`, `data-row-index`,
  ## `data-column-index`), so a press does what it did.
  if vm.isNil or pv.report.len > 0:
    return false
  let rows = vm.eventRows.val
  let shown = vm.columns.val.visibleColumns
  let order = vm.order()
  let start = vm.store.eventLog.loadedStart.val
  let maxTicks = max(1'u64, vm.store.eventLog.maxRRTicks.val)
  # The current event: the one the user selected, else the last at or
  # before the debugger's tick (`currentIndex`, or the rows read when the
  # engine named none) — the desktop's `.event-selected`.
  # The selected row: the one the user selected, else the desktop's — the
  # first event at or after the debugger's tick, or the last event when every
  # one is before it.
  # The selected row: the one the user selected, else the table's first —
  # the desktop's DataTables starts with its first row `.event-selected`
  # (measured on both a past and a future window).
  var current = 0
  let sel = vm.selectedRow.val
  if sel.isSome: current = sel.get

  let pane = r.createElement("div")
  r.setStyle(pane, "display", "flex")
  r.setStyle(pane, "flex-direction", "column")
  r.setStyle(pane, "flex-grow", "1")
  r.setStyle(pane, "height", "100%")

  # The toolbar.
  let bar = r.createElement("div")
  r.setAttribute(bar, "data-ct-event-toolbar", "true")
  r.setStyle(bar, "display", "flex")
  r.setStyle(bar, "flex-shrink", "0")
  r.setStyle(bar, "height", $EventToolbarPx & "px")
  r.setStyle(bar, "padding-left", "8px")
  r.setStyle(bar, "padding-right", "8px")
  r.setStyle(bar, "gap", "4px")
  let menu = eventField(r, 26, 26)
  r.setStyle(menu, "justify", "center")
  r.setStyle(menu, "color", DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark])
  r.appendChild(menu, r.createTextNode("⋯"))
  r.appendChild(bar, menu)
  let find = eventField(r, 0, 26)
  r.setStyle(find, "flex-grow", "1")
  r.setStyle(find, "flex-shrink", "1")
  r.setStyle(find, "padding-left", "7px")
  r.setStyle(find, "font-family", WindowFontFamily)
  r.setStyle(find, "font-size", "14px")
  let glass = r.createElement("img")
  r.setAttribute(glass, "src", stateIconPath("search", SearchGlassSvg,
    DesignTokenHex[dtColorsUiIconPrimarySubtle][dmDark]))
  r.setStyle(glass, "width", "14px")
  r.setStyle(glass, "height", "14px")
  r.setStyle(glass, "flex-shrink", "0")
  r.appendChild(find, glass)
  let ph = stateText(r, "Find event", DesignTokenHex[dtColorsUiTextPrimaryLabel][dmDark],
                     14, mono = false)
  r.setStyle(ph, "padding-left", "5px")
  r.appendChild(find, ph)
  r.appendChild(bar, find)
  let columns = r.createElement("div")
  r.setStyle(columns, "display", "flex")
  r.setStyle(columns, "items", "center")
  r.setStyle(columns, "justify", "center")
  r.setStyle(columns, "flex-shrink", "0")
  r.setStyle(columns, "width", "72px")
  r.setStyle(columns, "height", "24px")
  r.setStyle(columns, "rounded", "6px")
  r.setStyle(columns, "background-color", DesignTokenHex[dtColorsUiSurfacePrimaryDefault][dmDark])
  r.setStyle(columns, "font-family", WindowFontFamily)
  r.setStyle(columns, "font-size", "12px")
  r.setStyle(columns, "color", DesignTokenHex[dtColorsUiTextPrimaryBodySubtle][dmDark])
  r.appendChild(columns, r.createTextNode("Columns +"))
  r.appendChild(bar, columns)
  r.appendChild(pane, bar)

  # The table: the header, then the rows.
  let table = r.createElement("div")
  r.setAttribute(table, ViewIdAttribute, "eventLog")
  r.setAttribute(table, ViewKindAttribute, vocabularyName(pkTable))
  r.setStyle(table, "display", "flex")
  r.setStyle(table, "flex-direction", "column")
  r.setStyle(table, "flex-shrink", "1")
  r.setStyle(table, "overflow", "hidden")
  r.setStyle(table, "font-family", MonoFontFamily)
  let head = r.createElement("div")
  r.setAttribute(head, EventLogHeaderAttribute, "true")
  r.setStyle(head, "display", "flex")
  r.setStyle(head, "flex-shrink", "0")
  r.setStyle(head, "height", $EventHeaderPx & "px")
  r.setStyle(head, "font-weight", "600")
  r.setStyle(head, "color", DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
  # PLAT-70 Part I (Horizontal-Overflow.md §5.5): the columns' widths from
  # what the drawn rows hold — each column's widest cell — by the shared
  # solver; in SCROLL the header and the rows move together by the view.
  var widest: array[EventLogColumn, int]
  for ev in rows:
    for col in EventLogColumn:
      if col != elcKind:
        widest[col] = max(widest[col], pxOfText(oneLine(eventCellTextOf(ev, col)).runeLen) +
                                       eventCellPad(col))
  eventLogWidestPx = widest
  let layout = vm.columns.val.eventColumnsPx(eventLogPaneWidthPx)
  let fitPx = vm.columns.val.eventLogFitPx(eventLogPaneWidthPx)
  if eventLogPaneWidthPx > 0:
    eventLogHView.settle(fitPx)
  else:
    eventLogHView = HorizontalView()
  let hLeft = eventLogHView.leftCol
  let scrolls = eventLogPaneWidthPx > 0 and fitPx.overflows
  proc slide(el: GpuiElement) =
    ## A header or body row in SCROLL: as wide as the table, moved by the
    ## view (the table clips).
    if scrolls:
      r.setStyle(el, "width", $fitPx.contentUnits & "px")
      r.setStyle(el, "min-width", $fitPx.contentUnits & "px")
    if hLeft > 0:
      r.setStyle(el, "margin-left", $(-hLeft) & "px")
  slide(head)
  proc widthOf(col: EventLogColumn): int =
    for (c, _, w) in layout:
      if c == col: return w
    0
  proc drawnWidthOf(col: EventLogColumn): int =
    ## The width a cell is DRAWN at: the solver's (PLAT-70 Part I — the
    ## output column's share of the slack included); before the window laid
    ## out, the output column with no width of its own takes the rest.
    if eventLogPaneWidthPx <= 0 and col == elcOutput and
       vm.columns.val.widths[elcOutput] == 0: 0
    else: widthOf(col)
  proc widthOfX(col: EventLogColumn): int =
    for (c, x, _) in layout:
      if c == col: return x
    0
  let barPx = max(10, widthOf(elcTick) - 20)
  eventCuts = @[]
  for ci, col in shown:
    let c = eventCell(r, drawnWidthOf(col), eventCellPad(col))
    r.setAttribute(c, "data-column-index", $ci)
    if col == elcIndex:
      r.setStyle(c, "justify", "center")
    let title = if col == elcKind: "" else: eventLogColumnTitle(col)
    r.appendChild(c, r.createTextNode(title &
      (if order != RecordedEventOrder and order.column == col:
         (if order.ascending: " ▲" else: " ▼")
       else: "")))
    if ci < shown.high:
      # PLAT-70 Part B (§5.2): the separator's grip at the cell's right edge
      # — a drag on it resizes the column (`main.pressEventSeparator`). AFTER
      # the title: the header's first child is its title, which the window's
      # click targets read (`window_clicks`, `gcpEventHeader`).
      r.setStyle(c, "position", "relative")
      let grip = r.createElement("div")
      r.setAttribute(grip, EventSeparatorAttribute, $col)
      r.setStyle(grip, "position", "absolute")
      r.setStyle(grip, "left", $(widthOf(col) - EventSeparatorPx) & "px")
      r.setStyle(grip, "top", "0px")
      r.setStyle(grip, "width", $EventSeparatorPx & "px")
      r.setStyle(grip, "height", $EventHeaderPx & "px")
      r.appendChild(c, grip)
    r.appendChild(head, c)
  r.appendChild(table, head)
  let bodyRows = max(1, int(float(eventLogPaneHeightPx - EventRowsTopPx -
                                  EventFooterPx) / EventRowPitch))
    ## The rows the pane's body holds — the detail's cap is half of them.
  var line = 0
  for i, ev in rows:
    let rowTop = EventRowsTopPx + eventRowTopPx(line)
    let row = r.createElement("div")
    r.setAttribute(row, "data-row-index", $i)
    r.setStyle(row, "display", "flex")
    r.setStyle(row, "flex-shrink", "0")
    r.setStyle(row, "height", $(eventRowTopPx(line + 1) - eventRowTopPx(line)) & "px")
    r.setStyle(row, "color", DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
    slide(row)
    if i == current:
      r.setAttribute(row, "data-ct-event-current", "true")
      r.setStyle(row, "background-color", EventSelectedGround)
    if ev.rrTicks > eventLogNowTicks:
      r.setAttribute(row, "data-ct-event-future", "true")
      r.setStyle(row, "opacity", "0.5")
    for ci, col in shown:
      case col
      of elcTick:
        let c = eventCell(r, widthOf(elcTick), 8)
        r.setAttribute(c, "data-column-index", $ci)
        r.setStyle(c, "flex-direction", "column")
        r.setStyle(c, "items", "start")
        let t = r.createElement("div")
        r.setStyle(t, "height", "21px")
        r.setStyle(t, "line-height", "20px")
        r.setStyle(t, "font-size", "13.6px")
        r.appendChild(t, r.createTextNode($ev.rrTicks))
        r.appendChild(c, t)
        let track = r.createElement("div")
        r.setStyle(track, "display", "flex")
        r.setStyle(track, "width", $barPx & "px")
        r.setStyle(track, "height", "3px")
        r.setStyle(track, "background-color", EventBarTrack)
        let fill = r.createElement("div")
        let share = min(1.0, float(ev.rrTicks) / float(maxTicks))
        r.setStyle(fill, "width", $int(round(share * float(barPx))) & "px")
        r.setStyle(fill, "height", "3px")
        r.setStyle(fill, "background-color", EventBarFill)
        r.appendChild(track, fill)
        r.appendChild(c, track)
        r.appendChild(row, c)
      else:
        let c = eventCell(r, drawnWidthOf(col), eventCellPad(col))
        r.setAttribute(c, "data-column-index", $ci)
        if col == elcIndex:
          # `dt-type-num`, centred in its column.
          r.setStyle(c, "justify", "center")
        # PLAT-70 Part B (§5.1): the cell's text fitted to its column's
        # characters; a cut one ends in `…` and is reported for the hover and
        # the `…` click.
        let full = eventCellTextOf(ev, col)
        let cellX = widthOfX(col)
        let room = widthOf(col) - eventCellPad(col)
        # PLAT-71 (§9.2): the location loses its middle, a number is never
        # cut silently, the output loses its end.
        let kind = cutKindOf(EventLogTablePane, $col)
        let fitted = if eventLogPaneWidthPx <= 0: fitCell(full, high(int) div 2)
                     else: fitCellAs(full, cellsInPx(room), kind)
        if fitted.truncated:
          r.setAttribute(c, TableCutAttribute, $col)
          let drawn = if fitted.midMarker > 0:
                        fitted.text[0 ..< fitted.midMarker].runeLen + 1
                      else: fitted.text.runeLen
          let textX = cellX + eventCellPad(col)
          eventCuts.add CutCell(row: rowTop,
                                height: eventRowTopPx(line + 1) -
                                        eventRowTopPx(line),
                                col: cellX - hLeft, width: widthOf(col),
                                ellipsisCol: textX - hLeft + pxOfText(drawn - 1),
                                ellipsisWidth: pxOfText(1),
                                key: $ev.eventIndex, column: $col, full: full)
        r.appendChild(c, r.createTextNode(fitted.text))
        r.appendChild(row, c)
    r.appendChild(table, row)
    inc line
    # The event's full text under its row (§5.3), in its column.
    if tableDetail.isOpen(EventDetailPane, $ev.eventIndex):
      var col = elcOutput
      if elcOutput notin shown and shown.len > 0: col = shown[^1]
      for c in shown:
        if $c == tableDetail.column: col = c
      let room = widthOf(col) - eventCellPad(col)
      for text in detailView(eventCellTextOf(ev, col), max(1, cellsInPx(room)),
                             bodyRows, tableCopyChord).lines:
        let d = r.createElement("div")
        r.setAttribute(d, TableDetailAttribute, $ev.eventIndex)
        r.setStyle(d, "display", "flex")
        r.setStyle(d, "items", "center")
        r.setStyle(d, "flex-shrink", "0")
        r.setStyle(d, "height", $(eventRowTopPx(line + 1) - eventRowTopPx(line)) & "px")
        r.setStyle(d, "padding-left", $(widthOfX(col) + eventCellPad(col)) & "px")
        r.setStyle(d, "white-space", "nowrap")
        r.setStyle(d, "color", DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
        slide(d)
        r.appendChild(d, r.createTextNode(text))
        r.appendChild(table, d)
        inc line
  r.appendChild(pane, table)
  eventLogTableHeightPx = EventHeaderPx + eventRowTopPx(line)
  if scrolls:
    # §5.5.4: the table's horizontal bar, under its rows.
    let hb = r.createElement("div")
    r.setStyle(hb, "position", "relative")
    r.setStyle(hb, "flex-shrink", "0")
    r.setStyle(hb, "height", $TableHBarPx & "px")
    tableHBar(r, hb, eventLogHView, 0, 0, $paneEventLog)
    r.appendChild(pane, hb)

  # The pager, at the pane's foot.
  let spring = r.createElement("div")
  r.setStyle(spring, "flex-grow", "1")
  r.appendChild(pane, spring)
  let total = eventLogTotalOf(start, rows.len, vm.totalEventCount.val)
  let foot = r.createElement("div")
  r.setAttribute(foot, EventLogFooterAttribute, "true")
  r.setAttribute(foot, EventLogTotalAttribute, $total)
  r.setStyle(foot, "display", "flex")
  r.setStyle(foot, "items", "center")
  r.setStyle(foot, "flex-shrink", "0")
  r.setStyle(foot, "height", $EventFooterPx & "px")
  r.setStyle(foot, "padding-left", "8px")
  r.setStyle(foot, "gap", "3px")
  r.setStyle(foot, "font-family", WindowFontFamily)
  r.setStyle(foot, "font-size", "12px")
  r.setStyle(foot, "color", DesignTokenHex[dtColorsUiTextPrimaryBody][dmDark])
  r.appendChild(foot, r.createTextNode("Rows"))
  let firstBox = eventField(r, 54, 20)
  r.setStyle(firstBox, "padding-left", "6px")
  r.appendChild(firstBox, r.createTextNode($(if rows.len > 0: start + 1 else: 0)))
  r.appendChild(foot, firstBox)
  r.appendChild(foot, r.createTextNode("to " & $(start + rows.len) & " of " &
                                       $total))
  r.appendChild(pane, foot)
  r.appendChild(parent, pane)
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
  ##
  ## `PLAT35-F4`: and so are the state pane's, for the same reason one pane
  ## over (`renderState`). It takes the pane view rather than re-asking for
  ## one, because the `Tabs` half of that view is still the vocabulary's to
  ## draw.
  if leaf.builtin == paneCalltrace and not leaf.vm.isNil and
     renderCallTrace(r, parent, CalltraceVM(leaf.vm)):
    return true
  if leaf.builtin == paneFileTree and not leaf.vm.isNil and
     renderFileTree(r, parent, FilesystemVM(leaf.vm)):
    return true
  var pv = paneView(leaf.builtin, leaf.vm, budget, GpuiMedium)
  if leaf.builtin == paneState and not leaf.vm.isNil and
     renderState(r, parent, StateVM(leaf.vm), pv, budget):
    return true
  # `PLAT35-F5` / `PLAT35-F12`: and so are the event log's footer and header
  # rule (`renderEventLog`) — which, unlike the two arms above, keeps the
  # vocabulary's own `Table` and adds only the parts the vocabulary has no
  # word for. See that proc for why it is not in the shared binding.
  if leaf.builtin == paneEventLog and not leaf.vm.isNil and
     renderEventLog(r, parent, EventLogVM(leaf.vm), pv):
    return true
  let binding = renderGpui(r, pv.root)
  if leaf.builtin == paneVcs and not leaf.vm.isNil and pv.report.len == 0:
    # M71 (#838): the VCS pane scrolls by rows (`renderVcsScrolled`).
    renderVcsScrolled(r, parent, binding.root, pv.root)
  else:
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

proc renderLeaf*(r: GpuiRenderer; leaf: GpuiLeaf;
                surface: EditorSurface;
                editorViewportPx = 0;
                editorScrollLeftCols = 0;
                editorContentCols = -1;
                editorCaretMark = -1): (GpuiElement, bool) =
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
  r.setAttribute(node, SlotPathAttribute, slotPath(leaf))
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
                                  surface, editorViewportPx,
                                  editorScrollLeftCols, editorContentCols,
                                  editorCaretMark)
      return (node, not drewRows)
    # **AN ACCEPTED EXCEPTION SAYS WHICH EXCEPTION IT IS** (PLAT-41's LAW-P3),
    # in every product mode. `fileTree` and `buildOutput` have no replay
    # ViewModel by DECISION, so the generic not-live sentence below — "waiting
    # for the session to launch" — was a promise the session would never keep,
    # drawn on a real run of the shipped binary. `paneView` names the
    # exception and its reason without a ViewModel.
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
                                           report: NoSurfaceSuppliedReport);
                   editorViewportPx = 0;
                   editorScrollLeftCols = 0;
                   editorContentCols = -1;
                   editorCaretMark = -1):
                   LeafRenderOutcome =
  ## Build the element tree for one window.
  ##
  ## `editorViewportPx` is the editor pane's inner width, from the window's
  ## own geometry; `renderEditor`'s doc comment says why it is passed in and
  ## why zero draws no scrollbar (`PLAT35-F3`).
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
    let (node, reported) = renderLeaf(r, leaf, surface, editorViewportPx,
                                      editorScrollLeftCols,
                                      editorContentCols, editorCaretMark)
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
