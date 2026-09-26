## frontend/view_vocabulary/web_binding.nim — PLAT-3 deliverable 3. The web
## mapping: a `ViewNode` tree rendered onto DOM elements.
##
## ## GENERIC OVER THE BACKEND, AND BOTH INSTANTIATIONS ARE EXERCISED
##
## Written as `[R, N]` over isonim's `RendererBackend` — the same shape
## `isonim-gpui/tests/test_cross_renderer.nim` uses for `createCounter` and
## `createTaskList`, and the same shape every `isonim_*_view.nim` in this
## repository already uses through its `MockRenderer` / `WebRenderer` overload
## pair. The two instantiations and where each runs:
##
##   `[MockRenderer, MockNode]`   isonim's in-memory DOM, under the C backend:
##                                the `tui` lane's cross-medium suites.
##   `[WebRenderer, Element]`     A REAL DOCUMENT in a real browser: the
##                                `renderer-chromium` lane
##                                (`src/frontend/tests/view_vocabulary_chromium_test.nim`),
##                                which runs this module inside headless
##                                Chromium and drives it with keys Chromium's
##                                own input pipeline delivers.
##
## **Until 2026-09-26 the second line was a claim nothing had compiled.** The
## header said this body "serves the browser", and it did not type-check
## against `WebRenderer` at all (`firstChild` answers a `Node`, not an
## `Element`, and `WebRenderer` has no `getAttribute`); nor did it install a
## key handler — `sendKey` called `applyKey` directly. PLAT-3's status recorded
## "the web arm runs against `MockRenderer`, not a browser" as its second
## partiality; the adapters under `when defined(js)` below and the handler
## installed on every interactive element are what closed it.
##
## `MockRenderer` IS NOT A MOCK OF THE DOM in the sense the workspace policy
## means. It is one of the four renderer backends isonim ships, it satisfies
## the same compile-time `checkRendererBackend` conformance proof `WebRenderer`
## does, and it is the backend the product's own non-JS overload of every web
## view is compiled against. The cross-medium suite records the same thing in
## its header, where the justification belongs.
##
## ## WHAT IS EMITTED, AND WHY THE ATTRIBUTES ARE SEMANTIC
##
## Every node gets `data-view-kind` and `data-view-id`, and every piece of
## observable state gets a `data-<field>` attribute whose name is the same
## string `vocabulary.nodeFacts` uses. That is what lets `readWebFacts` below
## project a rendered DOM tree back down to `StateFact`s WITHOUT consulting the
## `ViewNode` it came from — a projection that read the model would compare the
## model with itself.
##
## The same state is ALSO spelled in HTML's own vocabulary, so a browser reads
## it without knowing about `data-*`: `<input type="checkbox" checked>`,
## `<details open>` with a `<summary>`, `<option selected>`, `<progress
## value max>`, `aria-selected` / `aria-expanded` on the rows, and a `Modal`
## that is `showModal()`-ed once it is in a document. The browser suite reads
## those back through the DOM's own properties (`.checked`, `.open`,
## `.selectedIndex`, `:modal`) and requires them to agree with the `data-*`
## projection — the browser, not this module, deciding what the markup means.
##
## The tags are the ones `mappings.webMapping` names, and the mapping table is
## the specification rather than a description written afterwards: `tagFor`
## below is the only place an entry's tag string appears, and the suite
## asserts it against `webMapping(k).target`.
##
## ## KEYS
##
## Every enabled interactive element gets a `keydown` listener. It reads the
## DOM's own key name (`KeyboardEvent.key`: `"ArrowDown"`, `"Escape"`, `" "`),
## translates it with `keyFromDom`, applies it with `behaviour.applyKey`,
## re-renders, and puts focus back on the element that now carries the same
## `data-view-id` — so a reader holding Down on a list keeps moving it, which a
## re-render that dropped focus would stop after one key. A handled key is
## `preventDefault`-ed (the browser must not also act on it) and not
## propagated; a key the entry does not claim is left to the host. A listener
## acts only when the element it is on IS the event's target: a key typed into
## an `Input` inside a `Collapsible` bubbles through the Collapsible, and must
## not toggle it.
##
## `sendKey` delivers a key the way a reader does — focus the element, then
## dispatch a `keydown` at whatever holds focus — so on `MockRenderer` the key
## reaches the same installed handler the browser's keys do. The browser suite
## does not use `sendKey` at all: its keys are real ones, from Chromium.
##
## ## MARKDOWN
##
## Rendered through `view_vocabulary/markdown_blocks`, a CommonMark-subset
## block parser written independently of the terminal's — see that module's
## header for why the independence is the point. `webMarkdownOutline` reads the
## RENDERED elements back into the outline the terminal's reading of its own
## widget is compared with.

