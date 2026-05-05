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

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

from ../../../ct/version import CodeTracerVersionStr
import ../store/types
import ../viewmodels/welcome_screen_vm

const WelcomeScreenRootClass* = "welcome-screen-root"
const WelcomeScreenWrapperClass* = "welcome-screen-wrapper"
const WelcomeScreenClass* = "welcome-screen"
const WelcomeScreenLoadingClass* = "welcome-screen-loading"
const WelcomeLoadingOverlayClass* = "welcome-screen-loading-overlay"
const RecentFoldersEmptyText* = "Open a folder to start editing."
const RecentFoldersFirstTimeText* =
  "Open a folder to start editing code, or record a program to begin time-travel debugging."
const RecentTracesEmptyText* =
  "Record a program to create your first trace, or open an existing trace file."

type WelcomeScreenCallbacks* = object
  onRecentTraceClick*: proc(traceId: int)
  onRecentFolderClick*: proc(folderPath: string)
  onStartOptionClick*: proc(key: string)
  onChooseExecutable*: proc()
  onChooseWorkDir*: proc()
  onChooseOutputFolder*: proc()
  onRecordExecutableChange*: proc(path: string)
  onRecordArgsChange*: proc(args: seq[string])
  onRecordWorkDirChange*: proc(path: string)
  onRecordOutputFolderChange*: proc(path: string)
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
    "ID: " & $trace.id,
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
                       traceId: int) =
  if callbacks.onRecentTraceClick != nil:
    callbacks.onRecentTraceClick(traceId)
  else:
    vm.beginLoadingTrace(traceId)

proc triggerFolderClick(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                        folderPath: string) =
  if callbacks.onRecentFolderClick != nil:
    callbacks.onRecentFolderClick(folderPath)
  else:
    vm.enterEditMode(folderPath)

proc folderClickHandler(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                        folderPath: string): proc() =
  let capturedPath = folderPath
  result = proc() = triggerFolderClick(vm, callbacks, capturedPath)

proc traceClickHandler(vm: WelcomeScreenVM; callbacks: WelcomeScreenCallbacks;
                       traceId: int): proc() =
  let capturedTraceId = traceId
  result = proc() = triggerTraceClick(vm, callbacks, capturedTraceId)

proc traceMouseOverHandler(vm: WelcomeScreenVM; traceId: int): proc() =
  let capturedTraceId = traceId
  result = proc() = vm.hoverTrace(capturedTraceId)

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

