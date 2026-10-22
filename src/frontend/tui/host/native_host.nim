## LAYER RULE — `src/frontend/tui/host/` is the NATIVE HOST half of the TUI,
## and it is the ONLY part of the TUI outside the Embed SDK facade.
##
## A module here may import everything `src/frontend/tui/app/` may, and
## additionally `backend/stdio_backend`, `viewmodel/headless_session`,
## `std/osproc`, `std/posix` and `nim_pty`. That is not a relaxation of the
## boundary; it is where the boundary is drawn.
##
## The reason is in CodeTracer-Embed-SDK.md §3.2 and is worth restating,
## because it is the argument that put the TUI in this repository at all:
## `codetracer_embed` deliberately withholds `backend/stdio_backend` and
## `viewmodel/headless_session` — the only modules that spawn a local
## `replay-server` for a `.ct` folder on disk. A front-end that lived outside
## this repo could therefore not open a local trace through the sanctioned
## surface at all. So the capability is not smuggled in; it is isolated in one
## named directory, on the other side of a line that
## `ci/test/sdk-facade-boundary.sh` records as an explicit exemption and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` enforces from the
## `app/` side.
##
## This directory carries NO `.sdk-consumer` marker, and that absence is
## load-bearing: adding one would make every module here a declared consumer
## and the facade guard would immediately, correctly, fail.
##
## host/native_host.nim — the process-owning side of the terminal front-end.
##
## ## What this is
##
## The counterpart of `viewmodel/headless_session.nim` for a terminal rather
## than for a test suite: it resolves a trace folder against the real
## filesystem, finds `replay-server` the way every other suite in this repo
## finds it, spawns it, and hands the resulting `BackendService` to
## `app/tui_app.nim`, which cannot build one.
##
## ## What it is not
##
## It is not the application. It holds no views, no layout and no ViewModel
## state, and nothing here is reactive. `TuiApp` is handed a backend and is
## otherwise unaware that a process exists — which is what lets the whole
## `app/` layer be exercised at Tier 1 with no child process at all.

when defined(js):
  {.error: "src/frontend/tui/host is native-only: it spawns replay-server.".}

import std/[algorithm, json, os, osproc, posix, sets, streams, strutils]

import isonim/core/signals   # `Signal.val`, for `PaneLoad`'s reads of the store
import isonim/core/async_compat   # `drainPlatformCallbacks`: applies the answers

import headless_session
import sdk/stop_loader   # the SDK's per-stop loads, which `loadStopPanes` runs
import store/types as store_types   # `FilesystemEntryNode`
from store/replay_data_store import applySymbolsResponse   # the omnibar's symbols
import viewmodels/filesystem_vm   # the replay file tree's `setRoot`
from viewmodels/calltrace_vm import selectEntry, currentCallInSectionOf   # PLAT-49 part B
from viewmodels/debug_controls_vm import invokeToolbarAction   # M76: the native Stop
from viewmodels/omnibar_vm import OmnibarEntry, OmnibarMode   # `recordingsBeside`
import ../../../common/trace_source_paths   # the shared source-folder rule
import ../../../common/replay_server_path   # the one replay-server search order
import ../../viewmodel/host/find_in_files   # PLAT-57: the one search runner
from viewmodels/search_results_vm import SearchResultsVM, acceptBatch
import ../../../ct/trace/trace_kind   # the shared test-oracle refusal
import ../../../ct/trace/recorder_output   # `ct record-test`'s recording id
export headless_session

type
  TuiHostError* = object of CatchableError
    ## A host-side failure a user can act on: no such trace folder, no
    ## `replay-server`. Every message names what to do about it, because the
    ## alternative — a stack trace out of the DAP handshake — diagnoses the
    ## symptom rather than the cause.

proc raiseHost(msg: string) {.noreturn.} =
  raise newException(TuiHostError, msg)

proc repoRoot(): string =
  ## The checkout this binary was built from, found by walking up from this
  ## source file until a marker appears.
  ##
  ## `currentSourcePath` rather than `getAppDir`: the test lane's binaries live
  ## in a nimcache directory that is nowhere near the checkout, and resolving
  ## `replay-server` relative to the executable would find nothing there. The
  ## markers are the same pair the ViewModel suites walk for.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir:
      break
    dir = parent
  raiseHost("could not locate the codetracer checkout from " &
            currentSourcePath())

