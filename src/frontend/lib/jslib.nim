import
  std/[ jsffi, async, macros, sequtils, strutils ],
  dom, vdom

import kdom except Location, document

type
  JSONObj* = ref object of js
    # probably not really -1
    stringify*: proc(
      source: js,
      replacer: proc(key: cstring, value: js): js = nil,
      level: js = jsUndefined): cstring {.noSideEffect, tags: [].}
    parse*: proc(s: cstring): js {.noSideEffect, tags: [].}

  DateJS* = ref object of js
    now*: proc: int

  # JavaScript Date instance for date parsing and manipulation
  JsDate* {.importc: "Date".} = ref object of JsRoot

  JsSet*[T] {.importc.} = JsAssoc[T, bool]

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

  Stmt* {.importc.} = ref object
    finalize*: proc: void
    run*: proc(args: varargs[cstring])

  JSMath* {.importc.} = ref object
    random*: proc(max: int): float
    floor*: proc(f: float): int
    ceil*: proc(f: float): int
    sqrt*: proc(f: float): float
    round*: proc(f: float): int

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

var
  jsthis* {.importcpp: "this".}: js
  windowSetTimeout* {.importcpp: "setTimeout(#, #)".}: proc (f: (proc: void), i: int): int
  windowClearTimeout* {.importcpp: "clearTimeout(#)".}: proc (f: int): void
  windowSetInterval* {.importcpp: "setInterval(#, #)".}: proc (f: (proc: void), i: int): int
  null* {.importc.}: js
  undefined* {.importc.}: js
  JSON* {.importc.}: JSONObj
  Date* {.importc.}: DateJS
  Math* {.importc.}: JSMath

proc createResizeObserver*(handler: proc) : ResizeObserver {.importjs:"new ResizeObserver(#)".}
proc createMutationObserver*(handler: proc) : MutationObserver {.importjs:"new MutationObserver(#)".}
proc observe*(observer: ResizeObserver, entry: kdom.Node) {.importjs:"#.observe(#)".}
proc disconnect*(observer: ResizeObserver) {.importjs:"#.disconnect()".}
proc observe*(observer: MutationObserver, domElement: kdom.Element, options: js) {.importjs:"#.observe(#,#)".}
proc disconnect*(observer: MutationObserver) {.importjs:"#.disconnect()".}

proc initJsSet*[T]: JsSet[T] = JsAssoc[T, bool]{}
proc isNaN*[T](n: T): bool {.importcpp: "isNaN(#)", noSideEffect, tags: [].}
proc isNone*[T](a: T): bool {.importcpp: "(# == null)", noSideEffect, tags: [].}
proc functionAsJS*[T](handler: T): js {.importcpp: "#".}
proc objectAssign*(a: js, b: js) {.importcpp: "Object.assign(#, #)".}
proc keysOf*[A, B](a: JsAssoc[A, B]): seq[cstring] {. importcpp: "(Object.keys(#))" .}
func hasKey*[A, B](a: JsAssoc[A, B], key: A): bool {. importcpp: "(#[#] != undefined)", noSideEffect.}

proc jsSpawn*(childProcess: js, name: cstring, cmd: seq[cstring], errorHandler: (proc: void)): js {.raises: [Exception], tags: [RootEffect].} =
  result = childProcess.spawn(name, cmd)
  result.on(cstring"close") do (code: int):
    if code != 0:
      errorHandler()

var jsNl* = cstring($("\n"[0]))

# milliseconds
proc wait*(duration: int): Future[void] =
  return newPromise do (resolve: (proc: void)):
    discard windowSetTimeout(resolve, duration)

proc chr*(i: int): cstring {.importcpp: "String.fromCharCode(#)".}
proc charAt*(s: cstring, index: int): cstring {.importcpp: "#.charAt(#)".}

proc parseJSInt*(s: cstring): int {.importcpp: "parseInt(#)".}
proc parseJSInt*(i: int): int {.importcpp: "parseInt(#)".}
proc parseJSFloat*(s: cstring): float {.importcpp: "parseFloat(#)".}

proc split*(s: cstring, separator: cstring): seq[cstring] {.importcpp: "#.split(#)".}

proc slice*(s: cstring, start: int): cstring {.importcpp: "#.slice(#)".}
proc slice*(s: cstring, start: int, finish: int): cstring {.importcpp: "#.slice(#, #)".}
proc slice*[T](s: seq[T], start: int, finish: int): seq[T] {.importcpp: "#.slice(#, #)".}

proc toLowerCase*(s: cstring): cstring {.importcpp.}
proc toUpperCase*(s: cstring): cstring {.importcpp.}
proc capitalize*(s: cstring): cstring = s.charAt(0).toUpperCase() & s.slice(1)

proc trim*(s: cstring): cstring {.importcpp: "#.trim()".}

proc toCString*[T](s: T): cstring {.importcpp: "#.toString()", noSideEffect, tags: [].}
proc replaceCString*(s: cstring, pattern: cstring, with: cstring): cstring {.importcpp: "#.replace(#, #)", noSideEffect.}

