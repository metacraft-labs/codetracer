## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/event_log.nim — CTUI-8. §3.3.5's "Tracepoint Event Log": the
## chronological list of recorded events, virtualized and SERVER-paginated.
##
## ## A PURE FUNCTION OF A VALUE, plus ONE callback — CTUI-7's shape, and for
## ## the same reason
##
## CTUI-8's risk mitigation is "dense event logs exhaust memory / server-side
## pagination in `EventLogVM`, asserted by `test_event_log_virtualization`". A
## pane that took its whole log as a value could not honour that: the value
## would be the whole log, which is the thing that must not exist in this
## process. So the model carries `pages`, an `EventPages` closure that answers
## ONE window of the recorded log, and `app/timeline_binding.nim` is the only
## module that builds one over a real `ct/event-load`. Everything else is a
## value: which rows are held, where the cursor is, and how far it has scrolled.
##
## `ensureWindow` calls it; `releaseOutside` drops what it returned. The second
## half is the one a reviewer should check, and
## `tests/test_event_log_virtualization.nim` asserts it as `heldRows` rather
## than as "the rows are gone" — a pane that merely stopped DRAWING would hold
## every page it had ever scrolled past, which is exactly the failure the
## mitigation names.
##
## ## THE TOTAL IS DISCOVERED, NOT DECLARED, AND THAT IS THE WIRE'S FAULT
##
## `ct/event-load` answers `{events, content, markers}` and NO total (measured
## against a real `replay-server` on 2026-09-06 — the response body's keys are
## exactly those three). Its `start`/`count` arguments really do slice
## server-side: `Handler::event_load` clamps them against `cached_events` and
## sends only the window. So the pane learns the size the only way the wire
## allows — a page that comes back SHORT is the last one — and until then the
## title says `40+` rather than a number it does not have. A pane that asked for
## a huge `count` to learn the total would do exactly the work the mitigation
## exists to avoid.
##
## ## THE ROW SET IS A PROPERTY OF THE RECORDING, NOT OF THE POSITION
##
## `viewmodels/event_log_vm.nim` carries a long comment about this and it was
## written from a real defect: keying the fetch on `rrTicks` made every jump
## re-issue `ct/event-load`, and a lost race between two draws emptied the pane.
## So `currentTick` is on this model for ONE purpose — deciding which row is
## marked as the one the debugger is standing on — and it is not a parameter of
## any fetch.
##
## ## FIVE CATEGORIES, AND FOUR OF THEM HAVE NO FIXTURE
##
## §3.3.5 lists what the log holds: print output, storage and memory mutations,
## syscalls and network I/O, and faults. `categoryFor` maps the wire's
## `EventLogKind` ordinals (`libs/ct-dap-client/src/types/common.rs:25`) onto
## those. Measured on all three fixtures of CTUI-1's corpus on 2026-09-06: the
## recorded logs are 6, 70 and 6 events and EVERY one of them is
## `kind = Write (0)` with `stdout = true`, i.e. `ecOutput`. So `ecMutation`,
## `ecSyscall`, `ecFault` and `ecTracepoint` have no integration coverage in
## this workspace; they are exercised at Tier 1 on constructed rows and the
## emptiness is asserted as an EQUALITY in
## `tests/test_event_log_jump.nim`, so the day a recorder emits one the suite
## says so.

import std/[strutils, tables]

import isonim_tui

# PLAT-49 part B: the column model is the Event Log ViewModel's
# (`EventLogColumns`), reached through the SDK facade.
from codetracer_embed import EventLogColumn, EventLogColumns,
  defaultEventLogColumns, visibleColumns, eventLogColumnTitle, elcTick,
  elcIndex, elcLocation, elcKind, elcOutput, EventLogOrder,
  RecordedEventOrder, clickedHeader
# PLAT-51: the scrollbar scrubber's shared model.
from codetracer_embed import ScrubberModel, scrubberModel
# PLAT-70 Part B: the cut cells, the open detail and the column widths
# (Horizontal-Overflow.md §5).
from codetracer_embed import FittedCell, fitCell, CutCell, DetailToggle,
  detailView, isOpen, isOpenIn, columnWidthOr, EventLogTableName, oneLine
# PLAT-70 Part I: the columns' widths and the horizontal view
# (Horizontal-Overflow.md §5.5).
from codetracer_embed import TableFit, fitTable, settle, overflows, barModel,
  HorizontalView, eventLogFitColumns, eventLogDefaultCells, EventLogTickCells,
  EventLogIndexCells, EventLogKindCells
from ../formatters/type_formatters import terminalMeasure, measureFor,
  markCut

import ../layout/profile
import ./styled_row
import ./scrubber_track
import ./table_hscroll

export styled_row, profile
export EventLogColumn, EventLogColumns, defaultEventLogColumns,
  visibleColumns, eventLogColumnTitle, EventLogOrder, RecordedEventOrder,
  clickedHeader

