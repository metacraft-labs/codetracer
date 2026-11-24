## test_event_log_columns_json.nim
##
## The Event Log's columns as JSON (`columnsToJson` / `columnsFromJson`): the
## value a renderer whose Event Log is drawn by its WebAssembly core mirrors
## into that core, and the core sends back when its own pane changed them.
## What one ViewModel holds must be what the other reads back: the order,
## the hidden columns, the widths and the focused column.

import std/[json, unittest]

import viewmodels/event_log_vm

proc changed(): EventLogColumns =
  result = defaultEventLogColumns()
  result.order = @[elcOutput, elcKind, elcTick, elcIndex, elcLocation]
  result.hidden = {elcTick}
  result.widths[elcOutput] = 40
  result.widths[elcIndex] = 7
  result.focused = elcOutput

suite "the Event Log's columns as JSON":

  test "a changed set of columns reads back as itself":
    let columns = changed()
    check columnsFromJson(columnsToJson(columns), defaultEventLogColumns()) ==
      columns

  test "the defaults read back as themselves":
    let columns = defaultEventLogColumns()
    check columnsFromJson(columnsToJson(columns), changed()) == columns

  test "each column is named, not numbered":
    let node = columnsToJson(changed())
    check node["order"][0].getStr == $elcOutput
    check node["hidden"].len == 1
    check node["hidden"][0].getStr == $elcTick
    check node["widths"][$elcOutput].getInt == 40
    check node["focused"].getStr == $elcOutput

  test "an unknown name is skipped and every column is kept once":
    let node = %*{"order": ["output", "no-such-column", "output"],
                  "hidden": ["no-such-column"]}
    let columns = columnsFromJson(node, defaultEventLogColumns())
    check columns.order.len == ord(high(EventLogColumn)) + 1
    check columns.order[0] == elcOutput
    var seen: set[EventLogColumn] = {}
    for col in columns.order:
      check col notin seen
      seen.incl col
    check columns.hidden == {}

  test "anything but an object leaves the base as it was":
    let base = changed()
    check columnsFromJson(newJNull(), base) == base
    check columnsFromJson(%*[1, 2], base) == base
