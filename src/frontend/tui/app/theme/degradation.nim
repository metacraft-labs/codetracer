## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/degradation.nim — CTUI-11, rebuilt on the design system by
## PLAT-46. The pass that puts a composited screen onto the tier the terminal
## actually has.
##
## ## The contract, restated exactly
##
## CTUI-11: *"Degradation never removes information: a monochrome screen
## distinguishes the same states by weight, underline and glyph."* PLAT-46 keeps
## that contract and changes where the colours come from:
##
##   * **Roles, not ANSI names.** Every view paints `SemanticRole`s
##     (`app/theme/roles.nim`) into `CellStyle.role` / `CellStyle.surface`. The
##     reverse lookup this module used to carry (`roleFor`, from a painted
##     16-colour style back to the role it meant) is GONE, and with it its
##     measured collisions — a breakpoint dot and a degraded-source banner were
##     one `red bold` and so could not be given different true colours. A view
##     now says which it means.
##   * **One table of colours, generated.** Each role names a
##     `codetracer-design-system` token; `app/theme/palette.nim` DERIVES the
##     256- and 16-colour rungs and the terminal palette from the token's hex.
##     There is no hand-picked palette anywhere in this front-end (the
##     `ci/test/tui-design-tokens-boundary.sh` gate (run by `ci/lint/nim.sh`)
##     forbids a `#rrggbb` literal under
##     `tui/app/`).
##   * **The distinguishability property** is asserted over the whole cross
##     product of roles, tiers, modes and palettes by
##     `app/tests/test_degraded_style_tables.nim`: within a group, any two roles
##     a colour rung tells apart are told apart in monochrome, by weight,
##     underline, reverse or glyph.
##
## **`degradeRows` is still the one choke point** the driver calls: every span
## of a composited frame goes through `degradeStyle`, so "the monochrome screen
## carries no colour attributes" and "the terminal palette emits only indices
## 0-15 and 39/49" are properties of one function rather than claims about
## eighteen view modules.

import std/[strutils, unicode]

import ../views/borders
import ../views/gutter
import ../views/styled_row
import ./capabilities
import ./colour_math
import ./palette

export capabilities, borders, palette

type
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
  PermittedMerges*: array[22, (SemanticRole, SemanticRole, string)] = [
    (srChromeText, srEditorText,
     "PLAT-51: the omnibox's text is the EDITOR's foreground" &
     " (`editor/theme/rule/default`, Commands-And-Omnibox.md 'Omnibox colours" &
     " on every front-end'), which the design system makes the same colour" &
     " as the chrome's body text. Two roles because they bind two tokens" &
     " that could part; where they do not, they are one text colour."),
    (srSyntaxPlain, srSyntaxIdentifier,
     "An identifier IS plain text. The design system paints both with" &
     " `colors/editor/syntax/primary` (`plain` is an alias of it), and" &
     " monochrome has no tint to distinguish them FROM. Merging them is what" &
     " leaves the remaining token classes one attribute combination each" &
     " instead of spending `reverse` — which dgLine reserves, so that an" &
     " execution line over a keyword still reads as an execution line."),
    (srSyntaxString, srSyntaxStringEscape,
     "A string's quote is part of the string. The desktop's Monaco theme" &
     " tints the quote (`string.escape`) a shade off the body, and the" &
     " colour rungs keep that shade; where no tint is left the two are one" &
     " string, which is what the reader needs to see."),
    (srSyntaxPunctuation, srSyntaxBracket,
     "A square bracket is punctuation. The desktop's dark theme gives" &
     " `delimiter.bracket` a lighter grey than the other delimiters; below" &
     " the rungs that can show a grey step the two are one delimiter class."),
    (srSyntaxKeyword, srSyntaxTag,
     "A decorator (`@name`, Monaco's `tag`) is drawn in a blue next to the" &
     " keyword blue; where the terminal cannot show the step between two" &
     " blues it reads as the keyword-like marker it is, never as plain text."),
    # PLAT-47 B4: the scopes the desktop's other Monaco tokenizers colour on
    # their own. Several of these pairs are ONE colour in one of the desktop's
    # two themes (said per pair), so they are merged at every rung there by
    # the desktop itself; the rest share their family's monochrome
    # attributes because monochrome has no combination left.
    (srSyntaxComment, srSyntaxCommentDoc,
     "A documentation comment is a comment. The light theme paints both" &
     " its `comment` rule's colour; the dark theme a green one step lighter for `comment.doc`."),
    (srSyntaxPlain, srSyntaxVariable,
     "A shell variable is text in the light theme (both the" &
     " default rule's colour); the dark theme greys it a step off the default."),
    (srSyntaxIdentifier, srSyntaxVariable,
     "A variable is an identifier: the light theme paints both the default" &
     " rule's colour, and monochrome draws both upright and unweighted."),
    (srSyntaxType, srSyntaxKeywordType,
     "A primitive type keyword (`keyword.type`) is a type name in the dark" &
     " theme — both its `type` rule's colour — and the keyword blue in the light one."),
    (srSyntaxType, srSyntaxTypeIdentifier,
     "A type identifier is a type: the light theme paints both its `type` rule's" &
     " colour," &
     " the dark theme only lightens `type.identifier` to a near-grey."),
    (srSyntaxKeywordType, srSyntaxTypeIdentifier,
     "Both are type names; monochrome gives every type the type's bold" &
     " italic, and no attribute combination is left to split them."),
    (srSyntaxType, srSyntaxNamespace,
     "A namespace (`Geometry::`, a YAML tag) names a type-like scope;" &
     " monochrome draws it in the type's bold italic."),
    (srSyntaxKeywordType, srSyntaxNamespace,
     "The type family's third member at the monochrome rung: bold italic."),
    (srSyntaxTypeIdentifier, srSyntaxNamespace,
     "The type family's fourth member at the monochrome rung: bold italic."),
    (srSyntaxString, srSyntaxRegexp,
     "A regular-expression literal is a string-like literal; where no tint" &
     " is left it reads as one, in the string's italic."),
    (srSyntaxStringEscape, srSyntaxRegexp,
     "A string's quote and a regex literal share the string's italic at the" &
     " monochrome rung, as the quote and the string body already do."),
    (srSyntaxOperator, srSyntaxAttributeName,
     "A command-line option (`-e`, `--force`, shell's `attribute.name`) is" &
     " dash-led syntax; monochrome draws it with the operator's bold" &
     " underline."),
    (srSyntaxKeyword, srSyntaxMetatag,
     "A shebang (`#!`, shell's `metatag`) is an interpreter directive and" &
     " reads as a keyword-like marker in monochrome's bold."),
    (srSyntaxTag, srSyntaxMetatag,
     "The shebang and a decorator are both markers: bold, at the monochrome" &
     " rung, as the decorator and the keyword already are."),
    # PLAT-50: three lines of the chrome's border tier.
    (srBorderPane, srDividerStrip,
     "The two `--dividers` choices for the same pane divider (the user's open" &
     " choice): a screen draws one or the other, never both, so where no" &
     " colour is left they are the one divider line `▏` they always are."),
    (srBorderPane, srBorderMenu,
     "A dropdown's frame and a pane divider: the frame is drawn in box" &
     " glyphs (`┌─┐│└┘`) and the divider in `▏`, so the GLYPH tells them" &
     " apart at every rung; the colour rungs add the frame's lighter" &
     " ui/border/primary."),
    (srBorderMenu, srDividerStrip,
     "A dropdown's frame and the strip-coloured divider: told apart by their" &
     " glyphs as above, and by colour on every colour rung.")]
    ## Pairs of roles in one group that share an appearance at some tier ON
    ## PURPOSE, each with the argument for it. The COUNT is asserted by
    ## `app/tests/test_degraded_style_tables.nim`.

