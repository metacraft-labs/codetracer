## frontend/view_vocabulary/terminal_binding.nim — PLAT-3 deliverable 2. The
## terminal mapping: a `ViewNode` tree rendered onto isonim-tui's widgets.
##
## ## WHAT MAKES THIS THE STRONG HALF OF THE CROSS-MEDIUM TEST
##
## This binding does NOT route keys through `behaviour.applyKey`. It
## translates a `behaviour.Key` into isonim-tui's own key name, fires a real
## `keydown` at the real widget, and then reads the resulting state OUT OF THE
## WIDGET — `CheckboxWidget.value`, `ListViewWidget.highlightedIndex`,
## `TreeWidget.cursor`, `DataTableWidget.selectedRow`, `InputWidget.value`.
##
## That is deliberate and it is the whole point. If this binding called
## `applyKey` and stamped the answer onto a terminal node, the cross-medium
## suite would be comparing one function's output with itself and would pass
## on a vocabulary whose contract no widget actually honours. Reading the
## widget's own fields makes isonim-tui — a library this repository does not
## own and did not write for this purpose — the independent oracle, and it is
## what turns "the terminal has this entry" from a claim in a table into a
## measurement.
##
## The consequence is that a DISAGREEMENT between the vocabulary and a widget
## shows up as a failing case rather than as a passing one, which is what
## `mappings.terminalMapping`'s per-entry notes were written from.
##
## ## FOUR WIDGETS NEED THE HARNESS, AND IT IS NOT A MOCK
##
## `Collapsible`, `Select`, `ProgressBar` and `Modal` take a
## `isonim_tui.TerminalTestHarness` rather than a bare `TerminalRenderer`,
## because each drives the library's animator. `TerminalTestHarness` is
## isonim-tui's own headless bundle — renderer, driver, compositor, animator,
## focus manager, worker manager and a virtual clock — and is the same object
## every one of isonim-tui's ~60 widget suites constructs. It is a HEADLESS
## HOST, not a stand-in for one: nothing about it is a stub, and the widgets it
## builds are the widgets the terminal front-end ships.
##
## ## WHAT IS NOT BOUND, AND WHY
##
## `Image` needs a `nim_termctl.Image`, which means decoding a real raster.
## `bindView` renders its `alt` through a `LabelWidget` instead, which is what
## `ImageWidget` itself falls back to where no graphics protocol is available
## — and is the reason `alt` is a required field. The entry's own state
## (`mediaType`, `alt`) is what the cross-medium projection compares, and both
## survive the fallback.

import std/[tables, unicode]

import isonim_tui/renderer as tui_renderer
import isonim_tui/events as tui_events
import isonim_tui/testing/harness as tui_harness
import isonim_tui/widgets/label as w_label
import isonim_tui/widgets/button as w_button
import isonim_tui/widgets/checkbox as w_checkbox
import isonim_tui/widgets/switch as w_switch
import isonim_tui/widgets/input as w_input
import isonim_tui/widgets/select as w_select
import isonim_tui/widgets/listview as w_listview
import isonim_tui/widgets/tree as w_tree
import isonim_tui/widgets/datatable as w_datatable
import isonim_tui/widgets/tabs as w_tabs
import isonim_tui/widgets/collapsible as w_collapsible
import isonim_tui/widgets/modal as w_modal
import isonim_tui/widgets/option_list as w_option_list
import isonim_tui/widgets/progress_bar as w_progress
import isonim_tui/widgets/markdown as w_markdown

import ../../common/view_vocabulary

