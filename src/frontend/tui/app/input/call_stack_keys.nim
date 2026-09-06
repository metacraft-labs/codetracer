## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. Nothing here touches a terminal: this module turns BYTES that
## somebody else read into a decision, and returns a new model.
##
## app/input/call_stack_keys.nim — CTUI-6. Keyboard and mouse navigation for the
## call stack pane.
##
## ## What this module is, and what it deliberately is not
##
## It is a PURE FUNCTION: `(model, token) -> (model', action)`. It reads no
## terminal, installs no handler, owns no state and calls nothing. That is what
## lets every navigation assertion in `tests/test_call_stack_navigation.nim` be
## made in process, and it is why the Tier-2 case can assert that a REAL
## `sendMouseClick` lands on the row this arithmetic predicted rather than
## re-deriving the arithmetic on the other side of the pty.
##
## It is NOT the product's input loop. `main.nim` still has no terminal driver
## (CTUI-3 recorded that, CTUI-5 re-recorded it, and CTUI-9 owns the modal state
## machine and the keymap). What drives this today is the snapshot app
## `tests/apps/app_call_stack.nim`, over a real pty, which is the strongest
## exercise available before CTUI-9 exists.
##
## ## THE MOUSE DECODER MOVED, AND THIS MODULE RE-EXPORTS IT
##
## §4.4 asks that clicking a call frame navigate the source view to that frame,
## and CTUI-6 wrote the SGR-1006 decoder here to answer it. CTUI-8's scrubber
## has the same need — §4.4's "clicking on the timeline scrubber" — so the
## decoder now lives in `app/input/mouse.nim`, which this module imports and
## RE-EXPORTS. Every CTUI-6 call site, `app/tests/test_call_stack_keys.nim`
## included, resolves unchanged; see that module's header for the byte-level
## contract and for why a second copy was the wrong answer.

import std/strutils

import ../views/call_stack
import ./mouse

export mouse

type
  CallStackAction* = enum
    ## What a token did. Returned rather than inferred from a model diff,
    ## because "nothing happened" and "the selection moved back to where it
    ## already was" are different answers for a caller deciding whether to
    ## repaint.
    csaNone
      ## The token was not one of this pane's.
    csaSelectionMoved
      ## The inspection cursor moved. The source view must follow.
    csaSelectionUnchanged
      ## A recognised motion that had nowhere to go — the top of the stack, the
      ## bottom of it. Distinct from `csaNone` so a caller can beep rather than
      ## ignore, and so a test can assert that `k` at frame 0 is a NO-OP rather
      ## than a wrap-around.
    csaGroupToggled
      ## A recursion group was expanded or collapsed.
    csaScrolled
      ## The body scrolled without the selection moving (wheel).

const
  KeyDown* = "j"
  KeyUp* = "k"
  KeyTop* = "g"
    ## The innermost frame (#0) — the frame the debugger is stopped in.
  KeyBottom* = "G"
    ## The outermost frame: the entry point.
  KeyToggleGroup* = "x"
  KeyArrowDown* = "\x1b[B"
  KeyArrowUp* = "\x1b[A"
  KeyPageDown* = "\x1b[6~"
  KeyPageUp* = "\x1b[5~"

  WheelScrollRows* = 3
    ## Rows one wheel notch scrolls. Three is the convention every terminal
    ## multiplexer uses; the number is named so a test can assert the exact
    ## resulting `scrollTop` rather than "it moved".

proc selectFrame*(model: var CallStackModel; frame: int;
                  bodyHeight: int): CallStackAction =
  ## Move the inspection cursor to `frame`, scrolling it into view.
  ##
  ## THE ONLY WRITER OF `selected` IN THIS MODULE, so "selecting a frame never
  ## touches the debugger" is a property of one function rather than of five
  ## call sites that each have to remember it. There is no session here to
  ## touch: this module imports `app/views/call_stack` and `std/strutils` and
  ## nothing else.
  if frame < 0 or frame >= model.frames.len:
    return csaSelectionUnchanged
  if frame == model.selected:
    model.scrollToSelection(bodyHeight)
    return csaSelectionUnchanged
  model.selected = frame
  model.scrollToSelection(bodyHeight)
  csaSelectionMoved

proc moveByRows*(model: var CallStackModel; delta, bodyHeight: int):
    CallStackAction =
  ## Move the cursor `delta` ROWS — so one keystroke crosses a collapsed
  ## recursion in one step rather than in forty-nine.
  ##
  ## Clamped, never wrapped: a cursor that jumped from the entry point back to
  ## the innermost frame would make `j` held down look like the stack was
  ## cycling.
  let rows = model.paneRows()
  if rows.len == 0:
    return csaSelectionUnchanged
  let current = rowOfFrame(rows, model.selected)
  if current < 0:
    return model.selectFrame(0, bodyHeight)
  let target = max(0, min(rows.len - 1, current + delta))
  if target == current:
    return csaSelectionUnchanged
  model.selectFrame(frameOfRow(rows, target), bodyHeight)

