## table_columns.nim — PLAT-70 Part B: the desktop's half of the ONE remembered
## document of the table panes' column widths (Horizontal-Overflow.md §5.2,
## HO-9), in Electron's main process.
##
## The terminal and GPUI read and write `table-columns` in their native state
## root themselves (`viewmodel/host/table_column_widths`). The desktop's
## renderer cannot touch the filesystem, so the main process does it here,
## at the SAME path — `$CODETRACER_TUI_LAYOUT_DIR` when set, else
## `common/ct_home.ctStateDir` (the rule `viewmodel/host/native_state`
## spells, pinned equal by `src/common/ct_home_isolation_test.nim`) — and in
## the same text (`table_overflow.encodeColumnWidths`):
##
##   * `CODETRACER::table-columns-request`: the renderer asks for the
##     document when its Event Log is set up; the answer is
##     `CODETRACER::table-columns` with the text;
##   * `CODETRACER::table-columns-save`: the renderer's widths for one table,
##     merged over the document's other tables and written (to a `.new`
##     file, renamed over the old one), so a width dragged on the desktop is
##     the width the terminal and GPUI open with.

import
  std / [async, jsffi, os],
  electron_vars,
  ../lib / [jslib, electron_lib],
  ../viewmodel/viewmodels/table_overflow,
  ../../common / [ct_home, ct_logging]

const
  TableColumnsMessage* = "CODETRACER::table-columns"
  NativeStateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"

proc renameSyncJs(oldPath, newPath: cstring)
  {.importjs: "require('fs').renameSync(#, #)".}

proc tableColumnsPath*(): string =
  let override = getEnv(NativeStateDirEnvVar)
  (if override.len > 0: override else: ctStateDir()) / TableColumnsFileName

proc readColumnsText(): string =
  let path = tableColumnsPath()
  if not fs.existsSync(cstring(path)):
    return ""
  try:
    $fs.readFileSync(cstring(path), cstring"utf8")
  except CatchableError:
    ""

proc onTableColumnsRequest*(sender: js, response: js) {.async.} =
  if mainWindow.isNil:
    return
  mainWindow.webContents.send(cstring(TableColumnsMessage), js{
    path: cstring(tableColumnsPath()), text: cstring(readColumnsText())})

proc onTableColumnsSave*(sender: js, response: js) {.async.} =
  ## One table's widths (`table`, and `text` in the document's own form),
  ## merged over the other tables' and written staged.
  let table = $cast[cstring](response[cstring"table"])
  let mine = decodeColumnWidths($cast[cstring](response[cstring"text"]))
  let stored = decodeColumnWidths(readColumnsText())
  let merged = mergeColumnWidths(
    (if stored.ok: stored.entries else: @[]), table,
    (if mine.ok: mine.entries else: @[]))
  let path = tableColumnsPath()
  try:
    fs.mkdirSync(cstring(path.parentDir), js{recursive: true})
    fs.writeFileSync(cstring(path & ".new"), cstring(encodeColumnWidths(merged)))
    renameSyncJs(cstring(path & ".new"), cstring(path))
  except CatchableError as e:
    warnPrint "table columns: cannot write ", path, ": ", e.msg