type
  BoundWidget* = object
    ## One vocabulary node and the isonim-tui widget it became.
    ##
    ## A variant over `ViewKind` so that reading a bound node's state is a
    ## total function the compiler checks, and so that a seventeenth entry
    ## cannot be bound by accident.
    id*: string
    node*: TerminalNode      ## the widget's own element, for firing events
    case kind*: ViewKind
    of pkText: labelW*: LabelWidget
    of pkButton: buttonW*: ButtonWidget
    of pkCheckbox: checkboxW*: CheckboxWidget
    of pkToggle: switchW*: SwitchWidget
    of pkInput: inputW*: InputWidget
    of pkSelect: selectW*: SelectWidget
    of pkList: listW*: ListViewWidget
    of pkTree:
      treeW*: TreeWidget
      treeNodes*: Table[string, TreeNodeRef]
        ## vocabulary node id -> the library's own node, so per-node expansion
        ## is read from the library rather than from the model.
      treeOrder*: seq[string]
    of pkTable: tableW*: DataTableWidget
    of pkTabs: tabsW*: TabsWidget
    of pkCollapsible: collapsibleW*: CollapsibleWidget
    of pkModal: modalW*: ModalWidget
    of pkMenu:
      menuListW*: OptionListWidget
      menuModalW*: ModalWidget
        ## THE COMPOSITION `mappings.terminalMapping(pkMenu)` names. isonim-tui
        ## has no menu widget; this is the same pairing `SelectWidget` uses
        ## internally.
    of pkProgressIndicator: progressW*: ProgressBarWidget
    of pkImage:
      imageAltW*: LabelWidget
      imageMediaType*: string
      imageAlt*: string
    of pkMarkdown: markdownW*: MarkdownWidget

  TerminalBinding* = ref object
    harness*: TerminalTestHarness
    root*: TerminalNode
    model*: ViewNode
    bound*: seq[BoundWidget]
    byId*: Table[string, int]   ## `ViewNode.id` -> index into `bound`

# ---------------------------------------------------------------------------
# Key translation
# ---------------------------------------------------------------------------

func terminalKeyName*(k: Key): string =
  ## `behaviour.Key` in isonim-tui's own spelling. The library accepts several
  ## aliases for some keys (`enter`/`return`, `escape`/`esc`); the canonical
  ## one is used here, and the aliases are the library's business.
  case k
  of kNone: ""
  of kChar: ""
  of kEnter: "enter"
  of kSpace: "space"
  of kEscape: "escape"
  of kTab: "tab"
  of kBackTab: "shift+tab"
  of kUp: "up"
  of kDown: "down"
  of kLeft: "left"
  of kRight: "right"
  of kHome: "home"
  of kEnd: "end"
  of kBackspace: "backspace"
  of kDelete: "delete"

func terminalKeyKind(k: Key): KeyKind =
  case k
  of kChar: kkChar
  of kUp, kDown, kLeft, kRight, kHome, kEnd: kkNavigation
  else: kkNamed

func toTerminalEvent*(kp: KeyPress): TerminalEvent =
  ## The event isonim-tui's own drivers construct, built from a vocabulary key.
  if kp.key == kChar:
    let ch = $kp.ch
    newKeyTerminalEvent("keydown",
      newKeyEvent(ch, uint32(int32(kp.ch)), kind = kkChar))
  else:
    newKeyTerminalEvent("keydown",
      newKeyEvent(terminalKeyName(kp.key), 0, kind = terminalKeyKind(kp.key)))

# ---------------------------------------------------------------------------
# Building
# ---------------------------------------------------------------------------

proc buildTreeNodes(v: ViewNode; parent: TreeNodeRef;
                    acc: var Table[string, TreeNodeRef];
                    order: var seq[string]) =
  for c in v.children:
    let n = newTreeNode(c.label, c.id, expandable = c.children.len > 0)
    n.expanded = c.expanded
    parent.addChild(n)
    acc[c.id] = n
    order.add c.id
    buildTreeNodes(c, n, acc, order)

