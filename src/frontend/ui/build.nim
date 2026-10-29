import ui_imports, ../[types, communication], build_location_parser, auto_hide, errors
import session_viewmodels
from ../viewmodel/viewmodels/errors_vm import ErrorsVM

# ---------------------------------------------------------------------------
# ViewModel layer — IsoNim is the primary renderer.
#
# The legacy Karax `method render` was dropped in favour of an IsoNim
# view (`viewmodel/views/isonim_build_view.nim`) that mounts directly
# into the GoldenLayout container.  The legacy `BuildComponent` retains
# its IPC subscriptions so the existing wiring (build-command,
# build-stdout, build-stderr, build-code) keeps feeding data; the
# component now mirrors every update into a `BuildVM` whose signals
# drive the IsoNim view.
# ---------------------------------------------------------------------------

import std/json
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  BuildOutputLine, BuildErrorLine, BuildProblemLine, BuildLineSeverity,
  blsNone, blsError, blsWarning, blsInfo
from ../viewmodel/viewmodels/build_vm import
  BuildVM, BuildStatus,
  setCommand, setRunning, setBuildStartTime, setCode, appendLine,
  appendError, appendProblem, clearOutput, jumpToLine,
  beginBuild, feedOutput, finishBuild, tickClock
from ../viewmodel/viewmodels/build_output_model import BuildLineReader,
  ReadBuildLine, chunkLines, located, read, reset
from ../viewmodel/viewmodels/build_diagnostics import feedBuildLine,
  severityOf
from isonim/web/dom_api import nil
# `Signal.val` is a template, so reading a `BuildVM` signal here needs the
# module in scope even though the type arrives through `build_vm`. Used by the
# empty-record guard in `syncLegacyBuildIntoVM`.
from isonim/core/signals import Signal, val, `val=`
from isonim/core/computation import Memo, val
from ../viewmodel/viewmodels/build_auto_reveal import BuildAutoReveal,
  BuildRevealSetting, BuildRevealStep, brsNone, brsReveal, brsRevealProblems,
  brsDismiss, initBuildAutoReveal, observe, interact, pending,
  DefaultBuildRevealSetting
from ../viewmodel/viewmodels/build_tasks import BuildTaskConfig,
  BuildTaskHost, BuildTasksFile, loadBuildTasks, parseBuildVerb,
  runBuildVerb, runBuildChoice, buildTaskEntries, pickerNote, defaultTask,
  BuildAlreadyRunningText
from ../viewmodel/viewmodels/omnibar_vm import OmnibarEntry
from ../viewmodel/viewmodels/editor_diagnostics import EditorDiagnostic,
  diagnosticsForFile, gutterSeverity, severityWord, BuildDiagnosticsOwner
from ../viewmodel/viewmodels/build_diagnostics import resolvedPath

export build_location_parser

# The session's ViewModel and the registered component, so the legacy
# event-bus handlers can feed the one and replay the other. The pane's view
# is mounted by the panel host (`ui/panel_host`).
var buildVMInstance*: BuildVM
var buildComponentRef: BuildComponent

var orphanReader: BuildLineReader
  ## The reader of a build whose tab has no `BuildVM` yet (a component that
  ## registered before any session): its lines still reach the legacy record
  ## with their diagnostics. Every other build is read by ITS ViewModel's
  ## reader (`BuildVM.feedOutput`, PLAT-56) — one per tab, reset when its
  ## build starts — which carries `nargo`'s severity keyword down onto the
  ## location line (`BuildLocationScanner`, `viewmodels/build_diagnostics`)
  ## and decodes the line's colours into styled runs.

var pendingBuildTask*: tuple[name, matcher, dir: string]
  ## The task (or typed command's) name, problem matcher and directory of the
  ## build the renderer asked the main process for (`startDesktopBuild`),
  ## taken by its `build-command` (Build-Output-Pane.md §3.6).

var buildReveal = initBuildAutoReveal()
  ## §3.8: when this window's builds show and put away the BUILD panel — the
  ## shared rule (`build_auto_reveal`), applied through the auto-hide strips.

var buildRevealConfigured = false

var buildClockTimer: int = 0
  ## The running build's clock tick (`BuildVM.tickClock`), 0 when none.

var onBuildStatusChange*: proc()
  ## PLAT-56: installed by the status bar (`ui/status`), called when the
  ## build indicator's words may have changed — a build started, ticked or
  ## ended (Build-Output-Pane.md §3.10).