proc renderWelcomeModeMock(r: MockRenderer; vm: WelcomeScreenVM;
                           callbacks: WelcomeScreenCallbacks): MockNode =
  let hoveredTraceId = vm.hoveredTrace.val
  let hoveredOptionKey = vm.hoveredOption.val
  let traces = vm.recentTraces.val
  let folders = vm.recentFolders.val
  let options = vm.startOptions.val
  let firstTime = traces.len == 0 and folders.len == 0

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
            text "Welcome to CodeTracer IDE"
          tdiv(class = "welcome-version"):
            text "Version " & CodeTracerVersionStr
        tdiv(class = "welcome-content"):
          tdiv(class = "welcome-left-panel"):
            tdiv(class = "recent-folders"):
              tdiv(class = "recent-folders-title"):
                text "RECENT FOLDERS"
              tdiv(class = "recent-folders-list"):
                if folders.len > 0:
                  for folder in folders:
                    let folderCopy = folder
                    let path = folderCopy.path
                    tdiv(class = "recent-folder-container"):
                      tdiv(class = "recent-folder",
                           onclick = folderClickHandler(vm, callbacks, path)):
                        tdiv(class = "recent-folder-name"):
                          text folderCopy.name
                else:
                  tdiv(class = "empty-state-message"):
                    if firstTime:
                      tdiv(class = "empty-state-welcome"):
                        text "Welcome to CodeTracer!"
                      tdiv(class = "empty-state-text"):
                        text RecentFoldersFirstTimeText
                    else:
                      tdiv(class = "empty-state-text"):
                        text RecentFoldersEmptyText
          tdiv(class = "welcome-right-panel"):
            tdiv(class = "recent-traces"):
              tdiv(class = "recent-traces-title"):
                text "RECENT TRACES"
              tdiv(class = "recent-traces-list"):
                if traces.len > 0:
                  for trace in traces:
                    let traceCopy = trace
                    let traceId = traceCopy.id
                    tdiv(class = "recent-trace-container"):
                      tdiv(class = "recent-trace",
                           onclick = traceClickHandler(vm, callbacks, traceId),
                           onmouseover = traceMouseOverHandler(vm, traceId),
                           onmouseleave = proc() =
                             vm.clearHoveredTrace()):
                        tdiv(class = "recent-trace-title"):
                          span(class = "recent-trace-title-time"):
                            text formatWelcomeTimeAgo(traceCopy.date)
                          tdiv(class = "separate-bar"):
                            discard
                          span(class = "recent-trace-title-content"):
                            text traceCommandText(traceCopy)
                        tdiv(class = traceTooltipClass(
                               hoveredTraceId == traceId)):
                          text traceTooltipText(traceCopy)
                else:
                  tdiv(class = "empty-state-message"):
                    tdiv(class = "empty-state-text"):
                      text RecentTracesEmptyText
        tdiv(class = "start-options"):
          for opt in options:
            let hovered = hoveredOptionKey == opt.key
            let optCopy = opt
            button(class = "ct-button-sm-tertiary " &
                           startOptionClass(optCopy, hovered),
                   onclick = startOptionClickHandler(vm, callbacks, optCopy),
                   onmouseover = startOptionMouseOverHandler(vm, optCopy.key),
                   onmouseleave = proc() =
                     vm.clearHoveredOption()):
              text optCopy.name

proc renderNewRecordModeMock(r: MockRenderer; vm: WelcomeScreenVM;
                             callbacks: WelcomeScreenCallbacks): MockNode =
  var execInput, argsInput, workDirInput, outputInput, checkbox: MockNode
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
                      class = "ct-input-form ct-fill-available",
                      placeholder = "Command line arguments",
                      value = vm.newRecord.val.args.join(" "))
            tdiv(class = "new-record-form-row"):
              tdiv(class = "new-record-input-row"):
                input(ref = workDirInput,
                      `type` = "text",
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
                      class = "ct-checkmark-input",
                      checked =
                        (if vm.newRecord.val.defaultOutputFolder: "true"
                         else: "false"))
                span(class = "ct-checkmark-label"):
                  text "Use default output folder"
            tdiv(class = "new-record-form-row"):
              tdiv(class = "new-record-input-row"):
                input(ref = outputInput,
                      `type` = "text",
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
                     onclick = proc() =
                       if callbacks.onSubmitNewRecord != nil:
                         callbacks.onSubmitNewRecord()
                       else:
                         discard vm.submitNewRecord()):
                text "Record"

  let captureExec = execInput
  let captureArgs = argsInput
  let captureWorkDir = workDirInput
  let captureOutput = outputInput
  let captureCheckbox = checkbox
  r.addEventListener(execInput, "input", proc() =
    let v = captureExec.attributes.getOrDefault("value", "")
    vm.setRecordExecutable(v)
    if callbacks.onRecordExecutableChange != nil:
      callbacks.onRecordExecutableChange(v))
  r.addEventListener(argsInput, "input", proc() =
    let v = captureArgs.attributes.getOrDefault("value", "")
    let parsed = parseArgsInput(v)
    vm.setRecordArgs(parsed)
    if callbacks.onRecordArgsChange != nil:
      callbacks.onRecordArgsChange(parsed))
  r.addEventListener(workDirInput, "input", proc() =
    let v = captureWorkDir.attributes.getOrDefault("value", "")
    vm.setRecordWorkDir(v)
    if callbacks.onRecordWorkDirChange != nil:
      callbacks.onRecordWorkDirChange(v))
  r.addEventListener(outputInput, "input", proc() =
    let v = captureOutput.attributes.getOrDefault("value", "")
    vm.setRecordOutputFolder(v)
    if callbacks.onRecordOutputFolderChange != nil:
      callbacks.onRecordOutputFolderChange(v))
  r.addEventListener(captureCheckbox, "change", proc() =
    vm.toggleDefaultOutputFolder()
    if callbacks.onToggleDefaultOutputFolder != nil:
      callbacks.onToggleDefaultOutputFolder())
  panel