proc bindNode(h: TerminalTestHarness; v: ViewNode): BoundWidget =
  let r = h.renderer
  case v.kind
  of pkText:
    let w = newLabel(r, v.text)
    BoundWidget(id: v.id, kind: pkText, node: w.node, labelW: w)
  of pkButton:
    let w = newButton(r, v.label, disabled = v.disabled)
    BoundWidget(id: v.id, kind: pkButton, node: w.node, buttonW: w)
  of pkCheckbox:
    let w = newCheckbox(r, v.label, v.checked, disabled = v.disabled)
    BoundWidget(id: v.id, kind: pkCheckbox, node: w.node, checkboxW: w)
  of pkToggle:
    let w = newSwitch(r, v.checked, disabled = v.disabled)
    BoundWidget(id: v.id, kind: pkToggle, node: w.node, switchW: w)
  of pkInput:
    let w = newInput(r, v.text)
    BoundWidget(id: v.id, kind: pkInput, node: w.node, inputW: w)
  of pkSelect:
    var choices: seq[SelectChoice] = @[]
    for o in v.options:
      choices.add SelectChoice(id: o.id, label: o.label, disabled: o.disabled)
    let w = newSelect(h, choices, selectedIndex = v.selected)
    BoundWidget(id: v.id, kind: pkSelect, node: w.node, selectW: w)
  of pkList:
    var items: seq[ListItem] = @[]
    for o in v.options:
      items.add ListItem(id: o.id, label: o.label, disabled: o.disabled)
    let w = newListView(r, items)
    BoundWidget(id: v.id, kind: pkList, node: w.node, listW: w)
  of pkTree:
    let w = newTree(r, v.label, v.id)
    w.root.expanded = v.expanded
    var acc = initTable[string, TreeNodeRef]()
    var order: seq[string] = @[]
    acc[v.id] = w.root
    order.add v.id
    buildTreeNodes(v, w.root, acc, order)
    w.cursor = v.cursor
    BoundWidget(id: v.id, kind: pkTree, node: w.node, treeW: w,
                treeNodes: acc, treeOrder: order)
  of pkTable:
    var cols: seq[ColumnDef] = @[]
    for c in v.columns:
      cols.add ColumnDef(key: c, label: c)
    var rows: seq[RowData] = @[]
    for row in v.rows:
      rows.add RowData(cells: row)
    let w = newDataTable(r, cols, rows)
    w.selectedRow = v.cursor
    w.selectedCol = v.column
    BoundWidget(id: v.id, kind: pkTable, node: w.node, tableW: w)
  of pkTabs:
    var tabs: seq[Tab] = @[]
    for o in v.options:
      tabs.add Tab(id: o.id, label: o.label, disabled: o.disabled)
    let w = newTabs(r, tabs, activeIndex = max(v.selected, 0))
    BoundWidget(id: v.id, kind: pkTabs, node: w.node, tabsW: w)
  of pkCollapsible:
    var body: seq[string] = @[]
    for c in v.children:
      body.add (if c.text.len > 0: c.text else: c.label)
    let w = newCollapsible(h, v.label, body,
                           initiallyExpanded = v.expanded)
    BoundWidget(id: v.id, kind: pkCollapsible, node: w.node, collapsibleW: w)
  of pkModal:
    let w = newModal(h, v.label)
    # The library leaves the Escape binding to the application, so a Modal
    # that answered nothing would look like the vocabulary being wrong about
    # its own contract. `installEscapeHandler` is isonim-tui's own answer to
    # exactly that; the binding installs it rather than reimplementing it.
    w.installEscapeHandler()
    if v.open: w.open()
    BoundWidget(id: v.id, kind: pkModal, node: w.node, modalW: w)
  of pkMenu:
    var rows: seq[OptionRow] = @[]
    for o in v.options:
      rows.add OptionRow(kind: orkOption, id: o.id, label: o.label,
                         disabled: o.disabled)
    let list = newOptionList(r, rows)
    list.highlightedIndex = v.highlight
    let holder = newModal(h, "")
    holder.installEscapeHandler()
    if v.open: holder.open()
    BoundWidget(id: v.id, kind: pkMenu, node: list.node,
                menuListW: list, menuModalW: holder)
  of pkProgressIndicator:
    let w = newProgressBar(h, 100.0,
      (if v.progress == ProgressIndeterminate: 0.0 else: float64(v.progress)))
    BoundWidget(id: v.id, kind: pkProgressIndicator, node: w.node,
                progressW: w)
  of pkImage:
    # See the header: the alt text is the fallback ImageWidget itself uses
    # where no graphics protocol is available.
    let w = newLabel(r, v.alt)
    BoundWidget(id: v.id, kind: pkImage, node: w.node, imageAltW: w,
                imageMediaType: v.mediaType, imageAlt: v.alt)
  of pkMarkdown:
    let w = newMarkdown(r, v.text)
    BoundWidget(id: v.id, kind: pkMarkdown, node: w.node, markdownW: w)

const SettleMs = 400
  ## Longer than any animation the bound widgets start: `ModalWidget` ramps
  ## over 200 ms and `CollapsibleWidget` over 250 ms, both on the harness's
  ## VIRTUAL clock, so this costs no wall time. Named rather than inlined
  ## because a widget added later with a longer ramp has to raise it, and a
  ## bare `400` at three call sites would be raised at two of them.

