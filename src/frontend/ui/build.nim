import ui_imports, ../[types, communication], build_location_parser, auto_hide, errors
import ../lib/ansi_html

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
  appendError, appendProblem, clearOutput, jumpToLine
from isonim/web/dom_api import nil
# `Signal.val` is a template, so reading a `BuildVM` signal here needs the
# module in scope even though the type arrives through `build_vm`. Used by the
# empty-record guard in `syncLegacyBuildIntoVM`.
from isonim/core/signals import Signal, val
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

var buildDiagnosticScanner: BuildLocationScanner
  ## THE READER THE `nargo` FAMILY NEEDS, and the reason this pane cannot use
  ## `parseBuildLocation` alone.
  ##
  ## `parseBuildLocation` is a function of ONE line. `nargo` — and every other
  ## `codespan-reporting` / `ariadne` producer — puts the severity keyword and
  ## the compiler's sentence on the line ABOVE the location:
  ##
  ##     warning: unused variable x
  ##       ┌─ src/main.nr:1:9
  ##
  ## so `parseNoirLocation` has nothing to read on the location line and
  ## returns the struct's zero value, `SevError`. Every Noir diagnostic
  ## therefore reached `buildSeverityToProblem` as an error, warnings included
  ## — measured on `test-programs/noir_build_error`: three diagnostics, two of
  ## them `warning:`, all three painted red in PROBLEMS. A warning presented as
  ## an error is a false alarm, and a pane that raises them stops being read.
  ##
  ## `BuildLocationScanner` was written for exactly this and had no product
  ## caller until this one: it was reached only from
  ## `viewmodel/tests/unit/test_noir_build_diagnostics.nim`.
  ##
  ## ## Why a module-level var here, when the type's own docs argue against one
  ##
  ## They argue against a global in `build_location_parser`, so that
  ## `parseBuildLocation` cannot answer differently for the same input
  ## depending on call history — the property that makes the parser testable.
  ## That is preserved: the state lives here, in the caller, exactly as the
  ## type prescribes.
  ##
  ## It is module-level rather than a `BuildComponent` field because this pane
  ## is a singleton and its producer is serial — `buildVMInstance`,
  ## `buildVMStore` and `buildComponentRef` above are module-level for the same
  ## reason. The two hazards the type names are both closed:
  ##   * a rerun inheriting the previous run's keyword — `onBuildCommand`
  ##     resets it, at the same instant it clears the pane;
  ##   * two concurrent builds colouring each other's rows — `onBuildCommand`
  ##     already calls `clearOutput`, so this pane cannot represent two builds
  ##     at once in the first place.
  ##
  ## The BULK-REPLAY path (`syncLegacyBuildIntoVM`) deliberately does NOT use
  ## this one. It walks a whole stored transcript from the start, so it owns a
  ## fresh local scanner; sharing this one would let a replay consume the live
  ## build's pending keyword.

proc tryMountIsoNimBuildPanel*()
proc parserSeverityToVM(sev: BuildSeverity): BuildLineSeverity
proc ansiToHtml(raw: cstring): cstring

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
  vm.onJumpToLine = proc(path: string, line: int) =
    discard data.openLocation(cstring(path), line)

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
  installBuildVMJumpCallback(buildVMInstance)
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
  installBuildVMJumpCallback(buildVMInstance)
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
     buildVMInstance.output.val.len > 0:
    return

  buildVMInstance.clearOutput()
  buildVMInstance.setCommand(safeStr(self.build.command))
  buildVMInstance.setRunning(self.build.running)
  buildVMInstance.setCode(self.build.code)
  # A FRESH scanner, local to this replay. `self.build.output` is walked whole
  # and from the start, so it is its own transcript; borrowing the live
  # producer's scanner would let a replay eat a pending keyword that belongs to
  # the build currently running.
  var replayScanner: BuildLocationScanner
  for entry in self.build.output:
    let raw = entry[0]
    let isStdout = entry[1]
    let rawText = safeStr(raw)
    let parsed = replayScanner.scan(rawText)
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
  # Reset the ErrorsVM problem list ahead of the bulk replay so we
  # don't double-up rows when E2E tests inject the legacy ``build``
  # record multiple times.
  errors.syncErrorsClear()
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
    buildVMInstance.appendProblem(problemRow)
    # Mirror into the ErrorsVM so the Problems panel reflects the
    # bulk-replay path that ``__ctRenderPanel`` uses for E2E tests.
    errors.syncErrorsAppendProblem(problemRow)

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

