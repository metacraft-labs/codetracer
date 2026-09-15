## test_edit_mode_source.nim — PLAT-16, Tier 1.
##
## ## THE CORE QUESTION, AND THE ONE THE MILESTONE SAYS MUST BE ASSERTED ON THE
## ## TELLING
##
## Two subjects, and they are in one file because the second is a consequence of
## the first:
##
##   1. **Which source does a mode show** — CodeTracer-TUI-Edit-Mode.md §2.
##      Debug shows the recording's, Edit shows the working tree, the Source
##      pane says which ALWAYS, and the gutter in Edit mode is Debug's minus the
##      execution pointer.
##   2. **The stale trace** — §2.1 consequence 3, and PLAT-16's own words:
##      *"edit, toggle to Debug on an existing trace, and assert the user is
##      **told**. A test that only checks the toggle succeeds would pass while
##      the user is misled."*
##
## So the stale-trace case below asserts the SENTENCE, on the STATUS ROW OF THE
## PAINTED SCREEN, and it names the file the user edited. Asserting that
## `toggleProductMode` returned true would be exactly the test the milestone
## says would pass while the user is misled.
##
## ## THREE THINGS THE LANDING PASS ADDED, AND WHY EACH IS HERE
##
## The first version of this file asserted the notice against a session built
## by hand — `app.traceName = "demo.ct"` plus a hand-opened buffer — and that
## fixture was an instance of the defect it existed to catch
## (`Verification-Harness-Traps.md` §7). **No shipped route could reach that
## state**, so the sentence the milestone calls its deliverable could not be
## produced by the product at all. Three suites' worth of consequence:
##
##   1. **§6's route is asserted** ("the toggle out of a REPLAY session…"): a
##      runtime with a trace AND the host seam, furnished by the product's own
##      `ensureEditWorkspace` rather than by this file. Tier 2's
##      `test_real_edit_mode.nim` does the same through the shipped binary.
##   2. **The save is asserted on the NOTICE, not on `editedPaths`** ("a saved
##      edit is still an edit the recording predates"). The list was right at
##      every intermediate point and wrong only where a user reads it.
##   3. **The staleness predicate's negative half is FALSIFIED** ("a save that
##      restores the recorded bytes IS fresh again"), because
##      `outrunsRecording` is a disjunction and §7a says an unfalsified
##      negative control is a self-comparison wearing a negation.
##
## ## No mocks
##
## A `TextAreaWidget` from `isonim-tui`, the product's own runtime, its own
## compositor and its own status bar. The `EditServices` closures in the build
## case are the HOST — the same category as CTUI-10's `CommandServices` — and
## each records what it was asked, so the assertion is about what the runtime
## requested rather than about what a fake returned.
##
## ## Templates, not procs, for anything that calls `check`

import std/[strutils, unittest]

# `product_mode` — `ProductMode`, `sourceOriginFor`, the stale-trace verdict
# and `slugOfPreservedRow` — comes from the CORE through the sanctioned facade,
# which is the same door the modules under test use.
import codetracer_embed

import ../edit_binding
import ../runtime
import ../theme/capabilities
import ../views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 137

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 120
  Rows = 40
  Project = "demo"
  FileA = "src/alpha.nim"
  TextA = "proc alpha() =\n  echo 1\n  echo 2\n  echo 3\n"
  CtrlF5 = "\x1b[15;5~"
    ## xterm's Ctrl+F5. Written as bytes rather than as a name, so the toggle is
    ## driven through the same decoder a terminal would feed.

proc caps(): TerminalCapabilities =
  ## A FIXED environment, never `getEnv`: a suite that read the host's terminal
  ## would assert something different on every machine.
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc editingRuntime(traceName = ""; cols = Cols): TuiRuntime =
  ## A runtime in EDIT mode with one file open, and optionally a recording.
  let app = newTuiApp()
  app.projectRoot = Project
  app.modes = initModeRegister(pmEdit)
  app.editSession = newEditSession()
  app.traceName = traceName
  discard app.editSession.openFile(FileA, TextA)
  result = newTuiRuntime(app, caps(), cols, Rows)
  discard result.focus.focusPaneKind(paneEditor)

