## emulators.nim — the real terminal emulators the `tui-real-emulators` lane
## drives (CodeTracer-TUI-Terminal-Adaptation.md §13.4), the displays they run
## on, and the pixel readings of the glyph test card.
##
## NOT A TEST FILE (the lane finds `test_*.nim`); `test_real_emulators.nim`
## imports it. Nothing here calls `check`.
##
## ## The displays
##
## * **Wayland: GuiAssert's headless sway** (`gui_assert/desktop_env/sway`,
##   the target the GPUI window captures use), frames through `grim`. foot is
##   Wayland-only and runs here.
## * **X11: a private Xvfb** (`XvfbTarget` below, a GuiAssert
##   `TargetEnvironment`), frames through ImageMagick's `import`. xterm is
##   X11-only; kitty, Ghostty and Alacritty render with OpenGL, which the
##   headless sway's pixman renderer cannot give a client (kitty: "EGL:
##   Failed to initialize EGL"; Alacritty draws nothing), while Xvfb's GLX
##   runs them on Mesa's software rasterizer. GuiAssert's own `linux-xvfb`
##   session is a CLI backend with its own helpers; a target of the same shape
##   as the sway one is what this lane needs, so it is written here.
##
## Every emulator is started with its configuration files ignored and one font
## (DejaVu Sans Mono, the only directory in the lane's `fonts.conf`), so what
## is measured is the terminal, not this host's settings.

import std/[json, os, osproc, streams, strtabs, strutils, tables, tempfiles, times]

import gui_assert/desktop_env

export desktop_env

type
  DisplayKind* = enum
    dkX11 = "Xvfb"
    dkWayland = "headless sway"

  Emulator* = object
    id*: string
      ## The persona's id: `<terminal>-<version>` (`tmux-3.6a-in-kitty-0.44.0`).
    terminal*: string
      ## The terminal's name as the capture records it (`kitty`, `tmux`).
    package*: string
      ## The nixpkgs attribute `real-emulators-tools.sh` provides it from.
    program*: string
    display*: DisplayKind
    version*: string
    host*: string
      ## For a multiplexer: the emulator it runs in ("" otherwise).
    hostVersion*: string

  XvfbTarget* = ref object of TargetEnvironment
    ## A private Xvfb: its own display number (reported by `-displayfd`, never
    ## guessed) and its own runtime directory.
    width*, height*: int
    runtimeDir: string
    xvfb: Process
    display: string

const
  Cols* = 160
  Rows* = 64
  ScreenW* = 1920
  ScreenH* = 1440

proc newXvfbTarget*(width = ScreenW; height = ScreenH): XvfbTarget =
  XvfbTarget(name: "xvfb", width: width, height: height,
             sessionEnv: newStringTable(modeCaseSensitive))

method start*(t: XvfbTarget) =
  if t.started: return
  t.runtimeDir = createTempDir("ct-emu-x-", "", "/tmp")
  setFilePermissions(t.runtimeDir, {fpUserRead, fpUserWrite, fpUserExec})
  let fdFile = t.runtimeDir / "display"
  try:
    t.xvfb = startProcess("/bin/sh", args = @["-c",
      "exec Xvfb -displayfd 3 -screen 0 " & $t.width & "x" & $t.height &
      "x24 +extension GLX -nolisten tcp 3>" & quoteShell(fdFile) & " >" &
      quoteShell(t.runtimeDir / "xvfb.log") & " 2>&1"], options = {poUsePath})
  except OSError as e:
    raise t.envError("start", "cannot run Xvfb: " & e.msg)
  let deadline = epochTime() + 15
  while true:
    let n = (if fileExists(fdFile): readFile(fdFile).strip else: "")
    if n.len > 0:
      t.display = ":" & n
      break
    if not t.xvfb.running or epochTime() > deadline:
      raise t.envError("start", "Xvfb did not report a display:\n" &
                       (try: readFile(t.runtimeDir / "xvfb.log") except IOError: ""))
    sleep(50)
  t.sessionEnv["DISPLAY"] = t.display
  t.sessionEnv["XDG_RUNTIME_DIR"] = t.runtimeDir
  t.started = true

