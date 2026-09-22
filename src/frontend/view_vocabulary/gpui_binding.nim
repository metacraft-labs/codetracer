## frontend/view_vocabulary/gpui_binding.nim — PLAT-21. **The third binding:
## a `ViewNode` tree rendered onto isonim-gpui's real element tree.**
##
## ## WHAT MAKES THIS A THIRD FRONT-END AND NOT A SECOND SPELLING OF THE WEB ONE
##
## `GpuiRenderer` satisfies isonim's `RendererBackend`, so the cheapest way to
## get a GPUI column would have been to instantiate `web_binding`'s generic
## `renderWeb[R, N]` at `[GpuiRenderer, GpuiElement]` and declare victory. That
## would have been a test of one function against itself — the exact shape
## Verification-Harness-Traps §14 is about, and the shape PLAT-20 measured the
## cost of when `distributeExtent` made a cross-front-end agreement blind to its
## own weights. A "third front-end" that is the second front-end pointed at a
## different backend proves nothing about the vocabulary.
##
## So this module makes its OWN decisions, and they are the three a real GPUI
## binding has to make:
##
##   * **its own tags** — the ones `mappings.gpuiMapping` names, which are not
##     the web's (`Tabs` is `nav` here and a `div role="tablist"` there, `Menu`
##     is `nav` here and a `div role="menu"` there, `Markdown` is block text
##     here and a `div` there);
##   * **its own key transport** — through the shim's event dispatcher, with a
##     GPUI-shaped keystroke (a base key name plus a modifier set) in the event
##     PAYLOAD;
##   * **its own attribute names**, which are the shared `data-` fact names the
##     web binding also writes.
##
## ## WHAT PLAT-38 CHANGED HERE, AND WHY IT IS NOT COSMETIC
##
## PLAT-21 filed three gaps against the renderer and this module carried an
## escape for each. All three are gone:
##
##   * `PLAT21-VG1` — *a key cannot be delivered*. The renderer's listener ABI
##     was `proc()`: no event object, no key. The only channel that could say
##     WHICH key was pressed was the event NAME, so this binding registered one
##     listener per key of an entry's contract under `vockey:<name>` and fired
##     the name. **The spelling `vockey:` is now retired**, and its absence is
##     asserted with a planted positive control in
##     `src/frontend/gpui/tests/test_gpui_key_delivery.nim` — an absence grep
##     with no control is Verification-Harness-Traps §4. One listener per node
##     under `keydown` now, and the key arrives in the payload.
##   * `PLAT21-VG2` — `setAttribute(el, "disabled", v)` was rewritten to
##     `enabled` and its value constant-folded to `"false"`, so saying
##     "enabled" recorded "disabled" and `getAttribute(el, "disabled")`
##     answered `""`. This module wrote `data-disabled` and recorded an escape
##     saying the prefix was what saved it. **The escape is gone** — not
##     because the write changed (it is still `data-disabled`, which is what
##     the WEB binding writes through the same function) but because the
##     reason it was renderer-keyed has been repaired. The round trip is
##     measured on the real shim by the suite rather than asserted from here.
##   * `PLAT21-VG3` — *no element focus*. `Modal`'s exclusivity was rendered as
##     PRESENCE, which is strictly less than the entry specifies. The renderer
##     now has element focus, a declared order and a focus TRAP, and this
##     binding uses all three: every interactive node is declared focusable, a
##     `Modal` sets a trap while it is open, and `Tab`/`Shift+Tab` move through
##     the order the render tree declares.
##
## ## WHAT IS SHARED, AND THAT IS ALSO DELIBERATE
##
## The READER is `fact_reader.readAttributeFacts`, one function, called by this
## binding and by the web one. Both media carry state as `data-*` attributes and
## a second copy of the walk is §14's defect; that module's header records what
## the sharing costs. The `getAttribute` overload below is the whole of what
## isonim-gpui needs to satisfy it — its own spelling is a free function rather
## than a method on the renderer, which is a difference in the FFI surface and
## not in the semantics.
##
## ## THE READBACK CROSSES THE FFI BOUNDARY, WHICH IS THE POINT
##
## Every fact this module reads back comes out of the Rust shim's element store
## through `gpui_get_attribute`. Nothing is echoed from the `ViewNode`. So a
## disagreement between this column and the other two is a statement about what
## isonim-gpui *kept*, and both gaps above were found exactly that way: by
## writing a value in and reading a different one out.
##
## ## NO MOCKS
##
## `GpuiRenderer` is isonim-gpui's real renderer and the element tree is the
## real Rust shim's, reached through its `extern "C"` surface — the same shim
## `codetracer-gpui` links. It is built without `--features gpui-backend`, so it
## is a SHADOW TREE and a RENDER PLAN rather than a window; that is PLAT-19's
## verification tier, it is a real tier, and PLAT-20's status block says plainly
## that no GPUI window has been observed. Nothing here claims one.

