## test_gpui_vocabulary_binding.nim — PLAT-21. **The third front-end's binding,
## through the real isonim-gpui shim, and the milestone's verification gate.**
##
## PLAT-21's gate: *"The count of vocabulary entries needing a GPUI-specific
## escape is **zero**, or each is a named, filed vocabulary defect. Silent
## escapes are how a shared vocabulary becomes three vocabularies."*
##
## This file is where that count is TAKEN. `gpui_binding` appends a
## `GpuiEscape` at the moment it takes one, so the census below comes out of a
## RUN over a view carrying all sixteen entries, and the assertion is that the
## set it produced equals the set `gpui_gaps.FiledGpuiGaps` names — in both
## directions, so neither an unfiled escape nor a filed gap nothing takes can
## pass.
##
## ## WHAT IS REAL HERE
##
## `GpuiRenderer` and the element tree are isonim-gpui's own, reached through
## the Rust shim's `extern "C"` surface — the same shim `codetracer-gpui` links,
## and the same tier PLAT-19 established. Every fact read back below comes out
## of the shim's element store through `gpui_get_attribute`; nothing is echoed
## from the `ViewNode`.
##
## **The shim is built WITHOUT `--features gpui-backend`, so this is a SHADOW
## TREE and a RENDER PLAN and NOT A WINDOW.** PLAT-20 recorded that no GPUI
## window has been observed on any host; PLAT-21 does not change it and does not
## imply otherwise. What a render plan can carry it carries, and what it cannot
## — a pixel, a layer, a focus ring — is stated as absent.
##
## ## NO MOCKS
##
## There are none in this file, and the reason is the same one PLAT-20's suites
## give: the subject is a RENDERING, which is a property of a `ViewNode` and of
## the renderer it is handed to, not of a recording. The product's own pane
## views on a real recording are the other suite —
## `src/frontend/tui/tests/test_cross_renderer_panes.nim` — which needs all
## three renderers and therefore runs in the `tui` lane.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)

import std/[algorithm, json, sequtils, strutils, tables, unicode, unittest]

import isonim_gpui/renderer
import isonim_gpui/bindings

import ../../../common/view_vocabulary
import ../../../common/value_presentation
import ../../view_vocabulary/gpui_binding as gbind
import ../../view_vocabulary/web_binding as wbind

var asserted = 0
var countedAssertions = 0

template ck(condition: untyped) =
  inc asserted
  inc countedAssertions
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template resetCount() =
  asserted = 0

# ---------------------------------------------------------------------------
# The view. All sixteen entries, so that no entry's gap row is unchecked.
# ---------------------------------------------------------------------------

proc opt(id, label: string; disabled = false): ViewOption =
  ViewOption(id: id, label: label, disabled: disabled)

proc wholeVocabulary(): ViewNode =
  viewCollapsible("panel", "Debug settings", @[
    viewText("title", "Settings"),
    viewButton("apply", "Apply"),
    viewCheckbox("wrap", "Wrap long values"),
    viewToggle("live", "Live update"),
    viewInput("filter", "abc"),
    viewSelect("lang", @[opt("rs", "Rust"), opt("py", "Python"),
                         opt("go", "Go")], selected = 0),
    viewList("recent", @[opt("a", "alpha"), opt("b", "beta", disabled = true),
                         opt("c", "gamma")]),
    viewTreeNode("state", "locals", @[
      viewTreeNode("state.x", "x"),
      viewTreeNode("state.p", "p", @[viewTreeNode("state.p.y", "y")])],
      expanded = true),
    viewTable("tbl", @["name", "value"],
              @[@["a", "1"], @["b", "2"], @["c", "3"]]),
    viewTabs("panes", @[opt("t1", "Source"), opt("t2", "State")]),
    viewMenu("ctx", @[opt("m1", "Copy"), opt("m2", "Paste")]),
    viewProgress("load", 40),
    viewImage("shot", "image/png", "screenshot of the state panel", 2048),
    viewMarkdown("doc", "# Title\n\nbody"),
    viewModal("dlg", "Confirm", @[viewText("dlgtext", "Are you sure?")])],
    expanded = true)

