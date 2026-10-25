## viewmodels/omnibar_sources.nim — PLAT-48 deliverable 2. WHAT THE OMNIBAR
## CAN FIND, gathered one way for every native front-end.
##
## `OmnibarVM` ranks an index; this module builds that index from the
## session's own ViewModels, so the terminal and the GPUI window — which
## both call `omnibarIndexOf` — search the same things for the same
## recording and show the same list for the same query:
##
##   * FILES: every file of the recording's source tree, as the Files pane
##     lists it (`FilesystemVM.rootEntry`, the desktop's replay Files pane);
##   * SYMBOLS: every function the recording called (`store.symbols`, the
##     engine's `ct/load-symbols`), located where it is defined;
##   * COMMANDS: every enabled action item of the menu, labelled by its menu
##     path, with the chord the active keymap binds — choosing one runs the
##     menu item, so the omnibar and the menu are two ways into one command
##     set, as the desktop's palette is fed from its menu tree.

import std/[sets, strutils]

import isonim/core/signals

import ../store/[replay_data_store, types]
import ./[filesystem_vm, layout_settings, menu_vm, omnibar_vm]
import ../keymap/keymap_selection

export layout_settings
from ./event_log_vm import EventLogColumn, eventLogColumnTitle,
  parseEventLogColumn
from ./table_overflow import ColumnStepCells

export omnibar_vm

proc filesOf*(fs: FilesystemVM): seq[OmnibarEntry] =
  if fs.isNil:
    return
  var seen = initHashSet[string]()
  proc walk(n: FilesystemEntryNode; acc: var seq[OmnibarEntry];
            seen: var HashSet[string]) =
    if not n.isFolder and n.path.len > 0 and n.path notin seen:
      seen.incl n.path
      acc.add OmnibarEntry(kind: omFile, label: n.path, detail: "",
                           target: n.path)
    for c in n.children:
      walk(c, acc, seen)
  walk(fs.rootEntry.val, result, seen)

proc symbolsOf*(store: ReplayDataStore): seq[OmnibarEntry] =
  ## Every function the recording called — the engine's list, not the
  ## call-trace section the store happens to hold, so a function outside the
  ## pane's window is found too.
  if store.isNil:
    return
  for sym in store.symbols.val:
    let where =
      if sym.path.len > 0: sym.path.split('/')[^1] & ":" & $sym.line
      else: ""
    # CHOOSING A SYMBOL GOES TO ITS FIRST CALL: the target is that call's
    # tick, so every front-end navigates the same way, in time.
    result.add OmnibarEntry(kind: omSymbol, label: sym.name, detail: where,
                            target: $sym.firstCallTicks)

proc commandsOf*(menu: MenuVM): seq[OmnibarEntry] =
  if menu.isNil:
    return
  for (p, it) in menu.root.actionItems():
    if it.hidden or not it.enabled or it.action.len == 0:
      continue
    var labels: seq[string] = @[]
    var node = menu.root
    for i in p[0 ..< p.len - 1]:
      node = node.children[i]
      labels.add node.label
    labels.add it.label
    result.add OmnibarEntry(kind: omCommand, label: labels.join(" › "),
                            detail: menu.shortcutFor(it.action),
                            target: it.action)

const EventLogColumnCommandPrefix* = "eventLogColumn:"
  ## PLAT-49 part B (finding 14): the target of an omnibar command over the
  ## event log's columns — `eventLogColumn:<toggle|left|right>:<column>`.

proc eventLogColumnCommands*(): seq[OmnibarEntry] =
  ## THE EVENT LOG'S COLUMN COMMANDS, for every front-end's omnibar: show or
  ## hide each column, move each one left or right — the show / hide /
  ## reorder capability (Event-Log-Pane.md's `[+ Columns]`) over
  ## `EventLogVM.columns`, reachable the same way in the terminal and GPUI.
  for col in EventLogColumn:
    let name = eventLogColumnTitle(col)
    result.add OmnibarEntry(kind: omCommand,
                            label: "Event Log › Show / hide column " & name,
                            target: EventLogColumnCommandPrefix & "toggle:" &
                                    name)
    result.add OmnibarEntry(kind: omCommand,
                            label: "Event Log › Move column " & name & " left",
                            target: EventLogColumnCommandPrefix & "left:" &
                                    name)
    result.add OmnibarEntry(kind: omCommand,
                            label: "Event Log › Move column " & name &
                                   " right",
                            target: EventLogColumnCommandPrefix & "right:" &
                                    name)

