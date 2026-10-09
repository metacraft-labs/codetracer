## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/roles.nim — every distinction this front-end paints, and the
## design-system token each one paints WITH.
##
## ## Where the colours come from
##
## From `codetracer-design-system`, and from nowhere else. The desktop's stylus
## (`src/frontend/styles/generated/*.styl`) and this front-end's
## `src/frontend/styles/generated/design_tokens.nim` are both written by ONE run
## of `scripts/tokens-to-styl.sh` over the pinned `libs/codetracer-design-system`
## revision, and `ci/test/design-tokens-fresh.sh` fails when either is stale. So
## a role here names a `DesignToken` — an enum member the generator emits per
## token path — and never a hex: a token the design system renames or removes is
## a COMPILE error in this file rather than a silently kept colour, and
## `ci/test/tui-design-tokens-boundary.sh` (run by `ci/lint/nim.sh`) rejects
## any `#rrggbb` literal under `tui/app/`.
##
## ## What a role is
##
## A role is one STATE of one thing the screen shows — a keyword, a verified
## breakpoint, the active tab, a pane body. It carries:
##
##   * `fg` / `bg` — the design-system tokens it paints its foreground and (for
##     a surface or a highlight) its background with, resolved per colour MODE
##     (the design system's Dark and Light);
##   * `attrs` — the weight/underline/reverse it carries on the COLOUR rungs
##     (truecolor, 256, 16 and the terminal palette). Where a DERIVED rung
##     merges two states of one group into one colour, both carry their `mono`
##     set there instead (`palette.CollapsedOnRung`), so no rung loses a
##     distinction the design made;
##   * `mono` — what it carries on the MONOCHROME rung, where attributes are all
##     that is left. CTUI-11's contract lives there: within a `DistinctionGroup`
##     any two roles whose colour rungs tell them apart are told apart in
##     monochrome too, by weight, underline, reverse or glyph
##     (`app/tests/test_degraded_style_tables.nim` asserts it over the whole
##     cross product).
##
## Views paint ROLES (`CellStyle.role`, `CellStyle.surface`); they never spell a
## colour. `app/theme/degradation.degradeRows` is the one place a role becomes a
## colour on the resolved tier.

import ../../../styles/generated/design_tokens
import ./editor_theme

export design_tokens

