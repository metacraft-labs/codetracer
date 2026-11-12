## ui/shared_editor_facade.nim — Monaco's editor API over the shared editor.
##
## `ui/shared_editor` draws the shared editing core; this module is the face
## the rest of the desktop sees: an object answering the part of Monaco's
## `ICodeEditor` and `ITextModel` the desktop calls (`lib/monaco_lib`'s
## `MonacoEditor` and `MonacoTextModel`, plus the members `ui/editor`,
## `ui/flow`, `ui/trace`, the LSP router and the test page objects reach
## through `toJs`). Every member is answered from the core:
##
##   * text and positions — the document and its line index, with Monaco's
##     1-based UTF-16 columns converted from the core's bytes;
##   * selections and the caret — `EditorState.selection`;
##   * `trigger(source, commandId)` — the editing operation that Monaco
##     command IS (`monaco_operations.MonacoOperations`, read backwards), run
##     by the core;
##   * decorations — the core's decoration set (`editor_dom_frame`);
##   * view zones, content and overlay widgets — positioned by the shared
##     editor's layout;
##   * events — fired by the shared editor when the core moved.
##
## A member the desktop does not call is absent rather than approximated.

import std/[jsffi, tables, strutils]

import ../viewmodel/editing_core
import ../viewmodel/editor/[selection, document_version]
import ../view_vocabulary/editor_dom_frame
import ./shared_editor
import ./monaco_operations

proc jsNew(): JsObject {.importjs: "({})@".}
proc jsArray(): JsObject {.importjs: "([])@".}
proc jsPush(a, v: JsObject) {.importjs: "#.push(#)".}
proc jsLen(a: JsObject): int {.importjs: "(#.length|0)".}
proc jsNum(v: JsObject): float {.importjs: "Number(#)".}
proc jsStr(v: JsObject): cstring {.importjs: "String(#)".}
proc isNilOrUndef(v: JsObject): bool {.importjs: "(# == null)".}
proc mergeInto(target, source: JsObject) {.importjs: "Object.assign(#, #)".}
proc callFn(f: JsObject; a: JsObject): JsObject {.importjs: "#(#)".}
proc defineGetter(o: JsObject; name: cstring; f: proc(): JsObject) {.importjs:
  "Object.defineProperty(#, #, {get: #, configurable: true, enumerable: true})".}
proc jsRegExp(pattern: cstring; flags: cstring): JsObject {.importjs: "new RegExp(#, #)".}
proc escapeRegExp(s: cstring): cstring =
  ## `s` with every regular-expression metacharacter escaped.
  var r = ""
  for c in $s:
    if c in {'.', '*', '+', '?', '^', '$', '{', '}', '(', ')', '|', '[', ']', '\\'}:
      r.add '\\'
    r.add c
  cstring(r)
proc execAll(re, text: JsObject): JsObject {.importjs: """
  (function(re, text){
    const acc = [];
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      acc.push([m.index, m[0].length, Array.from(m)]);
      if (m[0].length === 0) re.lastIndex++;
      if (acc.length > 100000) break;
    }
    return acc;
  })(#, #)""".}
proc utf8OffsetOf(text: cstring; idx16: int): int {.importjs: """
  (function(t, i){
    let n = 0;
    for (let k = 0; k < i && k < t.length; k++) {
      const c = t.charCodeAt(k);
      if (c < 0x80) n += 1;
      else if (c < 0x800) n += 2;
      else if (c >= 0xD800 && c <= 0xDBFF) { n += 4; k++; }
      else n += 3;
    }
    return n;
  })(#, #)""".}

var commandOperations: Table[string, string]
  ## Monaco command id -> the core's operation (MonacoOperations, reversed).

proc operationOfCommand*(command: string): string =
  if commandOperations.len == 0:
    for op, cmd in MonacoOperations:
      if not commandOperations.hasKey(cmd):
        commandOperations[cmd] = op
  commandOperations.getOrDefault(command, "")

proc posJs(p: tuple[lineNumber, column: int]): JsObject =
  result = jsNew()
  result["lineNumber"] = p.lineNumber
  result["column"] = p.column

proc rangeObj(sl, sc, el, ec: int): JsObject =
  result = jsNew()
  result["startLineNumber"] = sl
  result["startColumn"] = sc
  result["endLineNumber"] = el
  result["endColumn"] = ec

