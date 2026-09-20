## PLAT-34 — `DIFF-1`'s LOAD-BEARING HALF: **both front-ends' observed output
## changes when the model changes, each read FROM A RUN.**
##
## Spec: `Testing/Editor-Model-Conformance-Suite.md` §8 (`DIFF-1`);
## `Planned-Work/CodeTracer-Platform.milestones.org` under PLAT-34's
## verification gate.
##
## =========================================================================
## WHY THIS FILE EXISTS BESIDE THE OTHER ONE
## =========================================================================
##
## PLAT-34 names the trap before it is walked into: *"if both front-ends are
## thin derivations of one model — which is the milestone's goal — then
## comparing their model states is two reads of one value and CANNOT FAIL. So
## `DIFF-1` has two halves and the second is the load-bearing one."*
##
## `src/frontend/viewmodel/tests/unit/test_editor_front_end_differential.nim`
## is half 1 — thirty pinned sequences, the provenance scans, the
## mutable-buffer scan and the concern census — and it runs on the C, JS and
## wasm32 backends because it links neither renderer.
##
## **THIS FILE IS HALF 2 AND IT IS C-ONLY, AND THE REASON IS MEASURED RATHER
## THAN ASSERTED.** It paints the terminal's editor into a real `StyledGrid`
## through `views/edit_pane` and renders the GPUI editor into the real Rust
## shadow tree through `isonim-gpui`'s `extern "C"` surface — a `dynlib` the JS
## backend has no way to call. The first refusal a reader meets is one layer
## nearer than that, and it is the honest one to quote: `nim js` on this file
## stops at `osproc.nim(24, 8) Error: cannot export: quoteShell`, because the
## renderer-less control below spawns a child compiler. Either way there is no
## JS build of this suite, and a lane that pretended otherwise would be gating
## a configuration nothing ships. PLAT-29's `test_editor_async_closure.nim` is
## the same shape and the floor gate already carries the pattern.
##
## =========================================================================
## WHAT "OBSERVED OUTPUT" MEANS HERE, EXACTLY (§4a)
## =========================================================================
##
## Never the value the case constructed. For each medium:
##
## | medium | what is read | through |
## | --- | --- | --- |
## | terminal | the PAINTED CELLS of a `StyledGrid` | `paintEditPane` → `g.rowText(row)` |
## | gpui | the RUST-SIDE SHADOW TREE | `renderEditor` → `gpui_get_text_content` / `gpui_tree_node_count` |
##
## The GPUI side's node count comes back across the FFI boundary from the
## shim's own arena. A suite that read its `EditorSurface` back would be
## comparing this file's fixture with itself, which is exactly the defect
## PLAT-21 found in fifteen pre-existing cases that reported `[OK]` against a
## shim with no renderer.
##
## =========================================================================
## THE NEGATIVE CONTROL PLAT-21 EARNED, PERFORMED RATHER THAN DESCRIBED
## =========================================================================
##
## *"The same suite against a binary built WITHOUT the GPUI backend must not
## report `[OK]`."* It is performed by compiling **this file** a second time
## with `-d:ctGpuiShimAbsent` — under which the GPUI arm links no shim and
## returns an empty tree, which is what a renderer-less build IS from this
## suite's side — and asserting the child process fails.
##
## It is a define rather than a rebuild of `isonim-gpui` without
## `--features gpui-backend` for a reason that is a measurement rather than a
## preference: the shim this repository links is ALREADY built without that
## feature (`test_gpui_editing_surface.nim`'s header records it, and PLAT-20
## and PLAT-21 both do), and the feature governs `createWindow` — which
## nothing in this file calls. So "without the backend" would change nothing
## observable here, and the condition that DOES matter is whether the shadow
## tree exists at all. That is what the define removes.
##
## =========================================================================
## No mocks
## =========================================================================
##
## The grid is the shipped compositor, the pane model is the shipped
## `editPaneModelFor`, and the element tree is built by the real Rust shim.
## The only synthetic thing is the document's text, which is the subject.

import std/[compilesettings, os, osproc, strutils, unittest]

import codetracer_embed

import ../app/edit_binding

