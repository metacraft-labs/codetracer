## ui/shared_editor_lsp.nim — the language server's features in the desktop's
## shared editor: hover, completion, go to definition, rename, formatting and
## the semantic tokens the desktop colours Nim with.
##
## Monaco gets these from `monaco-languageclient`'s providers, which only a
## Monaco model can call. The shared editor asks the SAME client, through the
## bridge the semantic-token provider already uses
## (`window.codetracerLsp.sendRequest(kind, method, params)`, `lsp_router`),
## for the document the router opened for this editor
## (`lsp_router.lspDocumentOf`): one server, one document, one answer for
## either editor. Diagnostics need nothing here — the router's
## `setModelMarkers` reaches the shared editor's model through the facade.
##
## What each feature does is Monaco's: hover after the pointer rests on a
## word, the suggestion list on `Ctrl+Space` and after a trigger character,
## go to definition on `F12` (where the keymap leaves `F12` to the editor),
## and Rename Symbol / Format Document in the editor's context menu when the
## server is there (the facade's `getAction(id).isSupported()`).

import std/[jsffi, asyncjs, strutils, tables]

import ./shared_editor
import ../viewmodel/editing_core
import ../viewmodel/editor/[change_set, selection]
import ../view_vocabulary/editor_dom_frame
import ../tui/app/theme/editor_theme
import ../styles/generated/design_tokens

type
  LspTarget* = proc(): tuple[kind, uri: string]
    ## The editor's server family and document URI, asked each time (the
    ## router syncs a document after the editor exists).
  OpenLocation* = proc(path: string; line, column: int)
    ## Opens another file at a position (the desktop's tab opener).

proc jsNew(): JsObject {.importjs: "({})@".}
proc jsArray(): JsObject {.importjs: "([])@".}
proc jsLen(a: JsObject): int {.importjs: "(#.length|0)".}
proc jsNum(v: JsObject): float {.importjs: "Number(#)".}
proc jsStr(v: JsObject): cstring {.importjs: "String(#)".}
proc isNilOrUndef(v: JsObject): bool {.importjs: "(# == null)".}
proc isArray(v: JsObject): bool {.importjs: "Array.isArray(#)".}
proc createEl(tag: cstring): JsObject {.importjs: "document.createElement(#)".}
proc setStyle(e: JsObject; k, v: cstring) {.importjs: "#.style.setProperty(#, #)".}
proc rectOf(e: JsObject): JsObject {.importjs: "#.getBoundingClientRect()".}
proc nowMs(): float {.importjs: "Date.now()@".}
proc setTimeoutJs(f: proc(); ms: int): int {.importjs: "setTimeout(#, #)".}
proc clearTimeoutJs(id: int) {.importjs: "clearTimeout(#)".}
proc lspReady(kind: cstring): bool {.importjs:
  "(!!(globalThis.codetracerLspClients && globalThis.codetracerLspClients[#] && globalThis.codetracerLsp && globalThis.codetracerLsp.sendRequest))".}
proc serverHas(kind, capability: cstring): bool {.importjs: """
  ((k, c) => {
    const cli = globalThis.codetracerLspClients && globalThis.codetracerLspClients[k];
    const caps = cli && cli.initializeResult && cli.initializeResult.capabilities;
    return !!(caps && caps[c]);
  })(#, #)""".}
  ## Whether the connected server advertised `capability` in its
  ## `initialize` result. Asked before a request a server may not serve: the
  ## dev shell's nimlangserver 1.12.0 advertises no semantic tokens, and a
  ## `semanticTokens/range` sent to it is never answered and stalls every
  ## request after it (measured 2026-11-12).
proc lspSend(kind, meth: cstring; params: JsObject): Future[JsObject] {.importjs:
  "globalThis.codetracerLsp.sendRequest(#, #, #)".}

proc consoleWarn(a: cstring) {.importjs: "console.warn(#)".}

proc lspFailed(what: string) =
  ## A request the server refused or the bridge could not send: said on the
  ## console (Monaco's providers log theirs the same way), and the feature
  ## shows nothing.
  consoleWarn(cstring("shared editor: LSP " & what & " failed: " &
                      getCurrentExceptionMsg()))

