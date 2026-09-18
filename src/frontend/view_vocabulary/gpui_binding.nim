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
##   * **its own key transport** — through the shim's event dispatcher, with the
##     key encoded in the EVENT NAME, because the renderer's callback ABI has no
##     payload (gap `PLAT21-VG1`);
##   * **its own attribute names where the renderer mangles the obvious one** —
##     it never writes `disabled`, because isonim-gpui rewrites that name and
##     constant-folds its value (gap `PLAT21-VG2`).
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

import std/[strutils, tables]

import isonim_gpui/renderer
import isonim_gpui/bindings

import ../../common/view_vocabulary
import ./fact_reader

export fact_reader.factAttributeName

const
  KeyEventPrefix* = "vockey:"
    ## **THE ESCAPE `PLAT21-VG1` FILES.** isonim-gpui's listener ABI is
    ## `proc()` — no event object, no key — so the only channel that can say
    ## WHICH key was pressed is the event NAME. A listener is registered per key
    ## of the entry's contract under `vockey:<name>`, and `sendKey` fires that
    ## name. The dispatch is real: it goes out through `gpui_dispatch_event`,
    ## the Rust side looks the listener up in the node's own map, and the
    ## callback id comes back through `globalDispatcher`.
    ##
    ## It is a constant rather than an inlined string so the suite can assert
    ## the names the RENDER PLAN reports — `event_names` is one of the eight
    ## fields the plan carries, which makes an entry's keyboard contract
    ## observable from the Rust side rather than only from ours.

  CharKeyName* = "Char"
    ## `kChar` carries a rune, and the event name has to carry it too:
    ## `vockey:Char:Z`. Without this a binding would have to register one
    ## listener per possible character.

  DisabledFactName* = "disabled"
    ## The one `nodeFacts` field whose plain attribute name isonim-gpui
    ## destroys. Named so `PLAT21-VG2`'s escape is one constant rather than a
    ## string repeated at the write site and the assertion site.

type
  GpuiEscapeKind* = enum
    ## Which filed gap a taken escape belongs to. An enum rather than a string
    ## so a census over it is total and a fifth escape cannot appear unnamed.
    gekKeyInEventName        ## PLAT21-VG1
    gekDisabledAttribute     ## PLAT21-VG2
    gekModalWithoutFocus     ## PLAT21-VG3
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

func gpuiEscapeGapId*(k: GpuiEscapeKind): string =
  ## Which filed gap each escape kind is. Exhaustive: a fifth escape kind
  ## cannot compile without being filed.
  case k
  of gekKeyInEventName: "PLAT21-VG1"
  of gekDisabledAttribute: "PLAT21-VG2"
  of gekModalWithoutFocus: "PLAT21-VG3"
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

func gpuiKeyName*(k: Key; ch: string = ""): string =
  ## `behaviour.Key` in the EVENT-NAME spelling this binding uses.
  ##
  ## Deliberately NOT the DOM's names and NOT isonim-tui's: a third medium that
  ## borrowed one of the other two's spellings would leave the translation step
  ## — the one thing PLAT-3 says differs per medium — untested on this column.
  case k
  of kNone: ""
  of kChar: CharKeyName & ":" & ch
  of kEnter: "Commit"
  of kSpace: "Toggle"
  of kEscape: "Dismiss"
  of kTab: "FocusNext"
  of kBackTab: "FocusPrev"
  of kUp: "Up"
  of kDown: "Down"
  of kLeft: "Left"
  of kRight: "Right"
  of kHome: "First"
  of kEnd: "Last"
  of kBackspace: "EraseBack"
  of kDelete: "EraseForward"

func gpuiKeyEvent*(k: Key; ch: string = ""): string =
  ## The event name a key is delivered under.
  KeyEventPrefix & gpuiKeyName(k, ch)

func keyFromGpuiEvent*(event: string): KeyPress =
  ## The inverse. A handler registered for one name could have assumed its own
  ## key, but then the event name would be decoration: parsing it back is what
  ## makes the round trip through Rust load-bearing, because a dispatch that
  ## arrived at the wrong listener produces the wrong `KeyPress` here.
  if not event.startsWith(KeyEventPrefix): return press(kNone)
  let name = event[KeyEventPrefix.len .. ^1]
  if name.startsWith(CharKeyName & ":"):
    let rest = name[CharKeyName.len + 1 .. ^1]
    return (if rest.len == 1: typeChar(rest[0]) else: press(kNone))
  for k in Key:
    if k != kChar and k != kNone and gpuiKeyName(k) == name:
      return press(k)
  press(kNone)

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
  ## `disabled` is the one field that needs a word about it, and the word is
  ## `PLAT21-VG2`: the plain name would arrive at the shim as `enabled` with
  ## the literal value `false`, so the fact would be lost AND inverted. The
  ## `data-` prefix is what saves it, and the escape is recorded because "the
  ## prefix happened to save us" is not a thing a later reader can see.
  for f in nodeFacts(v):
    if f.field == DisabledFactName:
      b.recordEscape(gekDisabledAttribute, v,
        "wrote " & factAttributeName(f.field) & "=" & f.value &
        " because the renderer rewrites the plain name to `enabled` and " &
        "folds its value to `false`")
    b.renderer.setAttribute(el, factAttributeName(f.field), f.value)

