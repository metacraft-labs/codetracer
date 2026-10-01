## viewmodels/menu_vm.nim — PLAT-48 deliverable 1. THE PROGRAM MENU AS
## LOGICAL STATE, ONE MODEL FOR EVERY FRONT-END.
##
## ## What is in here, and what is deliberately not
##
## The menu's TREE (folders, items, separators, enabled / checked, the action
## an item runs, the keyboard shortcut to DISPLAY beside it) and its
## INTERACTION STATE: whether it is open, the path of folders the user has
## entered, the highlighted item at the deepest open level, whether the
## highlight came from the keyboard, the type-to-select prefix and the menu's
## own search. Every keyboard and pointer event a front-end receives becomes
## one of the operations below.
##
## Nothing here is a measurement. The desktop's `ui/menu.nim` measures item
## widths and submenu offsets in the DOM (`activePathWidths`,
## `activePathOffsets`); the terminal decides which cell a dropdown starts at;
## GPUI places a popover in pixels. Those stay in each renderer, for the reason
## Layout-ViewModel §5 gives about the layout model: a ViewModel that carried a
## cell or a pixel would be one front-end's model with the others adapting to
## it.
##
## ## One copy of the state
##
## Until PLAT-48 the desktop kept `active`, `activePath`, `activeIndex`,
## `activeLength`, `keyNavigation` and the search fields on
## `MenuComponent` itself, and a terminal or GPUI menu would have had to
## re-derive every rule (what `Right` does on an item that is not a folder,
## whether a hidden macOS-only folder can be highlighted). They are all here
## now; `ui/menu.nim` reads them when it renders and calls these operations
## from its event handlers, and the verification gate mutates `highlight` here
## and reads the highlighted item back out of the desktop's DOM.
##
## ## Portable
##
## Plain Nim: strings, ints, sequences and a table. It compiles on the C and
## the JavaScript backends (vm-unit and vm-unit-js both run its suite), holds
## no signal and imports no renderer. A host that wants to repaint when it
## changes installs `onChange`.

import std/[strutils, tables]

type
  MenuItemKind* = enum
    mikFolder = "folder"
    mikAction = "action"

  MenuItem* = object
    ## One entry of the menu tree.
    kind*: MenuItemKind
    label*: string
    action*: string
      ## The command an action item runs, spelled as the desktop's
      ## `ClientAction` member name (`forwardNext`, `aResetLayout`, …) — the
      ## vocabulary the desktop's keyboard shortcuts, its command palette and
      ## its native macOS menu already share. "" for a folder.
    enabled*: bool
    checked*: bool
      ## A toggle item's state. No item of today's tree is a toggle; the
      ## field is here so one can be added without changing the model.
    hidden*: bool
      ## Present in the tree but not on this platform (a macOS-only folder on
      ## Linux). Kept in place rather than removed, so a path names the same
      ## item on every platform and the desktop's `MenuNode` indices stay
      ## valid; navigation and rendering skip it.
    separatorAfter*: bool
      ## A separator follows this item (the desktop's
      ## `MenuNode.isBeforeNextSubGroup`).
    role*: string
      ## The macOS native-menu role, for the items macOS draws itself.
    os*: int
      ## The desktop's `MenuNodeOS` bits: which platforms the item is for.
      ## Carried so the desktop can build its `MenuNode` tree — and the
      ## native macOS menu — from this one tree.
    children*: seq[MenuItem]

  MenuActivation* = object
    ## What activating an item did.
    ran*: bool
      ## An action item was chosen: the host runs `action` and the menu is
      ## closed.
    action*: string
    path*: seq[int]
      ## The chosen item's path from the root.

  MenuVM* = ref object
    root*: MenuItem
      ## The whole tree; its children are the top-level folders.
    shortcuts*: Table[string, string]
      ## The chord to DISPLAY beside each action, from the front-end's ACTIVE
      ## keymap (`setShortcuts`). Absent means "not bound": nothing is shown.
    isOpen*: bool
    path*: seq[int]
      ## The folders entered, from the root: `[]` is the top level open,
      ## `[3]` means the fourth top-level folder's items are showing.
    highlight*: int
      ## The highlighted item at the deepest open level (an index into that
      ## level's `children`), or -1.
    keyNavigation*: bool
      ## Whether the highlight was put there by the keyboard. The desktop
      ## marks only a keyboard highlight (a hovered item is `:hover` CSS).
    typeahead*: string
    typeaheadAtMs*: int64
    searchQuery*: string
    searchResults*: seq[MenuActivation]
      ## Items the menu's own search matched, in tree order.
    searchLabels*: seq[string]
    searchIndex*: int
    revision*: int
      ## Bumped by every change, so a renderer can skip a repaint that would
      ## draw the same menu.
    onChange*: proc() {.closure.}

