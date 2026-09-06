## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/degradation.nim — CTUI-11. One style table per colour tier, and
## the pass that puts a composited screen onto the tier the terminal actually
## has.
##
## ## The contract, restated exactly
##
## CTUI-11: *"Degradation never removes information: a monochrome screen
## distinguishes the same states by weight, underline and glyph."* Two things
## follow, and they are different enough that this module has two halves.
##
## **`SemanticRole` and `roleStyle` are the table.** Thirty-four named roles,
## grouped into the sets whose members are STATES OF ONE THING — the three
## breakpoint states, the three source-provenance verdicts, the nine token
## classes, the five parts of a timeline. Within a group, any two roles that
## the 16-colour rung tells apart are told apart at EVERY rung, including
## monochrome, by weight, underline, reverse and glyph.
## `app/tests/test_degraded_style_tables.nim` asserts that property over the
## whole cross product rather than spot-checking it, and asserts the
## DISTINGUISHABILITY rather than the colours — so re-picking a palette does
## not redden it while a genuine collapse does.
##
## **`degradeRows` is what reaches the screen.** The eighteen view modules under
## `app/views/` paint with 121 `CellStyle` literals of their own, spelled in the
## sixteen ANSI names; rewiring every one of them to a role is the `:theme`
## work CTUI-10 recorded as unbuilt and did not do. So this module meets them
## where they are: `roleFor` is the REVERSE lookup from a painted style to the
## role it means, and `degradeRows` maps every span of an already-composited
## screen through the role table at the resolved tier, then every rune through
## `app/views/borders.asciiFor`. One choke point, no view edited, and the tier
## invariant is a property of the pass rather than of eighteen files agreeing.
##
## ## What the reverse lookup can and cannot do, measured rather than assumed
##
## `roleFor` keys on the 16-colour style ALONE, and two roles in different
## groups may share one. Measured on this tree rather than supposed, by running
## the lookup over every published pane constant:
##
##   | painted style                        | resolves to      |
##   |--------------------------------------|------------------|
##   | `gutter.BreakpointStyle` (red bold)  | `srChromeError`  |
##   | `source_pane.AbsentMarkerStyle` (red bold) | `srChromeError` |
##   | `gutter.BreakpointDisabledStyle` (bright_black) | `srChromeMuted` |
##   | `source_pane.TokenStyles[tcString]` (green) | `srSourceVerified` |
##
## That is not a defect of the lookup, it is a fact about the 16-colour rung —
## a breakpoint dot and a degraded-source banner really are the same `red bold`
## on the screen this front-end paints today, so mapping them to one role
## removes nothing that the tier below could have shown. Two consequences, both
## asserted in `app/tests/test_degraded_style_tables.nim`:
##
##   * the distinguishability property is stated over roles WITH DISTINCT
##     16-COLOUR STYLES, which is exactly the set a lower rung could lose;
##   * what the lookup guarantees is a ROUND TRIP — `ansi16Style(roleFor(s)) ==
##     s` — and not a role NAME, because a name would be an assertion about the
##     enum's declaration order rather than about the product. On a monochrome
##     screen such a pair is told apart by GLYPH (`●` against a banner's text),
##     which is what CTUI-11's contract says degradation may fall back on.
##
## The one merge that is not forced by the palette is recorded in
## `PermittedMerges` with its justification, and its COUNT is asserted, so a
## second one cannot be added without the number moving in a diff a reviewer
## reads. That is the shape `testing/dual_snap.CrossTierExclusions` already uses
## in this tree.
##
## ## Why `#RRGGBB` and `indexed:N` are the top two rungs
##
## `isonim_tui`'s compositor accepts `default`, the sixteen ANSI names and
## `#RRGGBB`; `ckIndexed` was encodable (`ansi.fgParams` emits `38;5;N`) and had
## no spelling in an inline style, so the 256-colour rung of this ladder could
## not have differed from the 16-colour one. CTUI-11 added `indexed:N` to
## `compositor.parseColorOrDefault` — additive, since every string that reached
## that point previously fell through to `namedColor`, which answers the
## terminal default for anything it does not recognise. Without it a
## four-tier ladder would have had three distinct rungs and a comment claiming
## four.

import std/[strutils, tables, unicode]

import ../views/borders
import ../views/diff_highlighter
import ../views/source_pane
import ../views/timeline_bar
import ./capabilities

export capabilities, borders

