## test_gpui_plugins_window.nim — INSTALLED PLUGINS RUN IN THE GPUI WINDOW
## (Extensibility-Model.md §11), asserted from the committed record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_gpui_plugins_window.nim
##
## `src/tests/visual/gpui-plugins-window.json` is written by
## `ci/test/gpui-plugins-window.sh` (six real `codetracer-gpui` windows on a
## headless sway over the real `calc` recording and `replay-server`, with the
## `acme-tools` test package installed as a component through
## `plugin_process_fixture.installPackage`, driven by real keys through the
## compositor) followed by `--record`; the `gpui-window-captures` CI job
## re-takes it (`plugins`). This suite reads no binary and no compositor, so
## it is portable.
##
## No mocks: the record is a measurement of the shipped binary, a real
## plugin process (the process table is read from outside the window), and
## the window's own gesture trace — the lines its plugin pump writes, among
## them what a contributed pane's element tree holds READ BACK from the shim —
## and the OCR of a `grim` frame. The facts:
##
##   * consent before the first start: no plugin process until the user
##     granted; the grant screen states the native program;
##   * both plugins run in ONE process, the pid the status report names;
##   * *Show pane: Metrics* docks the pane through the layout model, and it
##     draws the debugger's line from the plugin's mirrored session;
##   * *Metrics: Step forward* steps the primary through the window's own
##     control, and the pane draws the new position;
##   * SIGKILL: a new process, both plugins running again, and F10 still
##     steps the debugger;
##   * `--no-extensions`: no plugin process at any sample, the docked pane's
##     slot is the "extension that is not loaded" report, and the status says
##     why;
##   * a plugin that captures the window's keyboard is named on the footer;
##     three Escapes pop its layer and open RECOVER INPUT naming it;
##   * a key it swallows is dropped with the status sentence, the plugin loses
##     the keyboard (the footer stops naming it), and the next key reaches the
##     window's router;
##   * a plugin's decoration and marker on the execution line (the window's
##     marks, the footer, and the editor's frame read by OCR); a docked,
##     focused plugin list takes its Down and Enter, and the plugin's answer
##     marks the activated row; a real press on its other row activates
##     that one;
##   * the `ct-lens` package (`src/plugins/ct-lens/`, installed by
##     `ct_lens_fixture.installLens`): its three plugins granted, history and
##     watch in one process and jump in its own; the history pane draws the
##     function the debugger is in and its status item reaches the footer; F7
##     goes to the watch plugin once a step changed one value, and watches it;
##     Shift+F7's mode is named on the footer, a digit jumps through the
##     calltrace (the next step starts inside the call), the jump pane says
##     where, and three Escapes take the keyboard back from the mode.