type
  EventCategory* = enum
    ## §3.3.5's four bullets, plus the tracepoint results the same log carries
    ## and an explicit unknown.
    ##
    ## An enum rather than the wire's integer, because the pane colours by
    ## category and an unmapped ordinal must be visible as "I do not know what
    ## this is" rather than silently coloured like a print statement.
    ecOutput
    ecMutation
    ecSyscall
    ecFault
    ecTracepoint
    ecUnknown

  EventRow* = object
    ## One recorded event, as the pane needs it.
    index*: int
      ## Position in the WHOLE recorded log, not in the page. The pane's cursor
      ## and its scroll are both in this coordinate, so a page boundary cannot
      ## move them.
    tick*: uint64
      ## `ProgramEvent.directLocationRRTicks` — where selecting this row seeks.
    file*: string
    line*: int
    content*: string
    category*: EventCategory
    kindId*: int
      ## The raw `EventLogKind` ordinal, carried so a failure message can name
      ## the value `categoryFor` did not recognise.

  EventPage* = object
    ## One answer from the seam.
    rows*: seq[EventRow]
    atEnd*: bool
      ## The server had nothing after this window. See this module's header on
      ## why the total is discovered rather than declared.
    total*: int = -1
      ## PLAT-51: the WHOLE log's size when the engine said it (`ct/event-load`
      ## carries `total` since then), -1 when it did not — the population the
      ## scrollbar scrubber spans.

  EventPages* = proc(offset, limit: int): EventPage {.closure.}
    ## THE SERVER-PAGINATION SEAM. Answers one window of the recorded log.
    ##
    ## `(offset, limit)` and not `(page)`, because that is exactly
    ## `ct/event-load`'s `(start, count)` and a seam that spoke pages would have
    ## to invent an arithmetic the wire does not have.

  EventLogRowKind* = enum
    elrEvent
    elrPending
      ## A row inside the viewport whose page has not been fetched. Drawn as a
      ## placeholder rather than skipped, so a pane that forgot to call
      ## `ensureWindow` shows a hole instead of a shorter, plausible list.

  EventLogRow* = object
    kind*: EventLogRowKind
    index*: int
    event*: EventRow

  EventLogModel* = object
    ## Everything the pane shows.
    pages*: EventPages
    pageSize*: int
    selected*: int
      ## Absolute event index under the cursor, or -1 for none.
    scrollTop*: int
      ## Absolute index of the first visible row.
    currentTick*: uint64
      ## Where the debugger is. Marks a row; see this module's header.
    note*: string
      ## Why the log is empty, when it is empty and a reason is known.
    columns*: EventLogColumns
      ## PLAT-49 part B: which columns the pane draws, in which order — the
      ## Event Log ViewModel's model (`defaultEventLogColumns`: the desktop's
      ## tick, #, kind and output; location hidden). `:column-show`,
      ## `:column-hide`, `:column-left` and `:column-right` change it.
    order*: EventLogOrder
      ## PLAT-50 (K26): the column the header click ordered the log by, and
      ## its direction — the engine sorts (`ct/event-load`'s `sortKey`), the
      ## pages arrive in that order; `RecordedEventOrder` is the tick order.
    held: Table[int, seq[EventRow]]
      ## Materialised pages, by page index. PRIVATE: the only way in is
      ## `ensureWindow` and the only way out is `releaseOutside`, so "released
      ## on scroll" is a property of this module rather than of its callers.
    fetchedPages: seq[int]
      ## Every page index this model has ever asked the seam for, in order.
      ## `test_event_log_virtualization.nim` asserts it has no duplicates, which
      ## is what "requests successive pages exactly once" means.
    endPage: int
      ## Page index that came back short, or -1 until one does.
    knownTotal: int
      ## -1 until `endPage` is found.
    current*: int
      ## PLAT-51: the row of the CURRENT recording position in the whole log
      ## (the last event at or before the debugger's tick — the engine's
      ## `indexAtTick`), -1 when unknown: the scrubber track's mark.
    detail*: DetailToggle
      ## PLAT-70 Part B: the event whose full text is open under its row
      ## (`list.show-detail`, a click on a `…`); its key is the event's number.
    copyChord*: string
      ## The resolved `list.copy` chord the detail's hint names (KL-8).
    hview*: HorizontalView
      ## PLAT-70 Part I: the table's horizontal view (Horizontal-Overflow.md
      ## §5.5) — `leftCol` is what the runtime's wheel and bar move; the
      ## painter settles it over each frame's fit.

  EventLogScreen* = object
    ## One painted pane, plus the counts and coordinates a test asserts on.
    rows*: seq[StyledRow]
    area*: CellArea
    visible*: seq[EventLogRow]
    bodyHeight*: int
    eventRows*: int
    pendingRows*: int
    selectedRow*: int
      ## SCREEN row of the cursor, or -1 when it is scrolled out.
    currentRow*: int
      ## SCREEN row of the event at the debugger's tick, or -1.
    tickColumn*: int
    contentColumn*: int
      ## Screen columns of the tick and content fields' first cells. REPORTED
      ## rather than recomputed by the caller, for `frame_item.FrameItem`'s
      ## reason: a Tier-2 case reads a cell at this column and a drift between
      ## the two arithmetics would move the read rather than the field. -1
      ## when that column is hidden.
    headerRow*: int
      ## PLAT-49 part B: the SCREEN row of the column header, -1 when none.
    columnCells*: seq[(EventLogColumn, int, int)]
      ## Each visible column with its first screen column and its width, in
      ## display order — the header's cells, for a click and for a test.
    separators*: seq[(EventLogColumn, int)]
      ## PLAT-70 Part B: each column separator on the header row — the gap
      ## cell right of a column — and the column a drag on it resizes.
    cuts*: seq[CutCell]
      ## PLAT-70 Part B: every cell drawn cut, with its `…` (HO-8).
    lineRows*: seq[int]
      ## Each body line's index in `visible`, -1 for a line of an open detail.
    detailRows*: seq[int]
      ## The SCREEN rows the open detail's lines are on.
    trackCol*: int
      ## PLAT-51: the scrollbar scrubber's column (the pane's rightmost), -1
      ## when the pane is too small to draw one.
    trackTop*: int
    trackRows*: int
      ## The track's first screen row and its height (the body's).
    fit*: TableFit
      ## PLAT-70 Part I: the columns' fit this frame (FIT, SHRINK, SCROLL).
    hview*: HorizontalView
      ## The horizontal view the pane was drawn from, settled over `fit`.
    barRow*: int
      ## The SCREEN row of the horizontal bar, -1 when none is drawn.

