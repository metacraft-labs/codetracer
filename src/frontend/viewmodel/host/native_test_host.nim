## viewmodel/host/native_test_host.nim — the Test Results pane's host on the
## terminal and the GPUI window: the desktop's host state machine, over native
## producers.
##
## Spec: `GUI/Core-Panes/Test-Results-Pane.md` §8 (read §3 – §5 first: what a
## host owes the pane, and that a run settles however it ended).
##
## ## The desktop's host, installed unchanged
##
## `viewmodels/desktop_test_host.nim` is already free of Electron: its
## dispatches and its settles are injected, and its state machine — one
## pending run of either kind, `beginRun` before the dispatch, a refused or
## raising dispatch settled at once, the suite's settle that joins a
## provider's test names onto the catalog's ids, closes a row the runner left
## `running` and every open scope — is the part a second copy would get wrong.
## So this module installs THAT host on the native front-ends' ViewModel and
## supplies only what the desktop's main process supplies over IPC: the two
## commands, run in the background, and their answers.
##
## | Desktop (`index/traces.nim`)        | Here                                  |
## | ----------------------------------- | ------------------------------------- |
## | `onRunTestSuite`: `ct test run --workspace <root> --events <file>` | `dispatchSuite` |
## | `onRunTest`: `ct record-test …`     | `dispatchRecord`                      |
## | `CODETRACER::test-suite-settled`    | `settleSuite` → `settleDesktopSuiteRun` |
## | `CODETRACER::test-run-settled`      | `settleRecord` → `settleDesktopTestRun` |
## | `openRecording` (where §9 places it) | `openRecording` → the front-end's `openFolder`, by the same placement (§9.5) |
##
## ## Polled, not awaited
##
## A front-end calls `poll` from the loop that reads its input (the terminal's
## idle tick, the GPUI window's timer), so the screen keeps answering while a
## suite runs. The child's output goes to files (a pipe nobody drains would
## fill and stall it), and the child is its own process GROUP, so the
## front-end's exit (`stop`) ends `ct`, the `ct-test` it delegated to and the
## `nargo` under that, not just the first of them.
##
## ## Every way out settles (§5)
##
## Exited with any status; ENDED BY A SIGNAL (killed from outside, or by
## `stop`) — the desktop's sentence `ct test run was ended by signal <n>`,
## with whatever the events file already held; could not be started (no `ct`,
## a spawn error) — refused, which the desktop host settles at once. There is
## no fourth.

import std/[algorithm, monotimes, os, osproc, strutils, times]
when defined(posix):
  import std/posix

import isonim/core/signals

import ../viewmodels/test_results_vm
import ../viewmodels/desktop_test_host
import ../viewmodels/test_catalog_answer
import ../viewmodels/replay_open_setting
import ./native_state
from ../../../ct/trace/recorder_output import recordingIdFromOutput,
  recordTestFailureSentence
import ../../../common/ct_home

export desktop_test_host, test_results_vm, replay_open_setting

type
  NativeRunKind* = enum
    nrkSuite = "suite"
      ## `ct test run`.
    nrkRecord = "record"
      ## `ct record-test`.

  NativeTestJob* = ref object
    ## One background run.
    kind*: NativeRunKind
    process: Process
    pid*: int
      ## The child's pid, which is also its process group's id on POSIX.
    outPath, errPath*: string
    eventsPath*: string
      ## `nrkSuite`: the `--events` file.
    commandLine*: string

  NativeOpenFolder* = proc(testId, recordingId, folder: string;
                           policy: TraceOpenPolicy): string
    ## The front-end opens test `testId`'s recording `recordingId` (at
    ## `folder`) where §9 places it
    ## for the destination `policy` (`TestResultsVM.placeTestRecording`: by
    ## default a NEW SESSION TAB) and answers "" — or why it did not (a
    ## front-end with no session tabs says so here, which the pane then
    ## shows).
  NativeResolveFolder* = proc(recordingId: string): string
    ## Where the trace store keeps a recording (`ct trace-metadata --id`), or
    ## "".
  NativeCtBinary* = proc(): string
    ## The `ct` to run, or "" when there is none.
  NativeProjectRoot* = proc(): string
    ## The window's project (§8.2).

  NativeTestHost* = ref object
    host*: DesktopTestHost
    vm*: TestResultsVM
    projectRoot*: NativeProjectRoot
    ctBinary*: NativeCtBinary
    resolveFolder*: NativeResolveFolder
    openFolder*: NativeOpenFolder
    job*: NativeTestJob
      ## The run in flight, or nil.
    catalogRoot*: string
      ## The folder the catalog was last read from.
    opened*: seq[string]
      ## Every recording folder handed to `openFolder` that it opened, in
      ## order.
    openedPolicies*: seq[TraceOpenPolicy]
      ## The destination each of those was opened for, in the same order.
    placedWords*: string
      ## Set by the front-end's `openFolder` as it performs a placement: where
      ## the recording went (" in a new tab", " in its own tab", " in this
      ## tab"), for the note.
    note*: string
      ## The last thing the host has to say on a status line (a recording
      ## opened, an open refused), consumed by the front-end (`takeNote`).
    serial: int