proc buildStatusChanged() =
  if not onBuildStatusChange.isNil:
    onBuildStatusChange()

proc syncLegacyBuildIntoVM*(self: BuildComponent)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc installBuildVMJumpCallback(vm: BuildVM) =
  ## Give the BUILD pane's diagnostic rows the click their own header has
  ## documented since the Karax->IsoNim migration dropped it (commit
  ## 20e24939). `lineClass` still marks them `build-clickable` and the
  ## stylesheet still gives that class a `cursor: pointer`, so until now the
  ## rows looked clickable and did nothing.
  ##
  ## Reaches the editor through `data.openLocation`, the same live path the
  ## Find in Files pane uses -- NOT through `ct/jump-location`, which
  ## `backend/dap_dialect.md` section 7 records as having no engine
  ## implementation at all.
  if vm.isNil:
    return
  vm.onJumpToLine = proc(path: string, line, col: int) =
    # PLAT-56: a relative path resolves against the folder Edit mode opened
    # (`errors.desktopResolvedPath`, the Problems row's rule), at the column.
    discard data.openLocation(cstring(errors.desktopResolvedPath(path)), line,
                              col)

proc initBuildVMFromSession*(vm: BuildVM) =
  ## Hand the pane the session's `BuildVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ## Output the shown tab's component already holds is replayed into it
  ## once, when the ViewModel is first handed over.
  buildVMInstance = vm
  installBuildVMJumpCallback(buildVMInstance)
  if firstBinding(vm):
    let component = data.shownTabComponent(Content.Build)
    if not component.isNil:
      syncLegacyBuildIntoVM(BuildComponent(component))

proc paneVM(self: BuildComponent): BuildVM =
  ## The BuildVM of the tab that holds `self` — the tab whose build this
  ## component receives (`ui_js.ipcUiTarget` routes a build's output to the
  ## tab that started it), shown or not.
  ownPaneVM(self, buildVMInstance, buildVM)

