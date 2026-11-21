## test_gpui_ct_lens_plugins.nim — the `ct-lens` plugin package
## (`src/plugins/ct-lens/`) behind the GPUI window's door to its session's
## plugins (`host/gpui_plugins`), against its REAL plugin processes, a real
## git, and its panes drawn through the real isonim-gpui shim.
##
## Run in the `gpui-shell` lane (its glob), or:
##   nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_ct_lens_plugins.nim
##
## The package is built and installed as a component by
## `ct_lens_fixture.installLens`; `openWindowPlugins`, the window's own entry
## point, discovers it through `CODETRACER_COMPONENTS_ROOT`, reads the grant
## ledger under `CODETRACER_USER_ROOT` and starts its processes. Keys are
## handed to the door by their canonical names, as the window's key handler
## hands them; the window itself (a compositor, the footer drawn) is the
## window lane's.
##
## ## THE STAND-INS, AND WHY THEY ARE NOT MOCKS
##
## * The primary session is a real `SessionViewModel` over
##   `backend/mock_backend.MockBackendService`, as the GPUI plugin-host suite
##   (`test_gpui_plugins_host.nim`) uses it: the stop and the locals are
##   written into the store the way a replay's answer writes them, and the
##   core `StateVM` derives its change set from them itself. The real
##   recording and replay are the terminal suite's.
## * The repository is real: `ct_lens_fixture.makeHistoryRepo`, three commits.
##
## ## TIME
##
## The CI host runs at load above 100: every wait is on state, with a generous
## ceiling, and the liveness thresholds, which are not these cases' subject,
## are widened.

import std/[json, options, os, posix, strutils, times, unittest]

import isonim/core/[owner]
import isonim_gpui/renderer

import codetracer_embed
import backend/mock_backend
import plugin_host/supervisor
import ../app/leaves
import ../../view_vocabulary/editor_surface
import ../../viewmodel/viewmodels/omnibar_vm
import ../host/gpui_plugins
import ../../viewmodel/tests/unit/ct_lens_fixture

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

type Rig = object
  p: SessionPlugins
  session: SessionViewModel
  mock: MockBackendService
  repo, file: string

var homeCount = 0

proc newRig(): Rig =
  inc homeCount
  let home = lensScratchRoot() / ("gpui-home-" & $getpid() & "-" & $homeCount)
  removeDir(home)
  createDir(home / "components")
  createDir(home / "user-root")
  discard installLens(home / "components")
  result.repo = home / "repo"
  result.file = makeHistoryRepo(result.repo)
  putEnv("CODETRACER_COMPONENTS_ROOT", home / "components")
  putEnv("CODETRACER_USER_ROOT", home / "user-root")
  putEnv("XDG_STATE_HOME", home / "state")
  let mock = newMockBackendService(autoRespond = true)
  result.mock = mock
  var session: SessionViewModel
  createRoot proc(dispose: proc()) =
    session = createSessionVM(mock.toBackendService())
    session.initializePanelViewModels()
  result.session = session
  result.p = openWindowPlugins(session, false, home)
  result.p.sup.pongDeadlineMs = 20_000
  result.p.sup.busyHangMs = 30_000
  result.p.sup.helloDeadlineMs = 60_000

proc grantAll(r: Rig) =
  for id in ["ct-lens.history", "ct-lens.watch", "ct-lens.jump"]:
    discard r.p.control(@["grant", id])

proc running(r: Rig; id: string): bool =
  let s = r.p.sup.slot(id)
  not s.isNil and s.active

proc stopAt(r: Rig; file: string; line: int; first = 0; last = 0;
            function = "") =
  var st = r.session.store.debugger.val
  st.status = dsIdle
  st.location.file = file
  st.location.line = line
  inc st.rrTicks
  var stop = r.session.store.stop.val
  stop.path = file
  stop.line = line
  stop.functionName = function
  stop.functionFirst = first
  stop.functionLast = last
  r.session.store.stop.val = stop
  r.session.store.debugger.val = st

proc locals(r: Rig; values: openArray[(string, string)]) =
  var vs: seq[Variable]
  for (n, v) in values: vs.add Variable(name: n, value: v, typeName: "int")
  r.session.store.locals.loadedForRRTicks.val = r.session.store.debugger.val.rrTicks
  r.session.store.locals.locals.val = vs

proc elementText(node: GpuiElement): string =
  if node.isNil: return ""
  let n = childCount(node)
  if n == 0: return textContent(node).strip
  var parts: seq[string]
  for i in 0 ..< n:
    let t = elementText(nthChild(node, i))
    if t.len > 0: parts.add t
  parts.join(" ")

proc drawn(r: Rig; pane, title: string): string =
  ## The pane as the window draws it: the pushed view through the GPUI
  ## vocabulary binding, read back from the element tree.
  var g: GpuiRenderer
  elementText(renderLeaf(g, GpuiLeaf(kind: glkContributed, paneId: pane,
    title: title), EditorSurface(medium: GpuiMedium),
    contributedView = r.p.paneView(pane))[0])

proc labels(entries: seq[OmnibarEntry]): seq[string] =
  for e in entries: result.add e.label