proc selectionJs(ed: SharedEditor; r: SelectionRange): JsObject =
  ## Monaco's `Selection`: the range plus the anchor (`selectionStart*`) and
  ## the head (`position*`).
  let a = ed.positionAt(r.anchor)
  let h = ed.positionAt(r.head)
  let f = ed.positionAt(r.rangeFrom)
  let t = ed.positionAt(r.rangeTo)
  result = rangeObj(f.lineNumber, f.column, t.lineNumber, t.column)
  result["selectionStartLineNumber"] = a.lineNumber
  result["selectionStartColumn"] = a.column
  result["positionLineNumber"] = h.lineNumber
  result["positionColumn"] = h.column
  let emptyNow = r.isEmpty
  result["isEmpty"] = proc(): bool = emptyNow
  result["getStartPosition"] = proc(): JsObject = posJs(f)
  result["getEndPosition"] = proc(): JsObject = posJs(t)
  result["getPosition"] = proc(): JsObject = posJs(h)

proc rangeArg(ed: SharedEditor; r: JsObject): tuple[a, b: int] =
  let a = ed.offsetAt(int(jsNum(r["startLineNumber"])), int(jsNum(r["startColumn"])))
  let b = ed.offsetAt(int(jsNum(r["endLineNumber"])), int(jsNum(r["endColumn"])))
  (min(a, b), max(a, b))

proc disposable(f: proc()): JsObject =
  result = jsNew()
  result["dispose"] = f

# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------