const
  MinTrackedWidth* = 8
    ## PLAT-51: the narrowest pane that gives a column to the scrubber.
  EventLogTitle* = "TRACEPOINTS"
    ## Contains the string CTUI-3's own pane title produced for `paneEventLog`
    ## in the Compact profile (`shell.paneTitle` calls that pane `Tracepoints`),
    ## so every CTUI-3 assertion that reads it off a shell row still reads it.
  PaneRule* = canonical(grDividerH)

  DefaultEventPageSize* = 16
    ## Events fetched per window by a model built without a pane — the
    ## suites' models. A host passes its pane's own window instead
    ## (`tui_session.eventLogPageRows`, HSF-V2: the shared window policy for
    ## the rows the pane shows), so no shipped pane pages by this number.
    ##
    ## Smaller than the 70 events `noir_space_ship` records, which is what makes
    ## `test_event_log_virtualization.nim`'s assertion a real one rather than a
    ## restatement of the fixture's size: at 16 the fixture is five pages and
    ## the last one is short, so both "it pages" and "it finds the end" are
    ## observable on real data.

  TickFieldCells* = EventLogTickCells
  GapCells* = 1
  IndexFieldCells* = EventLogIndexCells
    ## The `#` column: the event's number in the log.
  CategoryFieldCells* = EventLogKindCells
    ## PLAT-70 Part I: the default widths are the shared declaration's
    ## (`event_log_vm.eventLogFitColumns`); the location and output columns
    ## take their widths from what they show (Horizontal-Overflow.md §5.5).
  HeaderStyle* = CellStyle(role: srChromeMuted, bold: true)
    ## The column header's titles (the desktop's `.eventLog-column-header`).

  PendingText* = canonical(grTruncation)

  TitleStyle* = CellStyle(role: srChromeTitle)
  TitleDetailStyle* = CellStyle(role: srChromeMuted)
  RuleStyle* = CellStyle(role: srBorderPane)
  TickStyle* = CellStyle(role: srChromeMuted)
  LocationStyle* = CellStyle(role: srChromeMuted)
  ContentStyle* = CellStyle(role: srChromeText)
  SelectedBackground* = srSurfaceSelection
  CurrentTickStyle* = CellStyle(role: srChromeAccent)
    ## The row at the debugger's own tick, in the SAME colour
    ## `timeline_bar.NeedleStyle` paints `▲` — one fact, one colour, on two
    ## panes.
  EmptyLogText* = "no recorded events"
  EmptyLogStyle* = CellStyle(role: srChromeMuted, italic: true)
  PendingStyle* = CellStyle(role: srChromeMuted, italic: true)
  DetailStyle* = CellStyle(role: srChromeText)
    ## PLAT-70 Part B: an open detail's lines, the row's text in full.

  OutputStyle* = CellStyle(role: srEventOutput)
  MutationStyle* = CellStyle(role: srEventMutation)
  SyscallStyle* = CellStyle(role: srEventSyscall)
  FaultStyle* = CellStyle(role: srEventFault)
  TracepointStyle* = CellStyle(role: srEventTracepoint)
  UnknownStyle* = CellStyle(role: srEventUnknown)

# ---------------------------------------------------------------------------
# The wire's event kinds
# ---------------------------------------------------------------------------

const
  KindWrite* = 0
  KindWriteFile* = 1
  KindWriteOther* = 2
  KindRead* = 3
  KindReadFile* = 4
  KindReadOther* = 5
  KindReadDir* = 6
  KindOpenDir* = 7
  KindCloseDir* = 8
  KindSocket* = 9
  KindOpen* = 10
  KindError* = 11
  KindTraceLogEvent* = 12
  KindEvmEvent* = 13
  KindWriteStderr* = 14
  KindExec* = 15
  KindReadEnv* = 16
  KindWriteEnv* = 17
  KindStat* = 18
  KindCreateDir* = 19
  KindRemoveDir* = 20
  KindRemoveFile* = 21
  KindRename* = 22
  KindChangeDir* = 23
    ## `EventLogKind` (`trace-events.md` §"EventLogKind (u8 enum)"), as
    ## `libs/ct-dap-client/src/types/common.rs` decodes it. Spelled out here
    ## rather than imported because `app/` may not reach the db-backend and
    ## because an ordinal that silently changed on the wire must show up as a
    ## row this pane calls UNKNOWN rather than as a row it miscolours.