proc settle*(b: TerminalBinding) =
  ## Run the harness's animator to completion.
  ##
  ## isonim-tui animates a Modal open and a Collapsible expand, so the widget
  ## state IMMEDIATELY after a key is a transitional one (`msOpening`) rather
  ## than the end state the vocabulary specifies. The vocabulary describes end
  ## states and says so — `mappings.terminalMapping(pkCollapsible)` records
  ## that the entry "specifies the end states and not the path between them" —
  ## so the binding settles the clock before anyone reads state back. The
  ## clock is VIRTUAL (`TestClock`), so this is not a sleep.
  b.harness.advance(SettleMs)

proc bindView*(h: TerminalTestHarness; model: ViewNode): TerminalBinding =
  ## Render `model` onto isonim-tui widgets under `h`.
  ##
  ## A `Tree` binds as ONE widget (the library's `TreeWidget` owns the whole
  ## hierarchy), so its children are not bound separately; every other
  ## container's children are.
  let b = TerminalBinding(harness: h, model: model,
                          byId: initTable[string, int]())
  b.root = h.renderer.createElement("div")
  proc visit(v: ViewNode) =
    let bw = bindNode(h, v)
    b.byId[v.id] = b.bound.len
    b.bound.add bw
    h.renderer.appendChild(b.root, bw.node)
    if v.kind != pkTree:
      for c in v.children:
        visit(c)
  visit(model)
  b.settle()
  b

# ---------------------------------------------------------------------------
# Driving
# ---------------------------------------------------------------------------

proc sendKey*(b: TerminalBinding; id: string; k: Key; ch = ' '): bool =
  ## Fire a real `keydown` at the widget bound to `id`, spelled the way
  ## isonim-tui spells it. Returns whether a widget was found; what the key DID
  ## is read back with `readTerminalFacts`, from the widget, not from here.
  if id notin b.byId: return false
  let bw = b.bound[b.byId[id]]
  let kp = if k == kChar: typeChar(ch) else: press(k)
  let ev = toTerminalEvent(kp)
  case bw.kind
  of pkSelect:
    # The Select's own overlay owns the keys while it is open, exactly as it
    # would with a real reader: the widget builds an OptionList inside a Modal
    # on open, and that list is where Up/Down/Enter/Escape land.
    if bw.selectW.optionList != nil and bw.selectW.modal != nil and
       bw.selectW.modal.state == msOpen:
      fireEventWith(bw.selectW.optionList.node, "keydown", ev)
    else:
      fireEventWith(bw.node, "keydown", ev)
  of pkMenu:
    if k == kEscape:
      # THE PANEL, NOT THE OVERLAY NODE. `installEscapeHandler` registers on
      # `m.panel`, which is the trapped region a real reader's focus is inside;
      # `m.node` is the outer overlay. Firing at the overlay reached no handler
      # and the modal stayed open — measured, and the reason this line names
      # `panel` explicitly rather than reusing `bw.node`.
      fireEventWith(bw.menuModalW.panel, "keydown", ev)
    else:
      fireEventWith(bw.menuListW.node, "keydown", ev)
  of pkModal:
    fireEventWith(bw.modalW.panel, "keydown", ev)
  else:
    fireEventWith(bw.node, "keydown", ev)
  b.settle()
  true

# ---------------------------------------------------------------------------
# Reading the widgets back
# ---------------------------------------------------------------------------

func selectHighlight(w: SelectWidget): int =
  ## While the overlay is open the highlight is the option list's; while it is
  ## closed the vocabulary says the highlight returns to the committed choice.
  if w.optionList != nil and w.modal != nil and w.modal.state == msOpen:
    w.optionList.highlightedIndex
  else:
    w.selectedIndex

