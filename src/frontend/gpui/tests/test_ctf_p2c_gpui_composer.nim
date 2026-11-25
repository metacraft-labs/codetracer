## CTF-P2c (P2c-G): the GPUI omnibox composer's presses and keys are routed
## (study D31; Input-Routing-And-Keymaps.md §4 and §5.1), in the story host
## that mounts it (`gpui/agent_harbor/ah_stories.nim`).
##
## * **A press is routed**: every element a press acts on carries its
##   operation (`data-ct-operation`) and its target (`data-ah-target`); a
##   press-down on it is resolved by the story host's router in the
##   `composer` scope and run on the viewmodel, and the view redraws from it
##   (a chip is cited, `+` opens the menu, `Send to …` sends again, the send
##   button sends).
## * **A key is routed**: `Down` / `Up` move the destination and `Enter`
##   sends, through `composerKey`.
##
## * **The sheet is laid out as the web's** (P2c-G): every composer story,
##   at the laptop and sidebar sizes and in both themes, plans its sheet at
##   the top and the height the web's layout record holds for it
##   (`agent-harbor-web-regions.json`, `composer-sheet`), within the layout
##   judge's pixel tolerance (`ctf_layout_judge.PxTolerance`). It needs no
##   window: the sheet carries the top and height it was laid out at
##   (`data-ah-sheet-top`, `data-ah-sheet-height`). It is what catches a
##   line pitch other than the web's, a body that drops what it cannot show
##   whole instead of clipping it as the web's scrollport does, and a wrap
##   decided on other widths than the window sets.
## * **A wrapping row is as tall as it is drawn**: every row of chips or
##   toggles packs its items into the number of lines its part was sized
##   for (`data-ah-flow-lines`, counted by the same `flowLineStarts` that
##   packs it).
## * **The composer's parts take the web's styles**: read off
##   the render plan the window draws from, in both themes. The omnibox field
##   on the primary surface's ground with the inputs' hairline, at the web's top, its
##   text clipped inside its padding; every form field's hairline and its
##   value on the box's line; a context item the instruction left out struck
##   through in the caption-subtle ink; the section labels, row titles and state
##   words in the face's Medium with the labels' tracking, and nothing in the
##   composer semibold; the add-context menu's rows on the dropdown rows'
##   ground; the `+` control as wide as the web lays it out. The values are
##   the design-system roles the web stylesheet names, measured in the
##   browser's computed styles (`agent_harbor_composer.styl`).
## * **A left-out context item reads dimmer than an offered one** (manager
##   note 122): in both themes its ink's contrast on the sheet is well under
##   an offered chip's, so struck through it also recedes. In Light the
##   disabled role it had is no dimmer than the offered chips' caption.
## * **A form field is one line** (the P2c study's D35): a value wider than
##   its field is cut in its middle, keeping at most its first 8 characters
##   and as much of its end as fits, so the plan file keeps its file name; a
##   value that fits is whole.
##
## No mocks: the real isonim-gpui shadow tree (the shim loaded in process, no
## window) and the composer stories' own viewmodels over their scripted
## router and action source; the web side is the committed layout record the
## window captures are judged against.