type
  DistinctionGroup* = enum
    ## A set of roles that are STATES OF ONE THING. The distinguishability
    ## contract is stated per group, and that is what makes it meaningful: a
    ## pane title and a string literal never need to be told apart — they are
    ## never in the same place — while a verified breakpoint and a disabled one
    ## always do.
    dgChrome = "chrome"
    dgGutter = "gutter"
    dgProvenance = "provenance"
    dgLine = "line"
    dgValue = "value"
    dgSyntax = "syntax"
    dgTimeline = "timeline"

  SemanticRole* = enum
    ## Every distinction this front-end's screen carries. Ordered by group, and
    ## the order is load-bearing in one place: `roleFor` resolves a shared
    ## 16-colour style to the FIRST role that claims it, so the enum order is
    ## the tie-break and is therefore stable rather than incidental.

    # ---- dgChrome: the shell's own furniture ------------------------------
    srChromeText = "chrome-text"
    srChromeMuted = "chrome-muted"
    srChromeTitle = "chrome-title"
    srChromeTitleFocused = "chrome-title-focused"
    srChromeNotification = "chrome-notification"
    srChromeError = "chrome-error"

    # ---- dgGutter: §3.3.2's marks -----------------------------------------
    srGutterNoMark = "gutter-no-mark"
    srGutterBreakpoint = "gutter-breakpoint"
    srGutterBreakpointDisabled = "gutter-breakpoint-disabled"
    srGutterTracepoint = "gutter-tracepoint"
    srGutterExecutionPointer = "gutter-execution-pointer"
    srGutterInspectionPointer = "gutter-inspection-pointer"

    # ---- dgProvenance: CTUI-4's source verdict ----------------------------
    srSourceVerified = "source-verified"
    srSourceUnverified = "source-unverified"
    srSourceAbsent = "source-absent"

    # ---- dgLine: what a whole source row can be ---------------------------
    srLineOrdinary = "line-ordinary"
    srLineExecution = "line-execution"
    srLineSearchMatch = "line-search-match"

    # ---- dgValue: CTUI-7's step-to-step diff ------------------------------
    srValueUnchanged = "value-unchanged"
    srValueModified = "value-modified"
    srValueModifiedTag = "value-modified-tag"

    # ---- dgSyntax: CTUI-5's nine token classes ----------------------------
    srSyntaxPlain = "syntax-plain"
    srSyntaxIdentifier = "syntax-identifier"
    srSyntaxKeyword = "syntax-keyword"
    srSyntaxType = "syntax-type"
    srSyntaxString = "syntax-string"
    srSyntaxNumber = "syntax-number"
    srSyntaxComment = "syntax-comment"
    srSyntaxOperator = "syntax-operator"
    srSyntaxPunctuation = "syntax-punctuation"

    # ---- dgTimeline: §3.3.5's scrubber ------------------------------------
    srTimelineTrack = "timeline-track"
    srTimelineSpan = "timeline-span"
    srTimelineMark = "timeline-mark"
    srTimelineNeedle = "timeline-needle"
    srTimelineBounds = "timeline-bounds"

  RoleAppearance* = object
    ## What one role looks like at one tier: the cell style AND the glyph it
    ## paints where it has one.
    ##
    ## THE GLYPH IS PART OF THE APPEARANCE, and that is the whole reason a
    ## monochrome screen can still tell a verified breakpoint from a disabled
    ## one. A comparison over `CellStyle` alone would report those two as
    ## identical at the bottom rung and would be right about the styles and
    ## wrong about the screen.
    style*: CellStyle
    glyph*: string
      ## "" for a role that tints text rather than painting a mark.

const
  PermittedMerges*: array[1, (SemanticRole, SemanticRole, string)] = [
    (srSyntaxPlain, srSyntaxIdentifier,
     "An identifier IS plain text. The 16-colour rung tints it `white` to lift" &
     " it off `blue` punctuation and `bright_blue` operators; monochrome has" &
     " neither, so the tint has nothing to distinguish it FROM. Merging them" &
     " is what leaves the remaining eight token classes one three-bit" &
     " attribute combination each (bold, italic, underline) instead of" &
     " spending `reverse` — which dgLine reserves, so that an execution line" &
     " over a keyword still reads as an execution line.")]
    ## Pairs of roles in one group that share an appearance at some tier ON
    ## PURPOSE, each with the argument for it.
    ##
    ## The COUNT is asserted by `app/tests/test_degraded_style_tables.nim`, for
    ## the reason `dual_snap.CrossTierExclusionCount` is: an unexplained merge
    ## is a collapse, and a list nobody counts grows one entry at a time.

  MonochromeSyntaxNote* =
    "monochrome maps the nine token classes onto eight attribute combinations"
    ## Quoted by the test that asserts the merge, so the log of a green run
    ## says what the bottom rung does rather than only that it passed.

proc groupOf*(role: SemanticRole): DistinctionGroup =
  ## Which set of states this role belongs to.
  case role
  of srChromeText .. srChromeError: dgChrome
  of srGutterNoMark .. srGutterInspectionPointer: dgGutter
  of srSourceVerified .. srSourceAbsent: dgProvenance
  of srLineOrdinary .. srLineSearchMatch: dgLine
  of srValueUnchanged .. srValueModifiedTag: dgValue
  of srSyntaxPlain .. srSyntaxPunctuation: dgSyntax
  of srTimelineTrack .. srTimelineBounds: dgTimeline

# ---------------------------------------------------------------------------
# The four rungs
# ---------------------------------------------------------------------------

