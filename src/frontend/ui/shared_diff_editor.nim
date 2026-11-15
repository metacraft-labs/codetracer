## ui/shared_diff_editor.nim — the unified-diff view on the shared editor.
##
## The VCS panel's and the review's unified diff (`ui/unified_diff`) is
## Monaco's diff editor in its inline layout: two code editors, the new
## revision read top to bottom and the old revision's removed lines drawn
## inside it as zones (`.view-lines.line-delete`), the old revision itself a
## strip of line numbers beside it. Under the developer setting
## `sharedEditor` the same view is two shared editors (`ui/shared_editor`)
## behind the part of Monaco's `IDiffEditor` the view calls (`setModel`,
## `getModifiedEditor`, `getOriginalEditor`, `updateOptions`, `layout`,
## `dispose`, `onDidUpdateDiff`, `getLineChanges`), with Monaco's structure
## and class names (`.monaco-diff-editor`,
## `.modified-in-monaco-diff-editor`, `.original-in-monaco-diff-editor`), so
## the view's decorations, gutter labels, hunk clicks, value bands and
## boundary gestures work on either.
##
## What it draws, each as Monaco 0.54 draws it (codetracer-pm
## spec/Architecture/Editor-ViewModel.md §3.2b):
##
##   * the line diff (`editor_dom_frame.lineDiff`): a removed run becomes a
##     zone of the old lines, coloured by the old revision's tokens, under
##     the line it followed; an added run is marked `line-insert`;
##   * WORD-LEVEL marks inside a run that both removes and adds
##     (`diff_regions.innerChanges`): `char-delete` over the removed words in
##     the zone and the old revision, `char-insert` over the added words; a
##     run of one kind is marked whole-line;
##   * with `hideUnchangedRegions`, the COLLAPSED REGIONS
##     (`diff_regions.unchangedRegions`): the hidden lines are the editors'
##     hidden areas, and each region's band (`.diff-hidden-lines-widget`)
##     carries Monaco's `.top` and `.bottom` handles — a press reveals
##     `revealLineCount` lines, a drag one line per line height — and its
##     `.center` ("N hidden lines", the unfold control). The regions are
##     reachable as Monaco's are, `_diffModel.get().unchangedRegions.get()`,
##     which is what `ui/diff_expansion` adds the keyboard path, the
##     accessible names and the menu through;
##   * the old revision ALIGNED row for row beside the new one
##     (`diff_regions.originalZones`): a spacer for each added run, each
##     band and each of the view's own zones (the value bands, the call and
##     loop controls), and one scroll position for both.

import std/[jsffi, strutils]

import ./shared_editor
import ./shared_editor_facade
import ../view_vocabulary/[editor_dom_frame, diff_regions]
from ../lib/monaco_appearance import CodeTracerDarkDiffVariables,
  CodeTracerWhiteDiffVariables

proc jsNew(): JsObject {.importjs: "({})@".}
proc jsArray(): JsObject {.importjs: "([])@".}
proc jsPush(a, v: JsObject) {.importjs: "#.push(#)".}
proc jsStr(v: JsObject): cstring {.importjs: "String(#)".}
proc jsNum(v: JsObject): float {.importjs: "Number(#)".}
proc isNilOrUndef(v: JsObject): bool {.importjs: "(# == null)".}
proc createEl(tag: cstring): JsObject {.importjs: "document.createElement(#)".}
proc setStyle(e: JsObject; k, v: cstring) {.importjs: "#.style.setProperty(#, #)".}
proc setAttr(e: JsObject; k, v: cstring) {.importjs: "#.setAttribute(#, #)".}
proc toggleClass(e: JsObject; c: cstring; on: bool) {.importjs: "#.classList.toggle(#, #)".}
proc addListener(e: JsObject; ev: cstring; f: proc(ev: JsObject)) {.importjs:
  "#.addEventListener(#, #)".}
proc removeListener(e: JsObject; ev: cstring; f: proc(ev: JsObject)) {.importjs:
  "#.removeEventListener(#, #)".}
proc callFn(f: JsObject; a: JsObject): JsObject {.importjs: "#(#)".}
proc shallowCopy(o: JsObject): JsObject {.importjs: "Object.assign({}, #)".}
proc ownerDoc(e: JsObject): JsObject {.importjs: "(#.ownerDocument || document)".}
proc removeEl(e: JsObject) {.importjs: "((e) => e && e.parentNode && e.parentNode.removeChild(e))(#)".}
proc queueTask(f: proc()) {.importjs: "queueMicrotask(#)".}
proc modelText(m: JsObject): string =
  if isNilOrUndef(m): "" else: $jsStr(m.getValue())