proc errorsVMOf(self: BuildComponent): ErrorsVM =
  ## The Problems pane's ViewModel of the same tab.
  ownPaneVM(self, errors.errorsVMInstance, errorsVM)

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  E2E tests
  ## inject objects directly into the legacy ``build`` record without
  ## populating every field, so cstring fields can land as ``null`` /
  ## ``undefined`` in JS — naive ``$`` would throw inside
  ## ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc syncLegacyBuildIntoVM*(self: BuildComponent) =
  ## Mirror the legacy ``self.build`` data structure into the IsoNim
  ## ``BuildVM``.  Used by the layout's `__ctRenderPanel` helper after
  ## E2E tests inject pre-built output directly into ``build.output``
  ## without going through ``appendBuild``.  Production code paths use
  ## the per-line ``appendBuild`` path; this proc covers the
  ## bulk-replace scenario.
  if self.isNil:
    return
  let buildVM = self.paneVM()
  if buildVM.isNil:
    return

  # AN EMPTY LEGACY RECORD IS NOT AN INSTRUCTION TO CLEAR, and this guard is
  # what makes the pane safe to have two producers.
  #
  # `self.build` is the ELECTRON producer's mirror: `onBuildCommand`,
  # `onBuildStdout` and `onBuildCode` fill it from `CODETRACER::build-*`, which
  # a `ct` process sends. The web instantiation has no such process — its
  # producer is `viewmodel/viewmodels/noir_build_producer`, driving the same
  # `BuildVM` from the wasm worker's `output` / `exit` / `failed` messages —
  # so `self.build` there is permanently empty.
  #
  # This proc is a BULK REPLACE, and `ui/layout.nim`'s `onPanelShown` calls it
  # every time the BUILD overlay is revealed. Without this guard, revealing the
  # pane to look at a build's result wiped that result and replaced it with the
  # empty desktop record. Measured, on the web arm: a compile that reported
  # `rows=1 paneRows=1` — the producer's view model and the pane's being the
  # same object, holding the row — and `#build` holding none 50 ms later, with
  # the row appearing only on the NEXT gesture, one whole build late. That is
  # this campaign's own failure shape, arriving inside the fix for it.
  #
  # The condition is about the SOURCE, not the platform: an empty legacy record
  # says "no legacy build has run", and it must not overwrite a view model that
  # something else filled. When the desktop's record does hold a build, it wins
  # exactly as before, which is what the E2E injection path this proc was
  # written for needs.
  if self.build.output.len == 0 and self.build.problems.len == 0 and
     safeStr(self.build.command).len == 0 and
     not self.build.running and
     buildVM.output.val.len > 0:
    return

  # IN SYNC ALREADY: the live handlers fed this ViewModel the same build line
  # by line, so a replay would only throw away what they recorded beyond the
  # legacy record (the build's number, its start and end, the history's
  # place). `onPanelShown` calls this on every reveal of the pane.
  if self.build.output.len == buildVM.output.val.len and
     safeStr(self.build.command) == buildVM.command.val and
     self.build.running == buildVM.running.val:
    return

  let startMs = buildVM.buildStartTime.val
  let endMs = buildVM.buildEndTime.val
  buildVM.running.val = false
  buildVM.clearOutput()
  # A FRESH reader, the replay's own (`clearOutput` keeps the live one's
  # state for a running build). `self.build.output` is walked whole and from
  # the start, so it is its own transcript; borrowing the live producer's
  # reader would let a replay eat a pending keyword that belongs to the build
  # currently running.
  buildVM.reader.reset()
  for entry in self.build.output:
    discard buildVM.feedOutput(safeStr(entry[0]), entry[1])
  # The legacy record's errors and problems are the truth for those lists
  # (the E2E injection path writes them directly).
  var legacyErrors: seq[BuildErrorLine] = @[]
  for err in self.build.errors:
    let location = err[0]
    legacyErrors.add(BuildErrorLine(
      locationPath: safeStr(location.path),
      locationLine: location.line,
      rawLocation: safeStr(err[1]),
      other: safeStr(err[2])))
  buildVM.errors.val = legacyErrors
  # Reset the ErrorsVM problem list ahead of the bulk replay so we
  # don't double-up rows when E2E tests inject the legacy ``build``
  # record multiple times.
  errors.syncErrorsClearInto(self.errorsVMOf())
  var rows: seq[BuildProblemLine] = @[]
  for prob in self.build.problems:
    let sev = case prob.severity
              of ProbError:   blsError
              of ProbWarning: blsWarning
              of ProbInfo:    blsInfo
    let problemRow = BuildProblemLine(
      severity: sev,
      path: safeStr(prob.path),
      line: prob.line,
      col: prob.col,
      message: safeStr(prob.message))
    rows.add problemRow
    # Mirror into the ErrorsVM so the Problems panel reflects the
    # bulk-replay path that ``__ctRenderPanel`` uses for E2E tests.
    errors.syncErrorsAppendProblemInto(self.errorsVMOf(), problemRow)
  buildVM.problems.val = rows
  buildVM.setCommand(safeStr(self.build.command))
  buildVM.setBuildStartTime(if self.build.buildStartTime > 0:
                              self.build.buildStartTime else: startMs)
  buildVM.buildEndTime.val = (if self.build.running: 0.0 else: endMs)
  if self.build.running:
    buildVM.setRunning(true)
  else:
    buildVM.setCode(self.build.code)

# ---------------------------------------------------------------------------
# BP-M6: Auto-hide integration state
# ---------------------------------------------------------------------------

var buildAutoDismissTimer: int = 0
  ## Timer handle for the auto-dismiss delay after a successful build.
  ## Zero means no timer is active.

var buildOverlayInteracted: bool = false
  ## Set to true when the user interacts with the auto-shown overlay
  ## during the auto-dismiss countdown, cancelling the dismiss.

proc cancelBuildAutoDismiss*() =
  ## Cancel any pending auto-dismiss timer. Called when the user interacts
  ## with the overlay or when a new build starts.
  if buildAutoDismissTimer != 0:
    windowClearTimeout(buildAutoDismissTimer)
    buildAutoDismissTimer = 0
  buildOverlayInteracted = false

proc autoRevealBuildPanel*() =
  ## If the build panel is pinned to an auto-hide edge strip, show the
  ## overlay so the user can see build output. No-op if the build panel
  ## is not in auto-hide state.
  if autoHideState.isNil:
    return
  let panel = autoHideState.findPanelByContent(Content.Build)
  if not panel.isNil:
    cancelBuildAutoDismiss()
    revealOverlay(panel)

