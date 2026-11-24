## test_ctf_p1b_tui_no_box_borders_between_areas.nim — CTF-P1b: **the
## terminal's Agent Harbor views separate their areas by background, never by
## a box**: few borders, areas told apart by their ground.
##
## For every story of the `CodeTracer/Agent Harbor` section (read from its
## one declaration, as the coverage suites do), at the laptop and sidebar
## sizes (and panel, for the session activity timeline) and in both colour
## modes, the screen the views draw is read cell by cell:
##
##   * NO BOX-DRAWING GLYPH anywhere: nothing in U+2500–U+257F (the Box
##     Drawing block, https://www.unicode.org/charts/PDF/U2500.pdf). The one
##     divider the style permits, `▏` (U+258F), is a Block Element and is not in it;
##   * NO ASCII FRAME: no horizontal run of three or more `-`, `=` or `+`
##     with a `+` or `|` at either end, and no column of two or more `|` one
##     above the other;
##   * ADJACENT AREAS DIFFER BY BACKGROUND: each cell belongs to the last
##     area the view recorded over it (`AhCanvas.areas`: the window, a frame
##     header, a section head, a filter band, a list, a row band, a group
##     header, a menu, the popup); wherever two cells side by side or one
##     above the other belong to different areas, their backgrounds must
##     differ, so every boundary the web draws with a hairline is one the
##     terminal draws with a change of ground;
##   * AND EVERY AREA IS ITS OWN GROUND: the cells along an area's edges are on
##     the background the area declared, so the check above reads the
##     grounds the areas really have;
##   * THE TIMELINE IS CARDLESS: every cell of a session activity timeline's
##     line is on the timeline's own ground (`timelineLineProblems`); only
##     the focus bar `▎` differs, by its ink;
##   * SO ARE CTF-P3'S ROWS: a spec card, a test, a Code tab file and an
##     inbox row is one ground from its first row to its last, along both
##     its edges (`cardlessRowProblems`), so no row is framed by a ground of
##     its own; the inset bar `▎` differs by its ink only.
##
## The same views drive the terminal story host that
## `real_terminal/test_ctf_p1b_tui_views_cover_web_states.nim` compares, cell
## for cell, with a real terminal and with the committed snapshots; this
## suite also reads those committed snapshots' text for box glyphs, so a
## snapshot recorded from a bordered drawing fails here as well.
##
## No mocks: the real views over the committed synthetic fixture set.

import std/[os, strutils, unittest]
from std/unicode import runes, Rune, `$`

import ../agent_harbor/ah_tui_stories
import ../../styles/generated/design_tokens

const ExpectedAssertions = 17

const Modes = [dmDark, dmLight]

var countedAssertions = 0
template ck(cond: untyped) =
  inc countedAssertions
  check cond

proc isBoxDrawing*(s: string): bool =
  for r in s.runes:
    if int(r) >= 0x2500 and int(r) <= 0x257F: return true

proc frameProblems*(rows: seq[string]): seq[string] =
  ## ASCII frames: a run of 3+ `-`/`=`/`+` closed by `+` or `|`, or a column
  ## of `|` two rows deep.
  var grid: seq[seq[string]]
  for line in rows:
    var cells: seq[string]
    for r in line.runes: cells.add $r
    grid.add cells
  for ri, cells in grid:
    var c = 0
    while c < cells.len:
      if cells[c] in ["-", "=", "+"]:
        var e = c
        while e < cells.len and cells[e] in ["-", "=", "+"]: inc e
        let closed = (c > 0 and cells[c - 1] in ["+", "|"]) or
                     (e < cells.len and cells[e] in ["+", "|"]) or
                     cells[c] == "+" or cells[e - 1] == "+"
        if e - c >= 3 and closed:
          return @["an ASCII frame line at row " & $ri & ", columns " & $c & "-" & $(e - 1)]
        c = e
      else: inc c
  for ri in 0 ..< grid.len - 1:
    for c in 0 ..< min(grid[ri].len, grid[ri + 1].len):
      if grid[ri][c] == "|" and grid[ri + 1][c] == "|":
        return @["an ASCII frame column at column " & $c & ", rows " & $ri & "-" & $(ri + 1)]

proc ownerGrid(c: AhCanvas): seq[seq[int]] =
  ## Each cell's area: the last one recorded over it (-1 for none).
  result = newSeq[seq[int]](c.rows)
  for r in 0 ..< c.rows:
    result[r] = newSeq[int](c.cols)
    for x in result[r].mitems: x = -1
  for i, a in c.areas:
    for r in max(0, a.row) ..< min(c.rows, a.row + a.height):
      for col in max(0, a.col) ..< min(c.cols, a.col + a.width):
        result[r][col] = i