proc s(v: JsObject): string =
  if isNilOrUndef(v): "" else: $jsStr(v)

type
  LspState = ref object
    ed: SharedEditor
    target: LspTarget
    openLocation: OpenLocation
    hoverTimer: int
    hoverAt: tuple[line, column: int]
    hover: JsObject
    suggest: JsObject
    items: seq[tuple[label, insert, detail: string]]
    selected: int
    replaceFrom, replaceTo: int
    semanticTimer: int
    semanticAsked: string

const
  HoverDelayMs = 300
    ## Monaco's `hover.delay`.
  SemanticDebounceMs = 120
    ## `nimSemanticTokens.js`'s debounce.
  SemanticTokenTypes = ["namespace", "type", "class", "enum", "interface",
    "struct", "typeParameter", "parameter", "variable", "property",
    "enumMember", "function", "method", "macro", "keyword", "modifier",
    "comment", "string", "number", "regexp", "operator", "decorator",
    "label"]
    ## The wire legend (`languages/nimSemanticTokens.js`
    ## SEMANTIC_TOKEN_TYPES, `nim-langserver/semantic_tokens.nim`).

proc posParams(st: LspState; offset: int): JsObject =
  let (kind, uri) = st.target()
  discard kind
  let ed = st.ed
  let p = ed.positionAt(offset)
  let line = ed.lineText(p.lineNumber)
  # LSP characters are UTF-16 units, as Monaco's columns.
  result = jsNew()
  let td = jsNew()
  td["uri"] = cstring(uri)
  result["textDocument"] = td
  let pos = jsNew()
  pos["line"] = p.lineNumber - 1
  pos["character"] = monacoColumnOf(line, byteColumnOf(line, p.column)) - 1
  result["position"] = pos

proc offsetOfLsp(ed: SharedEditor; p: JsObject): int =
  ed.offsetAt(int(jsNum(p["line"])) + 1, int(jsNum(p["character"])) + 1)

proc ready(st: LspState): bool =
  let (kind, uri) = st.target()
  kind.len > 0 and uri.len > 0 and lspReady(cstring(kind))

# ---------------------------------------------------------------------------
# Hover
# ---------------------------------------------------------------------------

proc hideHover(st: LspState) =
  if not st.hover.isNil:
    st.hover.setStyle("display", "none")

proc textOfHover(contents: JsObject): string =
  ## `Hover.contents`: MarkupContent, a MarkedString or an array of them.
  if isNilOrUndef(contents): return ""
  if isArray(contents):
    var parts: seq[string] = @[]
    for i in 0 ..< jsLen(contents): parts.add textOfHover(contents[i])
    return parts.join("\n\n")
  if not isNilOrUndef(contents["value"]): return s(contents["value"])
  s(contents)

proc showHover(st: LspState; text: string; line1, byteCol: int) =
  let ed = st.ed
  if st.hover.isNil:
    st.hover = createEl("div")
    st.hover.className = cstring"monaco-hover ct-hover"
    st.hover.setAttribute(cstring"role", cstring"tooltip")
    st.hover.setStyle("position", "absolute")
    st.hover.setStyle("z-index", "30")
    st.hover.setStyle("max-width", "600px")
    st.hover.setStyle("white-space", "pre-wrap")
    st.hover.setStyle("padding", "4px 8px")
    discard ed.root.appendChild(st.hover)
  st.hover.textContent = cstring(text)
  let x = ed.xOfByteCol(line1, byteCol) + float(ed.gutterPx) - float(ed.scrollLeft)
  let top = ed.topForLine(line1) - ed.scrollTop
  st.hover.setStyle("display", "block")
  st.hover.setStyle("left", cstring($max(0.0, x) & "px"))
  st.hover.setStyle("top", cstring($top & "px"))
  st.hover.setStyle("transform", "translateY(-100%)")
  ed.root.setAttribute(cstring"data-ct-hover", cstring(text))