const
  NoCtBinaryText* = "no ct found to run the tests with; set CT_BIN"
    ## A host with no `ct` (the desktop always has its own).
  SuiteRunsDirName* = "test-suite-runs"
    ## Under the CodeTracer tmp directory, as the desktop's.

proc replayOpenPath*(): string =
  ## §9.3's document, in the native state root (beside `table-columns`).
  nativeStateRoot() / ReplayOpenFileName

proc readReplayOpen*(): string =
  let path = replayOpenPath()
  try:
    if fileExists(path): readFile(path) else: ""
  except CatchableError:
    ""

proc writeReplayOpen*(text: string): string =
  writeStaged(replayOpenPath(), text)

proc localTimeText*(): string =
  ## When a recording was made, in the reader's own clock — the desktop's
  ## `toLocaleTimeString()` in its en-US shape (`h:mm:ss AM`).
  now().format("h:mm:ss tt")

# ---------------------------------------------------------------------------
# The catalog (§8.2)
# ---------------------------------------------------------------------------

proc noirSourcesUnder*(root: string): seq[NoirSourceFile] =
  ## Every readable `.nr` under `<root>/src`, named by its project-relative
  ## path with `/` separators, in path order — what `index/ns9_panes`'
  ## `noirSourcesUnder` reads with node's `fs`. An unreadable file is
  ## skipped: one bad file must not cost the project its catalog.
  let src = root / "src"
  if not dirExists(src):
    return
  var paths: seq[string] = @[]
  for path in walkDirRec(src, yieldFilter = {pcFile, pcLinkToFile}):
    if path.endsWith(".nr"):
      paths.add path
  paths.sort(system.cmp)
  for path in paths:
    try:
      result.add NoirSourceFile(
        path: relativePath(path, root).replace('\\', '/'),
        content: readFile(path))
    except CatchableError:
      discard

proc catalogAnswerFor*(root: string): TestCatalogAnswer =
  ## The shared rule (`test_catalog_answer`) over the filesystem.
  testCatalogAnswer(root,
    root.len > 0 and fileExists(root / NoirProjectMarker),
    proc(): seq[NoirSourceFile] = noirSourcesUnder(root))

proc refreshCatalog*(h: NativeTestHost; force = false): bool =
  ## Read the project's catalog into the pane when the project changed (or
  ## `force`). Whether anything was read.
  if h.isNil or h.vm.isNil:
    return false
  let root = if h.projectRoot.isNil: "" else: h.projectRoot()
  if not force and root == h.catalogRoot and h.catalogRoot.len > 0:
    return false
  h.catalogRoot = root
  # §9.3: the workspace's `replay-open-in`, read where the catalog is.
  h.vm.setOpenSetting(replayOpenFor(readReplayOpen(), root))
  let answer = catalogAnswerFor(root)
  h.vm.setRunAbsence(answer.absence)
  if answer.hasCatalog:
    h.vm.setCatalog(answer.catalog)
  else:
    h.vm.catalog.val = @[]
  true

# ---------------------------------------------------------------------------
# Running a command in the background
# ---------------------------------------------------------------------------

proc running*(h: NativeTestHost): bool =
  not h.isNil and not h.job.isNil

proc startJob(h: NativeTestHost; kind: NativeRunKind; argv: seq[string];
              workingDir: string): string =
  ## Start `argv` with its output in files, as its own process group. "" when
  ## it started, else why not (the desktop host settles a refusal at once).
  inc h.serial
  let dir = ctTmpDir() / SuiteRunsDirName
  try:
    createDir(dir)
  except CatchableError as e:
    return "could not make " & dir & ": " & e.msg
  let stem = dir / ($getCurrentProcessId() & "-" & $h.serial & "-" &
                    $int(epochTime() * 1000))
  var job = NativeTestJob(kind: kind, outPath: stem & ".out",
                          errPath: stem & ".err",
                          commandLine: argv.join(" "))
  if kind == nrkSuite:
    job.eventsPath = argv[^1]
  try:
    when defined(posix):
      # THE SHELL ONLY REDIRECTS. The command is passed as `$0 "$@"`, an
      # argument vector, so no part of it is ever parsed as shell text.
      let script = "exec \"$0\" \"$@\" </dev/null >" & quoteShell(job.outPath) &
                   " 2>" & quoteShell(job.errPath)
      job.process = startProcess("/bin/sh", workingDir = workingDir,
                                 args = @["-c", script] & argv,
                                 options = {poDaemon})
    else:
      job.process = startProcess(argv[0], workingDir = workingDir,
                                 args = argv[1 .. ^1],
                                 options = {poStdErrToStdOut, poDaemon})
    job.pid = job.process.processID
  except CatchableError as e:
    return "could not start " & argv[0].extractFilename & ": " & e.msg
  h.job = job
  ""