const
  DeletedZoneOrder = 1
    ## The removed lines' block comes under the view's own blocks after its
    ## line (a value band under the line), as Monaco orders them…
  BandZoneOrder = 2
    ## …and a collapsed region's band last, right above the lines it hides.
  SpacerOrderBase = -1_000_000
    ## The old revision's spacers keep the order `originalZones` gives them.

const DiffEditorCss = """
.ct-diff-original-host .scrollbar, .ct-diff-original-host .view-lines,
.ct-diff-original-host .cursors-layer, .ct-diff-original-host .diff-hidden-lines-widget
  { visibility: hidden !important; }
.ct-shared-diff-editor .view-zones, .ct-shared-diff-editor .diff-hidden-lines-widget {
  font-family: -apple-system, BlinkMacSystemFont, "Segoe WPC", "Segoe UI", "HelveticaNeue-Light",
    system-ui, "Ubuntu", "Droid Sans", sans-serif; }
:where(.ct-shared-diff-editor) .diff-hidden-lines-widget { width: 100%; }
:where(.ct-shared-diff-editor) .diff-hidden-lines {
  height: 0; transform: translate(0, -10px); font-size: 13px; line-height: 14px; }
:where(.ct-shared-diff-editor) .diff-hidden-lines .top,
:where(.ct-shared-diff-editor) .diff-hidden-lines .bottom {
  transition: background-color 0.1s ease-out; height: 4px; background-color: transparent;
  background-clip: padding-box; border-bottom: 2px solid transparent;
  border-top: 4px solid transparent; }
:where(.ct-shared-diff-editor) .diff-hidden-lines .top { transform: translate(0, 4px); }
:where(.ct-shared-diff-editor) .diff-hidden-lines .bottom { transform: translate(0, -6px); }
:where(.ct-shared-diff-editor) .diff-hidden-lines .top:hover,
:where(.ct-shared-diff-editor) .diff-hidden-lines .bottom:hover,
:where(.ct-shared-diff-editor) .diff-hidden-lines .dragging { background-color: #007fd4; }
:where(.ct-shared-diff-editor) .diff-hidden-lines .canMoveTop:not(.canMoveBottom) { cursor: n-resize; }
:where(.ct-shared-diff-editor) .diff-hidden-lines .canMoveBottom:not(.canMoveTop) { cursor: s-resize; }
:where(.ct-shared-diff-editor) .diff-hidden-lines .canMoveTop.canMoveBottom { cursor: ns-resize; }
:where(.ct-shared-diff-editor) .diff-hidden-lines .center {
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; height: 24px;
  background: rgba(128, 128, 128, 0.16); }
:where(.ct-shared-diff-editor) {
  --vscode-diffEditor-insertedTextBackground: rgba(156, 204, 44, 0.2);
  --vscode-diffEditor-removedTextBackground: rgba(255, 0, 0, 0.2);
  --vscode-diffEditor-insertedLineBackground: rgba(155, 185, 85, 0.2);
  --vscode-diffEditor-removedLineBackground: rgba(255, 0, 0, 0.2); }
:where(.ct-shared-diff-editor) .char-insert {
  background-color: var(--vscode-diffEditor-insertedTextBackground); }
:where(.ct-shared-diff-editor) .line-insert {
  background-color: var(--vscode-diffEditor-insertedLineBackground); }
:where(.ct-shared-diff-editor) .char-delete {
  background-color: var(--vscode-diffEditor-removedTextBackground); }
:where(.ct-shared-diff-editor) .line-delete {
  background-color: var(--vscode-diffEditor-removedLineBackground); }
"""
  ## The look Monaco's stylesheet gives the diff's own elements, at no
  ## specificity, so the page's rules (`styles/components/unified_diff.styl`)
  ## and Monaco's own, where loaded, decide; a page without them still draws
  ## the bands, their handles and the change colours. The view's zones and
  ## the bands are in the UI face, as Monaco's (its `.monaco-editor` rule; the
  ## code face is on the text and the removed lines). The change colours are
  ## Monaco's theme variables (vs-dark's defaults here): Monaco defines them
  ## only once one of its own editors has started its theme service, which a
  ## window drawing only shared editors never does.

