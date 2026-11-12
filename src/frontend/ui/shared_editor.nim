## ui/shared_editor.nim — the shared editing core on the desktop, drawn as DOM.
##
## The desktop's editor pane has two editors behind the developer setting
## `sharedEditor` (`ui/shared_editor_flag`): Monaco, the default, and this
## one — the editing core the terminal draws as cells and GPUI as elements
## (`viewmodel/editing_core`, Editor-ViewModel.md §3.2), drawn here as the
## browser's own elements.
##
## ## THE CONTRACT IS MONACO'S API
##
## `ui/editor`, `ui/flow`, `ui/trace` and the LSP router drive the editor
## through the part of Monaco's `ICodeEditor` they use (`lib/monaco_lib
## .MonacoEditor`): decorations, view zones, content widgets, reveal, the
## mouse and content events. This module answers that API (`facadeOf`) over
## the shared core, so the pane chooses an editor at ONE call
## (`editor.initMonacoForEditor`) and everything else in the desktop — the
## flow panel, the tracepoint editors, the value chips, the gutter's
## breakpoints, the context menu — runs unchanged against either. That is
## also what makes "drop Monaco later" a deletion rather than a port.
##
## The DOM keeps Monaco's structure and class names (`monaco-editor`,
## `.margin-view-overlays`, `.view-lines > .view-line`, `.view-overlays`,
## `.view-zones`, `.cursors-layer`, `.inputarea`), so the desktop's
## stylesheets, its theme's CSS variables and the Playwright page objects
## read either editor alike.
##
## ## WHAT IS THE CORE'S
##
## The text, the selections, every editing operation, undo, folding state,
## the modal state (Vim / Kakoune) and the pointer's meaning are the core's:
## keys reach `EditingDocument.applyKey` / `applyResolved` (through
## `ui/key_router`, PLAT-64's router), presses reach `editor_pointer
## .pressEditor`, composition and clipboard text reach the `insert-text` and
## `clipboard-paste` operations. The decorations live in the core's
## `DecorationSet` (`view_vocabulary/editor_dom_frame.DecorationTable`) and
## move through edits by its mapping. The syntax colours are the Monarch
## runner's (`lexical.tokenRuns`, PLAT-47). Nothing here edits text itself.
##
## ## NO MOCKS
##
## The renderer suites (`tests/shared_editor_chromium_test.nim`) run this
## module in a real Chromium page against the real core.

import std/[jsffi, tables, strutils, math]

import ../viewmodel/editing_core
import ../viewmodel/editor/[selection, document_version, change_set]
import ../viewmodel/input/editor_pointer
import ../viewmodel/keymap/[editing_keymap, context_keys, base_keymaps]
import ../view_vocabulary/editor_dom_frame
import ../viewmodel/viewmodels/find_vm
import ../viewmodel/editor/find_match
import ../tui/app/syntax/[lexical, token_class]
import ../tui/app/theme/editor_theme
import ../styles/generated/design_tokens

export editor_dom_frame.DecoOptions

# ---------------------------------------------------------------------------
# JavaScript helpers
# ---------------------------------------------------------------------------

proc jsNew(): JsObject {.importjs: "({})@".}
proc jsArray(): JsObject {.importjs: "([])@".}
proc jsPush(a, v: JsObject) {.importjs: "#.push(#)".}
proc jsLen(a: JsObject): int {.importjs: "(#.length|0)".}
proc createEl(tag: cstring): JsObject {.importjs: "document.createElement(#)".}
proc createText(s: cstring): JsObject {.importjs: "document.createTextNode(#)".}
proc appendChild(p, c: JsObject) {.importjs: "#.appendChild(#)".}
proc removeEl(e: JsObject) {.importjs: "((e) => e && e.parentNode && e.parentNode.removeChild(e))(#)".}
proc clearChildren(e: JsObject) {.importjs: "(#.textContent = '')".}
proc setAttr(e: JsObject; k, v: cstring) {.importjs: "#.setAttribute(#, #)".}
proc setStyle(e: JsObject; k, v: cstring) {.importjs: "#.style.setProperty(#, #)".}
proc setClass(e: JsObject; v: cstring) {.importjs: "(#.className = #)".}
proc setHtml(e: JsObject; v: cstring) {.importjs: "(#.innerHTML = #)".}
proc addListener(e: JsObject; ev: cstring; f: proc(ev: JsObject);
                 capture = false) {.importjs: "#.addEventListener(#, #, #)".}
proc removeListener(e: JsObject; ev: cstring; f: proc(ev: JsObject);
                    capture = false) {.importjs: "#.removeEventListener(#, #, #)".}
proc rectOf(e: JsObject): JsObject {.importjs: "#.getBoundingClientRect()".}
proc nowMs(): float {.importjs: "Date.now()@".}
proc jsNum(v: JsObject): float {.importjs: "Number(#)".}
proc isNilOrUndef(v: JsObject): bool {.importjs: "(# == null)".}
proc callFn(f: JsObject; a: JsObject): JsObject {.importjs: "#(#)".}
proc callFn0(f: JsObject): JsObject {.importjs: "#()".}
proc callMethod0(o: JsObject; name: cstring): JsObject {.importjs: "#[#]()".}
proc hasFn(o: JsObject; name: cstring): bool {.importjs:
  "((o, n) => o != null && typeof o[n] === 'function')(#, #)".}
proc docActive(): JsObject {.importjs: "(document.activeElement)@".}
proc contains(a, b: JsObject): bool {.importjs: "((a, b) => !!a && !!b && a.contains(b))(#, #)".}
proc queueRender(f: proc()) {.importjs: "queueMicrotask(#)".}
proc rafLater(f: proc()) {.importjs: "((f) => (typeof requestAnimationFrame === 'function') ? requestAnimationFrame(f) : setTimeout(f, 16))(#)".}
proc setTimeoutJs(f: proc(); ms: int): int {.importjs: "setTimeout(#, #)".}
proc caretRangeAt(x, y: float): JsObject {.importjs: """
  (function(x, y){
    if (document.caretRangeFromPoint) return document.caretRangeFromPoint(x, y);
    if (document.caretPositionFromPoint) {
      const p = document.caretPositionFromPoint(x, y);
      return p ? {startContainer: p.offsetNode, startOffset: p.offset} : null;
    }
    return null;
  })(#, #)""".}
proc textNodeX(node: JsObject; offset: int): float {.importjs: """
  (function(node, offset){
    const r = document.createRange();
    const len = node.length || 0;
    const o = Math.max(0, Math.min(offset, len));
    r.setStart(node, o); r.setEnd(node, o);
    const rects = r.getClientRects();
    if (rects.length > 0) return rects[0].left;
    if (len > 0) {
      const r2 = document.createRange();
      if (o >= len) { r2.setStart(node, len - 1); r2.setEnd(node, len); return r2.getBoundingClientRect().right; }
      r2.setStart(node, o); r2.setEnd(node, o + 1); return r2.getBoundingClientRect().left;
    }
    return node.parentNode ? node.parentNode.getBoundingClientRect().left : 0;
  })(#, #)""".}
proc utf16Len(s: cstring): int {.importjs: "(#.length)".}
proc jsStr(v: JsObject): cstring {.importjs: "String(#)".}
proc toCs(s: string): cstring = cstring(s)

const
  ## Monaco's `MouseTargetType`.
  mtUnknown = 0
  mtTextarea = 1
  mtGutterGlyphMargin = 2
  mtGutterLineNumbers = 3
  mtGutterLineDecorations = 4
  mtGutterViewZone = 5
  mtContentText = 6
  mtContentEmpty = 7
  mtContentViewZone = 8
  mtContentWidget = 9
  mtScrollbar = 11
  mtOverlayWidget = 12

  GlyphMarginPx = 18
  LineDecorationsPx = 10
  FoldingPx = 16
  ScrollbarPx = 14
  SharedEditorAttribute* = "data-ct-shared-editor"
    ## On the editor's root: present on the shared editor, never on Monaco's.
  DesktopDelivery* = KeyDelivery(frontEnd: feDesktop, platform: hostPlatform(),
                                 keyProtocol: kpNative)

# ---------------------------------------------------------------------------
# The editor
# ---------------------------------------------------------------------------

type
  ZoneRec = object
    id: int
    afterLine: int
    heightPx: int
    domNode: JsObject
    marginNode: JsObject
    spec: JsObject

  WidgetRec = object
    widget: JsObject
    node: JsObject
    overlay: bool

  Listener = object
    id: int
    f: JsObject

  SharedEditor* = ref object
    id*: int
    doc*: EditingDocument
    index: LineIndex
    decos*: DecorationTable
    path*: string
    languageId*: string
    lexer: LexerId
    readOnly*: bool
    options*: JsObject
    lineNumbersFn: JsObject
    darkTheme*: bool
    # DOM
    host*, root*, guard, margin, marginOverlays, glyphLayer, scrollable, linesContent,
      overlays, zonesLayer, linesLayer, widgetsLayer, cursorsLayer,
      textarea*, vbar, vslider, hbar, hslider, overlayWidgetsLayer,
      measureSpan: JsObject
    lineHeight*: int
    charWidth*: float
    fontSize*: int
    gutterPx*: int
    numberChars: int
    scrollTop*, scrollLeft*: int
    width*, height*: int
    contentWidthPx: int
    zones: seq[ZoneRec]
    nextZoneId: int
    widgets: seq[WidgetRec]
    listeners: Table[string, seq[Listener]]
    nextListenerId: int
    # tokens
    contexts: seq[string]
    lineRuns: seq[seq[TokenRun]]
      ## lineRuns[i]: line i's tokens, valid for i < contextsValid.
    contextsValid: int
      ## contexts[0 .. contextsValid] are the tokenizer states at the start of
      ## those lines.
    # input
    pointer*: EditorPointerState
    focused*: bool
    composing*: bool
    renderQueued: bool
    disposed*: bool
    model*: JsObject
    facade*: JsObject
    visible*: seq[int]
      ## the 1-based lines drawn by the last render
    contextKeys: Table[string, JsObject]
    markers*: seq[tuple[severity: int; line, col, endLine, endCol: int;
                       message: string]]
    actions: Table[string, JsObject]
    lastVersionSeen: DocumentVersion
    revealOnRender: bool
    lastCaretLine: int
    hoverDeco: string
    renders*: int
      ## How many frames were drawn (a suite reads it).
    find*: FindVM
      ## The editor's find session — the shared one the terminal and GPUI
      ## run (`viewmodels/find_vm`, Find-And-Incremental-Search.md).
    findWidget*, findInput*, replaceInput*, findCount: JsObject
    replaceShown*: bool
    keyInterceptor*: proc(name: string): bool
      ## A widget that owns some keys while it is open (the suggestion list):
      ## asked first, by the key router, for a key in the text area.
    semanticVersion*: DocumentVersion
    semanticSpans*: Table[int, seq[tuple[fromCol, toCol: int; cls: string]]]
      ## A language server's semantic tokens on the drawn lines, by 0-based
      ## line, as byte columns and the class that paints the token type —
      ## valid for `semanticVersion` only.

var
  sharedEditors*: seq[SharedEditor] = @[]
    ## Every live shared editor, newest last.
  nextEditorId = 1
  onSharedEditorFocus*: proc(ed: SharedEditor) = nil

proc sameString(s: string): string {.importjs: "#".}
  ## `s` itself, not a copy: on the JS backend a string is an array and
  ## binding it to a `let` copies it, which for a large document is the
  ## largest cost of a keystroke. The core never mutates a document string in
  ## place — every change builds a new one — so the reference stays the text
  ## of the version it was taken at.

proc text*(ed: SharedEditor): string = sameString(ed.doc.state.doc)

proc ensureIndex(ed: SharedEditor) =
  let v = ed.doc.timeline.version
  if not ed.index.built or ed.index.version != v or
     ed.index.textLen != ed.doc.state.doc.len:
    ed.index = buildLineIndex(ed.doc.state.doc, v)

proc lineCount*(ed: SharedEditor): int =
  ed.ensureIndex()
  ed.index.lineCount

proc lineText*(ed: SharedEditor; line1: int): string =
  ed.ensureIndex()
  ed.index.lineText(ed.doc.state.doc, line1 - 1)

proc offsetAt*(ed: SharedEditor; line1, column: int): int =
  ed.ensureIndex()
  ed.index.offsetOfPosition(ed.doc.state.doc, line1, column)

proc positionAt*(ed: SharedEditor; offset: int): tuple[lineNumber, column: int] =
  ed.ensureIndex()
  ed.index.positionOfOffset(ed.doc.state.doc, offset)

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

proc listen(ed: SharedEditor; name: string; f: JsObject): JsObject =
  inc ed.nextListenerId
  let id = ed.nextListenerId
  ed.listeners.mgetOrPut(name, @[]).add Listener(id: id, f: f)
  let disposable = jsNew()
  disposable["dispose"] = proc() =
    if ed.listeners.hasKey(name):
      var kept: seq[Listener] = @[]
      for l in ed.listeners[name]:
        if l.id != id: kept.add l
      ed.listeners[name] = kept
  disposable

