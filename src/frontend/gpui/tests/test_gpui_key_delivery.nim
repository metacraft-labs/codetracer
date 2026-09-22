## test_gpui_key_delivery.nim — PLAT-38. **The gate: a key reaches a view with
## its payload, an attribute round-trips under its own name, and an element
## holds focus.**
##
## ## WHAT THIS FILE IS FOR, AND WHAT IT REFUSES TO GRADE
##
## PLAT-21 filed three gaps against `isonim-gpui` and counted the entries each
## one affects: a key could not be DELIVERED (12 entries), `disabled` was
## destroyed on the way in and unreadable on the way out (12), and there was no
## ELEMENT focus, so `Modal`'s exclusivity — which is what that entry IS —
## could not be expressed (1). All three were at the **C ABI**, not at the view
## layer: `EventCallback` was `extern "C" fn()`, `gpui_dispatch_event` carried
## no payload, and a repo-wide search of the shim for `key_down`, `on_key`,
## `focus_handle`, `track_focus` or `key_context` returned zero code hits.
##
## **THERE IS AN EMULATION IN THIS WORKSPACE THAT MUST NOT BE MISTAKEN FOR THE
## REPAIR.** `isonim-render-serve/src/isonim_render_serve/adapters/
## gpui_input_adapter.nim` has two arms: one logs *"key event ignored"*, and
## one routes a keyboard event through the SHADOW TREE with a synthesised focus
## sink — `fireEvent(sink.focusedNode, "keydown")`, where `focusedNode` is the
## launcher's last hit-tested click target. That is adapter-level emulation
## over the payload-free ABI, and a case graded against it would be grading the
## emulation.
##
## So **every key assertion here reads the RUST-SIDE ELEMENT STORE**
## (`gpui_last_event_key`, `gpui_last_event_modifiers`, `gpui_last_event_seq`,
## `gpui_event_delivery_count`), which the shim writes before any callback runs
## and which nothing on the Nim side can write at all. The emulation leaves
## every one of those readings at its initial value.
##
## ## THE FLOOR, AND WHERE EACH TERM IS
##
## PLAT-38 publishes `FLOOR: 46 cases`. They are here in this order:
##
##   12  a key delivered with its payload, per interactive entry
##   12  an attribute round-tripping under its own name, per interactive entry
##    5  element focus over the five panes GPUI expresses
##    3  focus forward, focus backward, focus exclusive
##    5  the escape census retaken in both directions
##    6  a real keystroke through `wl_seat`, per pinned scenario
##    1  the unfocused negative twin
##    2  the vision witness (see the suite at the bottom: the claim it makes
##       is PLAT-37's — there is a window and its pixels are not a blank
##       screen — because the key changes no PIXELS on this product yet),
##       and its blank control
##
## The two 12s are the SAME twelve entries asserted about two different things,
## admitted under `Editor-Model-Conformance-Suite.md` §10.4 rule 2: a key
## arriving and an attribute round-tripping are different claims, each of which
## can fail without the other. **If a reviewer rejects that argument the floor
## is 34**, and PLAT-38 records the alternative so the rejection is a decision
## rather than a silent adjustment.
##
## ## THE LAST NINE READ A RECORD, AND THE RECORD HAS TWO SOURCES
##
## The compositor cases follow PLAT-37's arrangement exactly, because the
## reason is the same: the assertions are Nim and a suite that had to run
## *inside* a nested sway would be a suite nobody can run from an editor.
##
##   `source=live`      `build/plat38/manifest.json` and the store dumps it
##                      names are on this disk, so the record is read HERE.
##   `source=recorded`  they are not, so the record is the committed
##                      `src/tests/visual/plat38-keystrokes.json`.
##
## **The source is PRINTED and is never silent.** Neither source is a skip: a
## missing record is a named failure, because a green run over no capture is
## worth less than a red one (`Silent-Self-Pass-Audit-2026-08-23.md`).
##
## ## NO MOCKS
##
## `GpuiRenderer` is isonim-gpui's real renderer and the element tree is the
## real Rust shim's. There is no mock compositor, no fake keystroke and no
## synthetic store dump.

import std/[algorithm, os, sequtils, strutils, tables, unittest]

import isonim_gpui/renderer
import isonim_gpui/bindings

import ../../../common/view_vocabulary
import ../../view_vocabulary/gpui_binding as gbind
import ../../view_vocabulary/fact_reader
import ./plat38_keys

const ExpectedAssertions = 471
  ## Written from a run, and asserted against the tally in the final case.
  ## Printed as `CHECKS:` for the lane, which is preferred over the constant
  ## because a static one cannot see a case that returned early.

var countedAssertions = 0