proc readQuietly(path: string): string =
  if path.len == 0 or not fileExists(path):
    return ""
  try: readFile(path)
  except CatchableError: ""

proc removeQuietly(path: string) =
  if path.len > 0:
    try: removeFile(path)
    except CatchableError: discard

proc signalOf(exitCode: int): int =
  ## The signal a shell-like exit status reports (128 + n), or 0.
  if exitCode > 128 and exitCode < 128 + 65: exitCode - 128 else: 0

proc suiteEndedBySignalText*(signal: int): string =
  ## The desktop's sentence (`index/traces.onRunTestSuite`).
  "ct test run was ended by signal " & $signal

# ---------------------------------------------------------------------------
# The two dispatches, as the desktop's main process runs them
# ---------------------------------------------------------------------------

proc dispatchSuite(h: NativeTestHost; root: string): string =
  ## `ct test run --workspace <root> --events <file>`.
  let ct = if h.ctBinary.isNil: "" else: h.ctBinary()
  if ct.len == 0:
    return NoCtBinaryText
  let events = ctTmpDir() / SuiteRunsDirName /
               ($getCurrentProcessId() & "-events-" & $(h.serial + 1) & "-" &
                $int(epochTime() * 1000) & ".jsonl")
  h.startJob(nrkSuite, @[ct, "test", "run", "--workspace", root,
                         "--events", events], root)

proc dispatchRecord(h: NativeTestHost; selector, file: string;
                    line: int): string =
  ## `ct record-test <selector> <file> <line> 1 --with-diff=HEAD
  ## --store-trace-folder-for-pid=<pid>` — `onRunTest`'s arguments.
  let ct = if h.ctBinary.isNil: "" else: h.ctBinary()
  if ct.len == 0:
    return NoCtBinaryText
  let root = if h.projectRoot.isNil: "" else: h.projectRoot()
  let cwd = if root.len > 0 and dirExists(root): root else: getCurrentDir()
  h.startJob(nrkRecord, @[ct, "record-test", selector, file, $line,
                          "1", "--with-diff=HEAD",
                          "--store-trace-folder-for-pid=" &
                            $getCurrentProcessId()], cwd)

proc openRecordingFolder(h: NativeTestHost; testId, recordingId: string;
                         policy: TraceOpenPolicy): string =
  ## Open test `testId`'s recording `recordingId` where §9 places it: its
  ## folder resolved by the trace store, then handed to the front-end. ""
  ## when it opened.
  if h.openFolder.isNil:
    return NoReplayHostText
  let folder = if h.resolveFolder.isNil: "" else: h.resolveFolder(recordingId)
  if folder.len == 0:
    return "the trace store has no folder for recording " & recordingId
  h.placedWords = " in a new tab"
  let why = h.openFolder(testId, recordingId, folder, policy)
  if why.len == 0:
    h.opened.add folder
    h.openedPolicies.add policy
    h.note = "opened the recording " & folder.extractFilename & h.placedWords
  why

proc setReplayOpen*(h: NativeTestHost; policy: TraceOpenPolicy): string =
  ## The palette's **Tests: Open Recordings in …** (§9.3): write the
  ## project's `replay-open-in` and answer the status line's sentence.
  if h.isNil or h.vm.isNil:
    return NoReplayHostText
  let root = if h.projectRoot.isNil: "" else: h.projectRoot()
  if root.len == 0:
    return replayOpenNoWorkspaceText()
  let why = writeReplayOpen(withReplayOpen(readReplayOpen(), root, policy))
  if why.len > 0:
    return "could not remember " & ReplayOpenSettingName & ": " & why
  h.vm.setOpenSetting(policy)
  replayOpenSetNote(root, policy)