proc fire(ed: SharedEditor; name: string; ev: JsObject) =
  if not ed.listeners.hasKey(name): return
  let ls = ed.listeners[name]
  for l in ls:
    try:
      discard callFn(l.f, ev)
    except CatchableError:
      discard

# ---------------------------------------------------------------------------
# Tokens
# ---------------------------------------------------------------------------

proc invalidateTokensFrom(ed: SharedEditor; line0: int) =
  ed.contextsValid = min(ed.contextsValid, max(0, line0))
  if ed.contexts.len > ed.contextsValid + 1:
    ed.contexts.setLen(ed.contextsValid + 1)
  if ed.lineRuns.len > ed.contextsValid:
    ed.lineRuns.setLen(ed.contextsValid)

proc contextAt(ed: SharedEditor; line0: int; budgetMs = 30.0): tuple[ctx: string; exact: bool] =
  ## The tokenizer state at the start of `line0`, tokenizing forward from the
  ## last known state for at most `budgetMs` (Monaco tokenizes in the
  ## background the same way; a line beyond the budget is drawn from the
  ## nearest state and redrawn when the tokenizer gets there).
  if ed.lexer == lxNone: return ("", true)
  if ed.contexts.len == 0:
    ed.contexts = @[""]
    ed.contextsValid = 0
  let started = nowMs()
  while ed.contextsValid < line0:
    var ctx = ed.contexts[ed.contextsValid]
    let runs = tokenRuns(ed.lexer, ed.index.lineText(ed.doc.state.doc,
                                                     ed.contextsValid), ctx)
    if ed.lineRuns.len <= ed.contextsValid: ed.lineRuns.add runs
    else: ed.lineRuns[ed.contextsValid] = runs
    if ed.contexts.len <= ed.contextsValid + 1: ed.contexts.add ctx
    else: ed.contexts[ed.contextsValid + 1] = ctx
    inc ed.contextsValid
    if nowMs() - started > budgetMs and ed.contextsValid < line0:
      return (ed.contexts[ed.contextsValid], false)
  (ed.contexts[line0], true)

proc tokenColour*(ed: SharedEditor; cls: TokenClass): string =
  let t = tokenClassToken(cls)
  DesignTokenHex[t][if ed.darkTheme: dmDark else: dmLight]

# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

proc layoutNow(ed: SharedEditor): VerticalLayout =
  ed.ensureIndex()
  var zs: seq[ZoneSpec] = @[]
  for z in ed.zones:
    zs.add ZoneSpec(id: z.id, afterLine: z.afterLine, heightPx: z.heightPx)
  let hidden = hiddenRanges(ed.index, ed.doc.state.doc, ed.doc.state.folded)
  verticalLayout(ed.index.lineCount, ed.lineHeight, hidden, zs)

proc topForLine*(ed: SharedEditor; line1: int): int =
  ed.layoutNow.topOfLine(line1)

proc contentHeight*(ed: SharedEditor): int =
  ed.layoutNow.contentHeight

proc textViewportHeight(ed: SharedEditor): int = max(0, ed.height)
proc textViewportWidth(ed: SharedEditor): int =
  max(0, ed.width - ed.gutterPx - ScrollbarPx)

proc maxScrollTop(ed: SharedEditor): int =
  ## Monaco's: with `scrollBeyondLastLine` (its default) the last line can
  ## scroll up to the top of the view; without it, to the bottom.
  let beyond = ed.options.isNil or isNilOrUndef(ed.options["scrollBeyondLastLine"]) or
               ed.options["scrollBeyondLastLine"].to(bool)
  if beyond: max(0, ed.contentHeight - ed.lineHeight)
  else: max(0, ed.contentHeight - ed.textViewportHeight)

proc scrollHeightPx*(ed: SharedEditor): int =
  ## Monaco's `getScrollHeight`: what the view can scroll through.
  ed.maxScrollTop + ed.textViewportHeight

proc clampScroll(ed: SharedEditor) =
  ed.scrollTop = clamp(ed.scrollTop, 0, ed.maxScrollTop)
  ed.scrollLeft = clamp(ed.scrollLeft, 0,
                        max(0, ed.contentWidthPx - ed.textViewportWidth + ed.charWidth.int * 2))

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc render*(ed: SharedEditor)

proc requestRender*(ed: SharedEditor) =
  if ed.renderQueued or ed.disposed: return
  ed.renderQueued = true
  queueRender(proc() =
    ed.renderQueued = false
    if not ed.disposed: ed.render())

proc measureFont(ed: SharedEditor) =
  ## The editor font's cell width, measured in the editor's own element.
  if ed.measureSpan.isNil: return
  ed.measureSpan.textContent = cstring(repeat('x', 100))
  let w = jsNum(rectOf(ed.measureSpan).width)
  if w > 0: ed.charWidth = w / 100.0
  ed.measureSpan.textContent = cstring""

proc numberLabel(ed: SharedEditor; line1: int): cstring =
  if ed.lineNumbersFn.isNil or isNilOrUndef(ed.lineNumbersFn):
    return cstring($line1)
  let v = callFn(ed.lineNumbersFn, toJs(line1))
  if isNilOrUndef(v): cstring($line1) else: jsStr(v)

proc spanEl(ed: SharedEditor; s: FrameSpan): JsObject =
  let el = createEl("span")
  var cls = ""
  if s.kind == skText:
    cls = "mtk-" & $s.tokenClass
    if s.tokenClass != tcPlain:
      el.setStyle("color", toCs(ed.tokenColour(s.tokenClass)))
  for c in s.classes:
    if c.len > 0: cls.add " " & c
  if cls.len > 0: el.setClass(cstring(cls.strip))
  el.setAttr("data-col", cstring($s.fromCol))
  el.setAttr("data-kind", cstring($s.kind))
  el.appendChild(createText(cstring(s.text)))
  el

proc caretOffsets(ed: SharedEditor): seq[int] =
  for r in ed.doc.state.selection.ranges: result.add r.head

proc primaryOffset(ed: SharedEditor): int = ed.doc.state.primaryHead

proc lineElement(ed: SharedEditor; line1: int): JsObject =
  let q = ed.linesLayer.querySelector(cstring(".view-line[data-line=\"" & $line1 & "\"]"))
  if isNilOrUndef(q): nil else: q

proc xOfByteCol*(ed: SharedEditor; line1, byteCol: int): float =
  ## The x of byte column `byteCol` of a DRAWN line, relative to the text's
  ## left edge (`.lines-content`'s origin, scroll included), measured in the
  ## browser so tabs, wide glyphs and the font are the browser's own.
  let el = ed.lineElement(line1)
  let base = jsNum(rectOf(ed.linesContent).left)
  if el.isNil:
    return byteCol.float * ed.charWidth
  let spans = el.querySelectorAll(cstring("span[data-kind=\"skText\"]"))
  let n = jsLen(spans)
  let lineText = ed.lineText(line1)
  if n == 0:
    return 0.0
  for i in 0 ..< n:
    let sp = spans[i]
    let from0 = parseInt($jsStr(sp.getAttribute(cstring"data-col")))
    let tnode = sp.firstChild
    let len16 = utf16Len(jsStr(tnode.data))
    let spanBytes = len($jsStr(tnode.data))
    if byteCol <= from0 + spanBytes or i == n - 1:
      let within = clamp(byteCol - from0, 0, spanBytes)
      let sub = lineText[min(from0, lineText.len) ..< min(from0 + within, lineText.len)]
      let off16 = monacoColumnOf(sub, sub.len) - 1
      return textNodeX(tnode, min(off16, len16)) - base
  0.0

proc lineWidthPx(ed: SharedEditor; line1: int): float =
  let t = ed.lineText(line1)
  ed.xOfByteCol(line1, t.len)

var codiconProbe = -1

proc codiconFontPresent(): bool =
  ## Whether the page carries Monaco's codicon rules (the folding chevron's
  ## `::before` glyph), probed once.
  if codiconProbe < 0:
    var present = false
    {.emit: ["""(function(){ try { const e = document.createElement('div');
      e.className = 'codicon codicon-folding-expanded'; e.style.position = 'absolute';
      e.style.visibility = 'hidden'; document.body.appendChild(e);
      const c = getComputedStyle(e, '::before').content;
      """, present, """ = !!c && c !== 'none' && c !== 'normal' && c !== '""';
      e.remove(); } catch (_) {} })();"""].}
    codiconProbe = (if present: 1 else: 0)
  codiconProbe == 1

proc renderGutterLine(ed: SharedEditor; line1, top: int; deco: LineDecorations;
                      active, foldable, folded: bool;
                      highlighted = false): JsObject =
  let row = createEl("div")
  row.setStyle("position", "absolute")
  row.setStyle("top", cstring($top & "px"))
  row.setStyle("width", "100%")
  row.setStyle("height", cstring($ed.lineHeight & "px"))
  row.setAttr("data-line", cstring($line1))
  var mcls = ""
  for c in deco.marginClasses: mcls.add c & " "
  if active or highlighted: mcls.add "current-line-margin"
  if mcls.len > 0: row.setClass(cstring(mcls.strip))
  # Monaco's row: the current line's margin highlight, the line decorations
  # that exist, the number, and the folding control where a block starts —
  # an element only where there is something to draw, in this order, since
  # the page paints every `div` of the margin's rows with the gutter's
  # ground (`text_editor.styl`) and an empty cell would cover the number.
  if active or highlighted:
    let hl = createEl("div")
    hl.setClass("current-line current-line-margin-both")
    hl.setStyle("width", cstring($ed.gutterPx & "px"))
    row.appendChild(hl)
  if deco.lineDecoClasses.len > 0:
    let ldeco = createEl("div")
    var lcls = "cldr"
    for c in deco.lineDecoClasses: lcls.add " " & c
    ldeco.setClass(cstring(lcls))
    ldeco.setStyle("position", "absolute")
    ldeco.setStyle("left", cstring($(ed.gutterPx - LineDecorationsPx - FoldingPx) & "px"))
    ldeco.setStyle("width", cstring($LineDecorationsPx & "px"))
    ldeco.setStyle("height", cstring($ed.lineHeight & "px"))
    ldeco.setAttr("data-ct-target", "decorations")
    row.appendChild(ldeco)
  let num = createEl("div")
  num.setClass(cstring(if active: "line-numbers active-line-number" else: "line-numbers"))
  num.setStyle("position", "absolute")
  num.setStyle("left", cstring($GlyphMarginPx & "px"))
  num.setStyle("width", cstring($(ed.gutterPx - GlyphMarginPx - LineDecorationsPx - FoldingPx) & "px"))
  num.setStyle("height", cstring($ed.lineHeight & "px"))
  num.setStyle("line-height", cstring($ed.lineHeight & "px"))
  num.setAttr("data-ct-target", "number")
  num.setHtml(ed.numberLabel(line1))
  row.appendChild(num)
  if foldable:
    let fold = createEl("div")
    fold.setStyle("position", "absolute")
    fold.setStyle("left", cstring($(ed.gutterPx - FoldingPx) & "px"))
    fold.setStyle("top", "0px")
    fold.setStyle("width", cstring($FoldingPx & "px"))
    fold.setStyle("height", cstring($ed.lineHeight & "px"))
    fold.setAttr("data-ct-target", "fold")
    fold.setClass(cstring(if folded: "cldr codicon codicon-folding-collapsed ct-fold-toggle"
                          else: "cldr codicon codicon-folding-expanded ct-fold-toggle"))
    fold.setAttr("data-folded", cstring(if folded: "true" else: "false"))
    # The chevron is the codicon font's where the page has Monaco's styles;
    # a page without them gets a character.
    if not codiconFontPresent():
      fold.textContent = cstring(if folded: "›" else: "˅")
    row.appendChild(fold)
  row

proc glyphCell(ed: SharedEditor; line1, top: int; deco: LineDecorations): JsObject =
  ## A line's glyph-margin cell, in the glyph layer (`.glyph-margin-widgets`)
  ## as Monaco draws its glyph decorations: a `.cgmr` per line at the line's
  ## top, carrying the decorations' `glyphMarginClassName`s.
  result = createEl("div")
  var gcls = "cgmr codicon"
  for c in deco.glyphClasses: gcls.add " " & c
  result.setClass(cstring(gcls))
  result.setStyle("position", "absolute")
  result.setStyle("left", "0px")
  result.setStyle("top", cstring($top & "px"))
  result.setStyle("width", cstring($GlyphMarginPx & "px"))
  result.setStyle("height", cstring($ed.lineHeight & "px"))
  result.setAttr("data-line", cstring($line1))
  result.setAttr("data-ct-target", "glyph")

proc overlayRect(parent: JsObject; cls: string; left, width: float) =
  let el = createEl("div")
  el.setClass(cstring(cls))
  el.setStyle("position", "absolute")
  el.setStyle("left", cstring($left & "px"))
  el.setStyle("width", cstring($max(1.0, width) & "px"))
  el.setStyle("height", "100%")
  parent.appendChild(el)

proc updateTextarea(ed: SharedEditor)

