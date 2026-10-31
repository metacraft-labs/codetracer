## views/isonim_welcome_screen_view.nim
##
## IsoNim DOM-rendering view for the welcome screen.
##
## Renders the startup welcome surface from ``WelcomeScreenVM`` and
## replaces the legacy Karax ``method render`` in
## ``frontend/ui/welcome_screen.nim``.  Unlike the GoldenLayout-backed
## panels, the welcome screen mounts directly into ``#welcomeScreen``
## during ``layout.initLayout()``'s startup branch.
##
## This first migration focuses on the flows already covered by
## ``welcome_screen.spec.ts`` and ``welcome_screen_vm_test.nim``:
## recent traces / recent folders / start options / welcome → new
## record / online trace mode switches / loading overlay.  The
## trace-sharing buttons, transaction explorer, and richer per-form
## validation/status messaging remain follow-ups on top of the shared
## VM surface.

import std/[options, os, sequtils, strutils, tables, times]
when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
# `untrack` keeps the Start Debugger form's typing from rebuilding the whole
# screen — see the `setChecked` call in `renderNewRecordMode`.
from isonim/core/batch import untrack
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

# The generic procs expand the DSL at their caller.
export signals, computation, components

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

from ../../../ct/version import CodeTracerVersionStr
# THE DEPLOYED REVISION, when there is one. `CodeTracerVersionStr` is a
# `2026.09.0`-style release number compiled in; it is the same string for every
# build of a month and therefore cannot answer "does this page carry the fix?".
# On the web the answer is in the entry document's descriptor, and
# `versionLineText` appends it to the line that already exists rather than
# adding an element. On the desktop the label is "" and this line is byte-for-
# byte what it was.
import ../platform/displayed_build_identity
# WHAT THIS INSTANCE CALLS ITSELF. The heading used to read "CodeTracer IDE" —
# a literal, and a name no other surface uses — on a screen that a Noir Studio
# address reaches whenever the entry resolves to something other than a
# template (`/projects`, an unknown path). See `displayed_product.nim`.
import ../platform/displayed_product
import ../store/types
import ../viewmodels/welcome_screen_vm

const WelcomeScreenRootClass* = "welcome-screen-root"
const WelcomeScreenWrapperClass* = "welcome-screen-wrapper"
const WelcomeScreenClass* = "welcome-screen"
const WelcomeScreenLoadingClass* = "welcome-screen-loading"
const WelcomeLoadingOverlayClass* = "welcome-screen-loading-overlay"
const WelcomeLoadErrorClass* = "welcome-screen-load-error"
const RecentFoldersEmptyText* = "Folders you open are listed here."
const RecentFoldersFirstTimeText* =
  "Open a folder to start editing. It will be listed here afterwards."
const RecentTracesEmptyText* = "Traces you record are listed here."
  ## THREE EMPTY-STATE LINES THAT NO LONGER RE-ANNOUNCE THE BUTTONS BELOW THEM.
  ##
  ## They read, in order: "Open a folder to start editing.", "Open a folder to
  ## start editing code, or record a program to begin time-travel debugging.",
  ## and "Record a program to create your first trace, or open an existing
  ## trace file." Every verb in all three is the label of a button eight
  ## millimetres further down the same screen — Open folder, Record new trace,
  ## Open local trace — so the panels spent their only line repeating the row
  ## that says it better, and said nothing about themselves.
  ##
  ## What a reader of an empty panel actually needs is what will appear in it.
  ## The first-time line keeps one instruction, because on a first launch the
  ## panel has never had anything in it and "afterwards" is the fact that makes
  ## the empty panel make sense.

type WelcomeScreenCallbacks* = object
  # M-REC-3: ``recordingId`` is a UUIDv7 recording-id string.
  onRecentTraceClick*: proc(recordingId: string)
  onRecentFolderClick*: proc(folderPath: string)
  onStartOptionClick*: proc(key: string)
  onChooseExecutable*: proc()
  onChooseWorkDir*: proc()
  onChooseOutputFolder*: proc()
  onRecordExecutableChange*: proc(path: string)
  onRecordArgsChange*: proc(args: seq[string])
  onRecordWorkDirChange*: proc(path: string)
  onRecordOutputFolderChange*: proc(path: string)
  onRecordBackendChange*: proc(backend: RecordBackendChoice)
  onToggleDefaultOutputFolder*: proc()
  onSubmitNewRecord*: proc()
  onShowWelcome*: proc()
  onOnlineTraceInputChange*: proc(value: string)
  onSubmitOnlineTrace*: proc(value: string)