proc buildModel(ed: SharedEditor): JsObject =
  let m = jsNew()
  let uri = jsNew()
  uri["path"] = cstring(ed.path)
  uri["fsPath"] = cstring(ed.path)
  uri["scheme"] = cstring"file"
  uri["toString"] = proc(): cstring = cstring("file://" & ed.path)
  m["uri"] = uri
  m["id"] = cstring("ct-shared-model-" & $ed.id)
  m["__ctShared"] = true
  m["getValue"] = proc(): cstring = cstring(ed.text)
  m["setValue"] = proc(v: cstring) = ed.replaceAll($v)
  m["getLineCount"] = proc(): int = ed.lineCount
  m["getLineContent"] = proc(line: int): cstring = cstring(ed.lineText(line))
  m["getLinesContent"] = proc(): JsObject =
    let a = jsArray()
    for i in 1 .. ed.lineCount: a.jsPush(toJs(cstring(ed.lineText(i))))
    a
  m["getLineLength"] = proc(line: int): int =
    monacoColumnOf(ed.lineText(line), ed.lineText(line).len) - 1
  m["getLineMaxColumn"] = proc(line: int): int =
    monacoColumnOf(ed.lineText(line), ed.lineText(line).len)
  m["getLineMinColumn"] = proc(line: int): int = 1
  m["getLineFirstNonWhitespaceColumn"] = proc(line: int): int =
    let t = ed.lineText(line)
    for i, c in t:
      if c notin {' ', '\t'}: return monacoColumnOf(t, i)
    0
  m["getLineLastNonWhitespaceColumn"] = proc(line: int): int =
    let t = ed.lineText(line)
    for i in countdown(t.high, 0):
      if t[i] notin {' ', '\t'}: return monacoColumnOf(t, i + 1)
    0
  m["getVersionId"] = proc(): int = ordinal(ed.doc.timeline.version) + 1
  m["getAlternativeVersionId"] = proc(): int = ordinal(ed.doc.timeline.version) + 1
  m["getEOL"] = proc(): cstring = cstring("\n")
  m["getLanguageId"] = proc(): cstring = cstring(ed.languageId)
  m["getModeId"] = proc(): cstring = cstring(ed.languageId)
  m["isDisposed"] = proc(): bool = ed.disposed
  m["getOffsetAt"] = proc(p: JsObject): int =
    let off = ed.offsetAt(int(jsNum(p["lineNumber"])), int(jsNum(p["column"])))
    # Monaco's offsets are UTF-16 units.
    let before = ed.text[0 ..< off]
    cstring(before).len
  m["getPositionAt"] = proc(offset16: int): JsObject =
    let t = cstring(ed.text)
    posJs(ed.positionAt(utf8OffsetOf(t, offset16)))
  m["validatePosition"] = proc(p: JsObject): JsObject =
    let off = ed.offsetAt(int(jsNum(p["lineNumber"])), int(jsNum(p["column"])))
    posJs(ed.positionAt(off))
  m["getFullModelRange"] = proc(): JsObject =
    let n = ed.lineCount
    rangeObj(1, 1, n, monacoColumnOf(ed.lineText(n), ed.lineText(n).len))
  m["getValueInRange"] = proc(r: JsObject): cstring =
    let (a, b) = ed.rangeArg(r)
    cstring(ed.text[a ..< b])
  m["getWordAtPosition"] = proc(p: JsObject): JsObject =
    let line = int(jsNum(p["lineNumber"]))
    let t = ed.lineText(line)
    let w = wordAt(t, byteColumnOf(t, int(jsNum(p["column"]))))
    if not w.found: return nil
    result = jsNew()
    result["word"] = cstring(t[w.a ..< w.b])
    result["startColumn"] = monacoColumnOf(t, w.a)
    result["endColumn"] = monacoColumnOf(t, w.b)
  m["getWordUntilPosition"] = proc(p: JsObject): JsObject =
    let line = int(jsNum(p["lineNumber"]))
    let t = ed.lineText(line)
    let col = byteColumnOf(t, int(jsNum(p["column"])))
    let w = wordAt(t, col)
    result = jsNew()
    if not w.found or w.a >= col:
      result["word"] = cstring""
      result["startColumn"] = int(jsNum(p["column"]))
      result["endColumn"] = int(jsNum(p["column"]))
    else:
      result["word"] = cstring(t[w.a ..< col])
      result["startColumn"] = monacoColumnOf(t, w.a)
      result["endColumn"] = monacoColumnOf(t, col)
  m["findMatches"] = proc(search: JsObject; scope: JsObject; isRegex: bool;
                          matchCase: bool; wordSeparators: JsObject;
                          captureMatches: bool): JsObject =
    ## Monaco's `findMatches(searchString, searchOnlyEditableRange,
    ## isRegex, matchCase, wordSeparators, captureMatches)`.
    let pattern = if isRegex: jsStr(search) else: escapeRegExp(jsStr(search))
    var re: JsObject
    try:
      re = jsRegExp(pattern, cstring(if matchCase: "gm" else: "gmi"))
    except CatchableError:
      return jsArray()
    let acc = jsArray()
    for line in 1 .. ed.lineCount:
      let t = cstring(ed.lineText(line))
      let found = execAll(re, toJs(t))
      for k in 0 ..< jsLen(found):
        let hit = found[k]
        let i16 = int(jsNum(hit[0]))
        let l16 = int(jsNum(hit[1]))
        let fm = jsNew()
        fm["range"] = rangeObj(line, i16 + 1, line, i16 + l16 + 1)
        fm["matches"] = (if captureMatches: hit[2] else: nil)
        acc.jsPush(fm)
    acc
  m["deltaDecorations"] = proc(old, added: JsObject): JsObject =
    ed.deltaDecorationsJs(old, added)
  m["getDecorationRange"] = proc(id: cstring): JsObject = ed.decorationRange($id)
  m["getAllDecorations"] = proc(): JsObject =
    let acc = jsArray()
    for e in ed.decos.entries:
      let d = jsNew()
      d["id"] = cstring(e.id)
      d["range"] = ed.decorationRange(e.id)
      let o = jsNew()
      o["className"] = cstring(e.options.className)
      o["inlineClassName"] = cstring(e.options.inlineClassName)
      o["glyphMarginClassName"] = cstring(e.options.glyphMarginClassName)
      o["isWholeLine"] = e.options.isWholeLine
      d["options"] = o
      acc.jsPush(d)
    acc
  m["getLineDecorations"] = proc(line: int): JsObject =
    let acc = jsArray()
    for e in ed.decos.entries:
      let r = ed.decorationRange(e.id)
      if r.isNil: continue
      if int(jsNum(r["startLineNumber"])) <= line and line <= int(jsNum(r["endLineNumber"])):
        let d = jsNew()
        d["id"] = cstring(e.id)
        d["range"] = r
        let o = jsNew()
        o["className"] = cstring(e.options.className)
        o["inlineClassName"] = cstring(e.options.inlineClassName)
        o["glyphMarginClassName"] = cstring(e.options.glyphMarginClassName)
        d["options"] = o
        acc.jsPush(d)
    acc
  m["onDidChangeContent"] = proc(f: JsObject): JsObject = ed.on("modelContent", f)
  m["onWillDispose"] = proc(f: JsObject): JsObject = ed.on("dispose", f)
  m["onDidChangeLanguage"] = proc(f: JsObject): JsObject = ed.on("language", f)
  m["applyEdits"] = proc(edits: JsObject): JsObject =
    discard ed.executeEdits(edits, force = true)
    jsArray()
  m["pushEditOperations"] = proc(before, edits, cb: JsObject): JsObject =
    discard ed.executeEdits(edits, force = true)
    nil
  m["pushStackElement"] = proc() = discard
  m["dispose"] = proc() = discard
  m["getOptions"] = proc(): JsObject =
    result = jsNew()
    result["tabSize"] = 4
    result["insertSpaces"] = true
  m["updateOptions"] = proc(o: JsObject) = discard
  m["forceTokenization"] = proc(line: int) = discard
  m