proc areaProblems*(c: AhCanvas): seq[string] =
  ## Two neighbouring cells of different areas on one ground, or an area
  ## whose edge is not on the ground it declared.
  let owner = ownerGrid(c)
  for r in 0 ..< c.rows:
    for col in 0 ..< c.cols:
      let a = owner[r][col]
      if a < 0: continue
      for (dr, dc) in [(0, 1), (1, 0)]:
        let r2 = r + dr
        let c2 = col + dc
        if r2 >= c.rows or c2 >= c.cols: continue
        let b = owner[r2][c2]
        if b < 0 or b == a: continue
        if c.bgAt(r, col) == c.bgAt(r2, c2):
          return @["the " & c.areas[a].name & " at (" & $r & "," & $col & ") and the " &
                   c.areas[b].name & " at (" & $r2 & "," & $c2 & ") share the ground " &
                   c.bgAt(r, col)]
  # Every area's edge cells that it still owns are on its declared ground,
  # except where a control or a highlight is painted on it.
  for i, a in c.areas:
    var own, onGround = 0
    for r in max(0, a.row) ..< min(c.rows, a.row + a.height):
      for col in max(0, a.col) ..< min(c.cols, a.col + a.width):
        let edge = r == a.row or r == a.row + a.height - 1 or col == a.col or
                   col == a.col + a.width - 1
        if not edge or owner[r][col] != i: continue
        inc own
        if c.bgAt(r, col) == a.bg: inc onGround
    if own > 0 and onGround * 2 < own:
      result.add "the " & a.name & " at (" & $a.row & "," & $a.col & ") declares " & a.bg &
                 " but most of its edge is on other grounds"

proc timelineLineProblems*(c: AhCanvas): seq[string] =
  ## The session activity timeline is cardless: every cell of every drawn
  ## line is on the ground of the timeline's own area (`timeline`), so no
  ## line is set apart by a ground of its own; only the focus bar `▎`
  ## differs, and by its ink, not its ground.
  var ground = ""
  for a in c.areas:
    if a.name == "timeline": ground = a.bg
  if ground.len == 0: return
  for line in c.root.all("line"):
    for r in line.row ..< min(c.rows, line.row + max(1, line.height)):
      for col in line.col ..< min(c.cols, line.col + line.width):
        if c.bgAt(r, col) != ground:
          return @["the timeline line " & line.attr("line") & " at (" & $r & "," & $col &
                   ") is on " & c.bgAt(r, col) & ", not the timeline's ground " & ground]

const CardlessRowFacts = ["card", "test", "vcs-row", "item"]
  ## CTF-P3's rows: a spec card, a test, a Code tab file, an inbox row.

proc cardlessRowProblems*(c: AhCanvas): seq[string] =
  ## Each CTF-P3 row is one ground down both its edges (the cells it draws
  ## at its first and last column, on every row it spans that is on the
  ## screen): a row framed by another ground at an edge is a box.
  for fact in CardlessRowFacts:
    for n in c.root.all(fact):
      if n.row >= c.rows or n.width < 2: continue
      let ground = c.bgAt(n.row, n.col)
      for r in n.row ..< min(c.rows, n.row + max(1, n.height)):
        for col in [n.col, n.col + n.width - 1]:
          if c.bgAt(r, col) != ground:
            return @["the " & fact & " " & n.attr(fact) & " at (" & $r & "," & $col & ") is on " &
                     c.bgAt(r, col) & ", its first cell on " & ground]

let section = agentHarborSection()

proc storyProblems(story: CodeTracerStory; cols, rows: int; mode: DesignMode): seq[string] =
  let m = mountStory(story, cols, rows, mode)
  defer: m.dispose()
  var lines: seq[string]
  for r in 0 ..< m.rows: lines.add m.canvas.grid.rowText(r)
  for ri, line in lines:
    if isBoxDrawing(line):
      result.add "a box-drawing glyph on row " & $ri & ": " & line.strip
      break
  result.add frameProblems(lines)
  result.add areaProblems(m.canvas)
  result.add timelineLineProblems(m.canvas)
  result.add cardlessRowProblems(m.canvas)

