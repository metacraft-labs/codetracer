## capture-terminal-persona — run CodeTracer's terminal start-up round in the
## terminal this program runs in, and save the terminal's answers as a
## PERSONA fixture (CodeTracer-TUI-Terminal-Adaptation.md §13.1).
##
## A persona is the set of answers one real terminal gives. The suites that
## test the profile (`app/tests/test_plat71_terminal_profile.nim`,
## `tests/test_plat71_terminal_round.nim`) and the real-pty persona peer
## (`tests/real_terminal/persona_peer.nim`) replay these bytes verbatim, so the
## decisions under test are made on what the terminal really said.
##
## ## What it writes, and why it is the shipped round
##
## The bytes written are `host/terminal_probe.queriesFor` for the default
## command line and this terminal's environment — the same function the
## binary calls before frame 0 — so a persona cannot drift from the round it
## stands in for. They are written once, after raw mode and the alternate
## screen, exactly as `runStartupProbe` writes them.
##
## ## What it saves
##
## `--out FILE` gets one JSON object (schema `codetracer-terminal-persona/1`):
##
##   * `terminal`, `version`, `launch` — what the caller says it started
##     (`--terminal`, `--version`, `--launch`), so a fixture names the build
##     and the configuration it was captured with;
##   * `capturedAt`, `host` — the date (UTC) and `uname -srm`;
##   * `env` — the variables the profile reads (`TERM`, `TERM_PROGRAM`, the
##     terminals' own markers, `TMUX` present or not);
##   * `cols`, `rows`, `fenceMs` — the window and the time from the write to
##     the DA1 answer;
##   * `round` — the bytes written;
##   * `replies` — every reply token, in arrival order, verbatim;
##   * `answers` — the same tokens keyed by the question they answer
##     (`xtversion`, `da2`, `da1`, `decrqm.<mode>`, `cpr` in order, `osc11`,
##     `xtgettcap`, `decrqss`, `kittyKeyboard`, `cellSize`, `osc22`), and
##     `late` for anything after the fence.
##
## Reading continues for `--grace` ms after the fence (default 400), because
## some answers are written after it by design (Pointer-Affordances §5.5's
## wrapped OSC 22 query through tmux) and others by mistake; both are
## measured, not assumed.
##
## Run by the `tui-real-emulators` lane inside each real terminal, and by hand
## when a terminal updates:
##
##     capture-terminal-persona --terminal kitty --version 0.44.0 \
##       --launch 'kitty --config NONE' --out kitty.json

import std/[json, monotimes, os, osproc, posix, strutils, termios, times]

import ../../src/frontend/tui/host/capabilities
import ../../src/frontend/tui/host/terminal_probe

const PersonaSchema* = "codetracer-terminal-persona/1"

type
  Options = object
    outPath, terminal, version, launch: string
    graceMs, timeoutMs: int

proc usage() =
  stderr.writeLine "usage: capture-terminal-persona --out FILE " &
    "[--terminal NAME] [--version V] [--launch TEXT] [--grace MS] " &
    "[--timeout MS]"
  quit(2)

proc parseOptions(): Options =
  result = Options(graceMs: 400, timeoutMs: 3000)
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    proc next(): string =
      inc i
      if i > paramCount(): usage()
      paramStr(i)
    case a
    of "--out": result.outPath = next()
    of "--terminal": result.terminal = next()
    of "--version": result.version = next()
    of "--launch": result.launch = next()
    of "--grace": result.graceMs = parseInt(next())
    of "--timeout": result.timeoutMs = parseInt(next())
    else: usage()
    inc i
  if result.outPath.len == 0: usage()

proc writeAll(fd: cint; s: string) =
  var off = 0
  while off < s.len:
    let n = posix.write(fd, unsafeAddr s[off], s.len - off)
    if n <= 0:
      if errno == EINTR: continue
      return
    off += int(n)

proc readSome(fd: cint; waitMs: int): string =
  ## What arrives on `fd` within `waitMs`; "" on timeout.
  var p = TPollfd(fd: fd, events: POLLIN)
  if poll(addr p, 1, cint(max(0, waitMs))) <= 0:
    return ""
  var buf: array[4096, char]
  let n = posix.read(fd, addr buf[0], buf.len)
  if n <= 0:
    return ""
  result = newString(n)
  copyMem(addr result[0], addr buf[0], n)

proc tokens*(bytes: string): seq[string] =
  ## Split a reply stream into escape sequences: CSI (to its final byte), DCS,
  ## OSC and APC (to ST or BEL). Anything else is one byte per token.
  var i = 0
  while i < bytes.len:
    if bytes[i] != '\x1b' or i + 1 >= bytes.len:
      result.add $bytes[i]
      inc i
      continue
    let kind = bytes[i + 1]
    var j = i + 2
    case kind
    of '[':
      while j < bytes.len and bytes[j].ord notin 0x40 .. 0x7E:
        inc j
      result.add bytes[i .. min(j, bytes.len - 1)]
      i = j + 1
    of 'P', ']', '_', '^':
      while j < bytes.len:
        if bytes[j] == '\x07':
          inc j
          break
        if bytes[j] == '\x1b' and j + 1 < bytes.len and bytes[j + 1] == '\\':
          j += 2
          break
        inc j
      result.add bytes[i ..< min(j, bytes.len)]
      i = j
    else:
      result.add bytes[i .. i + 1]
      i += 2

