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
## No mocks: the real isonim-gpui shadow tree (the shim loaded in process, no
## window) and the results stories' own viewmodels over their scripted
## providers and Agent Harbor source.

import std/[json, os, sequtils, strutils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
from ../chrome import MonoFontFamily
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
