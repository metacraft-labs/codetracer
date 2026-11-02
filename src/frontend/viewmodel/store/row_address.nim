## store/row_address.nim — the logical address of a shared pane's row.
##
## Shared-DOM-Front-Ends D10 (decided 2026-10-26, SDF-AREQ11): "the VMs carry
## the view-agnostic logical data necessary to construct URLs … and the views
## provide the actual URL construction logic". This module is the first half:
## what a Call Trace or Event Log row IS, in the recording's own coordinates,
## with no URL in it. The second half is a host's `RowLinks` — a proc that
## turns an address into an `href` — which a host with a URL scheme passes to
## the views (BlockTracer writes its §6.0a debug URLs from it). CodeTracer's
## own front-ends pass none, and their rows stay `role="button"` controls.
##
## WHAT IS NOT HERE, ON PURPOSE:
##
##   * a trace identity — a session is one recording, and the host that opened
##     it knows which one (BlockTracer: the artifact's content hash);
##   * any chain reading of an event (`log`, `sw`, `revert`) — the recorder's
##     kind is carried verbatim, and classifying it is the host's job
##     (CodeTracer-Embed-SDK.md §3.2 keeps chain concepts one layer up);
##   * any URL, query or fragment syntax.
##
## Pure functions over the store's row types: no signals, no DOM. The
## ViewModels expose them per row (`CalltraceVM.rowAddress`,
## `EventLogVM.rowAddress`).

import ./types

type
  RowAddressKind* = enum
    rakNone   ## no row (a position the ViewModel no longer holds)
    rakFrame  ## a call-trace row: one call of the recording
    rakEvent  ## an event-log row: one recorded event

  RowAddress* = object
    ## Which row of the recording a shared pane's row is (D10's table).
    kind*: RowAddressKind
    rrTicks*: uint64
      ## Where the row is in time: where the call starts, or the event's tick.
    # rakFrame
    callIndex*: int64
      ## `CallLine.index`: the call's index in the trace.
    callKey*: string
    depth*: int
    callPath*: seq[int]
      ## The frame's place in the call tree as sibling ordinals: at each
      ## depth, its index among the frames under the same parent, counted over
      ## the rows the ViewModel holds from the first one (`callPathsOf`).
    # rakEvent
    eventIndex*: int
      ## `EventLogRow.eventIndex`: the event's index in the recording's log.
    eventKind*: string
      ## The recorder's kind for the event, verbatim.
    file*: string
    line*: int
    hasPosition*: bool
      ## False for an event the producer reported no position for
      ## (`EventLogRow.noPosition`): there is nowhere in time to go.

  RowLinks* = proc(address: RowAddress): string
    ## A host's link builder: the `href` of the row at `address`, or `""` to
    ## leave that row unlinked. Passed to the Call Trace and Event Log views by
    ## a host that has a URL for a row; `nil` (every CodeTracer front-end)
    ## leaves every row a `role="button"` control.

proc callPathsOf*(lines: openArray[CallLine]): seq[seq[int]] =
  ## The `callPath` of every row of `lines`, in order.
  ##
  ## Derived from depth and order alone, which is the structure a list of
  ## calls has: each segment is the frame's index among its siblings at that
  ## depth under the same parent. Entering a shallower or equal depth ends
  ## every deeper run, so the deeper sibling counters restart. A list that
  ## starts below depth 0 (a section of a deep trace) has no parents on hand,
  ## so a path starts at the first depth it has rather than at a root that is
  ## not in the list.
  ##
  ## This is the numbering BlockTracer's `call:` anchor is written from
  ## (`client/src/debugger/deeplink_landing.callPath`, joined with `.`), kept
  ## identical so a link built from an address names the frame BlockTracer's
  ## landing resolves. `test_row_address.nim` checks the two against the same
  ## rows.
  var counters: seq[int]     ## the next sibling index at each depth
  var pathAt: seq[seq[int]]  ## the path of the last frame seen at each depth
  for line in lines:
    let d = max(0, line.depth)
    while counters.len <= d: counters.add 0
    while pathAt.len <= d: pathAt.add newSeq[int]()
    for deeper in d + 1 ..< counters.len: counters[deeper] = 0
    let seg = counters[d]
    inc counters[d]
    pathAt[d] =
      if d == 0 or pathAt[d - 1].len == 0: @[seg]
      else: pathAt[d - 1] & seg
    result.add pathAt[d]

proc frameAddress*(line: CallLine; callPath: seq[int]): RowAddress =
  ## The address of the call-trace row showing `line`, whose path among the
  ## held rows is `callPath`.
  RowAddress(kind: rakFrame, rrTicks: line.rrTicks, callIndex: line.index,
             callKey: line.callKey, depth: line.depth, callPath: callPath)

proc eventAddress*(row: EventLogRow): RowAddress =
  ## The address of the event-log row showing `row`.
  RowAddress(kind: rakEvent, rrTicks: row.rrTicks, eventIndex: row.eventIndex,
             eventKind: row.kind, file: row.file, line: row.line,
             hasPosition: not row.noPosition)

proc linkOf*(links: RowLinks; address: RowAddress): string =
  ## What `links` builds for `address`; `""` without a builder or a row.
  if links.isNil or address.kind == rakNone: "" else: links(address)