when not defined(ctGpuiShimAbsent):
  import isonim_gpui/renderer
  import isonim_gpui/bindings
  import ../../view_vocabulary/pane_views
  import gpui/app/leaves

import ../../view_vocabulary/editor_surface

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 75
  ## Asserted by the last case against the runtime tally. Written LAST, from a
  ## run.

const
  Doc = "def calc(n):\n    total = 0\n    for i in range(n):\n" &
        "        total += i\n    return total\n"
    ## A real multi-line document with an indent ladder, so an indent, a
    ## join and a delete all have somewhere to act.
  GpuiMediumName = "gpui"
  TerminalMediumName = "terminal"
  GridCols = 72
  GridRows = 16

# ===========================================================================
# THE EIGHT TRANSACTION KINDS
#
# **THE FIGURE WAS RE-DERIVED AND IT IS NOT `transaction.UserEvent`.** That
# enum has SIX members (`ueInput`, `ueDelete`, `ueMove`, `ueSelect`, `ueUndo`,
# `ueRedo`) and two of them — `ueMove` and `ueSelect` — change no text, so a
# gate over it could not ask "does the drawn TEXT change" for eight of
# anything. PLAT-34's term is eight transaction SHAPES, and they are
# enumerated here rather than left as a number: §36b's rule is that a figure
# nothing re-takes is free to be wrong, and this one is now a `case` a reader
# can count.
# ===========================================================================

type
  TxKind* = enum
    txInsertChar = "insert a character"
    txInsertNewline = "split a line"
    txDeleteBackward = "delete backward"
    txDeleteSelection = "delete a selection"
    txIndentSelection = "indent a selection"
    txUpperCaseSelection = "upper-case a selection"
    txUndo = "undo"
    txRedo = "redo"

const TxKindCount = 8
  ## A NAMED CARDINALITY, asserted against the enum's span, so the floor's
  ## multiplier cannot drift away from the thing it counts.

proc arrangeTx(d: var EditingDocument; kind: TxKind; nowMs: int64) =
  ## What has to be true BEFORE the observed transaction, run before the
  ## before-snapshot is taken.
  ##
  ## **THIS PROCEDURE EXISTS BECAUSE THE FIRST VERSION OF THIS SUITE HAD A
  ## GREEN-LOOKING CELL THAT COULD NOT FAIL AND A RED ONE THAT SHOULD NOT
  ## HAVE BEEN.** `txUndo` originally inserted a character and undid it, both
  ## inside the measured window: the document ended where it started, the
  ## drawn output was byte-identical, and the case failed — correctly, and for
  ## a reason about the ARRANGEMENT rather than about either front-end. The
  ## edit belongs on the other side of the snapshot. It is §34's shape read
  ## off a red rather than a green: a cell whose two ends are the same state
  ## measures nothing, and which way it reports that is an accident of the
  ## assertion's sign.
  case kind
  of txUndo:
    discard d.applyNamed("insert-text", OpArgs(text: "Q"), nowMs)
  of txRedo:
    discard d.applyNamed("insert-text", OpArgs(text: "Q"), nowMs)
    discard d.applyNamed("undo", OpArgs(), nowMs + 1)
  else:
    discard

proc applyTx(d: var EditingDocument; kind: TxKind; nowMs: int64) =
  ## Apply one transaction kind to `d`, through the CORE's named-operation
  ## door. Both media are driven by this one procedure, which is the point:
  ## the model change is identical and the only thing that can differ is what
  ## each medium then draws.
  case kind
  of txInsertChar:
    discard d.applyNamed("insert-text", OpArgs(text: "X"), nowMs)
  of txInsertNewline:
    discard d.applyNamed("insert-newline", OpArgs(), nowMs)
  of txDeleteBackward:
    discard d.applyNamed("delete-char-backward", OpArgs(), nowMs)
  of txDeleteSelection:
    discard d.applyNamed("select-group-right", OpArgs(), nowMs)
    discard d.applyNamed("delete-selection", OpArgs(), nowMs)
  of txIndentSelection:
    discard d.applyNamed("select-line", OpArgs(), nowMs)
    discard d.applyNamed("indent-selection", OpArgs(), nowMs)
  of txUpperCaseSelection:
    discard d.applyNamed("select-group-right", OpArgs(), nowMs)
    discard d.applyNamed("upper-case", OpArgs(), nowMs)
  of txUndo:
    discard d.applyNamed("undo", OpArgs(), nowMs + 2)
  of txRedo:
    discard d.applyNamed("redo", OpArgs(), nowMs + 2)

