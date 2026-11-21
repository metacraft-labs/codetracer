## test_ct_lens_plugins.nim — the `ct-lens` plugin package
## (`src/plugins/ct-lens/`) driven as a REAL plugin process by the real
## `Supervisor`: one executable, two plugins, real pipes, a real `git`.
##
## `ct-lens.history` asks git which commits changed the function the debugger
## is stopped in, without holding its sibling while git runs. `ct-lens.watch`
## reads the core State ViewModel's change set and turns it into watches
## through the action relay, with pushed enablement and a context key for its
## key binding.
##
## ## THE STAND-INS, AND WHY THEY ARE NOT MOCKS
##
## * The primary session is a real `SessionViewModel` over
##   `backend/mock_backend.MockBackendService`, as `test_plugin_process_host`
##   uses it: these cases are about the plugins, not the replay. The stop and
##   the locals are written into the store the way a replay's answer writes
##   them, and the core `StateVM` derives its change set from them itself.
##   The real replay, the real recording and the real terminal are the TUI
##   suite's (`tui/tests/real_terminal/test_ct_lens_plugins_pty.nim`).
## * `slow-git` is a two-line shell script that sleeps and then runs the real
##   git with the same arguments. It is the one stand-in, and it is not a
##   mock: it is a slow repository, which is the condition under test, and
##   everything it answers comes from git.
## * The repository is real (`ct_lens_fixture.makeHistoryRepo`): three
##   commits, made by the suite.
##
## ## THE WEBASSEMBLY PORT (`-d:ctLensWasm`)
##
## Built with `-d:ctLensWasm`, the same file runs the `ct-lens.watch` suite
## against the plugin's WebAssembly build instead (`ct_lens_watch_wasm.nim`,
## one `plugin.wasm`), hosted by the real `ct-plugin-host`
## (Extensibility-Model.md §11.9): the same cases, the same assertions, no
## line changed between the two runs. The history and jump suites need the
## native package and are not compiled in.
##
## ## TIME
##
## The host is loaded (load above 100). Every wait is on STATE, with a
## generous ceiling, and the host's liveness thresholds are widened because
## they are not the subject here. The two cases about a slow git compare
## ORDER (the sibling answered while git was still running), not durations.

import std/[json, options, os, osproc, posix, sequtils, strutils, tables, times, unittest]

import isonim/core/[computation, owner, signals]

import codetracer_embed
import ../../../../common/value_presentation/presenter
import backend/mock_backend
import ../../../../common/plugin_model
import plugin_host/[protocol, supervisor]
import ct_lens_fixture

const Ceiling = 120_000
const LensWasm = defined(ctLensWasm)

proc waitUntil(sup: Supervisor; what: string; cond: proc(): bool;
               ceilingMs = Ceiling): bool {.discardable.} =
  let start = monotonicMs()
  while not cond():
    sup.poll()
    if monotonicMs() - start > ceilingMs:
      var panes = ""
      for pane in sup.contributedPanes:
        panes.add "\n" & pane.id & ": " & $sup.renderSurface(pane.id).toJson
      checkpoint "timed out waiting for: " & what & "\n" & sup.report() & panes &
        "\nevents:\n" & sup.events[max(0, sup.events.len - 30) .. ^1].join("\n")
      return false
    os.sleep(2)
  true

proc allText(n: ViewNode): string =
  if n.isNil: return ""
  result = n.label & " " & n.text
  for o in n.options: result.add " " & o.label
  for r in n.rows: result.add " " & r.join(" ")
  for c in n.children: result.add " " & allText(c)

type Rig = object
  sup: Supervisor
  session: SessionViewModel
  mock: MockBackendService
  dir: string
  repo: string
  file: string

var rigCount = 0

