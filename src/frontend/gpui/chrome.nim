## chrome.nim — PLAT-37. The colours `codetracer-gpui` paints its window with.
##
## ## Why this module exists at all, and what it is NOT
##
## PLAT-20 through PLAT-23 built a shadow tree and never opened a window, so
## nothing in this front-end had ever needed a colour. The whole of
## `gpui/app/leaves.nim` sets **two** styles, both `display: flex`, and
## `gpui_app.rs`'s `apply_styles_to_div` does not even read that key — so the
## tree this front-end produces, handed to a real renderer, paints
## default-coloured text on a default background. PLAT-37's claim is *"there
## is a window and its pixels are not the pixels of a blank screen"*, plus the
## OCR join, and neither is reachable from a tree with no colours in it.
##
## **This is NOT a design-system alignment claim, and reading it as one would
## be the tier confusion PLAT-37's instrument contract is written against.**
## Alignment with the Electron design is PLAT-35's, measured per question and
## per scenario, and `PLAT35-VG5` (*"the two front-ends open on different
## default layouts"*) and `PLAT35-VG8` (*"the GPUI state pane publishes no text
## role"*) are filed and stay filed. What is here is the minimum a frame needs
## to exist and be legible: a surface, a foreground, a pane fill, and a title
## colour. Four values.
##
## **Where the four values came from, said plainly rather than implied.** They
## are chosen here, in this milestone, and they are not read out of
## `codetracer-design-system` — because that repository publishes no hex for
## any member of `layout_questions.DesignTokenAlphabet` (checked 2026-09-22:
## `grep -rl 'editor.code.foreground' ../codetracer-design-system` is empty,
## and the Electron front-end resolves a token from a rendered CLASS, never
## from a colour, in `src/tests/gui/tools/layout-answers.ts`'s `q7`). Inventing
## a palette and calling it the design system's would be worse than choosing
## one and saying so. When a published mapping exists, this module is where it
## lands and these constants are what it replaces.
##
## ## The one property that IS asserted rather than asserted-by-eye
##
## A chrome whose foreground and background are close together is a window
## that opens, paints, and photographs as a blank screen — the exact failure
## PLAT-37 exists to make impossible, arriving through the palette instead of
## through the renderer. So contrast is COMPUTED, from the WCAG 2.x relative
## luminance definition, and the floor is a constant the suite reads.
##
## https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
## https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio

import std/[strutils, math]

import ../styles/generated/design_tokens
# `FamilyClass` — the face class a text role's DECLARED metric names. The
# window applies the face the answer already publishes rather than declaring
# it a second time; see `fontFamilyForMetric`.
import ../../common/view_vocabulary

type
  ChromeRole* = enum
    ## The closed set of things this front-end paints. Closed on purpose: a
    ## role added here is a role `chromeContrastFloorHolds` must then account
    ## for, which is what stops the palette growing a member nobody looked at.
    crWindowBackground = "window.background"
    crWindowForeground = "window.foreground"
    crPaneBackground = "pane.background"
    crPaneTitleForeground = "pane.title.foreground"
    crTabActiveForeground = "tab.active.foreground"
      ## PLAT-47, PLAT-49. The active tab of a strip: a foreground of its own
      ## (ui/text/primary/headings).
    crTabInactiveForeground = "tab.inactive.foreground"
      ## PLAT-47. Every other tab: the desktop's disabled title tier.
    crTabStripBackground = "tab.strip.background"
      ## PLAT-49. The tab strip's own ground, distinct from the pane body —
      ## the user's direction, 2026-10-01. The window's card tier
      ## (ui/surface/base/card): the terminal's strip token (base/raised,
      ## #161616) is all but the WINDOW's own ground between the panes
      ## (#12161c), so in the window a strip on it would read as a gap.
    crTabActiveBackground = "tab.active.background"
      ## PLAT-49. The active tab's own background (ui/surface/primary/
      ## tertiary), so the selected tab is unmistakable.
    crInputBackground = "input.background"
      ## PLAT-49. The omnibar's field: an input box on its own surface
      ## (ui/surface/input/default).
    crFocusOutline = "focus.outline"
      ## PLAT-47. The focused pane's 1px outline: the desktop's selected-panel
      ## stroke (`SELECTED_PANEL_BORDER_COLOR`, ui/border/primary).

