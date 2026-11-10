## test_ctf_p1b_tui_views_cover_web_states.nim — CTF-P1b, Tier 2: **every
## web story of CodeTracer as an Agent Harbor front-end has a terminal
## rendering of the same viewmodel state, and a real terminal shows it.**
##
## The stories are not listed here. They are read from their one
## declaration, `stories/codetracer_stories.nim` (`codeTracerStorySections`),
## and their StoryBook ids are computed by the generator's own `storybookId`,
## as the GPUI suite (`gpui/tests/test_ctf_p1b_gpui_views_cover_web_states.nim`)
## does. A story whose surface has no terminal view fails BY ITS ID.
##
## For every story of the `CodeTracer/Agent Harbor` section, at the brief's
## laptop and sidebar sizes (180×56 and 45×56 cells: 1440×900 and 360×900 at
## 8×16 px a cell, `ah_tui_stories.TuiSizes`) and in both colour modes:
##
##   1. THE DRAWING AGAINST THE VIEWMODEL. `mountStory` builds the viewmodel
##      with the SAME constructor the web mount uses and draws it; the drawn
##      facts (`AhNode`, the terminal's `data-ah-*`) are compared with that
##      viewmodel value by value — which tabs a strip draws and in what
##      order, their labels, attention and the active one, `+N` and its menu;
##      the list's tree nodes and rows; the initiative bar's tabs, recording
##      buttons, popup, sessions started elsewhere and inbox; the
##      initiatives' rows, selection and session lines; the progress panel's
##      milestones by group; the fleet's filters, counts, rows, selection and
##      unfolded activity; and the error a failing source reported. Each
##      text fact is held to the cells under it (the full text, or its
##      elision ending in "…" where the cells are fewer; a wrapped text's
##      lines read in order). A text the web shows whole — a head band's
##      source, summary and caveat, a panel's error, the initiative bar's
##      right-hand group, a milestone's meta — must be drawn whole, wrapped
##      where a line cannot hold it, and a tree node's title is never cut
##      while its counts are drawn (`cutTextProblems`). A text that lists
##      its parts with " · " wraps only after a separator
##      (`separatorWrapProblems`); a tree node's counts are not cut where
##      flowing `n/m` inline would keep them whole, and on the docked
##      panel's wide layout they end flush with the ages
##      (`sessionHeaderProblems`); the popup's heading shows a title whole
##      wherever the bar can hold it (`popupHeadingProblems`); an overflow
##      menu keeps two cells before its origin (`menuGapProblems`). A cut
##      text never leaves a space or a dangling separator before its "…",
##      and a tree header's counts are cut only between their parts
##      (`cutEdgeProblems`); a title keeps two cells before the status word
##      right-aligned on its line (`statusGapProblems`).
##   2. THE CELL STYLES AGAINST THE VIEWMODEL. The ground and ink of the
##      parts whose state the viewmodel decides — the active tab and row, the
##      selected initiative and fleet row, the current milestone, the active
##      filter and recording, each status mark's colour, an error's colour,
##      the section head's band, the focused initiative's underline in the
##      action colour (its own colour, SGR 58), a tab bar's notice ground at
##      least `NoticeGroundMinContrast` off the bar's, the inbox's steps at
##      the label's half opacity while nothing waits (as the browser draws
##      them), the auto-switch dot in the action border colour, a panel's
##      Retry on the controls' ground and the selected fleet row's `+N` chip
##      on a ground of its own (each at least `ControlGroundMinContrast` off
##      what it lies on), the fleet's activity lines
##      (red only on a row with no failure line) and filter counts — are
##      derived here from the
##      viewmodel and the design-system palette
##      (`viewmodel/views/agent_harbor_palette.nim`, the roles GPUI resolves)
##      and compared with the cells.
##   3. A REAL TERMINAL. `tests/apps/app_agent_harbor_story.nim` (the
##      terminal story host) is spawned in a pty by TermAssert and its frame
##      parsed by libvterm; every cell's glyph, foreground and background must
##      equal the in-process drawing's, so steps 1 and 2 are statements about
##      what a terminal shows, not about a buffer.
##   4. THE COMMITTED SNAPSHOT. The terminal's screen is compared with its
##      TermAssert styled snapshot (`plaintext.txt` + `styles.txt`, every
##      cell's colours), committed under `tests/snapshots/ctf-p1b/<capture
##      id>/` (`SNAP_RECORD=1` re-records). Only over the synthetic fixture
##      set, the one they are recorded from; another set is reported and not
##      compared.
##
## With `CTF_P1B_TUI_OUT=<dir>` it also writes each screen as
## `<capture id>.svg` in its colours (TermAssert `renderColourSvg`), the
## input of `ci/test/ctf-p1b-tui-capture.sh`.
##
## No mocks: the viewmodels read the committed fixture set through the
## production data-source seam, the views are the product's, and the
## terminal is a real pty and libvterm.

import std/[math, os, sequtils, sets, strutils, times, unittest]
from std/unicode import runes, runeAt, `$`, `==`

import term_assert

import ../../testing/dual_snap
import ../../agent_harbor/ah_tui_stories
import ../../agent_harbor/ah_tui_session_views
import ../../agent_harbor/ah_tui_initiative_tab_bar
import ../../agent_harbor/ah_tui_fleet_panel
import nim_agents/agent_harbor/fleet_records
import nim_agents_isonim_viewmodels/agent_harbor/[fleet_vm, session_tabs_vm,
  initiative_tabs_vm, initiatives_vm, initiative_progress_vm, fixture_source, data_source]
from ../../../viewmodel/views/agent_harbor_words import tabLabelOf, filterCount,
  countsText, activityLineIsError

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling.
const ExpectedAssertions = 86

const
  Stem = "app_agent_harbor_story"
  Modes = [dmDark, dmLight]
  MinimumStories = 59
    ## The section's stories at CTF-P2a's landing (9 fleet, 11 session tabs,
    ## 10 session list, 12 initiative tabs, 8 initiatives, 9 progress).

var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

proc themeOf(mode: DesignMode): string = (if mode == dmDark: "dark" else: "light")

# ---------------------------------------------------------------------------
# 1. The drawing against the viewmodel (the GPUI suite's comparisons, over
#    the terminal's facts)
# ---------------------------------------------------------------------------

const DrawnTextFacts = [
  "label", "title", "summary", "headline", "status", "meta", "progress", "source",
  "counts", "detail", "age", "activity", "origin", "inbox-position", "elsewhere-label",
  "frame-title", "caveat", "failure", "error", "error-title"]
  ## The facts that name a text the node draws on its one row.

proc elidedMatch*(drawn, value: string): bool =
  ## The cells show `value`, or its start cut to the cells and ended "…".
  if drawn == value: return true
  if drawn.endsWith(Ellipsis):
    let kept = drawn[0 ..< drawn.len - Ellipsis.len]
    return value.startsWith(kept) and widthOf(drawn) < widthOf(value)
  false

proc drawnText(m: AhTuiMount; n: AhNode): string =
  ## The text a node's cells hold: its one row, or the rows of a wrapped
  ## text (each line's ends trimmed) joined by a space, as the words were.
  let g = m.canvas.grid
  if n.height <= 1: return g.cellsText(n.row, n.col, n.width)
  var lines: seq[string]
  for r in n.row ..< min(m.rows, n.row + n.height):
    lines.add g.cellsText(r, n.col, n.width).strip
  lines.join(" ")

proc sameWords(drawn, value: string): bool =
  ## A wrapped text against its value: the same words, a word cut across
  ## two lines (a word longer than a line) included.
  drawn == value or drawn.replace(" ", "") == value.replace(" ", "")

proc drawnTextProblems(m: AhTuiMount): seq[string] =
  ## Each text fact against the cells under its node. A node below the
  ## screen's foot is in the tree and clipped off it, like a list the web
  ## clips: it is not read, and it must be wholly below the foot.
  for fact in DrawnTextFacts:
    for n in m.canvas.root.all(fact):
      if n.row >= m.rows: continue
      if n.width == 0:
        if n.attr(fact).len > 0:
          result.add "a " & fact & " says '" & n.attr(fact) & "' but draws no cell"
        continue
      let drawn = m.drawnText(n)
      if not (elidedMatch(drawn, n.attr(fact)) or
              n.height > 1 and sameWords(drawn, n.attr(fact))):
        result.add "a " & fact & " says '" & n.attr(fact) & "' but draws '" & drawn & "'"

