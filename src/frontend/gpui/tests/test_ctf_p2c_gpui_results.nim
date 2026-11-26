## CTF-P2c step 2: the GPUI omnibox result commands' presses and keys are
## routed (study D48; Input-Routing-And-Keymaps.md §4 and §5.1), in the
## story host that mounts them (`gpui/agent_harbor/ah_stories.nim`), and the
## field has the sheet's edges (D36).
##
## * **A press is routed**: every row carries `results.open` and its index,
##   `+N more` `results.more` and its group, `← All providers`
##   `results.all`; a press-down on it is resolved by the story host's
##   router in the `results` scope and run on the viewmodel, and the view
##   redraws from it.
## * **A key is routed**: `Down` / `Up` move the selection, `Enter` opens,
##   `Tab` inserts a completion, through `resultsKey`.
##
## * **Every region the web record holds is drawn** (issue
##   2026-11-24-gpui-omnibox-control-center-and-gaze-captures-fail-the-ctf-p1b-layout-gate):
##   for every results story, at the laptop and sidebar sizes and in both
##   themes, each region the committed web layout record
##   (`agent-harbor-web-regions.json`) holds for its capture is found in the
##   GPUI tree by the region's declared GPUI facts
##   (`agent-harbor-regions.json`, matched as the story window's region dump
##   matches them), and no region the record lacks is. The omnibox field once
##   carried no `data-ah-field-row`, so every window capture reported
##   `composer-field` "drawn only on web"; and a result row's selection was
##   the `data-ah-selected` the fleet's `selected-row` region reads, so the
##   selected result was "drawn only on gpui".
##
## * **A line of program text keeps the web's gap from where it is**: at the
##   laptop size, every code row's drawn line -- its characters at Space
##   Mono's own advances, read from the design system's font files, its
##   matches at the Bold face's -- ends at
##   least the web's 16px (`.ah-results-row-line`'s 0.5rem gap and
##   `.ah-results-title-code`'s 0.5rem margin) before its location, and at
##   least the margin before the line's end where nothing stands there. The
##   line's width is the web's geometry (the sheet's hairlines, the row's
##   1px margins and 12px paddings), not the view's own constants, and the
##   location's is the interface face's measure the view lays it out by.
## * **The sheet draws every part whose words fit above `More below ↓`**:
##   where a body holds more than its room, the ground left above the
##   line's hairline is less than the next part needs for what it
##   shows, and no drawn part shows anything under the hairline (only a
##   row's 5px bottom padding and its last line's leading may stand there,
##   as the web's rows scroll under that sticky line).
## * **A notice breaks between words only** (an API path is
##   never broken at a slash): each drawn line of `Agent Harbor is not
##   reachable: GET /api/v1/input-commands …` holds whole words.
##
## No mocks: the real isonim-gpui shadow tree (the shim loaded in process, no
## window) and the results stories' own viewmodels over their scripted
## providers and Agent Harbor source.

import std/[json, os, sequtils, strutils, unittest]
from std/unicode import runeLen

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
from ../chrome import MonoFontFamily
from ../agent_harbor/ah_theme import textPx, CaptionPx, BodyPx
from ../agent_harbor/ah_changes_inbox_parts import MonoAdvance, MonoBoldAdvance
from ../../viewmodel/input/element_press import OperationAttribute
import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ../../../tests/visual/agent_harbor/ctf_layout_judge

let r = GpuiRenderer()

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc carrying(root: GpuiElement; operation: string): seq[GpuiElement] =
  var all: seq[GpuiElement]
  collect(root, OperationAttribute, all)
  all.filterIt(getAttribute(it, OperationAttribute) == operation)

proc facts(root: GpuiElement; name: string): seq[string] =
  var all: seq[GpuiElement]
  collect(root, "data-ah-" & name, all)
  all.mapIt(getAttribute(it, "data-ah-" & name))

proc mount(fixture: string; width = 1440; height = 900): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-results", fixture, width, height, dmDark)

