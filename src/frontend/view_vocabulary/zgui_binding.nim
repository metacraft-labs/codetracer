## frontend/view_vocabulary/zgui_binding.nim — the zgui binding: a `ViewNode`
## tree rendered onto zgui's retained document through isonim-zgui.
##
## ## WHY IT STARTS FROM THE WEB BINDING'S DECISIONS
##
## zgui is CSS-native: its `Dom` takes HTML tag names, classes and CSS strings
## and lays them out with Stylo and Taffy. So the decisions the web binding
## makes about tags, roles and the `data-*` facts carry over unchanged, and
## this module takes them from `web_binding` rather than spelling a fourth set:
## `tagFor`, `roleFor`, `domKeyName` and `keyFromDom` are the web's, imported.
## What is this binding's own is everything the medium decides:
##
##   * **its own key transport** — a `keydown` listener registered with zgui,
##     whose key arrives in zgui's event payload (`ZguiEvent.key`, the DOM's
##     spelling), dispatched by zgui to the focused element;
##   * **its own storage** — every fact is read back out of zgui's document
##     across the C ABI (`zg_get_attribute`), never echoed from the model;
##   * **an in-place update** (`update`): a new model is reconciled against the
##     elements already in the document, so a change of one row writes that
##     row's text and nothing else. The GPUI front-end rebuilds a pane's tree
##     on every step (codetracer-pm issue 2026-11-18); a retained document makes
##     the precise update cheap, and the frame time is what this front-end is
##     measured on.
##
## ## WHAT IS SHARED
##
## The reader is `fact_reader.readAttributeFacts`, the one walk the web and
## GPUI bindings use too. `ZguiRenderer` already has the receiver-taking
## `getAttribute`, `firstChild` and `nextSibling` that walk needs.
##
## ## NO MOCKS
##
## `ZguiRenderer` is isonim-zgui's real renderer over zgui's real document,
## reached through the shim's `extern "C"` surface — the shim
## `codetracer-zgui` links. Headless, zgui runs its real cascade, layout and
## paint on its headless platform.

import std/[monotimes, tables, times]

import isonim_zgui/[bindings, renderer]

import ../../common/view_vocabulary
import ./fact_reader
import ./graphemes
from ./web_binding import tagFor, roleFor, domKeyName, keyFromDom

export fact_reader.factAttributeName, fact_reader.ViewIdAttribute,
       fact_reader.ViewKindAttribute

const
  KeyDownEventName* = "keydown"
    ## One listener per interactive element, under the DOM's event name, which
    ## isonim-zgui maps onto zgui's `key_down`.

  ZguiVocabularyCss* = """
[data-view-kind] { color: inherit; }
[data-view-kind="Text"] { display: inline; }
[data-view-kind="List"], [data-view-kind="Tree"] {
  display: flex; flex-direction: column; margin: 0; padding: 0;
  list-style-type: none;
}
[data-view-kind="List"] > li, [data-view-kind="Menu"] > div {
  display: block; white-space: nowrap; overflow: hidden; padding: 0 6px;
}
[data-highlighted="true"] { background-color: #264f78; }
[data-view-kind="Tabs"] { display: flex; flex-direction: row; gap: 2px; }
[data-view-kind="Tabs"] > div[role="tab"] { padding: 2px 8px; }
[data-view-kind="Table"] { display: flex; flex-direction: column; }
[data-view-kind="Table"] > tr { display: flex; flex-direction: row; }
[data-view-kind="Table"] th, [data-view-kind="Table"] td {
  display: block; flex: 1 1 0; min-width: 0; padding: 0 6px;
  white-space: nowrap; overflow: hidden; text-align: left;
}
[data-view-kind="Table"] th { color: #9d9d9d; font-weight: normal; }
[data-cell="cursor"] { background-color: #264f78; }
[data-view-kind="Collapsible"] > summary { display: block; }
[data-view-kind="Tree"] > span { display: block; white-space: nowrap;
  overflow: hidden; text-overflow: ellipsis; }
[data-view-kind="Input"] { background-color: #3c3c3c; color: #cccccc;
  border: 1px solid #555555; min-width: 120px; }
[data-view-kind="Modal"] { display: block; }
"""
    ## What the medium draws for the vocabulary. The web binding leaves this to
    ## the browser's own sheet and the product's stylesheets; zgui has HTML's
    ## user-agent sheet (isonim-zgui `ua.css`) and no product sheet, so the
    ## binding supplies one. Tables are laid out as flex rows: the cells of a
    ## debugger table share the pane's width, which is what the desktop's
    ## tables do.

