## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. Nothing here touches a terminal: this module turns BYTES that
## somebody else read into a value.
##
## app/input/mouse.nim — the SGR-1006 decoder, extracted by CTUI-8 from
## `app/input/call_stack_keys.nim` where CTUI-6 wrote it.
##
## ## Why it moved
##
## CTUI-8's scrubber has its own mouse contract — §4.4's "clicking on the
## timeline scrubber seeks the execution pointer directly to the clicked time
## ratio" — and `app/input/timeline_keys.nim` needs exactly this decoder. The
## alternatives were for `timeline_keys` to import `call_stack_keys` (and with
## it the whole call stack pane, for four types and one function) or to carry a
## second copy of the same byte arithmetic. Two decoders of one protocol is two
## things to keep true, and the off-by-one below is precisely the kind of detail
## that gets fixed in one copy.
##
## `call_stack_keys` imports and RE-EXPORTS this module, so every CTUI-6 call
## site — including `app/tests/test_call_stack_keys.nim`, which asserts the
## decoder against the exact bytes TermAssert writes — resolves unchanged.
##
## ## THE DECODER IS WRITTEN AGAINST THE BYTES
##
## `TermAssert.sendMouseClick(row, col)` writes
##
##     ESC [ < <button> ; <col+1> ; <row+1> M      (press)
##     ESC [ < <button> ; <col+1> ; <row+1> m      (release)
##
## (`TermAssert/src/term_assert.nim`, `sendMouseClick`) — SGR 1006, 1-BASED on
## the wire, and that off-by-one is the whole reason this decoder returns
## 0-based coordinates and says so in its type. `isonim_tui` ships a full input
## parser (`inputParser`, over nim-termctl) which the product's loop will almost
## certainly use; it is not used here because this module must be callable on a
## `string` a test wrote, with no parser state to carry, and because a decoder
## whose output is compared against the exact bytes the harness writes is
## checkable in a way a delegation is not.
##
## Wheel events arrive on the same protocol as buttons 64 and 65, which is why
## scrolling is decoded here rather than in a second module.

import std/strutils

type
  MouseButton* = enum
    mbLeft
    mbMiddle
    mbRight
    mbWheelUp
    mbWheelDown
    mbOther

  MouseEventKind* = enum
    mekPress
    mekRelease

  MouseEvent* = object
    ## One decoded SGR-1006 report, in ZERO-BASED screen coordinates.
    kind*: MouseEventKind
    button*: MouseButton
    row*: int
    col*: int

proc decodeMouse*(token: string): (bool, MouseEvent) =
  ## Decode one SGR-1006 report. `(false, _)` when `token` is not one.
  ##
  ## Returns a tuple rather than raising or returning an `Option`, so a caller
  ## in a byte loop neither pays for an exception nor imports `std/options` to
  ## ask a yes/no question.
  var event = MouseEvent(kind: mekPress, button: mbOther, row: -1, col: -1)
  if token.len < 9 or not token.startsWith("\x1b[<"):
    return (false, event)
  let final = token[^1]
  if final != 'M' and final != 'm':
    return (false, event)
  let fields = token[3 ..< token.len - 1].split(';')
  if fields.len != 3:
    return (false, event)
  var code, col, row: int
  try:
    code = parseInt(fields[0])
    col = parseInt(fields[1])
    row = parseInt(fields[2])
  except ValueError:
    return (false, event)
  # The low two bits are the button; bits 2-4 are shift/alt/ctrl; bit 6 (64) is
  # the wheel flag. Modifiers are decoded away rather than rejected, so a
  # ctrl-click is still a click on the row it happened on.
  event.kind = if final == 'M': mekPress else: mekRelease
  event.button =
    if (code and 64) != 0:
      if (code and 1) == 0: mbWheelUp else: mbWheelDown
    else:
      case code and 3
      of 0: mbLeft
      of 1: mbMiddle
      of 2: mbRight
      else: mbOther
  # 1-BASED ON THE WIRE. See this module's header.
  event.row = row - 1
  event.col = col - 1
  (true, event)