# ===========================================================================
# THE TWO OBSERVED OUTPUTS
# ===========================================================================

proc terminalObserved(buf: EditBuffer): string =
  ## **THE TERMINAL'S PAINTED CELLS.** `editPaneModelFor` is the shipped pane
  ## model and `paintEditPane` is the shipped painter; what comes back is what
  ## a user's terminal receives, read out of the grid rather than out of the
  ## model.
  let session = newEditSession()
  session.buffers = @[buf]
  session.active = 0
  let model = editPaneModelFor(session, buf)
  var g = newStyledGrid(GridCols, GridRows)
  discard paintEditPane(g, CellArea(col: 0, row: 0, width: GridCols,
                                    height: GridRows), model)
  for row in 0 ..< GridRows:
    result.add g.rowText(row)
    result.add '\n'

when defined(ctGpuiShimAbsent):
  # ---------------------------------------------------------------------
  # THE NEGATIVE CONTROL'S SUBJECT: the same suite with no renderer at all.
  # Every assertion below is unchanged; the only thing that moves is whether
  # there is a shadow tree to read. A suite that could still report `[OK]`
  # here is a suite that never read one.
  # ---------------------------------------------------------------------
  proc gpuiObserved(d: EditingDocument): string = ""
  proc gpuiNodeCount(): int = 0
  proc gpuiRowNodeCount(d: EditingDocument): int = 0
else:
  proc gpuiObserved(d: EditingDocument): string =
    ## **THE RUST-SIDE SHADOW TREE**, read back across the FFI boundary.
    gpui_reset_tree()
    var r: GpuiRenderer
    let parent = r.createElement("div")
    discard renderEditor(r, parent, sourcePaneView(GpuiMediumName).root,
                         editorSurfaceForDocument(d, GpuiMediumName,
                                                  mutableHere = false))
    textContent(parent)

  proc gpuiNodeCount(): int =
    ## The shim's own arena count, which is a number this process did not
    ## compute. A stub cannot forge it and a value read back from the
    ## `EditorSurface` is not it.
    int(gpui_tree_node_count())

  proc gpuiRowNodeCount(d: EditingDocument): int =
    gpui_reset_tree()
    var r: GpuiRenderer
    let parent = r.createElement("div")
    discard renderEditor(r, parent, sourcePaneView(GpuiMediumName).root,
                         editorSurfaceForDocument(d, GpuiMediumName,
                                                  mutableHere = false))
    var stack = @[parent]
    while stack.len > 0:
      let n = stack.pop()
      if n.isNil: continue
      if getAttribute(n, EditorRowAttribute).len > 0:
        inc result
      let kids = childCount(n)
      for i in countdown(kids - 1, 0):
        let c = nthChild(n, i)
        if not c.isNil: stack.add c

# ===========================================================================

