## test_macro_expansion_native.nim — Editor-Hosted-Front-Ends §E15 on the
## terminal: **Toggle Macro Expansion shows the code a Nim macro call expanded
## to, beside the source, and a step inside the expansion is shown at its row
## there while the source stays on the call.**
##
## Over the `ct record` recording of `test-programs/nim_macro_steps/main.nim`
## (`fixtures/native_recording.nimMacroRecording`): `addTwice(counter, 3)` on
## line 17 expands to the compiler's `expanded.nim` lines 1–4, and a step from
## line 16 stops on `expanded.nim:3` (the expansion's first `counter += 3`).
##
##   * collapsed (no toggle), that stop is the CALL: `main.nim:17`, not
##     `expanded.nim` (the replay's `apply_macro_expansion_level`) — until
##     2026-11-17 the terminal opened the whole generated file there;
##   * Toggle Macro Expansion on line 17 places the Macro Expansion pane
##     beside the source, listing the expansion's lines under its heading;
##     toggled on line 16 it refuses ("No macro expansion at main.nim:16");
##   * expanded, the same step is inside the expansion: the pane's `▸` is on
##     row 3 and the source's position stays `main.nim:17`;
##   * toggled again (the heading's press), the expansion closes and the next
##     stop inside it is the call again.
##
## No mocks: a real recording, the real `replay-server` and `ct-native-replay`,
## the terminal's own runtime, host and painters. Without `ct`, `ct-mcr`,
## `nim` or `ct-native-replay` the cases skip, printing `MISSING-PREREQ SKIP:`
## with what is missing.

import std/[os, strutils, unittest]

import isonim/core/[signals]

import headless_session
import view_vocabulary/pane_views
import ../../../common/view_vocabulary
import viewmodels/macro_expansion_vm

import ../app/runtime
import codetracer_embed
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/macro_expansion_pane
import ../host/tui_session
import ./fixtures/native_recording
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as the suite's RUNTIME assertion count.
const ExpectedAssertions = 36

var countedAssertions = 0
var skipped = false

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 56
  BeforeCall = 16
    ## `var counter = 0`.
  MacroCall = 17
    ## `addTwice(counter, 3)`.
  ExpansionFirst = 1
  ExpansionLast = 4
    ## `addTwice`'s expansion in `expanded.nim`.
  FirstStatementRow = 3
    ## `counter += 3`, the expansion's row a step from line 16 reaches.

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc open(path: string): (TuiRuntime, TuiSession) =
  let rt = newRuntime()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  rt.app.toggleMacroExpansion = proc(path: string; line: int):
      tuple[ok, opened: bool; detail: string] =
    s.toggleMacroExpansion(rt, path, line)
  (rt, s)

proc stopAt(s: TuiSession; rt: TuiRuntime; source: string; line: int) =
  ## Continue to a breakpoint on `line` (cleared after), the panes following.
  s.session.setBreakpoint(source, line)
  s.session.continueForward()
  discard s.session.clearBreakpoints(source)
  s.refresh(rt)

proc stepIn(s: TuiSession; rt: TuiRuntime) =
  s.session.stepIn()
  s.refresh(rt)

proc toggleAt(s: TuiSession; rt: TuiRuntime; path: string;
              line: int): RuntimeOutcome =
  ## What a menu's entry or a hosted heading runs: the operation on a target.
  discard rt.runPaneOperation("editor.toggle-macro-expansion",
                              PaneOpArgs(path: path, line: line), result)
  s.applyOutcome(rt, result)

proc screenText(rt: TuiRuntime): string =
  rt.shellScreenOf().rows.join("\n")

proc lineRows(rt: TuiRuntime): seq[MacroExpansionPaneRow] =
  for r in rt.app.macroExpansion.rows:
    if r.kind == mpLine: result.add r

proc missing(rec: NativeRecording): string =
  MissingPrereqSkipPrefix & " " & NimMacroFixtureName & " — " & rec.detail