proc autoDismissBuildPanel*() =
  ## After a successful build, keep the overlay visible for 2 seconds,
  ## then auto-hide it. If the user interacts with the overlay during
  ## the countdown (e.g. clicks, scrolls), the dismiss is cancelled.
  if autoHideState.isNil:
    return
  let panel = autoHideState.findPanelByContent(Content.Build)
  if panel.isNil:
    return
  # Only dismiss if the build panel is currently shown in the overlay.
  if autoHideState.activeOverlay != panel or not autoHideState.overlayVisible:
    return

  cancelBuildAutoDismiss()
  buildOverlayInteracted = false

  # Listen for any user interaction on the overlay to cancel the dismiss.
  let overlayEl = document.getElementById(cstring"auto-hide-overlay")
  if not overlayEl.isNil:
    # Use a one-shot listener: on any pointer/keyboard activity, cancel.
    let handler = proc(ev: Event) =
      buildOverlayInteracted = true
      cancelBuildAutoDismiss()
    # Attach listeners that fire once and then remove themselves.
    overlayEl.addEventListener(cstring"pointerdown", handler)
    overlayEl.addEventListener(cstring"keydown", handler)

  buildAutoDismissTimer = windowSetTimeout(proc() =
    buildAutoDismissTimer = 0
    if buildOverlayInteracted:
      return
    # Verify the build panel is still the active overlay before hiding.
    if not autoHideState.isNil and
       autoHideState.activeOverlay == panel and
       autoHideState.overlayVisible:
      hideOverlay()
  , 2000)

proc revealBuildPane*() =
  ## PLAT-56 (§3.10): the status bar's build indicator pressed — the Build
  ## Output pane brought on screen: its tab activated where the layout places
  ## it, its overlay revealed where it is pinned to an auto-hide edge.
  if data.isNil or data.ui.layout.isNil:
    return
  if data.ui.componentMapping[Content.Build].len > 0:
    data.openLayoutTab(Content.Build)
  autoRevealBuildPanel()

proc focusBuild*(self: BuildComponent) =
  ## Activate the build pane in the GL layout using the component mapping.
  ## This avoids hard-coded tree indices and works regardless of layout structure.
  if not self.data.ui.layout.isNil:
    self.data.openLayoutTab(Content.Build)

proc matchLocation*(self: BuildComponent, raw: string): (bool, types.Location, cstring, cstring) =
  ## Legacy API kept for backward compatibility.
  ## Delegates to `parseBuildLocation` and converts the result.
  var l = types.Location(line: 0)
  if "Hint" in raw:
    return (false, l, cstring"", cstring"")

  let parsed = parseBuildLocation(raw)
  if not parsed.found:
    return (false, l, cstring"", cstring"")

  let loc = types.Location(path: cstring(parsed.path), line: parsed.line)
  # Reconstruct a display string similar to the old format for the location part.
  var locDisplay: string
  if parsed.col >= 0:
    locDisplay = parsed.path & "(" & $parsed.line & ", " & $parsed.col & ")"
  else:
    locDisplay = parsed.path & "(" & $parsed.line & ")"

  return (true, loc, cstring(locDisplay), cstring(parsed.message))

proc buildSeverityToProblem(sev: BuildSeverity): ProblemSeverity =
  ## Convert a BuildSeverity from the parser to the ProblemSeverity used
  ## by the Problems panel. Keeps the two enums decoupled so the parser
  ## module stays free of UI types.
  case sev
  of SevError:   ProbError
  of SevWarning: ProbWarning
  of SevInfo:    ProbInfo

proc scrollBuildToBottom(self: BuildComponent) =
  ## Scroll the build output container to the bottom so the latest lines
  ## are visible. Called after appending lines when auto-scroll is enabled.
  let el = document.getElementById("build")
  if not el.isNil:
    el.toJs.scrollTop = el.toJs.scrollHeight

proc buildElapsedStr(self: BuildComponent): string =
  ## Return a human-readable elapsed duration string for the current build.
  ## Returns "" when no build is running or start time is not set.
  if self.build.buildStartTime == 0:
    return ""
  let elapsedMs = dateNowMs() - self.build.buildStartTime
  let elapsedSec = elapsedMs / 1000.0
  if elapsedSec < 60.0:
    return &"{elapsedSec:.1f}s"
  let mins = int(elapsedSec) div 60
  let secs = elapsedSec - float(mins * 60)
  return &"{mins}m {secs:.1f}s"

