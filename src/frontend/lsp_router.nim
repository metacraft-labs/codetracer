import
  std/[jsffi, strutils, tables],
  types,
  lang,
  lib/[monaco_lib, jslib],
  lsp_js_bindings,
  lsp_paths

when not defined(js):
  {.error: "lsp_router can only be used with the JavaScript backend.".}

type
  EditorEntry = ref object
    editor: MonacoEditor
    owner: cstring
    kind: string
  SyncedEntry = ref object
    editorId: int
    path: string
    uri: string
    languageId: string
    lspKind: string
    editor: MonacoEditor
    model: MonacoTextModel
    opened: bool

const
  baseMarkerOwner = cstring("codetracer-lsp")
  diagnosticsMethod = cstring"textDocument/publishDiagnostics"
  didOpenMethod = cstring"textDocument/didOpen"
  didChangeMethod = cstring"textDocument/didChange"
  didCloseMethod = cstring"textDocument/didClose"
  diagnosticIdentifier = cstring"codetracer-diagnostics"

var
  entriesByPath = initTable[string, EditorEntry]()
  pathsByEditor = initTable[int, seq[string]]()
  diagnosticsHandlers = initTable[string, JsObject]()
  fsModuleCache: JsObject
  syncedByEditorId = initTable[int, SyncedEntry]()
  clientsByKind = initTable[string, JsObject]()

proc detachLspDiagnostics*(kind: string)
proc requestDiagnostics(entry: SyncedEntry)
proc processDiagnosticResult(entry: SyncedEntry; response: JsObject)
proc buildMarker(diag: JsObject): JsObject
proc buildMarkers(params: JsObject): JsObject

proc decodeUriComponent(value: cstring): cstring {.importjs: "decodeURIComponent(#)".}
proc clientOnNotification(
  client: JsObject;
  methodName: cstring;
  handler: proc(params: JsObject) {.closure.}
): JsObject {.importjs: "#.onNotification(#, #)".}
proc sendDiagnosticsRequest(
  client: JsObject;
  params: JsObject;
  handler: proc(response: JsObject) {.closure.}
) {.importjs: "(function(c,p,h){ c.sendRequest('textDocument/diagnostic', p).then(h, function(err){ console.error('[LSP diagnostics]', err); }); })(#, #, #)".}
proc sendNotification(client: JsObject; methodName: cstring; payload: JsObject) {.importjs: "#.sendNotification(#, #)".}
proc logPayload(prefix: cstring; payload: JsObject) {.importjs: "console.log(#, JSON.stringify(#, null, 2))".}
proc objectKeys(obj: JsObject): JsObject {.importjs: "Object.keys(#)".}

proc disposeListener(handle: JsObject) =
  if handle.isNil:
    return
  try:
    discard call0(field(handle, "dispose"))
  except CatchableError:
    discard

proc monacoSetModelMarkers(model: MonacoTextModel; owner: cstring; markers: JsObject) {.importjs: "monaco.editor.setModelMarkers(#, #, #)".}
proc setFieldInt(target: JsObject; name: cstring; value: int) {.importjs: "#[#] = #".}

proc ensureFsModule(): JsObject =
  if fsModuleCache.isNil:
    fsModuleCache = requireModule("fs")
  fsModuleCache

proc newPosition(line: int; character: int): JsObject =
  let pos = newObject()
  setFieldInt(pos, "line", line)
  setFieldInt(pos, "character", character)
  pos

proc pathExists(path: string): bool =
  if path.len == 0:
    return false
  try:
    let fsModule = ensureFsModule()
    cast[bool](call1(field(fsModule, "existsSync"), toJs(path.cstring)))
  except CatchableError:
    false

proc normalizeKind(kind: string): string =
  if kind.len == 0:
    ""
  else:
    kind.toLowerAscii()

proc ownerForKind(kind: string): cstring =
  let normalized = normalizeKind(kind)
  if normalized.len == 0:
    baseMarkerOwner
  else:
    cstring($baseMarkerOwner & ":" & normalized)

proc getClient(kind: string): JsObject =
  let key = normalizeKind(kind)
  if clientsByKind.hasKey(key):
    clientsByKind[key]
  else:
    nil

proc uriToNormalizedPath(uri: string): string =
  if uri.len == 0:
    return ""
  var processed = uri
  if processed.startsWith("file://"):
    processed = processed["file://".len .. ^1]
    if processed.len == 0:
      return ""
    if processed[0] != '/':
      processed = "/" & processed
  try:
    processed = $decodeUriComponent(processed.cstring)
  except CatchableError:
    discard
  result = normalizePathString(processed)
  if result.len == 0 and processed.len > 0:
    result = processed