suite "CTF-P1b: no box borders between the terminal's Agent Harbor areas":
  test "test_ctf_p1b_tui_no_box_borders_between_areas":
    ck section.stories.len >= 59
    var failures: seq[string]
    var checked = 0
    for story in section.stories:
      let id = storybookId(section, story)
      for (sizeName, cols, rows) in sizesOf(story.surface):
        for mode in Modes:
          let problems = storyProblems(story, cols, rows, mode)
          inc checked
          if problems.len > 0:
            failures.add captureIdOf(id, sizeName, if mode == dmDark: "dark" else: "light") &
                         ": " & problems.join("; ")
    if failures.len > 0:
      echo "Story renderings with a border, or areas on one ground (" & $failures.len &
        "):\n  " & failures.join("\n  ")
    ck failures.len == 0
    var wanted = 0
    for story in section.stories: wanted += sizesOf(story.surface).len * Modes.len
    ck checked == wanted
    echo "  checked ", checked, " story renderings"

  test "the committed snapshots hold no box-drawing glyph":
    let dir = currentSourcePath().parentDir / "snapshots" / "ctf-p1b"
    var found = 0
    var bordered: seq[string]
    for kind, path in walkDir(dir):
      if kind != pcDir: continue
      let plain = path / "plaintext.txt"
      if not fileExists(plain): continue
      inc found
      if isBoxDrawing(readFile(plain)): bordered.add path.extractFilename
    # Every story, size and mode has one (the coverage suite records them).
    var wanted = 0
    for story in section.stories: wanted += sizesOf(story.surface).len * Modes.len
    ck found == wanted
    if bordered.len > 0: echo "  bordered snapshots: " & bordered.join(", ")
    ck bordered.len == 0

suite "CTF-P1b: the checks can fail":
  test "a box border, an ASCII frame and two areas on one ground are each reported":
    ck isBoxDrawing("a \xE2\x94\x80\xE2\x94\x80 b")            # ── U+2500
    ck not isBoxDrawing("a \xE2\x96\x8F b")                    # ▏ U+258F, permitted
    ck frameProblems(@["+----+", "|    |", "+----+"]).len > 0
    var c = newAhCanvas(10, 4, ahPalette(dmDark))
    c.area("top", 0, 0, 10, 2, c.tone.body)
    c.area("bottom", 2, 0, 10, 2, c.tone.body)
    ck areaProblems(c).len > 0

  test "a timeline line on a ground of its own is reported, the focus bar is not":
    # The session activity timeline's area rule: its lines on the
    # timeline's ground. One line repainted on the card surface is a box;
    # the focus bar, an ink on the same ground, is not.
    let story = block:
      var found: CodeTracerStory
      for s in section.stories:
        if s.surface == "agent-harbor-session-activity" and s.fixture == "focused": found = s
      found
    let m = mountStory(story, 95, 40, dmDark)
    defer: m.dispose()
    ck timelineLineProblems(m.canvas).len == 0
    let line = m.canvas.root.first("line")
    ck line != nil
    for col in line.col ..< line.col + line.width:
      discard m.canvas.put(line.row, col, " ", m.canvas.p.textBody, bg = m.canvas.p.menu)
    ck timelineLineProblems(m.canvas).len > 0

  test "a CTF-P3 row framed by a ground of its own is reported, the inset bar is not":
    # An open spec card carries the action bar `▎` down its left edge (an
    # ink on the card's ground): not reported. Its right edge repainted on
    # the card surface frames it: reported.
    let story = block:
      var found: CodeTracerStory
      for s in section.stories:
        if s.surface == "agent-harbor-changes" and s.fixture == "spec-changes": found = s
      found
    let m = mountStory(story, 95, 40, dmDark)
    defer: m.dispose()
    ck cardlessRowProblems(m.canvas).len == 0
    var open: AhNode
    for card in m.canvas.root.all("card"):
      if card.attr("open") == "true" and open.isNil: open = card
    ck open != nil
    for r in open.row ..< min(m.rows, open.row + open.height):
      discard m.canvas.put(r, open.col + open.width - 1, " ", m.canvas.p.textBody,
                           bg = m.canvas.p.menu)
    ck cardlessRowProblems(m.canvas).len > 0