proc newRig(history: JsonNode = nil; watch: JsonNode = nil;
            tune: proc(s: Supervisor) = nil): Rig =
  inc rigCount
  let root = lensScratchRoot() / ("rig-" & $getpid() & "-" & $rigCount)
  removeDir(root)
  createDir(root)
  result.dir = when LensWasm: installLensWasm(root) else: installLens(root)
  result.repo = root / "repo"
  result.file = makeHistoryRepo(result.repo)
  let mock = newMockBackendService(autoRespond = true)
  result.mock = mock
  var session: SessionViewModel
  createRoot proc(dispose: proc()) =
    session = createSessionVM(mock.toBackendService())
    session.initializePanelViewModels()
  result.session = session
  let sup = newSupervisor("tui", "1.0.0", true)
  when LensWasm:
    sup.wasmHost = pluginHostBin()
  # Widened: liveness is not the subject of these cases (see the header).
  sup.pongDeadlineMs = 20_000
  sup.busyHangMs = 30_000
  sup.helloDeadlineMs = 60_000
  sup.inputDeadlineMs = 20_000
  sup.logDir = root / "logs"
  if not tune.isNil: tune(sup)
  let pkg = parsePluginPackage(readFile(result.dir / "plugin.json"),
                               "plugin.json", "ct-lens")
  doAssert pkg.allErrors.len == 0, renderAll(pkg.allErrors)
  sup.addPackage(result.dir, pkg)
  sup.configure("ct-lens.history", true,
                if history.isNil: newJObject() else: history)
  sup.configure("ct-lens.watch", true, if watch.isNil: newJObject() else: watch)
  sup.configure("ct-lens.jump", true, newJObject())
  sup.attachSession(session, "s1")
  result.sup = sup

proc both(r: Rig) =
  when LensWasm:
    r.sup.activate("ct-lens.watch")
    doAssert r.sup.waitUntil("watch active", proc(): bool =
      r.sup.slot("ct-lens.watch").active)
  else:
    r.sup.activate("ct-lens.history")
    r.sup.activate("ct-lens.watch")
    doAssert r.sup.waitUntil("both active", proc(): bool =
      r.sup.slot("ct-lens.history").active and r.sup.slot("ct-lens.watch").active)

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

proc calls(r: Rig; names: openArray[string]; current: int) =
  ## A loaded calltrace section, as a `ct/load-calltrace-section` answer
  ## lands: one call per name, the debugger in call `current`.
  var lines: seq[CallLine]
  for i, n in names:
    lines.add CallLine(index: i.int64, name: n, depth: 1, rrTicks: uint64(10 + i),
                       location: Location(file: "/src/calc.py", line: 10 * (i + 1)),
                       callKey: "call-" & $i)
  r.session.store.calltrace.startLineIndex.val = 0
  r.session.store.calltrace.lines.val = lines
  r.session.store.calltrace.currentLineIndex.val = current.int64

proc openJump(r: Rig) =
  r.sup.activate("ct-lens.jump")
  doAssert r.sup.waitUntil("jump active", proc(): bool =
    r.sup.slot("ct-lens.jump").active)
  r.calls(["main", "evaluate", "apply_op", "add"], 0)
  doAssert r.sup.waitUntil("jump.open enabled", proc(): bool =
    r.sup.enablementOf("ct-lens.jump", "jump.open").enabled)
  let route = r.sup.resolveStaticKey("shift+f7", "")
  doAssert route.found and route.op == "jump.open", $route
  discard r.sup.routeKey(route, "shift+f7")
  doAssert r.sup.waitUntil("the jump layer", proc(): bool =
    r.sup.topLayerLabel.len > 0)

proc locals(r: Rig; values: openArray[(string, string)]) =
  ## The locals of the current stop, as a `ct/load-locals` answer lands.
  var vs: seq[Variable]
  for (n, v) in values: vs.add Variable(name: n, value: v, typeName: "int")
  r.session.store.locals.loadedForRRTicks.val = r.session.store.debugger.val.rrTicks
  r.session.store.locals.locals.val = vs

proc pane(r: Rig; id: string): string = allText(r.sup.renderSurface(id))

proc status(r: Rig; item: string): string =
  for it in r.sup.statusItems:
    if it.item == item: return allText(it.tree).strip

proc expectedHistory(dir, file: string; first, last: int): seq[string] =
  ## What git itself says, so the plugin is checked against the tool.
  let (o, code) = execCmdEx(quoteShellCommand(["git", "-C", dir, "log",
    "--format=%h %s", "-s", "-L", $first & "," & $last & ":" & file.extractFilename]))
  doAssert code == 0, o
  for l in o.splitLines:
    if l.strip.len > 0: result.add l.strip

proc slowGit(r: Rig; sleepSeconds: int; never = false): string =
  ## A git that takes `sleepSeconds` to start, or (`never`) one that never
  ## answers: it becomes `sleep` in place, so the pid it writes beside itself
  ## is the process the plugin must kill.
  result = r.dir.parentDir / "slow-git"
  writeFile(result, "#!/bin/sh\necho $$ > \"$0.pid\"\n" &
    (if never: "exec sleep " & $sleepSeconds & "\n"
     else: "sleep " & $sleepSeconds & "\nexec git \"$@\"\n"))
  setFilePermissions(result, {fpUserRead, fpUserWrite, fpUserExec})