proc hoverAt(st: LspState; line1, column: int) {.async.} =
  ## What Monaco's hover shows at a position: the markers' messages there,
  ## the decorations' hover messages, and the server's hover.
  let ed = st.ed
  let lineText = ed.lineText(line1)
  let byteCol = byteColumnOf(lineText, column)
  var parts: seq[string] = @[]
  for m in ed.markers:
    if (line1 > m.line or (line1 == m.line and column >= m.col)) and
       (line1 < m.endLine or (line1 == m.endLine and column <= m.endCol)):
      parts.add m.message
  let offset = ed.offsetAt(line1, column)
  for e in ed.decos.entries:
    if e.options.hoverMessage.len == 0: continue
    let r = ed.decos.rangeOf(e.id)
    if r.found and r.fromOffset <= offset and offset <= r.toOffset:
      parts.add e.options.hoverMessage
  if st.ready and wordAt(lineText, byteCol).found:
    let (kind, _) = st.target()
    try:
      let res = await lspSend(cstring(kind), "textDocument/hover",
                              st.posParams(offset))
      if not isNilOrUndef(res):
        let t = textOfHover(res["contents"]).strip
        if t.len > 0: parts.add t
    except:
      lspFailed("textDocument/hover")
  # The pointer moved on while the server answered.
  if st.hoverAt != (line1, column): return
  if parts.len > 0:
    st.showHover(parts.join("\n\n"), line1, byteCol)
  else:
    st.hideHover()

proc onMouseMove(st: LspState; ev: JsObject) =
  let t = ev["target"]
  if isNilOrUndef(t) or isNilOrUndef(t["position"]) or
     int(jsNum(t["type"])) != 6:
    st.hideHover()
    st.hoverAt = (0, 0)
    return
  let at = (int(jsNum(t["position"]["lineNumber"])),
            int(jsNum(t["position"]["column"])))
  if at == st.hoverAt: return
  st.hoverAt = at
  st.hideHover()
  if st.hoverTimer != 0: clearTimeoutJs(st.hoverTimer)
  st.hoverTimer = setTimeoutJs(proc() =
    st.hoverTimer = 0
    discard st.hoverAt(at[0], at[1]), HoverDelayMs)

# ---------------------------------------------------------------------------
# Completion
# ---------------------------------------------------------------------------

proc closeSuggest(st: LspState) =
  if not st.suggest.isNil:
    st.suggest.setStyle("display", "none")
  st.items = @[]
  st.ed.root.removeAttribute(cstring"data-ct-suggest")

proc drawSuggest(st: LspState) =
  let ed = st.ed
  if st.suggest.isNil:
    st.suggest = createEl("div")
    st.suggest.className = cstring"suggest-widget ct-suggest"
    st.suggest.setAttribute(cstring"role", cstring"listbox")
    st.suggest.setStyle("position", "absolute")
    st.suggest.setStyle("z-index", "30")
    st.suggest.setStyle("max-height", "240px")
    st.suggest.setStyle("overflow", "auto")
    discard ed.root.appendChild(st.suggest)
  st.suggest.textContent = cstring""
  for i, it in st.items:
    let row = createEl("div")
    row.className = cstring(if i == st.selected: "monaco-list-row focused" else: "monaco-list-row")
    row.setAttribute(cstring"role", cstring"option")
    row.setAttribute(cstring"aria-selected", cstring($(i == st.selected)))
    row.textContent = cstring(it.label & (if it.detail.len > 0: "  " & it.detail else: ""))
    let idx = i
    row.addEventListener(cstring"mousedown", proc(ev: JsObject) =
      discard ev.preventDefault()
      st.selected = idx
      st.drawSuggest())
    discard st.suggest.appendChild(row)
  let p = ed.positionAt(st.replaceFrom)
  let x = ed.xOfByteCol(p.lineNumber, st.replaceFrom - ed.offsetAt(p.lineNumber, 1)) +
          float(ed.gutterPx) - float(ed.scrollLeft)
  st.suggest.setStyle("display", "block")
  st.suggest.setStyle("left", cstring($x & "px"))
  st.suggest.setStyle("top", cstring($(ed.topForLine(p.lineNumber) - ed.scrollTop +
                                       ed.lineHeight) & "px"))
  ed.root.setAttribute(cstring"data-ct-suggest", cstring($st.items.len))

