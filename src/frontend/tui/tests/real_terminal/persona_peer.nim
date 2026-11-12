## persona_peer.nim — PLAT-71 (CodeTracer-TUI-Terminal-Adaptation.md §13.2):
## the PERSONA PEER. The pty's other end answers the shipped binary's
## start-up queries as one terminal would.
##
## NOT A TEST FILE (the lane finds `test_*.nim`; this is a library the PLAT-71
## suites import). Nothing here calls `check`.
##
## ## Why the peer is not a mock
##
## The subject — the shipped `codetracer-tui`, its round, its framer, its
## resolver, its repaint — is real and untouched. The peer stands in for the
## terminal EMULATOR, because fifteen emulators cannot run in CI; it reads
## the binary's real byte stream off the pty (`transcriptBytes`) and writes
## answers into the real pty, in the order a terminal answers. `nim-libvterm`
## parses the screen the suites read and answers nothing itself.
##
## kitty, foot, xterm, Ghostty, Alacritty and tmux are CAPTURED: their
## answers are the bytes each real terminal wrote back to the binary's round
## (`app/tests/personas/<id>.json`, taken by `tools/capture-terminal-persona`
## inside the real emulator by the `tui-real-emulators` lane, which also
## checks on every run that the terminal still answers so). `fromCapture`
## carries every answer over verbatim, and `test_plat71_terminal_round.nim`
## checks that `answerFor` gives back exactly the captured bytes. The VTE
## set to ambiguous WIDE and the Linux console are still WRITTEN from their
## documentation (neither runs on the lane's host), and the silent and slow
## personas are synthetic; each says so in its provenance. A cursor report is
## answered from the persona's width table for the probe glyph the binary
## printed — the same bytes the real terminal sent, since the probe prints at
## the top-left — because libvterm has no ambiguous-wide setting, so its
## cursor could not stand for a terminal set to draw East Asian Width `A`
## wide.

import std/[json, os, strutils, tables, times]

import term_assert

import ../../app/theme/terminal_profile
import ../../app/tests/personas/personas

export personas

type
  Persona* = object
    name*: string
    provenance*: string
    xtversion*: string
      ## The text inside `DCS > | … ST`; "" answers nothing.
    da2*: string
      ## The whole DA2 answer; "" answers nothing.
    da1*: string
      ## The fence's answer; "" for a SILENT terminal (it answers nothing).
    modes*: Table[int, int]
      ## DECRQM: mode -> `Ps`. A mode not listed is not answered.
    widths*: seq[int]
      ## The width the terminal advances for each width-probe glyph, in the
      ## order the binary prints them (P1 … P6); a missing entry, no report.
    kittyKeyboard*: bool
    pointerReply*: string
      ## The answer to OSC 22's query, `1,0,…`; "" answers nothing.
    delayMs*: int
      ## How long the terminal takes to answer (a slow link).
    verbatim*: Table[string, string]
      ## A captured persona's other answers, by question (`OSC 11`,
      ## XTGETTCAP, DECRQSS, the cell size, the Kitty keyboard flags),
      ## written back byte for byte.

  PeerLog* = object
    answered*: seq[string]
      ## What the peer wrote, in order.
    queries*: seq[string]
      ## What it was asked, in order.
    cursorReports*: int

const
  PointerQuery* =
    "\x1b]22;?default,pointer,text,col-resize,row-resize,grab,grabbing," &
    "not-allowed,ew-resize,ns-resize\x1b\\"
  WrappedPointerQuery* =
    "\x1bPtmux;\x1b\x1b]22;?default,pointer,text,col-resize,row-resize,grab," &
    "grabbing,not-allowed,ew-resize,ns-resize\x1b\x1b\\\x1b\\"
  KnownQueries* = [
    "\x1b]11;?\x1b\\", "\x1bP+q524742;5463\x1b\\", "\x1bP$qm\x1b\\",
    "\x1b[?1016$p", "\x1b[16t", "\x1b[?u", "\x1b[>q", "\x1b[>c",
    "\x1b[?2026$p", "\x1b[?2027$p", "\x1b[6n", "\x1b[c", WrappedPointerQuery, PointerQuery]
    ## Every question of the start-up round (`host/terminal_probe`).
  Da1Query* = "\x1b[c"
  CprQuery* = "\x1b[6n"