import std/[json, math, os, sequtils, strutils, tables, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
from ../../viewmodel/input/element_press import OperationAttribute
import ../../stories/codetracer_stories
import ../../../../tools/stories/emit_storybook_stories
import ../../../tests/visual/agent_harbor/ctf_layout_judge
from ../../viewmodel/views/cut_text_rules import danglesAroundEllipsis

let r = GpuiRenderer()

proc collect(node: GpuiElement; name: string; into: var seq[GpuiElement]) =
  if node.isNil: return
  if getAttribute(node, name).len > 0: into.add node
  for i in 0 ..< childCount(node): collect(nthChild(node, i), name, into)

proc carrying(root: GpuiElement; operation: string): seq[GpuiElement] =
  var all: seq[GpuiElement]
  collect(root, OperationAttribute, all)
  all.filterIt(getAttribute(it, OperationAttribute) == operation)

proc mount(fixture: string): AhStoryMount =
  gpui_reset_tree()
  r.mountAgentHarborStoryGpui("agent-harbor-composer", fixture, 1440, 900, dmDark)

suite "CTF-P2c: the GPUI composer's presses are routed":
  test "every pressable element carries its operation and its target":
    let m = mount("typing")
    for op in [ComposerCiteOperation, ComposerAddContextOperation, ComposerSendOperation]:
      check m.view.carrying(op).len >= 1
    for chip in m.view.carrying(ComposerCiteOperation):
      check getAttribute(chip, ComposerTargetAttribute).len > 0
    m.dispose()

  test "a press on a chip cites it through the viewmodel, and the view redraws":
    let m = mount("typing")
    let chip = m.view.carrying(ComposerCiteOperation)[0]
    let id = getAttribute(chip, ComposerTargetAttribute)
    let cited = m.composer.chips.filterIt(it.item.id == id)[0].cited
    fireEvent(chip, "mousedown")
    check m.composer.chips.filterIt(it.item.id == id)[0].cited != cited
    var redrawn: seq[GpuiElement]
    collect(m.view, "data-ah-chip", redrawn)
    let state = redrawn.filterIt(getAttribute(it, "data-ah-chip") == id)[0]
    check getAttribute(state, "data-ah-chip-state") == (if cited: "uncited" else: "cited")
    m.dispose()

  test "+ opens the add-context menu; the send button sends":
    let m = mount("typing")
    fireEvent(m.view.carrying(ComposerAddContextOperation)[0], "mousedown")
    check m.composer.addContextOpen.val
    fireEvent(m.view.carrying(ComposerSendOperation)[0], "mousedown")
    check m.composer.phase in {cpSending, cpSent}
    m.dispose()

  test "Send to … sends again":
    let m = mount("sent")
    let before = m.composer.draft.deliveries.len
    fireEvent(m.view.carrying(ComposerSendAgainOperation)[0], "mousedown")
    check m.composer.draft.deliveries.len == before + 1
    m.dispose()

suite "CTF-P2c: the GPUI composer's keys are routed":
  test "Down and Up move the destination, Enter sends":
    let m = mount("typing")
    let before = m.composer.draft.chosen
    check m.composerKey("Down") == ComposerNextOperation
    check m.composer.draft.chosen != before
    check m.composerKey("Up") == ComposerPreviousOperation
    check m.composer.draft.chosen == before
    check m.composerKey("Enter") == ComposerSendOperation
    check m.composer.phase in {cpSending, cpSent}
    check m.composerKey("x") == ""
    m.dispose()

proc firstWith(node: GpuiElement; name: string): GpuiElement =
  var all: seq[GpuiElement]
  collect(node, name, all)
  if all.len > 0: all[0] else: nil

proc sheetLayoutProblems(record: JsonNode; story: CodeTracerStory; size: string;
                         w, h: int; mode: DesignMode; theme: string): seq[string] =
  ## Where the story's sheet is planned at `w` x `h` against the web record's
  ## `composer-sheet` of the same capture; empty when they agree within
  ## `PxTolerance`.
  let sid = storybookId(agentHarborSection(), story)
  let id = ViewPrefix & sid[StoryIdPrefix.len .. ^1] & "-" & size & "-" & theme
  let web = record{id}{"regions"}{"composer-sheet"}
  if web.isNil: return @[id & ": the web record has no composer-sheet"]
  gpui_reset_tree()
  let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, mode)
  let sheet = m.view.firstWith("data-ah-sheet")
  if sheet.isNil:
    m.dispose()
    return @[id & ": no sheet drawn"]
  let top = parseFloat(getAttribute(sheet, "data-ah-sheet-top"))
  let fieldTop = parseFloat(getAttribute(sheet, "data-ah-field-top"))
  let height = parseFloat(getAttribute(sheet, "data-ah-sheet-height"))
  m.dispose()
  let webField = record{id}{"regions"}{"composer-field"}
  if webField.isNil or abs(fieldTop - webField["y"].getFloat) > 0.5:
    result.add id & ": field top " & $fieldTop & " against the web's " &
               (if webField.isNil: "none" else: $webField["y"].getFloat)
  if abs(top - web["y"].getFloat) > PxTolerance:
    result.add id & ": sheet top " & $top & " against the web's " & $web["y"].getFloat
  if abs(height - web["h"].getFloat) > PxTolerance:
    result.add id & ": sheet height " & $height & " against the web's " & $web["h"].getFloat

