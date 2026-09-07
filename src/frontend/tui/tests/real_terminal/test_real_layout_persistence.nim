## test_real_layout_persistence.nim — PLAT-6, Tier 2: **an arrangement survives
## a restart**.
##
## ## What only this file can say
##
## PLAT-6's Goal reads *"move tabs, resize splits, dock panes, save and
## restore"*, and its own verification pass recorded that the fourth clause was
## the one a user did not get: `binding.saveDocument` and
## `binding.restoreDocument` had no caller outside two Tier-1 suites, so an
## arrangement did not survive a restart.
##
## Persistence is the one property in this milestone that **cannot** be observed
## from inside one process. The subject is what one process wrote and a
## DIFFERENT process read, so this suite spawns a real child in a real pty,
## docks a pane with real SGR-1006 bytes, lets the child EXIT, and then spawns a
## SECOND child on the same recording and looks at its first frame.
##
## Every step is the product's own path:
##
##   * the bytes arrive on a real file descriptor and are framed into one token
##     by `host/terminal_driver.InputFramer`;
##   * `runtime.handleToken` asks `app/input/mouse.decodeMouse` and hands the
##     report to `binding.onMouse`;
##   * the child's exit runs `host/layout_store.persistLayoutForSession`, which
##     is the call `main.nim` makes after its input loop;
##   * the second child's first frame runs
##     `host/layout_store.restoreLayoutForSession`, which is the call `main.nim`
##     makes before its first paint.
##
## `tests/test_layout_persistence.nim` is the Tier-1 half and owns what a
## terminal cannot answer: the key rule, the resulting `Layout`, the persist
## plan and the four ways a document can be unreadable.
##
## ## THE BARRIER FOR THE SECOND PROCESS, WHICH IS THE HARD PART
##
## "The screen has content" is not a barrier: after a relaunch the pty is fresh,
## and a blank frame and a restored frame both take time to arrive while only
## one of them is the subject. `dual_snap.waitForCompleteFrame`'s
## `(rows-1, cols-1)` is not one either — the child parks its cursor elsewhere,
## and a report that opened no prompt would leave the cursor wherever the
## previous frame left it.
##
## So the child parks the cursor at `(0, step + 1)` after every frame and this
## file waits on `waitForCursorAt`. For the SECOND process, step 0 is `(0, 1)`,
## and a freshly spawned terminal's cursor is at `(0, 0)` — a position it was
## not at a moment earlier, which is exactly what a barrier has to be. The step
## counter is `test_app_runtime`'s and advances only when `handleInput` returns
## true, so a child that stopped repainting makes the barrier UNREACHABLE rather
## than trivially true: the failure direction is a named timeout with the
## observed cursor and screen in it, never a green run over a frame that never
## came.
##
## ## THE FAILURE ARMS ARE HERE TOO, BECAUSE THE USER-FACING HALF IS A SCREEN
##
## Tier 1 asserts that an unreadable document produces a typed report. That is
## the model half. **The claim that the USER IS TOLD is a claim about a
## terminal**, and it is only true if the message reaches the status row of a
## real screen and survives to be read — so the corrupt and future-version arms
## are driven here, against a real child, and the assertion is on the row a user
## looks at.
##
## ## It does not skip
##
## A child that will not compile, a child that never parks its cursor, a
## document that was not written: every one FAILS by name with what was actually
## observed. There is no `when false`, no early return on a missing
## prerequisite, and no `try/except` that turns a failure into a pass.
##
## ## No mocks
##
## The subject is a compiled binary in a real pty, parsed by a real terminal
## state machine, writing and reading a real file under a real temporary
## directory. The child's `Dispatcher` carries no ViewModels, which is not a
## stand-in for one: `app/commands/interpreter.nim` documents nil as "not wired"
## and answers `drUnavailable` by name, and neither a layout gesture nor a
## layout document needs a debugger.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc` sets a
## module-level global and the test still reports `[OK]` with its failed
## comparison printed directly above it. Every helper here that calls `check` is
## a `template`; the ones that are `proc`s return values and call `check`
## nowhere.

import std/[algorithm, json, os, strutils, tempfiles, times, unicode, unittest]

import term_assert

import headless_app/layout_model

