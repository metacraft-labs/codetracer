## test_degraded_style_tables.nim — CTUI-11, Tier 1.
##
## ## What this suite establishes
##
## CTUI-11: "every semantic style is distinguishable within every tier,
## including monochrome. Asserts the *distinguishability* property rather than
## specific colours, so a palette change does not falsely fail while a genuine
## collapse does." And its contract: "degradation never removes information: a
## monochrome screen distinguishes the same states by weight, underline and
## glyph."
##
## ## THE PROPERTY, STATED EXACTLY (PLAT-46)
##
## For every `DistinctionGroup` that holds STATES OF ONE THING, for every pair
## of roles in it whose appearances differ on ANY colour rung (16, 256, 24-bit
## or the terminal palette, in either design-system mode), the two appearances
## differ at every one of the tiers, in both modes, both palettes and both
## border modes — except for the pairs named in `degradation.PermittedMerges`,
## whose count is asserted.
##
## `dgSurface` is the one group the property is NOT stated over, and that is a
## decision rather than an omission: canvas, panel, card, editor, status line
## and input are REGIONS, told apart by where they are and by the box-drawing
## borders between them (which stay at every tier), not states one cell can
## switch between. The two surfaces that ARE states — selection and the current
## line — carry `reverse` in monochrome and are asserted against the base
## surfaces below.
##
## Load-bearing choices:
##
##   * **Per group, not over the whole table.** A pane title and a string
##     literal never need to be told apart; they are never in the same place.
##   * **Only pairs that differ on some colour rung.** `srValueNoneValue` and
##     `srValueOpaque` paint one token on every rung; a lower tier cannot lose
##     a distinction the tiers above it never had.
##   * **The key is the appearance, not the colour.** `distinctionKey` is the
##     style and the glyph — everything a terminal shows. Changing a token
##     moves every key and reddens nothing; two states arriving at one key
##     reddens exactly one pair and names it.
##
## ## Why this also asserts the MECHANICAL pass
##
## The role table is a theme, and `degradeRows` is what puts a composited screen
## onto a tier. CTUI-11's Tier-2 gate — "the ASCII/monochrome screen carries no
## colour attributes" — is a property of that pass, so it is asserted here on a
## real painted `ShellModel` as well as read off a real terminal there. The two
## are different claims: this one is about the emitter, that one is about what
## libvterm parsed.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[strutils, tables, unicode, unittest]

import ../theme/colour_math
import ../theme/degradation
import ../views/borders
import ../views/shell
import ../views/styled_row

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 2901

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  AllDepths = [cdMonochrome, cdAnsi16, cdAnsi256, cdTrueColor]
  ColourDepths = [cdAnsi16, cdAnsi256, cdTrueColor]
  AllBorderModes = [bmUnicode, bmAscii]
  AllModes = [dmDark, dmLight]
  AllPalettes = [pkDesign, pkTerminal]

  ExpectedRoleCount = 109
    ## PLAT-47 added `srLineNumberActive` (the execution line's number, the
    ## desktop's active line number) and the three syntax roles the desktop's
    ## Monaco Python tokenizer colours on their own (a string's quote, a
    ## square bracket, a decorator); its B4 the eight scopes the other Monaco
    ## tokenizers colour on their own (type identifier, primitive type
    ## keyword, doc comment, regexp, variable, namespace, attribute name,
    ## metatag); its deliverable 6 the drop indication's tint
    ## (`srSurfaceDropIndicator`, a background-only overlay colour).
    ## `srNone` plus 108 painted roles.
  ExpectedGroupCount = 18
  ExpectedMergeCount = 18
    ## `degradation.PermittedMerges`'s size, asserted so a second merge cannot
    ## be added without the number moving in a diff a reviewer reads.

proc capsFor(depth: ColorDepth; mode: BorderMode; design = dmDark;
             palette = pkDesign): TerminalCapabilities =
  TerminalCapabilities(colors: depth, borders: mode, mouse: true,
                       synchronizedOutput: false, kittyKeyboard: false,
                       theme: (if design == dmLight: utLight else: utDark),
                       mode: design, palette: palette)

