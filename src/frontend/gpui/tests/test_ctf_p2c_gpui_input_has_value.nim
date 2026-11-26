## The app's one input rule in the GPUI views of CodeTracer as an Agent
## Harbor front-end: an `input` holding a value is drawn with the action border on
## the input surface, as the web's `input.styl` draws it
## (`input:not(:placeholder-shown):not(:disabled)`), in both themes, from the
## design system's tokens (`DesignTokenHex`).
##
## * **The rule** (`ah_theme.inputLook`): a value fills; an empty field
##   showing its placeholder keeps its rest look; a disabled one is never
##   filled; focus sets only the border, to the same action token, so
##   focused and filled agree; an empty field with no placeholder is not
##   placeholder-shown, so it is filled as in the browser.
## * **The palette's field** (`ikCommandField`, the composer's and the
##   omnibox's) stays on its row's rest look whatever it holds, and a
##   **value box that is not an `input`** (`ikValueBox`, the composer form's
##   Repository, Branch, Session name) is never filled: the web's own
##   exemptions.
## * **Drawn**: the control center's instruction (`launch-failed`, the
##   instruction back in the field), the Changes panel's file search
##   (`code-filtered`) and the inbox's password field (`sudo`) take the
##   filled look holding a value and keep their rest look empty; the
##   instruction locked (`launching`) is not filled; the composer's field,
##   holding its text, keeps its rest look.
##
## No mocks: the stories' own viewmodels over their scripted sources, drawn
## by the real views through the real isonim-gpui shim, read off the render
## plan GPUI is handed.

import std/[json, sequtils, unittest]

import isonim_gpui/renderer
from isonim_gpui/bindings import gpui_reset_tree

import ../agent_harbor/ah_stories
import ../../stories/agent_harbor_control_center_stories
from ../../viewmodel/views/agent_harbor_changes_inbox_words import SearchFilesPlaceholder
from ../../viewmodel/views/agent_harbor_control_center_words import InstructionLabel
from ../agent_harbor/ah_changes_panel import FilledSearchIconInk

let r = GpuiRenderer()

proc hexOf(token: DesignToken; mode: DesignMode): string = DesignTokenHex[token][mode]

proc attr(n: JsonNode; name: string): string = n{"attributes"}{name}.getStr
proc style(n: JsonNode; name: string): string = n{"styles"}{name}.getStr

proc allWith(n: JsonNode; name: string; into: var seq[JsonNode]) =
  if n{"attributes"}.kind == JObject and n{"attributes"}.hasKey(name): into.add n
  for c in n{"children"}.getElems: allWith(c, name, into)

proc allWith(n: JsonNode; name: string): seq[JsonNode] = allWith(n, name, result)

proc holding(n: JsonNode; name, value: string): bool =
  ## Whether `n` or an element under it carries `name` = `value`.
  if n.attr(name) == value: return true
  n{"children"}.getElems.anyIt(it.holding(name, value))

proc planOf(m: AhStoryMount): JsonNode = parseJson(renderPlanJson(r, m.root))

const Modes = [dmDark, dmLight]

proc filledBorder(mode: DesignMode): string = hexOf(dtColorsUiBorderAction, mode)
proc filledFill(mode: DesignMode): string = hexOf(dtColorsUiSurfaceInputSecondary, mode)