proc render*(ed: SharedEditor) =
  ## Draw the viewport. Everything is rebuilt from the core's state; the
  ## viewport is a few dozen lines, so the rebuild is cheap and nothing on
  ## screen can disagree with the model. The DOM is WRITTEN in one phase
  ## (lines, gutter, overlay rows), READ in the next (every column's x, the
  ## browser's own measurement) and then the measured rectangles are
  ## written, so the browser lays out once per frame rather than once per
  ## measurement.
  if ed.disposed or ed.root.isNil: return
  inc ed.renders
  ed.ensureIndex()
  ed.decos.followDocument(ed.doc)
  let lay = ed.layoutNow
  ed.clampScroll()
  # The gutter is as wide as the largest line number needs.
  let chars = max(2, len($ed.index.lineCount))
  ed.numberChars = chars
  ed.gutterPx = GlyphMarginPx + int(ceil(ed.charWidth * float(chars + 1))) +
                LineDecorationsPx + FoldingPx
  if not ed.options.isNil and not isNilOrUndef(ed.options["lineNumbersMinChars"]):
    let minChars = int(jsNum(ed.options["lineNumbersMinChars"]))
    ed.gutterPx = max(ed.gutterPx, GlyphMarginPx +
      int(ceil(ed.charWidth * float(minChars + 1))) + LineDecorationsPx + FoldingPx)
  ed.margin.setStyle("width", cstring($ed.gutterPx & "px"))
  ed.scrollable.setStyle("left", cstring($ed.gutterPx & "px"))
  ed.scrollable.setStyle("width", cstring($(max(0, ed.width - ed.gutterPx)) & "px"))
  ed.linesContent.setStyle("top", cstring($(-ed.scrollTop) & "px"))
  ed.linesContent.setStyle("left", cstring($(-ed.scrollLeft) & "px"))
  ed.marginOverlays.setStyle("top", cstring($(-ed.scrollTop) & "px"))
  ed.glyphLayer.setStyle("top", cstring($(-ed.scrollTop) & "px"))
  let lines = lay.visibleLines(ed.scrollTop, ed.textViewportHeight)
  ed.visible = lines
  let firstL0 = if lines.len > 0: lines[0] - 1 else: 0
  let lastL0 = if lines.len > 0: lines[^1] - 1 else: 0
  let decoByLine = ed.decos.decorationsByLine(ed.index, firstL0, lastL0)
  let caretLine0 = ed.index.lineOfOffset(ed.primaryOffset)
  var hasSelection = false
  # Monaco highlights the line of every cursor, not only the primary's.
  var caretLines0: seq[int] = @[caretLine0]
  for r in ed.doc.state.selection.ranges:
    if not r.isEmpty: hasSelection = true
    let hl0 = ed.index.lineOfOffset(r.head)
    if hl0 notin caretLines0: caretLines0.add hl0
  let highlightCurrent = ed.options.isNil or
    isNilOrUndef(ed.options["renderLineHighlight"]) or
    $jsStr(ed.options["renderLineHighlight"]) != "none"
  # ---- write: the lines, the gutter and the overlay rows ----------------
  ed.linesLayer.clearChildren()
  ed.marginOverlays.clearChildren()
  ed.glyphLayer.clearChildren()
  ed.overlays.clearChildren()
  var overlayRows = initTable[int, JsObject]()
  var widestChars = 0
  for line1 in lines:
    let line0 = line1 - 1
    let top = lay.topOfLine(line1)
    let lt = ed.index.lineText(ed.doc.state.doc, line0)
    widestChars = max(widestChars, lt.len)
    var deco = decoByLine.getOrDefault(line0)
    if ed.semanticVersion == ed.doc.timeline.version and
       ed.semanticSpans.hasKey(line0):
      for sp in ed.semanticSpans[line0]:
        deco.inline.add (sp.fromCol, sp.toCol, sp.cls)
    var runs: seq[TokenRun] = @[]
    if ed.lexer != lxNone and lt.len > 0:
      # The line's tokens from the tokenizer's cache (`contextAt` keeps the
      # runs of every line it has passed); a line past the background
      # budget is tokenized from the nearest state.
      let (ctx0, exact) = ed.contextAt(line0 + 1)
      if exact and line0 < ed.lineRuns.len:
        runs = ed.lineRuns[line0]
      else:
        var (ctx, _) = ed.contextAt(line0)
        discard ctx0
        runs = tokenRuns(ed.lexer, lt, ctx)
    else:
      runs = @[TokenRun(text: lt, class: tcPlain)]
    let spans = lineSpans(lt, runs, deco)
    let vl = createEl("div")
    vl.setClass("view-line")
    vl.setAttr("data-line", cstring($line1))
    vl.setStyle("top", cstring($top & "px"))
    vl.setStyle("height", cstring($ed.lineHeight & "px"))
    vl.setStyle("line-height", cstring($ed.lineHeight & "px"))
    let outer = createEl("span")
    for s in spans: outer.appendChild(ed.spanEl(s))
    let foldable = isFoldable(ed.index, ed.doc.state.doc, line0)
    let folded = line0 in ed.doc.state.folded
    if folded and foldable:
      # Monaco's folded-line ellipsis.
      let ell = createEl("span")
      ell.setClass("inline-folded")
      ell.textContent = cstring(" \u22EF ")
      outer.appendChild(ell)
    vl.appendChild(outer)
    ed.linesLayer.appendChild(vl)
    ed.marginOverlays.appendChild(ed.renderGutterLine(line1, top, deco,
      line0 == caretLine0, foldable, folded, line0 in caretLines0))
    ed.glyphLayer.appendChild(ed.glyphCell(line1, top, deco))
    let ov = createEl("div")
    ov.setStyle("position", "absolute")
    ov.setStyle("top", cstring($top & "px"))
    ov.setStyle("width", "100%")
    ov.setStyle("height", cstring($ed.lineHeight & "px"))
    ov.setAttr("data-line", cstring($line1))
    for c in deco.lineClasses:
      let cd = createEl("div")
      cd.setClass(cstring("cdr " & c))
      cd.setStyle("position", "absolute")
      cd.setStyle("left", "0px")
      cd.setStyle("width", "100%")
      cd.setStyle("height", "100%")
      ov.appendChild(cd)
    if line0 in caretLines0 and not hasSelection and highlightCurrent:
      let cl = createEl("div")
      cl.setClass("current-line")
      cl.setStyle("position", "absolute")
      cl.setStyle("left", "0px")
      cl.setStyle("width", "100%")
      cl.setStyle("height", "100%")
      ov.appendChild(cl)
    ed.overlays.appendChild(ov)
    overlayRows[line1] = ov
  # ---- read: every x this frame needs, measured after one layout --------
  type Rect = tuple[line1: int; cls, title, marker: string; x0, x1: float]
  var rects: seq[Rect] = @[]
  for r in ed.doc.state.selection.ranges:
    if r.isEmpty: continue
    let a = r.rangeFrom
    let b = r.rangeTo
    let la = ed.index.lineOfOffset(a)
    let lb = ed.index.lineOfOffset(b)
    for line1 in lines:
      let line0 = line1 - 1
      if line0 < la or line0 > lb: continue
      let ls = ed.index.lineStart(line0)
      let le = ed.index.lineEnd(line0)
      let fc = (if line0 == la: a - ls else: 0)
      let tc = (if line0 == lb: b - ls else: le - ls)
      let x0 = ed.xOfByteCol(line1, fc)
      var x1 = ed.xOfByteCol(line1, tc)
      if line0 < lb: x1 += ed.charWidth   # the line break
      rects.add (line1, "cslr selected-text", "", "", x0, x1)
  let bm = matchingBracket(ed.doc.state.doc, ed.primaryOffset)
  if bm.found:
    for off in [bm.a, bm.b]:
      let l0 = ed.index.lineOfOffset(off)
      if (l0 + 1) notin lines: continue
      let ls = ed.index.lineStart(l0)
      rects.add (l0 + 1, "bracket-match", "", "", ed.xOfByteCol(l0 + 1, off - ls),
                 ed.xOfByteCol(l0 + 1, off - ls + 1))
  for m in ed.markers:
    for line1 in lines:
      if line1 < m.line or line1 > m.endLine: continue
      let lt = ed.lineText(line1)
      let fc = if line1 == m.line: byteColumnOf(lt, m.col) else: 0
      var tc = if line1 == m.endLine: byteColumnOf(lt, m.endCol) else: lt.len
      if tc <= fc: tc = min(lt.len, fc + 1)
      let cls = case m.severity
                of 8: "squiggly-error"
                of 4: "squiggly-warning"
                of 2: "squiggly-info"
                else: "squiggly-hint"
      rects.add (line1, "cdr " & cls & " ct-marker", m.message,
                 $m.severity & "@" & $line1, ed.xOfByteCol(line1, fc),
                 ed.xOfByteCol(line1, tc))
  type Caret = tuple[line1: int; x: float; primary: bool]
  var carets: seq[Caret] = @[]
  for r in ed.doc.state.selection.ranges:
    let head = r.head
    let hl0 = ed.index.lineOfOffset(head)
    if (hl0 + 1) in lines:
      carets.add (hl0 + 1, ed.xOfByteCol(hl0 + 1, head - ed.index.lineStart(hl0)),
                  head == ed.primaryOffset)
  type WidgetPlace = tuple[node: JsObject; show: bool; x: float; top: int; above: bool]
  var places: seq[WidgetPlace] = @[]
  for w in ed.widgets:
    if w.overlay or w.node.isNil or not hasFn(w.widget, "getPosition"):
      continue
    let p = callMethod0(w.widget, "getPosition")
    if isNilOrUndef(p) or isNilOrUndef(p["position"]):
      places.add (w.node, false, 0.0, 0, false)
      continue
    let line1 = int(jsNum(p["position"]["lineNumber"]))
    let col = int(jsNum(p["position"]["column"]))
    if line1 notin lines:
      places.add (w.node, false, 0.0, 0, false)
      continue
    let lt = ed.lineText(line1)
    var above = false
    let pref = p["preference"]
    if not isNilOrUndef(pref) and jsLen(pref) > 0 and int(jsNum(pref[0])) == 1:
      above = true
    places.add (w.node, true, ed.xOfByteCol(line1, byteColumnOf(lt, col)),
                lay.topOfLine(line1), above)
  # The find session's matches on the drawn lines (Monaco's `findMatch`
  # and `currentFindMatch`), the shared session's own spans.
  if ed.find.open and ed.doc.state.search.pattern.len > 0:
    for m in ed.find.matches:
      let l0 = ed.index.lineOfOffset(m.a)
      if l0 < firstL0: continue
      if l0 > lastL0: break
      let ls = ed.index.lineStart(l0)
      let le = ed.index.lineEnd(l0)
      let cls = if m.a == ed.find.current.a and m.b == ed.find.current.b:
                  "cdr currentFindMatch"
                else: "cdr findMatch"
      rects.add (l0 + 1, cls, "", "", ed.xOfByteCol(l0 + 1, m.a - ls),
                 ed.xOfByteCol(l0 + 1, min(m.b, le) - ls))
  # ---- write: the measured rectangles -----------------------------------
  for r in rects:
    if not overlayRows.hasKey(r.line1): continue
    let ov = overlayRows[r.line1]
    overlayRect(ov, r.cls, r.x0, r.x1 - r.x0)
    if r.title.len > 0 or r.marker.len > 0:
      let last = ov.lastChild
      last.setAttr("title", cstring(r.title))
      last.setAttr("data-ct-marker", cstring(r.marker))
  ed.cursorsLayer.clearChildren()
  for c in carets:
    let el = createEl("div")
    el.setClass(if c.primary: "cursor ct-primary-cursor" else: "cursor ct-secondary-cursor")
    el.setStyle("position", "absolute")
    el.setStyle("left", cstring($c.x & "px"))
    el.setStyle("top", cstring($lay.topOfLine(c.line1) & "px"))
    el.setStyle("height", cstring($ed.lineHeight & "px"))
    el.setStyle("width", "2px")
    el.setAttr("data-line", cstring($c.line1))
    ed.cursorsLayer.appendChild(el)
  for w in places:
    if not w.show:
      w.node.setStyle("display", "none")
      continue
    w.node.setStyle("display", "block")
    w.node.setStyle("position", "absolute")
    w.node.setStyle("left", cstring($w.x & "px"))
    if w.above:
      w.node.setStyle("top", cstring($w.top & "px"))
      w.node.setStyle("transform", "translateY(-100%)")
    else:
      w.node.setStyle("top", cstring($(w.top + ed.lineHeight) & "px"))
      w.node.setStyle("transform", "none")
  # Zones: positioned under their anchor lines.
  for z in ed.zones:
    if z.domNode.isNil: continue
    if z.afterLine >= 1 and lay.hidden.isHidden(z.afterLine - 1):
      z.domNode.setStyle("display", "none")
      continue
    let zt = lay.zoneTop(ZoneSpec(id: z.id, afterLine: z.afterLine,
                                  heightPx: z.heightPx))
    z.domNode.setStyle("display", "block")
    z.domNode.setStyle("position", "absolute")
    z.domNode.setStyle("top", cstring($zt & "px"))
    z.domNode.setStyle("height", cstring($z.heightPx & "px"))
    z.domNode.setStyle("width", "100%")
    if not z.marginNode.isNil:
      z.marginNode.setStyle("position", "absolute")
      z.marginNode.setStyle("top", cstring($zt & "px"))
      z.marginNode.setStyle("height", cstring($z.heightPx & "px"))
  # Scrollbars.
  let ch = max(1, lay.contentHeight)
  let vh = ed.textViewportHeight
  ed.contentWidthPx = int(float(widestChars + 2) * ed.charWidth)
  if ch > vh and vh > 0:
    let sliderH = max(20.0, float(vh) * float(vh) / float(ch))
    let sliderTop = (float(vh) - sliderH) * float(ed.scrollTop) / float(max(1, ch - vh))
    ed.vbar.setStyle("display", "block")
    ed.vslider.setStyle("height", cstring($sliderH & "px"))
    ed.vslider.setStyle("top", cstring($sliderTop & "px"))
  else:
    ed.vbar.setStyle("display", "none")
  ed.linesContent.setStyle("height", cstring($ch & "px"))
  ed.updateTextarea()
  ed.root.setAttr("data-ct-caret", cstring($(caretLine0 + 1)))
  ed.root.setAttr("data-ct-lines", cstring($ed.index.lineCount))
  ed.root.setAttr("data-ct-scroll-top", cstring($ed.scrollTop))
  ed.root.setAttr("data-ct-mode", cstring($ed.doc.state.mode))
  ed.root.setAttr("data-ct-keymap", cstring($ed.doc.model))
  ed.root.setAttr("data-ct-read-only", cstring(if ed.readOnly: "true" else: "false"))
  ed.fire("render", jsNew())