method stop*(t: XvfbTarget) =
  t.stopSpawned()
  if t.xvfb != nil:
    try:
      if t.xvfb.running:
        t.xvfb.terminate()
        discard t.xvfb.waitForExit(3000)
      if t.xvfb.running: t.xvfb.kill()
      t.xvfb.close()
    except OSError: discard
    t.xvfb = nil
  if t.runtimeDir.len > 0:
    removeDir(t.runtimeDir)
  t.started = false

method capture*(t: XvfbTarget; region: Rect): RgbImage =
  let (output, code) = execCmdEx(quoteShellCommand(["magick", "import",
    "-display", t.display, "-window", "root", "-crop",
    $region.w & "x" & $region.h & "+" & $region.x & "+" & $region.y,
    "+repage", "-depth", "8", "ppm:-"]))
  if code != 0: raise t.envError("capture", output.strip())
  try: decodePpm(output)
  except ValueError as e: raise t.envError("capture", e.msg)

proc displayName*(t: XvfbTarget): string = t.display

# ---------------------------------------------------------------------------
# The emulators and how each is started
# ---------------------------------------------------------------------------

proc versionOf*(versionsFile, package: string): string =
  ## The version in the store path `real-emulators-tools.sh` recorded for
  ## `package` (`/nix/store/<hash>-kitty-0.44.0` -> `0.44.0`); "" when the
  ## package was not provided.
  if not fileExists(versionsFile): return ""
  for line in readFile(versionsFile).splitLines:
    let parts = line.split(' ')
    if parts.len == 2 and parts[0] == package:
      let name = parts[1].extractFilename
      let dash = name.find('-')
      var rest = name[dash + 1 .. ^1]
      # `<pname>-<version>`: the version starts at the first `-<digit>`.
      for i in 0 ..< rest.len - 1:
        if rest[i] == '-' and rest[i + 1] in Digits:
          return rest[i + 1 .. ^1]
      return ""
  ""

proc missingReason*(missingFile, package: string): string =
  if not fileExists(missingFile): return ""
  for line in readFile(missingFile).splitLines:
    if line.startsWith(package & ":"):
      return line
  ""

proc emulatorTable*(versionsFile: string): seq[Emulator] =
  ## The lane's terminals, X11 first: GuiAssert's sway target exports its
  ## `WAYLAND_DISPLAY` into this process, which would make a later X11 client
  ## prefer Wayland.
  proc emu(terminal, package, program: string; display: DisplayKind): Emulator =
    let v = versionOf(versionsFile, package)
    Emulator(id: terminal & "-" & v, terminal: terminal, package: package,
             program: program, display: display, version: v)
  result = @[emu("kitty", "kitty", "kitty", dkX11),
             emu("xterm", "xterm", "xterm", dkX11),
             emu("ghostty", "ghostty", "ghostty", dkX11),
             emu("alacritty", "alacritty", "alacritty", dkX11)]
  var tmux = emu("tmux", "tmux", "tmux", dkX11)
  tmux.host = "kitty"
  tmux.hostVersion = versionOf(versionsFile, "kitty")
  tmux.id = "tmux-" & tmux.version & "-in-kitty-" & tmux.hostVersion
  result.add tmux
  result.add emu("foot", "foot", "foot", dkWayland)

const FontName* = "DejaVu Sans Mono"

proc tmuxConf*(dir: string): string =
  ## §11.4's lines: the configuration the user guide recommends.
  result = dir / "tmux.conf"
  writeFile(result, "set -g mouse on\n" &
    "set -as terminal-features ',xterm-kitty*:RGB'\n" &
    "set -g extended-keys on\nset -g allow-passthrough on\n" &
    "set -g set-clipboard on\nset -g focus-events on\n" &
    "set -g status off\nset -g escape-time 0\n")

