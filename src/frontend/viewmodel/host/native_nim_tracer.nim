## host/native_nim_tracer.nim — the native front-ends' route to the tracing
## Nim compiler: nimsuggest's `traceExpand` / `tracestatic` queries, asked
## directly, and `nim e --trace` for a NimScript file.
##
## The terminal and the GPUI window have no LSP client, and this is why they
## do not grow one: the language server's two trace commands
## (`nim/traceExpandMacro`, `nim/traceStaticBlock`) are each a one-line
## forward to the same nimsuggest query (`nim-langserver` `routes.nim`), so
## an LSP client would add a JSON-RPC session and a second process in front
## of the query without adding an answer. The measurement that decided it is
## recorded with the milestone (codetracer-pm `milestones/CodeTracer-
## Platform.milestones.org`, native Nim tracing).
##
## One trace at a time, stepwise: `startNimTrace` launches and returns,
## `pollNimTrace` drains the child and settles the ViewModel once it exits —
## so the front-end's own loop keeps painting while the compiler runs.
##
## Where things go: the compiler's cache and the recording live under the
## native state root (`nim-traces/`), so a run writes nothing into the
## project or the user's own Nim cache. A recording is a folder holding the
## one `.ct` container the compiler wrote and the sources it steps through
## (`files/`) — the shape `replay-server` opens.

import std/[os, osproc, streams, strutils, times]

import ../viewmodels/nim_tracing_vm
import ./native_state

export nim_tracing_vm

const
  NimsuggestEnvVar = "CODETRACER_NIMSUGGEST"
    ## The trace-enabled nimsuggest (codetracer-nim's); else `nimsuggest` on
    ## the PATH.
  NimEnvVar = "CODETRACER_NIM"
    ## The trace-enabled compiler for `nim e --trace`; else `nim` on the PATH.
  NimTracesDir = "nim-traces"
  RecordingFileName = "trace.ct"
  DefaultTimeoutMs = 300_000

type
  NativeNimTracer* = ref object
    vm*: NimTracingVM
    process: Process
    output: string
    produced: string
      ## Where the recording is expected (an evaluation names it itself).
    folder: string
      ## The recording's folder under the state root.
    cache: string
      ## The compiler's cache for this run, removed when it settles.
    startedAt: float
    timeoutMs*: int

proc newNativeNimTracer*(): NativeNimTracer =
  NativeNimTracer(vm: newNimTracingVM(), timeoutMs: DefaultTimeoutMs)

proc resolveTool(envVar, name: string): string =
  let fromEnv = getEnv(envVar).strip
  if fromEnv.len > 0:
    return (if fileExists(fromEnv): fromEnv else: "")
  findExe(name)

proc findNimsuggest(): string = resolveTool(NimsuggestEnvVar, "nimsuggest")
proc findTracingNim(): string = resolveTool(NimEnvVar, "nim")

proc tracesRoot(): string = nativeStateRoot() / NimTracesDir

proc freshFolder(request: NimTraceRequest): string =
  ## `<file>-<action>` under the traces root — short, because the session
  ## tab is called after it — and `-2`, `-3` … beside an earlier one.
  let stem = extractFilenameOf(request.path).changeFileExt("")
  let base = tracesRoot() / (stem & "-" & $request.action)
  result = base
  var n = 1
  while dirExists(result) or dirExists(result & ".nimcache"):
    inc n
    result = base & "-" & $n

proc missingToolReason(action: NimTraceAction): string =
  if action == ntaEval:
    "no `nim` to run the script with (set " & NimEnvVar & ")"
  else:
    "nimsuggest is not available: no trace-enabled nimsuggest on the PATH " &
      "(set " & NimsuggestEnvVar & ")"

proc launchFailed(t: NativeNimTracer; message: string) =
  t.vm.fail(ntfNoLanguageServer, message)
  t.process = nil

proc startNimTrace*(t: NativeNimTracer; asked: NimTraceRequest;
                    lines: openArray[string]): bool =
  ## Start tracing `request` — refused with the reason in `t.vm` when the
  ## caret does not offer it, a trace is running, or the tool is missing.
  if not t.vm.begin(asked, lines):
    return false
  # The request as the ViewModel normalised it (the line the compiler
  # matches).
  let request = t.vm.request
  t.output = ""
  t.produced = ""
  t.folder = freshFolder(request)
  t.cache = t.folder & ".nimcache"
  t.startedAt = epochTime()
  let tool = if request.action == ntaEval: findTracingNim()
             else: findNimsuggest()
  if tool.len == 0:
    t.launchFailed(missingToolReason(request.action))
    return false
  try:
    createDir(t.folder)
    if request.action == ntaEval:
      t.produced = t.folder / RecordingFileName
      t.process = startProcess(tool, workingDir = request.path.parentDir,
        args = evalArgumentsOf(request, t.produced,
                               ["--nimcache:" & t.cache]),
        options = {poStdErrToStdOut})
    else:
      t.process = startProcess(tool, workingDir = request.path.parentDir,
        # The trace queries are protocol 3's (`executeNoHooksV3`): without
        # `--v3` nimsuggest reads them and answers nothing.
        args = @["--v3", "--stdin", "--nimcache:" & t.cache, request.path],
        options = {poStdErrToStdOut})
      let input = t.process.inputStream
      input.write(nimsuggestCommandOf(request) & "\nquit\n")
      input.flush()   # `quit` ends the session; the pipe closes with it
  except CatchableError as e:
    t.launchFailed("could not start " & tool & ": " & e.msg)
    return false
  true

