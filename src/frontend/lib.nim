## this module defines some helpers and types for js
## still probably more stuff can be defines as there are still more casts than needed

when not defined(js):
  {.error "Electron is only available for javascript"}

import
  macros, dom, jsffi, typetraits, strutils, strformat, os, async,
  kdom, sugar, jsconsole, results, task_and_event, paths, sequtils
import ../common/ct_logging

type
  PyCommand* = object of RootEffect

  ExitError* = object of RootEffect

  NormalError* = object of RootEffect

  EventTarget* = ref object
    value*: cstring

  ElectronApp* {.importc.} = ref object of JsObject
    quit*: proc(code: int): void

  ElectronOrNodeProcess* {.importc.} = ref object of JsObject
    platform*: cstring
    argv*: seq[cstring]
    env*: JsAssoc[cstring, cstring]
    cwd*: proc: cstring

  Electron* = ref object of JsObject
    app*: ElectronApp
    BrowserWindow*: BrowserWindow

  NodeSubProcess* = ref object
    pid*: int
    stdout*: JsObject
    stderr*: JsObject
    kill*: proc(): bool # TODO: add signal parameter if needed (string | number) Default: "SIGTERM"

  BrowserWindow* {.importcpp.} = ref object of JsObject
    loadURL*: proc(url: cstring): void

    width*, height*, x*, y*: int

    useContentSize*, center*, resizable*, focusable*, thickFrame*: bool

    parent*: ref BrowserWindow

    backgroundColor*: cstring

  # NodeFS* = ref object of js
    # readFile*: proc(filename: cstring, encoding: cstring, handler: proc(err: js, file: js): void): void

  Screen* = ref object of js
    height*: int
    width*: int

  JSONObj* = ref object of js
    # probably not really -1
    stringify*: proc(
      source: js,
      replacer: proc(key: cstring, value: js): js = nil,
      level: js = jsUndefined): cstring {.noSideEffect, tags: [].}
    parse*: proc(s: cstring): js {.noSideEffect, tags: [].}

  VoidJS* = ref object of js

  DateJS* = ref object of js
    now*: proc: int

  UInt16Array* {.importc.} = ref object

  UInt32Array* {.importc.} = ref object

  ArrayBuffer* {.importc.} = ref object
    byteLength*: uint

  DataView*[T] {.importc.} = ref object
    length*: uint

  JsSet*[T] {.importc.} = JsAssoc[T, bool]

  FsStats* {.importc.} = ref object
    isFile*: proc(): bool

  FS* {.importc.} = ref object
    readFile*: proc(s: cstring, encoding: cstring, cb: proc(err: js, data: cstring))
    read*: proc(fd: uint, buffer: Buffer, offset: uint, length: uint, position: uint, cb: proc(err: js, bytesRead: uint, buffer: Buffer))
    write*: proc(fd: uint, buffer: Buffer, offset: uint, length: uint, position: uint, cb: proc(err: js, bytesWritten: uint, buffer: Buffer))
    open*: proc(path: cstring, flags: cstring, cb: proc(err: js, fd: uint))
    close*: proc(fd: uint, cb: proc(err: js))
    stat*: proc(filename: cstring, cb: proc(err: js, stats: Stats))
    writeFile*: proc(s: cstring, data: cstring, cb: proc(err: js))
    readFileSync*: proc(s: cstring, encoding: cstring): cstring
    writeFileSync*: proc(s: cstring, data: cstring)
    existsSync*: proc(s: cstring): bool
    appendFileSync*: proc(s: cstring, data: cstring)
    lstatSync*: proc(s: cstring): FsStats

  Chalk* {.importc.} = ref object
    yellow*: proc(s: cstring): cstring
    blue*: proc(s: cstring): cstring
    red*: proc(s: cstring): cstring
    green*: proc(s: cstring): cstring
    keyword*: proc(color: cstring): proc(s: cstring): cstring
    bold*: proc(s: cstring): cstring
    underline*: proc(s: cstring): cstring

  Buffer* {.importc.} = ref object
    length*: uint
    slice*: proc(start: uint, finish: uint): Buffer
    readUInt8*: proc(start: uint): uint8
    readUInt16LE*: proc(start: uint): uint16
    readUInt32LE*: proc(start: uint): uint32
    readInt16LE*: proc(start: uint): int16
    readInt32LE*: proc(start: uint): int32
    readIntLE*: proc(start: uint, count: uint): int
    readIntBE*: proc(start: uint, count: uint): int
    writeUInt16LE*: proc(value: uint16, start: uint)
    writeUIntLE*: proc(value: uint, start: uint, count: uint)
    toString*: proc(a: cstring): cstring

  Stats* {.importc.} = ref object
    blocks*: uint
    size*: uint

  DB* {.importc.} = ref object
    run*: proc(code: cstring)
    serialize*: proc(handler: proc: void)
    prepare*: proc(code: cstring): Stmt
    # each*: proc[T](code: cstring, handler: proc(err: js, row: T): void)
    # all*: proc[T](code: cstring, handler: proc(err: js, rows: seq[T]): void)

  Stmt* {.importc.} = ref object
    finalize*: proc: void
    run*: proc(args: varargs[cstring])

  D3* {.importc.} = ref object of js

  JSMath* {.importc.} = ref object
    random*: proc(max: int): float
    floor*: proc(f: float): int
    ceil*: proc(f: float): int
    sqrt*: proc(f: float): float
    round*: proc(f: float): int

  Yaml* {.importc.} = ref object
    load*: proc(a: cstring): js

  Monaco* = ref object of js
    editor*: MonacoEditorLib

  MonacoEditorLib* = ref object
    create*: proc(element: dom.Element, options: MonacoEditorOptions): MonacoEditor
    # based on monaco signature
    defineTheme*: proc(themeName: cstring, themeData: js)

  MonacoEditorOptions* = ref object
    value*:                  cstring
    language*:               cstring
    automaticLayout*:        bool
    theme*:                  cstring
    readOnly*:               bool
    lineNumbers*:            proc(line: int): cstring
    fontSize*:               int
    fontFamily*:             cstring
    contextmenu*:            bool
    minimap*:                JsObject
    find*:                   JsObject
    scrollbar*:              JsObject
    lineDecorationsWidth*:   int
    renderLineHighlight*:    cstring
    glyphMargin*:            bool
    folding*:                bool
    scrollBeyondLastColumn*: int
    overflowWidgetsDomNode*: JsObject
    fixedOverflowWidgets*:   bool
    fastScrollSensitivity*:  int
    scrollBeyondLastLine*:   bool
    smoothScrolling*:        bool
    mouseWheelScrollSensitivity*: int

  MonacoScrollType* = enum Smooth, Immediate

  MonacoContent* = enum EXACT, ABOVE, BELOW

  DeltaDecoration* = ref object
    `range`*:         MonacoRange
    options*:         js

  Fuzzysort* = object
    goAsync*:   proc(query: cstring, data: seq[js], options: FuzzyOptions): Future[seq[FuzzyResult]]
    go*:   proc(query: cstring, data: seq[js], options: FuzzyOptions): seq[FuzzyResult]
    prepare*:   proc(path: cstring): js
    highlight*: proc(results: FuzzyResult, open, close: cstring): cstring

  FuzzyResult* = object
    score*:     int
    target*:    cstring
    obj*:       js
    `"_indexes"`*: seq[int]

  FuzzyOptions* = object
    limit*: int
    allowTypo*: bool
    threshold*: int
    all*: bool

  MonacoTextModel* = object
    getLineMaxColumn*:     proc(line: int): int
    getLineFirstNonWhitespaceColumn*: proc(line: int): int
    getLineContent*:       proc(line: int): cstring
    findMatches*:          proc(searchString: cstring,
                                searchOnlyEditableRange: bool,
                                isRegex: bool,
                                matchCase: bool,
                                captureMatches: bool): js
    applyEdits*:           proc(operations: seq[js]): void
    getValueInRange*:      proc(`range`: MonacoRange, endOfLinePreference: int = 0): cstring

  MonacoEditorLayoutInfo* = ref object
    contentLeft*: int
    contentWidth*: int
    height*: int
    minimapWidth*: int
    minimapLeft*: int
    width*: int

  MonacoEditorConfig* = ref object
    layoutInfo*: MonacoEditorLayoutInfo
    lineHeight*: int

  MonacoPossibleOptionConfig* = ref object
    minimap*: MonacoMinimapConfig

    # copied from MonacoEditorLayoutConfig
    contentLeft*: int
    contentWidth*: int
    height*: int
    width*: int
    lineHeight*: int
    fontSize*: int
    decorationsLeft*: int

  MonacoMinimapConfig* = ref object
    minimapWidth*: int
    minimapLeft*: int

  MonacoSelection* = ref object
    startColumn*:     int
    endColumn*:       int
    startLineNumber*: int
    endLineNumber*:   int

  MonacoRange* = ref object
    startColumn*:     int
    endColumn*:       int
    startLineNumber*: int
    endLineNumber*:   int

  MonacoViewModel* = ref object
    hasFocus*:        bool

  MonacoEditOperation* = ref object
    forceMoveMarkers*: bool
    `range`*:          MonacoRange
    text*:             cstring

  MonacoEditor* = ref object
    config*:               MonacoEditorConfig
    getValue*:             proc: cstring
    focus*:                proc()
    layout*:               proc(layout: js)
    setValue*:             proc(code: cstring)
    deltaDecorations*:     proc(first: seq[cstring], second: seq[DeltaDecoration]): seq[cstring]
    addCommand*:           proc(keyCode: int, f: (proc: void))
    revealLine*:           proc(line: int, scrollType: MonacoScrollType = Smooth)
    addAction*:            proc(action: js)
    addContentWidget*:     proc(widget: js)
    addOverlayWidget*:     proc(widget: js)
    domElement*:           kdom.Node
    changeViewZones*:      proc(handler: proc(view: js))
    revealLineInCenter*:   proc(line: int, scrollType: MonacoScrollType = Smooth)
    setPosition*:          proc(position: MonacoPosition)
    revealLineInCenterIfOutsideViewport*: proc(line: int, scrollType: MonacoScrollType = Smooth)
    decorations*:          seq[cstring]
    statusWidget*:         js
    removeContentWidget*:  proc(widget: js)
    # getModel*:             proc: js
    onMouseDown*:          proc(handler: proc(ev: js))
    onMouseWheel*:         proc(handler: proc(ev: js))
    onContextMenu*:        proc(handler: proc(ev: js))
    onMouseMove*:          proc(handler: proc(ev: JsObject))
    onDidScrollChange*:    proc(handler: proc(ev: js))
    getAction*:            proc(a: cstring): js
    onKeyDown*:            js #proc(e: js)
    onDidChangeModelContent*:    proc(handler: proc: void): void
    hasTextFocus*:         proc: bool
    updateOptions*:        proc(options: MonacoEditorOptions)
    dispose*:              proc: void
    # cursor*:               MonacoCursor
    getPosition*:          proc: MonacoPosition {.noSideEffect.}
    getOptions*:           proc: JsObject
    getOption*:            proc(option: int): MonacoPossibleOptionConfig
    getVisibleRanges*:     proc: js
    getOffsetForColumn*:   proc(line: int, column: int): int
    getModel*:             proc: MonacoTextModel
    getSelection*:         proc: MonacoSelection
    trigger*:              proc(source: cstring, handlerId: cstring)
    viewModel*:            MonacoViewModel
    executeEdits*:         proc(source: cstring, edits: seq[MonacoEditOperation]): void


  MonacoCursor* = ref object
    getPosition*:          proc: MonacoPosition {.noSideEffect.}

  MonacoPosition* = ref object
    lineNumber*:           int
    column*:               int

  WebSocket* = ref object
    on*: proc(name: cstring, code: (proc(message: js): void))

  WebSocketServer* = ref object
    on*: proc(name: cstring, code: (proc(ws: WebSocket)))

  IPC* {.importc.} = ref object
    send*: proc(label: cstring, arg: js): void

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


  MMap* = ref object
    map*:  proc(size: int, a: int, b: int, c: int, d: int): Buffer
    PROT_READ*: int
    MAP_SHARED*: int

  MonacoLineStyle* = object
    line*: int
    class*: cstring
    inlineClass*: cstring

  ChildProcessLib* = ref object of JsObject
    spawn*: proc(path: cstring, args: seq[cstring], options: js = js{}): NodeSubProcess

  ResizeObserver* {.importc.} = ref object

  MutationObserver* {.importc.} = ref object

  MutationRecord* {.importc.} = ref object
    `type`*: cstring

  HTMLBoundingRect* = object
    top*:            float
    right*:          float
    bottom*:         float
    left*:           float
    width*:          float
    height*:         float

