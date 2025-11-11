import
  std/[jsffi, strutils, tables],
  types,
  ../common/lang,
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

const
  baseMarkerOwner = cstring("codetracer-lsp")
  diagnosticsMethod = cstring"textDocument/publishDiagnostics"

var
  entriesByPath = initTable[string, EditorEntry]()
  pathsByEditor = initTable[int, seq[string]]()
  diagnosticsHandlers = initTable[string, JsObject]()
  fsModuleCache: JsObject

proc detachLspDiagnostics*(kind: string)

proc decodeUriComponent(value: cstring): cstring {.importjs: "decodeURIComponent(#)".}
proc clientOnNotification(
  client: JsObject;
  methodName: cstring;
  handler: proc(params: JsObject) {.closure.}
): JsObject {.importjs: "#.onNotification(#, #)".}

proc disposeListener(handle: JsObject) =
  if handle.isNil:
    return
  try:
    discard call0(field(handle, "dispose"))
  except CatchableError:
    discard

proc monacoSetModelMarkers(model: JsObject; owner: cstring; markers: JsObject) {.importjs: "monaco.editor.setModelMarkers(#, #, #)".}
proc setFieldInt(target: JsObject; name: cstring; value: int) {.importjs: "#[#] = #".}

proc ensureFsModule(): JsObject =
  if fsModuleCache.isNil:
    fsModuleCache = requireModule("fs")
  fsModuleCache

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
      monacoSetModelMarkers(cast[JsObject](model), entry.owner, markers)
  pathsByEditor.del(editorId)

proc registerEntry(editorId: int; paths: seq[string]; entry: EditorEntry) =
  if paths.len == 0:
    return
  pathsByEditor[editorId] = paths
  for path in paths:
    entriesByPath[path] = entry

proc jsToInt(value: JsObject; fallback: int = 0): int =
  if value.isNil:
    fallback
  else:
    cast[int](value)

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
  monacoSetModelMarkers(cast[JsObject](model), owner, buildMarkers(params))

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

proc detachLspDiagnostics*(kind: string) =
  let key = normalizeKind(kind)
  if diagnosticsHandlers.hasKey(key):
    disposeListener(diagnosticsHandlers[key])
    diagnosticsHandlers.del(key)