# ---------------------------------------------------------------------------
# The text area: input, composition and the screen reader's view
# ---------------------------------------------------------------------------

proc updateTextarea(ed: SharedEditor) =
  ## The hidden text area holds the caret's line — what a screen reader reads
  ## for the line and the caret, as Monaco's does — with its own caret at the
  ## caret's column, and sits at the caret so the IME's candidate window
  ## opens there.
  if ed.textarea.isNil or ed.composing: return
  let head = ed.primaryOffset
  let l0 = ed.index.lineOfOffset(head)
  let lt = ed.index.lineText(ed.doc.state.doc, l0)
  let col16 = monacoColumnOf(lt, head - ed.index.lineStart(l0)) - 1
  var selFrom = col16
  var selTo = col16
  let main = ed.doc.state.selection.mainRange
  if not main.isEmpty:
    let la = ed.index.lineOfOffset(main.rangeFrom)
    let lb = ed.index.lineOfOffset(main.rangeTo)
    if la == l0 and lb == l0:
      selFrom = monacoColumnOf(lt, main.rangeFrom - ed.index.lineStart(l0)) - 1
      selTo = monacoColumnOf(lt, main.rangeTo - ed.index.lineStart(l0)) - 1
  ed.textarea.value = cstring(lt)
  try:
    discard ed.textarea.setSelectionRange(selFrom, selTo)
  except CatchableError:
    discard
  ed.textarea.setAttr("aria-label", cstring("Editor content, line " & $(l0 + 1) &
    " of " & $ed.index.lineCount & ", column " & $(col16 + 1)))
  ed.textarea.setAttr("aria-readonly", cstring(if ed.readOnly: "true" else: "false"))
  if (l0 + 1) in ed.visible:
    let x = ed.xOfByteCol(l0 + 1, head - ed.index.lineStart(l0))
    let top = ed.topForLine(l0 + 1) - ed.scrollTop
    ed.textarea.setStyle("top", cstring($top & "px"))
    ed.textarea.setStyle("left", cstring($(ed.gutterPx.float + x - ed.scrollLeft.float) & "px"))
  ed.textarea.setStyle("height", cstring($ed.lineHeight & "px"))

# ---------------------------------------------------------------------------
# Changes
# ---------------------------------------------------------------------------

proc revealOffset*(ed: SharedEditor; offset: int; center = false)

proc afterDocumentChange*(ed: SharedEditor; before: DocumentVersion;
                          beforeText: string) =
  ## The document moved: map the decorations, drop the tokenizer states from
  ## the first changed line on, tell the listeners, and draw.
  let now = ed.doc.timeline.version
  if now == before: return
  let known = ed.doc.timeline.knows(before)
  let cs = if known: ed.doc.timeline.delta(before)
           else: identityChangeSet(beforeText.len)
  let oldIx = if ed.index.built and ed.index.version == before and
                 ed.index.textLen == beforeText.len: ed.index
              else: buildLineIndex(beforeText, before)
  var firstLine0 = high(int)
  var changes = jsArray()
  for r in cs.changedRangeSeq(individual = true):
    let l0 = oldIx.lineOfOffset(r.fromA)
    firstLine0 = min(firstLine0, l0)
    let ch = jsNew()
    let p1 = oldIx.positionOfOffset(beforeText, r.fromA)
    let p2 = oldIx.positionOfOffset(beforeText, r.toA)
    let rng = jsNew()
    rng["startLineNumber"] = p1.lineNumber
    rng["startColumn"] = p1.column
    rng["endLineNumber"] = p2.lineNumber
    rng["endColumn"] = p2.column
    ch["range"] = rng
    ch["rangeOffset"] = r.fromA
    ch["rangeLength"] = r.toA - r.fromA
    let newText = ed.doc.state.doc[min(r.fromB, ed.doc.state.doc.len) ..<
                                   min(r.toB, ed.doc.state.doc.len)]
    ch["text"] = cstring(newText)
    changes.jsPush(ch)
  # The line index moves by the change rather than being rebuilt.
  ed.index = if known: updatedLineIndex(oldIx, cs, ed.doc.state.doc, now)
             else: buildLineIndex(ed.doc.state.doc, now)
  if firstLine0 != high(int):
    # Monaco's rule: a change that leaves its line ending in the tokenizer
    # state the next line already started in re-tokenizes that line alone.
    let sameLines = ed.index.lineCount == oldIx.lineCount
    var lastLine0 = firstLine0
    for r in cs.changedRangeSeq(individual = true):
      lastLine0 = max(lastLine0, oldIx.lineOfOffset(r.toA))
    if sameLines and lastLine0 == firstLine0 and ed.lexer != lxNone and
       firstLine0 + 1 < ed.contextsValid and firstLine0 < ed.lineRuns.len:
      var ctx = ed.contexts[firstLine0]
      let runs = tokenRuns(ed.lexer, ed.index.lineText(ed.doc.state.doc,
                                                       firstLine0), ctx)
      if ctx == ed.contexts[firstLine0 + 1]:
        ed.lineRuns[firstLine0] = runs
      else:
        ed.invalidateTokensFrom(firstLine0)
    else:
      ed.invalidateTokensFrom(firstLine0)
  ed.decos.followDocument(ed.doc)
  let ev = jsNew()
  ev["changes"] = changes
  ev["versionId"] = ordinal(now)
  ev["isFlush"] = false
  ed.fire("content", ev)
  if not ed.model.isNil:
    ed.fire("modelContent", ev)

proc fireCursor(ed: SharedEditor; source: string) =
  let p = ed.positionAt(ed.primaryOffset)
  let ev = jsNew()
  let pos = jsNew()
  pos["lineNumber"] = p.lineNumber
  pos["column"] = p.column
  ev["position"] = pos
  ev["source"] = cstring(source)
  ev["reason"] = 3
  ed.fire("cursorPosition", ev)
  ed.fire("cursorSelection", ev)

proc runCoreStep*(ed: SharedEditor; source: string;
                  step: proc(d: var EditingDocument): EditingOutcome): EditingOutcome =
  ## Every change to the document goes through here: the step runs against the
  ## core, then the editor follows what it did.
  let beforeV = ed.doc.timeline.version
  let beforeText = sameString(ed.doc.state.doc)
  let beforeHead = ed.primaryOffset
  let beforeSel = ed.doc.state.selection
  result = step(ed.doc)
  if ed.doc.timeline.version != beforeV:
    ed.afterDocumentChange(beforeV, beforeText)
  ed.ensureIndex()
  if ed.primaryOffset != beforeHead or ed.doc.state.selection != beforeSel or
     ed.doc.timeline.version != beforeV:
    ed.revealOffset(ed.primaryOffset)
    ed.fireCursor(source)
  ed.requestRender()

proc syncModel*(ed: SharedEditor; base: BaseKeymap) =
  ## Follow the desktop's base keymap (the router's `base`).
  if ed.doc.model != base:
    ed.doc.switchModel(base)

proc applyKeyName*(ed: SharedEditor; name: string): KeyApplication =
  ## One canonical key through the document's own keymap — the call the
  ## terminal's and GPUI's edit arms make (`editScopeOf`).
  var app: KeyApplication
  discard ed.runCoreStep("keyboard", proc(d: var EditingDocument): EditingOutcome =
    app = d.applyKey(editScopeOf(d), name, int64(nowMs()))
    app.outcome)
  app

proc probeKey*(ed: SharedEditor; name: string): EditingResolution =
  ## What the document's keymap WOULD do with `name`, with no effect.
  let km = if ed.doc.imported.isNil: keymapOf(ed.doc.model).keymap
           else: ed.doc.imported.keymap
  resolveKey(ed.doc.state, km, editScopeOf(ed.doc), name, int64(nowMs()))

proc applyResolved*(ed: SharedEditor; res: EditingResolution): KeyApplication =
  ## An operation the router resolved, run by the core.
  var app: KeyApplication
  discard ed.runCoreStep("keyboard", proc(d: var EditingDocument): EditingOutcome =
    app = d.applyResolved(res, int64(nowMs()))
    app.outcome)
  app

proc applyNamedOp*(ed: SharedEditor; name: string; args = OpArgs();
                   source = "api"): EditingOutcome =
  ed.runCoreStep(source, proc(d: var EditingDocument): EditingOutcome =
    d.applyNamed(name, args, int64(nowMs())))

proc insertText*(ed: SharedEditor; s: string; source = "keyboard"): EditingOutcome =
  ## Text the operating system's input produced (an IME's commit, a dead
  ## key's character, a layout's letter the key name does not carry).
  if s.len == 0: return eoIgnored
  ed.applyNamedOp("insert-text", OpArgs(text: s), source)

proc selectedText*(ed: SharedEditor): string =
  var parts: seq[string] = @[]
  for r in ed.doc.state.selection.ranges:
    if not r.isEmpty:
      parts.add ed.doc.state.doc[r.rangeFrom ..< r.rangeTo]
  parts.join("\n")

# ---------------------------------------------------------------------------
# Scrolling
# ---------------------------------------------------------------------------

proc fireScroll(ed: SharedEditor; topChanged, leftChanged: bool) =
  let ev = jsNew()
  ev["scrollTop"] = ed.scrollTop
  ev["scrollLeft"] = ed.scrollLeft
  ev["scrollHeight"] = ed.scrollHeightPx
  ev["scrollTopChanged"] = topChanged
  ev["scrollLeftChanged"] = leftChanged
  ed.fire("scroll", ev)

proc setScroll*(ed: SharedEditor; top, left: int) =
  let t0 = ed.scrollTop
  let l0 = ed.scrollLeft
  ed.scrollTop = top
  ed.scrollLeft = left
  ed.clampScroll()
  if ed.scrollTop != t0 or ed.scrollLeft != l0:
    ed.render()
    ed.fireScroll(ed.scrollTop != t0, ed.scrollLeft != l0)

proc lineFullyVisible*(ed: SharedEditor; line1: int): bool =
  ## Monaco's test for the `…IfOutsideViewport` reveals: the line's whole
  ## box inside the view (a line cut by an edge is outside).
  let top = ed.topForLine(line1)
  top >= ed.scrollTop and top + ed.lineHeight <= ed.scrollTop + ed.textViewportHeight

proc revealLine*(ed: SharedEditor; line1: int; center = false) =
  let top = ed.topForLine(line1)
  let vh = ed.textViewportHeight
  var st = ed.scrollTop
  if center:
    st = top - (vh - ed.lineHeight) div 2
  elif top < st:
    st = top
  elif top + ed.lineHeight > st + vh:
    st = top + ed.lineHeight - vh
  ed.setScroll(st, ed.scrollLeft)

proc revealOffset*(ed: SharedEditor; offset: int; center = false) =
  ed.ensureIndex()
  let l0 = ed.index.lineOfOffset(offset)
  # A caret inside a fold opens it (Monaco reveals hidden lines).
  let hidden = hiddenRanges(ed.index, ed.doc.state.doc, ed.doc.state.folded)
  if hidden.isHidden(l0):
    var kept: seq[int] = @[]
    for h in ed.doc.state.folded:
      let e = foldEnd(ed.index, ed.doc.state.doc, h)
      if not (h < l0 and l0 <= e): kept.add h
    ed.doc.state.folded = kept
  if ed.height <= 0: return
  let top = ed.topForLine(l0 + 1)
  let vh = ed.textViewportHeight
  var st = ed.scrollTop
  if center: st = top - (vh - ed.lineHeight) div 2
  elif top < st: st = top
  elif top + ed.lineHeight > st + vh: st = top + ed.lineHeight - vh
  # Horizontal: keep the caret's column in view.
  var sl = ed.scrollLeft
  let lt = ed.index.lineText(ed.doc.state.doc, l0)
  let col = clamp(offset - ed.index.lineStart(l0), 0, lt.len)
  let approx = int(float(columnAt(lt, col)) * ed.charWidth)
  let vw = ed.textViewportWidth
  if approx < sl: sl = max(0, approx - int(ed.charWidth * 4))
  elif approx > sl + vw - int(ed.charWidth * 2): sl = approx - vw + int(ed.charWidth * 4)
  ed.scrollTop = st
  ed.scrollLeft = sl
  ed.clampScroll()