proc freshBinding(): GpuiBinding =
  gpui_reset_tree()
  resetCallbacks()
  renderGpui(GpuiRenderer(), wholeVocabulary())

proc factTable(b: GpuiBinding): Table[string, string] =
  for f in b.readGpuiFacts():
    result[f.id & "." & f.field] = f.value

proc says(b: GpuiBinding; key: string): string =
  let t = factTable(b)
  if key in t: t[key] else: "<absent>"

proc planKinds(): Table[string, string] =
  ## Every tag this binding can emit, and the element KIND isonim-gpui's own
  ## render-plan builder classifies it as — read off the plan the Rust side
  ## produced, not off `tagMap`.
  gpui_reset_tree()
  resetCallbacks()
  let r = GpuiRenderer()
  let root = r.createElement("div")
  var tags: seq[string] = @[]
  for k in ViewKind:
    let t = gpuiTagFor(k)
    if t notin tags: tags.add t
    let c = gpuiChildTagFor(k)
    if c notin tags: tags.add c
  for extra in ["tr", "td", "th"]:
    if extra notin tags: tags.add extra
  for t in tags:
    r.appendChild(root, r.createElement(t))
  let plan = parseJson(r.renderPlanJson(root))
  for i, t in tags:
    result[t] = plan["children"][i]["kind"].getStr

# ---------------------------------------------------------------------------

suite "PLAT-21: the GPUI binding renders every entry through the real shim":

  test "all sixteen entries render, and the shim builds a valid render plan":
    resetCount()
    let b = freshBinding()
    ck b.planIsValid()
    # THE POSITIVE CONTROL FIRST (Verification-Harness-Traps §4): a binding
    # that rendered nothing produces an empty fact set, and an empty fact set
    # satisfies every "does not contain" assertion anybody could write below.
    let facts = b.readGpuiFacts()
    ck facts.len == 29
    # And every one of the sixteen entries is present BY ID, read out of the
    # shim rather than out of the model.
    var ids: seq[string] = @[]
    for f in facts:
      if f.id notin ids: ids.add f.id
    for id in ["title", "apply", "wrap", "live", "filter", "lang", "recent",
               "state", "tbl", "panes", "ctx", "load", "shot", "doc", "dlg",
               "panel"]:
      ck id in ids
    # The tree the shim holds is not a flat list: the sixteen entries, plus
    # the Modal's `Text` child, plus the Tree's two VISIBLE children. The
    # Tree's grandchild `state.p.y` is NOT here, because `state.p` is
    # collapsed and a collapsed node's children are absent rather than
    # hidden — which is the entry's own word and the thing the other two media
    # agree about.
    ck ids.len == 19
    expectCount(19)

  test "the tags are the ones the GPUI MAPPING TABLE names":
    # `mappings.gpuiMapping` is a table of claims PLAT-3 wrote from
    # isonim-gpui's `tagMap`. This is the case that reads it against what the
    # binding actually emits — the same pairing `test_view_vocabulary_cross_
    # medium.nim` makes for the web column.
    resetCount()
    for k in ViewKind:
      let tag = gpuiTagFor(k)
      ck tag.len > 0
      ck gpuiMapping(k).target.contains(tag)
    expectCount(32)

  test "the GPUI tags are NOT the web binding's tags":
    # If the third column emitted the second column's tags it would be the
    # second column, and the cross-renderer suite would be comparing one
    # binding with itself (Verification-Harness-Traps §14).
    resetCount()
    var differing = 0
    for k in ViewKind:
      if gpuiTagFor(k) != wbind.tagFor(k):
        inc differing
    ck differing == 3
    ck gpuiTagFor(pkTabs) == "nav"
    ck gpuiTagFor(pkMenu) == "nav"
    ck gpuiTagFor(pkMarkdown) == "p"
    expectCount(4)

