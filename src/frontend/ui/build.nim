import ui_imports, ../[types, communication], build_location_parser, auto_hide

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
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  BuildOutputLine, BuildErrorLine, BuildProblemLine, BuildLineSeverity,
  blsNone, blsError, blsWarning, blsInfo
from ../viewmodel/viewmodels/build_vm import
  BuildVM, BuildStatus, createBuildVM,
  setCommand, setRunning, setBuildStartTime, setCode, appendLine,
  appendError, appendProblem, clearOutput
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_build_view import mountIsoNimBuild

export build_location_parser

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by the terminal-output, event-log and calltrace
# migrations.
var buildVMInstance*: BuildVM
var buildVMStore: ReplayDataStore
var buildComponentRef: BuildComponent
var isoNimBuildMounted*: bool = false

proc tryMountIsoNimBuildPanel*()
proc parserSeverityToVM(sev: BuildSeverity): BuildLineSeverity
proc ansiToHtml(raw: cstring): cstring

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initBuildVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel ``BuildVM`` using an externally-provided
  ## ``ReplayDataStore`` (typically the shared store from
  ## ``SessionViewModel``).  If a stub-backed instance already exists
  ## (created by ``initBuildVM`` before the real backend was available)
  ## it is replaced so the panel uses the real backend.
  if buildVMInstance != nil:
    clog "BuildVM: replacing existing instance with shared-store version"
    isoNimBuildMounted = false
  buildVMStore = store
  buildVMInstance = createBuildVM(store)
  clog "BuildVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimBuildPanel()

proc initBuildVM() =
  ## Lazily create the parallel ``BuildVM`` backed by a stub
  ## ``BackendService``.  Fallback when no shared store has been
  ## provided via ``initBuildVMWithStore``.
  if buildVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  buildVMStore = createReplayDataStore(stubBackend)
  buildVMInstance = createBuildVM(buildVMStore)
  clog "BuildVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimBuildPanel()

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
  ## the per-event ``syncBuildOutputAppend`` path; this proc covers the
  ## bulk-replace scenario.
  if buildVMInstance.isNil or self.isNil:
    return
  buildVMInstance.clearOutput()
  buildVMInstance.setCommand(safeStr(self.build.command))
  buildVMInstance.setRunning(self.build.running)
  buildVMInstance.setCode(self.build.code)
  for entry in self.build.output:
    let raw = entry[0]
    let isStdout = entry[1]
    let rawText = safeStr(raw)
    let parsed = parseBuildLocation(rawText)
    var sevTag = blsNone
    var locPath = ""
    var locLine = 0
    var htmlText = rawText
    if parsed.found:
      sevTag = parserSeverityToVM(parsed.severity)
      locPath = parsed.path
      locLine = parsed.line
    when defined(js):
      # Convert ANSI escapes to HTML so the Web renderer can innerHTML
      # the line content.  The parsed-location case still uses the
      # original `raw` (unconverted) text because the legacy view did
      # the same — its `verbatim ansiToHtml(raw)` call passed `raw`
      # which was already the rendered display string for that line.
      if not raw.isNil:
        htmlText = $ansiToHtml(raw)
    buildVMInstance.appendLine(BuildOutputLine(
      htmlText: htmlText,
      isStdout: isStdout,
      severity: sevTag,
      locationPath: locPath,
      locationLine: locLine))
  for err in self.build.errors:
    let location = err[0]
    let rawLocation = err[1]
    let other = err[2]
    buildVMInstance.appendError(BuildErrorLine(
      locationPath: safeStr(location.path),
      locationLine: location.line,
      rawLocation: safeStr(rawLocation),
      other: safeStr(other)))
  for prob in self.build.problems:
    let sev = case prob.severity
              of ProbError:   blsError
              of ProbWarning: blsWarning
              of ProbInfo:    blsInfo
    buildVMInstance.appendProblem(BuildProblemLine(
      severity: sev,
      path: safeStr(prob.path),
      line: prob.line,
      col: prob.col,
      message: safeStr(prob.message)))