# ---------------------------------------------------------------------------
# Pointer
# ---------------------------------------------------------------------------

type
  Hit = object
    targetType: int
    line1: int
    column: int        ## Monaco column
    offset: int
    element: JsObject
    pe: PointerElement
    zoneId: int

proc hitAt(ed: SharedEditor; clientX, clientY: float; target: JsObject): Hit =
  ed.ensureIndex()
  let rootRect = rectOf(ed.root)
  let y = clientY - jsNum(rootRect.top) + float(ed.scrollTop)
  let lay = ed.layoutNow
  result.line1 = lay.lineAtY(int(y))
  result.element = target
  # Which layer was pressed: a widget, a zone, the gutter or the text.
  var node = target
  while not isNilOrUndef(node) and node != ed.root:
    if not isNilOrUndef(node.getAttribute) and hasFn(node, "getAttribute"):
      let t = node.getAttribute(cstring"data-ct-target")
      if not isNilOrUndef(t):
        case $jsStr(t)
        of "glyph": result.targetType = mtGutterGlyphMargin; result.pe = peGutterGlyph
        of "number": result.targetType = mtGutterLineNumbers; result.pe = peGutterLineNumber
        of "decorations": result.targetType = mtGutterLineDecorations; result.pe = peGutterLineNumber
        of "fold": result.targetType = mtGutterLineDecorations; result.pe = peGutterLineNumber
        of "zone": result.targetType = mtContentViewZone
        of "widget": result.targetType = mtContentWidget
        of "overlay-widget": result.targetType = mtOverlayWidget
        of "scrollbar": result.targetType = mtScrollbar
        else: discard
        if result.targetType != 0: break
    node = node.parentNode
  let lt = ed.index.lineText(ed.doc.state.doc, result.line1 - 1)
  var byteCol = lt.len
  if result.targetType == 0 or result.targetType == mtContentText:
    # The text: the browser's own caret position under the point.
    let r = caretRangeAt(clientX, clientY)
    var found = false
    if not isNilOrUndef(r):
      let n = r.startContainer
      let sp = n.parentNode
      if not isNilOrUndef(sp) and hasFn(sp, "getAttribute") and
         not isNilOrUndef(sp.getAttribute(cstring"data-col")) and
         $jsStr(sp.getAttribute(cstring"data-kind")) == "skText" and
         ed.linesLayer.contains(sp):
        let vl = sp.parentNode.parentNode
        let l1 = parseInt($jsStr(vl.getAttribute(cstring"data-line")))
        if l1 == result.line1:
          let from0 = parseInt($jsStr(sp.getAttribute(cstring"data-col")))
          let off16 = int(jsNum(r.startOffset))
          let spanText = $jsStr(n.data)
          byteCol = from0 + byteColumnOf(spanText, off16 + 1)
          found = true
          # A press on the middle of a character: Monaco places the caret
          # after it (the browser's caret position rounds the tie to the
          # left). Measured against the drawn boundaries either side.
          let xr = clientX - jsNum(rectOf(ed.linesContent).left)
          if byteCol < lt.len:
            var nextCol = byteCol + 1
            while nextCol < lt.len and (ord(lt[nextCol]) and 0xC0) == 0x80: inc nextCol
            let a = ed.xOfByteCol(result.line1, byteCol)
            let b = ed.xOfByteCol(result.line1, nextCol)
            if b > a and xr >= (a + b) / 2 - 0.5: byteCol = nextCol
    if not found:
      # Past the end of the line, or between spans: by x.
      let x = clientX - jsNum(rectOf(ed.linesContent).left)
      byteCol = lt.len
      let n = lt.len
      for c in 0 .. n:
        if ed.xOfByteCol(result.line1, c) + ed.charWidth / 2 > x:
          byteCol = c
          break
      result.targetType = if byteCol >= lt.len: mtContentEmpty else: mtContentText
    else:
      result.targetType = mtContentText
    result.pe = peText
  byteCol = clamp(byteCol, 0, lt.len)
  result.offset = ed.index.lineStart(result.line1 - 1) + byteCol
  result.column = monacoColumnOf(lt, byteCol)

proc mouseEventOf(ed: SharedEditor; ev: JsObject; h: Hit): JsObject =
  ## Monaco's `IEditorMouseEvent`.
  result = jsNew()
  let e = jsNew()
  e["browserEvent"] = ev
  e["ctrlKey"] = ev.ctrlKey
  e["altKey"] = ev.altKey
  e["shiftKey"] = ev.shiftKey
  e["metaKey"] = ev.metaKey
  let button = int(jsNum(ev.button))
  e["leftButton"] = button == 0
  e["middleButton"] = button == 1
  e["rightButton"] = button == 2
  e["buttons"] = ev.buttons
  e["detail"] = ev.detail
  e["posx"] = ev.pageX
  e["posy"] = ev.pageY
  e["target"] = ev.target
  e["timestamp"] = nowMs()
  e["preventDefault"] = proc() = discard ev.preventDefault()
  e["stopPropagation"] = proc() = discard ev.stopPropagation()
  result["event"] = e
  let t = jsNew()
  t["type"] = h.targetType
  t["element"] = h.element
  if h.line1 > 0:
    let p = jsNew()
    p["lineNumber"] = h.line1
    p["column"] = h.column
    t["position"] = p
    let rng = jsNew()
    rng["startLineNumber"] = h.line1
    rng["startColumn"] = h.column
    rng["endLineNumber"] = h.line1
    rng["endColumn"] = h.column
    t["range"] = rng
  else:
    t["position"] = jsNull
  t["mouseColumn"] = h.column
  let detail = jsNew()
  detail["isAfterLines"] = false
  t["detail"] = detail
  result["target"] = t

proc focusEditor*(ed: SharedEditor) =
  if ed.textarea.isNil: return
  discard ed.textarea.focus()

proc hasTextFocus*(ed: SharedEditor): bool =
  not ed.textarea.isNil and docActive() == ed.textarea

proc onMouseDown(ed: SharedEditor; ev: JsObject) =
  let h = ed.hitAt(jsNum(ev.clientX), jsNum(ev.clientY), ev.target)
  if h.targetType in [mtContentWidget, mtOverlayWidget, mtContentViewZone,
                      mtScrollbar]:
    ed.fire("mouseDown", ed.mouseEventOf(ev, h))
    return
  let button = int(jsNum(ev.button))
  let pb = case button
           of 1: pbMiddle
           of 2: pbRight
           else: pbLeft
  # The fold chevron: Monaco's folding lane toggles the fold.
  var node = ev.target
  if not isNilOrUndef(node) and hasFn(node, "getAttribute") and
     $jsStr(node.getAttribute(cstring"data-ct-target")) == "fold" and pb == pbLeft:
    let line0 = h.line1 - 1
    if isFoldable(ed.index, ed.doc.state.doc, line0):
      if line0 in ed.doc.state.folded:
        var kept: seq[int] = @[]
        for f in ed.doc.state.folded:
          if f != line0: kept.add f
        ed.doc.state.folded = kept
      else:
        ed.doc.state.folded.add line0
      ed.render()
    discard ev.preventDefault()
    return
  let mods = pointerModsOf(ev.ctrlKey.to(bool) or ev.metaKey.to(bool),
                           ev.altKey.to(bool), ev.shiftKey.to(bool))
  let press = PointerPress(timeMs: int64(nowMs()), button: pb, mods: mods,
    hit: PointerHit(element: h.pe, line: h.line1, offset: h.offset,
                    displayColumn: columnAt(ed.lineText(h.line1),
                                            h.offset - ed.offsetAt(h.line1, 1)) + 1,
                    cellHit: h.targetType == mtContentText),
    documentId: $ed.id, platformCount: max(1, int(jsNum(ev.detail))))
  var action: PointerAction
  discard ed.runCoreStep("mouse", proc(d: var EditingDocument): EditingOutcome =
    action = ed.pointer.pressEditor(d, press)
    eoMoved)
  # The desktop's handlers decide the debugger's half (breakpoints, jumps,
  # the menu), as they do for Monaco.
  ed.fire("mouseDown", ed.mouseEventOf(ev, h))
  if pb == pbLeft:
    ed.focusEditor()
    discard ev.preventDefault()
  ed.render()

proc onMouseMove(ed: SharedEditor; ev: JsObject) =
  let h = ed.hitAt(jsNum(ev.clientX), jsNum(ev.clientY), ev.target)
  if ed.pointer.held and (int(jsNum(ev.buttons)) and 1) == 1:
    var owned = false
    discard ed.runCoreStep("mouse", proc(d: var EditingDocument): EditingOutcome =
      owned = ed.pointer.dragEditor(d, PointerHit(element: h.pe, line: h.line1,
        offset: h.offset, displayColumn: columnAt(ed.lineText(h.line1),
          h.offset - ed.offsetAt(h.line1, 1)) + 1,
        cellHit: h.targetType == mtContentText), int64(nowMs()))
      eoMoved)
    if owned: ed.render()
  ed.fire("mouseMove", ed.mouseEventOf(ev, h))

proc onMouseUp(ed: SharedEditor; ev: JsObject) =
  if ed.pointer.held:
    ed.pointer.releaseEditor()
  let h = ed.hitAt(jsNum(ev.clientX), jsNum(ev.clientY), ev.target)
  ed.fire("mouseUp", ed.mouseEventOf(ev, h))

proc onContextMenu(ed: SharedEditor; ev: JsObject) =
  let h = ed.hitAt(jsNum(ev.clientX), jsNum(ev.clientY), ev.target)
  discard ev.preventDefault()
  ed.fire("contextMenu", ed.mouseEventOf(ev, h))

proc onWheel(ed: SharedEditor; ev: JsObject) =
  var dy = jsNum(ev.deltaY)
  var dx = jsNum(ev.deltaX)
  if int(jsNum(ev.deltaMode)) == 1:
    dy *= float(ed.lineHeight)
    dx *= ed.charWidth
  if ev.shiftKey.to(bool) and dx == 0:
    dx = dy
    dy = 0
  ed.setScroll(ed.scrollTop + int(dy), ed.scrollLeft + int(dx))
  let e = jsNew()
  e["browserEvent"] = ev
  e["deltaY"] = dy
  e["deltaX"] = dx
  ed.fire("mouseWheel", e)
  discard ev.preventDefault()

# ---------------------------------------------------------------------------
# Find and replace
# ---------------------------------------------------------------------------

proc findOwner(ed: SharedEditor): string = "shared-editor-" & $ed.id

proc refreshFindWidget(ed: SharedEditor) =
  if ed.findWidget.isNil: return
  if not ed.find.open:
    ed.findWidget.setStyle("display", "none")
    discard ed.findWidget.classList.remove(cstring"visible")
    ed.root.setAttr("data-ct-find", "closed")
    return
  ed.findWidget.setStyle("display", "flex")
  discard ed.findWidget.classList.add(cstring"visible")
  ed.root.setAttr("data-ct-find", "open")
  ed.findCount.textContent = cstring(ed.find.countText(ed.doc))
  let caseOn = ed.doc.state.search.options.caseSensitive
  let wordOn = ed.doc.state.search.options.wholeWord
  let cb = ed.findWidget.querySelector(cstring".ct-find-case")
  let wb = ed.findWidget.querySelector(cstring".ct-find-word")
  if not isNilOrUndef(cb): cb.setAttr("aria-pressed", cstring($caseOn))
  if not isNilOrUndef(wb): wb.setAttr("aria-pressed", cstring($wordOn))
  let rp = ed.findWidget.querySelector(cstring".ct-replace-part")
  if not isNilOrUndef(rp):
    rp.setStyle("display", cstring(if ed.replaceShown: "flex" else: "none"))

proc afterFindMove(ed: SharedEditor; r: FindReveal) =
  if r.line > 0:
    if not ed.lineFullyVisible(r.line): ed.revealLine(r.line, center = true)
  ed.refreshFindWidget()
  ed.fireCursor("find")
  ed.render()

proc openFindWidget*(ed: SharedEditor; replace: bool) =
  ## `find.open` / `find.open-replace`: the session opens seeded from the
  ## selection or the word at the caret (CUA's rule), the widget shows and
  ## its field takes the keyboard with the seed selected.
  var r: FindReveal
  discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
    r = ed.find.openFind(d, d.model, ed.findOwner, backward = false,
                         seed = fsSelectionOrWord, top = ed.scrollTop,
                         leftCol = ed.scrollLeft)
    eoMoved)
  ed.replaceShown = replace
  ed.findInput.value = cstring(ed.find.field)
  ed.afterFindMove(r)
  discard ed.findInput.focus()
  discard ed.findInput.select()

proc closeFindWidget*(ed: SharedEditor; restore: bool) =
  ## `find.accept` / `find.close` keep the current match selected;
  ## `find.cancel` restores the origin's selection and scroll.
  if not ed.find.open: return
  var back: tuple[top, leftCol: int]
  discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
    if restore: back = ed.find.cancel(d)
    else: discard ed.find.accept(d)
    eoMoved)
  if restore: ed.setScroll(back.top, back.leftCol)
  ed.refreshFindWidget()
  ed.render()
  ed.focusEditor()

