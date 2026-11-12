## test_real_emulators.nim — the terminal front-end in REAL terminal emulators
## (CodeTracer-TUI-Terminal-Adaptation.md §13.4, the `tui-real-emulators`
## lane).
##
## Persona capture is not proof that a real terminal draws what the profile
## claims. This suite opens each real emulator — kitty, xterm, Ghostty and
## Alacritty on a private Xvfb, foot on GuiAssert's headless sway, and tmux
## inside kitty — and in each, in a fresh window every time:
##
##   1. **The persona.** `tools/capture-terminal-persona` runs the binary's
##      start-up round and saves the answers; they must equal the committed
##      persona of that terminal (`app/tests/personas/<id>.json`), which the tier-1
##      and real-pty suites replay. A terminal update that changes an answer
##      fails here, by field, and `CT_REAL_EMULATORS_UPDATE_PERSONAS=1`
##      re-captures the fixtures.
##   2. **The profile.** The shipped `codetracer-tui --capabilities=json
##      --modern-unicode=auto` (under `script(1)`, so the report reaches a file
##      while the binary still talks to the real terminal): the identity it
##      read is this terminal's, and every axis is recorded as this
##      terminal's MEASURED row of §3.2 (`<out>/measured.json`).
##   3. **The glyph test card** (`--capabilities --card`, what `ct doctor
##      terminal` hands off to), screenshotted: OCR finds the card's title and
##      row labels where the printed lines put them, and pixel checks assert
##      that every closing `]` of the glyph rows sits in its own cell (a glyph
##      drawn wider than it measures pushes it), that the hairline scrollbar
##      thumb is a one-eighth-cell line at the right edge, and whether the
##      Legacy Computing row is drawn as its shapes — which must hold wherever
##      `modern-unicode = auto` turns them on (§6.7: `auto`'s list is earned
##      here).
##   4. **OSC 52.** An OSC 52 write from inside the terminal, then the
##      system clipboard read back (`xclip` on X11, `wl-paste` on Wayland):
##      the terminal ACCEPTED or REFUSED it, and that must be what the
##      profile's clipboard axis said (`osc52…` accepted, `in-app only`
##      refused) — so the copy message §8 shows on a refusing terminal is
##      shown exactly where the copy would be lost.
##
## ## Stand-ins
##
## None. The terminals, the compositor, the X server and the binary are all
## real; the emulators are the pinned nixpkgs builds `ci/test/real-emulators-
## tools.sh` provides, with their configuration files ignored and one font.
##
## ## MISSING-PREREQ, never a silent pass
##
## An emulator whose package could not be provided, or whose display cannot
## start on this host, is a `MISSING-PREREQ SKIP: <id>: <reason>` line and a
## skipped case — named, counted by the lane runner, and never green by
## omission. A missing `codetracer-tui` or capture tool FAILS.
##
## Environment (set by `ci/test/tui-real-emulators.sh`): `CT_REAL_EMULATORS_DIR`
## (tools in `tools/`, results in `out/`), `CT_TUI_BIN`, `CT_CAPTURE_BIN`,
## `CT_PERSONAS_DIR`; optional `CT_REAL_EMULATORS_ONLY` (comma-separated ids'
## prefixes) and `CT_REAL_EMULATORS_UPDATE_PERSONAS=1`.

import std/[base64, json, math, os, osproc, strutils, tables, times, unicode, unittest]

import gui_assert/ocr
import gui_assert/desktop_env/sway

import ./emulators

proc need(name: string): string =
  result = getEnv(name)
  if result.len == 0:
    quit("test_real_emulators: " & name & " is not set " &
         "(run `just test-tui-real-emulators`)", 2)

let
  laneDir = need("CT_REAL_EMULATORS_DIR")
  toolsDir = laneDir / "tools"
  outDir = laneDir / "out"
  tuiBin = need("CT_TUI_BIN")
  captureBin = need("CT_CAPTURE_BIN")
  personasDir = need("CT_PERSONAS_DIR")
  only = getEnv("CT_REAL_EMULATORS_ONLY")
  updatePersonas = getEnv("CT_REAL_EMULATORS_UPDATE_PERSONAS") == "1"