# AnsiUp converts ANSI escape sequences (e.g. from GCC, cargo, Go) to HTML
# <span> elements with inline styles. The library is already bundled via webpack.
# The instance comes from `lib/ansi_html` because that is where the escaping
# this line depends on is stated and asserted.
let buildAnsiUp {.exportc.} = ansi_html.newEscapingAnsiUp()

proc ansiToHtml(raw: cstring): cstring =
  ## Convert a single line of build output from raw text (possibly containing
  ## ANSI color codes) to an HTML string safe for use with `verbatim`.
  ansi_html.ansiToHtml(buildAnsiUp, raw)

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
  # EVERY line of the child's output goes through the scanner, in order, and
  # exactly once — including the lines that carry no location, because those
  # are where `nargo`'s severity keyword lives. A reader that only fed it lines
  # it had already decided were locations would never see a keyword at all.
  #
  # This call is what makes `buildDiagnosticScanner` reachable; see its
  # declaration for the defect that existed while it was not.
  let scanned = buildDiagnosticScanner.scan(buildLine)
  let (match, location, rawLocation, other) = self.matchLocation(buildLine)
  if match:
    if rawLocation.len > 0:
      self.build.output.add((rawLocation, stdout))
      let sevTag = if scanned.found: parserSeverityToVM(scanned.severity) else: blsNone
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
    #
    # From `scanned`, NOT from a second `parseBuildLocation(buildLine)` call.
    # The two differ on exactly the family this pane gets wrong without the
    # scanner: for a `┌─ path:line:col` line the stateless call returns
    # `SevError` and an empty message, so a `warning:` became a red row with
    # nothing written on it. `scanned` carries both down from the header.
    let parsed = scanned
    if parsed.found:
      self.build.problems.add(BuildProblem(
        severity: buildSeverityToProblem(parsed.severity),
        path: cstring(parsed.path),
        line: parsed.line,
        col: parsed.col,
        message: cstring(parsed.message)))
      let problemRow = BuildProblemLine(
        severity: parserSeverityToVM(parsed.severity),
        path: parsed.path,
        line: parsed.line,
        col: parsed.col,
        message: parsed.message)
      if not buildVMInstance.isNil:
        buildVMInstance.appendProblem(problemRow)
      # Mirror the structured diagnostic into the IsoNim ErrorsVM so
      # the Problems panel renders it without a separate sync pass.
      errors.syncErrorsAppendProblem(problemRow)
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
  # A NEW BUILD STARTS WITH NO PENDING KEYWORD. Without this, a run whose last
  # diagnostic header had no location line beneath it would hand its severity
  # to the FIRST located line of the next run — a warning from the previous
  # build painting this build's error orange, or the reverse.
  buildDiagnosticScanner.reset()
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

  # Mirror the per-build clear into the IsoNim ErrorsVM so the
  # Problems panel resets at the same instant the Build panel does.
  errors.syncErrorsClear()

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
        revealOverlay(errorsPanel)

    # HIGHLIGHT THE FIRST ERROR, AND DO NOT FOCUS ANYTHING (EMT-D21).
    #
    # `focusBuild` and `openLayoutTab` above only activate a tab; neither moves
    # keyboard focus, and this must not either. Selecting the first row gives
    # `next error` an origin and shows the user where they will land, while the
    # keyboard stays wherever it was — a build that pulled the caret out of the
    # editor would be unusable, and builds are frequent.
    errors.highlightFirstBuildError()

    self.data.functions.switchToEdit(self.data)
  else:
    # BP-M6: On success, schedule auto-dismiss of the build overlay after
    # a short delay so the user can see the success state briefly.
    autoDismissBuildPanel()

    self.data.functions.switchToDebug(self.data)


# BuildComponent.render() removed: IsoNim is the primary renderer.
# Generic callers are expected to use direct IsoNim mount paths; all real
# DOM construction happens in ``viewmodel/views/isonim_build_view.nim``.

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
