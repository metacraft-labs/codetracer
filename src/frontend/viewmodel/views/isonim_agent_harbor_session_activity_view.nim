## IsoNim view of an Agent Harbor session's activity: the cardless timeline
## of one session over `SessionTimelineVM` (nim-agents-isonim-viewmodels),
## framed as the Agent Activity panel. The GPUI
## (`gpui/agent_harbor/ah_session_activity.nim`) and terminal
## (`tui/agent_harbor/ah_tui_session_activity.nim`) views draw the same lines;
## what the three decide alike is in `agent_harbor_activity_words`.
##
## Layout, top to bottom:
##
## - the head (`.ah-activity-head`): the session's status, as a fleet row
##   says it, and, when the host set one, the connection badge;
## - while a filter is set (`list.filter`), a row with the query and how
##   many lines match;
## - the `Running: <command>` strip on the raised ground, shown only while
##   the running command's line is out of view (`data-ah-running-for` names
##   that line; a script hides the strip while the line is in view);
## - the lines (`.ah-activity-lines`), one column with no border, box or
##   background around an event: indentation, a leading glyph and the type
##   role of each part tell them apart (`agent_harbor_activity.styl`). The
##   focused line carries an inset bar, never a fill. An operator's message
##   starts a turn. Prose wraps; every other line is one line cut by the
##   views' one rule (`data-ah-cut`), and a file path in it is cut in its
##   middle (`data-ah-cut="path"`). A level-2 detail carries a Copy action;
## - the `N new · Jump to latest` chip at the bottom edge, while the reader
##   does not follow and items arrived;
## - when the host gives a suggested-actions block (`tail`,
##   `isonim_agent_harbor_suggested_actions_view`): while it waits, the block
##   beneath the list, pinned, so it never scrolls out of view; once
##   decided, its record lines after the timeline's lines, drawn as the
##   timeline's own lines (P2c study D23, D55). The timeline's own lines are
##   not changed by it.
##
## Every line carries its facts (`lineFacts`, `data-ah-*`), so the host
## tests read the same facts in every host.
##
## Presses and keys are routed (Input-Routing-And-Keymaps.md §5.1): the list
## is the `sessionActivity` scope (`data-ct-pane`), and each element a press
## acts on carries its operation (`data-ct-operation`: a line that opens
## `session-activity.toggle`, a detail's Copy `session-activity.copy`, the
## chip `session-activity.jump-to-latest`, Retry `session-activity.retry`)
## and its target (`data-ah-target`: the line's id, the text Copy copies).
## The page's one pointer listener resolves the press through the pointer
## keymap and the host runs it (`runActivityPress`); the window's keys reach
## the timeline through the host's router (`runActivityOperation`). The view
## holds no handler of its own.
##
## Scrolling (the browser): while the viewmodel follows, the list is kept at
## its end; otherwise the anchor line (`anchor`) is kept at the top, so
## arriving lines never move what the reader reads. Scrolling tells the
## viewmodel where the reader is (`readAt`) and whether it follows.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import ./ah_cut_text
from ../keymap/scope_path import SessionActivityScope
from ../input/element_press import OperationAttribute

when defined(js):
  import isonim/web/dom_api as isonim_dom

import nim_agents_isonim_viewmodels/agent_harbor/session_timeline_vm
import ./agent_harbor_activity_words
import ./isonim_agent_harbor_suggested_actions_view

export signals, computation, components, session_timeline_vm,
  agent_harbor_activity_words, isonim_agent_harbor_suggested_actions_view

static:
  # The DSL spells the attributes literally; they are the ones the page's
  # listener and the host read.
  doAssert OperationAttribute == "data-ct-operation"
  doAssert PressTargetAttribute == "data-ah-target"

const
  AgentHarborActivityClass* = "component-container agent-harbor-activity"

proc appendRendered[R, N](r: R; host, child: N) =
  mixin appendChild
  r.appendChild(host, child)

proc tagFacts[R, N](r: R; node: N; facts: openArray[(string, string)]) =
  mixin setAttribute
  for (k, v) in facts: r.setAttribute(node, "data-ah-" & k, v)

proc roleClass*(role: string): string =
  ## A part's type role: `ah-activity-role-<role>` (`agent_harbor_activity.styl`).
  "ah-activity-role-" & role