type
  ZguiBinding* = ref object
    ## A rendered view plus the model it was rendered from.
    renderer*: ZguiRenderer
    root*: ZguiNode
    model*: ViewNode
    nodes*: Table[string, ZguiNode]
      ## the rendered element per `ViewNode.id`.
    keysHandled*: int
      ## `keydown` events that reached an installed listener and were consumed.
    lastOutcome*: KeyOutcome
    onKeyHandled*: proc(id: string) {.closure.}
      ## Called after a consumed key re-rendered the view, so a host can act on
      ## the state the key produced (a list's highlight moving the debugger).
    replaced*: int
      ## Elements `update` created afresh since it was last reset — a subtree
      ## whose shape changed.
    written*: int
      ## Elements `update` wrote in place since it was last reset — a text, an
      ## attribute, a row.
    lastKeyUpdateNs*: int64
      ## How long the last consumed key took to write its state into the
      ## document (`update`), for a host's timing record.

# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func optionRoleFor(k: ViewKind): string =
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

func showsChildren(v: ViewNode): bool =
  ## A `Collapsible`, a `Modal` and a `Tree` render their body only while they
  ## show it — absent, not hidden, as the web binding renders them.
  case v.kind
  of pkCollapsible: v.expanded
  of pkModal: v.open
  of pkTree: v.expanded
  else: true

proc childNodes(el: ZguiNode): seq[ZguiNode] =
  var c = ZguiRenderer().firstChild(el)
  while not c.isNil:
    result.add c
    c = ZguiRenderer().nextSibling(c)

func leadingTexts(v: ViewNode): int =
  ## How many text nodes `renderNode` puts before an element's element
  ## children: one for a `Text` or `Markdown`, none for anything else. Every
  ## other text this binding draws sits alone in its own element, so the
  ## element children are known without asking zgui which node is a text.
  if v.kind in {pkText, pkMarkdown}: 1 else: 0

proc childElements(el: ZguiNode; v: ViewNode): seq[ZguiNode] =
  let all = childNodes(el)
  let skip = min(leadingTexts(v), all.len)
  all[skip .. ^1]

proc onKey(b: ZguiBinding; id, keyName: string): bool