suite "CTF-P2c: the GPUI results' presses are routed":
  test "every row carries results.open and its index; +N more its group":
    # A window tall enough for every row: the sheet draws the rows that fit
    # its body (the wrapped lines of the program's text make them tall).
    let m = mount("search-final", height = 2000)
    let rows = m.view.carrying(ResultsOpenOperation)
    check rows.len == m.results.selectableRows.len
    for i, e in rows: check getAttribute(e, ResultsTargetAttribute) == $i
    check m.view.carrying(ResultsMoreOperation).mapIt(getAttribute(it, ResultsTargetAttribute)) ==
          @["symbols", "program-text"]
    m.dispose()

  test "+N more shows the group alone; the way back shows every group":
    let m = mount("search-long")
    fireEvent(m.view.carrying(ResultsMoreOperation)[0], "mousedown")
    check m.results.alone.val == "program-text"
    check m.view.facts("group") == @["program-text"]
    fireEvent(m.view.carrying(ResultsAllOperation)[0], "mousedown")
    check m.results.alone.val == ""
    check m.view.facts("group").len == m.results.groups.len
    check m.results.groups.len > 1
    m.dispose()

  test "a press on a row opens it":
    let m = mount("search-final")
    fireEvent(m.view.carrying(ResultsOpenOperation)[0], "mousedown")
    check m.results.openedLine == "Opened src/shield.nr"
    check m.view.facts("header") == @["Opened src/shield.nr"]
    m.dispose()

suite "CTF-P2c: the GPUI results' keys are routed":
  test "Down and Up move the selection, Enter opens, Tab inserts":
    let m = mount("search-final")
    check m.resultsKey("Down") == ResultsNextOperation
    check m.results.selected.val == 1
    check m.resultsKey("Up") == ResultsPreviousOperation
    check m.results.selected.val == 0
    check m.resultsKey("Enter") == ResultsOpenOperation
    check m.results.openedLine == "Opened src/shield.nr"
    check m.resultsKey("x") == ""
    m.dispose()
    let c = mount("at-completion")
    check c.resultsKey("Tab") == ResultsInsertOperation
    check c.results.input == "/ai Run drained_field_fails again with @Claude "
    c.dispose()

suite "CTF-P2c: the field has the sheet's edges (D36)":
  test "the field is as wide as the sheet, at laptop and sidebar width":
    for width in [1440, 360]:
      let m = mount("at-completion", width)
      var fields, sheets: seq[GpuiElement]
      collect(m.view, "data-ah-field", fields)
      collect(m.view, "data-ah-sheet", sheets)
      check fields.len == 1 and sheets.len == 1
      check getAttribute(fields[0], "data-ah-field") == m.results.input
      check m.results.sheetWidthFor(width) == min(640, width - 16)
      m.dispose()

suite "CTF-P2c: manager note 132's follow-ups in GPUI (D60-D63)":
  test "the empty providers are one line after the groups, and no group":
    let m = mount("search-failed")
    check m.view.facts("empty-providers") == @["No matches in Files"]
    check "files" notin m.view.facts("group")
    m.dispose()

  test "a matched line is one line, the match whole":
    for width in [1440, 360]:
      let m = mount("search-group", width)
      var titles: seq[GpuiElement]
      collect(m.view, "data-ah-title-shown", titles)
      check titles.len > 0
      for t in titles:
        check "remaining" in getAttribute(t, "data-ah-title-shown").toLowerAscii
        check getAttribute(t, "data-ah-title-shown").count("\xE2\x80\xA6") <= 2
      m.dispose()

  test "a matched line of the program's text is set in the code face":
    # The brief: "a line of the program's text is set in the code face" (the
    # web's `.ah-results-title-code`, Space Mono). Every run of a code row's
    # title -- the matches and the text around them -- is in Space Mono, at
    # every width; its control, a row that is not code (a file's title), is
    # in the window's face (GPUI review of 2026-11-25: the program text was
    # in the body face).
    for width in [1440, 360]:
      let m = mount("search-final", width, height = 2000)
      let plan = parseJson(renderPlanJson(r, m.root))
      var code, other: seq[string]
      proc walk(n: JsonNode; inCode, inRow: bool) =
        let attrs = n{"attributes"}
        let isCode = inCode or (attrs.kind == JObject and attrs{"data-ah-face"}.getStr == "code")
        let isRow = inRow or (attrs.kind == JObject and attrs{"data-ah-kind"}.getStr.len > 0)
        let family = n{"styles"}{"font_family"}.getStr
        # Every run of text (`ah_theme.text`) names its face.
        if family.len > 0:
          if isCode: code.add family
          elif isRow: other.add family
        for c in n{"children"}.getElems: walk(c, isCode, isRow)
      walk(plan, false, false)
      checkpoint "width " & $width & ": code " & $code & ", other " & $other
      check code.len > 0
      check code.allIt(it == MonoFontFamily)
      check other.len > 0
      check other.allIt(it != MonoFontFamily)
      m.dispose()

  test "the selected row is on the editor's selection ground":
    for mode in [dmDark, dmLight]:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui("agent-harbor-results", "search-final", 1440, 900, mode)
      check m.view.facts("selected-ground") ==
            @[DesignTokenHex[dtColorsEditorSurfaceSelect][mode]]
      m.dispose()