proc epochTimeMs*(): int64 =
  ## Wall-clock milliseconds, for the peer's deadline.
  int64(epochTime() * 1000.0)

proc nextQuery(bytes: string; start: int): (int, string) =
  ## The earliest known query at or after `start`.
  var best = -1
  var which = ""
  for q in KnownQueries:
    let at = bytes.find(q, start)
    if at >= 0 and (best < 0 or at < best):
      best = at
      which = q
  (best, which)

proc answerFor*(p: Persona; query: string; cprIndex: int): string =
  ## What this persona writes back for `query` ("" for silence).
  if p.da1.len == 0:
    return ""        # a silent terminal answers nothing at all
  case query
  of "\x1b[>q":
    (if p.xtversion.len > 0: "\x1bP>|" & p.xtversion & "\x1b\\" else: "")
  of "\x1b[>c": p.da2
  of "\x1b[?2026$p", "\x1b[?2027$p", "\x1b[?1016$p":
    let mode = parseInt(query[3 ..< query.len - 2])
    (if mode in p.modes: "\x1b[?" & $mode & ";" & $p.modes[mode] & "$y"
     else: "")
  of "\x1b[?u":
    (if "\x1b[?u" in p.verbatim: p.verbatim["\x1b[?u"]
     elif p.kittyKeyboard: "\x1b[?0u" else: "")
  of "\x1b[6n":
    (if cprIndex < p.widths.len: "\x1b[1;" & $(p.widths[cprIndex] + 1) & "R"
     else: "")
  of PointerQuery, WrappedPointerQuery:
    (if p.pointerReply.len > 0: "\x1b]22;" & p.pointerReply & "\x1b\\" else: "")
  of "\x1b[c": p.da1
  else: p.verbatim.getOrDefault(query, "")

proc serve*(sess: var TuiTestSession; p: Persona; timeoutMs = 20000;
            fromByte = 0): PeerLog =
  ## Answer the round the binary writes, in order, until its fence has been
  ## answered (or, for a silent persona, until the fence was asked). Each
  ## answer waits `p.delayMs` first — the whole round arrives after one round
  ## trip, as it does over a slow link.
  var at = fromByte
  var cpr = 0
  let deadline = epochTimeMs() + timeoutMs
  var pending = ""
  while epochTimeMs() < deadline:
    discard sess.drainOutput(15)
    let bytes = sess.transcriptBytes()
    while true:
      let (pos, q) = nextQuery(bytes, at)
      if pos < 0:
        break
      at = pos + q.len
      result.queries.add q
      let a = p.answerFor(q, cpr)
      if q == CprQuery:
        inc cpr
        inc result.cursorReports
      if a.len > 0:
        pending.add a
        result.answered.add a
      if q == Da1Query:
        if pending.len > 0:
          if p.delayMs > 0:
            sleep(p.delayMs)
          sess.send(pending)
        return
    if not sess.isAlive:
      return
  if pending.len > 0:
    sess.send(pending)

# ---------------------------------------------------------------------------
# The personas (§13.1): captured from the real terminals, and the written ones
# no terminal on the lane's host can stand for.
# ---------------------------------------------------------------------------

proc stringBody(reply, prefix: string): string =
  ## The text of a DCS / OSC reply between `prefix` and its terminator (ST
  ## or BEL).
  result = reply[prefix.len .. ^1]
  if result.endsWith("\x1b\\"): result.setLen(result.len - 2)
  elif result.endsWith("\x07"): result.setLen(result.len - 1)