const NeverCutFacts = [
  "summary", "source", "caveat", "error", "error-title", "executive-summary",
  "inbox-position", "elsewhere-label"]
  ## The texts the web shows whole at every size — wrapping them where a
  ## line cannot hold them (a head band's source and summary, the withheld
  ## note, an error's reason) or giving them the room they need (the bar's
  ## right-hand group never shrinks). The terminal wraps them too: none may
  ## end in "…".

proc cutTextProblems(m: AhTuiMount): seq[string] =
  ## Every text the web never cuts is drawn whole, and so is each
  ## milestone's meta line on the progress panel (it wraps under its title,
  ## or its column grows). A title is never cut while its own counts
  ## survive: a group header gives the counts up first. The bar's
  ## right-hand group (badge, label, position, auto-switch) shows no "…".
  proc whole(m: AhTuiMount; n: AhNode; fact: string; into: var seq[string]) =
    if n.row >= m.rows or n.attr(fact).len == 0: return
    let drawn = m.drawnText(n)
    if not sameWords(drawn, n.attr(fact)):
      into.add "the " & fact & " '" & n.attr(fact) & "' is cut to '" & drawn &
               "' where the web shows it whole"
  # A tab strip's one-line notice is cut as the web cuts it (the brief's
  # `… connection refused …`); a panel's error block wraps its reason.
  var stripNotices: seq[AhNode]
  for n in m.canvas.root.all("notice"):
    if n.height <= 1: stripNotices.add n.all("error")
  for fact in NeverCutFacts:
    for n in m.canvas.root.all(fact):
      if n notin stripNotices: m.whole(n, fact, result)
  for ms in m.canvas.root.all("milestone"):
    for n in ms.all("meta"): m.whole(n, "meta", result)
  for g in m.canvas.root.all("group"):
    let t = g.first("title")
    let counts = g.first("counts")
    if t.isNil or counts.isNil or counts.width == 0 or t.row >= m.rows: continue
    if m.drawnText(t) != t.attr("title"):
      result.add "the group title '" & t.attr("title") & "' is cut to '" & m.drawnText(t) &
                 "' while its counts '" & m.drawnText(counts) & "' are drawn"
  for n in m.canvas.root.all("controls"):
    let drawn = m.canvas.grid.cellsText(n.row, n.col, n.width)
    if Ellipsis in drawn:
      result.add "the bar's right-hand group is cut: '" & drawn.strip & "'"

proc nodeLines(m: AhTuiMount; n: AhNode): seq[string] =
  ## A wrapped node's lines, each trimmed.
  for r in n.row ..< min(m.rows, n.row + max(1, n.height)):
    result.add m.canvas.grid.cellsText(r, n.col, n.width).strip

const SeparatorWrappedFacts = ["summary", "source", "caveat", "meta", "executive-summary",
                               "error", "error-title"]
  ## Texts that may list their parts with " · " and wrap.

proc separatorWrapProblems(m: AhTuiMount): seq[string] =
  ## A text that lists its parts with " · " and wraps breaks only after a
  ## separator, so no part (`Tests: 1 failing, 2 pending`) is split across
  ## lines: every line but the last ends with "·" — wherever every part
  ## (with its " ·") fits on a line of the text's width.
  for fact in SeparatorWrappedFacts:
    for n in m.canvas.root.all(fact):
      if n.height <= 1 or n.row >= m.rows: continue
      let value = n.attr(fact)
      if Middot notin value: continue
      var fits = true
      for part in value.split(Middot):
        if widthOf(part) + 2 > n.width: fits = false
      if not fits: continue
      let lines = m.nodeLines(n)
      for i in 0 ..< lines.len - 1:
        if not lines[i].endsWith("\xC2\xB7"):
          result.add "the " & fact & " '" & value & "' wraps inside a part: '" &
                     lines[i] & "' / '" & lines[i + 1] & "'"
          break

proc sessionHeaderProblems(m: AhTuiMount): seq[string] =
  ## The session tree's group headers. On the docked panel's wide layout
  ## every header's counts end flush with the rows' ages. Elsewhere `n/m`
  ## stands in a column only as a preference: a header whose counts are cut
  ## (or hidden) although they would show whole with `n/m` two cells after
  ## its title must flow inline.
  if m.surface != "agent-harbor-session-list": return
  let view = m.view
  let docked = view.attr("mode") == $tsmDocked and m.cols * CellPx >= 768
  var ageEnds: seq[int]
  for a in view.all("age"):
    if a.row < m.rows and a.width > 0: ageEnds.add a.col + a.width
  for g in view.all("group"):
    if g.row >= m.rows: continue
    let t = g.first("title")
    let counts = g.first("counts")
    if docked:
      if counts.isNil or counts.width == 0: continue
      for e in ageEnds:
        if counts.col + counts.width != e:
          result.add "the counts '" & counts.attr("counts") & "' of '" & t.attr("title") &
                     "' end at column " & $(counts.col + counts.width) &
                     ", the ages at " & $e
          break
      continue
    let value = if counts.isNil: g.first("counts-hidden").attr("counts-hidden")
                else: counts.attr("counts")
    let whole = not counts.isNil and counts.width > 0 and m.drawnText(counts) == value
    if whole or value.len == 0: continue
    let progress = g.first("progress")
    let progressCells = if progress.isNil: 0 else: widthOf(progress.attr("progress")) + 1
    let lineEnd = g.col + g.width - 1
    if t.col + widthOf(t.attr("title")) + 2 + progressCells + widthOf(value) <= lineEnd:
      result.add "the counts '" & value & "' of '" & t.attr("title") &
                 "' are cut in the n/m column, but fit inline after the title"

proc popupHeadingProblems(m: AhTuiMount): seq[string] =
  ## The popup's heading never cuts a title the web shows whole: wherever
  ## the bar can hold the heading (an inset, the mark, the title, two cells,
  ## the state word, an inset), the title is drawn whole.
  for p in m.canvas.root.all("popup"):
    let t = p.first("title")
    let word = p.first("state")
    if t.isNil or word.isNil or t.row >= m.rows: continue
    let need = 1 + 2 + widthOf(t.attr("title")) + 2 + widthOf(word.attr("state")) + 1
    if need <= m.cols and m.drawnText(t) != t.attr("title"):
      result.add "the popup's title '" & t.attr("title") & "' is cut to '" & m.drawnText(t) &
                 "' though the bar holds its heading (" & $need & " of " & $m.cols & " cells)"

proc menuGapProblems(m: AhTuiMount): seq[string] =
  ## An overflow menu's item keeps at least two cells between its title
  ## (cut or whole) and its right-hand column (the origin, `n/m`), and one
  ## cell between that column and the menu's edge.
  for menu in m.canvas.root.all("menu"):
    if menu.attr("menu") != "overflow": continue
    for item in menu.all("menu-item"):
      if item.row >= m.rows: continue
      let t = item.first("title")
      let trail = item.first("menu-trailing")
      if t.isNil or trail.isNil: continue
      let titleEnd = t.col + widthOf(m.canvas.grid.cellsText(t.row, t.col, t.width).strip(leading = false))
      if trail.col - titleEnd < 2:
        result.add "the menu item '" & t.attr("title") & "' leaves " & $(trail.col - titleEnd) &
                   " cell(s) before its origin"
      if menu.col + menu.width - (trail.col + trail.width) < 1:
        result.add "the menu item '" & t.attr("title") & "' puts its origin against the menu's edge"

proc cutEdgeProblems(m: AhTuiMount): seq[string] =
  ## A text cut to its cells never leaves a space, or a separator (" · ",
  ## " — ") the cut made last, before its "…": the cell is spent on nothing
  ## and the "…" stands apart like a word. A tree header's counts are cut
  ## only between their parts (`2 need input…`, never `2 need…`).
  for fact in DrawnTextFacts:
    for n in m.canvas.root.all(fact):
      if n.row >= m.rows or n.width == 0 or n.height > 1: continue
      let drawn = m.drawnText(n)
      if not drawn.endsWith(Ellipsis): continue
      let kept = drawn[0 ..< drawn.len - Ellipsis.len]
      if kept.len == 0: continue
      if kept.endsWith(" ") or kept.endsWith(" \xC2\xB7") or kept.endsWith(" \xE2\x80\x94"):
        result.add "the " & fact & " '" & n.attr(fact) & "' is cut to '" & drawn &
                   "', a space or a separator before its \"…\""
      if fact == "counts":
        var whole = false
        var acc = ""
        for part in n.attr(fact).split(Middot):
          acc = if acc.len == 0: part else: acc & Middot & part
          if acc == kept: whole = true
        if not whole:
          result.add "the counts '" & n.attr(fact) & "' are cut inside a part: '" & drawn & "'"

