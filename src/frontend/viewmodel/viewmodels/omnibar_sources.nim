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
##   * SYMBOLS: every distinct function of the call-trace section the store
##     holds (`store.calltrace.lines`), located at its call's file and line;
##   * COMMANDS: every enabled action item of the menu, labelled by its menu
##     path, with the chord the active keymap binds — choosing one runs the
##     menu item, so the omnibar and the menu are two ways into one command
##     set, as the desktop's palette is fed from its menu tree.

import std/[sets, strutils]

import isonim/core/signals

import ../store/[replay_data_store, types]
import ./[filesystem_vm, menu_vm, omnibar_vm]
from ./event_log_vm import EventLogColumn, eventLogColumnTitle,
  parseEventLogColumn

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
  if store.isNil:
    return
  var seen = initHashSet[string]()
  for line in store.calltrace.lines.val:
    let name = if line.displayName.len > 0: line.displayName else: line.name
    if name.len == 0 or name in seen:
      continue
    seen.incl name
    let where =
      if line.location.file.len > 0:
        line.location.file & ":" & $line.location.line
      else: ""
    # CHOOSING A SYMBOL GOES TO ITS CALL: the target is the call's tick, so
    # every front-end navigates the same way (in time, to the first call the
    # held section shows), whatever each can do with a file location.
    result.add OmnibarEntry(kind: omSymbol, label: name,
                            detail: where.split('/')[^1],
                            target: $line.rrTicks)

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

proc omnibarIndexOf*(fs: FilesystemVM; store: ReplayDataStore;
                     menu: MenuVM): seq[OmnibarEntry] =
  ## The whole index, in a fixed order (files, symbols, commands — the
  ## menu's, then the event log's column commands).
  result = filesOf(fs)
  result.add symbolsOf(store)
  result.add commandsOf(menu)
  result.add eventLogColumnCommands()