# ---------------------------------------------------------------------------
# The regions the window capture is judged on
# ---------------------------------------------------------------------------

proc matchesFacts(el: GpuiElement; facts: JsonNode): bool =
  ## The story window's region match (`ah_story_window.matches`): every
  ## declared `data-ah-*` attribute present, with its value when one is given.
  for attr, want in facts.pairs:
    let have = getAttribute(el, attr)
    if have.len == 0 or (want.getStr.len > 0 and have != want.getStr): return false
  true

proc anyMatching(node: GpuiElement; facts: JsonNode): bool =
  if node.isNil: return false
  if node.matchesFacts(facts): return true
  for i in 0 ..< childCount(node):
    if anyMatching(nthChild(node, i), facts): return true
  false

suite "CTF-P1b: a results story draws the regions the web draws, and no others":
  test "each region of every results story is matched by its GPUI facts exactly when the web has it":
    let regionsDir = repoRoot / "src" / "tests" / "visual"
    let record = loadWebRecord(regionsDir / "agent-harbor-web-regions.json")
    var declared: seq[(string, JsonNode)]
    for region in parseJson(readFile(regionsDir / "agent-harbor-regions.json"))["regions"]:
      declared.add (region["name"].getStr, region["gpui"])
    var stories, compared = 0
    var problems: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-results": continue
      inc stories
      let sid = storybookId(agentHarborSection(), story)
      for (size, w, h) in Sizes:
        for (mode, theme) in [(dmDark, "dark"), (dmLight, "light")]:
          let id = ViewPrefix & sid[StoryIdPrefix.len .. ^1] & "-" & size & "-" & theme
          let web = record{id}{"regions"}
          if web.isNil:
            problems.add id & ": the web record has no capture"
            continue
          gpui_reset_tree()
          let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, mode)
          for (name, facts) in declared:
            inc compared
            let drawn = m.root.anyMatching(facts)
            if web.hasKey(name) and not drawn:
              problems.add id & ": region " & name & " is drawn only on web"
            elif drawn and not web.hasKey(name):
              problems.add id & ": region " & name & " is drawn only on gpui"
          m.dispose()
    for p in problems: checkpoint p
    check stories == 18
    check compared > 0
    check problems.len == 0

proc firstWith(node: GpuiElement; name: string): GpuiElement =
  var all: seq[GpuiElement]
  collect(node, name, all)
  if all.len > 0: all[0] else: nil

