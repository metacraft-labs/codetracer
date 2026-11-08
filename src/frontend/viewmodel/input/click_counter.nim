## input/click_counter.nim — one rule for how many clicks a press is
## (Editor-Pane.md MC.1, Monaco's `MouseDownState.trySetCount`).
##
## A press's count is the smallest of three numbers: the platform's count
## capped at the previous count + 1; 1 if more than the interval has passed
## since the previous press; and the run of presses at the same position. It
## also resets when the button or the element changes, and there is no cap: a
## fourth press is 4.
##
## A front-end supplies what its medium has and compares no times itself. GPUI
## passes `MouseDownEvent.click_count` as `platformCount`; a terminal reports
## single presses, so it passes `NoPlatformCount` and this is the only counter.
##
## Pure, on the C and JavaScript backends: time is an argument.

const
  DefaultMultiClickIntervalMs* = 400
    ## Monaco's `CLEAR_MOUSE_DOWN_COUNT_TIME`, GPUI's Linux
    ## `DOUBLE_CLICK_INTERVAL` and GNOME's default.
  NoPlatformCount* = high(int)
    ## The medium has no count of its own, so that term never limits.

type
  ClickPress* = object
    timeMs*: int64
    button*: int
    element*: string
      ## The editor and the document the press landed on.
    line*, position*: int
      ## The caret boundary the press resolved to, not the pixel.
    platformCount*: int

  ClickCounter* = object
    intervalMs*: int
      ## `pointer.multi-click-interval`. Zero means the default.
    hasPrevious: bool
    previous: ClickPress
    count: int
    run: int
    down: bool

  ClickCount* = object
    count*: int
    duplicate*: bool
      ## The same button pressed at the same position with no release since.
      ## tmux can send a second physical press twice, so this one is not a
      ## press: the caller drops it and the count stays where it was.

func interval(c: ClickCounter): int =
  if c.intervalMs > 0: c.intervalMs else: DefaultMultiClickIntervalMs

proc observe*(c: var ClickCounter; p: ClickPress): ClickCount =
  let samePlace = c.hasPrevious and p.button == c.previous.button and
                  p.element == c.previous.element and
                  p.line == c.previous.line and
                  p.position == c.previous.position
  if c.down and samePlace:
    c.previous.timeMs = p.timeMs
    return ClickCount(count: c.count, duplicate: true)
  let sameTarget = c.hasPrevious and p.button == c.previous.button and
                   p.element == c.previous.element
  var fromPlatform =
    if p.platformCount <= 0: NoPlatformCount else: p.platformCount
  if not sameTarget or p.timeMs - c.previous.timeMs > c.interval.int64:
    fromPlatform = 1
  if fromPlatform > c.count + 1:
    fromPlatform = c.count + 1
  c.run = if samePlace: c.run + 1 else: 1
  c.count = min(fromPlatform, c.run)
  c.previous = p
  c.hasPrevious = true
  c.down = true
  ClickCount(count: c.count)

proc noteRelease*(c: var ClickCounter) =
  ## A release arrived, so the next press at the same place is a new press.
  c.down = false
