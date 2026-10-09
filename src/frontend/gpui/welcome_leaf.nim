## welcome_leaf.nim — PLAT-51 deliverable 8: THE WELCOME SCREEN OF A NEW TAB,
## in window pixels.
##
## Multi-Window-Tab-Management.md rule 3: the strip's "+" opens a tab showing
## the Welcome Screen (Welcome-Screen.md): the heading, the two recent panels
## side by side, the six start options in one row, and under them the form a
## chosen option opens (or what the screen has to say). The rows come from
## `viewmodels/native_welcome` — the model the terminal draws too
## (`tui/app/views/welcome_view`) — and this module is the ONE placement the
## window draws them at and hit-tests a press against.
##
## Pure: integers and the model's rows, no renderer.

import viewmodels/native_welcome

import ./window_geometry

export native_welcome

type
  WelcomeLayoutPx* = object
    heading*: PxRect
    foldersPanel*: PxRect
    tracesPanel*: PxRect
    rowRects*: seq[PxRect]
      ## Per row of `rowsOf`, where it is drawn (empty past its panel).
    line*: PxRect
      ## The form's field, or the message line.

const
  WelcomeRowPx* = 24
  WelcomeHeadingPx* = 40
  WelcomeMarginPx* = 24
  WelcomeButtonPadPx* = 14
  WelcomeButtonGapPx* = 10
  WelcomeCharPx* = 9
    ## The width budgeted per label character — `window_geometry.TabCharPx`'s
    ## rule: an explicit width, so a press and the drawn button agree.
  WelcomeMaxEntries* = 8

func buttonWidthPx*(label: string): int =
  2 * WelcomeButtonPadPx + WelcomeCharPx * label.len

func welcomeLayoutPx*(rows: seq[NativeWelcomeRow];
                      area: PxRect): WelcomeLayoutPx =
  ## Where everything goes inside the window's layout area.
  if area.isEmpty:
    return
  var y = area.y + WelcomeMarginPx
  result.heading = PxRect(x: area.x, y: y, w: area.w, h: WelcomeHeadingPx)
  y += WelcomeHeadingPx + WelcomeMarginPx
  var folders, traces, options: seq[int] = @[]
  for i, r in rows:
    case r.kind
    of nwrRecentFolder: folders.add i
    of nwrRecentTrace: traces.add i
    of nwrOption: options.add i
  result.rowRects = newSeq[PxRect](rows.len)
  let gap = WelcomeMarginPx
  let panelW = max(120, (area.w - 2 * WelcomeMarginPx - gap) div 2)
  let entries = min(WelcomeMaxEntries, max(1, max(folders.len, traces.len)))
  let panelH = (entries + 1) * WelcomeRowPx + 8
  result.foldersPanel = PxRect(x: area.x + WelcomeMarginPx, y: y, w: panelW,
                               h: panelH)
  result.tracesPanel = PxRect(x: area.x + WelcomeMarginPx + panelW + gap,
                              y: y, w: panelW, h: panelH)
  for k, i in folders:
    if k < entries:
      result.rowRects[i] = PxRect(x: result.foldersPanel.x + 4,
                                  y: y + (k + 1) * WelcomeRowPx + 4,
                                  w: panelW - 8, h: WelcomeRowPx)
  for k, i in traces:
    if k < entries:
      result.rowRects[i] = PxRect(x: result.tracesPanel.x + 4,
                                  y: y + (k + 1) * WelcomeRowPx + 4,
                                  w: panelW - 8, h: WelcomeRowPx)
  y += panelH + WelcomeMarginPx
  var x = area.x + WelcomeMarginPx
  for i in options:
    let w = buttonWidthPx(rows[i].label)
    if x + w > area.x + area.w - WelcomeMarginPx and
       x > area.x + WelcomeMarginPx:
      x = area.x + WelcomeMarginPx
      y += WelcomeRowPx + 12
    result.rowRects[i] = PxRect(x: x, y: y, w: w, h: WelcomeRowPx + 6)
    x += w + WelcomeButtonGapPx
  y += WelcomeRowPx + 6 + WelcomeMarginPx
  result.line = PxRect(x: area.x + WelcomeMarginPx, y: y,
                       w: max(1, area.w - 2 * WelcomeMarginPx),
                       h: WelcomeRowPx)

func welcomeRowAtPx*(lay: WelcomeLayoutPx; x, y: int): int =
  ## The row under a window pixel, or -1.
  for i, r in lay.rowRects:
    if not r.isEmpty and r.contains(x, y):
      return i
  -1
