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

suite "PLAT-21: the two renderer defects this milestone measured — REPAIRED BY PLAT-38":

  test "the `disabled` attribute ROUND-TRIPS — PLAT21-VG2, retired":
    # **THIS CASE MEASURED A DEFECT UNTIL 2026-09-22 AND NOW MEASURES ITS
    # REPAIR, AGAINST THE SAME CODE, THE SAME WAY.**
    #
    # What it used to find, quoted so the direction is legible:
    # `isonim-gpui/src/isonim_gpui/renderer.nim`'s `mapAttributeName` rewrote
    # `disabled` to `enabled` and `mapAttributeValue` answered the literal
    # `"false"` for it whatever the caller passed. So
    # `setAttribute(el, "disabled", "true")` left `disabled` reading `""` and
    # `enabled` reading `"false"`, and the sharp half was that saying "this
    # element is ENABLED" recorded it as disabled. Both are the identity now
    # (PLAT-38), and the measurement is made the same way it always was — by
    # writing a value in and reading it back out through the real shim.
    resetCount()
    gpui_reset_tree()
    let r = GpuiRenderer()
    let el = r.createElement("div")
    r.setAttribute(el, "disabled", "true")
    ck renderer.getAttribute(el, "disabled") == "true"
    # The name the renderer used to substitute is not written at all.
    ck renderer.getAttribute(el, "enabled") == ""
    r.setAttribute(el, "disabled", "false")
    ck renderer.getAttribute(el, "disabled") == "false"
    ck renderer.getAttribute(el, "enabled") == ""
    # The shared `data-` fact name still works — it is what the WEB binding
    # writes through the same function, and the binding's escape is gone
    # because the write stopped being renderer-keyed, not because it changed.
    r.setAttribute(el, factAttributeName("disabled"), "false")
    ck renderer.getAttribute(el, factAttributeName("disabled")) == "false"
    let b = freshBinding()
    ck b.says("apply.disabled") == "false"
    expectCount(6)

  test "the renderer's callback ABI CARRIES a key — PLAT21-VG1, retired":
    # **THIS CASE ASSERTED `vockey:` UNTIL 2026-09-22.** `addEventListener`
    # took `proc()`: a handler could not be told which key it was, so the
    # binding put the key in the EVENT NAME and registered one listener per
    # key of an entry's contract. PLAT-38 widened the ABI; the key rides in
    # the payload and `gpuiKeystroke` answers GPUI's own spelling rather than
    # a vocabulary this binding invented.
    resetCount()
    ck gpuiKeystroke(kDown).name == "down"
    ck gpuiKeystroke(kDown).modifiers == {}
    ck gpuiKeystroke(kChar, "Z").name == "Z"
    # The back-tab shares a NAME with the tab and differs only in the
    # modifier, which is how a keyboard produces one — and is the case a
    # decoder matching on the name alone gets wrong silently (§25).
    ck gpuiKeystroke(kBackTab).name == "tab"
    ck gpuiKeystroke(kBackTab).modifiers == {gmShift}
    ck keyFromGpuiKeystroke(gpuiKeystroke(kDown)).key == kDown
    ck keyFromGpuiKeystroke(gpuiKeystroke(kTab)).key == kTab
    ck keyFromGpuiKeystroke(gpuiKeystroke(kBackTab)).key == kBackTab
    ck keyFromGpuiKeystroke(gpuiKeystroke(kChar, "Z")).key == kChar
    ck $keyFromGpuiKeystroke(gpuiKeystroke(kChar, "Z")).ch == "Z"
    # A name this binding never emits decodes to nothing rather than to a
    # plausible key — the mirror, without which the decode could be answering
    # `kDown` to everything.
    ck keyFromGpuiKeystroke(GpuiKeystroke(name: "")).key == kNone
    ck keyFromGpuiKeystroke(GpuiKeystroke(name: "ArrowDown")).key == kNone
    # The names are GPUI's OWN rather than the DOM's or isonim-tui's: a
    # binding that invented a third spelling would make its own decoder and
    # the renderer's encoder agree by construction.
    ck gpuiKeystroke(kDown).name != "ArrowDown"
    ck gpuiKeystroke(kEscape).name == "escape"
    expectCount(14)

  test "there IS element focus in this renderer — PLAT21-VG3, retired":
    # **THIS CASE ASSERTED AN ABSENCE UNTIL 2026-09-22.** `Modal`'s specified
    # behaviour is exclusivity, and the render plan's node shape — the whole
    # of what a GPUI host is handed — had eight fields, none of them a layer,
    # a z-order or a focus. The plan's shape is UNCHANGED (focus is not a
    # render-plan field and was never going to be); what changed is that the
    # element store carries focus and the shim enforces exclusivity, which is
    # asserted through the FFI rather than through the plan.
    resetCount()
    let b = freshBinding()
    let plan = parseJson(b.planJson())
    var keys: seq[string] = @[]
    for k, _ in plan.pairs: keys.add k
    keys.sort()
    ck keys == @["children", "event_names", "has_click_handler",
                 "has_input_handler", "kind", "styles", "tag", "text"]
    # The modal is OPEN in the fixture, so it holds a focus trap and the trap
    # is the exclusivity the entry IS. Read from the Rust side.
    ck b.says("dlg.open") == "true"
    ck sameNode(focusTrapElement(), b.nodes["dlg"])
    ck focusedCount() <= 1
    # An interactive element OUTSIDE the open modal is refused focus.
    ck not b.focusNode("apply")
    # Presence is still carried, as it always was — the body is a fact while
    # the modal is open and absent once it is not — and dismissing releases
    # the trap.
    ck b.says("dlgtext.text") == "Are you sure?"
    discard b.sendKey("dlg", kEscape)
    ck b.says("dlg.open") == "false"
    ck b.says("dlgtext.text") == "<absent>"
    ck focusTrapElement().isNil
    ck b.focusNode("apply")
    expectCount(10)

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
    # **WHAT THIS ASSERTS CHANGED SHAPE IN PLAT-38, AND THE CHANGE IS THE
    # RETIREMENT OF `vockey:` SEEN FROM THE RUST SIDE.** It used to be that
    # an entry's whole keyboard CONTRACT was legible in the plan, because the
    # binding registered one listener per key and spelled the key into the
    # event name. There is one listener per interactive node now, under
    # `keydown`, so what the plan reports is that the node is KEYBOARD-BOUND
    # rather than which keys it answers — and the contract's legibility moved
    # to `keyContract` itself, which is medium-independent and always was.
    #
    # The assertion is kept rather than dropped because it is the only place
    # the retirement is checked from a RUN: a binding that still spelled keys
    # into names would report those names here.
    var expected: seq[string] = @[]
    for n in walk(b.model):
      if n.id notin renderedIds: continue
      if n.kind notin InteractiveKinds: continue
      if keyContract(n.kind).len == 0: continue
      expected.add KeyDownEventName
    planEvents.sort()
    expected.sort()
    ck planEvents.len > 0          # the §4 floor
    ck planEvents.len == 14
    ck planEvents == expected
    # And every reported name IS the one name, so a stray `vockey:` on any
    # node reddens here rather than being averaged away by a length check.
    for e in planEvents:
      ck e == KeyDownEventName
    expectCount(17)

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
    # **WHAT THIS HALF ASSERTS CHANGED IN PLAT-38, AND IT GOT STRONGER.**
    # There used to be one listener per KEY, so an unclaimed key reached no
    # listener at all and `dispatchCount` did not move — which distinguished
    # "the transport declined it" from "`applyKey` declined it". There is one
    # listener per NODE now, so an unclaimed key DOES reach the handler; the
    # counter moves and the model does not. The discriminator is the pair,
    # and the second half comes out of the RUST store rather than out of
    # anything this binding wrote.
    let before = b.says("wrap.checked")
    discard b.sendKey("wrap", kDown)
    ck b.dispatchCount == 3
    ck b.says("wrap.checked") == before
    ck not b.lastOutcome.handled
    # The key ARRIVED — the element store says which one, and says it was a
    # key-down rather than a click. "Nothing happened" and "nothing was
    # delivered" are two states and this is what separates them.
    ck b.nodes["wrap"].lastEventKey() == gpuiKeystroke(kDown).name
    ck b.nodes["wrap"].lastEventKind() == gekKeyDown
    ck b.nodes["wrap"].lastEventSeq() > 0
    # …and firing the event AT THE ELEMENT, with no call into this binding at
    # all, still acts. Nothing on the Nim side was asked to do anything: the
    # listener is registered in the Rust node's own map and the callback id
    # comes back through `globalDispatcher`.
    ck b.says("live.checked") == "false"
    discard fireEvent(b.nodes["live"], KeyDownEventName, gpuiPayloadFor(kSpace))
    ck b.dispatchCount == 4
    b.rerender()
    ck b.says("live.checked") == "true"
    expectCount(12)

  test "a key in the contract acts, and a key outside it does nothing":
    resetCount()
    let b = freshBinding()
    ck b.says("wrap.checked") == "false"
    let hit = b.sendKey("wrap", kSpace)
    ck hit.handled
    ck hit.transition == trCheck
    ck b.says("wrap.checked") == "true"
    # Down is not in `Checkbox`'s contract. Since PLAT-38 it still ARRIVES —
    # the node has one listener for every key — and the entry declines it.
    # The pair is the statement: the element store says the key came, and the
    # fact says nothing moved.
    let miss = b.sendKey("wrap", kDown)
    ck not miss.handled
    ck miss.transition == trNone
    ck b.says("wrap.checked") == "true"
    ck b.nodes["wrap"].lastEventKey() == gpuiKeystroke(kDown).name
    expectCount(8)

  test "motion skips an unavailable option, on this medium too":
    resetCount()
    let b = freshBinding()
    ck b.says("recent.highlight") == "0"
    discard b.sendKey("recent", kDown)
    # PAST `beta`, which is disabled. The option's availability is carried
    # under the shared `data-` fact name — which is what the WEB binding
    # writes too. Until PLAT-38 that prefix was also what SAVED it from the
    # renderer's `disabled` rewrite; the rewrite is gone (PLAT21-VG2,
    # retired) and the name is unchanged, because it was always the shared
    # name rather than an escape.
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
    # **THIRTEEN UNTIL 2026-09-22, ONE NOW.** PLAT-38 retired three of the
    # four filed gaps, and the register shrank because the BINDING STOPPED
    # ESCAPING — which is the direction the risk mitigation asks for. A gap
    # cannot retire here because the renderer grew a capability; it retires
    # because this run reports one fewer escape.
    ck taken.len == 1
    ck taken == @[pkImage]
    # Every escape kind the binding can take is filed, by enumeration over the
    # enum rather than over the ones somebody thought of.
    for k in GpuiEscapeKind:
      ck gapById(gpuiEscapeGapId(k)).id == gpuiEscapeGapId(k)
    # And the one that remains was actually taken on this view, so the row is
    # not a row nothing exercises.
    ck b.escapeKinds() == {gekImageWithoutPayload}
    expectCount(6)

  test "the entries that needed NO escape are named, and it is measured":
    # The gate's interesting half. Sixteen entries, and PLAT-21 measured
    # THREE that the binding rendered with nothing GPUI-specific at all:
    # `Text`, `ProgressIndicator` and `Markdown`. **It is FIFTEEN now** —
    # everything except `Image`, whose gap is against the VOCABULARY and which
    # no change to isonim-gpui could ever have closed. Asserted as an identity
    # so a future escape in any of them reddens here rather than growing the
    # register quietly.
    resetCount()
    var clean: seq[ViewKind] = @[]
    for k in ViewKind:
      if gapsFor(k).len == 0: clean.add k
    ck clean.len == 15
    ck pkImage notin clean
    for k in [pkText, pkProgressIndicator, pkMarkdown, pkModal, pkButton,
              pkTable]:
      ck k in clean
    # And they really do render: the §4 floor again, because "no escape" and
    # "not rendered" are indistinguishable from the register alone.
    let b = freshBinding()
    ck b.says("title.text") == "Settings"
    ck b.says("load.progress") == "40"
    ck b.says("doc.text").contains("# Title")
    ck b.says("dlg.open") == "true"
    expectCount(12)

  test "the register itself is well formed, and the shrink is an identity":
    # A gap whose fields may be blank is a gap that satisfies the gate for
    # free (Verification-Harness-Traps §4).
    resetCount()
    ck FiledGpuiGaps.len == 1
    var ids: seq[string] = @[]
    for g in FiledGpuiGaps:
      ck g.id.startsWith("PLAT21-VG")
      ck g.id notin ids
      ids.add g.id
      ck g.entries.len > 0
      ck g.what.len > 40
      ck g.measured.len > 40
      ck g.remedy.len > 40
    # The one that remains is filed against the VOCABULARY, which is why it is
    # the one that remains: conflating the two subjects is how a renderer bug
    # sends the next reader to edit the vocabulary.
    var byRenderer = 0
    var byVocabulary = 0
    for g in FiledGpuiGaps:
      case g.subject
      of gsRenderer: inc byRenderer
      of gsVocabulary: inc byVocabulary
    ck byRenderer == 0
    ck byVocabulary == 1
    ck gapById("PLAT21-VG4").subject == gsVocabulary
    ck gapById("PLAT21-VG4").entries == @[pkImage]
    ck describeGaps().contains("PLAT21-VG4")
    # **THE SHRINK, AS AN IDENTITY.** PLAT-21 filed four; three are retired.
    # `filed ∪ retired` must still be those four — a gap that vanished from
    # both registers is a claim that stopped being recorded, and an id in both
    # is a retirement nobody finished.
    var ever = everFiledGapIds()
    ever.sort()
    ck ever == @["PLAT21-VG1", "PLAT21-VG2", "PLAT21-VG3", "PLAT21-VG4"]
    ck RetiredGpuiGaps.len == 3
    for g in RetiredGpuiGaps:
      ck g.subject == gsRenderer     # all three were the renderer's
      ck isRetired(g.id)
      ck g.id notin filedGapIds()
      ck g.entries.len > 0
      ck g.repairedIn.len > 40
      ck g.evidence.len > 40
    ck not isRetired("PLAT21-VG4")   # the negative twin on the one predicate
    ck retiredGapById("PLAT21-VG1").entries.len == 12
    ck retiredGapById("PLAT21-VG2").entries.len == 12
    ck retiredGapById("PLAT21-VG3").entries == @[pkModal]
    expectCount(36)

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
const ExpectedAssertions = 217

suite "PLAT-21: the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