proc pidAlive(pid: int): bool = pid > 0 and kill(Pid(pid), 0) == 0

when not LensWasm:
  suite "ct-lens: one package, two plugins, one process":

    test "both plugins activate in one process and contribute their panes and status items":
      var r = newRig()
      r.both()
      check r.sup.pidOf("ct-lens.history") > 0
      check r.sup.pidOf("ct-lens.history") == r.sup.pidOf("ct-lens.watch")
      check r.sup.waitUntil("both panes", proc(): bool =
        "Line history" in r.pane("ct-lens.history/history") and
        "Changed at this step" in r.pane("ct-lens.watch/changes"))
      check r.sup.waitUntil("both status items", proc(): bool =
        r.status("history.status").len > 0 and r.status("watch.status").len > 0)
      r.sup.shutdown()

    test "disabling one plugin leaves the other working in the same process":
      var r = newRig()
      r.both()
      let pid = r.sup.pidOf("ct-lens.history")
      r.sup.setEnabled("ct-lens.watch", false)
      check r.sup.waitUntil("watch inactive", proc(): bool =
        not r.sup.slot("ct-lens.watch").active)
      r.stopAt(r.file, 5, 4, 6, "apply")
      check r.sup.waitUntil("history still follows the debugger", proc(): bool =
        "multiply instead of adding" in r.pane("ct-lens.history/history"))
      check r.sup.pidOf("ct-lens.history") == pid
      check r.status("watch.status").len == 0
      r.sup.shutdown()