template ck(condition: untyped) =
  ## A TEMPLATE, not a proc. A `unittest.check` inside a plain `proc` writes
  ## the module-level `testStatusIMPL`, so the test reports `[OK]` with the
  ## failed comparison printed directly above it
  ## (`Verification-Harness-Traps.md` §29).
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# The population: the TWELVE interactive entries, derived rather than listed
# ---------------------------------------------------------------------------

const InteractivePopulation = InteractiveKinds
  ## **NOT A LIST THIS MILESTONE WROTE.** `vocabulary.InteractiveKinds` is the
  ## set the vocabulary itself declares, and `gpui_gaps`'s retired `PLAT21-VG1`
  ## and `PLAT21-VG2` rows each name the same twelve. A sweep over the entries
  ## somebody remembered is `Verification-Harness-Traps.md` §34; the case
  ## "the population is the twelve interactive entries" asserts all three
  ## agree, in both directions.

proc opt(id, label: string; disabled = false): ViewOption =
  ViewOption(id: id, label: label, disabled: disabled)

proc nodeFor(k: ViewKind; id: string): ViewNode =
  ## One rendered node per entry, exhaustive over `ViewKind` so a seventeenth
  ## entry cannot arrive without this function refusing to compile.
  case k
  of pkText: viewText(id, "text")
  of pkButton: viewButton(id, "Apply")
  of pkCheckbox: viewCheckbox(id, "Wrap")
  of pkToggle: viewToggle(id, "Live")
  of pkInput: viewInput(id, "abc")
  of pkSelect: viewSelect(id, @[opt("a", "A"), opt("b", "B")], selected = 0)
  of pkList: viewList(id, @[opt("a", "A"), opt("b", "B")])
  of pkTree: viewTreeNode(id, "locals", @[viewTreeNode(id & ".x", "x")],
                          expanded = true)
  of pkTable: viewTable(id, @["n", "v"], @[@["a", "1"], @["b", "2"]])
  of pkTabs: viewTabs(id, @[opt("t1", "Source"), opt("t2", "State")])
  of pkCollapsible: viewCollapsible(id, "Panel", @[viewText(id & ".t", "t")],
                                    expanded = true)
  of pkModal: viewModal(id, "Confirm", @[viewButton(id & ".ok", "OK")],
                        open = true)
  of pkMenu: viewMenu(id, @[opt("m1", "Copy"), opt("m2", "Paste")])
  of pkProgressIndicator: viewProgress(id, 40)
  of pkImage: viewImage(id, "image/png", "alt", 2048)
  of pkMarkdown: viewMarkdown(id, "# T")

proc soloBinding(k: ViewKind): GpuiBinding =
  ## One entry, alone, under a container root — so a case about `Tabs` cannot
  ## be satisfied by something a neighbouring `List` did.
  gpui_reset_tree()
  resetCallbacks()
  renderGpui(GpuiRenderer(),
             viewCollapsible("root", "root", @[nodeFor(k, "subject")],
                             expanded = true))

proc firstContractKey(k: ViewKind): Key =
  for b in keyContract(k):
    if b.key != kChar: return b.key
  kNone

proc says(b: GpuiBinding; key: string): string =
  ## One observable fact, out of the SHIM's element store through the shared
  ## reader — never echoed from the `ViewNode`. `<absent>` rather than `""`
  ## so "the fact is missing" and "the fact is empty" are two readings.
  for f in b.readGpuiFacts():
    if f.id & "." & f.field == key: return f.value
  "<absent>"

# ---------------------------------------------------------------------------
# 12 — A KEY REACHES A VIEW WITH ITS PAYLOAD (PLAT21-VG1)
# ---------------------------------------------------------------------------