proc toggleGroupAtSelection*(model: var CallStackModel;
                             bodyHeight: int): CallStackAction =
  ## Expand or collapse the recursion group holding the selected frame.
  let first = model.groupContaining(model.selected)
  if first < 0:
    return csaNone
  if model.isExpanded(first):
    var kept: seq[int] = @[]
    for g in model.expandedGroups:
      if g != first:
        kept.add g
    model.expandedGroups = kept
    # Collapsing while a member is selected leaves the cursor on the group's
    # innermost frame, which is the row that will be on screen. Leaving it on a
    # member would put the cursor on a frame with no row.
    model.selected = first
  else:
    model.expandedGroups.add first
  model.scrollToSelection(bodyHeight)
  csaGroupToggled

proc scrollBy*(model: var CallStackModel; delta, bodyHeight: int):
    CallStackAction =
  ## Scroll the body without moving the cursor. §4.4: "Mouse scroll wheel:
  ## scrolls the pane beneath the pointer smoothly without requiring pane
  ## focus" — so the wheel deliberately does NOT move the inspection cursor,
  ## and therefore never moves the source view.
  let rows = model.paneRows()
  let before = model.scrollTop
  model.scrollTop = clampScrollTop(model.scrollTop + delta, rows.len,
                                   bodyHeight)
  if model.scrollTop == before: csaSelectionUnchanged else: csaScrolled

proc applyMouse*(model: var CallStackModel; screen: CallStackScreen;
                 event: MouseEvent): CallStackAction =
  ## Apply one decoded mouse report against the pane AS PAINTED.
  ##
  ## Against the painted screen rather than the model, because the row a user
  ## clicked is a fact about what was on the terminal: a model that has since
  ## scrolled would map the same coordinates onto a different frame.
  if event.kind != mekPress:
    # Only the press acts. Acting on both halves of a click would toggle a
    # group twice and land the caller back where it started.
    return csaNone
  # THE COLUMN CHECK COMES FIRST, WHEEL INCLUDED. §4.4: "Mouse scroll wheel:
  # scrolls the pane BENEATH THE POINTER" — a wheel over the source pane must
  # not scroll this one, and a check placed after the wheel branch would let it.
  if event.col < screen.area.col or
     event.col >= screen.area.col + screen.area.width:
    return csaNone
  case event.button
  of mbWheelUp:
    return model.scrollBy(-WheelScrollRows, screen.bodyHeight)
  of mbWheelDown:
    return model.scrollBy(WheelScrollRows, screen.bodyHeight)
  of mbLeft, mbMiddle, mbRight, mbOther:
    discard
  let visibleRow = rowAtScreenRow(screen, event.row)
  if visibleRow < 0:
    return csaNone
  let row = screen.visible[visibleRow]
  if row.kind == cskGroup:
    # Clicking a COLLAPSED group selects it (and shows its innermost frame);
    # clicking an EXPANDED group's header collapses it again, which is the only
    # way back from a 49-row expansion with the mouse alone.
    if row.expanded:
      discard model.selectFrame(row.firstFrame, screen.bodyHeight)
      return model.toggleGroupAtSelection(screen.bodyHeight)
  model.selectFrame(row.firstFrame, screen.bodyHeight)

proc applyKey*(model: var CallStackModel; token: string;
               screen: CallStackScreen): CallStackAction =
  ## Apply one input token — a key, an escape sequence, or an SGR-1006 mouse
  ## report — to the model.
  ##
  ## `screen` is the pane as last painted: the body height every motion clamps
  ## against, and the row map a click resolves through. Passing it in rather
  ## than recomputing it is what keeps "what the user saw" and "what the model
  ## does" the same thing.
  if token.len == 0:
    return csaNone
  let (isMouse, event) = decodeMouse(token)
  if isMouse:
    return model.applyMouse(screen, event)
  let body = max(1, screen.bodyHeight)
  case token
  of KeyDown, KeyArrowDown: model.moveByRows(1, body)
  of KeyUp, KeyArrowUp: model.moveByRows(-1, body)
  of KeyPageDown: model.moveByRows(body, body)
  of KeyPageUp: model.moveByRows(-body, body)
  of KeyTop: model.selectFrame(0, body)
  of KeyBottom: model.selectFrame(model.frames.len - 1, body)
  of KeyToggleGroup: model.toggleGroupAtSelection(body)
  else: csaNone