proc findReplayServer*(): string =
  ## Where `replay-server` is, or "" when it has not been built.
  ##
  ## The search order is `src/common/replay_server_path`'s, and deliberately
  ## not a list of this module's own: `REPLAY_SERVER_BIN`, the output root the
  ## build published (`CT_BUILD_OUT_ROOT`, `CODETRACER_BUILD_DIR`), the Repro
  ## and tup trees, and cargo's own directories last. Every headless suite
  ## resolves through the same module, because a front-end that looked
  ## somewhere else would find a different binary than the tests do — and
  ## that is exactly what happened while this list was private: it did not
  ## know the Repro output root, so a `repro`-built checkout ran a stale cargo
  ## engine and the window hung on a DAP read with no output at all
  ## (codetracer-pm
  ## `issues/2026-09-29-replay-server-discovery-misses-the-repro-build-output-root.md`).
  ##
  ## Returns "" rather than raising: a caller that only wants `--version` must
  ## not need a backend, and CTUI-1's fixture provider needs to be able to
  ## report the absence as a named, counted prerequisite rather than catch an
  ## exception.
  locateReplayServer()

proc traceFolderProblem*(path: string): string
  ## Forward-declared; defined below.

proc findCtBinary*(): string =
  ## PLAT-51: where `ct` is, for a welcome tab's "Record new trace" — `CT_BIN`,
  ## then beside `replay-server` (an installed suite ships them together), then
  ## this checkout's debug build, then `PATH`. "" when there is none.
  let envBin = getEnv("CT_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  let rs = findReplayServer()
  if rs.len > 0 and fileExists(rs.parentDir / "ct"):
    return rs.parentDir / "ct"
  let candidate = repoRoot() / "src" / "build-debug" / "bin" / "ct"
  if fileExists(candidate):
    return candidate
  findExe("ct")

type
  NativeRecordJob* = ref object
    ## PLAT-51 deliverable 8: a welcome tab's `ct record`, running. The host
    ## polls it (`pollRecordJob`) from the loop that reads its input, so the
    ## screen keeps answering while the program is recorded.
    process*: Process
    outputFolder*: string
    logPath*: string
    program*: string
    done*: bool
    ok*: bool
    message*: string
    testRun*: bool
      ## A `ct record-test` (`startRecordTestJob`): it records into the
      ## trace store, and says where by the recording id it prints.
    recordingId*: string
      ## That id, once the run finished.

proc startRecordJob*(program: string; args: seq[string];
                     outputFolder: string): NativeRecordJob =
  ## `ct record -o <outputFolder> <program> -- <args>`, in the background,
  ## its output to a log beside the recording. Refused (done, not ok, with
  ## why) when there is no `ct` or the program is not there.
  result = NativeRecordJob(outputFolder: outputFolder, program: program)
  let ct = findCtBinary()
  if ct.len == 0:
    result.done = true
    result.message = "no ct found to record with; set CT_BIN"
    return
  let target = absolutePath(program.expandTilde())
  if not fileExists(target) and not dirExists(target):
    result.done = true
    result.message = "no such program: " & target
    return
  try:
    createDir(outputFolder.parentDir)
  except CatchableError:
    discard
  result.logPath = outputFolder & ".log"
  var argv = @["record", "-o", outputFolder, target]
  if args.len > 0:
    argv.add "--"
    argv.add args
  try:
    result.process = startProcess(ct, workingDir = target.parentDir,
                                  args = argv,
                                  options = {poStdErrToStdOut})
  except CatchableError as e:
    result.done = true
    result.message = "could not start ct record: " & e.msg
    result.process = nil

proc startRecordTestJob*(path: string): NativeRecordJob =
  ## THE DESKTOP'S RUN-TESTS (`ui/debug.nim`'s `run-tests` action, answered
  ## by `index/traces.onRunTest`): `ct record-test "" <path> 0 0
  ## --with-diff=HEAD --store-trace-folder-for-pid=<pid>` in the background —
  ## the tests of the file the debugger is in, recorded. Its log is a
  ## temporary file; `recordingId` names the recording when it finishes.
  result = NativeRecordJob(program: path, testRun: true)
  let ct = findCtBinary()
  if ct.len == 0:
    result.done = true
    result.message = "no ct found to run the tests with; set CT_BIN"
    return
  result.logPath = getTempDir() / ("codetracer-record-test-" &
                                   $getCurrentProcessId() & ".log")
  try:
    writeFile(result.logPath, "")
    result.process = startProcess(ct, workingDir = path.parentDir,
      args = @["record-test", "", path, "0", "0", "--with-diff=HEAD",
               "--store-trace-folder-for-pid=" & $getCurrentProcessId()],
      options = {poStdErrToStdOut})
  except CatchableError as e:
    result.done = true
    result.message = "could not start ct record-test: " & e.msg
    result.process = nil

proc recordingFolderOf*(recordingId: string): string =
  ## Where the trace store keeps a recording (`ct trace-metadata --id`, as
  ## the desktop's `findTraceWithCodetracer` asks), or "".
  let ct = findCtBinary()
  if ct.len == 0 or recordingId.len == 0:
    return ""
  try:
    let (output, code) = execCmdEx(quoteShellCommand(
      [ct, "trace-metadata", "--id=" & recordingId]))
    if code != 0:
      return ""
    let start = output.find('{')
    if start < 0:
      return ""
    result = parseJson(output[start .. ^1]){"outputFolder"}.getStr("")
  except CatchableError:
    result = ""

proc pollRecordJob*(job: NativeRecordJob): bool =
  ## Whether the job FINISHED on this poll (once): `ok` and `message` say
  ## how. The recorder's output is drained so a chatty program cannot fill
  ## the pipe and stall it.
  if job.isNil or job.done:
    return false
  if job.process.isNil:
    job.done = true
    return true
  var chunk = ""
  try:
    let outp = job.process.outputStream
    while job.process.hasData:
      var line = ""
      if not outp.readLine(line):
        break
      chunk.add line & "\n"
  except CatchableError:
    discard
  if chunk.len > 0:
    try:
      let f = open(job.logPath, fmAppend)
      f.write(chunk)
      f.close()
    except CatchableError:
      discard
  let code = job.process.peekExitCode()
  if code == -1:
    return false
  job.done = true
  if job.testRun:
    var log = ""
    try: log = readFile(job.logPath)
    except CatchableError: discard
    job.recordingId = recordingIdFromOutput(log)
    job.ok = code == 0 and job.recordingId.len > 0
    if code == 0 and job.recordingId.len == 0:
      job.message = "ct record-test finished without reporting a " &
                    "recording id, so there is nothing to replay"
  else:
    job.ok = code == 0 and traceFolderProblem(job.outputFolder).len == 0
  job.process.close()
  if not job.ok and job.message.len == 0:
    var last = ""
    try:
      for l in readFile(job.logPath).splitLines():
        if l.strip.len > 0:
          last = l.strip
    except CatchableError:
      discard
    job.message = (if job.testRun: "running the tests of " else: "recording ") &
                  job.program & " failed (exit " & $code &
                  ")" & (if last.len > 0: ": " & last else: "")
  true

proc replayServerRemedy*(): string =
  ## What to tell a user whose `replay-server` is missing. One string, so the
  ## host and every future caller name the same command.
  "no replay-server found; set REPLAY_SERVER_BIN, or build one with " &
  "`cd src/db-backend && cargo build`"

proc resolveTraceFolder*(path: string): string =
  ## Turn a command-line trace path into an absolute directory, or fail saying
  ## why.
  ##
  ## `app/cli.nim` returns the path exactly as it was typed and does no
  ## filesystem I/O — resolving it against the process's working directory is
  ## this side of the line, and so is deciding that it does not exist.
  if path.len == 0:
    raiseHost("no trace folder given")
  let absolute = absolutePath(path.expandTilde())
  if not dirExists(absolute):
    if fileExists(absolute):
      raiseHost("'" & path & "' is a file; a CodeTracer trace is a folder")
    raiseHost("no such trace folder: " & absolute)
  absolute

proc traceFolderProblem*(path: string): string =
  ## "" when `path` holds something `replay-server` can open, and what is wrong
  ## with it otherwise.
  ##
  ## ## Why this exists, measured rather than supposed
  ##
  ## CTUI-11 pointed the shipped binary at a directory that is not a recording
  ## (the checkout root) and it HUNG: the driver had already claimed the
  ## terminal and painted "opening …", `replay-server` refused the folder and
  ## exited 2 without writing one byte of DAP, and the handshake's blocking read
  ## never returned. The user was left with a claimed alternate screen, no
  ## input loop yet running, and no key that could end it — the worst shape a
  ## failure can take in a full-screen application.
  ##
  ## So the shape is checked BEFORE anything is spawned and before the terminal
  ## is claimed. It is a cheap `stat`, and it turns the overwhelmingly common
  ## mistake — a mistyped or wrong path — into a named refusal on the ordinary
  ## screen.
  ##
  ## ## What it does NOT claim
  ##
  ## That the recording is INTACT. A folder with a truncated `trace.bin` passes
  ## here and fails in the engine.
  ##
  ## CTUI-11 recorded that as an OPEN WEDGE — such a folder hung the handshake
  ## behind a claimed alternate screen — and CTUI-14 closed it, in
  ## `backend/stdio_backend.DapReadBound` rather than here. The division is the
  ## point and is worth stating: THIS function refuses a folder that is not a
  ## recording, cheaply and before anything is spawned; the BOUND survives a
  ## folder that is a recording's shape and is not a recording, which no `stat`
  ## can tell apart from one that is. `openLocalTrace` below installs it.
  ##
  ## ## The three shapes
  ##
  ## The same three `src/frontend/tui/tests/fixtures/fixture_provider.
  ## isUsableTraceDir` recognises, which are in turn the ones
  ## `src/tests/gui/tests/noir-space-ship/noir_space_ship_test.nim` has always
  ## recognised. Spelled again here rather than shared, because that one is a
  ## TEST helper and a shipped binary must not depend on the test tree; the two
  ## are cross-referenced so a fourth shape is added to both.
  if not dirExists(path):
    return "no such folder"
  if fileExists(path / "trace.bin"):
    return ""
  if dirExists(path / "rr"):
    return ""
  for kind, entry in walkDir(path):
    if kind == pcFile and entry.endsWith(".ct"):
      return ""
  # A `trace.json` event stream is test-oracle output, not a recording; say
  # so in the words every other CodeTracer entry point uses.
  if fileExists(path / TestOracleTraceFileName):
    return testOracleRefusal(path / TestOracleTraceFileName)
  "it holds no `trace.bin`, no `rr/` and no `.ct` container, so it is not a " &
  "CodeTracer recording"

const
  DefaultHandshakeMs* = 30_000
    ## How long the TUI waits for ONE message from `replay-server` before it
    ## gives the terminal back and says so.
    ##
    ## THIRTY SECONDS IS DELIBERATELY GENEROUS, and it can be because it is not
    ## the only way out: the same bound watches the keyboard, so an attended
    ## session never waits this out — `Ctrl+c` ends it at once. What the clock
    ## is for is the UNATTENDED session, where there is nobody to press
    ## anything: a `ct tui` in a pane nobody is watching, or a CI job. A budget
    ## tight enough to be felt would instead have to be defended against every
    ## slow recording on every loaded machine, and losing that argument means
    ## refusing to open a trace that was merely slow.
    ##
    ## PER MESSAGE, not per session. See `DapReadBound.timeoutMs`.
    ##
    ## The GPUI window uses the same default while it opens a recording
    ## (`gpui_host.openGpuiTrace`): it has no window to take a keystroke yet,
    ## so for it the clock is the ONLY way out, and the argument above for a
    ## generous budget applies with more force, not less.
  HandshakeEnvVar* = "CODETRACER_TUI_HANDSHAKE_MS"
    ## Overrides `DefaultHandshakeMs`, in milliseconds.
    ##
    ## NOT A COMMAND-LINE FLAG. §6.2 is a published surface and this is a knob
    ## for a test that needs the clock to fire in seconds rather than in
    ## half a minute — `tests/real_terminal/test_real_pty_lifecycle.nim` is the
    ## reason it exists. `app/cli.parseTuiCommand` therefore never sees it and
    ## `TuiHelpText` never mentions it.

proc handshakeBudgetMs*(envVar = HandshakeEnvVar): int =
  ## The per-message budget this process will use, from the environment
  ## variable `envVar` or from `DefaultHandshakeMs`.
  ##
  ## A value that does not parse, or that is not positive, falls back to the
  ## default rather than disabling the bound: "the clock is off" is exactly the
  ## state this milestone exists to remove, and it must not be reachable by
  ## mistyping an environment variable.
  ##
  ## `envVar` is a parameter because each native front-end has its own knob —
  ## the terminal reads `HandshakeEnvVar`, the GPUI window
  ## `gpui_host.GpuiHandshakeEnvVar` — and both must parse it by THIS rule: a
  ## second copy of the fallback is a second place where a typo could switch
  ## the clock off.
  let raw = getEnv(envVar, "")
  if raw.len == 0:
    return DefaultHandshakeMs
  try:
    let parsed = parseInt(raw.strip())
    if parsed > 0: parsed else: DefaultHandshakeMs
  except ValueError:
    DefaultHandshakeMs

const
  MaxListedRecordings* = 64
    ## How many recordings `recordingsBeside` lists: a folder of thousands
    ## must not stall the omnibar's opening.

proc recordingsBeside*(traceFolder: string): seq[OmnibarEntry] =
  ## PLAT-49 part B: THE RECORDINGS A NEW SESSION TAB CAN OPEN without the
  ## user typing a path — every folder beside `traceFolder` (its own
  ## included) that `traceFolderProblem` accepts, as `omRecording` omnibar
  ## entries (its name, its parent, its absolute path), in name order. The
  ## native front-ends' answer to the desktop's welcome screen, which lists
  ## the recordings its index knows; a typed path is accepted too
  ## (`omnibar_vm.rankOmnibar`).
  if traceFolder.len == 0:
    return
  let parent = parentDir(absolutePath(traceFolder.expandTilde()))
  if not dirExists(parent):
    return
  var found: seq[string] = @[]
  for kind, path in walkDir(parent):
    if kind notin {pcDir, pcLinkToDir}:
      continue
    if traceFolderProblem(path).len == 0:
      found.add path
    if found.len >= MaxListedRecordings:
      break
  found.sort()
  for path in found:
    result.add OmnibarEntry(kind: OmnibarMode.omRecording,
                            label: extractFilename(path),
                            detail: parent, target: path)

# ---------------------------------------------------------------------------
# M76 (codetracer#843): THE NATIVE STOP
# ---------------------------------------------------------------------------
#
# Debugger-Controls.md § "Ending a session from inside it", requirement 2:
# "The replay backend for that session is terminated." `DebugControlsVM`'s
# `invokeToolbarAction` is "the one route a button, a key chord and a menu
# item take, on every front-end", and its `stop` entry is a host's to supply
# (`defaultDebugCommands` cannot end a process). Until M76 no native host
# supplied it, so `invokeToolbarAction("stop")` was a silent no-op on the
# terminal and GPUI. `openLocalTrace` — the one function both native front
# ends open a recording with — now installs it, so no native session has a
# nil Stop, and both front ends' Stop (button, menu, chord) goes through it
# (`stopThroughControls`).

type
  NativeStopOutcome* = object
    ## What the native Stop did to the session's replay — a VALUE, so a test
    ## and a host read the same fact.
    ended*: bool
      ## The replay was running and has been ended by this call.
    pid*: int
      ## The `replay-server` that was ended (or that had already gone), -1
      ## when the session had none.
    message*: string

proc endDebugSession*(s: HeadlessDebugSession): NativeStopOutcome =
  ## End the session's replay: the SDK session disposed and the
  ## `replay-server` child terminated, its handles released
  ## (`HeadlessDebugSession.close`). Idempotent: a session already ended
  ## answers `ended = false` and says so. The workspace's return to Edit mode
  ## and the tab that survives as an edit tab (requirements 1 and 3) are the
  ## front end's.
  result.pid = s.replayPid()
  if not s.replayRunning():
    result.message = "the debugging session had already ended"
    s.close()
    return
  s.close()
  result.ended = true
  result.message = "stopped the debugging session"

proc installNativeStop*(s: HeadlessDebugSession;
                        afterStop: proc() {.closure.} = nil) =
  ## Give the session's `DebugControlsVM` its host Stop: `commands.stop` ends
  ## this session's replay (`endDebugSession`), then runs `afterStop` — the
  ## front end's own half (its mode, its tab, forgetting the session), so a
  ## caller that reaches the ViewModel's Stop from anywhere leaves the front
  ## end consistent, not holding a dead engine. Installed again by a front end
  ## that has its half to add (`tui_session.header`).
  let vm = s.session.debugControlsVM
  if vm.isNil:
    return
  let sess = s
  vm.commands.stop = proc() =
    discard sess.endDebugSession()
    if not afterStop.isNil:
      afterStop()

proc stopThroughControls*(s: HeadlessDebugSession): NativeStopOutcome =
  ## A native front end's Stop, through THE route: the session's
  ## `DebugControlsVM.invokeToolbarAction("stop")`, which runs the host Stop
  ## `installNativeStop` gave it. Answers what happened to the replay.
  result.pid = s.replayPid()
  let wasRunning = s.replayRunning()
  let vm = s.session.debugControlsVM
  if vm.isNil or vm.commands.stop.isNil:
    # A session built without `openLocalTrace` (a test harness): end it the
    # same way, directly, rather than leaving its engine running.
    result = s.endDebugSession()
    return
  if not wasRunning:
    result.message = "the debugging session had already ended"
    return
  vm.invokeToolbarAction("stop")
  result.ended = wasRunning and not s.replayRunning()
  result.message =
    if result.ended: "stopped the debugging session"
    else: "the replay did not end"

proc openLocalTrace*(traceFolder: string;
                     bound: DapReadBound = DapReadBound(interruptFd: -1)
                    ): HeadlessDebugSession =
  ## Spawn `replay-server` on `traceFolder` and complete the DAP handshake.
  ##
  ## The one operation in the whole TUI that the Embed SDK facade cannot
  ## express, and therefore the one that decided this directory exists.
  ##
  ## `bound` is CTUI-14's clock and escape hatch. It defaults to the zero value
  ## so a caller that has no terminal to lose — a fixture builder, a probe —
  ## keeps the reads it always had; `main.nim` builds a real one.
  let resolved = resolveTraceFolder(traceFolder)
  let problem = traceFolderProblem(resolved)
  if problem.len > 0:
    raiseHost(resolved & ": " & problem)
  let bin = findReplayServer()
  if bin.len == 0:
    raiseHost(replayServerRemedy())
  result = newHeadlessDebugSession(resolved, bin, handshake = bound)
  result.installNativeStop()

# ---------------------------------------------------------------------------
# The panes' producers — ONE set, called by both native front-ends
# ---------------------------------------------------------------------------
#
# PLAT-40. The terminal and the GPUI window open a recording through the
# function above and then each decided on its own what to ask the engine for:
# the terminal asked for the event log, the calltrace and the locals; GPUI
# asked for the locals alone, so its call-trace pane drew "no call trace has
# been loaded" on every recording — the campaign's signature shape, *the
# mechanism works and nothing feeds it*, in the one place two front-ends could
# disagree about it. So the asking lives here, once, and both front-ends call
# it: a pane cannot be fed on one front-end and starved on the other.
#
# TOTAL: each request that the engine declines is recorded as not loaded
# rather than raised, because a front-end that let the refusal escape would
# drop a window or a terminal over a pane that would merely have been empty —
# and the answer SAYS which were loaded, so a caller (and a suite) can tell
# "empty because nothing asked" from "empty because the engine declined".

const
  RecordingCalltraceLevels* = 400
    ## The call STACK's depth cap — the frames `stackTrace` is asked for when
    ## the current call is selected (`selectCurrentCall`) and by the stop
    ## loader's call-stack fallback. A bound on one stack, not a page of a
    ## windowed list.
  RecordingCalltraceDepth* = 200
    ## The call-trace depth a native host pages its own call trace at, until
    ## its pane reports a viewport (Viewport-Driven-Loading V3).

type
  PaneLoad* = object
    ## Which producers ran AND loaded something the store now holds.
    events*: bool
    calltrace*: bool
    locals*: bool
    files*: bool
      ## PLAT-41: the replay file tree holds the recording's source folders.

proc listedEntry(dir, relative: string): FilesystemEntryNode =
  ## One folder of the trace's `files/` store, recursively: folders first,
  ## then files, each group sorted — a stable order a reader can scan.
  let name = relative[relative.rfind('/') + 1 .. ^1]
  result = FilesystemEntryNode(text: name, path: "/" & relative,
                               isFolder: true, isExpanded: true)
  var folders, files: seq[string] = @[]
  for kind, path in walkDir(dir):
    let leaf = path.extractFilename
    case kind
    of pcDir, pcLinkToDir: folders.add leaf
    of pcFile, pcLinkToFile: files.add leaf
  folders.sort()
  files.sort()
  for f in folders:
    result.children.add listedEntry(dir / f, relative & "/" & f)
  for f in files:
    result.children.add FilesystemEntryNode(text: f,
                                            path: "/" & relative & "/" & f)

proc storedSourcePaths(store: string): seq[string] =
  ## Every file of the trace's `files/` store, as a path relative to it, in a
  ## stable order — the desktop's own fallback when a trace folder carries no
  ## `paths.json` (`index/files.loadFilenames`: the `files/` payload, read
  ## relative to its root).
  if not dirExists(store):
    return
  for path in walkDirRec(store, relative = true):
    result.add path.replace('\\', '/')
  result.sort()

proc outermostRoots(roots: seq[string]): seq[string] =
  ## The roots no OTHER root contains. `listedEntry` lists a folder
  ## recursively, so a root inside another one (a package's `pkg/` beside
  ## its parent's modules) would be drawn twice — once as its own root and
  ## once inside its parent's. Order kept.
  for r in roots:
    var inside = false
    for o in roots:
      if o != r and r.startsWith(o & "/"):
        inside = true
        break
    if not inside and r notin result:
      result.add r

proc recordedSourcePaths(traceFolder: string): seq[string] =
  ## The recording's source paths: its `paths.json`, else its `files/`
  ## store's own listing (the desktop's `loadFilenames` fallback).
  let pathsFile = traceFolder / "paths.json"
  if fileExists(pathsFile):
    try:
      for p in parseJson(readFile(pathsFile)): result.add p.getStr("")
    except CatchableError:
      result = @[]
  if result.len == 0:
    result = storedSourcePaths(traceFolder / "files")

proc recordingFileTree*(traceFolder: string): FilesystemEntryNode =
  ## **The replay session's file tree**: the recording's own source folders,
  ## derived from its `paths.json` by the rule the desktop's Files pane uses
  ## (`trace_source_paths.sourceFolderRootsOf`), each listed from the trace's
  ## `files/` store. An empty tree when the recording lists no sources or
  ## carries no store — the pane then reports rather than guessing at a disk.
  ##
  ## A trace folder need not HAVE a `paths.json`: that sidecar is written
  ## when a container is materialised or imported, and a folder straight out
  ## of `ct record` holds the container and its `files/` store only. Then the
  ## store itself is the list of recorded sources — the desktop's
  ## `loadFilenames` fallback — so a recording whose sources span several
  ## folders (a runner in one place, the package it imports in another)
  ## lists every one of them instead of an empty tree.
  result = FilesystemEntryNode(text: "source folders", isFolder: true,
                               isExpanded: true)
  let store = traceFolder / "files"
  let recorded = recordedSourcePaths(traceFolder)
  for root in outermostRoots(sourceFolderRootsOf(recorded)):
    let dir = store / root
    if dirExists(dir):
      result.children.add listedEntry(dir, root)
    elif fileExists(dir):
      result.children.add FilesystemEntryNode(text: root.extractFilename,
                                              path: "/" & root)


# ---------------------------------------------------------------------------
# PLAT-57: Find in Files on the native front-ends
# ---------------------------------------------------------------------------

proc recordingSearchScope*(traceFolder: string): FindInFilesScope =
  ## What Find in Files reads for this recording — the runner's
  ## `findInFilesScope`, the desktop's rule: the recording's `files/` store
  ## (every recording the native front-ends open is read from it), else its
  ## source folders.
  findInFilesScope(traceFolder / "files", preferStore = true,
                   sourceFolderRootsOf(recordedSourcePaths(traceFolder)))

var nativeFindInFiles* = newFindInFilesService()
  ## The process's one runner service: a front-end runs one search at a
  ## time, and a new one cancels the one in flight. The host's loop pumps it.

proc wireFindInFiles*(vm: SearchResultsVM; scope: proc(): FindInFilesScope) =
  ## Hand `vm`'s searches to the shared runner: each runs over `scope()` and
  ## streams its batches into `vm`, which drops any that are not its latest.
  if vm.isNil:
    return
  vm.onSearch = proc(runId: int; query: string; options: TextMatchOptions) =
    discard nativeFindInFiles.search(runId, query, options, scope(),
      proc(b: FindInFilesBatch) =
        discard vm.acceptBatch(b.runId, b.rows, b.done, b.note))

proc expandAllFolders*(vm: FilesystemVM) =
  ## PLAT-50: mark every folder of `vm`'s tree expanded.
  if vm.isNil:
    return
  var paths = initHashSet[string]()
  proc walk(n: FilesystemEntryNode) =
    if n.isFolder:
      paths.incl n.path
    for c in n.children:
      walk(c)
  walk(vm.rootEntry.val)
  vm.setExpandedPaths(paths)

proc loadRecordingPanes*(s: HeadlessDebugSession;
                         raiseOnStall = false): PaneLoad =
  ## The per-RECORDING facts, asked once at open: the event log's size and
  ## the recording's extent, whether there is a call trace, and the
  ## recording's functions (the omnibar's symbols). The ROWS are not loaded
  ## here: each pane asks for the window it shows when it is drawn
  ## (Viewport-Driven-Loading V2). This returns what arrived.
  ##
  ## ONE ROW IS ENOUGH TO LEARN THE EXTENT: every event row carries the
  ## recording's `maxRRTicks` (CTUI-8: the timeline's bounds come from it),
  ## and `ct/event-load` answers the whole log's `total` with any window. A
  ## one-row call-trace section likewise answers `totalCallsCount`. These
  ## replaced reading 4096 events and a 400 x 200 call trace at open.
  ##
  ## `raiseOnStall`: A STALL IS NOT A DECLINE. A request the engine answers
  ## with a refusal is recorded as not loaded, as this section's header says.
  ## With `raiseOnStall`, an engine that answers NOTHING for a whole read
  ## budget (`DapStalledError`) is raised instead, because swallowing it makes
  ## the next request wait out the budget again — one budget per request
  ## before a run that will never get an answer says so — and reports a
  ## silent engine as a recording with empty panes. The GPUI front-end passes
  ## it, and reports the stall by name (`gpui/main.nim`). The terminal's call
  ## sites (`tui_session.learnExtent`) keep the default, because they run
  ## after and outside the `try` that reports a stall at their open: raised
  ## there, a stall would escape as an unhandled exception. On those paths a
  ## silent engine still costs one budget per request here.
  let store = s.session.store
  try:
    discard s.requestAndLoadEventLog(start = 0, count = 1)
    result.events = store.eventLog.rows.val.len > 0
  except DapStalledError:
    if raiseOnStall: raise
  except CatchableError:
    result.events = false
  try:
    s.requestAndLoadCalltrace(height = 1, depth = RecordingCalltraceDepth)
    result.calltrace = store.calltrace.totalCallsCount.val > 0'u64
  except DapStalledError:
    if raiseOnStall: raise
  except CatchableError:
    result.calltrace = false
  try:
    store.applySymbolsResponse(s.sendRawDapRequest("ct/load-symbols"))
    discard s.drainEvents()
  except DapStalledError:
    if raiseOnStall: raise
  except CatchableError:
    discard
  # PLAT-41: the recording's own source tree, read off the trace folder — a
  # host concern, which is why it is here and not in the ViewModel layer.
  let files = s.session.fileTreeVM
  if not files.isNil:
    files.setRoot(recordingFileTree(s.tracePath))
    result.files = files.rootEntry.val.children.len > 0
    # PLAT-50: BOTH NATIVE TREES OPEN FULLY EXPANDED, as they have always
    # listed it (every root and file of a multi-root recording —
    # `test_recording_file_tree`); from there a click collapses or expands a
    # folder through the VM (`FilesystemVM.toggleExpanded`, the desktop's
    # Files click), which the terminal's rows and GPUI's view follow.
    expandAllFolders(files)

proc refreshCallStackFallback*(s: HeadlessDebugSession) =
  ## PLAT-47: hand the calltrace pane the call STACK when — and only when —
  ## the recording provides no call trace (`CalltraceVM.fallbackStack`),
  ## re-asked now even at an unchanged stop. The load itself is the SDK stop
  ## loader's (`StopPane.spCallStackFallback`).
  s.sdk.stops.reload(spCallStackFallback)
  drainPlatformCallbacks()

proc selectCurrentCall*(s: HeadlessDebugSession) =
  ## PLAT-49 part B: select the call the debugger is in, as the desktop does
  ## on every move (`CalltraceComponent.onCompleteMove` -> `selectEntry`) —
  ## `calltrace_vm.currentCallOf` over the section held, the stop's tick and
  ## its call stack, through `currentCallInSectionOf`: never a call that has
  ## returned (codetracer#845: a collapsed parent hides the current call),
  ## and, when the section cannot show its answer has not returned, only the
  ## call the engine's `currentCallLineIndex` names too. Otherwise nothing
  ## is selected.
  let vm = s.session.calltraceVM
  let calltrace = s.session.store.calltrace
  let lines = calltrace.lines.val
  if vm.isNil or lines.len == 0:
    return
  var names: seq[string] = @[]
  try:
    let response = s.sendRawDapRequest("stackTrace", %*{
      "threadId": 1, "startFrame": 0, "levels": RecordingCalltraceLevels})
    discard s.drainEvents()
    for f in response{"body", "stackFrames"}.getElems:
      names.add f{"name"}.getStr("")
  except CatchableError:
    return
  # The lines carry their trace index (`startCallLineIndex + i`), the
  # numbering of `totalCallsCount` and `currentCallLineIndex` too.
  let reachesEnd =
    lines[^1].index + 1 >= calltrace.totalCallsCount.val.int64
  vm.selectEntry(currentCallInSectionOf(lines, s.getCurrentRRTicks(), names,
    reachesEnd, calltrace.currentLineIndex.val))

proc loadStopPanes*(s: HeadlessDebugSession): PaneLoad =
  ## The per-STOP producers — the values in scope where the debugger now is
  ## (the state pane and the editor's inline values) and the PLAT-47 call
  ## stack fallback — through the SDK's stop loader, the one per-stop loader
  ## of every front-end. Each is asked once per stop; the stdio transport's
  ## answers are applied when the platform callbacks are drained, below.
  let loader = s.sdk.stops
  loader.loadStop()
  drainPlatformCallbacks()
  result.locals = loader.status[spLocals].val == plsApplied

proc stdoutIsTerminal*(): bool =
  ## Whether standard output is a terminal.
  ##
  ## `isatty` is in `std/posix`, which is exactly the kind of import the
  ## `app/` layer may not make — the question "am I attached to a terminal" is
  ## the definition of a host concern. CTUI-11 builds capability negotiation on
  ## top of this; CTUI-0 uses it to decide whether `main.nim` may assume a
  ## screen.
  isatty(STDOUT_FILENO) == 1