proc installKeyHandler(b: ZguiBinding; el: ZguiNode; id: string) =
  addListener(el, KeyDownEventName, proc(ev: ZguiEvent): uint32 =
    # Only when this element is the target: a key bubbling up from a
    # descendant entry is that entry's.
    if ev.target != el: return 0
    if b.onKey(id, ev.key): 3'u32   # stop propagation, prevent the default
    else: 0'u32)

proc applyFacts(r: ZguiRenderer; el: ZguiNode; v: ViewNode) =
  for f in nodeFacts(v):
    r.setAttribute(el, factAttributeName(f.field), f.value)

proc textChild(r: ZguiRenderer; parent: ZguiNode; text: string) =
  r.appendChild(parent, r.createTextNode(text))

proc renderOption(r: ZguiRenderer; v: ViewNode; i: int): ZguiNode =
  let o = v.options[i]
  result = r.createElement(
    if v.kind == pkSelect: "option" elif v.kind == pkList: "li" else: "div")
  r.setAttribute(result, "data-option-id", o.id)
  r.setAttribute(result, "data-option-index", $i)
  let optRole = optionRoleFor(v.kind)
  if optRole.len > 0: r.setAttribute(result, "role", optRole)
  if o.disabled:
    r.setAttribute(result, "disabled", "true")
    r.setAttribute(result, "aria-disabled", "true")
  let highlighted = if v.kind == pkTabs: i == v.selected else: i == v.highlight
  r.setAttribute(result, "data-highlighted", $highlighted)
  if v.kind == pkSelect:
    if i == v.selected: r.setAttribute(result, "selected", "")
  else:
    r.setAttribute(result, "aria-selected", $highlighted)
  textChild(r, result, o.label)

proc renderRow(r: ZguiRenderer; v: ViewNode; ri: int): ZguiNode =
  result = r.createElement("tr")
  r.setAttribute(result, "data-row-index", $ri)
  for ci, cell in v.rows[ri]:
    let td = r.createElement("td")
    r.setAttribute(td, "data-cell",
      (if ri == v.cursor and ci == v.column: "cursor" else: ""))
    textChild(r, td, cell)
    r.appendChild(result, td)

proc renderNode(b: ZguiBinding; v: ViewNode): ZguiNode =
  let r = b.renderer
  let el = r.createElement(tagFor(v.kind))
  r.setAttribute(el, ViewKindAttribute, vocabularyName(v.kind))
  r.setAttribute(el, ViewIdAttribute, v.id)
  let role = roleFor(v.kind)
  if role.len > 0: r.setAttribute(el, "role", role)
  let inputType = inputTypeFor(v.kind)
  if inputType.len > 0: r.setAttribute(el, "type", inputType)
  if v.disabled: r.setAttribute(el, "disabled", "true")
  if v.kind in InteractiveKinds and not v.disabled:
    r.setAttribute(el, "tabindex", "0")
    installKeyHandler(b, el, v.id)
  applyFacts(r, el, v)

  case v.kind
  of pkText, pkMarkdown:
    # Markdown as its source text: a POC front-end has no block renderer of
    # its own, and the panes it shows carry no Markdown.
    textChild(r, el, v.text)
  of pkCheckbox, pkToggle:
    if v.checked: r.setAttribute(el, "checked", "")
    r.setAttribute(el, "aria-checked", $v.checked)
    if v.label.len > 0:
      r.setAttribute(el, "aria-label", v.label)
  of pkButton, pkModal:
    if v.kind == pkModal and v.open: r.setAttribute(el, "open", "")
    if v.label.len > 0:
      let lab = r.createElement("span")
      r.setAttribute(lab, "class", "view-label")
      textChild(r, lab, v.label)
      r.appendChild(el, lab)
  of pkCollapsible:
    if v.expanded: r.setAttribute(el, "open", "")
    let summary = r.createElement("summary")
    textChild(r, summary, v.label)
    r.appendChild(el, summary)
  of pkImage:
    r.setAttribute(el, "alt", v.alt)
    r.setAttribute(el, "data-media-bytes", $v.mediaBytes)
  of pkInput:
    r.setAttribute(el, "value", v.text)
  of pkSelect, pkList, pkMenu, pkTabs:
    if v.kind == pkMenu and not v.open: r.setAttribute(el, "hidden", "")
    for i in 0 ..< v.options.len:
      r.appendChild(el, renderOption(r, v, i))
  of pkTable:
    let head = r.createElement("tr")
    for c in v.columns:
      let th = r.createElement("th")
      textChild(r, th, c)
      r.appendChild(head, th)
    r.appendChild(el, head)
    for ri in 0 ..< v.rows.len:
      r.appendChild(el, renderRow(r, v, ri))
  of pkProgressIndicator:
    r.setAttribute(el, "max", "100")
    if v.progress != ProgressIndeterminate:
      r.setAttribute(el, "value", $v.progress)
  of pkTree:
    r.setAttribute(el, "aria-expanded", $v.expanded)
    let lab = r.createElement("span")
    textChild(r, lab, v.label)
    r.appendChild(el, lab)

  if showsChildren(v):
    for c in v.children:
      r.appendChild(el, renderNode(b, c))
  el

proc collectNodes(b: ZguiBinding; el: ZguiNode; v: ViewNode) =
  ## Index the rendered elements by `ViewNode.id`. The view children of an
  ## element are its trailing elements: chrome comes first.
  b.nodes[v.id] = el
  if not showsChildren(v) or v.children.len == 0: return
  let kids = childElements(el, v)
  let start = kids.len - v.children.len
  for i, c in v.children:
    collectNodes(b, kids[start + i], c)

proc reindex(b: ZguiBinding) =
  b.nodes = initTable[string, ZguiNode]()
  collectNodes(b, b.root, b.model)

proc rerender*(b: ZguiBinding) =
  ## Build the whole tree afresh and put it where the old one was.
  let fresh = renderNode(b, b.model)
  let old = b.root
  if not old.isNil:
    let parent = b.renderer.parentNode(old)
    if not parent.isNil:
      b.renderer.insertBefore(parent, fresh, old)
    old.release()
  b.root = fresh
  b.reindex()

# ---------------------------------------------------------------------------
# The in-place update
# ---------------------------------------------------------------------------

func sameOptions(a, b: ViewNode): bool =
  if a.options.len != b.options.len: return false
  for i in 0 ..< a.options.len:
    if a.options[i].id != b.options[i].id or
       a.options[i].disabled != b.options[i].disabled:
      return false
  true

func ownEqual(a, b: ViewNode): bool =
  ## Everything a node draws itself, its view children excluded.
  a.kind == b.kind and a.id == b.id and a.label == b.label and
    a.text == b.text and a.disabled == b.disabled and
    a.checked == b.checked and a.options == b.options and
    a.selected == b.selected and a.highlight == b.highlight and
    a.open == b.open and a.expanded == b.expanded and
    a.cursor == b.cursor and a.column == b.column and
    a.columns == b.columns and a.rows == b.rows and
    a.progress == b.progress and a.mediaType == b.mediaType and
    a.mediaBytes == b.mediaBytes and a.alt == b.alt

proc writeFacts(b: ZguiBinding; el: ZguiNode; old, fresh: ViewNode) =
  let was = nodeFacts(old)
  let now = nodeFacts(fresh)
  for i, f in now:
    if i >= was.len or was[i].value != f.value:
      b.renderer.setAttribute(el, factAttributeName(f.field), f.value)

proc setOwnText(b: ZguiBinding; el: ZguiNode; text: string) =
  ## The text of an element whose only child is one text node.
  let t = b.renderer.firstChild(el)
  if not t.isNil and b.renderer.nextSibling(t).isNil:
    b.renderer.setNodeText(t, text)
  else:
    b.renderer.setTextContent(el, text)

proc patchOwn(b: ZguiBinding; el: ZguiNode; old, fresh: ViewNode): bool =
  ## Write `fresh`'s own content over `old`'s in place. False when the shape
  ## differs in a way this does not write (the caller rebuilds the node).
  let r = b.renderer
  case fresh.kind
  of pkText, pkMarkdown:
    if old.text != fresh.text: b.setOwnText(el, fresh.text)
  of pkList, pkMenu, pkTabs, pkSelect:
    if not sameOptions(old, fresh) or old.open != fresh.open: return false
    let opts = childNodes(el)
    if opts.len < fresh.options.len: return false
    for i in 0 ..< fresh.options.len:
      let o = opts[i]
      if old.options[i].label != fresh.options[i].label:
        b.setOwnText(o, fresh.options[i].label)
        inc b.written
      let hiOld = if old.kind == pkTabs: i == old.selected else: i == old.highlight
      let hiNew = if fresh.kind == pkTabs: i == fresh.selected else: i == fresh.highlight
      if hiOld != hiNew:
        r.setAttribute(o, "data-highlighted", $hiNew)
        if fresh.kind != pkSelect: r.setAttribute(o, "aria-selected", $hiNew)
        inc b.written
      if fresh.kind == pkSelect and (i == old.selected) != (i == fresh.selected):
        if i == fresh.selected: r.setAttribute(o, "selected", "")
        else: r.removeAttribute(o, "selected")
  of pkTable:
    if old.columns != fresh.columns: return false
    let rows = childNodes(el)       # the header row, then one per row
    if rows.len != old.rows.len + 1: return false
    # Rows that keep their place are written cell by cell; rows added or
    # removed at the end are created or released.
    let common = min(old.rows.len, fresh.rows.len)
    for ri in 0 ..< common:
      let tr = rows[ri + 1]
      let cursorMoved = (ri == old.cursor) != (ri == fresh.cursor) or
                        (ri == fresh.cursor and old.column != fresh.column)
      if old.rows[ri] == fresh.rows[ri] and not cursorMoved: continue
      if old.rows[ri].len != fresh.rows[ri].len:
        let fr = renderRow(r, fresh, ri)
        r.insertBefore(el, fr, tr)
        tr.release()
        inc b.replaced
        continue
      let cells = childNodes(tr)
      for ci in 0 ..< fresh.rows[ri].len:
        if old.rows[ri][ci] != fresh.rows[ri][ci]:
          b.setOwnText(cells[ci], fresh.rows[ri][ci])
          inc b.written
        let wasCursor = ri == old.cursor and ci == old.column
        let isCursor = ri == fresh.cursor and ci == fresh.column
        if wasCursor != isCursor:
          r.setAttribute(cells[ci], "data-cell", (if isCursor: "cursor" else: ""))
          inc b.written
    for ri in common ..< old.rows.len:
      rows[ri + 1].release()
      inc b.replaced
    let before = if old.rows.len + 1 < rows.len: rows[old.rows.len + 1]
                 else: noNode
    for ri in common ..< fresh.rows.len:
      let fr = renderRow(r, fresh, ri)
      if before.isNil: r.appendChild(el, fr) else: r.insertBefore(el, fr, before)
      inc b.replaced
  else:
    return false
  b.writeFacts(el, old, fresh)
  inc b.written
  true

proc replaceNode(b: ZguiBinding; el: ZguiNode; fresh: ViewNode): ZguiNode =
  result = renderNode(b, fresh)
  let parent = b.renderer.parentNode(el)
  if not parent.isNil: b.renderer.insertBefore(parent, result, el)
  el.release()
  inc b.replaced

proc patchNode(b: ZguiBinding; el: ZguiNode; old, fresh: ViewNode): ZguiNode

proc keyedChildren(b: ZguiBinding; el: ZguiNode; old, fresh: ViewNode): bool =
  ## Reconcile view children by id: a child both models have is written in
  ## place, a new one is created where it belongs, a gone one is released.
  ## A state pane gains and loses locals as the debugger moves, and the rest
  ## of its tree is kept. False when the children cannot be matched this way
  ## (repeated ids, or kept children in a new order), and the caller draws the
  ## node afresh.
  var oldIndex = initTable[string, int]()
  for i, c in old.children:
    if c.id in oldIndex: return false
    oldIndex[c.id] = i
  var seen = initTable[string, bool]()
  var lastKept = -1
  for c in fresh.children:
    if c.id in seen: return false
    seen[c.id] = true
    if c.id in oldIndex:
      if oldIndex[c.id] < lastKept: return false
      lastKept = oldIndex[c.id]
  let kids = childElements(el, old)
  let start = kids.len - old.children.len
  # Gone first, so what is left is in its final relative order.
  for i, c in old.children:
    if c.id notin seen:
      kids[start + i].release()
      inc b.replaced
  var next = 0          # the next kept old child, in order
  var keptOrder: seq[int]
  for c in fresh.children:
    if c.id in oldIndex: keptOrder.add oldIndex[c.id]
  for c in fresh.children:
    if c.id in oldIndex:
      let i = oldIndex[c.id]
      discard b.patchNode(kids[start + i], old.children[i], c)
      inc next
    else:
      let made = renderNode(b, c)
      inc b.replaced
      if next < keptOrder.len:
        b.renderer.insertBefore(el, made, kids[start + keptOrder[next]])
      else:
        b.renderer.appendChild(el, made)
  true

proc patchNode(b: ZguiBinding; el: ZguiNode; old, fresh: ViewNode): ZguiNode =
  ## The element for `fresh`: `el` written in place where the two models share
  ## a shape, a new subtree where they do not.
  if old.kind != fresh.kind or old.id != fresh.id or
     showsChildren(old) != showsChildren(fresh) or
     old.disabled != fresh.disabled:
    return b.replaceNode(el, fresh)
  if not ownEqual(old, fresh) and not b.patchOwn(el, old, fresh):
    return b.replaceNode(el, fresh)
  if showsChildren(fresh):
    if old.children.len == fresh.children.len:
      var sameIds = true
      for i in 0 ..< fresh.children.len:
        if old.children[i].id != fresh.children[i].id: sameIds = false
      if sameIds:
        let kids = childElements(el, old)
        let start = kids.len - fresh.children.len
        for i in 0 ..< fresh.children.len:
          discard b.patchNode(kids[start + i], old.children[i], fresh.children[i])
        return el
    if not b.keyedChildren(el, old, fresh):
      return b.replaceNode(el, fresh)
  el

proc update*(b: ZguiBinding; model: ViewNode) =
  ## Show `model`, writing into the elements already in the document wherever
  ## the old model and this one share a shape.
  if b.root.isNil or b.model.isNil:
    b.model = model
    b.rerender()
    return
  b.root = b.patchNode(b.root, b.model, model)
  b.model = model
  b.reindex()

proc resetCounters*(b: ZguiBinding) =
  b.replaced = 0
  b.written = 0

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

proc findNode(v: ViewNode; id: string): ViewNode =
  for n in walk(v):
    if n.id == id: return n
  nil

proc cloneView(v: ViewNode): ViewNode =
  ## A copy deep enough that `applyKey`, which mutates the node it is given,
  ## leaves the original as the model the document shows.
  if v.isNil: return nil
  result = ViewNode()
  result[] = v[]
  result.children = @[]
  for c in v.children: result.children.add cloneView(c)

proc onKey(b: ZguiBinding; id, keyName: string): bool =
  ## What every installed listener runs. Answers whether the key was consumed.
  ## The model's own machine decides (`behaviour.applyKey`); the key arrived
  ## through zgui's dispatch, and the new state is written into zgui's
  ## document in place — a list's highlight moving rewrites two options.
  let fresh = cloneView(b.model)
  let target = findNode(fresh, id)
  if target.isNil: return false
  let o = applyKey(target, keyFromDom(keyName), graphemeBoundaries)
  b.lastOutcome = o
  if not o.handled: return false
  inc b.keysHandled
  b.resetCounters()
  let t0 = getMonoTime()
  b.update(fresh)
  b.lastKeyUpdateNs = (getMonoTime() - t0).inNanoseconds
  if id in b.nodes: b.nodes[id].focus()
  if not b.onKeyHandled.isNil: b.onKeyHandled(id)
  true

proc renderZgui*(r: ZguiRenderer; model: ViewNode): ZguiBinding =
  ## Render `model`. Its interactive elements carry key listeners that apply
  ## the key and re-render.
  result = ZguiBinding(renderer: r, model: model)
  result.rerender()

proc focusNode*(b: ZguiBinding; id: string): bool =
  if id notin b.nodes: return false
  b.nodes[id].focus()
  true

proc sendKey*(b: ZguiBinding; id: string; k: Key; ch = ""): KeyOutcome =
  ## Deliver a key the way a reader does: focus the element, then press the
  ## key on zgui's headless platform, which routes it to the focused element
  ## through zgui's own dispatch. Answers what the listener reported, or
  ## `ignored()` when no listener consumed it.
  if id notin b.nodes: return ignored()
  b.lastOutcome = ignored()
  let before = b.keysHandled
  b.nodes[id].focus()
  discard settle()
  let name = domKeyName(k, ch)
  zgCheck(zg_headless_key(name.cstring, "".cstring, 0'u32), "sendKey")
  # The platform queues the key; zgui dispatches it in the next frame.
  discard settle()
  if b.keysHandled > before: b.lastOutcome else: ignored()

# ---------------------------------------------------------------------------
# Reading the rendered tree back
# ---------------------------------------------------------------------------

proc readZguiFacts*(b: ZguiBinding): seq[StateFact] =
  ## Project the rendered document down to `StateFact`s by reading the
  ## `data-*` attributes back out of zgui. Never reads `b.model`.
  readAttributeFacts[ZguiRenderer, ZguiNode](b.renderer, b.root)

proc ownTextOf*(b: ZguiBinding; id: string): string =
  ## The text zgui holds under the element for `id`.
  if id notin b.nodes: return ""
  textContent(b.nodes[id])