proc statusGapProblems(m: AhTuiMount): seq[string] =
  ## A title, whole or cut, keeps `StatusWordGap` cells before the status
  ## word right-aligned on its line: an initiative's session lines (the
  ## Initiatives panel's and the popup's) and the popup's heading.
  proc gap(m: AhTuiMount; owner: AhNode; word: string; into: var seq[string]) =
    let t = owner.first("title")
    let w = owner.first(word)
    if t.isNil or w.isNil or t.row >= m.rows or t.row != w.row or w.width == 0: return
    let titleEnd = t.col + widthOf(m.canvas.grid.cellsText(t.row, t.col, t.width).strip(leading = false))
    if w.col - titleEnd < StatusWordGap:
      into.add "the title '" & t.attr("title") & "' leaves " & $(w.col - titleEnd) &
               " cell(s) before its " & word & " word '" & w.attr(word) & "'"
  for s in m.canvas.root.all("session"): m.gap(s, "status", result)
  for p in m.canvas.root.all("popup"): m.gap(p, "state", result)

proc expect(problems: var seq[string]; what: string; drawn, wanted: auto) =
  if drawn != wanted:
    problems.add what & ": drawn " & $drawn & ", the viewmodel says " & $wanted

proc commonState(view: AhNode; state: AsyncState; error: string;
                 problems: var seq[string]) =
  if state == asError:
    var shown = false
    for e in view.all("error"):
      if error in e.attr("error"): shown = true
    if not shown: problems.add "the error the source reported (" & error & ") is not drawn"
  if state in {asIdle, asLoading}:
    problems.expect("loading notice", view.values("notice").contains("loading"), true)