suite "CTF-P2c: the GPUI composer's sheet is laid out as the web's":
  test "every composer story's sheet has the web's top and height, both sizes and themes":
    let record = loadWebRecord(repoRoot / "src" / "tests" / "visual" /
                               "agent-harbor-web-regions.json")
    var stories = 0
    var problems: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-composer": continue
      inc stories
      for (size, w, h) in Sizes:
        for (mode, theme) in [(dmDark, "dark"), (dmLight, "light")]:
          problems.add sheetLayoutProblems(record, story, size, w, h, mode, theme)
    for p in problems: checkpoint p
    check stories == 30
    check problems.len == 0

suite "CTF-P2c: the GPUI composer sizes each wrapping row for the lines it draws":
  test "every row of chips or toggles holds as many lines as its part was sized for":
    # A part's height is planned before it is drawn; a row that packs its
    # items into another number of lines than the plan counted leaves an
    # empty line, or draws over the next part.
    var checked = 0
    var problems: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-composer": continue
      for (size, w, h) in Sizes:
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui(story.surface, story.fixture, w, h, dmDark)
        var flows: seq[GpuiElement]
        collect(m.view, "data-ah-flow-lines", flows)
        for f in flows:
          inc checked
          let planned = parseInt(getAttribute(f, "data-ah-flow-lines"))
          if childCount(f) != planned:
            problems.add story.fixture & " " & size & ": " & $childCount(f) &
                         " lines drawn, " & $planned & " planned"
        m.dispose()
    for p in problems: checkpoint p
    check checked > 0
    check problems.len == 0

suite "CTF-P2c: a GPUI form field is one line (D35)":
  const PlanFile = "milestones/2026-11-17-asteroid-fields-generated-from-seeds-end.milestones.org"

  test "a value that fits is whole; a wider one keeps its start and its end":
    check inputValueShown(PlanFile, 2000) == PlanFile
    check inputValueShown("noir-space-ship", 320) == "noir-space-ship"
    for boxPx in [120, 200, 320, 400, 500]:
      let shown = inputValueShown(PlanFile, boxPx)
      checkpoint $boxPx & ": " & shown
      check Ellipsis in shown
      check "\n" notin shown
      check textWidth(shown, BodyPx, faceGlyphs = true) <= float(boxPx - 18)
      let head = shown.split(Ellipsis)[0]
      check PlanFile.startsWith(head)
      check head.len <= 8
      check PlanFile.endsWith(shown.split(Ellipsis)[^1])
      # From the sidebar's field up, the end kept holds the file name's.
      if boxPx >= 320: check shown.endsWith(".milestones.org")
    check not danglesAroundEllipsis(inputValueShown("Asteroid fields generated from seeds, end to end", 200))

  test "the plan file keeps its file name's end at sidebar width, and is whole at laptop width":
    for (w, cut) in [(360, true), (1440, false)]:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui("agent-harbor-composer", "new-initiative", w, 900, dmDark)
      var values: seq[GpuiElement]
      collect(m.view, "data-ah-value", values)
      let plan = values.filterIt(getAttribute(it, "data-ah-value") == m.composer.planPreview)
      check plan.len == 1
      if plan.len == 1:
        let shown = getAttribute(plan[0], "data-ah-value-shown")
        checkpoint $w & ": " & shown
        check (Ellipsis in shown) == cut
        check shown.endsWith(".milestones.org")
        if cut: check shown.startsWith("mileston" & Ellipsis)
      m.dispose()

