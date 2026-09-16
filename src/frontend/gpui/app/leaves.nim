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

  ExecutionPointerGlyph* = "▶"
  InspectionPointerGlyph* = "▷"
  BreakpointGlyph* = "●"
  BreakpointDisabledGlyph* = "○"
  TracepointGlyph* = "◆"
  NoMarkGlyph* = " "
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

const GpuiNominalLineHeightPx* = 20
  ## **A NOMINAL line height, and the word is doing work.**
  ##
  ## A GPU surface's true line height is a font metric the renderer resolves at
  ## PAINT time — which is the same fact that makes `gpuiRowBudget().cells` zero
  ## rather than a number (`value_presentation/surfaces.nim` says so at the
  ## function, and PLAT-21 recorded that two of the three front-ends decline
  ## `Budget.cells` for this reason). So this constant is NOT a claim about what
  ## the window will draw.
  ##
  ## It sizes exactly one thing: how many lines `SourceVM`'s FETCH WINDOW holds.
  ## Being wrong makes the window hold too many lines or too few — a round trip
  ## more or a few kilobytes more — and `GpuiSourceOverscan` absorbs the
  ## difference in both directions. It can never make the editor draw a line it
  ## does not have, because a line outside the window is a REQUEST rather than a
  ## blank (`EditorRow.held`). A constant whose error is bounded by a cache miss
  ## is a constant that may be nominal; one that decided what was on screen
  ## would not be.

func editorRowsForViewport*(heightPx: int): int =
  ## How many source lines the editor's fetch window should hold for a window
  ## `heightPx` tall. At least one, because a window of zero lines makes every
  ## read a request, which reads exactly like a provider that never answers.
  max(1, heightPx div GpuiNominalLineHeightPx)

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
  of eptNone: " "
  of eptInspection: InspectionPointerGlyph
  of eptExecution: ExecutionPointerGlyph

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

proc renderEditorRow(r: GpuiRenderer; row: EditorRow): GpuiElement =
  ## One row of the source editor.
  ##
  ## Every attribute below is the ROW's own field stringified. Nothing here
  ## re-decides what the row says — `editor_surface` decided it from the
  ## ViewModels — so a rendering that drifts from the model is a rendering
  ## whose attributes stop matching the surface, which is exactly the
  ## comparison PLAT-22's second named integration test makes.
  let el = r.createElement("div")
  r.setAttribute(el, EditorRowAttribute, $row.line)
  r.setAttribute(el, EditorPointerAttribute, $row.pointer)
  r.setAttribute(el, EditorMarkAttribute, $row.mark)
  r.setAttribute(el, EditorFlowAttribute, $row.flow)
  r.setAttribute(el, EditorHeldAttribute, (if row.held: "true" else: "false"))
  r.setStyle(el, "display", "flex")

  let gutter = r.createElement("span")
  r.appendChild(gutter,
    r.createTextNode(markGlyph(row.mark) & $row.line & pointerGlyph(row.pointer)))
  r.appendChild(el, gutter)

  let code = r.createElement("span")
  r.appendChild(code,
    r.createTextNode(if row.held: row.text else: EditorLoadingText))
  r.appendChild(el, code)

  let annotation = inlineValueText(row.values)
  if annotation.len > 0:
    let ann = r.createElement("span")
    r.appendChild(ann, r.createTextNode(annotation))
    r.appendChild(el, ann)
  el

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
  for row in surface.rows:
    r.appendChild(parent, renderEditorRow(r, row))
  surface.rows.len > 0

proc renderPaneView(r: GpuiRenderer; parent: GpuiElement;
                    leaf: GpuiLeaf; budget: Budget): bool =
  ## Draw a builtin pane's vocabulary tree into `parent`. Answers whether the
  ## pane rendered DATA rather than a report.
  ##
  ## `pane_views.paneView` is the ONE door, and its `case` is exhaustive over
  ## `PaneKind`, so a pane added to the enum without a view does not compile
  ## rather than becoming a name nothing renders.
  let pv = paneView(leaf.builtin, leaf.vm, budget, GpuiMedium)
  let binding = renderGpui(r, pv.root)
  r.appendChild(parent, binding.root)
  pv.report.len == 0

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
      let heading = r.createElement("div")
      r.appendChild(heading, r.createTextNode(
        if leaf.title.len > 0: leaf.title else: leaf.paneId))
      r.appendChild(node, heading)
      let drewRows = renderEditor(r, node, sourcePaneView(GpuiMedium).root,
                                  surface)
      return (node, not drewRows)
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
    let heading = r.createElement("div")
    r.appendChild(heading, r.createTextNode(
      if leaf.title.len > 0: leaf.title else: leaf.paneId))
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
