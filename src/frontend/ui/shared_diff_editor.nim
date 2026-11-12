## ui/shared_diff_editor.nim — the unified-diff view on the shared editor.
##
## The VCS panel's and the review's unified diff (`ui/unified_diff`) is
## Monaco's diff editor in its inline layout: two code editors, the new
## revision read top to bottom and the old revision's removed lines drawn
## inside it as zones (`.view-lines.line-delete`). Under the developer setting
## `sharedEditor` the same view is two shared editors (`ui/shared_editor`)
## behind the part of Monaco's `IDiffEditor` the view calls (`setModel`,
## `getModifiedEditor`, `getOriginalEditor`, `updateOptions`, `layout`,
## `dispose`, `onDidUpdateDiff`, `getLineChanges`), with Monaco's structure
## and class names (`.monaco-diff-editor`,
## `.modified-in-monaco-diff-editor`, `.original-in-monaco-diff-editor`), so
## the view's decorations, gutter labels, hunk clicks and value bands work on
## either.
##
## The line diff is `editor_dom_frame.lineDiff` (a longest-common-subsequence
## over the lines, Monaco's `legacy` granularity); a removed run becomes a
## zone of the old lines under the line it followed, an added run a
## `line-insert` whole-line decoration.

import std/[jsffi]

import ./shared_editor
import ./shared_editor_facade
import ../view_vocabulary/editor_dom_frame

proc jsNew(): JsObject {.importjs: "({})@".}
proc jsArray(): JsObject {.importjs: "([])@".}
proc jsPush(a, v: JsObject) {.importjs: "#.push(#)".}
proc jsStr(v: JsObject): cstring {.importjs: "String(#)".}
proc isNilOrUndef(v: JsObject): bool {.importjs: "(# == null)".}
proc createEl(tag: cstring): JsObject {.importjs: "document.createElement(#)".}
proc setStyle(e: JsObject; k, v: cstring) {.importjs: "#.style.setProperty(#, #)".}
proc callFn(f: JsObject; a: JsObject): JsObject {.importjs: "#(#)".}
proc modelText(m: JsObject): string =
  if isNilOrUndef(m): "" else: $jsStr(m.getValue())

type
  SharedDiffEditor* = ref object
    host*, container*: JsObject
    original*, modified*: SharedEditor
    originalModel, modifiedModel: JsObject
    hunks*: seq[DiffHunk]
    zoneIds: seq[int]
    insertDecos: JsObject
    diffListeners: seq[JsObject]
    facade*: JsObject

proc redrawDiff(d: SharedDiffEditor) =
  ## The removed lines as zones in the new revision, the added ones marked.
  let oldLines = splitLinesKeep(d.original.text)
  let newLines = splitLinesKeep(d.modified.text)
  d.hunks = lineDiff(oldLines, newLines)
  for id in d.zoneIds: d.modified.removeZone(id)
  d.zoneIds = @[]
  let decos = jsArray()
  for h in d.hunks:
    if h.oldTo > h.oldFrom:
      let zone = createEl("div")
      zone.className = cstring"view-lines line-delete ct-diff-deleted"
      for k in h.oldFrom ..< h.oldTo:
        let row = createEl("div")
        row.className = cstring"view-line"
        row.setStyle("position", "relative")
        row.setStyle("height", cstring($d.modified.lineHeight & "px"))
        row.setStyle("line-height", cstring($d.modified.lineHeight & "px"))
        row.textContent = cstring(oldLines[k])
        discard zone.appendChild(row)
      let spec = jsNew()
      spec["afterLineNumber"] = h.newFrom
      spec["heightInLines"] = h.oldTo - h.oldFrom
      spec["domNode"] = zone
      d.zoneIds.add d.modified.addZone(spec)
    for k in h.newFrom ..< h.newTo:
      let r = jsNew()
      r["startLineNumber"] = k + 1
      r["startColumn"] = 1
      r["endLineNumber"] = k + 1
      r["endColumn"] = 1
      let o = jsNew()
      o["isWholeLine"] = true
      o["className"] = cstring"line-insert"
      let deco = jsNew()
      deco["range"] = r
      deco["options"] = o
      decos.jsPush(deco)
  d.insertDecos = d.modified.deltaDecorationsJs(
    (if d.insertDecos.isNil: jsArray() else: d.insertDecos), decos)
  d.modified.requestRender()
  for l in d.diffListeners: discard callFn(l, jsNew())