proc acceptSuggest(st: LspState) =
  if st.selected < 0 or st.selected >= st.items.len: return
  let it = st.items[st.selected]
  let a = st.replaceFrom
  let b = st.ed.doc.state.primaryHead
  st.closeSuggest()
  discard st.ed.runCoreStep("suggest", proc(d: var EditingDocument): EditingOutcome =
    d.selectSpan(a, max(a, b))
    d.applyNamed("insert-text", OpArgs(text: it.insert), int64(nowMs())))

proc requestSuggest(st: LspState) {.async.} =
  let ed = st.ed
  if not st.ready or ed.readOnly: return
  let head = ed.doc.state.primaryHead
  let p = ed.positionAt(head)
  let line = ed.lineText(p.lineNumber)
  let col = head - ed.offsetAt(p.lineNumber, 1)
  var a = col
  while a > 0 and (line[a - 1].isAlphaNumeric or line[a - 1] == '_'): dec a
  let prefix = line[a ..< col]
  let (kind, _) = st.target()
  var res: JsObject
  try:
    res = await lspSend(cstring(kind), "textDocument/completion", st.posParams(head))
  except:
    lspFailed("request")
    return
  if isNilOrUndef(res): return
  let list = if isArray(res): res else: res["items"]
  if isNilOrUndef(list): return
  var items: seq[tuple[label, insert, detail: string]] = @[]
  for i in 0 ..< jsLen(list):
    let it = list[i]
    let label = s(it["label"])
    var insert = s(it["insertText"])
    if not isNilOrUndef(it["textEdit"]) and not isNilOrUndef(it["textEdit"]["newText"]):
      insert = s(it["textEdit"]["newText"])
    if insert.len == 0: insert = label
    if prefix.len > 0 and not label.toLowerAscii.startsWith(prefix.toLowerAscii):
      continue
    items.add (label, insert, s(it["detail"]))
  if items.len == 0 or ed.doc.state.primaryHead != head:
    st.closeSuggest()
    return
  st.items = items
  st.selected = 0
  st.replaceFrom = head - (col - a)
  st.drawSuggest()

proc suggestKey(st: LspState; name: string): bool =
  ## The suggestion list's keys while it is open (Monaco's): the arrows
  ## move, Enter and Tab accept, Escape closes. Any other key closes it and
  ## goes on to the document.
  if st.items.len == 0: return false
  case name
  of "Down":
    st.selected = (st.selected + 1) mod st.items.len
    st.drawSuggest()
    true
  of "Up":
    st.selected = (st.selected - 1 + st.items.len) mod st.items.len
    st.drawSuggest()
    true
  of "Enter", "Tab":
    st.acceptSuggest()
    true
  of "Esc":
    st.closeSuggest()
    true
  else:
    st.closeSuggest()
    false

# ---------------------------------------------------------------------------
# Go to definition, rename, format
# ---------------------------------------------------------------------------

proc firstLocation(res: JsObject): JsObject =
  if isNilOrUndef(res): return nil
  if isArray(res):
    if jsLen(res) == 0: return nil
    return res[0]
  res

proc goToDefinition*(st: LspState; at = -1) {.async.} =
  ## The definition of the symbol at `at` (the caret when -1).
  if not st.ready: return
  let (kind, uri) = st.target()
  let offset = if at >= 0: at else: st.ed.doc.state.primaryHead
  var res: JsObject
  try:
    res = await lspSend(cstring(kind), "textDocument/definition",
                        st.posParams(offset))
  except:
    lspFailed("request")
    return
  let loc = firstLocation(res)
  if loc.isNil: return
  let targetUri = if not isNilOrUndef(loc["targetUri"]): s(loc["targetUri"]) else: s(loc["uri"])
  let rng = if not isNilOrUndef(loc["targetSelectionRange"]): loc["targetSelectionRange"]
            else: loc["range"]
  if isNilOrUndef(rng): return
  if targetUri == uri:
    let off = st.ed.offsetOfLsp(rng["start"])
    st.ed.setSelectionOffsets(off, off)
    st.ed.revealLine(st.ed.positionAt(off).lineNumber, center = true)
  elif not st.openLocation.isNil:
    var path = targetUri
    if path.startsWith("file://"): path = path[7 .. ^1]
    st.openLocation(path, int(jsNum(rng["start"]["line"])) + 1,
                    int(jsNum(rng["start"]["character"])) + 1)