proc lineClass*(line: TimelineLine): string =
  result = "ah-activity-line ah-activity-" & $line.kind
  if line.isProse: result.add " ah-activity-prose"
  if line.focused: result.add " ah-activity-focused"
  if line.expandable: result.add " ah-activity-expandable"

proc renderPart[R](r: R; part: LinePart; cut: bool): auto =
  ## One part of a line in its role; a part of a one-line line is cut.
  if cut:
    ui(r):
      span(`data-ah-cut` = "line", class = "ah-activity-part " & roleClass(part.role),
           title = part.text):
        text part.text
  else:
    ui(r):
      span(class = "ah-activity-part " & roleClass(part.role)):
        text part.text

proc renderLine[R, N](r: R; line: TimelineLine): N =
  let id = line.id
  var glyph, body: N
  let node = ui(r):
    tdiv(class = lineClass(line)):
      span(ref = glyph, class = "ah-activity-glyph")
      tdiv(ref = body, class = "ah-activity-text")
  r.tagFacts(node, line.lineFacts)
  r.tagFacts(node, [("indent", $line.indent)])
  # The indent is the line's drill-down depth (`--ah-indent`, in levels).
  mixin setAttribute
  r.setAttribute(node, "style", "--ah-indent: " & $line.indent)
  let mark = if line.glyph.len > 0: line.glyph
             elif line.kind == tlkTurn: turnGlyph()
             else: ""
  if mark.len > 0:
    let g = ui(r):
      span(class = (if line.glyph.len > 0: "ah-activity-mark" else: "ah-activity-turn-mark")):
        text mark
    r.appendRendered(glyph, g)
  if line.isProse:
    let prose = ui(r):
      span(class = "ah-activity-part " & roleClass(line.textRole)):
        text line.text
    r.appendRendered(body, prose)
  else:
    let first = line.parts[0]
    if line.path.len > 0:
      let words = line.pathWords.strip(leading = false)
      let w = ui(r):
        span(class = "ah-activity-part ah-activity-words " & roleClass(first.role)):
          text words
      r.appendRendered(body, w)
      let p = ui(r):
        span(`data-ah-cut` = CutPathValue, class = "ah-activity-part ah-activity-path " &
               roleClass(first.role), title = line.path):
          text line.path
      r.tagFacts(p, [("path-shown", line.path)])
      r.appendRendered(body, p)
    else:
      r.appendRendered(body, renderPart(r, first, cut = true))
    for part in line.partsAfterFirst:
      if part.role == "running":
        let dot = ui(r):
          span(class = "ah-activity-running-mark"):
            text "\xE2\x97\x8F"
        r.appendRendered(body, dot)
        r.appendRendered(body, renderPart(r, part, cut = true))
      else:
        r.appendRendered(body, renderPart(r, part, cut = false))
  if line.copyText.len > 0:
    let action = ui(r):
      button(class = "ah-activity-copy", title = "Copy to the clipboard",
             `data-ct-operation` = ActivityCopyOperation,
             `data-ah-target` = line.copyText):
        text CopyLabel
    r.tagFacts(action, [("copy-action", CopyLabel)])
    r.appendRendered(node, action)
  if line.expandable:
    # The whole line is the press's target, over the text (`.ah-activity-toggle`).
    let toggle = ui(r):
      span(role = "button", tabindex = "-1", class = "ah-activity-toggle",
           title = (if line.expanded: "Close" else: "Open"),
           `data-ct-operation` = ActivityToggleOperation, `data-ah-target` = id)
    r.appendRendered(node, toggle)
  node

proc renderHead[R, N](r: R; vm: SessionTimelineVM): N =
  var head: N
  let node = ui(r):
    tdiv(ref = head, class = "ah-activity-head"):
      span(`data-ah-cut` = "line", class = "ah-activity-status",
           `data-ah-status-label` = vm.statusLabel):
        text vm.statusLabel
  let badge = vm.connection.val
  if badge.len > 0:
    let b = ui(r):
      span(class = "ah-activity-badge", `data-ah-badge` = badge):
        text badge
    r.appendRendered(head, b)
  node

