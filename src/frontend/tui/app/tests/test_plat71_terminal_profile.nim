## test_plat71_terminal_profile.nim — PLAT-71, Tier 1. The terminal's
## capability PROFILE as a pure function (CodeTracer-TUI-Terminal-
## Adaptation.md §4, §5, §6, §10.1).
##
## What this suite establishes, each named after the spec's invariant:
##
##   * TA-1 — the profile is a pure function of (environment, flags,
##     settings, answers, cache): a table over terminal PERSONAS (the answers
##     a terminal gives, §13.1) crossed with flags and settings, asserting the
##     resolved axis AND the source that decided it;
##   * TA-2 — §5.2's precedence, axis by axis: for each adjacent pair of
##     ranks, a case where both speak and the higher wins;
##   * TA-8 — under the ambiguous-wide rule no one-cell role resolves to an
##     East Asian Width `A` glyph, judged by `isonim_tui`'s Unicode 16 table
##     (not by this tree's own list);
##   * TA-9 — `modern-unicode` is never on by detection alone;
##   * TA-12 — the cache never beats a live answer;
##   * TA-13 — the report's JSON names a source for every axis;
##   * §4.3's width model over EVERY combination of the probe answers, checked
##     against an oracle written from the spec's text;
##   * §4.2's round (what is asked, in what order, the restricted round for
##     the Linux console) and the reply parsers over the reply shapes the
##     terminals' documentation gives;
##   * §4.3's F3 rule: a `CSI 1 ; 5 R` is a cursor report only while the
##     width probe waits for one;
##   * §5.3's settings: the flags, the contradictions refused, and the
##     remembered `[terminal "<glob>"]` sections.
##
## ## The personas here are WRITTEN, not captured — and that is stated
##
## §13.1 asks for personas captured from real terminals. The answer sets
## below are written from each terminal's documentation (§3.2's sources);
## capturing them on the real emulators is PLAT-71 Part E's lane, which is
## owed. A written persona is the one stand-in of this file, and it is not a
## mock: the subject — `resolveCapabilities`, the parsers, the round — is the
## shipped code, called directly.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` inside a `proc` reports `[OK]` on failure.

import std/[json, options, sequtils, strutils, unicode, unittest]

import isonim_tui

import ../cli
import ../theme/capabilities
import ../theme/terminal_report
import ../theme/terminal_settings
import ../views/borders
import ../views/glyph_table
import ../views/scrollbar_styles
import codetracer_embed

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 523
  ## 520 -> 523, measured: the glyph table's `grRunControl` role (the Test
  ## Results pane's run control) — its ASCII glyph and its two one-cell
  ## columns.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# Personas: the answers a terminal gives (§13.1), written from §3.2
# ---------------------------------------------------------------------------

type
  Persona = object
    name: string
    env: TerminalEnv
    probe: TerminalProbe

proc widthsProbe(p1, p2, p3, p4, p5, p6: int): seq[int] =
  for w in [p1, p2, p3, p4, p5, p6]:
    if w >= 0: result.add w

proc answered(xtversion = ""; da2 = (0, 0); sync = -1; grapheme = -1;
              widths: seq[int] = @[]; truecolor = false;
              rtt = 1): TerminalProbe =
  result = TerminalProbe(attempted: true, answered: true, xtversion: xtversion,
                         cprExpected: 6, cprAnswers: widths,
                         truecolor: truecolor,
                         rttMeasured: true, rttMs: rtt)
  if da2[0] != 0:
    result.da2Answered = true
    result.da2Pp = da2[0]
    result.da2Pv = da2[1]
  if sync >= 0:
    result.sync2026Answered = true
    result.sync2026 = sync
  if grapheme >= 0:
    result.grapheme2027Answered = true
    result.grapheme2027 = grapheme