const
  # monaco option const
  # https://microsoft.github.io/monaco-editor/typedoc/enums/editor.EditorOption.html#layoutInfo
  LAYOUT_INFO* = 144
  # https://microsoft.github.io/monaco-editor/typedoc/enums/editor.EditorOption.html#lineHeight
  LINE_HEIGHT* = 67

proc join*(s: seq[cstring], separator: cstring): cstring {.importcpp: "#.join(#)".}

proc jsAsFunction*[T](handler: js): T {.importcpp: "#".}

var nodeProcess* {.importcpp: "process".}: ElectronOrNodeProcess

# proc getOptionsAsConfig*(editor: MonacoEditor)
when defined(ctIndex) or defined(ctTest) or defined(ctInCentralExtensionContext):
  let fs* = cast[NodeFilesystem](require("fs"))
  let fsPromises* = fs.promises

  proc pathExists*(path: cstring): Future[bool] {.async.} =
    var hasAccess: JsObject
    try:
      hasAccess = await fsPromises.access(path, fs.constants.F_OK)
    except:
      return false
    return hasAccess == jsUndefined

  var nodeStartProcess* = cast[(ChildProcessLib)](require("child_process"))

  let util = require("util")

  let execWithPromise* = jsAsFunction[proc(command: cstring): Future[JsObject]](util.promisify(nodeStartProcess.exec))

