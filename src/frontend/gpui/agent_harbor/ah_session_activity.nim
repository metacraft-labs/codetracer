## gpui/agent_harbor/ah_session_activity.nim — CTF-P2b. The GPUI session
## activity timeline: the cardless timeline of one Agent Harbor session over
## `SessionTimelineVM` (nim-agents-isonim-viewmodels), drawn as the web's
## `isonim_agent_harbor_session_activity_view` draws it, from the same
## lines, in the same places (the layout judge holds GPUI to the web's
## records once the stories mount it).
##
## Cardless: one column of lines on the panel's ground, no border, box or
## background around an event. Indentation (16px a level), a leading glyph
## (`▸` / `▾` on a line that opens, `›` before an operator's message, `●`
## before a running command) and the ink and weight of each part's role
## (`timelineInk`) tell lines apart. The focused line carries an inset bar
## in the action colour down its left edge (`insetBar`), never a fill. Each
## turn after the first starts 8px below the line before it.
##
## Prose (the operator's and the agent's words, a question, a failure, a
## detail, a trace) wraps; every other line is one line, cut by isonim-gpui's
## text element through the views' one rule (`ah_theme.text`, handed
## `CutSeparators`), and a file path is cut in its middle
## (`ah_theme.pathText`: `src/…/client.py`).
##
## Chrome: the head (the session's status and, when the host set one, the
## connection badge); a filter row while a filter is set; the
## `Running: <command>` strip on the raised ground while the running line is
## out of view; the `N new · Jump to latest` chip at the bottom edge while
## the reader does not follow and items arrived.
##
## Following: the view draws from the end while the viewmodel follows, the
## last line's foot on the list's foot (as the browser scrolls a list to its
## end), and from the anchor line otherwise (`anchor`; or earlier, when the
## lines after it leave the list room), so arriving lines never move what
## the reader reads. The line heights it lays out by are the drawn
## ones: 20px a body line, 16px a caption line, and a prose line's wrapped
## lines at the text's measured widths.
##
## Presses are routed (Input-Routing-And-Keymaps.md §5.1), as on the web:
## each element a press acts on carries its operation (`data-ct-operation`,
## `agent_harbor_activity_words`) and its target (`data-ah-target`), and its
## press-down listener only reports both to the host's `ActivityPress` (the
## hit test; GPUI's shim delivers a press to the element under the pointer),
## which resolves it through its router and runs it (`runActivityPress`).
## Nothing here decides what a press does. With no `press`, nothing listens.
##
## A tail (`ActivityTail`, built by `ah_suggested_actions.suggestionTail`)
## adds what a suggested-actions block brings: while it waits, the block
## beneath the list, pinned, so it never scrolls out of view; once decided,
## its record lines after the timeline's lines, drawn as the timeline's own
## (P2c study D23, D55). The timeline's own lines are not changed by it.
##
## Facts (`data-ah-*`): `surface`, `state`, `session-status`, `connection`, and each
## line's `lineFacts`; `running-strip`, `unseen`, `filter`, `badge`,
## `copy-action` and `path-shown`; on each drawn part of a line, its role
## (`part`) and the colour it is drawn in (`ink`).

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm
import ../../viewmodel/views/agent_harbor_activity_words
import ../../viewmodel/input/element_press
import ../chrome
import ./ah_theme
import ../../../common/pointer_shape

export session_timeline_vm, agent_harbor_activity_words, ah_theme

const
  IndentPx* = 16              ## one drill-down level
  GlyphPx* = 16               ## a leading glyph's column
  LinePx* = 20                ## a body line (14px on 20px)
  DetailLinePx* = 16          ## a detail's or a trace's line (12px on 16px)
  TurnGapPx* = 8              ## above each turn after the first
  HeadPx* = 32                ## the head band
  StripPx* = 24               ## the running strip, the filter row, the chip
  FocusBarPx* = 2             ## the inset bar of the focused line
  RunningGlyph* = "\xE2\x97\x8F"  ## ●