proc ansi16Style*(role: SemanticRole): CellStyle =
  ## THE 16-COLOUR RUNG, AND IT IS NOT A COPY. Every entry that a pane already
  ## paints is the pane's own published constant, read from the module that
  ## owns it — `gutter.BreakpointStyle`, `source_pane.TokenStyles`,
  ## `timeline_bar.NeedleStyle`, `diff_highlighter.ModifiedNameStyle`. There is
  ## therefore exactly ONE 16-colour palette in this tree, and `roleFor` below
  ## can be a reverse lookup rather than a guess.
  ##
  ## Three entries have no published constant because nothing paints them yet:
  ## `srChromeTitleFocused` (CTUI-9 tracks pane focus but no view styles it),
  ## `srChromeNotification` and `srLineSearchMatch`. They are named here rather
  ## than omitted, because the tier ladder is what a future view will ask, and
  ## a role added later would arrive with no lower rungs at all.
  case role
  of srChromeText: DefaultCellStyle
  of srChromeMuted: source_pane.RuleStyle
  of srChromeTitle: source_pane.TitleStyle
  of srChromeTitleFocused: CellStyle(fg: "white", bold: true, reverse: true)
  of srChromeNotification: CellStyle(fg: "yellow")
  of srChromeError: source_pane.DegradedStyle

  of srGutterNoMark: DefaultCellStyle
  of srGutterBreakpoint: BreakpointStyle
  of srGutterBreakpointDisabled: BreakpointDisabledStyle
  of srGutterTracepoint: TracepointStyle
  of srGutterExecutionPointer: ExecutionPointerStyle
  of srGutterInspectionPointer: InspectionPointerStyle

  of srSourceVerified: VerifiedMarkerStyle
  of srSourceUnverified: UnverifiedMarkerStyle
  of srSourceAbsent: AbsentMarkerStyle

  of srLineOrdinary: DefaultCellStyle
  of srLineExecution: CellStyle(bg: ExecutionLineBackground)
  of srLineSearchMatch: CellStyle(bg: "yellow", fg: "black")

  of srValueUnchanged: DefaultCellStyle
  of srValueModified: ModifiedNameStyle
  of srValueModifiedTag: ModifiedTagStyle

  of srSyntaxPlain: TokenStyles[tcPlain]
  of srSyntaxIdentifier: TokenStyles[tcIdentifier]
  of srSyntaxKeyword: TokenStyles[tcKeyword]
  of srSyntaxType: TokenStyles[tcType]
  of srSyntaxString: TokenStyles[tcString]
  of srSyntaxNumber: TokenStyles[tcNumber]
  of srSyntaxComment: TokenStyles[tcComment]
  of srSyntaxOperator: TokenStyles[tcOperator]
  of srSyntaxPunctuation: TokenStyles[tcPunctuation]

  of srTimelineTrack: TrackStyle
  of srTimelineSpan: SpanStyle
  of srTimelineMark: timeline_bar.MarkStyle
  of srTimelineNeedle: NeedleStyle
  of srTimelineBounds: BoundsStyle

type
  ThemeTint* = object
    ## What ONE theme repaints ONE role with, at the two rungs that have a
    ## palette wide enough to differ.
    ##
    ## `""` MEANS "DO NOT TOUCH IT", which is what makes a theme a diff against
    ## the 16-colour rung rather than a fourth copy of the whole table. The
    ## 16-colour rung is deliberately NOT themed: it has sixteen names, every
    ## one of which a terminal renders in the user's own configured palette, so
    ## a "light theme" there would be this program overriding the choice the
    ## user already made in their terminal. Monochrome is not themed for the
    ## stronger reason that it has no colour to theme.
    fg256*, bg256*, fgRgb*, bgRgb*: string

  ThemeTints* = array[SemanticRole, ThemeTint]

proc tint(fg256 = ""; bg256 = ""; fgRgb = ""; bgRgb = ""): ThemeTint =
  ThemeTint(fg256: fg256, bg256: bg256, fgRgb: fgRgb, bgRgb: bgRgb)

