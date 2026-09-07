## frontend/view_vocabulary/web_binding.nim — PLAT-3 deliverable 3. The web
## mapping: a `ViewNode` tree rendered onto DOM elements.
##
## ## GENERIC OVER THE BACKEND, WHICH IS WHY IT IS ONE FILE
##
## Written as `[R, N]` over isonim's `RendererBackend` — the same shape
## `isonim-gpui/tests/test_cross_renderer.nim` uses for `createCounter` and
## `createTaskList`, and the same shape every `isonim_*_view.nim` in this
## repository already uses through its `MockRenderer` / `WebRenderer` overload
## pair. So this one body serves the browser (`WebRenderer`, under `-d:js`) and
## the headless suites (`MockRenderer`), and neither is a reimplementation of
## the other.
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
## The tags are the ones `mappings.webMapping` names, and the mapping table is
## the specification rather than a description written afterwards: `tagFor`
## below is the only place a tag string appears, and the suite asserts it
## against `webMapping(k).target`.
##
## ## KEYS
##
## `sendKey` translates a `behaviour.Key` into the DOM's own key name
## (`"ArrowDown"`, `"Escape"`, `" "` for space) and dispatches a `keydown` the
## way a browser would, so the handler this module installs receives exactly
## what the browser would hand it. The handler calls `behaviour.applyKey` and
## re-renders. THE TRANSLATION IS THE ONLY THING THAT DIFFERS FROM THE TERMINAL
## BINDING, which is the claim PLAT-3 is making.

import std/[strutils, tables]

import isonim/testing/mock_dom

import ../../common/view_vocabulary

when defined(js):
  import isonim/web/web_renderer

type
  WebBinding*[R, N] = object
    ## A rendered view plus the model it was rendered from.
    renderer*: R
    root*: N
    model*: ViewNode
    nodes*: Table[string, N]
      ## rendered element per `ViewNode.id`, so `sendKey` can dispatch at the
      ## element a real reader would have focused.

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
  ## The inverse, which is what the installed handler runs. A single-character
  ## name that is not one of the named keys is a printable character — that is
  ## the DOM's own rule for `KeyboardEvent.key`.
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
    if name.len == 1: typeChar(name[0]) else: press(kNone)

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

proc applyFacts[R, N](r: R; el: N; v: ViewNode) =
  ## Stamp the node's observable state onto the element as `data-*`
  ## attributes, using the same field names `vocabulary.nodeFacts` uses.
  for f in nodeFacts(v):
    r.setAttribute(el, "data-" & f.field, f.value)

proc renderNode[R, N](r: R; v: ViewNode): N =
  let el = r.createElement(tagFor(v.kind))
  r.setAttribute(el, "data-view-kind", vocabularyName(v.kind))
  r.setAttribute(el, "data-view-id", v.id)
  let role = roleFor(v.kind)
  if role.len > 0:
    r.setAttribute(el, "role", role)
  if v.disabled:
    r.setAttribute(el, "disabled", "true")
  if v.kind in InteractiveKinds and not v.disabled:
    # A ROVING TABINDEX, not one per option: the entry specifies ONE
    # highlight for a list, so exactly one element per view is in the tab
    # order and the arrow keys move within it. That is the same arrangement
    # isonim-tui's focus manager arrives at from the other side, where Tab is
    # consumed before any widget sees it.
    r.setAttribute(el, "tabindex", "0")
  applyFacts(r, el, v)

  case v.kind
  of pkText, pkMarkdown:
    r.appendChild(el, r.createTextNode(v.text))
  of pkButton, pkCheckbox, pkToggle, pkCollapsible, pkModal:
    if v.label.len > 0:
      let lab = r.createElement("span")
      r.setAttribute(lab, "class", "view-label")
      r.appendChild(lab, r.createTextNode(v.label))
      r.appendChild(el, lab)
  of pkImage:
    r.setAttribute(el, "alt", v.alt)
    r.setAttribute(el, "data-media-bytes", $v.mediaBytes)
  of pkInput:
    r.setAttribute(el, "value", v.text)
  of pkSelect, pkList, pkMenu, pkTabs:
    for i, o in v.options:
      let child = r.createElement(
        if v.kind == pkSelect: "option"
        elif v.kind == pkList: "li"
        else: "div")
      r.setAttribute(child, "data-option-id", o.id)
      r.setAttribute(child, "data-option-index", $i)
      if o.disabled: r.setAttribute(child, "disabled", "true")
      let highlighted =
        if v.kind == pkTabs: i == v.selected
        else: i == v.highlight
      r.setAttribute(child, "data-highlighted", $highlighted)
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
    if v.progress != ProgressIndeterminate:
      r.setAttribute(el, "value", $v.progress)
  of pkTree:
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
      r.appendChild(el, renderNode[R, N](r, c))
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
  # The rendered children of a node are its trailing elements: chrome (label,
  # option rows, table rows) comes first and view children last, which is the
  # order `renderNode` appends them in.
  var kids: seq[N] = @[]
  var child = r.firstChild(el)
  while not child.isNil:
    kids.add child
    child = r.nextSibling(child)
  let start = kids.len - v.children.len
  for i, c in v.children:
    collectNodes[R, N](r, kids[start + i], c, acc)