import std/[strutils, tables, unicode]

import isonim/testing/mock_dom

import ../../common/view_vocabulary
import ../../common/view_vocabulary/markdown_blocks
import ./fact_reader
import ./graphemes

when defined(js):
  import isonim/web/dom_api
  import isonim/web/web_renderer
  export dom_api.Element

  template isWebR(R: typedesc): bool =
    ## Whether this instantiation renders into a real document. A template
    ## rather than `defined(js) and R is WebRenderer` because on the C backend
    ## `WebRenderer` does not exist and the second operand would not compile.
    R is WebRenderer
else:
  template isWebR(R: typedesc): bool = false

type
  WebBinding*[R, N] = ref object
    ## A rendered view plus the model it was rendered from.
    ##
    ## A `ref` because the key handlers installed on the elements hold it:
    ## the binding a handler re-renders is the binding the caller reads.
    renderer*: R
    root*: N
    model*: ViewNode
    nodes*: Table[string, N]
      ## rendered element per `ViewNode.id`, so a key can be delivered at the
      ## element a real reader would have focused.
    keysHandled*: int
      ## How many `keydown` events reached an installed handler and were
      ## consumed. A browser suite asserts it grew: a key that changed the
      ## state without passing through here would mean some other path —
      ## the browser's own default action — did the work.
    lastOutcome*: KeyOutcome

func tagFor*(k: ViewKind): string =
  ## The DOM tag each entry becomes. Exhaustive over `ViewKind`; the suite
  ## asserts each answer appears in `mappings.webMapping(k).target`, so the
  ## mapping table and the binding cannot drift.
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
  of pkTabs: "div"
  of pkCollapsible: "details"
  of pkModal: "dialog"
  of pkMenu: "div"
  of pkProgressIndicator: "progress"
  of pkImage: "img"
  of pkMarkdown: "div"

func roleFor*(k: ViewKind): string =
  ## The ARIA role, where the tag alone does not carry the entry's meaning.
  ## Empty where it does. This is the DOM's own answer to the same question
  ## `PresentationClass` answers on the value side: the semantic, not the look.
  case k
  of pkToggle: "switch"
  of pkTree: "tree"
  of pkTabs: "tablist"
  of pkMenu: "menu"
  of pkList: "listbox"
  else: ""

func optionRoleFor(k: ViewKind): string =
  ## The role of one member of a `List`, `Menu` or `Tabs`. (`Select`'s members
  ## are `<option>` elements and carry it already.)
  case k
  of pkList: "option"
  of pkMenu: "menuitem"
  of pkTabs: "tab"
  else: ""

func inputTypeFor(k: ViewKind): string =
  case k
  of pkCheckbox, pkToggle: "checkbox"
  of pkInput: "text"
  else: ""

# ---------------------------------------------------------------------------
# Key translation
# ---------------------------------------------------------------------------

func domKeyName*(k: Key; ch: string = ""): string =
  ## `behaviour.Key` in the DOM's own spelling — `KeyboardEvent.key` values.
  case k
  of kNone: ""
  of kChar: ch
  of kEnter: "Enter"
  of kSpace: " "
  of kEscape: "Escape"
  of kTab: "Tab"
  of kBackTab: "Tab"
  of kUp: "ArrowUp"
  of kDown: "ArrowDown"
  of kLeft: "ArrowLeft"
  of kRight: "ArrowRight"
  of kHome: "Home"
  of kEnd: "End"
  of kBackspace: "Backspace"
  of kDelete: "Delete"