# let p = await startProcess()
# send p.pid to frontend
# # await waitForExit(p)

  # let child_process* = cast[(ChildProcessLib)](require("child_process"))

  proc setupLdLibraryPath* =
    # originally in src/tester/tester.nim
    # adapted for javascript backend, as in tsc-ui-tests/lib/ct_helpers.ts
    # for more info, please read the comment for `setupLdLibraryPath` there
    nodeProcess.env["LD_LIBRARY_PATH"] = nodeProcess.env["CT_LD_LIBRARY_PATH"]

  proc runUploadWithStreaming*(
      path: cstring,
      args: seq[cstring],
      onData: proc(data: string),
      onDone: proc(success: bool, result: string)
  ) =
    setupLdLibraryPath()

    let process = nodeStartProcess.spawn(path, args)
    process.stdout.setEncoding("utf8")

    var fullOutput = ""

    process.stdout.toJs.on("data", proc(data: cstring) =
      let str = $data
      fullOutput.add(str)
      onData(str)
    )

    process.stderr.toJs.on("data", proc(err: cstring) =
      echo "[stderr]: ", err
      fullOutput.add($err)
    )

    process.toJs.on("exit", proc(code: int, _: cstring) =
      onDone(code == 0, fullOutput)
    )

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

  proc readCTOutput*(
    codetracerExe: cstring,
    args: seq[cstring],
    isNixOS: bool = false,
    options: JsObject = js{}
  ): Future[Result[cstring, JsObject]] =
    if not isNixOS or not ($codetracerExe).endsWith(".AppImage"):
      readProcessOutput(
        codetracerExe,
        args,
        options
      )
    else:
      readProcessOutput(
        "appimage-run",
        @[codetracerExe].concat(args),
        options
      )

  proc startProcess*(
    path: cstring,
    args: seq[cstring],
    options: JsObject = js{"stdio": cstring"ignore"}): Future[Result[NodeSubProcess, JsObject]] =
    # important to ignore stderr, as otherwise too much of it can lead to
    # the spawned process hanging: this is a bugfix for such a situation

    let futureHandler = proc(resolve: proc(res: Result[NodeSubProcess, JsObject])) =
      # debugPrint "RUN PROGRAM: ", path
      # debugPrint "WITH ARGS: ", args
      # debugPrint "OPTIONS: ", $(options.to(cstring))

      let process = nodeStartProcess.spawn(path, args, options)

      process.toJs.on("spawn", proc() =
        resolve(Result[NodeSubProcess, JsObject].ok(process)))

      process.toJs.on("error", proc(error: JsObject) =
        resolve(Result[NodeSubProcess, JsObject].err(error)))

    var future = newPromise(futureHandler)
    return future

  proc waitProcessResult*(process: NodeSubProcess): Future[JsObject] =
    let futureHandler = proc(resolve: proc(res: JsObject)) =

      process.toJs.on("exit", proc(code: int, signal: cstring) =
        if code == 0:
          resolve(nil)
        else:
          resolve(cstring(&"Exit with code {code}").toJs))

    var future = newPromise(futureHandler)
    return future

  proc runProcess*(path: cstring, args: seq[cstring]): Future[JsObject] {.async.} =

    let processStart = await startProcess(path, args)

    if not processStart.isOk:
      return processStart.error

    return await waitProcessResult(processStart.value)