proc checkSessionTabs(view: AhNode; vm: SessionTabStripVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  let tabs = vm.tabs
  if tabs.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  var wanted: seq[string]
  var overflow: seq[int]
  if vm.mode.val == tsmMultiLine:
    for t in tabs: wanted.add t.id
  else:
    let layout = vm.singleLine
    for i in layout.visible: wanted.add tabs[i].id
    overflow = layout.overflow
  var ids, labels, attention, wantedLabels, wantedAttention: seq[string]
  var active = ""
  for e in view.all("tab"):
    ids.add e.attr("tab")
    labels.add e.first("label").attr("label")
    attention.add e.attr("attention")
    if e.attr("active") == "true": active = e.attr("tab")
  for id in wanted:
    for t in tabs:
      if t.id == id:
        wantedLabels.add tabLabelOf(t)
        wantedAttention.add $t.attention
  result.expect("tabs", ids, wanted)
  result.expect("tab labels", labels, wantedLabels)
  result.expect("tab attention", attention, wantedAttention)
  result.expect("active tab", active, vm.activeId.val)
  result.expect("+N chip", view.values("overflow"),
                if overflow.len > 0: @[$overflow.len] else: @[])
  var menuItems: seq[string]
  let menu = view.first("menu")
  if menu != nil: menuItems = menu.values("menu-item")
  var wantedMenu: seq[string]
  if vm.overflowOpen.val:
    for i in overflow: wantedMenu.add tabs[i].id
  result.expect("overflow menu", menuItems, wantedMenu)

proc checkSessionList(view: AhNode; vm: SessionTabStripVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  result.expect("layout", view.attr("mode"), $vm.mode.val)
  let collapsed = vm.mode.val == tsmSidebar and vm.collapsed.val
  result.expect("collapsed", view.attr("collapsed"), $collapsed)
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  if vm.tabs.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  let headers = vm.grouped.val and not collapsed
  var groups, folded, rows: seq[string]
  for g in vm.groups:
    if headers:
      groups.add g.planId
      folded.add $g.collapsed
    if not (g.collapsed and headers):
      for t in g.tabs: rows.add t.id
  var drawnFolded: seq[string]
  for e in view.all("folded"): drawnFolded.add e.attr("folded")
  result.expect("tree nodes", drawnFolded, folded)
  var namedGroups: seq[string]
  for g in groups:
    if g.len > 0: namedGroups.add g
  var drawnGroups: seq[string]
  for g in view.values("group"):
    if g.len > 0: drawnGroups.add g
  result.expect("initiative nodes", drawnGroups, namedGroups)
  result.expect("rows", view.values("row"), rows)
  if not collapsed:
    result.expect("summary", view.values("summary"), @[vm.summaryText])
    result.expect("source", view.values("source"),
                  if vm.sourceLabel.len > 0: @[vm.sourceLabel] else: @[])
  for e in view.all("row"):
    if e.attr("active") == "true":
      result.expect("active row", e.attr("row"), vm.activeId.val)

proc checkInitiativeTabs(view: AhNode; vm: InitiativeTabStripVM): seq[string] =
  let tabs = vm.tabs
  let ready = vm.state.val == asReady
  result.expect("state", view.attr("state"),
                if ready and tabs.len == 0: "empty" else: stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if not ready: return
  let layout = vm.singleLine
  var wanted: seq[string]
  for i in layout.visible:
    wanted.add(if tabs[i].kind == stkInitiative: initiativeKey(tabs[i].id)
               else: sessionKey(tabs[i].id))
  result.expect("tabs", view.values("tab"), wanted)
  var active = ""
  for e in view.all("tab"):
    if e.attr("active") == "true": active = e.attr("tab")
  result.expect("active tab", active, vm.activeTab.val)
  result.expect("+N chip", view.values("overflow"),
                if layout.overflow.len > 0: @[$layout.overflow.len] else: @[])
  var wantedNumbers, wantedHidden: seq[string]
  for t in tabs:
    if t.active and t.kind == stkInitiative:
      let buttons = vm.recordingButtonsOf(t.id)
      for b in buttons.buttons: wantedNumbers.add $b.number
      if buttons.hidden > 0: wantedHidden.add $buttons.hidden
  result.expect("recording buttons", view.values("recording"), wantedNumbers)
  result.expect("recordings behind +N", view.values("recordings-hidden"), wantedHidden)
  let popupId = vm.popupId.val
  result.expect("popup", view.values("popup"), if popupId.len > 0: @[popupId] else: @[])
  if popupId.len > 0:
    let popup = vm.popupOf(popupId)
    let drawn = view.first("popup")
    if drawn != nil:
      result.expect("popup title", drawn.first("title").attr("title"), popup.title)
      result.expect("popup headline", drawn.values("headline"), @[popup.headline])
      var sessions: seq[string]
      for s in popup.sessions: sessions.add s.id
      result.expect("popup sessions", drawn.values("session"), sessions)
  result.expect("elsewhere badge", view.values("elsewhere"),
                if vm.elsewhereCount > 0: @[$vm.elsewhereCount] else: @[])
  var elsewhereMenu: seq[string]
  for m in view.all("menu"):
    if m.attr("menu") == "elsewhere": elsewhereMenu = m.values("menu-item")
  var wantedElsewhere: seq[string]
  if vm.elsewhereOpen.val:
    for e in vm.elsewhere: wantedElsewhere.add e.item.id
  result.expect("elsewhere menu", elsewhereMenu, wantedElsewhere)
  let position = if vm.inboxPosition.len == 0: "inbox empty" else: vm.inboxPosition
  result.expect("inbox", view.values("inbox"), @[position])
  result.expect("auto-switch", view.values("auto-switch"), @[$vm.autoSwitch.val])

proc checkInitiatives(view: AhNode; vm: InitiativesVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  let rows = vm.rows
  if rows.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  var ids, selected, folded: seq[string]
  for row in rows:
    ids.add row.id
    selected.add $row.selected
    folded.add $row.folded
  result.expect("initiatives", view.values("initiative"), ids)
  result.expect("selection", view.values("selected"), selected)
  result.expect("folded", view.values("folded"), folded)
  result.expect("summary", view.values("summary"), @[vm.summaryText])
  result.expect("source", view.values("source"),
                if vm.sourceLabel.len > 0: @[vm.sourceLabel] else: @[])
  for row in rows:
    for e in view.all("initiative"):
      if e.attr("initiative") == row.id:
        var wantedSessions: seq[string]
        if not row.folded:
          let shown = if row.expanded: row.sessions.len else: min(row.sessions.len, 4)
          for i in 0 ..< shown: wantedSessions.add row.sessions[i].id
        result.expect("sessions of " & row.id, e.values("session"), wantedSessions)
        result.expect("progress of " & row.id, e.values("progress"), @[row.progressText])

proc checkProgress(view: AhNode; vm: InitiativeProgressVM): seq[string] =
  let found = vm.state.val == asReady and vm.found
  result.expect("state", view.attr("state"),
                if vm.state.val == asReady and not vm.found: "empty"
                else: stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if not found: return
  var groups, milestones, current: seq[string]
  for g in vm.groups:
    groups.add g.name
    for m in g.milestones:
      milestones.add m.id
      current.add $m.current
  result.expect("status groups", view.values("group"), groups)
  result.expect("milestones", view.values("milestone"), milestones)
  var drawnCurrent: seq[string]
  for e in view.all("milestone"): drawnCurrent.add e.attr("current")
  result.expect("current milestone", drawnCurrent, current)
  result.expect("headline", view.values("summary"), @[vm.headline])
  result.expect("initiative title", view.values("source"), @[vm.current.title])
  let summary = vm.current.executiveSummary
  result.expect("executive summary", view.values("executive-summary"),
                @[if summary.len > 0: summary else: "The plan states no executive summary."])

proc checkFleet(view: AhNode; vm: FleetSnapshotVM): seq[string] =
  result.expect("state", view.attr("state"), stateName(vm.state.val))
  commonState(view, vm.state.val, vm.error.val, result)
  if vm.state.val != asReady: return
  let counts = vm.counts
  var filters, filterCounts: seq[string]
  for f in FleetFilter:
    filters.add $f
    filterCounts.add $counts.filterCount(f)
  result.expect("source", view.values("source"),
                if vm.sourceLabel.len > 0: @[vm.sourceLabel] else: @[])
  result.expect("filters", view.values("filter"), filters)
  result.expect("filter counts", view.values("filter-count"), filterCounts)
  for e in view.all("filter"):
    if e.attr("active") == "true":
      result.expect("active filter", e.attr("filter"), $vm.filter.val)
  let rows = vm.rows
  if rows.len == 0:
    result.expect("empty notice", view.values("notice"), @["empty"])
    return
  var ids, selected, expanded: seq[string]
  for row in rows:
    ids.add row.id
    selected.add $row.selected
    expanded.add $row.expanded
  result.expect("rows", view.values("row"), ids)
  result.expect("selection", view.values("selected"), selected)
  result.expect("unfolded", view.values("expanded"), expanded)
  for row in rows:
    for e in view.all("row"):
      if e.attr("row") == row.id:
        let shown = if row.expanded: row.activity.len else: min(1, row.activity.len)
        result.expect("activity of " & row.shortId, e.values("activity"),
                      row.activity[0 ..< shown])
        result.expect("title of " & row.shortId, e.first("title").attr("title"), row.title)

proc checkStory(m: AhTuiMount): seq[string] =
  let view = m.view
  if view.isNil: return @["no node says which surface was drawn"]
  if view.attr("surface") != m.surface:
    return @["the view's root says surface '" & view.attr("surface") & "'"]
  case m.surface
  of "agent-harbor-session-tabs": checkSessionTabs(view, m.sessions)
  of "agent-harbor-session-list": checkSessionList(view, m.sessions)
  of "agent-harbor-initiative-tabs": checkInitiativeTabs(view, m.initiativeTabs)
  of "agent-harbor-initiatives": checkInitiatives(view, m.initiatives)
  of "agent-harbor-initiative-progress": checkProgress(view, m.progress)
  of "agent-harbor-fleet": checkFleet(view, m.fleet)
  else: @["this suite has no comparison for surface " & m.surface]

# ---------------------------------------------------------------------------
# 2. Cell styles against the viewmodel and the palette
# ---------------------------------------------------------------------------

type CellLook = object
  ## What a cell shows: its glyph and colours as `#rrggbb` ("" for the
  ## terminal's default), and its underline's own colour ("" for none or
  ## the foreground's).
  rune, fg, bg, ul: string
  underline: bool

type LookOf = proc(row, col: int): CellLook {.closure.}

proc gridLook(m: AhTuiMount): LookOf =
  let g = m.canvas.grid
  result = proc(row, col: int): CellLook =
    let s = g.styleAt(row, col)
    CellLook(rune: g.runeAt(row, col), fg: s.fg, bg: s.bg,
             ul: (if s.underline: s.underlineColor else: ""), underline: s.underline)

proc hexOf(c: Color): string =
  case c.kind
  of ckRgb: "#" & toHex(int(c.r), 2).toLowerAscii & toHex(int(c.g), 2).toLowerAscii &
            toHex(int(c.b), 2).toLowerAscii
  of ckIndexed: "indexed:" & $int(c.idx)
  of ckDefault: ""

proc expectGround(problems: var seq[string]; look: LookOf; n: AhNode; rows: int;
                  what, wanted: string) =
  ## Every visible cell of `n` on `wanted`.
  if n.isNil: return
  for r in n.row ..< min(rows, n.row + max(1, n.height)):
    for c in n.col ..< n.col + n.width:
      let got = look(r, c).bg
      if got != wanted:
        problems.add what & " at (" & $r & "," & $c & ") is on " & got & ", not " & wanted
        return

proc expectInk(problems: var seq[string]; look: LookOf; n: AhNode; rows: int;
               what, wanted: string) =
  ## The ink of the node's first glyph (a wrapped, centred text's first line
  ## may start right of the node's left edge).
  if n.isNil or n.row >= rows: return
  var col = n.col
  while col < n.col + n.width - 1 and look(n.row, col).rune == " ": inc col
  let got = look(n.row, col).fg
  if got != wanted:
    problems.add what & " at (" & $n.row & "," & $col & ") is drawn in " & got &
                 ", not " & wanted

proc markInk(m: MarkStyle): string = m.colour

const NoticeGroundMinContrast = 1.3
  ## The least contrast ratio between a tab bar's notice ground and the bar
  ## (WCAG 2 contrast ratio, https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio):
  ## below it the notice reads as loose text, not as a tab.

const ControlGroundMinContrast = 1.3
  ## The least contrast ratio between a control's own ground (a panel's
  ## Retry, the selected fleet row's `+N` chip) and the ground it lies on:
  ## below it the control reads as text (the web outlines both).

proc relativeLuminance(hex: string): float =
  ## WCAG 2 relative luminance (https://www.w3.org/TR/WCAG21/#dfn-relative-luminance).
  var channel: array[3, float]
  for i in 0 .. 2:
    let v = float(parseHexInt(hex[1 + 2 * i .. 2 + 2 * i])) / 255.0
    channel[i] = if v <= 0.03928: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)
  0.2126 * channel[0] + 0.7152 * channel[1] + 0.0722 * channel[2]

proc contrastRatio(a, b: string): float =
  ## WCAG 2 contrast ratio (https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio).
  let la = relativeLuminance(a)
  let lb = relativeLuminance(b)
  (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

proc fleetInkProblems(view: AhNode; look: LookOf; rows: int; p: AhPalette;
                      vm: FleetSnapshotVM): seq[string] =
  ## The fleet's inks the shared rules decide: an activity line red only on
  ## a row with no failure line (`activityLineIsError`), else the caption
  ## role, the selection's text on the selected row; the active filter's
  ## count in the body role even at 0, another 0 in the disabled role.
  for row in vm.rows:
    for e in view.all("row"):
      if e.attr("row") != row.id or e.row >= rows: continue
      let lines = e.all("activity")
      for i, a in lines:
        let wanted = if row.selected: p.selectedText
                     elif activityLineIsError(row, i): p.textError
                     else: p.rowDetail
        result.expectInk(look, a, rows, "activity line " & $i & " of " & row.shortId &
                         (if row.failureText.len > 0: " (under a failure line)" else: ""),
                         wanted)
  for e in view.all("filter"):
    let active = e.attr("active") == "true"
    let count = e.first("count-of")
    if count.isNil: continue
    let n = parseInt(e.attr("filter-count"))
    result.expectInk(look, count, rows, "the count of filter " & e.attr("filter"),
                     if active: p.textBody elif n == 0: p.textDisabled else: p.textCaption)

proc styleProblems(m: AhTuiMount; look: LookOf): seq[string] =
  ## The grounds and inks the viewmodel's state decides, from the palette.
  let p = ahPalette(m.mode)
  let t = tone(p)
  let view = m.view
  if view.isNil: return
  let rows = m.rows
  # Every section head is on the head band.
  for h in view.all("head"):
    if h.attr("head") == "section header":
      result.expectGround(look, h, rows, "the section head", t.head)
  # A failure says what failed in the error role: a strip's one-line notice
  # all of it, a panel's error block its title (its reason is a caption).
  for n in view.all("notice"):
    if n.attr("notice") != "error": continue
    if n.height == 1:
      result.expectInk(look, n.first("error"), rows, "the error", p.textError)
    else:
      result.expectInk(look, n.first("error-title"), rows, "the error's title", p.textError)
      result.expectInk(look, n.first("error"), rows, "the error's reason", p.textCaption)
  # A panel's Retry is a control on its own ground, a visible step off the
  # panel's (`ControlGroundMinContrast`), as the web's outlined button is.
  for n in view.all("notice"):
    if n.attr("notice") != "error" or n.height <= 1: continue
    let b = n.first("button")
    if b.isNil or b.row >= rows: continue
    let ground = look(b.row, b.col).bg
    let panel = look(b.row, b.col - 2).bg
    if ground != t.chip:
      result.add "Retry is on " & ground & ", not the controls' ground " & t.chip
    elif ground == "" or panel == "" or contrastRatio(ground, panel) < ControlGroundMinContrast:
      result.add "Retry is on " & ground & ", " &
                 formatFloat(contrastRatio(ground, panel), ffDecimal, 2) &
                 ":1 against the panel's " & panel & ", under " &
                 formatFloat(ControlGroundMinContrast, ffDecimal, 2) & ":1"
  # A tab bar's notice is tab-shaped: its ground a visible step off the
  # bar's (`NoticeGroundMinContrast`).
  for n in view.all("notice"):
    if n.height != 1 or n.row >= rows: continue
    let ground = look(n.row, n.col).bg
    let bar = t.frame
    if ground == "" or contrastRatio(ground, bar) < NoticeGroundMinContrast:
      result.add "the notice '" & n.attr("notice") & "' is on " & ground & ", " &
                 (if ground == "": "no ground"
                  else: formatFloat(contrastRatio(ground, bar), ffDecimal, 2) & ":1") &
                 " against the bar's " & bar & ", under " &
                 formatFloat(NoticeGroundMinContrast, ffDecimal, 2) & ":1"
  case m.surface
  of "agent-harbor-session-tabs":
    let vm = m.sessions
    for e in view.all("tab"):
      let active = e.attr("tab") == vm.activeId.val
      result.expectGround(look, e, rows, "tab " & e.attr("tab"),
                          if active: p.activeTab else: t.frame)
      result.expectInk(look, e.first("label"), rows, "the label of " & e.attr("tab"),
                       if active: p.activeTabText else: p.textCaption)
      for tab in vm.tabs:
        if tab.id == e.attr("tab"):
          result.expectInk(look, e.first("mark"), rows, "the mark of " & tab.id,
                           markInk(p.markOf(tab.attention)))
      # The focused initiative's tabs: underlined in the action role
      # (`colors-ui-border-action`, the web's 2px line), the underline's own
      # colour, under the tab's inner cells.
      if e.attr("in-focus") == "true" and e.row < rows:
        for col in e.col + 1 ..< e.col + e.width - 1:
          let cell = look(e.row, col)
          if not cell.underline or cell.ul != p.borderAction:
            result.add "the focused tab " & e.attr("tab") & " at (" & $e.row & "," & $col &
                       ") is underlined " & (if cell.underline: "in '" & cell.ul & "'"
                                             else: "not at all") &
                       ", not in the action colour " & p.borderAction
            break
  of "agent-harbor-session-list":
    let vm = m.sessions
    for e in view.all("row"):
      if e.height == 0 or e.row >= rows: continue
      let active = e.attr("row") == vm.activeId.val
      result.expectGround(look, e, rows, "row " & e.attr("row"),
                          if active: p.activeRow else: t.body)
      for tab in vm.tabs:
        if tab.id == e.attr("row"):
          result.expectInk(look, e.first("mark"), rows, "the mark of " & tab.id,
                           markInk(p.markOf(tab.attention)))
  of "agent-harbor-initiative-tabs":
    let vm = m.initiativeTabs
    for e in view.all("tab"):
      let active = e.attr("tab") == vm.activeTab.val
      if active:
        # The tab's ground, outside its recording buttons.
        let label = e.first("label")
        result.expectGround(look, label, rows, "the active tab's title", p.activeTab)
      else:
        result.expectGround(look, e, rows, "tab " & e.attr("tab"), t.frame)
    for e in view.all("recording"):
      if e.attr("recording-active") == "true":
        result.expectGround(look, e, rows, "the active recording",
                            if m.mode == dmDark: p.action else: p.borderAction)
    for e in view.all("popup"):
      let drawn = AhNode(row: e.row, col: e.col, width: e.width, height: 1)
      result.expectGround(look, drawn, rows, "the popup", t.menu)
    # Auto-switch on: its dot in the action border role in both modes
    # (`.ah-inbox-auto-on::before`), the mark two cells before the label.
    for e in view.all("auto-switch"):
      if e.attr("auto-switch") != "true" or e.row >= rows: continue
      var dot: AhNode
      for mk in view.all("mark"):
        if mk.row == e.row and mk.col == e.col - 2: dot = mk
      if dot.isNil:
        result.add "auto-switch is on and draws no dot"
      else:
        result.expectInk(look, dot, rows, "the auto-switch dot", p.borderAction)
    # Previous / Next while nothing waits: the label at half opacity over
    # the bar, as the browser draws them (`InboxStepDisabledAlpha`).
    for e in view.all("step"):
      result.expectInk(look, e, rows, "the inbox step " & e.attr("button") &
                       " (" & e.attr("step") & ")",
                       if vm.inboxPosition.len == 0:
                         blendOver(p.textLabel & InboxStepDisabledAlpha, t.frame)
                       else: p.textLabel)
  of "agent-harbor-initiatives":
    let vm = m.initiatives
    for i, row in vm.rows:
      for e in view.all("initiative"):
        if e.attr("initiative") != row.id or e.row >= rows: continue
        let wanted = if row.selected: p.selectedGround
                     elif i mod 2 == 1: t.band else: t.body
        # The row's first cells after its left edge (the bar is drawn there).
        let probe = AhNode(row: e.row, col: e.col + 1, width: 1, height: 1)
        result.expectGround(look, probe, rows, "initiative " & row.id, wanted)
        result.expectInk(look, e.first("mark"), rows, "the mark of " & row.id,
                         markInk(p.markOf(row.state)))
  of "agent-harbor-initiative-progress":
    let vm = m.progress
    if vm.state.val == asReady and vm.found:
      for g in vm.groups:
        for ml in g.milestones:
          for e in view.all("milestone"):
            if e.attr("milestone") != ml.id or e.row >= rows: continue
            result.expectInk(look, e.first("mark"), rows, "the mark of " & ml.id,
                             markInk(p.markOf(ml.statusClass)))
            if ml.current:
              let probe = AhNode(row: e.row, col: e.col, width: 1, height: 1)
              result.expectGround(look, probe, rows, "the current milestone",
                if m.mode == dmDark: p.activeTab
                elif m.cols * CellPx >= 960: p.hover else: p.menu)
  of "agent-harbor-fleet":
    let vm = m.fleet
    for e in view.all("filter"):
      if e.attr("filter") == $vm.filter.val:
        result.expectGround(look, e, rows, "the active filter", t.chosen)
    for i, row in vm.rows:
      for e in view.all("row"):
        if e.attr("row") != row.id or e.row >= rows: continue
        let probe = AhNode(row: e.row, col: e.col, width: 1, height: 1)
        result.expectGround(look, probe, rows, "fleet row " & row.shortId,
          if row.selected: p.action elif i mod 2 == 1: t.band else: t.body)
        # The `+N` / `less` chip on its own ground; on the selected row a
        # visible step off the selection (`ControlGroundMinContrast`).
        let more = e.first("activity-more")
        if not more.isNil and more.row < rows:
          let wanted = if row.selected: t.chipOnAction else: t.chip
          result.expectGround(look, more, rows, "the chip " & more.attr("activity-more") &
                              " of " & row.shortId, wanted)
          if row.selected:
            let chipBg = look(more.row, more.col).bg
            let rowBg = look(e.row, e.col).bg
            if chipBg.len == 0 or rowBg.len == 0 or
               contrastRatio(chipBg, rowBg) < ControlGroundMinContrast:
              result.add "the chip of the selected row " & row.shortId & " is on " & chipBg &
                         " against the row's " & rowBg & ", under " &
                         formatFloat(ControlGroundMinContrast, ffDecimal, 2) & ":1"
    result.add fleetInkProblems(view, look, rows, p, vm)
  else: discard

# ---------------------------------------------------------------------------
# 3 and 4. A real terminal, and the committed snapshot
# ---------------------------------------------------------------------------

let section = agentHarborSection()
let root = dual_snap.repoRoot()
let snapshotRoot = root / "src" / "frontend" / "tui"
  ## `<root>/tests/snapshots/<name>`, TermAssert's layout.
let captureOut = getEnv("CTF_P1B_TUI_OUT")
let synthetic = AgentHarborFixtureSet == "synthetic"

proc screenProblems(sess: var TuiTestSession; m: AhTuiMount): seq[string] =
  ## Every cell the terminal shows against the in-process drawing.
  var shown = 0
  let look = m.gridLook()   # once: the closure holds a copy of the grid
  for r in 0 ..< m.rows:
    for c in 0 ..< m.cols:
      let cell = sess.cellAt(r, c)
      if cell.width == 0: continue
      let want = look(r, c)
      let rune = if cell.rune.int32 == 0: " " else: $cell.rune
      let fg = hexOf(cell.fg)
      let bg = hexOf(cell.bg)
      if rune != want.rune or fg != want.fg or bg != want.bg:
        if shown < 5:
          result.add "the terminal shows '" & rune & "' " & fg & " on " & bg & " at (" &
                     $r & "," & $c & "), the drawing '" & want.rune & "' " & want.fg &
                     " on " & want.bg
        inc shown
  if shown > 5: result.add "... and " & $(shown - 5) & " more cells"

proc terminalLook(sess: ptr TuiTestSession): LookOf =
  result = proc(row, col: int): CellLook =
    let cell = sess[].cellAt(row, col)
    CellLook(rune: if cell.rune.int32 == 0: " " else: $cell.rune,
             fg: hexOf(cell.fg), bg: hexOf(cell.bg),
             ul: (if cell.underline != usNone: hexOf(cell.underlineColor) else: ""),
             underline: cell.underline != usNone)

proc spawnStory(id: string; cols, rows: int; mode: DesignMode): TuiTestSession =
  result = newTuiTest(appBinaryPath(Stem),
                      @["--story=" & id, "--theme=" & themeOf(mode),
                        "--cols=" & $cols, "--rows=" & $rows])
    .width(cols).height(rows)
    .envSet("TERM", "xterm-256color")
    .envSet("COLORTERM", "truecolor")
    .envSet("LANG", "en_US.UTF-8")
    .spawn()
  waitForCompleteFrame(result, cols, rows)

proc renderOnTerminal(story: CodeTracerStory; sizeName: string; cols, rows: int;
                      mode: DesignMode): seq[string] =
  ## Steps 1 to 4 for one story, size and mode; the problems found.
  let id = storybookId(section, story)
  let m = try: mountStory(story, cols, rows, mode)
          except ValueError as e: return @["no terminal rendering: " & e.msg]
  defer: m.dispose()
  result = checkStory(m) & drawnTextProblems(m) & cutTextProblems(m) &
           separatorWrapProblems(m) & sessionHeaderProblems(m) & popupHeadingProblems(m) &
           menuGapProblems(m) & cutEdgeProblems(m) & statusGapProblems(m) &
           styleProblems(m, m.gridLook())
  var sess = spawnStory(id, cols, rows, mode)
  defer: sess.close()
  result.add screenProblems(sess, m)
  result.add styleProblems(m, terminalLook(addr sess))
  let capture = captureIdOf(id, sizeName, themeOf(mode))
  if synthetic:
    for d in styledSnapshotDiffs(sess.screen, snapshotDir("ctf-p1b" / capture, snapshotRoot)):
      result.add "snapshot " & capture & ": " & d
  if captureOut.len > 0:
    let p = ahPalette(mode)
    createDir(captureOut)
    writeFile(captureOut / (capture & ".svg"),
              renderColourSvg(sess.screen, defaultFg = p.textBody, defaultBg = p.ground))
    writeFile(captureOut / (capture & ".txt"), renderPlain(sess.screen))
  sess.send("q")

# The child embeds the fixture set this suite embedded, whatever chose it.
putEnv("AGENT_HARBOR_FIXTURES", AgentHarborFixtureRoot)
compileChildApp(Stem)

suite "CTF-P1b: the stories come from their one declaration":
  test "the Agent Harbor section is declared and holds the P2a stories":
    ck section.title == AgentHarborSectionTitle
    ck section.stories.len >= MinimumStories
    var ids: HashSet[string]
    for story in section.stories: ids.incl storybookId(section, story)
    ck ids.len == section.stories.len
    ck "codetracer-agent-harbor--initiative-tabs-popup" in ids

suite "CTF-P1b: every Agent Harbor story has a terminal rendering":
  test "test_ctf_p1b_tui_views_cover_web_states":
    var missing: seq[string]
    for story in section.stories:
      if not hasTuiRendering(story.surface):
        missing.add storybookId(section, story) & " (surface " & story.surface & ")"
    if missing.len > 0:
      echo "Stories with no terminal rendering:\n  " & missing.join("\n  ")
    ck missing.len == 0
    if not synthetic:
      echo "  the committed snapshots were not compared: this build embeds the '",
        AgentHarborFixtureSet, "' fixture set, and they are recorded from 'synthetic'"
    var failures: seq[string]
    var rendered = 0
    for story in section.stories:
      let id = storybookId(section, story)
      for (sizeName, cols, rows) in TuiSizes:
        for mode in Modes:
          let problems = renderOnTerminal(story, sizeName, cols, rows, mode)
          if problems.len == 0: inc rendered
          else:
            failures.add id & " @ " & sizeName & "/" & themeOf(mode) & ": " &
                         problems.join("; ")
    if failures.len > 0:
      echo "Terminal renderings that differ (" & $failures.len & "):\n  " &
        failures.join("\n  ")
    ck failures.len == 0
    ck rendered == section.stories.len * TuiSizes.len * Modes.len
    echo "  rendered ", rendered, " story renderings on a terminal (",
      section.stories.len, " stories × ", TuiSizes.len, " sizes × ", Modes.len, " modes)"

proc storyOf(surface, fixture: string): CodeTracerStory =
  for s in section.stories:
    if s.surface == surface and s.fixture == fixture: return s

suite "CTF-P1b: the comparisons can fail":
  # Positive controls: a drawing that disagrees with its viewmodel, a fact
  # that names a word the cells do not show, and a cell on the wrong ground
  # must each be reported, or the green run above would mean nothing.

  test "a tab activated after drawing is a mismatch until the view redraws":
    let m = mountStory(storyOf("agent-harbor-session-tabs", "multi-line"), 180, 56, dmDark)
    ck checkStory(m).len == 0
    let tabs = m.sessions.tabs
    ck m.sessions.activate(tabs[^1].id)
    let stale = checkStory(m)
    ck stale.join(" ").contains("active tab")
    m.draw()
    ck checkStory(m).len == 0
    m.dispose()

  test "a click on a fold redraws the tree from the viewmodel":
    let m = mountStory(storyOf("agent-harbor-initiatives", "populated"), 180, 56, dmDark)
    let fold = m.view.first("fold")
    let id = fold.attr("fold")
    ck m.handleInput("\x1b[<0;" & $(fold.col + 1) & ";" & $(fold.row + 1) & "M")
    ck m.initiatives.rows[0].folded
    ck checkStory(m).len == 0
    for e in m.view.all("initiative"):
      if e.attr("initiative") == id: ck e.all("session").len == 0
    m.dispose()

  test "a fact that names a word the cells do not show is a mismatch":
    let m = mountStory(storyOf("agent-harbor-session-tabs", "single-line"), 180, 56, dmDark)
    ck drawnTextProblems(m).len == 0
    m.view.first("label").tag("label", "not the viewmodel's title")
    let problems = drawnTextProblems(m)
    ck problems.len == 1
    ck problems.join(" ").contains("says 'not the viewmodel's title'")
    m.dispose()

  test "a cell on the wrong ground is a style mismatch":
    let m = mountStory(storyOf("agent-harbor-session-tabs", "single-line"), 180, 56, dmLight)
    ck styleProblems(m, m.gridLook()).len == 0
    let tab = m.view.first("tab")
    m.canvas.grid.paint(tab.row, tab.col + 2, " ",
                        CellStyle(fg: "#000000", bg: ahPalette(dmLight).panel))
    let problems = styleProblems(m, m.gridLook())
    ck problems.len == 1
    ck problems[0].contains("tab " & tab.attr("tab"))
    m.dispose()

  test "a text the web shows whole, drawn cut, is reported":
    let m = mountStory(storyOf("agent-harbor-initiatives", "populated"), 45, 56, dmDark)
    ck cutTextProblems(m).len == 0
    let summary = m.view.first("summary")
    summary.tag("summary", summary.attr("summary") & " and more words")
    let problems = cutTextProblems(m)
    ck problems.len == 1
    ck problems.join(" ").contains("where the web shows it whole")
    m.dispose()

  test "a group title cut while its counts survive is reported":
    let m = mountStory(storyOf("agent-harbor-session-list", "sidebar"), 45, 56, dmDark)
    ck cutTextProblems(m).len == 0
    var tagged = false
    for g in m.view.all("group"):
      if not tagged and not g.first("counts").isNil and g.first("counts").width > 0:
        g.first("title").tag("title", g.first("title").attr("title") & " that runs on")
        tagged = true
    ck tagged
    ck cutTextProblems(m).join(" ").contains("while its counts")
    m.dispose()

  test "a focused tab underlined in the text's colour is a style mismatch":
    let m = mountStory(storyOf("agent-harbor-session-tabs", "focused-initiative"), 180, 56,
                       dmDark)
    ck styleProblems(m, m.gridLook()).len == 0
    let focused = m.view.all("in-focus")
    ck focused.len > 0
    let tab = focused[0]
    m.canvas.grid.restyle(tab.row, tab.col + 1, tab.width - 2, proc(s: CellStyle): CellStyle =
      result = s
      result.underlineColor = "")
    ck styleProblems(m, m.gridLook()).join(" ").contains("not in the action colour")
    m.dispose()

proc canvasLook(c: AhCanvas): LookOf =
  let g = c.grid
  result = proc(row, col: int): CellLook =
    let s = g.styleAt(row, col)
    CellLook(rune: g.runeAt(row, col), fg: s.fg, bg: s.bg,
             ul: (if s.underline: s.underlineColor else: ""), underline: s.underline)

proc repaint(m: AhTuiMount; n: AhNode; fg: string) =
  ## The node's first row's cells in `fg`, their glyphs and grounds kept.
  m.canvas.grid.restyle(n.row, n.col, max(1, n.width), proc(s: CellStyle): CellStyle =
    result = s
    result.fg = fg)

proc fixtureSnapshot(): FleetSnapshot =
  var got: ref FleetSnapshot
  newFixtureDataSource().loadFleet proc(answer: DataResult[FleetSnapshot]) =
    doAssert answer.ok, answer.error
    got = new FleetSnapshot
    got[] = answer.value
  doAssert not got.isNil, "the fixture source answers synchronously"
  got[]

suite "CTF-P1b: the round-2 layout checks can fail":
  # Positive controls for the checks added after the second visual review:
  # each drawing is spoiled the way the check guards against and must be
  # reported.

  test "a separated text wrapped inside a part is reported":
    let m = mountStory(storyOf("agent-harbor-initiative-progress", "blocked"), 45, 56, dmLight)
    ck separatorWrapProblems(m).len == 0
    var spoiled = false
    for n in m.view.all("meta"):
      if not spoiled and n.height > 1:
        m.canvas.grid.paint(n.row, n.col, repeat("x", n.width), CellStyle(fg: "#000000",
                            bg: m.canvas.grid.styleAt(n.row, n.col).bg))
        spoiled = true
    ck spoiled
    ck separatorWrapProblems(m).join(" ").contains("wraps inside a part")
    m.dispose()

  test "docked counts that do not end at the ages are reported":
    let m = mountStory(storyOf("agent-harbor-session-list", "docked"), 180, 56, dmDark)
    ck sessionHeaderProblems(m).len == 0
    let counts = m.view.first("counts")
    counts.col -= 1
    ck sessionHeaderProblems(m).join(" ").contains("the ages at")
    m.dispose()

  test "counts cut in the column although they fit inline are reported":
    let m = mountStory(storyOf("agent-harbor-session-list", "sidebar"), 45, 56, dmDark)
    ck sessionHeaderProblems(m).len == 0
    var spoiled = false
    for g in m.view.all("group"):
      if not spoiled and g.attr("inline") == "true":
        g.first("counts").width = 0
        spoiled = true
    ck spoiled
    ck sessionHeaderProblems(m).join(" ").contains("fit inline")
    m.dispose()

  test "a popup title cut where the bar holds its heading is reported":
    let m = mountStory(storyOf("agent-harbor-initiative-tabs", "popup"), 45, 56, dmDark)
    ck popupHeadingProblems(m).len == 0
    let t = m.view.first("popup").first("title")
    m.canvas.grid.paint(t.row, t.col + t.width - 1, Ellipsis,
                        m.canvas.grid.styleAt(t.row, t.col + t.width - 1))
    ck popupHeadingProblems(m).join(" ").contains("though the bar holds its heading")
    m.dispose()

  test "a menu title against its origin is reported":
    let m = mountStory(storyOf("agent-harbor-session-tabs", "single-line-active-late"), 45, 56, dmDark)
    ck menuGapProblems(m).len == 0
    let trail = m.view.first("menu").first("menu-item").first("menu-trailing")
    ck not trail.isNil
    trail.col -= 2
    ck menuGapProblems(m).join(" ").contains("before its origin")
    m.dispose()

  test "a notice on a ground too close to the bar's is reported":
    let m = mountStory(storyOf("agent-harbor-session-tabs", "empty"), 45, 56, dmLight)
    ck styleProblems(m, m.gridLook()).len == 0
    let n = m.view.first("notice")
    m.canvas.grid.restyle(n.row, n.col, n.width, proc(s: CellStyle): CellStyle =
      result = s
      result.bg = tokenHexOf(dtColorsUiSurfaceBaseRaised, dmLight))
    ck styleProblems(m, m.gridLook()).join(" ").contains("against the bar's")
    m.dispose()

  test "an arrow drawn pressable with nothing waiting is reported":
    let m = mountStory(storyOf("agent-harbor-initiative-tabs", "empty"), 180, 56, dmLight)
    ck styleProblems(m, m.gridLook()).len == 0
    let step = m.view.first("step")
    ck step.attr("step") == "disabled"
    m.repaint(step, ahPalette(dmLight).textLabel)
    ck styleProblems(m, m.gridLook()).join(" ").contains("the inbox step")
    m.dispose()

  test "the active filter's 0 in the disabled role is reported":
    let m = mountStory(storyOf("agent-harbor-fleet", "empty"), 180, 56, dmLight)
    ck styleProblems(m, m.gridLook()).len == 0
    for f in m.view.all("filter"):
      if f.attr("active") == "true": m.repaint(f.first("count-of"), ahPalette(dmLight).textDisabled)
    ck styleProblems(m, m.gridLook()).join(" ").contains("the count of filter")
    m.dispose()

  test "an error-level activity line: red without a failure line, caption under one":
    # The story data holds error-level activity only under failure lines, so
    # the other case is made from it: one failed session of the embedded
    # synthetic fleet given the running status, served through the
    # production `SnapshotDataSource` seam. Its error-level line is then on
    # a row with no failure line.
    var snapshot = fixtureSnapshot()
    var id = ""
    for s in snapshot.sessions.mitems:
      if id.len == 0 and s.status == fsFailed:
        for a in s.recent:
          if a.level == "error": id = s.id
        if id.len > 0:
          s.status = fsRunning
          s.rawStatus = "running"
    ck id.len > 0
    # Tall enough for every row of the fleet, so both cases are on screen.
    const Tall = 240
    for mode in Modes:
      let p = ahPalette(mode)
      let vm = newFleetSnapshotVM(newSnapshotDataSource(snapshot))
      vm.load()
      var c = newAhCanvas(180, Tall, p)
      c.drawFleetPanel(vm, 0, 0, 180, Tall)
      let view = c.root.first("surface")
      ck fleetInkProblems(view, canvasLook(c), Tall, p, vm).len == 0
      var red, quiet: AhNode
      for row in vm.rows:
        for e in view.all("row"):
          if e.attr("row") != row.id or e.row >= Tall: continue
          for i, a in e.all("activity"):
            if a.row < Tall and row.activityLevels[i] == "error":
              if row.failureText.len == 0 and red.isNil: red = a
              elif row.failureText.len > 0 and quiet.isNil: quiet = a
      ck not red.isNil and not quiet.isNil
      ck c.grid.styleAt(red.row, red.col).fg == p.textError
      ck c.grid.styleAt(quiet.row, quiet.col).fg == p.rowDetail
      for (n, ink) in [(red, p.rowDetail), (quiet, p.textError)]:
        c.grid.restyle(n.row, n.col, n.width, proc(s: CellStyle): CellStyle =
          result = s
          result.fg = ink)
      let problems = fleetInkProblems(view, canvasLook(c), Tall, p, vm).join(" ")
      ck problems.contains("of " & id[0 ..< 8] & " at (") and
         problems.contains("is drawn in " & p.rowDetail & ", not " & p.textError)
      ck problems.contains("(under a failure line) at")
      vm.dispose()

suite "CTF-P1b: the round-3 checks can fail":
  # Positive controls for the checks added after the third visual review:
  # each drawing is spoiled the way the check guards against and must be
  # reported.

  test "a space before a cut text's \"…\", and counts cut inside a part, are reported":
    let m = mountStory(storyOf("agent-harbor-session-list", "sidebar"), 45, 56, dmDark)
    ck cutEdgeProblems(m).len == 0
    var t: AhNode
    for n in m.view.all("title"):
      if t.isNil and n.width >= 4 and n.row < m.rows: t = n
    ck not t.isNil
    let st = m.canvas.grid.styleAt(t.row, t.col)
    m.canvas.grid.paint(t.row, t.col + t.width - 2, " " & Ellipsis, st)
    ck cutEdgeProblems(m).join(" ").contains("a space or a separator before")
    m.dispose()
    let m2 = mountStory(storyOf("agent-harbor-session-list", "sidebar"), 45, 56, dmDark)
    var counts: AhNode
    for n in m2.view.all("counts"):
      if counts.isNil and Middot in n.attr("counts") and n.width >= 3: counts = n
    ck not counts.isNil
    m2.canvas.grid.paint(counts.row, counts.col, "2" & Ellipsis,
                         m2.canvas.grid.styleAt(counts.row, counts.col))
    counts.width = 2
    ck cutEdgeProblems(m2).join(" ").contains("cut inside a part")
    m2.dispose()

  test "a title against its status word is reported":
    let m = mountStory(storyOf("agent-harbor-initiative-tabs", "popup"), 180, 56, dmDark)
    ck statusGapProblems(m).len == 0
    var spoiled = false
    for sline in m.view.all("session"):
      let t = sline.first("title")
      let w = sline.first("status")
      if not spoiled and not t.isNil and not w.isNil:
        let titleEnd = t.col + widthOf(m.canvas.grid.cellsText(t.row, t.col, t.width).strip(leading = false))
        w.col = titleEnd + 1
        spoiled = true
    ck spoiled
    ck statusGapProblems(m).join(" ").contains("cell(s) before its status word")
    m.dispose()

  test "Retry on the panel's secondary surface is reported":
    let m = mountStory(storyOf("agent-harbor-fleet", "error"), 180, 56, dmDark)
    ck styleProblems(m, m.gridLook()).len == 0
    let b = m.view.first("notice").first("button")
    ck not b.isNil
    m.canvas.grid.restyle(b.row, b.col - 1, b.width + 2, proc(s: CellStyle): CellStyle =
      result = s
      result.bg = ahPalette(dmDark).secondary)
    ck styleProblems(m, m.gridLook()).join(" ").contains("Retry is on")
    m.dispose()

  test "the selected row's chip on the selection's own ground is reported":
    let m = mountStory(storyOf("agent-harbor-fleet", "selected"), 180, 56, dmLight)
    ck styleProblems(m, m.gridLook()).len == 0
    var spoiled = false
    for e in m.view.all("row"):
      let more = e.first("activity-more")
      if not spoiled and e.attr("selected") == "true" and not more.isNil:
        m.canvas.grid.restyle(more.row, more.col - 1, more.width + 2, proc(s: CellStyle): CellStyle =
          result = s
          result.bg = ahPalette(dmLight).action)
        spoiled = true
    ck spoiled
    ck styleProblems(m, m.gridLook()).join(" ").contains("of the selected row")
    m.dispose()

  test "the auto-switch dot in the action surface's colour is reported":
    let m = mountStory(storyOf("agent-harbor-initiative-tabs", "auto-switch"), 180, 56, dmLight)
    ck styleProblems(m, m.gridLook()).len == 0
    let e = m.view.first("auto-switch")
    ck e.attr("auto-switch") == "true"
    m.repaint(AhNode(row: e.row, col: e.col - 2, width: 1, height: 1), ahPalette(dmLight).action)
    ck styleProblems(m, m.gridLook()).join(" ").contains("the auto-switch dot")
    m.dispose()

suite "CTF-P1b: the story host answers the pointer on a real terminal":
  # The initiative popup opens on hover (DEC 1003 motion,
  # SGR 1006) and a press acts on what is under it. Driven through the pty as
  # a terminal would report the pointer, read back off the screen.
  test "hovering an initiative tab opens its popup; a press on a fold folds it":
    let story = storyOf("agent-harbor-initiative-tabs", "tabs")
    let id = storybookId(section, story)
    let m = mountStory(story, 180, 56, dmDark)
    let tab = m.view.first("tab")
    let initiative = m.initiativeTabs.tabs[0]
    let headline = m.initiativeTabs.popupOf(initiative.id).headline
    m.dispose()
    var sess = spawnStory(id, 180, 56, dmDark)
    ck not sess.screenContents().contains(headline)
    sess.sendMouseMove(tab.row, tab.col + 4)
    sess.waitForText(headline, initDuration(seconds = 10))
    ck sess.screenContents().contains(headline)
    sess.send("q")
    sess.close()
    let panel = storyOf("agent-harbor-initiatives", "populated")
    let pm = mountStory(panel, 180, 56, dmDark)
    let fold = pm.view.first("fold")
    let firstSession = pm.view.first("initiative").first("session").first("title").attr("title")
    pm.dispose()
    var ps = spawnStory(storybookId(section, panel), 180, 56, dmDark)
    ck ps.screenContents().contains(elide(firstSession, 20)[0 ..< 10])
    ps.sendMouseClick(fold.row, fold.col)
    ps.waitForText(FoldedGlyph, initDuration(seconds = 10))
    ck ps.cellAt(fold.row, fold.col).rune == "\xE2\x96\xB8".runeAt(0)
    ps.send("q")
    ps.close()

suite "CTF-P1b: the terminal views share the viewmodels, not the web views":
  test "no terminal Agent Harbor view imports a web view or the web renderer":
    # The words and the palette the three front-ends share live in
    # `viewmodel/views/agent_harbor_words` and `agent_harbor_palette`, which
    # render nothing. A terminal view that imported an `isonim_*_view`
    # module, the IsoNim DSL or the web renderer would put the web's
    # rendering code in the terminal front-end's closure.
    let viewDir = root / "src" / "frontend" / "tui" / "agent_harbor"
    var scanned = 0
    var offenders: seq[string]
    for path in @[root / "src" / "frontend" / "tui" / "tests" / "apps" / (Stem & ".nim")] &
                toSeq(walkFiles(viewDir / "*.nim")):
      inc scanned
      for line in readFile(path).splitLines:
        let code = line.strip
        if not (code.startsWith("import ") or code.startsWith("from ")): continue
        for forbidden in ["views/isonim_", "isonim/dsl", "isonim/web", "isonim_gpui"]:
          if forbidden in code: offenders.add path.extractFilename & ": " & code
    ck scanned >= 7
    if offenders.len > 0: echo "  web imports:\n    " & offenders.join("\n    ")
    ck offenders.len == 0

suite "CTF-P1b: assertion count":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