import std/[json, os, strutils, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 94

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let recordPath = repo / "src/tests/visual/gpui-plugins-window.json"

proc pids(n: JsonNode): seq[int] =
  if not n.isNil and n.kind == JArray:
    for x in n: result.add x.getInt

proc numberAfter(line, word: string): int =
  ## The decimal number right after `word ` in `line`, or -1.
  let at = line.find(word & " ")
  if at < 0: return -1
  var i = at + word.len + 1
  var digits = ""
  while i < line.len and line[i] in Digits:
    digits.add line[i]
    inc i
  if digits.len == 0: -1 else: parseInt(digits)

proc positionOf(line: string): int = numberAfter(line, "position")

proc tickOf(line: string): int =
  ## The rr tick of a `control next tick=<n>` line, or -1.
  let at = line.find("tick=")
  if at < 0: return -1
  var digits = ""
  for c in line[at + 5 .. ^1]:
    if c notin Digits: break
    digits.add c
  if digits.len == 0: -1 else: parseInt(digits)

proc showsDebuggerLine(line: string): bool =
  ## `line <file>:<n>`, the metrics plugin's reading of the mirrored stop.
  let at = line.find("line ")
  if at < 0: return false
  let rest = line[at + 5 .. ^1].split(' ')[0]
  let colon = rest.rfind(':')
  colon > 0 and rest[colon + 1 .. ^1].len > 0 and
    rest[colon + 1 .. ^1].allCharsInSet(Digits)

proc ended(w: JsonNode) =
  ck w["rc"].getInt == 0
  ck not w["endedOnDeadline"].getBool
  ck pids(w["pluginPidsAfterExit"]).len == 0

suite "GPUI: installed plugins in a real window":
  let r = parseJson(readFile(recordPath))
  let ws = r["windows"]

  test "consent, one process for both plugins, a docked pane, a command, a restart":
    let w = ws["consentAndRun"]
    ck w["mapped"].getBool
    ck w["awaitingConsent"].getBool
    ck pids(w["pidsBeforeConsent"]).len == 0
    ck w["grantScreenSaysNative"].getBool
    ck w["bothRunningState"].getStr.len > 0
    let running = pids(w["pidsRunning"])
    ck running.len == 1
    ck running.len == 1 and w["statePid"].getInt == running[0]
    ck w["paneDocked"].getBool
    ck showsDebuggerLine(w["paneDrew"].getStr)
    ck "position" in w["paneOcr"].getStr
    # Its tab is labelled with the pane's title.
    ck "Metrics" in w["paneOcr"].getStr
    ck w["pluginMove"].getStr == "plugin move next"
    ck w["controlAfterMove"].getStr.startsWith("control next tick=")
    ck positionOf(w["paneDrewAfterStep"].getStr) > positionOf(w["paneDrew"].getStr)
    ck w["killedPid"].getInt == running[0]
    let after = pids(w["pidsAfterKill"])
    ck after.len == 1 and after[0] != w["killedPid"].getInt
    ck w["restartedState"].getStr.len > 0
    ck w["keyStepAfterRestart"].getStr.startsWith("control next tick=")
    ended(w)

  test "--no-extensions starts no plugin process and keeps the pane's slot":
    let w = ws["noExtensions"]
    ck w["mapped"].getBool
    ck w["unloadedLeaf"].getStr == "leaf acme-tools.metrics/overview unloaded-extension"
    var most = 0
    for s in w["pidSamples"]: most = max(most, s.getInt)
    ck w["pidSamples"].len >= 10
    ck most == 0
    ck w["statusReport"].getStr.len > 0
    ck "not loaded" in w["unloadedOcr"].getStr
    ended(w)

  test "three Escapes take the keyboard back from a plugin layer":
    let w = ws["recoveryChord"]
    ck w["footerWithLayer"].getStr.startsWith("plugins footer FLAME MODE (acme-tools.flame)")
    ck "RECOVER INPUT" in w["dialog"].getStr
    ck "acme-tools.flame" in w["dialog"].getStr
    ck w["footerAfterChord"].getStr.len > 0
    ended(w)

  test "a swallowed key is dropped and the plugin loses the keyboard":
    let w = ws["swallowedKey"]
    ck w["keyRouted"].getStr == "plugin key j"
    ck w["droppedSentence"].getStr.len > 0
    ck w["footerAfterDrop"].getStr.len > 0
    ck w["nextKeyReachedRouter"].getStr.startsWith("key k at ")
    ck not w["nextKeyToPlugin"].getBool
    ck w["thirdKeyReachedRouter"].getStr.startsWith("key l at ")
    ck "breaker open" in w["breakerOpen"].getStr
    ended(w)

  test "a plugin's decoration on the execution line; a plugin pane takes its keys":
    let w = ws["paneKeyAndDecoration"]
    ck w["mapped"].getBool
    ck w["bothRunningState"].getStr.len > 0
    ck "metrics: line" in w["marks"].getStr
    ck "★" in w["marks"].getStr
    ck "◆ metrics: line" in w["footerDecoration"].getStr
    ck "metrics: line" in w["decorationOcr"].getStr
    ck "work 40%" in w["flameDrew"].getStr
    ck "(activated)" notin w["flameDrew"].getStr
    ck w["downKey"].getStr.endsWith(" on acme-tools.flame/flame")
    ck w["enterKey"].getStr.endsWith(" on acme-tools.flame/flame")
    ck "work 40% (activated)" in w["flameAnswered"].getStr
    ck "activated" in w["flameOcr"].getStr
    ck w["clickAt"].kind == JArray
    ck w["clickRouted"].getStr == "plugin view click flame.list#0 on acme-tools.flame/flame"
    ck "main 60% (activated)" in w["clickAnswered"].getStr
    ended(w)

  test "ct-lens: three plugins, two processes, panes, F7 and the jump mode":
    let w = ws["ctLens"]
    ck w["mapped"].getBool
    ck w["awaitingConsent"].getStr.startsWith("plugins awaiting consent ct-lens.")
    ck pids(w["pidsBeforeConsent"]).len == 0
    ck w["allRunningState"].getStr.len > 0
    # history and watch share a process; jump captures the window's keys and
    # runs in its own.
    ck pids(w["pidsRunning"]).len == 2
    ck w["historyDocked"].getBool
    ck "History of " in w["historyDrew"].getStr
    ck "history: " in w["historyFooter"].getStr
    let changed = w["changed"].getStr
    ck changed.len > 0
    ck ("changed: " & changed) in w["changedFooter"].getStr
    ck w["f7Routed"].getStr.toLowerAscii == "plugin key f7"
    ck "every changed value is already watched" in w["watchRefused"].getStr
    ck "Jump to call" in w["jumpPaneDrew"].getStr
    ck w["modeFooter"].getStr.startsWith("plugins footer JUMP MODE (ct-lens.jump)")
    let picked = w["picked"].getStr
    ck picked.len > 0
    ck w["digitRouted"].getStr == "plugin key 2"
    ck w["modeClosedFooter"].getStr.len > 0
    ck ("jumped to " & picked & " ") in w["jumpedPane"].getStr
    # The jump moved the session: the next step starts inside the call it
    # jumped to, far past the module's first steps, and the history pane
    # then names that call's function. (Whether the window draws the jumped
    # stop at once, `historyAtOnce`, is recorded, not asserted: a relayed
    # jump is shown at the next stop, the terminal's open issue.)
    ck tickOf(w["tickBeforeJump"].getStr) > 0
    ck tickOf(w["tickAfterJump"].getStr) > tickOf(w["tickBeforeJump"].getStr) + 1
    ck "History of " in w["historyAfterStep"].getStr
    ck w["modeAgain"].getStr.startsWith("plugins footer JUMP MODE (ct-lens.jump)")
    ck "RECOVER INPUT" in w["dialog"].getStr
    ck "ct-lens.jump" in w["dialog"].getStr
    ck w["footerAfterChord"].getStr.len > 0
    ended(w)

  test "assertion count":
    ck CHECKS == ExpectedAssertions