proc argvFor*(e: Emulator; shellCmd, workDir: string): seq[string] =
  ## The command line that opens `e` running `sh -c shellCmd`, Cols x Rows
  ## cells, configuration files ignored, the lane's font.
  let sh = @["sh", "-c", shellCmd]
  case e.terminal
  of "kitty":
    @["kitty", "--config", "NONE", "-o", "font_family=" & FontName,
      "-o", "cursor_blink_interval=0",
      "-o", "font_size=11", "-o", "remember_window_size=no",
      "-o", "initial_window_width=" & $Cols & "c",
      "-o", "initial_window_height=" & $Rows & "c",
      "-o", "window_padding_width=0", "-o", "update_check_interval=0",
      "-o", "linux_display_server=x11"] & sh
  of "xterm":
    @["xterm", "-fa", FontName, "-fs", "11", "-geometry", $Cols & "x" & $Rows & "+0+0",
      "-bw", "0", "-b", "0", "+sb", "-e"] & sh
  of "ghostty":
    @["ghostty", "--config-default-files=false", "--font-family=" & FontName,
      "--font-size=11", "--window-decoration=false", "--gtk-titlebar=false",
      "--window-width=" & $Cols, "--window-height=" & $Rows,
      "--window-padding-x=0", "--window-padding-y=0",
      "--window-padding-balance=false", "--confirm-close-surface=false",
      "--shell-integration=none", "--cursor-style-blink=false", "-e"] & sh
  of "alacritty":
    @["alacritty", "--config-file", "/dev/null",
      "-o", "font.normal.family=\"" & FontName & "\"", "-o", "font.size=11",
      "-o", "window.dimensions.columns=" & $Cols,
      "-o", "window.dimensions.lines=" & $Rows,
      "-o", "window.decorations=\"None\"", "-e"] & sh
  of "foot":
    @["foot", "--config=/dev/null", "--font=" & FontName & ":size=11",
      "--window-size-chars=" & $Cols & "x" & $Rows] & sh
  of "tmux":
    # tmux inside kitty: one private server (`-L`), the guide's options, the
    # command as the session's only window; the server exits with it.
    # `sleep 1` first: tmux learns its client's identity (XTVERSION,
    # `client_termtype`) and attaches it a moment after the session starts,
    # and before that `display -p` has no client to describe.
    let inner = "tmux -L ct-lane-" & $getCurrentProcessId() & " -f " &
                quoteShell(tmuxConf(workDir)) & " new-session -x " & $Cols &
                " -y " & $Rows & " " & quoteShell("sleep 1; " & shellCmd)
    argvFor(Emulator(terminal: "kitty"), inner, workDir)
  else:
    raise newException(ValueError, "no command line for " & e.terminal)

# ---------------------------------------------------------------------------
# Running one command in a fresh window
# ---------------------------------------------------------------------------

proc pressReturn*(t: TargetEnvironment; display: DisplayKind) =
  ## Focus the (only) window on the display and press Return in it, as a
  ## user would: a terminal takes an OSC 52 write only from a window that
  ## has had input — Wayland's `set_selection` needs an input event's serial
  ## (foot), and Alacritty on X11 sets nothing before it has focus and a key.
  case display
  of dkWayland:
    t.keys("Return")
  of dkX11:
    let d = t.sessionEnv["DISPLAY"]
    let (ids, _) = execCmdEx("DISPLAY=" & d &
                             " xdotool search --onlyvisible --name '.*'")
    for id in ids.splitLines:
      if id.strip.len == 0: continue
      discard execCmdEx("DISPLAY=" & d & " xdotool windowfocus --sync " &
                        id.strip & " key --window " & id.strip & " Return")

proc runIn*(t: TargetEnvironment; e: Emulator; shellCmd, workDir: string;
            env: seq[(string, string)]; done: string;
            timeout = initDuration(seconds = 90);
            whileOpen: proc() = nil; typeReturn = false): bool =
  ## Open `e` running `shellCmd; touch done; sleep`, wait for `done`, call
  ## `whileOpen` (the window still shows the result), then close the window.
  ## With `typeReturn`, the command first waits for a line and Return is
  ## pressed in the window once it is up (`pressReturn`). False when `done`
  ## never appeared.
  removeFile(done)
  let ready = done & ".ready"
  removeFile(ready)
  let pre = if typeReturn: "touch " & quoteShell(ready) & "; read -r _; " else: ""
  let cmd = pre & shellCmd & "; touch " & quoteShell(done) & "; sleep 600"
  discard t.spawn(argvFor(e, cmd, workDir), env, workingDir = workDir)
  if typeReturn:
    let readyBy = epochTime() + 30
    while not fileExists(ready) and epochTime() < readyBy: sleep(100)
    sleep(500)
    t.pressReturn(e.display)
  let deadline = epochTime() + timeout.inMilliseconds.float / 1000
  while not fileExists(done) and epochTime() < deadline:
    sleep(100)
  result = fileExists(done)
  if result and whileOpen != nil:
    whileOpen()
  t.stopSpawned()
  # The window's own children (the shell, `sleep`, a tmux server) are not
  # the spawned process; end whatever still names this work directory.
  # `[t]ouch`: the pattern does not match the shell `pkill` runs in.
  discard execCmdEx("pkill -f " & quoteShell("[t]ouch " & done))

