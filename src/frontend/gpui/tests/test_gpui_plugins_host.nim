## test_gpui_plugins_host.nim — the GPUI window's door to its session's
## plugins (`host/gpui_plugins`, Extensibility-Model.md §11), against REAL
## plugin processes, and a contributed leaf drawn through the real
## isonim-gpui shim.
##
## Run in the `gpui-shell` lane (its glob), or:
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_plugins_host.nim
##
## The `acme-tools` test package is built and installed as a component by
## `plugin_process_fixture.installPackage`; the window's own entry point,
## `openWindowPlugins`, discovers it through `CODETRACER_COMPONENTS_ROOT`, reads
## the user's settings and grant ledger under `CODETRACER_USER_ROOT`, and starts
## its process — everything a window does at open, minus the window. The
## window itself (keys through a compositor, the footer, a pane docked by the
## omnibar) is `test_gpui_plugins_window.nim`'s, over a measured record.
##
## ## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK
##
## The primary session is a real `SessionViewModel` over
## `backend/mock_backend.MockBackendService`, one of the `BackendService`
## implementations the ViewModel layer ships, as the plugin-process suite
## (`viewmodel/tests/unit/test_plugin_process_host.nim`) uses it: these cases
## are about the plugins' door, not the replay, and the debugger's stop is
## written into the store as a replay's answer would write it. The real
## recording and replay-server are the window lane's.
##
## ## TIME
##
## The CI host runs at load above 100: every wait is on state, with a generous
## ceiling, and a threshold that is not a case's subject is widened.

import std/[json, options, os, posix, sequtils, sets, strutils, times, unittest]

import isonim/core/[owner]
import isonim_gpui/renderer

import codetracer_embed
import backend/mock_backend
import plugin_host/[protocol, supervisor]
import headless_app/layout_model
import ../app/shell
import ../app/leaves
import ../../view_vocabulary/editor_surface
import ../../viewmodel/viewmodels/omnibar_vm
import ../host/gpui_plugins
import ../../viewmodel/tests/unit/plugin_process_fixture

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const Ceiling = 120_000

proc nowMs(): int64 = int64(epochTime() * 1000)

proc waitFor(p: SessionPlugins; what: string; cond: proc(): bool;
             ceilingMs = Ceiling): bool {.discardable.} =
  let start = nowMs()
  while not cond():
    discard p.pump()
    if nowMs() - start > ceilingMs:
      checkpoint "timed out waiting for: " & what & "\n" & p.sup.report()
      return false
    os.sleep(5)
  true

var homeCount = 0

proc newHome(capture = false; flameMode = ""; flameSettings: JsonNode = nil): string =
  ## A user's components root with the package installed, and their
  ## settings, as `ct install` and a settings edit leave them.
  inc homeCount
  result = scratchRoot() / ("gpui-home-" & $getpid() & "-" & $homeCount)
  removeDir(result)
  createDir(result / "components")
  createDir(result / "user-root")
  var manifest = ""
  if capture:
    var doc = packageManifest()
    doc["plugins"][1]["capturesWindowInput"] = %*{"reason": "a modal layer"}
    manifest = $doc
  discard installPackage(result / "components", manifest)
  if flameMode.len > 0:
    var settings = if flameSettings.isNil: newJObject() else: flameSettings.copy
    settings["mode"] = %flameMode
    writeFile(result / "user-root" / "plugin-settings.json",
      $(%*{"plugins": {"acme-tools.flame": {"settings": settings}}}))
  putEnv("CODETRACER_COMPONENTS_ROOT", result / "components")
  putEnv("CODETRACER_USER_ROOT", result / "user-root")
  putEnv("XDG_STATE_HOME", result / "state")

proc newSession(): SessionViewModel =
  let mock = newMockBackendService(autoRespond = true)
  var session: SessionViewModel
  createRoot proc(dispose: proc()) =
    session = createSessionVM(mock.toBackendService())
    session.initializePanelViewModels()
  var st = session.store.debugger.val
  st.status = dsIdle
  st.location.file = "/src/main.nim"
  st.location.line = 10
  session.store.debugger.val = st
  session

proc widen(p: SessionPlugins) =
  p.sup.pongDeadlineMs = 20_000
  p.sup.busyHangMs = 30_000
  p.sup.helloDeadlineMs = 60_000

proc openFor(home: string; noExtensions = false): SessionPlugins =
  result = openWindowPlugins(newSession(), noExtensions, home)
  if not result.isNil: result.widen()

proc grantBoth(p: SessionPlugins) =
  discard p.control(@["grant", "acme-tools.metrics"])
  discard p.control(@["grant", "acme-tools.flame"])

proc running(p: SessionPlugins; id: string): bool =
  let s = p.sup.slot(id)
  not s.isNil and s.active