var
  jstypeof* {.importcpp: "typeof(#)".}: proc(s: js): cstring
  electronProcess* {.importcpp: "process".}: ElectronOrNodeProcess
  jsthis* {.importcpp: "this".}: js
  requireModule* {.importcpp: "require".}: js
  windowSetTimeout* {.importcpp: "setTimeout(#, #)".}: proc (f: (proc: void), i: int): int
  windowClearTimeout* {.importcpp: "clearTimeout(#)".}: proc (f: int): void
  windowSetInterval* {.importcpp: "setInterval(#, #)".}: proc (f: (proc: void), i: int): int
  windowClearInterval* {.importcpp: "clearInterval(#)".}: proc (f: int): void
  Object* {.importc.}: js
  RegExp* {.importc.}: proc (source: cstring, flag: cstring): js
  # jsconsole* {.importcpp: "console".}: js
  screen* {.importc.}: Screen
  null* {.importc.}: js
  undefined* {.importc.}: js
  JSON* {.importc.}: JSONObj
  Date* {.importc.}: DateJS
  Math* {.importc.}: JSMath
  vex* {.importc.}: js
  jsNaN* {. importcpp: "NaN" .}: int
  jsobj* {.importcpp: "Object".}: js
  jsdebugger* {.importcpp: "debugger".}: js
  requireCall* {.importcpp: "require(#)(#, #)".}: proc(a: cstring, b: kdom.Window, c: js): js
  fetch* {.importc.}: proc(a: cstring): js

proc createResizeObserver*(handler: proc) : ResizeObserver {.importjs:"new ResizeObserver(#)".}

proc createMutationObserver*(handler: proc) : MutationObserver {.importjs:"new MutationObserver(#)".}

proc observe*(observer: ResizeObserver, entry: kdom.Node) {.importjs:"#.observe(#)".}

proc disconnect*(observer: ResizeObserver) {.importjs:"#.disconnect()".}

proc observe*(observer: MutationObserver, domElement: kdom.Element, options: js) {.importjs:"#.observe(#,#)".}

proc disconnect*(observer: MutationObserver) {.importjs:"#.disconnect()".}

proc on*[T](subProcess: NodeSubProcess, eventKind: cstring, handler: proc(arg: T): void) {.importc.}