proc traceSnapshotPath(data: Data; originalPath: string): string =
  if data.isNil or data.trace.isNil:
    return ""
  if originalPath.len == 0 or originalPath[0] != '/':
    return ""
  if data.trace.outputFolder.isNil:
    return ""
  let root = normalizePathString($data.trace.outputFolder)
  if root.len == 0:
    return ""
  let candidate = root & "/files" & originalPath
  if pathExists(candidate):
    candidate
  else:
    ""

proc candidatePaths(data: Data; rawPath: string): seq[string] =
  if data.isNil:
    return @[]
  var results: seq[string] = @[]
  let normalized = normalizePathString(rawPath)
  if normalized.len > 0:
    results.add(normalized)
  let snapshot = traceSnapshotPath(data, if normalized.len > 0: normalized else: rawPath)
  if snapshot.len > 0:
    let normalizedSnapshot = normalizePathString(snapshot)
    if normalizedSnapshot.len > 0 and normalizedSnapshot notin results:
      results.add(normalizedSnapshot)
  results

proc lspKindForLang(lang: Lang): string =
  case lang
  of LangRuby, LangRubyDb:
    "ruby"
  of LangRust, LangRustWasm:
    "rust"
  else:
    ""

proc pickSyncPath(paths: seq[string]): string =
  for candidate in paths:
    if pathExists(candidate):
      return candidate
  if paths.len > 0:
    paths[0]
  else:
    ""

proc sendDidClose(entry: SyncedEntry)

proc ensureDocumentOpened(entry: SyncedEntry) =
  if entry.isNil or entry.model.isNil:
    return
  let client = getClient(entry.lspKind)
  if client.isNil:
    entry.opened = false
    return
  if entry.opened:
    return
  let params = newObject()
  let textDoc = newObject()
  setField(textDoc, "uri", toJs(entry.uri.cstring))
  setField(textDoc, "languageId", toJs(entry.languageId.cstring))
  setFieldInt(textDoc, "version", entry.model.getVersionId())
  setField(textDoc, "text", toJs(entry.model.getValue()))
  setField(params, "textDocument", textDoc)
  logPayload(cstring"[LSP didOpen]", params)
  sendNotification(client, didOpenMethod, params)
  entry.opened = true
  requestDiagnostics(entry)

proc jsToInt(value: JsObject; fallback: int = 0): int =
  if value.isNil:
    fallback
  else:
    cast[int](value)

proc clampZero(value: int): int =
  if value <= 0: 0 else: value

proc sendDidChange(entry: SyncedEntry; changeEvent: JsObject = nil) =
  if entry.isNil or entry.model.isNil:
    return
  let client = getClient(entry.lspKind)
  if client.isNil:
    entry.opened = false
    return
  if not entry.opened:
    ensureDocumentOpened(entry)
    if not entry.opened:
      return
  let params = newObject()
  let textDoc = newObject()
  setField(textDoc, "uri", toJs(entry.uri.cstring))
  setFieldInt(textDoc, "version", entry.model.getVersionId())
  setField(params, "textDocument", textDoc)

  let lineCount = entry.model.getLineCount()
  let lastLineNumber = if lineCount <= 0: 1 else: lineCount
  let endLine = if lineCount <= 0: 0 else: lineCount - 1
  var endChar = entry.model.getLineMaxColumn(lastLineNumber)
  if endChar > 0:
    dec endChar

  let lspChanges = newArray()
  let currentText = $entry.model.getValue()
  if not changeEvent.isNil:
    let rawChanges = field(changeEvent, "changes")
    if not rawChanges.isNil and arrayLen(rawChanges) > 0:
      var idx = 0
      let count = arrayLen(rawChanges)
      while idx < count:
        let rawChange = arrayAt(rawChanges, idx)
        let lspChange = newObject()
        let rangeObj = field(rawChange, "range")
        if not rangeObj.isNil:
          let startLine = clampZero(jsToInt(field(rangeObj, "startLineNumber"), 1) - 1)
          let startCol = clampZero(jsToInt(field(rangeObj, "startColumn"), 1) - 1)
          let endLine = clampZero(jsToInt(field(rangeObj, "endLineNumber"), 1) - 1)
          let endCol = clampZero(jsToInt(field(rangeObj, "endColumn"), 1) - 1)
          let startPos = newPosition(startLine, startCol)
          let endPos = newPosition(endLine, endCol)
          let lspRange = newObject()
          setField(lspRange, "start", startPos)
          setField(lspRange, "end", endPos)
          setField(lspChange, "range", lspRange)
        let rangeLenField = field(rawChange, "rangeLength")
        if not rangeLenField.isNil:
          setFieldInt(lspChange, "rangeLength", jsToInt(rangeLenField, 0))
        let changeText = field(rawChange, "text")
        if not changeText.isNil:
          setField(lspChange, "text", changeText)
        push(lspChanges, lspChange)
        inc idx
  if arrayLen(lspChanges) == 0:
    let change = newObject()
    setField(change, "text", toJs(currentText.cstring))
    push(lspChanges, change)
  setField(params, "contentChanges", lspChanges)
  logPayload(cstring"[LSP didChange]", params)
  sendNotification(client, didChangeMethod, params)
  requestDiagnostics(entry)