# ---------------------------------------------------------------------------
# The editor
# ---------------------------------------------------------------------------

proc optionName(id: int): string =
  ## The name Monaco's `EditorOption` enum gives `id` in the page's Monaco.
  var name: cstring
  {.emit: [name, " = (function(id){ const e = globalThis.monaco && globalThis.monaco.editor && globalThis.monaco.editor.EditorOption; if (!e) return ''; return (typeof e[id] === 'string') ? e[id] : ''; })(", id, ");"].}
  $name

proc layoutInfoJs(ed: SharedEditor): JsObject =
  result = jsNew()
  result["width"] = ed.width
  result["height"] = ed.height
  result["glyphMarginLeft"] = 0
  result["glyphMarginWidth"] = 18
  result["lineNumbersLeft"] = 18
  result["lineNumbersWidth"] = max(0, ed.gutterPx - 18 - 26)
  result["decorationsLeft"] = max(0, ed.gutterPx - 26)
  result["decorationsWidth"] = 26
  result["contentLeft"] = ed.gutterPx
  result["contentWidth"] = max(0, ed.width - ed.gutterPx - 14)
  result["minimap"] = jsNew()
  result["minimapWidth"] = 0
  result["minimapLeft"] = ed.width
  result["verticalScrollbarWidth"] = 14
  result["horizontalScrollbarHeight"] = 10

proc optionValue(ed: SharedEditor; id: int): JsObject =
  case optionName(id)
  of "readOnly": toJs(ed.readOnly)
  of "lineHeight": toJs(ed.lineHeight)
  of "layoutInfo": ed.layoutInfoJs
  of "fontInfo":
    let fi = jsNew()
    fi["fontSize"] = ed.fontSize
    fi["lineHeight"] = ed.lineHeight
    fi["typicalHalfwidthCharacterWidth"] = ed.charWidth
    fi["spaceWidth"] = ed.charWidth
    fi
  of "fontSize": toJs(ed.fontSize)
  of "wordSeparators": toJs(cstring(DefaultWordSeparators))
  else:
    if not ed.options.isNil:
      let n = optionName(id)
      if n.len > 0 and not isNilOrUndef(ed.options[cstring(n)]):
        return ed.options[cstring(n)]
    case id
    of 165: ed.layoutInfoJs                # lib/monaco_lib LAYOUT_INFO
    of 75: toJs(ed.lineHeight)             # LINE_HEIGHT
    of 59:                                 # FONT_INFO
      let fi = jsNew()
      fi["fontSize"] = ed.fontSize
      fi["lineHeight"] = ed.lineHeight
      fi["typicalHalfwidthCharacterWidth"] = ed.charWidth
      fi
    else: nil

proc runCommand*(ed: SharedEditor; command: string; payload: JsObject): bool =
  ## Monaco's `trigger(source, handlerId, payload)`: the editing operation the
  ## command is, run by the core. `type` (text from an IME or a host) inserts.
  case command
  of "type":
    if not isNilOrUndef(payload) and not isNilOrUndef(payload["text"]):
      return ed.insertText($jsStr(payload["text"]), "api") != eoIgnored
    return false
  of "cursorMove":
    return false
  of "actions.find":
    return ed.findCommand("find.open")
  of "editor.action.revealDefinition", "editor.action.goToDeclaration":
    ed.emitEvent("revealDefinition", jsNew())
    return true
  else: discard
  let op = operationOfCommand(command)
  if op.len == 0:
    return false
  if '.' in op:
    # find.* and editor.scroll-*: the editor's own.
    case op
    of "editor.scroll-line-up": ed.setScroll(ed.scrollTop - ed.lineHeight, ed.scrollLeft)
    of "editor.scroll-line-down": ed.setScroll(ed.scrollTop + ed.lineHeight, ed.scrollLeft)
    of "editor.scroll-page-up": ed.setScroll(ed.scrollTop - ed.height, ed.scrollLeft)
    of "editor.scroll-page-down": ed.setScroll(ed.scrollTop + ed.height, ed.scrollLeft)
    else:
      return ed.findCommand(op)
    return true
  discard ed.applyNamedOp(op, source = "keyboard")
  true