const
  DarkTints*: ThemeTints = [
    ## CTUI-11's OWN NUMBERS, moved into a table and not re-picked. Every value
    ## here is the one `ansi256Style` and `trueColorStyle` carried before
    ## CTUI-14 gave them a theme axis, which is what makes `utDark` — the
    ## published default and the zero value — byte-for-byte the screen that
    ## shipped. `test_real_capability_negotiation.nim` asserting `indexed:244`
    ## on a default run is the check that keeps that true.
    srChromeText: tint(),
    srChromeMuted: tint(fg256 = "indexed:244", fgRgb = "#8a8f98"),
    srChromeTitle: tint(fg256 = "indexed:255", fgRgb = "#eceff4"),
    srChromeTitleFocused: tint(fg256 = "indexed:255", fgRgb = "#eceff4"),
    srChromeNotification: tint(fg256 = "indexed:214", fgRgb = "#f0a020"),
    srChromeError: tint(fg256 = "indexed:203", fgRgb = "#ff5f56"),

    srGutterNoMark: tint(),
    srGutterBreakpoint: tint(fg256 = "indexed:196", fgRgb = "#e0483d"),
    srGutterBreakpointDisabled: tint(fg256 = "indexed:244", fgRgb = "#8a8f98"),
    srGutterTracepoint: tint(fg256 = "indexed:44", fgRgb = "#22b8cf"),
    srGutterExecutionPointer: tint(fg256 = "indexed:220", fgRgb = "#ffd43b"),
    srGutterInspectionPointer: tint(fg256 = "indexed:80", fgRgb = "#5bc0de"),

    srSourceVerified: tint(fg256 = "indexed:41", fgRgb = "#2fb344"),
    srSourceUnverified: tint(fg256 = "indexed:214", fgRgb = "#f0a020"),
    srSourceAbsent: tint(fg256 = "indexed:203", fgRgb = "#ff5f56"),

    srLineOrdinary: tint(),
    srLineExecution: tint(bg256 = "indexed:24", bgRgb = "#1d3557"),
    srLineSearchMatch: tint(fg256 = "indexed:16", bg256 = "indexed:220",
                            fgRgb = "#101010", bgRgb = "#ffd43b"),

    srValueUnchanged: tint(),
    srValueModified: tint(fg256 = "indexed:41", fgRgb = "#2fb344"),
    srValueModifiedTag: tint(fg256 = "indexed:16", bg256 = "indexed:41",
                             fgRgb = "#101010", bgRgb = "#2fb344"),

    srSyntaxPlain: tint(),
    srSyntaxIdentifier: tint(fg256 = "indexed:252", fgRgb = "#d8dee9"),
    srSyntaxKeyword: tint(fg256 = "indexed:170", fgRgb = "#c678dd"),
    srSyntaxType: tint(fg256 = "indexed:80", fgRgb = "#56b6c2"),
    srSyntaxString: tint(fg256 = "indexed:114", fgRgb = "#98c379"),
    srSyntaxNumber: tint(fg256 = "indexed:215", fgRgb = "#d19a66"),
    srSyntaxComment: tint(fg256 = "indexed:243", fgRgb = "#7f848e"),
    srSyntaxOperator: tint(fg256 = "indexed:75", fgRgb = "#61afef"),
    srSyntaxPunctuation: tint(fg256 = "indexed:68", fgRgb = "#4b7bec"),

    srTimelineTrack: tint(fg256 = "indexed:240", fgRgb = "#5c6370"),
    srTimelineSpan: tint(fg256 = "indexed:62", fgRgb = "#7c7aed"),
    srTimelineMark: tint(fg256 = "indexed:214", fgRgb = "#f0a020"),
    srTimelineNeedle: tint(fg256 = "indexed:87", fgRgb = "#56d4ff"),
    srTimelineBounds: tint(fg256 = "indexed:255", fgRgb = "#eceff4")]

  LightTints*: ThemeTints = [
    ## FOR A LIGHT TERMINAL BACKGROUND. Every hue is darkened rather than
    ## re-hued: a light theme that changed which colour a keyword is would be a
    ## second product decision hiding inside a background change, and a user who
    ## knows `#c678dd` means "keyword" on the dark screen should not have to
    ## learn a second mapping to read the light one.
    ##
    ## The two roles with a BACKGROUND are the ones that had to be re-picked
    ## rather than darkened: `srLineExecution` and `srLineSearchMatch` paint a
    ## whole row, and a dark row on a light screen is a hole in it.
    srChromeText: tint(),
    srChromeMuted: tint(fg256 = "indexed:243", fgRgb = "#6b7280"),
    srChromeTitle: tint(fg256 = "indexed:232", fgRgb = "#1b1f24"),
    srChromeTitleFocused: tint(fg256 = "indexed:232", fgRgb = "#1b1f24"),
    srChromeNotification: tint(fg256 = "indexed:130", fgRgb = "#a35c00"),
    srChromeError: tint(fg256 = "indexed:160", fgRgb = "#c01c28"),

    srGutterNoMark: tint(),
    srGutterBreakpoint: tint(fg256 = "indexed:160", fgRgb = "#c01c28"),
    srGutterBreakpointDisabled: tint(fg256 = "indexed:243", fgRgb = "#6b7280"),
    srGutterTracepoint: tint(fg256 = "indexed:30", fgRgb = "#0f7285"),
    srGutterExecutionPointer: tint(fg256 = "indexed:136", fgRgb = "#b07d00"),
    srGutterInspectionPointer: tint(fg256 = "indexed:31", fgRgb = "#1d6fa5"),

    srSourceVerified: tint(fg256 = "indexed:28", fgRgb = "#1a7f37"),
    srSourceUnverified: tint(fg256 = "indexed:130", fgRgb = "#a35c00"),
    srSourceAbsent: tint(fg256 = "indexed:160", fgRgb = "#c01c28"),

    srLineOrdinary: tint(),
    srLineExecution: tint(bg256 = "indexed:153", bgRgb = "#cfe3ff"),
    srLineSearchMatch: tint(fg256 = "indexed:232", bg256 = "indexed:222",
                            fgRgb = "#1b1f24", bgRgb = "#ffe08a"),

    srValueUnchanged: tint(),
    srValueModified: tint(fg256 = "indexed:28", fgRgb = "#1a7f37"),
    srValueModifiedTag: tint(fg256 = "indexed:255", bg256 = "indexed:28",
                             fgRgb = "#ffffff", bgRgb = "#1a7f37"),

    srSyntaxPlain: tint(),
    srSyntaxIdentifier: tint(fg256 = "indexed:236", fgRgb = "#30363d"),
    srSyntaxKeyword: tint(fg256 = "indexed:90", fgRgb = "#8250df"),
    srSyntaxType: tint(fg256 = "indexed:30", fgRgb = "#0f7285"),
    srSyntaxString: tint(fg256 = "indexed:22", fgRgb = "#0a6640"),
    srSyntaxNumber: tint(fg256 = "indexed:130", fgRgb = "#a35c00"),
    srSyntaxComment: tint(fg256 = "indexed:245", fgRgb = "#8a9199"),
    srSyntaxOperator: tint(fg256 = "indexed:26", fgRgb = "#0a58ca"),
    srSyntaxPunctuation: tint(fg256 = "indexed:60", fgRgb = "#3d4f8a"),

    srTimelineTrack: tint(fg256 = "indexed:249", fgRgb = "#b1b7bd"),
    srTimelineSpan: tint(fg256 = "indexed:61", fgRgb = "#5850c4"),
    srTimelineMark: tint(fg256 = "indexed:130", fgRgb = "#a35c00"),
    srTimelineNeedle: tint(fg256 = "indexed:31", fgRgb = "#1d6fa5"),
    srTimelineBounds: tint(fg256 = "indexed:232", fgRgb = "#1b1f24")]

  MonokaiTints*: ThemeTints = [
    ## Monokai's published hues, the ones the scheme is recognised BY: pink
    ## `#f92672` for keywords, green `#a6e22e` for types, yellow `#e6db74` for
    ## strings, purple `#ae81ff` for numbers, grey `#75715e` for comments, blue
    ## `#66d9ef` for operators. The chrome roles are given the scheme's own
    ## greys rather than left on the dark theme's, so the whole screen reads as
    ## one palette.
    srChromeText: tint(),
    srChromeMuted: tint(fg256 = "indexed:242", fgRgb = "#75715e"),
    srChromeTitle: tint(fg256 = "indexed:231", fgRgb = "#f8f8f2"),
    srChromeTitleFocused: tint(fg256 = "indexed:231", fgRgb = "#f8f8f2"),
    srChromeNotification: tint(fg256 = "indexed:186", fgRgb = "#e6db74"),
    srChromeError: tint(fg256 = "indexed:197", fgRgb = "#f92672"),

    srGutterNoMark: tint(),
    srGutterBreakpoint: tint(fg256 = "indexed:197", fgRgb = "#f92672"),
    srGutterBreakpointDisabled: tint(fg256 = "indexed:242", fgRgb = "#75715e"),
    srGutterTracepoint: tint(fg256 = "indexed:81", fgRgb = "#66d9ef"),
    srGutterExecutionPointer: tint(fg256 = "indexed:208", fgRgb = "#fd971f"),
    srGutterInspectionPointer: tint(fg256 = "indexed:141", fgRgb = "#ae81ff"),

    srSourceVerified: tint(fg256 = "indexed:148", fgRgb = "#a6e22e"),
    srSourceUnverified: tint(fg256 = "indexed:208", fgRgb = "#fd971f"),
    srSourceAbsent: tint(fg256 = "indexed:197", fgRgb = "#f92672"),

    srLineOrdinary: tint(),
    srLineExecution: tint(bg256 = "indexed:237", bgRgb = "#3e3d32"),
    srLineSearchMatch: tint(fg256 = "indexed:235", bg256 = "indexed:186",
                            fgRgb = "#272822", bgRgb = "#e6db74"),

    srValueUnchanged: tint(),
    srValueModified: tint(fg256 = "indexed:148", fgRgb = "#a6e22e"),
    srValueModifiedTag: tint(fg256 = "indexed:235", bg256 = "indexed:148",
                             fgRgb = "#272822", bgRgb = "#a6e22e"),

    srSyntaxPlain: tint(),
    srSyntaxIdentifier: tint(fg256 = "indexed:231", fgRgb = "#f8f8f2"),
    srSyntaxKeyword: tint(fg256 = "indexed:197", fgRgb = "#f92672"),
    srSyntaxType: tint(fg256 = "indexed:148", fgRgb = "#a6e22e"),
    srSyntaxString: tint(fg256 = "indexed:186", fgRgb = "#e6db74"),
    srSyntaxNumber: tint(fg256 = "indexed:141", fgRgb = "#ae81ff"),
    srSyntaxComment: tint(fg256 = "indexed:242", fgRgb = "#75715e"),
    srSyntaxOperator: tint(fg256 = "indexed:81", fgRgb = "#66d9ef"),
    srSyntaxPunctuation: tint(fg256 = "indexed:245", fgRgb = "#8f908a"),

    srTimelineTrack: tint(fg256 = "indexed:239", fgRgb = "#49483e"),
    srTimelineSpan: tint(fg256 = "indexed:141", fgRgb = "#ae81ff"),
    srTimelineMark: tint(fg256 = "indexed:208", fgRgb = "#fd971f"),
    srTimelineNeedle: tint(fg256 = "indexed:81", fgRgb = "#66d9ef"),
    srTimelineBounds: tint(fg256 = "indexed:231", fgRgb = "#f8f8f2")]