import std/[tables, unicode]

import isonim_gpui/renderer
import isonim_gpui/bindings

import ../../common/view_vocabulary
import ./fact_reader

export fact_reader.factAttributeName

const
  KeyDownEventName* = "keydown"
    ## **ONE event name for every key.** Before PLAT-38 the name was the only
    ## channel that could carry a key, so this binding spelled the key INTO it
    ## (`vockey:Down`) and registered one listener per key of an entry's
    ## contract. The payload carries the key now, so a node has one listener.
    ##
    ## It is a constant rather than an inlined string for the reason the old
    ## one was: `event_names` is one of the fields the RENDER PLAN carries, so
    ## an entry's keyboard contract stays observable from the Rust side rather
    ## than only from ours — and the suite asserts the plan reports exactly
    ## this name, which is how the retirement of `vockey:` is checked from a
    ## RUN rather than from a grep alone.

  DisabledFactName* = "disabled"
    ## The `nodeFacts` field whose plain attribute name isonim-gpui used to
    ## destroy (`PLAT21-VG2`). The gap is repaired; the constant stays because
    ## the suite measures the round trip on the real shim by this name, and a
    ## string repeated at the write site and the assertion site is where the
    ## two would drift.

type
  GpuiEscapeKind* = enum
    ## Which filed gap a taken escape belongs to. An enum rather than a string
    ## so a census over it is total and a fifth escape cannot appear unnamed.
    ##
    ## **THREE MEMBERS WERE REMOVED BY PLAT-38** — `gekKeyInEventName`
    ## (`PLAT21-VG1`), `gekDisabledAttribute` (`PLAT21-VG2`) and
    ## `gekModalWithoutFocus` (`PLAT21-VG3`). Removing them rather than leaving
    ## them unused is deliberate: `gpuiEscapeGapId` is exhaustive over this
    ## enum, so a member with no remaining call site would compile forever and
    ## an escape kind nothing can produce is a register entry nothing can
    ## retire.
    gekImageWithoutPayload   ## PLAT21-VG4

  GpuiEscape* = object
    ## ONE escape, RECORDED WHERE IT WAS TAKEN.
    ##
    ## The gate counts entries needing an escape, and a count read off a
    ## document is a claim. These are appended by the rendering code at the
    ## moment it takes the escape, so the census the suite asserts is taken
    ## from a run (Verification-Harness-Traps §7a: a register nobody can make
    ## disagree with the code is a register nobody is checking).
    kind*: GpuiEscapeKind
    entry*: ViewKind
    nodeId*: string
    detail*: string

  GpuiBinding* = ref object
    ## A rendered view, the model it was rendered from, and what it cost.
    ##
    ## A `ref` because the key listeners close over it: a handler fired from
    ## Rust has to be able to mutate the model and re-render, and a value type
    ## would hand each closure its own copy.
    renderer*: GpuiRenderer
    root*: GpuiElement
    model*: ViewNode
    nodes*: Table[string, GpuiElement]
    escapes*: seq[GpuiEscape]
    dispatchCount*: int
      ## **HOW MANY KEYS ACTUALLY CAME BACK THROUGH THE SHIM.** Incremented
      ## inside `keyHandler`'s closure, which runs only when Rust dispatched to
      ## it — so it is evidence that the key crossed the FFI boundary rather
      ## than being applied on this side.
      ##
      ## It exists because a mutation arm found the gap. Arm G6 replaced
      ## `sendKey`'s `fireEvent` with a direct `applyKey` — the binding going
      ## AROUND its own transport — and it SURVIVED, because `applyKey` itself
      ## declines a key outside the entry's contract, so "an unclaimed key
      ## changes nothing" is true on both paths. The case that was supposed to
      ## prove the dispatch is real proved something `applyKey` already
      ## guarantees. This counter is the thing only the real path can move.
    lastOutcome*: KeyOutcome
      ## What the most recent dispatched key did, as the handler saw it.
      ## Carried on the binding rather than returned, because the handler runs
      ## on the far side of an FFI round trip and cannot return anything.
    lastKeyReceived*: GpuiEvent
      ## **THE KEY THE HANDLER WAS HANDED**, as opposed to the key the caller
      ## sent. Before PLAT-38 there was nothing to record: the handler was a
      ## `proc()` and knew only which closure it was. It is here so a case can
      ## compare what ARRIVED against what was SENT — and the stronger oracle,
      ## the Rust-side element store, is read through `renderer.lastEvent`
      ## rather than from this field, because a field this module writes is a
      ## surface the case built (§4a).