proc facadeOf*(ed: SharedEditor): JsObject =
  ## The editor's Monaco-shaped face. Built once; `ed.facade` keeps it.
  if not ed.facade.isNil: return ed.facade
  let f = jsNew()
  ed.facade = f
  ed.model = buildModel(ed)
  f["__ctShared"] = true
  f["__ctSharedEditorId"] = ed.id
  f["domElement"] = ed.root
  f["decorations"] = jsArray()
  f["getId"] = proc(): cstring = cstring("ct-shared-editor-" & $ed.id)
  f["getEditorType"] = proc(): cstring = cstring"vs.editor.ICodeEditor"
  f["getModel"] = proc(): JsObject = ed.model
  f["setModel"] = proc(m: JsObject) =
    if not isNilOrUndef(m) and not isNilOrUndef(m["getValue"]):
      ed.replaceAll($jsStr(callFn(m["getValue"], nil)))
  f["getValue"] = proc(): cstring = cstring(ed.text)
  f["setValue"] = proc(v: cstring) = ed.replaceAll($v)
  f["getDomNode"] = proc(): JsObject = ed.root
  f["getContainerDomNode"] = proc(): JsObject = ed.host
  f["focus"] = proc() = ed.focusEditor()
  f["hasTextFocus"] = proc(): bool = ed.hasTextFocus
  f["hasWidgetFocus"] = proc(): bool = ed.hasTextFocus
  f["isFocused"] = proc(): bool = ed.hasTextFocus
  let vm = jsNew()
  defineGetter(vm, "hasFocus", proc(): JsObject = toJs(ed.hasTextFocus))
  f["viewModel"] = vm
  f["layout"] = proc(dim: JsObject) =
    if not isNilOrUndef(dim) and not isNilOrUndef(dim["width"]):
      ed.layoutTo(int(jsNum(dim["width"])), int(jsNum(dim["height"])))
    else:
      ed.render()
  f["dispose"] = proc() = ed.dispose()
  f["updateOptions"] = proc(o: JsObject) =
    ## Monaco's `updateOptions`: the given options merged over the ones the
    ## editor was made with (the gutter's width, its numbers' renderer, the
    ## line highlight), `readOnly` applied to the document.
    if isNilOrUndef(o): return
    if ed.options.isNil: ed.options = jsNew()
    mergeInto(ed.options, o)
    if not isNilOrUndef(o["readOnly"]):
      ed.setReadOnlyMode(o["readOnly"].to(bool))
    if not isNilOrUndef(o["lineNumbers"]):
      ed.setLineNumbers(o["lineNumbers"])
    if not isNilOrUndef(o["fontSize"]) or not isNilOrUndef(o["fontFamily"]):
      ed.setFont(if isNilOrUndef(o["fontSize"]): ed.fontSize
                 else: int(jsNum(o["fontSize"])),
                 if isNilOrUndef(o["fontFamily"]): ""
                 else: $jsStr(o["fontFamily"]))
    ed.requestRender()
  f["getOption"] = proc(id: int): JsObject = ed.optionValue(id)
  f["getOptions"] = proc(): JsObject =
    result = jsNew()
    result["get"] = proc(id: int): JsObject = ed.optionValue(id)
  f["getLayoutInfo"] = proc(): JsObject = ed.layoutInfoJs
  f["getConfiguration"] = proc(): JsObject =
    result = jsNew()
    result["layoutInfo"] = ed.layoutInfoJs
    result["lineHeight"] = ed.lineHeight
  # Text and selection
  f["getPosition"] = proc(): JsObject =
    posJs(ed.positionAt(ed.doc.state.primaryHead))
  f["setPosition"] = proc(p: JsObject) =
    let off = ed.offsetAt(int(jsNum(p["lineNumber"])), int(jsNum(p["column"])))
    ed.setSelectionOffsets(off, off)
  f["getSelection"] = proc(): JsObject =
    ed.selectionJs(ed.doc.state.selection.mainRange)
  f["getSelections"] = proc(): JsObject =
    result = jsArray()
    for r in ed.doc.state.selection.ranges: result.jsPush(ed.selectionJs(r))
  f["setSelection"] = proc(r: JsObject) =
    let (a, b) = ed.rangeArg(r)
    var anchor = a
    var head = b
    if not isNilOrUndef(r["selectionStartLineNumber"]):
      anchor = ed.offsetAt(int(jsNum(r["selectionStartLineNumber"])),
                           int(jsNum(r["selectionStartColumn"])))
      head = ed.offsetAt(int(jsNum(r["positionLineNumber"])),
                         int(jsNum(r["positionColumn"])))
    ed.setSelectionOffsets(anchor, head)
  f["setSelections"] = proc(rs: JsObject) =
    if jsLen(rs) == 0: return
    var ranges: seq[SelectionRange] = @[]
    for i in 0 ..< jsLen(rs):
      let (a, b) = ed.rangeArg(rs[i])
      ranges.add spanRange(a, b)
    discard ed.runCoreStep("api", proc(d: var EditingDocument): EditingOutcome =
      d.state.selection = editorSelection(ranges)
      eoMoved)
  f["executeEdits"] = proc(source: cstring; edits: JsObject): bool =
    ed.executeEdits(edits)
  f["pushUndoStop"] = proc(): bool = true
  f["trigger"] = proc(source, handlerId: cstring; payload: JsObject) =
    discard ed.runCommand($handlerId, payload)
  f["getAction"] = proc(id: cstring): JsObject =
    let key = $id
    if ed.actionsTable.hasKey(key): return ed.actionsTable[key]
    if operationOfCommand(key).len == 0 and key != "actions.find": return nil
    result = jsNew()
    result["id"] = id
    result["run"] = proc(): JsObject =
      discard ed.runCommand(key, nil)
      nil
    result["isSupported"] = proc(): bool = true
  f["addAction"] = proc(desc: JsObject): JsObject =
    let key = $jsStr(desc["id"])
    let action = jsNew()
    action["id"] = desc["id"]
    action["label"] = desc["label"]
    action["run"] = proc(): JsObject = callFn(desc["run"], ed.facade)
    action["isSupported"] = proc(): bool = true
    ed.actionsTable[key] = action
    disposable(proc() = ed.actionsTable.del(key))
  f["addCommand"] = proc(keybinding: int; handler: JsObject): cstring = cstring""
  f["createContextKey"] = proc(key: cstring; def: JsObject): JsObject =
    let k = $key
    let ck = jsNew()
    ck["value"] = def
    ck["set"] = proc(v: JsObject) = ck["value"] = v
    ck["get"] = proc(): JsObject = ck["value"]
    ck["reset"] = proc() = ck["value"] = def
    ed.contextKeysTable[k] = ck
    ck
  # Decorations
  f["deltaDecorations"] = proc(old, added: JsObject): JsObject =
    ed.deltaDecorationsJs(old, added)
  f["createDecorationsCollection"] = proc(decos: JsObject): JsObject =
    let col = jsNew()
    col["__ids"] = ed.deltaDecorationsJs(jsArray(), decos)
    col["set"] = proc(ds: JsObject): JsObject =
      col["__ids"] = ed.deltaDecorationsJs(col["__ids"], ds)
      col["__ids"]
    col["clear"] = proc() =
      col["__ids"] = ed.deltaDecorationsJs(col["__ids"], jsArray())
    col["getRanges"] = proc(): JsObject =
      result = jsArray()
      let ids = col["__ids"]
      for i in 0 ..< jsLen(ids):
        let r = ed.decorationRange($jsStr(ids[i]))
        if not r.isNil: result.jsPush(r)
    defineGetter(col, "length", proc(): JsObject = toJs(jsLen(col["__ids"])))
    col
  # Scrolling and geometry
  f["getScrollTop"] = proc(): int = ed.scrollTop
  f["getScrollLeft"] = proc(): int = ed.scrollLeft
  f["setScrollTop"] = proc(v: int) = ed.setScroll(v, ed.scrollLeft)
  f["setScrollLeft"] = proc(v: int) = ed.setScroll(ed.scrollTop, v)
  f["setScrollPosition"] = proc(p: JsObject) =
    let t = if isNilOrUndef(p["scrollTop"]): ed.scrollTop else: int(jsNum(p["scrollTop"]))
    let l = if isNilOrUndef(p["scrollLeft"]): ed.scrollLeft else: int(jsNum(p["scrollLeft"]))
    ed.setScroll(t, l)
  f["getScrollHeight"] = proc(): int = ed.contentHeight
  f["getContentHeight"] = proc(): int = ed.contentHeight
  f["getScrollWidth"] = proc(): int = ed.width
  f["getTopForLineNumber"] = proc(line: int): int = ed.topForLine(line)
  f["getTopForPosition"] = proc(line, col: int): int = ed.topForLine(line)
  f["getOffsetForColumn"] = proc(line, col: int): int =
    let t = ed.lineText(line)
    int(ed.xOfByteCol(line, byteColumnOf(t, col)))
  f["getScrolledVisiblePosition"] = proc(p: JsObject): JsObject =
    let line = int(jsNum(p["lineNumber"]))
    let t = ed.lineText(line)
    result = jsNew()
    result["top"] = ed.topForLine(line) - ed.scrollTop
    result["left"] = int(ed.xOfByteCol(line, byteColumnOf(t, int(jsNum(p["column"]))))) +
                     ed.gutterPx - ed.scrollLeft
    result["height"] = ed.lineHeight
  f["getVisibleRanges"] = proc(): JsObject =
    result = jsArray()
    if ed.visible.len > 0:
      let last = ed.visible[^1]
      result.jsPush(rangeObj(ed.visible[0], 1, last,
        monacoColumnOf(ed.lineText(last), ed.lineText(last).len)))
  f["revealLine"] = proc(line: int) = ed.revealLine(line)
  f["revealLineInCenter"] = proc(line: int) = ed.revealLine(line, center = true)
  f["revealLineInCenterIfOutsideViewport"] = proc(line: int) =
    if line notin ed.visible: ed.revealLine(line, center = true)
  f["revealLineNearTop"] = proc(line: int) = ed.revealLine(line, center = true)
  f["revealLines"] = proc(a, b: int) = ed.revealLine(a)
  f["revealLinesInCenter"] = proc(a, b: int) = ed.revealLine(a, center = true)
  f["revealPosition"] = proc(p: JsObject) = ed.revealLine(int(jsNum(p["lineNumber"])))
  f["revealPositionInCenter"] = proc(p: JsObject) =
    ed.revealLine(int(jsNum(p["lineNumber"])), center = true)
  f["revealPositionInCenterIfOutsideViewport"] = proc(p: JsObject) =
    let line = int(jsNum(p["lineNumber"]))
    if line notin ed.visible: ed.revealLine(line, center = true)
  f["revealRange"] = proc(r: JsObject) = ed.revealLine(int(jsNum(r["startLineNumber"])))
  f["revealRangeInCenter"] = proc(r: JsObject) =
    ed.revealLine(int(jsNum(r["startLineNumber"])), center = true)
  f["revealRangeInCenterIfOutsideViewport"] = proc(r: JsObject) =
    let line = int(jsNum(r["startLineNumber"]))
    if line notin ed.visible: ed.revealLine(line, center = true)
  f["saveViewState"] = proc(): JsObject =
    result = jsNew()
    result["scrollTop"] = ed.scrollTop
    result["scrollLeft"] = ed.scrollLeft
    result["head"] = ed.doc.state.primaryHead
  f["restoreViewState"] = proc(s: JsObject) =
    if isNilOrUndef(s): return
    if not isNilOrUndef(s["head"]):
      let h = int(jsNum(s["head"]))
      ed.setSelectionOffsets(h, h)
    if not isNilOrUndef(s["scrollTop"]):
      ed.setScroll(int(jsNum(s["scrollTop"])), int(jsNum(s["scrollLeft"])))
  # Zones and widgets
  f["changeViewZones"] = proc(cb: JsObject) =
    let acc = jsNew()
    acc["addZone"] = proc(spec: JsObject): cstring = cstring($ed.addZone(spec))
    acc["removeZone"] = proc(id: JsObject) = ed.removeZone(int(jsNum(id)))
    acc["layoutZone"] = proc(id: JsObject) = ed.layoutZone(int(jsNum(id)))
    discard callFn(cb, acc)
    ed.requestRender()
  f["addContentWidget"] = proc(w: JsObject) =
    ed.addWidget(w, overlay = false)
    ed.requestRender()
  f["layoutContentWidget"] = proc(w: JsObject) = ed.requestRender()
  f["removeContentWidget"] = proc(w: JsObject) = ed.removeWidget(w)
  f["addOverlayWidget"] = proc(w: JsObject) = ed.addWidget(w, overlay = true)
  f["layoutOverlayWidget"] = proc(w: JsObject) = discard
  f["removeOverlayWidget"] = proc(w: JsObject) = ed.removeWidget(w)
  # Events
  f["onDidChangeModelContent"] = proc(h: JsObject): JsObject = ed.on("content", h)
  f["onDidChangeCursorPosition"] = proc(h: JsObject): JsObject = ed.on("cursorPosition", h)
  f["onDidChangeCursorSelection"] = proc(h: JsObject): JsObject = ed.on("cursorSelection", h)
  f["onDidScrollChange"] = proc(h: JsObject): JsObject = ed.on("scroll", h)
  f["onMouseDown"] = proc(h: JsObject): JsObject = ed.on("mouseDown", h)
  f["onMouseUp"] = proc(h: JsObject): JsObject = ed.on("mouseUp", h)
  f["onMouseMove"] = proc(h: JsObject): JsObject = ed.on("mouseMove", h)
  f["onMouseLeave"] = proc(h: JsObject): JsObject = ed.on("mouseLeave", h)
  f["onMouseWheel"] = proc(h: JsObject): JsObject = ed.on("mouseWheel", h)
  f["onContextMenu"] = proc(h: JsObject): JsObject = ed.on("contextMenu", h)
  f["onKeyDown"] = proc(h: JsObject): JsObject = ed.on("keyDown", h)
  f["onKeyUp"] = proc(h: JsObject): JsObject = ed.on("keyUp", h)
  f["onDidFocusEditorText"] = proc(h: JsObject): JsObject = ed.on("focus", h)
  f["onDidBlurEditorText"] = proc(h: JsObject): JsObject = ed.on("blur", h)
  f["onDidFocusEditorWidget"] = proc(h: JsObject): JsObject = ed.on("focus", h)
  f["onDidBlurEditorWidget"] = proc(h: JsObject): JsObject = ed.on("blur", h)
  f["onDidLayoutChange"] = proc(h: JsObject): JsObject = ed.on("layout", h)
  f["onDidContentSizeChange"] = proc(h: JsObject): JsObject = ed.on("layout", h)
  f["onDidChangeModel"] = proc(h: JsObject): JsObject = ed.on("model", h)
  f["onDidDispose"] = proc(h: JsObject): JsObject = ed.on("dispose", h)
  f["onDidChangeConfiguration"] = proc(h: JsObject): JsObject = ed.on("configuration", h)
  f["onDidPaste"] = proc(h: JsObject): JsObject = ed.on("paste", h)
  f["getTargetAtClientPoint"] = proc(x, y: float): JsObject = nil
  f["render"] = proc(force: bool) = ed.render()
  f["getSupportedActions"] = proc(): JsObject = jsArray()
  f