import ../../app/runtime
import ../../testing/dual_snap
import ../../testing/test_app_runtime
import ../../host/layout_store
import ../apps/app_layout_gestures as gestureApp
import ../apps/app_layout_persist as persistApp

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 70

const
  Stem = "app_layout_persist"
  Cols = persistApp.Cols
  Rows = persistApp.Rows
  FrameTimeoutMs = 20000

  DraggedPane = paneCalltrace
  DraggedPaneTitle = "Call Stack"
  DraggedPaneTitleRow = "CALL STACK"

  DropRow = 0
  DropCol = 40
    ## THE HEADER ROW — a cell outside the tree area, which is what makes a drop
    ## dock rather than move. `test_layout_command_routing.nim` measures over
    ## every cell of the screen that `{top, bottom}` is the whole reachable set.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# Values only. Nothing below calls `check`.
# ---------------------------------------------------------------------------

proc sgrReport(button, row, col: int; pressed: bool): string =
  ## One SGR-1006 report, in the exact bytes a terminal puts on the wire.
  ##
  ## Spelled out rather than taken from `TermAssert.sendMouseClick`, which
  ## writes a press AND a release AT ONE CELL and therefore cannot express a
  ## drag at all. `test_real_layout_mouse.nim`'s third case pins this encoder
  ## against the harness's own on a real child's stdin, which is the measurement
  ## Verification-Harness-Traps §9 asks for; this file reuses the encoder rather
  ## than re-measuring it.
  ##
  ## ONE-BASED ON THE WIRE (`app/input/mouse.nim`'s header): every argument here
  ## is zero-based and every field is `+ 1`.
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc paneRow(sess: var TuiTestSession; row: int): string =
  ## One row of the terminal, with its right-hand padding removed.
  ##
  ## `strutils.strip` IS QUALIFIED, AND THAT IS NOT STYLE. This file imports
  ## `std/unicode` for `textCells`' neighbourhood, and `unicode.strip` — which
  ## wins the overload on an unqualified call — returns an all-whitespace string
  ## UNCHANGED, so an assertion that a row is empty fails while every assertion
  ## about a row with content passes. Measured on nim 2.2.8; see
  ## `test_real_command_mode.nim`.
  strutils.strip(sess.regionText(row, 0, Cols, 1).split('\n')[0],
                 leading = false)

proc filesUnder(root: string): seq[string] =
  ## Every file below `root`, relative to it, sorted. THE WHOLE STATE ROOT,
  ## because "nothing was written" has to exclude a stray `.new` a failed
  ## rename left behind as well as the document itself.
  result = @[]
  if not dirExists(root):
    return
  for path in walkDirRec(root):
    result.add path.relativePath(root)
  result.sort()

proc mentionsKey(node: JsonNode; key: string): bool =
  case node.kind
  of JObject:
    for name, value in node:
      if name == key or value.mentionsKey(key):
        return true
    false
  of JArray:
    for value in node:
      if value.mentionsKey(key):
        return true
    false
  else:
    false

type
  Recording = object
    ## One test's private state root and stand-in recording.
    root: string
    trace: string
    document: string

proc newRecording(): Recording =
  let base = createTempDir("plat6-relaunch-", "")
  result = Recording(root: base / "state", trace: base / "recording.ct",
                     document: "")
  createDir(result.trace)
  # THE STATE ROOT IS PRIVATE TO THIS RUN. A suite that wrote into the
  # developer's own `$XDG_STATE_HOME/codetracer` would be a suite that changes
  # the machine it runs on, and the override exists for exactly that reason.
  putEnv(LayoutDirEnvVar, result.root)
  result.document = layoutDocumentPathFor(result.trace)

proc dispose(rec: Recording) =
  delEnv(LayoutDirEnvVar)
  removeDir(rec.root.parentDir)