proc parseEventLogColumnCommand*(target: string):
    tuple[ok: bool, verb: string, column: EventLogColumn] =
  ## `eventLogColumn:<verb>:<column>` -> its parts; `ok` false for anything
  ## else.
  if not target.startsWith(EventLogColumnCommandPrefix):
    return (false, "", EventLogColumn.low)
  let rest = target[EventLogColumnCommandPrefix.len .. ^1].split(':', 1)
  if rest.len != 2 or rest[0] notin ["toggle", "left", "right"]:
    return (false, "", EventLogColumn.low)
  let (found, col) = parseEventLogColumn(rest[1])
  if not found:
    return (false, "", EventLogColumn.low)
  (true, rest[0], col)

const
  OperationCommandPrefix* = "operation:"
    ## PLAT-70 Part B: a palette entry that runs a catalogued OPERATION —
    ## `operation:list.show-detail`, `operation:table.resize-column(+2)` — so
    ## the palette reaches what no base binds a chord to (Input-Routing IR-2).
  ShowDetailLabel* = "Show Detail"
  WidenColumnLabel* = "Widen Column"
  NarrowColumnLabel* = "Narrow Column"
  ScrollLeftLabel* = "View: Scroll Left"
  ScrollRightLabel* = "View: Scroll Right"
    ## PLAT-70 Part I: `view.scroll-left` / `-right` from the palette — the
    ## focused output pane's view, or a table pane's while its columns
    ## scroll (Horizontal-Overflow.md §4.4, §5.5).
  ColumnWidthVerb* = "column-width"
    ## Horizontal-Overflow.md §5.2: `:column-width <title> <cells>`, beside
    ## the `:column-*` verbs.

proc tableCommands*(): seq[OmnibarEntry] =
  ## THE TABLE PANES' PALETTE ENTRIES (Horizontal-Overflow.md §5.2, §5.3):
  ## **Show Detail** (`list.show-detail`) and **Widen Column** /
  ## **Narrow Column** (`table.resize-column`) for the focused column.
  result.add OmnibarEntry(kind: omCommand, label: ShowDetailLabel,
                          target: OperationCommandPrefix & "list.show-detail")
  result.add OmnibarEntry(kind: omCommand, label: WidenColumnLabel,
                          target: OperationCommandPrefix &
                                  "table.resize-column(+" & $ColumnStepCells &
                                  ")")
  result.add OmnibarEntry(kind: omCommand, label: NarrowColumnLabel,
                          target: OperationCommandPrefix &
                                  "table.resize-column(-" & $ColumnStepCells &
                                  ")")

proc viewScrollCommands*(): seq[OmnibarEntry] =
  ## PLAT-70 Part I: **View: Scroll Left** / **View: Scroll Right**
  ## (`view.scroll-left` / `-right`) — what `z h` / `z l` (and the output
  ## panes' arrows) do, reachable where no chord is bound.
  result.add OmnibarEntry(kind: omCommand, label: ScrollLeftLabel,
                          target: OperationCommandPrefix & "view.scroll-left")
  result.add OmnibarEntry(kind: omCommand, label: ScrollRightLabel,
                          target: OperationCommandPrefix & "view.scroll-right")

const
  FindCancelLabel* = "Find: Cancel and Return"
    ## PLAT-70 Part C (Find-And-Incremental-Search.md §3.5): CUA has no
    ## restoring exit — `Escape` keeps the match (the user's OQ-F1) — so
    ## `find.cancel` is reached under CUA from the palette (IR-2).