let
  NarrowWidths = widthsProbe(1, 1, 1, 1, 2, 2)
  utf8Env = initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8")
  Personas = [
    Persona(name: "kitty 0.36.4",
            env: initTerminalEnv(term = "xterm-kitty", lang = "en_US.UTF-8"),
            probe: answered("kitty(0.36.4)", (1, 4000), 2, 0, NarrowWidths,
                            true)),
    Persona(name: "foot 1.16.2",
            env: initTerminalEnv(term = "foot", lang = "en_US.UTF-8"),
            probe: answered("foot(1.16.2)", (1, 11602), 2, 2, NarrowWidths,
                            true)),
    Persona(name: "foot 1.7 (before Legacy Computing)",
            env: initTerminalEnv(term = "foot", lang = "en_US.UTF-8"),
            probe: answered("foot(1.7.0)", (1, 10700), 2, 2,
                            widthsProbe(1, 1, 1, 1, 2, 2), true)),
    Persona(name: "xterm 389",
            env: initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8"),
            probe: answered("XTerm(389)", (41, 389), 0, 0,
                            widthsProbe(1, 1, 1, 1, 2, 4))),
    Persona(name: "VTE 0.76 (GNOME Terminal)",
            env: initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8",
                                 vteVersion = "7600"),
            probe: answered("VTE(7600)", (65, 7600), 4, 0, NarrowWidths, true)),
    Persona(name: "VTE 0.76 set to ambiguous WIDE",
            env: initTerminalEnv(term = "xterm-256color", lang = "ja_JP.UTF-8",
                                 vteVersion = "7600"),
            probe: answered("VTE(7600)", (65, 7600), 4, 0,
                            widthsProbe(2, 2, 1, 2, 2, 2), true)),
    Persona(name: "Alacritty (no XTVERSION)",
            env: initTerminalEnv(term = "alacritty", lang = "en_US.UTF-8"),
            probe: answered("", (0, 0), 2, -1, NarrowWidths, true)),
    Persona(name: "Linux console",
            env: initTerminalEnv(term = "linux", lang = "en_US.UTF-8"),
            probe: answered("", (0, 0), -1, -1, widthsProbe(1, 1, 1, 1, 1, 4))),
    Persona(name: "a terminal that decodes Latin-1",
            env: initTerminalEnv(term = "xterm", lang = "C"),
            probe: answered("", (0, 0), -1, -1, widthsProbe(3, 3, 4, 3, 3, 11))),
    Persona(name: "silent",
            env: utf8Env,
            probe: TerminalProbe(attempted: true, cprExpected: 6))]

# ---------------------------------------------------------------------------
# An oracle for §4.3's width model, written from the spec's text
# ---------------------------------------------------------------------------

proc oracleUtf8(p1: int): Knowledge =
  if p1 < 0: knUnknown elif p1 == 3: knNo else: knYes

proc oracleAmbiguous(p1: int): AmbiguousPolicy =
  ## "if P1 == 2: awWide elif P1 == 1: awNarrow else: unknown" — and nothing
  ## when the terminal did not decode UTF-8 (P0 = 3).
  if p1 == 3: apUnknown
  elif p1 == 2: apWide elif p1 == 1: apNarrow else: apUnknown