proc applyTextEdits(st: LspState; edits: JsObject): bool =
  ## A server's `TextEdit[]` for this document, as ONE change.
  if isNilOrUndef(edits) or jsLen(edits) == 0: return false
  var es: seq[Edit] = @[]
  for i in 0 ..< jsLen(edits):
    let e = edits[i]
    let a = st.ed.offsetOfLsp(e["range"]["start"])
    let b = st.ed.offsetOfLsp(e["range"]["end"])
    es.add Edit(fromPos: min(a, b), toPos: max(a, b), insert: s(e["newText"]))
  var changed = false
  discard st.ed.runCoreStep("lsp", proc(d: var EditingDocument): EditingOutcome =
    changed = d.applyChangeSet(changeSetOrdered(d.state.doc.len, es),
                               int64(nowMs()))
    if changed: eoChanged else: eoIgnored)
  changed

proc renameAtCaret*(st: LspState; newName: string) {.async.} =
  if not st.ready or st.ed.readOnly or newName.len == 0: return
  let (kind, uri) = st.target()
  let params = st.posParams(st.ed.doc.state.primaryHead)
  params["newName"] = cstring(newName)
  var res: JsObject
  try:
    res = await lspSend(cstring(kind), "textDocument/rename", params)
  except:
    lspFailed("request")
    return
  if isNilOrUndef(res): return
  if not isNilOrUndef(res["changes"]) and not isNilOrUndef(res["changes"][cstring(uri)]):
    discard st.applyTextEdits(res["changes"][cstring(uri)])
  elif not isNilOrUndef(res["documentChanges"]):
    let dc = res["documentChanges"]
    for i in 0 ..< jsLen(dc):
      if s(dc[i]["textDocument"]["uri"]) == uri:
        discard st.applyTextEdits(dc[i]["edits"])

proc showRenameField*(st: LspState) =
  ## Monaco's rename widget: a field at the caret, seeded with the symbol;
  ## Enter renames through the server, Escape closes.
  let ed = st.ed
  if ed.readOnly or not st.ready: return
  let head = ed.doc.state.primaryHead
  let p = ed.positionAt(head)
  let line = ed.lineText(p.lineNumber)
  let w = wordAt(line, head - ed.offsetAt(p.lineNumber, 1))
  let field = createEl("input")
  field.className = cstring"rename-input ct-rename-input"
  field.setAttribute(cstring"aria-label", cstring"Rename Symbol")
  field.value = cstring(if w.found: line[w.a ..< w.b] else: "")
  field.setStyle("position", "absolute")
  field.setStyle("z-index", "30")
  field.setStyle("left", cstring($(ed.xOfByteCol(p.lineNumber, (if w.found: w.a else: 0)) +
                                   float(ed.gutterPx) - float(ed.scrollLeft)) & "px"))
  field.setStyle("top", cstring($(ed.topForLine(p.lineNumber) - ed.scrollTop +
                                  ed.lineHeight) & "px"))
  discard ed.root.appendChild(field)
  proc close() =
    {.emit: ["if (", field, ".parentNode) ", field, ".parentNode.removeChild(", field, ");"].}
    ed.focusEditor()
  field.addEventListener(cstring"keydown", proc(ev: JsObject) =
    let key = s(ev["key"])
    if key == "Enter":
      discard ev.preventDefault()
      discard ev.stopPropagation()
      let name = s(field.value)
      close()
      discard st.renameAtCaret(name)
    elif key == "Escape":
      discard ev.preventDefault()
      discard ev.stopPropagation()
      close())
  discard field.focus()
  discard field.select()

