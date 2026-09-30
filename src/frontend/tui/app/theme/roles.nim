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

    # ---- dgBorder: box drawing ---------------------------------------------
    srBorderPane = "border-pane"
    srBorderFocused = "border-focused"

    # ---- dgTab: tab strips ------------------------------------------------
    srTabBar = "tab-bar"
    srTabActive = "tab-active"
    srTabInactive = "tab-inactive"

    # ---- dgSurface: what a region's cells are filled with ------------------
    srSurfaceCanvas = "surface-canvas"
    srSurfacePanel = "surface-panel"
    srSurfaceCard = "surface-card"
    srSurfaceEditor = "surface-editor"
    srSurfaceStatusLine = "surface-status-line"
    srSurfaceInput = "surface-input"
    srSurfaceSelection = "surface-selection"
    srSurfaceCurrentLine = "surface-current-line"
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
    srValueModifiedTag = "value-modified-tag"

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
    srBorderFocused: fgOnly(dgBorder, dtColorsUiBorderPrimary,
                            mono = {raBold}),

    # The desktop's GoldenLayout strip, MEASURED (PLAT-47): the strip and
    # every tab sit on the pane's own ui/surface/base/panel — the header is
    # transparent over the panel, so an inactive tab and the strip's empty
    # run read #282828 exactly as the active tab does — and the tabs are told
    # apart by their text: the active tab in the label tier, the others in
    # the disabled tier (`components/golden_layout.styl`, `.lm_tab` /
    # `.lm_active` / `.lm_title`). The terminal adds BOLD to the active tab,
    # its weight cue; where colour is unavailable the active tab is reverse
    # video + bold (CTUI-11), never brackets.
    srTabBar: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,
                   dtColorsUiSurfaceBasePanel, baseSurface = true),
    srTabActive: fgbg(dgTab, dtColorsUiTextPrimaryLabel,
                      dtColorsUiSurfaceBasePanel, attrs = {raBold},
                      mono = {raBold, raReverse}, baseSurface = true),
    srTabInactive: fgbg(dgTab, dtColorsUiTextPrimaryDisabled,
                        dtColorsUiSurfaceBasePanel, baseSurface = true),

    srSurfaceCanvas: fgbg(dgSurface, dtColorsUiTextPrimaryBody,
                          dtColorsUiSurfaceBaseCanvas, baseSurface = true),
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
    srSurfaceSelection: bgOnly(dgSurface, dtEditorThemeSelection,
                               mono = {raReverse}),
    srSurfaceCurrentLine: bgOnly(dgSurface, dtEditorThemeExecutionLine,
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
    srValueModified: fgOnly(dgValue, dtColorsUiTextSuccessPrimary,
                            attrs = {raBold}, mono = {raBold, raUnderline}),
    srValueModifiedTag: fgbg(dgValue, dtColorsUiTextOnActionPrimary,
                             dtColorsUiSurfaceAlertSuccess, attrs = {raBold},
                             mono = {raBold, raReverse}),

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
                    mono = {raBold, raReverse})]

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
