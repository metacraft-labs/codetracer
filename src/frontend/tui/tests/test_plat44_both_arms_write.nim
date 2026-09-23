## PLAT-44 — `DIFF-1` RETAKEN WITH BOTH ARMS WRITING.
##
## PLAT-34's `DIFF-1` (`test_editor_front_end_observed.nim`) drove ONE model
## through the core's named-operation door and read two observed outputs; the
## GPUI arm could only READ. PLAT-44 makes it write, so this suite drives each
## of PLAT-34's eight transaction kinds as REAL KEYS on BOTH arms:
##
##   * the terminal arm: `EditBuffer.applyEditKey` — the shipped key route;
##   * the GPUI arm: `GpuiEditArm.applyGpuiKey`, fed GPUI's OWN keystroke
##     spelling (`"x"` + `shift`, `"z"` + `control`), decoded by
##     `gpui_keys.canonicalKeyOfGpui` — the route a window's keys take.
##
## and reads each arm's OBSERVED OUTPUT, never its model (§4a):
##
## | arm | read | through |
## | --- | --- | --- |
## | terminal | painted cells | `paintEditPane` → `rowText` |
## | gpui | the Rust shadow tree | `renderEditor` → `textContent` |
##
## **THE MODEL COMPARISON IS STILL THE HALF THAT CANNOT FAIL** (PLAT-34's own
## warning, §22/§30a): both arms are thin derivations of one core, so their
## documents agreeing is two reads of one value. It is asserted, and it is not
## the evidence. The evidence is (a) each arm's own observed output moved, and
## showed the changed line, from keys delivered through that arm's own
## decoder; and (b) the renderer-less child below FAILS.
##
## Key sequences are chosen per kind from the models that bind them: the
## product default for insert, newline, backspace, undo and redo; Kakoune for
## the three selection transactions (the product default binds no selection
## keys). The table is asserted against the core: each kind's keys, applied
## in-process, produce the same document as PLAT-34's named operations.
##
## No mocks: the shipped painter, the shipped pane model, the real Rust shim.

import std/[compilesettings, os, osproc, strutils, unittest]

import codetracer_embed

import ../app/edit_binding

when not defined(ctGpuiShimAbsent):
  import isonim_gpui/renderer
  import isonim_gpui/bindings
  import ../../view_vocabulary/pane_views
  import gpui/app/leaves

import gpui/app/edit_arm

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  Doc = "def calc(n):\n    total = 0\n    for i in range(n):\n" &
        "        total += i\n    return total\n"
  GridCols = 72
  GridRows = 16

type
  TxKind = enum
    txInsertChar = "insert a character"
    txInsertNewline = "split a line"
    txDeleteBackward = "delete backward"
    txDeleteSelection = "delete a selection"
    txIndentSelection = "indent a selection"
    txUpperCaseSelection = "upper-case a selection"
    txUndo = "undo"
    txRedo = "redo"

  KeyTx = object
    model: KeymapModel
    arrange: seq[string]
      ## Keys applied BEFORE the before-snapshot (PLAT-34's `arrangeTx`
      ## lesson: an undo whose edit sits inside the window measures nothing).
    keys: seq[string]
      ## The observed transaction, as canonical key names.
    named: seq[(string, OpArgs)]
      ## PLAT-34's named-operation spelling of the same transaction, after the
      ## same arrangement — the cross-check that the key route IS the kind.

const TxKindCount = 8

proc keyTx(kind: TxKind): KeyTx =
  case kind
  of txInsertChar:
    KeyTx(model: kmProductDefault, keys: @["X"],
          named: @[("insert-text", OpArgs(text: "X"))])
  of txInsertNewline:
    # Split mid-line, so the new line has text to find: at column 0 the
    # split's only visible product is an empty line (measured: the first run
    # found nothing to look for).
    KeyTx(model: kmProductDefault, arrange: @["Right", "Right", "Right"],
          keys: @["Enter"], named: @[("insert-newline", OpArgs())])
  of txDeleteBackward:
    KeyTx(model: kmProductDefault, arrange: @["Right"], keys: @["Backspace"],
          named: @[("delete-char-backward", OpArgs())])
  of txDeleteSelection:
    KeyTx(model: kmKakoune, keys: @["w", "d"],
          named: @[("select-group-right", OpArgs()),
                   ("delete-selection", OpArgs())])
  of txIndentSelection:
    KeyTx(model: kmKakoune, keys: @["X", ">"],
          named: @[("select-line", OpArgs()), ("indent-selection", OpArgs())])
  of txUpperCaseSelection:
    KeyTx(model: kmKakoune, keys: @["w", "~"],
          named: @[("select-group-right", OpArgs()), ("upper-case", OpArgs())])
  of txUndo:
    KeyTx(model: kmProductDefault, arrange: @["X"], keys: @["Ctrl+z"],
          named: @[("undo", OpArgs())])
  of txRedo:
    KeyTx(model: kmProductDefault, arrange: @["X", "Ctrl+z"],
          keys: @["Ctrl+y"], named: @[("redo", OpArgs())])

proc gpuiSpelling(name: string): (string, seq[string]) =
  ## How GPUI's `keystroke.key` + modifiers spell a canonical key — written
  ## out, so the GPUI arm's decoder is exercised rather than bypassed.
  case name
  of "Enter": ("enter", @[])
  of "Backspace": ("backspace", @[])
  of "Right": ("right", @[])
  else:
    if name.startsWith("Ctrl+"): (name[5 .. ^1], @["control"])
    elif name.len == 1 and name[0] in 'A'..'Z': ($name[0].toLowerAscii, @["shift"])
    else: (name, @[])