proc welcomeScreenClass*(loading: bool): string =
  if loading:
    WelcomeScreenClass & " " & WelcomeScreenLoadingClass
  else:
    WelcomeScreenClass

proc traceTooltipClass*(hovered: bool): string =
  if hovered:
    "recent-trace-tooltip visible"
  else:
    "recent-trace-tooltip"

proc startOptionClass*(opt: WelcomeStartOptionRecord; hovered: bool): string =
  var parts = @["start-option", opt.key]
  if opt.inactive:
    parts.add("inactive-start-option")
  if hovered:
    parts.add("hovered")
  parts.join(" ")

const StartOptionsNoteClass* = "start-options-note"
  ## The standing line under the start-options strip (issue #734). Rendered
  ## only when `vm.startOptionsNote` is non-empty, so the desktop's DOM is
  ## byte-for-byte what it was.

proc startOptionAriaDisabled*(opt: WelcomeStartOptionRecord): string =
  ## `aria-disabled` rather than the `disabled` attribute, because the button
  ## must stay focusable and hoverable: its `title` — the only place the
  ## refusal is spelled out per option — is what a real `disabled` control
  ## would suppress in several browsers, and a screen reader that skips the
  ## control entirely tells the user less than issue #734's reporter already
  ## knew. The refusal itself is enforced in `triggerStartOption` below, not
  ## by the attribute.
  if opt.inactive: "true" else: "false"

proc parseWelcomeDate(dateStr: string): Option[DateTime] =
  if dateStr.len == 0:
    return
  try:
    return some(parse(dateStr, "yyyy/MM/dd HH:mm:ss"))
  except TimeParseError:
    discard
  try:
    return some(parse(dateStr, "yyyy/MM/dd"))
  except TimeParseError:
    return

proc formatWelcomeTimeAgo*(dateStr: string): string =
  let parsed = parseWelcomeDate(dateStr)
  if parsed.isNone:
    return dateStr
  let diffSeconds =
    int(now().toTime.toUnix - parsed.get.toTime.toUnix)
  if diffSeconds < 60:
    return "just now"
  let minutes = diffSeconds div 60
  if minutes < 60:
    return if minutes == 1: "1 minute ago" else: $minutes & " minutes ago"
  let hours = minutes div 60
  if hours < 24:
    return if hours == 1: "1 hour ago" else: $hours & " hours ago"
  let days = hours div 24
  if days < 7:
    return if days == 1: "yesterday" else: $days & " days ago"
  let weeks = days div 7
  if weeks < 4:
    return if weeks == 1: "1 week ago" else: $weeks & " weeks ago"
  let months = days div 30
  if months < 12:
    return if months == 1: "1 month ago" else: $months & " months ago"
  let years = days div 365
  if years == 1:
    "1 year ago"
  else:
    $years & " years ago"

proc traceCommandText*(trace: RecentTraceRecord): string =
  let basename = extractFilename(trace.program)
  if trace.args.len == 0:
    return basename
  let raw = basename & " " & trace.args.join(" ")
  if raw.len <= 50:
    raw
  else:
    raw[0 ..< 48] & ".."

proc traceTooltipText*(trace: RecentTraceRecord): string =
  @[
    "Program: " & trace.program,
    if trace.args.len > 0: "Args: " & trace.args.join(" ") else: "",
    if trace.workdir.len > 0: "Workdir: " & trace.workdir else: "",
    "Recorded: " & trace.date,
    if trace.duration.len > 0: "Duration: " & trace.duration else: "",
    "ID: " & $trace.recordingId,
  ].filterIt(it.len > 0).join("\n")