func gpuiEscapeGapId*(k: GpuiEscapeKind): string =
  ## Which filed gap each escape kind is. Exhaustive: a second escape kind
  ## cannot compile without being filed.
  case k
  of gekImageWithoutPayload: "PLAT21-VG4"

# ---------------------------------------------------------------------------
# The renderer's shape, completed
# ---------------------------------------------------------------------------

proc getAttribute*(r: GpuiRenderer; node: GpuiElement; name: string): string =
  ## isonim-gpui spells this as a FREE function over the element; isonim's
  ## `RendererBackend` shape — and therefore `fact_reader.readAttributeFacts` —
  ## wants it with the renderer as the receiver. One forwarding line, so the
  ## shared reader can walk this tree without a second copy of itself.
  renderer.getAttribute(node, name)

# ---------------------------------------------------------------------------
# Tags
# ---------------------------------------------------------------------------

func gpuiTagFor*(k: ViewKind): string =
  ## The tag this binding emits for each entry.
  ##
  ## Exhaustive, and every answer is a tag `mappings.gpuiMapping(k).target`
  ## names — the suite asserts that, so the mapping table PLAT-3 wrote from
  ## isonim-gpui's `tagMap` and the binding that actually emits cannot drift.
  ## They are NOT the web binding's tags: five of the sixteen differ, which is
  ## what makes the two columns two columns.
  case k
  of pkText: "span"
  of pkButton: "button"
  of pkCheckbox: "input"
  of pkToggle: "input"
  of pkInput: "input"
  of pkSelect: "select"
  of pkList: "ul"
  of pkTree: "ul"
  of pkTable: "table"
  of pkTabs: "nav"
  of pkCollapsible: "details"
  of pkModal: "dialog"
  of pkMenu: "nav"
  of pkProgressIndicator: "progress"
  of pkImage: "img"
  of pkMarkdown: "p"

func gpuiChildTagFor*(k: ViewKind): string =
  ## The tag one OPTION row becomes. `select`'s is `option`, which is not in
  ## `tagMap` and therefore keeps its own spelling; the rest are `li` or `div`,
  ## both of which collapse.
  case k
  of pkSelect: "option"
  of pkList, pkTree: "li"
  else: "div"

# ---------------------------------------------------------------------------
# Key names
# ---------------------------------------------------------------------------