type
  Band = tuple[region, zoneId: int; node, top, bottom, label, spec: JsObject]

  SharedDiffEditor* = ref object
    host*, container*, oldHost, newHost: JsObject
    original*, modified*: SharedEditor
    originalModel, modifiedModel: JsObject
    oldLines, newLines: seq[string]
    hunks*: seq[DiffHunk]
    regions*: seq[UnchangedRegion]
    hideUnchanged*: bool
    contextLineCount*, minimumLineCount*, revealLineCount*: int
    deletedZoneIds: seq[int]
    bands: seq[Band]
    spacerIds: seq[int]
    modifiedDecos, originalDecos: seq[string]
    diffListeners: seq[JsObject]
    aligning: bool
    redrawQueued: bool
    stripWidth: int
    facade*: JsObject

# ---------------------------------------------------------------------------
# Options
# ---------------------------------------------------------------------------

proc readRegionOptions(d: SharedDiffEditor; o: JsObject) =
  ## `hideUnchangedRegions: {enabled, contextLineCount, minimumLineCount,
  ## revealLineCount}`, Monaco's defaults where a field is absent (3, 3, 20).
  if isNilOrUndef(o): return
  let h = o["hideUnchangedRegions"]
  if isNilOrUndef(h): return
  d.hideUnchanged = not isNilOrUndef(h["enabled"]) and h["enabled"].to(bool)
  proc field(name: string; dflt: int): int =
    if isNilOrUndef(h[cstring(name)]): dflt else: int(jsNum(h[cstring(name)]))
  d.contextLineCount = field("contextLineCount", 3)
  d.minimumLineCount = field("minimumLineCount", 3)
  d.revealLineCount = field("revealLineCount", 20)

# ---------------------------------------------------------------------------
# Layout: hidden areas, bands, the old revision's spacers
# ---------------------------------------------------------------------------

proc applyRegions(d: SharedDiffEditor)

proc alignOriginal(d: SharedDiffEditor) =
  ## The old revision's spacers for the new revision's blocks.
  if d.aligning: return
  d.aligning = true
  var mods: seq[AlignZone] = @[]
  for z in d.modified.zoneInfos:
    if z.id in d.deletedZoneIds: continue
    mods.add AlignZone(afterLine: z.afterLine, heightPx: z.heightPx, order: z.order)
  for id in d.spacerIds: d.original.removeZone(id)
  d.spacerIds = @[]
  for z in originalZones(d.hunks, mods, d.modified.lineHeight, DeletedZoneOrder):
    let spec = jsNew()
    spec["afterLineNumber"] = z.afterLine
    spec["heightInPx"] = z.heightPx
    spec["ctOrder"] = SpacerOrderBase + z.order
    let node = createEl("div")
    node.setAttr("class", "ct-diff-spacer")
    spec["domNode"] = node
    d.spacerIds.add d.original.addZone(spec)
  d.aligning = false
  d.original.requestRender()

proc regionAction(d: SharedDiffEditor; index: int;
                  action: proc(r: var UnchangedRegion)) =
  if index < 0 or index >= d.regions.len: return
  action(d.regions[index])
  d.applyRegions()

proc keepBoundaryAt(d: SharedDiffEditor; index: int;
                    action: proc(r: var UnchangedRegion)) =
  ## Reveal at the region's lower end without moving the lines below it on
  ## screen (Monaco's widget scrolls by what the region grew).
  if index < 0 or index >= d.regions.len: return
  let r = d.regions[index]
  let endLine = r.modifiedLine + r.lineCount
  let before = d.modified.topForLine(endLine)
  action(d.regions[index])
  d.applyRegions()
  let after = d.modified.topForLine(endLine)
  if after != before:
    d.modified.setScroll(d.modified.scrollTop + (after - before), d.modified.scrollLeft)