proc appendBuild(self: BuildComponent, buildLine: string, stdout: bool) =
  ## One line of a build's output (PLAT-56, Build-Output-Pane.md §3.13): read
  ## ONCE, by the tab's `BuildVM` (`feedOutput`: its text and styled runs, its
  ## location, and the shared diagnostics rule's reading —
  ## `viewmodels/build_diagnostics.feedBuildLine`, the rule the terminal's and
  ## the GPUI window's panes read their builds by), and mirrored into the
  ## legacy record and the tab's Problems pane.
  ##
  ## A line that names a location is kept WHOLE, as the compiler wrote it, and
  ## is the jump target. (Until PLAT-56 it was split into a reconstructed
  ## `path(line, col)` line and a message line, which no other front-end drew
  ## and which dropped the compiler's own text and colours.)
  self.build.output.add((cstring(buildLine), stdout))
  let vm = self.paneVM()
  let read =
    if vm.isNil: orphanReader.read(buildLine, stdout)
    else: vm.feedOutput(buildLine, stdout)
  if read.line.located:
    self.build.errors.add((types.Location(path: cstring(read.line.locationPath),
                                          line: read.line.locationLine),
                           cstring(read.line.text),
                           cstring(read.fed.scanned.message)))
  if read.fed.problem:
    let parsed = read.fed.scanned
    self.build.problems.add(BuildProblem(
      severity: buildSeverityToProblem(parsed.severity),
      path: cstring(parsed.path),
      line: parsed.line,
      col: parsed.col,
      message: cstring(parsed.message)))
    # The tab's Problems pane: the same row, at the same instant.
    errors.syncErrorsAppendProblemInto(self.errorsVMOf(), read.fed.row)

proc tickBuildClock(self: BuildComponent) =
  ## The running build's elapsed time (the header's duration and the status
  ## bar's indicator), ticked until the build ends.
  buildClockTimer = 0
  let vm = self.paneVM()
  if vm.isNil or not self.build.running:
    return
  vm.tickClock(dateNowMs())
  buildStatusChanged()
  buildClockTimer = windowSetTimeout(proc() = self.tickBuildClock(), 200)

var onDesktopBuildRequested*: proc()
  ## Installed by `ui_js`: the tab on screen is the one the build's output
  ## goes to (`buildRequestSession`).

proc projectFolder(): string

var buildMarkDecorations = JsAssoc[cstring, JsObject]{}
  ## Each editor's diagnostic gutter decorations, by editor name, so the next
  ## refresh replaces exactly them.

proc setBuildModelMarkers(editor: MonacoEditor; owner: cstring;
                          markers: JsObject) {.importjs:
  "(function(e,o,m){var md=e.getModel(); if (md) monaco.editor.setModelMarkers(md,o,m);})(#,#,#)".}
proc buildModelLine(editor: MonacoEditor; line: int): cstring {.importjs:
  "(function(e,l){var m=e.getModel(); if(!m||l<1||l>m.getLineCount()) return ''; return m.getLineContent(l);})(#,#)".}
proc buildDeltaDecorations(editor: MonacoEditor; old, fresh: JsObject): JsObject
  {.importjs: "#.deltaDecorations(#, #)".}
proc newMonacoRange(a, b, c, d: int): JsObject {.importjs: "new monaco.Range(#,#,#,#)".}
proc emptyJsArray(): JsObject {.importjs: "(function(){return [];})()".}
proc pushJs(a, v: JsObject) {.importjs: "#.push(#)".}

proc markerSeverity(s: BuildLineSeverity): int =
  ## Monaco's `MarkerSeverity`: Error 8, Warning 4, Info 2.
  case s
  of blsError: 8
  of blsWarning: 4
  else: 2

