import ui_imports, ../types, build_location_parser, auto_hide

export build_location_parser

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

template appendBuild(self: BuildComponent, buildLine: string, stdout: bool): untyped =
  let klass = if stdout: "build-stdout" else: "build-stderr"
  let (match, location, rawLocation, other) = self.matchLocation(buildLine)
  if match:
    if rawLocation.len > 0:
      self.build.output.add((rawLocation, stdout))
    if other.len > 0:
      self.build.output.add((other, stdout))
    self.build.errors.add((location, rawLocation, other))

    # BP-M4: Publish a structured Problem for the Problems panel.
    let parsed = parseBuildLocation(buildLine)
    if parsed.found:
      self.build.problems.add(BuildProblem(
        severity: buildSeverityToProblem(parsed.severity),
        path: cstring(parsed.path),
        line: parsed.line,
        col: parsed.col,
        message: cstring(parsed.message)))
  else:
    if buildLine.len > 0:
      self.build.output.add((cstring(buildLine), stdout))

method onBuildCommand*(self: BuildComponent, response: BuildCommand) {.async.} =
  self.build.command = response.command
  # Initialise auto-scroll to on and record the build start time.
  self.build.autoScroll = true
  self.build.buildStartTime = dateNowMs()
  self.build.running = true

  # BP-M6: Auto-reveal the build pane if it is pinned to an auto-hide strip.
  autoRevealBuildPanel()

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


proc buildLocationView(self: BuildComponent, location: types.Location, raw: cstring, klass: string): VNode =
  result = buildHtml(tdiv(class = &"build-location {klass}", onclick = proc =
      discard jumpLocation(location))):
    text raw

proc buildErrorView(self: BuildComponent, location: types.Location, rawLocation: cstring, other: cstring): VNode =
  result = buildHtml(tdiv(class = "build-error",
    onclick = proc = discard jumpLocation(location))):
      tdiv(class="build-location"):
        text rawLocation
      tdiv(class="build-other"):
        text other

proc buildHeaderControls(self: BuildComponent): VNode =
  ## Render the compact header control buttons: stop, clear, auto-scroll toggle,
  ## and elapsed duration display.
  let isRunning = self.build.running
  result = buildHtml(tdiv(class="build-header-controls")):
    # Stop button — sends IPC to cancel the running build process.
    if isRunning:
      tdiv(class="build-ctrl-btn build-stop-btn", title="Stop build",
           onclick = proc =
             if not self.data.ipc.isNil:
               self.data.ipc.send(cstring"CODETRACER::build-cancel", js{})
      ):
        text "\u25A0" # ■ square stop icon
    else:
      tdiv(class="build-ctrl-btn build-stop-btn disabled", title="No build running"):
        text "\u25A0"

    # Clear button — empties all build output.
    tdiv(class="build-ctrl-btn build-clear-btn", title="Clear build output",
         onclick = proc =
           self.build.output = @[]
           self.build.errors = @[]
           self.build.problems = @[]
           self.data.redraw()
    ):
      text "\u2715" # ✕ clear icon

    # Auto-scroll toggle — toggles sticky scrolling behaviour.
    let scrollClass = if self.build.autoScroll: "build-ctrl-btn build-scroll-btn active"
                      else: "build-ctrl-btn build-scroll-btn"
    tdiv(class=scrollClass, title="Toggle auto-scroll",
         onclick = proc =
           self.build.autoScroll = not self.build.autoScroll
           if self.build.autoScroll:
             self.scrollBuildToBottom()
           self.data.redraw()
    ):
      text "\u2193" # ↓ down-arrow icon

    # Elapsed duration display — shown while a build is running.
    if isRunning:
      let elapsed = self.buildElapsedStr()
      if elapsed.len > 0:
        tdiv(class="build-duration"):
          text elapsed

method render*(self: BuildComponent): VNode =
  result = buildHtml(tdiv(class="build-panel")):
    if self.build.running:
      tdiv(class="build-header"):
        tdiv(class="build-command-label"):
          text "running " & self.build.command
        buildHeaderControls(self)
    elif self.build.code != 0 and self.build.output.len > 0:
      tdiv(class="build-header build-failed"):
        tdiv(class="build-command-label"):
          text "build failed (exit code " & $self.build.code & ")"
        buildHeaderControls(self)
    elif self.build.output.len > 0:
      tdiv(class="build-header build-succeeded"):
        tdiv(class="build-command-label"):
          text "build succeeded"
        buildHeaderControls(self)
    else:
      # No build output yet — still show the controls row so clear/scroll
      # are always accessible.
      tdiv(class="build-header"):
        tdiv(class="build-command-label"):
          text ""
        buildHeaderControls(self)
    tdiv(id="build", class="build-output-container"):
      for (raw, stdout) in self.build.output:
        let parsed = parseBuildLocation($raw)
        if parsed.found:
          # Clickable line -- navigate to the parsed location on click.
          let loc = types.Location(path: cstring(parsed.path), line: parsed.line)
          let colorClass = case parsed.severity
            of SevError: "build-line-error"
            of SevWarning: "build-line-warning"
            of SevInfo: "build-line-info"
          tdiv(class = "build-output-line build-clickable " & colorClass,
               onclick = proc = discard jumpLocation(loc)):
            verbatim ansiToHtml(raw)
        else:
          let klass = if stdout: "build-stdout" else: "build-stderr"
          tdiv(class=klass):
            verbatim ansiToHtml(raw)

proc renderErrorsView*(self: BuildComponent): VNode =
  result = buildHtml(tdiv):
    tdiv(id="build-errors"):
      for (location, rawLocation, other) in self.build.errors:
        buildErrorView(self, location, rawLocation, other)
