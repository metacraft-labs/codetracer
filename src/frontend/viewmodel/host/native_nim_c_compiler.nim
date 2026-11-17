## host/native_nim_c_compiler.nim — Edit mode's source of a Nim file's
## generated C: `nim c --compileOnly --lineDir:on` into a scratch nimcache,
## the C files it wrote handed back
## (`GUI/Debugging-Features/Generated-Code-Listing.md` §13.4, "Where the C
## comes from").
##
## Debug mode reads the C a recording bundles; Edit mode has no recording, so
## the C is the compiler's, made now. `--compileOnly` stops before the C
## compiler runs, so the wait is the Nim front end's alone (§8.1), and
## `--lineDir:on` writes the `#line` directives a stock compiler's listing
## is anchored by, `--sourcemap:on` the `.c.map` CodeTracer's own compiler
## writes instead (`nim_c_producer`; each compiler ignores the other's). The file is compiled AS THE MAIN MODULE: the
## project's entry file need not import the file being edited, and compiling
## the file itself always yields that module's own C.
##
## One compile at a time, stepwise, like the Nim tracer
## (`native_nim_tracer`): `startNimCCompile` launches and returns,
## `pollNimCCompile` drains the child and settles once it exits — so the
## front-end's loop keeps painting while the compiler runs. The nimcache
## lives under the native state root (`nim-c-listings/`), one folder per
## source, reused by the next compile of the same file so Nim's own cache
## makes it faster; nothing is written into the project.

import std/[algorithm, os, osproc, streams, strutils, times]

import ./native_state
import ./nim_c_compile_plan
export nim_c_compile_plan
  # The compile itself — arguments, nimcache name, the error a refusal
  # quotes — is shared with the desktop's main process, which runs the same
  # compile through node (`index/nim_c_listing`).

const
  NimEnvVar = "CODETRACER_NIM"
    ## The compiler to run; else `nim` on the PATH (the tracer's variable:
    ## one compiler for both).
  DefaultTimeoutMs = 120_000

type
  NimCCompilePhase* = enum
    nccIdle, nccRunning, nccDone, nccFailed

  NimCCompile* = ref object
    ## The compile in flight, or the last one's result.
    phase*: NimCCompilePhase
    source*: string
      ## The Nim file compiled (absolute).
    message*: string
      ## Why it failed, "" otherwise.
    cFiles*: seq[string]
      ## The generated C files the compile left in the nimcache, sorted.
    timeoutMs*: int
    process: Process
    output: string
    cache: string
    startedAt: float

proc newNimCCompile*(): NimCCompile =
  NimCCompile(phase: nccIdle, timeoutMs: DefaultTimeoutMs)

proc findNim(): string =
  let fromEnv = getEnv(NimEnvVar).strip
  if fromEnv.len > 0:
    return (if fileExists(fromEnv): fromEnv else: "")
  findExe("nim")

proc cacheOf*(source: string): string =
  ## The scratch nimcache of `source`: one per file, named so a person can
  ## tell which (`<stem>-<hash of the path>`).
  nativeStateRoot() / NimCListingsDir / cacheNameOf(source)

proc running*(c: NimCCompile): bool = c.phase == nccRunning

proc fail(c: NimCCompile; message: string) =
  c.phase = nccFailed
  c.message = message
  c.process = nil

proc startNimCCompile*(c: NimCCompile; source: string): bool =
  ## Start compiling `source` to C. False — `message` saying why — when
  ## there is no compiler, or one is already running.
  if c.running:
    c.message = "the generated C of " & c.source.extractFilename &
                " is still being compiled"
    return false
  c.source = absolutePath(source)
  c.cFiles = @[]
  c.output = ""
  c.message = ""
  c.cache = cacheOf(c.source)
  c.startedAt = epochTime()
  if not fileExists(c.source):
    c.fail(c.source & " is not a file: save it first")
    return false
  let nim = findNim()
  if nim.len == 0:
    c.fail("no `nim` to compile " & c.source.extractFilename &
           " with (set " & NimEnvVar & ", or put `nim` on the PATH)")
    return false
  try:
    createDir(c.cache)
    c.process = startProcess(nim, workingDir = c.source.parentDir,
      args = compileArgumentsOf(c.source, c.cache),
      options = {poStdErrToStdOut})
  except CatchableError as e:
    c.fail("could not start " & nim & ": " & e.msg)
    return false
  c.phase = nccRunning
  true

when not defined(windows):
  import std/posix

  proc readable(fd: FileHandle): bool =
    var p = TPollfd(fd: cint(fd), events: POLLIN)
    posix.poll(addr p, 1, 0) == 1 and (p.revents and (POLLIN or POLLHUP)) != 0

proc drain(c: NimCCompile) =
  ## What the compiler printed so far, without blocking.
  when defined(windows):
    try:
      let outp = c.process.outputStream
      while c.process.hasData:
        var line = ""
        if not outp.readLine(line):
          break
        c.output.add line & "\n"
    except CatchableError:
      discard
  else:
    var buf: array[4096, char]
    let fd = c.process.outputHandle
    while readable(fd):
      let n = posix.read(fd, addr buf[0], buf.len)
      if n <= 0:
        break
      for i in 0 ..< n:
        c.output.add buf[i]

proc settle(c: NimCCompile; code: int) =
  if code != 0:
    let why = errorLineOf(c.output)
    c.fail(if why.len > 0: why else: "nim exited " & $code)
    return
  for f in walkDirRec(c.cache):
    if f.endsWith(".nim.c"):
      c.cFiles.add f
  if c.cFiles.len == 0:
    c.fail("nim wrote no C for " & c.source.extractFilename)
    return
  c.cFiles.sort()
  c.phase = nccDone

proc pollNimCCompile*(c: NimCCompile): bool =
  ## Advance the compile; true on the poll it settled (`phase` is then
  ## `nccDone` or `nccFailed`).
  if c.isNil or not c.running or c.process.isNil:
    return false
  c.drain()
  let code = c.process.peekExitCode()
  if code == -1:
    if c.timeoutMs > 0 and
       (epochTime() - c.startedAt) * 1000.0 > float(c.timeoutMs):
      c.process.terminate()
      discard c.process.waitForExit(2000)
      c.process.close()
      c.fail("nim did not finish within " & $(c.timeoutMs div 1000) & " s")
      return true
    return false
  c.drain()
  c.process.close()
  c.process = nil
  c.settle(code)
  true

proc waitNimCCompile*(c: NimCCompile; pollMs = 20): bool =
  ## Poll until the compile settles — for a caller with no loop of its own
  ## (a test). True when it compiled.
  while c.running:
    if not c.pollNimCCompile():
      sleep(pollMs)
  c.phase == nccDone