when not defined(windows):
  import std/posix

  proc readable(fd: FileHandle): bool =
    ## Whether `fd` has bytes (or its end) to read NOW. Not `osproc.hasData`:
    ## on POSIX that is a `select` with no timeout, which BLOCKS until the
    ## child writes — measured, a poll then froze the window for the whole
    ## compile, and for good when nimsuggest went quiet.
    var p = TPollfd(fd: cint(fd), events: POLLIN)
    posix.poll(addr p, 1, 0) == 1 and (p.revents and (POLLIN or POLLHUP)) != 0

proc drain(t: NativeNimTracer) =
  ## What the child has written so far, WITHOUT BLOCKING: nimsuggest's
  ## `--stdin` prompt is a `> ` with no newline, so a line read would wait
  ## for the answer — through the whole compile — and freeze the window that
  ## polls it. The bytes are read as they are, while the pipe has some.
  when defined(windows):
    try:
      let outp = t.process.outputStream
      while t.process.hasData:   # a non-blocking peek on Windows
        var line = ""
        if not outp.readLine(line):
          break
        t.output.add line & "\n"
    except CatchableError:
      discard
  else:
    var buf: array[4096, char]
    let fd = t.process.outputHandle
    while readable(fd):
      let n = posix.read(fd, addr buf[0], buf.len)
      if n <= 0:
        break
      for i in 0 ..< n:
        t.output.add buf[i]

proc drainToEnd(t: NativeNimTracer) =
  ## The rest of the output, once the child has exited.
  when defined(windows):
    try: t.output.add t.process.outputStream.readAll()
    except CatchableError: discard
  else:
    var buf: array[4096, char]
    let fd = t.process.outputHandle
    while readable(fd):
      let n = posix.read(fd, addr buf[0], buf.len)
      if n <= 0:
        break
      for i in 0 ..< n:
        t.output.add buf[i]

proc errorLineOf(output: string): string =
  ## The compiler's first `Error:` line, else the last line it printed.
  var last = ""
  for raw in output.splitLines():
    let l = raw.strip(chars = Whitespace + {'>'})
    if "Error:" in l:
      return l
    if l.len > 0:
      last = l
  last

proc bundleSources(folder, source: string) =
  ## The traced file's Nim sources, copied into the recording at
  ## `files/<absolute path>` — where `replay-server` reads a recording's
  ## source (`dap_handler`'s files root) — so the new session shows its code.
  ## The compiler's tracer records paths and not text; the file and the Nim
  ## files beside it (what it imports from its own folder) are what a trace
  ## of it steps through.
  let dir = source.parentDir
  for kind, path in walkDir(dir):
    if kind notin {pcFile, pcLinkToFile} or not isNimSource(path):
      continue
    let target = folder / "files" / absolutePath(path).strip(
      leading = true, trailing = false, chars = {'/'})
    try:
      createDir(target.parentDir)
      copyFile(path, target)
    except CatchableError:
      discard

proc settle(t: NativeNimTracer; code: int) =
  let request = t.vm.request
  var produced = t.produced
  if request.action != ntaEval:
    produced = nimsuggestTracePath(t.output)
  if produced.len == 0 or not fileExists(produced):
    let why = errorLineOf(t.output)
    if request.action == ntaEval:
      t.vm.refuse(if why.len > 0: why
                  else: "nim e exited " & $code & " without a recording")
    elif "Error:" in t.output:
      t.vm.refuse(why)
    elif produced.len > 0:
      t.vm.fail(ntfNoRecording, produced & " is not there")
    else:
      t.vm.refuse("No trace result at this position")
    try: removeDir(t.folder)
    except CatchableError: discard
  else:
    let target = t.folder / RecordingFileName
    try:
      if produced != target:
        moveFile(produced, target)
      bundleSources(t.folder, request.path)
      t.vm.succeed(t.folder)
    except CatchableError as e:
      t.vm.fail(ntfNoRecording, "could not keep " & produced & ": " & e.msg)
  try: removeDir(t.cache)
  except CatchableError: discard

proc pollNimTrace*(t: NativeNimTracer): bool =
  ## Whether the trace SETTLED on this poll (once): `t.vm` says how, and on
  ## success `t.vm.tracePath` is the recording's folder to open.
  if t.isNil or t.process.isNil or not t.vm.running:
    return false
  t.drain()
  var code = t.process.peekExitCode()
  if code == -1 and t.vm.request.action != ntaEval and
     nimsuggestAnswered(t.output):
    # The answer is in, and the recording (when there is one) is closed
    # before nimsuggest prints it. The session is ended here rather than
    # left to `quit`, which it does not always honour: measured, about one
    # session in three stays in a futex wait with its stdin reader blocked,
    # after printing the answer.
    t.process.terminate()
    discard t.process.waitForExit(2000)
    code = 0
  if code == -1:
    if t.timeoutMs > 0 and
       (epochTime() - t.startedAt) * 1000.0 > float(t.timeoutMs):
      t.process.terminate()
      discard t.process.waitForExit(2000)
      t.process.close()
      t.process = nil
      t.vm.fail(ntfCompileError, "the compiler did not finish within " &
                $(t.timeoutMs div 1000) & " s")
      return true
    return false
  t.drainToEnd()
  t.process.close()
  t.process = nil
  t.settle(code)
  true