proc roleStyle*(role: SemanticRole; depth: ColorDepth;
                mode: DesignMode = dmDark;
                palette: PaletteKind = pkDesign): CellStyle =
  ## One role, resolved onto one tier in one mode — the table the
  ## distinguishability property is asserted over.
  resolveRoles(CellStyle(role: role), depth, mode, palette)

proc monochromeStyle*(role: SemanticRole): CellStyle =
  ## THE BOTTOM RUNG: weight, underline, reverse. No `fg`, no `bg`, ever.
  roleStyle(role, cdMonochrome)

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
  of srTimelineBounds: "["
  else: ""

proc appearance*(role: SemanticRole;
                 caps: TerminalCapabilities): RoleAppearance =
  ## What this role looks like on THIS terminal, in the theme it was asked for.
  RoleAppearance(style: roleStyle(role, caps.colors, caps.mode, caps.palette),
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
# The mechanical projection, for styles no role claims
# ---------------------------------------------------------------------------

proc isRgbSpelling(s: string): bool =
  s.len == 7 and s[0] == '#'

proc isIndexedSpelling(s: string): bool =
  s.startsWith("indexed:")

proc nearestAnsiName*(colour: string): string =
  ## The closest of the sixteen ANSI names to an `#RRGGBB` or `indexed:N`
  ## spelling, in OKLab (`colour_math.nearestAnsi16Family` — the same derivation the
  ## role rungs use). An ANSI name, "" or anything unrecognised is returned
  ## unchanged.
  ##
  ## Only LITERAL colours reach here — content such as the frame viewer's
  ## pixels. Roles are resolved by `palette.resolveRoles` before projection.
  if isRgbSpelling(colour):
    var ok = false
    let c = parseHexColour(colour, ok)
    if not ok:
      return ""
    return AnsiNames[nearestAnsi16Family(c)]
  if isIndexedSpelling(colour):
    var idx = 0
    try:
      idx = parseInt(colour["indexed:".len .. ^1])
    except ValueError:
      return ""
    if idx < 16:
      return AnsiNames[max(0, idx)]
    return AnsiNames[nearestAnsi16Family(xterm256Rgb(min(idx, 255)))]
  colour

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
  ## One painted style at the resolved tier: the ROLES first
  ## (`palette.resolveRoles`, in the negotiated mode and palette), then the
  ## mechanical projection.
  ##
  ## The projection runs after the roles too, and that is not redundant: it is
  ## what makes the tier invariant a property of THIS function rather than of
  ## every table entry being right. Under `--palette=terminal` it projects to
  ## the sixteen names whatever the depth, so a literal content colour cannot
  ## smuggle a 24-bit SGR past the palette the user asked for.
  let resolved = resolveRoles(style, caps.colors, caps.mode, caps.palette)
  let depth =
    if caps.palette == pkTerminal and caps.colors > cdAnsi16: cdAnsi16
    else: caps.colors
  projectStyle(resolved, depth)

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