type
  GpuiKeystroke* = object
    ## **A key as GPUI spells it**: a base key name plus a modifier set, which
    ## is exactly the shape `gpui::Keystroke` has and exactly the shape the
    ## widened payload carries.
    ##
    ## NOT a rendered `"shift-tab"`. Verification-Harness-Traps §25: a helper
    ## that silently drops a modifier it cannot spell hands you a test about a
    ## different key, and this workspace has already paid for that once. A
    ## modifier cannot fall out of a set without the set changing.
    name*: string
    modifiers*: GpuiModifiers

func gpuiKeystroke*(k: Key; ch: string = ""): GpuiKeystroke =
  ## `behaviour.Key` in **GPUI's own keystroke spelling**.
  ##
  ## PLAT-21's version of this function invented a third vocabulary
  ## (`"Commit"`, `"Toggle"`, `"Dismiss"`, `"FocusNext"`), because the key was
  ## being smuggled through an event NAME and the name was this binding's to
  ## choose. It is not this binding's to choose any more: the names below are
  ## what `gpui::Keystroke.key` actually carries when a compositor key reaches
  ## the shim — lowercase, `"escape"` rather than `"Esc"`, and `"tab"` with
  ## the shift modifier for a back-tab, which is how a keyboard produces one.
  ##
  ## That is the point of the change rather than a side effect of it. A
  ## renderer-specific spelling would have made this binding's decoder and the
  ## renderer's encoder agree by construction, and PLAT-38's key-identity law
  ## needs two independent readings of one keystroke.
  case k
  of kNone: GpuiKeystroke()
  of kChar: GpuiKeystroke(name: ch)
  of kEnter: GpuiKeystroke(name: "enter")
  of kSpace: GpuiKeystroke(name: "space")
  of kEscape: GpuiKeystroke(name: "escape")
  of kTab: GpuiKeystroke(name: "tab")
  of kBackTab: GpuiKeystroke(name: "tab", modifiers: {gmShift})
  of kUp: GpuiKeystroke(name: "up")
  of kDown: GpuiKeystroke(name: "down")
  of kLeft: GpuiKeystroke(name: "left")
  of kRight: GpuiKeystroke(name: "right")
  of kHome: GpuiKeystroke(name: "home")
  of kEnd: GpuiKeystroke(name: "end")
  of kBackspace: GpuiKeystroke(name: "backspace")
  of kDelete: GpuiKeystroke(name: "delete")

func keyFromGpuiKeystroke*(ks: GpuiKeystroke): KeyPress =
  ## The inverse, over what the PAYLOAD carried.
  ##
  ## This is the function a real compositor key lands in: the shim passes
  ## `gpui::Keystroke.key` through verbatim and this binding decides what it
  ## MEANS. An unknown name answers `kNone` rather than guessing, so "a key
  ## this entry does not claim" and "a key nothing could name" are one
  ## outcome and the entry declines both.
  if ks.name.len == 0: return press(kNone)
  # The back-tab first: it shares its name with `kTab` and differs only in the
  # modifier, so a decoder that matched on the name alone would answer `kTab`
  # for both and the shift would be the thing that silently vanished.
  if ks.name == "tab":
    return press(if gmShift in ks.modifiers: kBackTab else: kTab)
  for k in Key:
    if k != kChar and k != kNone and k != kTab and k != kBackTab and
       gpuiKeystroke(k).name == ks.name:
      return press(k)
  # A single-rune name that matched no named key is a character. GPUI reports
  # the unshifted character plus a shift modifier, which is what `kChar`'s
  # rune already means on the other two media.
  if ks.name.runeLen == 1:
    let r = ks.name.runeAt(0)
    if r.int32 < 128: return typeChar(char(r.int32))
  press(kNone)

func keyFromGpuiEvent*(ev: GpuiEvent): KeyPress =
  ## What the widened payload decodes to. One line, so the suite and the
  ## handler read the payload through the same function (§30).
  keyFromGpuiKeystroke(GpuiKeystroke(name: ev.key, modifiers: ev.modifiers))

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc recordEscape(b: GpuiBinding; kind: GpuiEscapeKind; v: ViewNode;
                  detail: string) =
  b.escapes.add GpuiEscape(kind: kind, entry: v.kind, nodeId: v.id,
                           detail: detail)