proc fromCapture*(c: CapturedPersona): Persona =
  ## A captured persona as the peer serves it: every answer the terminal
  ## gave, verbatim, for the question it answered.
  result = Persona(name: c.terminal & " " & c.version,
                   provenance: c.provenance, da1: c.answerFor("da1"),
                   da2: c.answerFor("da2"))
  let xt = c.answerFor("xtversion")
  if xt.len > 0:
    result.xtversion = stringBody(xt, "\x1bP>|")
  for mode in [1016, 2026, 2027]:
    let a = c.answerFor("decrqm." & $mode)
    if a.len > 0:
      let (ok, m, ps) = parseDecrqm(a)
      if ok and m == mode: result.modes[mode] = ps
  for i in 0 ..< c.cprCount:
    let (_, _, col) = parseCpr(c.answerFor("cpr", i))
    result.widths.add col - 1
  let ptr22 = c.answerFor("osc22")
  if ptr22.len > 0:
    result.pointerReply = stringBody(ptr22, "\x1b]22;")
  for (key, query) in [("osc11", "\x1b]11;?\x1b\\"),
                       ("xtgettcap", "\x1bP+q524742;5463\x1b\\"),
                       ("decrqss", "\x1bP$qm\x1b\\"), ("cellSize", "\x1b[16t"),
                       ("kittyKeyboard", "\x1b[?u")]:
    let a = c.answerFor(key)
    if a.len > 0: result.verbatim[query] = a
  result.kittyKeyboard = "\x1b[?u" in result.verbatim

proc kitty*(): Persona = fromCapture(persona("kitty-0.44.0"))
proc foot*(): Persona = fromCapture(persona("foot-1.25.0"))
proc xterm*(): Persona = fromCapture(persona("xterm-403"))
proc ghostty*(): Persona = fromCapture(persona("ghostty-1.3.1"))
proc alacritty*(): Persona = fromCapture(persona("alacritty-0.16.1"))
proc tmuxInKitty*(): Persona = fromCapture(persona("tmux-3.6a-in-kitty-0.44.0"))

proc footGraphemeOff*(): Persona =
  ## foot as captured, but answering DEC 2027 `2` (recognised, reset), so the
  ## binary SETS grapheme clustering and the restore has a mode to undo
  ## (TA-10). foot 1.25.0 itself answered `1` (already set): the binary sets
  ## nothing there, which is right, and leaves TA-10's 2027 unexercised.
  result = foot()
  result.name = "foot 1.25.0, DEC 2027 answered 2"
  result.provenance = "the captured foot 1.25.0 persona with DECRQM 2027 " &
                      "answered 2 (recognised, reset) instead of its own 1"
  result.modes[2027] = 2

proc vteWide*(): Persona =
  Persona(name: "VTE 0.76, ambiguous-width characters set Wide",
          provenance: "written from VTE's src/modes.py and the GNOME " &
                      "Terminal profile option; not captured",
          xtversion: "VTE(7600)", da2: "\x1b[>65;7600;1c",
          da1: "\x1b[?65;1;9c", modes: {2026: 4, 2027: 0}.toTable,
          widths: @[2, 2, 1, 2, 2, 2])

proc linuxConsole*(): Persona =
  Persona(name: "the Linux console",
          provenance: "written from console_codes(4): DA and CPR only; not " &
                      "captured",
          da1: "\x1b[?6c", widths: @[1, 1, 1, 1, 1, 4])

proc silent*(): Persona =
  Persona(name: "silent (a bare parser)",
          provenance: "synthetic: answers nothing, not even the fence")

proc slowKitty*(delayMs = 300): Persona =
  result = kitty()
  result.name = "kitty over a slow link (" & $delayMs & " ms)"
  result.provenance = "synthetic: kitty's answers, " & $delayMs &
                      " ms after the round"
  result.delayMs = delayMs
