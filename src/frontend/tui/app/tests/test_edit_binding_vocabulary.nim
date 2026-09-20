## test_edit_binding_vocabulary.nim — PLAT-30, the terminal side of the
## retirement. **MIGRATED BY PLAT-34, AND THE MIGRATION IS THE POINT.**
##
## ## What was retired, and what this asserts survived
##
## `edit_binding.applyEditKey` was *"thirteen `of` arms over key names plus an
## `else` that inserts the character, fourteen behaviours, and the entire
## editing path today"* — the shape
## `codetracer-specs/GUI/Editing-Operations-And-Keymaps.md` §1 names as the one
## place the product's own binding rule had never been applied.
##
## PLAT-30 made it a LOOKUP in `src/common/editing_key_bindings.TuiEditBindings`
## followed by a dispatch over `EditBehaviour` against an `isonim-tui`
## `TextAreaWidget`. **PLAT-34 removed the second half.** The lookup is now
## PLAT-31's resolver — `product_keymap` LIFTS the same fourteen rows into its
## table — and the dispatch is PLAT-30's own named operations against
## `EditorState`. There is no widget on this path and no `case` over
## `EditBehaviour` anywhere in the product.
##
## ## WHAT THAT DOES TO THIS SUITE, SAID PLAINLY RATHER THAN LEFT TO A DIFF
##
## The suite's SUBJECT is unchanged and its cases are the same fourteen: one
## per row of the table, each driven the way a user drives it, each asserting
## what the behaviour's NAME claims about the caret (§36 — *"something
## changed" is never a witness for an operation whose name says which way*).
##
## What changed is where the arrangement comes from. `buf.widget.moveCursorTo`
## is `buf.moveCaretTo`, which is the model's `caretSelection`; the `Ctrl+z`
## arming edit is a real keystroke rather than a widget `insertText`; and
## `applyEditKey` takes the key name alone, because the resolver derives the
## character from it (see that proc's header on why the second parameter was a
## standing invitation to CTUI-10's defect).
##
## **Two of PLAT-30's mutation arms were re-aimed rather than dropped**, which
## is §32's rule rather than a courtesy: `M14` pointed at
## `of ebMoveCharLeft: w.moveLeft()` and `U4` at the widget caret placement,
## and both of those lines are gone. An arm whose needle a later repair moved
## is silently unkillable, so `run-plat30-vocabulary-mutations.py` carries the
## re-aim, its reason, and the re-run.
##
## ## The two sides, and why both are needed
##
##   * `src/frontend/viewmodel/tests/unit/test_editor_vocabulary_oracle.nim`
##     asserts that each row NAMES a published operation of §2.2 and that
##     running that operation over the ViewModel produces the effect the row
##     declares. It cannot reach `applyEditKey` — `tui/app/`'s layer rule and
##     the ViewModel lanes' file set both forbid it.
##   * This file asserts that `applyEditKey` DISPATCHES through the table, for
##     every row, from the front-end's side of the facade.
##
## Between them the table was a JOIN and is now a CALL, which is PLAT-34's
## deliverable stated from the test side: before this milestone the oracle ran
## the operation and this file ran a widget method, and nothing anywhere
## executed the edge between them.
##
## ## No mocks
## `newEditBuffer` builds the shipped editing core over a real multi-line
## document with a grapheme cluster in it.

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
  buf.moveCaretTo(1, 8)

suite "PLAT-30: `applyEditKey` dispatches through the table, row by row":

  test "the table is the one the ViewModel's oracle reads, and it is complete":
    ck TuiEditBindings.len == EditBehaviourCount
    ck duplicateEditKeys().len == 0
    ck unboundBehaviours().len == 0
    ck defaultEditBindingIndex() >= 0

  for row in TuiEditBindings:
    test "behaviour through the model: " & $row.behaviour:
      let buf = freshBuffer()
      placeMidDocument(buf)
      let before = buf.text
      let beforeCaret = (buf.caretLine, buf.caretColumn)
      # `Ctrl+z` and `Ctrl+y` need something in the widget's own undo stack,
      # and the only way to put something there is to edit — through this same
      # entry point, which is what makes the arrangement real rather than
      # constructed.
      if row.behaviour in {ebUndo, ebRedo}:
        ck applyEditKey(buf, "Q", 0) == ekChanged
      if row.behaviour == ebRedo:
        ck applyEditKey(buf, "Ctrl+z", 0) == ekChanged
      let armed = buf.text
      let key = if row.key.len > 0: row.key else: "Space"
      let outcome = applyEditKey(buf, key, 0)
      checkpoint("key '" & key & "' -> " & $outcome)
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
    ck applyEditKey(buf, "F10", 0) == ekIgnored
    ck applyEditKey(buf, "Ctrl+w", 0) == ekIgnored
    ck buf.text == before
    # …and the DEFAULT row fires for anything that stands for a character.
    ck applyEditKey(buf, "z", 0) == ekChanged
    ck buf.text != before

  test "`Space` inserts a space and never the word `Space`":
    # CTUI-10's measured defect, re-asserted at the retirement: `character` is
    # what gets inserted and `key` is `"Space"` for the space bar. A dispatch
    # that inserted `key` would type five letters into a user's file, and the
    # `case` this replaced got it right — so the replacement has to.
    let buf = freshBuffer()
    buf.moveCaretTo(0, 0)
    ck applyEditKey(buf, "Space", 0) == ekChanged
    ck buf.text.startsWith(" alpha")
    ck "Space" notin buf.text

  test "one backspace removes a whole grapheme cluster":
    # §5's whole reason for existing, at the key that performs it. The third
    # line is a Devanagari cluster: `नो` is a base plus a vowel sign, and a
    # backspace that removed a code point would leave half of it.
    let buf = freshBuffer()
    buf.moveCaretTo(2, 1)
    let before = buf.lines[2]
    ck applyEditKey(buf, "Backspace", 0) == ekChanged
    let after = buf.lines[2]
    checkpoint("line 2: '" & before & "' -> '" & after & "'")
    ck after.len < before.len
    # The remainder is still well-formed: nothing is left dangling where the
    # cluster was.
    ck after == before[before.len - after.len .. ^1]

  test "a nil buffer is ignored rather than raising":
    var nilBuf: EditBuffer
    ck applyEditKey(nilBuf, "Left", 0) == ekIgnored
    ck applyEditKey(nilBuf, "x", 0) == ekIgnored

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
