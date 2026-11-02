## test_edit_binding_vocabulary.nim — PLAT-30, the terminal side of the
## retirement; PLAT-68, the terminal side of the product default's
## replacement by the CUA base keymap.
##
## ## What was retired, twice, and what this asserts survived
##
## `edit_binding.applyEditKey` was *"thirteen `of` arms over key names plus an
## `else` that inserts the character, fourteen behaviours"*. PLAT-30 made it a
## table (`editing_key_bindings.TuiEditBindings`), PLAT-34 put the table behind
## PLAT-31's resolver, and PLAT-68 deleted the table: the default base is CUA
## now, VS Code's editor bindings (`viewmodel/keymap/cua_keymap.nim`).
##
## **THE FOURTEEN ROWS ARE KEPT HERE AS DATA, AND THE CLAIM IS THAT NONE OF
## THEM WAS LOST.** Editing-Operations-And-Keymaps.md §4.4 as amended: *"Every
## one of the fourteen rows has a CUA row with the same chord and either the
## same operation or the VS Code refinement of it (`Home` → `line-start-smart`,
## `Enter` → `insert-newline-and-indent`, `Tab` → insert or indent by
## selection)"*. `viewmodel/tests/unit/test_plat68_base_keymaps.nim` asserts
## that as a statement about the TABLE; this file asserts it through the
## terminal's own entry point, row by row, with what each behaviour's NAME
## claims about the caret — so a key that reached the wrong operation dies
## here even if the table is right.
##
## ## No mocks
## `newEditBuffer` builds the shipped editing core, under the shipped CUA
## base, over a real multi-line document with a grapheme cluster in it.

import std/[strutils, unittest]

import isonim_tui

import ../edit_binding

const ExpectedAssertions = 76
  ## Derived: 2 (the table and the default) + the fourteen rows — 6 each for
  ## the two horizontal moves, `Home` and `End` (operation, outcome, text,
  ## caret moved, two for the direction), 5 each for the vertical moves, 3
  ## each for the six edits, 4 for undo and 5 for redo (their arrangement) —
  ## 63 in all, + 13 for the four trailing cases.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  RetiredClaim = enum
    ## What the retired row's behaviour NAME claimed — the witness.
    rcLeft, rcRight, rcUp, rcDown, rcLineStart, rcLineEnd, rcEdit

  RetiredRow = object
    key: string
      ## The retired row's chord, in this product's canonical spelling; `""`
      ## is the character arm.
    operation: string
      ## The operation the retired row named.
    cuaOperation: string
      ## The operation the CUA base reaches for the same chord — the same
      ## one, or the named refinement.
    claim: RetiredClaim

const
  RetiredRows = [
    ## `editing_key_bindings.TuiEditBindings` at its retirement, row for row.
    RetiredRow(key: "Left", operation: "move-char-left",
               cuaOperation: "move-char-left", claim: rcLeft),
    RetiredRow(key: "Right", operation: "move-char-right",
               cuaOperation: "move-char-right", claim: rcRight),
    RetiredRow(key: "Up", operation: "move-line-up",
               cuaOperation: "move-line-up", claim: rcUp),
    RetiredRow(key: "Down", operation: "move-line-down",
               cuaOperation: "move-line-down", claim: rcDown),
    RetiredRow(key: "Home", operation: "move-line-start",
               cuaOperation: "move-line-start-smart", claim: rcLineStart),
    RetiredRow(key: "End", operation: "move-line-end",
               cuaOperation: "move-line-end", claim: rcLineEnd),
    RetiredRow(key: "Backspace", operation: "delete-char-backward",
               cuaOperation: "delete-char-backward", claim: rcEdit),
    RetiredRow(key: "Delete", operation: "delete-char-forward",
               cuaOperation: "delete-char-forward", claim: rcEdit),
    RetiredRow(key: "Enter", operation: "insert-newline",
               cuaOperation: "insert-newline-and-indent", claim: rcEdit),
    RetiredRow(key: "Tab", operation: "indent-selection",
               cuaOperation: "insert-tab", claim: rcEdit),
    RetiredRow(key: "Shift+Tab", operation: "dedent-selection",
               cuaOperation: "dedent-selection", claim: rcEdit),
    RetiredRow(key: "Ctrl+z", operation: "undo",
               cuaOperation: "undo", claim: rcEdit),
    RetiredRow(key: "Ctrl+y", operation: "redo",
               cuaOperation: "redo", claim: rcEdit),
    RetiredRow(key: "", operation: "insert-text",
               cuaOperation: "insert-text", claim: rcEdit),
  ]

  # A document with an indented line, a blank line and a ZWJ family, so
  # `Home`, `Tab` and `Backspace` each have something real to act on.
  Doc = "alpha beta\n    indented\nनोटे x\n"