type
  ActivityTail* = object
    ## What a host adds at the timeline's end (a suggested-actions block):
    ## lines after the timeline's own, and a block pinned beneath the list.
    lines*: seq[TimelineLine]
    blockPx*: int                    ## the block's height; 0: no block
    drawBlock*: proc(): GpuiElement  ## the block, `blockPx` tall
    surface*: string
      ## What the timeline's view says it is (`data-ah-surface`); "": the
      ## session activity timeline.
  ActivityTailOf* = proc(widthPx: int): ActivityTail
    ## The tail at a width, read while the timeline draws (so a viewmodel it
    ## reads is tracked by the draw).

const CaptionLines = {tlkDetail, tlkTrace, tlkTraceLine}
  ## The lines set as captions (`.ah-activity-detail`, `-trace`,
  ## `-trace-line`): a detail, a trace's line and its lines.

proc sizeOf(line: TimelineLine): int =
  if line.kind in CaptionLines: CaptionPx else: BodyPx

proc lineHeightOf(line: TimelineLine): int =
  if line.kind in CaptionLines: DetailLinePx else: LinePx

proc wrappedRows*(text: string; sizePx, availPx: int; faceGlyphs = false): int =
  ## How many lines `text` wraps to at `availPx`: word by word at the
  ## face's kerned widths, each of its own lines apart. `faceGlyphs`: the
  ## non-ASCII glyphs the face carries at their own advances (`textWidth`).
  for para in text.splitLines:
    var rows = 1
    var used = 0.0
    for word in para.splitWhitespace:
      let w = textWidth(word, sizePx, faceGlyphs = faceGlyphs)
      let space = if used > 0: textWidth(" ", sizePx) else: 0.0
      if used > 0 and used + space + w > float(availPx):
        inc rows
        used = w
      else:
        used += space + w
    result += rows
  result = max(1, result)

proc textStart(line: TimelineLine): int =
  InsetPx + line.indent * IndentPx + GlyphPx

proc heightOf*(line: TimelineLine; widthPx: int; first: bool): int =
  ## The pixels a line takes at `widthPx`.
  result = if line.kind == tlkTurn and not first: TurnGapPx else: 0
  if line.isProse:
    let copy = if line.copyText.len > 0: textPx(CopyLabel, CaptionPx) + InsetPx else: 0
    let avail = max(1, widthPx - textStart(line) - InsetPx - copy)
    result += lineHeightOf(line) * wrappedRows(line.text, sizeOf(line), avail)
  else:
    result += lineHeightOf(line)

proc firstShown*(lines: openArray[TimelineLine]; vm: SessionTimelineVM;
                 widthPx, heightPx: int): int =
  ## The first line drawn: the end's while following, else the anchor's.
  if lines.len == 0: return 0
  if vm.follow.val:
    var used = 0
    var i = lines.high
    while i >= 0:
      let h = heightOf(lines[i], widthPx, i == 0)
      if used + h > heightPx: break
      used += h
      dec i
    return i + 1
  let anchor = vm.anchor
  var at = 0
  for i, line in lines:
    if line.id == anchor: at = i
  # A list cannot scroll past its end (as the browser's cannot): when the
  # lines from the anchor on leave room below them, earlier lines fill it.
  var used = 0
  for i in at ..< lines.len: used += heightOf(lines[i], widthPx, i == at)
  while at > 0:
    let h = heightOf(lines[at - 1], widthPx, true)
    if used + h > heightPx: break
    used += h
    dec at
  at

proc tagged(el: GpuiElement; fact: string; into: var seq[GpuiElement]) =
  ## Every element under `el` (itself included) carrying `data-ah-<fact>`.
  if getAttribute(el, "data-ah-" & fact).len > 0: into.add el
  for i in 0 ..< childCount(el): tagged(nthChild(el, i), fact, into)

proc carries(r: GpuiRenderer; el: GpuiElement; operation, target: string;
             press: ActivityPress) =
  ## `el` carries `operation` on `target`; a press on it is reported to
  ## `press`, which routes it.
  r.setAttribute(el, OperationAttribute, operation)
  r.setAttribute(el, PressTargetAttribute, target)
  if press != nil:
    r.addEventListener(el, "mousedown", proc(ev: GpuiEvent) =  # ir1-gate: hit test
      press(operation, target))