proc replaceCurrent*(ed: SharedEditor): bool =
  ## Replace the current match with the replace field's text and move on.
  if not ed.find.open or not ed.find.hasCurrent or ed.readOnly: return false
  let span = ed.find.current
  let replacement = $ed.replaceInput.value.to(cstring)
  discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
    d.selectSpan(span.a, span.b)
    d.applyNamed("insert-text", OpArgs(text: replacement), int64(nowMs())))
  var r: FindReveal
  discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
    r = ed.find.setQuery(d, ed.find.field)
    eoMoved)
  ed.afterFindMove(r)
  true

proc replaceAllMatches*(ed: SharedEditor): int =
  ## Every match replaced, as ONE change (one undo), as Monaco's Replace All.
  if not ed.find.open or ed.readOnly: return 0
  let replacement = $ed.replaceInput.value.to(cstring)
  var edits: seq[Edit] = @[]
  for m in ed.find.matches:
    edits.add Edit(fromPos: m.a, toPos: m.b, insert: replacement)
  if edits.len == 0: return 0
  discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
    if d.applyChangeSet(changeSetOrdered(d.state.doc.len, edits),
                        int64(nowMs())): eoChanged
    else: eoIgnored)
  var r: FindReveal
  discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
    r = ed.find.setQuery(d, ed.find.field)
    eoMoved)
  ed.afterFindMove(r)
  edits.len

proc findCommand*(ed: SharedEditor; op: string): bool =
  ## The `find.*` operations on this editor (the router's resolution, or a
  ## Monaco find command id read backwards by the facade).
  var r: FindReveal
  case op
  of "find.open", "find.open-backward": ed.openFindWidget(replace = false)
  of "find.open-replace": ed.openFindWidget(replace = true)
  of "find.next", "find.previous":
    let next = op == "find.next"
    if ed.find.open:
      discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
        r = ed.find.step(d, next)
        eoMoved)
      ed.afterFindMove(r)
    else:
      var walked: tuple[reveal: FindReveal; wrapped: bool; message: string]
      discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
        walked = walkClosed(d, d.model, next)
        eoMoved)
      ed.afterFindMove(walked.reveal)
  of "find.close", "find.accept": ed.closeFindWidget(restore = false)
  of "find.cancel": ed.closeFindWidget(restore = true)
  of "find.toggle-case", "find.toggle-whole-word":
    if not ed.find.open: return false
    discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
      r = (if op == "find.toggle-case": ed.find.toggleCase(d)
           else: ed.find.toggleWholeWord(d))
      eoMoved)
    ed.afterFindMove(r)
  of "find.replace-one": discard ed.replaceCurrent()
  of "find.replace-all": discard ed.replaceAllMatches()
  of "find.select-all-matches":
    if not ed.find.open or ed.find.matches.len == 0: return false
    var ranges: seq[SelectionRange] = @[]
    for m in ed.find.matches: ranges.add spanRange(m.a, m.b)
    discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
      d.state.selection = editorSelection(ranges)
      eoMoved)
    ed.closeFindWidget(restore = false)
  else: return false
  true

proc buildFindWidget(ed: SharedEditor) =
  ## Monaco's find widget's place and parts (top right, the field, the count,
  ## Match Case, Whole Word, previous / next, close; the replace row under
  ## it), driven by the shared find session.
  let w = createEl("div")
  w.setClass("find-widget ct-find-widget")
  w.setAttr("role", "dialog")
  w.setAttr("aria-label", "Find / Replace")
  w.setAttr("data-ct-target", "overlay-widget")
  w.setStyle("position", "absolute")
  w.setStyle("top", "0px")
  w.setStyle("right", cstring($(ScrollbarPx + 4) & "px"))
  w.setStyle("display", "none")
  w.setStyle("flex-direction", "column")
  w.setStyle("z-index", "20")
  w.setHtml(cstring("""<div class="ct-find-part" style="display:flex;align-items:center;gap:2px">
<input class="ct-find-input" type="text" aria-label="Find" placeholder="Find" spellcheck="false">
<span class="matchesCount ct-find-count" aria-live="polite"></span>
<button class="ct-find-case" title="Match Case" aria-pressed="false">Aa</button>
<button class="ct-find-word" title="Match Whole Word" aria-pressed="false">ab</button>
<button class="ct-find-prev" title="Previous Match">&#x2191;</button>
<button class="ct-find-next" title="Next Match">&#x2193;</button>
<button class="ct-find-close" title="Close">&#x00D7;</button></div>
<div class="ct-replace-part" style="display:none;align-items:center;gap:2px">
<input class="ct-replace-input" type="text" aria-label="Replace" placeholder="Replace" spellcheck="false">
<button class="ct-replace-one" title="Replace">Replace</button>
<button class="ct-replace-all" title="Replace All">All</button></div>"""))
  ed.overlayWidgetsLayer.appendChild(w)
  ed.findWidget = w
  ed.findInput = w.querySelector(cstring".ct-find-input")
  ed.replaceInput = w.querySelector(cstring".ct-replace-input")
  ed.findCount = w.querySelector(cstring".ct-find-count")
  ed.findInput.addListener("input", proc(ev: JsObject) =
    var r: FindReveal
    let value = $ed.findInput.value.to(cstring)
    discard ed.runCoreStep("find", proc(d: var EditingDocument): EditingOutcome =
      r = ed.find.setQuery(d, value)
      eoMoved)
    ed.afterFindMove(r))
  proc keys(ev: JsObject) =
    # The widget's own keys when the window's router left them to the
    # field: Enter / Shift+Enter walk, Escape closes (VS Code keeps the
    # match selected).
    let key = $jsStr(ev.key)
    var op = ""
    if key == "Enter":
      op = if ev.shiftKey.to(bool): "find.previous" else: "find.next"
      if ev.target == ed.replaceInput: op = "find.replace-one"
    elif key == "Escape": op = "find.close"
    elif key == "F3": op = if ev.shiftKey.to(bool): "find.previous" else: "find.next"
    if op.len > 0:
      discard ev.preventDefault()
      discard ev.stopPropagation()
      discard ed.findCommand(op)
  ed.findInput.addListener("keydown", keys)
  ed.replaceInput.addListener("keydown", keys)
  for (sel, op) in [(".ct-find-case", "find.toggle-case"),
                    (".ct-find-word", "find.toggle-whole-word"),
                    (".ct-find-prev", "find.previous"),
                    (".ct-find-next", "find.next"),
                    (".ct-find-close", "find.close"),
                    (".ct-replace-one", "find.replace-one"),
                    (".ct-replace-all", "find.replace-all")]:
    let b = w.querySelector(cstring(sel))
    let theOp = op
    b.addListener("mousedown", proc(ev: JsObject) =
      discard ev.preventDefault()
      discard ev.stopPropagation())
    b.addListener("click", proc(ev: JsObject) =
      discard ev.stopPropagation()
      discard ed.findCommand(theOp))
  w.addListener("mousedown", proc(ev: JsObject) = discard ev.stopPropagation())

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc lexerForLanguage(path, language: string): LexerId =
  result = lexerForPath(path)
  if result == lxNone and language.len > 0:
    result = lexerForPath("x." & (case language
      of "python": "py"
      of "rust": "rs"
      of "javascript": "js"
      of "typescript": "ts"
      of "ruby": "rb"
      of "cpp": "cpp"
      of "c": "c"
      of "go": "go"
      of "java": "java"
      of "shell": "sh"
      of "yaml": "yaml"
      of "nim": "nim"
      else: language))

proc styleBox(e: JsObject; css: openArray[(string, string)]) =
  for (k, v) in css: e.setStyle(cstring(k), cstring(v))

proc layoutTo*(ed: SharedEditor; width, height: int) =
  ed.width = width
  ed.height = height
  ed.render()

proc measureHost(ed: SharedEditor) =
  let r = rectOf(ed.host)
  let w = int(jsNum(r.width))
  let h = int(jsNum(r.height))
  if w > 0 and h > 0 and (w != ed.width or h != ed.height):
    ed.width = w
    ed.height = h
    ed.render()
    let ev = jsNew()
    ed.fire("layout", ev)

proc massagedFontFamily*(family: string): string =
  ## The family Monaco draws with: the option's, then Monaco's platform
  ## default (`EDITOR_FONT_DEFAULTS.fontFamily`) as the fallback.
  let fallback = case hostPlatform()
    of pkMac: "Menlo, Monaco, \"Courier New\", monospace"
    of pkWindows: "Consolas, \"Courier New\", monospace"
    else: "\"Droid Sans Mono\", \"monospace\", monospace"
  if family.len == 0: fallback
  elif family.endsWith(fallback): family
  else: family & ", " & fallback

proc defaultLineHeight*(fontSize: int; mac: bool): int =
  ## Monaco's line height for a font size: `fontSize * 1.5` on macOS,
  ## `* 1.35` elsewhere (`EditorFontInfo`'s golden ratio), rounded.
  int(round(float(fontSize) * (if mac: 1.5 else: 1.35)))

proc themeHex(t: DesignToken; dark: bool): string =
  DesignTokenHex[t][if dark: dmDark else: dmLight]

proc themeRules(dark: bool): string =
  ## One theme's colours, scoped to the editor root's theme class (`vs-dark`
  ## or `vs`, the class Monaco's own editors carry), so editors of both
  ## themes can share the page's one stylesheet.
  let scope = if dark: ".ct-shared-editor.vs-dark" else: ".ct-shared-editor.vs"
  let ground = themeHex(dtEditorThemeGround, dark)
  let fg = themeHex(dtEditorThemeRuleDefault, dark)
  let num = themeHex(dtEditorThemeLineNumber, dark)
  let activeNum = themeHex(dtEditorThemeActiveLineNumber, dark)
  let sel = themeHex(dtEditorThemeSelection, dark)
  let pointer = themeHex(dtEditorThemeExecutionPointer, dark)
  scope & " { background: var(--vscode-editor-background, " & ground & ");\n" &
  "  color: var(--vscode-editor-foreground, " & fg & "); }\n" &
  scope & " .margin { background: var(--vscode-editorGutter-background, " & ground & "); }\n" &
  scope & " .line-numbers { color: var(--vscode-editorLineNumber-foreground, " & num & "); }\n" &
  scope & " .line-numbers.active-line-number {\n" &
  "  color: var(--vscode-editorLineNumber-activeForeground, " & activeNum & "); }\n" &
  scope & " .selected-text { background: var(--vscode-editor-inactiveSelectionBackground, " & sel & "); }\n" &
  scope & ".focused .selected-text { background: var(--vscode-editor-selectionBackground, " & sel & "); }\n" &
  scope & " .cursor { background: var(--vscode-editorCursor-foreground, " & fg & "); }\n" &
  scope & " .ct-fold-toggle, " & scope & " .inline-folded { color: " & num & "; }\n" &
  scope & " .inputarea.ime-input { color: inherit; background: var(--vscode-editor-background, " & ground & ");\n" &
  "  border-bottom: 1px solid " & pointer & "; }\n"

proc installSharedEditorStyles() =
  ## The shared editor's own rules, once per page. The colours are the
  ## design system's editor theme (PLAT-46: `editor-theme/*`, the tokens the
  ## desktop's Monaco theme is generated from and the terminal and GPUI paint
  ## with), read through Monaco's CSS variables first so a page whose Monaco
  ## theme is loaded draws both editors from one source. The forced-colours
  ## block is the high-contrast theme: system colours for the text, the
  ## selection, the caret and the current line, as Monaco's `hc-black` does.
  var present = false
  {.emit: [present, " = !!document.getElementById('ct-shared-editor-styles');"].}
  if present: return
  let css = themeRules(true) & themeRules(false) & """
.ct-shared-editor { cursor: text; }
.ct-shared-editor .line-numbers { text-align: right; box-sizing: border-box; padding-right: 4px; cursor: default; }
.ct-shared-editor .view-line { position: absolute; width: 100%; white-space: pre; }
.ct-shared-editor .view-overlays > div > div { pointer-events: none; }
.ct-shared-editor .current-line { box-sizing: border-box;
  border: 2px solid var(--vscode-editor-lineHighlightBorder, rgba(128,128,128,0.15)); }
.ct-shared-editor .bracket-match { box-sizing: border-box;
  border: 1px solid var(--vscode-editorBracketMatch-border, #888); }
.ct-shared-editor:not(.focused) .cursor { visibility: hidden; }
.ct-shared-editor.focused .cursor { animation: ct-shared-editor-blink 1s step-end infinite; }
@keyframes ct-shared-editor-blink { 50% { visibility: hidden; } }
.ct-shared-editor .squiggly-error { border-bottom: 2px wavy var(--vscode-editorError-foreground, #f14c4c); }
.ct-shared-editor .squiggly-warning { border-bottom: 2px wavy var(--vscode-editorWarning-foreground, #cca700); }
.ct-shared-editor .squiggly-info, .ct-shared-editor .squiggly-hint {
  border-bottom: 2px dotted var(--vscode-editorInfo-foreground, #3794ff); }
.ct-shared-editor .ct-fold-toggle { cursor: pointer; text-align: center; }
.ct-shared-editor .scrollbar .slider { background: rgba(121,121,121,0.4); }
.ct-shared-editor .findMatch { background: var(--vscode-editor-findMatchHighlightBackground, rgba(234,92,0,0.33)); }
.ct-shared-editor .currentFindMatch { background: var(--vscode-editor-findMatchBackground, #515c6a); }
.ct-shared-editor .ct-find-widget { background: var(--vscode-editorWidget-background, #252526);
  border: 1px solid var(--vscode-widget-border, #454545); padding: 4px; gap: 4px; }
@media (forced-colors: active) {
  .ct-shared-editor { forced-color-adjust: none; background: Canvas !important; color: CanvasText !important; }
  .ct-shared-editor .view-line span { color: CanvasText !important; }
  .ct-shared-editor .selected-text, .ct-shared-editor.focused .selected-text { background: Highlight !important; }
  .ct-shared-editor .cursor { background: CanvasText !important; }
  .ct-shared-editor .current-line { border-color: Highlight; }
  .ct-shared-editor .line-numbers { color: GrayText !important; }
  .ct-shared-editor .line-numbers.active-line-number { color: CanvasText !important; }
}
"""
  let el = createEl("style")
  el.setAttr("id", "ct-shared-editor-styles")
  el.textContent = cstring(css)
  {.emit: ["(document.head || document.documentElement).appendChild(", el, ");"].}