const
  TypeaheadResetMs* = 1000'i64
    ## How long a type-to-select prefix waits for its next character before
    ## a new keystroke starts a new prefix — the common menu convention.
  MenuShortcutNone* = ""

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

func folder*(label: string; children: seq[MenuItem]; os = 0;
             role = ""; hidden = false): MenuItem =
  MenuItem(kind: mikFolder, label: label, enabled: true, os: os, role: role,
           hidden: hidden, children: children)

func item*(label, action: string; enabled = true; os = 0;
           role = ""): MenuItem =
  MenuItem(kind: mikAction, label: label, action: action, enabled: enabled,
           os: os, role: role)

func sep*(it: MenuItem): MenuItem =
  ## `it`, with a separator after it.
  result = it
  result.separatorAfter = true

proc changed(vm: MenuVM) =
  inc vm.revision
  if not vm.onChange.isNil:
    vm.onChange()

proc newMenuVM*(root = MenuItem(kind: mikFolder, enabled: true)): MenuVM =
  MenuVM(root: root, shortcuts: initTable[string, string](), isOpen: false,
         path: @[], highlight: -1, searchIndex: 0)

# ---------------------------------------------------------------------------
# Reading the tree
# ---------------------------------------------------------------------------

proc folderAt*(vm: MenuVM; path: openArray[int]): MenuItem =
  ## The folder the path names (the root for `[]`), or an empty folder when
  ## the path does not name a folder any more.
  result = vm.root
  for i in path:
    if i < 0 or i >= result.children.len or
       result.children[i].kind != mikFolder:
      return MenuItem(kind: mikFolder)
    result = result.children[i]

proc itemAt*(vm: MenuVM; path: openArray[int]): MenuItem =
  ## The item at a full path (the last index is the item itself).
  if path.len == 0:
    return vm.root
  let parent = vm.folderAt(path[0 ..< path.len - 1])
  let i = path[^1]
  if i < 0 or i >= parent.children.len:
    return MenuItem(kind: mikAction)
  parent.children[i]

proc level*(vm: MenuVM; depth: int): seq[MenuItem] =
  ## The items shown at `depth` (0 = the top level) along the open path.
  if depth > vm.path.len:
    return @[]
  vm.folderAt(vm.path[0 ..< depth]).children

proc currentLevel*(vm: MenuVM): seq[MenuItem] =
  vm.level(vm.path.len)

proc selectable(it: MenuItem): bool = not it.hidden

proc firstSelectable(items: seq[MenuItem]): int =
  for i, it in items:
    if it.selectable:
      return i
  -1

proc visibleChildren*(it: MenuItem): seq[int] =
  ## The indices of the children a renderer draws.
  for i, c in it.children:
    if not c.hidden:
      result.add i

proc highlightedItem*(vm: MenuVM): MenuItem =
  let items = vm.currentLevel()
  if vm.highlight < 0 or vm.highlight >= items.len:
    return MenuItem(kind: mikAction)
  items[vm.highlight]

proc highlightedPath*(vm: MenuVM): seq[int] =
  ## The highlighted item's full path, or `[]` when nothing is highlighted.
  if vm.highlight < 0:
    return @[]
  vm.path & @[vm.highlight]