when not LensWasm:
  suite "ct-lens.history: git, as a child process of the plugin":

    test "the commits that changed the function the debugger stopped in, newest first":
      var r = newRig()
      r.both()
      r.stopAt(r.file, 5, 4, 6, "apply")
      let want = expectedHistory(r.repo, r.file, 4, 6)
      check want.len == 2
      check r.sup.waitUntil("history of apply", proc(): bool =
        "multiply instead of adding" in r.pane("ct-lens.history/history"))
      let text = r.pane("ct-lens.history/history")
      check "History of apply (calc.py:4-6)" in text
      for w in want:
        check w.split(' ')[0] in text
      check "other returns two" notin text
      check text.find("multiply instead of adding") < text.find("create the calculator")
      # The status item is a frame of its own, after the pane's: waited for.
      check r.sup.waitUntil("the status item", proc(): bool =
        r.status("history.status").startsWith("history: " & want[0].split(' ')[0]) and
        "(2 commits)" in r.status("history.status"))
      # Another function: another range, another answer.
      r.stopAt(r.file, 10, 9, 10, "other")
      check r.sup.waitUntil("history of other", proc(): bool =
        "other returns two" in r.pane("ct-lens.history/history"))
      check "multiply instead of adding" notin r.pane("ct-lens.history/history")
      r.sup.shutdown()

    test "the commit that last changed the function decorates its first line":
      var r = newRig()
      r.both()
      r.stopAt(r.file, 5, 4, 6, "apply")
      let newest = expectedHistory(r.repo, r.file, 4, 6)[0].split(' ')[0]
      proc marks(r: Rig; doc: string): JsonNode =
        r.sup.slot("ct-lens.history").decorations.getOrDefault(doc, newJArray())
      check r.sup.waitUntil("the decoration", proc(): bool =
        r.marks(r.file).len == 1)
      let m = r.marks(r.file)[0]
      check m{"line"}.getInt(0) == 4
      check m{"text"}.getStr("").startsWith("history: " & newest & " ")
      check "multiply instead of adding" in m{"text"}.getStr("")
      # Another file: the first one's decoration is withdrawn.
      let loose = r.dir.parentDir / "loose"
      createDir(loose)
      writeFile(loose / "y.py", "y = 1\n")
      r.stopAt(loose / "y.py", 1)
      check r.sup.waitUntil("withdrawn", proc(): bool =
        r.marks(r.file).len == 0)
      r.sup.shutdown()

    test "a stop without a function range asks about its line alone":
      var r = newRig()
      r.both()
      r.stopAt(r.file, 1)
      check r.sup.waitUntil("history of line 1", proc(): bool =
        "History of calc.py:1" in r.pane("ct-lens.history/history") and
        "create the calculator" in r.pane("ct-lens.history/history"))
      check "multiply" notin r.pane("ct-lens.history/history")
      r.sup.shutdown()

    test "git's own refusal is shown, not an empty history":
      var r = newRig()
      r.both()
      let loose = r.dir.parentDir / "loose"
      createDir(loose)
      writeFile(loose / "x.py", "x = 1\n")
      r.stopAt(loose / "x.py", 1)
      check r.sup.waitUntil("not a repository", proc(): bool =
        "not a git repository" in r.pane("ct-lens.history/history").toLowerAscii)
      check r.sup.waitUntil("unavailable", proc(): bool =
        r.status("history.status") == "history: unavailable")
      r.sup.shutdown()

    test "a git that cannot be started is named":
      var r = newRig(history = %*{"git": "/nonexistent/ct-lens-git"})
      r.both()
      r.stopAt(r.file, 5, 4, 6, "apply")
      check r.sup.waitUntil("could not run", proc(): bool =
        "could not run /nonexistent/ct-lens-git" in r.pane("ct-lens.history/history"))
      r.sup.shutdown()

    test "a slow git does not hold the sibling plugin":
      var r = newRig()
      let slow = r.slowGit(8)
      r.sup.configure("ct-lens.history", true, %*{"git": slow})
      r.both()
      r.stopAt(r.file, 5, 4, 6, "apply")
      check r.sup.waitUntil("asking git", proc(): bool =
        "asking git" in r.pane("ct-lens.history/history"))
      # While git sleeps, the sibling answers a command and follows a step.
      r.stopAt(r.file, 5, 4, 6, "apply")
      r.locals({"total": "1"})
      check r.sup.waitUntil("watch follows while git runs", proc(): bool =
        "Changed at this step" in r.pane("ct-lens.watch/changes") and
        "waiting for the locals" notin r.pane("ct-lens.watch/changes"))
      check "asking git" in r.pane("ct-lens.history/history")
      let id = r.sup.invoke("ct-lens.watch", "watch.add-changed")
      check id.len > 0
      check r.sup.waitUntil("watch answered", proc(): bool =
        r.sup.takeAnswers(id).len > 0)
      check "asking git" in r.pane("ct-lens.history/history")
      # And git's answer still arrives.
      check r.sup.waitUntil("slow history", proc(): bool =
        "multiply instead of adding" in r.pane("ct-lens.history/history"))
      check r.sup.faults.len == 0
      r.sup.shutdown()

    test "a git past its deadline is killed and the history says so":
      var r = newRig()
      let slow = r.slowGit(600, never = true)
      r.sup.configure("ct-lens.history", true, %*{"git": slow, "timeoutMs": 300})
      r.both()
      r.stopAt(r.file, 5, 4, 6, "apply")
      check r.sup.waitUntil("deadline", proc(): bool =
        "did not answer within 300 ms" in r.pane("ct-lens.history/history"))
      # The program the plugin started is gone (killed and reaped), not left
      # running past the deadline it was given.
      check r.sup.waitUntil("pid written", proc(): bool =
        fileExists(slow & ".pid") and readFile(slow & ".pid").strip.len > 0)
      let pid = parseInt(readFile(slow & ".pid").strip)
      check r.sup.waitUntil("killed", proc(): bool = not pidAlive(pid))
      r.sup.shutdown()