suite "CTF-P1b: a results story's sheet is as tall as the web's":
  test "every results story's sheet has the web's top and height, both sizes":
    # Every line of the web's results inherits the sheet's 24px; a row is
    # its 5px paddings around its line, a group its head's line and 0.25rem
    # paddings, the body ends with its last part's 0.5rem, and a body taller
    # than the window's room is the sheet's `max-height`. The GPUI sheet was
    # laid out on 16px lines and stopped up to 99px short (issue
    # 2026-11-24-gpui-omnibox-control-center-and-gaze-captures-fail-the-ctf-p1b-layout-gate).
    let record = loadWebRecord(repoRoot / "src" / "tests" / "visual" /
                               "agent-harbor-web-regions.json")
    var compared = 0
    var problems: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-results": continue
      let sid = storybookId(agentHarborSection(), story)
      # The web story GPUI's drawing is judged against (the judge's own
      # pairing: the rich rows are the web's text form, `GpuiDrawsAs`).
      var name = sid[StoryIdPrefix.len .. ^1]
      for (gpui, web) in GpuiDrawsAs:
        if name == gpui: name = web
      for (size, w, h) in Sizes:
        let id = ViewPrefix & name & "-" & size & "-dark"
        let web = record{id}{"regions"}{"composer-sheet"}
        if web.isNil:
          problems.add id & ": the web record has no composer-sheet"
          continue
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, dmDark)
        let sheet = m.view.firstWith("data-ah-sheet-height")
        if sheet.isNil:
          problems.add id & ": no sheet drawn"
        else:
          inc compared
          let top = parseFloat(getAttribute(sheet, "data-ah-sheet-top"))
          let height = parseFloat(getAttribute(sheet, "data-ah-sheet-height"))
          if abs(top - web["y"].getFloat) > PxTolerance:
            problems.add id & ": sheet top " & $top & ", the web's " & $web["y"].getFloat
          if abs(height - web["h"].getFloat) > PxTolerance:
            problems.add id & ": sheet height " & $height & ", the web's " & $web["h"].getFloat
        m.dispose()
    for p in problems: checkpoint p
    check compared == 36
    check problems.len == 0

# ---------------------------------------------------------------------------
# A line of program text and where it is
# ---------------------------------------------------------------------------

proc fontAdvanceEm(file: string): float =
  ## Space Mono's one advance, in ems, read from the design system's font
  ## file itself (the OpenType `head`, `hhea` and `hmtx` tables,
  ## https://learn.microsoft.com/typography/opentype/spec/hmtx): the widest
  ## advance (`hhea.advanceWidthMax`) over the units per em, after checking
  ## that every glyph that advances advances by exactly that (a monospaced
  ## face). 0.0 when the file is not such a face.
  let d = readFile(repoRoot / "libs" / "codetracer-design-system" / "SpaceGrotesk_Complete" /
                   "Fonts" / "Space_Mono" / file)
  proc u16(o: int): int = (ord(d[o]) shl 8) or ord(d[o + 1])
  proc u32(o: int): int = (u16(o) shl 16) or u16(o + 2)
  var head, hhea, hmtx = -1
  for i in 0 ..< u16(4):
    let rec = 12 + 16 * i
    case d[rec ..< rec + 4]
    of "head": head = u32(rec + 8)
    of "hhea": hhea = u32(rec + 8)
    of "hmtx": hmtx = u32(rec + 8)
    else: discard
  if head < 0 or hhea < 0 or hmtx < 0: return 0.0
  let advance = u16(hhea + 10)
  for g in 0 ..< u16(hhea + 34):
    let a = u16(hmtx + 4 * g)
    if a != 0 and a != advance: return 0.0
  advance / u16(head + 18)

const
  WebCodeGapPx = 8 + 8
    ## The web's room between a line of program text and where it is:
    ## `.ah-results-row-line { gap: 0.5rem }` and `.ah-results-title-code
    ## { margin-right: 0.5rem }` (agent_harbor_results.styl).
  WebCodeMarginPx = 8
    ## The code title's own margin, kept where nothing stands after it.
  WebRowEdgesPx = 2 + 2 + 2 * 12
    ## A row's line is the sheet less its two hairlines, the row's 1px
    ## margins and its 12px paddings (`.ah-results-row`).

proc drawnCodePx(title: GpuiElement; regular, bold: float): float =
  ## How wide `title` (a code row's line, `data-ah-face="code"`) draws: every
  ## run at Space Mono's advance at the body size, the matches (`data-ah-match`)
  ## at the Bold face's.
  var matched: seq[GpuiElement]
  collect(title, "data-ah-match", matched)
  var boldChars = 0
  for m in matched: boldChars += getAttribute(m, "data-ah-match").runeLen
  let all = getAttribute(title, "data-ah-title-shown").runeLen
  float(BodyPx) * (float(all - boldChars) * regular + float(boldChars) * bold)