proc backToWelcome(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks) =
  if callbacks.onShowWelcome != nil:
    callbacks.onShowWelcome()
  else:
    vm.showWelcome()

proc triggerStartOption(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                        opt: WelcomeStartOptionRecord) =
  if opt.inactive:
    return
  if callbacks.onStartOptionClick != nil:
    callbacks.onStartOptionClick(opt.key)
    return
  case opt.key
  of "record-new-trace":
    vm.showNewRecord()
  of "open-online-trace":
    vm.showOnlineTrace()
  else:
    discard

proc triggerTraceClick(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                       # M-REC-3: UUIDv7 recording-id string.
                       recordingId: string) =
  if callbacks.onRecentTraceClick != nil:
    callbacks.onRecentTraceClick(recordingId)
  else:
    vm.loadRecentTrace(recordingId)

proc triggerFolderClick(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                        folderPath: string) =
  if callbacks.onRecentFolderClick != nil:
    callbacks.onRecentFolderClick(folderPath)
  else:
    vm.loadRecentFolder(folderPath)

proc folderClickHandler(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                        folderPath: string): proc() =
  let capturedPath = folderPath
  result = proc() = triggerFolderClick(vm, callbacks, capturedPath)

proc traceClickHandler(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                       # M-REC-3: UUIDv7 recording-id string.
                       recordingId: string): proc() =
  let captured = recordingId
  result = proc() = triggerTraceClick(vm, callbacks, captured)

proc traceMouseOverHandler(vm: WelcomeScreenVM; recordingId: string): proc() =
  let captured = recordingId
  result = proc() = vm.hoverTrace(captured)

proc startOptionClickHandler(
    vm: WelcomeScreenVM;
    callbacks: WelcomeScreenCallbacks;
    opt: WelcomeStartOptionRecord): proc() =
  let capturedOpt = opt
  result = proc() = triggerStartOption(vm, callbacks, capturedOpt)

proc startOptionMouseOverHandler(vm: WelcomeScreenVM; key: string): proc() =
  let capturedKey = key
  result = proc() = vm.hoverOption(capturedKey)

proc parseArgsInput*(value: string): seq[string] =
  if value.strip.len == 0:
    @[]
  else:
    value.split(" ").filterIt(it.len > 0)

# ---------------------------------------------------------------------------
# Form wiring
# ---------------------------------------------------------------------------
#
# A field's current text is read where the renderer keeps it: the DOM
# input's `value` property in the browser, the node's `value` attribute in
# `MockRenderer` (what a headless test sets before firing `input`).

proc wireWelcomeInput[R, N](r: R; node: N; onValue: proc(v: string)) =
  ## Report the control's value after every keystroke.
  let captured = node
  r.addEventListener(node, "input", proc() =
    onValue(r.inputValue(captured)))

proc wireWelcomeChange[R, N](r: R; node: N; onValue: proc(v: string)) =
  ## Report the control's value when it is committed (a select, a checkbox).
  let captured = node
  r.addEventListener(node, "change", proc() =
    onValue(r.inputValue(captured)))

# ---------------------------------------------------------------------------
# The screen, for every renderer
# ---------------------------------------------------------------------------

# One Recent traces row, and one start option, each built in a proc of its
# own rather than inline in `renderWelcomeMode`'s `for` loops.  Their
# `class` expressions read the hover state, so the `ui` DSL gives each one a
# live effect (a closure).  Nim's JS backend shares one closure environment
# across a loop's iterations, so effects created inline in the loop all saw
# the LAST row's element and id: hovering any row could only ever mark the
# last tooltip.  A proc call gets a fresh environment per row.
proc renderRecentTraceRow[R, N](r: R; vm: WelcomeScreenVM;
                                callbacks: WelcomeScreenCallbacks;
                                trace: RecentTraceRecord): N =
  let recordingId = trace.recordingId
  ui(r):
    tdiv(class = "recent-trace-container"):
      tdiv(role = "button", tabindex = "0", class = "recent-trace",
           onclick = traceClickHandler(vm, callbacks, recordingId),
           onmouseover = traceMouseOverHandler(vm, recordingId),
           onmouseleave = proc() = vm.clearHoveredTrace()):
        tdiv(class = "recent-trace-title"):
          span(class = "recent-trace-title-time"):
            text formatWelcomeTimeAgo(trace.date)
          tdiv(class = "separate-bar"):
            discard
          span(class = "recent-trace-title-content"):
            text traceCommandText(trace)
        tdiv(class = traceTooltipClass(vm.hoveredRecording.val == recordingId)):
          text traceTooltipText(trace)

