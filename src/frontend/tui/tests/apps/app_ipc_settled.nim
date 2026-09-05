## app_ipc_settled.nim — CTUI-2 snapshot app for the IPC settled-frame suite.
##
## Small on purpose. `test_ipc_settled_frame.nim` is about WHO DECIDES a frame
## is final and about how the arm fails when nobody does; a large screen would
## add compile time and cellmap bulk to a question neither depends on.
##
## The same binary serves both arms of that suite:
##
##   `--test-ipc`                 connect, paint, and answer the capture
##                                request with `requestScreenshot(label)`.
##   `--test-ipc --never-settle`  connect, paint, and DECLINE — the negative
##                                arm, which must fail as "label never
##                                arrived" rather than as a bare timeout.
##
## Both are the runtime's flags, not this file's: see
## `testing/test_app_runtime.nim`.

import std/strutils

import isonim_tui

const SettledMarker* = "reactive graph settled"

proc rowNode(r: TerminalRenderer; text: string): TerminalNode =
  result = r.createElement("div")
  r.appendChild(result, r.createTextNode(text))

proc buildTree*(r: TerminalRenderer): TerminalNode =
  let root = r.createElement("div")
  r.appendChild(root, rowNode(r, "┌── ipc settled frame ──┐"))
  r.appendChild(root, rowNode(r, "│ " & SettledMarker & " │"))
  for i in 0 ..< 6:
    r.appendChild(root, rowNode(r, "│ pane " & align($i, 2, '0') & " " &
                                   "─".repeat(12) & " │"))
  let accent = r.createElement("div")
  r.setStyle(accent, "color", "bright_green")
  r.setStyle(accent, "bold", "true")
  r.appendChild(accent, r.createTextNode("│ 世界 accented row     │"))
  r.appendChild(root, accent)
  r.appendChild(root, rowNode(r, "└───────────────────────┘"))
  root

when isMainModule:
  # Imported HERE rather than at the top so a test that merely imports this
  # module for its `buildTree` does not carry an unused `std/os` and an
  # unused runtime with it — ten `UnusedImport` warnings across five apps,
  # in a lane whose output is read for the ones that matter.
  import std/os
  import ../../testing/test_app_runtime
  quit(snapshotAppMain(buildTree, commandLineParams()))