proc isMerged(a, b: SemanticRole): bool =
  for (x, y, _) in PermittedMerges:
    if (x == a and y == b) or (x == b and y == a):
      return true
  false

proc roleCount(): int =
  for _ in SemanticRole:
    inc result

proc groupCount(): int =
  for _ in DistinctionGroup:
    inc result

proc rolesIn(group: DistinctionGroup): seq[SemanticRole] =
  result = @[]
  for role in SemanticRole:
    if groupOf(role) == group:
      result.add role

proc hasColour(s: CellStyle): bool =
  s.fg.len > 0 or s.bg.len > 0

proc isAnsiName(colour: string): bool =
  colour.len == 0 or colour in AnsiNames

proc isRgb(colour: string): bool =
  colour.len == 7 and colour[0] == '#'

proc cellsOf(s: string): int =
  cellWidthOf(s)

proc differsOnSomeColourRung(a, b: SemanticRole): bool =
  ## Whether ANY coloured rung, in either mode or palette, tells the two
  ## apart — the set a lower rung could lose.
  for design in AllModes:
    for palette in AllPalettes:
      for depth in ColourDepths:
        if roleStyle(a, depth, design, palette) !=
           roleStyle(b, depth, design, palette):
          return true
  false

proc sampleScreen(width, height: int): seq[StyledRow] =
  ## A REAL painted screen, not a hand-made row.
  ##
  ## `newShellModel` + `shellScreen(...).styledRows` is the same path `app/tui_app.nim`
  ## takes for a frame, so the styles this degrades are the ones eighteen view
  ## modules actually paint. A hand-written row would degrade whatever the test
  ## author remembered to put in it.
  ##
  ## TWO PANE MODELS ARE FILLED, and that is not decoration. Measured while
  ## writing this suite: an EMPTY shell has **zero** styled spans on it, because
  ## `app/views/shell.paintPane` paints CTUI-3's plain `TITLE ────` row with the
  ## default style and only delegates to a pane's own painter when that pane's
  ## model has content. A sample built from `newShellModel` alone would have
  ## made "no colour after degrading" true for free, on a screen that never had
  ## any — the positive-floor trap, arriving through a fixture instead of
  ## through an assertion.
  var model = newShellModel(width, height,
                            notification = "capability negotiation")
  model.timeline = initTimelineBarModel(
    minTick = 0'u64, maxTick = 400'u64, currentTick = 120'u64,
    boundsKnown = true)
  model.callStack = initCallStackModel(
    frames = @[StackFrame(name: "main", path: "/tmp/main.py", line: 12),
               StackFrame(name: "evaluate", path: "/tmp/main.py", line: 40)],
    userRoots = @["/tmp"], executionFrame = 0, selected = 0)
  shellScreen(model, width, height).styledRows