proc tintsFor*(theme: UiTheme): ThemeTints =
  ## The palette one theme paints in.
  ##
  ## `utPlain` answers `DarkTints` and that is not a fallback: `plain` resolves
  ## the colour LADDER to `cdMonochrome` (see
  ## `app/theme/capabilities.resolveColorDepth`), so no rung that reads a tint
  ## is ever reached under it. Answering with a table nothing consults is the
  ## honest shape; inventing a fourth palette for it would be a table that could
  ## never be wrong because it could never be seen.
  case theme
  of utDark, utPlain: DarkTints
  of utLight: LightTints
  of utMonokai: MonokaiTints

proc ansi256Style*(role: SemanticRole; theme: UiTheme = utDark): CellStyle =
  ## THE 256-COLOUR RUNG. `indexed:N` names a cell of xterm's 256-colour cube,
  ## which `compositor.parseColorOrDefault` now understands and `ansi.fgParams`
  ## emits as `38;5;N`.
  ##
  ## Every attribute is carried over from the 16-colour rung unchanged, so this
  ## is a widening of the palette and never a change of weight: a role that is
  ## bold at 16 colours is bold at 256, and the distinguishability property
  ## therefore cannot be *lost* on the way up. THAT IS ALSO WHY A THEME CANNOT
  ## COLLAPSE TWO STATES BY ACCIDENT — it moves hues and leaves every attribute
  ## where it was — but it is asserted rather than assumed, over all four
  ## themes, in `app/tests/test_degraded_style_tables.nim`.
  result = ansi16Style(role)
  let t = tintsFor(theme)[role]
  if t.fg256.len > 0: result.fg = t.fg256
  if t.bg256.len > 0: result.bg = t.bg256