proc layerHeld(p: SessionPlugins): bool =
  ## The flame layer is on top AND its plugin is active: a layer arrives
  ## while the plugin is still activating, and the router skips the layers
  ## of a plugin that is not active yet (the supervisor suite's `layerUp`).
  p.layerLabel == "FLAME MODE (acme-tools.flame)" and p.running("acme-tools.flame")

proc labels(entries: seq[OmnibarEntry]): seq[string] =
  for e in entries: result.add e.label

proc elementText(node: GpuiElement): string =
  if node.isNil: return ""
  let n = childCount(node)
  if n == 0: return textContent(node).strip
  var parts: seq[string]
  for i in 0 ..< n:
    let t = elementText(nthChild(node, i))
    if t.len > 0: parts.add t
  parts.join(" ")

suite "GPUI: the window's plugins (host/gpui_plugins)":

  test "--no-extensions and CODETRACER_NO_EXTENSIONS start no plugin process":
    let home = newHome()
    let p = openFor(home, noExtensions = true)
    discard p.pump()
    os.sleep(300)
    discard p.pump()
    ck p.sup.processIds.len == 0
    ck not p.sup.extensionsEnabled
    ck p.loadedPanes.len == 0
    ck "--no-extensions" in p.control(@["status"]).body
    p.close()
    putEnv("CODETRACER_NO_EXTENSIONS", "1")
    ck extensionsOffFor(false)
    let q = openFor(home)
    ck not q.sup.extensionsEnabled
    q.close()
    delEnv("CODETRACER_NO_EXTENSIONS")
    ck not extensionsOffFor(false)
    ck extensionsOffFor(true)

  test "installing is not accepting; granted, one process runs both, and the omnibar lists them":
    let home = newHome()
    let p = openFor(home)
    ck p.awaitingConsent.len == 2
    let before = labels(p.pluginEntries)
    ck "Plugins: Grant acme-tools.metrics" in before
    ck "Plugins: Review acme-tools.flame" in before
    for _ in 0 ..< 20:
      discard p.pump()
      os.sleep(10)
    ck p.sup.processIds.len == 0
    p.grantBoth()
    ck p.waitFor("both running", proc(): bool =
      p.running("acme-tools.metrics") and p.running("acme-tools.flame"))
    ck p.sup.processIds.len == 1
    let after = p.pluginEntries
    let names = labels(after)
    for (label, _) in ReservedPaletteEntries:
      ck label in names
    ck "Metrics: Step forward (acme-tools.metrics)" in names
    ck "Show pane: Metrics (acme-tools.metrics/overview)" in names
    ck "Plugins: Grant acme-tools.metrics" notin names
    var run: seq[string]
    for e in after:
      if e.label == "Metrics: Step forward (acme-tools.metrics)":
        let w = pluginsWordsOf(e.target)
        ck w.ok
        run = w.words
    ck run == @["run", "acme-tools.metrics", "metrics.step"]
    ck pluginsWordsOf("plugins grant acme-tools.flame") ==
      (true, @["grant", "acme-tools.flame"])
    ck not pluginsWordsOf("constraints").ok
    let pid = p.sup.processIds[0]
    p.close()
    # The stop sequence ends the process (a group signal, then a reap).
    let start = nowMs()
    while kill(Pid(pid), 0) == 0 and nowMs() - start < 30_000:
      os.sleep(20)
    ck kill(Pid(pid), 0) != 0

  test "a plugin's relayed step arrives as the window's own control":
    let home = newHome()
    let p = openFor(home)
    let queue = new(seq[string])
    p.routeMovesToControls(queue)
    p.grantBoth()
    ck p.waitFor("metrics enabled", proc(): bool =
      p.running("acme-tools.metrics") and
        p.sup.enablementOf("acme-tools.metrics", "metrics.step").enabled)
    discard p.control(@["run", "acme-tools.metrics", "metrics.step"])
    ck p.waitFor("the move", proc(): bool = queue[].len > 0)
    ck queue[] == @["next"]
    p.close()

  test "a contributed leaf draws its plugin's view through the GPUI binding":
    let home = newHome()
    let p = openFor(home)
    p.grantBoth()
    ck p.waitFor("the metrics view", proc(): bool =
      "line main.nim:10" in elementText(renderLeaf(GpuiRenderer(),
        GpuiLeaf(kind: glkContributed, paneId: "acme-tools.metrics/overview",
                 title: "Metrics"),
        EditorSurface(medium: GpuiMedium),
        contributedView = p.paneView("acme-tools.metrics/overview"))[0]))
    let loaded = p.loadedPanes
    ck "acme-tools.metrics/overview" in loaded
    ck "acme-tools.flame/flame" in loaded
    ck classify(PaneRef(kind: prContributed, id: "acme-tools.metrics/overview"),
                loaded).kind == prContributed
    ck classify(PaneRef(kind: prContributed, id: "other.plugin/pane"),
                loaded).kind == prUnloadedExtension
    var r: GpuiRenderer
    let (node, reported) = renderLeaf(r, GpuiLeaf(kind: glkContributed,
      paneId: "acme-tools.metrics/overview", title: "Metrics"),
      EditorSurface(medium: GpuiMedium),
      contributedView = p.paneView("acme-tools.metrics/overview"))
    ck not reported
    ck getAttribute(node, StateAttribute) == "live"
    ck getAttribute(node, ContributedPaneAttribute) == "acme-tools.metrics/overview"
    let (bare, bareReported) = renderLeaf(r, GpuiLeaf(kind: glkContributed,
      paneId: "acme-tools.metrics/overview", title: "Metrics"),
      EditorSurface(medium: GpuiMedium))
    ck bareReported
    ck NoContributedViewReport in elementText(bare)
    p.close()

  test "keys: the layer takes Escape, the user's row beats the plugin pass, the chord recovers":
    let home = newHome(capture = true, flameMode = "swallow-input")
    let p = openFor(home)
    p.grantBoth()
    ck p.waitFor("the flame layer", proc(): bool =
      p.layerHeld)
    ck p.waitFor("metrics ready", proc(): bool =
      p.sup.enablementOf("acme-tools.metrics", "metrics.step").enabled)
    ck pluginKeyName("Esc") == "escape"
    ck pluginKeyName("Ctrl+Alt+M") == "ctrl+alt+m"
    # §11.7.2: a user row for the key keeps the plugin pass out.
    ck not p.routePluginKey("Ctrl+Alt+M", userBound = true)
    ck p.routePluginKey("Ctrl+Alt+M", userBound = false)
    # The footer names who holds the keyboard, whatever note is shown.
    ck p.windowFooterNote("a note").startsWith("FLAME MODE (acme-tools.flame)")
    ck "a note" in p.windowFooterNote("a note")
    # A plugin's status item stays on the footer beside a note.
    ck "metrics ok" in p.windowFooterNote("a note")
    # Only Escape counts towards the chord.
    for _ in 0 ..< 3: ck not p.observeWindowEscape("j")
    # The layer binds Escape: the first two go to it; the third recovers.
    ck not p.observeWindowEscape("Esc")
    let first = p.routePluginKey("Esc", userBound = false)
    if not first:
      checkpoint p.sup.report() & "\nlayer " & p.layerLabel & "\nevents:\n" &
        p.sup.events[max(0, p.sup.events.len - 20) .. ^1].join("\n")
    ck first
    ck not p.observeWindowEscape("Esc")
    ck p.routePluginKey("Esc", userBound = false)
    ck p.observeWindowEscape("Esc")
    ck p.layerLabel == ""
    ck "acme-tools.flame" in p.control(@["recovery-dialog"]).body
    p.close()

  test "a key the plugin swallows is dropped and said, and the plugin loses the keyboard":
    let home = newHome(capture = true, flameMode = "swallow-input")
    let p = openFor(home)
    p.grantBoth()
    ck p.waitFor("the flame layer", proc(): bool =
      p.layerHeld)
    ck p.routePluginKey("j", userBound = false)
    var note = ""
    ck p.waitFor("the dropped key", proc(): bool =
      let n = p.takeNote(" (Plugins: Show status for more)")
      if n.len > 0: note = n
      "went to acme-tools.flame" in note)
    ck note == "`j` went to acme-tools.flame, which did not answer"
    ck p.layerLabel == ""
    p.close()

  test "a layer that never answers: the first key dropped, the next falls through, the third opens the breaker":
    let home = newHome(capture = true, flameMode = "swallow-input")
    let p = openFor(home)
    p.sup.inputDeadlineMs = InputDeadlineMs   # the subject: the spec's value
    p.grantBoth()
    ck p.waitFor("the flame layer", proc(): bool =
      p.layerHeld)
    ck p.routePluginKey("j", userBound = false)
    ck p.waitFor("the missed deadline", proc(): bool =
      p.sup.slot("acme-tools.flame").suspect)
    ck p.takeNote(" (Plugins: Show status for more)") ==
      "`j` went to acme-tools.flame, which did not answer"
    # The second key is the window's: the layer is transparent.
    ck not p.routePluginKey("k", userBound = false)
    ck p.sup.slot("acme-tools.flame").breaker == bsClosed
    # The third strike opens the breaker, and the layer is gone for good.
    ck not p.routePluginKey("l", userBound = false)
    ck p.sup.slot("acme-tools.flame").breaker == bsOpen
    ck p.layerLabel == ""
    p.close()

  test "a key answered in 300 ms is no strike, and its latency is in the status":
    let home = newHome(capture = true, flameMode = "slow-ack",
                       flameSettings = %*{"ackDelayMs": 300})
    let p = openFor(home)
    p.sup.inputDeadlineMs = 10_000   # widened: 300 ms is the subject, not the clock
    p.grantBoth()
    ck p.waitFor("the flame layer", proc(): bool =
      p.layerHeld)
    ck p.routePluginKey("j", userBound = false)
    ck p.waitFor("the answer", proc(): bool =
      p.sup.slot("acme-tools.flame").ackSamples.len == 1)
    let s = p.sup.slot("acme-tools.flame")
    ck s.ackSamples[0] >= 300
    ck s.strikes.len == 0
    ck not s.suspect
    ck "ack p50" in p.control(@["status"]).body
    ck p.layerLabel == "FLAME MODE (acme-tools.flame)"
    p.close()

  test "a plugin killed while it holds the keyboard: its layer goes at once, the next key is the window's":
    let home = newHome(capture = true, flameMode = "swallow-input")
    let p = openFor(home)
    p.grantBoth()
    ck p.waitFor("the flame layer", proc(): bool =
      p.layerHeld)
    discard kill(Pid(p.sup.pidOf("acme-tools.flame")), SIGKILL)
    ck p.waitFor("the crash", proc(): bool =
      p.sup.faults.anyIt(it.kind == fkCrash))
    ck p.layerLabel == ""
    ck not p.routePluginKey("j", userBound = false)
    ck p.sup.slot("acme-tools.flame").breaker == bsOpen
    # The fault notification's actions are the omnibar's while it is stopped.
    ck "acme-tools.flame" in p.takeNote(" (Plugins: Show status for more)")
    let offered = labels(p.pluginEntries())
    ck "Plugins: Re-enable acme-tools.flame" in offered
    ck "Plugins: Disable acme-tools.flame" in offered
    ck "Plugins: Show log" in offered
    ck "Plugins: Re-enable acme-tools.metrics" notin offered
    # Re-enable, as the omnibar runs it: the entry's target, through the verbs.
    var target = ""
    for e in p.pluginEntries():
      if e.label == "Plugins: Re-enable acme-tools.flame": target = e.target
    let (ok, words) = pluginsWordsOf(target)
    ck ok
    ck p.control(words).body == "re-enabled acme-tools.flame (on probation)"
    ck p.sup.slot("acme-tools.flame").breaker == bsHalfOpen
    ck p.waitFor("the plugin running again", proc(): bool =
      p.running("acme-tools.flame"))
    ck "Plugins: Re-enable acme-tools.flame" notin labels(p.pluginEntries())
    p.close()

  test "half-open after the backoff, one strike reopens, the third opening latches until Re-enable":
    let home = newHome(capture = true, flameMode = "swallow-input")
    let p = openFor(home)
    p.sup.inputDeadlineMs = 300
    p.sup.breakerBackoffMs = 200
    p.sup.strikesToOpen = 1
    p.grantBoth()
    for opening in 1 .. 3:
      ck p.waitFor("the flame layer " & $opening, proc(): bool =
        p.layerHeld)
      ck p.routePluginKey("j", userBound = false)
      ck p.waitFor("opening " & $opening, proc(): bool =
        p.sup.slot("acme-tools.flame").openings == opening)
      if opening < 3:
        ck not p.sup.slot("acme-tools.flame").latched
        ck p.waitFor("half-open " & $opening, proc(): bool =
          p.sup.slot("acme-tools.flame").breaker == bsHalfOpen)
    ck p.sup.slot("acme-tools.flame").latched
    let latchedAt = nowMs()
    p.waitFor("a backoff's worth", proc(): bool = nowMs() - latchedAt > 600)
    ck p.sup.slot("acme-tools.flame").breaker == bsOpen
    ck "stopped until re-enabled" in p.control(@["status"]).body
    ck p.control(@["re-enable", "acme-tools.flame"]).body ==
      "re-enabled acme-tools.flame (on probation)"
    ck p.sup.slot("acme-tools.flame").breaker == bsHalfOpen
    ck p.waitFor("the layer back", proc(): bool =
      p.layerHeld)
    p.close()

  test "Show pane places a plugin's pane as a tab beside the Variables stack":
    let tree = sharedDefaultLayout().tree
    let cmd = tree.pluginPaneCommand("acme-tools.metrics/overview", "Metrics")
    ck cmd.kind == lcAddContributedPane
    ck cmd.addContributedAfter == some(paneState)
    # With no anchor placed, it still goes somewhere.
    let bare = contributedPaneNode("acme-tools.flame/flame", "Flame", 1.0)
    ck bare.pluginPaneCommand("acme-tools.metrics/overview", "Metrics").addContributedAfter.isNone

  test "assertion count":
    ck CHECKS == 118
    echo "CHECKS: ", CHECKS