# ---------------------------------------------------------------------------
# The styles, off the render plan
# ---------------------------------------------------------------------------

proc planOf(m: AhStoryMount): JsonNode = parseJson(renderPlanJson(r, m.root))

proc attr(n: JsonNode; name: string): string = n{"attributes"}{name}.getStr
proc style(n: JsonNode; name: string): string = n{"styles"}{name}.getStr

proc allWith(n: JsonNode; name: string; into: var seq[JsonNode]) =
  if n{"attributes"}.kind == JObject and n{"attributes"}.hasKey(name): into.add n
  for c in n{"children"}.getElems: allWith(c, name, into)

proc allWith(n: JsonNode; name: string): seq[JsonNode] = allWith(n, name, result)

proc parentsOf(n: JsonNode; name: string; into: var seq[JsonNode]) =
  ## The elements whose child carries `name`.
  for c in n{"children"}.getElems:
    if c{"attributes"}.kind == JObject and c{"attributes"}.hasKey(name): into.add n
    parentsOf(c, name, into)

proc everyNode(n: JsonNode; into: var seq[JsonNode]) =
  into.add n
  for c in n{"children"}.getElems: everyNode(c, into)

proc hexOf(token: DesignToken; mode: DesignMode): string = DesignTokenHex[token][mode]

proc styleProblems(fixture: string; w: int; mode: DesignMode): seq[string] =
  ## The composer story's drawn styles against the web's roles; empty when
  ## they agree.
  gpui_reset_tree()
  let m = r.mountAgentHarborStoryGpui("agent-harbor-composer", fixture, w, 900, mode)
  let plan = m.planOf
  m.dispose()
  let at = fixture & " " & $w & " " & $mode & ": "
  template want(what: string; got, wanted: string) =
    if got != wanted: result.add at & what & " is '" & got & "', the web's '" & wanted & "'"
  # The omnibox field: the primary surface's ground, the inputs' hairline, the web's
  # top, its text clipped inside its padding.
  for f in plan.allWith("data-ah-field-row"):
    want("the field's ground", f.style("bg"), hexOf(dtColorsUiSurfacePrimaryDefault, mode))
    want("the field's border", f.style("border_color"), hexOf(dtColorsUiBorderSecondary, mode))
    want("the field's top", f.style("margin_top"), $FieldTopPx & "px")
  var clips: seq[JsonNode]
  plan.parentsOf("data-ah-field", clips)
  if clips.len != 1 or clips[0].attr("data-ah-field-clip") != "true" or
      clips[0].style("overflow") != "hidden":
    result.add at & "the field's text is not inside a clipping box within the padding"
  for t in plan.allWith("data-ah-field"):
    want("the field text's line", t.style("line_height"), $(FieldHeightPx - 2) & "px")
  # A form field's value box: the inputs' hairline (the error ink when it has
  # a problem), its text on the box's line.
  var boxes: seq[JsonNode]
  plan.parentsOf("data-ah-value", boxes)
  for b in boxes:
    if b.style("border_color") != hexOf(dtColorsUiTextErrorPrimary, mode):
      want("a field's border", b.style("border_color"), hexOf(dtColorsUiBorderSecondary, mode))
  for v in plan.allWith("data-ah-value"):
    want("a field value's line", v.style("line_height"), $ControlPx & "px")
  # A context item left out: struck through, in the web's caption-subtle
  # role (manager note 122).
  for ch in plan.allWith("data-ah-chip-state"):
    if ch.attr("data-ah-chip-state") != "uncited": continue
    let t = ch{"children"}.getElems
    if t.len == 0 or "line-through" notin t[0].style("text_decoration"):
      result.add at & "the left-out chip " & ch.attr("data-ah-chip-label") & " is not struck through"
    else:
      want("the left-out chip's ink", t[0].style("text_color"), hexOf(dtColorsUiTextPrimaryCaptionSubtle, mode))
  # Labels, titles and state words: Medium, the labels tracked; nothing
  # semibold.
  for name in ["data-ah-section", "data-ah-dest-title"]:
    for e in plan.allWith(name):
      want(name & "'s weight", e.style("font_weight"), "500")
      want(name & "'s tracking", e.style("letter_spacing"), "0.04em")
  for e in plan.allWith("data-ah-state"):
    want("a state word's weight", e.style("font_weight"), "500")
  var all: seq[JsonNode]
  everyNode(plan, all)
  for e in all:
    if e.style("font_weight") in ["600", "700", "bold"]:
      result.add at & "a part is drawn semibold or bold: " & $e{"attributes"}
  # The add-context menu's rows, and the `+` control.
  var rows: seq[JsonNode]
  plan.parentsOf("data-ah-context-item", rows)
  for row in rows:
    want("a menu row's ground", row.style("bg"), hexOf(dtColorsUiSurfaceBaseRaised, mode))
  for add in plan.allWith("data-ah-add-context"):
    want("the + control's width", add.style("w"), "21px")