func categoryFor*(kindId: int; stdout: bool): EventCategory =
  ## Which of §3.3.5's bullets an event belongs to.
  ##
  ## `stdout` splits the write kinds, and that split is the whole reason this
  ## takes two arguments: the wire has ONE `Write` kind and uses the `stdout`
  ## flag to say whether it went to a terminal or to storage. Every event in
  ## CTUI-1's corpus is `Write` with `stdout = true`; a storage write would be
  ## the same ordinal with the flag clear.
  ##
  ## `WriteStderr` is terminal output whatever the flag says; the kinds that
  ## change the filesystem or the environment are mutations; the kinds that
  ## ask about them, run a program or move the process are syscalls.
  case kindId
  of KindWrite, KindWriteFile, KindWriteOther:
    if stdout: ecOutput else: ecMutation
  of KindWriteStderr:
    ecOutput
  of KindWriteEnv, KindCreateDir, KindRemoveDir, KindRemoveFile, KindRename:
    ecMutation
  of KindRead, KindReadFile, KindReadOther, KindReadDir, KindOpenDir,
     KindCloseDir, KindSocket, KindOpen, KindExec, KindReadEnv, KindStat,
     KindChangeDir:
    ecSyscall
  of KindError:
    ecFault
  of KindTraceLogEvent, KindEvmEvent:
    ecTracepoint
  else:
    ecUnknown

func categoryLabel*(category: EventCategory): string =
  ## Four cells, so the field is a COLUMN a Tier-2 case can read at a fixed
  ## offset rather than a word whose width depends on the row.
  case category
  of ecOutput: "out "
  of ecMutation: "mut "
  of ecSyscall: "sys "
  of ecFault: "err "
  of ecTracepoint: "trc "
  of ecUnknown: "??? "

func categoryStyle*(category: EventCategory): CellStyle =
  case category
  of ecOutput: OutputStyle
  of ecMutation: MutationStyle
  of ecSyscall: SyscallStyle
  of ecFault: FaultStyle
  of ecTracepoint: TracepointStyle
  of ecUnknown: UnknownStyle

# ---------------------------------------------------------------------------
# The model
# ---------------------------------------------------------------------------

proc initEventLogModel*(pages: EventPages = nil;
                        pageSize = DefaultEventPageSize;
                        currentTick = 0'u64;
                        note = ""): EventLogModel =
  EventLogModel(
    pages: pages,
    pageSize: max(1, pageSize),
    selected: -1,
    scrollTop: 0,
    currentTick: currentTick,
    note: note,
    columns: defaultEventLogColumns(),
    order: RecordedEventOrder,
    held: initTable[int, seq[EventRow]](),
    fetchedPages: @[],
    endPage: -1,
    knownTotal: -1,
    current: -1)

proc scrubberOf*(model: EventLogModel; bodyHeight: int): ScrubberModel =
  ## PLAT-51: the scrollbar scrubber over the WHOLE log (Scrollbar-Scrubbers.md
  ## §2: the Event Log's population, not the rows held) — its total, the
  ## view's first row and height, and the current position's row. While the
  ## total is unknown the thumb is indeterminate (§3.1).
  scrubberModel(max(0, model.knownTotal), model.scrollTop, bodyHeight,
                model.current, totalKnown = model.knownTotal >= 0)

proc pageOf*(model: EventLogModel; index: int): int =
  ## Which page an absolute event index falls in.
  if index < 0: -1 else: index div model.pageSize

proc knownTotal*(model: EventLogModel): int =
  ## How many events the log has, or -1 while that is still unknown.
  model.knownTotal

proc atEndKnown*(model: EventLogModel): bool =
  model.endPage >= 0

proc heldRows*(model: EventLogModel): int =
  ## Rows materialised right now. THE NUMBER THE MITIGATION IS ABOUT: a pane
  ## that paged correctly but never released would grow this without bound.
  for _, rows in model.held:
    result += rows.len

proc heldPages*(model: EventLogModel): int =
  model.held.len

proc fetchCount*(model: EventLogModel): int =
  ## How many times the seam has been called.
  model.fetchedPages.len

proc fetchedPageOrder*(model: EventLogModel): seq[int] =
  model.fetchedPages

proc fetchesFor*(model: EventLogModel; page: int): int =
  ## How many times ONE page was asked for. Exactly one is the contract; this
  ## is what lets the suite assert it per page instead of only in aggregate.
  for p in model.fetchedPages:
    if p == page:
      inc result

proc fetchPage(model: var EventLogModel; page: int) =
  ## Ask the seam for one page. EXACTLY ONCE per page per model: a page already
  ## held, or already known to be past the end, is not asked for again.
  if page < 0 or model.pages.isNil:
    return
  if model.held.hasKey(page):
    return
  if model.endPage >= 0 and page > model.endPage:
    return
  let answer = model.pages(page * model.pageSize, model.pageSize)
  model.fetchedPages.add page
  model.held[page] = answer.rows
  if answer.total >= 0:
    # PLAT-51: the engine said how long the whole log is — the end is KNOWN,
    # not discovered by reading the page that comes back short.
    model.knownTotal = answer.total
    model.endPage = if answer.total <= 0: 0
                    else: (answer.total - 1) div model.pageSize
  elif answer.atEnd or answer.rows.len < model.pageSize:
    model.endPage = page
    model.knownTotal = page * model.pageSize + answer.rows.len

proc rowAt*(model: EventLogModel; index: int): (bool, EventRow) =
  ## The event at an absolute index, if its page is held.
  let page = model.pageOf(index)
  if page < 0 or not model.held.hasKey(page):
    return (false, EventRow(index: -1))
  let within = index - page * model.pageSize
  let rows = model.held[page]
  if within < 0 or within >= rows.len:
    return (false, EventRow(index: -1))
  (true, rows[within])

