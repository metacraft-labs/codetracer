## test_gpui_plugins_window.nim — INSTALLED PLUGINS RUN IN THE GPUI WINDOW
## (Extensibility-Model.md §11), asserted from the committed record.
##
## Run:
##   nim c -r src/frontend/gpui/tests/test_gpui_plugins_window.nim
##
## `src/tests/visual/gpui-plugins-window.json` is written by
## `ci/test/gpui-plugins-window.sh` (four real `codetracer-gpui` windows on a
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
##     window's router.

import std/[json, os, strutils, unittest]

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const ExpectedAssertions = 48

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

  test "assertion count":
    ck CHECKS == ExpectedAssertions