proc statusRow(rt: TuiRuntime): string =
  let screen = rt.shellScreenOf()
  strutils.strip(screen.rows[^1], leading = false)

proc pathOf(buf: EditBuffer): string =
  ## `buf.path`, NIL-SAFELY, and the reason is a mutation arm that was scored
  ## SURVIVED while killing its case outright.
  ##
  ## M32 makes `ensureEditWorkspace` do nothing, so `activeBuffer()` is nil. The
  ## case said `ck not buf.isNil` — which reports the failure correctly — and
  ## then `ck buf.path == FileA`, which **dereferences a nil ref and takes the
  ## process down**. `unittest` never printed the `[FAILED]` line, the harness
  ## saw no verdict for the named case, and scored it `SURVIVED`: trap §1a's
  ## shape, where a mutant that dies before its summary is indistinguishable
  ## from one nothing noticed.
  ##
  ## `ck` MUST NOT BE ABLE TO CRASH THE BINARY. Every other accessor this file
  ## uses (`text`, `isDirty`, `outrunsRecording`, `activeBuffer`) is already
  ## nil-safe by construction; `path` is a bare field on a `ref`, so it needs
  ## this. A guarded `if buf.isNil: … else: …` would have worked too and is
  ## worse: it changes the assertion COUNT, which §4c's counter then reports as
  ## a second failure nobody asked about.
  if buf.isNil: "" else: buf.path

proc editorRows(rt: TuiRuntime): seq[string] =
  ## The rows of the pane the `editor` rectangle occupies.
  let screen = rt.shellScreenOf()
  result = @[]
  for region in screen.projection.regions:
    if region.pane == paneEditor:
      for r in region.area.row ..< region.area.row + region.area.height:
        if r < screen.rows.len:
          result.add screen.rows[r][region.area.col ..<
            min(screen.rows[r].len, region.area.col + region.area.width)]

# ---------------------------------------------------------------------------