proc refreshBuildEditorMarks*() =
  ## Build-Output-Pane.md §3.9: the build's diagnostics in every open editor —
  ## the shared rule's spans (`editor_diagnostics`) as Monaco markers (its
  ## squiggles, in the severity's colour, and the message on hover) and the
  ## most severe one's icon in the gutter's pointer lane. From the Problems
  ## pane's rows (`errorsVMInstance`), so a new build — which clears them —
  ## clears the marks.
  if data.isNil or data.ui.isNil or data.ui.editors.isNil:
    return
  let errs = errors.errorsVMInstance
  let rows = if errs.isNil: newSeq[BuildProblemLine]() else: errs.problems.val
  let folder = projectFolder()
  let dir = if errors.desktopBuildDirectory.len > 0: errors.desktopBuildDirectory
            else: folder
  for name, editor in data.ui.editors:
    if editor.isNil or editor.monacoEditor.isNil or editor.path.isNil:
      continue
    let monacoEditor = editor.monacoEditor
    let diags = diagnosticsForFile(rows, dir, $editor.path, folder,
      proc(line: int): string = $buildModelLine(monacoEditor, line))
    let markers = emptyJsArray()
    let glyphs = emptyJsArray()
    var marked: seq[int]
    for d in diags:
      markers.pushJs js{severity: markerSeverity(d.severity),
                        message: cstring(d.message),
                        source: cstring"build",
                        startLineNumber: d.line,
                        startColumn: d.fromColumn + 1,
                        endLineNumber: d.line,
                        endColumn: d.toColumn + 1}
      if d.line notin marked:
        marked.add d.line
        let sev = severityWord(gutterSeverity(diags, d.line))
        glyphs.pushJs js{range: newMonacoRange(d.line, 1, d.line, 1),
                         options: js{
                           marginClassName: cstring(
                             "build-diagnostic-margin build-diagnostic-margin-" &
                             sev)}}
    setBuildModelMarkers(monacoEditor, cstring(BuildDiagnosticsOwner), markers)
    let old = if buildMarkDecorations.hasKey(name): buildMarkDecorations[name]
              else: emptyJsArray()
    buildMarkDecorations[name] = buildDeltaDecorations(monacoEditor, old, glyphs)

proc configuredRevealSetting(): BuildRevealSetting =
  ## §5.1's `build.autoReveal` / `build.autoDismissOnSuccess` from the loaded
  ## configuration (a configuration written before them has neither: the
  ## defaults).
  result = DefaultBuildRevealSetting
  if data.isNil or data.config.isNil:
    return
  let b = data.config.toJs["build"]
  if b.isNil or b.isUndefined:
    return
  for (key, field) in [("autoReveal", 0), ("autoDismissOnSuccess", 1)]:
    let v = b[cstring(key)]
    if not v.isNil and not v.isUndefined and jsTypeOf(v) == cstring"boolean":
      if field == 0: result.autoReveal = v.to(bool)
      else: result.autoDismissOnSuccess = v.to(bool)

proc revealStep(self: BuildComponent): BuildRevealStep =
  ## §3.8: the shared rule's step for this tab's build now.
  let vm = self.paneVM()
  if vm.isNil:
    return brsNone
  if not buildRevealConfigured:
    buildRevealConfigured = true
    buildReveal = initBuildAutoReveal(configuredRevealSetting())
  let errs = self.errorsVMOf()
  buildReveal.observe(vm.number.val, vm.status.val,
                      (if errs.isNil: 0 else: errs.errorCount.val),
                      (if errs.isNil: 0 else: errs.warningCount.val),
                      dateNowMs())

proc readProjectText(path: cstring): JsObject {.importjs: """(function(p) {
  try { return {ok: true, text: require('fs').readFileSync(p, 'utf8')}; }
  catch (e) { return {ok: false, text: ''}; } })(#)""".}

proc projectFolder(): string =
  if data.isNil or data.startOptions.folder.isNil: ""
  else: $data.startOptions.folder

proc desktopBuildTasks*(): BuildTaskConfig =
  ## Build-Output-Pane.md §3.6, §5.2: the project's tasks, read from its
  ## `.codetracer/build.yaml` NOW; with no file, the session's own build
  ## command (`trace.compileCommand`, the configuration's `defaultBuild`).
  let folder = projectFolder()
  var inferred = ""
  if not data.isNil and not data.trace.isNil and
     not data.trace.compileCommand.isNil:
    inferred = $data.trace.compileCommand
  if folder.len == 0:
    return loadBuildTasks("", false, inferred)
  let read = readProjectText(cstring(folder & "/" & BuildTasksFile))
  loadBuildTasks($read["text"].to(cstring), read["ok"].to(bool), inferred)

proc desktopBuildRunning(): bool =
  not buildVMInstance.isNil and buildVMInstance.running.val

proc startDesktopBuild*(command, dir, task, matcher: string): string =
  ## A build run by the main process (`index/build_runner`): its command in
  ## `dir`, its output into the BUILD panel of the tab on screen. "" when it
  ## was asked for, else why not.
  if desktopBuildRunning():
    return BuildAlreadyRunningText
  if data.isNil:
    return "this window cannot run builds"
  if not onDesktopBuildRequested.isNil:
    onDesktopBuildRequested()
  pendingBuildTask = (task, matcher, dir)
  data.ipc.send cstring"CODETRACER::build-start",
    js{command: cstring(command), cwd: cstring(dir)}
  ""