proc diffFacade(d: SharedDiffEditor): JsObject =
  if not d.facade.isNil: return d.facade
  let f = jsNew()
  d.facade = f
  f["__ctShared"] = true
  f["setModel"] = proc(m: JsObject) =
    if isNilOrUndef(m): return
    d.originalModel = m["original"]
    d.modifiedModel = m["modified"]
    d.original.replaceAll(modelText(d.originalModel))
    d.modified.replaceAll(modelText(d.modifiedModel))
    # The models' later `setValue` (a hunk expanded) reaches the editors.
    for (model, ed) in [(d.originalModel, d.original), (d.modifiedModel, d.modified)]:
      let target = ed
      if not isNilOrUndef(model) and not isNilOrUndef(model["onDidChangeContent"]):
        let theModel = model
        discard model.onDidChangeContent(proc(ev: JsObject) =
          target.replaceAll(modelText(theModel))
          d.redrawDiff())
    d.redrawDiff()
  f["getModel"] = proc(): JsObject =
    result = jsNew()
    result["original"] = d.originalModel
    result["modified"] = d.modifiedModel
  f["getModifiedEditor"] = proc(): JsObject = facadeOf(d.modified)
  f["getOriginalEditor"] = proc(): JsObject = facadeOf(d.original)
  f["updateOptions"] = proc(o: JsObject) =
    if isNilOrUndef(o): return
    if not isNilOrUndef(o["fontSize"]):
      discard
    d.modified.requestRender()
  f["getOptions"] = proc(): JsObject = jsNew()
  f["layout"] = proc(dim: JsObject) =
    discard facadeOf(d.modified).layout(dim)
  f["hasTextFocus"] = proc(): bool = d.modified.hasTextFocus or d.original.hasTextFocus
  f["focus"] = proc() = d.modified.focusEditor()
  f["dispose"] = proc() =
    d.original.dispose()
    d.modified.dispose()
    let c = d.container
    {.emit: ["if (", c, " && ", c, ".parentNode) ", c, ".parentNode.removeChild(", c, ");"].}
  f["onDidUpdateDiff"] = proc(cb: JsObject): JsObject =
    d.diffListeners.add cb
    result = jsNew()
    result["dispose"] = proc() = discard
  f["getLineChanges"] = proc(): JsObject =
    result = jsArray()
    for h in d.hunks:
      let c = jsNew()
      c["originalStartLineNumber"] = h.oldFrom + 1
      c["originalEndLineNumber"] = (if h.oldTo > h.oldFrom: h.oldTo else: 0)
      c["modifiedStartLineNumber"] = h.newFrom + 1
      c["modifiedEndLineNumber"] = (if h.newTo > h.newFrom: h.newTo else: 0)
      result.jsPush(c)
  f

proc newSharedDiffEditor*(host: JsObject; options: JsObject; fontSize: int;
                          fontFamily: string; darkTheme: bool;
                          language = ""): JsObject =
  ## The diff editor in `host`: Monaco's `createDiffEditor(host, options)`
  ## on the shared editor, in the inline layout.
  installMonacoGlobals()
  let d = SharedDiffEditor(host: host)
  let c = createEl("div")
  c.className = cstring"monaco-diff-editor ct-shared-diff-editor"
  c.setStyle("position", "relative")
  c.setStyle("width", "100%")
  c.setStyle("height", "100%")
  discard host.appendChild(c)
  d.container = c
  # The old revision's editor: present (its decorations are the view's) and
  # laid out, but not shown — the inline layout reads the new revision.
  let oldHost = createEl("div")
  oldHost.className = cstring"ct-diff-original-host"
  oldHost.setStyle("position", "absolute")
  oldHost.setStyle("left", "0")
  oldHost.setStyle("top", "0")
  oldHost.setStyle("width", "100%")
  oldHost.setStyle("height", "100%")
  oldHost.setStyle("visibility", "hidden")
  oldHost.setStyle("pointer-events", "none")
  discard c.appendChild(oldHost)
  let newHost = createEl("div")
  newHost.className = cstring"ct-diff-modified-host"
  newHost.setStyle("position", "absolute")
  newHost.setStyle("inset", "0")
  discard c.appendChild(newHost)
  let opts = if isNilOrUndef(options): jsNew() else: options
  d.original = newSharedEditor(oldHost, "", "", language, true, fontSize,
                               fontFamily, darkTheme, opts)
  d.modified = newSharedEditor(newHost, "", "", language, true, fontSize,
                               fontFamily, darkTheme, opts)
  discard d.original.root.classList.add(cstring"original-in-monaco-diff-editor")
  discard d.modified.root.classList.add(cstring"modified-in-monaco-diff-editor")
  # Monaco's diff editor carries a minimap element; the view's checks name it.
  let mini = createEl("div")
  mini.className = cstring"minimap"
  mini.setStyle("display", "none")
  discard d.modified.root.appendChild(mini)
  d.original.observeSize()
  d.modified.observeSize()
  d.diffFacade()
