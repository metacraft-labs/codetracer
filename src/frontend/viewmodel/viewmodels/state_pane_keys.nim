## viewmodels/state_pane_keys.nim — the Variables pane FROM THE KEYBOARD:
## its rows as one list, the value-origin chain's hops among them, and what
## each `list.*` and `variables.*` operation does to the cursor
## (Variable-State-Pane.md § Value origin from the keyboard;
## Value-Origin-Tracking.md §13.0: *"↑/↓ move between hops; Enter seeks; →
## expands operands; ← collapses; Esc dismisses the chain"*).
##
## Owns:
##   * `OriginHopRow` — one hop of an open chain as the pane lists it: the
##     line drawn, the tick `Enter` seeks to, and its operand snapshots.
##     `originHopRows` derives them from the engine's `OriginChain`, so the
##     drawn text and the seek target are one value and cannot disagree.
##   * `StateCursor` and `stateKey` — the cursor (a variable, or a hop of its
##     open chain) and the ONE rule for what an operation does to it. Every
##     native front-end hands `stateKey` the rows it lists, in order, and
##     applies the effect it answers; none decides by itself which row is
##     next, what `Enter` on a hop means or where `Escape` returns.
##
## Refuses to own: fetching a chain (the host's `loadValueOrigin`), drawing a
## row, seeking (the host's one seek), and the chords (the keymap data).
##
## Pure: no signals, no I/O — compiled on the C and the JS backends alike.

import std/strutils

import ./origin_chain_types

type
  OriginHopRow* = object
    ## One hop of an open origin chain, as a row of the Variables pane.
    text*: string
      ## The line drawn: `tick N  kind  target <- source  file:line`.
    tick*: uint64
      ## Where the hop's value was written — what `Enter` on the hop seeks to.
    path*: string
    line*: int
    operands*: seq[string]
      ## `name = value` per operand snapshot (computational hops); `→` shows
      ## them under the hop, `←` hides them.

  StateRowKind* = enum
    srkVariable  ## a variable (or a watch) — a cursor stop
    srkHop       ## a hop of the chain open under the variable — a cursor stop
    srkOther     ## anything else the pane lists (notes, history, load-more)

  StateKeyRow* = object
    ## One row of the pane as `stateKey` needs it, in the order listed.
    kind*: StateRowKind
    path*: string
      ## The variable's path; for a hop, the path of the variable it belongs
      ## to.
    hop*: int
      ## The hop's index in its chain; -1 for a variable.
    expandable*, expanded*: bool
      ## A variable's tree state.
    tick*: uint64
      ## A hop's seek target.
    hasOperands*, operandsOpen*: bool
      ## A hop's operand snapshots, and whether they are shown.
    chainOpen*: bool
      ## A variable whose origin chain is open under it.

  StateCursor* = object
    ## Where the Variables pane's keyboard cursor is: a variable (`hop` -1),
    ## or a hop of the chain open under it.
    path*: string
    hop*: int

  StateKeyEffectKind* = enum
    skeUnhandled
      ## Not the pane's: the caller lets the key go on (an `Escape` on a
      ## variable, an operation this pane does not take).
    skeNone
      ## The pane's, and nothing changes (Down on the last row).
    skeMoved
      ## The cursor moved to `cursor`.
    skeExpand, skeCollapse
      ## Open / close the variable `path` in the tree.
    skeToggleOperands
      ## Show or hide hop `hop`'s operands under it.
    skeSeek
      ## Move the recording to `tick` (`Enter` on a hop: it is a navigation
      ## row, Click-Navigation.md §2).
    skeCloseChain
      ## Close `path`'s chain; the cursor returns to the variable (`cursor`).
    skeToggleChain
      ## Open or close `path`'s chain (`variables.show-value-origin`); when
      ## it closes the cursor returns to the variable (`cursor`).

  StateKeyEffect* = object
    kind*: StateKeyEffectKind
    cursor*: StateCursor
      ## The cursor after the operation.
    path*: string
    hop*: int
    tick*: uint64

const
  ShowValueOriginOperation* = "variables.show-value-origin"
    ## The state pane's own operation: the action of the row menu's "Show
    ## value origin" (K28) and the origin badge (K41), from the keyboard.

func variableCursor*(path: string): StateCursor =
  StateCursor(path: path, hop: -1)

func originHopRows*(chain: OriginChain): seq[OriginHopRow] =
  ## The chain's hops as the pane lists them, nearest cause first, skipping a
  ## hop that names no recorded step (the desktop's origin panel's rows).
  for hop in chain.hops:
    if hop.location.path.len == 0 and hop.location.rrTicks == 0'u64:
      continue
    var file = hop.location.path
    let slash = file.rfind('/')
    if slash >= 0: file = file[slash + 1 .. ^1]
    var row = OriginHopRow(
      text: "tick " & $hop.location.rrTicks & "  " & $hop.kind & "  " &
            hop.targetExpr & " <- " & hop.sourceExpr.strip() & "  " &
            file & ":" & $hop.location.line,
      tick: hop.location.rrTicks, path: hop.location.path,
      line: hop.location.line)
    for o in hop.operandSnapshots:
      row.operands.add o.name & " = " & o.value
    result.add row

