## index_startup_state_test.nim
##
## What the index process's own state (`index/config.data`) holds after it
## starts a session, run against a real temporary directory.
##
## `index/startup.init` and `index/traces.loadTrace` used to take
## `dataArg: var ServerData` and work on `var data = dataArg`. `ServerData` is
## an `object`, so on the JS backend that local is a COPY (`nimCopy`): every
## field they wrote landed on the copy, and the handlers that run afterwards
## — the Files pane's operations and lazy loads, tab loads, Find in Files,
## a later mode switch — read a process state that never received it. A
## `ct edit <folder>` session had no opened folder (every Files operation was
## refused "No folder is open") and no save.
##
## The cases:
##
## 1. An edit launch (`ct edit <folder>`), through the real `init`: the
##    process state holds the opened folder, the save `init` loaded (the one
##    it also sent the renderer in `CODETRACER::no-trace`), and the start
##    options' `isInstalled`.
## 2. A trace load, through the real `loadTrace`, of an imported
##    (self-contained) trace: the process state holds its save, and the
##    file-tree roots it sends follow `Filesystem-Pane.md` § "Imported
##    (self-contained) traces" — the payload folder, not the recorded source
##    folder on the live disk.
##
## Not covered here: `init`'s replay branch needs a trace in the trace index
## (`ct trace-metadata`) and a session manager. Run against a real Electron
## replay launch, the process state's `trace` was set during that branch
## anyway, by `traces.prepareForLoadingTrace`, so the copy never cost a
## replay its trace; `loadTrace` (case 2) is the replay path's write that was
## lost.
##
## No fakes but one: the Electron window the index process sends to is an
## object that records what it was sent and, as the renderer does, answers
## `CODETRACER::started` (`startup.onStarted`), which `init` waits for. The
## startup code, `fs` and the directories are real.
##
## Lane: `main-process` — `nim js -d:nodejs -d:ctIndex -d:server`, run under
## node. Writes only under one `mkdtemp` directory, which it removes.

import std/[asyncjs, jsffi, strutils]

import lib/src_relative_require
import ../lib/jslib
import ../[types, lang]
import ../index/config
import ../index/electron_vars
import ../index/startup
import ../index/traces
import ../index/[ipc_utils, server_config, load_admission, tab_answers]

var checks = 0
var failedChecks = 0
var startupPaused: proc()

proc ck(cond: bool; name: string) =
  inc checks
  if cond: echo "  [OK] ", name
  else:
    inc failedChecks
    echo "  [FAILED] ", name

proc exitProcess(code: int) {.importjs: "process.exit(#)".}

proc makeTempDir(): cstring {.importjs: """(function () {
  var os = require('os'), path = require('path'), fs = require('fs');
  return fs.mkdtempSync(path.join(os.tmpdir(), 'ct-startup-state-'));
})()""".}

proc removeDir(dir: cstring) {.importjs:
  "require('fs').rmSync(#, {recursive: true, force: true})".}

proc writeText(path: cstring; text: cstring) {.importjs: """(function (p, t) {
  var path = require('path'), fs = require('fs');
  fs.mkdirSync(path.dirname(p), {recursive: true});
  fs.writeFileSync(p, t);
})(#, #)""".}

proc joinPath(a, b: cstring): cstring {.importjs: "require('path').join(#, #)".}

proc setTimeoutZero(f: proc()) {.importjs: "setTimeout(#, 0)".}

type Sent = ref object
  messages: seq[(string, JsObject)]

proc rendererWindow(sent: Sent): JsObject =
  ## The window the index process sends to. It records every message and,
  ## like the renderer, answers `CODETRACER::started` — on a later task, as a
  ## reply over IPC would arrive.
  let webContents = newJsObject()
  webContents["send"] = proc(channel: cstring; payload: JsObject) =
    sent.messages.add(($channel, payload))
    if $channel == "CODETRACER::started":
      if not startupPaused.isNil:
        startupPaused()
      setTimeoutZero(proc() = discard onStarted(nil, nil))
  result = newJsObject()
  result["webContents"] = webContents

proc payloadOf(sent: Sent; channel: string): JsObject =
  for (c, payload) in sent.messages:
    if c == channel:
      return payload
  nil

proc childNames(node: JsObject): seq[string] =
  if node.isNil or node.isUndefined:
    return @[]
  let children = node[cstring"children"]
  for i in 0 ..< children[cstring"length"].to(int):
    result.add $children[i][cstring"text"].to(cstring)

const ExpectedChecks = 15