proc trueColorStyle*(role: SemanticRole; theme: UiTheme = utDark): CellStyle =
  ## THE 24-BIT RUNG. Same rule as the one above: hues widen, weights do not
  ## move.
  result = ansi16Style(role)
  let t = tintsFor(theme)[role]
  if t.fgRgb.len > 0: result.fg = t.fgRgb
  if t.bgRgb.len > 0: result.bg = t.bgRgb

proc monochromeStyle*(role: SemanticRole): CellStyle =
  ## THE BOTTOM RUNG: weight, underline, reverse. No `fg`, no `bg`, ever —
  ## which is exactly what CTUI-11's Tier-2 gate reads back off a real
  ## terminal's cells.
  ##
  ## `reverse` is spent on `dgLine` and on `srChromeTitleFocused` and nowhere
  ## else, deliberately: it is the only attribute that repaints a whole row, and
  ## the execution line is the one thing that must stay legible when it lands on
  ## top of any of the other thirty-three roles.
  ##
  ## `dim` is absent for the reason `app/views/styled_row.nim`'s header gives:
  ## libvterm's cell model has no dim bit, so a "muted" expressed as `dim` would
  ## be a distinction no Tier-2 assertion could ever read.
  case role
  of srChromeText: DefaultCellStyle
  of srChromeMuted: CellStyle(italic: true)
  of srChromeTitle: CellStyle(bold: true)
  of srChromeTitleFocused: CellStyle(bold: true, reverse: true)
  of srChromeNotification: CellStyle(underline: true)
  of srChromeError: CellStyle(bold: true, underline: true)

  of srGutterNoMark: DefaultCellStyle
  of srGutterBreakpoint: CellStyle(bold: true)
  of srGutterBreakpointDisabled: CellStyle(italic: true)
  of srGutterTracepoint: CellStyle(bold: true)
  of srGutterExecutionPointer: CellStyle(bold: true, underline: true)
  of srGutterInspectionPointer: CellStyle(italic: true, underline: true)

  of srSourceVerified: DefaultCellStyle
  of srSourceUnverified: CellStyle(bold: true, italic: true)
  of srSourceAbsent: CellStyle(bold: true, underline: true)

  of srLineOrdinary: DefaultCellStyle
  of srLineExecution: CellStyle(reverse: true)
  of srLineSearchMatch: CellStyle(reverse: true, underline: true)

  of srValueUnchanged: DefaultCellStyle
  of srValueModified: CellStyle(bold: true, underline: true)
  of srValueModifiedTag: CellStyle(bold: true, reverse: true)

  # The nine token classes across eight combinations; see `PermittedMerges`.
  of srSyntaxPlain, srSyntaxIdentifier: DefaultCellStyle
  of srSyntaxKeyword: CellStyle(bold: true)
  of srSyntaxType: CellStyle(bold: true, italic: true)
  of srSyntaxString: CellStyle(italic: true)
  of srSyntaxNumber: CellStyle(underline: true)
  of srSyntaxComment: CellStyle(italic: true, underline: true)
  of srSyntaxOperator: CellStyle(bold: true, underline: true)
  of srSyntaxPunctuation: CellStyle(bold: true, italic: true, underline: true)

  of srTimelineTrack: CellStyle(italic: true)
  of srTimelineSpan: DefaultCellStyle
  of srTimelineMark: CellStyle(bold: true)
  of srTimelineNeedle: CellStyle(bold: true, underline: true)
  of srTimelineBounds: CellStyle(bold: true, italic: true)

proc roleStyle*(role: SemanticRole; depth: ColorDepth;
                theme: UiTheme = utDark): CellStyle =
  ## The one entry point into the four tables above.
  ##
  ## The theme reaches only the two rungs that have a palette wide enough to
  ## carry one — see `ThemeTint`. `theme` defaults to the published default so
  ## every existing call site reads unchanged and means what it always meant.
  case depth
  of cdMonochrome: monochromeStyle(role)
  of cdAnsi16: ansi16Style(role)
  of cdAnsi256: ansi256Style(role, theme)
  of cdTrueColor: trueColorStyle(role, theme)

proc roleGlyph*(role: SemanticRole; mode: BorderMode): string =
  ## The mark this role paints, in the border set the terminal can show.
  ##
  ## Read out of `app/views/borders.nim`'s two sets rather than spelled here,
  ## so the ASCII fallback of a mark and the ASCII fallback of the same rune
  ## arriving through `degradeRows` cannot disagree.
  let bs = borderSet(mode)
  case role
  of srGutterBreakpoint: bs.breakpoint
  of srGutterBreakpointDisabled: bs.breakpointDisabled
  of srGutterTracepoint: bs.tracepoint
  of srGutterExecutionPointer: ExecutionPointerGlyph
  of srGutterInspectionPointer: InspectionPointerGlyph
  of srGutterNoMark: NoPointerGlyph
  of srTimelineTrack: bs.horizontal
  of srTimelineSpan: bs.span
  of srTimelineMark: bs.tracepoint
  of srTimelineNeedle: bs.needle
  of srTimelineBounds: BoundsOpenGlyph
  else: ""

