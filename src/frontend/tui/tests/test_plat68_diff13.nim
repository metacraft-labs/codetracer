## test_plat68_diff13.nim — PLAT-68 DIFF-13: ONE KEY, ONE SITUATION, ONE
## ANSWER ON EVERY FRONT-END.
##
## Base-Keymaps-And-Layer-Stack.md §6: the keymaps and the user's
## configuration are SHARED; how input reaches them — the scope path a
## front-end reads off its own focus chain and the facts its ViewModels hold —
## is the front-end's. This suite holds the two native front-ends to that, on
## the same recording, in the same situations:
##
##   * the read-only editor focused (Debug mode's start);
##   * a list pane focused (the call trace);
##   * the palette open over the editor;
##   * the editor made writable (`Ctrl+E`);
##
## and for each, a fixed set of keys. The TERMINAL is asked in process —
## `runtime.probeKey`, its own scope path (`scopePath`, read off the
## `isonim-tui` focus tree) and facts — and GPUI through the SHIPPED binary's
## window plan — `--window-ops=…,probe:<key>`, its scope path read off GPUI's
## element focus chain. Each answers `<key> at <scope path> -> <resolution>`
## (`keymap_router.describeResolution`), and the two must be the same string:
## the same scope path from two different focus models, and so the same
## operation from the one router.
##
## No mocks: the terminal's runtime over a real `replay-server` session, the
## GPUI binary over the same recording and its own engine.

import std/[os, osproc, streams, strtabs, strutils, tables, tempfiles, unittest]
import ../../gpui/tests/gpui_child_env

import codetracer_embed
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 62

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50

type
  Situation = object
    name: string
    gpuiOps: string
      ## The window events that put GPUI in the situation.
    tuiTokens: seq[string]
      ## The bytes that put the terminal there (after its focus is set).
    tuiPane: PaneKind

  Probe = tuple[tuiName, gpuiKey: string]
    ## One key: its canonical name, and GPUI's `probe:` spelling of it.

const
  Probes: seq[Probe] = @[
    ("F10", "f10"), ("n", "n"), ("s", "s"), ("Enter", "enter"),
    ("Shift+Down", "down:shift"), ("Ctrl+c", "c:control"),
    ("Esc", "escape"), ("Home", "home"), ("x", "x"), ("Ctrl+p", "p:control"),
    ("Ctrl+e", "e:control"), ("a", "a")]

  Situations = [
    Situation(name: "the read-only editor", gpuiOps: "", tuiTokens: @[],
              tuiPane: paneEditor),
    Situation(name: "the call trace (a list)", gpuiOps: "click:tab:calltrace",
              tuiTokens: @[], tuiPane: paneCalltrace),
    Situation(name: "the palette over the editor", gpuiOps: "key:p:control",
              tuiTokens: @["\x10"], tuiPane: paneEditor),
    Situation(name: "the writable editor", gpuiOps: "key:e:control",
              tuiTokens: @["\x05"], tuiPane: paneEditor)]

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let gpuiBin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc gpuiAnswers(subject, ops: string): seq[string] =
  ## Every `probe` line the GPUI window traced, in order.
  if not fileExists(gpuiBin):
    raise newException(IOError, "prerequisite missing: " & gpuiBin &
                       " (just build-gpui)")
  let state = createTempDir("plat68-diff13-", "")
  defer: removeDir(state)
  var env = newStringTable()
  for k, v in envPairs(): env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env["CODETRACER_TUI_LAYOUT_DIR"] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_KEYBINDINGS"] = state / "keybindings.json"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let errFile = state / "trace.err"
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             gpuiBin, "--report-window-plan", "--width=1440", "--height=1400",
             "--window-ops=" & ops, subject],
    env = env, options = {})
  discard p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let trace = if fileExists(errFile): readFile(errFile) else: ""
  if rc != 0:
    checkpoint(trace)
    raise newException(IOError, "the GPUI window plan failed: " & ops)
  for line in trace.splitLines:
    if line.startsWith("gesture probe "):
      result.add line["gesture probe ".len .. ^1]

proc tuiAnswers(subject: string; s: Situation): seq[string] =
  ## The terminal's answers in the same situation: the runtime over a real
  ## session of the same recording.
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  let rt = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard rt.enableLayoutBinding()
  let session = openTuiSession(subject, viewportHeight = Rows - 8)
  defer: session.close()
  session.header(rt)
  session.learnExtent()
  session.refresh(rt)
  doAssert rt.focus.focusPaneKind(s.tuiPane)
  for t in s.tuiTokens:
    session.applyOutcome(rt, rt.handleToken(t, 0))
  for (name, _) in Probes:
    let path = rt.scopePath
    result.add name & " at " & $path & " -> " &
               describeResolution(rt.probeKey(name))

let calc = resolveFixture("calc")

suite "PLAT-68 DIFF-13: the terminal and GPUI answer every key alike":

  for s in Situations:
    test "in " & s.name:
      require calc.outcome == foRecorded
      var ops: seq[string] = @[]
      if s.gpuiOps.len > 0: ops.add s.gpuiOps
      for (_, key) in Probes: ops.add "probe:" & key
      let gpui = gpuiAnswers(calc.tracePath, ops.join(","))
      let tui = tuiAnswers(calc.tracePath, s)
      ck gpui.len == Probes.len
      ck tui.len == Probes.len
      for i in 0 ..< min(gpui.len, tui.len):
        checkpoint("terminal: " & tui[i])
        checkpoint("GPUI:     " & gpui[i])
        ck tui[i] == gpui[i]

  test "the situations are told apart (the differential is not vacuous)":
    # The same key resolves differently across the situations — on BOTH
    # front-ends — so agreement above is about the situation, not a constant.
    require calc.outcome == foRecorded
    var nAnswers: seq[string] = @[]
    for s in Situations:
      let tui = tuiAnswers(calc.tracePath, s)
      nAnswers.add tui[1].split(" -> ")[1]   # `n`
    checkpoint($nAnswers)
    ck nAnswers[0] == "operation debugger.step-over"     # read-only editor
    ck nAnswers[1] == "operation debugger.step-over"     # a list
    ck nAnswers[2] == "character n"                      # the palette's field
    ck nAnswers[3] == "character n"                      # the writable editor

suite "PLAT-68: an overlay hands the focus back":

  test "closing the palette hands the focus back to the pane it covered":
    # The palette hangs at the window (`motions.scopePathOf`); the pane it
    # covered is held (`heldPane`) and has the focus again when it closes —
    # not the first pane of the ring.
    require calc.outcome == foRecorded
    let caps = resolveCapabilities(
      initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                      lang = "en_US.UTF-8"), initCapabilityFlags())
    let rt = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
    discard rt.enableLayoutBinding()
    let session = openTuiSession(calc.tracePath, viewportHeight = Rows - 8)
    defer: session.close()
    session.header(rt)
    session.learnExtent()
    session.refresh(rt)
    doAssert rt.focus.focusPaneKind(paneCalltrace)
    let before = $rt.scopePath
    session.applyOutcome(rt, rt.handleToken("\x10", 0))     # Ctrl+P
    ck rt.app.omnibar.isOpen
    session.applyOutcome(rt, rt.handleToken("\e", 0))       # Esc
    checkpoint(before & " -> " & $rt.scopePath)
    ck $rt.scopePath == before

suite "PLAT-68 DIFF-13: assertion count":
  test "the declared count was reached":
    check countedAssertions == ExpectedAssertions