proc join*(s: seq[cstring], separator: cstring): cstring {.importcpp: "#.join(#)".}

proc `$`*(a: js): string {.importcpp: "cstrToNimstr(JSON.stringify(#))".}

type RegexMatch = ref object
  index*: int
  input*: cstring
  groups*: JsAssoc[cstring, JsObject]
  indices*: seq[JsObject]

proc regex*(a: cstring): js {.importcpp: "new RegExp(#, 'g')", noSideEffect.}
proc `[]`*(match: RegexMatch, index: uint): cstring {.importcpp: "#[#]".}
proc matchAll*(a: cstring, regex: js): seq[RegexMatch] {.importcpp: "[...#.matchAll(#)]".}

proc len*[B, A](a: JsAssoc[B, A]): int {.noSideEffect.} =
  if a.isNone:
    0
  else:
    keysOf(a).len

proc isJsArray*(a: js): bool {.importcpp: "(# instanceof Array)".}
proc isJsObject*(a: js): bool {.importcpp: "(# instanceof Object)".}
proc del*[A, B](value: JsAssoc[A, B], key: A) {.importcpp: "(delete #[#])".}

proc delta*(a: BiggestInt, b: BiggestInt): BiggestInt {.importcpp: "(# - #)".}
proc floor*(a: float): int {.importcpp: "Math.floor(#)".}

proc newChart*(ctx: js, config: js): js {.importcpp: "new Chart(#, #)".}
proc now*: int64 {.importcpp: "(new Date()).getTime()".}

# JavaScript Date utilities
proc newJsDate*(dateStr: cstring): JsDate {.importjs: "new Date(#)".}
  ## Create a new JavaScript Date from a date string
proc getTime*(date: JsDate): float {.importjs: "#.getTime()".}
  ## Get milliseconds since epoch from a Date object
proc isValidDate*(date: JsDate): bool {.importjs: "!isNaN(#.getTime())".}
  ## Check if a Date object represents a valid date
proc dateNowMs*(): float {.importjs: "Date.now()".}
  ## Get current time in milliseconds since epoch

var lastJSError* {.importc.}: JsObject

const
  # dom events
  UP_KEY_CODE* = 38
  DOWN_KEY_CODE* = 40
  ENTER_KEY_CODE* = 13
  ESC_KEY_CODE* = 27
  TAB_KEY_CODE* = 9
  BACKSPACE_KEY_CODE* = 8
  commandPrefix* = ":"

var domwindow* {.importc: "window".}: JsObject

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

macro jsobject*(args: varargs[untyped]): untyped =
  generateJsObject(args)

func startsWith*(a, b: cstring): bool {.importjs: "#.startsWith(#)".}
func endsWith*(a, b: cstring): bool {.importjs: "#.endsWith(#)".}

proc jsAsFunction*[T](handler: js): T {.importcpp: "#".}

template byId*(id: typed): untyped =
  document.getElementById(`id`)

template findElement*(selector: cstring): kdom.Element =
  kdom.document.querySelector(`selector`)

template jq*(selector: typed): untyped =
  dom.document.querySelector(`selector`)

template jqall*(selector: typed): untyped =
  dom.document.querySelectorAll(`selector`)

proc findAllNodesInElement*(element: kdom.Node, selector: cstring): seq[kdom.Node] {.importjs:"Array.from(#.querySelectorAll(#))".}

proc findNodeInElement*(element: kdom.Node, selector: cstring): js {.importjs:"#.querySelector(#)".}

proc isHidden*(e: kdom.Element): bool =
  e.classList.contains(cstring("hidden"))

proc hideDomElement*(e: kdom.Element) =
  e.classList.add(cstring("hidden"))

proc showDomElement*(e: kdom.Element) =
  e.classList.remove(cstring("hidden"))

proc isActive*(e: kdom.Element): bool =
  e.classList.contains(cstring("active"))

proc activateDomElement*(e: kdom.Element) =
  e.classList.add(cstring("active"))

proc deactivateDomElement*(e: kdom.Element) =
  e.classList.remove(cstring("active"))

proc hide*(e: dom.Element) =
  e.style.display = cstring"none"

proc show*(e: dom.Element) =
  e.style.display = cstring"block"

proc eattr*(e: dom.Node, s: string): cstring {.importcpp: "#.getAttribute('data-' + toJSStr(#))" .}
proc eattr*(e: kdom.Node, s: string): cstring {.importcpp: "#.getAttribute('data-' + toJSStr(#))" .}
proc createElementNS*(document: dom.Document, a: cstring, b: cstring): dom.Element {.importcpp: "(#.createElementNS(#, #))".}
proc append*(element: dom.Element, other: dom.Element) {.importcpp: "(#.append(#))".}

proc convertStringToHtmlClass*(input : cstring): cstring =
  var normalString: string
  let pattern =  regex("([a-zA-Z][a-zA-Z0-9-]+)")
  var matches = input.matchAll(pattern)

  normalString = ($(matches.mapIt(it[0]).join(cstring"-"))).toLowerAscii()

  return normalString.cstring