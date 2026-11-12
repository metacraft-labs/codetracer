## shared_editor_lsp_chromium_test.nim — the desktop's shared editor's
## language features (`ui/shared_editor_lsp`) against a REAL language server:
## `nimlangserver` (the dev shell's, the server the desktop starts for Nim),
## spoken to over stdio by the Chromium runner (`chromium-run.mjs`'s
## `ctLspStart` / `ctLspRequest` / `ctLspNotify`).
##
## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK: the desktop's LSP router
## (`lsp_router`) is not in this page — it needs the Electron index process
## that starts the servers. Its two jobs are done here in its place, by the
## same protocol: the document is opened and kept in sync with
## `textDocument/didOpen` / `didChange` (the router's `sendDidChange` sends
## the full text too), and `window.codetracerLsp.sendRequest(kind, method,
## params)` — the bridge the router publishes — forwards to the server. The
## server's answers are the server's.
##
## WHY A BROWSER: the features are shown as DOM the pointer and the keys reach
## (the hover after the pointer rests, the suggestion list's keys).
##
## COUNTED ASSERTIONS (Verification-Harness-Traps §4c).

import std/[asyncjs, jsffi, strutils]

import ../ui/[shared_editor, shared_editor_facade, shared_editor_lsp]
import ../viewmodel/editing_core

const
  MainText = staticRead("fixtures/shared_editor_lsp/main.nim")

var
  MainPath = ""
  MainUri = ""
    ## Set from the directory the runner wrote the project into.
  ExpectedChecks = 14
    ## Written from a run. See the end of `main`.

proc ctLspStart(command: cstring; args: JsObject; filesJson: cstring): Future[cstring] {.importjs:
  "window.ctLspStart(#, #, #)".}
proc ctLspRequest(meth, json: cstring): Future[cstring] {.importjs: "window.ctLspRequest(#, #)".}
proc ctLspNotify(meth, json: cstring): Future[void] {.importjs: "window.ctLspNotify(#, #)".}
proc ctPress(selector, key: cstring): Future[void] {.importjs: "window.ctPress(#, #)".}
proc ctMouse(kind: cstring; x, y: float; button: cstring;
             clickCount: int): Future[void] {.importjs: "window.ctMouse(#, #, #, #, #)".}
proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
proc ctKey(kind, key: cstring): Future[void] {.importjs: "window.ctKey(#, #)".}
proc ctOnly(): cstring {.importjs: "(window.ctOnly || '')@".}
  ## The cases a harness asked for (`CT_CHROMIUM_ONLY`), or "" for all.

proc selected(name: string): bool =
  let only = $ctOnly()
  only.len == 0 or name in only.split(',')