proc isOnPath*(vm: MenuVM; path: openArray[int]): bool =
  ## Whether `path` names a folder that is open, or the highlighted item —
  ## what a renderer marks as "active" on every level.
  if path.len == 0:
    return false
  if path.len <= vm.path.len:
    for i in 0 ..< path.len:
      if vm.path[i] != path[i]:
        return false
    return true
  if path.len == vm.path.len + 1:
    for i in 0 ..< vm.path.len:
      if vm.path[i] != path[i]:
        return false
    return path[^1] == vm.highlight
  false

proc shortcutFor*(vm: MenuVM; action: string): string =
  vm.shortcuts.getOrDefault(action, MenuShortcutNone)

proc collectActions(n: MenuItem; p: seq[int];
                    acc: var seq[tuple[path: seq[int], item: MenuItem]]) =
  for i, c in n.children:
    if c.kind == mikFolder:
      collectActions(c, p & @[i], acc)
    else:
      acc.add (path: p & @[i], item: c)

proc actionItems*(it: MenuItem): seq[tuple[path: seq[int], item: MenuItem]] =
  ## Every ACTION item under `it`, depth first, with its path.
  collectActions(it, @[], result)

proc pathOfAction*(vm: MenuVM; action: string): seq[int] =
  ## The path of the first item that runs `action`, or `[]`.
  for (p, it) in vm.root.actionItems():
    if it.action == action:
      return p
  @[]

# ---------------------------------------------------------------------------
# Changing the tree and the displayed shortcuts
# ---------------------------------------------------------------------------

proc setTree*(vm: MenuVM; root: MenuItem) =
  ## Replace the tree. An open path that no longer names folders is closed
  ## back to the deepest level that still exists.
  vm.root = root
  var keep: seq[int] = @[]
  var node = root
  for i in vm.path:
    if i < 0 or i >= node.children.len or node.children[i].kind != mikFolder:
      break
    keep.add i
    node = node.children[i]
  vm.path = keep
  if vm.highlight >= node.children.len:
    vm.highlight = firstSelectable(node.children)
  vm.changed()

proc setShortcuts*(vm: MenuVM; shortcuts: Table[string, string]) =
  ## Install the chords of the ACTIVE keymap. Called again whenever the
  ## keymap changes, which is how a keymap switch changes what the menu shows.
  vm.shortcuts = shortcuts
  vm.changed()

proc setEnabled*(vm: MenuVM; available: proc(action: string): bool) =
  ## Mark every action item enabled exactly when `available` says the
  ## front-end can perform it. A front-end that cannot run an action shows it
  ## disabled rather than dropping it, so every front-end has the same menu.
  proc walk(n: var MenuItem) =
    for c in n.children.mitems:
      if c.kind == mikFolder:
        walk(c)
      else:
        c.enabled = available(c.action)
  walk(vm.root)
  vm.changed()

# ---------------------------------------------------------------------------
# Opening and closing
# ---------------------------------------------------------------------------

proc open*(vm: MenuVM; keyboard = true) =
  ## Show the top level, the first item highlighted.
  vm.isOpen = true
  vm.path = @[]
  vm.highlight = firstSelectable(vm.root.children)
  vm.keyNavigation = keyboard
  vm.typeahead = ""
  vm.changed()

proc close*(vm: MenuVM) =
  vm.isOpen = false
  vm.path = @[]
  vm.highlight = -1
  vm.keyNavigation = false
  vm.typeahead = ""
  vm.searchQuery = ""
  vm.searchResults = @[]
  vm.searchLabels = @[]
  vm.searchIndex = 0
  vm.changed()

proc toggle*(vm: MenuVM) =
  if vm.isOpen: vm.close() else: vm.open(keyboard = false)

proc openFolder*(vm: MenuVM; index: int; keyboard = true) =
  ## Open the top-level folder `index` directly — a menu bar's click on a
  ## folder title, or `Alt+<letter>`.
  let items = vm.root.children
  if index < 0 or index >= items.len or items[index].hidden:
    return
  vm.isOpen = true
  vm.keyNavigation = keyboard
  if items[index].kind == mikFolder:
    vm.path = @[index]
    vm.highlight = firstSelectable(items[index].children)
  else:
    vm.path = @[]
    vm.highlight = index
  vm.changed()