putEnv("PATH", toolsDir / "bin" & ":" & getEnv("PATH"))
# The environment the emulators start from: nothing that names another
# terminal, multiplexer or session (this process may itself run inside tmux
# or over SSH), and a UTF-8 locale. Each emulator sets its own markers.
for v in ["TMUX", "TMUX_PANE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
          "COLORTERM", "STY", "ZELLIJ", "KITTY_WINDOW_ID", "KITTY_PID",
          "KITTY_INSTALLATION_DIR", "KITTY_PUBLIC_KEY", "WEZTERM_EXECUTABLE",
          "WEZTERM_PANE", "VTE_VERSION", "KONSOLE_VERSION",
          "ALACRITTY_WINDOW_ID", "ALACRITTY_SOCKET", "ALACRITTY_LOG",
          "GHOSTTY_RESOURCES_DIR", "GHOSTTY_BIN_DIR", "WT_SESSION",
          "TERMINAL_EMULATOR", "SSH_CONNECTION", "SSH_TTY", "SSH_CLIENT",
          "LC_ALL", "LC_CTYPE", "NO_COLOR", "COLORFGBG", "NERD_FONT",
          "CODETRACER_TUI_GLYPHS", "CODETRACER_TUI_MODERN_UNICODE",
          "CODETRACER_TUI_AMBIGUOUS_WIDTH", "CODETRACER_TUI_COLORS",
          "CODETRACER_TUI_PROBE", "LD_PRELOAD"]:
  delEnv(v)
putEnv("LANG", "C.UTF-8")
putEnv("FONTCONFIG_FILE", toolsDir / "fonts.conf")
createDir(outDir)

var xvfb: XvfbTarget
var swayT: SwayTarget
var measured = newJObject()

proc wanted(e: Emulator): bool =
  if only.len == 0: return true
  for p in only.split(','):
    if p.strip.len > 0 and e.id.startsWith(p.strip): return true
  false

proc targetFor(e: Emulator): (TargetEnvironment, string) =
  ## The started display for `e`, or "" and the reason it cannot start.
  try:
    case e.display
    of dkX11:
      if xvfb == nil:
        xvfb = newXvfbTarget()
        xvfb.start()
      (TargetEnvironment(xvfb), "")
    of dkWayland:
      if swayT == nil:
        swayT = newSwayTarget(ScreenW, ScreenH)
        swayT.start()
      (TargetEnvironment(swayT), "")
  except CatchableError as ex:
    (nil, $e.display & " did not start: " & ex.msg.splitLines[0])

proc sessionEnv(work: string): seq[(string, string)] =
  ## A private CodeTracer state for every window (the per-terminal cache
  ## must not carry one terminal's answers into the next), a UTF-8 locale.
  for d in ["state", "data", "config", "home", "layout"]:
    createDir(work / d)
  @[("XDG_STATE_HOME", work / "state"), ("XDG_DATA_HOME", work / "data"),
    ("XDG_CONFIG_HOME", work / "config"), ("CODETRACER_HOME", work / "home"),
    ("CODETRACER_TUI_LAYOUT_DIR", work / "layout")]
    # No `CT_TUI_PROBE_TIMEOUT_MS`: `--capabilities` is a one-shot report and
    # waits for the fence up to the late-reply window by itself
    # (`terminal_probe.diagnosticProbeTimeoutMs`), which is what a user's
    # `ct doctor terminal` does on the same software renderer.

proc answersDiff(live, committed: JsonNode): seq[string] =
  ## The questions whose answers differ, as `<key>: <committed> -> <live>`.
  var keys: seq[string]
  for k, _ in live: keys.add k
  for k, _ in committed:
    if k notin keys: keys.add k
  for k in keys:
    let a = committed{k}
    let b = live{k}
    if a == nil or b == nil or $a != $b:
      result.add k & ": " & (if a == nil: "(none)" else: $a) & " -> " &
                 (if b == nil: "(none)" else: $b)

proc clipboardText(t: TargetEnvironment; e: Emulator): string =
  let cmd = if e.display == dkX11:
              "DISPLAY=" & XvfbTarget(t).displayName &
              " timeout 5 xclip -o -selection clipboard"
            else:
              "timeout 5 wl-paste -n"
  let (o, rc) = execCmdEx(cmd)
  if rc == 0: o else: ""