proc renderWeb*[R, N](r: R; model: ViewNode): WebBinding[R, N] =
  ## Render `model` and return the binding. Re-render after every state change
  ## with `rerender`, which is what the installed key handler does.
  var b = WebBinding[R, N](renderer: r, model: model)
  b.root = renderNode[R, N](r, model)
  b.nodes = initTable[string, N]()
  collectNodes[R, N](r, b.root, model, b.nodes)
  b

proc rerender*[R, N](b: var WebBinding[R, N]) =
  b.root = renderNode[R, N](b.renderer, b.model)
  b.nodes = initTable[string, N]()
  collectNodes[R, N](b.renderer, b.root, b.model, b.nodes)

proc findNode(v: ViewNode; id: string): ViewNode =
  for n in walk(v):
    if n.id == id: return n
  nil

proc sendKey*[R, N](b: var WebBinding[R, N]; id: string;
                    k: Key; ch = ""): KeyOutcome =
  ## Deliver a key to the node named `id`, spelled the way the DOM spells it,
  ## and re-render. Returns what the vocabulary says happened.
  let target = findNode(b.model, id)
  if target.isNil: return ignored()
  let kp = keyFromDom(domKeyName(k, ch))
  result = applyKey(target, kp)
  if result.handled:
    rerender[R, N](b)

# ---------------------------------------------------------------------------
# Reading the rendered tree back
# ---------------------------------------------------------------------------

proc readWebFacts*[R, N](b: WebBinding[R, N]): seq[StateFact] =
  ## Project the RENDERED DOM tree down to `StateFact`s, by reading the
  ## `data-*` attributes off the elements. Deliberately does not look at
  ## `b.model`: a projection that read the model would be comparing the model
  ## with itself, and the cross-medium suite would pass on a binding that
  ## rendered nothing.
  proc visit(r: R; el: N; acc: var seq[StateFact]) =
    if not el.isNil:
      let id = r.getAttribute(el, "data-view-id")
      if id.len > 0:
        let kindName = r.getAttribute(el, "data-view-kind")
        for k in ViewKind:
          if vocabularyName(k) == kindName:
            # The FIELD NAMES come from the vocabulary, not from a list here,
            # so a field added to `nodeFacts` is read back without an edit.
            for f in nodeFacts(ViewNode(kind: k)):
              acc.add fact(id, f.field, r.getAttribute(el, "data-" & f.field))
            break
      var child = r.firstChild(el)
      while not child.isNil:
        visit(r, child, acc)
        child = r.nextSibling(child)
  visit(b.renderer, b.root, result)