suite "PLAT-34: DIFF-1 half 2 — one model change, two observed outputs":

  test "the transaction-kind count is the enum's span":
    var n = 0
    for k in TxKind: inc n
    counted n == TxKindCount

  for kind in TxKind:
    test "a model change is drawn by BOTH front-ends: " & $kind:
      # ONE DOCUMENT, TWO MEDIA, ONE CHANGE. The terminal's buffer and the
      # GPUI front-end's document start from the same bytes and take the same
      # transaction through the same core; what is compared is what each one
      # then DRAWS.
      let buf = newEditBuffer("calc.py", Doc)
      buf.moveCaretTo(1, 8)
      var gd = initEditingDocument("calc.py", Doc)
      gd.moveCaretTo(1, 8)
      # THE ARRANGEMENT IS OUTSIDE THE MEASURED WINDOW. See `arrangeTx`.
      arrangeTx(buf.doc, kind, 5_000)
      arrangeTx(gd, kind, 5_000)

      let tBefore = terminalObserved(buf)
      let gBefore = gpuiObserved(gd)
      counted tBefore.len > 0
      counted gBefore.len > 0
      # §4a, PER CELL AND NOT ONCE. Neither observed output may BE the model's
      # string: the terminal's carries the gutter and the pane's framing, the
      # GPUI tree's carries the source statement and the row glyphs. A reader
      # that quietly returned `d.text` would satisfy every "it changed"
      # assertion below — measured, by the arm that does exactly that — and
      # the whole point of this file is that the change is read from a RUN.
      counted tBefore != buf.doc.text
      counted gBefore != gd.text

      applyTx(buf.doc, kind, 5_000)
      applyTx(gd, kind, 5_000)
      # The model change is the SAME change — asserted, because two media
      # drawing two different edits would also both have changed.
      counted buf.doc.state == gd.state

      let tAfter = terminalObserved(buf)
      let gAfter = gpuiObserved(gd)
      checkpoint("terminal delta: " & $(tAfter != tBefore) &
                 "  gpui delta: " & $(gAfter != gBefore))
      counted tAfter != tBefore
      counted gAfter != gBefore

  # -------------------------------------------------------------------------
  # THE NEGATIVE CONTROL PLAT-21 EARNED — four cases.
  # -------------------------------------------------------------------------

  test "the GPUI side is READ FROM THE SHIM, not from this file's value":
    # `gpui_tree_node_count` is the Rust arena's own count. It is zero after a
    # reset and non-zero after a render, and neither number is computed here.
    var d = initEditingDocument("calc.py", Doc)
    discard gpuiObserved(d)
    let after = gpuiNodeCount()
    checkpoint("shim node count after a render: " & $after)
    counted after > 0

  test "the shim's node count TRACKS THE MODEL":
    # A stub returning a constant satisfies "non-zero" and fails this. The
    # row nodes are counted by their own attribute, so a renderer that drew a
    # fixed number of rows fails too.
    var small = initEditingDocument("a.py", "one\ntwo\n")
    var large = initEditingDocument("a.py", Doc)
    let smallRows = gpuiRowNodeCount(small)
    let largeRows = gpuiRowNodeCount(large)
    checkpoint("row nodes: " & $smallRows & " vs " & $largeRows)
    counted smallRows == small.lineCount
    counted largeRows == large.lineCount
    counted largeRows > smallRows

  test "the terminal side is READ FROM THE PAINTED GRID, not from the model":
    # §4a. The grid's text carries the gutter and the pane's own framing, so
    # it is NOT the model's string — and it contains the model's line, so it
    # is not something else either. Both halves, because either alone is
    # satisfied by the wrong thing.
    let buf = newEditBuffer("calc.py", Doc)
    let painted = terminalObserved(buf)
    counted painted != buf.doc.text
    counted "total = 0" in painted
    counted painted.len > buf.doc.text.len

  test "A BUILD WITH NO RENDERER MUST NOT REPORT [OK]":
    # PLAT-21's control, performed. This file, compiled again with
    # `-d:ctGpuiShimAbsent`, must FAIL — because every `gpui` assertion above
    # reads a tree that is then not there.
    #
    # A MISSING TOOLCHAIN FAILS BY NAME RATHER THAN SKIPPING
    # (Silent-Self-Pass-Audit-2026-08-23.md): a control that detects its own
    # prerequisite is missing, returns early and is counted PASSED is the
    # defect this whole campaign is written against.
    when defined(ctGpuiShimAbsent):
      # The control's own subject does not spawn itself. One level, and the
      # recursion is refused rather than bounded.
      counted true
    else:
      let nim = findExe("nim")
      checkpoint("nim: " & nim)
      counted nim.len > 0
      # **THE CHILD IS COMPILED WITH THIS BUILD'S OWN COMMAND LINE**, read
      # from `std/compilesettings`, plus the define and its own `-o:`.
      #
      # It is read rather than spelled for a reason this case measured: the
      # first spelling passed only `--path:src/frontend/viewmodel` and the
      # child failed to LINK — the `tui` lane supplies a tree-sitter archive
      # and two `-L` flags through `ci/lib/test-lane-files.sh`, and without
      # them a `.nim` importing `isonim_tui` does not build at all. A control
      # whose child fails to compile has a non-zero rc and proves nothing
      # about whether the suite can tell a renderer from its absence, which is
      # why the assertion below is not only on the rc. Reading the parent's
      # own command line makes the two builds differ in exactly one thing.
      let base = querySetting(SingleValueSetting.commandLine)
      counted base.len > 0
      let outBin = getTempDir() / ("plat34-norenderer-" & $getCurrentProcessId())
      # `commandLine` already carries `c -r`, every flag and the source file
      # — measured, not assumed: it comes back as
      # `" c -r --hints:off … -o:<parent> <path>.nim"`.
      #
      # **THE EXTRA FLAGS GO BEFORE THE FILE, AND THAT COST A RUN.** Appending
      # them after the source path produced a child that compiled and passed:
      # nim took `-d:ctGpuiShimAbsent` and the second `-o:` as trailing
      # arguments and built the parent's configuration again, so the control
      # reported "the renderer-less build succeeded" about a build that had a
      # renderer. §4 in the control itself — the instrument measured a
      # different thing and said nothing about it. The split below is asserted
      # rather than assumed, so a change to `commandLine`'s shape fails by
      # name instead of silently rebuilding the parent.
      #
      # A SEPARATE `nimcache` IS NOT TIDINESS: the child differs from the
      # parent by a `-d:`, and sharing a cache directory between two builds
      # that differ in a define is how one of them gets the other's objects.
      let cut = base.strip().rfind(' ')
      counted cut > 0
      # THE LEADING COMMAND WORD IS DROPPED WITH THE FILE. `commandLine` is
      # `" c [-r] <flags…> <path>.nim"`, and `c -r` is supplied explicitly
      # above so the child runs whatever the parent's lane did; leaving the
      # inherited one in would pass `c` twice.
      var flags = base.strip()[0 ..< cut]
      if flags.startsWith("c "): flags = flags[2 .. ^1]
      if flags.startsWith("-r "): flags = flags[3 .. ^1]
      let childFile = base.strip()[cut + 1 .. ^1]
      checkpoint("child file: " & childFile)
      counted childFile.endsWith(".nim")
      counted childFile.endsWith("test_editor_front_end_observed.nim")
      counted not flags.contains(" c ")
      # **`-r` IS ADDED RATHER THAN INHERITED, AND THAT COST A LANE RUN.**
      # `commandLine` carries whatever THIS build was invoked with, and the
      # `tui` lane compiles and runs in two steps — `nim c` with no `-r`, then
      # the artifact. So a child that inherited the flags COMPILED and exited
      # 0 without running a single case, and the control reported "the
      # renderer-less build succeeded" for the second time, by a second route.
      # It is §37a's own rule paying out: the run that caught it is the one
      # where `"[OK] …" in output` failed against an EMPTY output, not the one
      # where `code != 0` did.
      let cmd = quoteShell(nim) & " c -r " & flags &
        " -d:ctGpuiShimAbsent" &
        " --nimcache:" & quoteShell(outBin & "-cache") &
        " -o:" & quoteShell(outBin) & " " & quoteShell(childFile)
      checkpoint(cmd)
      let (output, code) = execCmdEx(cmd)
      checkpoint("rc " & $code)
      # IT MUST FAIL, and it must fail for the RIGHT REASON. A compile error
      # is also a non-zero rc and would prove nothing about the suite's
      # ability to tell a renderer from its absence, so the child is required
      # to have RUN — a case that does not touch the renderer must be green in
      # it — and to have failed in the cases that do.
      counted code != 0
      counted "[OK] the transaction-kind count is the enum's span" in output
      counted "[FAILED]" in output
      counted "a model change is drawn by BOTH front-ends" in output
      counted "the GPUI side is READ FROM THE SHIM" in output
      removeFile(outBin)
      removeDir(outBin & "-cache")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