proc dragHandle(d: SharedDiffEditor; index: int; top: bool; handle, ev: JsObject) =
  ## Monaco's boundary drag: one line per line height, a press that does not
  ## move reveals `revealLineCount` lines.
  if not isNilOrUndef(ev["button"]) and int(jsNum(ev["button"])) != 0: return
  if index < 0 or index >= d.regions.len: return
  discard ev.preventDefault()
  handle.toggleClass("dragging", true)
  let startY = jsNum(ev["clientY"])
  let start = if top: d.regions[index].visibleTop else: d.regions[index].visibleBottom
  var moved = false
  let doc = ownerDoc(handle)
  var onMove, onUp: proc(e: JsObject)
  onMove = proc(e: JsObject) =
    if index >= d.regions.len: return
    let y = jsNum(e["clientY"])
    moved = moved or dragMoved(startY, y)
    let r = d.regions[index]
    if top:
      let v = draggedVisibleTop(start, startY, y, d.modified.lineHeight, r)
      d.regionAction(index, proc(rr: var UnchangedRegion) = rr.visibleTop = v)
    else:
      let v = draggedVisibleBottom(start, startY, y, d.modified.lineHeight, r)
      d.keepBoundaryAt(index, proc(rr: var UnchangedRegion) = rr.visibleBottom = v)
  onUp = proc(e: JsObject) =
    doc.removeListener("mousemove", onMove)
    doc.removeListener("mouseup", onUp)
    handle.toggleClass("dragging", false)
    if not moved:
      let n = d.revealLineCount
      if top: d.regionAction(index, proc(rr: var UnchangedRegion) = rr.showMoreAbove(n))
      else: d.keepBoundaryAt(index, proc(rr: var UnchangedRegion) = rr.showMoreBelow(n))
  doc.addListener("mousemove", onMove)
  doc.addListener("mouseup", onUp)

proc bandNode(d: SharedDiffEditor; index: int):
    tuple[node, top, bottom, label: JsObject] =
  ## Monaco's band: `div.diff-hidden-lines-widget > div.diff-hidden-lines >
  ## (.top, .center, .bottom)`.
  let root = createEl("div")
  root.setAttr("class", "diff-hidden-lines-widget")
  let lines = createEl("div")
  lines.setAttr("class", "diff-hidden-lines")
  discard root.appendChild(lines)
  let top = createEl("div")
  top.setAttr("class", "top")
  top.setAttr("title", "Click or drag to show more above")
  let center = createEl("div")
  center.setAttr("class", "center")
  center.setStyle("display", "flex")
  let first = createEl("div")
  first.setStyle("display", "flex")
  first.setStyle("justify-content", "center")
  first.setStyle("align-items", "center")
  first.setStyle("flex-shrink", "0")
  first.setStyle("width", cstring($d.modified.gutterPx & "px"))
  let unfold = createEl("a")
  unfold.setAttr("title", "Show Unchanged Region")
  unfold.setAttr("role", "button")
  let icon = createEl("span")
  icon.setAttr("class", "codicon codicon-unfold")
  discard unfold.appendChild(icon)
  let regionIndex = index
  unfold.addListener("click", proc(e: JsObject) =
    d.regionAction(regionIndex, proc(r: var UnchangedRegion) = r.showAll()))
  discard first.appendChild(unfold)
  let others = createEl("div")
  others.setStyle("display", "flex")
  others.setStyle("justify-content", "center")
  others.setStyle("align-items", "center")
  let label = createEl("span")
  label.setAttr("title", "Double click to unfold")
  label.addListener("dblclick", proc(e: JsObject) =
    if not isNilOrUndef(e["button"]) and int(jsNum(e["button"])) != 0: return
    discard e.preventDefault()
    d.regionAction(regionIndex, proc(r: var UnchangedRegion) = r.showAll()))
  discard others.appendChild(label)
  discard center.appendChild(first)
  discard center.appendChild(others)
  let bottom = createEl("div")
  bottom.setAttr("class", "bottom")
  bottom.setAttr("title", "Click or drag to show more below")
  bottom.setAttr("role", "button")
  top.addListener("mousedown", proc(e: JsObject) =
    d.dragHandle(regionIndex, true, top, e))
  bottom.addListener("mousedown", proc(e: JsObject) =
    d.dragHandle(regionIndex, false, bottom, e))
  discard lines.appendChild(top)
  discard lines.appendChild(center)
  discard lines.appendChild(bottom)
  (root, top, bottom, label)

proc updateBand(d: SharedDiffEditor; b: Band) =
  let r = d.regions[b.region]
  b.label.textContent = cstring($r.hiddenCount & " hidden lines")
  let all = r.controlsHidden
  b.bottom.toggleClass("canMoveTop", not all)
  b.bottom.toggleClass("canMoveBottom", r.visibleBottom > 0)
  b.top.toggleClass("canMoveTop", r.visibleTop > 0)
  b.top.toggleClass("canMoveBottom", not all)