func keyFromDom*(name: string): KeyPress =
  ## The inverse, which is what the installed handler runs. A name that is ONE
  ## RUNE and not one of the named keys is a printable character — the DOM's
  ## own rule for `KeyboardEvent.key` (`"é"` is one key, `"Shift"` is not).
  case name
  of "Enter": press(kEnter)
  of " ": press(kSpace)
  of "Escape": press(kEscape)
  of "Tab": press(kTab)
  of "ArrowUp": press(kUp)
  of "ArrowDown": press(kDown)
  of "ArrowLeft": press(kLeft)
  of "ArrowRight": press(kRight)
  of "Home": press(kHome)
  of "End": press(kEnd)
  of "Backspace": press(kBackspace)
  of "Delete": press(kDelete)
  else:
    if name.len > 0 and name.runeLen == 1: typeRune(name.runeAt(0))
    else: press(kNone)

# ---------------------------------------------------------------------------
# The two backends' differences, in one place
# ---------------------------------------------------------------------------

when defined(js):
  proc jsKey(ev: Event): cstring {.importjs: "#.key".}
  proc jsPreventDefault(ev: Event) {.importjs: "#.preventDefault()".}
  proc jsStopPropagation(ev: Event) {.importjs: "#.stopPropagation()".}
  proc jsFocus(el: Element) {.importjs: "#.focus()".}
  proc jsIsConnected(el: Element): bool {.importjs: "(#.isConnected === true)".}
  proc jsShowModal(el: Element) {.importjs: "#.showModal()".}
  proc jsHasAttribute(el: Node; name: cstring): bool {.importjs:
    "((n, a) => n.nodeType === 1 && n.hasAttribute(a))(#, #)".}
  proc jsSetSelectionRange(el: Element; a, b: int) {.importjs:
    "#.setSelectionRange(#, #)".}
  proc jsDispatchKey(el: Node; key: cstring) {.importjs:
    "#.dispatchEvent(new KeyboardEvent('keydown', {key: #, bubbles: true, cancelable: true}))".}
  proc jsActiveElement(): Node {.importjs: "(document.activeElement)".}

  # `WebRenderer` answers `firstChild` / `nextSibling` with a `Node` (a text
  # node is a child too) and has no `getAttribute`; `fact_reader` walks with
  # all three. These overloads take the `Node` the walk actually holds, and
  # `getAttribute` answers "" for anything that is not an element rather than
  # throwing on a text node.
  proc getAttribute*(r: WebRenderer; n: Node; name: string): string =
    if n.isNil or not jsHasAttribute(n, cstring(name)): return ""
    $dom_api.getAttribute(Element(n), cstring(name))

  proc firstChild*(r: WebRenderer; n: Node): Node = n.firstChild
  proc nextSibling*(r: WebRenderer; n: Node): Node = n.nextSibling

proc childElements[R, N](r: R; el: N): seq[N] =
  ## Every child of `el` that is an ELEMENT, in order — text nodes skipped.
  when isWebR(R):
    var c = Node(el).firstChild
    while not c.isNil:
      if c.nodeType == 1: result.add Element(c)
      c = c.nextSibling
  else:
    var c = r.firstChild(el)
    while not c.isNil:
      if c.kind == mnkElement: result.add c
      c = r.nextSibling(c)

proc allChildren[R, N](r: R; el: N): int =
  ## How many children `el` has, text nodes included.
  when isWebR(R):
    var c = Node(el).firstChild
    while not c.isNil:
      inc result
      c = c.nextSibling
  else:
    el.children.len

proc tagOf[R, N](r: R; el: N): string =
  when isWebR(R):
    ($el.tagName).toLowerAscii
  else:
    el.tag

proc textOf[R, N](r: R; el: N): string =
  when isWebR(R):
    $Node(el).textContent
  else:
    textContent(el)

proc attrOf[R, N](r: R; el: N; name: string): string =
  when isWebR(R):
    getAttribute(r, Node(el), name)
  else:
    r.getAttribute(el, name)