proc renderFilterRow[R](r: R; vm: SessionTimelineVM): auto =
  ui(r):
    tdiv(class = "ah-activity-filter", `data-ah-filter` = vm.filter.val):
      span(`data-ah-cut` = "line", class = "ah-activity-filter-query"):
        text "Filter: " & vm.filter.val
      span(class = "ah-activity-filter-count"):
        text vm.filterCountText

proc renderNotice[R](r: R; message, kind: string): auto =
  ui(r):
    tdiv(class = "empty-overlay ah-activity-notice", `data-ah-notice` = kind):
      text message

proc renderError[R, N](r: R; vm: SessionTimelineVM): N =
  mixin appendChild
  var message: N
  result = ui(r):
    tdiv(class = "ah-activity-error", `data-ah-notice` = "error"):
      tdiv(class = "ah-activity-error-title"):
        text ErrorTitle
      tdiv(ref = message, class = "ah-activity-error-message", `data-ah-error` = vm.error.val)
      button(class = "ah-activity-retry", `data-ct-operation` = ActivityRetryOperation):
        text "Retry"
  # A request's path breaks before each `/` (a `<wbr>`: no character is
  # added) and the words at their spaces, as GPUI wraps them, never after
  # the hyphens of an id: each segment's first word is kept whole
  # (`.ah-activity-error-word`).
  let parts = vm.error.val.split('/')
  for i, part in parts:
    if i > 0:
      let opportunity = ui(r):
        wbr()
      r.appendChild(message, opportunity)
    let segment = (if i > 0: "/" else: "") & part
    let space = segment.find(' ')
    let head = if space < 0: segment else: segment[0 ..< space]
    let whole = ui(r):
      span(class = "ah-activity-error-word"):
        text head
    r.appendChild(message, whole)
    if space >= 0:
      let rest = ui(r):
        span:
          text segment[space .. ^1]
      r.appendChild(message, rest)

when defined(js):
  proc keepPlace(list: isonim_dom.Element; strip: isonim_dom.Element;
                 follow: bool; anchor, runningId: cstring;
                 onScroll: proc(top: cstring; atEnd: bool)) {.importjs: """
    (function (list, strip, follow, anchor, runningId, onScroll) {
      // Where the list stands after a redraw: at its end while following,
      // else the anchor line at its top.
      function place() {
        if (follow) { list.scrollTop = list.scrollHeight; }
        else if (anchor && anchor.length) {
          var a = list.querySelector('[data-ah-line="' + CSS.escape(anchor) + '"]');
          if (a) list.scrollTop = a.offsetTop - list.offsetTop;
        }
      }
      // The strip shows only while the running line is out of view.
      function strip_() {
        if (!strip) return;
        var line = runningId && runningId.length ?
          list.querySelector('[data-ah-line="' + CSS.escape(runningId) + '"]') : null;
        var inView = false;
        if (line) {
          var l = line.getBoundingClientRect(), b = list.getBoundingClientRect();
          inView = l.bottom > b.top && l.top < b.bottom;
        }
        strip.hidden = inView;
      }
      place();
      strip_();
      // On the first drawing the list is not in the page yet, so it has no
      // layout to scroll or measure: place it again once it is laid out.
      requestAnimationFrame(function () { place(); strip_(); });
      // And again once the faces have loaded, which changes the lines'
      // heights and so where the list's end is.
      if (document.fonts && document.fonts.ready)
        document.fonts.ready.then(function () { place(); strip_(); });
      // And whenever a line's height changes after that (a late wrap): the
      // list stays where it stands, at its end while following.
      if (typeof ResizeObserver !== 'undefined') {
        var ro = new ResizeObserver(function () { place(); strip_(); });
        for (var i = 0; i < list.children.length; i++) ro.observe(list.children[i]);
      }
      list.onscroll = function () {
        strip_();
        var b = list.getBoundingClientRect(), top = '';
        var lines = list.querySelectorAll('[data-ah-line]');
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].getBoundingClientRect().bottom > b.top + 1) {
            top = lines[i].getAttribute('data-ah-line'); break;
          }
        }
        var atEnd = list.scrollTop + list.clientHeight >= list.scrollHeight - 2;
        onScroll(top, atEnd);
      };
    })(#, #, #, #, #, #)""".}