proc appearance*(role: SemanticRole;
                 caps: TerminalCapabilities): RoleAppearance =
  ## What this role looks like on THIS terminal, in the theme it was asked for.
  RoleAppearance(style: roleStyle(role, caps.colors, caps.theme),
                 glyph: roleGlyph(role, caps.borders))

proc distinctionKey*(a: RoleAppearance): string =
  ## The observable identity of an appearance: everything a terminal shows and
  ## nothing else.
  ##
  ## THIS IS WHAT THE DISTINGUISHABILITY PROPERTY IS STATED OVER, and it is
  ## deliberately not "the colours are different". A palette change moves every
  ## key and reddens nothing; a collapse — two states arriving at one key —
  ## reddens exactly one pair and names it.
  describe(a.style) & " glyph=" & (if a.glyph.len > 0: a.glyph else: "-")

proc distinctionKey*(role: SemanticRole; caps: TerminalCapabilities): string =
  distinctionKey(appearance(role, caps))

# ---------------------------------------------------------------------------
# The reverse lookup: a painted style -> the role it means
# ---------------------------------------------------------------------------

proc styleKey(s: CellStyle): string =
  ## A canonical string for a `CellStyle`, so the reverse map can be a hash.
  ## `describe` already produces one and is the string every failure message
  ## in this tree quotes, so there is one spelling rather than two.
  describe(s)

let RoleByAnsi16Style: Table[string, SemanticRole] = block:
  ## Every distinct 16-colour style, mapped to the FIRST role that claims it.
  ##
  ## `let` rather than `const`: `describe` walks a `seq` and Nim's VM will not
  ## fold it here. The table is built once at module initialisation, which is
  ## before the first paint by construction.
  var t = initTable[string, SemanticRole]()
  for role in SemanticRole:
    let key = styleKey(ansi16Style(role))
    if key notin t:
      t[key] = role
  t

proc roleFor*(style: CellStyle): (bool, SemanticRole) =
  ## The role a painted style means, or `(false, …)` when no role claims it.
  ##
  ## A `false` here is not a failure: `degradeRows` falls back to the
  ## mechanical projection below, which is what keeps the tier invariant true
  ## for a style no role has been written for yet. The BOOLEAN is returned
  ## rather than a sentinel role because "unclaimed" and "chrome text" are two
  ## different answers and `srChromeText` is a real role.
  let key = styleKey(style)
  if key in RoleByAnsi16Style:
    (true, RoleByAnsi16Style[key])
  else:
    (false, srChromeText)

# ---------------------------------------------------------------------------
# The mechanical projection, for styles no role claims
# ---------------------------------------------------------------------------

proc isRgbSpelling(s: string): bool =
  s.len == 7 and s[0] == '#'

proc isIndexedSpelling(s: string): bool =
  s.startsWith("indexed:")

proc nearestAnsiName*(colour: string): string =
  ## The closest of the sixteen ANSI names to an `#RRGGBB` or `indexed:N`
  ## spelling. An ANSI name, "" or anything unrecognised is returned unchanged.
  ##
  ## Nearest by squared distance in RGB, over the xterm palette's own values for
  ## the sixteen — not perceptually ideal, and deliberately simple: this runs
  ## only for a style no role claims, on a terminal that has sixteen colours, and
  ## a better metric would change which of two similar names is picked rather
  ## than whether information survives.
  const AnsiRgb = [
    ("black", 0, 0, 0), ("red", 205, 0, 0), ("green", 0, 205, 0),
    ("yellow", 205, 205, 0), ("blue", 0, 0, 238), ("magenta", 205, 0, 205),
    ("cyan", 0, 205, 205), ("white", 229, 229, 229),
    ("bright_black", 127, 127, 127), ("bright_red", 255, 0, 0),
    ("bright_green", 0, 255, 0), ("bright_yellow", 255, 255, 0),
    ("bright_blue", 92, 92, 255), ("bright_magenta", 255, 0, 255),
    ("bright_cyan", 0, 255, 255), ("bright_white", 255, 255, 255)]
  var r, g, b: int
  if isRgbSpelling(colour):
    try:
      r = parseHexInt(colour[1 .. 2])
      g = parseHexInt(colour[3 .. 4])
      b = parseHexInt(colour[5 .. 6])
    except ValueError:
      return ""
  elif isIndexedSpelling(colour):
    var idx = 0
    try:
      idx = parseInt(colour["indexed:".len .. ^1])
    except ValueError:
      return ""
    if idx < 16:
      return AnsiRgb[idx][0]
    elif idx < 232:
      # xterm's 6x6x6 cube: the level table is 0, 95, 135, 175, 215, 255.
      const Levels = [0, 95, 135, 175, 215, 255]
      let n = idx - 16
      r = Levels[(n div 36) mod 6]
      g = Levels[(n div 6) mod 6]
      b = Levels[n mod 6]
    else:
      let grey = 8 + (idx - 232) * 10
      r = grey
      g = grey
      b = grey
  else:
    return colour
  var best = 0
  var bestDistance = high(int)
  for i, entry in AnsiRgb:
    let dr = r - entry[1]
    let dg = g - entry[2]
    let db = b - entry[3]
    let d = dr * dr + dg * dg + db * db
    if d < bestDistance:
      bestDistance = d
      best = i
  AnsiRgb[best][0]