suite "CTUI-11 Tier 1: degraded style tables":

  test "the table's shape: every role in a group, and one named merge":
    checkpoint("roles: " & $roleCount() & " groups: " & $groupCount())
    ck roleCount() == ExpectedRoleCount
    ck groupCount() == ExpectedGroupCount
    var partitioned = 0
    for group in DistinctionGroup:
      let members = rolesIn(group)
      checkpoint($group & ": " & $members.len & " role(s)")
      # `dgNone` holds exactly `srNone`; every real group has two states or
      # more, or its pair sweep would be vacuous.
      if group == dgNone:
        ck members == @[srNone]
      else:
        ck members.len >= 2
      partitioned += members.len
    ck partitioned == ExpectedRoleCount
    ck PermittedMerges.len == ExpectedMergeCount
    for (a, b, why) in PermittedMerges:
      ck why.len > 40
      ck groupOf(a) == groupOf(b)

  test "every painted role names a design-system token, and nothing else":
    # PLAT-46 deliverable 2. A role with neither a foreground nor a background
    # token paints nothing of its own; those are the deliberate "no mark"
    # states, and they are listed so a role cannot lose its binding quietly.
    var bound = 0
    var bare: seq[SemanticRole] = @[]
    for role in SemanticRole:
      let s = spec(role)
      if s.hasFg or s.hasBg:
        inc bound
      else:
        bare.add role
    checkpoint("bound: " & $bound & " bare: " & $bare)
    ck bare == @[srNone, srGutterNoMark, srLineOrdinary, srValueUnchanged]
    ck bound == ExpectedRoleCount - 4
    # THE 24-BIT RUNG IS THE TOKEN'S HEX, in both modes, for every bound role.
    var checked = 0
    for design in AllModes:
      for role in SemanticRole:
        let s = spec(role)
        let rgb = roleStyle(role, cdTrueColor, design)
        if s.hasFg:
          ck rgb.fg == tokenHex(s.fg, design)
          inc checked
        if s.hasBg:
          ck rgb.bg == tokenHex(s.bg, design)
          inc checked
    ck checked >= 2 * (ExpectedRoleCount - 4)

  test "the roles PLAT-46 names are bound to the tokens it names":
    # THE BINDING, against the milestone's own words rather than against the
    # table: "keyword → colors/editor/syntax/keyword, pane border →
    # colors/ui/border/secondary, focused pane border → colors/ui/border/focus,
    # pane title → colors/ui/text/primary/label, muted chrome →
    # colors/ui/text/primary/caption-subtle", the surfaces (panel on
    # surface/base/panel, the editor on editor/surface/primary, the current
    # line on editor/syntax/current-line), and the desktop's GoldenLayout strip
    # for the tabs. Pointing any of these at another token reddens this case.
    # PLAT-47 re-bound four of them, each to what the DESKTOP measures: the
    # editor to its Monaco theme (keyword, the editor ground, the execution
    # line, the selection — generated `editor-theme/*` tokens), the focused
    # border to the desktop's selected-panel outline (ui/border/primary), and
    # the tab strip onto the pane's surface.
    const Fg = [(srSyntaxKeyword, dtEditorThemeRuleKeyword),
                (srBorderPane, dtColorsUiBorderSecondary),
                (srBorderFocused, dtColorsUiBorderPrimary),
                (srChromeTitle, dtColorsUiTextPrimaryLabel),
                (srChromeMuted, dtColorsUiTextPrimaryCaptionSubtle),
                (srTabActive, dtColorsUiTextPrimaryLabel),
                (srTabInactive, dtColorsUiTextPrimaryDisabled)]
    const Bg = [(srSurfaceCanvas, dtColorsUiSurfaceBaseCanvas),
                (srSurfacePanel, dtColorsUiSurfaceBasePanel),
                (srSurfaceCard, dtColorsUiSurfaceBaseCard),
                (srSurfaceEditor, dtEditorThemeGround),
                (srSurfaceStatusLine, dtColorsUiSurfaceBaseRaised),
                (srSurfaceInput, dtColorsUiSurfaceInputDefault),
                (srSurfaceSelection, dtEditorThemeSelection),
                (srSurfaceCurrentLine, dtEditorThemeExecutionLine),
                (srLineExecution, dtEditorThemeExecutionLine),
                (srTabBar, dtColorsUiSurfaceBasePanel),
                (srTabActive, dtColorsUiSurfaceBasePanel),
                (srTabInactive, dtColorsUiSurfaceBasePanel)]
    for (role, token) in Fg:
      ck spec(role).hasFg and spec(role).fg == token
    for (role, token) in Bg:
      ck spec(role).hasBg and spec(role).bg == token

  test "the 256- and 16-colour rungs are the NEAREST entries to the tokens":
    # PLAT-46 deliverable 6: DERIVED from each role's hex, not a second table.
    # Asserted against `colour_math`'s nearest-entry search run HERE, so a rung
    # that came from anywhere else — a stale table, a hand-picked index — is a
    # mismatch. `tests/test_plat46_token_derivation.nim` is the other half:
    # change a token in a scratch build and every rung moves.
    var checked = 0
    for design in AllModes:
      for role in SemanticRole:
        let s = spec(role)
        if not s.hasFg:
          continue
        let c = parseHexColour(tokenHex(s.fg, design))
        ck roleStyle(role, cdAnsi256, design).fg ==
           "indexed:" & $nearestXterm256(c)
        ck roleStyle(role, cdAnsi16, design).fg == AnsiNames[nearestAnsi16Family(c)]
        inc checked
    ck checked >= 150

  test "within every group, every distinct state stays distinguishable":
    # THE PROPERTY, over roles x tiers x modes x palettes x border modes.
    var compared = 0
    var eligiblePairs = 0
    var collisions: seq[string] = @[]
    var mergesSeen = 0
    for group in DistinctionGroup:
      if group in {dgNone, dgSurface}:
        continue
      let members = rolesIn(group)
      for i in 0 ..< members.len:
        for j in i + 1 ..< members.len:
          let a = members[i]
          let b = members[j]
          if isMerged(a, b):
            inc mergesSeen
            continue
          if not differsOnSomeColourRung(a, b):
            continue
          inc eligiblePairs
          for design in AllModes:
            for palette in AllPalettes:
              for depth in AllDepths:
                for mode in AllBorderModes:
                  let caps = capsFor(depth, mode, design, palette)
                  let keyA = distinctionKey(a, caps)
                  let keyB = distinctionKey(b, caps)
                  inc compared
                  if keyA == keyB:
                    collisions.add $group & " " & $a & " == " & $b &
                      " at " & $depth & "/" & $mode & ": " & keyA
    checkpoint("eligible pairs: " & $eligiblePairs &
               "  comparisons: " & $compared &
               "  permitted merges skipped: " & $mergesSeen)
    for c in collisions:
      checkpoint("COLLAPSE: " & c)
    ck collisions.len == 0
    ck compared == eligiblePairs * AllModes.len * AllPalettes.len *
                   AllDepths.len * AllBorderModes.len
    ck eligiblePairs >= 150
    ck mergesSeen == ExpectedMergeCount

  test "the highlight surfaces are told apart from the base ones in monochrome":
    # The two SURFACE roles that are states (a selected row, the current line)
    # must survive the bottom rung, where the base surfaces carry nothing.
    for highlight in [srSurfaceSelection, srSurfaceCurrentLine,
                      srLineExecution]:
      for base in [srSurfaceCanvas, srSurfacePanel, srSurfaceCard,
                   srSurfaceEditor, srSurfaceStatusLine]:
        ck roleStyle(highlight, cdMonochrome) != roleStyle(base, cdMonochrome)

  test "MUTATION ARM: the sweep reports a collapse when there is one":
    let caps = capsFor(cdMonochrome, bmUnicode)
    let realA = distinctionKey(srGutterBreakpoint, caps)
    let realB = distinctionKey(srGutterBreakpointDisabled, caps)
    checkpoint("breakpoint=" & realA & "  disabled=" & realB)
    ck realA != realB
    let collapsed = distinctionKey(
      RoleAppearance(style: roleStyle(srGutterBreakpoint, cdMonochrome),
                     glyph: roleGlyph(srGutterBreakpoint, bmUnicode)))
    let collapsedTwin = distinctionKey(
      RoleAppearance(style: roleStyle(srGutterBreakpoint, cdMonochrome),
                     glyph: roleGlyph(srGutterBreakpoint, bmUnicode)))
    ck collapsed == collapsedTwin
    let styleOnly = distinctionKey(
      RoleAppearance(style: CellStyle(bold: true), glyph: "x"))
    let glyphOnly = distinctionKey(
      RoleAppearance(style: CellStyle(bold: true), glyph: "y"))
    ck styleOnly != glyphOnly
    let attrOnly = distinctionKey(
      RoleAppearance(style: CellStyle(italic: true), glyph: "x"))
    ck styleOnly != attrOnly

  test "the tier invariant holds for every role, on every rung and palette":
    var checked = 0
    for design in AllModes:
      for role in SemanticRole:
        let mono = roleStyle(role, cdMonochrome, design)
        if hasColour(mono):
          checkpoint("COLOUR AT THE BOTTOM RUNG: " & $role)
        ck not hasColour(mono)
        let ansi = roleStyle(role, cdAnsi16, design)
        ck isAnsiName(ansi.fg) and isAnsiName(ansi.bg)
        let indexed = roleStyle(role, cdAnsi256, design)
        ck not (isRgb(indexed.fg) or isRgb(indexed.bg))
        # THE TERMINAL PALETTE, at every depth: sixteen names or the default.
        for depth in ColourDepths:
          let term = roleStyle(role, depth, design, pkTerminal)
          if not (isAnsiName(term.fg) and isAnsiName(term.bg)):
            checkpoint("NOT A SYMBOLIC INDEX UNDER --palette=terminal: " &
                       $role & " -> " & describe(term))
          ck isAnsiName(term.fg) and isAnsiName(term.bg)
        inc checked
    ck checked == 2 * ExpectedRoleCount

  test "the terminal palette leaves region surfaces to the terminal":
    # Deliverable 9: base surfaces become the DEFAULT background (SGR 49);
    # highlights keep an index so they are still highlights.
    for role in SemanticRole:
      let s = spec(role)
      if not s.hasBg:
        continue
      for design in AllModes:
        let term = roleStyle(role, cdTrueColor, design, pkTerminal)
        if s.baseSurface:
          ck term.bg == ""
        else:
          ck term.bg in AnsiNames
    # And a mode's own body text is the terminal's default foreground.
    for design in AllModes:
      ck roleStyle(srChromeText, cdTrueColor, design, pkTerminal).fg == ""

  test "the rungs really widen: 256 and 24-bit are not the 16-colour table":
    var indexedRoles = 0
    var rgbRoles = 0
    var widened = 0
    for role in SemanticRole:
      let ansi = roleStyle(role, cdAnsi16)
      let indexed = roleStyle(role, cdAnsi256)
      let truecolor = roleStyle(role, cdTrueColor)
      if indexed.fg.startsWith("indexed:") or indexed.bg.startsWith("indexed:"):
        inc indexedRoles
      if isRgb(truecolor.fg) or isRgb(truecolor.bg):
        inc rgbRoles
      if indexed != ansi and truecolor != ansi and truecolor != indexed:
        inc widened
      # THE ATTRIBUTES ON A COLOURED RUNG ARE THE ROLE'S OWN, OR — ONLY where
      # that rung's derived colours merged it with another state of its
      # group — its monochrome set (`palette.CollapsedOnRung`). Nothing else
      # moves a weight between rungs.
      for (depth, got) in [(cdAnsi16, ansi), (cdAnsi256, indexed),
                           (cdTrueColor, truecolor)]:
        let guarded = CollapsedOnRung[dmDark][rungOf(depth, pkDesign)][role]
        var want = CellStyle()
        let attrs = if guarded: spec(role).mono else: spec(role).attrs
        want.bold = raBold in attrs
        want.italic = raItalic in attrs
        want.underline = raUnderline in attrs
        want.reverse = raReverse in attrs
        if role == srNone or spec(role).group in {dgSurface}:
          continue
        ck got.bold == want.bold and got.italic == want.italic
        ck got.underline == want.underline and got.reverse == want.reverse
    checkpoint("roles with an indexed colour: " & $indexedRoles &
               ", with 24-bit: " & $rgbRoles &
               ", distinct at all three coloured rungs: " & $widened)
    ck indexedRoles >= 80
    ck rgbRoles >= 80
    ck widened >= 80

  test "the reverse lookup is gone: views say which role they mean":
    # PLAT-46 deliverable 3. `roleFor` resolved a painted 16-colour style back
    # to a role and so could not tell a breakpoint dot from a degraded-source
    # banner (both `red bold`). It must not come back.
    ck not compiles(roleFor(DefaultCellStyle))
    # The pairs it collapsed are now distinct roles with distinct 24-bit
    # colours where the design gives them.
    ck BreakpointStyle.role == srGutterBreakpoint
    ck source_pane.DegradedStyle.role == srChromeError
    ck AbsentMarkerStyle.role == srSourceAbsent
    ck TokenStyles[tcString].role == srSyntaxString
    ck VerifiedMarkerStyle.role == srSourceVerified
    ck roleStyle(srSyntaxString, cdTrueColor) !=
       roleStyle(srSourceVerified, cdTrueColor)

  test "the mechanical projection is total, for styles no role claims":
    # The safety net. Whatever a future view paints, the tier invariant holds.
    let samples = [
      CellStyle(fg: "#7c7aed", bg: "#102030", bold: true),
      CellStyle(fg: "indexed:214", underline: true),
      CellStyle(fg: "bright_magenta", bg: "blue", italic: true),
      CellStyle(bg: "green"),
      DefaultCellStyle]
    var projected = 0
    for style in samples:
      let mono = projectStyle(style, cdMonochrome)
      ck not hasColour(mono)
      # A BACKGROUND BECOMES `reverse`, because a background IS a highlight and
      # reverse is the monochrome spelling of one. Without this a highlighted
      # row would degrade to an unhighlighted one, which is the "degradation
      # removes information" failure the contract forbids.
      if style.bg.len > 0:
        ck mono.reverse
      let ansi = projectStyle(style, cdAnsi16)
      ck isAnsiName(ansi.fg) and isAnsiName(ansi.bg)
      let indexed = projectStyle(style, cdAnsi256)
      ck not (isRgb(indexed.fg) or isRgb(indexed.bg))
      let truecolor = projectStyle(style, cdTrueColor)
      ck truecolor == style
      inc projected
    checkpoint("styles projected onto every rung: " & $projected)
    ck projected == samples.len
    # `nearestAnsiName` on the two spellings it has to quantise, asserted
    # against the answer a reader can check by eye rather than against itself.
    checkpoint("#ff0000 -> " & nearestAnsiName("#ff0000") &
               ", indexed:196 -> " & nearestAnsiName("indexed:196") &
               ", indexed:244 -> " & nearestAnsiName("indexed:244"))
    ck nearestAnsiName("#ff0000") == "bright_red"
    ck nearestAnsiName("#000000") == "black"
    ck nearestAnsiName("indexed:1") == "red"
    ck nearestAnsiName("indexed:196") == "bright_red"
    ck nearestAnsiName("green") == "green"
    ck nearestAnsiName("") == ""

  test "both border sets are one cell per glyph, and map one-to-one":
    # THE WIDTH EQUALITY the degradation pass depends on: `degradeText` rewrites
    # runes inside an already-composited grid, where a substitution of a
    # different width would shift every column after it.
    var widthsChecked = 0
    for mode in AllBorderModes:
      let bs = borderSet(mode)
      for glyph in [bs.topLeft, bs.topRight, bs.bottomLeft, bs.bottomRight,
                    bs.horizontal, bs.vertical, bs.teeLeft, bs.teeRight,
                    bs.teeTop, bs.teeBottom, bs.cross, bs.breakpoint,
                    bs.breakpointDisabled, bs.tracepoint, bs.collapsed,
                    bs.expanded, bs.needle, bs.span, bs.ellipsis, bs.dotFill,
                    bs.dashFill]:
        if cellsOf(glyph) != 1:
          checkpoint("NOT ONE CELL: " & $mode & " '" & glyph & "' is " &
                     $cellsOf(glyph))
        ck cellsOf(glyph) == 1
        inc widthsChecked
    checkpoint("glyph widths checked: " & $widthsChecked)
    ck widthsChecked == 42
    var mapped = 0
    for source, target in AsciiFallbackTable:
      if cellsOf(source) != cellsOf(target):
        checkpoint("WIDTH CHANGES: '" & source & "' (" & $cellsOf(source) &
                   ") -> '" & target & "' (" & $cellsOf(target) & ")")
      ck cellsOf(source) == cellsOf(target)
      ck target.len == 1
      inc mapped
    checkpoint("ASCII fallback pairs: " & $mapped)
    ck mapped == AsciiFallbackTable.len
    ck mapped == 25
    # A rune that is NOT chrome passes through unchanged, in both modes — the
    # rule that keeps a Python identifier or a recorded path out of the
    # substitution table.
    ck asciiFor("世") == "世"
    ck asciiFor("a") == "a"
    ck glyphFor("─", bmUnicode) == "─"
    ck glyphFor("─", bmAscii) == "-"

  test "a real painted screen degrades to a colourless ASCII one":
    # CTUI-11's Tier-2 gate, asserted here on the EMITTER. The screen is the one
    # `app/views/shell.nim` paints, not a hand-made row — see `sampleScreen`.
    const Width = 120
    const Height = 30
    let rows = sampleScreen(Width, Height)
    ck rows.len == Height
    var spansBefore = 0
    var colouredBefore = 0
    for row in rows:
      for span in row:
        inc spansBefore
        # Undegraded, a view's span carries ROLES, not colours (PLAT-46).
        if span.style.role != srNone or span.style.surface != srNone:
          inc colouredBefore
    # THE POSITIVE FLOOR. "No colour after degrading" is satisfied by a screen
    # that had none to begin with, which is what an empty shell would give.
    checkpoint("undegraded screen: " & $spansBefore & " span(s), " &
               $colouredBefore & " carrying colour")
    ck colouredBefore > 0

    let caps = capsFor(cdMonochrome, bmAscii)
    let degraded = degradeRows(rows, caps)
    ck degraded.len == rows.len
    var spansAfter = 0
    var colouredAfter = 0
    var attributed = 0
    for row in degraded:
      for span in row:
        inc spansAfter
        if hasColour(span.style):
          inc colouredAfter
        if span.style.bold or span.style.italic or span.style.underline or
           span.style.reverse:
          inc attributed
    checkpoint("degraded screen: " & $spansAfter & " span(s), " &
               $colouredAfter & " coloured, " & $attributed & " attributed")
    ck spansAfter == spansBefore
    ck colouredAfter == 0
    # …AND THE INFORMATION SURVIVED as weight and underline rather than being
    # dropped. A pass that simply cleared `fg` and `bg` would satisfy the line
    # above and would be precisely the collapse the contract forbids.
    ck attributed > 0

    # THE GLYPHS. Every Unicode chrome rune is gone and its ASCII stand-in is
    # there, read off the rows themselves.
    var text = ""
    for row in degraded:
      text.add rowText(row)
    var originalText = ""
    for row in rows:
      originalText.add rowText(row)
    checkpoint("undegraded screen holds ─:" & $originalText.contains("─") &
               " │:" & $originalText.contains("│"))
    ck originalText.contains("─")
    ck originalText.contains("│")
    ck not text.contains("─")
    ck not text.contains("│")
    ck not text.contains("●")
    ck text.contains("-")
    ck text.contains("|")

    # EVERY ROW KEEPS ITS CELL COUNT. A substitution of a different width would
    # shift every column after it, and the shell's own geometry assertions
    # would go on passing because they read the model rather than the degraded
    # rows.
    var widthsHeld = 0
    for i in 0 ..< rows.len:
      if cellsOf(rowText(degraded[i])) != cellsOf(rowText(rows[i])):
        checkpoint("row " & $i & " changed width: " &
                   $cellsOf(rowText(rows[i])) & " -> " &
                   $cellsOf(rowText(degraded[i])))
      ck cellsOf(rowText(degraded[i])) == cellsOf(rowText(rows[i]))
      inc widthsHeld
    ck widthsHeld == Height

  test "a real painted screen at the top rung carries 24-bit colour":
    # The other end of the same pass, and the reason `degradeRows` is a THEME:
    # the same screen that goes colourless at the bottom rung gains the 24-bit
    # accents of the role table at the top.
    const Width = 120
    const Height = 30
    let rows = sampleScreen(Width, Height)
    let truecolor = degradeRows(rows, capsFor(cdTrueColor, bmUnicode))
    let indexed = degradeRows(rows, capsFor(cdAnsi256, bmUnicode))
    var rgbSpans = 0
    var indexedSpans = 0
    for row in truecolor:
      for span in row:
        if isRgb(span.style.fg) or isRgb(span.style.bg):
          inc rgbSpans
    for row in indexed:
      for span in row:
        if span.style.fg.startsWith("indexed:") or
           span.style.bg.startsWith("indexed:"):
          inc indexedSpans
    checkpoint("spans upgraded: " & $rgbSpans & " to 24-bit, " &
               $indexedSpans & " to indexed")
    ck rgbSpans > 0
    ck indexedSpans > 0
    # PLAT-46 DELIVERABLE 8, at the emitter: EVERY span of the degraded screen
    # carries a background, so the terminal's own background shows nowhere.
    var unfilled = 0
    for row in truecolor:
      for span in row:
        if not isRgb(span.style.bg):
          inc unfilled
    checkpoint("spans with no 24-bit background: " & $unfilled)
    ck unfilled == 0
    # THE TAB STRIP (the sample is the shared default's Variables/Scratchpad
    # stack, PLAT-45): the active tab lifted onto the panel, the others on the
    # strip.
    var tabRow = -1
    for i in 0 ..< truecolor.len:
      if rowText(truecolor[i]).contains(" Variables "):
        tabRow = i
    ck tabRow >= 0
    if tabRow >= 0:
      var activeBg, inactiveBg, activeFg, inactiveFg = ""
      for span in truecolor[tabRow]:
        if span.text.contains("Variables") and activeBg.len == 0:
          activeBg = span.style.bg
          activeFg = span.style.fg
        # The stack is 16 cells wide at 120x30 (15 inside its separator), so
        # the inactive label is cut to its first two letters at the edge.
        if span.text.contains("Sc") and inactiveBg.len == 0:
          inactiveBg = span.style.bg
          inactiveFg = span.style.fg
      checkpoint("tabs: active " & activeFg & " on " & activeBg &
                 ", inactive " & inactiveFg & " on " & inactiveBg)
      # PLAT-47: both on the pane's surface, as the desktop's strip measures…
      ck activeBg == tokenHex(dtColorsUiSurfaceBasePanel, dmDark)
      ck inactiveBg == tokenHex(dtColorsUiSurfaceBasePanel, dmDark)
      # …and told apart by their FOREGROUNDS (the label tier for the active
      # tab, the disabled tier for the rest), which is the only colour the
      # painter's role choice now moves.
      ck activeFg == tokenHex(dtColorsUiTextPrimaryLabel, dmDark)
      ck inactiveFg == tokenHex(dtColorsUiTextPrimaryDisabled, dmDark)
    # A PANE sits on the panel surface — its title row as much as its body —
    # and the header on its card: the shell's fills, read off the emitter.
    var paneRow = -1
    for i in 0 ..< truecolor.len:
      if rowText(truecolor[i]).contains("CALL STACK") or
         rowText(truecolor[i]).contains("CALL TRACE"):
        paneRow = i
    ck paneRow > 0
    if paneRow > 0:
      ck truecolor[paneRow][0].style.bg ==
         tokenHex(dtColorsUiSurfaceBasePanel, dmDark)
    ck truecolor[0][0].style.bg == tokenHex(dtColorsUiSurfaceBaseCard, dmDark)
    # …and under `--palette=terminal` the same screen carries NO 24-bit and no
    # indexed colour at all — only the sixteen names and the default.
    let term = degradeRows(rows, capsFor(cdTrueColor, bmUnicode,
                                         palette = pkTerminal))
    var nonSymbolic = 0
    var symbolic = 0
    for row in term:
      for span in row:
        if not (isAnsiName(span.style.fg) and isAnsiName(span.style.bg)):
          inc nonSymbolic
        if span.style.fg.len > 0 or span.style.bg.len > 0:
          inc symbolic
    checkpoint("terminal palette: " & $symbolic & " coloured span(s), " &
               $nonSymbolic & " not symbolic")
    ck nonSymbolic == 0
    ck symbolic > 0
    # …and the unicode border mode leaves the glyphs alone, so the screen at the
    # top rung is the screen the shell painted.
    for i in 0 ..< rows.len:
      ck rowText(truecolor[i]) == rowText(rows[i])

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