proc newNativeTestHost*(vm: TestResultsVM; projectRoot: NativeProjectRoot;
                        ctBinary: NativeCtBinary;
                        resolveFolder: NativeResolveFolder;
                        openFolder: NativeOpenFolder): NativeTestHost =
  ## The host, installed on `vm`: the header ▶ and the three row actions, as
  ## `ui_js` installs the desktop's.
  let h = NativeTestHost(vm: vm, projectRoot: projectRoot, ctBinary: ctBinary,
                         resolveFolder: resolveFolder, openFolder: openFolder)
  h.host = newDesktopTestHost(vm,
    dispatch = proc(selector, file: string; line: int): string =
      h.dispatchRecord(selector, file, line),
    settleEditor = nil)
  h.host.installDesktopSuiteRun(
    workspaceRoot = proc(): string =
      if h.projectRoot.isNil: "" else: h.projectRoot(),
    suiteDispatch = proc(workspaceRoot: string): string =
      h.dispatchSuite(workspaceRoot))
  h.host.installDesktopRowActions(
    keepWindowDispatch = proc(selector, file: string; line: int): string =
      h.dispatchRecord(selector, file, line),
    openRecording = proc(testId, recordingId: string;
                         policy: TraceOpenPolicy): string =
      h.openRecordingFolder(testId, recordingId, policy))
  h

# ---------------------------------------------------------------------------
# The answers
# ---------------------------------------------------------------------------

proc settleSuite(h: NativeTestHost; job: NativeTestJob; exitCode: int) =
  ## `onRunTestSuite`'s answer: the events file whatever the status, the
  ## runner's stderr, and the signal's sentence when one ended it.
  let events = readQuietly(job.eventsPath)
  let stderrText = readQuietly(job.errPath)
  let signal = signalOf(exitCode)
  let ended = if signal > 0: suiteEndedBySignalText(signal) else: ""
  h.host.settleDesktopSuiteRun(events, exitCode, stderrText, ended)

proc settleRecord(h: NativeTestHost; job: NativeTestJob; exitCode: int) =
  ## `onRunTest`'s answer: the recording `ct record-test` reported, or the
  ## recorder's own reason there is none. For record-and-open the shared host
  ## then opens the recording where §9 places it (`settleDesktopTestRun`).
  let stdoutText = readQuietly(job.outPath)
  let stderrText = readQuietly(job.errPath)
  let signal = signalOf(exitCode)
  var recordingId = ""
  var error = ""
  if exitCode == 0:
    recordingId = recordingIdFromOutput(stdoutText)
    if recordingId.len == 0:
      error = "ct record-test finished without reporting a recording id, " &
              "so there is nothing to replay"
  else:
    error = recordTestFailureSentence(exitCode,
      (if signal > 0: $signal else: ""), stdoutText, stderrText, "")
  h.host.settleDesktopTestRun(
    recordingId = recordingId,
    recordedAtText = (if recordingId.len > 0: localTimeText() else: ""),
    errorMessage = error)

proc finish(h: NativeTestHost; job: NativeTestJob; exitCode: int) =
  h.job = nil
  try:
    job.process.close()
  except CatchableError:
    discard
  case job.kind
  of nrkSuite: h.settleSuite(job, exitCode)
  of nrkRecord: h.settleRecord(job, exitCode)
  removeQuietly(job.outPath)
  removeQuietly(job.errPath)
  removeQuietly(job.eventsPath)

proc poll*(h: NativeTestHost): bool =
  ## Settle the run in flight if it has ended. Whether it did (the pane
  ## changed).
  if not h.running:
    return false
  let job = h.job
  var code = -1
  try:
    code = job.process.peekExitCode()
  except CatchableError:
    code = 1
  if code == -1:
    return false
  h.finish(job, code)
  true

proc killGroup(job: NativeTestJob; signal: cint) =
  when defined(posix):
    if job.pid > 0:
      discard posix.kill(Pid(-job.pid), signal)
      discard posix.kill(Pid(job.pid), signal)
  else:
    try: job.process.kill()
    except CatchableError: discard

proc stop*(h: NativeTestHost) =
  ## End the run in flight — its whole process group — and settle it, as the
  ## front-end closes. Waits (bounded) for the child, then settles whatever
  ## it answered: a run ended this way is "ended by a signal".
  if not h.running:
    return
  let job = h.job
  when defined(posix):
    job.killGroup(SIGTERM)
  else:
    job.killGroup(0)
  let deadline = getMonoTime() + initDuration(milliseconds = 2000)
  var code = -1
  while getMonoTime() < deadline:
    try: code = job.process.peekExitCode()
    except CatchableError: code = 1
    if code != -1:
      break
    sleep(20)
  if code == -1:
    when defined(posix):
      job.killGroup(SIGKILL)
    try: code = job.process.waitForExit(2000)
    except CatchableError: code = 137
    if code == -1: code = 137
  h.finish(job, code)

proc takeNote*(h: NativeTestHost): string =
  ## What the host last had to say on a status line, once.
  if h.isNil:
    return ""
  result = h.note
  h.note = ""