func cursorIndex*(rows: openArray[StateKeyRow]; cursor: StateCursor): int =
  ## The row the cursor is on, or -1 (no cursor, or its row is not listed —
  ## a hop of a chain that closed).
  for i, r in rows:
    case r.kind
    of srkVariable:
      if cursor.hop < 0 and r.path == cursor.path: return i
    of srkHop:
      if cursor.hop >= 0 and r.path == cursor.path and r.hop == cursor.hop:
        return i
    of srkOther: discard
  -1

func cursorOf(r: StateKeyRow): StateCursor =
  StateCursor(path: r.path, hop: (if r.kind == srkHop: r.hop else: -1))

func stops(rows: openArray[StateKeyRow]): seq[int] =
  for i, r in rows:
    if r.kind in {srkVariable, srkHop}: result.add i

func moved(rows: openArray[StateKeyRow]; cursor: StateCursor;
           to: int): StateKeyEffect =
  let next = rows[to].cursorOf
  if next == cursor: StateKeyEffect(kind: skeNone, cursor: cursor)
  else: StateKeyEffect(kind: skeMoved, cursor: next)

func stateKey*(rows: openArray[StateKeyRow]; cursor: StateCursor;
               operation: string; page = 10): StateKeyEffect =
  ## What `operation` does to the Variables pane whose rows are `rows` (in
  ## the order listed) with the cursor at `cursor`.
  let stops = rows.stops
  let at = rows.cursorIndex(cursor)
  # The cursor's position among the stops, or -1.
  var s = -1
  for k, i in stops:
    if i == at: s = k
  case operation
  of "list.focus-next", "list.focus-previous", "list.focus-first",
     "list.focus-last", "list.focus-page-down", "list.focus-page-up":
    if stops.len == 0:
      return StateKeyEffect(kind: skeNone, cursor: cursor)
    let k =
      case operation
      of "list.focus-first": 0
      of "list.focus-last": stops.high
      of "list.focus-next": (if s < 0: 0 else: s + 1)
      of "list.focus-previous": (if s < 0: 0 else: s - 1)
      of "list.focus-page-down": (if s < 0: 0 else: s + max(1, page))
      else: (if s < 0: 0 else: s - max(1, page))
    return rows.moved(cursor, stops[clamp(k, 0, stops.high)])
  else: discard
  if at < 0:
    # No cursor: nothing below acts on a row.
    return StateKeyEffect(kind: (if operation == ShowValueOriginOperation:
                                   skeNone else: skeUnhandled),
                          cursor: cursor)
  let row = rows[at]
  case operation
  of "list.expand", "list.collapse", "list.toggle-expand":
    case row.kind
    of srkVariable:
      let open = row.expanded
      if operation == "list.expand" and open or
         operation == "list.collapse" and not open or not row.expandable:
        return StateKeyEffect(kind: skeNone, cursor: cursor)
      StateKeyEffect(kind: (if open: skeCollapse else: skeExpand),
                     cursor: cursor, path: row.path)
    of srkHop:
      # `→` expands the hop's operands, `←` collapses them; `←` on a hop
      # whose operands are not shown goes to its variable, as a tree's
      # child does to its parent.
      if operation == "list.collapse" and not row.operandsOpen:
        return StateKeyEffect(kind: skeMoved, cursor: variableCursor(row.path))
      if not row.hasOperands or
         operation == "list.expand" and row.operandsOpen:
        return StateKeyEffect(kind: skeNone, cursor: cursor)
      StateKeyEffect(kind: skeToggleOperands, cursor: cursor, path: row.path,
                     hop: row.hop)
    of srkOther:
      StateKeyEffect(kind: skeUnhandled, cursor: cursor)
  of "list.activate":
    case row.kind
    of srkHop:
      StateKeyEffect(kind: skeSeek, cursor: cursor, path: row.path,
                     hop: row.hop, tick: row.tick)
    of srkVariable:
      if not row.expandable:
        return StateKeyEffect(kind: skeNone, cursor: cursor)
      StateKeyEffect(kind: (if row.expanded: skeCollapse else: skeExpand),
                     cursor: cursor, path: row.path)
    of srkOther:
      StateKeyEffect(kind: skeUnhandled, cursor: cursor)
  of "list.clear-selection":
    # `Escape` on a hop closes the chain and returns to the variable; on a
    # variable it is not this pane's.
    if row.kind != srkHop:
      return StateKeyEffect(kind: skeUnhandled, cursor: cursor)
    StateKeyEffect(kind: skeCloseChain, cursor: variableCursor(row.path),
                   path: row.path)
  of ShowValueOriginOperation:
    StateKeyEffect(kind: skeToggleChain, cursor: variableCursor(row.path),
                   path: row.path)
  else:
    StateKeyEffect(kind: skeUnhandled, cursor: cursor)

func operandKey*(path: string; hop: int): string =
  ## The key of hop `hop` of `path`'s chain in a set of hops whose operands
  ## are shown (`StateVM.openOperands`, the terminal's model).
  path & "#" & $hop