proc applyFacts(b: GpuiBinding; el: GpuiElement; v: ViewNode) =
  ## Stamp the node's observable state, through the SAME name function the web
  ## binding writes with and the shared reader reads with.
  ##
  ## **THERE IS NO `disabled` SPECIAL CASE ANY MORE, AND ITS ABSENCE IS THE
  ## POINT.** PLAT-21 recorded an escape here (`PLAT21-VG2`): the plain name
  ## arrived at the shim as `enabled` with the literal value `false`, so the
  ## fact was lost AND inverted, and the `data-` prefix was what accidentally
  ## saved it. The renderer keeps what it is given now. The write is unchanged
  ## — `data-disabled`, which is exactly what the WEB binding writes through
  ## exactly this function — so it is no longer a code path keyed on the
  ## renderer, which is `gpui_gaps.nim`'s own definition of an escape.
  for f in nodeFacts(v):
    b.renderer.setAttribute(el, factAttributeName(f.field), f.value)

proc keyHandler(b: GpuiBinding; nodeId: string): GpuiEventHandler =
  ## ONE handler per node, and it reads the key OUT OF THE EVENT.
  ##
  ## **A SEPARATE `proc` AND NOT A CLOSURE LITERAL IN THE LOOP, AND THAT IS
  ## MEASURED RATHER THAN STYLISTIC.** PLAT-21's `installKeys` built the
  ## closure inline inside `for binding in contract`, and every closure in one
  ## loop shared ONE environment slot for the loop body's `let` — so all of an
  ## entry's listeners ran `applyKey` with the LAST key of its contract.
  ##
  ## What that looked like from outside is the reason it is still written
  ## down even though there is no longer a loop to make the mistake in.
  ## `Checkbox` went on passing, because its contract is Space then Enter and
  ## both are `trCheck`, so firing Space and applying Enter produced the right
  ## answer for the wrong reason. `List` and `Input` both end their contracts
  ## with Enter, so Down did nothing and Left did nothing — and only running
  ## them separated the three. Verification-Harness-Traps §32a, in the
  ## instrument rather than in an arm: the listener resolved, the dispatch
  ## crossed into Rust and back, the handler ran, and the EVIDENCE was never
  ## about the key. **The payload removes the class of defect rather than the
  ## instance**: there is one listener now, and which key it applies is a
  ## function of what arrived rather than of which closure ran.
  result = proc(ev: GpuiEvent) =
    inc b.dispatchCount
    b.lastKeyReceived = ev
    for n in walk(b.model):
      if n.id == nodeId:
        b.lastOutcome = applyKey(n, keyFromGpuiEvent(ev))
        break

proc installKeys(b: GpuiBinding; el: GpuiElement; v: ViewNode) =
  ## ONE listener per interactive node, under `keydown`, and the node is
  ## declared FOCUSABLE.
  ##
  ## PLAT-21 registered one listener per key of the entry's contract, under
  ## `vockey:<name>`, and recorded an escape saying so. Both are gone: the key
  ## rides in the payload, and focus is something the renderer now has.
  let contract = keyContract(v.kind)
  if contract.len == 0: return
  b.renderer.addEventListener(el, KeyDownEventName, b.keyHandler(v.id))
  # An entry with a keyboard contract is an entry keys can be routed TO, so
  # it joins the focus order. The order itself is the render tree's document
  # order, which is what `PLAT35-VG4` said was "declared by the leaf renderer
  # and enforced by nothing" — it is enforced by the renderer now, and
  # `focusOrder()` reads it back from the Rust side.
  setFocusable(el)