suite "Toggle Macro Expansion on the terminal, over a `ct record` Nim recording":

  let rec = nimMacroRecording()

  test "a step inside a collapsed call is the call's line":
    if not rec.ok:
      echo "  ", rec.missing
      skipped = true
      skip()
    else:
      let (rt, s) = open(rec.tracePath)
      defer: s.close()
      s.stopAt(rt, rec.sourcePath, BeforeCall)
      ck s.session.getCurrentLine() == BeforeCall
      s.stepIn(rt)
      checkpoint("stop: " & s.session.getCurrentFile() & ":" &
                 $s.session.getCurrentLine())
      # The control: the replay reported `…/nimcache/expanded.nim:3` here.
      ck s.session.getCurrentFile() == rec.sourcePath
      ck s.session.getCurrentLine() == MacroCall
      ck not s.session.session.store.stop.val.isExpanded
      ck rt.app.macroExpansion.rows.len == 0

  test "the toggle shows the expansion beside the source; a step lands in it":
    if not rec.ok:
      echo "  ", rec.missing
      skipped = true
      skip()
    else:
      let (rt, s) = open(rec.tracePath)
      defer: s.close()
      s.stopAt(rt, rec.sourcePath, BeforeCall)
      # A line that expands nothing is refused, and opens nothing.
      let refused = s.toggleAt(rt, rec.sourcePath, BeforeCall)
      checkpoint("line 16: " & refused.refused)
      ck refused.refused == "No macro expansion at main.nim:" & $BeforeCall
      ck not rt.app.layoutBinding.layout.tree.contains(paneMacroExpansion)
      # The call's line opens its expansion, in the pane beside the source.
      let focusBefore = rt.focus.focusedPane()
      let opened = s.toggleAt(rt, rec.sourcePath, MacroCall)
      ck opened.refused.len == 0
      ck rt.app.layoutBinding.layout.tree.contains(paneMacroExpansion)
      let vm = s.session.session.macroExpansionVM
      ck vm.isOpen(rec.sourcePath, MacroCall)
      ck vm.expansions.val.len == 1
      let e = vm.expansions.val[0]
      ck e.expandedPath.endsWith("nimcache/expanded.nim")
      ck (e.firstLine, e.lastLine) == (ExpansionFirst, ExpansionLast)
      ck rt.app.macroExpansion.rows[0].kind == mpHeading
      ck rt.app.macroExpansion.rows[0].text ==
           "main.nim:" & $MacroCall & " · expanded.nim " & $ExpansionFirst &
           "–" & $ExpansionLast
      let lines = rt.lineRows
      ck lines.len == ExpansionLast - ExpansionFirst + 1
      ck lines.len == 4 and lines[0].text.contains("addTwice expansion")
      ck lines.len == 4 and lines[2].text.strip == "counter += 3"
      let screen = rt.screenText
      checkpoint(screen)
      ck screen.contains("Macro Expansion")
      ck screen.contains("counter += 3")
      # The focus stayed where it was: the user steps from there.
      ck rt.focus.focusedPane() == focusBefore
      # Expanded, the step from line 16 is inside the expansion: its row is
      # the pane's execution row, and the source stays on the call.
      s.stepIn(rt)
      let stop = s.session.session.store.stop.val
      checkpoint("stop: " & stop.path & ":" & $stop.line & " expanded=" &
                 $stop.isExpanded)
      ck stop.isExpanded
      ck stop.path.endsWith("nimcache/expanded.nim")
      ck stop.line == FirstStatementRow
      ck s.session.getCurrentFile() == rec.sourcePath
      ck s.session.getCurrentLine() == MacroCall
      let at = rt.app.macroExpansion.executionRow
      ck at >= 0 and rt.app.macroExpansion.rows[at].number == FirstStatementRow
      var pointed = false
      for row in rt.shellScreenOf().rows:
        if row.contains("▸") and row.contains("counter += 3"): pointed = true
      ck pointed
      # GPUI's view of the same ViewModel marks the same row.
      let view = macroExpansionPaneView(vm)
      var marked: seq[string] = @[]
      for n in walk(view.root):
        if n.kind == pkTable:
          for row in n.rows:
            if row.len == 3 and row[0].len > 0: marked.add row[1]
      ck marked == @[$FirstStatementRow]

  test "toggled again, the expansion closes and its stops are the call's":
    if not rec.ok:
      echo "  ", rec.missing
      skipped = true
      skip()
    else:
      let (rt, s) = open(rec.tracePath)
      defer: s.close()
      s.stopAt(rt, rec.sourcePath, BeforeCall)
      discard s.toggleAt(rt, rec.sourcePath, MacroCall)
      ck rt.app.macroExpansion.rows.len > 0
      # The heading's press is the toggle on its call.
      let heading = rt.app.macroExpansion.rows[0]
      ck heading.kind == mpHeading and heading.callLine == MacroCall
      let closed = s.toggleAt(rt, heading.callPath, heading.callLine)
      ck closed.refused.len == 0
      ck rt.app.macroExpansion.rows.len == 0
      ck not s.session.session.macroExpansionVM.isOpen(rec.sourcePath, MacroCall)
      # The replay's level went back with it: the step is the call's line.
      s.stepIn(rt)
      ck not s.session.session.store.stop.val.isExpanded
      ck s.session.getCurrentLine() == MacroCall

suite "terminal macro expansion suite self-check":
  test "macro_expansion_native_assertion_count_is_measured":
    if skipped:
      skip()
    else:
      checkpoint("assertions: " & $countedAssertions)
      check countedAssertions == ExpectedAssertions