const
  WindowChrome*: array[ChromeRole, string] = [
    "#12161c", # crWindowBackground — the surface behind every pane
    "#e6edf3", # crWindowForeground — body text
    "#1b222c", # crPaneBackground — one pane's fill, lifted off the surface
    "#7ee3c8", # crPaneTitleForeground — the pane heading
    # PLAT-47: the tab strip and the focus outline are the DESKTOP'S, read
    # from the design system the desktop's stylesheets are generated from
    # (Dark), not chosen here — see `components/golden_layout.styl`.
    DesignTokenHex[dtColorsUiTextPrimaryHeadings][dmDark],
    DesignTokenHex[dtColorsUiTextPrimaryDisabled][dmDark],
    # PLAT-49: the strip's own ground (see `crTabStripBackground`) and the
    # active tab's own background — the token the terminal's `srTabActive`
    # paints.
    DesignTokenHex[dtColorsUiSurfaceBaseCard][dmDark],
    DesignTokenHex[dtColorsUiSurfacePrimaryTertiary][dmDark],
    DesignTokenHex[dtColorsUiSurfaceInputDefault][dmDark],
    DesignTokenHex[dtColorsUiBorderPrimary][dmDark],
  ]
    ## Indexed by `ChromeRole`, so a role with no colour does not compile.

  FocusOutlinePx* = 1
    ## The focused pane's outline width, in device pixels — the desktop's
    ## `SELECTED_PANEL_BORDER` (0.0625rem, measured 1px). Every pane carries
    ## an outline this wide so focus moving never moves a pane's content;
    ## an unfocused pane's is the window's own background, i.e. invisible.

  MinimumContrastRatio* = 4.5
    ## WCAG 2.x AA for body text. It is a FLOOR on a computed quantity and not
    ## a description of the values above: raising it is how a future palette is
    ## held to the same standard, and lowering it would be the silent repair
    ## §36a names.
    ##
    ## HISTORY: introduced 2026-09-22 at 4.5. It has never been lowered.

  WindowFontFamily* = when defined(macosx): "Helvetica Neue" else: "DejaVu Sans"
    ## The window's text face, named rather than left to GPUI's default
    ## (`.SystemUIFont`). Measured 2026-09-29 on the window lane: with the
    ## default alias the text rendered in the fallback sans's Book face and a
    ## `font-weight: bold` tab drew exactly as heavy as a regular one — the
    ## alias resolved no bold face — so the active tab was bold in the plan
    ## and not on screen. Naming the family lets the text system find its
    ## Bold. DejaVu Sans is what that fallback already was on that host, so
    ## no metric moved there.
    ##
    ## **IT IS PER PLATFORM SINCE 2026-10-02, AND THE SINGLE VALUE WAS A
    ## SILENT NO-OP ON macOS.** The family is resolved by the platform's own
    ## text system — `MacTextSystem` on macOS, `CosmicTextSystem` on Linux —
    ## and only the second consults fontconfig. The dev shell exports
    ## `FONTCONFIG_FILE=…/fonts.conf`, which is where DejaVu comes from and
    ## which Core Text never reads; `ls /System/Library/Fonts` on
    ## aarch64-darwin / macOS 15 answers `Courier.ttc`, `Menlo.ttc`,
    ## `SFNSMono.ttf` and no DejaVu at all. So a name no font has, and a
    ## fallback to whatever the text system picks — which is how a
    ## `font-family` that is set, drawn and asserted still produced the
    ## proportional default the 2026-10-02 reviews reported.
    ##
    ## `Helvetica Neue` and `Menlo` are chosen because they have shipped in
    ## `/System/Library/Fonts` since OS X 10.6 and are addressable by exactly
    ## these names; `.SystemUIFont` and `SF Mono` are not reliably resolvable
    ## by name, which is the defect this constant exists against.

  MonoFontFamily* = when defined(macosx): "Menlo" else: "DejaVu Sans Mono"
    ## **The face the editor, the gutter and the inline values are set in.**
    ##
    ## PLAT-35, 2026-10-02, and it is a correction of a sentence this tree
    ## carried rather than a new choice. `app/leaves.nim`'s `GutterGap` said
    ## *"the face drawn is the window's proportional default (the shim does
    ## not draw `font-family`, so `gpuiMetricFor`'s mono is declared rather
    ## than applied — `PLAT35-VG1`)"*. The second clause is FALSE and was
    ## measured false: `gpui_app.rs`'s `apply_styles_to_div` reads
    ## `"font-family" | "font_family"` into `styles.font_family` and calls
    ## `el.font_family(...)` on it. Nothing was applying the declared face
    ## because nothing was setting the key.
    ##
    ## The first macOS capture of this front-end's own scene is what made the
    ## consequence visible rather than arguable. Three of the six review
    ## readings on 2026-10-02 reported it, and one of them named the
    ## mechanism exactly: *"code is set in a proportional sans, not monospace
    ## (`total = add(total, i)` glyph widths vary); columns do not line up"*,
    ## and *"the `▶` on line 6 displaces the `6` rightward, so numbers 2/6/10
    ## each sit at a different x"*. The gutter's lanes are fixed-WIDTH in
    ## characters (`gutterText` is
    ## `<pointer><mark><lane gap><right-aligned number><gap>` since 2026-10-03
    ## — `<padding><pointer><mark><number><gap>` before that, which is
    ## `PLAT35-F14`; every lane is still one glyph), which aligns the numbers
    ## in a monospaced face and in no other.
    ##
    ## Each value is `WindowFontFamily`'s own monospace sibling on its
    ## platform, so the two faces come from one family and a host that has
    ## one has the other — and the per-platform split is not cosmetic: the
    ## first attempt at this fix set one name for both platforms and
    ## **re-captured six byte-identical frames**, which is the measurement
    ## that found it. See `WindowFontFamily`.
    ## The brief's third design goal is the requirement being met:
    ## *"monospace for code, gutter and inline values; proportional for pane
    ## titles and variable names"* — which is also `gpuiMetricFor`'s table,
    ## already written and until now unapplied.
    ##
    ## **THE FALSE SENTENCE IS NOW CORRECTED IN `app/leaves.nim`, 2026-10-03,
    ## AND THE COUNT THIS PARAGRAPH CARRIED WAS WRONG — AS WAS THE FIRST
    ## CORRECTION OF IT.** It said that `run-plat20-mutations.py`,
    ## `run-plat21-mutations.py`, `run-plat22-mutations.py` and
    ## `run-plat35-visual-mutations.py` each digest `app/leaves.nim`
    ## byte-for-byte into a `*-control.sha256`, so editing the comment moved
    ## FOUR digests. A first correction read only the harnesses under
    ## `src/frontend/gpui/tests/` and said THREE. Measured at review on
    ## 2026-10-03 against `c05d8443a`, by parsing EVERY `*-control.sha256` in
    ## the tree: it is **SIX** — plat20, plat22, plat35-visual, and also
    ## `run-plat42-surface-mutations.py`, `run-plat47-parity-mutations.py`
    ## and `run-plat49-chrome-mutations.py`, which live under
    ## `src/frontend/tui/tests/` and hold `leaves.nim` as a subject across the
    ## medium boundary. The exclusion every draft got right stands:
    ## `run-plat21-mutations.py`'s subjects are `gpui_binding`, `fact_reader`,
    ## `pane_views`, `gpui_gaps`, `mappings`, `surfaces` and
    ## `terminal_binding`, and `leaves.nim` is not among them.
    ##
    ## `leaves.nim`'s own `GutterGap` header carries the full table and, for
    ## each of the six, THE RE-GRADE THAT WAS ATTEMPTED AND WHAT IT ANSWERED.
    ## One of them — plat20 — grades on this host (14 of 14 KILLED) and its
    ## digest IS re-recorded; the other five refuse for reasons named there.
    ##
    ## **EDITING *THIS* FILE MOVES THREE**, measured the same way —
    ## `run-plat37-window-mutations.py`, `run-plat47-parity-mutations.py` and
    ## `run-plat49-chrome-mutations.py` — and all three were GREEN at the
    ## parent commit, so all three were RUN rather than reasoned about:
    ##
    ##   * `plat37-window` REFUSES — *"an arm in this selection is graded
    ##     against the LIVE corpus and `build/plat37/manifest.json` is not
    ##     here"*. That manifest comes from the WINDOWED capture lane
    ##     (`ci/test/plat37-window-frame.sh`), which is Wayland-only and is
    ##     TCC-refused on aarch64-darwin — the measurement this module's own
    ##     header and `ci/test/plat35-gpui-capture.sh` both already carry.
    ##   * `plat47-parity` and `plat49-chrome` answer *"REFUSING TO RUN:
    ##     `REPLAY_SERVER_BIN` is not exported"*. Their needle scans pass with
    ##     `0 problems`; only the environment is missing.
    ##
    ## None of those three is re-recorded here, because none could be
    ## re-graded here, and recording a digest without a re-grade is
    ## `Verification-Harness-Traps` §39.

  ChromeGapPx* = 8
  ChromePaddingPx* = 12
    ## The window's own padding and the gap between panes, in device pixels.
    ## They are here rather than in `main.nim` because `paneWidthPx` below has
    ## to subtract exactly these, and two spellings of one number is §30.

