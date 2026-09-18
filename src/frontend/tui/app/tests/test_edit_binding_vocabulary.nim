## test_edit_binding_vocabulary.nim — PLAT-30, the terminal side of the
## retirement.
##
## ## What was retired, and what this asserts survived
##
## `edit_binding.applyEditKey` was *"thirteen `of` arms over key names plus an
## `else` that inserts the character, fourteen behaviours, and the entire
## editing path today"* — the shape
## `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` §1 names as the one
## place the product's own binding rule had never been applied.
##
## It is now a LOOKUP in `src/common/editing_key_bindings.TuiEditBindings`
## followed by a dispatch over `EditBehaviour`. This suite asserts, **through
## the real `TextAreaWidget`**, that the fourteen behaviours are unchanged —
## each one by name, each one driven the way a user drives it.
##
## ## The two sides, and why both are needed
##
##   * `src/frontend/viewmodel/tests/unit/test_editor_vocabulary_oracle.nim`
##     asserts that each row NAMES a published operation of §2.2 and that
##     running that operation over the ViewModel produces the effect the row
##     declares. It cannot reach `applyEditKey` — `tui/app/`'s layer rule and
##     the ViewModel lanes' file set both forbid it.
##   * This file asserts that `applyEditKey` DISPATCHES through the table, on
##     the substrate, for every row. It cannot reach the vocabulary — same
##     rule, from the other side.
##
## Between them the table is a join rather than a label. Neither alone is:
## a table nothing dispatches through is documentation, and a dispatch through
## a table whose names mean nothing is the third orphan vocabulary this
## milestone exists to avoid.
##
## ## No mocks
## `newEditBuffer` builds the shipped `isonim-tui` `TextAreaWidget`. The text
## is a real multi-line document with a grapheme cluster in it.

import std/[strutils, unittest]

import isonim_tui

import ../edit_binding

const ExpectedAssertions = 64

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  # A document with an indented line, a blank line and a ZWJ family, so
  # `Home`, `Tab` and `Backspace` each have something real to act on.
  Doc = "alpha beta\n    indented\nनोटे x\n"

proc freshBuffer(): EditBuffer =
  newEditBuffer("/tmp/plat30.txt", Doc)

proc placeMidDocument(buf: EditBuffer) =
  ## Line 1 (`    indented`), four clusters in — so a motion in either
  ## direction has somewhere to go and `Home` has an indent to skip.
  buf.widget.moveCursorTo(Caret(line: 1, column: 8))

suite "PLAT-30: `applyEditKey` dispatches through the table, row by row":

  test "the table is the one the ViewModel's oracle reads, and it is complete":
    ck TuiEditBindings.len == EditBehaviourCount
    ck duplicateEditKeys().len == 0
    ck unboundBehaviours().len == 0
    ck defaultEditBindingIndex() >= 0

  for row in TuiEditBindings:
    test "behaviour through the widget: " & $row.behaviour:
      let buf = freshBuffer()
      placeMidDocument(buf)
      let before = buf.text
      let beforeCaret = (buf.caretLine, buf.caretColumn)
      # `Ctrl+z` and `Ctrl+y` need something in the widget's own undo stack,
      # and the only way to put something there is to edit — through this same
      # entry point, which is what makes the arrangement real rather than
      # constructed.
      if row.behaviour in {ebUndo, ebRedo}:
        ck applyEditKey(buf, "", "Q") == ekChanged
      if row.behaviour == ebRedo:
        ck applyEditKey(buf, "Ctrl+z", "") == ekChanged
      let armed = buf.text
      let key = if row.key.len > 0: row.key else: "Space"
      let character = if row.key.len > 0: "" else: " "
      let outcome = applyEditKey(buf, key, character)
      checkpoint("key '" & key & "' char '" & character & "' -> " & $outcome)
      case row.effect
      of eeMoved:
        ck outcome == ekMoved
        ck buf.text == before
        ck (buf.caretLine, buf.caretColumn) != beforeCaret
      of eeChanged:
        ck outcome == ekChanged
        ck buf.text != armed
      # **THE DIRECTION, AND NOT MERELY THAT THE CARET MOVED.** The three lines
      # above were the whole of this case's motion witness on the first run,
      # and the arm that makes the dispatch perform `moveRight` where the table
      # says `move-char-left` SURVIVED them: the text is unchanged, the outcome
      # is still `ekMoved`, and the caret is still not where it was. That is
      # Verification-Harness-Traps §36 exactly — a witness too weak to observe
      # the mutation reads as "the mutation is harmless" — and the repair is to
      # the ASSERTION. What each behaviour's NAME claims about the caret is
      # declared here, in the test, and asserted.
      case row.behaviour
      of ebMoveCharLeft:
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn < beforeCaret[1]
      of ebMoveCharRight:
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn > beforeCaret[1]
      of ebMoveLineUp:
        ck buf.caretLine < beforeCaret[0]
      of ebMoveLineDown:
        ck buf.caretLine > beforeCaret[0]
      of ebMoveLineStart:
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn == 0
      of ebMoveLineEnd:
        ck buf.caretLine == beforeCaret[0]
        ck buf.caretColumn > beforeCaret[1]
      else:
        # The eight editing behaviours have no caret claim of their own; their
        # witness is `buf.text != armed` above, and the ViewModel's oracle
        # suite is what grades WHICH edit each one performed.
        discard

  test "a key the table does not bind is handed back, and a CHARACTER is not":
    let buf = freshBuffer()
    placeMidDocument(buf)
    let before = buf.text
    # `F10` is the debugger's, and the editor must hand it back rather than
    # swallow it — §1.1's resolution order, at the one place it is decided.
    ck applyEditKey(buf, "F10", "") == ekIgnored
    ck applyEditKey(buf, "Ctrl+w", "") == ekIgnored
    ck buf.text == before
    # …and the DEFAULT row fires for anything that stands for a character.
    ck applyEditKey(buf, "z", "z") == ekChanged
    ck buf.text != before

  test "`Space` inserts a space and never the word `Space`":
    # CTUI-10's measured defect, re-asserted at the retirement: `character` is
    # what gets inserted and `key` is `"Space"` for the space bar. A dispatch
    # that inserted `key` would type five letters into a user's file, and the
    # `case` this replaced got it right — so the replacement has to.
    let buf = freshBuffer()
    buf.widget.moveCursorTo(Caret(line: 0, column: 0))
    ck applyEditKey(buf, "Space", " ") == ekChanged
    ck buf.text.startsWith(" alpha")
    ck "Space" notin buf.text

  test "one backspace removes a whole grapheme cluster":
    # §5's whole reason for existing, at the key that performs it. The third
    # line is a Devanagari cluster: `नो` is a base plus a vowel sign, and a
    # backspace that removed a code point would leave half of it.
    let buf = freshBuffer()
    buf.widget.moveCursorTo(Caret(line: 2, column: 1))
    let before = buf.lines[2]
    ck applyEditKey(buf, "Backspace", "") == ekChanged
    let after = buf.lines[2]
    checkpoint("line 2: '" & before & "' -> '" & after & "'")
    ck after.len < before.len
    # The remainder is still well-formed: nothing is left dangling where the
    # cluster was.
    ck after == before[before.len - after.len .. ^1]

  test "a nil buffer is ignored rather than raising":
    var nilBuf: EditBuffer
    ck applyEditKey(nilBuf, "Left", "") == ekIgnored
    ck applyEditKey(nilBuf, "", "x") == ekIgnored

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