suite "PLAT-38: a key is delivered, with its payload, to every interactive entry":

  for entry in InteractivePopulation:
    let name = vocabularyName(entry)
    test "a key reaches " & name & " and the RUST store says which key":
      let b = soloBinding(entry)
      let k = firstContractKey(entry)
      # The §4 floor, first: this entry really does have a key to send. An
      # entry with an empty contract would make every assertion below vacuous.
      ck k != kNone
      let el = b.nodes["subject"]
      ck el.lastEventSeq() == 0        # nothing has arrived yet
      let outcome = b.sendKey("subject", k)
      # THE ORACLE. Not `outcome`, not `b.lastKeyReceived` — both of those are
      # surfaces this side built (§4a). These four come back across the FFI
      # boundary out of the node's own record, written by the shim before any
      # callback ran.
      ck el.lastEventKey() == gpuiKeystroke(k).name
      ck el.lastEventModifiers() == gpuiKeystroke(k).modifiers
      ck el.lastEventKind() == gekKeyDown
      ck el.lastEventName() == KeyDownEventName
      ck el.lastEventSeq() > 0
      ck el.deliveryCount() == 1
      # …and the binding ACTED on the key it was handed rather than on a key
      # it assumed: `keyFromGpuiEvent` decodes the payload, so a dispatch that
      # arrived carrying the wrong key produces the wrong outcome here.
      ck b.lastKeyReceived.key == gpuiKeystroke(k).name
      ck keyFromGpuiEvent(b.lastKeyReceived).key == k
      ck outcome.handled
      # THE NEGATIVE TWIN, at the entry level: a SECOND key, one this entry
      # does not claim, still arrives and changes the record — so "the store
      # has something in it" cannot be satisfied by a stale reading.
      #
      # **THE ELEMENT IS RE-READ FROM `b.nodes` AND THAT IS NOT INCIDENTAL.**
      # A handled key re-renders, which builds an entirely NEW element tree,
      # so the handle above refers to a node nothing dispatches to any more.
      # Holding it would have made this half a reading of the PREVIOUS key —
      # which is exactly what it was until a run said so: `lastEventSeq()`
      # came back unchanged and `lastEventKey()` came back `enter`, the key
      # the first half had sent.
      let firstSeq = b.nodes["subject"].lastEventSeq()
      discard b.sendKey("subject", kBackTab)
      let after = b.nodes["subject"]
      ck after.lastEventSeq() > firstSeq
      ck after.lastEventKey() == gpuiKeystroke(kBackTab).name
      ck after.lastEventModifiers() == {gmShift}
      # …and the key it does not claim changed nothing: the pair is the claim,
      # because "the event fired" is true of a binding that acts on
      # everything.
      ck not b.lastOutcome.handled

# ---------------------------------------------------------------------------
# 12 — AN ATTRIBUTE ROUND-TRIPS UNDER ITS OWN NAME (PLAT21-VG2)
# ---------------------------------------------------------------------------

suite "PLAT-38: an attribute round-trips under the name it was written with":

  for entry in InteractivePopulation:
    let name = vocabularyName(entry)
    test "disabled round-trips on " & name & ", both polarities":
      let b = soloBinding(entry)
      let el = b.nodes["subject"]
      # BOTH POLARITIES, because the defect this replaces was a CONSTANT FOLD:
      # `mapAttributeValue` answered the literal `"false"` whatever it was
      # given, so a one-polarity case passed while "enabled" recorded
      # "disabled". One value cannot see a fold; two can.
      for v in ["true", "false"]:
        b.renderer.setAttribute(el, DisabledFactName, v)
        ck getAttribute(el, DisabledFactName) == v
      # And the name the renderer used to substitute is not written at all.
      # This is the half `getAttribute` could not reach before, because it
      # never mapped the name it was asked for.
      ck getAttribute(el, "enabled") == ""
      # The shared `data-` fact name still round-trips too — it is what the
      # WEB binding writes through the same function, and the binding's
      # escape is gone because the write stopped being renderer-keyed rather
      # than because it changed.
      b.renderer.setAttribute(el, factAttributeName(DisabledFactName), "true")
      ck getAttribute(el, factAttributeName(DisabledFactName)) == "true"
      # The §4 floor: this element really is in the shim's store, so the
      # readings above are about something.
      ck getAttribute(el, ViewKindAttribute) == name

# ---------------------------------------------------------------------------
# 5 — ELEMENT FOCUS OVER THE FIVE PANES GPUI EXPRESSES
# ---------------------------------------------------------------------------

const GpuiPaneEntries = @[pkTabs, pkTree, pkCollapsible, pkList, pkTable]
  ## The five PLAT-21 renders as the debugger's panes — state (`Tabs` +
  ## `Tree` + `Collapsible`), call trace and tracepoints (`List`), event log
  ## (`Table`). Named here as the entries rather than as the panes because
  ## this suite links no ViewModel; the pane-level reading is
  ## `test_cross_renderer_panes.nim`'s.

suite "PLAT-38: element focus, over the panes GPUI expresses":

  for entry in GpuiPaneEntries:
    let name = vocabularyName(entry)
    test "focus is held, exclusively, by a " & name & " pane":
      let b = soloBinding(entry)
      # Nothing holds focus until something is given it, and the count is
      # taken over the WHOLE element store rather than over this node.
      ck focusedCount() == 0
      ck b.focusNode("subject")
      ck focusedCount() == 1
      ck b.focusedNodeId() == "subject"
      ck isFocused(b.nodes["subject"])
      # A key routed to focus lands HERE and nowhere else.
      let win = gpui_create_window("t", 100, 100)
      discard gpui_show_window(win)
      gpui_notify_focus(win, 1)
      let k = firstContractKey(entry)
      ck k != kNone
      let reached = sendKeyToFocus(KeyDownEventName, gpuiPayloadFor(k))
      ck reached == 1
      ck b.nodes["subject"].lastEventKey() == gpuiKeystroke(k).name
      # THE PANE'S OWN CONTAINER did not receive it. "The key arrived" is true
      # of a renderer that delivers to everything.
      ck b.nodes["root"].lastEventSeq() == 0
      gpui_reset_windows()