proc focusEl[R, N](r: R; el: N) =
  when isWebR(R):
    jsFocus(el)
  else:
    r.focus(el)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc applyFacts[R, N](r: R; el: N; v: ViewNode) =
  ## Stamp the node's observable state onto the element as `data-*`
  ## attributes, using the same field names `vocabulary.nodeFacts` uses.
  ##
  ## The attribute SPELLING comes from `fact_reader.factAttributeName` — one
  ## function shared with the reader below and with the GPUI binding, so a
  ## writer and a reader cannot disagree about the prefix
  ## (Verification-Harness-Traps §14).
  for f in nodeFacts(v):
    r.setAttribute(el, factAttributeName(f.field), f.value)

proc renderSpans[R, N](r: R; parent: N; spans: seq[MdSpan]) =
  for s in spans:
    case s.kind
    of mskText: r.appendChild(parent, r.createTextNode(s.text))
    of mskBreak: r.appendChild(parent, r.createElement("br"))
    of mskCode:
      let c = r.createElement("code")
      r.appendChild(c, r.createTextNode(s.text))
      r.appendChild(parent, c)
    of mskEmphasis, mskStrong, mskLink:
      let tag = case s.kind
        of mskEmphasis: "em"
        of mskStrong: "strong"
        else: "a"
      let e = r.createElement(tag)
      if s.kind == mskLink: r.setAttribute(e, "href", s.url)
      renderSpans[R, N](r, e, s.children)
      r.appendChild(parent, e)

proc renderBlocks[R, N](r: R; parent: N; blocks: seq[MdBlockNode]) =
  for b in blocks:
    case b.kind
    of mbkHeading:
      let h = r.createElement("h" & $b.level)
      renderSpans[R, N](r, h, b.spans)
      r.appendChild(parent, h)
    of mbkParagraph:
      let p = r.createElement("p")
      renderSpans[R, N](r, p, b.spans)
      r.appendChild(parent, p)
    of mbkCode:
      let pre = r.createElement("pre")
      let code = r.createElement("code")
      if b.info.len > 0: r.setAttribute(code, "class", "language-" & b.info)
      r.appendChild(code, r.createTextNode(b.code.join("\n")))
      r.appendChild(pre, code)
      r.appendChild(parent, pre)
    of mbkRule:
      r.appendChild(parent, r.createElement("hr"))
    of mbkQuote:
      let q = r.createElement("blockquote")
      renderBlocks[R, N](r, q, b.body)
      r.appendChild(parent, q)
    of mbkList:
      let l = r.createElement(if b.ordered: "ol" else: "ul")
      if b.ordered: r.setAttribute(l, "start", $b.start)
      for item in b.items:
        let li = r.createElement("li")
        renderBlocks[R, N](r, li, item)
        r.appendChild(l, li)
      r.appendChild(parent, l)

proc onKey[R, N](b: WebBinding[R, N]; id, keyName: string): bool

func nativeDefaultChangesState*(k: ViewKind; open: bool;
                                keyName: string): bool =
  ## Whether the BROWSER's default action for `keyName` on this entry's
  ## native element changes the element's state even though the entry does not
  ## claim the key. Such a key must be `preventDefault`-ed anyway, or the page
  ## shows a state the model does not have. Measured in headless Chromium by
  ## `src/frontend/tests/view_vocabulary_chromium_test.nim`, case "what the
  ## browser does on its own":
  ##
  ##   `<select>`, closed   ArrowUp / ArrowDown / Home / End / PageUp /
  ##                        PageDown and a printable character (type-ahead)
  ##                        each COMMIT a different option at once. The
  ##                        entry's highlight/commit split exists natively
  ##                        only inside the opened popup.
  ##   `<input type=text>`  ArrowUp and ArrowDown move the caret to the start
  ##                        and the end; the entry claims neither.
  ##
  ## Found by the browser suite, not by review: before this guard, Down on a
  ## closed `Select` left the model on the first option and the browser on the
  ## second.
  case k
  of pkSelect:
    if open: keyName in ["Home", "End", "PageUp", "PageDown"] or
             (keyName.len > 0 and keyName.runeLen == 1 and keyName != " ")
    else: keyName in ["ArrowUp", "ArrowDown", "Home", "End", "PageUp",
                      "PageDown"] or
          (keyName.len > 0 and keyName.runeLen == 1 and keyName != " ")
  of pkInput: keyName in ["ArrowUp", "ArrowDown", "PageUp", "PageDown"]
  else: false

