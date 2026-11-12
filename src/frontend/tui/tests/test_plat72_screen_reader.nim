## test_plat72_screen_reader.nim — Tier 1. The screen-reader mode
## (CodeTracer-TUI-Terminal-Adaptation.md §9.4, its decisions SR-D1 – SR-D7):
##
##   * TA-15 — the `screen-reader` setting's ranks (`:set`, a flag, the
##     `CODETRACER_TUI_SCREEN_READER` override, the remembered settings) over
##     the environment's hints, `auto` saying nothing at its rank, and the
##     hints themselves: `ACCESSIBLE` and its off spellings, Speakup's
##     synthesizer on the Linux console only; the report and its JSON name
##     the rank or the hint; every text form of the setting round-trips;
##   * what the mode forces: the ASCII tier over any `glyphs` choice, and
##     reduced motion (SR-D3, SR-D4);
##   * TA-16 — the glyph table's quiet column: every decorative role a space,
##     every other role its ASCII glyph; the box's tees too; a scrollbar is
##     recorded and not drawn; and the runtime's FULL SCREEN on a real
##     recording: every chrome cell ASCII, no border, divider or scrollbar
##     cell holding a glyph;
##   * TA-19's pure half — that screen shows one pane, the focused one, and
##     follows focus;
##   * TA-17 / TA-18's pure half — `focus_locator` over painted rows: the
##     caret, the selected / active / current row at its first cell, the
##     first body row, the row's text, and the announcement's two forms.
##
## No mocks. The recording is real (`fixture_provider`), the runtime is the
## shipped one, and the screens are its own `shellScreenOf`.
##
## Templates, not procs, for anything that calls `check`.

import std/[json, options, os, sequtils, strutils, unicode, unittest]

import isonim_tui
import codetracer_embed
import headless_app/layout_model

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/terminal_report
import ../app/theme/terminal_settings
import ../app/views/borders
import ../app/views/focus_locator
import ../app/views/glyph_table
import ../app/views/scrollbar_styles
import ../app/views/shell
import ../app/views/styled_row
import ../app/layout/cells
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 211
  ## Measured: the quiet column checks each of the 47 glyph roles (one for a
  ## decorative role, two for one that keeps its glyph), the full screen
  ## nine per pane over four panes.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 140
  Rows = 40

proc env(accessible = ""; term = "xterm-256color"; speakup = "";
         ctScreenReader = ""): TerminalEnv =
  result = initTerminalEnv(term = term, colorterm = "truecolor",
                           lang = "en_US.UTF-8")
  result.accessible = accessible
  result.speakupSynth = speakup
  result.ctScreenReader = ctScreenReader

proc flagsWith(reader: Option[bool]; glyphs = none(GlyphsChoice)):
    CapabilityFlags =
  result = initCapabilityFlags()
  result.choices.screenReader = reader
  result.choices.glyphs = glyphs

proc resolveWith(e: TerminalEnv; flags = initCapabilityFlags();
                 prefs = TerminalPrefs();
                 session = TerminalChoices()): TerminalCapabilities =
  resolveCapabilities(e, flags, TerminalProbe(), prefs, session)

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: "")

proc rowsOf(cells: seq[(string, CellStyle)]): StyledRow =
  for (text, style) in cells:
    result.add StyledSpan(text: text, style: style)

