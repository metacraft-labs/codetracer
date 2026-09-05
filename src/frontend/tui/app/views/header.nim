## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/header.nim — CTUI-3. The session header of
## CodeTracer-TUI.md §3.3.1.
##
## ## Everything here is a pure function of a value
##
## `headerText(model, width)` returns a string of EXACTLY `width` cells. No
## renderer, no signal, no ViewModel: the header is decided from a
## `HeaderModel` and nothing else, for the same reason CTUI-3 asks profile
## selection to be a pure function. A string can be asserted exactly; a screen
## region can then be asserted to EQUAL it; and a failure lands on one side of
## that line rather than between them.
##
## `app/tui_app.nim` is what fills a `HeaderModel` in from a `HeadlessApp`, so
## this module never learns that a debugger exists.
##
## ## WIDTH IS COUNTED IN CELLS, NOT IN BYTES OR RUNES
##
## A trace file name can hold a CJK character, which is one rune and TWO cells.
## `fitCells` measures with `isonim_tui`'s `displayWidth` — the same table the
## compositor and the terminal agree on, which CTUI-2 established by finding
## the place they did not. Padding computed from `len` would be one byte per
## multi-byte character short and the status badge would drift off the right
## edge of the screen; padding computed from `runeLen` would be one cell short
## per wide glyph, which is the subtler half of the same bug.

import std/[strutils, unicode]

import isonim_tui

type
  ExecutionStatus* = enum
    ## §3.3.1's status badge. The five the specification names, spelled as they
    ## appear on screen so the enum and the header cannot drift apart.
    esPaused = "PAUSED"
    esStepping = "STEPPING"
    esReversing = "REVERSING"
    esSeeking = "SEEKING"
    esTerminated = "TERMINATED"

  SessionTab* = object
    ## One entry of the §3.3.1 session tab strip.
    title*: string
    active*: bool

  HeaderModel* = object
    ## Everything the header row shows, as a value.
    traceName*: string
      ## The trace container's file name, or the origin transaction hash.
    targetArch*: string
      ## `x86_64`, `aarch64`, `wasm32`, `evm`, ...
    recordingKind*: string
      ## The recorder that produced the trace (`native`, `ruby`, `noir`, ...).
      ## Empty when unknown, and then simply omitted rather than shown as an
      ## empty field — a header reading `kind:` with nothing after it is worse
      ## than one that does not mention the kind.
    status*: ExecutionStatus
    tick*: int
    totalTicks*: int
    sessions*: seq[SessionTab]

const
  HeaderPrefix* = "[ct]"
    ## The product mark §3.1's Compact drawing opens the header with.

proc initHeaderModel*(traceName = ""; targetArch = ""; recordingKind = "";
                      status = esPaused; tick = 0; totalTicks = 0):
    HeaderModel =
  ## A header with no sessions. Named rather than built inline so the default
  ## for every field lives in one place.
  HeaderModel(traceName: traceName, targetArch: targetArch,
              recordingKind: recordingKind, status: status, tick: tick,
              totalTicks: totalTicks, sessions: @[])

proc textCells*(s: string): int =
  ## How many terminal cells `s` occupies. One call site for the width table,
  ## so a view cannot accidentally use `len`.
  displayWidth(s)

proc fitCells*(s: string; width: int): string =
  ## `s` truncated or space-padded to exactly `width` cells.
  ##
  ## Truncation is by RUNE with a cell budget, so a wide glyph that would
  ## straddle the last column is dropped rather than half-drawn — a half-drawn
  ## wide glyph is the one thing a compositor and a terminal reliably disagree
  ## about, which is the defect CTUI-2's first run found in isonim-tui.
  if width <= 0:
    return ""
  var fitted = ""
  var used = 0
  for r in runes(s):
    let w = displayWidth($r)
    if used + w > width:
      break
    fitted.add $r
    used += w
  if used < width:
    fitted.add spaces(width - used)
  fitted

proc groupThousands*(n: int): string =
  ## `1420` -> `1,420`. §3.3.1 shows tick counters grouped, and a nine-digit
  ## tick with no separators is the difference between a number a reader can
  ## compare at a glance and one they have to count.
  let digits = $abs(n)
  var grouped = ""
  for i, ch in digits:
    if i > 0 and (digits.len - i) mod 3 == 0:
      grouped.add ','
    grouped.add ch
  if n < 0: "-" & grouped else: grouped

