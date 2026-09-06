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
## ## THE PROPERTY, STATED EXACTLY
##
## For every `DistinctionGroup`, for every pair of roles in it whose SIXTEEN-
## COLOUR appearances differ, the two appearances differ at every one of the
## four tiers and in both border modes — except for the pairs named in
## `degradation.PermittedMerges`, whose count is asserted.
##
## Three parts of that sentence are load-bearing and each was chosen against an
## alternative that would have made the suite weaker:
##
##   * **Per group, not over the whole table.** A pane title and a string
##     literal never need to be told apart; they are never in the same place. A
##     verified breakpoint and a disabled one always do. Requiring all 595 pairs
##     to differ would have forced arbitrary attribute combinations onto roles
##     that share no screen, which is a table nobody could read and a property
##     nobody would keep.
##   * **Only pairs that differ at 16 colours.** `srGutterTracepoint` and
##     `srGutterInspectionPointer` are both `cyan bold` on the screen this
##     front-end paints today. A lower tier cannot lose a distinction that the
##     tier above it never had, and demanding one would be demanding that
##     degradation ADD information.
##   * **The key is the appearance, not the colour.** `distinctionKey` is the
##     style and the glyph — everything a terminal shows. Re-picking a palette
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

import ../theme/degradation
import ../views/borders
# `TracepointStyle` is published TWICE — `gutter`'s cyan gutter diamond and
# `event_log`'s magenta row tint — and `views/shell` re-exports both. Imported
# by name so the constants below are qualified rather than ambiguous.
import ../views/gutter
import ../views/shell
import ../views/styled_row

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 1358

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  AllDepths = [cdMonochrome, cdAnsi16, cdAnsi256, cdTrueColor]
  AllBorderModes = [bmUnicode, bmAscii]
  AnsiNames = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "bright_black", "bright_red", "bright_green", "bright_yellow",
    "bright_blue", "bright_magenta", "bright_cyan", "bright_white"]

  ExpectedRoleCount = 35
  ExpectedGroupCount = 7
  ExpectedMergeCount = 1
    ## `degradation.PermittedMerges`'s size, asserted so a second merge cannot
    ## be added without the number moving in a diff a reviewer reads. The same
    ## construction `testing/dual_snap.CrossTierExclusionCount` uses.

proc capsFor(depth: ColorDepth; mode: BorderMode;
             theme = utDark): TerminalCapabilities =
  TerminalCapabilities(colors: depth, borders: mode, mouse: true,
                       synchronizedOutput: false, kittyKeyboard: false,
                       theme: theme)

const AllThemes = [utDark, utLight, utPlain, utMonokai]
  ## §6.2's four published themes — CTUI-14. Spelled as an array rather than
  ## iterated from `UiTheme` so the sweep below can assert its comparison count
  ## against a NUMBER a reader can check, which is what
  ## `compared == pairs * depths * modes * themes` is for.

proc isMerged(a, b: SemanticRole): bool =
  ## Whether this pair is one `PermittedMerges` names, in either order.
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
  ## `app/views/styled_row.cellWidthOf`, named locally so the checks below read
  ## as a width comparison. The production width table, not `len` — a
  ## three-byte box-drawing glyph is one cell and `len` says three.
  cellWidthOf(s)

proc sampleScreen(width, height: int): seq[StyledRow] =
  ## A REAL painted screen, not a hand-made row.
  ##
  ## `newShellModel` + `shellStyledRows` is the same path `app/tui_app.nim`
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
  shellStyledRows(model, width, height)