proc renderAgentHarborSessionActivity*[R, N](r: R; vm: SessionTimelineVM;
                                            tail: SuggestedActionsVM = nil): N =
  ## The timeline, for every renderer, and the suggested-actions block
  ## `tail` gives, if any. The body is rebuilt whenever what it shows moves.
  mixin clearChildren, setAttribute
  var body: N
  let panel = ui(r):
    tdiv(class = AgentHarborActivityClass,
         `data-ah-surface` = timelineSurfaceOf(tail),
         `data-ct-pane` = SessionActivityScope):
      tdiv(ref = body, class = "ah-activity-body")

  createRenderEffect proc() =
    if tail != nil: discard tail.revision.val
    r.clearChildren(body)
    r.tagFacts(panel, [("state", (case vm.state.val
                                  of asIdle, asLoading: "loading"
                                  of asError: "error"
                                  of asReady: "ready")),
                       ("session-status", vm.statusLabel), ("connection", vm.connection.val)])
    r.appendRendered(body, renderHead[R, N](r, vm))
    if vm.filter.val.len > 0:
      r.appendRendered(body, renderFilterRow(r, vm))
    case vm.state.val
    of asIdle, asLoading:
      r.appendRendered(body, renderNotice(r, LoadingNotice, "loading"))
      return
    of asError:
      if vm.unresolvable.val.len > 0:
        # A session the source does not hold is an error, said in words
        # (`This session cannot be loaded: <reason>`), never an empty
        # timeline; centred as the notices are.
        let n = ui(r):
          tdiv(class = "ah-activity-unresolvable ah-activity-error-state",
               `data-ah-notice` = "unresolvable"):
            text vm.notice
        r.appendRendered(body, n)
      else:
        r.appendRendered(body, renderError[R, N](r, vm))
      return
    of asReady:
      discard
    if vm.isEmpty:
      r.appendRendered(body, renderNotice(r, EmptyNotice, "empty"))
      return
    let lines = timelineLinesWith(vm.lines, tail)
    let runningId = runningLineId(lines, vm.runningLine)
    let stripText = runningStripText(vm)
    var strip: N
    if stripText.len > 0:
      let s = ui(r):
        tdiv(ref = strip, class = "ah-activity-running-strip",
             `data-ah-running-strip` = stripText, `data-ah-running-for` = runningId):
          span(class = "ah-activity-running-mark"):
            text "\xE2\x97\x8F"
          span(`data-ah-cut` = "line", class = "ah-activity-running-command"):
            text stripText
      r.appendRendered(body, s)
    var list: N
    let listNode = ui(r):
      tdiv(ref = list, class = "ah-activity-lines", tabindex = "0",
           `data-ah-lines` = $lines.len)
    for line in lines:
      r.appendRendered(list, renderLine[R, N](r, line))
    r.appendRendered(body, listNode)
    if vm.showsUnseenChip:
      let chip = ui(r):
        tdiv(class = "ah-activity-unseen-row"):
          button(class = "ah-activity-unseen", `data-ah-unseen` = $vm.unseen.val,
                 `data-ct-operation` = ActivityJumpOperation):
            text unseenChipText(vm.unseen.val)
      r.appendRendered(body, chip)
    if showsBlock(tail):
      r.appendRendered(body, renderAgentHarborSuggestedActions[R, N](r, tail))
    when defined(js):
      when typeof(list) is isonim_dom.Element:
        let target = vm
        let follow = vm.follow.val
        let anchor = vm.anchor
        keepPlace(list, strip, follow, cstring(anchor), cstring(runningId),
          proc(top: cstring; atEnd: bool) =
            if atEnd:
              if not target.follow.val: target.setFollow(true)
            else:
              if target.follow.val: target.setFollow(false)
              if $top != target.readingAt.val: target.readAt($top))

  panel

when defined(js):
  import isonim/web/web_renderer

  proc mountAgentHarborSessionActivityPanel*(container: isonim_dom.Element;
                                             vm: SessionTimelineVM;
                                             tail: SuggestedActionsVM = nil) =
    ## The timeline in `container`, for the browser, with the
    ## suggested-actions block `tail` gives, if any.
    discard isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(
      renderAgentHarborSessionActivity[WebRenderer, isonim_dom.Element](WebRenderer(), vm,
                                                                         tail)))