proc guardsNative[R, N](b: WebBinding[R, N]; id, keyName: string): bool =
  ## The guard above, for the entry `id` in its current state.
  for n in walk(b.model):
    if n.id == id:
      return nativeDefaultChangesState(n.kind, n.open, keyName)
  false

proc installKeyHandler[R, N](b: WebBinding[R, N]; el: N; id: string) =
  ## The listener the header describes. One per enabled interactive element.
  when isWebR(R):
    b.renderer.addEventListener(el, "keydown", proc(ev: Event) =
      # Only when this element IS the target: a key bubbling up from a
      # descendant entry is that entry's, not this one's.
      if ev.target != Node(el): return
      let name = $jsKey(ev)
      if b.onKey(id, name):
        jsPreventDefault(ev)
        jsStopPropagation(ev)
      elif b.guardsNative(id, name):
        jsPreventDefault(ev))
  else:
    b.renderer.addEventListener(el, "keydown", proc(ev: MockEvent) =
      if ev.target != el: return
      if b.onKey(id, ev.key):
        ev.preventDefault()
        ev.stopPropagation()
      elif b.guardsNative(id, ev.key):
        ev.preventDefault())

proc renderNode[R, N](b: WebBinding[R, N]; v: ViewNode): N =
  let r = b.renderer
  let el = r.createElement(tagFor(v.kind))
  r.setAttribute(el, ViewKindAttribute, vocabularyName(v.kind))
  r.setAttribute(el, ViewIdAttribute, v.id)
  let role = roleFor(v.kind)
  if role.len > 0:
    r.setAttribute(el, "role", role)
  let inputType = inputTypeFor(v.kind)
  if inputType.len > 0:
    r.setAttribute(el, "type", inputType)
  if v.disabled:
    r.setAttribute(el, "disabled", "true")
  if v.kind in InteractiveKinds and not v.disabled:
    # A ROVING TABINDEX, not one per option: the entry specifies ONE
    # highlight for a list, so exactly one element per view is in the tab
    # order and the arrow keys move within it. That is the same arrangement
    # isonim-tui's focus manager arrives at from the other side, where Tab is
    # consumed before any widget sees it.
    r.setAttribute(el, "tabindex", "0")
    installKeyHandler[R, N](b, el, v.id)
  applyFacts(r, el, v)

  case v.kind
  of pkText:
    r.appendChild(el, r.createTextNode(v.text))
  of pkMarkdown:
    renderBlocks[R, N](r, el, parseMdBlocks(v.text))
  of pkCheckbox, pkToggle:
    if v.checked: r.setAttribute(el, "checked", "")
    r.setAttribute(el, "aria-checked", $v.checked)
    if v.label.len > 0:
      r.setAttribute(el, "aria-label", v.label)
      let lab = r.createElement("span")
      r.setAttribute(lab, "class", "view-label")
      r.appendChild(lab, r.createTextNode(v.label))
      r.appendChild(el, lab)
  of pkButton, pkModal:
    if v.kind == pkModal and v.open:
      # `open` here; `mountModals` replaces it with `showModal()` once the
      # element is in a document, which is what makes the rest of the page
      # inert. An element that is not in a document cannot be shown modally,
      # and the attribute is the DOM's spelling of "shown" for that case.
      r.setAttribute(el, "open", "")
    if v.label.len > 0:
      let lab = r.createElement("span")
      r.setAttribute(lab, "class", "view-label")
      r.appendChild(lab, r.createTextNode(v.label))
      r.appendChild(el, lab)
  of pkCollapsible:
    if v.expanded: r.setAttribute(el, "open", "")
    let summary = r.createElement("summary")
    r.appendChild(summary, r.createTextNode(v.label))
    r.appendChild(el, summary)
  of pkImage:
    r.setAttribute(el, "alt", v.alt)
    r.setAttribute(el, "data-media-bytes", $v.mediaBytes)
  of pkInput:
    r.setAttribute(el, "value", v.text)
  of pkSelect, pkList, pkMenu, pkTabs:
    if v.kind == pkMenu and not v.open:
      # A CLOSED MENU IS NOT SHOWING. `hidden` takes it out of the rendering
      # and out of the focus order, as the terminal's `MenuWidget` takes its
      # overlay out of the tree; its state stays readable, which is what a
      # reader of the data attributes (and the vocabulary) expects.
      r.setAttribute(el, "hidden", "")
    for i, o in v.options:
      let child = r.createElement(
        if v.kind == pkSelect: "option"
        elif v.kind == pkList: "li"
        else: "div")
      r.setAttribute(child, "data-option-id", o.id)
      r.setAttribute(child, "data-option-index", $i)
      let optRole = optionRoleFor(v.kind)
      if optRole.len > 0: r.setAttribute(child, "role", optRole)
      if o.disabled:
        r.setAttribute(child, "disabled", "true")
        r.setAttribute(child, "aria-disabled", "true")
      let highlighted =
        if v.kind == pkTabs: i == v.selected
        else: i == v.highlight
      r.setAttribute(child, "data-highlighted", $highlighted)
      if v.kind == pkSelect:
        if i == v.selected: r.setAttribute(child, "selected", "")
      else:
        r.setAttribute(child, "aria-selected", $highlighted)
      r.appendChild(child, r.createTextNode(o.label))
      r.appendChild(el, child)
  of pkTable:
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
    r.setAttribute(el, "max", "100")
    if v.progress != ProgressIndeterminate:
      r.setAttribute(el, "value", $v.progress)
  of pkTree:
    r.setAttribute(el, "aria-expanded", $v.expanded)
    let lab = r.createElement("span")
    r.appendChild(lab, r.createTextNode(v.label))
    r.appendChild(el, lab)

  # Children. A `Collapsible` and a `Modal` render their body only while they
  # are showing it — "present or absent" is the entry's own word, and an
  # element that stayed in the tree with `display:none` would be present.
  let showChildren =
    case v.kind
    of pkCollapsible: v.expanded
    of pkModal: v.open
    of pkTree: v.expanded
    else: true
  if showChildren:
    for c in v.children:
      r.appendChild(el, renderNode[R, N](b, c))
  el