proc renderStartOption[R, N](r: R; vm: WelcomeScreenVM;
                             callbacks: WelcomeScreenCallbacks;
                             opt: WelcomeStartOptionRecord): N =
  ui(r):
    button(class = "ct-button-sm-tertiary " &
                   startOptionClass(opt, vm.hoveredOption.val == opt.key),
           title = opt.disabledReason,
           `aria-disabled` = startOptionAriaDisabled(opt),
           onclick = startOptionClickHandler(vm, callbacks, opt),
           onmouseover = startOptionMouseOverHandler(vm, opt.key),
           onmouseleave = proc() =
             vm.clearHoveredOption()):
      text opt.name

proc renderWelcomeMode[R, N](r: R; vm: WelcomeScreenVM;
                             callbacks: WelcomeScreenCallbacks): N =
  # The hover state is NOT read here.  This proc runs inside
  # `renderWelcomeScreenPanel`'s `createRenderEffect`, which clears and
  # rebuilds the whole screen whenever a signal read directly in its body
  # changes.  Reading `vm.hoveredRecording` / `vm.hoveredOption` here rebuilt
  # the screen on every row and button enter/leave, and the rebuilt Recent
  # traces list started back at the top — scrolling it with the wheel moved
  # rows under the pointer, changed the hover, and snapped the list back.
  # Each hover read now sits in its element's `class` expression instead
  # (`renderRecentTraceRow`, `renderStartOption`), where the `ui` DSL
  # wraps it in an effect of its own that only re-sets that one attribute
  # (see `isDynamic`, isonim/dsl/transform.nim).
  let traces = vm.recentTraces.val
  let folders = vm.recentFolders.val
  let options = vm.startOptions.val
  let startOptionsNote = vm.startOptionsNote.val
  let firstTime = traces.len == 0 and folders.len == 0
  # Plain names for the child calls: the `ui` macro passes a call through as
  # a child only when its callee is an identifier, and `f[R, N](...)` is not.
  template traceRow(trace: RecentTraceRecord): N =
    renderRecentTraceRow[R, N](r, vm, callbacks, trace)
  template startOption(opt: WelcomeStartOptionRecord): N =
    renderStartOption[R, N](r, vm, callbacks, opt)

  ui(r):
    tdiv(class = WelcomeScreenWrapperClass):
      tdiv(class = "window-menu"):
        discard
      tdiv(class = welcomeScreenClass(vm.loading.val),
           id = "welcome-screen"):
        tdiv(class = "welcome-title"):
          tdiv(class = "welcome-text"):
            tdiv(class = "welcome-logo"):
              discard
            tdiv:
              tdiv: text "Welcome to"
              tdiv: text displayedProductName()
          tdiv(class = "welcome-version"):
            text versionLineText(CodeTracerVersionStr, displayedBuildLabel())
        tdiv(class = "welcome-content"):
          tdiv(class = "welcome-left-panel"):
            tdiv(class = "recent-folders"):
              tdiv(class = "recent-folders-title"):
                text "Recent folders"
              tdiv(class = "recent-folders-list"):
                if folders.len > 0:
                  for folder in folders:
                    let folderCopy = folder
                    let path = folderCopy.path
                    tdiv(class = "recent-folder-container"):
                      tdiv(role = "button", tabindex = "0", class = "recent-folder",
                           onclick = folderClickHandler(vm, callbacks, path)):
                        tdiv(class = "recent-folder-name"):
                          text folderCopy.name
                else:
                  tdiv(class = "empty-state-message"):
                    if firstTime:
                      tdiv(class = "empty-state-text"):
                        text RecentFoldersFirstTimeText
                    else:
                      tdiv(class = "empty-state-text"):
                        text RecentFoldersEmptyText
          tdiv(class = "welcome-right-panel"):
            tdiv(class = "recent-traces"):
              tdiv(class = "recent-traces-title"):
                text "Recent traces"
              tdiv(class = "recent-traces-list"):
                if traces.len > 0:
                  for trace in traces:
                    traceRow(trace)
                else:
                  tdiv(class = "empty-state-message"):
                    tdiv(class = "empty-state-text"):
                      text RecentTracesEmptyText
        tdiv(class = "start-options"):
          for opt in options:
            startOption(opt)
        if startOptionsNote.len > 0:
          tdiv(class = StartOptionsNoteClass):
            text startOptionsNote

