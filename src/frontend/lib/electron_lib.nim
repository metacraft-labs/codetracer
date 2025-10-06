import
  std/[ jsffi, async, strutils, strformat, os ],
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
    kill*: proc(): bool # TODO: add signal parameter if needed (string | number) Default: "SIGTERM"

  NodeFilesystemPromises* = ref object
    access*: proc(path: cstring, mode: JsObject): Future[JsObject]
    appendFile*: proc(path: cstring, text: cstring): Future[JsObject]
    writeFile*: proc(filename: cstring, content: cstring, options: JsObject): Future[JsObject]
    readFile*: proc(path: cstring, options: JsObject = cstring("utf-8").toJs()): Future[cstring]

  NodeFilesystem* = ref object
    watch*: proc(path: cstring, handler: proc(e: cstring, filenameArg: cstring))
    writeFile*: proc(filename: cstring, content: cstring, callback: proc(err: js))
    writeFileSync*: proc(filename: cstring, content: cstring, options: JsObject = js{})# callback: proc(err: js))
    readFileSync*: proc(filename: cstring, encoding: cstring): cstring
    existsSync*: proc(filename: cstring): bool
    lstatSync*: proc(filename: cstring): js
    # https://nodejs.org/api/fs.html#fsopenpath-flags-mode-callback
    open*: proc(path: cstring, flags: cstring, callback: proc(err: js, fd: int))
    createWriteStream*: proc(path: cstring, options: js): NodeWriteStream
    mkdirSync*: proc(path: cstring, options: js)
    promises*: NodeFilesystemPromises
    constants*: JsObject

  NodeWriteStream* = ref object
    # can be also Buffer, Uint8Array, any, but for now we use cstring
    # https://nodejs.org/api/stream.html#writablewritechunk-encoding-callback
    write*: proc(chunk: cstring, encoding: cstring = cstring"utf8", callback: proc: void = nil): bool

  ServerElectron* = object

  ChildProcessLib* = ref object of JsObject
    spawn*: proc(path: cstring, args: seq[cstring], options: js = js{}): NodeSubProcess

var
  nodeProcess* {.importcpp: "process".}: ElectronOrNodeProcess
  electronProcess* {.importcpp: "process".}: ElectronOrNodeProcess

when defined(ctIndex) or defined(ctTest) or defined(ctInCentralExtensionContext):
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
          resolve(Result[cstring, JsObject].err(cast[JsObject](cstring(&"Exit with code {code}")))))

    var future = newPromise(futureHandler)
    return future

var nodePath*: NodePath

when defined(ctRenderer):
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
  let currentPath* = if not jsDirname.isNil: ($jsDirname).rsplit("/", 3)[0] & "/" else: ""

let chomedriverExe* = linksPath & "/bin/chromedriver"

import misc_lib

var helpers* {.exportc: "helpers".}: js
if inElectron:
  helpers = require("./helpers")