proc spawnChild(rec: Recording; withBinding: bool): TuiTestSession =
  ## A child on this recording, with or without PLAT-6's binding.
  ##
  ## `envSet` AFTER `envRemove` WOULD BE A TRAP (Verification-Harness-Traps
  ## §11): `TermAssert.effectiveEnv` used to apply its blocklist to the
  ## overrides too, so `.envRemove(X).envSet(X, v)` handed the child an
  ## environment with no `X` at all. Nothing here removes a variable it also
  ## sets, and the OFF arm expresses "not set" by not setting it — which cannot
  ## hit that shape whatever the harness does.
  compileChildApp(Stem)
  var builder = newTuiTest(appBinaryPath(Stem),
                           @["--cols=" & $Cols, "--rows=" & $Rows])
    .width(Cols).height(Rows)
    .envSet(LayoutDirEnvVar, rec.root)
    .envSet(persistApp.TraceEnvVar, rec.trace)
  if withBinding:
    builder = builder.envSet(persistApp.BindingEnvVar, "1")
  builder.spawn()

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template ckFirstFrame(sess: var TuiTestSession; label: string) =
  ## The barrier for a process's FIRST frame, plus the non-vacuity floor every
  ## screen assertion after it depends on.
  block:
    waitForCursorAt(sess, 0, persistApp.cursorParkColumn(0, Cols),
                    FrameTimeoutMs)
    let contents = sess.screenContents()
    checkpoint(label & ": first frame, " &
               $strutils.strip(contents).len & " non-blank characters")
    # A SCREEN THAT PARSED TO NOTHING satisfies every `contains` and every
    # `not contains` below for the wrong reason.
    ck strutils.strip(contents).len > 0

template ckArrangementIsDocked(sess: var TuiTestSession; label: string) =
  ## The arrangement a docked call-stack pane produces, asserted ABSOLUTELY —
  ## against `DockStripGlyph` and the pane's own name, neither of which is read
  ## off a model's rendering.
  block:
    let strip = paneRow(sess, 1)      ## the body's first row, below the header
    checkpoint(label & " strip row: '" & strip & "'")
    ck strip.startsWith(DraggedPaneTitle)
    var glyphCells = 0
    var wrongCells: seq[string] = @[]
    for col in textCells(DraggedPaneTitle) ..< Cols:
      let rune = $sess.cellAt(1, col).rune
      if rune == DockStripGlyph: inc glyphCells
      else: wrongCells.add "(1," & $col & ") is '" & rune & "'"
    if wrongCells.len > 0:
      checkpoint(wrongCells[0 .. min(4, wrongCells.high)].join(", "))
    # EXACT, not "more than none" (Verification-Harness-Traps §4b): the strip
    # spans the body's full width and the label takes its first cells.
    ck glyphCells == Cols - textCells(DraggedPaneTitle)
    ck wrongCells.len == 0
    # AND THE PANE IS GONE FROM THE BODY. A strip drawn beside a pane that was
    # never removed satisfies every assertion above.
    ck not sess.screenContents().contains(DraggedPaneTitleRow)
    # `revealed` IS NOT PERSISTED (Layout-ViewModel §3.2): a restore that
    # reopened the overlay a previous session had open would paint it here.
    #
    # This is slightly STRONGER than it reads, and the strength is honest rather
    # than accidental: `RevealOverlayGlyph` and `DropTargetGlyph` are the same
    # rune (`▒`), so what this actually says is that no reveal overlay AND no
    # drop target is on the screen. Both are `Interaction` state and neither may
    # survive a restore, so one assertion covering two is right — but a reader
    # should not take it as evidence about the reveal overlay ALONE.
    ck not sess.screenContents().contains(RevealOverlayGlyph)

template ckArrangementIsDefault(sess: var TuiTestSession; label: string) =
  ## The profile's own arrangement: the pane is in the body and no strip exists.
  block:
    let contents = sess.screenContents()
    checkpoint(label & ": default arrangement expected")
    ck contents.contains(DraggedPaneTitleRow)
    ck contents.contains("[Variables]")     ## the Compact profile's tab stack
    ck not contents.contains(DockStripGlyph)

template ckQuitsCleanly(sess: var TuiTestSession; label: string) =
  ## The child ENDS, which is the whole premise of a relaunch test: a save that
  ## runs after the input loop has not run until the loop has returned.
  block:
    sess.send($TestAppQuitByte)
    let status = sess.waitExit(initDuration(seconds = 10))
    checkpoint(label & " exited with " & $status)
    ck status.isSome
    ck status.get() == TestAppExitOk

# ---------------------------------------------------------------------------