proc tryMountIsoNimBuildPanel*() =
  ## Mount the IsoNim build view into the GoldenLayout-managed (or
  ## standalone auto-hide) container.  The container's id is
  ## ``buildComponent-{id}``; the build panel is a singleton (id always
  ## 0) but we still resolve through the registered component's id
  ## field for symmetry with the other IsoNim mounts.
  ##
  ## Safe to call multiple times — mounts only once.  Retries until the
  ## DOM container appears (capped at 200 attempts, ~2 s) since
  ## GoldenLayout creates the host slightly after the layout state
  ## changes.
  if isoNimBuildMounted or buildVMInstance.isNil:
    return
  if buildComponentRef.isNil:
    return

  let key = cstring("buildComponent-" & $buildComponentRef.id)
  var retryCount = 0
  proc doMount() =
    if isoNimBuildMounted:
      return
    retryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if retryCount > 200:
        cerror "tryMountIsoNimBuildPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    # Replace any prior content (the layout bridge may have planted a
    # stub element before the IsoNim mount fires).
    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimBuildMounted = true
    try:
      mountIsoNimBuild(container, buildVMInstance)
    except:
      cerror "tryMountIsoNimBuildPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

  doMount()

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
    showOverlay(panel)

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

# AnsiUp converts ANSI escape sequences (e.g. from GCC, cargo, Go) to HTML
# <span> elements with inline styles. The library is already bundled via webpack.
var newAnsiUp {.importcpp: "new AnsiUp".}: proc: js
let buildAnsiUp {.exportc.} = newAnsiUp()

proc ansiToHtml(raw: cstring): cstring =
  ## Convert a single line of build output from raw text (possibly containing
  ## ANSI color codes) to an HTML string safe for use with `verbatim`.
  cast[cstring](buildAnsiUp.ansi_to_html(raw))

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

proc parserSeverityToVM(sev: BuildSeverity): BuildLineSeverity =
  ## Convert the build_location_parser severity into the
  ## platform-neutral ``BuildLineSeverity`` consumed by the IsoNim
  ## view.  Kept separate from ``buildSeverityToProblem`` so the
  ## Problems-panel and the build-line tagging stay independently
  ## evolvable.
  case sev
  of SevError:   blsError
  of SevWarning: blsWarning
  of SevInfo:    blsInfo

proc syncBuildOutputAppend(self: BuildComponent, htmlText: cstring,
                           isStdout: bool, severity: BuildLineSeverity = blsNone,
                           locationPath: cstring = cstring"",
                           locationLine: int = 0) =
  ## Mirror a single rendered output line into the IsoNim ``BuildVM``.
  ## The legacy data structures are still updated by the caller so any
  ## non-IsoNim consumers (Problems panel, etc.) keep working — the VM
  ## sync is purely additive.
  if buildVMInstance.isNil:
    return
  buildVMInstance.appendLine(BuildOutputLine(
    htmlText: $htmlText,
    isStdout: isStdout,
    severity: severity,
    locationPath: $locationPath,
    locationLine: locationLine))