proc reorder*(model: var EventLogModel; order: EventLogOrder) =
  ## PLAT-50 (K26): order the log by `order` — every held page is dropped
  ## (its rows were cut from the old order), the cursor and the scroll go back
  ## to the top, and the next `ensureWindow` asks the seam again.
  model.order = order
  model.held.clear()
  model.fetchedPages = @[]
  model.endPage = -1
  model.knownTotal = -1
  model.selected = -1
  model.scrollTop = 0

proc headerColumnAt*(screen: EventLogScreen; row, col: int):
    (bool, EventLogColumn) =
  ## PLAT-50 (K26): the column whose header a press at `(row, col)` is on, as
  ## `paintEventLog` laid the header out.
  if screen.headerRow < 0 or row != screen.headerRow:
    return (false, elcTick)
  for (c, at, w) in screen.columnCells:
    if col >= at and col < at + max(1, w):
      return (true, c)
  (false, elcTick)

proc ensureWindow*(model: var EventLogModel; first, count: int) =
  ## Materialise every page the window `[first, first+count)` touches.
  ##
  ## THE ONE ENTRY POINT. Painting does not fetch — see the module header on why
  ## the pane stays a pure function of what is held — so a caller that scrolls
  ## calls this and then paints, and a caller that forgot sees `elrPending`
  ## rows.
  if count <= 0 or model.pages.isNil:
    return
  let lo = max(0, first)
  let hi = lo + count - 1
  for page in model.pageOf(lo) .. model.pageOf(hi):
    model.fetchPage(page)
    if model.endPage >= 0 and page >= model.endPage:
      break

proc releaseOutside*(model: var EventLogModel; first, count: int;
                     keepPages = 1) =
  ## Drop every page more than `keepPages` away from the window.
  ##
  ## `keepPages = 1` keeps the neighbours, so a one-row scroll back does not
  ## re-fetch. RELEASED MEANS RELEASED: the entry leaves `held`, which is what
  ## `heldRows` counts, so "the pane bounds its memory" is a statement about
  ## objects and not about rows drawn.
  if count <= 0:
    return
  let lo = model.pageOf(max(0, first)) - keepPages
  let hi = model.pageOf(max(0, first) + count - 1) + keepPages
  var doomed: seq[int] = @[]
  for page, _ in model.held:
    if page < lo or page > hi:
      doomed.add page
  for page in doomed:
    model.held.del(page)

proc paneRows*(model: EventLogModel; first, count: int): seq[EventLogRow] =
  ## The rows a body `count` tall starting at absolute index `first` shows.
  result = @[]
  if count <= 0:
    return
  for i in max(0, first) ..< max(0, first) + count:
    if model.knownTotal >= 0 and i >= model.knownTotal:
      break
    let (found, event) = model.rowAt(i)
    if found:
      result.add EventLogRow(kind: elrEvent, index: i, event: event)
    elif model.endPage >= 0 and model.pageOf(i) > model.endPage:
      break
    else:
      result.add EventLogRow(kind: elrPending, index: i)

proc isEmpty*(model: EventLogModel): bool =
  ## Whether the pane has a log at all. A model whose first page is held and
  ## empty is an empty log; a model with nothing held has not asked yet.
  model.knownTotal == 0

proc hasContent*(model: EventLogModel): bool =
  ## Whether this pane has anything to draw.
  ##
  ## `heldPages > 0` and NOT `knownTotal > 0`: a log whose first full page is
  ## held has not discovered its end yet, so its total is still -1 and a shell
  ## that tested the total would leave the rectangle blank on exactly the
  ## recordings that have the most to show.
  model.heldPages > 0

proc clampScrollTop*(scrollTop, total, bodyHeight: int): int =
  ## The first visible index, clamped so the body never runs off either end.
  ## `total < 0` means "not yet known", and then only the lower bound applies —
  ## a pane that clamped against an unknown total would refuse to scroll past
  ## the first page and could never discover the end.
  if scrollTop < 0: 0
  elif bodyHeight <= 0: 0
  elif total < 0: scrollTop
  elif total <= bodyHeight: 0
  elif scrollTop > total - bodyHeight: total - bodyHeight
  else: scrollTop

proc scrollToSelection*(model: var EventLogModel; bodyHeight: int) =
  ## The smallest scroll that brings the cursor into the body.
  if model.selected < 0 or bodyHeight <= 0:
    return
  if model.selected < model.scrollTop:
    model.scrollTop = model.selected
  elif model.selected > model.scrollTop + bodyHeight - 1:
    model.scrollTop = model.selected - bodyHeight + 1
  model.scrollTop = clampScrollTop(model.scrollTop, model.knownTotal,
                                   bodyHeight)

# ---------------------------------------------------------------------------
# Painting
# ---------------------------------------------------------------------------

proc titleRowSpans*(model: EventLogModel; width: int;
                    glyphs = DefaultGlyphs): StyledRow =
  ## `TRACEPOINTS 70 event(s) ────`, or `70+` while the end is undiscovered.
  result = @[]
  if width <= 0:
    return
  var parts: seq[StyledSpan] = @[]
  parts.add StyledSpan(text: EventLogTitle, style: TitleStyle)
  let count =
    if model.knownTotal >= 0: $model.knownTotal & " event(s)"
    elif model.heldRows() > 0: $model.heldRows() & "+ event(s)"
    else: "loading"
  parts.add StyledSpan(text: " " & count, style: TitleDetailStyle)
  if model.knownTotal == 0 and model.note.len > 0:
    parts.add StyledSpan(text: " " & model.note, style: EmptyLogStyle)
  var used = 0
  for part in parts:
    if used >= width:
      break
    let fitted = truncateToCells(part.text, width - used)
    if fitted.len == 0:
      continue
    result.add StyledSpan(text: fitted, style: part.style)
    used += cellWidthOf(fitted)
  if used < width:
    result.add StyledSpan(text: " ", style: DefaultCellStyle)
    inc used
  if used < width:
    result.add StyledSpan(text: repeatGlyph(glyphs.glyph(grDividerH), width - used),
                          style: RuleStyle)