proc stopDesktopBuild*(): string =
  ## ■ Stop / `:build: stop`: the main process stops the build it runs.
  if not desktopBuildRunning():
    return "nothing is running"
  data.ipc.send cstring"CODETRACER::build-cancel", js{}
  "cancelling build …"

var openBuildTaskPickerProc*: proc(): string
  ## Installed by the command palette (`ui/command`): open it on `:build: `.
var showBuildHistoryProc*: proc(): string
  ## Installed by the BUILD panel's view host: open its history picker.

proc desktopBuildTaskHost*(): BuildTaskHost =
  ## What the desktop does for `build_tasks`.
  result.running = desktopBuildRunning()
  result.projectDir = projectFolder()
  result.start = proc(command, dir, task, matcher: string): string =
    startDesktopBuild(command, dir, task, matcher)
  result.stop = proc(): string = stopDesktopBuild()
  result.clear = proc(): string =
    if not buildVMInstance.isNil:
      buildVMInstance.clearOutput()
      buildStatusChanged()
    ""
  result.showHistory = proc(): string =
    if buildVMInstance.isNil or buildVMInstance.history.val.len == 0:
      return "no earlier build in this window"
    revealBuildPane()
    if showBuildHistoryProc.isNil: "" else: showBuildHistoryProc()
  result.openPicker = proc(): string =
    if openBuildTaskPickerProc.isNil: "this window has no task picker"
    else: openBuildTaskPickerProc()

proc runDesktopBuildLine*(line: string): string =
  ## A `:build` line (§3.12) through the shared grammar. What to say.
  runBuildVerb(desktopBuildTaskHost(), desktopBuildTasks(),
               parseBuildVerb(line))

proc runDesktopBuildChoice*(entry: OmnibarEntry): string =
  ## A picker entry chosen.
  runBuildChoice(desktopBuildTaskHost(), desktopBuildTasks(), entry)

method onBuildCommand*(self: BuildComponent, response: BuildCommand) {.async.} =
  self.build.command = response.command
  # A NEW BUILD STARTS AFRESH: the legacy record's lines, errors and
  # problems are this build's, and its reader (the ViewModel's, reset by
  # `beginBuild`) has no pending keyword or colour. Without the reset, a run
  # whose last diagnostic header had no location line beneath it would hand
  # its severity to the FIRST located line of the next run.
  self.build.output = @[]
  self.build.errors = @[]
  self.build.problems = @[]
  orphanReader.reset()
  # Initialise auto-scroll to on and record the build start time.
  self.build.autoScroll = true
  self.build.buildStartTime = dateNowMs()
  self.build.running = true

  # The task this build runs, and the directory its relative paths are in.
  let task = pendingBuildTask
  pendingBuildTask = ("", "", "")
  errors.desktopBuildDirectory = task.dir

  # Mirror the start-of-build state into the IsoNim VM. The legacy
  # ``self.build`` record stays the source of truth for the Karax-driven
  # Problems panel; the VM mirrors only what the IsoNim view needs.
  let buildVM = self.paneVM()
  if not buildVM.isNil:
    # New builds clear the previous output so failures from one run don't
    # bleed into the next; the previous build goes to the history (§3.7).
    buildVM.beginBuild($response.command, self.build.buildStartTime,
                       taskName = task.name, problemMatcher = task.matcher)
    if buildClockTimer == 0:
      buildClockTimer = windowSetTimeout(proc() = self.tickBuildClock(), 200)
  buildStatusChanged()

  # Mirror the per-build clear into the IsoNim ErrorsVM so the
  # Problems panel resets at the same instant the Build panel does.
  errors.syncErrorsClearInto(self.errorsVMOf())
  # §3.9: the editors' marks of the last build go with its rows.
  refreshBuildEditorMarks()
  # §3.8, BP-M6: the shared rule — a build starting reveals the panel where
  # it is pinned to an auto-hide strip.
  if self.revealStep() == brsReveal:
    autoRevealBuildPanel()

  self.data.redraw()

