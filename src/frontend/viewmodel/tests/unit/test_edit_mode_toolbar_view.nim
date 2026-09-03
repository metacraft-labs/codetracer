## EMT — the toolbar reaches a renderer.
##
## The viewmodel this exercises was complete, tested on both backends, and
## imported by nothing outside its own two suites. These checks are about the
## gap that made that possible: which surface the topbar host carries, and
## whether the buttons a model carries actually become elements.
##
## Every check runs identically on `vm-unit` (C) and `vm-unit-js` (node),
## because the mock renderer is the one both lanes can drive.

import std/[unittest, strutils, tables, sequtils]

import isonim/testing/mock_dom

import ../../viewmodels/edit_mode_toolbar
import ../../views/isonim_edit_mode_toolbar_view
import ../../platform/capabilities

var asserted = 0
template ck(cond: untyped) =
  inc asserted
  check cond

template startCount() =
  asserted = 0

template expectCount(n: int) =
  check asserted == n

proc noirListing(): seq[string] = @["Nargo.toml", "src/main.nr"]

proc collectIds(node: MockNode; into: var seq[string]) =
  if node.attributes.hasKey("id"):
    into.add node.attributes["id"]
  for child in node.children:
    collectIds(child, into)

proc findBySurface(node: MockNode): string =
  if node.attributes.hasKey("data-topbar-surface"):
    return node.attributes["data-topbar-surface"]
  for child in node.children:
    let found = findBySurface(child)
    if found.len > 0: return found
  ""

proc attrOf(node: MockNode; name: string): string =
  if node.attributes.hasKey(name): node.attributes[name] else: ""

proc collectDisabled(node: MockNode; into: var seq[string]) =
  if node.attributes.hasKey("disabled") and node.attributes.hasKey("id"):
    into.add node.attributes["id"]
  for child in node.children:
    collectDisabled(child, into)

suite "EMT §7.3 which surface the topbar host carries":

  test "EMT-V1 the mode decides the surface, and an absent model does not blank it":
    ## The whole defect, as a value. `tsEditCommands` only when BOTH hold, and
    ## the debugger controls are the fallback rather than nothing — an empty
    ## topbar is a worse failure than the one being fixed.
    startCount()
    ck topbarSurface(EditMode, true) == tsEditCommands
    ck topbarSurface(QuickEditMode, true) == tsEditCommands
    ck topbarSurface(InteractiveEditMode, true) == tsEditCommands
    # Replaying surfaces keep the debugger, model or no model.
    ck topbarSurface(DebugMode, true) == tsDebuggerControls
    ck topbarSurface(CalltraceLayoutMode, true) == tsDebuggerControls
    # And the negative twin that stops the check above being about `mode` alone:
    # editing WITHOUT a model must still produce a toolbar.
    ck topbarSurface(EditMode, false) == tsDebuggerControls
    ck topbarSurface(DebugMode, false) == tsDebuggerControls
    expectCount(7)