suite "PLAT-71 Tier 1: the terminal's capability profile":

  test "§4.3: the width model over every combination of the probe answers":
    var combos = 0
    var wrong = 0
    for p1 in [-1, 1, 2, 3]:
      for p2 in [-1, 1, 2]:
        for p3 in [-1, 0, 1, 2]:
          for p4 in [-1, 1, 2]:
            for p5 in [-1, 1, 2]:
              for p6 in [-1, 2, 4, 5]:
                for g in [-1, 0, 2, 3]:
                  var a = noWidthAnswers()
                  a[wpEllipsis] = p1; a[wpBlock] = p2; a[wpLegacy] = p3
                  a[wpPicto] = p4; a[wpWide] = p5; a[wpCluster] = p6
                  let m = widthModelOf(a, g)
                  let utf8 = oracleUtf8(p1)
                  var ok = m.utf8 == utf8 and m.ambiguous == oracleAmbiguous(p1)
                  if utf8 != knNo:
                    ok = ok and m.blockAmbig == oracleAmbiguous(
                      (if p2 == 3: -1 else: p2))
                    ok = ok and m.unicode13 == (if p3 < 0: knUnknown
                                                elif p3 == 1: knYes else: knNo)
                    ok = ok and m.pictoWide == (if p4 < 0: knUnknown
                                                elif p4 == 2: knYes else: knNo)
                    ok = ok and m.wideOk == (if p5 < 0: knUnknown
                                             elif p5 == 2: knYes else: knNo)
                    # `clusters`: DECRQM 2027 recognised (Ps 1–4) or P6 == 2.
                    let clusters = if g in {1, 2, 3, 4}: knYes
                                   elif p6 < 0: knUnknown
                                   elif p6 == 2: knYes else: knNo
                    ok = ok and m.clusters == clusters
                  else:
                    ok = ok and m.unicode13 == knUnknown and
                         m.clusters == knUnknown
                  if not ok:
                    inc wrong
                    if wrong < 5:
                      checkpoint("P=" & $p1 & "," & $p2 & "," & $p3 & "," &
                                 $p4 & "," & $p5 & "," & $p6 & " 2027=" & $g &
                                 " -> " & describe(m))
                  inc combos
    checkpoint("width-model combinations: " & $combos)
    ck combos == 4 * 3 * 4 * 3 * 3 * 4 * 4
    ck wrong == 0

  test "§4.4: the reply parsers read each terminal's documented answer":
    ck parseXtversionText("kitty(0.36.4)") == ("kitty", "0.36.4")
    ck parseXtversionText("XTerm(389)") == ("xterm", "389")
    ck parseXtversionText("tmux 3.4") == ("tmux", "3.4")
    ck parseXtversionText("VTE(7600)") == ("vte", "0.76.0")
    ck parseXtversionText("WezTerm 20240203-110809-5046fc22")[0] == "wezterm"
    ck parseXtversionText("foot(1.16.2)") == ("foot", "1.16.2")
    ck parseXtversionReply("\x1bP>|kitty(0.36.4)\x1b\\") == (true,
                                                            "kitty(0.36.4)")
    ck parseDa2("\x1b[>41;389;0c") == (true, 41, 389)
    ck identityOfDa2(41, 389) == ("xterm", "389")
    ck identityOfDa2(65, 6800) == ("vte", "0.68.0")
    ck identityOfDa2(84, 0)[0] == "tmux"
    ck identityOfDa2(1, 4000) == ("", "")
    ck parseDecrqm("\x1b[?2026;2$y") == (true, 2026, 2)
    ck parseDecrqm("\x1b[?2027;0$y") == (true, 2027, 0)
    ck parseCpr("\x1b[1;2R") == (true, 1, 2)
    ck not parseCpr("\x1b[A")[0]
    ck versionAtLeast("1.16.2", "1.8.0")
    ck not versionAtLeast("1.7.0", "1.8.0")
    ck not versionAtLeast("", "0.1")

  test "TA-1: every persona resolves to its documented profile, sources named":
    var rows = 0
    for persona in Personas:
      let caps = resolveCapabilities(persona.env, initCapabilityFlags(),
                                     persona.probe)
      checkpoint(persona.name & ": " & describe(caps))
      inc rows
      case persona.name
      of "kitty 0.36.4":
        ck caps.identity.name == "kitty" and caps.identity.version == "0.36.4"
        ck caps.identityFrom == csProbe
        ck caps.synchronizedOutput and caps.syncFrom == csProbe
        ck not caps.graphemeMode
        ck caps.tier == tierExtended
        ck not caps.modernUnicode      # off by default, even where it would draw
        ck caps.modernNote.contains("auto would turn it on")
        ck not caps.ambiguousWide and caps.ambiguousFrom == csProbe
      of "foot 1.16.2":
        ck caps.identity.name == "foot"
        ck caps.graphemeMode and caps.graphemeSet   # 2027 recognised, off
      of "xterm 389":
        ck caps.identity.name == "xterm"
        # A NEGATIVE DECRQM answer beats every list (§5.2 note).
        ck not caps.synchronizedOutput and caps.syncFrom == csProbe
        ck caps.widths.clusters == knNo
      of "VTE 0.76 (GNOME Terminal)":
        ck caps.identity.name == "vte" and caps.identity.version == "0.76.0"
        ck not caps.synchronizedOutput     # VTE answers 4: permanently reset
      of "VTE 0.76 set to ambiguous WIDE":
        ck caps.ambiguousWide and caps.ambiguousFrom == csProbe
        ck glyphProfileOf(caps).columnOf == gcolAmbiguous
      of "Alacritty (no XTVERSION)":
        ck caps.identity.name == "alacritty"
        ck caps.identityFrom == csEnvironment
        ck caps.synchronizedOutput
      of "Linux console":
        ck caps.tier == tierBasic
        ck caps.widths.wideOk == knNo
      of "a terminal that decodes Latin-1":
        ck caps.widths.utf8 == knNo
        ck caps.tier == tierAscii
        ck caps.borders == bmAscii
      of "silent":
        ck not caps.widths.measured
        ck caps.ambiguousFrom == csDefault and not caps.ambiguousWide
        ck caps.tier == tierExtended and caps.bordersFrom == csEnvironment
      else: discard
      # The profile is ONE value, and the same inputs give the same value.
      ck caps == resolveCapabilities(persona.env, initCapabilityFlags(),
                                     persona.probe)
    ck rows == Personas.len

  test "OQ-T8: a C locale on a terminal that decodes UTF-8 uses Unicode":
    let env = initTerminalEnv(term = "xterm-256color", lang = "C")
    let unanswered = resolveCapabilities(env, initCapabilityFlags())
    ck unanswered.tier == tierAscii and unanswered.bordersFrom == csDefault
    let caps = resolveCapabilities(env, initCapabilityFlags(),
                                   answered(widths = NarrowWidths))
    ck caps.tier == tierExtended and caps.bordersFrom == csProbe
    ck caps.tierNote.contains("terminal decodes UTF-8")
    ck caps.remedies.anyIt(it.contains("LANG=C.UTF-8"))
    # …except under tmux with client_utf8 = 0.
    var tmuxProbe = answered(widths = NarrowWidths)
    tmuxProbe.tmuxClientUtf8 = "0"
    let tmuxed = resolveCapabilities(initTerminalEnv(term = "screen",
                                     lang = "C", tmux = "/tmp/t,1,0"),
                                     initCapabilityFlags(), tmuxProbe)
    ck tmuxed.tier == tierAscii

  test "OQ-T3: unmeasured widths on a CJK locale use the ambiguous-safe glyphs":
    let cjk = resolveCapabilities(initTerminalEnv(term = "xterm",
                                  lang = "zh_CN.UTF-8"), initCapabilityFlags())
    ck cjk.ambiguousWide and cjk.ambiguousFrom == csEnvironment
    let en = resolveCapabilities(utf8Env, initCapabilityFlags())
    ck not en.ambiguousWide and en.ambiguousFrom == csDefault

  test "TA-2: §5.2's precedence, axis by axis, each adjacent pair":
    let wide = answered(widths = widthsProbe(2, 2, 1, 1, 2, 2))
    let narrow = answered(widths = NarrowWidths)
    proc session(c: TerminalChoices): TerminalChoices = c
    var glyphsAscii = TerminalChoices(glyphs: some(gcAscii))
    var glyphsBasic = TerminalChoices(glyphs: some(gcBasic))
    var glyphsExtended = TerminalChoices(glyphs: some(gcExtended))
    # Rank 1 (:set) over rank 2 (flag).
    var flagBasic = initCapabilityFlags()
    flagBasic.choices = glyphsBasic
    let r12 = resolveCapabilities(utf8Env, flagBasic, narrow,
                                  session = glyphsAscii)
    ck r12.tier == tierAscii and r12.bordersFrom == csSetting
    # Rank 2 (flag) over rank 3 (CODETRACER_TUI_GLYPHS).
    var envAscii = utf8Env
    envAscii.ctGlyphs = "ascii"
    let r23 = resolveCapabilities(envAscii, flagBasic, narrow)
    ck r23.tier == tierBasic and r23.bordersFrom == csFlag
    # Rank 3 (environment) over rank 4 (a [terminal] section).
    let kittyEnv = initTerminalEnv(term = "xterm-kitty", lang = "en_US.UTF-8",
                                   ctGlyphs = "ascii")
    let kittyProbe = answered("kitty(0.36.4)", widths = NarrowWidths)
    let scopedBasic = TerminalPrefs(scoped: @[ScopedChoices(glob: "kitty*",
                                                            choices: glyphsBasic)])
    let r34 = resolveCapabilities(kittyEnv, initCapabilityFlags(), kittyProbe,
                                  scopedBasic)
    ck r34.tier == tierAscii and r34.bordersFrom == csEnvironment
    # Rank 4 (scoped) over rank 5 (global).
    let both = TerminalPrefs(global: glyphsAscii,
                             scoped: @[ScopedChoices(glob: "kitty*",
                                                     choices: glyphsBasic)])
    var kittyPlain = kittyEnv
    kittyPlain.ctGlyphs = ""
    let r45 = resolveCapabilities(kittyPlain, initCapabilityFlags(), kittyProbe,
                                  both)
    ck r45.tier == tierBasic and r45.tierNote.contains("[terminal")
    # …and a section for ANOTHER terminal says nothing here.
    let other = TerminalPrefs(scoped: @[ScopedChoices(glob: "foot",
                                                      choices: glyphsAscii)])
    ck resolveCapabilities(kittyPlain, initCapabilityFlags(), kittyProbe,
                           other).tier == tierExtended
    # Rank 5 (global) over detection (rank 7: the probe measured UTF-8).
    let r57 = resolveCapabilities(utf8Env, initCapabilityFlags(), narrow,
                                  TerminalPrefs(global: glyphsAscii))
    ck r57.tier == tierAscii and r57.bordersFrom == csSetting
    # COLOURS: rank 5 (a setting) over rank 6 (NO_COLOR) — no-color.org's own
    # rule; NO_COLOR over detection.
    var noColorEnv = utf8Env
    noColorEnv.noColor = "1"
    let colorSetting = TerminalPrefs(global: TerminalChoices(
      colors: some(cc256)))
    let r56 = resolveCapabilities(noColorEnv, initCapabilityFlags(),
                                  answered(truecolor = true), colorSetting)
    ck r56.colors == cdAnsi256 and r56.colorsFrom == csSetting
    let r67 = resolveCapabilities(noColorEnv, initCapabilityFlags(),
                                  answered(truecolor = true))
    ck r67.colors == cdMonochrome and r67.colorsFrom == csEnvironment
    # Rank 7 (an answer) over rank 9 (an environment hint): DECRQSS beats
    # TERM=xterm-256color.
    let r79 = resolveCapabilities(utf8Env, initCapabilityFlags(),
                                  answered(truecolor = true))
    ck r79.colors == cdTrueColor and r79.colorsFrom == csProbe
    # AMBIGUOUS WIDTH: a setting over the measurement; the measurement over the
    # CJK hint; the hint over the default.
    let r5a = resolveCapabilities(utf8Env, initCapabilityFlags(), wide,
                                  TerminalPrefs(global: TerminalChoices(
                                    ambiguousWidth: some(acNarrow))))
    ck not r5a.ambiguousWide and r5a.ambiguousFrom == csSetting
    let cjkEnv = initTerminalEnv(term = "xterm", lang = "ja_JP.UTF-8")
    let r7a = resolveCapabilities(cjkEnv, initCapabilityFlags(), narrow)
    ck not r7a.ambiguousWide and r7a.ambiguousFrom == csProbe
    # SYNC: an answer (negative) over the identity list (kitty claims it).
    let negative = answered("kitty(0.36.4)", sync = 0, widths = NarrowWidths)
    let r78 = resolveCapabilities(kittyPlain, initCapabilityFlags(), negative)
    ck not r78.synchronizedOutput and r78.syncFrom == csProbe
    # …identity (rank 8) over the environment list (rank 9): foot by XTVERSION
    # under a TERM the list does not name.
    let r89 = resolveCapabilities(utf8Env, initCapabilityFlags(),
                                  answered("foot(1.16.2)", widths = NarrowWidths))
    ck r89.synchronizedOutput and r89.syncFrom == csIdentity
    # PROBE OFF: a setting turns the round off; nothing else does.
    ck not probeWanted(utf8Env, initCapabilityFlags(),
                       TerminalPrefs(global: TerminalChoices(probe: some(false))))
    var probeEnv = utf8Env
    probeEnv.ctProbe = "off"
    ck not probeWanted(probeEnv, initCapabilityFlags())
    ck probeWanted(utf8Env, initCapabilityFlags())
    ck not probeWanted(initTerminalEnv(term = "dumb"), initCapabilityFlags())
    discard session(glyphsExtended)

  test "TA-9: modern-unicode is never on by detection alone":
    var swept = 0
    for persona in Personas:
      for prefs in [TerminalPrefs(),
                    TerminalPrefs(global: TerminalChoices(
                      modernUnicode: some(mcOff)))]:
        let caps = resolveCapabilities(persona.env, initCapabilityFlags(),
                                       persona.probe, prefs)
        ck not caps.modernUnicode
        inc swept
      # `auto`: on ONLY for the identities that draw the range themselves,
      # at a version that has it, with U+1FB87 measured one cell.
      let auto = resolveCapabilities(persona.env, initCapabilityFlags(),
                                     persona.probe, TerminalPrefs(
                                       global: TerminalChoices(
                                         modernUnicode: some(mcAuto))))
      let expected = persona.name in ["kitty 0.36.4", "foot 1.16.2",
                                      "VTE 0.76 (GNOME Terminal)",
                                      "VTE 0.76 set to ambiguous WIDE"]
      checkpoint(persona.name & " auto -> " & $auto.modernUnicode & " (" &
                 auto.modernNote & ")")
      ck auto.modernUnicode == expected
      if auto.modernUnicode:
        ck auto.modernUnicodeFrom == csIdentity
    ck swept == Personas.len * 2
    # `on` draws them only on the extended tier.
    let onAscii = resolveCapabilities(utf8Env, initCapabilityFlags(),
                                      answered(widths = NarrowWidths),
                                      TerminalPrefs(global: TerminalChoices(
                                        modernUnicode: some(mcOn),
                                        glyphs: some(gcBasic))))
    ck not onAscii.modernUnicode
    # Not through a multiplexer that hides the outer terminal.
    let screenEnv = initTerminalEnv(term = "screen-256color",
                                    lang = "en_US.UTF-8", sty = "1.pts")
    let viaScreen = resolveCapabilities(screenEnv, initCapabilityFlags(),
      answered("kitty(0.36.4)", widths = NarrowWidths),
      TerminalPrefs(global: TerminalChoices(modernUnicode: some(mcAuto))))
    ck not viaScreen.modernUnicode

  test "TA-8: no one-cell role is an East Asian Width A glyph when wide":
    var checked = 0
    var offenders: seq[string] = @[]
    for tier in [tierExtended, tierBasic]:
      let p = GlyphProfile(tier: tier, ambiguousWide: true)
      for role in GlyphRole:
        if role == grTruncation:
          continue   # OQ-T2: `…` drawn as TWO cells, by decision
        let g = p.glyph(role)
        inc checked
        if g == RvSpace:
          continue
        for r in g.runes:
          if eawClass(int32(r)) == eawAmbiguous:
            offenders.add $role & " " & g
    # The scrollbar part of the table, both ambiguous-wide columns.
    for tier in [gtAmbiguous, gtAmbiguousModern]:
      for thickness in BarThickness:
        for looks in [ScrollbarGlyphs[tier][thickness].rest,
                      ScrollbarGlyphs[tier][thickness].widened]:
          for axis in BarAxis:
            for g in looks[axis].thumb.byMask & @[looks[axis].track]:
              if g.len == 0 or g == RvSpace: continue
              inc checked
              for r in g.runes:
                if eawClass(int32(r)) == eawAmbiguous:
                  offenders.add $tier & " " & $thickness & " " & g
    checkpoint("glyphs checked: " & $checked & ", offenders: " & $offenders)
    ck offenders.len == 0
    ck checked > 100
    # And the truncation marker takes two cells there (OQ-T2).
    ck GlyphProfile(ambiguousWide: true).markerCells == 2
    ck GlyphProfile().markerCells == 1

  test "TA-12: the cache gives frame 0, and a live answer always beats it":
    let cached = CachedProfile(key: "k", identityName: "kitty",
                               identityVersion: "0.36.4",
                               widths: [2, 2, 1, 1, 2, 2], sync2026: 2,
                               grapheme2027: -1, truecolor: true, rttMs: 120,
                               stampSec: 1000)
    let env = initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8")
    let frame0 = resolveCapabilities(env, initCapabilityFlags(),
                                     TerminalProbe(attempted: true),
                                     cache = some(cached))
    ck frame0.ambiguousWide and frame0.ambiguousFrom == csCache
    ck frame0.colors == cdTrueColor and frame0.colorsFrom == csCache
    ck frame0.linkConservative and frame0.reduceMotion
    ck frame0.identity.name == "kitty" and frame0.identityFrom == csCache
    # The live answer disagrees: it wins on every axis it speaks to.
    let live = resolveCapabilities(env, initCapabilityFlags(),
                                   answered(widths = NarrowWidths, rtt = 2),
                                   cache = some(cached))
    ck not live.ambiguousWide and live.ambiguousFrom == csProbe
    ck not live.linkConservative and live.rttFrom == csProbe
    # The codec: what is written is read back, entries age out at 90 days,
    # at most 32 are kept, the newest first.
    let text = encodeCache(@[cached])
    let (ok, back, _) = decodeCache(text)
    ck ok and back.len == 1 and back[0] == cached
    ck lookupCache(back, "k", 1000 + CacheMaxAgeSec).isSome
    ck lookupCache(back, "k", 1001 + CacheMaxAgeSec).isNone
    var many: seq[CachedProfile] = @[]
    for i in 0 ..< 40:
      many = rememberInCache(many, CachedProfile(key: $i, stampSec: int64(i)))
    ck many.len == CacheMaxEntries
    ck many[0].key == "39"
    ck not decodeCache("{not json")[0]

  test "TA-13: the report's JSON names a source for every axis":
    var axes = 0
    for persona in Personas:
      let j = profileJson(resolveCapabilities(persona.env,
                                              initCapabilityFlags(),
                                              persona.probe))
      for key, value in j.pairs:
        ck value.kind == JObject and value.hasKey("from") and
           value.hasKey("value")
        inc axes
      let report = profileReport(resolveCapabilities(persona.env,
                                                     initCapabilityFlags(),
                                                     persona.probe))
      ck report.len >= 14
      ck report[0].startsWith("Terminal")
    ck axes == Personas.len * 18

  test "§6.3: the glyph table's columns and the views' published constants":
    ck GlyphProfile(tier: tierAscii).glyph(grTruncation) == "~"
    ck GlyphProfile(tier: tierBasic).glyph(grExecPointer) == "►"
    ck GlyphProfile(tier: tierExtended).glyph(grDividerV) == "▏"
    ck GlyphProfile(tier: tierExtended, ambiguousWide: true).glyph(
      grDividerV) == "|"
    ck GlyphProfile(tier: tierAscii, ambiguousWide: true).columnOf == gcolAscii
    # Every ASCII-column glyph is ASCII, and every column one cell (save the
    # reverse-video space and the two-cell marker).
    for role in GlyphRole:
      let a = ChromeGlyphs[role][gcolAscii]
      ck a.len == 1 and ord(a[0]) < 0x80
      for col in [gcolExtended, gcolBasic]:
        ck displayWidth(ChromeGlyphs[role][col], awNarrow) == 1
    ck UnicodeBorders.breakpoint == "●" and AsciiBorders.breakpoint == "*"
    ck borderSet(bmAscii).ellipsis == "~"

  test "§3.3, §4.5: through tmux the outer terminal is tmux's client":
    var probe = answered("tmux 3.4", (84, 0), widths = NarrowWidths)
    probe.tmuxClientTermType = "kitty(0.36.4)"
    probe.tmuxVersion = "3.4"
    let env = initTerminalEnv(term = "tmux-256color", lang = "en_US.UTF-8",
                              tmux = "/tmp/tmux-1000/default,1,0")
    let caps = resolveCapabilities(env, initCapabilityFlags(), probe,
      TerminalPrefs(global: TerminalChoices(modernUnicode: some(mcAuto))))
    ck caps.identity.name == "kitty" and caps.identity.via == @["tmux 3.4"]
    ck caps.identity.source == isTmuxClient and caps.identity.endToEnd
    ck caps.identity.chainName == "tmux>kitty"
    ck caps.modernUnicode            # known end to end through tmux
    # Without a client termtype the outer terminal is unknown: no `auto`.
    var blind = probe
    blind.tmuxClientTermType = ""
    let unknown = resolveCapabilities(env, initCapabilityFlags(), blind,
      TerminalPrefs(global: TerminalChoices(modernUnicode: some(mcAuto))))
    ck not unknown.identity.known and not unknown.modernUnicode

  test "§10.3: the glyph test card":
    let card = glyphTestCard(resolveCapabilities(utf8Env,
                                                 initCapabilityFlags()))
    var text = ""
    for row in card:
      for span in row: text.add span.text
      text.add "\n"
    ck text.contains(CardRuler)
    ck text.contains("[\u{1FB87}]")
    ck text.contains(CardLegacyLabel)
    ck text.contains("ambiguous-wide modern-unicode")
    ck text.contains("[~]")

  test "§5.3: the settings' flags, words and contradictions":
    let c = parseTuiCommand(@["--glyphs=basic", "--modern-unicode=auto",
                              "--ambiguous-width=wide", "--colors=16",
                              "--no-probe", "trace"])
    ck c.kind == tckOpenTrace
    ck c.flags.choices.glyphs == some(gcBasic)
    ck c.flags.choices.modernUnicode == some(mcAuto)
    ck c.flags.choices.ambiguousWidth == some(acWide)
    ck c.flags.choices.colors == some(cc16)
    ck c.flags.choices.probe == some(false)
    let auto = parseTuiCommand(@["--glyphs=auto", "trace"])
    ck auto.flags.choices.glyphs.isNone
    ck parseTuiCommand(@["--glyphs=ascii", "--modern-unicode=on",
                         "trace"]).kind == tckUsageError
    ck parseTuiCommand(@["--ascii-borders", "--glyphs=extended",
                         "trace"]).kind == tckUsageError
    ck parseTuiCommand(@["--no-color", "--colors=256",
                         "trace"]).kind == tckUsageError
    ck parseTuiCommand(@["--card"]).kind == tckUsageError
    let report = parseTuiCommand(@["--capabilities=json"])
    ck report.kind == tckCapabilities and report.capabilitiesJson
    ck parseTuiCommand(@["--capabilities", "--card"]).capabilitiesCard
    # The remembered file: a `[terminal "<glob>"]` section is read back, and a
    # setting that is not a terminal one is refused inside it.
    let text = "glyphs=basic\nmodern-unicode=off\n" &
               "[terminal \"kitty*\"]\nmodern-unicode=on\n"
    let decoded = decodeLayoutSettings(text)
    ck decoded.ok
    ck decoded.settings.terminal.glyphs == "basic"
    ck decoded.settings.scoped.len == 1
    ck decoded.settings.scoped[0].glob == "kitty*"
    let prefs = prefsOf(decoded.settings)
    ck prefs.global.glyphs == some(gcBasic)
    ck prefs.global.modernUnicode.isNone   # `off` is the default, not a choice
    ck prefs.scoped[0].choices.modernUnicode == some(mcOn)
    ck encodeLayoutSettings(decoded.settings).contains(
      "[terminal \"kitty*\"]\nmodern-unicode=on\n")
    ck not decodeLayoutSettings("[terminal \"x\"]\nfocus-highlight=off\n").ok
    ck globMatch("kitty*", "kitty") and globMatch("tmux>*", "tmux>kitty")
    ck not globMatch("foot", "footx")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
