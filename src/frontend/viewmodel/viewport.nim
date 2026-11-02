## viewport.nim — how a view tells a ViewModel the size it was
## given, and how a ViewModel turns that into a windowed request.
##
## Viewport-Driven-Loading.md V1-V2. A ViewModel cannot know the screen, and a
## view must not fetch; so every view reports one `Viewport` — in the pane's
## own units, never pixels — and every windowed ViewModel derives its request
## window from it with the policy below. The conversion from a medium's units
## (pixels, terminal cells, editor lines) is the view binding's job.
##
## THE WINDOW is the Electron GUI's call-trace policy, which the spec makes the
## policy of every windowed list (Viewport-Driven-Loading Q1): up to
## `TrailRows` rows before the first visible one and `LeadRows` after the last
## (`ui/calltrace.nim`'s `START_BUFFER = 10` and `CALL_BUFFER = 20`).
##
## THE DEBOUNCE (UI-Data-Loading-Guidelines Pattern 6): consecutive reports
## within `ViewportDebounceMs` produce one request. The timer is INJECTED
## (`ViewportScheduler`), so a suite can drive it from a `TestClock`. The default
## applies a report at once: native hosts report a viewport only when a layout
## is committed, and a host that reports continuously (the DOM's
## `ResizeObserver` and scroll listener) installs `timeoutScheduler`.
##
## Works on both the C and JS backends.

type
  Viewport* = object
    ## What a view was given, in the pane's own units — rows for a list,
    ## lines for source. A ViewModel never sees pixels.
    rows*: int
      ## Visible rows; 0 = not yet measured. An unmeasured viewport issues no
      ## windowed request.
    cols*: int
      ## Visible columns where depth or width matters (call-trace depth,
      ## value truncation); 0 = unknown.
    firstRow*: int
      ## The first visible row — the scroll position.

  RowWindow* = object
    ## The rows a ViewModel asks the backend for.
    start*: int
    count*: int

  ViewportScheduler* = ref object
    ## The injected timer a ViewModel debounces with.
    schedule*: proc(delayMs: float64; callback: proc()): int
      ## Run `callback` after `delayMs`; returns an id for `cancel`.
    cancel*: proc(id: int)

  ViewportGate* = ref object
    ## One windowed ViewModel's debounce: the latest report wins, and it is
    ## applied once the reports stop for `ViewportDebounceMs`.
    schedulerOf: proc(): ViewportScheduler
      ## Read when a report arrives, so a host may install its timer after
      ## the ViewModel exists.
    scheduler: ViewportScheduler
      ## The timer the report now waiting was scheduled on.
    timer: int
    hasTimer: bool
    pending: Viewport
    apply: proc(v: Viewport)

const
  LeadRows* = 20
    ## Rows asked for after the last visible one (`CALL_BUFFER`).
  TrailRows* = 10
    ## Rows asked for before the first visible one (`START_BUFFER`).
  ViewportDebounceMs* = 100.0
    ## Reports closer together than this are one report (Pattern 6).

func measured*(v: Viewport): bool =
  ## Whether a view has reported a size. An unmeasured viewport issues no
  ## windowed request (V2).
  v.rows > 0

func scrolledTo*(v: Viewport; firstRow: int): Viewport =
  ## `v` with its first visible row moved to `firstRow` (clamped at 0).
  result = v
  result.firstRow = max(0, firstRow)

func withRows*(v: Viewport; rows: int): Viewport =
  ## `v` with `rows` visible rows.
  result = v
  result.rows = max(0, rows)

func withCols*(v: Viewport; cols: int): Viewport =
  ## `v` with `cols` visible columns.
  result = v
  result.cols = max(0, cols)

func listWindow*(v: Viewport): RowWindow =
  ## The window a windowed list asks for: `TrailRows` before the first visible
  ## row (fewer at the top) and `LeadRows` after the last. Empty for an
  ## unmeasured viewport.
  if not v.measured:
    return RowWindow(start: 0, count: 0)
  let first = max(0, v.firstRow)
  let start = first - min(first, TrailRows)
  RowWindow(start: start, count: v.rows + LeadRows + (first - start))

func covers*(held: RowWindow; wanted: RowWindow): bool =
  ## Whether the rows already held contain every row `wanted` asks for.
  wanted.count <= 0 or
    (wanted.start >= held.start and
     wanted.start + wanted.count <= held.start + held.count)

# ---------------------------------------------------------------------------
# Schedulers
# ---------------------------------------------------------------------------

proc immediateScheduler*(): ViewportScheduler =
  ## Applies every report at once: no debounce. The default, for hosts that
  ## report a viewport only when a layout is committed.
  ViewportScheduler(
    schedule: proc(delayMs: float64; callback: proc()): int =
      callback()
      0,
    cancel: proc(id: int) = discard)

when defined(js):
  proc jsSetTimeout(cb: proc(); ms: float64): int {.importjs: "setTimeout(#, #)".}
  proc jsClearTimeout(id: int) {.importjs: "clearTimeout(#)".}

  proc timeoutScheduler*(): ViewportScheduler =
    ## Debounces on the browser's own timer — for a host that reports on every
    ## resize and scroll event.
    ViewportScheduler(
      schedule: proc(delayMs: float64; callback: proc()): int =
        jsSetTimeout(callback, delayMs),
      cancel: proc(id: int) = jsClearTimeout(id))

# ---------------------------------------------------------------------------
# The gate
# ---------------------------------------------------------------------------

proc newViewportGate*(schedulerOf: proc(): ViewportScheduler;
                      apply: proc(v: Viewport)): ViewportGate =
  ## A gate that hands the last of a burst of reports to `apply`, debounced
  ## on whatever timer `schedulerOf` names when a report arrives (immediate
  ## when it names none).
  ViewportGate(schedulerOf: schedulerOf, apply: apply)

proc submit*(g: ViewportGate; v: Viewport) =
  ## Report `v`. Applied after `ViewportDebounceMs` with no newer report.
  g.pending = v
  if g.hasTimer:
    g.scheduler.cancel(g.timer)
    g.hasTimer = false
  var scheduler = if g.schedulerOf.isNil: nil else: g.schedulerOf()
  if scheduler.isNil:
    scheduler = immediateScheduler()
  g.scheduler = scheduler
  let gate = g
  var fired = false
  let id = scheduler.schedule(ViewportDebounceMs, proc() =
    fired = true
    gate.hasTimer = false
    gate.apply(gate.pending))
  # An immediate scheduler has already applied the report; a deferring one
  # holds it until the timer fires.
  if not fired:
    g.timer = id
    g.hasTimer = true

proc flush*(g: ViewportGate) =
  ## Apply a report still waiting for its timer now (a host about to read
  ## the window, or tearing down).
  if g.hasTimer:
    g.scheduler.cancel(g.timer)
    g.hasTimer = false
    g.apply(g.pending)
