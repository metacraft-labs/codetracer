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