proc initJsSet*[T]: JsSet[T] =
  JsAssoc[T, bool]{}

proc incl*[T](aSet: JsSet[T], value: T) =
  aSet[value] = true

proc excl*[T](aSet: JsSet[T], value: T) =
  discard jsDelete(aSet[value])

proc contains*[T](aSet: JsSet[T], value: T): bool =
  aSet.hasKey(value)

var nodePath*: NodePath

when defined(ctRenderer):
  var inElectron* {.importc.}: bool
  var loadScripts* {.importc.}: bool
else:
  var inElectron*: bool = false
  var loadScripts*: bool = false

proc `$`*(a: js): string {.importcpp: "cstrToNimstr(JSON.stringify(#))".}

proc jsGetEnv*(a: cstring): cstring {.importcpp: "process.env[#]".}


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

# dump currentPath
# var codetracerInstallDir*: string
# if "build-debug" notin currentPath:
#   codetracerInstallDir = currentPath.rsplit("/", 3)[0] & "/"
# else:
#   if getEnv("CODETRACER_IN_TEST", "") == "1":
#     codetracerInstallDir = currentPath.rsplit("/", 3)[0] & "/"
#   else:
#     codetracerInstallDir = currentPath.rsplit("/", 4)[0] & "/"

# when defined(ctTest):
#   codetracerInstallDir = currentPath #.rsplit("/", 1)[0] & "/"

debugPrint "lib.nim: codetracerInstallDir ", codetracerInstallDir

# let codetracerExeDir* = if "build-debug" notin basedirText: basedirText & "/build-debug/" else: basedirText & "/../"
# let linksPath* = codetracerExeDir

let pluginsDir* = codetracerExeDir & "/plugins/"
let chomedriverExe* = linksPath & "/bin/chromedriver"

when defined(ctRenderer):
  proc tippy*(query: cstring, options: JsAssoc[cstring, JsObject]): JsObject {.importc.}

var yaml*: Yaml
if inElectron:
  yaml = cast[Yaml](require("js-yaml"))
else:
  when not defined(ctRenderer) and not defined(ctInExtension):
    yaml = cast[Yaml](require("js-yaml"))

# let mmap* = cast[MMap](require("mmap-io"))
var mmap*: MMap
var helpers* {.exportc: "helpers".}: js
if inElectron:
  helpers = require("./helpers")

proc `$`*(u: uint): string =
  $(u.int)


type
  DistinctInt = concept a
      a is distinct
      a.int


proc newMessage*(cap: js, buffer: Buffer, b: bool): js {.importcpp: "new #.Message(#, #)".}
proc toJsKey*[T: DistinctInt](text: cstring, t: type T): T {.importcpp: "parseInt(#)".}

template safeString*(a: cstring): string =
  if not a.isNone:
    $a
  else:
    ""

template componentContainerClass*(class: string = ""): cstring =
  cstring("component-container " & class)

var d3* {.importc.}: D3
var Mousetrap* {.importc.}: js

proc isNaN*[T](n: T): bool {.importcpp: "isNaN(#)", noSideEffect, tags: [].}

proc isNone*[T](a: T): bool {.importcpp: "(# == null)", noSideEffect, tags: [].}

proc newSqlite*(sqlite: js, name: cstring): js {.importcpp: "(new #(#))".}

proc bufferconcat*(buffers: seq[Buffer]): Buffer {.importcpp: "(Buffer.concat(#))".}

proc functionAsJS*[T](handler: T): js {.importcpp: "#".}

proc objectAssign*(a: js, b: js) {.importcpp: "Object.assign(#, #)".}

proc keysOf*[A, B](a: JsAssoc[A, B]): seq[cstring] {. importcpp: "(Object.keys(#))" .}

func hasKey*[A, B](a: JsAssoc[A, B], key: A): bool {. importcpp: "(#[#] != undefined)", noSideEffect.}

proc merge*[A, B](a: JsAssoc[A, B], b: JsAssoc[A, B]) {. importcpp: "Object.assign(#, #)".}

proc newMonacoRange*(startLineNumber: int, startColumn: int, endLineNumber: int, endColumn: int): MonacoRange {.importcpp: "new monaco.Range(#, #, #, #)".}

proc newClusterize*(b: js): js {.importcpp: "new Clusterize(#)".}

proc jsSpawn*(childProcess: js, name: cstring, cmd: seq[cstring], errorHandler: (proc: void)): js {.raises: [Exception], tags: [RootEffect].} =
  result = childProcess.spawn(name, cmd)
  result.on(cstring"close") do (code: int):
    if code != 0:
      errorHandler()

when defined(ctIndex):
  # proc startProcess*(name: cstring, cmd: seq[cstring]): js =
  #   result = nodeStartProcess.spawn(name, cmd)

  proc stopProcess*(process: NodeSubProcess) =
    process.toJs.kill()

template j*(x: typed): untyped =
  cstring(x)

