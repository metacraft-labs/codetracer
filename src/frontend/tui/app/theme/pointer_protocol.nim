## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header. Nothing here touches a terminal: this module
## turns a negotiation into bytes somebody else writes.
##
## app/theme/pointer_protocol.nim — OSC 22, the terminal's pointer shape
## (Pointer-Affordances.md §5): the dialects, the query and its reply, tmux's
## wrapping, and `PointerEmitter`, which decides what to write for each shape
## the shared function answers (`common/pointer_shape`).
##
## Pure: the driver writes what this answers (`host/terminal_driver`), and
## hands `restoreBytes` to `nim-termctl`'s async-signal-safe restore.

import std/strutils

import ../../../../common/pointer_shape

export pointer_shape

type
  PointerDialect* = enum
    pdOff = "off"
    pdKitty = "kitty"
      ## CSS names, push / pop, and a query that says shape by shape.
    pdCss = "css"
      ## CSS names, set only (foot, Ghostty).
    pdX11 = "x11"
      ## X11 cursor-font names, set only (xterm).

  PointerShapesChoice* = enum
    ## `--pointer-shapes=` / `:set pointer-shapes`.
    pscAuto = "auto"
    pscOn = "on"
    pscOff = "off"

  PointerCaps* = object
    ## What the negotiation decided (§5.2, §5.5).
    dialect*: PointerDialect
    supported*: set[PointerShape]
    columnAlias*, rowAlias*: bool
      ## The terminal has no `col-resize` / `row-resize` but does have the
      ## `ew-resize` / `ns-resize` it answered for them (measured: kitty 0.47).
    resetName*: string
      ## What a set-only terminal is given on exit; "" is the empty form. xterm
      ## 407 and Ghostty 1.3.1 ignore the empty form (measured), so each is told
      ## the name of the I-beam it shows over text by itself.
    wrapped*: bool
      ## Inside tmux: every sequence goes through its passthrough.
    source*: string
      ## Why, for `--capabilities`: `query`, the identified terminal, `flag`.
    remedy*: string
      ## Non-empty when tmux's option is what keeps the shapes off.

  PointerEmitter* = object
    ## What the terminal has been told. `emit` writes only on change (PA-6).
    caps*: PointerCaps
    wanted*: PointerShape
      ## The shape the pointer's element asks for, applied again on focus-in.
    hasWanted*: bool
    shown*: PointerShape
      ## The last shape written.
    hasShown*: bool
    pushed*: bool
      ## The kitty dialect's one push is outstanding (§5.3).
    dirty*: bool
      ## A set-only terminal was given a shape since its last reset.
    unfocused*: bool

const
  PointerRemedy* = "pointer shapes need `set -g allow-passthrough on` in tmux"
  OscOpen = "\x1b]22;"
  St = "\x1b\\"

func pointerQuerySequence(): string =
  result = OscOpen & "?"
  for shape in PointerShape:
    if shape != low(PointerShape):
      result.add ','
    result.add shape.cssName
  result.add ",ew-resize,ns-resize"
  result.add St

func tmuxWrap*(sequence: string): string =
  ## tmux's passthrough, every `ESC` inside doubled (§5.5).
  "\x1bPtmux;" & sequence.replace("\x1b", "\x1b\x1b") & St

func pointerQuery*(inTmux: bool): string =
  ## §5.2's question, wrapped when it has to cross tmux.
  if inTmux: tmuxWrap(pointerQuerySequence()) else: pointerQuerySequence()

func isPointerReply*(token: string): bool =
  token.startsWith(OscOpen)

type
  PointerReply* = object
    ## What the terminal answered to the query.
    supported*: set[PointerShape]
    columnAlias*, rowAlias*: bool

func parsePointerReply*(token: string): (bool, PointerReply) =
  ## `OSC 22 ; 1,0,… ST`, one answer per name in the order asked.
  if not token.isPointerReply:
    return (false, PointerReply())
  var body = token[OscOpen.len .. ^1]
  if body.endsWith(St): body.setLen(body.len - St.len)
  elif body.endsWith("\x07"): body.setLen(body.len - 1)
  let answers = body.split(',')
  let shapes = ord(high(PointerShape)) + 1
  if answers.len notin [shapes, shapes + 2]:
    return (false, PointerReply())
  var reply: PointerReply
  for shape in PointerShape:
    case answers[ord(shape)].strip
    of "1": reply.supported.incl shape
    of "0": discard
    else: return (false, PointerReply())
  if answers.len == shapes + 2:
    if psColResize notin reply.supported and answers[shapes].strip == "1":
      reply.supported.incl psColResize
      reply.columnAlias = true
    if psRowResize notin reply.supported and answers[shapes + 1].strip == "1":
      reply.supported.incl psRowResize
      reply.rowAlias = true
  (true, reply)