suite "PLAT-21: PLAT-3's msAbsent premise, RE-TAKEN against the render plan":

  test "an unknown tag does NOT reach a classifier with no case for it":
    # PLAT-3 recorded `Table`, `Modal` and `ProgressIndicator` as `msAbsent`
    # on GPUI, and gave one reason for all three: *"mapTag passes an unknown
    # tag through unchanged, so `table` reaches a Rust classifier with no case
    # for it."* MEASURED HERE, 2026-09-15, against the plan the Rust side
    # builds: it does have a case for it, and the case is `Div` — which is
    # EXACTLY what `button`, `input`, `select`, `ul` and `li` get, and those
    # five are `msPartial`.
    #
    # So the msAbsent/msPartial distinction PLAT-3 drew from `tagMap`
    # membership does not survive to the renderer. That is why none of those
    # three entries is in `FiledGpuiGaps` for a TAG reason, and why `Modal` is
    # in it for a different one (no element focus, `PLAT21-VG3`).
    resetCount()
    let kinds = planKinds()
    for absentTag in ["table", "tr", "td", "th", "dialog", "progress",
                      "option"]:
      ck kinds.getOrDefault(absentTag, "<missing>") == "Div"
    for partialTag in ["button", "input", "select", "ul", "li"]:
      ck kinds.getOrDefault(partialTag, "<missing>") == "Div"
    # THE POSITIVE TWIN, so the row above is not "everything is Div".
    ck kinds.getOrDefault("span", "<missing>") == "TextContainer"
    ck kinds.getOrDefault("p", "<missing>") == "TextContainer"
    ck kinds.getOrDefault("img", "<missing>") == "Img"
    # And the three entries really do render: their facts come back.
    let b = freshBinding()
    ck b.says("tbl.row") == "0"
    ck b.says("dlg.open") == "true"
    ck b.says("load.progress") == "40"
    expectCount(18)

suite "PLAT-21: the two renderer defects this milestone measured":

  test "the `disabled` attribute is destroyed by the renderer — PLAT21-VG2":
    # The measurement `gpui_gaps.PLAT21-VG2` quotes, taken here rather than
    # written into the register by hand. It is not a claim about our binding:
    # it is a claim about `isonim-gpui/src/isonim_gpui/renderer.nim`'s
    # `mapAttributeName` / `mapAttributeValue`, and it is made by writing a
    # value in and reading it back out.
    resetCount()
    gpui_reset_tree()
    let r = GpuiRenderer()
    let el = r.createElement("div")
    r.setAttribute(el, "disabled", "true")
    ck renderer.getAttribute(el, "disabled") == ""
    ck renderer.getAttribute(el, "enabled") == "false"
    r.setAttribute(el, "disabled", "false")
    # THE SHARP HALF: saying "this element is ENABLED" records it as disabled.
    ck renderer.getAttribute(el, "enabled") == "false"
    # And the escape works: the same fact under the `data-` prefix survives
    # whole, which is why `Button.disabled` reads back correctly below.
    r.setAttribute(el, factAttributeName("disabled"), "false")
    ck renderer.getAttribute(el, factAttributeName("disabled")) == "false"
    let b = freshBinding()
    ck b.says("apply.disabled") == "false"
    expectCount(5)

  test "the renderer's callback ABI carries no key — PLAT21-VG1":
    # `addEventListener` takes `proc()`. A handler cannot be told which key it
    # was, so the binding puts the key in the EVENT NAME — and the round trip
    # through Rust is what makes that load-bearing rather than decorative:
    # `keyFromGpuiEvent` parses the name back, so a dispatch that reached the
    # wrong listener produces the wrong `KeyPress`.
    resetCount()
    ck gpuiKeyEvent(kDown) == "vockey:Down"
    ck gpuiKeyEvent(kChar, "Z") == "vockey:Char:Z"
    ck keyFromGpuiEvent("vockey:Down").key == kDown
    ck keyFromGpuiEvent("vockey:Char:Z").key == kChar
    ck $keyFromGpuiEvent("vockey:Char:Z").ch == "Z"
    # A name this binding never emits parses to nothing rather than to a
    # plausible key — the mirror of the above, without which the parse could
    # be answering `kDown` to everything.
    ck keyFromGpuiEvent("keydown").key == kNone
    ck keyFromGpuiEvent("vockey:ArrowDown").key == kNone
    # The names are each medium's OWN: if this column borrowed the DOM's, the
    # translation step would be untested here.
    ck gpuiKeyName(kDown) != "ArrowDown"
    ck gpuiKeyName(kEscape) == "Dismiss"
    expectCount(9)

  test "there is no element focus in this renderer — PLAT21-VG3":
    # `Modal`'s specified behaviour is exclusivity. The render plan's node
    # shape is the whole of what a GPUI host is handed, and it has eight
    # fields; none of them is a layer, a z-order or a focus.
    resetCount()
    let b = freshBinding()
    let plan = parseJson(b.planJson())
    var keys: seq[string] = @[]
    for k, _ in plan.pairs: keys.add k
    keys.sort()
    ck keys == @["children", "event_names", "has_click_handler",
                 "has_input_handler", "kind", "styles", "tag", "text"]
    ck "focus" notin keys
    ck "layer" notin keys
    ck "z_index" notin keys
    # What the binding CAN carry is presence, and it does: the modal's body is
    # a fact while it is open and absent once it is not.
    ck b.says("dlgtext.text") == "Are you sure?"
    discard b.sendKey("dlg", kEscape)
    ck b.says("dlg.open") == "false"
    ck b.says("dlgtext.text") == "<absent>"
    expectCount(7)