proc locationTextFor*(event: EventRow): string =
  if event.file.len == 0: ""
  else: pathBaseName(event.file) & ":" & $event.line

func eventCellText*(event: EventRow; col: EventLogColumn): string =
  ## What `col` says about `event`, whole — the cell before it is fitted.
  case col
  of elcTick: $event.tick
  of elcIndex:
    # The EVENT's number in the recorded log (`EventRow.index`), not the
    # row's position — the two differ once a header click ordered the log
    # by another column (PLAT-50).
    $event.index
  of elcLocation: locationTextFor(event)
  of elcKind: categoryLabel(event.category).strip
  of elcOutput: event.content.strip(leading = false, trailing = true)

proc eventLogFit*(model: EventLogModel; rows: openArray[EventLogRow];
                  width: int): TableFit =
  ## PLAT-70 Part I (Horizontal-Overflow.md §5.5): the columns' widths in a
  ## pane `width` cells wide (the scrubber's column excluded), from each
  ## column's widest cell over the rows shown — FIT, SHRINK or SCROLL, the
  ## shared solver's decision (`table_fit.fitTable`, the declaration
  ## `event_log_vm.eventLogFitColumns`).
  var widest: array[EventLogColumn, int]
  for row in rows:
    if row.kind != elrEvent:
      continue
    for col in EventLogColumn:
      widest[col] = max(widest[col],
                        cellWidthOf(oneLine(eventCellText(row.event, col))))
  fitTable(model.columns.eventLogFitColumns(widest, eventLogDefaultCells()),
           width, GapCells)

proc columnCellsOf*(model: EventLogModel; startCol: int;
                    fit: TableFit): seq[(EventLogColumn, int, int)] =
  ## Every visible column with its first column (from `startCol`) and width
  ## — the ONE table both the header and the rows are laid out by.
  let shown = model.columns.visibleColumns
  for k, col in shown:
    if k < fit.widths.len:
      result.add (col, startCol + fit.starts[k], fit.widths[k])

proc columnCellsOf*(model: EventLogModel; startCol, width: int):
    seq[(EventLogColumn, int, int)] =
  ## The columns of a pane `width` cells wide over the rows from the view's
  ## top — for a caller with no painted screen at hand.
  let rows = model.paneRows(model.scrollTop, max(1, model.pageSize))
  model.columnCellsOf(startCol, model.eventLogFit(rows, width))

proc eventRowLayout*(model: EventLogModel; row: EventLogRow;
                     cells: openArray[(EventLogColumn, int, int)];
                     startCol, width, screenRow: int;
                     glyphs = DefaultGlyphs; ambiguous = awNarrow):
    tuple[spans: StyledRow; cuts: seq[CutCell]] =
  ## One body row, `     38 out  main.py:111  2 + 3 = 5`, and the cells it
  ## drew cut, laid out over `cells` (columns from 0) in a row `width` cells
  ## wide.
  ##
  ## PLAT-70 Part B (Horizontal-Overflow.md §5.1): EVERY CELL IS FITTED TO ITS
  ## COLUMN BY `fitCell` — cut with `…` when it does not fit, untouched when
  ## it does — so the `…` on screen is exactly the shared decision's
  ## `truncated` (HO-8). The columns are the header's.
  if width <= 0:
    return
  case row.kind
  of elrPending:
    result.spans.add StyledSpan(text: fitCell(glyphs.glyph(grTruncation), width,
                                              measureFor(ambiguous)).text,
                                style: PendingStyle)
    return
  of elrEvent:
    discard
  let event = row.event
  let atCurrent = event.tick == model.currentTick
  let selected = row.index == model.selected
  var spans: seq[StyledSpan] = @[]
  var used = 0
  for (col, at, w) in cells:
    if at > used:
      spans.add StyledSpan(text: repeat(' ', at - used), style: DefaultCellStyle)
      used = at
    if w <= 0 or used >= width:
      continue
    let room = min(w, width - used)
    let fittedCell = fitCell(eventCellText(event, col), room,
                             measureFor(ambiguous))
    var cell = fittedCell
    cell.text = markCut(fittedCell, glyphs)
    let drawn = cellWidthOf(cell.text, ambiguous)
    # Numbers are right-aligned in their column; text is left-aligned.
    let text = if col in {elcTick, elcIndex}: padLeft(cell.text, room, ambiguous)
               else: padRight(cell.text, room, ambiguous)
    let style = case col
                of elcTick: (if atCurrent: CurrentTickStyle else: TickStyle)
                of elcIndex: TickStyle
                of elcLocation: LocationStyle
                of elcKind: categoryStyle(event.category)
                of elcOutput: ContentStyle
    spans.add StyledSpan(text: text, style: style)
    if cell.truncated:
      let first = startCol + used +
                  (if col in {elcTick, elcIndex}: room - drawn else: 0)
      result.cuts.add CutCell(row: screenRow, col: startCol + used,
                              width: room,
                              ellipsisCol: first + drawn - glyphs.markerCells,
                              key: $event.index, column: $col,
                              full: eventCellText(event, col))
    used += room
  for span in spans:
    var style = span.style
    # THE CURSOR'S HIGHLIGHT ONLY TOUCHES SPANS WITH NO BACKGROUND OF THEIR OWN.
    # CTUI-7's first draft of `tree_node.treeRow` painted the selection over
    # every span and ate the one badge the row existed to show; this pane has
    # the same shape and takes the fix rather than the defect.
    if selected and not style.hasOwnBackground:
      style = style.withBackground(SelectedBackground)
    result.spans.add StyledSpan(text: span.text, style: style)
  if selected and used < width:
    result.spans.add StyledSpan(text: repeat(' ', width - used),
                                style: CellStyle(surface: SelectedBackground))

