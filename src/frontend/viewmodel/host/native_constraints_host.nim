## viewmodel/host/native_constraints_host.nim — PLAT-62. **The terminal's and
## the GPUI window's Constraints pane is measured the way the desktop's is.**
##
## The desktop's main process runs `nargo info --json` in the project's folder
## and answers the pane with the shared rule (`index/ns9_panes` over
## `viewmodels/constraints_answer`). This is the same host for a native
## window: it owns nothing but the run — the window's `ConstraintsVM` is the
## caller's — and it runs the same command in the same folder and hands the
## outcome to the same rule, so the three front-ends show the same report, the
## same absences and the same rows (`ConstraintsVM.rows`, placed against the
## sources read here).
##
## ONE PER WINDOW, as Test Results' host is (`native_test_host`): every tab of
## a native window shares its project, so a recording opened from it shows the
## project's circuit too.
##
## The run is a background process with its output in files, polled from the
## front-end's loop (`poll`), so the screen keeps answering while `nargo`
## compiles. It is started again when the project changes (`refresh`) and when
## a source the counts depend on is saved (`watch`, the desktop's re-ask on
## save); an unsaved edit marks the counts stale (`noteEdited`), as the
## desktop's editor hook does.

import std/[algorithm, monotimes, os, osproc, strutils, times]
when defined(posix):
  import std/posix

import ../viewmodels/constraints_vm
import ../viewmodels/constraints_answer
from ./native_test_host import noirSourcesUnder
import ../../../common/ct_home

type
  NativeConstraintsRoot* = proc(): string {.closure.}
    ## The window's project folder, "" for none.

  NativeConstraintsJob = ref object
    process: Process
    pid: int
    root: string
    outPath, errPath: string

  NativeConstraintsHost* = ref object
    vm*: ConstraintsVM
    projectRoot: NativeConstraintsRoot
    measuredRoot*: string
      ## The folder the pane's report describes ("" before the first).
    fingerprint: string
      ## The sources' state the last run was started at (`watch`).
    job: NativeConstraintsJob
    lastWatchMs: int64
    serial: int
    runs*: int
      ## How many `nargo info` runs were started — for the suites.
    nargoProgram*: string
      ## The program run; `nargo` on PATH unless a caller names another.

const
  WatchIntervalMs* = 750
    ## How often `watch` reads the sources' state.
  ConstraintsRunsDirName = "constraints-runs"

proc nowMs(): int64 =
  getMonoTime().ticks div 1_000_000

proc sourcesFingerprint*(root: string): string =
  ## The state of the files a compile reads — `Nargo.toml` and every `.nr`
  ## under `src/` — as paths, sizes and modification times. A save of any of
  ## them changes it; an edit not yet saved does not.
  if root.len == 0:
    return ""
  var parts: seq[string] = @[]
  for path in [root / NoirProjectMarker]:
    if fileExists(path):
      try: parts.add path & ":" & $getFileSize(path) & ":" &
                     $getLastModificationTime(path).toUnixFloat
      except CatchableError: discard
  let src = root / "src"
  if dirExists(src):
    for path in walkDirRec(src, yieldFilter = {pcFile, pcLinkToFile}):
      if path.endsWith(".nr"):
        try: parts.add path & ":" & $getFileSize(path) & ":" &
                       $getLastModificationTime(path).toUnixFloat
        except CatchableError: discard
  parts.sort(system.cmp)
  parts.join("\n")

proc running*(h: NativeConstraintsHost): bool =
  not h.isNil and not h.job.isNil

proc readQuietly(path: string): string =
  if path.len == 0 or not fileExists(path):
    return ""
  try: readFile(path)
  except CatchableError: ""

proc removeQuietly(path: string) =
  if path.len > 0:
    try: removeFile(path)
    except CatchableError: discard

proc programMissing(program: string): bool =
  ## Whether `program` cannot be found: not a path that exists, and not on
  ## PATH. The desktop reads node's ENOENT for this; a native window asks
  ## before starting.
  if program.contains(DirSep) or program.contains('/'):
    return not fileExists(program)
  findExe(program).len == 0

proc settle(h: NativeConstraintsHost; root: string; run: NargoInfoRun) =
  ## The shared rule over a finished (or refused) run, into the pane.
  let hasMarker = root.len > 0 and fileExists(root / NoirProjectMarker)
  let answer = constraintsAnswer(root, hasMarker, run)
  h.measuredRoot = root
  if answer.hasReport:
    h.vm.setSources(noirSourcesUnder(root))
    h.vm.setReport(answer.report)
  else:
    h.vm.setSources(@[])
    h.vm.setAbsence(answer.absence)