suite "PLAT-16 §2: which source a mode shows":

  test "the two modes read two origins, and the answer is the core's":
    # §2's table, as the core answers it. `SourceOrigin` is CTUI-4's own
    # vocabulary — reached through the facade — rather than a second enum.
    ck sourceOriginFor(pmDebug) == soTracePayload
    ck sourceOriginFor(pmEdit) == soWorkingTree
    ck sourceOriginFor(pmDebug) != sourceOriginFor(pmEdit)
    # …and the other three columns of that table.
    ck not isMutable(pmDebug)
    ck isMutable(pmEdit)
    ck usesSourceVM(pmDebug)
    ck not usesSourceVM(pmEdit)
    # §2.1 consequence 2: "A mode switch may change what the Source pane
    # displays, for the same path." True across the switch, false within it —
    # which is what stops the predicate from being a constant.
    ck displayedSourceMayDiffer(pmDebug, pmEdit)
    ck displayedSourceMayDiffer(pmEdit, pmDebug)
    ck not displayedSourceMayDiffer(pmDebug, pmDebug)
    ck not displayedSourceMayDiffer(pmEdit, pmEdit)

  test "the Source pane states which mode's source it shows, ALWAYS":
    # §2's Requirement: "The Source pane states which mode's source it is
    # showing, always — not only when they differ, because 'only when it
    # matters' requires the user to know when it matters."
    for mode in ProductMode:
      ck sourceStatementFor(mode).len > 0
    ck sourceStatementFor(pmDebug) != sourceStatementFor(pmEdit)
    ck sourceStatementFor(pmEdit).contains("working tree")
    ck sourceStatementFor(pmDebug).contains("recording")

    # AND IT REACHES THE SCREEN, through the binding rather than through a
    # model this file built: `editPaneModelFor` is what production calls.
    let session = newEditSession()
    discard session.openFile(FileA, TextA)
    let model = editPaneModelFor(session, session.activeBuffer())
    ck model.sourceStatement == sourceStatementFor(pmEdit)
    let title = titleRowText(model, Cols)
    checkpoint("title: " & title.strip())
    ck title.contains(sourceStatementFor(pmEdit))
    ck title.contains("alpha.nim")
    # …even for a session with no file open, which is the case "always" is
    # about: a pane that stated its source only once a file was loaded would
    # say nothing at the moment a user is most likely to be confused.
    let empty = editPaneModelFor(session, nil)
    ck empty.sourceStatement == sourceStatementFor(pmEdit)
    ck titleRowText(empty, Cols).contains(sourceStatementFor(pmEdit))

  test "the gutter is Debug's minus the execution pointer, and the code column does not move":
    # §3: "the gutter reused from Debug mode minus the execution pointer (there
    # is no execution). Breakpoint markers stay."
    let session = newEditSession()
    discard session.openFile(FileA, TextA)
    session.points = @[SourcePoint(path: FileA, line: 2,
                                   kind: sptBreakpoint, enabled: true)]
    let model = editPaneModelFor(session, session.activeBuffer())
    var g = newStyledGrid(Cols, Rows)
    let screen = paintEditPane(g, CellArea(col: 0, row: 0, width: 60,
                                           height: 10), model)
    var text = ""
    for row in 0 ..< 10:
      text.add g.rowText(row) & "\n"
    checkpoint(text)
    # FIVE, NOT FOUR, AND THE FIFTH IS REAL. `TextA` ends with a newline, so
    # the widget's `lines` is five entries with an empty last one — the same
    # count `wc -l` would disagree with and every editor on earth agrees with.
    # Asserted as the widget's own answer rather than as "the number of visible
    # `echo`s", because a pane that silently dropped a trailing empty line is a
    # pane a user cannot put their caret at the end of.
    ck screen.renderedLines == 5
    ck session.activeBuffer().lineCount == 5
    # NO EXECUTION POINTER ANYWHERE.
    ck not text.contains(ExecutionPointerGlyph)
    ck not text.contains(InspectionPointerGlyph)
    # THE BREAKPOINT STAYS.
    ck text.contains(BreakpointGlyph)

    # THE POSITIVE CONTROL, without which "no `-->` on screen" is satisfied by
    # a pane that draws nothing: the SAME text through the Debug pane with an
    # execution line DOES carry the pointer.
    var g2 = newStyledGrid(Cols, Rows)
    let debugModel = initSourcePaneModel(
      path = FileA, heldLines = @["proc alpha() =", "  echo 1", "  echo 2",
                                  "  echo 3"],
      firstHeldLine = 1, totalLineCount = 4, viewportTop = 1,
      executionLine = 2,
      marks = @[(2, gmBreakpoint)])
    let debugScreen = paintSourcePane(
      g2, CellArea(col: 0, row: 0, width: 60, height: 10), debugModel)
    var debugText = ""
    for row in 0 ..< 10:
      debugText.add g2.rowText(row) & "\n"
    ck debugText.contains(ExecutionPointerGlyph)
    ck debugText.contains(BreakpointGlyph)
    # AND THE CODE COLUMN IS AT THE SAME x IN BOTH, which is what the reserved
    # three-cell pointer field buys: a mode switch must not slide the text
    # sideways under the user's eyes.
    checkpoint("edit gutter " & $screen.gutterWidth & " debug gutter " &
               $debugScreen.gutterWidth)
    ck screen.gutterWidth == debugScreen.gutterWidth
    ck screen.codeWidth == debugScreen.codeWidth

  test "the editor rectangle is painted from the PRODUCT mode and nothing else":
    # `shell.paintPane` branches on `model.product`, not on "is there an edit
    # buffer". A branch on the data would paint the edit pane in Debug mode for
    # any session that had ever opened a file — the silent cross-mode leak §2.1
    # consequence 2 requires a user to be able to SEE.
    let rt = editingRuntime()
    let inEdit = editorRows(rt).join("\n")
    checkpoint("edit pane:\n" & inEdit)
    ck inEdit.contains(EditPaneTitle)
    ck inEdit.contains(sourceStatementFor(pmEdit))

    # THE SAME SESSION, TOGGLED. The edit buffer is still there and the pane is
    # not.
    ck rt.app.modes.toggle(rt.app.shellModel(Cols, Rows).layout, lpStandard)
    ck rt.app.modes.product == pmDebug
    ck not rt.app.editSession.activeBuffer().isNil
    let inDebug = editorRows(rt).join("\n")
    checkpoint("debug pane:\n" & inDebug)
    ck not inDebug.contains(EditPaneTitle)
    ck not inDebug.contains(sourceStatementFor(pmEdit))

