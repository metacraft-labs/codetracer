## app_stamp_probe.nim — the child `tests/real_terminal/test_dual_snap_child_stamp
## .nim` builds to ask one question of `dual_snap.compileChildApp`: was the
## binary it handed back built from the sources it links NOW?
##
## It prints the bytes of one `isonim_tui/text/ansi` encoder and exits. The
## suite edits that encoder in a private copy of the `isonim-tui` tree, so a
## binary that still prints the unedited bytes is a stale child reused after a
## renderer edit — the false red (and the possible false green) the suite
## exists to rule out. It deliberately imports the SGR module alone rather than
## `isonim_tui` as a whole: the question is about the stamp, not the renderer,
## and three links of the whole library would cost the lane minutes to ask it.
##
## The two other imports, and the `staticRead`, are there to be TOUCHED, not
## for what they compute: an in-repo module outside the trees the stamp once
## listed by hand (`common/key_names`), a sibling library no hand-written list
## named (`nim-everywhere`), and a file embedded from ANOTHER directory, which
## the compiler does not report (the viewmodels embed `events.nim` this way).
## The suite moves their modification times and expects a rebuild.

import std/strutils

import isonim_tui/text/ansi
import nim_everywhere/platform
import ../../../../common/key_names

const EventsSource =
  staticRead("../../../../common/common_types/codetracer_features/events.nim")

when isMainModule:
  doAssert EventsSource.len > 0
  doAssert NamedKeys.len > 0
  doAssert not memoryFileSystem().exists("absent")
  echo "CURSOR-HIDE " & cursorHide().escape
