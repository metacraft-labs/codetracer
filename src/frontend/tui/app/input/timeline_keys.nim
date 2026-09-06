## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. Nothing here touches a terminal or a debugger: this module turns
## BYTES that somebody else read into a DECISION, and returns it as a value.
##
## app/input/timeline_keys.nim — CTUI-8. §4.2's "Time-Travel Seeking" row:
## `[` / `]` (previous / next call boundary), `{` / `}` (previous / next
## mutation) and `t <tick> Enter` (seek to an absolute tick), plus §4.4's click
## on the scrubber track.
##
## ## IT DECIDES WHERE TO GO; IT NEVER GOES THERE
##
## `applyKey` returns a `TimelineKeyResult` — an action and, for a seek, ONE
## tick. It performs no navigation, holds no session and calls nothing. That
## separation is what makes CTUI-8's central contract assertable: "selecting an
## event issues ONE atomic `goto`" is only checkable if the thing that decides
## the destination and the thing that issues the seek are two things, and the
## suites can then assert that exactly one seek was issued for one keystroke.
##
## It is NOT the product's input loop. `main.nim` still has no terminal driver
## (CTUI-3, CTUI-5, CTUI-6 and CTUI-7 each recorded it; CTUI-9 owns the modal
## state machine). What drives this today is `tests/apps/app_timeline.nim` over
## a real pty, and the Tier-1 suites over a real session.
##
## ## THE TARGETS COME FROM THE BACKEND, AND THIS MODULE INSISTS ON IT
##
## `nextAfter` / `prevBefore` are pure searches over a `seq[uint64]` THE CALLER
## SUPPLIES. `app/timeline_binding.nim` builds it from
## `ct/load-calltrace-section`'s own `rrTicks` — the recorded call boundaries —
## and from the recorded event log's mutation rows. CTUI-8 asks that repeated
## `]` land "on successive call boundaries the backend agrees are boundaries",
## and a module that computed boundaries for itself could not satisfy that
## sentence however carefully it computed them.
##
## The searches do NOT assume the input is sorted. A calltrace section is sorted
## in practice (measured on all three fixtures, 2026-09-06) and an assumption
## that happens to hold is still an assumption; a linear scan for the smallest
## element greater than `current` costs nothing at these sizes and cannot be
## wrong.
##
## ## `t <tick> Enter` IS A MODE, AND THE MODE IS PART OF THE VALUE
##
## §4.2 spells the absolute seek as three keystrokes. So this module carries a
## two-state machine in `TimelineKeyState`, and every transition is an action a
## caller can render and a test can assert: entering it, editing the buffer,
## rejecting a non-digit, cancelling, and committing. A design that swallowed
## the digits silently would make "the user typed 4 and nothing happened"
## indistinguishable from "the user typed 4 and it was accepted".

import std/[strutils]

import ../views/timeline_bar
import ./mouse

export mouse

type
  TimelineAction* = enum
    ## What a token did. Returned rather than inferred from a state diff,
    ## because "not my key" and "my key, nowhere to go" are different answers
    ## for a caller deciding whether to beep.
    tkaNone
      ## The token was not one of this pane's.
    tkaSeek
      ## Seek to `TimelineKeyResult.tick`. The ONE action that moves anything.
    tkaNoTarget
      ## A recognised motion with nowhere to go — no call boundary after the
      ## current tick, no mutation before it. Distinct from `tkaNone` so the
      ## last `]` of a recording is a no-op rather than an unhandled key, and so
      ## a test can assert that it did NOT wrap around to the beginning.
    tkaSeekEntryBegan
    tkaSeekEntryEdited
    tkaSeekEntryCancelled
    tkaSeekEntryRejected
      ## A key that is not a digit, a backspace, `Enter` or `Esc` arrived while
      ## the tick buffer was open. Reported rather than ignored: see the header.

  TimelineKeyMode* = enum
    tkmNormal
    tkmSeekEntry

  TimelineKeyState* = object
    ## The absolute-seek prompt, as a value.
    mode*: TimelineKeyMode
    buffer*: string
      ## The digits typed so far. Never longer than `MaxSeekDigits`.

  TimelineTargets* = object
    ## Where `[`, `]`, `{` and `}` may land, as the BACKEND reported them.
    callBoundaries*: seq[uint64]
    mutations*: seq[uint64]
    minTick*: uint64
    maxTick*: uint64

  TimelineKeyResult* = object
    action*: TimelineAction
    tick*: uint64
      ## Meaningful only when `action == tkaSeek`.

