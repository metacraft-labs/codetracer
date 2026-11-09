## app_stamp_probe.nim — the child `tests/real_terminal/test_dual_snap_child_stamp
## .nim` builds to ask one question of `dual_snap.compileChildApp`: which
## `isonim-tui` renderer did the binary it handed back actually link?
##
## It prints the bytes of one `isonim_tui/text/ansi` encoder and exits. The
## suite edits that encoder in a private copy of the `isonim-tui` tree, so a
## binary that still prints the unedited bytes is a stale child reused after a
## renderer edit — the false red (and the possible false green) the suite
## exists to rule out. It deliberately imports the SGR module alone rather than
## `isonim_tui` as a whole: the question is about the stamp, not the renderer,
## and three links of the whole library would cost the lane minutes to ask it.

import std/strutils

import isonim_tui/text/ansi

when isMainModule:
  echo "CURSOR-HIDE " & cursorHide().escape