proc renderOnlineTraceModeMock(r: MockRenderer; vm: WelcomeScreenVM;
                               callbacks: WelcomeScreenCallbacks): MockNode =
  var inputNode: MockNode
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
              button(class = "ct-button-sm-tertiary ct-mr-4",
                     onclick = proc() =
                       backToWelcome(vm, callbacks)):
                text "Back"
              button(class = "ct-button-sm-primary",
                     onclick = proc() =
                       if callbacks.onSubmitOnlineTrace != nil:
                         callbacks.onSubmitOnlineTrace(
                           vm.onlineTraceInput.val)):
                text "Download"

  let captureInput = inputNode
  r.addEventListener(inputNode, "input", proc() =
    let v = captureInput.attributes.getOrDefault("value", "")
    vm.setOnlineTraceInput(v)
    if callbacks.onOnlineTraceInputChange != nil:
      callbacks.onOnlineTraceInputChange(v))
  panel

proc renderLoadingOverlayMock(r: MockRenderer): MockNode =
  ui(r):
    tdiv(class = WelcomeLoadingOverlayClass):
      tdiv(class = "welcome-screen-loading-overlay-icon"):
        discard
      tdiv(class = "welcome-screen-loading-overlay-text"):
        tdiv:
          text "Loading trace..."

proc renderWelcomeScreenPanel*(r: MockRenderer; vm: WelcomeScreenVM;
                               callbacks: WelcomeScreenCallbacks =
                                 WelcomeScreenCallbacks()): MockNode =
  var rootContainer: MockNode
  let panel = ui(r):
    tdiv(ref = rootContainer, class = WelcomeScreenRootClass):
      discard

  createRenderEffect proc() =
    r.clearChildren(rootContainer)
    case vm.mode.val
    of wsmWelcome:
      r.appendChild(rootContainer, renderWelcomeModeMock(r, vm, callbacks))
    of wsmNewRecord:
      r.appendChild(rootContainer, renderNewRecordModeMock(r, vm, callbacks))
    of wsmOnlineTrace:
      r.appendChild(rootContainer, renderOnlineTraceModeMock(r, vm, callbacks))
    of wsmEdit:
      discard
    if vm.loading.val:
      r.appendChild(rootContainer, renderLoadingOverlayMock(r))

  panel