proc typescriptJson*(path: string): JsonNode =
  ## The `--capabilities=json` report in a `script` typescript: the object
  ## printed after the binary left the alternate screen.
  let bytes = readFile(path)
  let leave = bytes.rfind("\x1b[?1049l")
  let start = bytes.find('{', max(0, leave))
  let stop = bytes.rfind('}')
  if start < 0 or stop < start:
    raise newException(ValueError, "no JSON report in " & path)
  parseJson(bytes[start .. stop].replace("\r\n", "\n"))

proc stripSgr*(s: string): string =
  ## `s` without CSI sequences (the card's colours) and carriage returns.
  var i = 0
  while i < s.len:
    if s[i] == '\x1b' and i + 1 < s.len and s[i + 1] == '[':
      var j = i + 2
      while j < s.len and s[j].ord notin 0x40 .. 0x7E: inc j
      i = j + 1
    elif s[i] == '\r':
      inc i
    else:
      result.add s[i]
      inc i

proc typescriptLines*(path: string): seq[string] =
  ## The lines the binary printed after leaving the alternate screen — what
  ## the window shows from its first row, the shell having cleared it.
  let bytes = readFile(path)
  let leave = bytes.rfind("\x1b[?1049l")
  let tail = bytes[(if leave >= 0: leave + "\x1b[?1049l".len else: 0) .. ^1]
  for line in stripSgr(tail).split('\n'):
    result.add line
  while result.len > 0 and result[^1].strip.len == 0:
    result.setLen(result.len - 1)

# ---------------------------------------------------------------------------
# The card on the screen: the grid, and what a cell holds
# ---------------------------------------------------------------------------

type
  Grid* = object
    x0*, y0*: float
      ## The top-left pixel of cell (0, 0).
    cw*, ch*: float
      ## The cell's size in pixels.

  Ink* = object
    ## The pixels of one cell that differ from the cell's background.
    count*: int
    minX*, maxX*, minY*, maxY*: int
      ## Relative to the cell's left / top edge; -1 when nothing is inked.
    total*: int

proc luma(p: (uint8, uint8, uint8)): int =
  (int(p[0]) * 299 + int(p[1]) * 587 + int(p[2]) * 114) div 1000

proc cellRect*(g: Grid; col, row: int; span = 1): (int, int, int, int) =
  let x = int(g.x0 + col.float * g.cw + 0.5)
  let y = int(g.y0 + row.float * g.ch + 0.5)
  let x2 = int(g.x0 + (col + span).float * g.cw + 0.5)
  let y2 = int(g.y0 + (row + 1).float * g.ch + 0.5)
  (x, y, x2 - x, y2 - y)

proc inkOf*(img: RgbImage; g: Grid; col, row: int; bg: int; span = 1): Ink =
  ## The inked pixels of a cell: luma more than 60 from the background's.
  let (x, y, w, h) = g.cellRect(col, row, span)
  result = Ink(minX: -1, maxX: -1, minY: -1, maxY: -1, total: w * h)
  for yy in 0 ..< h:
    for xx in 0 ..< w:
      let px = x + xx
      let py = y + yy
      if px < 0 or py < 0 or px >= img.width or py >= img.height: continue
      if abs(luma(img.pixel(px, py)) - bg) > 60:
        inc result.count
        if result.minX < 0 or xx < result.minX: result.minX = xx
        if xx > result.maxX: result.maxX = xx
        if result.minY < 0 or yy < result.minY: result.minY = yy
        if yy > result.maxY: result.maxY = yy

proc background*(img: RgbImage; g: Grid; col, row: int): int =
  ## The luma most common in a cell known to be blank.
  var counts = initCountTable[int]()
  let (x, y, w, h) = g.cellRect(col, row)
  for yy in 0 ..< h:
    for xx in 0 ..< w:
      if x + xx < img.width and y + yy < img.height:
        counts.inc luma(img.pixel(x + xx, y + yy))
  counts.largest[0]

type
  BlockShape* = object
    ## A block element's ink, as fractions of the cell: [x1, x2) × [y1, y2).
    x1*, x2*, y1*, y2*: float