proc monoEmphasisFor(colour: string): CellStyle =
  ## The attributes a colour's CONTRAST CLASS earns on a monochrome screen.
  ##
  ## Four classes, and this pass preserves exactly those four:
  ## muted, ordinary, emphatic and alerting. It is the FALLBACK — a style that
  ## a role claims never reaches here, and the role table is where full state
  ## distinguishability lives. Stating the narrower contract is the point: a
  ## hue-agnostic pass over nine token classes cannot keep nine of them apart,
  ## and pretending otherwise is how a table stops meaning anything.
  let name = nearestAnsiName(colour)
  case name
  of "": DefaultCellStyle
  of "bright_black", "black": CellStyle(italic: true)
  of "red", "bright_red": CellStyle(bold: true, underline: true)
  of "yellow", "bright_yellow": CellStyle(underline: true)
  of "white", "bright_white": CellStyle(bold: true)
  of "magenta", "bright_magenta", "cyan", "bright_cyan": CellStyle(bold: true)
  else: DefaultCellStyle

proc mergeAttrs(base: CellStyle; extra: CellStyle): CellStyle =
  result = base
  result.bold = base.bold or extra.bold
  result.italic = base.italic or extra.italic
  result.underline = base.underline or extra.underline
  result.reverse = base.reverse or extra.reverse

proc projectStyle*(style: CellStyle; depth: ColorDepth): CellStyle =
  ## Put a style onto `depth` MECHANICALLY, without consulting the role table.
  ##
  ## The tier invariant is this function's contract and it is total:
  ##
  ##   * `cdMonochrome` — no `fg` and no `bg` come out, ever. A background
  ##     becomes `reverse`, because a background IS a highlight and `reverse` is
  ##     the monochrome spelling of one.
  ##   * `cdAnsi16` — only the sixteen names come out; `#RRGGBB` and
  ##     `indexed:N` are quantised.
  ##   * `cdAnsi256` — no `#RRGGBB` comes out; names and indices pass.
  ##   * `cdTrueColor` — everything passes.
  case depth
  of cdTrueColor:
    result = style
  of cdAnsi256:
    result = style
    if isRgbSpelling(result.fg):
      result.fg = nearestAnsiName(result.fg)
    if isRgbSpelling(result.bg):
      result.bg = nearestAnsiName(result.bg)
  of cdAnsi16:
    result = style
    result.fg = nearestAnsiName(result.fg)
    result.bg = nearestAnsiName(result.bg)
  of cdMonochrome:
    result = mergeAttrs(style, monoEmphasisFor(style.fg))
    if style.bg.len > 0:
      result.reverse = true
    result.fg = ""
    result.bg = ""

proc degradeStyle*(style: CellStyle; caps: TerminalCapabilities): CellStyle =
  ## One painted style at the resolved tier. THE ROLE TABLE FIRST — that is
  ## what makes the ladder a theme rather than a filter — and the mechanical
  ## projection for anything no role claims.
  ##
  ## The role arm is still projected afterwards, and that is not redundant: it
  ## is what makes the tier invariant a property of THIS function rather than
  ## of thirty-four hand-written table entries all being right. A role entry
  ## that mistakenly carried a colour at `cdMonochrome` would be stripped here
  ## and reported by `app/tests/test_degraded_style_tables.nim`, rather than
  ## reaching a terminal.
  let (claimed, role) = roleFor(style)
  let widened =
    if claimed: roleStyle(role, caps.colors, caps.theme) else: style
  projectStyle(widened, caps.colors)

proc degradeText*(text: string; caps: TerminalCapabilities): string =
  ## One span's text with its chrome glyphs put onto the border set.
  ##
  ## Walks by RUNE rather than by byte, because the substitution table is keyed
  ## by rune and a byte walk would never match a three-byte `─`.
  if caps.borders == bmUnicode:
    return text
  result = newStringOfCap(text.len)
  for r in text.utf8:
    result.add asciiFor(r)

proc degradeRow*(row: StyledRow; caps: TerminalCapabilities): StyledRow =
  ## One composited screen row at the resolved tier.
  ##
  ## Spans are NOT re-fused afterwards, and that is deliberate: two adjacent
  ## spans that degrade to one style stay two spans, which costs one extra
  ## `LayoutEntry` and keeps this function a map rather than a re-encode. The
  ## compositor's `allText` branch emits them at adjacent columns either way, so
  ## the screen is identical; only the entry count differs.
  result = @[]
  for span in row:
    result.add StyledSpan(text: degradeText(span.text, caps),
                          style: degradeStyle(span.style, caps))

proc degradeRows*(rows: seq[StyledRow];
                  caps: TerminalCapabilities): seq[StyledRow] =
  ## A whole frame at the resolved tier. THE ONE CHOKE POINT the driver calls,
  ## and the reason CTUI-11's Tier-2 gate ("the ASCII/monochrome screen carries
  ## no colour attributes") is a property of one function instead of a claim
  ## about eighteen view modules.
  result = @[]
  for row in rows:
    result.add degradeRow(row, caps)
