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

import ../layout/profile
import ./styled_row

export styled_row, profile

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
      ## the two arithmetics would move the read rather than the field.

const
  EventLogTitle* = "TRACEPOINTS"
    ## Contains the string CTUI-3's own pane title produced for `paneEventLog`
    ## in the Compact profile (`shell.paneTitle` calls that pane `Tracepoints`),
    ## so every CTUI-3 assertion that reads it off a shell row still reads it.
  PaneRule* = "─"

  DefaultEventPageSize* = 16
    ## Events fetched per window.
    ##
    ## Smaller than the 70 events `noir_space_ship` records, which is what makes
    ## `test_event_log_virtualization.nim`'s assertion a real one rather than a
    ## restatement of the fixture's size: at 16 the fixture is five pages and
    ## the last one is short, so both "it pages" and "it finds the end" are
    ## observable on real data.

  TickFieldCells* = 8
  GapCells* = 1
  CategoryFieldCells* = 4
  LocationFieldCells* = 18

  PendingText* = "…"

  TitleStyle* = CellStyle(fg: "white", bold: true)
  TitleDetailStyle* = CellStyle(fg: "bright_black")
  RuleStyle* = CellStyle(fg: "bright_black")
  TickStyle* = CellStyle(fg: "bright_black")
  LocationStyle* = CellStyle(fg: "bright_black")
  ContentStyle* = CellStyle(fg: "white")
  SelectedBackground* = "bright_black"
  CurrentTickStyle* = CellStyle(fg: "bright_cyan", bold: true)
    ## The row at the debugger's own tick, in the SAME colour
    ## `timeline_bar.NeedleStyle` paints `▲` — one fact, one colour, on two
    ## panes.
  EmptyLogText* = "no recorded events"
  EmptyLogStyle* = CellStyle(fg: "bright_black", italic: true)
  PendingStyle* = CellStyle(fg: "bright_black", italic: true)

  OutputStyle* = CellStyle(fg: "green")
  MutationStyle* = CellStyle(fg: "yellow")
  SyscallStyle* = CellStyle(fg: "cyan")
  FaultStyle* = CellStyle(fg: "red", bold: true)
  TracepointStyle* = CellStyle(fg: "magenta")
  UnknownStyle* = CellStyle(fg: "bright_black")

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
  KindTrace* = 12
  KindHistory* = 13
    ## `EventLogKind`, `libs/ct-dap-client/src/types/common.rs:25`. Spelled out
    ## here rather than imported because `app/` may not reach the db-backend and
    ## because an ordinal that silently changed on the wire must show up as a
    ## row this pane calls UNKNOWN rather than as a row it miscolours.
  HighestKnownKind* = KindHistory

func categoryFor*(kindId: int; stdout: bool): EventCategory =
  ## Which of §3.3.5's bullets an event belongs to.
  ##
  ## `stdout` splits the write kinds, and that split is the whole reason this
  ## takes two arguments: the wire has ONE `Write` kind and uses the `stdout`
  ## flag to say whether it went to a terminal or to storage. Every event in
  ## CTUI-1's corpus is `Write` with `stdout = true`; a storage write would be
  ## the same ordinal with the flag clear.
  case kindId
  of KindWrite, KindWriteFile, KindWriteOther:
    if stdout: ecOutput else: ecMutation
  of KindRead, KindReadFile, KindReadOther, KindReadDir, KindOpenDir,
     KindCloseDir, KindSocket, KindOpen:
    ecSyscall
  of KindError:
    ecFault
  of KindTrace, KindHistory:
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
    held: initTable[int, seq[EventRow]](),
    fetchedPages: @[],
    endPage: -1,
    knownTotal: -1)

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

proc isPageHeld*(model: EventLogModel; page: int): bool =
  model.held.hasKey(page)

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
  if answer.atEnd or answer.rows.len < model.pageSize:
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

proc titleRowSpans*(model: EventLogModel; width: int): StyledRow =
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
    result.add StyledSpan(text: repeatGlyph(PaneRule, width - used),
                          style: RuleStyle)

proc locationTextFor*(event: EventRow): string =
  if event.file.len == 0: ""
  else: pathBaseName(event.file) & ":" & $event.line