proc newBand(d: SharedDiffEditor; i, afterLine: int): Band =
  ## Monaco's `ViewZoneOverlayWidget`: the zone holds the band's room in the
  ## text, and the band itself is drawn over the whole editor, gutter
  ## included, at the zone's place. A proc of its own so each band's
  ## closures see their own element.
  let (node, top, bottom, label) = d.bandNode(i)
  node.setAttr("data-ct-target", "overlay-widget")
  node.setStyle("position", "absolute")
  node.setStyle("left", "0")
  node.setStyle("width", "100%")
  node.setStyle("height", cstring($BandHeightPx & "px"))
  discard d.modified.root.appendChild(node)
  let holder = createEl("div")
  holder.setAttr("class", "ct-diff-band-zone")
  let spec = jsNew()
  spec["afterLineNumber"] = afterLine
  spec["heightInPx"] = BandHeightPx
  spec["ctOrder"] = BandZoneOrder
  spec["domNode"] = holder
  spec["onDomNodeTop"] = proc(t: int) =
    if t < -100_000: node.setStyle("display", "none")
    else:
      node.setStyle("display", "block")
      node.setStyle("top", cstring($t & "px"))
  (i, d.modified.addZone(spec), node, top, bottom, label, spec)

proc applyRegions(d: SharedDiffEditor) =
  ## The editors' hidden areas, the bands and the old revision's spacers,
  ## for the regions as they stand. A band that stays keeps its element (and
  ## so the keyboard focus a reader left on its handle).
  var modHidden, origHidden: seq[LineSpan] = @[]
  let live = liveRegions(d.regions)
  for i in live:
    modHidden.add d.regions[i].hiddenModifiedSpan
    origHidden.add d.regions[i].hiddenOriginalSpan
  d.modified.hiddenAreas = mergeSpans(modHidden, [])
  d.original.hiddenAreas = mergeSpans(origHidden, [])
  d.aligning = true
  var kept: seq[Band] = @[]
  for b in d.bands:
    if b.region in live: kept.add b
    else:
      d.modified.removeZone(b.zoneId)
      b.node.removeEl()
  d.bands = @[]
  for i in live:
    var found = -1
    for k, b in kept:
      if b.region == i: found = k
    let afterLine = d.regions[i].bandAfterLine(true)
    if found >= 0:
      # The band moves with the region's upper end; its element stays.
      let b = kept[found]
      b.spec["afterLineNumber"] = afterLine
      d.modified.layoutZone(b.zoneId)
      d.bands.add b
    else:
      d.bands.add d.newBand(i, afterLine)
  for b in d.bands: d.updateBand(b)
  d.aligning = false
  d.alignOriginal()
  d.modified.requestRender()
  d.original.requestRender()

proc regionFacade(d: SharedDiffEditor; index: int): JsObject =
  ## One region as Monaco's `UnchangedRegion`. A proc of its own, not a loop
  ## body: Nim's closures built in one loop share its variables, and every
  ## region would act as the last one (`ui/diff_expansion` says the same).
  let r = d.regions[index]
  result = jsNew()
  result["originalLineNumber"] = r.originalLine
  result["modifiedLineNumber"] = r.modifiedLine
  result["lineCount"] = r.lineCount
  let top = jsNew()
  top["get"] = proc(): int =
    if index < d.regions.len: d.regions[index].visibleTop else: 0
  let bottom = jsNew()
  bottom["get"] = proc(): int =
    if index < d.regions.len: d.regions[index].visibleBottom else: 0
  result["visibleLineCountTop"] = top
  result["visibleLineCountBottom"] = bottom
  result["showMoreAbove"] = proc(n: JsObject) =
    let count = if isNilOrUndef(n): 10 else: int(jsNum(n))
    d.regionAction(index, proc(rr: var UnchangedRegion) = rr.showMoreAbove(count))
  result["showMoreBelow"] = proc(n: JsObject) =
    let count = if isNilOrUndef(n): 10 else: int(jsNum(n))
    d.keepBoundaryAt(index, proc(rr: var UnchangedRegion) = rr.showMoreBelow(count))
  result["showAll"] = proc() =
    d.regionAction(index, proc(rr: var UnchangedRegion) = rr.showAll())

proc regionFacades(d: SharedDiffEditor): JsObject =
  ## Monaco's `unchangedRegions.get()`: the regions that still have a band,
  ## in line order.
  result = jsArray()
  for i in liveRegions(d.regions): result.jsPush(d.regionFacade(i))