suite "EMT §7.3 the model becomes elements":

  test "EMT-V2 an edit-mode model renders every button it carries, and the count is asserted":
    ## `visibleButtons` filters `buttons` by `actions`; a panel that silently
    ## dropped three of four would still "render the edit toolbar", so the
    ## count is pinned and then each id is pinned under it.
    startCount()
    let model = editModeToolbar(desktopProfile, EditMode,
                                listing = noirListing())
    let buttons = model.visibleButtons
    # Build and Run — and nothing else. The row was four until the report
    # *"I see 'Run tests' and 'Record tests' as some kind of boxes next to the
    # build and run buttons"* took the two text buttons off it.
    ck buttons.len == 2
    var ids: seq[string] = @[]
    for b in buttons: ids.add b.id
    ck "build-image" in ids
    ck "run-image" in ids
    # The removal, pinned from the other side. Without these two, putting the
    # entries back into `result.buttons` would leave every assertion in this
    # test satisfiable by a longer row.
    ck "run-tests-image" notin ids
    ck "record-tests-image" notin ids

    var rendered: seq[string] = @[]
    let panel = renderEditModeToolbarPanel(
      MockRenderer(), model, proc(id: string) = discard)
    collectIds(panel, rendered)
    # Every button the model carries reached the DOM, and nothing else did.
    ck rendered.len == buttons.len
    for id in ids:
      ck id in rendered
    # The root names the surface, which is what lets a selector tell the two
    # panels apart when they share an id.
    ck findBySurface(panel) == "edit-commands"
    # The count travels in the markup too, so a browser check can assert it
    # without counting nodes it might mis-select.
    ck attrOf(panel, "data-button-count") == "2"
    expectCount(10)
    ## COUNT 12 -> 10, and the arithmetic is stated so the next edit can check
    ## it: two `in ids` assertions became two `notin ids` (no change), and the
    ## `for id in ids` loop went from four iterations to two (-2).

  test "EMT-V3 Debug mode carries no command buttons at all — EMT-D12":
    ## Rebuilding underneath a live replay invalidates the trace being
    ## replayed, so these are ABSENT rather than disabled. Asserted through
    ## the renderer, because "the model excludes them" and "the panel does not
    ## draw them" are different claims and only the second is what a user sees.
    startCount()
    let model = editModeToolbar(desktopProfile, DebugMode,
                                listing = noirListing())
    var ids: seq[string] = @[]
    for b in model.visibleButtons: ids.add b.id
    ck "build-image" notin ids
    ck "run-image" notin ids
    # The test buttons used to be the two that survived into Debug mode. They
    # are on neither bar now — see EMT-A3 in the model suite for why, and for
    # where each gesture went.
    ck "run-tests-image" notin ids
    ck "record-tests-image" notin ids
    # WHICH MAKES THE DEBUG-MODE ROW EMPTY, and that is stated rather than
    # left to be inferred from four absences.
    #
    # It is not a blank topbar. `topbarSurface` mounts `tsEditCommands` only
    # when `mode.isEditing`, so in Debug mode this panel is never on screen at
    # all and the debugger's twelve stepping controls are. The assertion is
    # here because the model must not start claiming otherwise: if this row
    # ever became non-empty AND the mount rule changed, the two together are
    # what would put a stray Build button over a live replay (EMT-D12).
    ck ids.len == 0

    var rendered: seq[string] = @[]
    let panel = renderEditModeToolbarPanel(
      MockRenderer(), model, proc(id: string) = discard)
    collectIds(panel, rendered)
    ck "build-image" notin rendered
    ck "run-image" notin rendered
    ck rendered.len == 0
    expectCount(8)

  test "EMT-V4 a disabled button carries the attribute AND says why":
    ## The browser treats any value of `disabled` as disabled, so the attribute
    ## has to be absent on an enabled button rather than empty. Both directions
    ## are asserted, and the reason is required to be non-empty because a
    ## disabled control with no explanation is EMT-D14's defect.
    startCount()
    # The web tier cannot run an arbitrary program, so the conventional
    # commands are disabled-with-a-reason rather than hidden (§8).
    let model = editModeToolbar(webProfile, EditMode, listing = noirListing())
    let buttons = model.visibleButtons
    ck buttons.len > 0
    var disabledSeen = 0
    for b in buttons:
      if not b.enabled:
        inc disabledSeen
        ck b.reason.len > 0
        # `buttonTitle` is what the pointer reveals, and for a disabled button
        # it must be the reason rather than the command line.
        ck b.buttonTitle == b.reason
    ck disabledSeen > 0

    var renderedDisabled: seq[string] = @[]
    let panel = renderEditModeToolbarPanel(
      MockRenderer(), model, proc(id: string) = discard)
    collectDisabled(panel, renderedDisabled)
    ck renderedDisabled.len == disabledSeen
    expectCount(3 + disabledSeen * 2)

  test "EMT-V5 clicking a rendered button invokes THAT button's id":
    ## The loop captures `id` per iteration. Without that every handler closes
    ## over the last button and one toolbar runs one command four times — a
    ## defect no structural check would see, because the markup is correct.
    startCount()
    let model = editModeToolbar(desktopProfile, EditMode,
                                listing = noirListing())
    var invoked: seq[string] = @[]
    let panel = renderEditModeToolbarPanel(
      MockRenderer(), model, proc(id: string) = invoked.add id)

    proc clickAll(node: MockNode) =
      if node.attributes.hasKey("id") and
         not node.attributes.hasKey("disabled"):
        fireEvent(node, "click")
      for child in node.children:
        clickAll(child)

    clickAll(panel)
    var enabledIds: seq[string] = @[]
    for b in model.visibleButtons:
      if b.enabled: enabledIds.add b.id
    ck invoked.len == enabledIds.len
    # Each id appears exactly once, and it is its OWN id.
    for id in enabledIds:
      ck invoked.count(id) == 1
    expectCount(1 + enabledIds.len)