proc eventRowSpans*(model: EventLogModel; row: EventLogRow;
                    width: int): StyledRow =
  ## One body row: `     38 out  main.py:111  2 + 3 = 5`.
  result = @[]
  if width <= 0:
    return
  case row.kind
  of elrPending:
    result.add StyledSpan(text: truncateToCells(PendingText, width),
                          style: PendingStyle)
    return
  of elrEvent:
    discard
  let event = row.event
  let atCurrent = event.tick == model.currentTick
  let selected = row.index == model.selected
  var spans: seq[StyledSpan] = @[]
  spans.add StyledSpan(
    text: padLeft($event.tick, TickFieldCells),
    style: (if atCurrent: CurrentTickStyle else: TickStyle))
  spans.add StyledSpan(text: " ", style: DefaultCellStyle)
  spans.add StyledSpan(text: categoryLabel(event.category),
                       style: categoryStyle(event.category))
  spans.add StyledSpan(
    text: padRight(locationTextFor(event), LocationFieldCells),
    style: LocationStyle)
  spans.add StyledSpan(text: " ", style: DefaultCellStyle)
  spans.add StyledSpan(text: event.content.strip(leading = false,
                                                 trailing = true),
                       style: ContentStyle)
  var used = 0
  for span in spans:
    if used >= width:
      break
    let fitted = truncateToCells(span.text, width - used)
    if fitted.len == 0:
      continue
    var style = span.style
    # THE CURSOR'S HIGHLIGHT ONLY TOUCHES SPANS WITH NO BACKGROUND OF THEIR OWN.
    # CTUI-7's first draft of `tree_node.treeRow` painted the selection over
    # every span and ate the one badge the row existed to show; this pane has
    # the same shape and takes the fix rather than the defect.
    if selected and style.bg.len == 0:
      style = style.withBackground(SelectedBackground)
    result.add StyledSpan(text: fitted, style: style)
    used += cellWidthOf(fitted)
  if selected and used < width:
    result.add StyledSpan(text: repeat(' ', width - used),
                          style: CellStyle(bg: SelectedBackground))

proc paintEventLog*(g: var StyledGrid; area: CellArea;
                    model: EventLogModel): EventLogScreen =
  ## Paint the pane into `area` of `g`, and report what it painted.
  ##
  ## PURE over what is held: this never calls the seam. See the module header.
  result = EventLogScreen(
    rows: @[], area: area, visible: @[], bodyHeight: 0, eventRows: 0,
    pendingRows: 0, selectedRow: -1, currentRow: -1,
    tickColumn: area.col,
    contentColumn: area.col + TickFieldCells + GapCells + CategoryFieldCells +
                   LocationFieldCells + GapCells)
  if area.width <= 0 or area.height <= 0:
    return

  var spanAt = area.col
  for span in titleRowSpans(model, area.width):
    g.paint(area.row, spanAt, span.text, span.style)
    spanAt += cellWidthOf(span.text)

  if area.height <= 1:
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  let bodyHeight = area.height - 1
  result.bodyHeight = bodyHeight
  let rows = model.paneRows(model.scrollTop, bodyHeight)

  if rows.len == 0:
    g.paint(area.row + 1, area.col,
            truncateToCells(EmptyLogText, area.width), EmptyLogStyle)
    for r in area.row ..< area.row + area.height:
      result.rows.add g.rowSpansIn(r, area.col, area.width)
    return

  for i, row in rows:
    let screenRow = area.row + 1 + i
    var at = area.col
    for span in eventRowSpans(model, row, area.width):
      g.paint(screenRow, at, span.text, span.style)
      at += cellWidthOf(span.text)
    result.visible.add row
    case row.kind
    of elrEvent:
      inc result.eventRows
      if row.index == model.selected:
        result.selectedRow = screenRow
      if row.event.tick == model.currentTick and result.currentRow < 0:
        result.currentRow = screenRow
    of elrPending:
      inc result.pendingRows

  for r in area.row ..< area.row + area.height:
    result.rows.add g.rowSpansIn(r, area.col, area.width)

proc eventLogScreen*(model: EventLogModel;
                     width, height: int): EventLogScreen =
  var g = newStyledGrid(width, height)
  let area = CellArea(col: 0, row: 0, width: width, height: height)
  result = paintEventLog(g, area, model)

proc eventLogRows*(model: EventLogModel; width, height: int): seq[StyledRow] =
  eventLogScreen(model, width, height).rows

proc eventLogText*(model: EventLogModel; width, height: int): seq[string] =
  result = @[]
  for row in eventLogRows(model, width, height):
    result.add rowText(row)

proc bodyRowForEvent*(screen: EventLogScreen; index: int): int =
  ## The SCREEN row showing event `index`, or -1 when it is scrolled out.
  result = -1
  for i, row in screen.visible:
    if row.index == index:
      return screen.area.row + 1 + i

proc eventAtScreenRow*(screen: EventLogScreen; screenRow: int): int =
  ## The absolute event index a screen row shows, or -1 outside the body.
  let i = screenRow - screen.area.row - 1
  if i < 0 or i >= screen.visible.len: -1
  elif screen.visible[i].kind != elrEvent: -1
  else: screen.visible[i].index

proc renderEventLogTree*(model: EventLogModel; r: TerminalRenderer;
                         width, height: int): TerminalNode =
  styledRowsTree(r, eventLogRows(model, width, height))