proc formatDocument*(st: LspState) {.async.} =
  if not st.ready or st.ed.readOnly: return
  let (kind, uri) = st.target()
  let params = jsNew()
  let td = jsNew()
  td["uri"] = cstring(uri)
  params["textDocument"] = td
  let opts = jsNew()
  opts["tabSize"] = 4
  opts["insertSpaces"] = true
  params["options"] = opts
  var res: JsObject
  try:
    res = await lspSend(cstring(kind), "textDocument/formatting", params)
  except:
    lspFailed("request")
    return
  discard st.applyTextEdits(res)

# ---------------------------------------------------------------------------
# Semantic tokens
# ---------------------------------------------------------------------------

proc installSemanticStyles() =
  ## One rule per semantic token type and theme, coloured as the editor theme
  ## colours the scope of that name (Monaco's semantic highlighting reads the
  ## theme's rules by token type). A type the theme has no rule for keeps the
  ## Monarch colour.
  var present = false
  {.emit: [present, " = !!document.getElementById('ct-shared-editor-semantic');"].}
  if present: return
  var css = ""
  for dark in [true, false]:
    let scope = if dark: ".ct-shared-editor.vs-dark" else: ".ct-shared-editor.vs"
    for t in SemanticTokenTypes:
      let token = editorScopeToken(t)
      if token == dtEditorThemeRuleDefault: continue
      let hex = DesignTokenHex[token][if dark: dmDark else: dmLight]
      css.add scope & " .ct-sem-" & t & " { color: " & hex & " !important; }\n"
  let el = createEl("style")
  el.id = cstring"ct-shared-editor-semantic"
  el.textContent = cstring(css)
  {.emit: ["(document.head || document.documentElement).appendChild(", el, ");"].}

proc requestSemantic(st: LspState) {.async.} =
  let ed = st.ed
  if not st.ready or ed.visible.len == 0: return
  let (kind, uri) = st.target()
  if not serverHas(cstring(kind), "semanticTokensProvider"): return
  let version = ed.doc.timeline.version
  let first = ed.visible[0]
  let last = ed.visible[^1]
  let key = $ordinal(version) & ":" & $first & ":" & $last
  if key == st.semanticAsked: return
  let params = jsNew()
  let td = jsNew()
  td["uri"] = cstring(uri)
  params["textDocument"] = td
  let rng = jsNew()
  let a = jsNew()
  a["line"] = first - 1
  a["character"] = 0
  let b = jsNew()
  b["line"] = last
  b["character"] = 0
  rng["start"] = a
  rng["end"] = b
  params["range"] = rng
  var res: JsObject
  try:
    res = await lspSend(cstring(kind), "textDocument/semanticTokens/range", params)
  except:
    lspFailed("request")
    return
  if isNilOrUndef(res) or isNilOrUndef(res["data"]) or
     ed.doc.timeline.version != version:
    return
  # LSP's relative encoding: (deltaLine, deltaStart, length, type, modifiers).
  let data = res["data"]
  var spans = initTable[int, seq[tuple[fromCol, toCol: int; cls: string]]]()
  var line = 0
  var start = 0
  var i = 0
  let n = jsLen(data)
  while i + 4 < n:
    let dl = int(jsNum(data[i]))
    let ds = int(jsNum(data[i + 1]))
    let len16 = int(jsNum(data[i + 2]))
    let typ = int(jsNum(data[i + 3]))
    if dl > 0:
      line += dl
      start = ds
    else:
      start += ds
    i += 5
    if typ < 0 or typ >= SemanticTokenTypes.len: continue
    let text = ed.lineText(line + 1)
    let fc = byteColumnOf(text, start + 1)
    let tc = byteColumnOf(text, start + len16 + 1)
    if tc > fc:
      spans.mgetOrPut(line, @[]).add (fc, tc, "ct-sem-" & SemanticTokenTypes[typ])
  st.semanticAsked = key
  ed.semanticSpans = spans
  ed.semanticVersion = version
  ed.requestRender()