func hexChannel(hex: string; index: int): float =
  ## One 8-bit channel of `#rrggbb`, as 0.0 .. 1.0.
  ##
  ## `func`, and it raises `ValueError` on a malformed string rather than
  ## defaulting to zero: a palette entry that is not a colour must fail where
  ## it is written, not paint black and look like a rendering defect.
  let body = if hex.len > 0 and hex[0] == '#': hex[1 .. ^1] else: hex
  if body.len != 6:
    raise newException(ValueError, "not a #rrggbb colour: '" & hex & "'")
  float(parseHexInt(body[index * 2 .. index * 2 + 1])) / 255.0

func relativeLuminance*(hex: string): float =
  ## WCAG 2.x relative luminance of an sRGB colour.
  var linear: array[3, float]
  for i in 0 .. 2:
    let c = hexChannel(hex, i)
    linear[i] =
      if c <= 0.04045: c / 12.92
      else: pow((c + 0.055) / 1.055, 2.4)
  0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

func contrastRatio*(a, b: string): float =
  ## The WCAG contrast ratio between two colours, in 1.0 .. 21.0. Symmetric,
  ## which is why the lighter of the two is chosen rather than assumed.
  let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
  let (lighter, darker) = if la >= lb: (la, lb) else: (lb, la)
  (lighter + 0.05) / (darker + 0.05)