proc collectNodes[R, N](r: R; el: N; v: ViewNode;
                        acc: var Table[string, N]) =
  ## Index the rendered elements by `ViewNode.id`, walking the two trees in
  ## lock step. Only the nodes that were RENDERED are indexed, so a collapsed
  ## body's children are absent from the index exactly as they are absent from
  ## the document.
  acc[v.id] = el
  let showChildren =
    case v.kind
    of pkCollapsible: v.expanded
    of pkModal: v.open
    of pkTree: v.expanded
    else: true
  if not showChildren: return
  # The rendered children of a node are its trailing ELEMENTS: chrome (label,
  # summary, option rows, table rows) comes first and view children last,
  # which is the order `renderNode` appends them in.
  let kids = childElements[R, N](r, el)
  let start = kids.len - v.children.len
  for i, c in v.children:
    collectNodes[R, N](r, kids[start + i], c, acc)

proc mountModals[R, N](b: WebBinding[R, N]) =
  ## Show every open `Modal` MODALLY, once its element is in a document.
  ## `showModal()` is what makes the rest of the page inert — the entry's
  ## exclusivity, supplied by the medium — and it refuses an element that is
  ## not connected, so it runs after the tree is attached. On `MockRenderer`
  ## there is no document and nothing to do; the `open` attribute stands.
  when isWebR(R):
    for n in walk(b.model):
      if n.kind == pkModal and n.open and n.id in b.nodes:
        let el = b.nodes[n.id]
        if jsIsConnected(el):
          b.renderer.removeAttribute(el, "open")
          jsShowModal(el)
  else:
    discard

proc placeCaret[R, N](b: WebBinding[R, N]; id: string) =
  ## Put the browser's caret where the model's `Input.cursor` says. The model
  ## counts grapheme CLUSTERS; `setSelectionRange` counts UTF-16 code units,
  ## so the offset is converted rather than passed through.
  when isWebR(R):
    var target: ViewNode = nil
    for n in walk(b.model):
      if n.id == id: target = n
    if target.isNil or target.kind != pkInput or id notin b.nodes: return
    let bounds = graphemeBoundaries(target.text)
    let stop = bounds[max(0, min(target.cursor, bounds.len - 1))]
    var units = 0
    for ru in runes(target.text[0 ..< stop]):
      units += (if int32(ru) > 0xFFFF: 2 else: 1)
    jsSetSelectionRange(b.nodes[id], units, units)
  else:
    discard