suite "PLAT-21: the keyboard contract, THROUGH the shim's own dispatcher":

  test "the render plan reports each entry's contract as event_names":
    # The strongest thing this tier can say about the keyboard contract: the
    # list of keys an entry answers is read out of the RUST side, out of the
    # plan a GPUI host would execute, and compared with `behaviour.keyContract`
    # — which is the vocabulary's own data.
    resetCount()
    let b = freshBinding()
    let plan = parseJson(b.planJson())
    # The plan carries no attributes (PLAT-20 measured that), so the node
    # cannot be matched to an id through it. What it CAN do is report the
    # multiset of contracts, which is what is compared.
    var planEvents: seq[string] = @[]
    proc collect(n: JsonNode) =
      if n.kind == JObject:
        let ev = n{"event_names"}
        if not ev.isNil and ev.kind == JArray and ev.len > 0:
          var names: seq[string] = @[]
          for e in ev: names.add e.getStr
          names.sort()
          planEvents.add names.join(",")
        let kids = n{"children"}
        if not kids.isNil:
          for c in kids: collect(c)
    collect(plan)
    # The expectation is built over the ids THE SHIM REPORTS — a node that was
    # not rendered has no fact, so `state.p.y` (under a collapsed `Tree` node)
    # is outside the population by construction. Walking the model instead
    # counted it, and the case went red with 15 against 14: the model knows
    # about a node the renderer correctly did not draw, and an expectation
    # derived from the model is an expectation about the wrong set.
    var renderedIds: seq[string] = @[]
    for f in b.readGpuiFacts():
      if f.id notin renderedIds: renderedIds.add f.id
    var expected: seq[string] = @[]
    for n in walk(b.model):
      if n.id notin renderedIds: continue
      if n.kind notin InteractiveKinds: continue
      var names: seq[string] = @[]
      for binding in keyContract(n.kind):
        if binding.key == kChar: continue
        names.add gpuiKeyEvent(binding.key)
      if names.len == 0: continue
      names.sort()
      expected.add names.join(",")
    planEvents.sort()
    expected.sort()
    ck planEvents.len > 0          # the §4 floor
    ck planEvents.len == 14
    ck planEvents == expected
    expectCount(3)

  test "a handled key CROSSED the FFI boundary, and an unclaimed one did not":
    # **ADDED AFTER ARM G6 SURVIVED.** The case below asserts that a key in the
    # contract acts and a key outside it does nothing — and that is true of a
    # binding that never dispatches at all, because `behaviour.applyKey`
    # declines an unclaimed key by itself. So the case that was meant to prove
    # the transport proved something the vocabulary already guarantees:
    # Verification-Harness-Traps §7a, an argued property with nothing that can
    # tell it from its opposite.
    #
    # `dispatchCount` is incremented inside the handler Rust calls back into,
    # so it is the one number only the real path can move.
    resetCount()
    let b = freshBinding()
    ck b.dispatchCount == 0
    discard b.sendKey("wrap", kSpace)
    ck b.dispatchCount == 1
    discard b.sendKey("recent", kDown)
    ck b.dispatchCount == 2
    # An unclaimed key reaches NO listener on the Rust side, so the counter
    # does not move — which is a different statement from "applyKey declined
    # it", and it is the one this case is for.
    discard b.sendKey("wrap", kDown)
    ck b.dispatchCount == 2
    # …and firing the event AT THE ELEMENT, with no call into this binding at
    # all, still acts. Nothing on the Nim side was asked to do anything: the
    # listener is registered in the Rust node's own map and the callback id
    # comes back through `globalDispatcher`.
    ck b.says("live.checked") == "false"
    fireEvent(b.nodes["live"], gpuiKeyEvent(kSpace))
    ck b.dispatchCount == 3
    b.rerender()
    ck b.says("live.checked") == "true"
    expectCount(7)

  test "a key in the contract acts, and a key outside it does nothing":
    resetCount()
    let b = freshBinding()
    ck b.says("wrap.checked") == "false"
    let hit = b.sendKey("wrap", kSpace)
    ck hit.handled
    ck hit.transition == trCheck
    ck b.says("wrap.checked") == "true"
    # Down is not in `Checkbox`'s contract, so no listener was ever registered
    # under that name and `gpui_dispatch_event` reaches NOTHING on the Rust
    # side. That is a stronger statement than "applyKey declined it".
    let miss = b.sendKey("wrap", kDown)
    ck not miss.handled
    ck miss.transition == trNone
    ck b.says("wrap.checked") == "true"
    expectCount(7)

  test "motion skips an unavailable option, on this medium too":
    resetCount()
    let b = freshBinding()
    ck b.says("recent.highlight") == "0"
    discard b.sendKey("recent", kDown)
    # PAST `beta`, which is disabled. The option's availability survived the
    # renderer only because the binding carried it under the `data-` prefix —
    # see PLAT21-VG2.
    ck b.says("recent.highlight") == "2"
    discard b.sendKey("recent", kEnd)
    ck b.says("recent.highlight") == "2"
    discard b.sendKey("recent", kHome)
    ck b.says("recent.highlight") == "0"
    expectCount(4)

  test "editing an Input agrees with the vocabulary over ASCII":
    resetCount()
    let b = freshBinding()
    ck b.says("filter.text") == "abc"
    ck b.says("filter.cursor") == "3"
    discard b.sendKey("filter", kLeft)
    ck b.says("filter.cursor") == "2"
    discard b.sendKey("filter", kChar, "Z")
    ck b.says("filter.text") == "abZc"
    ck b.says("filter.cursor") == "3"
    discard b.sendKey("filter", kBackspace)
    ck b.says("filter.text") == "abc"
    expectCount(6)