suite "CTF-P2c: a line of program text keeps the web's gap from where it is":
  test "the views measure Space Mono at the font files' own advances":
    let regular = fontAdvanceEm("SpaceMono-Regular.ttf")
    let bold = fontAdvanceEm("SpaceMono-Bold.ttf")
    checkpoint "Regular " & $regular & ", Bold " & $bold
    check regular > 0.0 and bold > 0.0
    check abs(MonoAdvance - regular) < 1e-9
    check abs(MonoBoldAdvance - bold) < 1e-9

  test "every code row's drawn line ends the web's gap before its location":
    let regular = fontAdvanceEm("SpaceMono-Regular.ttf")
    let bold = fontAdvanceEm("SpaceMono-Bold.ttf")
    var rowsSeen, besideLocation = 0
    var problems: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-results": continue
      for (w, h) in [(1440, 900), (1440, 2000), (360, 900)]:
        for mode in [dmDark, dmLight]:
          gpui_reset_tree()
          let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, mode)
          let lineW = float(m.results.sheetWidthFor(w) - WebRowEdgesPx)
          var rows: seq[GpuiElement]
          collect(m.view, "data-ah-row", rows)
          for row in rows:
            var titles, locations, tags: seq[GpuiElement]
            collect(row, "data-ah-title-shown", titles)
            if titles.len == 0: continue
            inc rowsSeen
            collect(row, "data-ah-location", locations)
            collect(row, "data-ah-tag", tags)
            let drawn = drawnCodePx(titles[0], regular, bold)
            # Where the line's right-hand parts start, from its end: the
            # tag, the row's gap and the location (`margin-left: auto`
            # pushes them to the end; the view lays the location out at the
            # interface face's measure). Only beside the title: at the
            # sidebar size they are on the line under it.
            let beside = not m.results.isNarrow(w) and (locations.len > 0 or tags.len > 0)
            var rightPx = 0.0
            if beside:
              inc besideLocation
              if locations.len > 0:
                rightPx += float(textPx(getAttribute(locations[0], "data-ah-location"), CaptionPx))
              if tags.len > 0:
                rightPx += float(textPx(getAttribute(tags[0], "data-ah-tag"), CaptionPx))
                if locations.len > 0: rightPx += 8.0
            let room = lineW - rightPx - (if beside: float(WebCodeGapPx) else: float(WebCodeMarginPx))
            if drawn > room:
              problems.add story.fixture & " " & $w & "x" & $h & " " & $mode & ": `" &
                getAttribute(titles[0], "data-ah-title-shown") & "` draws " & $drawn &
                "px where " & $room & "px leave the web's gap"
          m.dispose()
    for p in problems: checkpoint p
    check rowsSeen > 0
    check besideLocation > 0
    check problems.len == 0

suite "CTF-P2c: the sheet draws every part whose words fit above More below":
  test "the ground above More below is less than the next part shows":
    var sheets = 0
    var problems: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-results": continue
      for (w, h) in [(1440, 900), (360, 900)]:
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, dmDark)
        let sheet = m.view.firstWith("data-ah-more-room")
        if not sheet.isNil:
          inc sheets
          let free = parseInt(getAttribute(sheet, "data-ah-more-room"))
          let next = parseInt(getAttribute(sheet, "data-ah-more-next"))
          let id = story.fixture & " " & $w & "x" & $h
          # Nothing a drawn part shows stands under the hairline: only a
          # row's 5px bottom padding and its last line's leading may (at
          # most 4px: a caption on the sheet's 24px line).
          if free < -(5 + 4): problems.add id & ": a drawn part runs " & $(-free) & "px under the line"
          # And the next part would not fit: what it shows is taller than
          # the ground left.
          if next > 0 and next <= free:
            problems.add id & ": " & $free & "px left above the line, where the next part needs " &
              $next & "px"
        m.dispose()
    for p in problems: checkpoint p
    check sheets > 0
    check problems.len == 0

suite "CTF-P2c: a notice breaks between words only":
  test "the unreachable notice keeps its API path whole":
    for (w, h) in [(1440, 900), (360, 900)]:
      let m = mount("ah-unreachable", w, h)
      let lines = m.view.facts("notice-lines")
      check lines.len == 1
      let text = m.view.facts("notice-line")[0]
      let drawn = lines[0].split("\n")
      checkpoint $w & ": " & $drawn
      # Every drawn line is whole words of the notice, and together they are
      # the notice.
      check drawn.join(" ") == text.splitWhitespace.join(" ")
      check drawn.anyIt("/api/v1/input-commands" in it)
      m.dispose()
