## test_gpui_gutter_mark_name.nim — the GPUI layout answer's name for a
## gutter row, graded against the Electron extractor's published mapping.
##
## `gutterMarkName` is the GPUI half of "two readings of one alphabet"; the
## Electron half is `src/tests/gui/tools/layout-answers.ts`, which names a
## glyph-margin class set `breakpoint`, `breakpoint-disabled` and/or
## `tracepoint`, in that order. A line carrying BOTH an armed breakpoint and a
## tracepoint has the one combined mark (Editor-Pane.md MC.5) and the Electron
## extractor answers it `breakpoint+tracepoint`; this suite pins that GPUI
## answers the same, and walks EVERY `EditorMark` so a mark kind added later
## cannot fall through to "no name" without this suite saying so.
##
## No mocks: the real naming function over the real `EditorMark` enum, and the
## real extractor source read from disk.
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_gpui_gutter_mark_name.nim

import std/[os, strutils, unittest]

import ../../../common/view_vocabulary
import ../../view_vocabulary/gpui_layout_answers

const
  ## What the Electron extractor answers for each mark with no pointer and
  ## verified provenance. Written out per mark, not derived from the producer.
  ElectronName = [
    emNone: "",
    emBreakpoint: "breakpoint",
    emBreakpointDisabled: "breakpoint-disabled",
    emTracepoint: "tracepoint",
    emBreakpointTracepoint: "breakpoint+tracepoint"]

suite "gutterMarkName names every mark the way the Electron extractor does":
  test "every EditorMark has the Electron extractor's name":
    for m in EditorMark:
      check gutterMarkName($m, "", "") == ElectronName[m]

  test "a line with both points names both, in the Electron order":
    check gutterMarkName("emBreakpointTracepoint", "", "") ==
      "breakpoint+tracepoint"

  test "the combined mark composes with a pointer and provenance":
    check gutterMarkName("emBreakpointTracepoint", "eptExecution",
                         "epUnverified") ==
      "execution+breakpoint+tracepoint+unverified"

  test "an absent mark attribute names no mark":
    check gutterMarkName("", "", "") == ""
    check gutterMarkName("", "eptInspection", "") == "inspection"

  test "a mark name outside the alphabet is refused, not silently dropped":
    expect ValueError:
      discard gutterMarkName("emNotAMark", "", "")

  test "the Electron extractor still maps the combined glyph class to both names":
    let src = readFile(currentSourcePath().parentDir / ".." / ".." / ".." /
                       "tests" / "gui" / "tools" / "layout-answers.ts")
    check src.contains("gutter-glyph-breakpoint-tracepoint")
    check src.contains("""names.push("breakpoint")""")
    check src.contains("""names.push("tracepoint")""")