suite "PLAT-21: THE VERIFICATION GATE":

  test "every entry needing an escape is a filed gap, and every filed gap is taken":
    # PLAT-21: *"The count of vocabulary entries needing a GPUI-specific escape
    # is zero, or each is a named, filed vocabulary defect."*
    #
    # BOTH DIRECTIONS. An unfiled escape is the silent escape the gate exists
    # against; a filed gap nothing takes is a register that has stopped
    # describing the code, which is Verification-Harness-Traps §7a — an
    # assertion of absence that would look the same if everything were present.
    resetCount()
    let b = freshBinding()
    let taken = b.escapedEntries()
    let filed = entriesWithFiledGap()
    if taken != filed:
      checkpoint("escapes taken on a run: " &
                 taken.mapIt(vocabularyName(it)).join(", "))
      checkpoint("entries named by FiledGpuiGaps: " &
                 filed.mapIt(vocabularyName(it)).join(", "))
    ck taken.len > 0            # the §4 floor: a binding that recorded nothing
    ck taken == filed
    ck taken.len == 13
    # Every escape kind the binding can take is filed, by enumeration over the
    # enum rather than over the four somebody thought of.
    for k in GpuiEscapeKind:
      ck gapById(gpuiEscapeGapId(k)).id == gpuiEscapeGapId(k)
    # And all four were actually taken on this view, so none of the four rows
    # is a row nothing exercises.
    ck b.escapeKinds() == {gekKeyInEventName, gekDisabledAttribute,
                           gekModalWithoutFocus, gekImageWithoutPayload}
    expectCount(8)

  test "the three entries that needed NO escape are named, and it is measured":
    # The gate's interesting half. Sixteen entries, thirteen with a filed gap,
    # and THREE that the binding rendered with nothing GPUI-specific at all:
    # `Text`, `ProgressIndicator` and `Markdown`. Asserted as an identity so a
    # future escape in any of the three reddens here rather than growing the
    # register quietly.
    resetCount()
    var clean: seq[ViewKind] = @[]
    for k in ViewKind:
      if gapsFor(k).len == 0: clean.add k
    ck clean == @[pkText, pkProgressIndicator, pkMarkdown]
    # And they really do render: the §4 floor again, because "no escape" and
    # "not rendered" are indistinguishable from the register alone.
    let b = freshBinding()
    ck b.says("title.text") == "Settings"
    ck b.says("load.progress") == "40"
    ck b.says("doc.text").contains("# Title")
    expectCount(4)

  test "the register itself is well formed":
    # A gap whose fields may be blank is a gap that satisfies the gate for
    # free (Verification-Harness-Traps §4).
    resetCount()
    ck FiledGpuiGaps.len == 4
    var ids: seq[string] = @[]
    for g in FiledGpuiGaps:
      ck g.id.startsWith("PLAT21-VG")
      ck g.id notin ids
      ids.add g.id
      ck g.entries.len > 0
      ck g.what.len > 40
      ck g.measured.len > 40
      ck g.remedy.len > 40
    # THREE filed against the RENDERER and ONE against the VOCABULARY, and the
    # split is asserted because conflating them is how a renderer bug sends
    # the next reader to edit the vocabulary.
    var byRenderer = 0
    var byVocabulary = 0
    for g in FiledGpuiGaps:
      case g.subject
      of gsRenderer: inc byRenderer
      of gsVocabulary: inc byVocabulary
    ck byRenderer == 3
    ck byVocabulary == 1
    ck gapById("PLAT21-VG4").subject == gsVocabulary
    ck gapById("PLAT21-VG4").entries == @[pkImage]
    ck describeGaps().contains("PLAT21-VG1")
    expectCount(30)