suite "PLAT-16 §2.1: the stale trace, asserted on what the user is TOLD":

  test "edit, toggle to Debug on an existing trace, and the user is told":
    # PLAT-16: "The stale-trace case: edit, toggle to Debug on an existing
    # trace, and assert the user is TOLD. A test that only checks the toggle
    # succeeds would pass while the user is misled."
    let rt = editingRuntime(traceName = "demo.ct")
    ck rt.app.modes.product == pmEdit

    # THE EDIT IS MADE THROUGH THE REAL INPUT PATH: a byte, decoded by
    # `keymap.keyName`, routed by `runtime.editorOwnsToken`, applied to the
    # `isonim-tui` widget. Not `buf.widget.insertText` called directly.
    ck rt.editorOwnsToken("X")
    let typed = rt.handleToken("X", 0)
    ck typed.repaint
    let buf = rt.app.editSession.activeBuffer()
    ck buf.isDirty
    ck buf.text != TextA
    ck rt.app.editSession.editedPaths == @[FileA]

    # …AND NOW THE TOGGLE, as real bytes.
    let switched = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmDebug
    ck switched.repaint
    ck switched.action == kaToggleProductMode

    # THE ASSERTION THE MILESTONE ASKS FOR: what the user is TOLD, on the row
    # they are looking at.
    #
    # AT 120 COLUMNS, which is the Standard profile's own width and therefore
    # what a real user reading this notice has. The notification area is
    # right-aligned and bounded by `statusBarText`'s arithmetic, so the row is
    # the message AS TRUNCATED — and the three things that must survive the
    # truncation are the fact, the file and the consequence.
    let row = statusRow(rt)
    checkpoint("status row (120): " & row)
    ck row.contains("predates")
    ck row.contains(FileA)
    ck row.contains("line numbers")
    # The outcome carries the WHOLE sentence, including the remedy — which is
    # the part a 120-column status line cannot fit and a wider one can. Split
    # in two deliberately: "the user saw it" and "the message says what to do"
    # are different claims and only the second is about the string.
    ck switched.detail == rt.app.notification
    ck switched.detail.contains("predates")
    ck switched.detail.contains(":run")
    ck switched.detail.contains("re-record")

    # …AND AT 200 COLUMNS THE WHOLE SENTENCE IS ON THE ROW, remedy included.
    # This is what says the truncation above is a width effect rather than a
    # message that never carried the remedy.
    let wide = editingRuntime(traceName = "demo.ct", cols = 200)
    discard wide.handleToken("X", 0)
    let wideSwitch = wide.handleToken(CtrlF5, 0)
    let wideRow = statusRow(wide)
    checkpoint("status row (200): " & wideRow)
    ck wideRow.contains(":run")
    ck wideRow.contains(wideSwitch.detail)

  test "told ONCE, and the negative control says the notice can be absent":
    # §2.1: "must be told, once, plainly." A notice repeated on every switch
    # teaches the user to dismiss the one that matters (§4c obligation 3's
    # argument, arriving through a different door).
    let rt = editingRuntime(traceName = "demo.ct")
    discard rt.handleToken("X", 0)
    let first = rt.handleToken(CtrlF5, 0)
    ck first.detail.contains("predates")
    # Back to Edit, and to Debug again.
    discard rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmEdit
    let second = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmDebug
    checkpoint("second switch said: " & second.detail)
    ck not second.detail.contains("predates")
    ck second.detail.contains("DEBUG")

    # THE NEGATIVE CONTROL, FALSIFIED RATHER THAN ASSERTED
    # (Verification-Harness-Traps §7a). Three arms, and each differs from the
    # positive case in exactly one input:
    #
    #   * no edit  -> no notice, because there is nothing stale;
    #   * no trace -> no notice, because there is nothing to be stale;
    #   * edit + trace -> a notice. (The positive case above.)
    let noEdit = editingRuntime(traceName = "demo.ct")
    let a = noEdit.handleToken(CtrlF5, 0)
    ck noEdit.app.modes.product == pmDebug
    ck not a.detail.contains("predates")

    let noTrace = editingRuntime()
    discard noTrace.handleToken("X", 0)
    ck noTrace.app.editSession.editedPaths == @[FileA]
    let b = noTrace.handleToken(CtrlF5, 0)
    ck noTrace.app.modes.product == pmDebug
    ck not b.detail.contains("predates")
    # …and the reason is the verdict, not an accident of the message:
    ck assessTrace(false, @[FileA]).verdict == stvNoTrace
    ck assessTrace(true, @[]).verdict == stvFresh
    ck assessTrace(true, @[FileA]).verdict == stvStale

  test "a saved edit is still an edit the recording predates":
    # PLAT-16's landing pass, F2. `:w` used to SILENCE this notice, and the
    # comment at the `:w` arm claimed in so many words that it did not:
    # *"`editedPaths` keeps the path and the notice still fires on the next
    # switch."* Measured before the repair, on this exact sequence:
    #
    #   A (edit, toggle):     "This recording predates your edits to 1 file…"
    #   B (edit, :w, toggle): detail = 'switched to DEBUG mode'
    #                         editedPaths: @[]   verdict: fresh
    #
    # `markSaved` made the buffer non-dirty and `refreshEditedPaths` dropped
    # every non-dirty path — `isDirty` ("differs from disk") read as "the
    # recording is not stale", which is Verification-Harness-Traps §5a with the
    # dangerous event read as the benign one. Saving makes a recording MORE
    # stale: after it the bytes the recording was made from are gone from the
    # disk as well as from the buffer.
    #
    # THIS CASE ASSERTS THE EFFECT AND NOT THE LIST. `editedPaths` was correct
    # at every intermediate point and wrong only at the one that reaches a
    # user, which is why the suite that read the list was green.
    let rt = editingRuntime(traceName = "demo.ct")
    var written: seq[string] = @[]
    rt.editServices.writeFile = proc(relative, text: string): EditWriteResult =
      written.add relative & "=" & text
      EditWriteResult(ok: true)
    discard rt.handleToken("X", 0)
    let buf = rt.app.editSession.activeBuffer()
    ck buf.isDirty
    ck buf.outrunsRecording

    # `:w` THROUGH THE REAL PROMPT, not by calling `markSaved`.
    discard rt.prompt.open(pkCommand)
    for ch in ":w":
      discard rt.prompt.applyKey($ch, @[])
    discard rt.handleToken("\r", 0)
    checkpoint("written: " & written.join(", "))
    ck written.len == 1
    ck written[0].startsWith(FileA & "=")

    # THE TWO PREDICATES NOW DISAGREE, AND THAT IS THE REPAIR. One means "there
    # is unsaved work" and drives the `[+]` marker; the other means "this file
    # has outrun the recording" and drives the notice. Before the split they
    # were one comparison and this line could not be written.
    ck not buf.isDirty
    ck buf.outrunsRecording

    # …AND THE USER IS STILL TOLD.
    let switched = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmDebug
    checkpoint("after edit+save+toggle: " & switched.detail)
    ck switched.detail.contains("predates")
    ck switched.detail.contains(FileA)
    ck statusRow(rt).contains("predates")

  test "a save that restores the recorded bytes IS fresh again":
    # THE NEGATIVE HALF OF THE SAME PREDICATE, FALSIFIED RATHER THAN ASSERTED
    # (§7a). `outrunsRecording` is a disjunction — the BUFFER moved, or the
    # DISK moved — and each half needs a case only it can satisfy, or one of
    # them is doing no work:
    #
    #   * edit, `:w`, undo            -> STALE. The buffer is back; the disk is
    #                                    not. A buffer-only predicate says
    #                                    fresh, and is wrong.
    #   * edit, `:w`, undo, `:w`      -> FRESH. Both are back. A disk-only
    #                                    predicate that latched on the first
    #                                    write says stale, and is wrong.
    let rt = editingRuntime(traceName = "demo.ct")
    var onDisk = TextA
    rt.editServices.writeFile = proc(relative, text: string): EditWriteResult =
      onDisk = text
      EditWriteResult(ok: true)
    template typeCommand(text: string) =
      discard rt.prompt.open(pkCommand)
      for ch in text:
        discard rt.prompt.applyKey($ch, @[])
      discard rt.handleToken("\r", 0)

    discard rt.handleToken("X", 0)
    typeCommand(":w")
    ck onDisk != TextA
    discard rt.handleToken("\x1a", 0)          # Ctrl+z, back to the loaded text
    let buf = rt.app.editSession.activeBuffer()
    ck buf.text == TextA
    # THE DISK STILL HOLDS THE EDIT, so the recording is still outrun.
    ck buf.outrunsRecording
    ck rt.app.editSession.editedPaths == @[FileA]

    # …and writing the restored text back closes it.
    typeCommand(":w")
    ck onDisk == TextA
    ck not buf.outrunsRecording
    let switched = rt.handleToken(CtrlF5, 0)
    checkpoint("after edit+save+undo+save: " & switched.detail)
    ck not switched.detail.contains("predates")
    ck rt.app.editSession.editedPaths.len == 0

  test "an edit that was undone is not a staleness":
    # `refreshEditedPaths` re-derives from the buffers' actual contents, so
    # `Ctrl+z` back to the loaded bytes leaves nothing to announce. A notice
    # about a file the user restored is a notice about nothing.
    let rt = editingRuntime(traceName = "demo.ct")
    discard rt.handleToken("X", 0)
    ck rt.app.editSession.editedPaths.len == 1
    discard rt.handleToken("\x1a", 0)      # Ctrl+z
    let buf = rt.app.editSession.activeBuffer()
    checkpoint("after undo: '" & buf.text & "'")
    ck not buf.isDirty
    let switched = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmDebug
    ck not switched.detail.contains("predates")
    ck rt.app.editSession.editedPaths.len == 0

  test "the notice names the files, and caps the list rather than the count":
    # A notice that said only "this trace is stale" would leave the user to work
    # out which edit caused it. With many files the list is capped and the COUNT
    # is still exact, so the user can tell "three of my files" from "thirty".
    let many = @["a.nim", "b.nim", "c.nim", "d.nim", "e.nim"]
    let notice = staleTraceNotice(assessTrace(true, many))
    checkpoint(notice)
    ck notice.contains("5 files")
    ck notice.contains("a.nim")
    ck notice.contains("c.nim")
    ck not notice.contains("e.nim")
    ck notice.contains("…")
    let one = staleTraceNotice(assessTrace(true, @["only.nim"]))
    ck one.contains("1 file (")
    ck one.contains("only.nim")
    ck not one.contains("…")
    # …and a fresh trace produces NO sentence at all, so "" and a sentence are
    # the two states rather than a sentence and a shorter sentence.
    ck staleTraceNotice(assessTrace(true, @[])).len == 0
    ck staleTraceNotice(assessTrace(false, @["x.nim"])).len == 0