proc terminalObserved(buf: EditBuffer): string =
  ## The terminal's PAINTED CELLS, as `test_editor_front_end_observed.nim`
  ## reads them.
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
  proc gpuiObserved(arm: GpuiEditArm): string = ""
else:
  proc gpuiObserved(arm: GpuiEditArm): string =
    ## The GPUI arm's RUST-SIDE SHADOW TREE, drawn by the function the window
    ## redraws with, from the arm's own (writable) surface.
    gpui_reset_tree()
    var r: GpuiRenderer
    let parent = r.createElement("div")
    discard renderEditor(r, parent, sourcePaneView(GpuiMedium).root,
                         arm.surfaceOf(GridRows))
    textContent(parent)

proc changedLine(before, after: string): string =
  ## The first line of `after` that differs from `before` at the same index —
  ## what the transaction produced, for the "is it DRAWN" assertion.
  let a = before.splitLines()
  let b = after.splitLines()
  for i in 0 ..< b.len:
    if i >= a.len or a[i] != b[i]:
      return b[i].strip()
  ""

suite "PLAT-44: DIFF-1 with both arms writing, from real keys":

  test "the transaction-kind count is the enum's span":
    var n = 0
    for k in TxKind: inc n
    ck n == TxKindCount

  test "each kind's keys ARE the kind: the same document as PLAT-34's named operations":
    for kind in TxKind:
      let tx = keyTx(kind)
      var byKeys = initEditingDocument("doc", Doc, tx.model)
      var byName = initEditingDocument("doc", Doc, tx.model)
      var now = 0'i64
      for k in tx.arrange:
        inc now
        discard byKeys.applyKey(editScopeOf(byKeys), k, now)
        discard byName.applyKey(editScopeOf(byName), k, now)
      for k in tx.keys:
        inc now
        discard byKeys.applyKey(editScopeOf(byKeys), k, now)
      for (op, args) in tx.named:
        inc now
        discard byName.applyNamed(op, args, now)
      checkpoint($kind)
      ck byKeys.state.doc == byName.state.doc
      ck byKeys.state.doc != Doc or kind == txUndo

  for kind in TxKind:
    test "a TYPED " & $kind & " is drawn by BOTH arms":
      let tx = keyTx(kind)
      let term = newEditBuffer("doc", Doc, GridRows, tx.model)
      let arm = newGpuiEditArm("", "doc", Doc, tx.model)
      var now = 0'i64
      for k in tx.arrange:
        inc now
        discard term.applyEditKey(k, now)
        let (key, mods) = gpuiSpelling(k)
        discard arm.applyGpuiKey(key, mods, now)
      let docBefore = term.doc.state.doc
      let termBefore = terminalObserved(term)
      let gpuiBefore = gpuiObserved(arm)
      let keysBefore = arm.keys
      for k in tx.keys:
        inc now
        discard term.applyEditKey(k, now)
        let (key, mods) = gpuiSpelling(k)
        let applied = arm.applyGpuiKey(key, mods, now)
        ck applied.name == k
      let termAfter = terminalObserved(term)
      let gpuiAfter = gpuiObserved(arm)
      let line = changedLine(docBefore, term.doc.state.doc)
      checkpoint("changed line: " & line)
      # Each arm's OWN observed output moved…
      ck termAfter != termBefore
      ck gpuiAfter != gpuiBefore
      # …and shows what the transaction produced.
      ck line.len > 0
      ck line in termAfter
      ck line in gpuiAfter
      # The GPUI arm took every key through its decoder and the core.
      ck arm.keys - keysBefore == tx.keys.len
      # The half that cannot fail, asserted and not relied on.
      ck arm.text == term.doc.state.doc

  test "A BUILD WITH NO RENDERER MUST NOT REPORT [OK]":
    # PLAT-21's control with §37a's repair, as PLAT-34 performs it: this file
    # compiled again with `-d:ctGpuiShimAbsent` must FAIL — having RUN, which
    # the non-renderer cases prove by being green in the child.
    when defined(ctGpuiShimAbsent):
      ck true
    else:
      let nim = findExe("nim")
      ck nim.len > 0
      let base = querySetting(SingleValueSetting.commandLine)
      ck base.len > 0
      let outBin = getTempDir() / ("plat44-norenderer-" & $getCurrentProcessId())
      let cut = base.strip().rfind(' ')
      ck cut > 0
      var flags = base.strip()[0 ..< cut]
      if flags.startsWith("c "): flags = flags[2 .. ^1]
      if flags.startsWith("-r "): flags = flags[3 .. ^1]
      let childFile = base.strip()[cut + 1 .. ^1]
      checkpoint("child file: " & childFile)
      # THE SPLIT IS ASSERTED: the file is last and is this file, and no second
      # `c` survives in the flags — a change to `commandLine`'s shape fails
      # here by name instead of silently rebuilding the parent.
      ck childFile.endsWith("test_plat44_both_arms_write.nim")
      ck not flags.contains(" c ")
      let cmd = quoteShell(nim) & " c -r " & flags &
        " -d:ctGpuiShimAbsent" &
        " --nimcache:" & quoteShell(outBin & "-cache") &
        " -o:" & quoteShell(outBin) & " " & quoteShell(childFile)
      checkpoint(cmd)
      let (output, code) = execCmdEx(cmd)
      checkpoint("rc " & $code)
      ck code != 0
      ck "[OK] the transaction-kind count is the enum's span" in output
      ck "[OK] each kind's keys ARE the kind" in output
      ck "[FAILED] a TYPED insert a character is drawn by BOTH arms" in output
      removeFile(outBin)
      removeDir(outBin & "-cache")

suite "PLAT-44 both arms — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