suite "CTUI-11 Tier 1: degraded style tables":

  test "the table's shape: 35 roles in 7 groups, and one named merge":
    checkpoint("roles: " & $roleCount() & " groups: " & $groupCount())
    ck roleCount() == ExpectedRoleCount
    ck groupCount() == ExpectedGroupCount
    # EVERY GROUP IS NON-EMPTY and the partition is total: a role whose
    # `groupOf` arm went missing would land in some group's `..` range silently,
    # and a group with no members would make its pair sweep vacuous.
    var partitioned = 0
    for group in DistinctionGroup:
      let members = rolesIn(group)
      checkpoint($group & ": " & $members.len & " role(s)")
      ck members.len >= 2
      partitioned += members.len
    ck partitioned == ExpectedRoleCount
    checkpoint("permitted merges: " & $PermittedMerges.len)
    ck PermittedMerges.len == ExpectedMergeCount
    for (a, b, why) in PermittedMerges:
      # Each merge names its own justification, and the pair is in ONE group —
      # a merge across groups would be meaningless, because the property is
      # only ever asserted within one.
      ck why.len > 40
      ck groupOf(a) == groupOf(b)

  test "within every group, every distinct state stays distinguishable":
    # THE PROPERTY. See this suite's header for why it is stated per group and
    # over pairs that differ at sixteen colours.
    var compared = 0
    var eligiblePairs = 0
    var collisions: seq[string] = @[]
    var mergesSeen = 0
    for group in DistinctionGroup:
      let members = rolesIn(group)
      for i in 0 ..< members.len:
        for j in i + 1 ..< members.len:
          let a = members[i]
          let b = members[j]
          if ansi16Style(a) == ansi16Style(b):
            # Already one appearance at the tier above; a lower tier cannot
            # lose what was never there.
            continue
          if isMerged(a, b):
            inc mergesSeen
            continue
          inc eligiblePairs
          for depth in AllDepths:
            for mode in AllBorderModes:
              let caps = capsFor(depth, mode)
              let keyA = distinctionKey(a, caps)
              let keyB = distinctionKey(b, caps)
              inc compared
              if keyA == keyB:
                collisions.add $group & " " & $a & " == " & $b & " at " &
                               $depth & "/" & $mode & ": " & keyA
    checkpoint("eligible pairs: " & $eligiblePairs &
               "  comparisons: " & $compared &
               "  permitted merges skipped: " & $mergesSeen)
    if collisions.len > 0:
      for c in collisions:
        checkpoint("COLLAPSE: " & c)
    ck collisions.len == 0
    # THE COMPARISON COUNT AGAINST ITS PARAMETERS. `collisions.len == 0` is
    # satisfied by a sweep that compared nothing, which is what a `rolesIn` that
    # stopped matching would produce.
    ck compared == eligiblePairs * AllDepths.len * AllBorderModes.len
    ck eligiblePairs >= 60
    ck mergesSeen == ExpectedMergeCount

  test "no THEME collapses a distinction, over all four of them":
    # CTUI-14. A theme is a PALETTE and never a distinction, and the case above
    # asserts that for `utDark` alone because `roleStyle`'s theme parameter
    # defaults to it. This is the same property over the whole cross product —
    # roles x depths x border modes x themes — and it is the check that would
    # redden if a hue picked for `light` or `monokai` happened to collide with
    # another role's in the same group.
    var compared = 0
    var eligiblePairs = 0
    var collisions: seq[string] = @[]
    for group in DistinctionGroup:
      let members = rolesIn(group)
      for i in 0 ..< members.len:
        for j in i + 1 ..< members.len:
          let a = members[i]
          let b = members[j]
          if ansi16Style(a) == ansi16Style(b):
            continue
          if isMerged(a, b):
            continue
          inc eligiblePairs
          for theme in AllThemes:
            for depth in AllDepths:
              for mode in AllBorderModes:
                let caps = capsFor(depth, mode, theme)
                inc compared
                if distinctionKey(a, caps) == distinctionKey(b, caps):
                  collisions.add $theme & " " & $group & " " & $a & " == " &
                                 $b & " at " & $depth & "/" & $mode
    checkpoint("eligible pairs: " & $eligiblePairs & "  comparisons: " &
               $compared & " over " & $AllThemes.len & " theme(s)")
    if collisions.len > 0:
      for c in collisions:
        checkpoint("THEME COLLAPSE: " & c)
    ck collisions.len == 0
    # THE COMPARISON COUNT AGAINST ITS PARAMETERS, which is what says the theme
    # axis was actually swept rather than iterated over one value.
    ck compared == eligiblePairs * AllThemes.len * AllDepths.len *
                   AllBorderModes.len
    ck AllThemes.len == 4

  test "a theme moves the COLOURS and never the attributes":
    # THE OTHER HALF OF "a theme is a palette". `ansi256Style` and
    # `trueColorStyle` are built by widening `ansi16Style` and overwriting `fg`
    # / `bg`, so a theme cannot reach a weight — and that is asserted rather
    # than left to the construction, because the construction is one edit away
    # from being different.
    var moved = 0
    var roles = 0
    for role in SemanticRole:
      inc roles
      let dark = ansi256Style(role, utDark)
      for theme in AllThemes:
        let tinted = ansi256Style(role, theme)
        ck tinted.bold == dark.bold
        ck tinted.italic == dark.italic
        ck tinted.underline == dark.underline
        ck tinted.reverse == dark.reverse
        let rgb = trueColorStyle(role, theme)
        ck rgb.bold == dark.bold
        ck rgb.italic == dark.italic
        if theme notin [utDark, utPlain] and tinted != dark:
          inc moved
    checkpoint($roles & " role(s); " & $moved &
               " (theme, role) pair(s) whose colour moved off the dark table")
    ck roles == ExpectedRoleCount
    # THE NON-VACUITY FLOOR, and the important one here: a `tintsFor` that
    # answered `DarkTints` for everything would satisfy every equality above
    # and move nothing. Two themes x at least twenty-five tinted roles.
    ck moved >= 50
    # …AND `utPlain` IS DELIBERATELY THE DARK TABLE, because it never reaches a
    # coloured rung at all: `resolveColorDepth` sends it to `cdMonochrome`.
    for role in SemanticRole:
      ck ansi256Style(role, utPlain) == ansi256Style(role, utDark)

  test "MUTATION ARM: the sweep reports a collapse when there is one":
    # A comparison that cannot be made to fail is indistinguishable from one
    # that is not reading the table. The COMPARISON is the same
    # `distinctionKey` the case above uses; what is mutated is the pair handed
    # to it.
    let caps = capsFor(cdMonochrome, bmUnicode)
    # A genuine pair, which must differ …
    let realA = distinctionKey(srGutterBreakpoint, caps)
    let realB = distinctionKey(srGutterBreakpointDisabled, caps)
    checkpoint("breakpoint=" & realA & "  disabled=" & realB)
    ck realA != realB
    # … and a COLLAPSED pair, built by giving two roles one appearance, which
    # the same comparison must report as equal.
    let collapsed = distinctionKey(
      RoleAppearance(style: roleStyle(srGutterBreakpoint, cdMonochrome),
                     glyph: roleGlyph(srGutterBreakpoint, bmUnicode)))
    let collapsedTwin = distinctionKey(
      RoleAppearance(style: roleStyle(srGutterBreakpoint, cdMonochrome),
                     glyph: roleGlyph(srGutterBreakpoint, bmUnicode)))
    ck collapsed == collapsedTwin
    # … and the two halves of the key each matter on their own: a pair that
    # differs ONLY in glyph and a pair that differs ONLY in style must both be
    # reported as distinct, or the key is reading one half.
    let styleOnly = distinctionKey(
      RoleAppearance(style: CellStyle(bold: true), glyph: "x"))
    let glyphOnly = distinctionKey(
      RoleAppearance(style: CellStyle(bold: true), glyph: "y"))
    ck styleOnly != glyphOnly
    let attrOnly = distinctionKey(
      RoleAppearance(style: CellStyle(italic: true), glyph: "x"))
    ck styleOnly != attrOnly

  test "the tier invariant holds for every role, on every rung":
    # WHAT EACH RUNG MAY CONTAIN. The monochrome arm is CTUI-11's own gate,
    # stated over the table rather than over a screen.
    var monoChecked = 0
    var ansiChecked = 0
    var indexedChecked = 0
    for role in SemanticRole:
      let mono = roleStyle(role, cdMonochrome)
      if hasColour(mono):
        checkpoint("COLOUR AT THE BOTTOM RUNG: " & $role & " -> " &
                   describe(mono))
      ck not hasColour(mono)
      inc monoChecked

      let ansi = roleStyle(role, cdAnsi16)
      if not (isAnsiName(ansi.fg) and isAnsiName(ansi.bg)):
        checkpoint("NOT AN ANSI NAME AT THE 16-COLOUR RUNG: " & $role &
                   " -> " & describe(ansi))
      ck isAnsiName(ansi.fg) and isAnsiName(ansi.bg)
      inc ansiChecked

      let indexed = roleStyle(role, cdAnsi256)
      if isRgb(indexed.fg) or isRgb(indexed.bg):
        checkpoint("24-BIT AT THE 256-COLOUR RUNG: " & $role & " -> " &
                   describe(indexed))
      ck not (isRgb(indexed.fg) or isRgb(indexed.bg))
      inc indexedChecked
    checkpoint("roles checked per rung: mono " & $monoChecked & ", ansi16 " &
               $ansiChecked & ", ansi256 " & $indexedChecked)
    ck monoChecked == ExpectedRoleCount
    ck ansiChecked == ExpectedRoleCount
    ck indexedChecked == ExpectedRoleCount

  test "the rungs really widen: 256 and 24-bit are not the 16-colour table":
    # THE POSITIVE TWIN of the invariant above. "No RGB at 256" is satisfied by
    # a 256 rung that is byte-identical to the 16-colour one — which is what
    # this ladder was before `indexed:N` existed as an inline-style spelling,
    # and it would have been a four-tier comment over a three-tier table.
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
      # THE ATTRIBUTES NEVER MOVE between rungs. A widening that also changed a
      # weight could not preserve the distinguishability property upward, since
      # the property is asserted per tier and not by induction.
      ck indexed.bold == ansi.bold and indexed.italic == ansi.italic
      ck indexed.underline == ansi.underline and indexed.reverse == ansi.reverse
      ck truecolor.bold == ansi.bold and truecolor.italic == ansi.italic
    checkpoint("roles with an indexed colour: " & $indexedRoles &
               ", with 24-bit: " & $rgbRoles &
               ", distinct at all three coloured rungs: " & $widened)
    ck indexedRoles >= 25
    ck rgbRoles >= 25
    ck widened >= 25

  test "the reverse lookup claims every published pane style, consistently":
    # WHAT MAKES THE TABLE A THEME RATHER THAN A DOCUMENT. `degradeRows` maps a
    # painted style through `roleFor`; if that lookup missed, every pane would
    # fall through to the mechanical projection and the role table would be
    # decoration.
    #
    # WHAT IS ASSERTED IS CONSISTENCY, NOT IDENTITY, and the difference was
    # measured rather than assumed. `roleFor` keys on the SIXTEEN-COLOUR
    # appearance alone, and four of the twelve constants below share one with a
    # role declared earlier in the enum:
    #
    #   gutter.BreakpointStyle       (red bold)         == srChromeError
    #   gutter.BreakpointDisabledStyle (bright_black)   == srChromeMuted
    #   source_pane.AbsentMarkerStyle (red bold)        == srChromeError
    #   source_pane.TokenStyles[tcString] (green)       == srSourceVerified
    #
    # Those pairs are ALREADY one appearance on the screen this front-end paints
    # today — a breakpoint dot and a degraded-source banner really are the same
    # red bold — so mapping them to one role removes nothing a lower tier could
    # have shown. Asserting a specific role NAME would therefore have been
    # asserting the enum's declaration order, which is not a product fact. What
    # is a product fact is that the lookup CLAIMS every published style and
    # round-trips it: `ansi16Style(roleFor(s)) == s`.
    #
    # The consequence for a monochrome screen is that such a pair is told apart
    # by GLYPH rather than by weight — `●` against a banner's text — which is
    # exactly what CTUI-11's contract says degradation may fall back on.
    var resolved = 0
    var roundTripped = 0
    for style in [BreakpointStyle, BreakpointDisabledStyle,
                  gutter.TracepointStyle, ExecutionPointerStyle,
                  VerifiedMarkerStyle, UnverifiedMarkerStyle,
                  AbsentMarkerStyle, TokenStyles[tcKeyword],
                  TokenStyles[tcString], TokenStyles[tcComment],
                  NeedleStyle, ModifiedNameStyle]:
      let (claimed, role) = roleFor(style)
      if not claimed:
        checkpoint("UNCLAIMED published style: " & describe(style))
      ck claimed
      if claimed:
        if ansi16Style(role) != style:
          checkpoint("roleFor(" & describe(style) & ") -> " & $role &
                     " whose 16-colour style is " & describe(ansi16Style(role)))
        ck ansi16Style(role) == style
        inc roundTripped
      inc resolved
    checkpoint("published pane constants claimed: " & $resolved &
               ", round-tripped: " & $roundTripped)
    ck resolved == 12
    ck roundTripped == 12
    # THE FOUR ROLES WHOSE OWN CONSTANT IS UNAMBIGUOUS still resolve to
    # themselves, so the lookup is not simply answering "the first role" for
    # everything.
    var exact = 0
    for (style, expected) in [
        (gutter.TracepointStyle, srGutterTracepoint),
        (ExecutionPointerStyle, srGutterExecutionPointer),
        (UnverifiedMarkerStyle, srSourceUnverified),
        (TokenStyles[tcKeyword], srSyntaxKeyword)]:
      let (claimed, role) = roleFor(style)
      ck claimed
      ck role == expected
      inc exact
    ck exact == 4
    # THE NEGATIVE TWIN: a style no role publishes must report UNCLAIMED rather
    # than being silently mapped onto whichever role sorts first.
    let (claimed, _) = roleFor(CellStyle(fg: "#123456", italic: true,
                                         reverse: true))
    ck not claimed

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
        if hasColour(span.style):
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
    # …and the unicode border mode leaves the glyphs alone, so the screen at the
    # top rung is the screen the shell painted.
    for i in 0 ..< rows.len:
      ck rowText(truecolor[i]) == rowText(rows[i])

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