# ---------------------------------------------------------------------------
# 3 — FOCUS MOVES FORWARD, MOVES BACKWARD, AND IS EXCLUSIVE
# ---------------------------------------------------------------------------

proc focusFixture(): GpuiBinding =
  ## Three interactive siblings in a known document order, plus a `Text` that
  ## is NOT interactive — so "everything is focusable" and "the declared order
  ## is the interactive nodes" are different readings.
  gpui_reset_tree()
  resetCallbacks()
  renderGpui(GpuiRenderer(), viewCollapsible("root", "root", @[
    viewText("label", "not focusable"),
    viewButton("one", "One"),
    viewCheckbox("two", "Two"),
    viewToggle("three", "Three")], expanded = true))

suite "PLAT-38: focus moves through the declared order, and is exclusive":

  test "focus moves FORWARD through the order the render tree declares":
    let b = focusFixture()
    # THE ORDER IS READ FROM THE RUST SIDE. `PLAT35-VG4` was filed because
    # GPUI's order was "declared by the leaf renderer and enforced by
    # nothing"; it is enforced by the renderer now and `focusOrder()` reads it
    # back rather than recomputing it here.
    let order = focusOrder()
    # **FOUR, NOT THREE, AND THE FOURTH IS THE CONTAINER.** `root` is a
    # `Collapsible`, which is one of the twelve INTERACTIVE entries — its
    # contract is Enter and Space — so the binding declares it focusable too.
    # The case expected three until a run said four, and the run was right:
    # an order that skipped an interactive container would be an order the
    # keyboard could not reach it through.
    ck order.len == 4
    ck sameNode(order[0], b.nodes["root"])
    ck sameNode(order[1], b.nodes["one"])
    ck sameNode(order[2], b.nodes["two"])
    ck sameNode(order[3], b.nodes["three"])
    # The NON-interactive node is not in it, which is what makes the order a
    # claim about keyboard contracts rather than a traversal of the tree.
    for el in order:
      ck not sameNode(el, b.nodes["label"])
    ck b.focusNode("one")
    ck focusNext()
    ck b.focusedNodeId() == "two"
    ck focusNext()
    ck b.focusedNodeId() == "three"
    ck focusNext()
    ck b.focusedNodeId() == "root"     # wraps, rather than clamping (§36a)

  test "focus moves BACKWARD through the same order":
    let b = focusFixture()
    ck b.focusNode("one")
    ck focusPrev()
    ck b.focusedNodeId() == "root"     # backward from the first, to the root
    ck focusPrev()
    ck b.focusedNodeId() == "three"    # …and from the root it wraps to the last
    ck focusPrev()
    ck b.focusedNodeId() == "two"
    # Forward-then-backward is the identity, which a one-directional
    # implementation that simply re-entered the list would also satisfy — so
    # the wrap above is what carries this case and this is the corroboration.
    ck focusNext()
    ck focusPrev()
    ck b.focusedNodeId() == "two"

  test "THE FOCUS PARTITION — at most one element holds focus, ever":
    # **READ THE KILLER AGAINST THE IMPLEMENTATION BEFORE TRUSTING THE LAW**
    # (§36). If focus were stored as a single id on the tree, "exactly zero or
    # one element holds it" would be true by construction and the published
    # killing mutation — *let two elements hold it* — could not be performed.
    # It is a PER-NODE FLAG in `rust/gpui-nim-shim/src/tree.rs`, cleared by a
    # pass over every node, and `gpui_focused_count` counts them; so the law
    # can fail and the arm lands.
    let b = focusFixture()
    ck focusedCount() == 0
    var seen: seq[int] = @[]
    for id in ["one", "two", "three", "one"]:
      ck b.focusNode(id)
      seen.add focusedCount()
    ck seen == @[1, 1, 1, 1]
    # Blurring leaves ZERO, which is the other half of "zero or one" and is
    # the half a suite that only ever focuses never reaches.
    blurElement(b.nodes["one"])
    ck focusedCount() == 0
    # And a node with no keyboard contract refuses, so the partition is not
    # maintained by everything being focusable.
    ck not b.focusNode("label")
    ck focusedCount() == 0

# ---------------------------------------------------------------------------
# 5 — THE ESCAPE CENSUS, RETAKEN FROM A RUN, IN BOTH DIRECTIONS
# ---------------------------------------------------------------------------