proc widgetFacts(bw: BoundWidget): seq[StateFact] =
  ## The state isonim-tui's widget objects hold, projected onto the same
  ## `(id, field, value)` triples `vocabulary.nodeFacts` produces. The FIELD
  ## NAMES have to match `nodeFacts` exactly, which is what makes the two
  ## projections comparable; a field renamed in one place fails the suite's
  ## field-name case rather than silently comparing nothing.
  case bw.kind
  of pkText:
    @[fact(bw.id, "text", bw.labelW.node.textContent)]
  of pkButton:
    @[fact(bw.id, "label", bw.buttonW.label),
      fact(bw.id, "disabled", $bw.buttonW.disabled)]
  of pkCheckbox:
    @[fact(bw.id, "checked", $bw.checkboxW.value)]
  of pkToggle:
    @[fact(bw.id, "checked", $bw.switchW.value)]
  of pkInput:
    # `InputWidget.selection.cursor` is a GRAPHEME-CLUSTER index and the
    # vocabulary's `Input.cursor` is a RUNE index. They agree on everything
    # that is not a combining sequence or an emoji ZWJ join, and they diverge
    # on those — a real difference between the two definitions, recorded here
    # and in `mappings.terminalMapping(pkInput)` rather than papered over by
    # converting one into the other. The cross-medium suite drives ASCII, and
    # says so.
    @[fact(bw.id, "text", bw.inputW.value),
      fact(bw.id, "cursor", $bw.inputW.selection.cursor)]
  of pkSelect:
    @[fact(bw.id, "selected", $bw.selectW.selectedIndex),
      fact(bw.id, "highlight", $selectHighlight(bw.selectW)),
      fact(bw.id, "open", $(bw.selectW.modal != nil and
                            bw.selectW.modal.state == msOpen))]
  of pkList:
    @[fact(bw.id, "highlight", $bw.listW.highlightedIndex)]
  of pkTree:
    # ONLY THE VISIBLE NODES, walked through the LIBRARY's own `expanded`
    # flags. A collapsed node's children have no state a reader can observe
    # on any medium — "present or absent" is the entry's own word — and the
    # web binding renders exactly the visible set, so a terminal projection
    # that reported the whole hierarchy would report state the other medium
    # correctly does not have.
    var acc: seq[StateFact] = @[]
    proc visitTree(n: TreeNodeRef) =
      let id = n.data
      acc.add fact(id, "expanded", $n.expanded)
      acc.add fact(id, "cursor", (if id == bw.id: $bw.treeW.cursor else: "0"))
      if n.expanded:
        for c in n.children:
          visitTree(c)
    visitTree(bw.treeW.root)
    acc
  of pkTable:
    @[fact(bw.id, "row", $bw.tableW.selectedRow),
      fact(bw.id, "column", $bw.tableW.selectedCol)]
  of pkTabs:
    @[fact(bw.id, "selected", $bw.tabsW.activeIndex)]
  of pkCollapsible:
    @[fact(bw.id, "expanded", $bw.collapsibleW.expanded)]
  of pkModal:
    @[fact(bw.id, "open", $(bw.modalW.state in {msOpen, msOpening}))]
  of pkMenu:
    @[fact(bw.id, "highlight", $bw.menuListW.highlightedIndex),
      fact(bw.id, "open", $(bw.menuModalW.state in {msOpen, msOpening}))]
  of pkProgressIndicator:
    @[fact(bw.id, "progress", $int(bw.progressW.progress))]
  of pkImage:
    @[fact(bw.id, "mediaType", bw.imageMediaType),
      fact(bw.id, "alt", bw.imageAlt)]
  of pkMarkdown:
    # The library's MarkdownWidget parses the source into an `MdDocument` and
    # does not keep the source, so the SOURCE is not readable back out of the
    # widget. Reported as "" rather than echoed from the model, and the suite
    # excludes Markdown's `text` from the comparison BY NAME with this reason
    # beside it — an unexplained exclusion is how a suite stops covering the
    # thing it claims to cover.
    @[fact(bw.id, "text", "")]

proc readTerminalFacts*(b: TerminalBinding): seq[StateFact] =
  ## Every VISIBLE bound widget's state.
  ##
  ## Visibility is read from the WIDGETS — `CollapsibleWidget.expanded`,
  ## `ModalWidget.state` — and not from the model, for the same reason every
  ## other fact here is. A closed Modal's body is state no reader can observe,
  ## and the web binding does not render it at all, so a terminal projection
  ## that reported it would be reporting a difference that is not one.
  proc visit(v: ViewNode; acc: var seq[StateFact]) =
    if v.id notin b.byId: return
    let bw = b.bound[b.byId[v.id]]
    acc.add widgetFacts(bw)
    if v.kind == pkTree: return   # the TreeWidget owns its whole subtree
    let showChildren =
      case bw.kind
      of pkCollapsible: bw.collapsibleW.expanded
      of pkModal: bw.modalW.state in {msOpen, msOpening}
      else: true
    if showChildren:
      for c in v.children:
        visit(c, acc)
  visit(b.model, result)