proc renderNewRecordMode[R, N](r: R; vm: WelcomeScreenVM;
                               callbacks: WelcomeScreenCallbacks): N =
  var execInput, argsInput, workDirInput, outputInput, checkbox: N
  var backendSelect: N
  # The backend choice is read here, in the body: its rows are a plain list
  # below, and a change to either signal rebuilds the form (it runs in
  # `renderWelcomeScreenPanel`'s effect), as before.
  let showBackend = vm.showRecordBackendChoice.val
  var backendRows: seq[tuple[value, label: string; selected: bool]] = @[]
  if showBackend:
    let chosen = vm.newRecord.val.backendChoice
    for opt in vm.recordBackendOptions.val:
      backendRows.add((opt.backend.recordBackendWireName, opt.label,
                       opt.backend == chosen))
  let panel = ui(r):
    tdiv(class = WelcomeScreenWrapperClass):
      tdiv(class = "window-menu"):
        discard
      tdiv(class = "new-record-screen"):
        tdiv(class = "new-record-screen-content"):
          tdiv(class = "welcome-logo"):
            discard
          tdiv(class = "new-record-title"):
            text "Start Debugger"
          tdiv(class = "new-record-form"):
            tdiv(class = "new-record-form-row"):
              tdiv(class = "new-record-input-row"):
                input(ref = execInput,
                      `type` = "text",
                      id = "new-record-executable",
                      `data-field` = "new-record-executable",
                      class = "ct-input-form ct-fill-available",
                      placeholder = "Local project path",
                      value = vm.newRecord.val.executable)
                button(class = "ct-button-sm-tertiary",
                       onclick = proc() =
                         if callbacks.onChooseExecutable != nil:
                           callbacks.onChooseExecutable()):
                  text "Choose"
            tdiv(class = "new-record-form-row"):
              tdiv(class = "new-record-input-row"):
                input(ref = argsInput,
                      `type` = "text",
                      id = "new-record-args",
                      `data-field` = "new-record-args",
                      class = "ct-input-form ct-fill-available",
                      placeholder = "Command line arguments",
                      value = vm.newRecord.val.args.join(" "))
            if showBackend:
              tdiv(class = "new-record-form-row record-backend-row"):
                select(ref = backendSelect,
                       id = "new-record-backend",
                       `data-field` = "new-record-backend",
                       class = "ct-input-form record-backend-select"):
                  for row in backendRows:
                    let backendValue = row.value
                    let backendLabel = row.label
                    if row.selected:
                      option(value = backendValue,
                             selected = "selected"):
                        text backendLabel
                    else:
                      option(value = backendValue):
                        text backendLabel
            tdiv(class = "new-record-form-row"):
              tdiv(class = "new-record-input-row"):
                input(ref = workDirInput,
                      `type` = "text",
                      id = "new-record-workdir",
                      `data-field` = "new-record-workdir",
                      class = "ct-input-form ct-fill-available",
                      placeholder = "Working directory",
                      value = vm.newRecord.val.workDir)
                button(class = "ct-button-sm-tertiary",
                       onclick = proc() =
                         if callbacks.onChooseWorkDir != nil:
                           callbacks.onChooseWorkDir()):
                  text "Choose"
            tdiv(class = "new-record-form-row"):
              label(class = "ct-checkmark-field"):
                input(ref = checkbox,
                      `type` = "checkbox",
                      class = "ct-checkmark-input")
                span(class = "ct-checkmark-label"):
                  text "Use default output folder"
            tdiv(class = "new-record-form-row"):
              tdiv(class = "new-record-input-row"):
                input(ref = outputInput,
                      `type` = "text",
                      id = "new-record-output",
                      `data-field` = "new-record-output",
                      class = "ct-input-form ct-fill-available",
                      placeholder = "Output folder",
                      value =
                        (if vm.newRecord.val.defaultOutputFolder:
                           "/home/<user>/.local/codetracer/"
                         else:
                           vm.newRecord.val.outputFolder))
                button(class = "ct-button-sm-tertiary",
                       onclick = proc() =
                         if callbacks.onChooseOutputFolder != nil:
                           callbacks.onChooseOutputFolder()):
                  text "Choose"
            tdiv(class = "new-record-form-row"):
              button(class = "ct-button-sm-tertiary mr-2",
                     onclick = proc() =
                       backToWelcome(vm, callbacks)):
                text "Back"
              button(class = "ct-button-sm-primary",
                     id = "new-record-submit",
                     onclick = proc() =
                       if callbacks.onSubmitNewRecord != nil:
                         callbacks.onSubmitNewRecord()
                       else:
                         discard vm.submitNewRecord()):
                text "Record"

  # Read untracked.  This proc runs inside `renderWelcomeScreenPanel`'s
  # `createRenderEffect`, which re-runs — clearing and rebuilding the whole
  # screen — whenever a signal read directly in its body changes.  A plain
  # `vm.newRecord.val` here subscribed it to the entire form state, so every
  # keystroke in any field (each one calls `vm.setRecord…`) rebuilt the form:
  # the field lost focus after one character, and the Record button was
  # replaced instead of changing state.  The checkbox only needs the value it
  # has when the form opens; toggling it goes through its own handler below.
  untrack proc() =
    r.setChecked(checkbox, vm.newRecord.val.defaultOutputFolder)
  wireWelcomeInput(r, execInput, proc(v: string) =
    vm.setRecordExecutable(v)
    if callbacks.onRecordExecutableChange != nil:
      callbacks.onRecordExecutableChange(v))
  wireWelcomeInput(r, argsInput, proc(v: string) =
    let parsed = parseArgsInput(v)
    vm.setRecordArgs(parsed)
    if callbacks.onRecordArgsChange != nil:
      callbacks.onRecordArgsChange(parsed))
  wireWelcomeInput(r, workDirInput, proc(v: string) =
    vm.setRecordWorkDir(v)
    if callbacks.onRecordWorkDirChange != nil:
      callbacks.onRecordWorkDirChange(v))
  wireWelcomeInput(r, outputInput, proc(v: string) =
    vm.setRecordOutputFolder(v)
    if callbacks.onRecordOutputFolderChange != nil:
      callbacks.onRecordOutputFolderChange(v))
  if showBackend:
    wireWelcomeChange(r, backendSelect, proc(v: string) =
      let backend = recordBackendChoiceFromWireName(v)
      vm.setRecordBackendChoice(backend)
      if callbacks.onRecordBackendChange != nil:
        callbacks.onRecordBackendChange(backend))
  wireWelcomeChange(r, checkbox, proc(v: string) =
    vm.toggleDefaultOutputFolder()
    if callbacks.onToggleDefaultOutputFolder != nil:
      callbacks.onToggleDefaultOutputFolder())
  panel