proc sleep(ms: int): Future[void] {.importjs: "new Promise((r) => setTimeout(r, #))".}
proc setHtml(html: cstring) {.importjs: "document.body.innerHTML = #".}
proc qs(sel: cstring): JsObject {.importjs: "document.querySelector(#)".}
proc isNull(o: JsObject): bool {.importjs: "(# == null)".}
proc jsNew(): JsObject {.importjs: "({})@".}
proc jsonOf(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
proc jsParse(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
proc rectOf(e: JsObject): JsObject {.importjs: "#.getBoundingClientRect()".}
proc num(v: JsObject): float {.importjs: "Number(#)".}
proc installBridge() {.importjs: """
  (() => {
    window.codetracerLspClients = { nim: {} };
    window.codetracerLsp = { sendRequest: (k, m, p) =>
      // The dev shell's server advertises semantic tokens but never answers
      // a range request, and the unanswered request stalls every request
      // after it; the bridge refuses it here (the semantic case below plays
      // the codetracer langserver's response instead).
      (m === 'textDocument/semanticTokens/range')
        ? Promise.reject(new Error('semantic tokens are not served by this server'))
        : window.ctLspRequest(m, JSON.stringify(p)).then((s) => {
        const r = JSON.parse(s);
        if (r && r.__error) throw new Error(JSON.stringify(r.__error));
        return r;
      }) };
  })()@""".}
type js = JsObject

proc publishInitializeResult(init: JsObject) {.importjs:
  "(window.codetracerLspClients.nim.initializeResult = #)".}
  ## The client object the router publishes carries the server's
  ## `initialize` result (vscode-languageclient's `initializeResult`).

proc str(v: JsObject): string =
  if v.isNil or isNull(v): "" else: $v.to(cstring)

var checks = 0
var caseFailed = false
var failedCases = 0

template ck(cond: untyped; detail: string = "") =
  inc checks
  if not (cond):
    caseFailed = true
    echo "    Check failed: " & astToStr(cond) &
      (if detail.len > 0: "  -- " & detail else: "")

proc beginCase() = caseFailed = false
proc endCase(name: string) =
  if caseFailed:
    inc failedCases
    echo "  [FAILED] " & name
  else:
    echo "  [OK] " & name

proc waitFor(cond: proc(): bool; ms: int): Future[bool] {.async.} =
  var waited = 0
  while waited < ms:
    if cond(): return true
    await sleep(100)
    waited += 100
  return cond()

var version = 1

proc openEditor(): SharedEditor =
  setHtml("""<div id="host" style="width: 900px; height: 500px; position: relative"></div>""")
  let all = sharedEditors
  for e in all: e.dispose()
  installMonacoGlobals()
  result = newSharedEditor(qs("#host"), MainText, MainPath, "nim", false, 14,
                           "monospace", true, jsNew())
  let ed = result
  installSharedEditorLsp(ed, proc(): tuple[kind, uri: string] = ("nim", MainUri))
  # The router's sync: the full text on every change.
  discard ed.on("content", toJs(proc(ev: JsObject) =
    inc version
    let p = jsNew()
    let td = jsNew()
    td["uri"] = cstring(MainUri)
    td["version"] = version
    p["textDocument"] = td
    let change = jsNew()
    change["text"] = cstring(ed.text)
    p["contentChanges"] = toJs([change])
    discard ctLspNotify("textDocument/didChange", jsonOf(p))))
  ed.render()

proc pointOf(ed: SharedEditor; line1, byteCol: int): tuple[x, y: float] =
  let base = rectOf(ed.root.querySelector(cstring".lines-content"))
  let vl = ed.root.querySelector(cstring(".view-line[data-line=\"" & $line1 & "\"]"))
  let r = rectOf(vl)
  (num(base.left) + ed.xOfByteCol(line1, byteCol) + ed.charWidth / 2,
   num(r.top) + num(r.height) / 2)

proc lineOf(text, needle: string): int =
  let ls = text.splitLines()
  for i, l in ls:
    if needle in l: return i + 1
  0

proc caseHover(ed: SharedEditor) {.async.} =
  beginCase()
  # The pointer rests on `greet` in `echo greet(greeter)`.
  let line = lineOf(MainText, "echo greet(")
  let p = ed.pointOf(line, "echo gr".len)
  await ctMouse("move", p.x, p.y, "left", 1)
  let shown = await waitFor(proc(): bool =
    str(ed.root.getAttribute(cstring"data-ct-hover")).contains("greet"), 60_000)
  ck shown, "a hover naming `greet` (got `" &
    str(ed.root.getAttribute(cstring"data-ct-hover")) & "`)"
  ck not isNull(ed.root.querySelector(cstring".monaco-hover.ct-hover"))
  endCase("the server's hover shows where the pointer rests")

proc caseDefinition(ed: SharedEditor) {.async.} =
  beginCase()
  let line = lineOf(MainText, "echo greet(")
  discard facadeOf(ed).setPosition(js{lineNumber: line, column: 8})
  ed.focusEditor()
  await ctPress("", "F12")
  let defLine = lineOf(MainText, "proc greet")
  let moved = await waitFor(proc(): bool =
    ed.positionAt(ed.doc.state.primaryHead).lineNumber == defLine, 30_000)
  ck moved, "F12 moved the caret to line " & $defLine & " (it is on " &
    $ed.positionAt(ed.doc.state.primaryHead).lineNumber & ")"
  endCase("go to definition moves the caret to the declaration")

proc caseCompletion(ed: SharedEditor) {.async.} =
  beginCase()
  # A new line at the end: `greeter.ti`, then the list.
  let last = ed.lineCount
  discard facadeOf(ed).setPosition(js{lineNumber: last, column: 1})
  ed.focusEditor()
  for ch in "echo greeter.ti":
    discard ed.applyKeyName($ch)
  await ctPress("", "Control+Space")
  let listed = await waitFor(proc(): bool =
    str(ed.root.getAttribute(cstring"data-ct-suggest")).len > 0, 60_000)
  ck listed, "the suggestion list opened"
  if listed:
    let row = ed.root.querySelector(cstring".ct-suggest .monaco-list-row.focused")
    ck not isNull(row) and str(row.textContent).startsWith("times"),
      "the first suggestion is `times`: `" & (if isNull(row): "" else: str(row.textContent)) & "`"
    # Enter accepts, through the key the list owns.
    ck ed.keyInterceptor("Enter")
    ck ed.lineText(last) == "echo greeter.times", "line `" & ed.lineText(last) & "`"
  endCase("completion lists the server's items and Enter inserts one")

proc caseCtrlClickDefinition(ed: SharedEditor) {.async.} =
  beginCase()
  # Ctrl+click on `greet` in `echo greet(greeter)`, the caret elsewhere.
  discard facadeOf(ed).setPosition(js{lineNumber: 1, column: 1})
  let line = lineOf(MainText, "echo greet(")
  let p = ed.pointOf(line, "echo gr".len)
  await ctKey("down", "Control")
  await ctMouse("click", p.x, p.y, "left", 1)
  await ctKey("up", "Control")
  let defLine = lineOf(MainText, "proc greet")
  let moved = await waitFor(proc(): bool =
    ed.positionAt(ed.doc.state.primaryHead).lineNumber == defLine, 30_000)
  ck moved, "Ctrl+click moved the caret to line " & $defLine & " (it is on " &
    $ed.positionAt(ed.doc.state.primaryHead).lineNumber & ")"
  endCase("Ctrl+click on a symbol goes to its definition in a writable editor")

proc cannedSemanticTokens() {.importjs: """
  (() => {
    const live = window.codetracerLsp.sendRequest;
    const cli = window.codetracerLspClients.nim;
    cli.initializeResult = cli.initializeResult || { capabilities: {} };
    cli.initializeResult.capabilities.semanticTokensProvider = { range: true };
    window.codetracerLsp.sendRequest = (k, m, p) => {
      if (m !== 'textDocument/semanticTokens/range') return live(k, m, p);
      // Line 9 (`proc greet(g: Greeter)`): `greet` a function (type 11),
      // `g` a parameter (type 7), `Greeter` a type (type 1); LSP's relative
      // encoding, 0-based lines.
      return Promise.resolve({ data: [8, 5, 5, 11, 1,  0, 6, 1, 7, 0,  0, 3, 7, 1, 0] });
    };
  })()@""".}

proc caseSemanticTokens(ed: SharedEditor) {.async.} =
  beginCase()
  # THE SECOND STAND-IN: the dev shell's nimlangserver 1.12.0 does not answer
  # `textDocument/semanticTokens/range` (measured 2026-11-12: no response in
  # 8 s, and `.../full` is "rpc method not found"), so the desktop's Monaco
  # gets no semantic tokens from it either. The response the codetracer
  # langserver sends (`nim-langserver/semantic_tokens.nim`, the legend in
  # `languages/nimSemanticTokens.js`) is played here instead, through the
  # same bridge; what is graded is the decoding and the painting.
  cannedSemanticTokens()
  ed.render()
  let coloured = await waitFor(proc(): bool =
    not isNull(ed.root.querySelector(cstring(".view-line span[class*=\"ct-sem-\"]"))), 10_000)
  ck coloured, "semantic token spans drawn"
  let fn = ed.root.querySelector(cstring(".view-line[data-line=\"9\"] .ct-sem-function"))
  ck not isNull(fn) and str(fn.textContent) == "greet",
    "`greet` painted as a function"
  let ty = ed.root.querySelector(cstring(".view-line[data-line=\"9\"] .ct-sem-type"))
  ck not isNull(ty) and str(ty.textContent) == "Greeter"
  endCase("the server's semantic tokens colour the drawn lines")

proc caseDiagnostics(ed: SharedEditor) {.async.} =
  beginCase()
  # The router's diagnostics path: `setModelMarkers` on the editor's model.
  let f = facadeOf(ed)
  {.emit: ["""monaco.editor.setModelMarkers(""", f, """.getModel(), 'nim',
    [{severity: 8, startLineNumber: 3, startColumn: 1, endLineNumber: 3,
      endColumn: 5, message: 'undeclared identifier'}]);"""].}
  await sleep(50)
  let sq = ed.root.querySelector(cstring".view-overlays .squiggly-error")
  ck not isNull(sq), "an error squiggle"
  ck not isNull(sq) and str(sq.getAttribute(cstring"title")) == "undeclared identifier"
  endCase("the router's diagnostics squiggle their spans")

proc main() {.async.} =
  echo ""
  echo "[Suite] the shared editor's language features against nimlangserver"
  installBridge()
  let files = jsNew()
  files["main.nim"] = cstring(MainText)
  let started = jsParse(await ctLspStart("nimlangserver", toJs(newSeq[cstring]()),
                                         jsonOf(files)))
  MainPath = str(started.root) & "/main.nim"
  publishInitializeResult(started.init)
  MainUri = "file://" & MainPath
  let ed = openEditor()
  let p = jsNew()
  let td = jsNew()
  td["uri"] = cstring(MainUri)
  td["languageId"] = cstring"nim"
  td["version"] = 1
  td["text"] = cstring(MainText)
  p["textDocument"] = td
  await ctLspNotify("textDocument/didOpen", jsonOf(p))
  # The server answers once its nimsuggest has loaded the project (seconds):
  # wait for a hover to come back, as a user waits for the first one.
  var serverReady = false
  for attempt in 0 ..< 60:
    let hp = jsNew()
    let htd = jsNew()
    htd["uri"] = cstring(MainUri)
    hp["textDocument"] = htd
    let pos = jsNew()
    pos["line"] = lineOf(MainText, "echo greet(") - 1
    pos["character"] = 7
    hp["position"] = pos
    let raw = await ctLspRequest("textDocument/hover", jsonOf(hp))
    if $raw != "null" and ($raw).len > 4:
      serverReady = true
      break
    await sleep(1000)
  echo "    server ready: " & $serverReady
  if selected("caseDiagnostics"): await caseDiagnostics(ed)
  if selected("caseHover"): await caseHover(ed)
  if selected("caseDefinition"): await caseDefinition(ed)
  if selected("caseCtrlClickDefinition"): await caseCtrlClickDefinition(ed)
  if selected("caseSemanticTokens"): await caseSemanticTokens(ed)
  if selected("caseCompletion"): await caseCompletion(ed)
  beginCase()
  inc checks
  echo "CHECKS: " & $checks
  if ($ctOnly()).len == 0 and checks != ExpectedChecks:
    caseFailed = true
    echo "    assertion count is " & $checks & ", expected " & $ExpectedChecks
  endCase("every assertion above ran")
  ctFinish(if failedCases > 0: 1 else: 0)

discard main()