# ---------------------------------------------------------------------------
# The diff
# ---------------------------------------------------------------------------

proc redrawDiff(d: SharedDiffEditor; force = true) =
  ## The removed lines as zones in the new revision, the added ones marked,
  ## the word-level marks, and the collapsed regions.
  let oldLines = splitLinesKeep(d.original.text)
  let newLines = splitLinesKeep(d.modified.text)
  if not force and oldLines == d.oldLines and newLines == d.newLines: return
  d.oldLines = oldLines
  d.newLines = newLines
  d.hunks = lineDiff(d.oldLines, d.newLines)
  d.aligning = true
  for id in d.deletedZoneIds: d.modified.removeZone(id)
  d.deletedZoneIds = @[]
  var modReqs, origReqs: seq[DecoRequest] = @[]
  proc wholeLine(ed: SharedEditor; line0: int; cls, margin: string): DecoRequest =
    let a = ed.lineStartOffset(line0)
    DecoRequest(fromOffset: a, toOffset: a,
                options: DecoOptions(className: cls, isWholeLine: true,
                                     marginClassName: margin))
  proc inline(ed: SharedEditor; s: CharSpan; cls: string): DecoRequest =
    let a = ed.lineStartOffset(s.line)
    DecoRequest(fromOffset: a + s.fromCol, toOffset: a + s.toCol,
                options: DecoOptions(inlineClassName: cls))
  for h in d.hunks:
    let inner = innerChanges(d.oldLines, d.newLines, h)
    let whole = wholeLineMarks(h)
    if h.oldTo > h.oldFrom:
      let zone = createEl("div")
      zone.setAttr("class", "view-lines line-delete monaco-mouse-cursor-text ct-diff-deleted")
      zone.setStyle("font-family", d.modified.root.style.fontFamily.to(cstring))
      for k in h.oldFrom ..< h.oldTo:
        var marks: seq[tuple[fromCol, toCol: int; cls: string]] = @[]
        for s in inner.deleted:
          if s.line == k: marks.add (s.fromCol, s.toCol, "char-delete")
        if k in whole.deletedLines and d.oldLines[k].len > 0:
          marks.add (0, d.oldLines[k].len, "char-delete")
        let row = createEl("div")
        row.setAttr("class", "view-line")
        row.setStyle("position", "relative")
        row.setStyle("height", cstring($d.modified.lineHeight & "px"))
        row.setStyle("line-height", cstring($d.modified.lineHeight & "px"))
        discard row.appendChild(d.original.lineContentElement(k + 1, marks))
        discard zone.appendChild(row)
        origReqs.add wholeLine(d.original, k, "line-delete", "gutter-delete")
        if k in whole.deletedLines:
          origReqs.add wholeLine(d.original, k, "char-delete", "")
      let spec = jsNew()
      spec["afterLineNumber"] = h.newFrom
      spec["heightInLines"] = h.oldTo - h.oldFrom
      spec["ctOrder"] = DeletedZoneOrder
      spec["domNode"] = zone
      d.deletedZoneIds.add d.modified.addZone(spec)
    for k in h.newFrom ..< h.newTo:
      modReqs.add wholeLine(d.modified, k, "line-insert", "gutter-insert")
      if k in whole.insertedLines:
        modReqs.add wholeLine(d.modified, k, "char-insert", "")
    for s in inner.inserted: modReqs.add inline(d.modified, s, "char-insert")
    for s in inner.deleted: origReqs.add inline(d.original, s, "char-delete")
  # Keep what a reader opened of a region the new diff still has.
  let previous = d.regions
  d.regions = @[]
  if d.hideUnchanged:
    d.regions = unchangedRegions(d.hunks, d.oldLines.len, d.newLines.len,
                                 d.minimumLineCount, d.contextLineCount)
    for r in d.regions.mitems:
      for p in previous:
        if p.modifiedLine == r.modifiedLine and p.lineCount == r.lineCount:
          r.visibleTop = p.visibleTop
          r.visibleBottom = p.visibleBottom
  for r in d.regions:
    for k in 0 ..< r.lineCount:
      modReqs.add wholeLine(d.modified, r.modifiedLine - 1 + k, "diff-unchanged-lines", "")
      origReqs.add wholeLine(d.original, r.originalLine - 1 + k, "diff-unchanged-lines", "")
  d.modifiedDecos = d.modified.deltaDecorationOffsets(d.modifiedDecos, modReqs)
  d.originalDecos = d.original.deltaDecorationOffsets(d.originalDecos, origReqs)
  d.aligning = false
  d.applyRegions()
  for l in d.diffListeners: discard callFn(l, jsNew())