suite "CTF-P1c: an ended mark and word keep their contrast on every surface":
  # The ended role is grey, and grey has no hue to fall back on: on Light's
  # active tab icon-subtle measured 1.42:1, and the caption-coloured
  # `completed` 2.59:1 on Light's raised row. The palette all three hosts
  # resolve (`agent_harbor_palette`, and `agent_harbor.styl` for the web)
  # must keep an ended session's and an ended initiative's mark at 3:1 (WCAG
  # 1.4.11, https://www.w3.org/TR/WCAG21/#non-text-contrast) and an ended
  # session's status word at 4.5:1 (WCAG 1.4.3,
  # https://www.w3.org/TR/WCAG21/#contrast-minimum) on every surface a mark
  # or a row sits on, in both modes.
  test "the ended mark at 3:1 and the ended word at 4.5:1, Dark and Light":
    var problems: seq[string]
    for mode in Modes:
      let p = ahPalette(mode)
      let t = p.tone
      let surfaces = [("the window", p.ground), ("the panel", p.panel),
                      ("the active tab", p.activeTab), ("the active row", p.activeRow),
                      ("a row band", t.band), ("a hovered row", p.hover),
                      ("a group header", t.group[0]), ("a group header", t.group[1]),
                      ("a menu", p.menu)]
      for (name, ground) in surfaces:
        for (what, ink) in [("session", p.markOf(saEnded).colour),
                            ("initiative", p.markOf(isEnded).colour)]:
          let ratio = contrastOf(ink, ground)
          if ratio < 3.0:
            problems.add $mode & ": an ended " & what & "'s mark " & ink & " on " & name &
              " " & ground & " is " & formatFloat(ratio, ffDecimal, 2) & ":1"
        let word = p.statusWordColour(saEnded)
        let ratio = contrastOf(word, ground)
        if ratio < 4.5:
          problems.add $mode & ": the ended word " & word & " on " & name & " " & ground &
            " is " & formatFloat(ratio, ffDecimal, 2) & ":1"
    for problem in problems: echo "  ", problem
    ck problems.len == 0

  test "the web's ended rules resolve to the colours held above":
    # The web does not read the palette: its marks and words come from
    # `agent_harbor.styl`. Each ended rule's colour, a design token or
    # `by-mode(<dark token>, <light token>)`, must resolve in each mode to
    # the palette's ended colour the case above holds to its contrast, so the
    # web cannot keep the grey that fell to 1.42:1 while the native hosts
    # move on.
    let styl = readFile(currentSourcePath().parentDir.parentDir.parentDir /
                        "styles" / "components" / "agent_harbor.styl").splitLines

    proc tokenNamed(name: string): (bool, DesignToken) =
      ## The design token a stylesheet name spells (`colors-ui-icon-…` is
      ## `colors/ui/icon/…`).
      for t in DesignToken:
        if ($t).replace('/', '-') == name: return (true, t)

    proc declaration(selector, property: string): string =
      ## The value of `property` in the rule whose selector list starts with
      ## the line `selector`; "" when there is none.
      for i, line in styl:
        if line != selector: continue
        var j = i + 1
        while j < styl.len and styl[j].len > 0 and styl[j][0] != ' ': inc j
        while j < styl.len and styl[j].startsWith("  "):
          let d = styl[j].strip
          if d.startsWith(property & ":"): return d[property.len + 1 .. ^1].strip
          inc j
        return ""

    var problems: seq[string]
    var resolved = 0
    for (selector, property, word) in [
        (".ah-tab-mark", "background", false),
        (".ah-ist-ended > .ah-tab-mark,", "background", false),
        # The fleet's rows draw the progress pie (CTF-P1d), whose inks the
        # pie's own unit test holds (`test_agent_harbor_pie`): no ended mark.
        (".ah-att-ended .ah-session-row-status", "color", true)]:
      let value = declaration(selector, property)
      var names = @[value, value]
      if value.startsWith("by-mode(") and value.endsWith(")"):
        names = value["by-mode(".len ..< value.high].split(',')
        for n in names.mitems: n = n.strip
      if names.len != 2:
        problems.add selector & ": " & property & " '" & value & "' is not one token or by-mode of two"
        continue
      for k, mode in Modes:
        let (known, token) = tokenNamed(names[k])
        let p = ahPalette(mode)
        let want = if word: p.statusWordColour(saEnded) else: p.markOf(saEnded).colour
        if not known:
          problems.add selector & ": '" & names[k] & "' is not a design token"
        elif tokenHexOf(token, mode) != want:
          problems.add $mode & ": " & selector & " resolves to " & tokenHexOf(token, mode) &
            " (" & names[k] & "), the palette's ended colour is " & want
        else: inc resolved
    for problem in problems: echo "  ", problem
    ck problems.len == 0 and resolved == 6

suite "CTF-P1b: assertion count":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