# ---------------------------------------------------------------------------
# Keyboard
# ---------------------------------------------------------------------------

proc moveHighlight*(vm: MenuVM; delta: int) =
  ## `Up` / `Down` (and, on a menu bar's top level, `Left` / `Right`): the
  ## next selectable item at the current level, wrapping.
  if not vm.isOpen:
    return
  let items = vm.currentLevel()
  if items.len == 0:
    return
  var i = vm.highlight
  if i < 0:
    i = (if delta > 0: -1 else: items.len)
  for _ in 0 ..< items.len:
    i = (i + (if delta > 0: 1 else: -1) + items.len) mod items.len
    if items[i].selectable:
      break
  vm.highlight = i
  vm.keyNavigation = true
  vm.changed()

proc enterFolder*(vm: MenuVM): bool =
  ## `Right` / `Enter` on a folder: open it, its first item highlighted.
  ## Answers whether a folder was entered.
  let it = vm.highlightedItem()
  if not vm.isOpen or it.kind != mikFolder or not it.enabled or it.hidden:
    return false
  vm.path.add vm.highlight
  vm.highlight = firstSelectable(it.children)
  vm.keyNavigation = true
  vm.changed()
  true

proc leaveFolder*(vm: MenuVM): bool =
  ## `Left` / `Esc` inside a folder: back to its parent, the folder
  ## highlighted. Answers whether there was a folder to leave.
  if vm.path.len == 0:
    return false
  vm.highlight = vm.path.pop()
  vm.keyNavigation = true
  vm.changed()
  true

proc escape*(vm: MenuVM) =
  ## `Esc`: leave the open folder, or close the menu at the top level.
  if not vm.leaveFolder():
    vm.close()

proc siblingMenu*(vm: MenuVM; delta: int) =
  ## A menu bar's `Left` / `Right` inside a dropdown: the neighbouring
  ## top-level folder, opened.
  if not vm.isOpen or vm.path.len == 0:
    vm.moveHighlight(delta)
    return
  let items = vm.root.children
  if items.len == 0:
    return
  var i = vm.path[0]
  for _ in 0 ..< items.len:
    i = (i + (if delta > 0: 1 else: -1) + items.len) mod items.len
    if items[i].selectable:
      break
  vm.openFolder(i)

proc activate*(vm: MenuVM): MenuActivation =
  ## `Enter`: run the highlighted action (the menu closes), or enter the
  ## highlighted folder. A disabled item does nothing.
  if not vm.isOpen:
    return
  if vm.searchResults.len > 0:
    let chosen = vm.searchResults[max(0, min(vm.searchIndex,
                                              vm.searchResults.high))]
    vm.close()
    return chosen
  let it = vm.highlightedItem()
  if it.kind == mikFolder:
    discard vm.enterFolder()
    return
  if it.hidden or not it.enabled or it.action.len == 0:
    return
  result = MenuActivation(ran: true, action: it.action,
                          path: vm.highlightedPath())
  vm.close()

proc typeToSelect*(vm: MenuVM; ch: string; nowMs: int64 = 0) =
  ## Type-to-select: the next item at the current level whose label starts
  ## with the prefix typed so far (case-insensitive). A pause longer than
  ## `TypeaheadResetMs` starts a new prefix. The same character typed again
  ## cycles through the items that start with it.
  if not vm.isOpen or ch.len == 0:
    return
  if nowMs - vm.typeaheadAtMs > TypeaheadResetMs:
    vm.typeahead = ""
  vm.typeaheadAtMs = nowMs
  let cycling = vm.typeahead.len == 1 and
                vm.typeahead.toLowerAscii == ch.toLowerAscii
  if not cycling:
    vm.typeahead.add ch
  let prefix = vm.typeahead.toLowerAscii
  let items = vm.currentLevel()
  let start = if cycling: vm.highlight + 1 else: max(0, vm.highlight)
  for k in 0 ..< items.len:
    let i = (start + k) mod items.len
    if items[i].selectable and
       items[i].label.toLowerAscii.startsWith(prefix):
      vm.highlight = i
      vm.keyNavigation = true
      vm.changed()
      return