func detailColumnOf*(model: EventLogModel; column: string): EventLogColumn =
  ## The column an open detail shows: the one named (a `…` click), else the
  ## event's text — the output column when it is shown, else the last one.
  let shown = model.columns.visibleColumns
  for col in shown:
    if $col == column:
      return col
  if elcOutput in shown: elcOutput
  elif shown.len > 0: shown[^1]
  else: elcOutput

proc headerRowSpans*(model: EventLogModel;
                     cells: openArray[(EventLogColumn, int, int)];
                     width: int; glyphs = DefaultGlyphs): StyledRow =
  ## The column header: each visible column's title over its cells, in the
  ## model's order (the desktop's `.eventLog-column-header`). A title is
  ## clipped to its column (chrome: a header is not a table cell).
  var line = ""
  for (col, at, w) in cells:
    while cellWidthOf(line) < at:
      line.add ' '
    # PLAT-50: the column the log is ordered by carries the desktop's sort
    # arrow (DataTables' `dt-ordering-asc` / `-desc`) once a header click
    # left the recorded order.
    let title = eventLogColumnTitle(col) &
      (if model.order != RecordedEventOrder and model.order.column == col:
         (if model.order.ascending: " " & glyphs.glyph(grSortAscending)
          else: " " & glyphs.glyph(grSortDescending))
       else: "")
    # Numbers are right-aligned under a right-aligned title.
    line.add (if col in {elcTick, elcIndex}: padLeft(title, w)
              else: truncateToCells(title, w))
  @[StyledSpan(text: truncateToCells(line, width), style: HeaderStyle)]

type
  EventLogGeometry* = object
    ## PLAT-70 Part I: where the pane's parts go this frame — read by the
    ## painter and by the runtime's wheel, bar and resize routes, so a
    ## gesture and the drawing cannot disagree.
    tracked*: bool
    width*: int
      ## The cells the columns are shown in (the scrubber's column excluded).
    header*: bool
    firstBody*: int
    bodyHeight*: int
      ## The body's rows, less the bar's row while it is shown.
    fit*: TableFit
    view*: HorizontalView
      ## The pane's horizontal view, settled over `fit`.
    barRow*: int
      ## The SCREEN row of the horizontal bar, -1 when it is not drawn.

proc eventLogGeometry*(model: EventLogModel; area: CellArea): EventLogGeometry =
  ## The pane's geometry in `area`: the columns' fit over the rows the body
  ## shows (§5.5), the horizontal view settled over it, and — in SCROLL, when
  ## the body has a row to spare — §4.7's bar on the body's last row.
  result.barRow = -1
  result.tracked = area.width >= MinTrackedWidth and area.height > 2
  result.width = if result.tracked: area.width - ScrubberTrackCells
                 else: area.width
  result.header = area.height > 2
  result.firstBody = area.row + (if result.header: 2 else: 1)
  result.bodyHeight = max(0, area.row + area.height - result.firstBody)
  let rows = model.paneRows(model.scrollTop, result.bodyHeight)
  result.fit = model.eventLogFit(rows, max(0, result.width))
  result.view = model.hview
  result.view.settle(result.fit)
  if result.fit.overflows and result.bodyHeight > 1:
    dec result.bodyHeight
    result.barRow = result.firstBody + result.bodyHeight

