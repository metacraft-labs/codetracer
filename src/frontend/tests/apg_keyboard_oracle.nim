## apg_keyboard_oracle.nim — the W3C ARIA Authoring Practices' own reference
## widgets, as a keyboard oracle, in the page `chromium-run.mjs` opens.
##
## The scripts under `vendor/aria-practices/` are the Authoring Practices
## Guide's example implementations of a listbox, a tree view and a data grid,
## copied verbatim (see `PROVENANCE.md` there). This module only BUILDS the
## markup those scripts expect, hands it to them, puts each widget in a given
## state, and READS BACK where the widget's own code moved its focus. It never
## decides what a key does: a key reaches the widget through Chromium's input
## pipeline (the suite presses it with `ctPress`), and the widget's handler —
## W3C's code — moves the focus.
##
## ## WHY IT IS INDEPENDENT, AND HOW THAT IS KEPT
##
## The suite's other oracle is isonim-tui's widgets, read in the C suite and
## carried here as a fixture. Neither the vocabulary's key rules nor
## isonim-tui's widgets share an author or a line of code with W3C's scripts,
## and this glue must not become the path by which they meet: a glue that
## consulted the vocabulary's own answer would agree with it for the same
## reason the vocabulary agrees with itself (Verification-Harness-Traps
## §22, §30a). So the glue knows nothing of the vocabulary — it takes plain
## data (a list of availabilities, a tree of ids, a grid's size) — and the
## suite scans THIS FILE's text for the vocabulary's spellings
## (`ForbiddenInOracle`), with the list's cardinality asserted.

when not defined(js):
  {.error: "apg_keyboard_oracle runs in a browser page".}

import std/[jsffi, strutils]

const
  ApgSources = [
    staticRead("vendor/aria-practices/utils.js"),
    staticRead("vendor/aria-practices/listbox.js"),
    staticRead("vendor/aria-practices/treeitem.js"),
    staticRead("vendor/aria-practices/tree.js"),
    staticRead("vendor/aria-practices/dataGrid.js")]
    ## In dependency order. `tree.js` also registers a `load` listener; the
    ## page has loaded by the time a suite runs, so it never fires and the
    ## tree is initialised here instead.

type
  ApgNode* = ref object
    ## One tree item: its id, whether it is open, and its children. A node
    ## with children is expandable, as the reference tree decides it — by the
    ## presence of its group.
    id*: string
    expanded*: bool
    children*: seq[ApgNode]

  ApgListbox* = object
    node: JsObject
    widget: JsObject

  ApgTree* = object
    node: JsObject
    widget: JsObject

  ApgGrid* = object
    node: JsObject
    widget: JsObject

proc runScript(src: cstring) {.importjs:
  "((s) => { const e = document.createElement('script'); e.textContent = s; document.head.appendChild(e); })(#)".}
proc mk(tag: cstring): JsObject {.importjs: "document.createElement(#)".}
proc setAttr(e: JsObject; n, v: cstring) {.importjs: "#.setAttribute(#, #)".}
proc getAttr(e: JsObject; n: cstring): cstring {.importjs:
  "(#.getAttribute(#) ?? '')".}
proc append(p, c: JsObject) {.importjs: "#.appendChild(#)".}
proc setText(e: JsObject; t: cstring) {.importjs: "#.textContent = #".}
proc byId(id: cstring): JsObject {.importjs: "document.getElementById(#)".}
proc active(): JsObject {.importjs: "(document.activeElement)".}
proc focusEl(e: JsObject) {.importjs: "#.focus()".}
proc isNull(e: JsObject): bool {.importjs: "(# == null)".}
proc newListboxOf(n: JsObject): JsObject {.importjs: "new aria.Listbox(#)".}
proc newTreeOf(n: JsObject): JsObject {.importjs: "new Tree(#)".}
proc newGridOf(n: JsObject): JsObject {.importjs: "new aria.Grid(#)".}

var injected = false

proc injectReferenceWidgets*() =
  ## Run W3C's scripts in the page, once.
  if injected: return
  for src in ApgSources: runScript(cstring(src))
  injected = true

# ---------------------------------------------------------------------------
# Listbox
# ---------------------------------------------------------------------------

proc newApgListbox*(host: JsObject; disabled: seq[bool]): ApgListbox =
  ## A single-select listbox of `disabled.len` options, each marked
  ## `aria-disabled` when it is unavailable.
  injectReferenceWidgets()
  let ul = mk("ul")
  setAttr(ul, "role", "listbox")
  setAttr(ul, "tabindex", "0")
  for i, d in disabled:
    let li = mk("li")
    setAttr(li, "role", "option")
    setAttr(li, "id", cstring("apg-o-" & $i))
    setAttr(li, "data-index", cstring($i))
    if d: setAttr(li, "aria-disabled", "true")
    setText(li, cstring("option " & $i))
    append(ul, li)
  append(host, ul)
  ApgListbox(node: ul, widget: newListboxOf(ul))

