## tui/host/constraints_source.nim — PLAT-62. **The terminal's Constraints
## pane is filled from the desktop's ViewModel, measured by the desktop's
## rule.**
##
## The host half of the pane, as `problems_source.nim` is Problems': it owns
## the window's `ConstraintsVM` and the `NativeConstraintsHost` that runs
## `nargo info --json` in the window's project (`viewmodel/host/
## native_constraints_host.nim`, the desktop's `index/ns9_panes` over native
## producers), hands the app layer the value `views/constraints_pane.nim`
## paints, and answers the pane's acts (`TuiApp.constraintsAct`) through the
## ViewModel's own actions — the ones the desktop's view calls:
##
## * a press on a row selects it and opens the line that declares its
##   function (`activateRow`), the editor focused; a row no source declares
##   opens nothing and says why;
## * a right press opens the row menu (`rowMenu`, through
##   `headless_app/constraint_menu`): Go to Source, Copy Name, Copy Source
##   Location;
## * the list keys move the selection, Enter opens it.
##
## ONE PER WINDOW, NOT PER TAB, as Test Results' source is: every tab shares
## the window's project (`app.projectRoot`), so a recording of the project
## opened in a new tab shows the project's circuit too. Opening a file is the
## loop's (`open`): Edit mode's editor, or — in a replay's Debug mode — the
## file shown from the recording.

import std/[os, strutils]

import isonim/core/[owner, signals, computation]

import ../app/runtime
import ../app/tui_app
import ../app/edit_binding
import ../app/views/constraints_pane
import ../../viewmodel/viewmodels/constraints_vm
import ../../viewmodel/host/native_constraints_host
import headless_app/constraint_menu

export native_constraints_host

type
  ConstraintsOpener* = proc(path: string; line, col: int): string {.closure.}
    ## Open the absolute `path` at `line:col` (1-based); "" when it opened,
    ## else why not.

  ConstraintsSource* = ref object
    vm*: ConstraintsVM
    host*: NativeConstraintsHost
    open: ConstraintsOpener
    projectRoot: NativeConstraintsRoot
    said: string
      ## What the last open said (why it failed, or "opened …").
    started*: bool
      ## The project has been measured once: the pane was on screen. The
      ## listing is not measured for a window that never shows the pane
      ## (Debug mode places it nowhere by default).
    dispose: proc()

proc paneModelOf*(vm: ConstraintsVM): ConstraintsPaneModel =
  ## The shared ViewModel as the pane's value — every word the ViewModel's
  ## (the desktop's view reads the same procs), nothing derived here.
  let report = vm.report.val
  result = ConstraintsPaneModel(loaded: true, headline: vm.headline.val,
                                stale: report.stale and
                                       report.absence.len == 0,
                                provenance: report.provenance,
                                absence: report.absence,
                                selected: vm.selected.val)
  result.notice = listingNoticeFor(report)
  for i, row in vm.rows.val:
    result.rows.add ConstraintsPaneRow(
      index: i, opcode: row.kind == crkOpcode,
      unconstrained: row.kind == crkFunction and
                     row.kindLabel == kindLabelOf(cfkUnconstrained),
      name: row.name, kind: row.kindLabel, count: row.count,
      where: whereText(row.source), args: row.args,
      linked: row.source.linked, title: rowTitle(row))

proc publish*(s: ConstraintsSource; rt: TuiRuntime) =
  ## Hand the app layer the pane's value; the reading position is the
  ## reader's (the painter clamps it).
  if s.isNil:
    return
  let top = rt.app.constraints.scrollTop
  rt.app.constraints = paneModelOf(s.vm)
  rt.app.constraints.scrollTop = top

proc act(s: ConstraintsSource; rt: TuiRuntime;
         a: ConstraintsAct): ConstraintsActResult =
  s.said = ""
  case a.kind
  of cakSelect:
    s.vm.selectRow(a.index)
  of cakOpen:
    let done = s.vm.activateRow(a.index)
    if not done.opened:
      result.note = done.reason
    else:
      result.opened = s.said.startsWith("opened ")
      result.note = s.said
  of cakRowMenu:
    s.vm.selectRow(a.index)
    result.menu = constraintRowContextMenuOf(s.vm, a.index)
  of cakMenuChoice:
    let outcome = runConstraintMenuAction(s.vm, a.action, a.target)
    if not outcome.done:
      result.note = "that row has changed since the menu opened"
    elif outcome.copied.len > 0:
      result.copied = outcome.copied
    elif outcome.activation.opened:
      result.opened = s.said.startsWith("opened ")
      result.note = s.said
    else:
      result.note = outcome.activation.reason
  of cakKey:
    if s.vm.rows.val.len == 0:
      result.note = "the Constraints pane lists no row"
    else:
      discard s.vm.moveSelection(a.operation, a.page)
  of cakCopy:
    let at = s.vm.selected.val
    if at < 0:
      result.note = "no row of the Constraints pane is selected"
    else:
      result.copied = rowText(s.vm.rows.val[at])
  s.publish(rt)

proc newConstraintsSource*(rt: TuiRuntime; projectRoot: NativeConstraintsRoot;
                           open: ConstraintsOpener;
                           nargoProgram = ""): ConstraintsSource =
  ## The window's Constraints source over its project, its acts installed on
  ## `rt`'s app. Nothing is measured until `refresh`.
  result = ConstraintsSource(open: open, projectRoot: projectRoot)
  let s = result
  createRoot proc(dispose: proc()) =
    s.vm = createConstraintsVM()
    s.dispose = dispose
  s.host = newNativeConstraintsHost(s.vm, projectRoot, nargoProgram)
  s.vm.onOpenSource = proc(path: string; line, column: int) =
    let root = if s.projectRoot.isNil: "" else: s.projectRoot()
    let full = if root.len > 0: root / path else: path
    let why = if s.open.isNil: CannotOpenReason
              else: s.open(full, line, column)
    s.said = if why.len > 0: why else: "opened " & path & ":" & $line
  rt.app.constraintsAct = proc(a: ConstraintsAct): ConstraintsActResult =
    s.act(rt, a)
  s.publish(rt)

proc refresh*(s: ConstraintsSource; rt: TuiRuntime; force = false) =
  ## Measure the project (when it changed, or `force`) and publish.
  if s.isNil:
    return
  s.started = true
  discard s.host.refresh(force)
  s.publish(rt)

proc noteEdited*(s: ConstraintsSource; path: string) =
  ## An unsaved edit to `path` (project-relative): the counts may be stale.
  if not s.isNil:
    s.host.noteEdited(path)

proc tick*(s: ConstraintsSource; rt: TuiRuntime): bool =
  ## Settle a measurement that ended, follow a re-rooted project and a saved
  ## source, and mark the counts stale while a source the circuit depends on
  ## has unsaved edits. Whether the pane changed.
  if s.isNil:
    return false
  if not s.started:
    # Measured the first time the pane is on screen.
    if rt.paneAreaOf(paneConstraints).width <= 0:
      return false
    s.refresh(rt)
    return true
  let before = s.vm.report.val.stale
  if not rt.app.editSession.isNil:
    for buf in rt.app.editSession.buffers:
      if buf.isDirty:
        s.host.noteEdited(buf.path)
  result = s.host.poll() or s.host.watch() or
           s.vm.report.val.stale != before
  if result:
    s.publish(rt)

proc close*(s: ConstraintsSource) =
  if s.isNil:
    return
  s.host.stop()
  if not s.dispose.isNil:
    s.dispose()