proc paintEventLog*(g: var StyledGrid; area: CellArea;
                    model: EventLogModel): EventLogScreen =
  ## Paint the pane into `area` of `g`, and report what it painted.
  ##
  ## PURE over what is held: this never calls the seam. See the module header.
  ##
  ## PLAT-70 Part I (Horizontal-Overflow.md §5.5): the header and the rows are
  ## laid out once at the TABLE's width (the solver's), into a scratch grid,
  ## and the window `[leftCol, leftCol + width)` of each is copied to the
  ## pane — the header over its cells at every scroll.
  result = EventLogScreen(
    rows: @[], area: area, visible: @[], bodyHeight: 0, eventRows: 0,
    pendingRows: 0, selectedRow: -1, currentRow: -1,
    tickColumn: -1, contentColumn: -1, headerRow: -1, trackCol: -1,
    barRow: -1)
  # PLAT-51: THE RIGHTMOST COLUMN IS THE SCROLLBAR SCRUBBER, inside the pane's
  # own rectangle (Scrollbar-Scrubbers.md §4), when the pane has a body and
  # room for it; the columns lay out in the cells left of it.
  let geo = model.eventLogGeometry(area)
  let width = geo.width
  let left = geo.view.leftCol
  let shift = area.col - left
  result.fit = geo.fit
  result.hview = geo.view
  let tableCells = model.columnCellsOf(0, geo.fit)
  let tableW = max(width, geo.fit.contentUnits)
  for (col, at, w) in tableCells:
    result.columnCells.add (col, at + shift, w)
  for (col, at, _) in result.columnCells:
    if col == elcTick: result.tickColumn = at
    if col == elcOutput: result.contentColumn = at
  if area.width <= 0 or area.height <= 0:
    return

  var spanAt = area.col
  for span in titleRowSpans(model, area.width, g.glyphs):
    g.paint(area.row, spanAt, span.text, span.style)
    spanAt += cellWidthOf(span.text)

  if area.height <= 1:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  # The table at its own width; row `area.row + k` of the pane is row `k`.
  var table = newStyledGridLike(g, tableW, area.height)
  # PLAT-49 part B: THE COLUMN HEADER, under the title row (which the shell's
  # tab strip replaces) — the desktop's table names its columns, and with
  # columns that can be hidden and reordered the reader has to see which are
  # which.
  if geo.header:
    result.headerRow = area.row + 1
    var at = 0
    for span in headerRowSpans(model, tableCells, tableW, g.glyphs):
      table.paint(1, at, span.text, span.style)
      at += cellWidthOf(span.text)
    g.copySlice(area.row + 1, area.col, table, 1, left, width)
  let firstBody = geo.firstBody
  let bodyHeight = geo.bodyHeight
  result.bodyHeight = bodyHeight
  let rows = model.paneRows(model.scrollTop, bodyHeight)
  if geo.tracked and bodyHeight > 0:
    result.trackCol = area.col + width
    result.trackTop = firstBody
    result.trackRows = bodyHeight
    paintVerticalScrubber(g, result.trackCol, firstBody, bodyHeight,
                          model.scrubberOf(bodyHeight))
  if geo.barRow >= 0:
    # §4.7: the bar on the body's last row; the corner cell (the scrubber's
    # column on that row) belongs to neither track (HO-7).
    result.barRow = geo.barRow
    paintHorizontalBar(g, geo.barRow, area.col, width, geo.view.barModel)

  if rows.len == 0:
    g.paint(firstBody, area.col,
            truncateToCells(EmptyLogText, width), EmptyLogStyle)
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  # PLAT-70 Part B: the separators a drag on the header resizes — the gap
  # cell right of each column but the last (those on screen).
  if geo.header:
    for k in 0 ..< result.columnCells.len - 1:
      let (col, at, w) = result.columnCells[k]
      if at + w >= area.col and at + w < area.col + width:
        result.separators.add (col, at + w)

  # The body: each event's row, and under the one whose detail is open its
  # full text (Horizontal-Overflow.md §5.3), until the body is full.
  var line = 0
  for i, row in rows:
    if line >= bodyHeight:
      break
    let screenRow = firstBody + line
    let tableRow = screenRow - area.row
    let laid = eventRowLayout(model, row, tableCells, 0, tableW, screenRow,
                              g.glyphs, g.ambiguous)
    var at = 0
    for span in laid.spans:
      table.paint(tableRow, at, span.text, span.style)
      at += cellWidthOf(span.text)
    g.copySlice(screenRow, area.col, table, tableRow, left, width)
    result.cuts.add shiftCuts(laid.cuts, shift, area.col, area.col + width)
    result.visible.add row
    result.lineRows.add result.visible.high
    inc line
    case row.kind
    of elrEvent:
      inc result.eventRows
      if row.index == model.selected:
        result.selectedRow = screenRow
      if row.event.tick == model.currentTick and result.currentRow < 0:
        result.currentRow = screenRow
      if model.detail.isOpenIn(EventLogTableName) and
         model.detail.key == $row.event.index:
        let col = model.detailColumnOf(model.detail.column)
        var colAt, colW = 0
        for (c, cAt, cW) in result.columnCells:
          if c == col:
            # The detail wraps inside the column's part on screen.
            colAt = max(area.col, cAt)
            colW = max(1, min(cAt + cW, area.col + width) - colAt)
        let view = detailView(eventCellText(row.event, col), colW,
                              bodyHeight, model.copyChord, terminalMeasure)
        for text in view.lines:
          if line >= bodyHeight:
            break
          g.paint(firstBody + line, colAt, padRight(text, colW), DetailStyle)
          result.detailRows.add firstBody + line
          result.lineRows.add -1
          inc line
    of elrPending:
      inc result.pendingRows

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc eventRowAtScreen*(screen: EventLogScreen; row: int):
    (bool, EventLogRow) =
  ## The event row painted on SCREEN row `row` — not a header, not a line of
  ## an open detail, not a pending placeholder.
  let firstBody = screen.area.row + (if screen.headerRow >= 0: 2 else: 1)
  let i = row - firstBody
  if i < 0 or i >= screen.lineRows.len or screen.lineRows[i] < 0:
    return (false, EventLogRow())
  let r = screen.visible[screen.lineRows[i]]
  if r.kind != elrEvent:
    return (false, EventLogRow())
  (true, r)

proc separatorAt*(screen: EventLogScreen; row, col: int):
    (bool, EventLogColumn) =
  ## PLAT-70 Part B: the column whose separator a press at `(row, col)` holds.
  if screen.headerRow < 0 or row != screen.headerRow:
    return (false, elcTick)
  for (c, at) in screen.separators:
    if col == at:
      return (true, c)
  (false, elcTick)

proc eventLogScreen*(model: EventLogModel;
                     width, height: int): EventLogScreen =
  var g = newStyledGrid(width, height)
  let area = CellArea(col: 0, row: 0, width: width, height: height)
  result = paintEventLog(g, area, model)