proc syncListbox*(lb: ApgListbox; index: int) =
  ## Put the listbox's active option at `index`, through its own method, and
  ## give it the keyboard.
  let el = byId(cstring("apg-o-" & $index))
  if not el.isNull:
    discard lb.widget.focusItem(el)
  focusEl(lb.node)

proc listboxIndex*(lb: ApgListbox): int =
  ## The option the listbox's own code made active.
  let el = byId(getAttr(lb.node, "aria-activedescendant"))
  if el.isNull: -1 else: parseInt($getAttr(el, "data-index"))

# ---------------------------------------------------------------------------
# Tree
# ---------------------------------------------------------------------------

proc buildItem(n: ApgNode; parent: JsObject; counter: var int) =
  let li = mk("li")
  setAttr(li, "role", "treeitem")
  setAttr(li, "id", cstring("apg-t-" & $counter))
  setAttr(li, "data-node", cstring(n.id))
  inc counter
  let label = mk("span")
  setText(label, cstring(n.id))
  append(li, label)
  if n.children.len > 0:
    setAttr(li, "aria-expanded", if n.expanded: "true" else: "false")
    let group = mk("ul")
    for c in n.children: buildItem(c, group, counter)
    append(li, group)
  append(parent, li)

proc newApgTree*(host: JsObject; root: ApgNode): ApgTree =
  injectReferenceWidgets()
  let ul = mk("ul")
  setAttr(ul, "role", "tree")
  var counter = 0
  buildItem(root, ul, counter)
  append(host, ul)
  let t = newTreeOf(ul)
  discard t.init()
  ApgTree(node: ul, widget: t)

proc visibleItems(t: ApgTree): seq[JsObject] =
  let items = t.widget.treeitems
  for i in 0 ..< items.length.to(int):
    let ti = items[i]
    if ti.isVisible.to(bool): result.add ti

proc syncTree*(t: ApgTree; expanded: proc(id: string): bool; cursor: int) =
  ## Open exactly the items `expanded` names, let the tree recompute what is
  ## visible, and focus the `cursor`-th visible item.
  let items = t.widget.treeitems
  for i in 0 ..< items.length.to(int):
    let dom = items[i].domNode
    if not isNull(dom) and getAttr(dom, "aria-expanded").len > 0:
      setAttr(dom, "aria-expanded",
              if expanded($getAttr(dom, "data-node")): "true" else: "false")
  discard t.widget.updateVisibleTreeitems()
  let vis = t.visibleItems()
  if cursor >= 0 and cursor < vis.len:
    discard t.widget.setFocusToItem(vis[cursor])

proc treeCursor*(t: ApgTree): int =
  ## Where the tree's own code put the focus, as an index into what it shows.
  let a = active()
  for i, ti in t.visibleItems():
    if ti.domNode == a: return i
  -1

proc treeVisibleCount*(t: ApgTree): int = t.visibleItems().len

proc treeIsOpen*(t: ApgTree; id: string): bool =
  let items = t.widget.treeitems
  for i in 0 ..< items.length.to(int):
    let dom = items[i].domNode
    if $getAttr(dom, "data-node") == id:
      return $getAttr(dom, "aria-expanded") == "true"
  false

# ---------------------------------------------------------------------------
# Grid
# ---------------------------------------------------------------------------

proc newApgGrid*(host: JsObject; rows, columns: int): ApgGrid =
  ## A data grid of `rows` x `columns` focusable cells under one header row.
  injectReferenceWidgets()
  let table = mk("table")
  setAttr(table, "role", "grid")
  let head = mk("tr")
  for c in 0 ..< columns:
    let th = mk("th")
    setText(th, cstring("column " & $c))
    append(head, th)
  append(table, head)
  for r in 0 ..< rows:
    let tr = mk("tr")
    for c in 0 ..< columns:
      let td = mk("td")
      setAttr(td, "tabindex", "-1")
      setAttr(td, "data-row", cstring($r))
      setAttr(td, "data-col", cstring($c))
      setText(td, cstring($r & "," & $c))
      append(tr, td)
    append(table, tr)
  append(host, table)
  ApgGrid(node: table, widget: newGridOf(table))

proc syncGrid*(g: ApgGrid; row, column: int) =
  discard g.widget.focusCell(row, column)

proc gridCell*(g: ApgGrid): (int, int) =
  ## The cell the grid's own code focused; (-1, -1) when none of its cells is.
  let a = active()
  if a.isNull or getAttr(a, "data-row").len == 0: return (-1, -1)
  (parseInt($getAttr(a, "data-row")), parseInt($getAttr(a, "data-col")))
