## personas.nim — the terminal PERSONAS captured from real terminals
## (CodeTracer-TUI-Terminal-Adaptation.md §13.1).
##
## NOT A TEST FILE (the lanes find `test_*.nim`); a library the PLAT-71 suites
## import. Nothing here calls `check`.
##
## A persona is the set of answers one real terminal gives to CodeTracer's
## start-up round. Each `<id>.json` beside this file was written by
## `tools/capture-terminal-persona`, run INSIDE that terminal by the
## `tui-real-emulators` lane (`ci/test/tui-real-emulators.sh`): the round the
## binary writes, the reply bytes verbatim and in order, the terminal's version
## and launch line, the host and the date. The lane re-captures every persona
## on every run and fails when a committed one no longer matches its terminal
## (`CT_REAL_EMULATORS_UPDATE_PERSONAS=1` rewrites them).
##
## Embedded at compile time (`staticRead`), so a suite needs no path at run
## time and a persona that is not committed is a compile error, not a skip.
##
## Two readers:
##
##   * `probeOf` — the `TerminalProbe` the shipped `host/terminal_probe.noteReply`
##     builds from these replies. Written over the app-level parsers because
##     `app/tests/` may not import `host/`; `tests/test_plat71_terminal_round.nim`
##     feeds the same bytes through `noteReply` itself and asserts the two
##     agree field by field, so this reading cannot drift from the shipped one.
##   * `answerFor` — the bytes this terminal wrote back for one question of the
##     round, for the real-pty persona peer (`real_terminal/persona_peer.nim`).

import std/[json, math, os, strutils]

import ../../theme/capabilities

const
  PersonaSchema* = "codetracer-terminal-persona/1"
  PersonaDir = currentSourcePath().parentDir
  CapturedIds* = [
    "kitty-0.44.0", "xterm-403", "ghostty-1.3.1", "alacritty-0.16.1",
    "foot-1.25.0", "tmux-3.6a-in-kitty-0.44.0"]
    ## Every committed persona. The lane captures exactly these terminals.

  PersonaTexts = block:
    var texts: seq[(string, string)]
    for id in CapturedIds:
      texts.add (id, staticRead(PersonaDir / id & ".json"))
    texts

type
  CapturedPersona* = object
    id*: string
    terminal*, version*, launch*, capturedAt*, host*: string
    env*: JsonNode
    replies*: seq[string]
      ## Every reply token, in arrival order.
    answers*: JsonNode
      ## The same tokens keyed by question (see the capture tool's header).
    fenceMs*: float
    round*: string
      ## The bytes the capture wrote: the binary's round for this terminal.
    afterFence*: string
      ## What it wrote once the fence came back: inside tmux, the wrapped
      ## OSC 22 query (`terminal_probe.pointerQueryAfterFence`); "" elsewhere.
    cols*, rows*: int

proc parsePersona*(id, text: string): CapturedPersona =
  let j = parseJson(text)
  if j{"schema"}.getStr != PersonaSchema:
    raise newException(ValueError, id & ": not a " & PersonaSchema & " persona")
  result = CapturedPersona(id: id, terminal: j["terminal"].getStr,
    version: j["version"].getStr, launch: j["launch"].getStr,
    capturedAt: j["capturedAt"].getStr, host: j["host"].getStr,
    env: j["env"], answers: j["answers"],
    fenceMs: (if j["fenceMs"].kind == JNull: -1.0 else: j["fenceMs"].getFloat),
    round: j["round"].getStr, afterFence: j{"afterFence"}.getStr,
    cols: j["cols"].getInt, rows: j["rows"].getInt)
  for r in j["replies"]:
    result.replies.add r.getStr

proc persona*(id: string): CapturedPersona =
  ## The committed persona `id` (one of `CapturedIds`).
  for (pid, text) in PersonaTexts:
    if pid == id:
      return parsePersona(pid, text)
  raise newException(KeyError, "no captured persona " & id)

proc capturedPersonas*(): seq[CapturedPersona] =
  for (pid, text) in PersonaTexts:
    result.add parsePersona(pid, text)

proc provenance*(p: CapturedPersona): string =
  "captured from " & p.terminal & " " & p.version & " on " & p.capturedAt &
    " (" & p.host & ") by tools/capture-terminal-persona; launched as `" &
    p.launch & "`"

proc envVar*(p: CapturedPersona; name: string): string =
  p.env{name}.getStr

proc envOf*(p: CapturedPersona): TerminalEnv =
  ## The environment the terminal gave the capture: its `TERM`, its
  ## `TERM_PROGRAM` and its own markers, under a UTF-8 locale.
  result = initTerminalEnv(term = p.envVar("TERM"), lang = "en_US.UTF-8",
                           colorterm = p.envVar("COLORTERM"),
                           termProgram = p.envVar("TERM_PROGRAM"),
                           termProgramVersion = p.envVar("TERM_PROGRAM_VERSION"),
                           kittyWindowId = p.envVar("KITTY_WINDOW_ID"),
                           tmux = p.envVar("TMUX"))
  result.alacrittyWindowId = p.envVar("ALACRITTY_WINDOW_ID")
  result.ghosttyResourcesDir = p.envVar("GHOSTTY_RESOURCES_DIR")