suite "CTF-P2c: the GPUI input rule":
  test "the design system's values: Dark #282828, Light #dbd6cc, the action border":
    # The values the web draws; a token that moves shows here.
    check filledFill(dmDark) == "#282828"
    check filledFill(dmLight) == "#dbd6cc"
    check filledBorder(dmDark) == "#6366f1"
    check filledBorder(dmLight) == "#6366f1"

  test "a value fills; an empty field keeps its rest look; disabled never fills":
    for mode in Modes:
      let p = ahPalette(mode)
      let rest = (border: p.borderSecondary, fill: p.ground)
      let full = inputLook(p, "Add a test", "Describe the task", rest.border, rest.fill)
      check full.filled
      check full.border == filledBorder(mode)
      check full.fill == filledFill(mode)
      let empty = inputLook(p, "", "Describe the task", rest.border, rest.fill)
      check not empty.filled
      check (empty.border, empty.fill) == rest
      for value in ["", "Add a test"]:
        let off = inputLook(p, value, "Describe the task", rest.border, rest.fill,
                            disabled = true)
        check not off.filled
        check off.disabled
        check off.border == hexOf(dtColorsUiBorderDisabled, mode)
        check off.fill == hexOf(dtColorsUiSurfacePrimaryDisabled, mode)

  test "focus sets the border only, and agrees with a value":
    for mode in Modes:
      let p = ahPalette(mode)
      let focusedEmpty = inputLook(p, "", "Describe the task", p.borderSecondary, p.ground,
                                   focused = true)
      check not focusedEmpty.filled
      check focusedEmpty.border == filledBorder(mode)
      check focusedEmpty.fill == p.ground
      let focusedFull = inputLook(p, "Add a test", "Describe the task", p.borderSecondary,
                                  p.ground, focused = true)
      check focusedFull == inputLook(p, "Add a test", "Describe the task",
                                     p.borderSecondary, p.ground)
      # Disabled outranks focus (a disabled field takes no focus at all).
      check inputLook(p, "", "x", p.borderSecondary, p.ground, disabled = true,
                      focused = true).border == hexOf(dtColorsUiBorderDisabled, mode)

  test "an empty field with no placeholder is not placeholder-shown":
    check placeholderShown("", "Search files")
    check not placeholderShown("", "")
    check not placeholderShown("q", "Search files")
    let p = ahPalette(dmDark)
    check inputLook(p, "", "", p.borderSecondary, p.ground).filled

  test "the palette's field and a value box are the web's exemptions":
    for mode in Modes:
      let p = ahPalette(mode)
      for kind in [ikCommandField, ikValueBox]:
        let look = inputLook(p, "/ai Also test", "", p.borderSecondary, p.ground, kind = kind)
        check not look.filled
        check (look.border, look.fill) == (p.borderSecondary, p.ground)
      # The palette's row turns to the action border while its field has
      # focus (`.command-input-row:focus-within`); its fill stays.
      let focused = inputLook(p, "/ai", "", p.borderSecondary, p.ground,
                              kind = ikCommandField, focused = true)
      check (focused.border, focused.fill) == (filledBorder(mode), p.ground)

  test "inputBox draws the look and says so":
    for mode in Modes:
      let p = ahPalette(mode)
      for (value, disabled, filled) in [("q", false, true), ("", false, false),
                                        ("q", true, false)]:
        gpui_reset_tree()
        let look = inputLook(p, value, "Search", p.borderSecondary, p.ground,
                             disabled = disabled)
        let el = r.inputBox(look, [("height", "24px")])
        let plan = parseJson(renderPlanJson(r, el))
        check plan.style("border_color") == look.border
        check plan.style("bg") == look.fill
        check plan.attr("data-ah-input-filled") == $filled
        check plan.attr("data-ah-input-disabled") == $disabled
        if filled: check plan.style("bg") == filledFill(mode)

  test "the control center's instruction: filled with a value, rest look empty or locked":
    for mode in Modes:
      let p = ahPalette(mode)
      for (fixture, filled) in [("launch-failed", true), ("populated", false),
                                ("launching", false)]:
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui("agent-harbor-control-center", fixture,
                                            1440, 900, mode)
        let plan = m.planOf
        m.dispose()
        # The instruction's box: the field under the `Instruction` label
        # (the form's own value boxes carry their own labels).
        var boxes: seq[JsonNode]
        for f in plan.allWith("data-ah-field-label"):
          if f.attr("data-ah-field-label") == InstructionLabel:
            boxes.add f.allWith("data-ah-input-filled")
        checkpoint fixture & " " & $mode
        check boxes.len >= 1
        let box = boxes[0]
        check box.attr("data-ah-input-filled") == $filled
        if filled:
          check box.style("border_color") == filledBorder(mode)
          check box.style("bg") == filledFill(mode)
        elif fixture == "launching":
          check box.style("border_color") == p.panel
          check box.style("bg") == p.panel
        else:
          check box.style("border_color") == p.borderSecondary
          check box.style("bg") == p.ground
        # The form's value boxes (Repository, Branch, Session name) are not
        # inputs: never filled, a value or none.
        for v in plan.allWith("data-ah-input-filled"):
          if v.holding("data-ah-value", "noir-space-ship") and
              not v.holding("data-ah-value", EmptyShieldTask):
            check v.attr("data-ah-input-filled") == "false"
            check v.style("border_color") != filledBorder(mode)
            check v.style("bg") == (if fixture == "launching": p.panel else: p.ground)

  test "the Changes panel's file search: filled with a query, rest look without":
    for mode in Modes:
      let p = ahPalette(mode)
      for (fixture, filled) in [("code-filtered", true), ("code", false)]:
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui("agent-harbor-changes", fixture, 1440, 900, mode,
                                            frameTitle = "Changes")
        let plan = m.planOf
        m.dispose()
        let searches = plan.allWith("data-ah-search")
        checkpoint fixture & " " & $mode
        check searches.len == 1
        if searches.len == 1:
          let s = searches[0]
          check s.attr("data-ah-input-filled") == $filled
          check s.style("border_color") == (if filled: filledBorder(mode) else: p.borderSecondary)
          check s.style("bg") == filledFill(mode)  # `.ct-input-panel`'s rest fill is the same
          check (s.attr("data-ah-search").len > 0) == filled
          # The magnifier, the field's first child: the filled field's icon
          # colour holding a query (`ct-images-default-search-icon`), the
          # placeholder's without one.
          let kids = s{"children"}.getElems
          check kids.len > 0
          if kids.len > 0:
            check (kids[0].style("border_color") == FilledSearchIconInk) == filled
    check SearchFilesPlaceholder.len > 0

  test "the inbox's password field: filled once a password is given":
    for mode in Modes:
      gpui_reset_tree()
      let m = r.mountAgentHarborStoryGpui("agent-harbor-inbox-item", "sudo", 1440, 900, mode)
      # The story's item may be drawn more than once (the list and the
      # page); every password field it draws follows the rule.
      var fields = m.planOf.allWith("data-ah-password-field")
      check fields.len >= 1
      for f in fields:
        check f.attr("data-ah-input-filled") == "false"
        check f.style("border_color") == ahPalette(mode).borderSecondary
      m.changesInbox.inboxItem.setPassword("hunter2")
      fields = m.planOf.allWith("data-ah-password-field")
      check fields.len >= 1
      for f in fields:
        check f.attr("data-ah-input-filled") == "true"
        check f.style("border_color") == filledBorder(mode)
        check f.style("bg") == filledFill(mode)
      m.dispose()

  test "the composer's field holding its text keeps its row's rest look":
    for mode in Modes:
      let p = ahPalette(mode)
      for fixture in ["typing", "launch", "multi-line"]:
        gpui_reset_tree()
        let m = r.mountAgentHarborStoryGpui("agent-harbor-composer", fixture, 1440, 900, mode)
        let plan = m.planOf
        m.dispose()
        let rows = plan.allWith("data-ah-field-row")
        checkpoint fixture & " " & $mode
        check rows.len == 1
        for f in rows:
          check f.attr("data-ah-input-filled") == "false"
          check f.style("border_color") == p.borderSecondary
          check f.style("bg") == p.ground