proc newSharedEditor*(host: JsObject; text, path, language: string;
                      readOnly: bool; fontSize: int; fontFamily: string;
                      darkTheme: bool; options: JsObject;
                      model = bkCua): SharedEditor =
  ## Build the editor in `host` over `text`.
  let ed = SharedEditor(id: nextEditorId, path: path, languageId: language,
    readOnly: readOnly, options: options, darkTheme: darkTheme,
    fontSize: max(6, fontSize), charWidth: float(max(6, fontSize)) * 0.6)
  inc nextEditorId
  ed.doc = initEditingDocument(path, text, model, delivery = DesktopDelivery)
  ed.doc.setReadOnly(readOnly)
  ed.lastVersionSeen = ed.doc.timeline.version
  ed.decos = initDecorationTable(ed.doc.timeline.version)
  ed.lexer = lexerForLanguage(path, language)
  ed.lineHeight = defaultLineHeight(ed.fontSize, hostPlatform() == pkMac)
  if not options.isNil and not isNilOrUndef(options["lineHeight"]) and
     jsNum(options["lineHeight"]) > 0:
    ed.lineHeight = int(jsNum(options["lineHeight"]))
  if not options.isNil and not isNilOrUndef(options["lineNumbers"]):
    ed.lineNumbersFn = options["lineNumbers"]
  ed.host = host
  installSharedEditorStyles()
  let root = createEl("div")
  root.setClass(cstring("monaco-editor ct-shared-editor no-user-select " &
    (if darkTheme: "vs-dark" else: "vs")))
  root.setAttr(SharedEditorAttribute, "1")
  root.setAttr("role", "code")
  root.setAttr("data-mode-id", cstring(language))
  root.setAttr("data-uri", cstring(path))
  root.styleBox([("position", "relative"), ("overflow", "hidden"),
                 ("width", "100%"), ("height", "100%"),
                 ("font-size", $ed.fontSize & "px"),
                 ("--ct-shared-editor-line-height", $ed.lineHeight & "px")])
  if fontFamily.len > 0:
    root.setStyle("font-family", cstring(massagedFontFamily(fontFamily)))
  ed.root = root
  let guard = createEl("div")
  guard.setClass("overflow-guard")
  guard.styleBox([("position", "absolute"), ("inset", "0"), ("overflow", "hidden")])
  root.appendChild(guard)
  ed.guard = guard
  let margin = createEl("div")
  margin.setClass("margin")
  margin.setAttr("role", "presentation")
  margin.styleBox([("position", "absolute"), ("top", "0"), ("left", "0"),
                   ("height", "100%"), ("overflow", "hidden")])
  guard.appendChild(margin)
  ed.margin = margin
  let mo = createEl("div")
  mo.setClass("margin-view-overlays")
  mo.styleBox([("position", "absolute"), ("left", "0"), ("width", "100%")])
  margin.appendChild(mo)
  ed.marginOverlays = mo
  # Monaco's glyph margin: the column (`.glyph-margin`, what a user aims at)
  # and the layer its decorations are drawn in (`.glyph-margin-widgets`).
  let gcol = createEl("div")
  gcol.setClass("glyph-margin")
  gcol.styleBox([("position", "absolute"), ("top", "0"), ("left", "0"),
                 ("width", $GlyphMarginPx & "px"), ("height", "100%"),
                 ("pointer-events", "none")])
  margin.appendChild(gcol)
  let gl = createEl("div")
  gl.setClass("glyph-margin-widgets")
  gl.styleBox([("position", "absolute"), ("left", "0"),
               ("width", $GlyphMarginPx & "px")])
  margin.appendChild(gl)
  ed.glyphLayer = gl
  let sc = createEl("div")
  sc.setClass("monaco-scrollable-element editor-scrollable")
  sc.setAttr("role", "presentation")
  sc.styleBox([("position", "absolute"), ("top", "0"), ("height", "100%"),
               ("overflow", "hidden")])
  guard.appendChild(sc)
  ed.scrollable = sc
  let lc = createEl("div")
  lc.setClass("lines-content monaco-editor-background")
  # Monaco's: a strictly contained, composited box, so what the page's
  # widgets draw `position: fixed` (the flow's value chips) is placed in the
  # editor's text, not in the window.
  lc.styleBox([("position", "absolute"), ("width", "1000000px"),
               ("height", "1000000px"), ("overflow", "hidden"),
               ("contain", "strict"), ("transform", "translate3d(0px, 0px, 0px)")])
  sc.appendChild(lc)
  ed.linesContent = lc
  let ov = createEl("div")
  ov.setClass("view-overlays")
  ov.setAttr("role", "presentation")
  ov.styleBox([("position", "absolute"), ("width", "100%")])
  lc.appendChild(ov)
  ed.overlays = ov
  let zl = createEl("div")
  zl.setClass("view-zones")
  zl.setAttr("role", "presentation")
  zl.styleBox([("position", "absolute"), ("width", "100%")])
  lc.appendChild(zl)
  ed.zonesLayer = zl
  let ll = createEl("div")
  ll.setClass("view-lines monaco-mouse-cursor-text")
  ll.setAttr("role", "presentation")
  ll.setAttr("aria-hidden", "true")
  ll.styleBox([("position", "absolute"), ("width", "100%"),
               ("white-space", "pre"), ("tab-size", "4")])
  lc.appendChild(ll)
  ed.linesLayer = ll
  let wl = createEl("div")
  wl.setClass("contentWidgets")
  wl.styleBox([("position", "absolute"), ("top", "0"), ("left", "0")])
  lc.appendChild(wl)
  ed.widgetsLayer = wl
  let cl = createEl("div")
  cl.setClass("cursors-layer cursor-line-style cursor-solid")
  cl.setAttr("role", "presentation")
  cl.styleBox([("position", "absolute"), ("top", "0"), ("left", "0")])
  lc.appendChild(cl)
  ed.cursorsLayer = cl
  let ta = createEl("textarea")
  ta.setClass("inputarea monaco-mouse-cursor-text")
  ta.setAttr("role", "textbox")
  ta.setAttr("aria-roledescription", "editor")
  ta.setAttr("aria-multiline", "true")
  ta.setAttr("aria-autocomplete", "both")
  ta.setAttr("autocorrect", "off")
  ta.setAttr("autocapitalize", "off")
  ta.setAttr("autocomplete", "off")
  ta.setAttr("spellcheck", "false")
  ta.setAttr("wrap", "off")
  ta.setAttr("tabindex", "0")
  ta.styleBox([("position", "absolute"), ("width", "1px"), ("padding", "0"),
               ("border", "0"), ("margin", "0"), ("resize", "none"),
               ("outline", "none"), ("opacity", "0"), ("overflow", "hidden"),
               ("white-space", "pre"), ("z-index", "-10"),
               ("font-size", "inherit"), ("font-family", "inherit")])
  guard.appendChild(ta)
  ed.textarea = ta
  let vbar = createEl("div")
  vbar.setClass("scrollbar vertical")
  vbar.setAttr("data-ct-target", "scrollbar")
  vbar.styleBox([("position", "absolute"), ("right", "0"), ("top", "0"),
                 ("width", $ScrollbarPx & "px"), ("height", "100%")])
  let vs = createEl("div")
  vs.setClass("slider")
  vs.styleBox([("position", "absolute"), ("left", "0"), ("width", "100%")])
  vbar.appendChild(vs)
  guard.appendChild(vbar)
  ed.vbar = vbar
  ed.vslider = vs
  let owl = createEl("div")
  owl.setClass("overlayWidgets")
  owl.styleBox([("position", "absolute"), ("top", "0"), ("left", "0"),
                ("width", "100%")])
  root.appendChild(owl)
  ed.overlayWidgetsLayer = owl
  let ms = createEl("span")
  ms.styleBox([("position", "absolute"), ("visibility", "hidden"),
               ("white-space", "pre")])
  root.appendChild(ms)
  ed.measureSpan = ms
  host.appendChild(root)
  ed.buildFindWidget()
  ed.measureFont()
  # Listeners.
  root.addListener("mousedown", proc(ev: JsObject) = ed.onMouseDown(ev))
  root.addListener("mousemove", proc(ev: JsObject) = ed.onMouseMove(ev))
  root.addListener("mouseup", proc(ev: JsObject) = ed.onMouseUp(ev))
  root.addListener("contextmenu", proc(ev: JsObject) = ed.onContextMenu(ev))
  root.addListener("wheel", proc(ev: JsObject) = ed.onWheel(ev))
  root.addListener("mouseleave", proc(ev: JsObject) =
    let e = jsNew()
    e["event"] = jsNew()
    e["target"] = nil
    ed.fire("mouseLeave", e))
  ta.addListener("focus", proc(ev: JsObject) =
    ed.focused = true
    discard root.classList.add(cstring"focused")
    if not onSharedEditorFocus.isNil: onSharedEditorFocus(ed)
    ed.fire("focus", jsNew()))
  ta.addListener("blur", proc(ev: JsObject) =
    ed.focused = false
    discard root.classList.remove(cstring"focused")
    ed.fire("blur", jsNew()))
  ta.addListener("compositionstart", proc(ev: JsObject) =
    ed.composing = true
    ta.value = cstring""
    discard ta.classList.add(cstring"ime-input")
    ta.setStyle("opacity", "1")
    ta.setStyle("z-index", "10")
    ta.setStyle("width", "auto")
    root.setAttr("data-ct-composing", "true"))
  ta.addListener("compositionupdate", proc(ev: JsObject) =
    root.setAttr("data-ct-composition", ev.data.to(cstring)))
  ta.addListener("compositionend", proc(ev: JsObject) =
    ed.composing = false
    discard ta.classList.remove(cstring"ime-input")
    ta.setStyle("opacity", "0")
    ta.setStyle("z-index", "-10")
    ta.setStyle("width", "1px")
    discard root.removeAttribute(cstring"data-ct-composing")
    discard root.removeAttribute(cstring"data-ct-composition")
    let committed = $ev.data.to(cstring)
    if not ed.readOnly:
      discard ed.insertText(committed, "ime")
    ed.updateTextarea())
  ta.addListener("input", proc(ev: JsObject) =
    # Text the key router did not consume — a dead key's character, a
    # layout's letter with no canonical key name — arrives as the text
    # area's input. Composition text is taken at `compositionend`.
    if ed.composing or ev.isComposing.to(bool): return
    let kind = $jsStr(ev.inputType)
    if kind in ["insertText", "insertReplacementText"] and
       not isNilOrUndef(ev.data):
      if not ed.readOnly:
        discard ed.insertText($ev.data.to(cstring), "keyboard")
    ed.updateTextarea())
  ta.addListener("copy", proc(ev: JsObject) =
    discard ed.applyNamedOp("clipboard-copy", source = "keyboard")
    let t = ed.selectedText
    if t.len > 0:
      discard ev.clipboardData.setData(cstring"text/plain", cstring(t))
    discard ev.preventDefault())
  ta.addListener("cut", proc(ev: JsObject) =
    let t = ed.selectedText
    if t.len > 0:
      discard ev.clipboardData.setData(cstring"text/plain", cstring(t))
    if not ed.readOnly:
      discard ed.applyNamedOp("clipboard-cut", source = "keyboard")
    discard ev.preventDefault())
  ta.addListener("paste", proc(ev: JsObject) =
    discard ev.preventDefault()
    if ed.readOnly: return
    let t = $ev.clipboardData.getData(cstring"text/plain").to(cstring)
    if t.len == 0: return
    ed.doc.offerClipboard(t)
    discard ed.applyNamedOp("clipboard-paste", source = "paste"))
  sharedEditors.add ed
  ed.measureHost()
  if ed.width == 0:
    discard setTimeoutJs(proc() = ed.measureHost(), 0)
  ed.render()
  ed

