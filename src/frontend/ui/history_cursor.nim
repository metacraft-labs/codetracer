## history_cursor.nim — WHICH WAY IS BACK, answered once, in the only place
## that knows.
##
## ## The two inversions this module replaces
##
## Back/forward history navigation was CORRECT on `cloud` and correct only
## because two names lied in opposite directions. Both are recorded here
## because the arrangement was a trap: fixing either one alone shipped a
## product whose Back button went forward, and nothing in the suite could have
## said so.
##
## **Inversion 1 — the parameter.** `ui/debug.nim:552`
##
##     proc handleHistoryJump*(self: DebugComponent, isForward: bool) =
##       if isForward:
##         ... self.historyIndex += 1
##
## `jumpHistory` is appended to by `onCompleteMove`, so `[^1]` is the NEWEST
## entry and `historyIndex` is a 1-based offset from the end. INCREMENTING it
## therefore walks toward entries recorded EARLIER — it is the BACK gesture.
## The parameter named the opposite of what its `true` branch did.
##
## **Inversion 2 — the two call sites, each compensating for inversion 1.**
##
##   * `ui/debug.nim:599-603` mapped `"history-back"` to `isForward = true`
##     and `"history-forward"` to `isForward = false`. A GUI suite already
##     refused to drive these two buttons because of it:
##     `src/tests/gui/tests/debug-controls/toolbar-tooltip-chords.spec.ts:479`
##     — "the two history controls are the subject of a separate, tracked
##     defect ... a test that drove them would be asserting through a
##     known-wrong mapping."
##
##   * `ui/shortcuts.nim:13-14` declared `BROWSER_FORWARD = 3` and
##     `BROWSER_BACK = 4`. Those are backwards: `MouseEvent.button` 3 is the
##     fourth button, which is the platform's BACK, and 4 is the fifth, which
##     is FORWARD. The branch bodies then read consistently with the wrong
##     constants (`BROWSER_FORWARD` -> `isForward = true`), so the mouse path
##     carried its own pair of cancelling errors.
##
## Composition, on both paths: back gesture -> `isForward = true` ->
## `historyIndex += 1` -> an older location. Right answer, twice wrong.
##
## ## Why an enum and not a corrected `bool`
##
## A `bool` named for a USER-FACING VERB has to be read against the array's
## direction every time, and that is the reading that went wrong. `hdOlder` /
## `hdNewer` name the direction the CURSOR moves through `jumpHistory`, which
## is a fact about the sequence and cannot be inverted by an opinion about
## what "forward" means to a person. The verb-to-direction step is what the
## two lookup procs below do, once, where a test can state it.
##
## ## No imports, deliberately
##
## Every caller is inside `ui/`, whose modules pull in Karax, Monaco and the
## Electron bridge and cannot be compiled by a unit lane. Keeping this file
## free of them is what lets `viewmodel/tests/unit/test_history_cursor.nim`
## assert the LOCATION A GESTURE LANDS ON, on both the C and JS backends,
## rather than assert that a command was dispatched.

type
  HistoryDirection* = enum
    ## Which way the cursor moves through `DebugComponent.jumpHistory`.
    ##
    ## Named for the SEQUENCE, not for the gesture. `jumpHistory` grows at the
    ## end, so "older" is toward index 0 and "newer" is toward `[^1]`.
    hdOlder
      ## Toward entries recorded EARLIER. This is what a Back gesture does,
      ## and it raises `historyIndex`, which counts back from the end.
    hdNewer
      ## Toward entries recorded LATER. A Forward gesture; lowers
      ## `historyIndex`.

const
  HistoryBackActionId* = "history-back"
    ## The toolbar button id and the `aHistoryBack` chord's target.
  HistoryForwardActionId* = "history-forward"
    ## The toolbar button id and the `aHistoryForward` chord's target.

  MouseButtonBack* = 3
    ## `MouseEvent.button` for the fourth button — the platform's BACK.
    ## UI Events assigns 3 to the fourth button and every desktop browser puts
    ## Back there; `shortcuts.nim` had this number under the name
    ## `BROWSER_FORWARD`.
  MouseButtonForward* = 4
    ## `MouseEvent.button` for the fifth button — the platform's FORWARD.

proc historyDirectionOfAction*(actionId: string): HistoryDirection =
  ## The direction a debug-toolbar action id moves the cursor.
  ##
  ## Callers must have established that `actionId` is one of the two; there is
  ## no third answer and no sentinel, because a sentinel would let a typo in
  ## the `case` above silently mean "back". `HistoryBackActionId` is the
  ## `else`, so the only way to reach it wrongly is to hand this proc an id it
  ## was never given — which the caller's own `case` prevents.
  if actionId == HistoryForwardActionId: hdNewer
  else: hdOlder

proc historyDirectionOfMouseButton*(button: int): HistoryDirection =
  ## The direction a mouse side-button moves the cursor. Same contract as
  ## `historyDirectionOfAction`: the caller has already matched the button
  ## against `MouseButtonBack` / `MouseButtonForward`.
  if button == MouseButtonForward: hdNewer
  else: hdOlder

proc nextHistoryIndex*(historyLen, historyIndex: int;
                       direction: HistoryDirection): int =
  ## The cursor `historyIndex` becomes, or `0` for REFUSED.
  ##
  ## `0` rather than "clamp to the end", because the two are different
  ## products: a clamp re-issues a jump to the location already showing, which
  ## costs a backend round trip and records a redundant move. Refusing means
  ## the pane does nothing, which is what a browser's greyed-out Back button
  ## does.
  ##
  ## THE BOUNDS ARE THE PRE-MOVE ONES, both stated:
  ##   * `hdOlder` needs an entry beyond the cursor, i.e. `historyIndex` still
  ##     below `historyLen` — at `historyIndex == historyLen` the cursor is on
  ##     the oldest entry, `[^historyLen]`.
  ##   * `hdNewer` needs the cursor off the newest entry, i.e.
  ##     `historyIndex >= 2` — `1` is `[^1]`, where the user already is.
  if historyLen == 0:
    return 0
  case direction
  of hdOlder:
    if historyIndex < historyLen: historyIndex + 1 else: 0
  of hdNewer:
    if historyIndex >= 2: historyIndex - 1 else: 0