suite "ct-lens.watch: the core change set, turned into watches":

  test "what the step changed, before and after, with the command enabled for it":
    var r = newRig()
    r.both()
    check r.sup.enablementOf("ct-lens.watch", "watch.add-changed").enabled == false
    r.stopAt(r.file, 4)
    r.locals({"a": "1"})
    r.stopAt(r.file, 5)
    r.locals({"a": "1", "b": "2"})
    # The plugin sees this stop before the next one, as it does between two
    # steps a user takes: the publisher merges whatever changed between two
    # polls into one batch, and a stop the plugin never saw has no "before".
    check r.sup.waitUntil("the first stop", proc(): bool =
      "b ? 2 new" in r.pane("ct-lens.watch/changes"))
    r.stopAt(r.file, 6)
    r.locals({"a": "1", "b": "5", "c": "7"})
    check r.sup.waitUntil("b and c changed", proc(): bool =
      let t = r.pane("ct-lens.watch/changes")
      "b 2 5 changed" in t and "c ? 7 new" in t)
    check " a 1 " notin r.pane("ct-lens.watch/changes")
    check r.sup.waitUntil("the status item", proc(): bool =
      r.status("watch.status") == "changed: b, c")
    check r.sup.waitUntil("enabled", proc(): bool =
      r.sup.enablementOf("ct-lens.watch", "watch.add-changed").enabled)
    check r.sup.waitUntil("context key", proc(): bool =
      r.sup.contextKeys.getOrDefault("plugin.ct-lens.watch.hasChanges", false))
    r.sup.shutdown()

  test "the command adds the changed values as watches in the core State ViewModel":
    var r = newRig()
    r.both()
    r.stopAt(r.file, 5)
    r.locals({"a": "1", "b": "2"})
    r.stopAt(r.file, 6)
    r.locals({"a": "3", "b": "2"})
    check r.sup.waitUntil("enabled", proc(): bool =
      r.sup.enablementOf("ct-lens.watch", "watch.add-changed").enabled)
    let id = r.sup.invoke("ct-lens.watch", "watch.add-changed")
    check id.len > 0
    check r.sup.waitUntil("the primary watches a", proc(): bool =
      "a" in r.session.stateVM.watchExpressions.val)
    check "b" notin r.session.stateVM.watchExpressions.val
    # Everything changed is watched now: the command says why it is off.
    check r.sup.waitUntil("disabled with the reason", proc(): bool =
      let e = r.sup.enablementOf("ct-lens.watch", "watch.add-changed")
      not e.enabled and e.reason == "every changed value is already watched")
    check r.sup.waitUntil("context key cleared", proc(): bool =
      not r.sup.contextKeys.getOrDefault("plugin.ct-lens.watch.hasChanges", true))
    r.sup.shutdown()

  test "a step that changed nothing disables the command, with the reason":
    var r = newRig()
    r.both()
    r.stopAt(r.file, 5)
    r.locals({"a": "1"})
    r.stopAt(r.file, 6)
    r.locals({"a": "1"})
    check r.sup.waitUntil("nothing changed", proc(): bool =
      "this step changed nothing" in r.pane("ct-lens.watch/changes"))
    check r.sup.waitUntil("disabled with the reason", proc(): bool =
      let e = r.sup.enablementOf("ct-lens.watch", "watch.add-changed")
      not e.enabled and e.reason == "this step changed nothing")
    r.sup.shutdown()

  test "its visualiser reaches the presenter at the plugin tier":
    var r = newRig()
    r.both()
    check r.sup.waitUntil("visualiser published", proc(): bool =
      r.sup.pluginVisualisers.anyIt(it.typeMatch == "NoneType"))
    let v = r.sup.pluginVisualisers.filterIt(it.typeMatch == "NoneType")[0]
    check v.tier == ptPlugin
    check v.id.startsWith("plugin:ct-lens.watch#")
    r.sup.setEnabled("ct-lens.watch", false)
    check r.sup.waitUntil("visualiser withdrawn", proc(): bool =
      not r.sup.pluginVisualisers.anyIt(it.typeMatch == "NoneType"))
    r.sup.shutdown()