proc findCommands*(): seq[OmnibarEntry] =
  ## THE FIND SESSION'S PALETTE ENTRY: **Find: Cancel and Return**
  ## (`find.cancel`) — the selection and both scroll offsets as they were
  ## when the find opened.
  result.add OmnibarEntry(kind: omCommand, label: FindCancelLabel,
                          target: OperationCommandPrefix & "find.cancel")

proc parseOperationCommand*(target: string): tuple[ok: bool; operation: string] =
  ## `operation:<name>[(<arg>)]` -> the operation text; `ok` false otherwise.
  if not target.startsWith(OperationCommandPrefix):
    return (false, "")
  (true, target[OperationCommandPrefix.len .. ^1])

proc parseColumnWidthLine*(words: openArray[string]):
    tuple[ok: bool; column: EventLogColumn; cells: int; message: string] =
  ## `column-width <title> <cells>` (the verb first) -> its parts, or why not.
  if words.len != 3 or words[0] != ColumnWidthVerb:
    return (false, EventLogColumn.low, 0,
            "usage: :" & ColumnWidthVerb & " <column> <cells>")
  let (found, col) = parseEventLogColumn(words[1])
  if not found:
    return (false, EventLogColumn.low, 0, "no event log column `" & words[1] & "`")
  var cells = 0
  try:
    cells = parseInt(words[2])
  except ValueError:
    return (false, col, 0, "`" & words[2] & "` is not a number of cells")
  (true, col, cells, "")

proc layoutSettingCommands*(terminalSettings = true): seq[OmnibarEntry]
proc baseKeymapCommands*(): seq[OmnibarEntry]
  ## Forward-declared; defined at the end of this module.

proc omnibarIndexOf*(fs: FilesystemVM; store: ReplayDataStore;
                     menu: MenuVM;
                     terminalSettings = true): seq[OmnibarEntry] =
  ## The whole index, in a fixed order (files, symbols, commands — the
  ## menu's, then the event log's column commands).
  result = filesOf(fs)
  result.add symbolsOf(store)
  result.add commandsOf(menu)
  result.add eventLogColumnCommands()
  result.add tableCommands()
  result.add viewScrollCommands()
  result.add findCommands()
  result.add layoutSettingCommands(terminalSettings)
  result.add baseKeymapCommands()

proc baseKeymapCommands*(): seq[OmnibarEntry] =
  ## PLAT-68: **Preferences: Select Base Keymap**, one entry per base, on every
  ## front-end's palette — `:keymap <name>` without the prompt.
  for m in BaseKeymap:
    result.add OmnibarEntry(kind: OmnibarMode.omCommand,
                            label: SelectBaseKeymapLabel & " › " & $m,
                            detail: ":keymap " & $m,
                            target: baseKeymapCommandTarget(m))

proc layoutSettingCommands*(terminalSettings = true): seq[OmnibarEntry] =
  ## PLAT-51: the layout preferences as omnibox commands, on and off —
  ## `:set focus-highlight …` and `:set live-resize …` without the prompt, on
  ## both native front-ends (`layout_settings`).
  ## PLAT-70 Part H: a setting that takes a value (`scrollbar-thickness`)
  ## has one entry per value, as the base keymaps have.
  ## PLAT-71: the terminal's own settings (`isTerminalSetting`) only where
  ## `terminalSettings` — the window front-end draws with real fonts.
  for which in LayoutSetting:
    if which.isTerminalSetting and not terminalSettings:
      continue
    for value in settingValues(which):
      result.add OmnibarEntry(kind: OmnibarMode.omCommand,
                              label: settingCommandLabel(which, value),
                              detail: ":set " & describe(which, value),
                              target: settingCommandTarget(which, value))
  # PLAT-70 (Horizontal-Overflow.md §4.6): the markers' toggle, by the
  # specification's name.
  result.add OmnibarEntry(kind: OmnibarMode.omCommand,
                          label: ToggleOverflowMarkersLabel,
                          detail: ":set " & $lsOverflowMarkers & " on|off",
                          target: settingToggleTarget(lsOverflowMarkers))