proc editLaunch(dir: cstring) {.async.} =
  # 1. `ct edit <folder>`.
  let folder = joinPath(dir, cstring"proj")
  writeText(joinPath(folder, cstring"src/main.nr"), cstring"fn main() {}")
  let sent = Sent()
  mainWindow = rendererWindow(sent)
  # Reset everything the checks below read, so each can only pass by `init`'s
  # own write: case 2 runs first and leaves its trace's save (id -1, the same
  # id this launch's save has) on the process state.
  data.save = Save()
  data.workspaceFolder = cstring(nil)
  data.startOptions.edit = true
  data.startOptions.welcomeScreen = false
  data.startOptions.folder = folder
  data.startOptions.name = cstring""
  data.startOptions.isInstalled = false
  startupPaused = proc() =
    # The REAL registered load-recent-trace callback, while REAL init is
    # suspended at its renderer handshake. Admission must refuse before the
    # actual handler can touch metadata, trace or replay state.
    var registered: JsObject = nil
    for entry in ipc.registry.handlers:
      if entry.event == cstring"CODETRACER::load-recent-trace":
        registered = entry.handler
    doAssert not registered.isNil, "configureIpcMain must register the production load handler"
    let call = jsAsFunction[proc(request: JsObject)](registered)
    call(js{tab: 22, traceId: cstring"not-a-recording"})
    let refusal = sent.payloadOf("CODETRACER::trace-load-error")
    ck not refusal.isNil, "startup refuses the production second load"
    ck not refusal.isNil and refusal["tab"].to(int) == 22,
      "startup refusal answers the second load's asking tab"
    ck not refusal.isNil and not refusal["preserveLoading"].to(bool),
      "startup refusal lets the other tab leave its loading overlay"
    ck forLoadTab(js{})["tab"].to(int) == 0,
      "the refused request leaves startup addressed to its first tab"
  await init(Config(), js{}, JsAssoc[cstring, Helper]{})
  startupPaused = nil
  let released = beginLoad(js{tab: 23})
  ck released, "real startup releases admission after initialization"
  if released: finishLoad()

  let noTrace = sent.payloadOf("CODETRACER::no-trace")
  ck not noTrace.isNil, "init took the edit branch and sent no-trace"
  ck not noTrace.isNil and noTrace["tab"].to(int) == 0,
    "startup's delayed no-trace message still names its first tab"
  ck not data.workspaceFolder.isNil and $data.workspaceFolder == $folder,
    "the process state holds the opened folder (got '" &
      (if data.workspaceFolder.isNil: "nil" else: $data.workspaceFolder) & "')"
  let sentSaveId =
    if noTrace.isNil: -2 else: noTrace[cstring"save"][cstring"id"].to(int)
  ck sentSaveId == -1 and data.save.id == sentSaveId,
    "the process state holds the save init loaded and sent (state id " &
      $data.save.id & ", sent id " & $sentSaveId & ")"
  ck data.startOptions.isInstalled,
    "the process state holds the start options init completed (isInstalled)"

proc importedTraceLoad(dir: cstring) {.async.} =
  # 2. An imported trace: its sources are in `files/src`; its recorded source
  #    folder is a live checkout with other files in it.
  let recorded = joinPath(dir, cstring"recorded-checkout")
  writeText(joinPath(recorded, cstring"src/main.nr"), cstring"live")
  writeText(joinPath(recorded, cstring"unrelated/notes.txt"), cstring"x")
  let traceFolder = joinPath(dir, cstring"trace")
  writeText(joinPath(traceFolder, cstring"files/src/main.nr"), cstring"payload")
  let trace = Trace(
    program: cstring"main",
    outputFolder: traceFolder,
    sourceFolders: @[recorded],
    imported: true,
    lang: LangNoir)
  data.save = Save()
  data.workspaceFolder = cstring(nil)
  let sent = Sent()
  let window = rendererWindow(sent)
  await loadTrace(window, trace, Config(), JsAssoc[cstring, Helper]{})

  let traceLoaded = sent.payloadOf("CODETRACER::trace-loaded")
  ck not traceLoaded.isNil, "loadTrace sent trace-loaded"
  ck not traceLoaded.isNil and traceLoaded["tab"].to(int) == 0,
    "loadTrace's delayed message retains its admitted startup tab"
  let sentSaveId =
    if traceLoaded.isNil: -2 else: traceLoaded[cstring"save"][cstring"id"].to(int)
  ck sentSaveId == -1 and data.save.id == sentSaveId,
    "the process state holds the trace's save (state id " & $data.save.id &
      ", sent id " & $sentSaveId & ")"
  # The tree is sent without being awaited; give it its turn.
  var tree: JsObject = nil
  for _ in 0 ..< 200:
    tree = sent.payloadOf("CODETRACER::filesystem-loaded")
    if not tree.isNil:
      break
    await newPromise(proc(resolve: proc()) = setTimeoutZero(resolve))
  let folders = if tree.isNil: nil else: tree[cstring"folders"]
  let roots = childNames(folders)
  ck roots == @["src"],
    "the roots are the payload folder, not the recorded checkout (got " &
      $roots & ")"
  let srcRoot =
    if folders.isNil or folders.isUndefined or roots.len == 0: nil
    else: folders[cstring"children"][0]
  ck not srcRoot.isNil and
      "unrelated" notin childNames(srcRoot) and
      childNames(srcRoot) == @["main.nr"],
    "the payload root lists the payload's files only"

proc main() {.async.} =
  let dir = makeTempDir()
  try:
    configureIpcMain()
    # The same initial owner startup establishes, before the direct loadTrace
    # arm below (which deliberately calls the pipeline without an IPC handler).
    startLoadFor(js{tab: 0})
    await importedTraceLoad(dir)
    await editLaunch(dir)
  except:
    inc failedChecks
    echo "  [FAILED] the suite raised: ", getCurrentExceptionMsg()
  removeDir(dir)
  echo "CHECKS: ", checks
  if checks != ExpectedChecks:
    inc failedChecks
    echo "  [FAILED] the suite ran ", checks, " of ", ExpectedChecks, " cases"
  echo checks, " check(s): ", checks - failedChecks, " OK, ", failedChecks, " FAILED"
  exitProcess(if failedChecks == 0: 0 else: 1)

discard main()