template mkey*(key, command) =
  Mousetrap.`bind`(key, proc =
    ipc.send command, js{})



proc isNotUndefined*[T](s: T): bool {. importcpp: "((#) != undefined)" .}


template toElement*(s: untyped): untyped =
  cast[dom.Element](`s`)

template toNode*(s: untyped): untyped =
  cast[dom.Node](`s`)

var jsNl* = j($("\n"[0]))
var jsTab* = j($("\t"[0]))

# await wait(5000)

# await startProcess(a, b) -> promise <-----------------------|
#                                       |
# promise.handler(promise.resolve)      |
#                                       |
# promise.resolve() --------------------|



# milliseconds
proc wait*(duration: int): Future[void] =
  # debugPrint "wait ", duration
  return newPromise do (resolve: (proc: void)):
    # debugPrint "start ", duration
    discard windowSetTimeout(resolve, duration)

proc chr*(i: int): cstring {.importcpp: "String.fromCharCode(#)".}
proc toCString*[T](s: T): cstring {.importcpp: "#.toString()", noSideEffect, tags: [].}

# proc `&`*(s: cstring, t: char): cstring {.importcpp: "# + #", noSideEffect, tags: [].}

proc parseJSInt*(s: cstring): int {.importcpp: "parseInt(#)".}
proc parseJSInt*(i: int): int {.importcpp: "parseInt(#)".}

proc parseJSFloat*(s: cstring): float {.importcpp: "parseFloat(#)".}

proc split*(s: cstring, separator: cstring): seq[cstring] {.importcpp: "#.split(#)".}

# TODO: pass correctly, not as a number
# proc split*(s: cstring, separator: char): seq[cstring] {.importcpp: "#.split(#)".}

proc split*(s: cstring, separator: js): seq[cstring] {.importcpp: "#.split(#)".}

proc slice*(s: cstring, start: int): cstring {.importcpp: "#.slice(#)".}

proc slice*(s: cstring, start: int, finish: int): cstring {.importcpp: "#.slice(#, #)".}

proc slice*[T](s: seq[T], start: int): seq[T] {.importcpp: "#.slice(#)".}

proc slice*[T](s: seq[T], start: int, finish: int): seq[T] {.importcpp: "#.slice(#, #)".}

proc toLowerCase*(s: cstring): cstring {.importcpp.}

proc toUpperCase*(s: cstring): cstring {.importcpp.}

proc charAt*(s: cstring, index: int): cstring {.importcpp: "#.charAt(#)".}

proc capitalize*(s: cstring): cstring =
  s.charAt(0).toUpperCase() & s.slice(1)

proc trim*(s: cstring): cstring {.importcpp: "#.trim()".}

proc replace*(s: cstring, pattern: js, with: cstring): cstring {.importcpp: "#.replace(#, #)", noSideEffect.}

proc replaceCString*(s: cstring, pattern: cstring, with: cstring): cstring {.importcpp: "#.replace(#, #)", noSideEffect.}

func isArray*(a: JsObject): bool {.importcpp: "Array.isArray(#)".}

#proc indexOf*(s: cstring, e: char, )
proc `[]`*(s: cstring, index: int): cstring {.importcpp: "#[#]".}

proc `[]`*[T](elements: DataView[T], index: uint): T {.importcpp: "#[#]".}

proc `[]=`*[T](elements: DataView[T], index: uint, value: T) {.importcpp: "#[#] = #".}

proc `[]`*(buffer: Buffer, index: uint): char {.importcpp: "#[#]".}

proc `[]=`*(buffer: Buffer, index: uint, value: char) {.importcpp: "#[#] = #".}

proc uint16Array*(buffer: ArrayBuffer): DataView[uint16] {.importcpp: "new Uint16Array(#)".}

proc uint32Array*(buffer: ArrayBuffer): DataView[uint32] {.importcpp: "new Uint32Array(#)".}

proc newBuffer*(a: uint): Buffer {.importcpp: "Buffer.alloc(#)".}

proc arrayBuffer*(size: uint): ArrayBuffer {.importcpp: "new ArrayBuffer(#)".}

proc regex*(a: cstring): js {.importcpp: "new RegExp(#, 'g')", noSideEffect.}

type RegexMatch = ref object
  index*: int
  input*: cstring
  groups*: JsAssoc[cstring, JsObject]
  indices*: seq[JsObject]

proc `[]`*(match: RegexMatch, index: uint): cstring {.importcpp: "#[#]".}

proc matchAll*(a: cstring, regex: js): seq[RegexMatch] {.importcpp: "[...#.matchAll(#)]".}

proc exec*(regExp: js, text: cstring): js {.importcpp: "#.exec(#)".}

proc shallowCopy*[T](t: T): T {.importcpp: "Object.assign({}, #)".}

proc dump*[T](yaml: Yaml, a: T, indent: int): cstring {.importcpp: "#.dump(#, #)".}


proc jqueryFind*(a: cstring): js {.importcpp: "jQuery(#)".}

