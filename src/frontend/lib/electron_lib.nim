when defined(ctWeb):
  {.error: "lib/electron_lib.nim is Electron's binding layer: it loads the node " &
           "filesystem, child-process and path modules, plus the helpers shim. " &
           "It is ABSENT from a web build because there is no Electron in a " &
           "browser tab, not because it has not been migrated yet: this module " &
           "exists TO wrap the host, so putting it behind the platform facade " &
           "would only move the same node calls one layer down. A web build that " &
           "needs one of its capabilities should ask `ctPlatform()` for that " &
           "capability instead. If you reached this error, something in the web " &
           "build's import graph still depends on Electron — find that edge and " &
           "cut it; do not relax this guard." .}

import
  std/[ jsffi, asyncjs, strutils, strformat, os ],
  results,
  jslib,
  ../../common/[ ct_logging, paths ]

type
  ElectronApp* {.importc.} = ref object of JsObject
    quit*: proc(code: int): void

  ElectronOrNodeProcess* {.importc.} = ref object of JsObject
    platform*: cstring
    argv*: seq[cstring]
    env*: JsAssoc[cstring, cstring]
    cwd*: proc: cstring

  NodeSubProcess* = ref object
    pid*: int
    stdout*: JsObject
    stderr*: JsObject
    # TODO: add signal parameter if needed
    # (string | number) Default: "SIGTERM"
    kill*: proc(): bool

  NodeFilesystemPromises* = ref object
    access*: proc(path: cstring, mode: JsObject): Future[JsObject]
    appendFile*: proc(path: cstring, text: cstring): Future[JsObject]
    writeFile*: proc(
      filename: cstring,
      content: cstring,
      options: JsObject): Future[JsObject]
    readFile*: proc(
      path: cstring,
      options: JsObject =
        cstring("utf-8").toJs()
    ): Future[cstring]

  NodeFilesystem* = ref object
    watch*: proc(
      path: cstring,
      handler: proc(
        e: cstring,
        filenameArg: cstring))
    # ``fs.watchFile`` uses ``stat(2)`` polling rather than inotify, so it
    # is immune to ``ENOSPC`` (the system-wide inotify watch budget) and to
    # platforms/filesystems where ``fs.watch`` silently never fires (e.g.
    # certain tmpfs/overlayfs/NFS mounts).  We use it as a fallback when
    # ``fs.watch`` is unavailable.
    # https://nodejs.org/api/fs.html#fswatchfilefilename-options-listener
    watchFile*: proc(
      path: cstring,
      options: JsObject,
      handler: proc(curr: js, prev: js))
    unwatchFile*: proc(path: cstring)
    writeFile*: proc(
      filename: cstring,
      content: cstring,
      callback: proc(err: js))
    writeFileSync*: proc(
      filename: cstring,
      content: cstring,
      options: JsObject = js{})
    readFileSync*: proc(filename: cstring, encoding: cstring): cstring
    existsSync*: proc(filename: cstring): bool
    lstatSync*: proc(filename: cstring): js
    # `statSync` FOLLOWS symlinks, which `lstatSync` does not.  That is the
    # difference between "is this a directory?" as `spawn` asks it — it
    # `chdir`s, so a symlink to a directory is a directory — and as `lstat`
    # answers it.  A project checked out behind a symlink is ordinary enough
    # that getting this wrong would re-create issue #747's failure in a new
    # place.  https://nodejs.org/api/fs.html#fsstatsyncpath-options
    statSync*: proc(filename: cstring): js
    # https://nodejs.org/api/fs.html#fsopenpath-flags-mode-callback
    open*: proc(
      path: cstring,
      flags: cstring,
      callback: proc(err: js, fd: int))
    createWriteStream*: proc(
      path: cstring,
      options: js): NodeWriteStream
    mkdirSync*: proc(path: cstring, options: js)
    readdirSync*: proc(path: cstring): seq[cstring]
    promises*: NodeFilesystemPromises
    constants*: JsObject

  NodeWriteStream* = ref object
    # can be also Buffer, Uint8Array, any, but for now we use cstring
    # https://nodejs.org/api/stream.html#writablewritechunk-encoding-callback
    write*: proc(
      chunk: cstring,
      encoding: cstring = cstring"utf8",
      callback: proc: void = nil): bool

  ServerElectron* = object

  ChildProcessLib* = ref object of JsObject
    spawn*: proc(
      path: cstring,
      args: seq[cstring],
      options: js = js{}): NodeSubProcess

var
  nodeProcess* {.importcpp: "process".}: ElectronOrNodeProcess
  electronProcess* {.importcpp: "process".}: ElectronOrNodeProcess