proc keyHandler(b: GpuiBinding; nodeId, event: string): proc() =
  ## ONE handler, for one node and one event name.
  ##
  ## **A SEPARATE `proc` AND NOT A CLOSURE LITERAL IN THE LOOP, AND THAT IS
  ## MEASURED RATHER THAN STYLISTIC.** The first version of `installKeys` built
  ## the closure inline inside `for binding in contract`, and every closure in
  ## one loop shared ONE environment slot for the loop body's `let` — so all of
  ## an entry's listeners ran `applyKey` with the LAST key of its contract.
  ##
  ## What that looked like from outside is the reason it is written down.
  ## `Checkbox` went on passing, because its contract is Space then Enter and
  ## both are `trCheck`, so firing Space and applying Enter produced the right
  ## answer for the wrong reason. `List` and `Input` both end their contracts
  ## with Enter, so Down did nothing and Left did nothing — and only running
  ## them separated the three. Verification-Harness-Traps §32a, in the
  ## instrument rather than in an arm: the listener resolved, the dispatch
  ## crossed into Rust and back, the handler ran, and the EVIDENCE was never
  ## about the key.
  ##
  ## Taking the arguments by value gives each handler its own environment.
  result = proc() =
    inc b.dispatchCount
    for n in walk(b.model):
      if n.id == nodeId:
        b.lastOutcome = applyKey(n, keyFromGpuiEvent(event))
        break

proc installKeys(b: GpuiBinding; el: GpuiElement; v: ViewNode) =
  ## One listener per key of the entry's contract, under `vockey:<name>`.
  ##
  ## THE ESCAPE `PLAT21-VG1` FILES, and it is recorded once per interactive
  ## node rather than once per key: the gate counts ENTRIES.
  let contract = keyContract(v.kind)
  if contract.len == 0: return
  let id = v.id
  var names: seq[string] = @[]
  for binding in contract:
    if binding.key == kChar:
      # `kChar` is a class of keys, not a key. One listener per character the
      # cross-renderer script types would be a listener list that depends on
      # the script; the binding registers the characters the model can receive
      # by registering a marker and letting `sendKey` name the character.
      continue
    let event = gpuiKeyEvent(binding.key)
    names.add event
    b.renderer.addEventListener(el, event, b.keyHandler(id, event))
  b.recordEscape(gekKeyInEventName, v,
    "registered " & $names.len & " listener(s) whose NAME carries the key, " &
    "because the renderer's callback ABI has no event payload")

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
    # PLAT21-VG3. There is no element focus and no layer in this renderer, so
    # the exclusivity the entry IS cannot be drawn. What the binding can carry
    # is PRESENCE — the body is in the tree while the modal is open — and that
    # is strictly less, which is why the escape is recorded rather than left
    # to be inferred from a `div` that looks like every other `div`.
    b.recordEscape(gekModalWithoutFocus, v,
      "rendered the modal's exclusivity as presence only; the renderer has " &
      "no element focus, no layer and no z-order")
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
      # NOT `disabled`: PLAT21-VG2 again, one level down. An option's
      # availability is the state `behaviour.nextEnabled` skips on, so losing
      # it here would make GPUI's motion disagree with the other two media
      # while every element still rendered.
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
  b.escapes = @[]
  b.nodes = initTable[string, GpuiElement]()
  b.root = b.renderNode(b.model)
  b.collectNodes(b.root, b.model)

# ---------------------------------------------------------------------------
# Driving
# ---------------------------------------------------------------------------

proc sendKey*(b: GpuiBinding; id: string; k: Key; ch = ""): KeyOutcome =
  ## Deliver a key by DISPATCHING IT THROUGH THE SHIM.
  ##
  ## `gpui_dispatch_event` crosses into Rust, the Rust side finds the node's
  ## listener list for that event name, and the registered callback id comes
  ## back through `globalDispatcher`. A key with no listener on the node — one
  ## outside the entry's contract — reaches nothing, which is how "an unclaimed
  ## key changes nothing" is asserted on this medium rather than assumed.
  b.lastOutcome = ignored()
  if id notin b.nodes: return b.lastOutcome
  if k == kChar:
    # The character class: the listener is registered on demand under the
    # exact name, because `installKeys` cannot enumerate every rune.
    let node = b.nodes[id]
    let event = gpuiKeyEvent(kChar, ch)
    b.renderer.addEventListener(node, event, b.keyHandler(id, event))
    fireEvent(node, event)
  else:
    fireEvent(b.nodes[id], gpuiKeyEvent(k))
  if b.lastOutcome.handled:
    b.rerender()
  b.lastOutcome

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
