## PLAT-29 — file reads and writes as ASYNCHRONOUS producers, reconciled.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat29_file_producer.nim
##
## `:w` and `:e!` hand a job to the host's file worker and are reconciled
## against the buffer when the answer arrives (`app/file_io_producer`,
## Editor-ViewModel.md §11). This suite delivers the answers when IT chooses —
## after the buffer has moved, or not — and asserts:
##
##   * a WRITE marks the buffer saved as of exactly the bytes written: typed
##     past during the write, the buffer stays dirty and the status says the
##     buffer changed since;
##   * a RELOAD onto an unmoved buffer installs the disk's bytes through the
##     editing core — and `undo` takes them back out;
##   * a RELOAD the user typed INTO while it was in flight is discarded and
##     said so, keeping every keystroke; one that saw typing only at the
##     buffer's EDGE is installed past it by `rebase`, keeping the typing;
##   * every answer is counted in the buffer's `fileReport`;
##   * the real worker thread finishes a submitted write before `stop` joins
##     it — `:w` then quit reaches the disk.
##
## ## The one stand-in, and why it is not a mock
##
## `rt.editServices.submitFileJob` KEEPS the jobs so a case can run them late.
## Running one is `edit_host.readProjectFile` / `writeProjectFile` on a real
## file in a real temporary project — the functions the worker runs — so the
## answer is the disk's, not a fabricated one. The last suite runs the real
## thread.

import std/[os, posix, strutils, tempfiles, unittest]

import codetracer_embed
import ../app/edit_binding
import ../app/runtime
import ../app/theme/capabilities
import ../host/edit_host
import ../host/file_worker
import ../host/native_host

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Cols = 120
  Rows = 40
  Path = "doc.txt"
  Text = "alpha\nbeta\ngamma\n"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

type Fixture = object
  rt: TuiRuntime
  root: string
  jobs: ref seq[FileJob]

proc fixture(): Fixture =
  result.root = createTempDir("plat29-files-", "")
  writeFile(result.root / Path, Text)
  let app = newTuiApp()
  app.modes = initModeRegister(pmEdit)
  app.editSession = newEditSession()
  discard app.editSession.openFile(Path, Text)
  result.rt = newTuiRuntime(app, caps(), Cols, Rows)
  discard result.rt.focus.focusPaneKind(paneEditor)
  let jobs = new seq[FileJob]
  result.jobs = jobs
  result.rt.editServices.submitFileJob = proc(job: FileJob) = jobs[].add job

proc run(f: Fixture; job: FileJob): FileJobResult =
  ## The job, done now, by the functions the worker runs.
  result = FileJobResult(job: job)
  try:
    case job.kind
    of fjRead: result.text = readProjectFile(f.root, job.path)
    of fjWrite: writeProjectFile(f.root, job.path, job.text)
    result.ok = true
  except TuiHostError as e:
    result.message = e.msg

proc buf(f: Fixture): EditBuffer = f.rt.app.editSession.activeBuffer()

proc prompt(f: Fixture; line: string) =
  discard f.rt.prompt.open(pkCommand)
  for ch in line:
    discard f.rt.prompt.applyKey($ch, @[])
  discard f.rt.handleToken("\r", 0)

proc typeAt(f: Fixture; line, column: int; text: string) =
  f.buf.doc.moveCaretTo(line, column)
  var now = 100'i64
  for ch in text:
    now += 1
    discard f.rt.handleToken($ch, now)

suite "PLAT-29: a write's answer marks what was WRITTEN as saved":

  test "`:w` on an unmoved buffer: clean, on disk, `wrote`":
    let f = fixture()
    defer: removeDir(f.root)
    f.typeAt(0, 5, "!")
    ck f.buf.isDirty
    f.prompt(":w")
    ck f.rt.app.notification == "writing " & Path & "…"
    ck f.jobs[].len == 1
    ck f.rt.deliverFileJob(f.run(f.jobs[][0]))
    ck f.rt.app.notification == "wrote " & Path
    ck not f.buf.isDirty
    ck readFile(f.root / Path) == "alpha!\nbeta\ngamma\n"
    ck f.buf.fileReport.count(pkFileWrite, roApplied) == 1

  test "typed past while the write ran: the typing stays dirty":
    let f = fixture()
    defer: removeDir(f.root)
    f.typeAt(0, 5, "1")
    f.prompt(":w")
    f.typeAt(2, 0, "2")                           # after the job was made
    ck f.rt.deliverFileJob(f.run(f.jobs[][0]))
    ck f.rt.app.notification == "wrote " & Path & " (the buffer has changed since)"
    ck readFile(f.root / Path) == "alpha1\nbeta\ngamma\n"
    ck f.buf.loadedText == "alpha1\nbeta\ngamma\n"
    ck f.buf.isDirty
    ck f.buf.fileReport.count(pkFileWrite, roMapped) == 1

suite "PLAT-29: a reload is installed, or discarded, never clobbers":

  test "`:e!` onto an unmoved buffer installs the disk — and undo takes it out":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / Path, "changed on disk\n")
    f.prompt(":e!")
    ck f.rt.app.notification == "reloading " & Path & "…"
    ck f.rt.deliverFileJob(f.run(f.jobs[][0]))
    ck f.rt.app.notification == "reloaded " & Path
    ck f.buf.text == "changed on disk\n"
    ck not f.buf.isDirty
    ck f.buf.fileReport.count(pkFileRead, roApplied) == 1
    discard f.buf.doc.applyNamed("undo", OpArgs(), 200)
    ck f.buf.text == Text

  test "typed INTO while the reload was read: discarded, typing kept":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / Path, "changed on disk\n")
    f.prompt(":e!")
    f.typeAt(1, 2, "X")                           # inside the evidence
    ck f.rt.deliverFileJob(f.run(f.jobs[][0]))
    ck f.rt.app.notification.startsWith("reload of " & Path & " discarded")
    ck f.buf.text == "alpha\nbeXta\ngamma\n"
    ck f.buf.fileReport.count(pkFileRead, roDropped) == 1

  test "typed only at the buffer's EDGE: installed past it, typing kept":
    let f = fixture()
    defer: removeDir(f.root)
    writeFile(f.root / Path, "changed on disk\n")
    f.prompt(":e!")
    f.typeAt(3, 0, "tail")                        # after the final newline
    ck f.rt.deliverFileJob(f.run(f.jobs[][0]))
    ck f.buf.text == "changed on disk\ntail"
    ck f.rt.app.notification.startsWith("reloaded " & Path & " (keeping")
    ck f.buf.fileReport.count(pkFileRead, roMapped) == 1

  test "a failed read says why, and changes nothing":
    let f = fixture()
    defer: removeDir(f.root)
    removeFile(f.root / Path)
    f.prompt(":e!")
    ck f.rt.deliverFileJob(f.run(f.jobs[][0]))
    ck f.rt.app.notification == Path & ": no such file"
    ck f.buf.text == Text

suite "PLAT-29: the real file worker":

  test "a write submitted before `stop` is on disk after it":
    let root = createTempDir("plat29-worker-", "")
    defer: removeDir(root)
    writeFile(root / Path, Text)
    var fds: array[2, cint]
    doAssert posix.pipe(fds) == 0
    defer:
      discard posix.close(fds[0])
      discard posix.close(fds[1])
    let w = startFileWorker(root, fds[1])
    let d = initEditingDocument(Path, "written by the worker\n")
    w.submit(fileJobFor(fjWrite, d, Path, 1))
    w.stop()                                      # joins after the write
    ck readFile(root / Path) == "written by the worker\n"

suite "PLAT-29 file producer — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