suite "GPUI: the ct-lens package behind the window's plugins":

  test "granted from the omnibar's verbs, history and watch share a process; jump has its own":
    var r = newRig()
    let before = labels(r.p.pluginEntries)
    ck "Plugins: Grant ct-lens.history" in before
    r.grantAll()
    ck r.p.waitFor("all three running", proc(): bool =
      r.running("ct-lens.history") and r.running("ct-lens.watch") and
        r.running("ct-lens.jump"))
    ck r.p.sup.processIds.len == 2
    ck r.p.sup.pidOf("ct-lens.history") == r.p.sup.pidOf("ct-lens.watch")
    ck r.p.sup.pidOf("ct-lens.jump") != r.p.sup.pidOf("ct-lens.history")
    let names = labels(r.p.pluginEntries)
    ck "Show pane: Line history (ct-lens.history/history)" in names
    ck "Show pane: Jump to call (ct-lens.jump/calls)" in names
    ck "Changed values: Watch what this step changed (ct-lens.watch)" in names
    r.p.close()

  test "line history is drawn through the GPUI binding, and its status item reaches the footer":
    var r = newRig()
    r.grantAll()
    ck r.p.waitFor("history running", proc(): bool = r.running("ct-lens.history"))
    r.stopAt(r.file, 5, 4, 6, "apply")
    ck r.p.waitFor("the commits drawn", proc(): bool =
      "multiply instead of adding" in r.drawn("ct-lens.history/history", "Line history"))
    let text = r.drawn("ct-lens.history/history", "Line history")
    ck "History of apply (calc.py:4-6)" in text
    ck "create the calculator" in text
    ck "other returns two" notin text
    ck r.p.waitFor("the status item", proc(): bool =
      "(2 commits)" in r.p.windowFooterNote(""))
    ck "history: " in r.p.windowFooterNote("")
    r.p.close()

  test "F7 from the window watches what the step changed":
    var r = newRig()
    r.grantAll()
    ck r.p.waitFor("watch running", proc(): bool = r.running("ct-lens.watch"))
    # The window hands the door its keys by canonical name, after the user's
    # own rows: F7 is the plugin's only while something is left to watch.
    ck not r.p.routePluginKey("F7", userBound = false)
    r.stopAt(r.file, 4)
    r.locals({"a": "1"})
    r.stopAt(r.file, 5)
    r.locals({"a": "1", "b": "2"})
    ck r.p.waitFor("enabled", proc(): bool =
      r.p.sup.enablementOf("ct-lens.watch", "watch.add-changed").enabled)
    ck r.p.routePluginKey("F7", userBound = false)
    ck r.p.waitFor("the primary watches b", proc(): bool =
      "b" in r.session.stateVM.watchExpressions.val)
    ck r.p.waitFor("disabled with the reason", proc(): bool =
      let e = r.p.sup.enablementOf("ct-lens.watch", "watch.add-changed")
      not e.enabled and e.reason == "every changed value is already watched")
    r.p.close()

  test "Shift+F7's mode is named on the footer; three Escapes take the keyboard back":
    var r = newRig()
    r.grantAll()
    ck r.p.waitFor("jump running", proc(): bool = r.running("ct-lens.jump"))
    var lines: seq[CallLine]
    for i, n in ["main", "evaluate", "apply_op"]:
      lines.add CallLine(index: i.int64, name: n, depth: 1, rrTicks: uint64(10 + i),
                         location: Location(file: "/src/calc.py", line: 10 * (i + 1)),
                         callKey: "call-" & $i)
    r.session.store.calltrace.startLineIndex.val = 0
    r.session.store.calltrace.lines.val = lines
    r.session.store.calltrace.currentLineIndex.val = 0
    ck r.p.waitFor("jump.open enabled", proc(): bool =
      r.p.sup.enablementOf("ct-lens.jump", "jump.open").enabled)
    # The docked pane lists the calls before any mode is open.
    ck r.p.waitFor("the calls drawn", proc(): bool =
      "evaluate (calc.py:20)" in r.drawn("ct-lens.jump/calls", "Jump to call"))
    ck r.p.routePluginKey("Shift+F7", userBound = false)
    ck r.p.waitFor("the mode", proc(): bool =
      r.p.layerLabel == "JUMP MODE (ct-lens.jump)")
    ck r.p.windowFooterNote("a note").startsWith("JUMP MODE (ct-lens.jump)")
    # A digit in the mode is a jump through the calltrace.
    r.mock.clearReceivedCommands()
    ck r.p.routePluginKey("2", userBound = false)
    ck r.p.waitFor("the jump reached the backend", proc(): bool =
      r.mock.findCommand("ct/calltrace-jump").isSome)
    ck r.mock.findCommand("ct/calltrace-jump").get.args{"line"}.getInt(0) == 30
    ck r.p.waitFor("the mode closed", proc(): bool = r.p.layerLabel == "")
    # Open again, then the chord.
    ck r.p.routePluginKey("Shift+F7", userBound = false)
    ck r.p.waitFor("the mode again", proc(): bool =
      r.p.layerLabel == "JUMP MODE (ct-lens.jump)")
    ck not r.p.observeWindowEscape("Esc")
    ck not r.p.observeWindowEscape("Esc")
    ck r.p.observeWindowEscape("Esc")
    ck r.p.layerLabel == ""
    ck "ct-lens.jump" in r.p.control(@["recovery-dialog"]).body
    r.p.close()

  test "assertion count":
    ck CHECKS == 37
    echo "CHECKS: ", CHECKS