# ---------------------------------------------------------------------------
# Pointer
# ---------------------------------------------------------------------------

proc hoverPath*(vm: MenuVM; path: seq[int]) =
  ## The pointer is over the item at `path`: a folder opens (its first item
  ## highlighted), an item is highlighted. Not a keyboard highlight.
  if not vm.isOpen or path.len == 0:
    return
  let it = vm.itemAt(path)
  if it.hidden:
    return
  let before = (vm.path, vm.highlight, vm.keyNavigation)
  if it.kind == mikFolder and it.enabled:
    vm.path = path
    vm.highlight = firstSelectable(it.children)
  else:
    vm.path = path[0 ..< path.len - 1]
    vm.highlight = path[^1]
  vm.keyNavigation = false
  if (vm.path, vm.highlight, vm.keyNavigation) != before:
    vm.changed()

proc clickPath*(vm: MenuVM; path: seq[int]): MenuActivation =
  ## A click on the item at `path`: an action runs (and the menu closes), a
  ## folder opens.
  if path.len == 0:
    return
  if not vm.isOpen:
    vm.isOpen = true
  let it = vm.itemAt(path)
  if it.hidden:
    return
  if it.kind == mikFolder:
    vm.hoverPath(path)
    return
  if not it.enabled or it.action.len == 0:
    return
  result = MenuActivation(ran: true, action: it.action, path: path)
  vm.close()

# ---------------------------------------------------------------------------
# The menu's own search
# ---------------------------------------------------------------------------

proc setSearch*(vm: MenuVM; query: string) =
  ## Filter every enabled action item whose label contains `query`
  ## (case-insensitive), in tree order.
  vm.searchQuery = query
  vm.searchResults = @[]
  vm.searchLabels = @[]
  vm.searchIndex = 0
  let q = query.strip.toLowerAscii
  if q.len > 0:
    for (p, it) in vm.root.actionItems():
      if not it.hidden and it.enabled and it.label.toLowerAscii.contains(q):
        vm.searchResults.add MenuActivation(ran: true, action: it.action,
                                            path: p)
        vm.searchLabels.add it.label
  vm.changed()

proc moveSearch*(vm: MenuVM; delta: int) =
  if vm.searchResults.len == 0:
    return
  vm.searchIndex = max(0, min(vm.searchResults.high, vm.searchIndex + delta))
  vm.keyNavigation = true
  vm.changed()

# ---------------------------------------------------------------------------
# A value describing what to draw, for assertions and for simple renderers
# ---------------------------------------------------------------------------

type
  MenuLevelView* = object
    ## One open level, as a renderer draws it: which folder it is, its
    ## visible items, and which of them is highlighted / on the open path.
    folderPath*: seq[int]
    items*: seq[tuple[index: int, label, shortcut: string, folder,
                      enabled, active, separatorAfter: bool]]

proc openLevels*(vm: MenuVM): seq[MenuLevelView] =
  ## The levels an open menu shows, outermost first: the top level, then one
  ## per entered folder.
  if not vm.isOpen:
    return @[]
  for depth in 0 .. vm.path.len:
    let fp = vm.path[0 ..< depth]
    let f = vm.folderAt(fp)
    var lv = MenuLevelView(folderPath: fp)
    for i in f.visibleChildren():
      let c = f.children[i]
      lv.items.add (index: i, label: c.label,
                    shortcut: (if c.kind == mikAction: vm.shortcutFor(c.action)
                               else: ""),
                    folder: c.kind == mikFolder, enabled: c.enabled,
                    active: vm.isOnPath(fp & @[i]),
                    separatorAfter: c.separatorAfter)
    result.add lv