const
  KeyPrevCall* = "["
  KeyNextCall* = "]"
  KeyPrevMutation* = "{"
  KeyNextMutation* = "}"
  KeySeekPrompt* = "t"
  KeyEnter* = "\r"
  KeyEnterLf* = "\n"
  KeyEscape* = "\x1b"
  KeyBackspace* = "\x7f"
  KeyBackspaceCtrlH* = "\b"

  MaxSeekDigits* = 20
    ## `uint64`'s decimal width. A buffer that grew past it could not be parsed
    ## and would make `Enter` fail on input the user could not see was invalid;
    ## the twenty-first digit is REJECTED instead, which is visible.

  SeekPromptPrefix* = ":goto "
    ## What a status bar shows while the buffer is open. Here rather than in a
    ## view because the prompt and the mode are one thing, and CTUI-10 owns the
    ## command line that will render it.

proc initTimelineKeyState*(): TimelineKeyState =
  TimelineKeyState(mode: tkmNormal, buffer: "")

proc promptText*(state: TimelineKeyState): string =
  ## The prompt, or "" in normal mode.
  if state.mode == tkmSeekEntry: SeekPromptPrefix & state.buffer else: ""

proc initTimelineTargets*(callBoundaries: seq[uint64] = @[];
                          mutations: seq[uint64] = @[];
                          minTick = 0'u64;
                          maxTick = 0'u64): TimelineTargets =
  TimelineTargets(callBoundaries: callBoundaries, mutations: mutations,
                  minTick: minTick, maxTick: maxTick)

# ---------------------------------------------------------------------------
# The searches. Pure, order-independent, and never wrapping.
# ---------------------------------------------------------------------------

func nextAfter*(ticks: openArray[uint64]; current: uint64): (bool, uint64) =
  ## The smallest tick strictly greater than `current`.
  ##
  ## STRICTLY, so `]` on a call boundary advances to the NEXT one rather than
  ## re-seeking to where the debugger already is — which would make the key
  ## look broken exactly where it is most likely to be pressed twice.
  var found = false
  var best = 0'u64
  for t in ticks:
    if t > current and (not found or t < best):
      found = true
      best = t
  (found, best)

func prevBefore*(ticks: openArray[uint64]; current: uint64): (bool, uint64) =
  ## The largest tick strictly less than `current`.
  var found = false
  var best = 0'u64
  for t in ticks:
    if t < current and (not found or t > best):
      found = true
      best = t
  (found, best)

func clampToBounds*(tick: uint64; targets: TimelineTargets): uint64 =
  ## A typed tick, held inside the recording.
  ##
  ## Clamped rather than refused: `t 999999 Enter` on a 1314-tick recording
  ## means "the end", which is what every scrubber in every media player does,
  ## and a refusal would be indistinguishable from the key not working.
  if targets.maxTick <= targets.minTick:
    return targets.minTick
  if tick < targets.minTick: targets.minTick
  elif tick > targets.maxTick: targets.maxTick
  else: tick

# ---------------------------------------------------------------------------
# Keys
# ---------------------------------------------------------------------------

proc seekTo(tick: uint64): TimelineKeyResult =
  TimelineKeyResult(action: tkaSeek, tick: tick)

proc noTarget(): TimelineKeyResult =
  TimelineKeyResult(action: tkaNoTarget, tick: 0'u64)

proc applySeekEntryKey(state: var TimelineKeyState; token: string;
                       targets: TimelineTargets): TimelineKeyResult =
  ## One token while the tick buffer is open.
  if token == KeyEnter or token == KeyEnterLf:
    let typed = state.buffer
    state.mode = tkmNormal
    state.buffer = ""
    if typed.len == 0:
      # `t` then `Enter` is a cancel, not a seek to tick 0. Seeking to the
      # beginning on an empty buffer would make a mistyped keystroke throw away
      # the user's position.
      return TimelineKeyResult(action: tkaSeekEntryCancelled, tick: 0'u64)
    var value: uint64
    try:
      value = parseBiggestUInt(typed)
    except ValueError:
      return TimelineKeyResult(action: tkaSeekEntryRejected, tick: 0'u64)
    return seekTo(clampToBounds(value, targets))
  if token == KeyEscape:
    state.mode = tkmNormal
    state.buffer = ""
    return TimelineKeyResult(action: tkaSeekEntryCancelled, tick: 0'u64)
  if token == KeyBackspace or token == KeyBackspaceCtrlH:
    if state.buffer.len == 0:
      # Backspace on an empty buffer leaves the prompt, which is what every
      # shell does and what makes the prompt escapable without `Esc`.
      state.mode = tkmNormal
      return TimelineKeyResult(action: tkaSeekEntryCancelled, tick: 0'u64)
    state.buffer.setLen(state.buffer.len - 1)
    return TimelineKeyResult(action: tkaSeekEntryEdited, tick: 0'u64)
  if token.len == 1 and token[0] in Digits:
    if state.buffer.len >= MaxSeekDigits:
      return TimelineKeyResult(action: tkaSeekEntryRejected, tick: 0'u64)
    state.buffer.add token
    return TimelineKeyResult(action: tkaSeekEntryEdited, tick: 0'u64)
  TimelineKeyResult(action: tkaSeekEntryRejected, tick: 0'u64)

proc applyKey*(state: var TimelineKeyState; token: string;
               targets: TimelineTargets;
               currentTick: uint64): TimelineKeyResult =
  ## Apply one input token — a key or an escape sequence — to the timeline.
  ##
  ## `targets` is what the BACKEND said about this recording and `currentTick`
  ## is where the debugger is; both are passed in rather than remembered, so two
  ## keystrokes at two positions are two calls with no state between them but
  ## the seek prompt.
  if token.len == 0:
    return TimelineKeyResult(action: tkaNone, tick: 0'u64)
  if state.mode == tkmSeekEntry:
    return applySeekEntryKey(state, token, targets)
  case token
  of KeySeekPrompt:
    state.mode = tkmSeekEntry
    state.buffer = ""
    TimelineKeyResult(action: tkaSeekEntryBegan, tick: 0'u64)
  of KeyNextCall:
    let (found, tick) = nextAfter(targets.callBoundaries, currentTick)
    if found: seekTo(tick) else: noTarget()
  of KeyPrevCall:
    let (found, tick) = prevBefore(targets.callBoundaries, currentTick)
    if found: seekTo(tick) else: noTarget()
  of KeyNextMutation:
    let (found, tick) = nextAfter(targets.mutations, currentTick)
    if found: seekTo(tick) else: noTarget()
  of KeyPrevMutation:
    let (found, tick) = prevBefore(targets.mutations, currentTick)
    if found: seekTo(tick) else: noTarget()
  else:
    TimelineKeyResult(action: tkaNone, tick: 0'u64)

# ---------------------------------------------------------------------------
# The mouse
# ---------------------------------------------------------------------------

proc applyMouse*(screen: TimelineBarScreen; model: TimelineBarModel;
                 event: MouseEvent): TimelineKeyResult =
  ## §4.4: "Clicking on the timeline scrubber: seeks the execution pointer
  ## directly to the clicked time ratio."
  ##
  ## Against the scrubber AS PAINTED rather than against the model, for the
  ## reason CTUI-6 recorded for `call_stack_keys.applyMouse`: the cell a user
  ## clicked is a fact about what was on the terminal, and a model that has
  ## since been repainted at another width would map the same coordinates onto
  ## another tick.
  if event.kind != mekPress:
    # Only the press acts. Acting on both halves of one click would issue TWO
    # seeks for one click — and "one click, one atomic goto" is this
    # milestone's contract.
    return TimelineKeyResult(action: tkaNone, tick: 0'u64)
  if event.button != mbLeft and event.button != mbMiddle and
     event.button != mbRight:
    return TimelineKeyResult(action: tkaNone, tick: 0'u64)
  let column = trackColumnAt(screen, event.row, event.col)
  if column < 0:
    return TimelineKeyResult(action: tkaNone, tick: 0'u64)
  if not model.boundsKnown:
    return noTarget()
  seekTo(tickForColumn(column, model.minTick, model.maxTick,
                       screen.trackWidth))

proc applyToken*(state: var TimelineKeyState; token: string;
                 screen: TimelineBarScreen; model: TimelineBarModel;
                 targets: TimelineTargets;
                 currentTick: uint64): TimelineKeyResult =
  ## One token of any kind: an SGR-1006 mouse report, or a key.
  ##
  ## The single entry point a driver uses, so a driver cannot forget to try the
  ## mouse decoder first — which would make every mouse report land in
  ## `applyKey`'s `else` branch and silently do nothing.
  let (isMouse, event) = decodeMouse(token)
  if isMouse:
    return applyMouse(screen, model, event)
  applyKey(state, token, targets, currentTick)
