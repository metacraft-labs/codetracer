## column_click_resolver.nim
##
## M6 — Column-Aware Replay Navigation: pixel → column resolver.
##
## The Monaco gutter (custom HTML in CodeTracer) and the surrounding
## editor surface emit click events whose effective `(line, column)`
## must be decoded by the View layer to decide whether to drive the
## *line-only* legacy `addBreakpoint` path or the M1 column-aware
## `addColumnBreakpoint(path, line, column)` path.
##
## This module isolates that decode in a pure function so the
## ViewModel-layer test (`test_column_breakpoint_gutter_click_vm.nim`)
## can drive it with synthetic pixel coordinates without needing a real
## Monaco editor instance.
##
## ## Click classification
##
## Three intent buckets, all 1-indexed for `line` / `column`:
##
## 1. **Gutter click** — user clicked on the gutter (line numbers
##    margin, breakpoint dot, etc.); resolver returns
##    `kind = GutterClick`, `column = 0`.  The View layer must drive
##    the legacy `DebuggerService.addBreakpoint(path, line)` path so
##    M1's back-compat invariant holds.
## 2. **Column-aware click** — user clicked on the line's text at a
##    Monaco-resolved column > 1.  Resolver returns
##    `kind = ColumnAwareClick` with `column >= 2`.  The View layer
##    must drive `DebuggerService.addColumnBreakpoint(path, line,
##    column)`.
## 3. **Line-start click** — Monaco resolved the click to column 1
##    (the line's leading whitespace or first character).  Resolver
##    returns `kind = GutterClick` even though Monaco hit the text:
##    column 1 is indistinguishable from a "click the start of the
##    line" intent and must fall through to the legacy line-only path
##    per the M6 contract (Column-Aware-Navigation.status.org §M6
##    Deliverables).
##
## The resolver is intentionally agnostic about *where* the line
## number came from — the View layer either reads it from the gutter
## HTML element's `data-line` attribute (legacy gutter click) or from
## the Monaco mouse-event `target.position.lineNumber` (Alt+click on
## the text content).

import std/options

type
  ColumnClickKind* = enum
    GutterClick      ## Click was outside the line text (or at column 1):
                     ##   fall through to legacy `addBreakpoint`.
    ColumnAwareClick ## Click resolved to column ≥ 2 on the line text:
                     ##   call `addColumnBreakpoint`.

  ColumnClickResolution* = object
    ## Output of `resolveColumnClick`.  `line` is always populated
    ## when a click landed on a valid line; `column` is 0 when the
    ## click should be treated as gutter-only (legacy path), and the
    ## 1-based column otherwise.
    kind*: ColumnClickKind
    line*: int
    column*: int

const ColumnAwareThreshold* = 2
  ## Minimum 1-based column at which a click is treated as
  ## column-aware.  Clicks resolving to column 1 (or 0) fall back to
  ## the line-only legacy path so the GUI default behaviour matches
  ## pre-M6 expectations and the M1 contract ("legacy line-only
  ## breakpoints column = 0 MUST continue to work").

proc resolveColumnClick*(
    line: int;
    monacoColumn: Option[int];
    onGutterElement: bool;
    lineMaxColumn: Option[int] = none(int)): ColumnClickResolution =
  ## Decide which breakpoint path a gutter / editor click should
  ## trigger.
  ##
  ## Parameters:
  ##   * `line` — 1-based line number the click landed on; 0 is
  ##     interpreted as "no line" and yields a `GutterClick` with
  ##     `line = 0` so callers can early-return.
  ##   * `monacoColumn` — when present, the 1-based column Monaco
  ##     resolved from the click's `target.position.column`.  Absent
  ##     means the click was on a CodeTracer gutter HTML element
  ##     (`.gutter-line` / `.gutter-breakpoint`) for which Monaco
  ##     does not report a text column.
  ##   * `onGutterElement` — true when the click came through the
  ##     `.gutter` HTML chain (the legacy CodeTracer gutter).  When
  ##     true, the resolver always returns `GutterClick` regardless
  ##     of the Monaco column — preserves M1's "gutter click = line-
  ##     only" invariant.
  ##   * `lineMaxColumn` — optional upper bound from
  ##     `MonacoTextModel.getLineMaxColumn(line)`.  When provided, the
  ##     resolved column is clamped to `[1, lineMaxColumn]`.
  ##
  ## See the module-doc comment for the three intent buckets the
  ## return value encodes.
  if line <= 0:
    return ColumnClickResolution(kind: GutterClick, line: 0, column: 0)

  if onGutterElement:
    return ColumnClickResolution(kind: GutterClick, line: line, column: 0)

  if monacoColumn.isNone:
    return ColumnClickResolution(kind: GutterClick, line: line, column: 0)

  var column = monacoColumn.get
  if column < 1:
    column = 1
  if lineMaxColumn.isSome:
    let maxCol = lineMaxColumn.get
    if maxCol >= 1 and column > maxCol:
      column = maxCol

  if column < ColumnAwareThreshold:
    return ColumnClickResolution(kind: GutterClick, line: line, column: 0)

  ColumnClickResolution(kind: ColumnAwareClick, line: line, column: column)


proc isColumnAware*(r: ColumnClickResolution): bool =
  ## Convenience predicate for callers that just want to know which
  ## breakpoint path to invoke.
  r.kind == ColumnAwareClick and r.column >= ColumnAwareThreshold