proc revealHiddenLine(d: SharedDiffEditor; line1: int): bool =
  ## A caret moved onto a hidden line (a find match) shows it.
  for i in 0 ..< d.regions.len:
    if d.regions[i].controlsHidden: continue
    var r = d.regions[i]
    if r.revealModifiedLine(line1):
      d.regions[i] = r
      d.applyRegions()
      return true
  false

proc layoutStrip(d: SharedDiffEditor) =
  ## The old revision is as wide as its gutter; the new one starts there.
  let w = max(1, d.original.gutterPx)
  if w == d.stripWidth: return
  d.stripWidth = w
  d.oldHost.setStyle("width", cstring($w & "px"))
  d.newHost.setStyle("left", cstring($w & "px"))

proc followModel(model: JsObject; ed: SharedEditor) =
  ## `ed` takes the model's text whenever the model's `setValue` changes it.
  if not isNilOrUndef(model) and not isNilOrUndef(model["onDidChangeContent"]):
    discard model.onDidChangeContent(proc(ev: JsObject) =
      ed.replaceAll(modelText(model)))

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
    # The models' later `setValue` reaches the editors (and the editors'
    # content changes the diff, below).
    followModel(d.originalModel, d.original)
    followModel(d.modifiedModel, d.modified)
    d.redrawDiff()
  f["getModel"] = proc(): JsObject =
    result = jsNew()
    result["original"] = d.originalModel
    result["modified"] = d.modifiedModel
  f["getModifiedEditor"] = proc(): JsObject = facadeOf(d.modified)
  f["getOriginalEditor"] = proc(): JsObject = facadeOf(d.original)
  f["updateOptions"] = proc(o: JsObject) =
    if isNilOrUndef(o): return
    if not isNilOrUndef(o["hideUnchangedRegions"]):
      d.readRegionOptions(o)
      d.redrawDiff()
    # The code editors' options given to the diff editor reach both of them.
    let mine = shallowCopy(o)
    {.emit: ["delete ", mine, ".hideUnchangedRegions;"].}
    discard facadeOf(d.modified).updateOptions(mine)
    discard facadeOf(d.original).updateOptions(shallowCopy(mine))
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
    let cbRef = cb
    result["dispose"] = proc() =
      var kept: seq[JsObject] = @[]
      for l in d.diffListeners:
        if l != cbRef: kept.add l
      d.diffListeners = kept
  f["getLineChanges"] = proc(): JsObject =
    result = jsArray()
    for h in d.hunks:
      let c = jsNew()
      c["originalStartLineNumber"] = h.oldFrom + 1
      c["originalEndLineNumber"] = (if h.oldTo > h.oldFrom: h.oldTo else: 0)
      c["modifiedStartLineNumber"] = h.newFrom + 1
      c["modifiedEndLineNumber"] = (if h.newTo > h.newFrom: h.newTo else: 0)
      result.jsPush(c)
  # Monaco's view model, as `ui/diff_expansion` reads it.
  let model = jsNew()
  let regionsObs = jsNew()
  regionsObs["get"] = proc(): JsObject = d.regionFacades()
  model["unchangedRegions"] = regionsObs
  let modelObs = jsNew()
  modelObs["get"] = proc(): JsObject = model
  f["_diffModel"] = modelObs
  f