suite "PLAT-6 Tier 2: an arrangement survives a restart, on a real terminal":

  test "a pane docked on a real pty is still docked in the NEXT process":
    # **THE ROW.** Dock, exit, relaunch, look.
    let rec = newRecording()
    try:
      ck filesUnder(rec.root).len == 0

      # THE IN-PROCESS TWIN, built through the app's own constructor, purely to
      # say WHERE the pane is. Nothing is asserted against its screen here —
      # `test_real_layout_mouse.nim` owns the cross-tier comparison and this
      # file owns what a second process sees.
      let model = gestureApp.newBoundRuntime(Cols, Rows)
      let source = model.layoutGeometry().regionOfPane(DraggedPane)
      checkpoint("the dragged pane is at " & $source)
      ck not source.isEmptyArea

      # ---- PROCESS 1: dock the pane and exit ------------------------------
      var first = spawnChild(rec, withBinding = true)
      try:
        ckFirstFrame(first, "process 1")
        ckArrangementIsDefault(first, "process 1 before the drag")
        # Nothing has been written yet: a document that appeared before the
        # gesture would mean the session saves its own default, which is the
        # freeze bug `app/layout/persistence.nim`'s header names.
        ck filesUnder(rec.root).len == 0

        first.send(sgrReport(0, source.row, source.col, true))
        waitForCursorAt(first, 0, persistApp.cursorParkColumn(1, Cols),
                        FrameTimeoutMs)
        first.send(sgrReport(0, DropRow, DropCol, false))
        waitForCursorAt(first, 0, persistApp.cursorParkColumn(2, Cols),
                        FrameTimeoutMs)
        ckArrangementIsDocked(first, "process 1 after the drop")
        # STILL NOTHING ON DISK. The save is once per session, not once per
        # gesture, and this is what says so rather than a comment.
        ck filesUnder(rec.root).len == 0
        ckQuitsCleanly(first, "process 1")
      finally:
        first.terminate()
        first.close()

      # ---- WHAT PROCESS 1 LEFT BEHIND -------------------------------------
      checkpoint("after process 1 the state root holds " &
                 $filesUnder(rec.root))
      ck filesUnder(rec.root) ==
        @[LayoutDocumentDirName / rec.document.extractFilename]
      let written = readFile(rec.document)
      let doc = parseJson(written)
      ck doc["version"].getInt == LayoutSchemaVersion
      ck doc["docked"].len == 1
      ck doc["docked"][0]["pane"].getStr == $DraggedPane
      ck doc["docked"][0]["edge"].getStr == $leTop
      # `revealed` IS NOT IN THE DOCUMENT AT ALL — a decoder cannot resurrect
      # what an encoder never wrote.
      ck not doc.mentionsKey("revealed")
      # …and the positive twin for that scan, so `not mentionsKey` is a
      # measurement rather than a walk that reaches nothing.
      ck doc.mentionsKey("docked")
      ck doc.mentionsKey("edge")

      # ---- PROCESS 2: a DIFFERENT process, the same recording -------------
      var second = spawnChild(rec, withBinding = true)
      try:
        # THE BARRIER FOR THE SECOND PROCESS. `(0, 1)` against a fresh pty's
        # `(0, 0)` — see this file's header.
        ckFirstFrame(second, "process 2")
        # **THE ARRANGEMENT CAME BACK**, on the first frame, with no gesture.
        ckArrangementIsDocked(second, "process 2 on its first frame")
        ckQuitsCleanly(second, "process 2")
      finally:
        second.terminate()
        second.close()

      # A RESTORE FOLLOWED BY A SAVE IS IDEMPOTENT: process 2 rearranged
      # nothing, so what it wrote back is what process 1 wrote.
      ck fileExists(rec.document)
      ck readFile(rec.document) == written
      ck filesUnder(rec.root) ==
        @[LayoutDocumentDirName / rec.document.extractFilename]
    finally:
      rec.dispose()

  test "an unreadable document is NAMED on the status row and left alone":
    # THE USER-FACING HALF OF THE FAILURE ARM. Tier 1 asserts the typed report;
    # the claim that a user is TOLD is a claim about a screen, and this is that
    # screen. Two arms, because they fail at two different depths: bytes that
    # are not JSON never reach the decoder, and a schema version from a newer
    # build reaches it and is refused BY THE MIGRATION CHAIN — which is the one
    # the chain exists for and the one where overwriting would cost a user
    # their arrangement.
    var armsChecked = 0
    for arm in [("corrupt bytes", "{ this is not a layout ", "NotJson"),
                ("a schema version from a NEWER build",
                 """{"version": 99, "layout": {"kind": "pane",
                     "pane": "editor"}, "docked": []}""", "UnknownVersion")]:
      inc armsChecked
      let rec = newRecording()
      try:
        createDir(rec.document.parentDir)
        writeFile(rec.document, arm[1])
        let planted = readFile(rec.document)

        var sess = spawnChild(rec, withBinding = true)
        try:
          ckFirstFrame(sess, arm[0])
          # THE STATUS ROW, WHICH IS WHERE A USER LOOKS. The message leads with
          # the KIND because `views/status_bar.statusBarText` fits the
          # notification to the columns that are left and truncates the tail.
          let status = paneRow(sess, Rows - 1)
          checkpoint(arm[0] & " status row: '" & status & "'")
          ck status.contains("saved layout ignored")
          ck status.contains(arm[2])
          # AND THE SESSION IS USABLE, on the profile's own arrangement — the
          # half that says this is a report rather than a refusal to start.
          ckArrangementIsDefault(sess, arm[0])
          ckQuitsCleanly(sess, arm[0])
        finally:
          sess.terminate()
          sess.close()

        # THE DOCUMENT IS UNTOUCHED. A build that answered `UnknownVersion` by
        # overwriting would destroy a user's arrangement because they opened an
        # older binary once.
        ck readFile(rec.document) == planted
        ck filesUnder(rec.root) ==
          @[LayoutDocumentDirName / rec.document.extractFilename]
      finally:
        rec.dispose()
    checkpoint("unreadable-document arms driven on a real terminal: " &
               $armsChecked)
    ck armsChecked == 2

  test "OFF: with no binding the child neither reads nor writes a document":
    # THE ARM THE OPT-IN RESTS ON, at Tier 2. The child differs from the one
    # above in exactly one call — `enableLayoutBinding` — and a VALID document
    # is sitting at the path a bound session would read. It is not read, the
    # arrangement is the profile's own, and nothing under the state root moves.
    let rec = newRecording()
    try:
      # Plant a real document by running a BOUND child, so the file is the
      # product's own bytes rather than a fixture this file invented.
      let model = gestureApp.newBoundRuntime(Cols, Rows)
      let source = model.layoutGeometry().regionOfPane(DraggedPane)
      var planting = spawnChild(rec, withBinding = true)
      try:
        ckFirstFrame(planting, "the planting child")
        planting.send(sgrReport(0, source.row, source.col, true))
        waitForCursorAt(planting, 0, persistApp.cursorParkColumn(1, Cols),
                        FrameTimeoutMs)
        planting.send(sgrReport(0, DropRow, DropCol, false))
        waitForCursorAt(planting, 0, persistApp.cursorParkColumn(2, Cols),
                        FrameTimeoutMs)
        ckQuitsCleanly(planting, "the planting child")
      finally:
        planting.terminate()
        planting.close()
      ck fileExists(rec.document)
      let planted = readFile(rec.document)
      let plantedFiles = filesUnder(rec.root)
      ck plantedFiles.len == 1

      var sess = spawnChild(rec, withBinding = false)
      try:
        ckFirstFrame(sess, "the unbound child")
        # NOTHING WAS READ: the arrangement is the profile's, and the status row
        # carries no report about a document.
        ckArrangementIsDefault(sess, "the unbound child")
        let status = paneRow(sess, Rows - 1)
        checkpoint("the unbound child's status row: '" & status & "'")
        ck not status.contains("saved layout")
        ck not status.contains("layout restored")
        ckQuitsCleanly(sess, "the unbound child")
      finally:
        sess.terminate()
        sess.close()

      # NOTHING WAS WRITTEN AND NOT ONE BYTE MOVED.
      ck readFile(rec.document) == planted
      ck filesUnder(rec.root) == plantedFiles
    finally:
      rec.dispose()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
