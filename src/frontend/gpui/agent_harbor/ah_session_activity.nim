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
## Following: the view draws from the end while the viewmodel follows, and
## from the anchor line otherwise (`anchor`), so arriving lines never move
## what the reader reads. The line heights it lays out by are the drawn
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
## Facts (`data-ah-*`): `surface`, `state`, `status`, `connection`, and each
## line's `lineFacts`; `running-strip`, `unseen`, `filter`, `badge`,
## `copy-action` and `path-shown`.

import std/strutils
import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm
import ../../viewmodel/views/agent_harbor_activity_words
import ../../viewmodel/input/element_press
import ../chrome
import ./ah_theme

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

proc sizeOf(line: TimelineLine): int =
  if line.kind in {tlkDetail, tlkTraceLine}: CaptionPx else: BodyPx

proc lineHeightOf(line: TimelineLine): int =
  if line.kind in {tlkDetail, tlkTraceLine}: DetailLinePx else: LinePx

proc wrappedRows*(text: string; sizePx, availPx: int): int =
  ## How many lines `text` wraps to at `availPx`: word by word at the
  ## face's kerned widths, each of its own lines apart.
  for para in text.splitLines:
    var rows = 1
    var used = 0.0
    for word in para.splitWhitespace:
      let w = textWidth(word, sizePx)
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
  for i, line in lines:
    if line.id == anchor: return i
  0

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
    let action = r.text(CopyLabel, CaptionPx, p.textCaption, shrink = false,
                        pairs = [("cursor", "pointer"), ("margin-left", $InsetPx & "px")])
    r.tag(action, "copy-action", CopyLabel)
    r.carries(action, ActivityCopyOperation, line.copyText, press)
    r.appendChild(result, action)
  if line.expandable:
    # A press on the line opens or closes it (`session-activity.toggle`).
    r.setStyle(result, "cursor", "pointer")
    r.carries(result, ActivityToggleOperation, line.id, press)

proc drawSessionActivity*(r: GpuiRenderer; host: GpuiElement; vm: SessionTimelineVM;
                          p: AhPalette; widthPx, heightPx: int;
                          press: ActivityPress = nil) =
  ## The timeline in `host`, `widthPx` × `heightPx`, on the panel's ground;
  ## a press is reported to `press`.
  r.clearChildren(host)
  r.styles(host, [("display", "flex"), ("flex-direction", "column"),
                  ("width", $widthPx & "px"), ("height", $heightPx & "px"),
                  ("background", p.panel), ("overflow", "hidden")])
  r.tag(host, "surface", "agent-harbor-session-activity")
  r.tag(host, "state", stateName(vm.state.val))
  r.tag(host, "status", vm.statusLabel)
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
  let lines = vm.lines
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
  let list = r.box(column = true, pairs = [("flex-grow", "1"), ("min-height", "0px"),
                                           ("overflow", "hidden")])
  r.tag(list, "lines", $lines.len)
  for i in first ..< lines.len:
    r.appendChild(list, r.drawLine(p, vm, lines[i], widthPx, i == first, press))
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

proc mountSessionActivity*(r: GpuiRenderer; host: GpuiElement; vm: SessionTimelineVM;
                           p: AhPalette; widthPx, heightPx: int;
                           press: ActivityPress = nil) =
  ## Draws the timeline, and again whenever what it shows moves.
  createRenderEffect proc() =
    drawSessionActivity(r, host, vm, p, widthPx, heightPx, press)