proc newSharedDiffEditor*(host: JsObject; options: JsObject; fontSize: int;
                          fontFamily: string; darkTheme: bool;
                          language = ""): JsObject =
  ## The diff editor in `host`: Monaco's `createDiffEditor(host, options)`
  ## on the shared editor, in the inline layout.
  installMonacoGlobals()
  let d = SharedDiffEditor(host: host, contextLineCount: 3, minimumLineCount: 3,
                           revealLineCount: 20)
  let opts = if isNilOrUndef(options): jsNew() else: options
  d.readRegionOptions(opts)
  let c = createEl("div")
  c.setAttr("class", "monaco-diff-editor ct-shared-diff-editor")
  c.setStyle("position", "relative")
  c.setStyle("width", "100%")
  c.setStyle("height", "100%")
  c.setStyle("overflow", "hidden")
  # The theme's diff colours (the change washes, the collapsed region's
  # band) as the CSS variables Monaco's theme service writes for its own
  # editors — which it does only once one of them exists, never in a window
  # drawing only shared editors.
  let themeOpt = opts["theme"]
  let lightTheme = not isNilOrUndef(themeOpt) and
    ($jsStr(themeOpt)).toLowerAscii.contains("white")
  c.setAttr("style", cstring($jsStr(c.getAttribute("style")) & ";" &
    (if lightTheme: CodeTracerWhiteDiffVariables else: CodeTracerDarkDiffVariables)))
  discard host.appendChild(c)
  d.container = c
  # The old revision: its gutter, as a strip beside the new revision.
  let oldHost = createEl("div")
  oldHost.setAttr("class", "editor original ct-diff-original-host")
  oldHost.setStyle("position", "absolute")
  oldHost.setStyle("left", "0")
  oldHost.setStyle("top", "0")
  oldHost.setStyle("width", "40px")
  oldHost.setStyle("height", "100%")
  oldHost.setStyle("overflow", "hidden")
  discard c.appendChild(oldHost)
  let newHost = createEl("div")
  newHost.setAttr("class", "editor modified ct-diff-modified-host")
  newHost.setStyle("position", "absolute")
  newHost.setStyle("left", "40px")
  newHost.setStyle("top", "0")
  newHost.setStyle("right", "0")
  newHost.setStyle("height", "100%")
  discard c.appendChild(newHost)
  d.oldHost = oldHost
  d.newHost = newHost
  d.stripWidth = 40
  # Each editor its own copy of the options: `updateOptions` on one side
  # (its gutter's labels and lanes) must not reach the other.
  let editorOpts = shallowCopy(opts)
  {.emit: ["delete ", editorOpts, ".hideUnchangedRegions;"].}
  d.original = newSharedEditor(oldHost, "", "", language, true, fontSize,
                               fontFamily, darkTheme, shallowCopy(editorOpts))
  d.modified = newSharedEditor(newHost, "", "", language, true, fontSize,
                               fontFamily, darkTheme, shallowCopy(editorOpts))
  d.original.monacoGutter = true
  d.modified.monacoGutter = true
  discard d.original.root.classList.add(cstring"original-in-monaco-diff-editor")
  discard d.modified.root.classList.add(cstring"modified-in-monaco-diff-editor")
  # The strip shows numbers only: no scrollbar of its own, and the wheel over
  # it scrolls the diff.
  let stripCss = createEl("style")
  stripCss.textContent = cstring(DiffEditorCss)
  discard c.appendChild(stripCss)
  oldHost.addListener("wheel", proc(ev: JsObject) =
    discard ev.preventDefault()
    d.modified.setScroll(d.modified.scrollTop + int(jsNum(ev["deltaY"])),
                         d.modified.scrollLeft))
  # Monaco's diff editor carries a minimap element; the view's checks name it.
  let mini = createEl("div")
  mini.setAttr("class", "minimap")
  mini.setStyle("display", "none")
  discard d.modified.root.appendChild(mini)
  # One scroll position: the old revision follows the new one every frame.
  discard d.modified.on("render", toJs(proc(ev: JsObject) =
    if d.original.scrollTop != d.modified.scrollTop:
      d.original.setScroll(d.modified.scrollTop, 0)
      d.original.requestRender()))
  discard d.original.on("render", toJs(proc(ev: JsObject) = d.layoutStrip()))
  d.modified.onZonesChanged = proc() =
    if not d.aligning: d.alignOriginal()
  d.modified.onHiddenLine = proc(line1: int): bool = d.revealHiddenLine(line1)
  # A side's text set through its own model (`ui/unified_diff` re-publishes
  # both documents that way) is diffed again, once per turn.
  for ed in [d.original, d.modified]:
    discard ed.on("content", toJs(proc(ev: JsObject) =
      if d.redrawQueued: return
      d.redrawQueued = true
      queueTask(proc() =
        d.redrawQueued = false
        d.redrawDiff(force = false))))
  d.original.observeSize()
  d.modified.observeSize()
  d.diffFacade()

proc sharedDiffEditorOf*(facade: JsObject): bool =
  ## Whether `facade` is a diff editor made here.
  not isNilOrUndef(facade) and not isNilOrUndef(facade["__ctShared"])