func resolvePointerCaps*(choice: PointerShapesChoice; answered: bool;
                         reply: PointerReply; inTmux, inScreen: bool;
                         identity: string): PointerCaps =
  ## §5.2 and §5.5: what the terminal answered, then who it is. Inside tmux
  ## only the wrapped query's answer turns the shapes on, because the identity
  ## tmux reports says nothing about its passthrough; the same goes for GNU
  ## screen, which has no passthrough to rely on. `identity` is the outer
  ## terminal's canonical name when it is known.
  if choice == pscOff:
    return PointerCaps(dialect: pdOff, source: "setting")
  let all = {low(PointerShape) .. high(PointerShape)}
  if answered:
    return PointerCaps(dialect: pdKitty, supported: reply.supported,
                       columnAlias: reply.columnAlias, rowAlias: reply.rowAlias,
                       wrapped: inTmux, source: "query")
  let setOnly =
    case identity
    of "foot", "ghostty": pdCss
    of "xterm": pdX11
    else: pdOff
  let resetName =
    case identity
    of "xterm": "xterm"
    of "ghostty": "text"
    else: ""
  if choice == pscOn:
    return PointerCaps(dialect: (if setOnly == pdOff: pdCss else: setOnly),
                       supported: all, resetName: resetName, wrapped: inTmux,
                       source: "forced")
  if inTmux:
    return PointerCaps(dialect: pdOff, source: "tmux", remedy: PointerRemedy)
  if inScreen or setOnly == pdOff:
    return PointerCaps(dialect: pdOff, source: "unidentified")
  PointerCaps(dialect: setOnly, supported: all, resetName: resetName,
              source: identity)

func framed(caps: PointerCaps; sequence: string): string =
  if caps.wrapped: tmuxWrap(sequence) else: sequence

func nameIn(caps: PointerCaps; shape: PointerShape): string =
  if caps.dialect == pdX11: X11PointerNames[shape]
  elif shape == psColResize and caps.columnAlias: "ew-resize"
  elif shape == psRowResize and caps.rowAlias: "ns-resize"
  else: shape.cssName

func setBytes(caps: PointerCaps; shape: PointerShape): string =
  caps.framed(OscOpen & caps.nameIn(shape) & St)

func pushBytes(caps: PointerCaps; shape: PointerShape): string =
  caps.framed(OscOpen & ">" & caps.nameIn(shape) & St)

func popBytes(caps: PointerCaps): string =
  caps.framed(OscOpen & "<" & St)

func resetBytes(caps: PointerCaps): string =
  ## The terminal's own shape, on a dialect that cannot pop (§5.4).
  caps.framed(OscOpen & caps.resetName & St)

func write(e: var PointerEmitter; shape: PointerShape): string =
  let (ok, s) = supportedFallback(shape, e.caps.supported)
  if not ok or (e.hasShown and e.shown == s):
    return ""
  result =
    if e.caps.dialect == pdKitty and not e.pushed: e.caps.pushBytes(s)
    else: e.caps.setBytes(s)
  e.pushed = e.caps.dialect == pdKitty
  e.dirty = e.caps.dialect != pdKitty
  e.shown = s
  e.hasShown = true

func emit*(e: var PointerEmitter; shape: PointerShape): string =
  ## What to write for `shape`; "" when the terminal is already showing it, or
  ## shows nothing at all.
  e.wanted = shape
  e.hasWanted = true
  if e.caps.dialect == pdOff or e.unfocused:
    return ""
  e.write(shape)

func focusChanged*(e: var PointerEmitter; focused: bool): string =
  ## §5.3: the pointer belongs to whichever window or tmux pane has the focus.
  e.unfocused = not focused
  if e.caps.dialect == pdOff:
    return ""
  if focused:
    return if e.hasWanted: e.write(e.wanted) else: ""
  if e.pushed:
    result = e.caps.popBytes
    e.pushed = false
  elif e.hasShown:
    result = e.caps.setBytes(psDefault)
  e.hasShown = false

func restoreBytes*(e: PointerEmitter): string =
  ## The bytes that give the terminal its own pointer back, on every exit path:
  ## the pop of the one push, or the reset of a set-only dialect (§5.4). Empty
  ## while nothing is owed; a pop nobody pushed would take the shape of whoever
  ## pushed before this program.
  if e.pushed: e.caps.popBytes
  elif e.dirty: e.caps.resetBytes
  else: ""

func resumeBytes*(e: PointerEmitter): string =
  ## The bytes that show the last shape again after a stop is continued (§5.4).
  ## The stop wrote `restoreBytes`, so a kitty terminal needs its push again.
  if not e.hasShown: ""
  elif e.pushed: e.caps.pushBytes(e.shown)
  else: e.caps.setBytes(e.shown)