proc wholeVocabulary(): ViewNode =
  viewCollapsible("panel", "Debug settings", @[
    viewText("title", "Settings"),
    viewButton("apply", "Apply"),
    viewCheckbox("wrap", "Wrap"),
    viewToggle("live", "Live"),
    viewInput("filter", "abc"),
    viewSelect("lang", @[opt("rs", "Rust"), opt("py", "Python")], selected = 0),
    viewList("recent", @[opt("a", "alpha"), opt("b", "beta", disabled = true)]),
    viewTreeNode("state", "locals", @[viewTreeNode("state.x", "x")],
                 expanded = true),
    viewTable("tbl", @["name", "value"], @[@["a", "1"]]),
    viewTabs("panes", @[opt("t1", "Source"), opt("t2", "State")]),
    viewMenu("ctx", @[opt("m1", "Copy")]),
    viewProgress("load", 40),
    viewImage("shot", "image/png", "a screenshot of the state panel", 2048),
    viewMarkdown("doc", "# Title"),
    viewModal("dlg", "Confirm", @[viewButton("dlgok", "OK")], open = true)],
    expanded = true)

proc vocabularyBinding(): GpuiBinding =
  gpui_reset_tree()
  resetCallbacks()
  renderGpui(GpuiRenderer(), wholeVocabulary())

suite "PLAT-38: the escape census, retaken from a run, in both directions":

  test "PLAT21-VG1 is RETIRED, and the retirement is conditioned on delivery":
    # **A RETIREMENT MUST NOT FIRE ON A RUN IN WHICH NOTHING HAPPENED.**
    # `PLAT35-VG7` was retired against the one run in six where the GPUI
    # locals never arrived: two empty answers compared equal, the question
    # agreed, and the retirement case then demanded the gap go. So the
    # positive evidence is demanded FIRST and the absence is asserted second.
    let b = vocabularyBinding()
    let el = b.nodes["wrap"]
    discard b.sendKey("wrap", kSpace)
    ck el.lastEventKey() == gpuiKeystroke(kSpace).name
    ck el.lastEventSeq() > 0
    ck el.deliveryCount() == 1
    ck b.says("wrap.checked") == "true"
    # …and ONLY THEN the absence.
    ck isRetired("PLAT21-VG1")
    ck "PLAT21-VG1" notin filedGapIds()
    ck gekImageWithoutPayload in b.escapeKinds()
    ck b.escapeKinds() == {gekImageWithoutPayload}
    # The retirement row carries the evidence it was conditioned on, so a
    # reader is not left to infer it from a green run.
    ck retiredGapById("PLAT21-VG1").evidence.contains("element store")

  test "PLAT21-VG2 is RETIRED, and the retirement is conditioned on a read-back":
    let b = vocabularyBinding()
    let el = b.nodes["apply"]
    b.renderer.setAttribute(el, DisabledFactName, "false")
    ck getAttribute(el, DisabledFactName) == "false"
    b.renderer.setAttribute(el, DisabledFactName, "true")
    ck getAttribute(el, DisabledFactName) == "true"
    ck getAttribute(el, "enabled") == ""
    ck isRetired("PLAT21-VG2")
    ck "PLAT21-VG2" notin filedGapIds()
    ck retiredGapById("PLAT21-VG2").evidence.contains("polarities")

  test "PLAT21-VG3 is RETIRED, and the retirement is conditioned on a trap":
    let b = vocabularyBinding()
    # The modal is open, so it traps.
    ck b.says("dlg.open") == "true"
    ck sameNode(focusTrapElement(), b.nodes["dlg"])
    ck focusedCount() == 1
    # Focus moved INSIDE when the modal opened, and it landed on the MODAL
    # itself rather than on its button: `Modal` is interactive (its contract
    # is Escape), so it is the first focusable node in its own subtree. The
    # case expected `dlgok` until a run said `dlg`, and the run was right —
    # a trap whose first stop skipped the region that owns the Escape binding
    # would be a trap the user could not dismiss from.
    ck b.focusedNodeId() == "dlg"
    ck not b.focusNode("apply")        # the outside is refused
    ck isRetired("PLAT21-VG3")
    ck "PLAT21-VG3" notin filedGapIds()
    ck retiredGapById("PLAT21-VG3").evidence.contains("trap")

  test "Modal is EXPRESSIBLE, and the mapping table says so":
    # PLAT-3's `msAbsent` row for `Modal` was the last one in the GPUI column.
    ck mappingFor(feGpui, pkModal).status == msPartial
    ck absentEntryNames(feGpui).len == 0
    # …and the exclusivity is the thing that moved it, demonstrated rather
    # than asserted from the table: opening traps, dismissing releases.
    let b = vocabularyBinding()
    ck not focusTrapElement().isNil
    discard b.sendKey("dlg", kEscape)
    ck b.says("dlg.open") == "false"
    ck focusTrapElement().isNil
    ck b.focusNode("apply")

  test "THE CENSUS — escapes taken on a run EQUAL the filed register":
    # BOTH DIRECTIONS. An unfiled escape is the silent escape the gate exists
    # against; a filed gap nothing takes is a register that has stopped
    # describing the code.
    let b = vocabularyBinding()
    let taken = b.escapedEntries()
    let filed = entriesWithFiledGap()
    if taken != filed:
      checkpoint("escapes taken on a run: " &
                 taken.mapIt(vocabularyName(it)).join(", "))
      checkpoint("entries named by FiledGpuiGaps: " &
                 filed.mapIt(vocabularyName(it)).join(", "))
    ck taken.len > 0                   # the §4 floor
    ck taken == filed
    ck taken == @[pkImage]
    # THE IDENTITY OVER THE ENTRIES THAT NEED NOTHING. Fifteen of sixteen,
    # asserted as a set so a future escape reddens here rather than growing
    # the register quietly — and the shrink is asserted against the union, so
    # a gap that vanished from both registers cannot pass.
    var clean: seq[ViewKind] = @[]
    for k in ViewKind:
      if gapsFor(k).len == 0: clean.add k
    ck clean.len == 15
    ck pkModal in clean
    var ever = everFiledGapIds()
    ever.sort()
    ck ever == @["PLAT21-VG1", "PLAT21-VG2", "PLAT21-VG3", "PLAT21-VG4"]
    ck RetiredGpuiGaps.len == 3
    ck FiledGpuiGaps.len == 1