func chromeOf*(role: ChromeRole): string =
  WindowChrome[role]

func fontFamilyFor*(family: FamilyClass): string =
  ## The window's face for a declared family class. An exhaustive `case`, so
  ## a third class does not compile until it has a face.
  case family
  of fcMono: MonoFontFamily
  of fcProportional: WindowFontFamily

func fontFamilyForMetric*(metric: string): string =
  ## The face a DECLARED text metric names, or "" when it names none.
  ##
  ## **THE APPLIED FACE IS DERIVED FROM THE ANSWERED ONE, which is the whole
  ## point of parsing a string here instead of taking a `TextRole`.**
  ## `metric` is what `leaves.gpuiMetricFor` stamped on the element and what
  ## the tier-3 `text-metrics-per-role` question compares against the
  ## Electron front-end's `getComputedStyle` reading. Deriving the face from
  ## it makes *the face the gate compares* and *the face the renderer draws*
  ## one fact, so they cannot drift apart; a second `case` over `TextRole`
  ## here would be two spellings of one declaration
  ## (`Verification-Harness-Traps` §30), and the failure mode of that drift
  ## is a front-end that ANSWERS `mono` and DRAWS proportional — exactly the
  ## state measured on 2026-10-02.
  ##
  ## "" rather than a default face for an unparseable metric: an element with
  ## no declared metric keeps the window's inherited face, and an element
  ## whose metric this build cannot read must not be silently restyled.
  if metric.len == 0:
    return ""
  let face = metric.split('/')[0]
  for family in FamilyClass:
    if $family == face:
      return fontFamilyFor(family)
  ""