proc replaceRoot[R, N](b: WebBinding[R, N]; fresh: N) =
  ## Swap the rendered tree in place, so a binding mounted in a document stays
  ## mounted across a re-render.
  let old = b.root
  when isWebR(R):
    let parent = Node(old).parentNode
    if not parent.isNil:
      discard dom_api.replaceChild(parent, Node(fresh), Node(old))
  else:
    let parent = b.renderer.parentNode(old)
    if not parent.isNil:
      b.renderer.insertBefore(parent, fresh, old)
      b.renderer.removeChild(parent, old)
  b.root = fresh

proc rerender*[R, N](b: WebBinding[R, N]) =
  let fresh = renderNode[R, N](b, b.model)
  if not b.root.isNil: replaceRoot[R, N](b, fresh)
  else: b.root = fresh
  b.nodes = initTable[string, N]()
  collectNodes[R, N](b.renderer, b.root, b.model, b.nodes)
  mountModals[R, N](b)

proc findNode(v: ViewNode; id: string): ViewNode =
  for n in walk(v):
    if n.id == id: return n
  nil

proc onKey[R, N](b: WebBinding[R, N]; id, keyName: string): bool =
  ## What every installed listener runs. Answers whether the key was consumed.
  let target = findNode(b.model, id)
  if target.isNil: return false
  # The UAX #29 segmenter, so an `Input`'s caret moves over what a reader
  # sees as one character — as the browser's own `<input>` caret does.
  let o = applyKey(target, keyFromDom(keyName), graphemeBoundaries)
  b.lastOutcome = o
  if not o.handled: return false
  inc b.keysHandled
  b.rerender()
  if id in b.nodes:
    focusEl[R, N](b.renderer, b.nodes[id])
    b.placeCaret(id)
  true

proc renderWeb*[R, N](r: R; model: ViewNode): WebBinding[R, N] =
  ## Render `model` and return the binding. Its elements carry key handlers
  ## that re-render it on every consumed key.
  let b = WebBinding[R, N](renderer: r, model: model)
  b.rerender()
  b

proc mountWeb*[R, N](b: WebBinding[R, N]; host: N) =
  ## Attach the rendered tree under `host` (an element in a document), then
  ## show any open Modal modally — which needs the document.
  b.renderer.appendChild(host, b.root)
  mountModals[R, N](b)

proc sendKey*[R, N](b: WebBinding[R, N]; id: string;
                    k: Key; ch = ""): KeyOutcome =
  ## Deliver a key the way a reader does: focus the element named `id`, then
  ## dispatch a `keydown` — spelled the way the DOM spells it — at whatever
  ## holds focus. Returns what the installed handler reported, or `ignored()`
  ## when no handler consumed it.
  if id notin b.nodes: return ignored()
  b.lastOutcome = ignored()
  let before = b.keysHandled
  let el = b.nodes[id]
  focusEl[R, N](b.renderer, el)
  when isWebR(R):
    jsDispatchKey(jsActiveElement(), cstring(domKeyName(k, ch)))
  else:
    let target = b.renderer.activeElement()
    if target.isNil: return ignored()
    fireEventWith(target, "keydown",
      MockEvent(`type`: "keydown", target: target, currentTarget: target,
                key: domKeyName(k, ch)))
  if b.keysHandled > before: b.lastOutcome else: ignored()

# ---------------------------------------------------------------------------
# Reading the rendered tree back
# ---------------------------------------------------------------------------