when not LensWasm:
  suite "ct-lens.jump: a modal layer, and the input defences against its own code":

    test "its key opens a mode that lists the calls; a digit jumps through the calltrace":
      var r = newRig()
      r.openJump()
      check r.sup.topLayerLabel == "JUMP MODE (ct-lens.jump)"
      check "ct-lens.jump" in r.sup.topLayerLabel
      check r.sup.waitUntil("the choices on the status line", proc(): bool =
        "jump: 1 evaluate" in r.status("jump.status") and
        "3 add" in r.status("jump.status"))
      r.mock.clearReceivedCommands()
      let route = r.sup.resolveLayerKey("2", "")
      check route.found and route.plugin == "ct-lens.jump" and route.op == "jump.pick"
      discard r.sup.routeKey(route, "2")
      check r.sup.waitUntil("the jump reached the backend", proc(): bool =
        r.mock.findCommand("ct/calltrace-jump").isSome)
      let sent = r.mock.findCommand("ct/calltrace-jump").get
      # "2" is the second call after the current one: apply_op, at line 30.
      check sent.args{"line"}.getInt(0) == 30
      check r.sup.waitUntil("the mode closed", proc(): bool =
        r.sup.topLayerLabel.len == 0)
      r.sup.shutdown()

    test "a call activated in its docked pane is a jump, without the mode":
      var r = newRig()
      r.sup.activate("ct-lens.jump")
      check r.sup.waitUntil("jump active", proc(): bool =
        r.sup.slot("ct-lens.jump").active)
      r.calls(["main", "evaluate", "apply_op", "add"], 0)
      check r.sup.waitUntil("the calls listed", proc(): bool =
        "evaluate (calc.py:20)" in r.pane("ct-lens.jump/calls") and
        "add (calc.py:40)" in r.pane("ct-lens.jump/calls"))
      check r.sup.topLayerLabel.len == 0
      r.mock.clearReceivedCommands()
      # Row 1 (from 0) of the list is apply_op, the second call after main:
      # the transition the terminal's `applyKey` produces for Enter on it.
      r.sup.viewEvent("ct-lens.jump/calls",
        %*{"transition": "trActivate", "node": "calls.list", "kind": "List",
           "index": 1})
      check r.sup.waitUntil("the jump reached the backend", proc(): bool =
        r.mock.findCommand("ct/calltrace-jump").isSome)
      check r.mock.findCommand("ct/calltrace-jump").get.args{"line"}.getInt(0) == 30
      check r.sup.waitUntil("the pane says so", proc(): bool =
        "jumped to apply_op (calc.py:30)" in r.pane("ct-lens.jump/calls"))
      r.sup.shutdown()

    test "a mode plugin runs in a process of its own, apart from its siblings":
      var r = newRig()
      r.both()
      r.openJump()
      let jump = r.sup.pidOf("ct-lens.jump")
      check jump > 0
      check jump != r.sup.pidOf("ct-lens.history")
      check r.sup.pidOf("ct-lens.history") == r.sup.pidOf("ct-lens.watch")
      r.sup.shutdown()

    test "stopped while it holds the keyboard, it loses the keyboard; its siblings keep running":
      # The real thresholds: the input deadline is the subject here. The
      # plugin is stopped with SIGSTOP, as a debugger attaching to it or the
      # machine swapping it out would stop it — nothing in its code changes.
      var r = newRig(tune = proc(s: Supervisor) =
        s.inputDeadlineMs = 500)
      r.both()
      r.openJump()
      let pid = r.sup.pidOf("ct-lens.jump")
      let siblings = r.sup.pidOf("ct-lens.history")
      check kill(Pid(pid), SIGSTOP) == 0
      let route = r.sup.resolveLayerKey("1", "")
      check route.found and route.plugin == "ct-lens.jump"
      discard r.sup.routeKey(route, "1")
      check r.sup.waitUntil("the missed deadline", proc(): bool =
        "went to ct-lens.jump, which did not answer" in r.sup.statusLine)
      # Transparent now: the next digit is not the plugin's.
      check r.sup.waitUntil("transparent", proc(): bool =
        not r.sup.resolveLayerKey("1", "").found)
      check r.sup.waitUntil("its layer is gone", proc(): bool =
        r.sup.topLayerLabel.len == 0)
      discard kill(Pid(pid), SIGCONT)
      check r.sup.pidOf("ct-lens.history") == siblings
      r.stopAt(r.file, 5, 4, 6, "apply")
      check r.sup.waitUntil("history still answers", proc(): bool =
        "multiply instead of adding" in r.pane("ct-lens.history/history"))
      r.sup.shutdown()

    test "three Escapes take the keyboard back from its mode, and the healthy plugin gets it back":
      var r = newRig()
      r.openJump()
      check r.sup.observeEscape() == false
      check r.sup.observeEscape() == false
      check r.sup.observeEscape()
      check r.sup.topLayerLabel.len == 0
      check "ct-lens.jump" in r.sup.recoveryPlugins
      check not r.sup.resolveLayerKey("1", "").found
      # The chord is the user's gesture, not a fault: the healthy plugin gets
      # its key back once its watchdog answers idle, and the mode opens again.
      check r.sup.waitUntil("no longer suspect", proc(): bool =
        not r.sup.slot("ct-lens.jump").suspect)
      check r.sup.waitUntil("its key is live again", proc(): bool =
        r.sup.resolveStaticKey("shift+f7", "").found)
      let again = r.sup.resolveStaticKey("shift+f7", "")
      discard r.sup.routeKey(again, "shift+f7")
      check r.sup.waitUntil("the mode again", proc(): bool =
        r.sup.topLayerLabel == "JUMP MODE (ct-lens.jump)")
      r.sup.shutdown()