proc cprCount*(p: CapturedPersona): int = p.answers["cpr"].len

proc answerFor*(p: CapturedPersona; key: string; cprIndex = 0): string =
  ## The reply this terminal gave to the question `key` (the capture's keys:
  ## `xtversion`, `da2`, `da1`, `decrqm.<mode>`, `cpr`, `osc11`,
  ## `xtgettcap`, `decrqss`, `kittyKeyboard`, `cellSize`, `osc22`), or ""
  ## when it gave none.
  if key == "cpr":
    let c = p.answers["cpr"]
    return (if cprIndex < c.len: c[cprIndex].getStr else: "")
  if key.startsWith("decrqm."):
    return p.answers["decrqm"]{key["decrqm.".len .. ^1]}.getStr
  p.answers{key}.getStr

proc decodeHexText(s: string): string =
  var i = 0
  while i + 1 < s.len:
    try:
      result.add char(fromHex[int](s[i .. i + 1]))
    except ValueError:
      return ""
    i += 2

proc probeOf*(p: CapturedPersona; cprExpected = 6): TerminalProbe =
  ## The probe `noteReply` builds from `p.replies` up to and including the
  ## DA1 fence (see the module header for why this is not `noteReply` itself).
  result = TerminalProbe(attempted: true, cprExpected: cprExpected)
  for token in p.replies:
    if token.startsWith("\x1b[?") and token.endsWith("c"):
      result.answered = true
      break
    let (isCpr, _, col) = parseCpr(token)
    if isCpr and result.cprAnswers.len < cprExpected:
      result.cprAnswers.add max(0, col - 1)
    elif token.startsWith("\x1bP>|"):
      let (ok, text) = parseXtversionReply(token)
      if ok: result.xtversion = text
    elif isDa2Reply(token):
      let (ok, pp, pv) = parseDa2(token)
      if ok:
        result.da2Answered = true
        result.da2Pp = pp
        result.da2Pv = pv
    elif token.startsWith("\x1b[?2026;") or token.startsWith("\x1b[?2027;"):
      let (ok, mode, ps) = parseDecrqm(token)
      if ok and mode == 2026:
        result.sync2026Answered = true
        result.sync2026 = ps
      elif ok and mode == 2027:
        result.grapheme2027Answered = true
        result.grapheme2027 = ps
    elif token.startsWith("\x1b[?1016;") and token.endsWith("$y"):
      result.pixelMouseAnswered = true
      try:
        result.pixelMouse = parseInt(token["\x1b[?1016;".len ..< token.len - 2]) in {1, 2, 3}
      except ValueError:
        result.pixelMouse = false
    elif token.startsWith("\x1b[?") and token.endsWith("u"):
      result.kittyKeyboardAnswered = true
    elif isPointerReply(token):
      let (ok, reply) = parsePointerReply(token)
      if ok:
        result.pointerAnswered = true
        result.pointerReply = reply
    elif token.startsWith("\x1b[6;") and token.endsWith("t"):
      let parts = token["\x1b[6;".len ..< token.len - 1].split(';')
      if parts.len == 2:
        try:
          let h = parseInt(parts[0])
          let w = parseInt(parts[1])
          if h > 0 and w > 0:
            result.cellHeightPx = h
            result.cellWidthPx = w
        except ValueError:
          discard
    elif token.startsWith("\x1b]11;"):
      let (ok, rgb) = parseOsc11Reply(token)
      if ok:
        result.hasBackground = true
        result.background = rgb
    elif token.startsWith("\x1bP1+r"):
      for item in token[5 .. ^1].split('\x1b')[0].split(';'):
        if decodeHexText(item.split('=')[0]) in ["RGB", "Tc"]:
          result.truecolor = true
          if result.truecolorVia.len == 0:
            result.truecolorVia = "xtgettcap"
    elif token.startsWith("\x1bP1$r"):
      if (token.contains("48:2") or token.contains("48;2")) and
         (token.contains(":1:2:3") or token.contains(";1;2;3")):
        result.truecolor = true
        if result.truecolorVia.len == 0:
          result.truecolorVia = "decrqss"
  # Inside tmux the pointer query was asked after the fence, and the outer
  # terminal's answer arrived after it too.
  if p.afterFence.len > 0:
    let (ok, reply) = parsePointerReply(p.answers{"osc22"}.getStr)
    if ok:
      result.pointerAnswered = true
      result.pointerReply = reply
  if p.fenceMs >= 0:
    result.rttMeasured = true
    result.rttMs = int(round(p.fenceMs))