proc len*[B, A](a: JsAssoc[B, A]): int {.noSideEffect.} =
  if a.isNone:
    0
  else:
    keysOf(a).len

proc obj*(a: js, depth: int = 4): js =
  if isUndefined(a):
    return undefined
  var b = cast[JsAssoc[cstring, js]](a)
  var txt = js{}
  if isNotUndefined(b.toJs.length) and len(b) > 10:
    return (j"..").toJs

  for name, value in b:
    try:
      if jstypeof(value) == j"function" or name == j"m_type" or not b.toJs.hasOwnProperty(name):
        continue
      elif jstypeof(value) == j"object":
        if depth > 0:
          txt[name] = obj(value, depth - 1)
        else:
          txt[name] = j"object"
      else:
        txt[name] = value
    except:
      # heidenbug ?
      warnPrint "surprising exception ", getCurrentExceptionMsg()
      # debugPrint b.toJs.hasOwnProperty
      continue
  return txt


proc isJsArray*(a: js): bool {.importcpp: "(# instanceof Array)".}

proc isJsObject*(a: js): bool {.importcpp: "(# instanceof Object)".}

proc del*[A, B](value: JsAssoc[A, B], key: A) {.importcpp: "(delete #[#])".}

proc now*: int64 {.importcpp: "(new Date()).getTime()".}

proc delta*(a: BiggestInt, b: BiggestInt): BiggestInt {.importcpp: "(# - #)".}

proc toISO*(time: int64): cstring {.importcpp: "new Date(#).toISOString()".}

proc newChart*(ctx: js, config: js): js {.importcpp: "new Chart(#, #)".}

proc jsmul*(a: BiggestInt, b: BiggestInt): BiggestInt {.importcpp: "(# * #)".}

proc jsdiv*(a: BiggestInt, b: BiggestInt): BiggestInt {.importcpp: "Math.trunc(# / #)".}

proc floor*(a: float): int {.importcpp: "Math.floor(#)".}

proc ceil*(a: float): int {.importcpp: "Math.ceil(#)".}

proc kout2*[T](a: T): void {.importcpp: "console.log(#)".}

proc kout2*[T](a: T, b: T): void {.importcpp: "console.log(#, #)".}


template taskLog*(taskId: TaskId): cstring =
  let taskIdString = taskId.cstring
  if taskIdString.len > 0:
    # for compat with codetracer_output for chronicles
    cstring" taskId=" & taskIdString & cstring" time=" & (cast[float](now()) / 1_000).toCString
  else:
    cstring""

template locationInfo: untyped =
  let i = instantiationInfo(0)
  i.filename & ":" & $i.line

template withDebugInfo*(a: cstring, taskId: TaskId, level: string): cstring =
  # tries to be compatible with out codetracer_output
  # in chronicles and with the rr/gdb scripts logs:
  # <time:18> | <level:5> | <task-id:17> | <file:line:28> | ([<indentation space>]<message>:50)[<args>()]
  cstring(
    ($(cast[float](now()) / 1_000)).alignLeft(18) & " | " & # time
    level.alignLeft(5) & " | " &
    ($taskId).alignLeft(17) & " | " &
    locationInfo().alignLeft(28) & " | " &
    ($(a.toCString)))

template cdebug*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.debug withDebugInfo(a.toCString, taskId, "DEBUG")
  #  withLocationInfo(a.toCString) & taskLog(taskId)

template clog*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.log withDebugInfo(a.toCString, taskId, "DEBUG")
  #  withLocationInfo(a.toCString) & taskLog(taskId)

template cwarn*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.warn withDebugInfo(a.toCString, taskId, "WARN")
  # console.warn withLocationInfo(a.toCString) & taskLog(taskId)

template cerror*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.error withDebugInfo(a.toCString, taskId, "ERROR")
  # console.error withLocationInfo(a.toCString) & taskLog(taskId)


# repeat code here inside, instead of calling
# the generic versions, so it's on the same level of compile time stack
# for locationInfo:

template cdebug*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.debug withDebugInfo(a.cstring, taskId, "DEBUG")

template clog*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.log withDebugInfo(a.cstring, taskId, "DEBUG")

template cwarn*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.warn withDebugInfo(a.cstring, taskId, "WARN")

template cerror*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.error withDebugInfo(a.cstring, taskId, "ERROR")

template uiTestLog*(msg: string): void =
  clog "ui test: " & msg

var lastJSError* {.importc.}: JsObject

const
  # dom events
  UP_KEY_CODE* = 38
  DOWN_KEY_CODE* = 40
  ENTER_KEY_CODE* = 13
  ESC_KEY_CODE* = 27
  TAB_KEY_CODE* = 9
  BACKSPACE_KEY_CODE* = 8

var domwindow* {.importc: "window".}: JsObject

proc jsFalse*(value: js): bool =
  isUndefined(value) or not cast[bool](value)