proc renderNode(b: GpuiBinding; v: ViewNode): GpuiElement =
  let r = b.renderer
  let el = r.createElement(gpuiTagFor(v.kind))
  r.setAttribute(el, ViewKindAttribute, vocabularyName(v.kind))
  r.setAttribute(el, ViewIdAttribute, v.id)
  b.applyFacts(el, v)
  b.installKeys(el, v)

  case v.kind
  of pkText, pkMarkdown:
    r.appendChild(el, r.createTextNode(v.text))
  of pkButton, pkCheckbox, pkToggle, pkCollapsible:
    if v.label.len > 0:
      r.appendChild(el, r.createTextNode(v.label))
  of pkModal:
    # **PLAT21-VG3, CLOSED.** PLAT-21 could carry only PRESENCE here — the
    # body is in the tree while the modal is open — and recorded an escape
    # saying so, because the entry's specified behaviour is *a region that
    # takes exclusive input until dismissed* and there was no element focus
    # to build exclusivity out of. There is now: a focus TRAP confines the
    # focus order to this subtree and refuses `focusElement` from outside it,
    # which is the exclusivity the entry IS rather than a `div` that looks
    # like every other `div`.
    #
    # The trap is set AFTER the children exist, at the end of `renderNode`,
    # because a trap over an empty subtree has nothing to move focus to.
    if v.label.len > 0:
      r.appendChild(el, r.createTextNode(v.label))
  of pkImage:
    # PLAT21-VG4. `img` is one of exactly two tags that reach a dedicated Rust
    # element kind, and the entry has no payload to give it — so the one
    # renderer that could draw the picture gets the alt text, the same as the
    # terminal fallback.
    b.recordEscape(gekImageWithoutPayload, v,
      "emitted <img> with alt text and no source; ViewNode carries " &
      "mediaType and mediaBytes and no bytes")
    r.setAttribute(el, "alt", v.alt)
    r.appendChild(el, r.createTextNode(v.alt))
  of pkInput:
    r.appendChild(el, r.createTextNode(v.text))
  of pkSelect, pkList, pkMenu, pkTabs:
    for i, o in v.options:
      let child = r.createElement(gpuiChildTagFor(v.kind))
      r.setAttribute(child, "data-option-id", o.id)
      r.setAttribute(child, "data-option-index", $i)
      # `data-option-disabled`, through the shared name function, exactly as
      # the web binding writes it. PLAT-21 had a note here saying this was
      # `PLAT21-VG2` one level down — that the plain name would have been
      # destroyed. It would not be now; the name is unchanged because it is
      # the SHARED fact name, and an option's availability is the state
      # `behaviour.nextEnabled` skips on, so a per-renderer spelling would
      # make GPUI's motion disagree with the other two media while every
      # element still rendered.
      r.setAttribute(child, factAttributeName("optionDisabled"), $o.disabled)
      let highlighted =
        if v.kind == pkTabs: i == v.selected
        else: i == v.highlight
      r.setAttribute(child, "data-highlighted", $highlighted)
      r.appendChild(child, r.createTextNode(o.label))
      r.appendChild(el, child)
  of pkTable:
    # `table`, `tr` and `td` are NOT in isonim-gpui's `tagMap`, and PLAT-3
    # recorded that as `msAbsent` on the reasoning that such a tag "reaches a
    # Rust classifier with no case for it". MEASURED on 2026-09-15, that is not
    # what happens: an unknown tag keeps its spelling and classifies as `Div`,
    # which is the same outcome `button` and `ul` get. So the table is nested
    # containers here exactly as it is nested elements on the web, the
    # row/column relationship is the nesting, and NO ESCAPE IS RECORDED — see
    # `gpui_gaps.nim`'s "what counts as an escape", second exclusion.
    let head = r.createElement("tr")
    for c in v.columns:
      let th = r.createElement("th")
      r.appendChild(th, r.createTextNode(c))
      r.appendChild(head, th)
    r.appendChild(el, head)
    for ri, row in v.rows:
      let tr = r.createElement("tr")
      r.setAttribute(tr, "data-row-index", $ri)
      for ci, cell in row:
        let td = r.createElement("td")
        r.setAttribute(td, "data-cell",
          (if ri == v.cursor and ci == v.column: "cursor" else: ""))
        r.appendChild(td, r.createTextNode(cell))
        r.appendChild(tr, td)
      r.appendChild(el, tr)
  of pkProgressIndicator:
    # No escape. The entry's whole specified state is the number, and the
    # number is on the element. A bar's WIDTH is geometry, which the vocabulary
    # refuses to carry in any medium.
    if v.progress != ProgressIndeterminate:
      r.setAttribute(el, "value", $v.progress)
  of pkTree:
    r.appendChild(el, r.createTextNode(v.label))

  let showChildren =
    case v.kind
    of pkCollapsible: v.expanded
    of pkModal: v.open
    of pkTree: v.expanded
    else: true
  if showChildren:
    for c in v.children:
      r.appendChild(el, b.renderNode(c))

  # THE MODAL'S EXCLUSIVITY, once its subtree exists. `setFocusTrap` moves
  # focus inside when the current holder is outside, so opening a modal takes
  # input from whatever had it — which is the behaviour the entry specifies
  # and the thing `PLAT21-VG3` said could not be expressed.
  #
  # An open modal with no focusable descendant traps nothing, and that is the
  # renderer's answer rather than this binding's: `gpui_set_focus_trap`
  # blurs in that case rather than pretending. Recorded here because a modal
  # whose body is all `Text` is a shape the vocabulary permits.
  if v.kind == pkModal:
    discard setFocusTrap(el, v.open)
  el