proc partEl(r: GpuiRenderer; p: AhPalette; part: LinePart; sizePx: int;
            shrink: bool): GpuiElement =
  result = r.text(part.text, sizePx, timelineInk(p, part.role),
                  bold = part.role == "label", shrink = shrink)
  if part.role.isMono: r.setStyle(result, "font-family", MonoFontFamily)
  r.tag(result, "part", part.role)
  r.tag(result, "ink", timelineInk(p, part.role))

proc drawLine(r: GpuiRenderer; p: AhPalette; vm: SessionTimelineVM;
              line: TimelineLine; widthPx: int; first: bool;
              press: ActivityPress): GpuiElement =
  let size = sizeOf(line)
  let lh = lineHeightOf(line)
  result = r.box(pairs = [("position", "relative"), ("flex-shrink", "0"),
                          ("padding-left", $(InsetPx + line.indent * IndentPx) & "px"),
                          ("padding-right", $InsetPx & "px"),
                          ("items", "flex-start"),
                          ("min-height", $lh & "px")])
  if line.kind == tlkTurn and not first:
    r.setStyle(result, "margin-top", $TurnGapPx & "px")
  for (k, v) in line.lineFacts: r.tag(result, k, v)
  if line.focused:
    r.appendChild(result, r.insetBar(p.action, FocusBarPx))
  # The leading glyph.
  let glyph = if line.glyph.len > 0: line.glyph
              elif line.kind == tlkTurn: turnGlyph()
              else: ""
  let glyphEl = r.box(pairs = [("width", $GlyphPx & "px"), ("min-width", $GlyphPx & "px"),
                               ("height", $lh & "px"), ("items", "center"),
                               ("flex-shrink", "0")])
  if glyph.len > 0:
    r.appendChild(glyphEl, r.text(glyph, size,
      if line.kind == tlkTurn and line.glyph.len == 0: p.action else: p.textCaption,
      shrink = false))
  r.appendChild(result, glyphEl)
  let body = r.box(pairs = [("flex-grow", "1"), ("min-width", "0px"), ("gap", "6px"),
                            ("items", "center"), ("line-height", $lh & "px")])
  if line.isProse:
    let ink = timelineInk(p, line.textRole)
    let prose = r.text(line.text, size, ink, bold = line.textRole == "label",
                       shrink = false,
                       pairs = [("white-space", "pre-wrap"), ("line-height", $lh & "px"),
                                ("flex-shrink", "1"), ("min-width", "0px")])
    if line.textRole.isMono or line.kind in {tlkDetail, tlkTraceLine} and
        line.parts.len > 0 and line.parts[0].role.isMono:
      r.setStyle(prose, "font-family", MonoFontFamily)
    r.tag(prose, "part", line.textRole)
    r.tag(prose, "ink", ink)
    r.appendChild(body, prose)
  else:
    let first = line.parts[0]
    if line.path.len > 0:
      let words = r.partEl(p, LinePart(text: line.pathWords.strip(leading = false),
                                       role: first.role), size, shrink = false)
      r.appendChild(body, words)
      let path = r.pathText(line.path, size, timelineInk(p, first.role),
                            bold = first.role == "label")
      r.tag(path, "path-shown", line.path)
      r.tag(path, "part", first.role)
      r.tag(path, "ink", timelineInk(p, first.role))
      r.appendChild(body, path)
    else:
      r.appendChild(body, r.partEl(p, first, size, shrink = true))
    for part in line.partsAfterFirst:
      if part.role == "running":
        r.appendChild(body, r.text(RunningGlyph, size, timelineInk(p, "running"),
                                   shrink = false))
        r.appendChild(body, r.partEl(p, part, size, shrink = true))
      else:
        r.appendChild(body, r.partEl(p, part, size, shrink = false))
  r.appendChild(result, body)
  if line.copyText.len > 0:
    # On the line's own pitch, as the web's Copy takes its line's height.
    let action = r.text(CopyLabel, CaptionPx, p.textCaption, shrink = false,
                        pairs = [("cursor", pointerShapeOf(HitTarget(kind: hkControl)).cssName),
                                 ("margin-left", $InsetPx & "px"),
                                 ("line-height", $lh & "px")])
    r.tag(action, "copy-action", CopyLabel)
    r.carries(action, ActivityCopyOperation, line.copyText, press)
    r.appendChild(result, action)
  if line.expandable:
    # A press on the line opens or closes it (`session-activity.toggle`).
    r.setStyle(result, "cursor", pointerShapeOf(HitTarget(kind: hkExpander)).cssName)
    r.carries(result, ActivityToggleOperation, line.id, press)