proc loadValues*(a: js, id: cstring): JsAssoc[cstring, cstring] =
  var fields = JsAssoc[cstring, js]{}
  var values = JsAssoc[cstring, cstring]{}
  if id == j"CODETRACER::updated-slice":
    return values
  if isJsObject(a):
    fields = cast[JsAssoc[cstring, js]](a)
  elif isJsArray(a):
    for i, element in a:
      fields[i.toCString] = element
  else:
    fields[j""] = a
  for field, value in fields:
    if field == j"source":
      continue
    elif not value.isNil:
      values[field] = value.toCString
    elif value.isNil:
      values[field] = j"undefined"
    else:
      values[field] = j"nil"
  return values


let PYTHON_PATCH_PATH* = "~/cpython/debug/python"
let PYTHON_PATCH_DIR* = "~/cpython/debug/"
let PYTHON_PATCH_PARENT_DIR* = "~/cpython/"

proc generateJsObject(properties: NimNode): NimNode =
  var empty = newEmptyNode()
  result = nnkStmtList.newTree()
  var first = nnkTypeSection.newTree(
    nnkTypeDef.newTree(
      ident("temp"),
      empty,
      nnkObjectTy.newTree(
        empty,
        empty,
        nnkRecList.newTree())))
  var second = ident("temp")

  for property in properties:
    expectKind(property, nnkExprEqExpr)
    first[0][2][2].add(nnkIdentDefs.newTree(
      property[0],
      property[1],
      newEmptyNode()))

  result.add(first)
  result.add(second)

when defined(ctIndex) or defined(ctTest):
  var app*: cstring
  # if inElectron:
  app = getEnv("XDG_DATA_HOME", $paths.home & "/.local/share") & "/codetracer"


macro jsobject*(args: varargs[untyped]): untyped =
  generateJsObject(args)


macro cView*(node: untyped): untyped =
  expectKind node, {nnkObjConstr, nnkCall}

  let z = ident"zspecial"
  let componentName = node[0]

  result = quote:
    let `z` = newComponent(`componentName`)
  # let section
  result = nnkStmtList.newTree(result)

  for i, arg in node:
    if i > 0:
      expectKind arg, nnkExprColonExpr

      let name = arg[0]
      let value = arg[1]
      let a = quote:
        `z`.`name` = `value`
      result.add(a)
  # let render = ident(&"render{componentName}")
  # let a = quote:
  #   `z`.renderImpl = `render`
  # result.add(a)
  result.add(z)
  result = nnkBlockStmt.newTree(newEmptyNode(), result)


macro renderc*(component: untyped, code: untyped): untyped =
  expectKind component, {nnkIdent, nnkBracketExpr}

  let name = if component.kind == nnkIdent: $component else: $component[0]
  let c = ident"component"
  let function = nnkPostfix.newTree(ident"*", ident(&"render{name}"))
  let empty = newEmptyNode()
  let functionGenerics =
    if component.kind == nnkIdent:
      empty
   else:
      let g = nnkGenericParams.newTree()
      for z, t in component:
        if z > 0:
          g.add(nnkIdentDefs.newTree(t, empty, empty))
      g
  let functionCode = quote:
    let self {.inject.} = `component`(`c`)
    `code`
  result = nnkProcDef.newTree(
    function,
    empty,
    functionGenerics,
    nnkFormalParams.newTree(
      ident"VNode",
      nnkIdentDefs.newTree(
        c,
        ident"VComponent",
        empty)),
    empty,
    empty,
    functionCode)

    # proc `function`(`c`: VComponent): VNode =
    #   let self {.inject.} = `component`(`c`)
    #   `code`


macro time*(f: untyped): untyped =
  # a pragma for logging time of a function
  # proc a(b: string) {.time.} =
  #   log b
  # a: 23 ms
  # TODO: it doesn't work with return
  result = f
  let originalCode = f.body
  var label = f[0]
  let startNode = ident("start")
  let finishNode = ident("finish")
  if label.kind == nnkPostfix:
    label = label[1]
  label = newLit(label.repr)
  let first = quote:
    let `startNode` = now()
  let last = quote:
    let `finishNode` = now()
    # debugPrint `label`, ":", delta(`finishNode`, `startNode`), " ms"
  result.body = nnkStmtList.newTree(first, originalCode, last)

macro update*(value: untyped, fields: untyped): untyped =
  # merges fields into value
  # a = A(e: 4, f: 2)
  # a.update
  #   e = 2
  #   f = 1
  result = nnkStmtList.newTree()
  for field in fields:
    expectKind(field, nnkAsgn)
    let line = nnkAsgn.newTree(nnkDotExpr.newTree(value, field[0]), field[1])
    result.add(line)


proc add*[T, U](a: var JsAssoc[T, U], element: (T, U)) =
  a[element[0]] = element[1]

proc mapPairs*[K, V](a: JsAssoc[K, V]): seq[(K, V)] =
  result = @[]
  for k, v in a:
    result.add((k, v))


export sugar, task_and_event
