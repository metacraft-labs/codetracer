## viewmodel/sdk/tracepoints.nim — the producer of tracepoint rows for the DOM
## hosts (codetracer#886, Pxor-Bugs M107).
##
## The Breakpoints & Tracepoints pane draws `store.pointList.rows`
## (`PointListVM.points`), and the contract it shares with every front-end
## (`CodeTracer-TUI.md` §3.3.5a) is one row per breakpoint or tracepoint the
## session HOLDS. Breakpoints get there through `sdk/breakpoints`. The native
## front-ends make a tracepoint a row when its sweep returns
## (`headless_session.runTracepoints` → `applyTracepointResults`), because
## that is when they first hold one. The desktop holds a tracepoint from the
## moment its editor opens under a line (`ui/trace.toggleTrace`), before
## anything has been run, so its row has to exist from then on. This module
## writes that row, and finds it again for the editor's later operations.
##
## Kept out of `replay_data_store.nim` on purpose. The store's operations
## (`applyTracepointResults`, `setTracepointsEnabled`, `deleteTracepoint`)
## already do what a desktop run, toggle and close need. What the desktop
## adds is only "hold a row nobody has swept yet" and "where is my row after
## a sweep located it", and both are written here over those operations.
##
## Pure Nim and backend-free, so the headless suites drive it over a real
## store (`src/tests/gui/tests/point-list/point_list_vm_test.nim`).

import std/options

import isonim/core/signals

import ../store/[replay_data_store, types]

const
  DeclaredTracepointResolution* = "declared"
    ## The `resolution` of a tracepoint row no sweep has answered for yet.
    ## A sweep overwrites it with `swept` / `swept, no hits` / `swept,
    ## errored` (`applyTracepointResults`).
  DeclaredTracepointDetail* = "not run yet"
  EmptyTracepointLabel* = "(no expression)"
    ## The label of a tracepoint whose editor is open with nothing typed in it.
    ## The row still names a tracepoint the session holds; the pane must not
    ## draw an empty label cell for it.

func tracepointLabel*(expression: string): string =
  ## What the pane shows for a tracepoint: what the user typed, as the rows a
  ## sweep creates show it (`applyTracepointResults`).
  if expression.len > 0: expression else: EmptyTracepointLabel

proc tracepointRowIndex(rows: openArray[PointListEntry]; path: string;
                        line: int): int =
  ## The index of the tracepoint row at `path:line`, or -1. A breakpoint on the
  ## same line is never the tracepoint (M76), and a row with no line is at no
  ## line.
  for i, r in rows:
    if r.kind == PointKindTracepoint and r.line != 0 and r.line == line and
       r.path == path:
      return i
  -1

proc tracepointRowAt*(store: ReplayDataStore; path: string;
                      line: int): Option[PointListEntry] =
  ## The tracepoint row at `path:line`, if the store holds one.
  if store.isNil:
    return none(PointListEntry)
  let rows = store.pointList.rows.val
  let i = rows.tracepointRowIndex(path, line)
  if i < 0: none(PointListEntry) else: some(rows[i])

proc heldTracepointLocation*(store: ReplayDataStore; path: string; line: int;
                             swept: openArray[TracepointSweepHit]):
                             Option[tuple[path: string, line: int]] =
  ## Where the row of the tracepoint the user declared at `path:line` is now.
  ##
  ## A sweep may MOVE the row: `applyTracepointResults` re-locates it to where
  ## the engine reported its first hit, because the engine is the authority on
  ## where a tracepoint fired. An editor that later disables or closes the
  ## tracepoint still knows it by the line it was opened under. So the row is
  ## looked for there first, and then at the first of `swept`, the hits the
  ## last sweep reported for this tracepoint. That is the hit
  ## `applyTracepointResults` took the location from. `none` when neither
  ## place holds a tracepoint row.
  if store.isNil:
    return none(tuple[path: string, line: int])
  if store.tracepointRowAt(path, line).isSome:
    return some((path: path, line: line))
  if swept.len > 0:
    let hit = swept[0]
    let hitPath = if hit.path.len > 0: hit.path else: path
    if hit.line > 0 and store.tracepointRowAt(hitPath, hit.line).isSome:
      return some((path: hitPath, line: hit.line))
  none(tuple[path: string, line: int])

proc declareTracepoint*(store: ReplayDataStore; path: string; line: int;
                        expression = ""; enabled = true;
                        swept: openArray[TracepointSweepHit] = []) =
  ## Hold the tracepoint at `path:line` as a row of the point list, run or
  ## not.
  ##
  ## An UPSERT. When the store already holds this tracepoint's row (the editor
  ## was hidden and opened again, or a run is about to send what the user
  ## typed since) its expression, label and enabled flag are brought up to
  ## date. Its resolution is kept, so a row a sweep annotated still says what
  ## that sweep found. Otherwise a new row is added, saying it has not been
  ## run. A breakpoint at the line is left as it is and stays a row of its
  ## own: the two are different points the user set (M76).
  ##
  ## `swept` is what the last sweep reported for this tracepoint (see
  ## `heldTracepointLocation`). A row that sweep moved is put back at
  ## `path:line`, where the user declared it. The next sweep is sent for that
  ## line and `applyTracepointResults` matches its answer by `(path, line)`,
  ## so a row left at the moved line would get a duplicate.
  ##
  ## A line below 1 is not a place, and nothing is written for it.
  if store.isNil or line < 1:
    return
  var rows = store.pointList.rows.val
  var i = -1
  let at = store.heldTracepointLocation(path, line, swept)
  if at.isSome:
    i = rows.tracepointRowIndex(at.get.path, at.get.line)
  if i >= 0:
    if rows[i].path == path and rows[i].line == line and
       rows[i].expression == expression and rows[i].enabled == enabled and
       rows[i].label == tracepointLabel(expression):
      return
    rows[i].path = path
    rows[i].line = line
    rows[i].expression = expression
    rows[i].label = tracepointLabel(expression)
    rows[i].enabled = enabled
  else:
    rows.add PointListEntry(
      kind: PointKindTracepoint,
      label: tracepointLabel(expression),
      path: path, line: line,
      enabled: enabled,
      collection: "",
      resolution: DeclaredTracepointResolution,
      detail: DeclaredTracepointDetail,
      expression: expression)
  store.pointList.rows.val = rows

proc setDeclaredTracepointEnabled*(store: ReplayDataStore; path: string;
                                   line: int; enabled: bool;
                                   swept: openArray[TracepointSweepHit] = []):
                                   bool =
  ## Enable or disable the tracepoint declared at `path:line`, wherever its
  ## row now is (`heldTracepointLocation`). True when a row changed.
  let at = store.heldTracepointLocation(path, line, swept)
  if at.isNone:
    return false
  store.setTracepointsEnabled(at.get.path, at.get.line, enabled) > 0

proc removeDeclaredTracepoint*(store: ReplayDataStore; path: string;
                               line: int;
                               swept: openArray[TracepointSweepHit] = []):
                               bool =
  ## Remove the tracepoint declared at `path:line`: its row, wherever a sweep
  ## moved it, and the hits its sweeps left (`deleteTracepoint`). Every other
  ## row, breakpoints at the same line among them, is kept. False when the
  ## store held no such tracepoint.
  let at = store.heldTracepointLocation(path, line, swept)
  if at.isNone:
    return false
  store.deleteTracepoint(at.get.path, at.get.line)