proc sendDidClose(entry: SyncedEntry) =
  if entry.isNil or not entry.opened:
    return
  let client = getClient(entry.lspKind)
  if client.isNil:
    entry.opened = false
    return
  let params = newObject()
  let textDoc = newObject()
  setField(textDoc, "uri", toJs(entry.uri.cstring))
  setField(params, "textDocument", textDoc)
  logPayload(cstring"[LSP didClose]", params)
  sendNotification(client, didCloseMethod, params)
  entry.opened = false

proc requestDiagnostics(entry: SyncedEntry) =
  if entry.isNil:
    return
  if normalizeKind(entry.lspKind) != "ruby":
    return
  let client = getClient(entry.lspKind)
  if client.isNil:
    return
  let params = newObject()
  let textDoc = newObject()
  setField(textDoc, "uri", toJs(entry.uri.cstring))
  setField(params, "textDocument", textDoc)
  setField(params, "identifier", toJs(diagnosticIdentifier))
  sendDiagnosticsRequest(client, params, proc(response: JsObject) =
    processDiagnosticResult(entry, response)
  )

proc removeSyncedEntry(editorId: int) =
  if not syncedByEditorId.hasKey(editorId):
    return
  let entry = syncedByEditorId[editorId]
  if not entry.isNil:
    sendDidClose(entry)
  syncedByEditorId.del(editorId)

proc reopenDocumentsForClient(kind: string) =
  for _, entry in syncedByEditorId:
    if not entry.isNil and normalizeKind(entry.lspKind) == normalizeKind(kind):
      ensureDocumentOpened(entry)
      requestDiagnostics(entry)

proc applyDiagnosticsForUri(uri: string; diagItems: JsObject) =
  let normalized = uriToNormalizedPath(uri)
  if normalized.len == 0 or not entriesByPath.hasKey(normalized):
    return
  let entry = entriesByPath[normalized]
  if entry.isNil or entry.editor.isNil:
    return
  let model = entry.editor.getModel()
  if model.isNil:
    return
  let markers = newArray()
  if not diagItems.isNil:
    var idx = 0
    let count = arrayLen(diagItems)
    while idx < count:
      let diag = arrayAt(diagItems, idx)
      push(markers, buildMarker(diag))
      inc idx
  monacoSetModelMarkers(model, entry.owner, markers)

proc processDiagnosticResult(entry: SyncedEntry; response: JsObject) =
  if response.isNil:
    return
  let diagItems = field(response, "items")
  applyDiagnosticsForUri(entry.uri, diagItems)
  let relatedDocs = field(response, "relatedDocuments")
  if relatedDocs.isNil:
    return
  let keys = objectKeys(relatedDocs)
  let count = arrayLen(keys)
  var idx = 0
  while idx < count:
    let uriKey = arrayAt(keys, idx)
    if not uriKey.isNil:
      let uriCStr = toCString(uriKey)
      let uriText = $uriCStr
      let report = field(relatedDocs, uriCStr)
      if not report.isNil:
        applyDiagnosticsForUri(uriText, field(report, "items"))
    inc idx

proc registerSyncedEditor(component: EditorViewComponent; kind: string; paths: seq[string]) =
  if component.monacoEditor.isNil or component.tabInfo.isNil:
    return
  let syncPath = pickSyncPath(paths)
  if syncPath.len == 0:
    return
  removeSyncedEntry(component.id)
  let model = component.monacoEditor.getModel()
  if model.isNil:
    return
  let entry = SyncedEntry(
    editorId: component.id,
    path: syncPath,
    uri: toFileUri(syncPath),
    languageId: component.tabInfo.lang.toCLang(),
    lspKind: kind,
    editor: component.monacoEditor,
    model: model,
    opened: false
  )
  component.monacoEditor.onDidChangeModelContent(proc (event: JsObject) =
    sendDidChange(entry, event)
  )
  syncedByEditorId[component.id] = entry
  ensureDocumentOpened(entry)