proc renderOnlineTraceMode[R, N](r: R; vm: WelcomeScreenVM;
                                 callbacks: WelcomeScreenCallbacks): N =
  var inputNode: N
  let panel = ui(r):
    tdiv(class = WelcomeScreenWrapperClass):
      tdiv(class = "window-menu"):
        discard
      tdiv(class = "new-record-screen"):
        tdiv(class = "new-record-screen-content"):
          tdiv(class = "welcome-logo"):
            discard
          tdiv(class = "new-record-title"):
            text "Download and open online trace"
          tdiv(class = "new-record-form new-online-trace-form"):
            tdiv(class = "new-record-form-row"):
              tdiv(class = "new-record-input-row"):
                input(ref = inputNode,
                      `type` = "text",
                      class = "ct-input-form ct-fill-available",
                      placeholder = "Download URL or key",
                      value = vm.onlineTraceInput.val)
            tdiv(class = "new-record-form-row"):
              # `mr-2` (8px), the same class as the Start Debugger form's
              # Back button, so both screens space their button pair alike.
              button(class = "ct-button-sm-tertiary mr-2",
                     onclick = proc() =
                       backToWelcome(vm, callbacks)):
                text "Back"
              button(class = "ct-button-sm-primary",
                     onclick = proc() =
                       if callbacks.onSubmitOnlineTrace != nil:
                         callbacks.onSubmitOnlineTrace(
                           vm.onlineTraceInput.val)):
                text "Download"

  wireWelcomeInput(r, inputNode, proc(v: string) =
    vm.setOnlineTraceInput(v)
    if callbacks.onOnlineTraceInputChange != nil:
      callbacks.onOnlineTraceInputChange(v))
  panel