suite "PLAT-21: the GPUI surface declares its own budget":

  test "gpui-panel is a declared surface, and it is not a borrowed one":
    resetCount()
    ck SurfaceBudgets.len == 8
    var names: seq[string] = @[]
    for b in SurfaceBudgets: names.add b.name
    ck "gpui-panel" in names
    ck GpuiPanelBudget.name == "gpui-panel"
    # The numbers are `state-panel`'s, moved rather than invented — so a
    # difference between the desktop column and the GPUI column is a
    # difference in the RENDERING and not in the budget.
    ck GpuiPanelBudget.depth == StatePanelBudget.depth
    ck GpuiPanelBudget.members == StatePanelBudget.members
    ck GpuiPanelBudget.expandable == StatePanelBudget.expandable
    # `cells: 0` — a GPU surface has no cells. Two of three front-ends decline
    # this field, and the vocabulary's own `0 = unbounded` is what lets them.
    ck GpuiPanelBudget.cells == 0
    ck StatePanelBudget.cells == 0
    ck TuiTreeBudget.cells == 0
    # …and it is NOT the same budget as the terminal's tree, which is what
    # "declares its own" means.
    ck GpuiPanelBudget != TuiTreeBudget
    ck gpuiRowBudget().name == "gpui-row"
    ck gpuiRowBudget().lines == 1
    ck gpuiRowBudget().cells == 0
    expectCount(13)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 176

suite "PLAT-21: the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