suite "the screen-reader mode, Tier 1 (§9.4)":

  test "TA-15: the setting's ranks over the environment's hints":
    # Off by default, and nothing claims a reason.
    let plain = resolveWith(env())
    ck not plain.screenReader
    ck plain.screenReaderFrom == csDefault
    # SR-D2: `ACCESSIBLE` says a screen reader is listening…
    let hinted = resolveWith(env(accessible = "1"))
    ck hinted.screenReader
    ck hinted.screenReaderFrom == csEnvironment
    ck hinted.screenReaderNote == "ACCESSIBLE=1"
    # …unless it says no.
    for off in ["0", "false", "no", "off", "OFF", " "]:
      checkpoint("ACCESSIBLE=" & off)
      ck not resolveWith(env(accessible = off)).screenReader
    # Speakup drives a synthesizer — on the Linux console only.
    let speakup = resolveWith(env(term = "linux", speakup = "soft\n"))
    ck speakup.screenReader
    ck speakup.screenReaderNote == "Speakup (soft)"
    ck not resolveWith(env(term = "linux", speakup = "none")).screenReader
    ck not resolveWith(env(term = "xterm-256color",
                           speakup = "soft")).screenReader
    # The ranks, strongest first: `:set`, a flag, the override, the
    # remembered settings — each over the hint, each over the next.
    ck not resolveWith(env(accessible = "1", ctScreenReader = "off")).screenReader
    let envOn = resolveWith(env(ctScreenReader = "on"))
    ck envOn.screenReader and envOn.screenReaderFrom == csEnvironment and
       envOn.screenReaderNote == "CODETRACER_TUI_*"
    let flagOff = resolveWith(env(ctScreenReader = "on"),
                              flagsWith(some(false)))
    ck not flagOff.screenReader and flagOff.screenReaderFrom == csFlag
    let sessionOn = resolveWith(env(), flagsWith(some(false)),
                                session = TerminalChoices(
                                  screenReader: some(true)))
    ck sessionOn.screenReader and sessionOn.screenReaderFrom == csSetting and
       sessionOn.screenReaderNote == ":set"
    let remembered = resolveWith(env(), prefs = TerminalPrefs(
      global: TerminalChoices(screenReader: some(true))))
    ck remembered.screenReader and remembered.screenReaderFrom == csSetting
    ck not resolveWith(env(accessible = "1"), prefs = TerminalPrefs(
      global: TerminalChoices(screenReader: some(false)))).screenReader
    # `auto` at a rank says nothing: the hint below it decides.
    var autoChoice = TerminalChoices()
    ck choicesOf(lsScreenReader, "auto", autoChoice)
    ck autoChoice.screenReader.isNone
    ck resolveWith(env(accessible = "yes"),
                   session = autoChoice).screenReader
    ck resolveWith(env(accessible = "1", ctScreenReader = "auto")).screenReader
    # A value that is not one is named, never ignored.
    let bad = resolveWith(env(ctScreenReader = "loud"))
    ck not bad.screenReader
    ck bad.remedies.anyIt(it.contains("CODETRACER_TUI_SCREEN_READER=loud"))

  test "SR-D1: every text form of the setting":
    ck lsScreenReader.isTerminalSetting
    ck settingValues(lsScreenReader) == @["auto", "on", "off"]
    for value in settingValues(lsScreenReader):
      let flag = parseSettingFlag("--screen-reader=" & value)
      ck flag.isFlag and flag.ok and flag.setting == lsScreenReader and
         flag.word == value
      let line = parseSetLine(":set screen-reader " & value)
      ck line.isSet and line.ok and line.value == value
      var s = defaultLayoutSettings()
      ck s.assignValue(lsScreenReader, value)
      let back = decodeLayoutSettings(encodeLayoutSettings(s))
      ck back.ok and back.settings.valueText(lsScreenReader) == value
    ck defaultLayoutSettings().valueText(lsScreenReader) == "auto"
    # The remembered `on` is rank 5's.
    var s = defaultLayoutSettings()
    ck s.assignValue(lsScreenReader, "on")
    ck prefsOf(s).global.screenReader == some(true)

  test "SR-D3, SR-D4: the mode forces the ASCII tier and reduced motion":
    let on = resolveWith(env(accessible = "1"),
                         flagsWith(none(bool), some(gcExtended)))
    ck on.tier == tierAscii
    ck on.tierNote == "screen-reader"
    ck on.reduceMotion and on.reduceMotionFrom == csEnvironment
    ck not on.modernUnicode
    let g = glyphProfileOf(on)
    ck g.quiet and g.tier == tierAscii
    let off = resolveWith(env(), flagsWith(some(false), some(gcExtended)))
    ck off.tier == tierExtended and not glyphProfileOf(off).quiet

  test "TA-13: the report names the mode and what decided it":
    let caps = resolveWith(env(accessible = "1"))
    var line = ""
    for l in profileReport(caps):
      if l.startsWith("Screen reader"): line = l
    checkpoint(line)
    ck line.contains("on:")
    ck line.contains("(environment: ACCESSIBLE=1)")
    let j = profileJson(caps)
    ck j["screenReader"]["value"].getBool
    ck j["screenReader"]["from"].getStr == "environment"
    ck j["screenReader"]["note"].getStr == "ACCESSIBLE=1"
    ck profileJson(resolveWith(env()))["screenReader"]["from"].getStr ==
       "default"

  test "TA-16: the quiet column — decoration is a space, meaning is kept":
    let quiet = GlyphProfile(tier: tierAscii, quiet: true)
    let ascii = GlyphProfile(tier: tierAscii)
    for role in GlyphRole:
      checkpoint($role)
      if role in DecorativeRoles:
        ck quiet.glyph(role) == " "
      else:
        ck quiet.glyph(role) == ascii.glyph(role)
        ck quiet.glyph(role).strip.len > 0
    # The marks that carry meaning, by name.
    ck quiet.glyph(grTruncation) == "~"
    ck quiet.glyph(grBreakpoint) == "*"
    ck quiet.glyph(grTreeCollapsed) == ">"
    let box = borderSetOf(quiet)
    for g in [box.topLeft, box.topRight, box.bottomLeft, box.bottomRight,
              box.horizontal, box.vertical, box.teeLeft, box.teeRight,
              box.teeTop, box.teeBottom, box.cross]:
      ck g == " "
    # A scrollbar is recorded for the pointer and not drawn.
    var grid = newStyledGrid(10, 10)
    grid.glyphs = quiet
    grid.paintBar(axVertical, 9, 0, 10,
                  ScrubberModel(total: 100, totalKnown: true, firstVisible: 0,
                                visible: 10, current: -1))
    ck grid.bars.len == 1
    var drawn = ""
    for r in 0 ..< 10:
      drawn.add grid.runeAt(r, 9)
    ck drawn.strip.len == 0
    var loud = newStyledGrid(10, 10)
    loud.glyphs = ascii
    loud.paintBar(axVertical, 9, 0, 10,
                  ScrubberModel(total: 100, totalKnown: true, firstVisible: 0,
                                visible: 10, current: -1))
    var shown = ""
    for r in 0 ..< 10:
      shown.add loud.runeAt(r, 9)
    ck shown.strip.len > 0          # the control: the same bar, drawn

  test "focus_locator: the caret, the selected row, the first row":
    let area = CellArea(col: 2, row: 1, width: 20, height: 5)
    let blank = rowsOf(@[(repeat(' ', 30), DefaultCellStyle)])
    # A selected row: its first cell inside the pane.
    var rows = @[blank, blank, blank,
                 rowsOf(@[("  ", DefaultCellStyle),
                          ("  main    calc.py:3   ",
                           CellStyle(surface: srSurfaceSelection)),
                          ("      ", DefaultCellStyle)]),
                 blank, blank]
    var s = focusSpotIn(rows, area)
    ck s.found and s.how == fhSelection and s.row == 3 and s.col == 2
    ck s.text == "main calc.py:3"
    # An active row when nothing is selected.
    rows[3] = rowsOf(@[("  ", DefaultCellStyle),
                       ("  add  ", CellStyle(surface: srSurfaceActiveRow))])
    s = focusSpotIn(rows, area)
    ck s.how == fhActiveRow and s.row == 3
    # The caret beats a selection: a reversed cell on the current line.
    rows[2] = rowsOf(@[("  x = ", CellStyle(surface: srSurfaceCurrentLine)),
                       ("1", CellStyle(surface: srSurfaceCurrentLine,
                                       reverse: true)),
                       ("  ", CellStyle(surface: srSurfaceCurrentLine))])
    s = focusSpotIn(rows, area)
    ck s.how == fhCaret and s.row == 2 and s.col == 6
    ck s.text == "x = 1"
    # The strip row is the pane's title, never its focused element; with
    # nothing highlighted, the first body row.
    rows = @[blank, rowsOf(@[("  ", DefaultCellStyle),
                             ("Title", CellStyle(surface: srSurfaceSelection))]),
             rowsOf(@[("  first  row", DefaultCellStyle)]), blank]
    s = focusSpotIn(rows, area)
    ck s.how == fhFirstRow and s.row == 2 and s.col == 2
    ck s.text == "first row"
    # SR-D7's two forms.
    ck announcementOf(s, true, "Call Stack") == "Call Stack: first row"
    ck announcementOf(s, false, "Call Stack") == "first row"
    ck announcementOf(FocusSpot(found: true), false, "x") == "blank"

  test "TA-16, TA-19: the full screen on a real recording":
    let calc = resolveFixture(pythonSpec("calc"))
    if calc.outcome != foRecorded:
      checkpoint(calc.detail)
    ck calc.outcome == foRecorded
    if calc.outcome == foRecorded:
      # What may be non-ASCII on the screen: the recorded program's own text
      # (content is drawn as recorded, TA-7) and the typographic punctuation
      # of CodeTracer's own sentences (a pane's explanation of an empty
      # list), which a screen reader reads as punctuation, not as a picture.
      var allowed: seq[string] = @[]
      for rune in readFile(repoRoot() / calc.spec.program).runes:
        if int(rune) >= 0x80: allowed.add $rune
      for (u, _) in ProsePunctuation: allowed.add u
      let caps = resolveWith(env(accessible = "1"))
      let rt = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
      discard rt.enableLayoutBinding()
      let s = openTuiSession(calc.tracePath, viewportHeight = Rows - 8)
      s.header(rt)
      s.learnExtent()
      s.refresh(rt)
      var visited: seq[PaneKind] = @[]
      for step in 0 ..< 4:
        let (had, focused) = rt.focus.focusedPane()
        ck had
        visited.add focused
        let screen = rt.shellScreenOf()
        # TA-19: one pane, the focused one, fills the body.
        ck screen.projection.regions.len == 1
        ck screen.projection.regions[0].pane == focused
        # TA-16: every cell ASCII (the calc program's source is ASCII), and
        # no border, divider or scrollbar cell holding a glyph.
        var leaks: seq[string] = @[]
        var decorated: seq[string] = @[]
        for r, row in screen.styledRows:
          for span in row:
            for rune in span.text.runes:
              if int(rune) >= 0x80 and $rune notin allowed:
                leaks.add $r & ":" & $rune
            if span.style.role in {srBorderPane, srBorderFocused,
                                   srDividerStrip, srScrollbarTrack,
                                   srScrollbarTrackRevealed, srScrollbarThumb,
                                   srScrollbarThumbSolid,
                                   srScrollbarThumbHover,
                                   srScrollbarThumbHeld} and
               span.text.strip.len > 0:
              decorated.add $r & ":" & $span.style.role & "=" & span.text
        checkpoint("pane " & $focused & ": non-ASCII " & $leaks &
                   "; decorated " & $decorated)
        if leaks.len + decorated.len > 0:
          for r, row in screen.rows:
            checkpoint($r & "| " & row)
        ck leaks.len == 0
        ck decorated.len == 0
        # SR-D5: the focused element is found on the painted frame, inside
        # the focused pane.
        ck not rt.followFocus(screen) or rt.app.notification.len > 0
        let spot = rt.focusSpot
        let area = rt.paintedAreaOf(focused)
        ck spot.found and spot.pane == focused
        ck spot.row > area.row and spot.row < area.row + area.height
        discard rt.handleToken("\x1b[17~", 0)   # F6: the next pane (CUA)
      # Focus moved, and the screen followed it.
      ck visited[0] != visited[1]
      s.close()

  test "the count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