proc readWebFacts*[R, N](b: WebBinding[R, N]): seq[StateFact] =
  ## Project the RENDERED DOM tree down to `StateFact`s, by reading the
  ## `data-*` attributes off the elements. Deliberately does not look at
  ## `b.model`: a projection that read the model would be comparing the model
  ## with itself, and the cross-medium suite would pass on a binding that
  ## rendered nothing.
  ##
  ## **THE WALK MOVED to `fact_reader.readAttributeFacts` on 2026-09-15**, and
  ## this is now the naming of it this binding's callers use. PLAT-21's GPUI
  ## binding renders onto a second attribute-carrying element tree; a second
  ## copy of this walk is Verification-Harness-Traps §14, and that module's
  ## header records what the sharing costs as well as what it buys. Nothing
  ## about this function's answer changed — the field names still come from
  ## `vocabulary.nodeFacts` and the model is still never consulted.
  when isWebR(R):
    readAttributeFacts[WebRenderer, Node](b.renderer, Node(b.root))
  else:
    readAttributeFacts[R, N](b.renderer, b.root)

proc spanOutline[R, N](r: R; el: N): string =
  ## The inline structure of a rendered block, in `markdown_blocks`'s
  ## spelling — read from the ELEMENTS, not from the source.
  when isWebR(R):
    var c = Node(el).firstChild
    while not c.isNil:
      if c.nodeType == 3:
        result.add $c.nodeValue
      elif c.nodeType == 1:
        let e = Element(c)
        let inner = spanOutline[R, N](r, e)
        case ($e.tagName).toLowerAscii
        of "strong": result.add inlineToken(mskStrong, inner, "")
        of "em": result.add inlineToken(mskEmphasis, inner, "")
        of "code": result.add inlineToken(mskCode, inner, "")
        of "a": result.add inlineToken(mskLink, inner, attrOf(r, e, "href"))
        of "br": result.add inlineToken(mskBreak, "", "")
        else: result.add inner
      c = c.nextSibling
  else:
    for c in el.children:
      if c.kind == mnkText:
        result.add c.text
      else:
        let inner = spanOutline[R, N](r, c)
        case c.tag
        of "strong": result.add inlineToken(mskStrong, inner, "")
        of "em": result.add inlineToken(mskEmphasis, inner, "")
        of "code": result.add inlineToken(mskCode, inner, "")
        of "a": result.add inlineToken(mskLink, inner, attrOf(r, c, "href"))
        of "br": result.add inlineToken(mskBreak, "", "")
        else: result.add inner

proc blockOutline[R, N](r: R; el: N; acc: var seq[string]) =
  for c in childElements[R, N](r, el):
    let tag = tagOf(r, c)
    case tag
    of "h1", "h2", "h3", "h4", "h5", "h6":
      acc.add tag & " " & spanOutline[R, N](r, c)
    of "p":
      acc.add "p " & spanOutline[R, N](r, c)
    of "pre":
      let codes = childElements[R, N](r, c)
      var info = ""
      var body = ""
      if codes.len > 0:
        let cls = attrOf(r, codes[0], "class")
        if cls.startsWith("language-"): info = cls["language-".len .. ^1]
        body = textOf(r, codes[0])
      acc.add "code " & info & "|" & body
    of "hr":
      acc.add "hr"
    of "blockquote":
      acc.add "quote{"
      blockOutline[R, N](r, c, acc)
      acc.add "}"
    of "ul", "ol":
      acc.add (if tag == "ol": "ol" & attrOf(r, c, "start") & "{" else: "ul{")
      for li in childElements[R, N](r, c):
        acc.add "li{"
        blockOutline[R, N](r, li, acc)
        acc.add "}"
      acc.add "}"
    else:
      discard

proc webMarkdownOutline*[R, N](b: WebBinding[R, N]; id: string): seq[string] =
  ## The outline of the Markdown entry `id` AS RENDERED — read off its child
  ## elements by tag, never re-derived from the source. Empty when `id` is not
  ## a rendered Markdown entry.
  if id notin b.nodes: return
  let el = b.nodes[id]
  if attrOf(b.renderer, el, ViewKindAttribute) != vocabularyName(pkMarkdown):
    return
  blockOutline[R, N](b.renderer, el, result)

proc webChildCount*[R, N](b: WebBinding[R, N]; id: string): int =
  ## How many DOM children the element for `id` has, text nodes included —
  ## for a suite that must tell "rendered as blocks" from "rendered as one
  ## text node".
  if id notin b.nodes: return -1
  allChildren[R, N](b.renderer, b.nodes[id])