when defined(js):
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc setChecked(node: isonim_dom.Node; checked: bool) {.importjs: "#.checked = #".}

  proc createText(tag: string; value: string; cssClass: string = ""):
      isonim_dom.Element =
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(value))
    isonim_dom.appendChild(isonim_dom.Node(n), t)
    n

  proc clearChildren(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc readInputValue(node: isonim_dom.Node): string =
    $node.inputValue()

  proc renderWelcomeModeWeb(r: WebRenderer; vm: WelcomeScreenVM;
                            callbacks: WelcomeScreenCallbacks):
      isonim_dom.Element =
    let hoveredTraceId = vm.hoveredTrace.val
    let hoveredOptionKey = vm.hoveredOption.val
    let traces = vm.recentTraces.val
    let folders = vm.recentFolders.val
    let options = vm.startOptions.val
    let firstTime = traces.len == 0 and folders.len == 0

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
              text "Welcome to CodeTracer IDE"
            tdiv(class = "welcome-version"):
              text "Version " & CodeTracerVersionStr
          tdiv(class = "welcome-content"):
            tdiv(class = "welcome-left-panel"):
              tdiv(class = "recent-folders"):
                tdiv(class = "recent-folders-title"):
                  text "RECENT FOLDERS"
                tdiv(class = "recent-folders-list"):
                  if folders.len > 0:
                    for folder in folders:
                      let folderCopy = folder
                      let path = folderCopy.path
                      tdiv(class = "recent-folder-container"):
                        tdiv(class = "recent-folder",
                             onclick = folderClickHandler(vm, callbacks, path)):
                          tdiv(class = "recent-folder-name"):
                            text folderCopy.name
                  else:
                    tdiv(class = "empty-state-message"):
                      if firstTime:
                        tdiv(class = "empty-state-welcome"):
                          text "Welcome to CodeTracer!"
                        tdiv(class = "empty-state-text"):
                          text RecentFoldersFirstTimeText
                      else:
                        tdiv(class = "empty-state-text"):
                          text RecentFoldersEmptyText
            tdiv(class = "welcome-right-panel"):
              tdiv(class = "recent-traces"):
                tdiv(class = "recent-traces-title"):
                  text "RECENT TRACES"
                tdiv(class = "recent-traces-list"):
                  if traces.len > 0:
                    for trace in traces:
                      let traceCopy = trace
                      let traceId = traceCopy.id
                      tdiv(class = "recent-trace-container"):
                        tdiv(class = "recent-trace",
                             onclick = traceClickHandler(vm, callbacks, traceId),
                             onmouseover = traceMouseOverHandler(vm, traceId),
                             onmouseleave = proc() =
                               vm.clearHoveredTrace()):
                          tdiv(class = "recent-trace-title"):
                            span(class = "recent-trace-title-time"):
                              text formatWelcomeTimeAgo(traceCopy.date)
                            tdiv(class = "separate-bar"):
                              discard
                            span(class = "recent-trace-title-content"):
                              text traceCommandText(traceCopy)
                          tdiv(class = traceTooltipClass(
                                 hoveredTraceId == traceId)):
                            text traceTooltipText(traceCopy)
                  else:
                    tdiv(class = "empty-state-message"):
                      tdiv(class = "empty-state-text"):
                        text RecentTracesEmptyText
          tdiv(class = "start-options"):
            for opt in options:
              let hovered = hoveredOptionKey == opt.key
              let optCopy = opt
              button(class = "ct-button-sm-tertiary " &
                             startOptionClass(optCopy, hovered),
                     onclick = startOptionClickHandler(vm, callbacks, optCopy),
                     onmouseover = startOptionMouseOverHandler(vm, optCopy.key),
                     onmouseleave = proc() =
                       vm.clearHoveredOption()):
                text optCopy.name

  proc renderNewRecordModeWeb(r: WebRenderer; vm: WelcomeScreenVM;
                              callbacks: WelcomeScreenCallbacks):
      isonim_dom.Element =
    var execInput, argsInput, workDirInput, outputInput, checkbox:
      isonim_dom.Element
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
                        class = "ct-input-form ct-fill-available",
                        placeholder = "Command line arguments",
                        value = vm.newRecord.val.args.join(" "))
              tdiv(class = "new-record-form-row"):
                tdiv(class = "new-record-input-row"):
                  input(ref = workDirInput,
                        `type` = "text",
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
                       onclick = proc() =
                         if callbacks.onSubmitNewRecord != nil:
                           callbacks.onSubmitNewRecord()
                         else:
                           discard vm.submitNewRecord()):
                  text "Record"

    let execNode = isonim_dom.Node(execInput)
    let argsNode = isonim_dom.Node(argsInput)
    let workDirNode = isonim_dom.Node(workDirInput)
    let outputNode = isonim_dom.Node(outputInput)
    let checkboxNode = isonim_dom.Node(checkbox)
    checkboxNode.setChecked(vm.newRecord.val.defaultOutputFolder)
    isonim_dom.addEventListener(execNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        let v = readInputValue(execNode)
        vm.setRecordExecutable(v)
        if callbacks.onRecordExecutableChange != nil:
          callbacks.onRecordExecutableChange(v))
    isonim_dom.addEventListener(argsNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        let v = readInputValue(argsNode)
        let parsed = parseArgsInput(v)
        vm.setRecordArgs(parsed)
        if callbacks.onRecordArgsChange != nil:
          callbacks.onRecordArgsChange(parsed))
    isonim_dom.addEventListener(workDirNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        let v = readInputValue(workDirNode)
        vm.setRecordWorkDir(v)
        if callbacks.onRecordWorkDirChange != nil:
          callbacks.onRecordWorkDirChange(v))
    isonim_dom.addEventListener(outputNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        let v = readInputValue(outputNode)
        vm.setRecordOutputFolder(v)
        if callbacks.onRecordOutputFolderChange != nil:
          callbacks.onRecordOutputFolderChange(v))
    isonim_dom.addEventListener(checkboxNode, cstring"change",
      proc(ev: isonim_dom.Event) =
        vm.toggleDefaultOutputFolder()
        if callbacks.onToggleDefaultOutputFolder != nil:
          callbacks.onToggleDefaultOutputFolder())
    panel

  proc renderOnlineTraceModeWeb(r: WebRenderer; vm: WelcomeScreenVM;
                                callbacks: WelcomeScreenCallbacks):
      isonim_dom.Element =
    var inputNode: isonim_dom.Element
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
                button(class = "ct-button-sm-tertiary ct-mr-4",
                       onclick = proc() =
                         backToWelcome(vm, callbacks)):
                  text "Back"
                button(class = "ct-button-sm-primary",
                       onclick = proc() =
                         if callbacks.onSubmitOnlineTrace != nil:
                           callbacks.onSubmitOnlineTrace(
                             vm.onlineTraceInput.val)):
                  text "Download"

    let inputAsNode = isonim_dom.Node(inputNode)
    isonim_dom.addEventListener(inputAsNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        let v = readInputValue(inputAsNode)
        vm.setOnlineTraceInput(v)
        if callbacks.onOnlineTraceInputChange != nil:
          callbacks.onOnlineTraceInputChange(v))
    panel

  proc renderLoadingOverlayWeb(r: WebRenderer): isonim_dom.Element =
    ui(r):
      tdiv(class = WelcomeLoadingOverlayClass):
        tdiv(class = "welcome-screen-loading-overlay-icon"):
          discard
        tdiv(class = "welcome-screen-loading-overlay-text"):
          tdiv:
            text "Loading trace..."

  proc renderWelcomeScreenPanel*(r: WebRenderer; vm: WelcomeScreenVM;
                                 callbacks: WelcomeScreenCallbacks =
                                   WelcomeScreenCallbacks()):
      isonim_dom.Element =
    var rootContainer: isonim_dom.Element
    let panel = ui(r):
      tdiv(ref = rootContainer, class = WelcomeScreenRootClass):
        discard

    createRenderEffect proc() =
      clearChildren(rootContainer)
      let nextNode =
        case vm.mode.val
        of wsmWelcome:
          renderWelcomeModeWeb(r, vm, callbacks)
        of wsmNewRecord:
          renderNewRecordModeWeb(r, vm, callbacks)
        of wsmOnlineTrace:
          renderOnlineTraceModeWeb(r, vm, callbacks)
        of wsmEdit:
          nil
      if not nextNode.isNil:
        isonim_dom.appendChild(isonim_dom.Node(rootContainer),
                               isonim_dom.Node(nextNode))
      if vm.loading.val:
        let overlay = renderLoadingOverlayWeb(r)
        isonim_dom.appendChild(isonim_dom.Node(rootContainer),
                               isonim_dom.Node(overlay))

    panel

  proc mountIsoNimWelcomeScreen*(container: isonim_dom.Element;
                                 vm: WelcomeScreenVM;
                                 callbacks: WelcomeScreenCallbacks =
                                   WelcomeScreenCallbacks()) =
    let r = WebRenderer()
    let panel = renderWelcomeScreenPanel(r, vm, callbacks)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