suite "PLAT-16 §6: the toggle out of a REPLAY session reaches something to edit":

  test "the toggle furnishes the workspace through the host seam, exactly once":
    # PLAT-16's landing pass, F1. The stale-trace notice needs a recording AND
    # an edited buffer at the same moment, and **no shipped route had both**:
    # `ct edit --ui=tui` opens buffers and has no recording (correctly — see
    # `main.editInteractive`'s header), while `ct replay --ui=tui` had the
    # recording and wired no `EditServices` at all, so `Ctrl+F5` arrived at an
    # empty `EditSession` where `activeBuffer()` was nil and `:e` answered
    # *"`:e` has no reader in this session"*. The suite's own fixture supplied
    # the missing state by hand — §7's green fixture being an instance of the
    # defect — and the milestone had named that exact failure in advance:
    # *"a test that only checks the toggle succeeds would pass while the user
    # is misled."*
    #
    # This case is that route at Tier 1: a Debug-mode runtime with a trace and
    # the four host closures, which is what `main.interactive` now builds.
    # `tests/real_terminal/test_real_edit_mode.nim` asserts the same route
    # through the shipped binary, on a real recording and a real disk.
    let app = newTuiApp()
    app.projectRoot = Project
    app.traceName = "demo.ct"
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    var walks = 0
    var reads: seq[string] = @[]
    rt.editServices.listFiles = proc(): EditListResult =
      inc walks
      EditListResult(files: @[FileA, "src/beta.nim"], truncated: false)
    rt.editServices.readFile = proc(relative: string): EditReadResult =
      reads.add relative
      EditReadResult(ok: true, text: TextA)
    ck rt.app.modes.product == pmDebug
    ck rt.app.editSession.isNil

    let toEdit = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmEdit
    # THE WALK HAPPENED ON THE SWITCH AND NOT BEFORE IT: a replay session that
    # never presses Ctrl+F5 must not pay for a filesystem walk.
    ck walks == 1
    ck reads == @[FileA]
    ck rt.app.fileTree.files.len == 2
    ck rt.app.fileTree.openPath == FileA
    let buf = rt.app.editSession.activeBuffer()
    ck not buf.isNil
    ck pathOf(buf) == FileA
    # The arrival message names the ROOT, because a replay session's project is
    # the working directory and a user who was somewhere else has to be able to
    # see which tree they got.
    checkpoint("arrival: " & toEdit.detail)
    ck toEdit.detail.contains(Project)
    ck toEdit.detail.contains("2 file(s)")
    # AND THE EDITOR HAS THE FOCUS, which is what makes the next byte text
    # rather than a keybinding aimed at the user's own source.
    ck rt.editorOwnsToken("X")

    # …so the whole §2.1 route exists on a runtime nothing hand-built.
    discard rt.handleToken("X", 0)
    ck buf.isDirty
    let back = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmDebug
    checkpoint("switched back: " & back.detail)
    ck back.detail.contains("predates")
    ck back.detail.contains(FileA)

    # ONCE PER SESSION. A second entry re-walks nothing, re-reads nothing, and
    # — the reason that matters — cannot replace the unsaved buffer, which
    # Mode-Transitions.md §5 calls data loss by name.
    let again = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmEdit
    ck walks == 1
    ck reads == @[FileA]
    ck again.detail.contains("EDIT")
    ck rt.app.editSession.activeBuffer().text == buf.text
    ck rt.app.editSession.activeBuffer().isDirty

  test "no seam, no workspace — and the toggle still says what it did":
    # THE NEGATIVE CONTROL, and it is the state a session is in when nothing
    # wired the host: the switch happens, nothing is invented, and the message
    # is the plain one rather than a fabricated `editing … — 0 file(s)`.
    let app = newTuiApp()
    app.traceName = "demo.ct"
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    let toEdit = rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmEdit
    ck toEdit.detail == "switched to EDIT mode"
    ck rt.app.fileTree.files.len == 0
    ck rt.app.editSession.activeBuffer().isNil
    # …and `ensureEditWorkspace` is idempotent over that, rather than raising.
    ck rt.ensureEditWorkspace() == ""

  test "an empty project is furnished once and reported honestly":
    # A project with no files is a real state, and it is the one a
    # `buffers.len > 0` guard would re-walk on every switch. The editor stays
    # empty, the count is reported, and the walk happens exactly once.
    let app = newTuiApp()
    app.projectRoot = Project
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    var walks = 0
    rt.editServices.listFiles = proc(): EditListResult =
      inc walks
      EditListResult(files: @[], truncated: false)
    let toEdit = rt.handleToken(CtrlF5, 0)
    checkpoint("arrival: " & toEdit.detail)
    ck toEdit.detail.contains("0 file(s)")
    ck rt.app.editSession.activeBuffer().isNil
    ck walks == 1
    discard rt.handleToken(CtrlF5, 0)
    discard rt.handleToken(CtrlF5, 0)
    ck rt.app.modes.product == pmEdit
    ck walks == 1

  test "a reader that refuses wins the status line over the file count":
    # "editing … — 3 file(s)" over an empty editor is the message that reads as
    # success. The refusal is what the user needs.
    let app = newTuiApp()
    app.projectRoot = Project
    let rt = newTuiRuntime(app, caps(), Cols, Rows)
    rt.editServices.listFiles = proc(): EditListResult =
      EditListResult(files: @[FileA], truncated: false)
    rt.editServices.readFile = proc(relative: string): EditReadResult =
      EditReadResult(ok: false, message: relative & ": no such file")
    let toEdit = rt.handleToken(CtrlF5, 0)
    checkpoint("arrival: " & toEdit.detail)
    ck toEdit.detail.contains("no such file")
    ck not toEdit.detail.contains("file(s)")
    ck rt.app.editSession.activeBuffer().isNil
    # The TREE is still filled: the walk succeeded and only the read did not.
    ck rt.app.fileTree.files == @[FileA]

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