proc sharedEditorOfFacade*(f: JsObject): SharedEditor =
  if isNilOrUndef(f) or isNilOrUndef(f["__ctSharedEditorId"]): return nil
  let id = int(jsNum(f["__ctSharedEditorId"]))
  for ed in sharedEditors:
    if ed.id == id: return ed
  nil

proc installMonacoGlobals*() =
  ## Let the page's Monaco API see the shared editors: `getEditors()` lists
  ## them, `setModelMarkers` on a shared model draws its squiggles, and
  ## `setModelLanguage` re-colours it. Installed once, before the first
  ## shared editor; a page without Monaco gets a minimal `monaco.editor`.
  var installed: bool
  {.emit: [installed, " = !!(globalThis.__ctSharedMonacoGlobals);"].}
  if installed: return
  let listEditors = proc(): JsObject =
    result = jsArray()
    for ed in sharedEditors:
      if not ed.disposed: result.jsPush(facadeOf(ed))
  let themes = proc(name: cstring) =
    let dark = not ($name).toLowerAscii.contains("white") and
               not ($name).toLowerAscii.contains("light") and $name != "vs"
    for ed in sharedEditors: ed.setDarkTheme(dark)
  let listModels = proc(): JsObject =
    result = jsArray()
    for ed in sharedEditors:
      if not ed.disposed:
        discard facadeOf(ed)
        result.jsPush(ed.model)
  let markers = proc(model, owner, ms: JsObject): bool =
    for ed in sharedEditors:
      if not ed.model.isNil and ed.model == model:
        ed.setMarkers(ms)
        return true
    false
  {.emit: ["""
    globalThis.__ctSharedMonacoGlobals = true;
    globalThis.monaco = globalThis.monaco || {};
    const me = globalThis.monaco.editor = globalThis.monaco.editor || {};
    const origGet = me.getEditors ? me.getEditors.bind(me) : (() => []);
    me.getEditors = function() { return origGet().concat(""", listEditors, """()); };
    const origModels = me.getModels ? me.getModels.bind(me) : (() => []);
    me.getModels = function() { return origModels().concat(""", listModels, """()); };
    const origMarkers = me.setModelMarkers ? me.setModelMarkers.bind(me) : null;
    me.setModelMarkers = function(model, owner, ms) {
      if (model && model.__ctShared) { """, markers, """(model, owner, ms); return; }
      if (origMarkers) return origMarkers(model, owner, ms);
    };
    const origTheme = me.setTheme ? me.setTheme.bind(me) : null;
    me.setTheme = function(name) { """, themes, """(String(name));
      if (origTheme) return origTheme(name); };
    const origLang = me.setModelLanguage ? me.setModelLanguage.bind(me) : null;
    me.setModelLanguage = function(model, lang) {
      if (model && model.__ctShared) return;
      if (origLang) return origLang(model, lang);
    };
  """].}