proc tickCoordinates*(m: HeaderModel): string =
  ## `tick: 1,420 / 8,950 [15.8%]` — §3.3.1's time coordinates.
  ##
  ## The percentage is omitted when the total is unknown rather than shown as
  ## `[0.0%]`, because "we do not know how long the recording is" and "you are
  ## at the very beginning" are different facts and a reader would act on them
  ## differently.
  result = "tick: " & groupThousands(m.tick)
  if m.totalTicks > 0:
    result.add " / " & groupThousands(m.totalTicks)
    let pct = 100.0 * float(m.tick) / float(m.totalTicks)
    result.add " [" & formatFloat(pct, ffDecimal, 1) & "%]"

proc sessionTabsText*(m: HeaderModel): string =
  ## The §3.3.1 tab strip: the active session in brackets, the rest bare.
  ##
  ## Empty for a single session, on purpose. Tabs that are always drawn make
  ## "one session" and "the tab strip failed to render" the same picture, and
  ## the specification says tabs appear "when multiple trace sessions are
  ## loaded".
  if m.sessions.len < 2:
    return ""
  var parts: seq[string] = @[]
  for s in m.sessions:
    parts.add(if s.active: "[" & s.title & "]" else: " " & s.title & " ")
  parts.join("")

type HeaderDetail* = enum
  ## How much of the header is shown. Not a style — a WIDTH BUDGET, applied in
  ## this order as the terminal narrows.
  ##
  ## Degrading field by field rather than truncating the whole line is what
  ## keeps the tick counter readable at 80 columns: §3.1's own Compact drawing
  ## shows `trace`, `arch` and `tick` and no recording kind, and a line cut at
  ## the right edge would have lost the total tick count instead of the field
  ## the drawing itself omits.
  hdFull          ## every field, and the percentage
  hdNoKind        ## drop the recording kind
  hdNoArch        ## drop the target architecture too
  hdTickOnly      ## drop everything but the mark, the trace and the ticks

proc headerFields*(m: HeaderModel; detail = hdFull): seq[string] =
  ## The header's fields, in order, before any width is applied.
  ##
  ## Exposed so a test can assert what the header WOULD say independently of
  ## how much of it fits — otherwise a narrow terminal and a missing field are
  ## the same observation.
  result = @[HeaderPrefix]
  result.add "trace: " & (if m.traceName.len > 0: m.traceName else: "-")
  if detail <= hdNoKind and m.targetArch.len > 0:
    result.add "arch: " & m.targetArch
  if detail <= hdFull and m.recordingKind.len > 0:
    result.add "kind: " & m.recordingKind
  if detail == hdTickOnly:
    result.add "tick: " & groupThousands(m.tick) &
      (if m.totalTicks > 0: " / " & groupThousands(m.totalTicks) else: "")
  else:
    result.add tickCoordinates(m)

proc headerText*(m: HeaderModel; width: int): string =
  ## The header row, exactly `width` cells wide.
  ##
  ## The status badge is RIGHT-ALIGNED and is the last thing dropped: it is the
  ## one field whose absence changes what a user believes about the program's
  ## state, so on a narrow terminal the trace path is truncated before the
  ## badge is. The tab strip sits between them and is dropped first.
  if width <= 0:
    return ""
  let badge = "[" & $m.status & "]"
  let tabs = sessionTabsText(m)

  if textCells(badge) >= width:
    return fitCells(badge, width)
  let room = width - textCells(badge)

  # The widest detail level that still fits, then the tab strip if there is
  # room left for it. `hdTickOnly` is the floor; below that the line is simply
  # truncated, which is the only remaining option.
  var line = headerFields(m, hdTickOnly).join(" | ")
  for detail in [hdFull, hdNoKind, hdNoArch]:
    let candidate = headerFields(m, detail).join(" | ")
    if textCells(candidate) + 1 <= room:
      line = candidate
      break
  if tabs.len > 0 and textCells(line) + 2 + textCells(tabs) + 1 <= room:
    line.add "  " & tabs
  fitCells(fitCells(line, max(0, room - 1)) & " ", room) & badge