const BlockShapes* = {
  "▕": BlockShape(x1: 7/8, x2: 1, y1: 0, y2: 1),     # U+2595 right one eighth
  "▏": BlockShape(x1: 0, x2: 1/8, y1: 0, y2: 1),     # U+258F left one eighth
  "▁": BlockShape(x1: 0, x2: 1, y1: 7/8, y2: 1),     # U+2581 lower one eighth
  "▔": BlockShape(x1: 0, x2: 1, y1: 0, y2: 1/8),     # U+2594 upper one eighth
  "▐": BlockShape(x1: 1/2, x2: 1, y1: 0, y2: 1),     # U+2590 right half
  "█": BlockShape(x1: 0, x2: 1, y1: 0, y2: 1),       # U+2588 full
  "🮇": BlockShape(x1: 3/4, x2: 1, y1: 0, y2: 1),    # U+1FB87 right one quarter
  "🮂": BlockShape(x1: 0, x2: 1, y1: 0, y2: 1/4),    # U+1FB82 upper one quarter
  "🭰": BlockShape(x1: 1/8, x2: 2/8, y1: 0, y2: 1),  # U+1FB70 vertical 1/8 #2
  "🭻": BlockShape(x1: 0, x2: 1, y1: 6/8, y2: 7/8)}.toTable  # U+1FB7B #7

proc matchesShape*(ink: Ink; s: BlockShape; g: Grid): (bool, string) =
  ## Whether a cell's ink is the block `s`: its extent within one pixel (or a
  ## sixteenth of the cell) of the shape's edges, and the shape's rectangle
  ## at least 80 % inked. The reason names what differs.
  let tolX = max(1.5, g.cw / 16)
  let tolY = max(1.5, g.ch / 16)
  let ex1 = s.x1 * g.cw
  let ex2 = s.x2 * g.cw - 1
  let ey1 = s.y1 * g.ch
  let ey2 = s.y2 * g.ch - 1
  let area = max(1.0, (s.x2 - s.x1) * g.cw * (s.y2 - s.y1) * g.ch)
  let what = "ink x " & $ink.minX & ".." & $ink.maxX & " y " & $ink.minY &
             ".." & $ink.maxY & " (" & $ink.count & " px); expected x " &
             formatFloat(ex1, ffDecimal, 1) & ".." & formatFloat(ex2, ffDecimal, 1) &
             " y " & formatFloat(ey1, ffDecimal, 1) & ".." &
             formatFloat(ey2, ffDecimal, 1)
  if ink.count == 0:
    return (false, "nothing drawn; " & what)
  let ok = abs(ink.minX.float - ex1) <= tolX and abs(ink.maxX.float - ex2) <= tolX and
           abs(ink.minY.float - ey1) <= tolY and abs(ink.maxY.float - ey2) <= tolY and
           ink.count.float >= 0.8 * area
  (ok, what)

proc columnProfile*(img: RgbImage; g: Grid; col, row, bg: int;
                    shift = 0): seq[int] =
  ## The inked pixels per pixel column of a cell, the cell moved `shift`
  ## pixels right.
  let (x, y, w, h) = g.cellRect(col, row)
  for xx in 0 ..< w:
    var n = 0
    for yy in 0 ..< h:
      let px = x + xx + shift
      if px >= 0 and px < img.width and y + yy < img.height and
         abs(luma(img.pixel(px, y + yy)) - bg) > 60:
        inc n
    result.add n

proc similarity*(a, b: seq[int]): float =
  ## 1 - (sum of differences / sum of ink): 1 for identical profiles.
  var diff, total = 0
  for i in 0 ..< min(a.len, b.len):
    diff += abs(a[i] - b[i])
    total += max(a[i], b[i])
  if total == 0: return 0.0
  1.0 - diff.float / total.float

proc writePng*(img: RgbImage; path: string) =
  ## The frame as a PNG for people (and the failure artefact).
  var s = "P6\n" & $img.width & " " & $img.height & "\n255\n"
  let off = s.len
  s.setLen(off + img.data.len)
  for i, b in img.data: s[off + i] = char(b)
  let ppm = path.changeFileExt("ppm")
  writeFile(ppm, s)
  discard execCmdEx(quoteShellCommand(["magick", ppm, path]))
  removeFile(ppm)