proc onRender(st: LspState) =
  if st.semanticTimer != 0: clearTimeoutJs(st.semanticTimer)
  st.semanticTimer = setTimeoutJs(proc() =
    st.semanticTimer = 0
    discard st.requestSemantic(), SemanticDebounceMs)

# ---------------------------------------------------------------------------
# Installation
# ---------------------------------------------------------------------------

var states: Table[int, LspState]

proc lspStateOf*(ed: SharedEditor): LspState =
  states.getOrDefault(ed.id, nil)

proc installSharedEditorLsp*(ed: SharedEditor; target: LspTarget;
                             openLocation: OpenLocation = nil) =
  ## Give `ed` the language server's features, through `target`'s server.
  let st = LspState(ed: ed, target: target, openLocation: openLocation,
                    selected: -1)
  states[ed.id] = st
  installSemanticStyles()
  discard ed.on("mouseMove", toJs(proc(ev: JsObject) = st.onMouseMove(ev)))
  discard ed.on("mouseDown", toJs(proc(ev: JsObject) =
    # Ctrl+click (Cmd+click) on a symbol: Monaco's go to definition. In a
    # read-only (Debug) editor the press is the debugger's line jump
    # (Editor-Pane.md MC.6), so only a writable editor takes it.
    let e = ev["event"]
    let t = ev["target"]
    if ed.readOnly or isNilOrUndef(t) or int(jsNum(t["type"])) != 6: return
    if not (e["ctrlKey"].to(bool) or e["metaKey"].to(bool)): return
    if e["altKey"].to(bool) or e["shiftKey"].to(bool): return
    let at = ed.offsetAt(int(jsNum(t["position"]["lineNumber"])),
                         int(jsNum(t["position"]["column"])))
    discard st.goToDefinition(at)))
  discard ed.on("mouseLeave", toJs(proc(ev: JsObject) =
    st.hoverAt = (0, 0)
    st.hideHover()))
  discard ed.on("scroll", toJs(proc(ev: JsObject) = st.hideHover()))
  discard ed.on("render", toJs(proc(ev: JsObject) = st.onRender()))
  discard ed.on("content", toJs(proc(ev: JsObject) =
    st.hideHover()
    # A trigger character typed: the list opens (Monaco's `.` trigger).
    let changes = ev["changes"]
    if jsLen(changes) == 1 and s(changes[0]["text"]) == ".":
      discard st.requestSuggest()
    elif st.items.len > 0:
      discard st.requestSuggest()))
  ed.keyInterceptor = proc(name: string): bool = st.suggestKey(name)
  ed.textarea.addEventListener(cstring"keydown", proc(ev: JsObject) =
    # Keys the router left to the editor (Monaco's own bindings).
    let key = s(ev["key"])
    let ctrl = ev["ctrlKey"].to(bool) or ev["metaKey"].to(bool)
    if ctrl and key == " ":
      discard ev.preventDefault()
      discard st.requestSuggest()
    elif key == "F12" and not ctrl and not ev["shiftKey"].to(bool):
      discard ev.preventDefault()
      discard st.goToDefinition())
  # The context menu's language rows (`editor.monacoActionIsSupported`).
  for (id, label) in [("editor.action.rename", "Rename Symbol"),
                      ("editor.action.formatDocument", "Format Document"),
                      ("editor.action.revealDefinition", "Go to Definition")]:
    let action = jsNew()
    let theId = id
    action["id"] = cstring(id)
    action["label"] = cstring(label)
    action["isSupported"] = proc(): bool =
      st.ready and (theId == "editor.action.revealDefinition" or not ed.readOnly)
    action["run"] = proc(): JsObject =
      case theId
      of "editor.action.formatDocument": discard st.formatDocument()
      of "editor.action.revealDefinition": discard st.goToDefinition()
      of "editor.action.rename": st.showRenameField()
      else: discard
      nil
    ed.actionsTable[id] = action