proc keyOf*(token: string): string =
  ## The question a reply token answers ("" when it answers none).
  if token.startsWith("\x1bP>|"): "xtversion"
  elif token.startsWith("\x1bP1+r") or token.startsWith("\x1bP0+r"): "xtgettcap"
  elif token.startsWith("\x1bP1$r") or token.startsWith("\x1bP0$r"): "decrqss"
  elif token.startsWith("\x1b]11;"): "osc11"
  elif token.startsWith("\x1b]22;"): "osc22"
  elif token.startsWith("\x1b[?") and token.endsWith("$y"):
    "decrqm." & token[3 ..< token.len - 2].split(';')[0]
  elif token.startsWith("\x1b[?") and token.endsWith("u"): "kittyKeyboard"
  elif token.startsWith("\x1b[6;") and token.endsWith("t"): "cellSize"
  elif token.startsWith("\x1b[>") and token.endsWith("c"): "da2"
  elif token.startsWith("\x1b[?") and token.endsWith("c"): "da1"
  elif token.startsWith("\x1b[") and token.endsWith("R"): "cpr"
  else: ""

const EnvNames = ["TERM", "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
                  "VTE_VERSION", "KONSOLE_VERSION", "KITTY_WINDOW_ID",
                  "WEZTERM_EXECUTABLE", "ALACRITTY_WINDOW_ID",
                  "GHOSTTY_RESOURCES_DIR", "WT_SESSION", "TERMINAL_EMULATOR",
                  "TMUX", "STY", "ZELLIJ", "LANG", "LC_ALL", "LC_CTYPE"]

proc main() =
  let opts = parseOptions()
  let tty = posix.open("/dev/tty", O_RDWR or O_NOCTTY)
  if tty < 0:
    stderr.writeLine "capture-terminal-persona: no controlling terminal"
    quit(1)
  var saved, raw: Termios
  discard tcGetAttr(tty, addr saved)
  raw = saved
  raw.c_iflag = raw.c_iflag and not Cflag(BRKINT or ICRNL or INPCK or ISTRIP or IXON)
  raw.c_oflag = raw.c_oflag and not Cflag(OPOST)
  raw.c_lflag = raw.c_lflag and not Cflag(ECHO or ICANON or IEXTEN or ISIG)
  raw.c_cflag = raw.c_cflag or Cflag(CS8)
  discard tcSetAttr(tty, TCSAFLUSH, addr raw)
  var ws: IOctl_WinSize
  discard ioctl(tty, TIOCGWINSZ, addr ws)
  let cols = max(int(ws.ws_col), 1)
  let rows = max(int(ws.ws_row), 1)
  let env = readTerminalEnv(tty)
  # The default command line's round: no flag pins the theme, the depth or
  # the mouse, so every question the binary can ask is asked.
  let roundBytes = queriesFor(initCapabilityFlags(), env, cols)
  writeAll(tty, "\x1b[?1049h\x1b[?25l")
  let start = getMonoTime()
  writeAll(tty, roundBytes)
  var replies = ""
  var fenceAt = -1.0
  let hardStop = start + initDuration(milliseconds = opts.timeoutMs)
  while getMonoTime() < hardStop:
    var waitMs = int((hardStop - getMonoTime()).inMilliseconds)
    if fenceAt >= 0:
      let graceEnd = fenceAt + opts.graceMs.float
      let nowMs = (getMonoTime() - start).inMicroseconds.float / 1000.0
      if nowMs >= graceEnd: break
      waitMs = min(waitMs, int(graceEnd - nowMs) + 1)
    let got = readSome(tty, waitMs)
    if got.len == 0:
      continue
    replies.add got
    if fenceAt < 0:
      for t in tokens(replies):
        if keyOf(t) == "da1":
          fenceAt = (getMonoTime() - start).inMicroseconds.float / 1000.0
          break
  writeAll(tty, "\x1b[?25h\x1b[?1049l")
  discard tcSetAttr(tty, TCSAFLUSH, addr saved)
  discard posix.close(tty)

  var answers = newJObject()
  var cpr = newJArray()
  var late = newJArray()
  var decrqm = newJObject()
  var fenceSeen = false
  var replyList = newJArray()
  for t in tokens(replies):
    replyList.add %t
    let key = keyOf(t)
    if fenceSeen:
      late.add %t
      continue
    case key
    of "": late.add %t
    of "cpr": cpr.add %t
    of "da1":
      answers["da1"] = %t
      fenceSeen = true
    else:
      if key.startsWith("decrqm."):
        decrqm[key["decrqm.".len .. ^1]] = %t
      else:
        answers[key] = %t
  answers["decrqm"] = decrqm
  answers["cpr"] = cpr
  answers["late"] = late
  var envJ = newJObject()
  for n in EnvNames:
    if existsEnv(n):
      # A session id is a fact about one window, not about the terminal:
      # record THAT it is set, never its value.
      envJ[n] = %(if n in ["TMUX", "KITTY_WINDOW_ID", "ALACRITTY_WINDOW_ID",
                           "WT_SESSION", "STY", "ZELLIJ"]: "set"
                  else: getEnv(n))
  let (uname, _) = execCmdEx("uname -srm")
  let persona = %*{
    "schema": PersonaSchema,
    "terminal": opts.terminal,
    "version": opts.version,
    "launch": opts.launch,
    "capturedAt": now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"),
    "host": uname.strip,
    "env": envJ,
    "cols": cols, "rows": rows,
    "fenceMs": (if fenceAt >= 0: %(float(int(fenceAt * 100 + 0.5)) / 100) else: newJNull()),
    "round": roundBytes,
    "replies": replyList,
    "answers": answers}
  createDir(opts.outPath.parentDir)
  writeFile(opts.outPath, pretty(persona) & "\n")
  quit(if fenceSeen: 0 else: 3)

when isMainModule:
  main()