proc drawSessionActivity*(r: GpuiRenderer; host: GpuiElement; vm: SessionTimelineVM;
                          p: AhPalette; widthPx, heightPx: int;
                          press: ActivityPress = nil; tailOf: ActivityTailOf = nil) =
  ## The timeline in `host`, `widthPx` × `heightPx`, on the panel's ground,
  ## with what `tailOf` adds at its end, if anything; a press is reported to
  ## `press`.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", $heightPx & "px"),
                  ("background", p.panel), ("overflow", "hidden")])
  let tail = if tailOf.isNil: ActivityTail() else: tailOf(widthPx)
  r.tag(host, "surface", if tail.surface.len > 0: tail.surface
                         else: "agent-harbor-session-activity")
  r.tag(host, "state", stateName(vm.state.val))
  r.tag(host, "session-status", vm.statusLabel)
  r.tag(host, "connection", vm.connection.val)
  # The head: the status, and the connection badge on the right.
  let head = r.box(pairs = [("height", $HeadPx & "px"), ("items", "center"),
                            ("padding-left", $InsetPx & "px"),
                            ("padding-right", $InsetPx & "px"), ("gap", "8px"),
                            ("flex-shrink", "0")])
  r.tag(head, "head", "status")
  let status = r.text(vm.statusLabel, CaptionPx, p.textCaption,
                      pairs = [("flex-grow", "1"), ("min-width", "0px")])
  r.tag(status, "status-label", vm.statusLabel)
  r.appendChild(head, status)
  let badge = vm.connection.val
  if badge.len > 0:
    let b = r.box(pairs = [("height", "20px"), ("items", "center"),
                           ("padding-left", "6px"), ("padding-right", "6px"),
                           ("rounded", "4px"), ("border-width", "1px"),
                           ("border-color", p.borderPrimary), ("flex-shrink", "0")])
    r.appendChild(b, r.text(badge, CaptionPx, p.textLabel, shrink = false))
    r.tag(b, "badge", badge)
    r.appendChild(head, b)
  r.appendChild(host, head)
  var bodyH = heightPx - HeadPx
  if vm.filter.val.len > 0:
    let row = r.box(pairs = [("height", $StripPx & "px"), ("items", "center"),
                             ("padding-left", $InsetPx & "px"), ("gap", "8px"),
                             ("flex-shrink", "0")])
    r.tag(row, "filter", vm.filter.val)
    # The region declaration names the row by this fact (`filter` alone is
    # the fleet's filter buttons' too).
    r.tag(row, "activity-filter", vm.filter.val)
    r.appendChild(row, r.text("Filter: " & vm.filter.val, CaptionPx, p.textLabel))
    r.appendChild(row, r.text(vm.filterCountText, CaptionPx, p.textCaption, shrink = false))
    r.appendChild(host, row)
    bodyH -= StripPx
  case vm.state.val
  of asIdle, asLoading:
    r.appendChild(host, r.notice(p, LoadingNotice, "loading"))
    return
  of asError:
    if vm.unresolvable.val.len > 0:
      r.appendChild(host, r.notice(p, vm.notice, "unresolvable"))
    else:
      let retry = r.errorBlock(p, ErrorTitle, vm.error.val, nil)
      var buttons: seq[GpuiElement]
      tagged(retry, "button", buttons)
      for b in buttons:
        r.carries(b, ActivityRetryOperation, "", press)
      r.appendChild(host, retry)
    return
  of asReady:
    discard
  if vm.isEmpty:
    r.appendChild(host, r.notice(p, EmptyNotice, "empty"))
    return
  var lines = vm.lines
  lines.add tail.lines
  # The block takes the panel's foot (leaving the list three lines at
  # least), beneath the list and the chip.
  let blockPx = if tail.blockPx > 0 and tail.drawBlock != nil:
                  min(tail.blockPx, max(0, bodyH - 3 * LinePx))
                else: 0
  bodyH -= blockPx
  let chip = vm.showsUnseenChip
  let listH = bodyH - (if chip: StripPx else: 0)
  let first = firstShown(lines, vm, widthPx, listH)
  var drawnIds: seq[string]
  var used = 0
  for i in first ..< lines.len:
    if used >= listH: break
    drawnIds.add lines[i].id
    used += heightOf(lines[i], widthPx, i == first)
  let runningId = runningLineId(lines, vm.runningLine)
  let strip = runningStripText(vm)
  if strip.len > 0 and runningId notin drawnIds:
    # The one ground step a cardless view allows: the raised ground.
    let s = r.box(pairs = [("height", $StripPx & "px"), ("items", "center"),
                           ("padding-left", $InsetPx & "px"),
                           ("padding-right", $InsetPx & "px"), ("gap", "6px"),
                           ("background", p.secondary), ("flex-shrink", "0")])
    r.tag(s, "running-strip", strip)
    r.appendChild(s, r.text(RunningGlyph, CaptionPx, timelineInk(p, "running"), shrink = false))
    r.appendChild(s, r.text(strip, CaptionPx, p.textBody))
    r.appendChild(host, s)
  # While following, the list is laid out as the browser scrolls it to its
  # end: the last line's foot on the list's foot, and the line above the
  # first whole one cut by the list's top edge.
  let listBoxH = listH - (if strip.len > 0 and runningId notin drawnIds: StripPx else: 0)
  var start = first
  var topMargin = 0
  var shifted = false
  if vm.follow.val:
    # From the end up, each line with the gap above it (a turn's), until the
    # lines fill the list; the line that crosses its top is drawn first,
    # pulled up by what does not fit.
    var total = 0
    var i = lines.high
    while i >= 0:
      total += heightOf(lines[i], widthPx, i == 0)
      if total >= listBoxH: break
      dec i
    if i >= 0:
      start = i
      shifted = true
      let gap = if lines[i].kind == tlkTurn and i > 0: TurnGapPx else: 0
      topMargin = gap - (total - listBoxH)
  let list = r.box(column = true, pairs = [("flex-grow", "1"), ("min-height", "0px"),
                                           ("overflow", "hidden")])
  if blockPx > 0:
    # The block follows the timeline's last line, or sits at the panel's
    # foot once the lines fill the rest (D55): the list takes only its lines.
    var content = (if shifted: topMargin else: 0)
    for i in start ..< lines.len: content += heightOf(lines[i], widthPx, i == start)
    r.styles(list, [("flex-grow", "0"), ("height", $min(content, listBoxH) & "px"),
                    ("flex-shrink", "0")])
  r.tag(list, "lines", $lines.len)
  # The region declaration names the list by this fact (`lines` is the
  # session strip's too).
  r.tag(list, "activity-lines", $lines.len)
  for i in start ..< lines.len:
    let el = r.drawLine(p, vm, lines[i], widthPx, i == start, press)
    if i == start and shifted: r.setStyle(el, "margin-top", $topMargin & "px")
    r.appendChild(list, el)
  r.appendChild(host, list)
  if chip:
    let row = r.box(pairs = [("height", $StripPx & "px"), ("justify", "center"),
                             ("items", "center"), ("flex-shrink", "0")])
    let label = unseenChipText(vm.unseen.val)
    let button = r.button(p, label, nil)
    r.tag(button, "unseen", $vm.unseen.val)
    r.carries(button, ActivityJumpOperation, "", press)
    r.appendChild(row, button)
    r.appendChild(host, row)
  if blockPx > 0:
    let blk = tail.drawBlock()
    r.styles(blk, [("height", $blockPx & "px"), ("flex-shrink", "0")])
    r.appendChild(host, blk)

proc mountSessionActivity*(r: GpuiRenderer; host: GpuiElement; vm: SessionTimelineVM;
                           p: AhPalette; widthPx, heightPx: int;
                           press: ActivityPress = nil; tailOf: ActivityTailOf = nil) =
  ## Draws the timeline, and again whenever what it or its tail shows moves.
  createRenderEffect proc() =
    drawSessionActivity(r, host, vm, p, widthPx, heightPx, press, tailOf)