# ---------------------------------------------------------------------------
# THE POPULATION, AND THE SOURCE SCAN — laws, not cases in the floor
# ---------------------------------------------------------------------------

suite "PLAT-38: the population and the retirement of `vockey:`":

  test "THE POPULATION IS THE TWELVE INTERACTIVE ENTRIES, from three sources":
    # §34: a sweep over the entries somebody remembered. The count is taken
    # from the vocabulary's own set, from PLAT21-VG1's retired row and from
    # PLAT21-VG2's, and all three are compared — in both directions, with the
    # cardinality, because two set differences are both satisfied by two
    # empty sets.
    var fromVocabulary: seq[ViewKind] = @[]
    for k in ViewKind:
      if k in InteractiveKinds: fromVocabulary.add k
    let fromVg1 = retiredGapById("PLAT21-VG1").entries
    let fromVg2 = retiredGapById("PLAT21-VG2").entries
    ck fromVocabulary.len == 12
    ck fromVg1.len == 12
    ck fromVg2.len == 12
    ck fromVocabulary.sorted() == fromVg1.sorted()
    ck fromVocabulary.sorted() == fromVg2.sorted()
    # …and every one of them has a keyboard contract, which is what makes
    # "interactive" mean something a key can be sent to.
    var withContract = 0
    for k in fromVocabulary:
      if keyContract(k).len > 0: inc withContract
    ck withContract == 12
    # THE NEGATIVE TWIN: the four that are NOT in the population have no
    # contract, so the set is not "every entry".
    var without = 0
    for k in ViewKind:
      if k notin InteractiveKinds:
        ck keyContract(k).len == 0
        inc without
    ck without == 4

  test "THE SCAN'S SUBJECT SET is derived from the directory, and is non-empty":
    # **THE SUBJECT SET IS DERIVED FROM THE DIRECTORY, NOT LISTED HERE** (§35).
    # A hardcoded subject list cannot see a new file in the directory it
    # claims to cover, and that route has been walked seven times in this
    # campaign — most recently by a probe in a directory the file set covered
    # but the import closure did not.
    let dir = bindingDirectory()
    ck dirExists(dir)
    var scanned: seq[string] = @[]
    var body = ""
    for kind, path in walkDir(dir):
      if kind != pcFile: continue
      if not path.endsWith(".nim"): continue
      scanned.add extractFilename(path)
      body.add codeOnly(readFile(path))
    scanned.sort()
    # THE POSITIVE CONTROLS, first and in three forms, because a scan that
    # matched nothing satisfies every "must not contain" written over it (§4):
    # the directory listed FILES, the read produced BYTES, and the bytes
    # contain a spelling that IS there.
    ck scanned.len >= 4
    ck "gpui_binding.nim" in scanned
    ck body.len > 5000
    ck body.contains("KeyDownEventName")
    # …and the subject set is what the NEXT case scans. The two are separate
    # cases because they are separate claims: a subject set that went empty
    # and a needle that could not be derived are different defects, and each
    # can happen without the other.
    ck body.contains("gpuiKeystroke")

  test "THE NEEDLE is derived from the retired gap, and `vockey:` is GONE":
    # THE NEEDLE IS DERIVED FROM THE BINDING'S OWN RECORDED HISTORY rather
    # than being a literal (§35's fifth-file route, walked four times in this
    # campaign). `retiredKeyEventPrefix` reads the spelling out of
    # `RetiredGpuiGaps`' `PLAT21-VG1` row, so a milestone that reinstated the
    # spelling under a different constant name would still be caught — and a
    # milestone that DELETED the retired row makes the derivation raise
    # rather than answer an empty string, because `contains("")` is true of
    # every file and is the most expensive false green a scan can produce.
    let dir = bindingDirectory()
    var body = ""
    for kind, path in walkDir(dir):
      if kind != pcFile: continue
      if not path.endsWith(".nim"): continue
      body.add codeOnly(readFile(path))
    ck body.len > 5000                 # the §4 floor, again and locally
    let needle = retiredKeyEventPrefix()
    ck needle == "vockey:"
    ck not body.contains(needle)
    # AND THE PLANTED POSITIVE CONTROL: the same stripper, over a string that
    # DOES carry the needle, must find it — and over a COMMENT carrying it,
    # must not (§4d: a scan a comment can satisfy is a scan prose can move).
    ck codeOnly("let x = \"" & needle & "Down\"").contains(needle)
    ck not codeOnly("## a comment mentioning " & needle).contains(needle)

