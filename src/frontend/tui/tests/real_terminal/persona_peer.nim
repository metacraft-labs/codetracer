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
## The answers are WRITTEN FROM each terminal's documentation (§3.2's
## sources), not yet captured from the real emulators: capturing them is
## PLAT-71 Part E's lane, which is owed, and each persona says so. A cursor
## report is answered from the persona's own width table for the probe glyph
## the binary printed — libvterm has no ambiguous-wide setting, so its cursor
## could not stand for a terminal set to draw East Asian Width `A` wide.

import std/[os, strutils, tables, times]

import term_assert

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
    delayMs*: int
      ## How long the terminal takes to answer (a slow link).

  PeerLog* = object
    answered*: seq[string]
      ## What the peer wrote, in order.
    queries*: seq[string]
      ## What it was asked, in order.
    cursorReports*: int

const
  KnownQueries* = [
    "\x1b]11;?\x1b\\", "\x1bP+q524742;5463\x1b\\", "\x1bP$qm\x1b\\",
    "\x1b[?1016$p", "\x1b[16t", "\x1b[?u", "\x1b[>q", "\x1b[>c",
    "\x1b[?2026$p", "\x1b[?2027$p", "\x1b[6n", "\x1b[c"]
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
  of "\x1b[?u": (if p.kittyKeyboard: "\x1b[?0u" else: "")
  of "\x1b[6n":
    (if cprIndex < p.widths.len: "\x1b[1;" & $(p.widths[cprIndex] + 1) & "R"
     else: "")
  of "\x1b[c": p.da1
  else: ""

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
# The personas (§13.1). WRITTEN FROM DOCUMENTATION — capture owed (Part E).
# ---------------------------------------------------------------------------

proc kitty*(): Persona =
  Persona(name: "kitty 0.36.4",
          provenance: "written from kitty's documentation (XTVERSION, " &
                      "DECRQM 2026, the keyboard protocol); not captured",
          xtversion: "kitty(0.36.4)", da2: "\x1b[>1;4000;29c",
          da1: "\x1b[?62;22c", modes: {2026: 2, 2027: 0, 1016: 2}.toTable,
          widths: @[1, 1, 1, 1, 2, 2], kittyKeyboard: true)

proc foot*(): Persona =
  Persona(name: "foot 1.16.2",
          provenance: "written from foot's CHANGELOG and foot.ini(5); not " &
                      "captured",
          xtversion: "foot(1.16.2)", da2: "\x1b[>1;11602;0c",
          da1: "\x1b[?62;4;22c", modes: {2026: 2, 2027: 2, 1016: 2}.toTable,
          widths: @[1, 1, 1, 1, 2, 2], kittyKeyboard: true)

proc vteWide*(): Persona =
  Persona(name: "VTE 0.76, ambiguous-width characters set Wide",
          provenance: "written from VTE's src/modes.py and the GNOME " &
                      "Terminal profile option; not captured",
          xtversion: "VTE(7600)", da2: "\x1b[>65;7600;1c",
          da1: "\x1b[?65;1;9c", modes: {2026: 4, 2027: 0}.toTable,
          widths: @[2, 2, 1, 2, 2, 2])

proc xterm*(): Persona =
  Persona(name: "xterm 389",
          provenance: "written from invisible-island.net/xterm/ctlseqs; not " &
                      "captured",
          xtversion: "XTerm(389)", da2: "\x1b[>41;389;0c",
          da1: "\x1b[?64;1;2;6;9;15;16;17;18;21;22;28c",
          modes: {2026: 0, 2027: 0, 1016: 2}.toTable,
          widths: @[1, 1, 1, 1, 2, 4])

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