when defined(ctIndex) or defined(ctTest) or
    defined(ctInCentralExtensionContext):
  let fs* = cast[NodeFilesystem](require("fs"))
  let fsPromises* = fs.promises
  var nodeStartProcess* = cast[(ChildProcessLib)](require("child_process"))

  proc setupLdLibraryPath* =
    # originally in src/tester/tester.nim
    # adapted for javascript backend, as in tsc-ui-tests/lib/ct_helpers.ts
    # for more info, please read the comment for `setupLdLibraryPath` there
    nodeProcess.env["LD_LIBRARY_PATH"] = nodeProcess.env["CT_LD_LIBRARY_PATH"]

  proc readProcessOutput*(
      path: cstring,
      args: seq[cstring],
      options: JsObject = js{}): Future[Result[cstring, JsObject]] =

    var raw = cstring""
    let futureHandler = proc(resolve: proc(res: Result[cstring, JsObject])) =
      debugPrint "(readProcessOutput:)"
      debugPrint "RUN PROGRAM: ", path
      debugPrint "WITH ARGS: ", args
      # debugPrint "OPTIONS: ", $(options.to(cstring))

      setupLdLibraryPath()

      # Prevent spawned console apps from creating
      # visible console windows on Windows.
      options.windowsHide = true
      let process = nodeStartProcess.spawn(path, args, options)

      process.stdout.setEncoding(cstring"utf8")

      process.toJs.on("spawn", proc() =
        debugPrint "spawn ok")

      process.toJs.on("error", proc(error: JsObject) =
        resolve(Result[cstring, JsObject].err(error)))

      process.stdout.toJs.on("data", proc(data: cstring) =
        raw.add(data))

      process.toJs.on("exit", proc(code: int, signal: cstring) =
        if code == 0:
          resolve(Result[cstring, JsObject].ok(raw))
        else:
          let msg = cstring(&"Exit with code {code}")
          resolve(Result[cstring, JsObject].err(
            cast[JsObject](msg))))

    var future = newPromise(futureHandler)
    return future

  proc readProcessOutputAnyExit*(
      path: cstring,
      args: seq[cstring],
      options: JsObject = js{}): Future[cstring] =
    ## Like ``readProcessOutput`` but always resolves with whatever stdout was
    ## captured, regardless of the process exit code. Use when the caller needs
    ## output lines (e.g. "Saved trace to <path>") even from a process that exits
    ## with a non-zero code (e.g. a recorder that partially succeeds).
    var raw = cstring""
    let futureHandler = proc(resolve: proc(res: cstring)) =
      setupLdLibraryPath()
      options.windowsHide = true
      let process = nodeStartProcess.spawn(path, args, options)
      process.stdout.setEncoding(cstring"utf8")
      process.stdout.toJs.on("data", proc(data: cstring) =
        raw.add(data))
      process.toJs.on("error", proc(error: JsObject) =
        resolve(raw))
      process.toJs.on("exit", proc(code: int, signal: cstring) =
        resolve(raw))
    return newPromise(futureHandler)

  type
    ProcessOutcome* = object
      ## Everything a finished child process said, however it finished.
      exitCode*: int
        ## The exit status, or -1 when the process never reached one: it
        ## could not be started (`spawnError`), or a signal ended it
        ## (`signal`).
      signal*: cstring
        ## The signal that ended it, or "".
      stdout*: cstring
      stderr*: cstring
      spawnError*: cstring
        ## Why the process could not be started, or "" when it was.

  proc nodeExitCode(code: JsObject): int {.importjs:
    "(function(c){ return (c === null || c === undefined) ? -1 : c; })(#)".}
    ## Node passes `null` for `code` when a signal ended the child.

  proc nodeErrorText(error: JsObject): cstring {.importjs:
    "(function(e){ return (e && e.message) ? String(e.message) : String(e); })(#)".}

  proc readProcessOutcome*(
      path: cstring,
      args: seq[cstring],
      options: JsObject = js{}): Future[ProcessOutcome] =
    ## Run a child to completion and resolve with its exit status AND both of
    ## its streams. NEVER REJECTS: a child that could not be started resolves
    ## with `spawnError` set, so a caller has one value to branch on and no
    ## path out of an `await` that escapes it.
    ##
    ## The two helpers above answer narrower questions and each drops what
    ## this one is for: `readProcessOutput` turns every non-zero exit into an
    ## error carrying only `Exit with code <n>` (no stdout, no stderr), and
    ## `readProcessOutputAnyExit` keeps stdout but loses the exit status. A
    ## caller that must tell "the tests failed" (exit 1) from "no test ran"
    ## (exit 2) from "the runner never started", and quote the runner's own
    ## stderr for each, needs all of it.
    ##
    ## Resolves on `close`, not `exit`: Node emits `exit` before the child's
    ## stdio streams are drained, so output read at `exit` can be truncated.
    ## https://nodejs.org/api/child_process.html#event-close
    var outcome = ProcessOutcome(exitCode: -1, signal: cstring"",
                                 stdout: cstring"", stderr: cstring"",
                                 spawnError: cstring"")
    let futureHandler = proc(resolve: proc(res: ProcessOutcome)) =
      var settled = false
      proc finish() =
        if not settled:
          settled = true
          resolve(outcome)
      try:
        setupLdLibraryPath()
        options.windowsHide = true
        let process = nodeStartProcess.spawn(path, args, options)
        process.stdout.setEncoding(cstring"utf8")
        process.stderr.setEncoding(cstring"utf8")
        process.stdout.toJs.on("data", proc(data: cstring) =
          outcome.stdout.add(data))
        process.stderr.toJs.on("data", proc(data: cstring) =
          outcome.stderr.add(data))
        process.toJs.on("error", proc(error: JsObject) =
          # `error` without a following `close` is how Node reports a binary
          # that could not be spawned; with one, `close` carries the status.
          outcome.spawnError = nodeErrorText(error)
          finish())
        process.toJs.on("close", proc(code: JsObject, signal: JsObject) =
          outcome.exitCode = nodeExitCode(code)
          if not signal.isNil and not signal.isUndefined:
            outcome.signal = signal.to(cstring)
          finish())
      except:
        # `spawn` itself can throw synchronously (an invalid argument); that
        # is a child that could not be started, not an exception to escape.
        outcome.spawnError = cstring(getCurrentExceptionMsg())
        finish()
    return newPromise(futureHandler)

  proc readProcessOutputStreaming*(
      path: cstring,
      args: seq[cstring],
      onLine: proc(line: cstring),
      options: JsObject = js{}): Future[Result[void, JsObject]] =
    ## Like ``readProcessOutput`` but calls ``onLine`` for each newline-
    ## delimited chunk from stdout instead of buffering everything.
    ## Used by the install flow to stream JSON progress events.

    let futureHandler = proc(resolve: proc(res: Result[void, JsObject])) =
      debugPrint "(readProcessOutputStreaming:)"
      debugPrint "RUN PROGRAM: ", path
      debugPrint "WITH ARGS: ", args

      setupLdLibraryPath()

      options.windowsHide = true
      let process = nodeStartProcess.spawn(path, args, options)

      process.stdout.setEncoding(cstring"utf8")

      # Buffer for incomplete lines (data events may split mid-line).
      var lineBuf = ""

      process.toJs.on("spawn", proc() =
        debugPrint "spawn ok")

      process.toJs.on("error", proc(error: JsObject) =
        resolve(Result[void, JsObject].err(error)))

      process.stdout.toJs.on("data", proc(data: cstring) =
        lineBuf &= $data
        var lines = lineBuf.split('\n')
        # Keep the last (possibly incomplete) segment in the buffer.
        lineBuf = lines[^1]
        for i in 0 ..< lines.len - 1:
          if lines[i].len > 0:
            onLine(cstring(lines[i])))

      process.toJs.on("exit", proc(code: int, signal: cstring) =
        # Flush any remaining buffered content.
        if lineBuf.len > 0:
          onLine(cstring(lineBuf))
        if code == 0:
          resolve(Result[void, JsObject].ok())
        else:
          let msg = cstring(&"Exit with code {code}")
          resolve(Result[void, JsObject].err(
            cast[JsObject](msg))))

    var future = newPromise(futureHandler)
    return future