# ---------------------------------------------------------------------------
# 6 + 1 + 2 — THE COMPOSITOR, READ FROM A RECORD
# ---------------------------------------------------------------------------

let record = keystrokeRecord()

suite "PLAT-38: a real keystroke through the compositor's own wl_seat":

  test "the record's provenance is stated, and the source is printed":
    # Printed, never silent. A recorded capture with no date is a capture
    # nobody can age, and a source nobody prints is a source nobody checks.
    echo "PLAT38 RECORD source=", record.source, " taken=", record.takenAt,
         " host=", record.host, " scenarios=", record.scenarios.len
    ck record.source in ["live", "recorded"]
    ck record.takenAt.len >= 10
    ck record.host.len > 0
    ck record.scenarios.len == 6

  for i in 0 ..< PinnedScenarioCount:
    let scenarioIndex = i
    test "scenario " & $scenarioIndex & ": a wl_seat key reached the store":
      let s = record.scenarios[scenarioIndex]
      ck s.name.len > 0
      ck s.outcome == "delivered"
      # THE ORACLE IS THE RUST-SIDE ELEMENT STORE, dumped by the process that
      # received the key. Not a log line, not an exit code: the key name, the
      # modifier bits and the delivery sequence the shim recorded before any
      # callback ran.
      ck s.arrivals.len >= 1
      ck s.deliverySeq > 0
      ck s.deliveryCount >= 1
      for a in s.arrivals:
        ck a.key.len > 0
        ck a.kind == "keydown"
        ck a.seq > 0
      # THE MODIFIER SURVIVED THE COMPOSITOR (§25). Asserted by NAME on the
      # scenario that sends one, and asserted ABSENT on the others, because a
      # transport reporting everything as shifted would satisfy "shift seen".
      if s.expectModifier.len > 0:
        ck s.expectModifier in s.arrivals[^1].modifiers
      else:
        ck s.arrivals[^1].modifiers.len == 0
      # AND THE WINDOW WAS FOCUSED. A key routed while the window held no
      # focus is the negative twin below and must not be confusable with this.
      ck s.windowFocused

  test "THE KEY IDENTITY — the binding's spellings are the COMPOSITOR's":
    # **THE SECOND ORACLE, AND IT EXISTS BECAUSE AN ARM SURVIVED.**
    # `gpuiKeystroke` encodes a `behaviour.Key` into GPUI's spelling and
    # `keyFromGpuiKeystroke` decodes it back — and the decoder compares
    # against `gpuiKeystroke(k).name`, so the two are each other's inverse BY
    # CONSTRUCTION. Every case in this suite driven by `sendKey` therefore
    # agrees with itself about what a key is called, and a wrong spelling is
    # invisible to all of them: mutation arm `B2` changes `escape` to `esc`
    # and SURVIVED every one of them. That is
    # `Verification-Harness-Traps.md` §30a in this milestone's own binding.
    #
    # The only thing that can see it is a name that came from OUTSIDE, and
    # the record carries several: the keys a real `wl_seat` delivered, and
    # the SENTINEL the capture read back out of the element store.
    ck record.sentinelKey.len > 0                 # the §4 floor
    ck gpuiKeystroke(kEscape).name == record.sentinelKey
    ck keyFromGpuiKeystroke(
         GpuiKeystroke(name: record.sentinelKey)).key == kEscape
    # …and every key the compositor delivered decodes to the vocabulary key
    # the capture's own class table says it is. `f10` and `a` are NOT in
    # `behaviour.Key` at all — the vocabulary is terminal-first and carries no
    # function keys — so they decode to `kNone` and `kChar` respectively, and
    # asserting that is what keeps this from being a list of the keys that
    # happened to work.
    var decoded: seq[string] = @[]
    for sc in record.scenarios:
      for a in sc.arrivals:
        var mods: GpuiModifiers
        for m in a.modifiers:
          case m
          of "control": mods.incl gmControl
          of "alt": mods.incl gmAlt
          of "shift": mods.incl gmShift
          of "platform": mods.incl gmPlatform
          of "function": mods.incl gmFunction
          else: discard
        let k = keyFromGpuiKeystroke(GpuiKeystroke(name: a.key,
                                                   modifiers: mods))
        decoded.add a.key & "=>" & $k.key
    ck decoded.len == 6
    ck "down=>kDown" in decoded
    ck "home=>kHome" in decoded
    ck "tab=>kBackTab" in decoded     # the shift is what makes it a back-tab
    ck "a=>kChar" in decoded
    ck "f10=>kNone" in decoded        # not in a terminal-first key set
    # THE NEGATIVE TWIN ON THE DECODER: a name the compositor never sends
    # decodes to nothing rather than to a plausible key.
    ck keyFromGpuiKeystroke(GpuiKeystroke(name: "Escape")).key == kNone
    ck keyFromGpuiKeystroke(GpuiKeystroke(name: "esc")).key == kNone

  test "THE NEGATIVE TWIN — the same key with the window unfocused changes nothing":
    ck record.negativeTwin.attempted
    ck record.negativeTwin.outcome == "refused"
    ck record.negativeTwin.deliverySeq == 0
    ck record.negativeTwin.deliveryCount == 0
    # The SAME key, on the SAME binary, with the only variable changed. A twin
    # that sent a different key would be a different experiment.
    ck record.negativeTwin.key == record.scenarios[0].arrivals[^1].key
    ck record.negativeTwin.key.len > 0