proc removeEditorPaths(editorId: int) =
  if not pathsByEditor.hasKey(editorId):
    return
  let paths = pathsByEditor[editorId]
  var entry: EditorEntry = nil
  for path in paths:
    if entriesByPath.hasKey(path):
      entry = entriesByPath[path]
      entriesByPath.del(path)
  if not entry.isNil and not entry.editor.isNil:
    let model = entry.editor.getModel()
    if not model.isNil:
      let markers = newArray()
      monacoSetModelMarkers(model, entry.owner, markers)
  pathsByEditor.del(editorId)
  removeSyncedEntry(editorId)

proc registerEntry(editorId: int; paths: seq[string]; entry: EditorEntry) =
  if paths.len == 0:
    return
  pathsByEditor[editorId] = paths
  for path in paths:
    entriesByPath[path] = entry

proc markerSeverity(level: int): int =
  case level
  of 1: 8      # Error
  of 2: 4      # Warning
  of 3: 2      # Information
  of 4: 1      # Hint
  else: 4

proc buildMarker(diag: JsObject): JsObject =
  let marker = newObject()
  setFieldInt(marker, "severity", markerSeverity(jsToInt(field(diag, "severity"), 2)))
  let message = field(diag, "message")
  if not message.isNil:
    setField(marker, "message", message)
  let range = field(diag, "range")
  let start = if range.isNil: nil else: field(range, "start")
  let finish = if range.isNil: nil else: field(range, "end")
  setFieldInt(marker, "startLineNumber", jsToInt(field(start, "line"), 0) + 1)
  setFieldInt(marker, "startColumn", jsToInt(field(start, "character"), 0) + 1)
  setFieldInt(marker, "endLineNumber", jsToInt(field(finish, "line"), 0) + 1)
  setFieldInt(marker, "endColumn", jsToInt(field(finish, "character"), 0) + 1)
  let codeField = field(diag, "code")
  if not codeField.isNil:
    setField(marker, "code", codeField)
  let source = field(diag, "source")
  if not source.isNil:
    setField(marker, "source", source)
  marker

proc buildMarkers(params: JsObject): JsObject =
  let markers = newArray()
  let diagnostics = field(params, "diagnostics")
  if diagnostics.isNil:
    return markers
  var idx = 0
  let count = arrayLen(diagnostics)
  while idx < count:
    let diag = arrayAt(diagnostics, idx)
    push(markers, buildMarker(diag))
    inc idx
  markers

proc handleDiagnostics(kind: string; params: JsObject) =
  if params.isNil:
    return
  let uriField = field(params, "uri")
  if uriField.isNil:
    return
  let path = uriToNormalizedPath($toCString(uriField))
  if path.len == 0 or not entriesByPath.hasKey(path):
    return
  let entry = entriesByPath[path]
  if entry.isNil or entry.editor.isNil:
    return
  let model = entry.editor.getModel()
  if model.isNil:
    return
  let owner = entry.owner
  monacoSetModelMarkers(model, owner, buildMarkers(params))

proc registerLspEditor*(component: EditorViewComponent) =
  if component.isNil or component.data.isNil or component.monacoEditor.isNil or component.tabInfo.isNil:
    return
  if component.isExpansion:
    return
  let langValue = component.tabInfo.lang
  let kind = lspKindForLang(Lang(langValue))
  if kind.len == 0:
    return
  let pathValue = if component.path.isNil: "" else: $component.path
  var paths: seq[string] = @[]
  for rawPath in candidatePaths(component.data, pathValue):
    let normalizedPath = uriToNormalizedPath(rawPath)
    if normalizedPath.len > 0 and normalizedPath notin paths:
      paths.add(normalizedPath)
  if paths.len == 0:
    return
  removeEditorPaths(component.id)
  let entry = EditorEntry(editor: component.monacoEditor, owner: ownerForKind(kind), kind: kind)
  registerEntry(component.id, paths, entry)
  registerSyncedEditor(component, kind, paths)

proc unregisterLspEditor*(component: EditorViewComponent) =
  if component.isNil:
    return
  removeEditorPaths(component.id)

proc attachLspDiagnostics*(kind: string; client: JsObject) =
  if client.isNil:
    return
  let key = normalizeKind(kind)
  detachLspDiagnostics(kind)
  let handler = proc(params: JsObject) {.closure.} =
    handleDiagnostics(key, params)
  diagnosticsHandlers[key] = clientOnNotification(client, diagnosticsMethod, handler)
  clientsByKind[key] = client
  reopenDocumentsForClient(key)

proc detachLspDiagnostics*(kind: string) =
  let key = normalizeKind(kind)
  if diagnosticsHandlers.hasKey(key):
    disposeListener(diagnosticsHandlers[key])
    diagnosticsHandlers.del(key)
  if clientsByKind.hasKey(key):
    clientsByKind.del(key)
  for _, entry in syncedByEditorId:
    if not entry.isNil and normalizeKind(entry.lspKind) == key:
      entry.opened = false