type
  DistinctionGroup* = enum
    ## A set of roles that are STATES OF ONE THING. The distinguishability
    ## contract is stated per group: a pane title and a string literal never need
    ## to be told apart — they are never in the same place — while a verified
    ## breakpoint and a disabled one always do.
    dgNone = "none"
    dgChrome = "chrome"
    dgBorder = "border"
    dgTab = "tab"
    dgSurface = "surface"
    dgGutter = "gutter"
    dgLineNumber = "line-number"
    dgProvenance = "provenance"
    dgLine = "line"
    dgValue = "value"
    dgValueKind = "value-kind"
    dgSyntax = "syntax"
    dgTimeline = "timeline"
    dgEvent = "event"
    dgBuild = "build"
    dgMode = "mode"
    dgFrame = "frame"
    dgHeat = "heat"
    dgCategory = "variable-category"
      ## PLAT-49: which group (local, argument, …) a variables row belongs to.
    dgCallTrace = "call-trace"
      ## PLAT-49 part B: the parts of a call-trace row the desktop colours —
      ## its arguments and its return value.
    dgScrubber = "scrubber"
      ## PLAT-52: a scrubber's parts — a list pane's scrollbar scrubber
      ## (Scrollbar-Scrubbers.md §4) and the terminal screen's built-in one
      ## (Terminal-Output-Pane.md §3): the track, the thumb, the thumb's ground
      ## where an eighth block is drawn reversed, and the current-position
      ## mark.

  SemanticRole* = enum
    ## Every distinction this front-end's screen carries. `srNone` is the zero
    ## value, so a `CellStyle()` names no role and a view that forgets one is a
    ## cell `degradeRows` paints in the surrounding surface's text colour rather
    ## than in the terminal's default.
    srNone = "none"

    # ---- dgChrome: the shell's own furniture ------------------------------
    srChromeText = "chrome-text"
    srChromeMuted = "chrome-muted"
    srChromeTitle = "chrome-title"
    srChromeTitleFocused = "chrome-title-focused"
    srChromeNotification = "chrome-notification"
    srChromeError = "chrome-error"
    srChromeSuccess = "chrome-success"
    srChromeInfo = "chrome-info"
    srChromeAccent = "chrome-accent"
    srChromePrompt = "chrome-prompt"
    srEditorText = "editor-text"
      ## PLAT-51: the EDITOR'S default foreground as a text role, for a cell
      ## on a ground that is not the editor's own (the omnibox's selected
      ## result, on the editor's selection colour — Commands-And-Omnibox.md,
      ## "Omnibox colours on every front-end").

    # ---- dgBorder: box drawing ---------------------------------------------
    srBorderPane = "border-pane"
    srBorderFocused = "border-focused"
    srBorderMenu = "border-menu"
      ## PLAT-50: the hairline round a dropdown (the menu, a context menu) —
      ## the desktop's `dropdown-surface-chrome()` border.
    srDividerStrip = "divider-strip"
      ## PLAT-50: a pane divider drawn in the TAB STRIP'S ground — the
      ## `--dividers=strip` choice, the desktop's splitter colour.

    # ---- dgTab: tab strips ------------------------------------------------
    srTabBar = "tab-bar"
    srTabActive = "tab-active"
    srTabInactive = "tab-inactive"
    srTabBarFocused = "tab-bar-focused"
      ## PLAT-51 (Native-Front-End-Parity.md §2): the FOCUSED pane's tab
      ## strip, filled with the focus colour the ring uses.
    srTabActiveFocused = "tab-active-focused"
      ## …its active tab: the focus ground, the active tab's foreground and
      ## weight unchanged. (Its other tabs are the strip's own role, as an
      ## unfocused strip's inactive tabs are its strip's.)
    srSessionTab = "session-tab"
      ## PLAT-49 part B (finding 7): an INACTIVE session tab in the top bar —
      ## a ground of its own, so each session is a separate clickable item
      ## on the bar (the active one is `srTabActive`).

    # ---- dgSurface: what a region's cells are filled with ------------------
    srSurfaceCanvas = "surface-canvas"
    srSurfaceTopBar = "surface-top-bar"
      ## PLAT-50: the top bar's ground — the desktop's caption bar (`#menu`).
    srSurfaceMenu = "surface-menu"
      ## PLAT-50: an open dropdown's ground — the desktop's dropdown surface.
    srSurfacePanel = "surface-panel"
    srSurfaceCard = "surface-card"
    srSurfaceEditor = "surface-editor"
    srSurfaceStatusLine = "surface-status-line"
    srSurfaceInput = "surface-input"
    srSurfaceField = "surface-field"
      ## PLAT-49: a one-row input box in the top bar (the omnibar's field).
    srSurfaceSelection = "surface-selection"
    srSurfaceCurrentLine = "surface-current-line"
    srSurfaceActiveRow = "surface-active-row"
      ## PLAT-49 part B: the ground of a list's ACTIVE row — the call the
      ## debugger is in, in the call trace (the desktop's `.event-selected`).
    srSurfaceDropIndicator = "surface-drop-indicator"
      ## PLAT-47: the colour a drag's drop zone is TINTED toward (an
      ## `isonim_tui` overlay re-colours the cells, it never fills them).

    # ---- dgGutter: §3.3.2's marks -----------------------------------------
    srGutterNoMark = "gutter-no-mark"
    srGutterBreakpoint = "gutter-breakpoint"
    srGutterBreakpointDisabled = "gutter-breakpoint-disabled"
    srGutterTracepoint = "gutter-tracepoint"
    srGutterExecutionPointer = "gutter-execution-pointer"
    srGutterInspectionPointer = "gutter-inspection-pointer"

    # ---- dgLineNumber: the gutter's number, tinted by provenance -----------
    srLineNumber = "line-number"
    srLineNumberActive = "line-number-active"
    srLineNumberUnverified = "line-number-unverified"
    srLineNumberAbsent = "line-number-absent"

    # ---- dgProvenance: CTUI-4's source verdict ----------------------------
    srSourceVerified = "source-verified"
    srSourceUnverified = "source-unverified"
    srSourceAbsent = "source-absent"

    # ---- dgLine: what a whole source row can be ---------------------------
    srLineOrdinary = "line-ordinary"
    srLineExecution = "line-execution"
    srLineSearchMatch = "line-search-match"
    srLineNotTaken = "line-not-taken"

    # ---- dgValue: CTUI-7's step-to-step diff ------------------------------
    srValueUnchanged = "value-unchanged"
    srValueModified = "value-modified"
      ## PLAT-51: a CHANGED VALUE — the shared changed-value accent the
      ## desktop's `.value-changed` paints. (`srValueModifiedTag`, the `[MOD]`
      ## badge's black-on-green, is gone with the badge.)

    # ---- dgCategory: PLAT-49's per-row variable category tags -------------
    srCategoryLocal = "category-local"
    srCategoryArgument = "category-argument"
    srCategoryGlobal = "category-global"
    srCategoryReturnValue = "category-return-value"
    srCategoryRegister = "category-register"
    srCategoryWatch = "category-watch"

    # ---- dgCallTrace: PLAT-49 part B's call-trace row parts ---------------
    srCallArgs = "call-args"
      ## A call's argument list (`.call-args`, CALLTRACE_ARGS_COLOR).
    srCallReturn = "call-return"
      ## A call's ` => value` (`.return-text`, CALLTRACE_RETURN_COLOR).

    # ---- dgValueKind: PLAT-2's value presentation --------------------------
    srValueNumber = "value-number"
    srValueString = "value-string"
    srValueBoolean = "value-boolean"
    srValuePointer = "value-pointer"
    srValueCompound = "value-compound"
    srValueNoneValue = "value-none"
    srValueError = "value-error"
    srValueOpaque = "value-opaque"
    srValueMedia = "value-media"
    srValueDefault = "value-default"

    # ---- dgSyntax: CTUI-5's nine token classes, and PLAT-47's three --------
    srSyntaxPlain = "syntax-plain"
    srSyntaxIdentifier = "syntax-identifier"
    srSyntaxKeyword = "syntax-keyword"
    srSyntaxType = "syntax-type"
    srSyntaxString = "syntax-string"
    srSyntaxNumber = "syntax-number"
    srSyntaxComment = "syntax-comment"
    srSyntaxOperator = "syntax-operator"
    srSyntaxPunctuation = "syntax-punctuation"
    srSyntaxStringEscape = "syntax-string-escape"
    srSyntaxBracket = "syntax-bracket"
    srSyntaxTag = "syntax-tag"
    srSyntaxTypeIdentifier = "syntax-type-identifier"
    srSyntaxKeywordType = "syntax-keyword-type"
    srSyntaxCommentDoc = "syntax-comment-doc"
    srSyntaxRegexp = "syntax-regexp"
    srSyntaxVariable = "syntax-variable"
    srSyntaxNamespace = "syntax-namespace"
    srSyntaxAttributeName = "syntax-attribute-name"
    srSyntaxMetatag = "syntax-metatag"

    # ---- dgTimeline: §3.3.5's scrubber ------------------------------------
    srTimelineTrack = "timeline-track"
    srTimelineSpan = "timeline-span"
    srTimelineMark = "timeline-mark"
    srTimelineNeedle = "timeline-needle"
    srTimelineBounds = "timeline-bounds"

    # ---- dgEvent: the event log's kinds -----------------------------------
    srEventOutput = "event-output"
    srEventMutation = "event-mutation"
    srEventSyscall = "event-syscall"
    srEventFault = "event-fault"
    srEventTracepoint = "event-tracepoint"
    srEventUnknown = "event-unknown"

    # ---- dgBuild: Edit mode's build verdicts ------------------------------
    srBuildIdle = "build-idle"
    srBuildRunning = "build-running"
    srBuildSucceeded = "build-succeeded"
    srBuildFailed = "build-failed"
    srBuildCancelled = "build-cancelled"

    # ---- dgMode: the status line's mode indicator -------------------------
    srModeDebug = "mode-debug"
    srModeEdit = "mode-edit"
    srModeNormal = "mode-normal"
    srModeCommand = "mode-command"
    srModeSearch = "mode-search"
    srModeInspect = "mode-inspect"
    srModeVisual = "mode-visual"
    srModeSeek = "mode-seek"

    # ---- dgFrame: the call stack's rows -----------------------------------
    srFrameGroupMarker = "frame-group-marker"
    srFrameUserBadge = "frame-user-badge"
    srFrameLibrary = "frame-library"
    srFrameLocation = "frame-location"

    # ---- dgHeat: the heatmap's execution-count scale ----------------------
    srHeat0 = "heat-0"
    srHeat1 = "heat-1"
    srHeat2 = "heat-2"
    srHeat3 = "heat-3"
    srHeat4 = "heat-4"
    srHeat5 = "heat-5"

    # ---- dgScrubber: PLAT-52's scrubbers -----------------------------------
    srScrubberTrack = "scrubber-track"
    srScrubberThumb = "scrubber-thumb"
    srScrubberThumbGround = "scrubber-thumb-ground"
      ## The thumb's colour as a GROUND, for the one partial cell at a thumb's
      ## far end: an upper (or right) part of a cell has no eighth-block glyph,
      ## so it is drawn as the complementary lower (left) block in the track's
      ## colour on this ground.
    srScrubberMark = "scrubber-mark"
      ## The current recording position on the track, in the execution
      ## pointer's colour.

  DividerChoice* = enum
    ## PLAT-50 (the user, 2026-10-02, undecided between the two): the colour a
    ## pane-body divider is drawn in. Either way the divider is a thin edge
    ## line (`DividerGlyph`) and, in a tab-strip row, the strip's own ground.
    dcStrip = "strip"
      ## The tab strip's ground (`srDividerStrip`, ui/surface/primary/
      ## default) — the desktop's splitter colour (`.lm_splitter`, measured
      ## #1b1b1b, the ground its tabs sit on). The default: closer to the
      ## desktop.
    dcSubtle = "subtle"
      ## A distinct subtle line (`srBorderPane`, ui/border/secondary).
  RoleAttr* = enum

    raBold, raItalic, raUnderline, raReverse

  RoleSpec* = object
    ## One row of the table.
    group*: DistinctionGroup
    hasFg*: bool
    fg*: DesignToken
    hasBg*: bool
    bg*: DesignToken
    attrs*: set[RoleAttr]
      ## On every colour rung.
    mono*: set[RoleAttr]
      ## On the monochrome rung.
    baseSurface*: bool
      ## A surface a whole region is filled with (pane body, editor, tab bar,
      ## status line, input). `--palette=terminal` paints these with the
      ## terminal's DEFAULT background (SGR 49) — the user's own theme — and
      ## keeps only the highlight surfaces (selection, current line, …) as
      ## ANSI indices.