proc expectedIdentity(e: Emulator): string =
  if e.terminal == "tmux": e.host else: e.terminal

proc runeColumns(line: string; wideRunes: seq[Rune] = @[]): seq[(int, string)] =
  ## Each rune of a card line with the cell column it starts at. Every glyph
  ## on the card is one cell wide by the terminal's measurement (the card's
  ## own premise: a wider one pushes its bracket).
  var col = 0
  for r in line.runes:
    result.add (col, $r)
    col += (if r in wideRunes: 2 else: 1)

suite "PLAT-71 real emulators: the terminal front-end in the terminal it runs in":

  test "the binary and the capture tool exist":
    check fileExists(tuiBin)
    check fileExists(captureBin)
    check fileExists(toolsDir / "versions.txt")

  for e0 in emulatorTable(toolsDir / "versions.txt"):
    let e = e0
    if not wanted(e): continue

    test e.id & ": persona, profile, glyph test card, OSC 52":
      block body:
        var missing = missingReason(toolsDir / "missing.txt", e.package)
        if missing.len == 0 and e.version.len == 0:
          missing = e.package & ": not provided (no versions.txt entry)"
        if missing.len == 0 and e.host.len > 0:
          missing = missingReason(toolsDir / "missing.txt", e.host)
        if missing.len > 0:
          echo "MISSING-PREREQ SKIP: ", e.id, ": ", missing
          skip()
          break body
        let (t, why) = targetFor(e)
        if t == nil:
          echo "MISSING-PREREQ SKIP: ", e.id, ": ", why
          skip()
          break body
        let work = outDir / e.id
        removeDir(work)
        createDir(work)
        let env = sessionEnv(work)
        var row = %*{"terminal": e.terminal, "version": e.version,
                     "display": $e.display, "id": e.id}
        if e.host.len > 0:
          row["inside"] = %(e.host & " " & e.hostVersion)

        # 1. The persona.
        # Recorded without this run's paths: the work directory and the tmux
        # socket's process id are facts about the run, not the terminal.
        let launch = argvFor(e, "<command>", work).join(" ")
          .replace(work, "<work>")
          .replace("ct-lane-" & $getCurrentProcessId(), "ct-lane-<pid>")
        let personaPath = work / "persona.json"
        let captured = t.runIn(e, quoteShellCommand([captureBin,
          "--terminal", e.terminal, "--version", e.version, "--launch", launch,
          "--grace", "1500", "--out", personaPath]), work, env, work / "persona.done")
        check captured
        check fileExists(personaPath)
        if not fileExists(personaPath): break body
        let live = parseJson(readFile(personaPath))
        check live["answers"]{"da1"}.getStr.len > 0       # the fence answered
        let committedPath = personasDir / e.id & ".json"
        if updatePersonas:
          copyFile(personaPath, committedPath)
          echo "  persona written: ", committedPath
        check fileExists(committedPath)
        if fileExists(committedPath):
          let committed = parseJson(readFile(committedPath))
          let diffs = answersDiff(live["answers"], committed["answers"])
          for d in diffs:
            checkpoint(e.id & " answers differ from the committed persona " &
                       "(re-capture with CT_REAL_EMULATORS_UPDATE_PERSONAS=1): " & d)
          check diffs.len == 0
          check $live["round"] == $committed["round"]
        row["fenceMs"] = live["fenceMs"]

        # 2. The profile the shipped binary reads in this terminal.
        let capsTs = work / "caps.typescript"
        check t.runIn(e, "script -q -e -c " & quoteShell(quoteShellCommand(
          [tuiBin, "--capabilities=json", "--modern-unicode=auto"])) & " " &
          quoteShell(capsTs), work, env, work / "caps.done")
        var j: JsonNode
        try:
          j = typescriptJson(capsTs)
        except CatchableError as ex:
          checkpoint(ex.msg)
          check false
          break body
        writeFile(work / "capabilities.json", pretty(j))
        let id = j["identity"]["value"]
        checkpoint(e.id & " identity: " & $id)
        check id["name"].getStr == expectedIdentity(e)
        if e.terminal == "tmux":
          check id["via"].len == 1 and id["via"][0].getStr.startsWith("tmux")
        for k in ["identity", "tier", "colors", "widths", "ambiguousWide",
                  "syncOutput", "graphemeMode", "keyProtocol", "clipboard",
                  "pointerShapes", "modernUnicode", "rttMs", "mouse"]:
          row[k] = j[k]

        # 3. The glyph test card, on the screen.
        let cardTs = work / "card.typescript"
        var frame: RgbImage
        var haveFrame = false
        check t.runIn(e, "clear; script -q -e -c " & quoteShell(
          quoteShellCommand([tuiBin, "--capabilities", "--card"])) & " " &
          quoteShell(cardTs), work, env, work / "card.done",
          whileOpen = proc() =
            sleep(500)
            frame = t.captureSettled(Rect(x: 0, y: 0, w: ScreenW, h: ScreenH))
            haveFrame = true)
        check haveFrame
        if not haveFrame: break body
        frame.writePng(work / "card.png")
        let lines = typescriptLines(cardTs)
        writeFile(work / "card.txt", lines.join("\n"))
        # Where each printed line starts on the screen: a line longer than
        # the window wraps (the report's summary line does). The window's
        # width is the capture's: a tiled foot fills sway's output.
        let winCols = live["cols"].getInt
        var startRow: seq[int]
        var nextRow = 0
        for l in lines:
          startRow.add nextRow
          nextRow += max(1, (l.runeLen + winCols - 1) div winCols)
        var rowOf = initTable[string, int]()
        var lineOf = initTable[string, int]()
        for i, l in lines:
          var w = l.strip(trailing = false).split(' ')[0]
          if l.strip.startsWith("classic ") and "hairline [" in l:
            w = "scrollbar-classic"
          if w in ["markers", "dividers", "joins", "blocks", "legacy", "marks",
                   "Glyph", "attributes", "truecolor", "scrollbar-classic"] and
             w notin rowOf:
            rowOf[w] = startRow[i]
            lineOf[w] = i
        for k in ["Glyph", "markers", "dividers", "joins", "blocks", "legacy",
                  "marks", "scrollbar-classic", "truecolor", "attributes"]:
          checkpoint(e.id & ": card line " & k & " at screen row " &
                     $rowOf.getOrDefault(k, -1))
          check k in rowOf
        if rowOf.len < 10: break body

        # The grid. The cell size the terminal reported (CSI 16 t); the
        # origin and the rows the shell used before the report from the
        # card's colour rows, whose cells are painted edge to edge in every
        # terminal: the three rows from column 11 are one band of colour,
        # 3 cells tall, at the printed row `truecolor` plus that offset.
        let cell = live["answers"]{"cellSize"}.getStr
        var g = Grid(x0: 0, y0: 0)
        if cell.len > 0:
          let parts = cell[4 ..< cell.len - 1].split(';')
          g.ch = parseFloat(parts[0])
          g.cw = parseFloat(parts[1])
        # The background, from a cell no line reaches (the first row's end).
        let probeCw = if g.cw > 0: g.cw else: 6.0
        let bgPx = frame.pixel(int((winCols - 3).float * probeCw), 4)
        # Only the window: Xvfb's root around it is black, not background.
        let winW = int(winCols.float * probeCw)
        let winH = if g.ch > 0: int(live["rows"].getInt.float * g.ch) else: frame.height
        proc painted(x, y: int): bool =
          if x < 0 or y < 0 or x >= min(frame.width, winW) or
             y >= min(frame.height, winH): return false
          let p = frame.pixel(x, y)
          abs(int(p[0]) - int(bgPx[0])) + abs(int(p[1]) - int(bgPx[1])) +
            abs(int(p[2]) - int(bgPx[2])) > 90
        # The band: the longest vertical run of painted pixels in the middle
        # of the gradient (column 23 of 11 + 24); a glyph's stroke is never
        # three cells tall.
        let probeX = int(23.5 * probeCw)
        var bandTop, bandLen = -1
        var run = 0
        for y in 0 .. frame.height:
          if y < frame.height and painted(probeX, y):
            inc run
          else:
            if run > bandLen:
              bandLen = run
              bandTop = y - run
            run = 0
        var bandLeft = probeX
        while painted(bandLeft - 1, bandTop + bandLen div 6): dec bandLeft
        var bandRight = probeX
        while painted(bandRight + 1, bandTop + bandLen div 6): inc bandRight
        if g.ch == 0:
          # No cell-size answer (Alacritty): the band is 3 rows of 24 cells.
          g.ch = bandLen / 3
          g.cw = (bandRight - bandLeft + 1) / 24
        checkpoint(e.id & ": colour band " & $bandLen & " px tall, x " &
                   $bandLeft & ".." & $bandRight & "; cell " & $g.cw & "x" & $g.ch)
        check g.ch > 0 and g.cw > 0
        check abs(bandLen.float - 3 * g.ch) <= 2
        check abs((bandRight - bandLeft + 1).float - 24 * g.cw) <= 2
        if g.ch == 0 or g.cw == 0 or bandTop < 0: break body
        row["cellPx"] = %[g.cw, g.ch]
        let shift = int(floor(bandTop.float / g.ch)) - rowOf["truecolor"]
        g.y0 = bandTop.float - (rowOf["truecolor"] + shift).float * g.ch
        g.x0 = bandLeft.float - 11 * g.cw
        checkpoint(e.id & ": colour band at y " & $bandTop & ", x " & $bandLeft &
                   "; origin " & $g.x0 & "," & $g.y0 & "; rows before the report " &
                   $shift)
        # Measured, not assumed: 1 or 2 in the X11 terminals and tmux, -1 in
        # foot, whose main screen comes back one row higher.
        check shift in -1 .. 3
        check g.x0 >= -1 and g.x0 < g.cw and g.y0 >= -1 and g.y0 < g.ch
        row["screenRowOffset"] = %shift
        row["originPx"] = %[g.x0, g.y0]
        # OCR: the card's labels, read in the first column, on the rows the
        # printed lines and that offset put them.
        let words = runOcrEx(work / "card.png", initOcrOptions(upscale = 2.0))
        var ocrRow = initTable[string, float]()
        for w in words:
          let txt = w.text.strip(chars = {'.', ',', ':', ';'})
          if w.bbox[0].float < g.x0 + 2 * g.cw and
             txt in ["markers", "dividers", "Glyph", "attributes"] and
             txt notin ocrRow:
            ocrRow[txt] = w.bbox[1].float + w.bbox[3].float / 2.0
        # A word's box centre sits within a quarter cell of its row (an
        # ascender-heavy word like "dividers" centres high); tesseract
        # misses a label now and then, so three of the four suffice.
        var read = 0
        for k in ["Glyph", "markers", "dividers", "attributes"]:
          let want = g.y0 + (rowOf[k] + shift).float * g.ch
          checkpoint(e.id & ": OCR " & k & " centre y " &
                     $ocrRow.getOrDefault(k, -1.0) & ", its row spans y " &
                     $want & ".." & $(want + g.ch))
          if k in ocrRow:
            inc read
            check ocrRow[k] >= want - g.ch / 4 and
                  ocrRow[k] <= want + g.ch + g.ch / 4
        check read >= 3

        let bg = frame.background(g, Cols - 2, rowOf["markers"] + shift)
        # Brackets: every `]` of a glyph row against the `]` of the ASCII
        # `[~]` on the markers row, whose place no measurement can move.
        let markersCols = runeColumns(lines[lineOf["markers"]])
        var refCol = -1
        for i in 1 ..< markersCols.len:
          if markersCols[i][1] == "]" and markersCols[i - 1][1] == "~":
            refCol = markersCols[i][0]
        check refCol >= 0
        let reference = frame.columnProfile(g, refCol, rowOf["markers"] + shift, bg)
        var displaced: seq[string]
        var brackets = 0
        for k in ["markers", "dividers", "joins", "blocks", "legacy", "marks"]:
          for (col, glyph) in runeColumns(lines[lineOf[k]]):
            if glyph != "]": continue
            inc brackets
            let s = similarity(frame.columnProfile(g, col, rowOf[k] + shift, bg), reference)
            if s < 0.7:
              displaced.add k & " col " & $col & " (similarity " &
                            formatFloat(s, ffDecimal, 2) & ")"
        row["bracketsInPlace"] = %(displaced.len == 0)
        row["bracketsDisplaced"] = %displaced
        checkpoint(e.id & ": " & $brackets & " brackets, displaced: " & $displaced)
        check brackets == 38
        check displaced.len == 0
        # The reading can tell: an opening `[` is not taken for a `]`.
        var confused: seq[string]
        for (col, glyph) in runeColumns(lines[lineOf["markers"]]):
          if glyph == "[":
            let s = similarity(frame.columnProfile(g, col,
              rowOf["markers"] + shift, bg), reference)
            if s >= 0.7: confused.add "col " & $col
        check confused.len == 0

        # Block shapes: the blocks row, the extended scrollbar row, the
        # Legacy Computing row.
        var shapes = newJObject()
        for k in ["blocks", "scrollbar-classic", "legacy"]:
          for (col, glyph) in runeColumns(lines[lineOf[k]]):
            if glyph notin BlockShapes or ($glyph & "@" & k) in shapes: continue
            let ink = frame.inkOf(g, col, rowOf[k] + shift, bg)
            let (ok, why) = ink.matchesShape(BlockShapes[glyph], g)
            shapes[glyph & "@" & k] = %*{"drawn": ok, "ink": why}
        row["shapes"] = shapes
        let hair = shapes{"▕@scrollbar-classic"}
        checkpoint(e.id & ": hairline thumb " & $hair)
        let legacyDrawn = shapes{"🮇@legacy"}{"drawn"}.getBool and
                          shapes{"🮂@legacy"}{"drawn"}.getBool and
                          shapes{"🭰@legacy"}{"drawn"}.getBool and
                          shapes{"🭻@legacy"}{"drawn"}.getBool
        row["legacyDrawn"] = %legacyDrawn
        row["hairlineAtRightEdge"] = %(hair != nil and hair["drawn"].getBool)
        checkpoint(e.id & ": Legacy Computing drawn " & $legacyDrawn &
                   "; modern-unicode auto " & $j["modernUnicode"])
        # The hairline thumb is a one-eighth-cell line at the right edge, and
        # every block element of the card is its shape, in every terminal.
        check row["hairlineAtRightEdge"].getBool
        for glyph in ["▁@blocks", "█@blocks", "▏@blocks", "▐@blocks", "▕@blocks"]:
          checkpoint(e.id & ": " & glyph & " " & $shapes{glyph})
          check shapes{glyph}{"drawn"}.getBool
        # The Legacy Computing row is drawn by the terminals that claim to
        # draw it (§3.2) — and by no other: xterm takes it from the font,
        # which has none of these, and Alacritty draws U+1FB82–1FB8B only
        # from 0.17.
        check legacyDrawn == (expectedIdentity(e) in ["kitty", "ghostty", "foot"])
        # §6.7: `auto` turns them on only where the terminal draws them.
        if j["modernUnicode"]["value"].getBool:
          check legacyDrawn

        # 4. OSC 52: accepted or refused, and the profile's word for it.
        let token = "ct-osc52-" & e.id
        # The clipboard starts empty: every earlier window, which may own
        # the selection, is closed.
        var pasted = ""
        check t.runIn(e, "printf '\\033]52;c;" & encode(token) &
                      "\\007'; sleep 1", work, env, work / "osc52.done",
                      whileOpen = proc() = pasted = clipboardText(t, e),
                      typeReturn = true)
        # `execCmdEx` ends what it read with a newline of its own.
        if pasted.endsWith("\n"): pasted.setLen(pasted.len - 1)
        let accepted = pasted == token
        row["osc52ReadBack"] = %pasted
        let clip = j["clipboard"]["value"].getStr
        row["osc52Accepted"] = %accepted
        checkpoint(e.id & ": OSC 52 " & (if accepted: "accepted" else: "refused") &
                   " (clipboard read back " & pasted.escape & "); profile: " & clip)
        check accepted == clip.startsWith("osc52")
        measured[e.id] = row
        writeFile(outDir / "measured.json", pretty(measured))

  test "the displays are stopped":
    if xvfb != nil: xvfb.stop()
    if swayT != nil: swayT.stop()
    check true
