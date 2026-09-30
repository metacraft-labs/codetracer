## LAYER RULE — `src/frontend/tui/testing/` is TEST-ONLY infrastructure (see
## `dual_snap.nim`); nothing here is reachable from `main.nim`.
##
## testing/strip_read.nim — PLAT-48. Reading an auto-hide STRIP back off a real
## terminal, absolutely.
##
## Until PLAT-48 a horizontal dock strip was a row of `binding.DockStripGlyph`
## (`·`) with the docked panes' titles written over its first cells, and the
## real-PTY layout suites asserted exactly that. Since PLAT-48 the shell paints
## a strip as the desktop's footer does: each docked pane's LABEL, padded by one
## cell each side, in strip order, on a blank strip (`shell.paintDockStrips`).
## The shared default docks the desktop's four footer panels at the bottom, so a
## bottom strip is there before any gesture and a docked pane's label follows
## them.
##
## `stripLabelProblems` is the absolute reading those suites assert: every
## label, in order, as ` <title> `, and nothing else on the row but blanks. It
## is a proc that RETURNS its findings and calls `check` nowhere
## (Verification-Harness-Traps §13): the caller asserts the list is empty and
## checkpoints the first entries.

import std/[strutils, unicode]

import headless_app/layout_model

proc footerTitles*(): seq[string] =
  ## The shared default's docked footer panels' titles, in strip order — what
  ## every bottom strip carries first.
  for d in sharedDefaultDocked():
    result.add d.title

proc stripLabelProblems*(row: string; labels: openArray[string]): seq[string] =
  ## What is wrong with `row` as a strip carrying exactly `labels`, in order.
  ## Empty when every label is found as ` <label> ` after the previous one and
  ## every other cell is blank.
  var rest = row
  var at = 0
  for label in labels:
    let padded = " " & label & " "
    let found = rest.find(padded, at)
    if found < 0:
      result.add "label '" & label & "' not found (in order) on '" &
                 row.strip & "'"
      continue
    # Blank the label so only the strip's filler remains to be checked.
    rest = rest[0 ..< found] & spaces(padded.len) & rest[found + padded.len .. ^1]
    at = found + padded.len
  var col = 0
  for r in rest.runes:
    if r != Rune(' '):
      result.add "cell " & $col & " is '" & $r & "', not the strip's blank"
    inc col