proc collectNodes(b: GpuiBinding; el: GpuiElement; v: ViewNode) =
  b.nodes[v.id] = el
  let showChildren =
    case v.kind
    of pkCollapsible: v.expanded
    of pkModal: v.open
    of pkTree: v.expanded
    else: true
  if not showChildren: return
  var kids: seq[GpuiElement] = @[]
  var child = b.renderer.firstChild(el)
  while not child.isNil:
    kids.add child
    child = b.renderer.nextSibling(child)
  let start = kids.len - v.children.len
  if start < 0: return
  for i, c in v.children:
    b.collectNodes(kids[start + i], c)

proc renderGpui*(r: GpuiRenderer; model: ViewNode): GpuiBinding =
  ## Render `model` onto isonim-gpui's element tree.
  let b = GpuiBinding(renderer: r, model: model,
                      nodes: initTable[string, GpuiElement]())
  b.root = b.renderNode(model)
  b.collectNodes(b.root, model)
  b

proc rerender*(b: GpuiBinding) =
  ## Rebuild after a state change. The escapes are recomputed with the tree,
  ## because an entry that left the rendered set stops costing one.
  ##
  ## `dispatchCount` is deliberately NOT reset: it is a running total over a
  ## key script, and a counter a re-render zeroed would report 1 for every
  ## script of any length.
  ##
  ## **THE OLD TREE'S FOCUS STATE IS RELEASED FIRST, AND THAT WAS A DEFECT
  ## FOUND BY A CASE RATHER THAN BY DESIGN.** A re-render builds an entirely
  ## new element tree; the previous one is not destroyed, so a `Modal` that
  ## was open before the re-render went on holding its focus TRAP in the
  ## shim's store — and a trap belonging to a tree nothing draws refuses focus
  ## in the tree that IS drawn. The symptom was `Escape` dismissing a modal
  ## and the outside staying unreachable. Releasing here rather than teaching
  ## the renderer about staleness is deliberate: the shim has no idea which
  ## of its nodes this binding still considers current, and a renderer that
  ## guessed would be guessing about the consumer's model.
  for _, el in b.nodes:
    discard setFocusTrap(el, false)
    blurElement(el)
  b.escapes = @[]
  b.nodes = initTable[string, GpuiElement]()
  b.root = b.renderNode(b.model)
  b.collectNodes(b.root, b.model)

# ---------------------------------------------------------------------------
# Driving
# ---------------------------------------------------------------------------

proc gpuiPayloadFor*(k: Key; ch = ""): GpuiEvent =
  ## The payload a key travels in. One function, used by `sendKey` and by the
  ## suite's assertions, so the two cannot disagree about what was sent.
  let ks = gpuiKeystroke(k, ch)
  GpuiEvent(kind: gekKeyDown, key: ks.name, modifiers: ks.modifiers)