proc renderLoadingOverlay[R, N](r: R): N =
  ui(r):
    tdiv(class = WelcomeLoadingOverlayClass):
      tdiv(class = "welcome-screen-loading-overlay-icon"):
        discard
      tdiv(class = "welcome-screen-loading-overlay-text"):
        tdiv:
          text "Loading trace..."

proc renderLoadError[R, N](r: R; message: string): N =
  ui(r):
    tdiv(class = WelcomeLoadErrorClass, role = "alert"):
      text message

proc renderWelcomeScreenPanel*[R, N](r: R; vm: WelcomeScreenVM;
                                     callbacks: WelcomeScreenCallbacks =
                                       WelcomeScreenCallbacks()): N =
  ## The welcome screen, for every renderer: one mode at a time, rebuilt when
  ## the mode or the loading state changes.
  var rootContainer: N
  let panel = ui(r):
    tdiv(ref = rootContainer, class = WelcomeScreenRootClass):
      discard

  createRenderEffect proc() =
    r.clearChildren(rootContainer)
    case vm.mode.val
    of wsmWelcome:
      r.appendChild(rootContainer, renderWelcomeMode[R, N](r, vm, callbacks))
    of wsmNewRecord:
      r.appendChild(rootContainer, renderNewRecordMode[R, N](r, vm, callbacks))
    of wsmOnlineTrace:
      r.appendChild(rootContainer,
                    renderOnlineTraceMode[R, N](r, vm, callbacks))
    of wsmEdit:
      discard
    if vm.loading.val:
      r.appendChild(rootContainer, renderLoadingOverlay[R, N](r))
    if vm.loadError.val.len > 0:
      r.appendChild(rootContainer, renderLoadError[R, N](r, vm.loadError.val))

  panel

when defined(js):
  proc mountIsoNimWelcomeScreen*(container: isonim_dom.Element;
                                 vm: WelcomeScreenVM;
                                 callbacks: WelcomeScreenCallbacks =
                                   WelcomeScreenCallbacks()) =
    let r = WebRenderer()
    let panel = renderWelcomeScreenPanel[WebRenderer, isonim_dom.Element](
      r, vm, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
    # Position each trace tooltip to the right of its row instead of the
    # viewport center.  Event delegation on #welcomeScreen handles all
    # traces without re-attaching listeners after reactive updates.
    # ``mouseover`` bubbles, so ``closest('.recent-trace')`` reliably
    # identifies the trace row even when the event originates from an inner
    # span.  We query the container by id to avoid Nim variable-name
    # mangling inside {.emit:}.
    {.emit: """
(function() {
  var cont = document.getElementById('welcomeScreen');
  if (!cont) return;
  cont.addEventListener('mouseover', function(e) {
    var trace = e.target.closest('.recent-trace');
    if (!trace) return;
    var tooltip = trace.querySelector('.recent-trace-tooltip');
    if (!tooltip) return;
    var rect = trace.getBoundingClientRect();
    tooltip.style.left = (rect.right + 8) + 'px';
    tooltip.style.top = (rect.top + rect.height / 2) + 'px';
    tooltip.style.transform = 'translateY(-50%)';
  });
})();
""".}