template appendBuild(self: BuildComponent, buildLine: string, stdout: bool): untyped =
  let klass = if stdout: "build-stdout" else: "build-stderr"
  let (match, location, rawLocation, other) = self.matchLocation(buildLine)
  if match:
    if rawLocation.len > 0:
      self.build.output.add((rawLocation, stdout))
      let parsed0 = parseBuildLocation(buildLine)
      let sevTag = if parsed0.found: parserSeverityToVM(parsed0.severity) else: blsNone
      self.syncBuildOutputAppend(rawLocation, stdout, sevTag, location.path, location.line)
    if other.len > 0:
      self.build.output.add((other, stdout))
      self.syncBuildOutputAppend(other, stdout)
    self.build.errors.add((location, rawLocation, other))
    if not buildVMInstance.isNil:
      buildVMInstance.appendError(BuildErrorLine(
        locationPath: $location.path,
        locationLine: location.line,
        rawLocation: $rawLocation,
        other: $other))

    # BP-M4: Publish a structured Problem for the Problems panel.
    let parsed = parseBuildLocation(buildLine)
    if parsed.found:
      self.build.problems.add(BuildProblem(
        severity: buildSeverityToProblem(parsed.severity),
        path: cstring(parsed.path),
        line: parsed.line,
        col: parsed.col,
        message: cstring(parsed.message)))
      if not buildVMInstance.isNil:
        buildVMInstance.appendProblem(BuildProblemLine(
          severity: parserSeverityToVM(parsed.severity),
          path: parsed.path,
          line: parsed.line,
          col: parsed.col,
          message: parsed.message))
  else:
    if buildLine.len > 0:
      self.build.output.add((cstring(buildLine), stdout))
      # The Web renderer's per-line div uses innerHTML, so feed the
      # ANSI-converted HTML rather than the raw text. Falls back to the
      # plain text when ansiUp is unavailable (e.g. on the native code
      # path during tests where this file is not compiled).
      when defined(js):
        self.syncBuildOutputAppend(ansiToHtml(cstring(buildLine)), stdout)
      else:
        self.syncBuildOutputAppend(cstring(buildLine), stdout)

method onBuildCommand*(self: BuildComponent, response: BuildCommand) {.async.} =
  self.build.command = response.command
  # Initialise auto-scroll to on and record the build start time.
  self.build.autoScroll = true
  self.build.buildStartTime = dateNowMs()
  self.build.running = true

  # BP-M6: Auto-reveal the build pane if it is pinned to an auto-hide strip.
  autoRevealBuildPanel()

  # Mirror the start-of-build state into the IsoNim VM. The legacy
  # ``self.build`` record stays the source of truth for the Karax-driven
  # Problems panel; the VM mirrors only what the IsoNim view needs.
  if not buildVMInstance.isNil:
    buildVMInstance.setCommand($response.command)
    buildVMInstance.setBuildStartTime(self.build.buildStartTime)
    buildVMInstance.setRunning(true)
    # New builds clear the previous output so failures from one run
    # don't bleed into the next.
    buildVMInstance.clearOutput()

  self.data.redraw()

proc processBuildOutput(self: BuildComponent, data: cstring, isStdout: bool) =
  ## Process build output lines: split by newline, append each line to the
  ## build output, and trigger a redraw. Extracted to avoid a Nim async
  ## template macro bug with for-loop variables in {.async.} methods.
  let parts = ($data).splitLines
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
  if not buildVMInstance.isNil:
    buildVMInstance.setCode(response.code)
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
        showOverlay(errorsPanel)

    self.data.functions.switchToEdit(self.data)
  else:
    # BP-M6: On success, schedule auto-dismiss of the build overlay after
    # a short delay so the user can see the success state briefly.
    autoDismissBuildPanel()

    self.data.functions.switchToDebug(self.data)


# BuildComponent.render() removed: IsoNim is the primary renderer.
# The base ``Component.render()`` returns a valid empty VNode for any
# generic callers (auto-hide, vnodeToDom bridge); all real DOM
# construction happens in ``viewmodel/views/isonim_build_view.nim``.

method register*(self: BuildComponent, api: MediatorWithSubscribers) =
  ## Register the BuildComponent with the mediator.  Bring up the
  ## IsoNim BuildVM lazily so the mount procedure can find it; the
  ## shared-store version is installed by ``configureMiddleware`` if the
  ## ViewModel layer is enabled.
  self.api = api
  initBuildVM()
  if buildComponentRef.isNil:
    buildComponentRef = self
    tryMountIsoNimBuildPanel()