var nodePath*: NodePath

when defined(ctRenderer) and not defined(ctInCentralExtensionContext):
  # In a renderer / webview the host HTML defines the `inElectron` and
  # `loadScripts` globals via an inline <script> before the bundle loads,
  # so we import them.  The VS Code central extension context
  # (`-d:ctInCentralExtensionContext`, used for ct_vscode.js) has no HTML
  # host — importing the globals there yields a `ReferenceError:
  # inElectron is not defined` that aborts extension activation — so it
  # falls through to the plain-`var` branch below.
  var inElectron* {.importc.}: bool
  var loadScripts* {.importc.}: bool
else:
  var inElectron*: bool = false
  var loadScripts*: bool = false

if inElectron:
  nodePath = cast[NodePath](require("path"))
let basedirText* = currentSourcePath.rsplit("/", 1)[0]
if not inElectron:
  when defined(ctRenderer):
    jsDirname = cstring""
  else:
    nodePath = cast[NodePath](require("path"))
# dump jsDirname
when not defined(ctTest):
  let basedir* = cstring(basedirText)
  let currentPath* = if not jsDirname.isNil: $jsDirname & "/" else: ""
else:
  let basedir* = cstring(basedirText)
  let currentPath* =
    if not jsDirname.isNil:
      ($jsDirname).rsplit("/", 3)[0] & "/"
    else: ""

let chomedriverExe* = codetracerPrefix & "/bin/chromedriver"

import misc_lib

var helpers* {.exportc: "helpers".}: js
if inElectron:
  helpers = require("./helpers")
