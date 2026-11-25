## host/table_column_widths.nim — PLAT-70 Part B: THE TABLE PANES' COLUMN
## WIDTHS, REMEMBERED (Horizontal-Overflow.md §5.2).
##
## One document for every front-end, `table-columns` in the native state root
## (`native_state.nim`), beside the layout and the preferences: a width
## dragged in the terminal is the width the GPUI window opens with, and the
## desktop's Electron main process reads and writes the same file
## (`index/table_columns.nim`), so it is the width there too (HO-9). The text
## is `table_overflow.encodeColumnWidths`'s, written staged.
##
## An absent file is no widths (each front-end's defaults); an unreadable or
## malformed one is refused by name and the defaults are used.
##
## Native only (it touches files), like every module in this directory.

import std/os

import ../viewmodels/[table_overflow, event_log_vm]
import ./native_state

type
  ColumnWidthsLoad* = object
    entries*: seq[ColumnWidthEntry]
    path*: string
    message*: string
      ## Why the stored widths were not used; "" when they were (or there
      ## were none).

proc tableColumnsPath*(): string =
  nativeStateRoot() / TableColumnsFileName

proc loadColumnWidths*(): ColumnWidthsLoad =
  let path = tableColumnsPath()
  result.path = path
  if not fileExists(path):
    return
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    result.message = "the stored column widths could not be read: " & path &
                     ": " & e.msg
    return
  let decoded = decodeColumnWidths(text)
  if decoded.ok:
    result.entries = decoded.entries
  else:
    result.message = "the stored column widths were ignored: " &
                     decoded.message & " (in " & path & ")"

proc saveColumnWidths*(table: string;
                       entries: openArray[ColumnWidthEntry]): string =
  ## Remember `table`'s widths; other tables' stored widths are kept. "" on
  ## success, else why they could not be saved.
  let merged = mergeColumnWidths(loadColumnWidths().entries, table, entries)
  let failure = writeStaged(tableColumnsPath(), encodeColumnWidths(merged))
  if failure.len == 0: ""
  else: "the column widths could not be saved: " & failure

proc eventLogColumnsPath*(): string =
  nativeStateRoot() / EventLogColumnsFileName

type
  EventLogColumnsLoad* = object
    ok*: bool
      ## True when a valid file was found and decoded; false uses defaults.
    c*: EventLogColumns
    path*: string
    message*: string

proc loadEventLogColumns*(): EventLogColumnsLoad =
  ## Read the persisted event log column layout (order + hidden). An absent
  ## file is the defaults; a malformed file is refused by name.
  let path = eventLogColumnsPath()
  result = EventLogColumnsLoad(ok: false, c: defaultEventLogColumns(), path: path)
  if not fileExists(path):
    return
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    result.message = "the stored event-log column layout could not be read: " &
                     path & ": " & e.msg
    return
  let decoded = decodeEventLogColumns(text)
  if decoded.ok:
    result.ok = true
    result.c = decoded.c
  else:
    result.message = "the stored event-log column layout was ignored: " &
                     decoded.message & " (in " & path & ")"

proc saveEventLogColumns*(c: EventLogColumns): string =
  ## Persist the event log column layout. "" on success, else the reason.
  let path = eventLogColumnsPath()
  let failure = writeStaged(path, encodeEventLogColumns(c))
  if failure.len == 0: ""
  else: "the event-log column layout could not be saved: " & failure