func paneWidthPx*(viewportWidth, paneCount: int): int =
  ## How wide one pane is when `paneCount` of them tile the window's width.
  ##
  ## Derived rather than declared, because the number that matters is the one
  ## the renderer receives: `gpui_app.rs`'s `apply_styles_to_div` accepts
  ## `100%` / `full` or a pixel value and NOTHING ELSE — no `50%`, no `1fr` —
  ## so a front-end that wants two panes side by side has to do this division
  ## itself. Returns at least 1 so a degenerate viewport produces a visible
  ## sliver rather than a zero-width div the renderer silently drops.
  if paneCount <= 0:
    return max(1, viewportWidth - 2 * ChromePaddingPx)
  let usable = viewportWidth - 2 * ChromePaddingPx - (paneCount - 1) * ChromeGapPx
  max(1, usable div paneCount)

func tabStyle*(active: bool): seq[(string, string)] =
  ## PLAT-47 deliverable 8, revisited by PLAT-49's finding 4 (the user,
  ## 2026-10-01, over PLAT-47's "follow the desktop's single #282828"): how
  ## one tab of a strip is styled. Shaped by colour and weight alone — no
  ## brackets, no rule — but the SELECTED tab has a background AND a
  ## foreground of its own, bold; every other tab sits on the strip's own
  ## ground (`stripStyle`) in the disabled tier. The window's chrome applies
  ## exactly this list (`main.paintWindowChrome`).
  if active:
    @[("color", chromeOf(crTabActiveForeground)), ("font-weight", "bold"),
      ("background-color", chromeOf(crTabActiveBackground))]
  else:
    @[("color", chromeOf(crTabInactiveForeground))]

func stripStyle*(): seq[(string, string)] =
  ## PLAT-49: a tab strip's own ground, distinct from the pane body under it.
  @[("background-color", chromeOf(crTabStripBackground))]

func paneOutlineStyle*(focused: bool): seq[(string, string)] =
  ## PLAT-47 deliverable 9, GPUI's half: every pane box's 1px BORDER — the
  ## desktop's selected-panel colour around the focused pane, the window's
  ## own background (invisible) around the rest. The same width around every
  ## pane, so focus moving never moves content, and closed on all four sides
  ## by construction: the border belongs to the pane's own box, around its
  ## tab strip and its body together, as the desktop's does.
  ##
  ## A BORDER since isonim-gpui's shim draws `border-*` (part B's B2). Until
  ## then the shim drew fills and padding only, and this was a frame: a fill
  ## one pixel wider than the pane, padded by `FocusOutlinePx`.
  @[("border-width", $FocusOutlinePx & "px"),
    ("border-color",
     chromeOf(if focused: crFocusOutline else: crWindowBackground))]
