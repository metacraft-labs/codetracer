## test_editor_mark_agreement.nim — the terminal and the GPUI window draw the
## same gutter mark on every line, from one set of points.
##
## A line can carry an armed line breakpoint, a disabled one and a tracepoint
## in any combination, and the glyph column has room for one mark. Which one
## wins is a rule, and the two front-ends used to spell it twice: the
## terminal's `source_binding.marksForFile` emitted tracepoints and then
## breakpoints of either kind and let `source_pane.markFor` take the last,
## while the GPUI editor asks `editor_rows.markFor`, which ranks an armed
## breakpoint, then a tracepoint, then a disabled breakpoint. On a line with a
## tracepoint and a disabled breakpoint the terminal drew `○` and the window
## `◆`, and nothing compared them (PLAT-22's residue 10).
##
## This suite drives ONE set of points — all eight combinations, one per line
## — through both media and reads what each one DREW:
##
##   * the terminal: the painted source pane (`sourcePaneText`), the glyph in
##     the line's mark cell, mapped back through `gutter.markGlyph`;
##   * GPUI: `leaves.renderEditor` on the real isonim-gpui shim, the mark the
##     rendered row carries (`data-ct-mark`), read back across the FFI.
##
## Each is compared with a TABLE written here rather than with `markFor`, so
## a change to the shared ranking moves both media and still fails (a
## comparison of two answers computed by one function cannot fail —
## Verification-Harness-Traps §22). The two are then compared with each other,
## which is the agreement the residue asked for.
##
## ## NO MOCKS
##
## None. The terminal pane is isonim-tui's painter over a real
## `SourcePaneModel`; the GPUI tree is the shim's element store. No recording
## is needed: the subject is how points become a mark, and the points are the
## input.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)

import std/[strutils, tables, unicode, unittest]

import isonim_gpui/renderer as gpui_renderer
import isonim_gpui/bindings as gpui_bindings

import ../app/source_binding
import ../app/views/gutter
import ../../view_vocabulary/editor_surface
import ../../view_vocabulary/pane_views
import gpui/app/leaves

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Path = "/project/combo.py"
  Width = 60
  Height = 14

type Combo = object
  armed, disabled, trace: bool
  want: GutterMark      ## the ranking's answer, written out by hand

const Combos = [
  Combo(want: gmNone),
  Combo(armed: true, want: gmBreakpoint),
  Combo(disabled: true, want: gmBreakpointDisabled),
  Combo(trace: true, want: gmTracepoint),
  Combo(armed: true, disabled: true, want: gmBreakpoint),
  Combo(armed: true, trace: true, want: gmBreakpointTracepoint),
  # THE LINE THE TWO FRONT-ENDS DISAGREED ON: a tracepoint records and a
  # disabled breakpoint does nothing, so the tracepoint is the mark.
  Combo(disabled: true, trace: true, want: gmTracepoint),
  Combo(armed: true, disabled: true, trace: true,
        want: gmBreakpointTracepoint)]

proc lineText(line: int): string = "combo_line_" & $line & " = " & $line

proc points(): seq[SourcePoint] =
  for i, c in Combos:
    let line = i + 1
    if c.armed:
      result.add SourcePoint(path: Path, line: line, kind: sptBreakpoint,
                             enabled: true)
    if c.disabled:
      result.add SourcePoint(path: Path, line: line, kind: sptBreakpoint,
                             enabled: false)
    if c.trace:
      result.add SourcePoint(path: Path, line: line, kind: sptTracepoint,
                             enabled: true)
  # Another file's point must not reach this one.
  result.add SourcePoint(path: "/project/other.py", line: 1,
                         kind: sptBreakpoint, enabled: true)

proc documentText(): string =
  for i in 1 .. Combos.len:
    if i > 1: result.add '\n'
    result.add lineText(i)

proc terminalMarks(): Table[int, GutterMark] =
  ## What the terminal PAINTED in each line's mark cell.
  var held: seq[string] = @[]
  for i in 1 .. Combos.len: held.add lineText(i)
  let model = initSourcePaneModel(path = Path, heldLines = held,
                                  totalLineCount = Combos.len,
                                  marks = marksForFile(points(), Path))
  for row in sourcePaneText(model, Width, Height):
    for line in 1 .. Combos.len:
      if row.contains(lineText(line)):
        let glyph = $row.runeAt(0)
        for m in GutterMark:
          if markGlyph(m) == glyph:
            result[line] = m

proc gpuiMarks(): Table[int, string] =
  ## What the GPUI editor RENDERED on each line, read off the shim.
  gpui_reset_tree()
  resetCallbacks()
  let surface = editorSurfaceForProject(Path, documentText(), GpuiMedium,
    mutableHere = false, points = editorPointsOf(points()))
  var r: GpuiRenderer
  let parent = r.createElement("div")
  discard renderEditor(r, parent, sourcePaneView(GpuiMedium).root, surface)
  var stack = @[parent]
  while stack.len > 0:
    let n = stack.pop()
    if n.isNil: continue
    let line = getAttribute(n, EditorRowAttribute)
    if line.len > 0:
      result[parseInt(line)] = getAttribute(n, EditorMarkAttribute)
    for i in 0 ..< childCount(n):
      let c = nthChild(n, i)
      if not c.isNil: stack.add c

func sharedName(m: GutterMark): string =
  ## The GPUI row's spelling of the terminal's mark — the enum names differ
  ## only in their prefix, and this table says so rather than deriving it.
  case m
  of gmNone: "emNone"
  of gmBreakpoint: "emBreakpoint"
  of gmBreakpointDisabled: "emBreakpointDisabled"
  of gmTracepoint: "emTracepoint"
  of gmBreakpointTracepoint: "emBreakpointTracepoint"

suite "one set of points, one mark per line, on both front-ends":

  test "the terminal draws the ranking's mark on every line":
    let drawn = terminalMarks()
    # THE POSITIVE CONTROL: every line was found on the painted pane.
    ck drawn.len == Combos.len
    for i, c in Combos:
      ck drawn.getOrDefault(i + 1, gmNone) == c.want
    # The line the two disagreed on, by name.
    ck drawn.getOrDefault(7, gmNone) == gmTracepoint

  test "the GPUI window draws the ranking's mark on every line":
    let drawn = gpuiMarks()
    ck drawn.len >= Combos.len
    for i, c in Combos:
      ck drawn.getOrDefault(i + 1, "<no row>") == sharedName(c.want)
    ck drawn.getOrDefault(7, "<no row>") == "emTracepoint"

  test "the two front-ends agree on every line, including the one they disagreed on":
    let term = terminalMarks()
    let gpui = gpuiMarks()
    var agreed = 0
    for line in 1 .. Combos.len:
      ck line in term and line in gpui
      if line in term and line in gpui and
         sharedName(term[line]) == gpui[line]:
        inc agreed
    ck agreed == Combos.len
    # And the binding emits ONE mark per line, so the pane's last-wins read
    # has nothing left to decide.
    let marks = marksForFile(points(), Path)
    var seen: seq[int] = @[]
    for (line, _) in marks:
      ck line notin seen
      seen.add line
    ck marks.len == Combos.len - 1     # line 1 carries no point

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 37

suite "the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