proc sendKey*(b: GpuiBinding; id: string; k: Key; ch = ""): KeyOutcome =
  ## Deliver a key by DISPATCHING IT THROUGH THE SHIM, with the key in the
  ## PAYLOAD.
  ##
  ## `gpui_dispatch_event_with` crosses into Rust, the Rust side records the
  ## arrival in the node's own element store, finds the node's `keydown`
  ## listeners and dispatches to them; the callback id and the payload come
  ## back together through `globalDispatcher`. A key the entry does not claim
  ## still ARRIVES and changes nothing, which is a stronger statement than
  ## PLAT-21 could make — there, an unclaimed key reached no listener at all,
  ## so "nothing happened" and "nothing was delivered" were one observation.
  ##
  ## The listener count the dispatch reached is returned by the shim and
  ## dropped here deliberately: this function's answer is the vocabulary's
  ## `KeyOutcome`, and a case that wants the delivery count reads it from the
  ## element store, which is the side the binding cannot write.
  b.lastOutcome = ignored()
  if id notin b.nodes: return b.lastOutcome
  discard fireEvent(b.nodes[id], KeyDownEventName, gpuiPayloadFor(k, ch))
  if b.lastOutcome.handled:
    b.rerender()
  b.lastOutcome

proc focusNode*(b: GpuiBinding; id: string): bool =
  ## Give element focus to one rendered node. Answers false when the node is
  ## not in the tree, is not interactive, or sits outside an open modal's
  ## focus trap — the last of which is `Modal`'s exclusivity, observable.
  if id notin b.nodes: return false
  focusElement(b.nodes[id])

proc focusedNodeId*(b: GpuiBinding): string =
  ## Which rendered node holds element focus, read from the RUST side and
  ## matched back to a model id by node identity rather than by a table this
  ## module keeps in step.
  let f = focusedElement()
  if f.isNil: return ""
  for id, el in b.nodes:
    if sameNode(el, f): return id
  ""

# ---------------------------------------------------------------------------
# Reading the rendered tree back
# ---------------------------------------------------------------------------

proc readGpuiFacts*(b: GpuiBinding): seq[StateFact] =
  ## The state isonim-gpui's own element store holds, read back across the FFI
  ## boundary. Through the SHARED reader; see `fact_reader.nim`.
  readAttributeFacts[GpuiRenderer, GpuiElement](b.renderer, b.root)

proc ownTextOf*(b: GpuiBinding; id: string): string =
  ## **The node's OWN text**, out of the Rust shim's element store.
  ##
  ## Not `textContent(node)`: that concatenates every descendant's text, so a
  ## `Tree` row with children rendered under it would answer its own label
  ## followed by all of theirs. `renderNode` appends a node's own text FIRST
  ## and its view children last, so the first child is the text node.
  ##
  ## Added by PLAT-21 for the same reason `terminal_binding.treeLabelOf` was:
  ## PLAT-2's purity requirement is about bytes, and this is where this
  ## column's copy of those bytes is.
  if id notin b.nodes: return ""
  let first = nthChild(b.nodes[id], 0)
  if first.isNil: return ""
  textContent(first)

proc escapedEntries*(b: GpuiBinding): seq[ViewKind] =
  ## Which vocabulary entries this rendering needed an escape for, in
  ## `ViewKind` order and without repeats. **THE GATE'S NUMBER**, taken from a
  ## run rather than from a list.
  for k in ViewKind:
    for e in b.escapes:
      if e.entry == k:
        result.add k
        break

proc escapeKinds*(b: GpuiBinding): set[GpuiEscapeKind] =
  for e in b.escapes: result.incl e.kind

proc planJson*(b: GpuiBinding): string =
  b.renderer.renderPlanJson(b.root)

proc planIsValid*(b: GpuiBinding): bool =
  b.renderer.verifyRenderPlan(b.root)