proc startRun(h: NativeConstraintsHost; root: string) =
  ## Start `nargo info --json` in `root`, or settle at once when there is
  ## nothing to run.
  let hasMarker = root.len > 0 and fileExists(root / NoirProjectMarker)
  if absenceBeforeRun(root, hasMarker).len > 0:
    h.settle(root, NargoInfoRun())
    return
  let program = if h.nargoProgram.len > 0: h.nargoProgram else: "nargo"
  if programMissing(program):
    h.settle(root, NargoInfoRun(missing: true))
    return
  inc h.serial
  let dir = ctTmpDir() / ConstraintsRunsDirName
  try:
    createDir(dir)
  except CatchableError as e:
    h.settle(root, NargoInfoRun(message: "could not make " & dir & ": " &
                                         e.msg))
    return
  let stem = dir / ($getCurrentProcessId() & "-" & $h.serial & "-" &
                    $int(epochTime() * 1000))
  var job = NativeConstraintsJob(root: root, outPath: stem & ".out",
                                 errPath: stem & ".err")
  try:
    when defined(posix):
      # THE SHELL ONLY REDIRECTS: the command is `$0 "$@"`, an argument
      # vector, as `native_test_host.startJob` runs its own.
      let script = "exec \"$0\" \"$@\" </dev/null >" & quoteShell(job.outPath) &
                   " 2>" & quoteShell(job.errPath)
      job.process = startProcess("/bin/sh", workingDir = root,
                                 args = @["-c", script, program] &
                                        @NargoInfoArgs,
                                 options = {poDaemon})
    else:
      job.process = startProcess(program, workingDir = root,
                                 args = @NargoInfoArgs,
                                 options = {poUsePath, poDaemon})
    job.pid = job.process.processID
  except CatchableError as e:
    h.settle(root, NargoInfoRun(message: "could not start " & program & ": " &
                                         e.msg))
    return
  inc h.runs
  h.job = job

proc finish(h: NativeConstraintsHost; exitCode: int) =
  let job = h.job
  h.job = nil
  try: job.process.close()
  except CatchableError: discard
  var run = NargoInfoRun(started: true, exitCode: exitCode)
  when defined(posix):
    run.output = readQuietly(job.outPath)
    run.message = readQuietly(job.errPath)
  else:
    run.output = ""
  removeQuietly(job.outPath)
  removeQuietly(job.errPath)
  h.settle(job.root, run)

proc poll*(h: NativeConstraintsHost): bool =
  ## Settle the run in flight if it has ended. Whether it did (the pane
  ## changed).
  if not h.running:
    return false
  var code = -1
  try:
    code = h.job.process.peekExitCode()
  except CatchableError:
    code = 1
  if code == -1:
    return false
  h.finish(code)
  true

proc stop*(h: NativeConstraintsHost) =
  ## End the run in flight (its process group), as the front-end closes.
  if not h.running:
    return
  let job = h.job
  when defined(posix):
    if job.pid > 0:
      discard posix.kill(Pid(-job.pid), SIGKILL)
      discard posix.kill(Pid(job.pid), SIGKILL)
  else:
    try: job.process.kill()
    except CatchableError: discard
  try: discard job.process.waitForExit(2000)
  except CatchableError: discard
  try: job.process.close()
  except CatchableError: discard
  removeQuietly(job.outPath)
  removeQuietly(job.errPath)
  h.job = nil

proc refresh*(h: NativeConstraintsHost; force = false): bool =
  ## Measure the window's project when it changed (or `force`): a run is
  ## started, or the absence settled at once. Whether anything started.
  if h.isNil or h.vm.isNil:
    return false
  let root = if h.projectRoot.isNil: "" else: h.projectRoot()
  if not force and root == h.measuredRoot and
     (h.measuredRoot.len > 0 or h.runs > 0 or h.running):
    return false
  if h.running:
    h.stop()
  h.fingerprint = sourcesFingerprint(root)
  h.lastWatchMs = nowMs()
  h.startRun(root)
  true

proc watch*(h: NativeConstraintsHost): bool =
  ## Follow the project: re-measure when it was re-rooted, or when a source
  ## the counts depend on was saved since the last run (bounded to one look
  ## per `WatchIntervalMs`). Whether a run started.
  if h.isNil or h.vm.isNil:
    return false
  let root = if h.projectRoot.isNil: "" else: h.projectRoot()
  if root != h.measuredRoot and not h.running:
    return h.refresh()
  let now = nowMs()
  if now - h.lastWatchMs < WatchIntervalMs:
    return false
  h.lastWatchMs = now
  if h.running or root.len == 0:
    return false
  let state = sourcesFingerprint(root)
  if state == h.fingerprint:
    return false
  h.fingerprint = state
  h.startRun(root)
  true

proc noteEdited*(h: NativeConstraintsHost; path: string) =
  ## An unsaved edit to `path`: the counts may no longer describe the program
  ## on screen (`ConstraintsVM.noteSourceEdited` decides which files count).
  if not h.isNil and not h.vm.isNil:
    h.vm.noteSourceEdited(path)

proc newNativeConstraintsHost*(vm: ConstraintsVM;
                               projectRoot: NativeConstraintsRoot;
                               nargoProgram = ""): NativeConstraintsHost =
  ## A host for `vm` over the window's project. Nothing runs until `refresh`.
  NativeConstraintsHost(vm: vm, projectRoot: projectRoot,
                        nargoProgram: nargoProgram)