suite "PLAT-38: the vision witness, and what it can and cannot say":

  test "the key entered a window whose pixels are not a blank screen":
    # **VISION CARRIES ONE CLAIM INTROSPECTION CANNOT MAKE** — that there is a
    # WINDOW and its pixels are not the pixels of a blank screen — and it
    # carries no structural claim. The structure is the element store above.
    # PLAT-37's instrument contract, at the moment of delivery and on BOTH
    # sides of the key.
    #
    # **WHAT THIS CASE IS NOT, AND THE DELIVERABLE IT DOES NOT MEET.**
    # PLAT-38's counted target names *"the vision witness that a key CHANGED
    # the screen"*. It did not, and the capture records the figure:
    # `changedFraction` is 0.0. That is not a capture defect and not a
    # delivery defect — the key reaches the focused element's store, which
    # every case above reads — it is that `codetracer-gpui` has no BINDING
    # from a key to a replay operation. That binding is PLAT-23's `--ui=gui`
    # contract, which is why `--replay-ops` still exists. Asserting a change
    # here would have meant asserting something no shipped route produces
    # (§7c); the figure is PRINTED so the absence is visible rather than
    # implied.
    let v = record.vision
    ck v.attempted
    ck v.beforeNonBlank
    ck v.afterNonBlank
    ck v.threshold > 0.0
    # Both frames differ from the BLANK control by more than the threshold.
    # A window that never opened, or opened and painted nothing, fails here.
    ck v.beforeVsBlank > v.threshold
    ck v.afterVsBlank > v.threshold
    echo "PLAT38 VISION beforeVsBlank=", v.beforeVsBlank,
         " afterVsBlank=", v.afterVsBlank,
         " changedByTheKey=", v.changedFraction,
         " (0.0 is expected: no key->operation binding yet, PLAT-23)"

  test "THE BLANK CONTROL — a control that has never failed is not a control":
    # §7b. The capture retains the blank frame it waited for, and its ABSENCE
    # is fatal rather than tolerated. Compared through the same three
    # functions that measured the two frames above (`ci/test/plat38_frames.py`,
    # shared with `just plat38-threshold-probe`), so the readings are one
    # measurement rather than three.
    let v = record.vision
    ck v.blankPresent
    ck not v.blankNonBlank
    # The control against ITSELF changes by nothing, which is what makes the
    # two figures above a comparison rather than a coincidence.
    ck v.blankChangedFraction < v.threshold
    ck v.blankChangedFraction >= 0.0
    # …and the control is genuinely DIFFERENT from what it controls for: if
    # the blank frame and the painted frame were the same picture, every
    # reading in the case above would be true for free.
    ck v.beforeVsBlank > v.blankChangedFraction

suite "PLAT-38: the tally":

  test "the assertion count matches the declared constant":
    echo "CHECKS: ", countedAssertions
    check countedAssertions == ExpectedAssertions