func fgbg(group: DistinctionGroup; fg: DesignToken; bg: DesignToken;
          attrs: set[RoleAttr] = {}; mono: set[RoleAttr] = {};
          baseSurface = false): RoleSpec =
  RoleSpec(group: group, hasFg: true, fg: fg, hasBg: true, bg: bg,
           attrs: attrs, mono: mono, baseSurface: baseSurface)

func fgOnly(group: DistinctionGroup; fg: DesignToken;
            attrs: set[RoleAttr] = {}; mono: set[RoleAttr] = {}): RoleSpec =
  RoleSpec(group: group, hasFg: true, fg: fg, attrs: attrs, mono: mono)

func bgOnly(group: DistinctionGroup; bg: DesignToken;
            mono: set[RoleAttr] = {}; baseSurface = false): RoleSpec =
  RoleSpec(group: group, hasBg: true, bg: bg, mono: mono,
           baseSurface: baseSurface)

func bare(group: DistinctionGroup; mono: set[RoleAttr] = {}): RoleSpec =
  RoleSpec(group: group, mono: mono)

const
  RoleSpecs*: array[SemanticRole, RoleSpec] = [
    srNone: bare(dgNone),

    # The spec's own examples: pane title -> ui/text/primary/label, muted
    # chrome -> ui/text/primary/caption-subtle.
    srChromeText: fgOnly(dgChrome, dtColorsUiTextPrimaryBody),
    srChromeMuted: fgOnly(dgChrome, dtColorsUiTextPrimaryCaptionSubtle,
                          mono = {raItalic}),
    srChromeTitle: fgOnly(dgChrome, dtColorsUiTextPrimaryLabel,
                          attrs = {raBold}, mono = {raBold}),
    srChromeTitleFocused: fgOnly(dgChrome, dtColorsUiTextPrimaryHeadings,
                                 attrs = {raBold},
                                 mono = {raBold, raReverse}),
    srChromeNotification: fgOnly(dgChrome, dtColorsUiTextWarningPrimary,
                                 mono = {raUnderline}),
    srChromeError: fgOnly(dgChrome, dtColorsUiTextErrorPrimary,
                          attrs = {raBold}, mono = {raBold, raUnderline}),
    srChromeSuccess: fgOnly(dgChrome, dtColorsUiTextSuccessPrimary,
                            mono = {raBold, raItalic}),
    srChromeInfo: fgOnly(dgChrome, dtColorsUiTextInformationPrimary,
                         mono = {raItalic, raUnderline}),
    srChromeAccent: fgOnly(dgChrome, dtColorsEditorActionPrimary,
                           attrs = {raBold},
                           mono = {raBold, raItalic, raUnderline}),
    srChromePrompt: fgOnly(dgChrome, dtColorsEditorActionSecondary,
                           attrs = {raBold}, mono = {raBold, raReverse,
                                                     raUnderline}),

    srEditorText: fgOnly(dgChrome, dtEditorThemeRuleDefault),
    srBorderPane: fgOnly(dgBorder, dtColorsUiBorderSecondary),
    # THE FOCUSED PANE'S OUTLINE (PLAT-47 deliverable 9): the desktop's own
    # focus colour, measured — GoldenLayout's selected panel is outlined by
    # one 1px stroke of ui/border/primary (`components/golden_layout.styl`,
    # `SELECTED_PANEL_BORDER_COLOR`), and nothing else about it changes. So
    # the terminal draws its focused pane's dividers in that token, at normal
    # weight on every colour rung; PLAT-46 had bound it to ui/border/focus, a
    # saturated blue the desktop uses only for keyboard focus rings, which the
    # user reported as far louder than the desktop. Monochrome keeps bold,
    # the one attribute a divider glyph can carry there.
    #
    # PLAT-51 (the user, 2026-10-05; Native-Front-End-Parity.md §2): SUBTLER.
    # The ring — and now the focused pane's whole tab strip, which takes the
    # same colour as its ground — moved one step closer to the surrounding
    # ground on the design system's border ramp: ui/border/secondary
    # (#3a3a3a / #bfb8aa) instead of ui/border/primary (#565656 / #aca494).
    # Measured contrast against the unfocused strip (ui/surface/primary/
    # default) 1.51 dark / 1.83 light (was 2.35 / 2.29), against the pane
    # body (ui/surface/base/panel) 1.30 / 1.53 (was 2.01 / 1.92) — non-zero on
    # every rung (`tests/test_plat51b_parity.nim` re-measures them from the
    # token table); monochrome keeps bold.
    srBorderFocused: fgOnly(dgBorder, dtColorsUiBorderSecondary,
                            mono = {raBold}),
    # PLAT-50 (the user, 2026-10-02: "the drop-down menu needs its own
    # background ... its borders are invisible"): A DROPDOWN IS FRAMED, as
    # the desktop's is — `dropdown-surface-chrome()` (components/
    # shared_widgets.styl) is ui/surface/primary/default under a
    # ui/border/primary hairline, measured on `#menu-main` (#1b1b1b, 1px
    # #565656) over #282828 panels. Monochrome keeps the frame's glyphs.
    srBorderMenu: fgOnly(dgBorder, dtColorsUiBorderPrimary),
    # PLAT-50: THE DIVIDER IN THE STRIP'S GROUND. The desktop's splitters
    # (`.lm_splitter`, components/golden_layout.styl) are
    # ui/surface/primary/default — the ground its tabs sit on — so a divider
    # drawn in that colour joins the tab strips it meets. The other choice is
    # `srBorderPane` (ui/border/secondary); `--dividers` picks.
    srDividerStrip: fgOnly(dgBorder, dtColorsUiSurfacePrimaryDefault),

    # THE TAB STRIP, BY THE USER'S DIRECTION (PLAT-49 finding 4, 2026-10-01),
    # which overrides PLAT-47's measured "follow the desktop's single
    # #282828": the strip sits on its OWN ground, distinct from the pane body
    # (ui/surface/base/raised — darker than the panel in Dark, lighter in
    # Light), inactive tabs on that ground in the disabled text tier, and the
    # selected tab on a background of its own (ui/surface/primary/tertiary)
    # with a foreground of its own (ui/text/primary/headings) and bold — so
    # it is unmistakable. The active tab is NOT a base surface: under
    # `--palette=terminal` it keeps an ANSI background index while the strip
    # takes the terminal's own. Where a rung collapses two of these (16
    # colours, the terminal palette's neutrals) the collapse guard paints the
    # monochrome attributes, and monochrome is reverse + bold (CTUI-11).
    srTabBar: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,
                   dtColorsUiSurfacePrimaryDefault, baseSurface = true),
    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryHeadings,
                      dtColorsUiSurfacePrimaryTertiary, attrs = {raBold},
                      mono = {raBold, raReverse}),
    # PLAT-50 (the user, 2026-10-02: "the black of the inactive tabs looks
    # like a defect"): the strip's ground moved from ui/surface/base/raised
    # (#161616 / #f3f3f3) to ui/surface/primary/default (#1b1b1b /
    # #f8f6f2) — the ground the desktop's tabs sit on, measured behind
    # `.lm_header` and on every `.lm_splitter`. Still its own ground, apart
    # from the pane body (PLAT-49 finding 4), by the desktop's own step.
    srTabInactive: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,
                        dtColorsUiSurfacePrimaryDefault, baseSurface = true),
    # PLAT-51: THE FOCUSED PANE'S STRIP on the ring's colour
    # (`srBorderFocused`'s token): every cell of it, tabs included; the
    # active tab keeps its foreground and weight; the others are in the
    # subdued body tier, because the disabled tier reads 2.36:1 (dark) /
    # 2.44:1 (light) on the focus colour, under the chrome floor, where
    # body-subtle reads 5.5:1 / 6.1:1 and stays apart from the active tab's
    # headings and bold. In monochrome, and wherever a rung collapses the
    # ground into the unfocused strip's, the strip is underlined and italic:
    # not reverse video (the selected tab stays the only reversed tab, PLAT-49)
    # and not underline alone (the session tab's mark).
    srTabBarFocused: fgbg(dgTab, dtColorsUiTextPrimaryBodySubtle,
                          dtColorsUiBorderSecondary,
                          mono = {raUnderline, raItalic}),
    srTabActiveFocused: fgbg(dgTab, dtColorsUiTextPrimaryHeadings,
                             dtColorsUiBorderSecondary, attrs = {raBold},
                             mono = {raBold, raReverse, raUnderline}),
    # PLAT-49 part B: a session tab off the bar's card (#262626 / #dbd6cc) by
    # one subtle step — ui/surface/primary/default (#1b1b1b / #f8f6f2) —
    # under the caption tier, the desktop's dimmed `.session-tab` text; the
    # active one is `srTabActive`'s tertiary with headings, as on the strips.
    srSessionTab: fgbg(dgTab, dtColorsUiTextPrimaryCaption,
                       dtColorsUiSurfacePrimaryDefaultHover, baseSurface = true,
                       mono = {raUnderline}),

    srSurfaceCanvas: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                          dtColorsUiSurfaceBaseCanvas, baseSurface = true),
    # PLAT-50: THE TOP BAR IS THE DESKTOP'S CAPTION BAR — `#menu` is
    # ui/surface/primary/default (components/menu_bar.styl), measured #1b1b1b,
    # and its menu button, transport buttons and omnibox all sit on that
    # ground with no fill of their own (they were on ui/surface/base/card, the
    # controls filled #161616).
    srSurfaceTopBar: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                          dtColorsUiSurfacePrimaryDefault, baseSurface = true),
    # PLAT-50: AN OPEN DROPDOWN'S GROUND — the desktop's dropdown surface
    # (see `srBorderMenu`). Not a base surface: under `--palette=terminal`
    # the menu keeps an index of its own rather than the terminal's ground,
    # so it never merges with the panes it covers.
    srSurfaceMenu: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                        dtColorsUiSurfacePrimaryDefault, mono = {raReverse}),
    srSurfacePanel: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                         dtColorsUiSurfaceBasePanel, baseSurface = true),
    srSurfaceCard: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                        dtColorsUiSurfaceBaseCard, baseSurface = true),
    # THE EDITOR IS THE DESKTOP'S (PLAT-47): its ground and default text are
    # the desktop's Monaco theme's, generated from the same file
    # (`theme/editor_theme.nim`), not the design system's `colors/editor/*`.
    srSurfaceEditor: fgbg(dgSurface, dtEditorThemeRuleDefault,
                          dtEditorThemeGround, baseSurface = true),
    srSurfaceStatusLine: fgbg(dgSurface, dtColorsUiTextPrimaryCaption,
                              dtColorsUiSurfaceBaseRaised,
                              baseSurface = true),
    srSurfaceInput: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                         dtColorsUiSurfaceInputDefault, mono = {raUnderline},
                         baseSurface = true),
    # PLAT-49 finding 6: THE OMNIBAR IS AN INPUT BOX with a ground of its
    # own. The design system's input token (#242424 in Dark) is all but the
    # top bar's card (#262626) — a field on it would not read as a box — so
    # the field is the base surface that differs from the card in both
    # modes: ui/surface/base/raised, recessed in Dark, lifted in Light. Not a
    # base surface, so `--palette=terminal` keeps an index for it; monochrome
    # underlines it, as the prompt's input surface is.
    #
    # PLAT-50 (the user, 2026-10-02: "the omnibox's white background looks
    # like a selection"): raised was #f3f3f3 in Light. The desktop's field
    # (`.command-input-row`) is the bar's own ground inside a
    # ui/border/secondary border; here it is the design system's input
    # surface (#242424 / #f8f6f2) — one subtle step off the bar — bounded by
    # that border as edge lines (`top_bar.paintTopBar`).
    srSurfaceField: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                         dtColorsUiSurfaceInputDefault, mono = {raUnderline}),
    srSurfaceSelection: bgOnly(dgSurface, dtEditorThemeSelection,
                               mono = {raReverse}),
    srSurfaceCurrentLine: bgOnly(dgSurface, dtEditorThemeExecutionLine,
                                 mono = {raReverse}),
    # PLAT-49 part B: THE ACTIVE ROW'S GROUND. The desktop's call trace puts
    # the call the debugger is in on a ground of its own (`.event-selected`),
    # and its step list puts its active row on ui/surface/primary/
    # secondary-hover (`.active-step-line`) — the design system's active-row
    # token, used here. In Dark (#333333 under the #282828 panel) the call
    # trace's body text, argument and return colours all clear 4.5:1 on it;
    # the toggle is drawn in the body colour on that row (the desktop's
    # `active` toggle icon). The argument and return colours' Light values
    # fail on every Light ground, the panel included (filed). Monochrome
    # reverses the row.
    srSurfaceActiveRow: bgOnly(dgSurface, dtColorsUiSurfacePrimarySecondaryHover,
                               mono = {raReverse}),
    # PLAT-47: the drop zone. The desktop's GoldenLayout darkens its drop
    # zone (`lm_dropTargetIndicator .lm_inner`, black at 20%) — a step a
    # terminal on the dark ground cannot show at 256 or 16 colours — so the
    # terminal and GPUI tint toward the design system's action colour
    # instead; monochrome reverses (`isonim_tui/overlay`).
    srSurfaceDropIndicator: bgOnly(dgSurface, dtColorsUiBorderAction,
                                   mono = {raReverse}),

    srGutterNoMark: bare(dgGutter),
    srGutterBreakpoint: fgOnly(dgGutter, dtColorsEditorSyntaxError,
                               attrs = {raBold}, mono = {raBold}),
    srGutterBreakpointDisabled: fgOnly(dgGutter, dtColorsUiTextPrimaryDisabled,
                                       mono = {raItalic}),
    srGutterTracepoint: fgOnly(dgGutter, dtColorsEditorSyntaxType,
                               attrs = {raBold}, mono = {raBold}),
    srGutterExecutionPointer: fgOnly(dgGutter, dtColorsEditorActionSecondary,
                                     attrs = {raBold},
                                     mono = {raBold, raUnderline}),
    srGutterInspectionPointer: fgOnly(dgGutter,
                                      dtColorsUiTextInformationPrimary,
                                      attrs = {raBold},
                                      mono = {raItalic, raUnderline}),

    srLineNumber: fgOnly(dgLineNumber, dtEditorThemeLineNumber),
    srLineNumberActive: fgOnly(dgLineNumber, dtEditorThemeActiveLineNumber,
                               mono = {raBold}),
    srLineNumberUnverified: fgOnly(dgLineNumber, dtColorsUiTextWarningPrimary,
                                   mono = {raBold, raItalic}),
    srLineNumberAbsent: fgOnly(dgLineNumber, dtColorsUiTextErrorPrimary,
                               mono = {raBold, raUnderline}),

    srSourceVerified: fgOnly(dgProvenance, dtColorsUiTextSuccessPrimary),
    srSourceUnverified: fgOnly(dgProvenance, dtColorsUiTextWarningPrimary,
                               attrs = {raBold}, mono = {raBold, raItalic}),
    srSourceAbsent: fgOnly(dgProvenance, dtColorsUiTextErrorPrimary,
                           attrs = {raBold}, mono = {raBold, raUnderline}),

    srLineOrdinary: bare(dgLine),
    srLineExecution: bgOnly(dgLine, dtEditorThemeExecutionLine,
                            mono = {raReverse}),
    srLineSearchMatch: fgbg(dgLine, dtColorsEditorSyntaxOnColor,
                            dtColorsEditorActionSecondary,
                            mono = {raReverse, raUnderline}),
    srLineNotTaken: fgOnly(dgLine, dtColorsEditorSyntaxDisabled,
                           mono = {raItalic}),

    srValueUnchanged: bare(dgValue),
    # PLAT-51 (the user, 2026-10-05: the desktop had NO changed-value
    # styling — measured: no class, no rule in `isonim_state_view.nim` or the
    # stylesheets — "give it one, a subtle design-token accent on the changed
    # value, and use the same in the terminal and GPUI"). The token is
    # ui/text/information/primary-hover (#60a5fa / #1d4ed8): the one accent
    # of the design system's text ramps that clears 4.5:1 on the pane's
    # surface in BOTH modes (8.2 / 4.0 for information/primary itself — its
    # Light value fails). Normal weight: subtle. Monochrome underlines it.
    srValueModified: fgOnly(dgValue, dtColorsUiTextInformationPrimaryHover,
                            mono = {raUnderline}),

    # PLAT-49 finding 12: the variables pane's ONE-LETTER CATEGORY TAG
    # (`state_vm.categoryTag`), each category its own colour — six of the
    # design system's syntax hues, every one at or above 4.5:1 on the pane's
    # surface in both modes. On the monochrome rung the LETTER already tells
    # them apart; the attributes keep the group distinct by style as well.
    srCategoryLocal: fgOnly(dgCategory, dtColorsEditorSyntaxType,
                            attrs = {raBold}, mono = {raBold}),
    srCategoryArgument: fgOnly(dgCategory, dtColorsEditorSyntaxParameter,
                               attrs = {raBold}, mono = {raItalic}),
    srCategoryGlobal: fgOnly(dgCategory, dtColorsEditorSyntaxNumber,
                             attrs = {raBold}, mono = {raUnderline}),
    srCategoryReturnValue: fgOnly(dgCategory, dtColorsEditorSyntaxFunction,
                                  attrs = {raBold},
                                  mono = {raBold, raItalic}),
    srCategoryRegister: fgOnly(dgCategory, dtColorsEditorSyntaxKeyword,
                               attrs = {raBold},
                               mono = {raBold, raUnderline}),
    srCategoryWatch: fgOnly(dgCategory, dtColorsEditorSyntaxString,
                            attrs = {raBold},
                            mono = {raItalic, raUnderline}),

    # PLAT-49 part B: the desktop's call-trace row colours
    # (`default_*_theme.styl`): CALLTRACE_ARGS_COLOR #BBF7D0 / #15803D is
    # ui/text/success/primary (#bbf7d0 dark, #16a34a light), and
    # CALLTRACE_RETURN_COLOR #BFDBFE / #2563EB is ui/text/information/primary
    # (#93c5fd dark, #2563eb light) — the design system's nearest tokens.
    srCallArgs: fgOnly(dgCallTrace, dtColorsUiTextSuccessPrimary,
                       mono = {raItalic}),
    srCallReturn: fgOnly(dgCallTrace, dtColorsUiTextInformationPrimary,
                         mono = {raUnderline}),

    srValueNumber: fgOnly(dgValueKind, dtColorsEditorSyntaxNumber,
                          mono = {raUnderline}),
    srValueString: fgOnly(dgValueKind, dtColorsEditorSyntaxString,
                          mono = {raItalic}),
    srValueBoolean: fgOnly(dgValueKind, dtColorsEditorSyntaxKeyword,
                           mono = {raBold}),
    srValuePointer: fgOnly(dgValueKind, dtColorsEditorSyntaxType,
                           mono = {raBold, raUnderline}),
    srValueCompound: fgOnly(dgValueKind, dtColorsEditorSyntaxParameter,
                            mono = {raBold, raItalic}),
    srValueNoneValue: fgOnly(dgValueKind, dtColorsEditorSyntaxTertiary,
                             mono = {raItalic, raUnderline}),
    srValueError: fgOnly(dgValueKind, dtColorsEditorSyntaxError,
                         mono = {raBold, raItalic, raUnderline}),
    srValueOpaque: fgOnly(dgValueKind, dtColorsEditorSyntaxTertiary,
                          mono = {raItalic, raUnderline}),
    srValueMedia: fgOnly(dgValueKind, dtColorsEditorSyntaxFunction,
                         mono = {raReverse}),
    srValueDefault: fgOnly(dgValueKind, dtColorsEditorSyntaxPrimary),

    # THE SYNTAX COLOURS ARE THE DESKTOP'S MONACO THEME'S (PLAT-47): each
    # class through `editor_theme.TokenClassScope` to the rule Monaco applies
    # to the same scope. No weight or slant on the colour rungs — the theme's
    # rules carry no `fontStyle`, so the desktop draws every token upright at
    # normal weight; the monochrome attributes are CTUI-11's and stay.
    srSyntaxPlain: fgOnly(dgSyntax, tokenClassToken(tcPlain)),
    srSyntaxIdentifier: fgOnly(dgSyntax, tokenClassToken(tcIdentifier)),
    srSyntaxKeyword: fgOnly(dgSyntax, tokenClassToken(tcKeyword),
                            mono = {raBold}),
    srSyntaxType: fgOnly(dgSyntax, tokenClassToken(tcType),
                         mono = {raBold, raItalic}),
    srSyntaxString: fgOnly(dgSyntax, tokenClassToken(tcString),
                           mono = {raItalic}),
    srSyntaxNumber: fgOnly(dgSyntax, tokenClassToken(tcNumber),
                           mono = {raUnderline}),
    srSyntaxComment: fgOnly(dgSyntax, tokenClassToken(tcComment),
                            mono = {raItalic, raUnderline}),
    srSyntaxOperator: fgOnly(dgSyntax, tokenClassToken(tcOperator),
                             mono = {raBold, raUnderline}),
    srSyntaxPunctuation: fgOnly(dgSyntax, tokenClassToken(tcPunctuation),
                                mono = {raBold, raItalic, raUnderline}),
    # The three scopes the desktop's Monaco Python tokenizer colours on their
    # own. Monochrome has no attribute combination left for them, so each
    # takes the attributes of the class it is a part of — a string's quote
    # the string's, a bracket the punctuation's, a decorator the keyword's —
    # and `degradation.PermittedMerges` says so, pair by pair.
    srSyntaxStringEscape: fgOnly(dgSyntax, tokenClassToken(tcStringEscape),
                                 mono = {raItalic}),
    srSyntaxBracket: fgOnly(dgSyntax, tokenClassToken(tcBracket),
                            mono = {raBold, raItalic, raUnderline}),
    srSyntaxTag: fgOnly(dgSyntax, tokenClassToken(tcTag),
                        mono = {raBold}),
    # PLAT-47 B4: the scopes the desktop's other Monaco tokenizers colour on
    # their own. Monochrome has no attribute combination left for them either,
    # so each takes the attributes of the class it is a kind of, and
    # `degradation.PermittedMerges` names each pair.
    srSyntaxTypeIdentifier: fgOnly(dgSyntax, tokenClassToken(tcTypeIdentifier),
                                   mono = {raBold, raItalic}),
    srSyntaxKeywordType: fgOnly(dgSyntax, tokenClassToken(tcKeywordType),
                                mono = {raBold, raItalic}),
    srSyntaxCommentDoc: fgOnly(dgSyntax, tokenClassToken(tcCommentDoc),
                               mono = {raItalic, raUnderline}),
    srSyntaxRegexp: fgOnly(dgSyntax, tokenClassToken(tcRegexp),
                           mono = {raItalic}),
    srSyntaxVariable: fgOnly(dgSyntax, tokenClassToken(tcVariable)),
    srSyntaxNamespace: fgOnly(dgSyntax, tokenClassToken(tcNamespace),
                              mono = {raBold, raItalic}),
    srSyntaxAttributeName: fgOnly(dgSyntax, tokenClassToken(tcAttributeName),
                                  mono = {raBold, raUnderline}),
    srSyntaxMetatag: fgOnly(dgSyntax, tokenClassToken(tcMetatag),
                            mono = {raBold}),

    srTimelineTrack: fgOnly(dgTimeline, dtColorsUiDividerSecondary,
                            mono = {raItalic}),
    srTimelineSpan: fgOnly(dgTimeline, dtColorsUiBorderAction),
    srTimelineMark: fgOnly(dgTimeline, dtColorsEditorActionSecondary,
                           attrs = {raBold}, mono = {raBold}),
    srTimelineNeedle: fgOnly(dgTimeline, dtColorsEditorActionPrimary,
                             attrs = {raBold}, mono = {raBold, raUnderline}),
    srTimelineBounds: fgOnly(dgTimeline, dtColorsUiTextPrimaryLabel,
                             attrs = {raBold}, mono = {raBold, raItalic}),

    srEventOutput: fgOnly(dgEvent, dtColorsUiTextSuccessPrimary),
    srEventMutation: fgOnly(dgEvent, dtColorsUiTextWarningPrimary,
                            mono = {raUnderline}),
    srEventSyscall: fgOnly(dgEvent, dtColorsUiTextInformationPrimary,
                           mono = {raItalic}),
    srEventFault: fgOnly(dgEvent, dtColorsUiTextErrorPrimary,
                         attrs = {raBold}, mono = {raBold, raUnderline}),
    srEventTracepoint: fgOnly(dgEvent, dtColorsEditorSyntaxKeyword,
                              mono = {raBold}),
    srEventUnknown: fgOnly(dgEvent, dtColorsUiTextPrimaryCaptionSubtle,
                           mono = {raItalic, raUnderline}),

    srBuildIdle: fgOnly(dgBuild, dtColorsUiTextPrimaryCaptionSubtle,
                        attrs = {raBold}, mono = {raItalic}),
    srBuildRunning: fgOnly(dgBuild, dtColorsUiTextInformationPrimary,
                           attrs = {raBold}, mono = {raBold, raItalic}),
    srBuildSucceeded: fgOnly(dgBuild, dtColorsUiTextSuccessPrimary,
                             attrs = {raBold}, mono = {raBold}),
    srBuildFailed: fgOnly(dgBuild, dtColorsUiTextErrorPrimary,
                          attrs = {raBold}, mono = {raBold, raUnderline}),
    srBuildCancelled: fgOnly(dgBuild, dtColorsUiTextWarningPrimary,
                             attrs = {raBold}, mono = {raUnderline}),

    srModeDebug: fgOnly(dgMode, dtColorsUiTextPrimaryBody),
    srModeEdit: fgOnly(dgMode, dtColorsEditorActionSecondary,
                       mono = {raUnderline}),
    srModeNormal: fgOnly(dgMode, dtColorsUiTextSuccessPrimary,
                         attrs = {raBold}, mono = {raBold}),
    srModeCommand: fgOnly(dgMode, dtColorsUiTextWarningPrimary,
                          attrs = {raBold}, mono = {raBold, raUnderline}),
    srModeSearch: fgOnly(dgMode, dtColorsEditorSyntaxKeyword,
                         attrs = {raBold}, mono = {raBold, raItalic}),
    srModeInspect: fgOnly(dgMode, dtColorsUiTextInformationPrimary,
                          attrs = {raBold}, mono = {raItalic, raUnderline}),
    srModeVisual: fgOnly(dgMode, dtColorsUiBorderFocus,
                         attrs = {raBold}, mono = {raBold, raReverse}),
    srModeSeek: fgOnly(dgMode, dtColorsEditorActionPrimary,
                       attrs = {raBold},
                       mono = {raBold, raItalic, raUnderline}),

    srFrameGroupMarker: fgOnly(dgFrame, dtColorsEditorSyntaxKeyword,
                               attrs = {raBold}, mono = {raBold}),
    srFrameUserBadge: fgOnly(dgFrame, dtColorsUiTextSuccessPrimary,
                             mono = {raUnderline}),
    srFrameLibrary: fgOnly(dgFrame, dtColorsUiTextPrimaryCaptionSubtle,
                           mono = {raItalic}),
    srFrameLocation: fgOnly(dgFrame, dtColorsUiTextInformationPrimary,
                            mono = {raItalic, raUnderline}),

    # NO SEQUENTIAL (HEAT) SCALE EXISTS in the design system (filed:
    # codetracer-specs/issues/2026-09-26-design-system-no-heat-scale.md). The
    # six levels climb the editor syntax palette from subtle through the error,
    # parameter and string hues to the action highlight and the primary text,
    # which is the cold-to-hot order the ANSI ramp this replaces had.
    srHeat0: fgOnly(dgHeat, dtColorsEditorSyntaxTertiary, mono = {raItalic}),
    srHeat1: fgOnly(dgHeat, dtColorsEditorSyntaxError),
    srHeat2: fgOnly(dgHeat, dtColorsEditorSyntaxParameter,
                    mono = {raUnderline}),
    srHeat3: fgOnly(dgHeat, dtColorsEditorSyntaxString,
                    mono = {raBold, raItalic}),
    srHeat4: fgOnly(dgHeat, dtColorsEditorActionSecondary,
                    mono = {raBold, raUnderline}),
    srHeat5: fgOnly(dgHeat, dtColorsEditorSyntaxPrimary, attrs = {raBold},
                    mono = {raBold, raReverse}),

    # PLAT-52. The track is a divider line; the thumb the scrollbar thumb's
    # colour (the desktop's `::-webkit-scrollbar-thumb` reads the subtle
    # caption tone); the mark the execution pointer's (the gutter's) colour.
    srScrubberTrack: fgOnly(dgScrubber, dtColorsUiDividerSecondary,
                            mono = {raItalic}),
    srScrubberThumb: fgOnly(dgScrubber, dtColorsUiTextPrimaryCaptionSubtle,
                            mono = {raReverse}),
    srScrubberThumbGround: bgOnly(dgScrubber,
                                  dtColorsUiTextPrimaryCaptionSubtle,
                                  mono = {raReverse, raItalic}),
    srScrubberMark: fgOnly(dgScrubber, dtColorsEditorActionSecondary,
                           attrs = {raBold}, mono = {raBold, raUnderline})]

func spec*(role: SemanticRole): RoleSpec {.inline.} =
  RoleSpecs[role]

func groupOf*(role: SemanticRole): DistinctionGroup =
  ## Which set of states this role belongs to.
  RoleSpecs[role].group

func isSurface*(role: SemanticRole): bool =
  ## Whether the role paints a background.
  RoleSpecs[role].hasBg

func tokenHex*(token: DesignToken; mode: DesignMode): string =
  ## The resolved `#rrggbb` of one design-system token in one mode.
  DesignTokenHex[token][mode]

func dividerLineRole*(choice: DividerChoice): SemanticRole =
  ## The role a body-row divider's line is drawn in, for a `--dividers`
  ## choice.
  case choice
  of dcStrip: srDividerStrip
  of dcSubtle: srBorderPane