proc freshBuffer(): EditBuffer =
  newEditBuffer("/tmp/plat30.txt", Doc)

proc placeMidDocument(buf: EditBuffer) =
  ## Line 1 (`    indented`), eight clusters in — so a motion in either
  ## direction has somewhere to go and `Home` has an indent to stop at.
  buf.moveCaretTo(1, 8)

suite "PLAT-68: the fourteen retired behaviours, through the CUA base":

  test "the retired table had fourteen rows, and the CUA base is the default":
    ck RetiredRows.len == 14
    ck $freshBuffer().doc.model == "cua"

  for row in RetiredRows:
    test "retired behaviour through the terminal: " & row.operation:
      let buf = freshBuffer()
      placeMidDocument(buf)
      let before = buf.text
      let beforeCaret = (buf.caretLine, buf.caretColumn)
      # `Ctrl+z` and `Ctrl+y` need something in the history, and the only way
      # to put something there is to edit — through this same entry point,
      # which is what makes the arrangement real rather than constructed.
      if row.operation in ["undo", "redo"]:
        ck applyEditKey(buf, "Q", 0).outcome == ekChanged
      if row.operation == "redo":
        ck applyEditKey(buf, "Ctrl+z", 0).outcome == ekChanged
      let armed = buf.text
      let key = if row.key.len > 0: row.key else: "Space"
      let applied = applyEditKey(buf, key, 0)
      checkpoint("key '" & key & "' -> " & $applied.outcome & " " &
                 $applied.operations)
      # THE SAME OPERATION OR THE NAMED REFINEMENT — reached through the
      # resolver, from the key.
      ck row.cuaOperation in applied.operations
      case row.claim
      of rcEdit:
        ck applied.outcome == ekChanged
        ck buf.text != armed
      else:
        ck applied.outcome == ekMoved
        ck buf.text == before
        ck (buf.caretLine, buf.caretColumn) != beforeCaret
      # **THE DIRECTION, AND NOT MERELY THAT THE CARET MOVED** (§36): what
      # each behaviour's NAME claims about the caret.
      case row.claim
      of rcLeft:
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn < beforeCaret[1]
      of rcRight:
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn > beforeCaret[1]
      of rcUp:
        ck buf.caretLine < beforeCaret[0]
      of rcDown:
        ck buf.caretLine > beforeCaret[0]
      of rcLineStart:
        # THE REFINEMENT, MEASURED: VS Code's `Home` stops at the first
        # non-blank (column 4 of `    indented`) where the retired row went to
        # column 0.
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn == 4
      of rcLineEnd:
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn > beforeCaret[1]
      of rcEdit:
        discard

  test "a key the table does not bind is handed back, and a CHARACTER is not":
    let buf = freshBuffer()
    placeMidDocument(buf)
    let before = buf.text
    # `F10` is the debugger's, and the editor must hand it back rather than
    # swallow it — §1.1's resolution order, at the one place it is decided.
    ck applyEditKey(buf, "F10", 0).outcome == ekIgnored
    ck applyEditKey(buf, "Ctrl+w", 0).outcome == ekIgnored
    ck buf.text == before
    # …and the character arm fires for anything that stands for a character.
    ck applyEditKey(buf, "z", 0).outcome == ekChanged
    ck buf.text != before

  test "`Space` inserts a space and never the word `Space`":
    # CTUI-10's measured defect, re-asserted at the retirement: `character` is
    # what gets inserted and `key` is `"Space"` for the space bar. A dispatch
    # that inserted `key` would type five letters into a user's file, and the
    # `case` this replaced got it right — so the replacement has to.
    let buf = freshBuffer()
    buf.moveCaretTo(0, 0)
    ck applyEditKey(buf, "Space", 0).outcome == ekChanged
    ck buf.text.startsWith(" alpha")
    ck "Space" notin buf.text

  test "one backspace removes a whole grapheme cluster":
    # §5's whole reason for existing, at the key that performs it. The third
    # line is a Devanagari cluster: `नो` is a base plus a vowel sign, and a
    # backspace that removed a code point would leave half of it.
    let buf = freshBuffer()
    buf.moveCaretTo(2, 1)
    let before = buf.lines[2]
    ck applyEditKey(buf, "Backspace", 0).outcome == ekChanged
    let after = buf.lines[2]
    checkpoint("line 2: '" & before & "' -> '" & after & "'")
    ck after.len < before.len
    # The remainder is still well-formed: nothing is left dangling where the
    # cluster was.
    ck after == before[before.len - after.len .. ^1]

  test "a nil buffer is ignored rather than raising":
    var nilBuf: EditBuffer
    ck applyEditKey(nilBuf, "Left", 0).outcome == ekIgnored
    ck applyEditKey(nilBuf, "x", 0).outcome == ekIgnored

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