proc observeSize*(ed: SharedEditor) =
  ## Re-measure when the host's size changes (Monaco's `automaticLayout`).
  let cb = proc() = ed.measureHost()
  let hostEl = ed.host
  let rootEl = ed.root
  {.emit: ["if (typeof ResizeObserver === 'function') { const ro = new ResizeObserver(() => (", cb, ")()); ro.observe(", hostEl, "); ", rootEl, ".__ctResize = ro; }"].}

proc dispose*(ed: SharedEditor) =
  if ed.disposed: return
  ed.disposed = true
  let rootEl = ed.root
  {.emit: ["if (", rootEl, " && ", rootEl, ".__ctResize) ", rootEl, ".__ctResize.disconnect();"].}
  if not ed.root.isNil: ed.root.removeEl()
  var kept: seq[SharedEditor] = @[]
  for e in sharedEditors:
    if e != ed: kept.add e
  sharedEditors = kept
  ed.fire("dispose", jsNew())

proc sharedEditorOfElement*(el: JsObject): SharedEditor =
  ## The shared editor whose DOM holds `el`, or nil.
  if isNilOrUndef(el): return nil
  for ed in sharedEditors:
    if not ed.root.isNil and (ed.root == el or ed.root.contains(el)):
      return ed
  nil

proc focusedSharedEditor*(): SharedEditor =
  ## The shared editor holding the focus anywhere in it (its text area, its
  ## find widget, a tracepoint field in one of its zones), or nil.
  sharedEditorOfElement(docActive())

proc textFocusedSharedEditor*(): SharedEditor =
  ## The shared editor whose OWN text area holds the focus — the keys that are
  ## the document's — or nil.
  let a = docActive()
  for ed in sharedEditors:
    if not ed.textarea.isNil and ed.textarea == a:
      return ed
  nil

# ---------------------------------------------------------------------------
# Zones and widgets
# ---------------------------------------------------------------------------

proc addZone*(ed: SharedEditor; spec: JsObject): int =
  inc ed.nextZoneId
  var h = 0
  if not isNilOrUndef(spec["heightInPx"]): h = int(jsNum(spec["heightInPx"]))
  elif not isNilOrUndef(spec["heightInLines"]):
    h = int(round(jsNum(spec["heightInLines"]) * float(ed.lineHeight)))
  else: h = ed.lineHeight
  let node = spec["domNode"]
  if not isNilOrUndef(node):
    node.setAttr("data-ct-target", "zone")
    ed.zonesLayer.appendChild(node)
  var mnode: JsObject = nil
  if not isNilOrUndef(spec["marginDomNode"]):
    mnode = spec["marginDomNode"]
    ed.marginOverlays.parentNode.appendChild(mnode)
  ed.zones.add ZoneRec(id: ed.nextZoneId,
    afterLine: int(jsNum(spec["afterLineNumber"])), heightPx: h,
    domNode: (if isNilOrUndef(node): nil else: node), marginNode: mnode,
    spec: spec)
  ed.nextZoneId

proc removeZone*(ed: SharedEditor; id: int) =
  var kept: seq[ZoneRec] = @[]
  for z in ed.zones:
    if z.id == id:
      if not z.domNode.isNil: z.domNode.removeEl()
      if not z.marginNode.isNil: z.marginNode.removeEl()
    else: kept.add z
  ed.zones = kept

proc layoutZone*(ed: SharedEditor; id: int) =
  for z in ed.zones.mitems:
    if z.id == id:
      let spec = z.spec
      if not isNilOrUndef(spec["heightInPx"]): z.heightPx = int(jsNum(spec["heightInPx"]))
      elif not isNilOrUndef(spec["heightInLines"]):
        z.heightPx = int(round(jsNum(spec["heightInLines"]) * float(ed.lineHeight)))
      z.afterLine = int(jsNum(spec["afterLineNumber"]))

proc zoneCount*(ed: SharedEditor): int = ed.zones.len

proc addWidget*(ed: SharedEditor; widget: JsObject; overlay: bool) =
  let node = callMethod0(widget, "getDomNode")
  if isNilOrUndef(node): return
  node.setAttr("data-ct-target", cstring(if overlay: "overlay-widget" else: "widget"))
  if overlay: ed.overlayWidgetsLayer.appendChild(node)
  else: ed.widgetsLayer.appendChild(node)
  ed.widgets.add WidgetRec(widget: widget, node: node, overlay: overlay)

proc removeWidget*(ed: SharedEditor; widget: JsObject) =
  var kept: seq[WidgetRec] = @[]
  for w in ed.widgets:
    var same = false
    let ww = w.widget
    {.emit: [same, " = (", ww, " === ", widget, ") || (!!", ww, ".getId && !!", widget, ".getId && ", ww, ".getId() === ", widget, ".getId());"].}
    if same:
      w.node.removeEl()
    else: kept.add w
  ed.widgets = kept

# ---------------------------------------------------------------------------
# Decorations from the desktop
# ---------------------------------------------------------------------------

proc optionsOf(o: JsObject): DecoOptions =
  proc s(v: JsObject): string =
    if isNilOrUndef(v): "" else: $jsStr(v)
  if isNilOrUndef(o): return
  result.className = s(o["className"])
  result.isWholeLine = not isNilOrUndef(o["isWholeLine"]) and o["isWholeLine"].to(bool)
  result.inlineClassName = s(o["inlineClassName"])
  result.glyphMarginClassName = s(o["glyphMarginClassName"])
  result.linesDecorationsClassName = s(o["linesDecorationsClassName"])
  result.marginClassName = s(o["marginClassName"])
  result.showIfCollapsed = not isNilOrUndef(o["showIfCollapsed"]) and
                           o["showIfCollapsed"].to(bool)
  if not isNilOrUndef(o["after"]):
    result.afterContent = s(o["after"]["content"])
    result.afterClass = s(o["after"]["inlineClassName"])
  if not isNilOrUndef(o["before"]):
    result.beforeContent = s(o["before"]["content"])
    result.beforeClass = s(o["before"]["inlineClassName"])
  let hm = o["hoverMessage"]
  if not isNilOrUndef(hm):
    if not isNilOrUndef(hm["value"]): result.hoverMessage = s(hm["value"])
    elif jsLen(hm) > 0 and not isNilOrUndef(hm[0]) and not isNilOrUndef(hm[0]["value"]):
      result.hoverMessage = s(hm[0]["value"])
  if not isNilOrUndef(o["stickiness"]): result.stickiness = int(jsNum(o["stickiness"]))

proc rangeOffsets(ed: SharedEditor; r: JsObject): tuple[a, b: int] =
  let a = ed.offsetAt(int(jsNum(r["startLineNumber"])), int(jsNum(r["startColumn"])))
  let b = ed.offsetAt(int(jsNum(r["endLineNumber"])), int(jsNum(r["endColumn"])))
  (min(a, b), max(a, b))

proc deltaDecorationsJs*(ed: SharedEditor; old, added: JsObject): JsObject =
  ed.decos.followDocument(ed.doc)
  var oldIds: seq[string] = @[]
  if not isNilOrUndef(old):
    for i in 0 ..< jsLen(old): oldIds.add $jsStr(old[i])
  var reqs: seq[DecoRequest] = @[]
  if not isNilOrUndef(added):
    for i in 0 ..< jsLen(added):
      let d = added[i]
      let (a, b) = ed.rangeOffsets(d["range"])
      reqs.add DecoRequest(fromOffset: a, toOffset: b, options: optionsOf(d["options"]))
  let ids = ed.decos.deltaDecorations(oldIds, reqs)
  result = jsArray()
  for id in ids: result.jsPush(toJs(cstring(id)))
  ed.requestRender()

proc rangeJs(ed: SharedEditor; a, b: int): JsObject =
  let p1 = ed.positionAt(a)
  let p2 = ed.positionAt(b)
  result = jsNew()
  result["startLineNumber"] = p1.lineNumber
  result["startColumn"] = p1.column
  result["endLineNumber"] = p2.lineNumber
  result["endColumn"] = p2.column

# ---------------------------------------------------------------------------
# Text replacement from the desktop (`setValue`, `executeEdits`)
# ---------------------------------------------------------------------------

proc replaceAll*(ed: SharedEditor; text: string) =
  ## `setValue`: the whole text, as ONE change through the core (so it maps
  ## the decorations and is undoable), past the read-only filter — the
  ## desktop sets the text of a read-only editor when it loads a file.
  if text == ed.doc.state.doc: return
  let ro = ed.doc.isReadOnly
  if ro: ed.doc.setReadOnly(false)
  let beforeV = ed.doc.timeline.version
  let beforeText = sameString(ed.doc.state.doc)
  discard ed.doc.applyChangeSet(changeSet(beforeText.len, 0, beforeText.len, text),
                                int64(nowMs()))
  if ro: ed.doc.setReadOnly(true)
  ed.afterDocumentChange(beforeV, beforeText)
  ed.requestRender()

proc executeEdits*(ed: SharedEditor; edits: JsObject; force = false): bool =
  ## Monaco's `executeEdits`: each edit's range replaced by its text, as one
  ## change. Refused by a read-only document unless `force`.
  ed.ensureIndex()
  var es: seq[Edit] = @[]
  for i in 0 ..< jsLen(edits):
    let e = edits[i]
    let (a, b) = ed.rangeOffsets(e["range"])
    let t = if isNilOrUndef(e["text"]): "" else: $jsStr(e["text"])
    es.add Edit(fromPos: a, toPos: b, insert: t)
  if es.len == 0: return false
  if ed.doc.isReadOnly and not force: return false
  let ro = ed.doc.isReadOnly
  if ro: ed.doc.setReadOnly(false)
  let beforeV = ed.doc.timeline.version
  let beforeText = sameString(ed.doc.state.doc)
  result = ed.doc.applyChangeSet(changeSetOrdered(beforeText.len, es), int64(nowMs()))
  if ro: ed.doc.setReadOnly(true)
  ed.afterDocumentChange(beforeV, beforeText)
  ed.requestRender()

proc setReadOnlyMode*(ed: SharedEditor; readOnly: bool) =
  ed.readOnly = readOnly
  ed.doc.setReadOnly(readOnly)
  ed.requestRender()

proc setSelectionOffsets*(ed: SharedEditor; anchor, head: int) =
  discard ed.runCoreStep("api", proc(d: var EditingDocument): EditingOutcome =
    d.state.selection = singleSelection(anchor, head)
    eoMoved)

proc setMarkers*(ed: SharedEditor; markers: JsObject) =
  ed.markers = @[]
  if isNilOrUndef(markers): return
  for i in 0 ..< jsLen(markers):
    let m = markers[i]
    ed.markers.add (int(jsNum(m["severity"])), int(jsNum(m["startLineNumber"])),
                    int(jsNum(m["startColumn"])), int(jsNum(m["endLineNumber"])),
                    int(jsNum(m["endColumn"])), $jsStr(m["message"]))
  ed.requestRender()

proc setDarkTheme*(ed: SharedEditor; dark: bool) =
  ## The desktop switched its theme (`monaco.editor.setTheme`): the root's
  ## theme class and the token colours follow.
  if ed.darkTheme == dark: return
  ed.darkTheme = dark
  discard ed.root.classList.remove(cstring(if dark: "vs" else: "vs-dark"))
  discard ed.root.classList.add(cstring(if dark: "vs-dark" else: "vs"))
  ed.render()

proc setFont*(ed: SharedEditor; fontSize: int; fontFamily: string) =
  ## Monaco's `fontSize` / `fontFamily` options changed (the desktop's zoom,
  ## a mode switch): the cell re-measured, the line height re-derived.
  if fontSize > 0:
    ed.fontSize = fontSize
    ed.root.setStyle("font-size", cstring($fontSize & "px"))
    if ed.options.isNil or isNilOrUndef(ed.options["lineHeight"]) or
       jsNum(ed.options["lineHeight"]) <= 0:
      ed.lineHeight = defaultLineHeight(fontSize, hostPlatform() == pkMac)
  if fontFamily.len > 0:
    ed.root.setStyle("font-family", cstring(massagedFontFamily(fontFamily)))
  ed.measureFont()
  ed.render()

proc setLineNumbers*(ed: SharedEditor; fn: JsObject) =
  ## The gutter's numbers' renderer (Monaco's `lineNumbers` option).
  ed.lineNumbersFn = fn

proc listenerCount*(ed: SharedEditor; name: string): int =
  if ed.listeners.hasKey(name): ed.listeners[name].len else: 0

proc on*(ed: SharedEditor; name: string; f: JsObject): JsObject = ed.listen(name, f)

proc emitEvent*(ed: SharedEditor; name: string; ev: JsObject) = ed.fire(name, ev)

proc rangeOf*(ed: SharedEditor; a, b: int): JsObject = ed.rangeJs(a, b)

proc decorationRange*(ed: SharedEditor; id: string): JsObject =
  let r = ed.decos.rangeOf(id)
  if not r.found: return nil
  ed.rangeJs(r.fromOffset, r.toOffset)

proc actionsTable*(ed: SharedEditor): var Table[string, JsObject] = ed.actions
proc contextKeysTable*(ed: SharedEditor): var Table[string, JsObject] = ed.contextKeys