suite "CTF-P2c: the GPUI composer's parts take the web's styles":
  test "field, form fields, a left-out chip, labels, the menu and + in both themes":
    var problems: seq[string]
    var checked = 0
    for fixture in ["context-edited", "add-context", "new-initiative-invalid", "launch",
                    "launch-scheduled", "no-session", "sent", "send-failed", "typing"]:
      for w in [1440, 360]:
        for mode in [dmDark, dmLight]:
          inc checked
          problems.add styleProblems(fixture, w, mode)
    for p in problems: checkpoint p
    check checked == 36
    check problems.len == 0

  test "a left-out chip reads dimmer than an offered one, in both themes":
    # WCAG 2's contrast ratio (https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio):
    # how far an ink stands off the sheet it is drawn on.
    proc luminance(hex: string): float =
      for k, i in [1, 3, 5]:
        let c = float(parseHexInt(hex[i .. i + 1])) / 255.0
        let lin = if c <= 0.04045: c / 12.92 else: pow((c + 0.055) / 1.055, 2.4)
        result += [0.2126, 0.7152, 0.0722][k] * lin
    proc contrast(a, b: string): float =
      let (la, lb) = (luminance(a), luminance(b))
      (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    for w in [1440, 360]:
      for mode in [dmDark, dmLight]:
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui("agent-harbor-composer", "context-edited", w, 900, mode)
        let plan = m.planOf
        m.dispose()
        let sheets = plan.allWith("data-ah-sheet")
        check sheets.len == 1
        if sheets.len != 1: continue
        let ground = sheets[0].style("bg")
        var inks: Table[string, string]
        for ch in plan.allWith("data-ah-chip-state"):
          let t = ch{"children"}.getElems
          if t.len > 0: inks[ch.attr("data-ah-chip-state")] = t[0].style("text_color")
        checkpoint $w & " " & $mode & ": " & $inks & " on " & ground
        check "uncited" in inks and "offered" in inks
        if "uncited" notin inks or "offered" notin inks: continue
        let (left, offered) = (contrast(inks["uncited"], ground), contrast(inks["offered"], ground))
        checkpoint "left out " & $left & ":1, offered " & $offered & ":1"
        # A step under it: at most four fifths of an offered chip's contrast
        # (Light: 2.90:1 against 4.25:1; Dark: 3.58:1 against 8.31:1).
        check left <= offered * 0.8

  test "context-edited has a left-out chip to judge":
    gpui_reset_tree()
    let m = r.mountAgentHarborStoryGpui("agent-harbor-composer", "context-edited", 1440, 900, dmLight)
    let plan = m.planOf
    m.dispose()
    check plan.allWith("data-ah-chip-state").anyIt(it.attr("data-ah-chip-state") == "uncited")

# ---------------------------------------------------------------------------
# A scrolled body says what is above it
# ---------------------------------------------------------------------------

proc scrolledOf(sheet: JsonNode): bool =
  ## Whether the sheet's body is scrolled past its start: by the pixels it
  ## was scrolled (`data-ah-scroll`), or by the parts it scrolled past.
  sheet.attr("data-ah-scroll").len > 0 and parseInt(sheet.attr("data-ah-scroll")) > 0 or
    parseInt(sheet.attr("data-ah-hidden-above")) > 0

proc aboveCueProblems(fixture: string; w, h: int; mode: DesignMode;
                      scrolled: var bool): seq[string] =
  ## The `More above ↑` cue against the body's scroll: drawn when the body
  ## is scrolled past its start, as `More below ↓` is drawn while it holds
  ## more below (brief "The composer"), at the body's top edge, on the
  ## sheet's ground, with the hairline that parts it from the scrolled
  ## content; absent otherwise.
  gpui_reset_tree()
  let m = r.mountAgentHarborStoryGpui("agent-harbor-composer", fixture, w, h, mode)
  let plan = m.planOf
  m.dispose()
  let at = fixture & " " & $w & "x" & $h & " " & $mode & ": "
  let sheets = plan.allWith("data-ah-sheet")
  if sheets.len != 1: return @[at & $sheets.len & " sheets drawn"]
  let sheet = sheets[0]
  scrolled = sheet.scrolledOf
  let cues = plan.allWith("data-ah-more-above")
  if not scrolled:
    if cues.len > 0: result.add at & "a body at its start says there is more above"
    return
  if cues.len != 1:
    return @[at & "the body is scrolled past its start and nothing says so (" &
             $cues.len & " `More above` cues)"]
  let t = cues[0]
  if t.attr("data-ah-more-above") != MoreAbove:
    result.add at & "the cue reads '" & t.attr("data-ah-more-above") & "'"
  if t.style("text_color") != hexOf(dtColorsUiTextPrimaryCaption, mode):
    result.add at & "the cue is not in the caption role"
  var boxes: seq[JsonNode]
  plan.parentsOf("data-ah-more-above", boxes)
  if boxes.len != 1: return result & @[at & "the cue has no line of its own"]
  let line = boxes[0]
  if line.style("top") != "0px":
    result.add at & "the cue's line is not at the body's top edge (top " & line.style("top") & ")"
  if line.style("border_bottom_width") != "1px" or
      line.style("border_color") != hexOf(dtColorsUiBorderSecondary, mode):
    result.add at & "no hairline parts the header from the scrolled body"
  if line.style("bg") != sheet.style("bg"):
    result.add at & "the cue's line is not on the sheet's ground"

suite "CTF-P2c: a scrolled GPUI composer body says what is above it":
  test "More above ↑ under the header's hairline exactly while the body is scrolled":
    var problems: seq[string]
    var scrolledSeen: seq[string]
    for story in agentHarborSection().stories:
      if story.surface != "agent-harbor-composer": continue
      for (w, h) in [(1440, 900), (360, 900), (960, 600)]:
        for mode in [dmDark, dmLight]:
          var scrolled = false
          problems.add aboveCueProblems(story.fixture, w, h, mode, scrolled)
          if scrolled: scrolledSeen.add story.fixture & " " & $w & "x" & $h
    for p in problems: checkpoint p
    checkpoint "scrolled: " & $scrolledSeen
    # The issue's view: the open schedule is scrolled into view, so the body
    # starts below `In view` and the context chips.
    check scrolledSeen.anyIt(it.startsWith("launch-scheduled 1440x900"))
    check scrolledSeen.anyIt(it.startsWith("launch-scheduled 360x900"))
    check problems.len == 0