proc processBuildOutput(self: BuildComponent, data: cstring, isStdout: bool) =
  ## Process build output lines: split by newline, append each line to the
  ## build output, and trigger a redraw. Extracted to avoid a Nim async
  ## template macro bug with for-loop variables in {.async.} methods.
  # PLAT-56: `chunkLines` — a write ending with a newline does not end with
  # an empty line; an empty line inside one is a line, as the compiler wrote
  # it (the native runners keep it too).
  let parts = chunkLines($data)
  if self.build.output.len == 0:
    self.focusBuild()
  for part in parts:
    self.appendBuild(part, isStdout)
  self.data.redraw()
  if self.build.autoScroll:
    self.scrollBuildToBottom()

method onBuildStdout*(self: BuildComponent, response: BuildOutput) {.async.} =
  self.processBuildOutput(response.data, true)

method onBuildStderr*(self: BuildComponent, response: BuildOutput) {.async.} =
  self.processBuildOutput(response.data, false)

method onBuildCode*(self: BuildComponent, response: BuildCode) {.async.} =
  self.build.code = response.code
  self.build.running = false
  let buildVM = self.paneVM()
  if not buildVM.isNil:
    buildVM.finishBuild(response.code, dateNowMs(),
                        cancelled = response.cancelled)
  buildStatusChanged()
  # §3.9: the build's diagnostics in the open editors.
  refreshBuildEditorMarks()
  let step = self.revealStep()
  if response.runner:
    # A TASK OR A TYPED COMMAND (`index/build_runner`): the mode stays as it
    # is — this is a build of the working tree, not the record-and-debug
    # flow below. §3.8: a failure reveals the panel and Problems and
    # highlights the first error (EMT-D21); a clean success puts the
    # revealed panel away.
    if step == brsRevealProblems:
      autoRevealBuildPanel()
      if not autoHideState.isNil:
        let errorsPanel = autoHideState.findPanelByContent(Content.BuildErrors)
        if not errorsPanel.isNil:
          revealOverlay(errorsPanel)
      errors.highlightFirstBuildErrorIn(errorsVMOf(self))
    elif buildReveal.pending:
      autoDismissBuildPanel()
    self.data.redraw()
    return
  if self.build.code != 0:
    self.focusBuild()
    # Also focus the build errors tab via the component mapping,
    # instead of hard-coded GL tree indices that break with layout changes.
    if self.data.ui.componentMapping[Content.BuildErrors].len > 0:
      self.data.openLayoutTab(Content.BuildErrors)

    # BP-M6: Auto-reveal the build pane on failure so errors are visible,
    # and also reveal the Problems (BuildErrors) panel if it is pinned.
    autoRevealBuildPanel()
    if not autoHideState.isNil:
      let errorsPanel = autoHideState.findPanelByContent(Content.BuildErrors)
      if not errorsPanel.isNil:
        revealOverlay(errorsPanel)

    # HIGHLIGHT THE FIRST ERROR, AND DO NOT FOCUS ANYTHING (EMT-D21).
    #
    # `focusBuild` and `openLayoutTab` above only activate a tab; neither moves
    # keyboard focus, and this must not either. Selecting the first row gives
    # `next error` an origin and shows the user where they will land, while the
    # keyboard stays wherever it was — a build that pulled the caret out of the
    # editor would be unusable, and builds are frequent.
    #
    # THIS TAB'S Problems pane — the one `appendBuild` filled — and not the
    # SHOWN tab's slot `errorsVMInstance`, which the highlight used to go to:
    # measured by the PLAT-55 capture, the panel listed the rows and none was
    # selected (codetracer-pm issue
    # `2026-10-26-desktop-failed-build-highlights-no-problems-row`).
    errors.highlightFirstBuildErrorIn(self.errorsVMOf())

    self.data.functions.switchToEdit(self.data)
  else:
    # BP-M6: On success, schedule auto-dismiss of the build overlay after
    # a short delay so the user can see the success state briefly.
    autoDismissBuildPanel()

    self.data.functions.switchToDebug(self.data)


# BuildComponent.render() removed: IsoNim is the primary renderer.
# The pane's view (``viewmodel/views/isonim_build_view.nim``) is mounted by
# the panel host.

method register*(self: BuildComponent, api: MediatorWithSubscribers) =
  ## Register the BuildComponent with the mediator. Its handlers feed the
  ## session's `BuildVM` once `initBuildVMFromSession` has installed it.
  self.api = api
  if buildComponentRef.isNil:
    buildComponentRef = self
