## viewmodel/views/agent_harbor_palette.nim — CTF-P1b. The design-system
## roles the Agent Harbor views of every native front-end paint with, resolved
## for one colour mode.
##
## The web prototypes take each colour from a stylesheet role
## (`styles/components/agent_harbor.styl`, `session_tabs.styl`); a native
## front-end has no stylesheet, so each role the stylesheet names is resolved
## here, once, from the same generated tokens
## (`styles/generated/design_tokens.nim`), in either mode the design system
## publishes. GPUI (`gpui/agent_harbor/ah_theme.nim`) and the terminal
## (`tui/agent_harbor/ah_tui_canvas.nim`) both read it, so the two cannot
## resolve a role differently. It renders nothing and imports no renderer
## (the `agent_harbor_words` pattern).
##
## Colours are `#rrggbb` spellings; `selectedTint` in Dark is `#rrggbbaa`
## (the stylesheet's translucent tint), which a renderer without alpha blends
## over the panel itself.

import std/[algorithm, math, strutils]
import ../../styles/generated/design_tokens
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_items,
                                                  progress_pie]

export design_tokens, progress_pie

type
  AhPalette* = object
    ## The design-system roles the Agent Harbor views use, resolved for one
    ## colour mode. Named after the role (`colors-ui-…`) they hold.
    mode*: DesignMode
    ground*: string          ## surface/primary/default: the caption bar, the window
    panel*: string           ## surface/base/panel
    hover*: string           ## surface/primary/secondary-hover: active tab, selected row
    tertiary*: string        ## surface/primary/tertiary
    secondary*: string       ## surface/primary/secondary: a Retry button
    menu*: string            ## surface/base/card: a dropdown
    action*: string          ## surface/action/primary: the active recording
    onAction*: string        ## text/on-action/primary
    textBody*: string
    textBodySubtle*: string  ## a row's age (`.ah-fleet-row-age`, `.ah-session-row-age`)
    textCaption*: string
    textLabel*: string
    textDisabled*: string
    editedOut*: string
      ## A context item the operator left out of an instruction (the
      ## composer's uncited chip, struck through): the caption-subtle role
      ## (`text/primary/caption-subtle`, `agent_harbor_composer.styl`). In
      ## Light the disabled role (#727272, 4.46:1 on the sheet) is no dimmer
      ## than an offered chip's caption (#7a756a, 4.25:1), so a left-out item
      ## read as offered; caption-subtle (#999180, 2.90:1) is a step under it,
      ## as the disabled role is in Dark, where caption-subtle is the same
      ## grey (#727272). P2c study, manager note 122.
    textWarning*: string
    textSuccess*: string
    textError*: string
    borderSecondary*: string ## the hairline between sections
    borderPrimary*: string   ## a dropdown's border
    borderAction*: string
    borderError*: string     ## a failed recording's outline (Dark)
    iconWarning*: string
    iconSuccess*: string
    iconError*: string
    iconInfo*: string
    textInfo*: string
      ## text/information/primary: the `link` role's own ink, before a
      ## ground (`linkInk` resolves it per ground).
    iconSubtle*: string      ## icon/primary/subtle
    endedMark*: string
      ## An ended session's, initiative's or fleet row's grey mark:
      ## `by-mode(colors-ui-icon-primary-subtle,
      ## colors-ui-icon-primary-default-hover)` (`agent_harbor.styl`). Light's
      ## icon-subtle (#999180) fell to 1.42:1 on the active tab (#b5ae9f) and
      ## 2.42:1 on the panel; #4e4b45 keeps 3:1 (WCAG 1.4.11, a graphical
      ## object) on every Light surface a mark sits on. Dark keeps its role.
    timelineAdded*: string
      ## The session activity timeline's added count (`+40`):
      ## `by-mode(colors-ui-text-success-primary,
      ## colors-ui-text-success-primary-hover)`. Light's success text
      ## (#16a34a) measures 2.55:1 on the panel; its hover step keeps the 3:1
      ## the timeline holds a status role to (WCAG 1.4.11). Dark keeps its role.
    timelineWarning*: string
      ## The timeline's unanswered question: `by-mode(colors-ui-text-warning-primary,
      ## colors-ui-text-warning-primary-hover)`, Light's warning text (#ea580c)
      ## being 2.76:1 on the panel.
    endedWord*: string
      ## An ended session's status word (`completed`):
      ## `by-mode(caption, label)`. Light's caption (#7a756a) fell to 2.59:1
      ## on the raised row (#c8c2b5); the label role keeps 4.5:1 (WCAG 1.4.3)
      ## on every Light surface a row sits on, as the row's quiet text does
      ## on selection (`activeRowQuiet`).
    iconDefault*: string     ## the hollow ring of an idle session
    trackPlanned*: string    ## the milestone bar's planned segment (`by-mode`)
    tabIcon*: string
      ## A frame tab's pin and close icons: `TAB_ICON_COLOR`, the
      ## icon-subtle role (#919191 / #999180), as the masks are painted.
    activeTab*: string
      ## The active tab, the active session row and the active item of a
      ## tab dropdown: `by-mode(#3c3c3c, colors-ui-surface-primary-tertiary)`
      ## (`session_tabs.styl`, `agent_harbor.styl`).
    activeRow*: string
      ## The active session row: `#3c3c3c` in Dark as the tab; in Light the
      ## secondary-hover surface the browser draws it on (measured: #c8c2b5).
    activeTabText*: string   ## its title: `by-mode(#ffffff, text-primary-body)`
    activeTabOrigin*: string ## its origin: `by-mode(#b0b0b0, text-primary-caption)`
    activeRowQuiet*: string
      ## The active session row's meta and detail: `by-mode(caption, label)`
      ## (Light's tertiary is too dark for the caption role). Its status word
      ## keeps its status colour.
    rowDetail*: string
      ## Any session row's detail line, and a fleet row's activity line:
      ## `by-mode(caption, label)` -- on Light's warm panel the caption role
      ## sits near 3:1 under a title.
    addText*: string         ## "+": `by-mode(#b0b0b0, text-primary-label)`
    selectedTint*: string
      ## A selection tint: `by-mode(rgba(surface-action-primary, 0.28),
      ## surface-primary-secondary-hover)`, as `#rrggbbaa` (the changes
      ## inbox's selection and the composer's cited line; a list's selected
      ## row uses `activeRow`).

  MarkStyle* = object
    ## A status mark: a filled dot, or a hollow ring (idle, planned).
    colour*: string
    ring*: bool
    role*: PieRole
      ## The status role the mark draws (`markOf`), so a view can resolve
      ## its ink for the ground under it (`markOn`); read only when `roled`.
    roled*: bool
      ## Whether `role` is set: false for a mark with no status role (the
      ## auto-switch dot, a milestone's planned or other mark).

proc ahPalette*(mode: DesignMode): AhPalette =
  template t(token: DesignToken): string = DesignTokenHex[token][mode]
  AhPalette(
    mode: mode,
    ground: t(dtColorsUiSurfacePrimaryDefault),
    panel: t(dtColorsUiSurfaceBasePanel),
    hover: t(dtColorsUiSurfacePrimarySecondaryHover),
    tertiary: t(dtColorsUiSurfacePrimaryTertiary),
    secondary: t(dtColorsUiSurfacePrimarySecondary),
    menu: t(dtColorsUiSurfaceBaseCard),
    action: t(dtColorsUiSurfaceActionPrimary),
    onAction: t(dtColorsUiTextOnActionPrimary),
    textBody: t(dtColorsUiTextPrimaryBody),
    textBodySubtle: t(dtColorsUiTextPrimaryBodySubtle),
    textCaption: t(dtColorsUiTextPrimaryCaption),
    textLabel: t(dtColorsUiTextPrimaryLabel),
    textDisabled: t(dtColorsUiTextPrimaryDisabled),
    editedOut: t(dtColorsUiTextPrimaryCaptionSubtle),
    textWarning: t(dtColorsUiTextWarningPrimary),
    textSuccess: t(dtColorsUiTextSuccessPrimary),
    textError: t(dtColorsUiTextErrorPrimary),
    borderSecondary: t(dtColorsUiBorderSecondary),
    borderPrimary: t(dtColorsUiBorderPrimary),
    borderAction: t(dtColorsUiBorderAction),
    borderError: t(dtColorsUiBorderError),
    iconWarning: t(dtColorsUiIconWarningPrimary),
    iconSuccess: t(dtColorsUiIconSuccessPrimary),
    iconError: t(dtColorsUiIconErrorPrimary),
    iconInfo: t(dtColorsUiIconInformationPrimary),
    textInfo: t(dtColorsUiTextInformationPrimary),
    iconSubtle: t(dtColorsUiIconPrimarySubtle),
    endedMark: (if mode == dmDark: t(dtColorsUiIconPrimarySubtle)
                else: t(dtColorsUiIconPrimaryDefaultHover)),
    timelineAdded: (if mode == dmDark: t(dtColorsUiTextSuccessPrimary)
                    else: t(dtColorsUiTextSuccessPrimaryHover)),
    timelineWarning: (if mode == dmDark: t(dtColorsUiTextWarningPrimary)
                      else: t(dtColorsUiTextWarningPrimaryHover)),
    endedWord: (if mode == dmDark: t(dtColorsUiTextPrimaryCaption)
                else: t(dtColorsUiTextPrimaryLabel)),
    iconDefault: t(dtColorsUiIconPrimaryDefault),
    # The stylesheet's last word on planned (`agent_harbor.styl`, "Planned
    # in Dark: a mark the eye finds"): the mark and the bar's segment both
    # `by-mode(colors-ui-icon-primary-subtle, colors-ui-border-primary)`,
    # filled.
    trackPlanned: (if mode == dmDark: t(dtColorsUiIconPrimarySubtle)
                   else: t(dtColorsUiBorderPrimary)),
    tabIcon: t(dtColorsUiIconPrimarySubtle),
    # The stylesheet's own literals for Dark, where it states one (`by-mode`
    # with a hex): the design system has no role for these greys.
    activeTab: (if mode == dmDark: "#3c3c3c" else: t(dtColorsUiSurfacePrimaryTertiary)),
    activeRow: (if mode == dmDark: "#3c3c3c" else: t(dtColorsUiSurfacePrimarySecondaryHover)),
    activeTabText: (if mode == dmDark: "#ffffff" else: t(dtColorsUiTextPrimaryBody)),
    activeTabOrigin: (if mode == dmDark: "#b0b0b0" else: t(dtColorsUiTextPrimaryCaption)),
    activeRowQuiet: (if mode == dmDark: t(dtColorsUiTextPrimaryCaption)
                     else: t(dtColorsUiTextPrimaryLabel)),
    rowDetail: (if mode == dmDark: t(dtColorsUiTextPrimaryCaption)
                else: t(dtColorsUiTextPrimaryLabel)),
    addText: (if mode == dmDark: "#b0b0b0" else: t(dtColorsUiTextPrimaryLabel)),
    # 0.28 of 255 is 71.4: alpha 0x47.
    selectedTint: (if mode == dmDark: t(dtColorsUiSurfaceActionPrimary) & "47"
                   else: t(dtColorsUiSurfacePrimarySecondaryHover)))

proc inboxStepInk*(p: AhPalette; disabled: bool): string =
  ## The inbox's Previous / Next (`.ah-inbox-step`): the label role while
  ## a session waits, the disabled role at full opacity while nothing does
  ## (`.ah-initiative-tab-bar .ah-inbox-empty .ah-inbox-step`). The steps
  ## wrap, so an empty inbox is the only state they are disabled in.
  if disabled: p.textDisabled else: p.textLabel

# ---------------------------------------------------------------------------
# Status colours: `agent_harbor.styl`'s `.ah-att-*`, `.ah-ist-*`, `.ah-ms-*`
# ---------------------------------------------------------------------------

proc markOf*(p: AhPalette; attention: SessionAttention): MarkStyle =
  case attention
  of saNeedsInput: MarkStyle(colour: p.iconWarning, role: prWarning, roled: true)
  of saRunning: MarkStyle(colour: p.iconSuccess, role: prSuccess, roled: true)
  of saQueued: MarkStyle(colour: p.iconInfo, role: prInfo, roled: true)
  of saFailed: MarkStyle(colour: p.iconError, role: prError, roled: true)
  of saIdle: MarkStyle(colour: p.iconDefault, ring: true, role: prIdle, roled: true)
  of saEnded: MarkStyle(colour: p.endedMark, role: prEnded, roled: true)

proc markOf*(p: AhPalette; state: InitiativeState): MarkStyle =
  case state
  of isNeedsInput: MarkStyle(colour: p.iconWarning, role: prWarning, roled: true)
  of isWorking: MarkStyle(colour: p.iconSuccess, role: prSuccess, roled: true)
  of isBlocked: MarkStyle(colour: p.iconError, role: prError, roled: true)
  of isIdle: MarkStyle(colour: p.iconDefault, ring: true, role: prIdle, roled: true)
  of isEnded: MarkStyle(colour: p.endedMark, role: prEnded, roled: true)

proc markOf*(p: AhPalette; status: MilestoneStatusClass): MarkStyle =
  case status
  of mscCompleted: MarkStyle(colour: p.iconSuccess, role: prSuccess, roled: true)
  of mscInProgress: MarkStyle(colour: p.iconInfo, role: prInfo, roled: true)
  of mscPartial: MarkStyle(colour: p.iconWarning, role: prWarning, roled: true)
  of mscBlocked: MarkStyle(colour: p.iconError, role: prError, roled: true)
  of mscPlanned: MarkStyle(colour: p.trackPlanned)
  of mscOther: MarkStyle(colour: p.iconSubtle)

proc segmentOf*(p: AhPalette; status: MilestoneStatusClass): string =
  ## A milestone bar's segment (`.ah-ms-seg.ah-ms-*`).
  if status == mscPlanned: p.trackPlanned else: p.markOf(status).colour

proc statusWordColour*(p: AhPalette; attention: SessionAttention): string =
  ## A session's status word (`.ah-att-* .ah-session-row-status`).
  case attention
  of saNeedsInput: p.textWarning
  of saRunning: p.textSuccess
  of saFailed: p.textError
  of saEnded: p.endedWord
  else: p.textLabel

proc stateWordColour*(p: AhPalette; state: InitiativeState): string =
  case state
  of isNeedsInput: p.textWarning
  of isWorking: p.textSuccess
  of isBlocked: p.textError
  else: p.textCaption

proc timelineInk*(p: AhPalette; role: string): string =
  ## The ink of a session activity timeline line's part, by the role the
  ## viewmodel gives it (`SessionTimelineVM`'s `LinePart.role`): the GPUI and
  ## terminal timelines draw with it, and `agent_harbor_activity.styl` names
  ## the same design-system roles for the web. The operator's words in the
  ## label colour (and weight), the agent's in the body colour, quiet lines
  ## (thoughts, statuses, gaps) as captions, a failure in the error colour,
  ## an unanswered question in the warning colour, a running command in the
  ## info colour, an ending in the ended word's colour, a diff's counts in
  ## the success and error colours.
  case role
  of "label": p.textLabel
  of "quiet": p.textCaption
  of "error", "removed": p.textError
  of "warning": p.timelineWarning
  of "running": p.iconInfo
  of "ended": p.endedWord
  of "added": p.timelineAdded
  else: p.textBody

# ---------------------------------------------------------------------------
# The progress pie's inks (`nim_agents_isonim_viewmodels/agent_harbor/
# progress_pie`): a ring in its state's ink, filled by a wedge of that ink
# ---------------------------------------------------------------------------
#
# A pie is drawn in one ink, its state role's full ink, on the ground it
# sits on, resolved here once for every front end:
#
# - a 1 px EDGE ring (`PieEdgePx`) in the full ink, the pie's outline;
# - inside it, past a gap of the ground (`pieRingGapPx`), a disc whose
#   WEDGE (the share done, from twelve o'clock clockwise) is filled in the
#   same full ink and whose REST is left as the ground, untinted.
#
# So 0 % is an empty ring and 100 % a full disc inside the ring, and a share
# reads as ink against the ground (3.3:1 or more), not as one shade of the
# ink against another: at 9 to 12 px a wedge 1.5:1 against a tinted rest
# made 0, 16, 84 and 100 % read as one solid dot. The state is told by the
# ink alone.
#
# The rules, measured on every ground a pie sits on in both modes:
#
# - the ink (the edge and the wedge) holds `PieInkFloor` (3.3:1) against the
#   ground: WCAG 2.2 SC 1.4.11's 3:1 for a graphical object
#   (https://www.w3.org/TR/WCAG22/#non-text-contrast) with a margin, because
#   the 1 px edge is antialiased and an ink at 3.0-3.15:1 drew edge pixels
#   at 2.7-2.9:1;
# - any two roles' inks on one ground differ by at least `PieRoleDeltaE`
#   (20) in CIEDE2000 (`deltaE2000`) -- every pair, idle and ended among
#   them, in every front end: the ink is all that tells two states apart;
# - warning and error, the two warm roles, also differ in luminance by
#   `PieWarningErrorContrast` (1.3:1) or more, so a one-cell terminal glyph
#   does not tell them apart by hue alone;
# - ended stays a neutral grey, `PieEndedChroma` (12) or less of CIE chroma,
#   and stands apart from idle by lightness, never by taking a hue.
#
# The roles are resolved per ground in `PieRoleOrder` (`roleInkReport`).
# Each takes, of the inks `inkCandidates` offers (its own ink, its ink moved
# toward black or white, inks around its hue at other lightness and chroma;
# for ended, its own grey at other lightness and up to 12 of chroma), the
# one nearest its own ink in CIEDE2000 that holds the floor, stands 20 from
# every earlier role's ink, and (error) 1.3:1 from warning. The ink floor,
# the 20 between inks and ended's chroma are never given up. Where no
# candidate holds the warning/error luminance with the others, the one with
# the most is taken and reported, with its best value. Where a role has no
# candidate at all, the role before it gives way: the two are chosen
# together, the pair nearest their own inks (Light's active tab: idle moves
# darker so ended, a grey lighter than it, holds 3.3:1 and stands 20 from
# it).
#
# Every adjustment is made here, per ground, never per front end, so the web
# stylesheet (`agent_harbor_pie_inks.styl`, written from `pieStylesheet`),
# GPUI and the terminal draw one pie in the same inks.
#
# A pie with NO KNOWN PROGRESS draws no wedge: its edge ring and a centred
# dot of the full ink a quarter of its diameter across, so it never reads as
# 0 % (the empty ring) or as done.

const
  PieInkFloor* = 3.3
    ## The least contrast of a pie's ink (its wedge and edge) on its ground.
  PieStepPercent* = 5
    ## The step a role's ink is moved toward black or white by.
  PieRoleDeltaE* = 20.0
    ## Any two roles' inks on one ground differ by at least this in CIEDE2000.
  PieWarningErrorContrast* = 1.3
    ## The least luminance contrast of warning's and error's inks.
  PieEndedChroma* = 12.0
    ## The most CIE chroma ended's ink has: a neutral grey.
  PieRoleOrder* = [prWarning, prSuccess, prInfo, prError, prIdle, prEnded]
    ## The order the roles' inks are resolved in on a ground: a later role
    ## gives way to an earlier one it comes too near.
  StoryTextFloor* = 4.5
    ## The least contrast of the pie story's own words (WCAG 2.2 SC 1.4.3,
    ## https://www.w3.org/TR/WCAG22/#contrast-minimum).

type
  PieGround* = enum
    ## The grounds a pie sits on: the window (the caption bar, a tab
    ## strip), a panel, the active tab, a selected row, and a menu.
    pgWindow = "window"
    pgPanel = "panel"
    pgActiveTab = "active-tab"
    pgSelectedRow = "selected-row"
    pgMenu = "menu"

  PieInks* = object
    ## The inks of one pie on one ground, as `#rrggbb`: the wedge and the
    ## edge are the role's full ink; the rest of the disc is `ground`.
    wedge*, edge*: string
    ground*: string
      ## The ground they were resolved for, which the rest is left as.

proc pieGroundColour*(p: AhPalette; ground: PieGround): string =
  ## The colour of a pie's ground in `p`'s mode.
  case ground
  of pgWindow: p.ground
  of pgPanel: p.panel
  of pgActiveTab: p.activeTab
  of pgSelectedRow: p.activeRow
  of pgMenu: p.menu

proc tabPieGround*(active: bool): PieGround =
  ## The ground a tab's pie sits on in every host: the active tab's fill,
  ## or the window (the caption bar the strips sit in) under an inactive
  ## tab.
  if active: pgActiveTab else: pgWindow

proc pieGroundShown*(p: AhPalette; ground: PieGround): bool =
  ## Whether `ground` has a colour no earlier ground (in `PieGround`'s
  ## order) has in `p`'s mode: the pie story shows each distinct ground once.
  for earlier in PieGround:
    if earlier == ground: return true
    if p.pieGroundColour(earlier) == p.pieGroundColour(ground): return false

proc hexChannels(hex: string): array[3, int] =
  ## The 8-bit channels of `#rrggbb` (the translucent `#rrggbbaa` keeps its
  ## colour; a pie's ground is never one).
  let body = if hex.startsWith("#"): hex[1 .. ^1] else: hex
  if body.len < 6:
    raise newException(ValueError, "not a #rrggbb colour: '" & hex & "'")
  for i in 0 .. 2: result[i] = parseHexInt(body[i * 2 .. i * 2 + 1])

proc inkLuminance*(hex: string): float =
  ## WCAG 2.x relative luminance of an sRGB colour
  ## (https://www.w3.org/TR/WCAG22/#dfn-relative-luminance).
  let c = hexChannels(hex)
  var linear: array[3, float]
  for i in 0 .. 2:
    let v = c[i].float / 255.0
    linear[i] = if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)
  0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

proc inkContrast*(a, b: string): float =
  ## The WCAG contrast ratio of two colours, 1 to 21
  ## (https://www.w3.org/TR/WCAG22/#dfn-contrast-ratio).
  let (la, lb) = (inkLuminance(a), inkLuminance(b))
  (max(la, lb) + 0.05) / (min(la, lb) + 0.05)

proc mixInk*(a, b: string; percentTowardB: int): string =
  ## `a` mixed `percentTowardB` % of the way toward `b`, per sRGB channel,
  ## rounded (CSS `color-mix(in srgb, …)` at those weights).
  let (x, y) = (hexChannels(a), hexChannels(b))
  let t = clamp(percentTowardB, 0, 100).float / 100.0
  result = "#"
  for i in 0 .. 2:
    result.add toHex(int(round(x[i].float * (1.0 - t) + y[i].float * t)), 2).toLowerAscii

proc roleInk*(p: AhPalette; role: PieRole): string =
  ## A role's full ink, before any ground: the status marks' colours.
  case role
  of prWarning: p.iconWarning
  of prSuccess: p.iconSuccess
  of prInfo: p.iconInfo
  of prError: p.iconError
  of prIdle: p.iconDefault
  of prEnded: p.endedMark

proc inkLab*(hex: string): array[3, float] =
  ## CIE L*a*b* (D65) of an sRGB colour
  ## (https://en.wikipedia.org/wiki/CIELAB_color_space#From_CIEXYZ_to_CIELAB).
  let c = hexChannels(hex)
  var lin: array[3, float]
  for i in 0 .. 2:
    let v = c[i].float / 255.0
    lin[i] = if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)
  let x = (0.4124 * lin[0] + 0.3576 * lin[1] + 0.1805 * lin[2]) / 0.95047
  let y = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
  let z = (0.0193 * lin[0] + 0.1192 * lin[1] + 0.9505 * lin[2]) / 1.08883
  proc f(t: float): float =
    if t > 0.008856: pow(t, 1.0 / 3.0) else: 7.787 * t + 16.0 / 116.0
  [116.0 * f(y) - 16.0, 500.0 * (f(x) - f(y)), 200.0 * (f(y) - f(z))]

proc deltaE2000Lab*(x, y: array[3, float]): float =
  ## The CIEDE2000 colour difference of two L*a*b* colours (Sharma, Wu and
  ## Dalal, "The CIEDE2000 Color-Difference Formula",
  ## https://hajim.rochester.edu/ece/sites/gsharma/ciede2000/ciede2000noteCRNA.pdf).
  let (l1, a1, b1) = (x[0], x[1], x[2])
  let (l2, a2, b2) = (y[0], y[1], y[2])
  # The paper's barred means (C-bar, L-bar', C-bar', h-bar') are spelled
  # meanChroma, meanLightness, meanChromaP and meanHue.
  let meanChroma = (hypot(a1, b1) + hypot(a2, b2)) / 2.0
  let g = 0.5 * (1.0 - sqrt(pow(meanChroma, 7) / (pow(meanChroma, 7) + pow(25.0, 7))))
  let (a1p, a2p) = ((1.0 + g) * a1, (1.0 + g) * a2)
  let (c1p, c2p) = (hypot(a1p, b1), hypot(a2p, b2))
  proc hue(bb, ap: float): float =
    result = radToDeg(arctan2(bb, ap))
    if result < 0: result += 360.0
  let (h1, h2) = (hue(b1, a1p), hue(b2, a2p))
  let dL = l2 - l1
  let dC = c2p - c1p
  var dHue = h2 - h1
  if c1p * c2p == 0: dHue = 0
  elif dHue > 180: dHue -= 360
  elif dHue < -180: dHue += 360
  let dBigH = 2.0 * sqrt(c1p * c2p) * sin(degToRad(dHue / 2.0))
  let meanLightness = (l1 + l2) / 2.0
  let meanChromaP = (c1p + c2p) / 2.0
  var meanHue = h1 + h2
  if c1p * c2p != 0:
    if abs(h1 - h2) <= 180: meanHue = (h1 + h2) / 2.0
    elif h1 + h2 < 360: meanHue = (h1 + h2 + 360.0) / 2.0
    else: meanHue = (h1 + h2 - 360.0) / 2.0
  let t = 1.0 - 0.17 * cos(degToRad(meanHue - 30)) + 0.24 * cos(degToRad(2 * meanHue)) +
          0.32 * cos(degToRad(3 * meanHue + 6)) - 0.2 * cos(degToRad(4 * meanHue - 63))
  let dTheta = 30.0 * exp(-pow((meanHue - 275.0) / 25.0, 2))
  let rc = 2.0 * sqrt(pow(meanChromaP, 7) / (pow(meanChromaP, 7) + pow(25.0, 7)))
  let sl = 1.0 + 0.015 * pow(meanLightness - 50, 2) / sqrt(20.0 + pow(meanLightness - 50, 2))
  let sc = 1.0 + 0.045 * meanChromaP
  let sh = 1.0 + 0.015 * meanChromaP * t
  let rt = -sin(degToRad(2 * dTheta)) * rc
  sqrt(pow(dL / sl, 2) + pow(dC / sc, 2) + pow(dBigH / sh, 2) + rt * (dC / sc) * (dBigH / sh))

proc deltaE2000*(a, b: string): float =
  ## The CIEDE2000 difference of two sRGB colours (`#rrggbb`).
  deltaE2000Lab(inkLab(a), inkLab(b))

proc rolesApart*(a, b: string): bool =
  ## Two roles' inks are told apart (see the section's header).
  deltaE2000(a, b) >= PieRoleDeltaE

proc inkChroma*(hex: string): float =
  ## The CIE chroma (C*ab) of an sRGB colour.
  let lab = inkLab(hex)
  hypot(lab[1], lab[2])

proc labInk*(l, a, b: float): string =
  ## The sRGB colour of a CIE L*a*b* (D65) value, or "" when it lies outside
  ## the sRGB gamut (the inverse of `inkLab`).
  let fy = (l + 16.0) / 116.0
  let fx = fy + a / 500.0
  let fz = fy - b / 200.0
  proc inv(t: float): float =
    if t * t * t > 0.008856: t * t * t else: (t - 16.0 / 116.0) / 7.787
  let (x, y, z) = (inv(fx) * 0.95047, inv(fy), inv(fz) * 1.08883)
  let lin = [3.2406 * x - 1.5372 * y - 0.4986 * z,
             -0.9689 * x + 1.8758 * y + 0.0415 * z,
             0.0557 * x - 0.2040 * y + 1.0570 * z]
  result = "#"
  for c in lin:
    if c < -0.001 or c > 1.001: return ""
    let v = clamp(c, 0.0, 1.0)
    let e = if v <= 0.0031308: 12.92 * v else: 1.055 * pow(v, 1.0 / 2.4) - 0.055
    result.add toHex(int(round(e * 255.0)), 2).toLowerAscii

proc inkCandidates*(base: string; role: PieRole): seq[string] =
  ## The inks a role may take on a ground (`roleInkReport` weighs each by its
  ## distance from `base`): `base` itself and `base` moved toward black and
  ## toward white in `PieStepPercent` steps; then, for ended, its own grey at
  ## every whole L* with up to `PieEndedChroma` of chroma in its own hue (a
  ## neutral grey, apart from idle by lightness); for any other role the
  ## in-gamut inks around its hue at other lightness (2 L* steps, within 50)
  ## and chroma (3 C* steps, within 30), its hue within 40° in 5° steps, or,
  ## for a grey (chroma under 8), its own hue with up to 24 of chroma.
  result.add base
  for step in countup(0, 100, PieStepPercent):
    result.add mixInk(base, "#000000", step)
    result.add mixInk(base, "#ffffff", step)
  let lab = inkLab(base)
  let chroma = hypot(lab[1], lab[2])
  let hue = radToDeg(arctan2(lab[2], lab[1]))
  if role == prEnded:
    for l in 0 .. 100:
      for c in countup(0, int(PieEndedChroma), 2):
        let ink = labInk(l.float, c.float * cos(degToRad(hue)), c.float * sin(degToRad(hue)))
        if ink.len > 0: result.add ink
    return
  var hues: seq[float]
  var chromas: seq[float]
  if chroma > 8.0:
    for d in countup(-40, 40, 5): hues.add hue + d.float
    for c in countup(max(0, int(chroma) - 30), int(chroma) + 30, 3): chromas.add c.float
  else:
    hues.add hue
    for c in countup(0, 24, 2): chromas.add c.float
  for l in countup(int(lab[0]) - 50, int(lab[0]) + 50, 2):
    if l < 0 or l > 100: continue
    for c in chromas:
      for h in hues:
        let ink = labInk(l.float, c * cos(degToRad(h)), c * sin(degToRad(h)))
        if ink.len > 0: result.add ink

type
  RoleShortfall* = object
    ## A soft rule a role's ink could not meet on a ground, and the best
    ## value it reached.
    role*: PieRole
    rule*: string     ## "warning-error" (`PieWarningErrorContrast`)
    best*: float

  RoleInkReport* = object
    ## How a ground's role inks were resolved: the inks, the soft rules a
    ## role fell short of (`shortOf`, each with its best value), the hard
    ## rules nothing met (`unmet`: the role keeps its own ink), and the roles
    ## that gave way to a later one (`gaveWay`).
    inks*: array[PieRole, string]
    shortOf*: seq[RoleShortfall]
    unmet*: seq[PieRole]
    gaveWay*: seq[PieRole]

  InkPick = object
    ink: string
    tier: int         ## 0 every rule; 1 short of warning/error
    score: float      ## within a tier, lower is better
    best: float       ## the luminance contrast reached

var roleInkMemo: seq[(string, RoleInkReport)]
  ## `roleInkReport` is a pure function of its inputs and costs a search;
  ## its answers are kept, keyed by the palette's role inks and the ground.

proc inkPicks(p: AhPalette; ground: string; role: PieRole; earlier: openArray[PieRole];
              inks: array[PieRole, string]): seq[InkPick] =
  ## Every ink `role` may take on `ground` against the `earlier` roles'
  ## `inks`, best first: those that hold the hard rules (the ink floor, 20
  ## from every earlier ink, ended's chroma), by tier, then nearest the
  ## role's own ink (tier 0) or the most warning/error contrast (tier 1).
  let base = p.roleInk(role)
  for ink in inkCandidates(base, role):
    if inkContrast(ink, ground) < PieInkFloor: continue
    if role == prEnded and inkChroma(ink) > PieEndedChroma: continue
    var apart = true
    for other in earlier:
      if deltaE2000(ink, inks[other]) < PieRoleDeltaE:
        apart = false
        break
    if not apart: continue
    let lum = if role == prError and prWarning in earlier: inkContrast(ink, inks[prWarning])
              else: Inf
    if lum < PieWarningErrorContrast:
      result.add InkPick(ink: ink, tier: 1, score: -lum, best: lum)
    else:
      result.add InkPick(ink: ink, tier: 0, score: deltaE2000(ink, base))
  result.sort(proc (a, b: InkPick): int = cmp((a.tier, a.score), (b.tier, b.score)))

proc roleInkReport*(p: AhPalette; ground: string): RoleInkReport =
  ## Every role's full ink on `ground` (see the section's header).
  var key = ground
  for role in PieRole: key.add "|" & p.roleInk(role)
  for (k, v) in roleInkMemo:
    if k == key: return v
  var earlier: seq[PieRole]
  proc take(r: var RoleInkReport; role: PieRole; pick: InkPick) =
    r.inks[role] = pick.ink
    if pick.tier == 1:
      r.shortOf.add RoleShortfall(role: role, rule: "warning-error", best: pick.best)
  for k, role in PieRoleOrder:
    let picks = p.inkPicks(ground, role, earlier, result.inks)
    if picks.len > 0:
      result.take(role, picks[0])
    elif k > 0:
      # The role before gives way: the two are chosen together, of the
      # previous role's picks against the roles before it and this role's
      # against all but the previous one, the pair that stands 20 apart at
      # the best tier, nearest their own inks.
      let prev = PieRoleOrder[k - 1]
      let before = earlier[0 ..< earlier.len - 1]
      let prevPicks = p.inkPicks(ground, prev, before, result.inks)
      let mine = p.inkPicks(ground, role, before, result.inks)
      var best = (99, Inf, -1, -1)
      for i, a in prevPicks:
        if a.tier > best[0]: break
        for j, b in mine:
          if max(a.tier, b.tier) > best[0]: break
          if deltaE2000(a.ink, b.ink) < PieRoleDeltaE: continue
          let cost = deltaE2000(a.ink, p.roleInk(prev)) + deltaE2000(b.ink, p.roleInk(role))
          if (max(a.tier, b.tier), cost) < (best[0], best[1]):
            best = (max(a.tier, b.tier), cost, i, j)
      if best[2] >= 0:
        # Re-taken: drop what the previous role reported for its first pick.
        var kept: seq[RoleShortfall]
        for s in result.shortOf:
          if s.role != prev: kept.add s
        result.shortOf = kept
        result.take(prev, prevPicks[best[2]])
        result.take(role, mine[best[3]])
        result.gaveWay.add prev
      else:
        result.inks[role] = p.roleInk(role)
        result.unmet.add role
    else:
      result.inks[role] = p.roleInk(role)
      result.unmet.add role
    earlier.add role
  roleInkMemo.add (key, result)

proc roleInks*(p: AhPalette; ground: string): array[PieRole, string] =
  ## Every role's full ink on `ground` (`roleInkReport`).
  p.roleInkReport(ground).inks

proc pieInks*(p: AhPalette; role: PieRole; ground: string): PieInks =
  ## The inks of a `role` pie on `ground` (`#rrggbb`), meeting the rules
  ## (see the section's header): the wedge and the edge in the role's ink,
  ## the rest left as the ground.
  let ink = p.roleInks(ground)[role]
  PieInks(wedge: ink, edge: ink, ground: ground)

proc readableInk*(p: AhPalette; ground: string; floor = StoryTextFloor): string =
  ## The quietest of the text roles (caption, label, body) that holds
  ## `floor` on `ground`; the one with the most contrast when none does.
  var most = ""
  for ink in [p.textCaption, p.textLabel, p.textBody]:
    if inkContrast(ink, ground) >= floor: return ink
    if most.len == 0 or inkContrast(ink, ground) > inkContrast(most, ground): most = ink
  most

proc pieInks*(p: AhPalette; role: PieRole; ground: PieGround): PieInks =
  p.pieInks(role, p.pieGroundColour(ground))

# ---------------------------------------------------------------------------
# Status inks on a ground: a status word, a status count and a status mark
# readable on the ground they are drawn on
# ---------------------------------------------------------------------------
#
# The design system's status roles (`colors-ui-text-<status>-primary`,
# `colors-ui-icon-<status>-primary`) are measured against its own surfaces;
# on Light's warm grounds they fall under the floors (the terminal review of
# the initiative tab bar, 2026-11-26: the warning dot 1.61:1 on the open
# `+N` chip's #b5ae9f, the error banner 3.34:1 and the menus' status words
# and dots 2.0-2.5:1 on the card #dbd6cc and on #c8c2b5). Each is resolved
# here, per ground, by one rule for every view that draws on such a ground:
#
# - a status WORD or COUNT is text: WCAG 2.2 SC 1.4.3, 4.5:1
#   (https://www.w3.org/TR/WCAG22/#contrast-minimum). It takes the role's
#   text step where that holds, else its hover step (the 700 step), else
#   that step taken `StatusInkStepPercent` at a time toward the body text
#   (`statusTextInk`): only tokens, mixed in code, as `buttonStateInk` mixes
#   orange/700 toward the body for orange/800 (the Nim design-token table
#   carries no 800 step);
# - a status MARK (the one-cell dot) is a graphical object: SC 1.4.11, 3:1
#   (https://www.w3.org/TR/WCAG22/#non-text-contrast). It keeps the role's
#   icon ink where that holds, else it takes the pie's ink for its role on
#   that ground (`roleInks`, 3.3:1 and 20 CIEDE2000 from every other role),
#   so a pie and a dot of one role on one ground are one ink (`markOn`).
#
# Dark's roles hold both floors on every Dark ground the views use, so Dark
# draws the roles themselves.

const
  StatusTextFloor* = 4.5
    ## A status word's or count's least contrast on its ground (SC 1.4.3).
  StatusMarkFloor* = 3.0
    ## A status mark's least contrast on its ground (SC 1.4.11).
  StatusInkStepPercent* = 25
    ## The step a status role's hover ink is taken toward the body text by.

proc statusTextSteps(p: AhPalette; role: PieRole): (string, string) =
  ## A status role's text step and its hover (700) step; a role with no
  ## status text (idle, ended) has the label role for both.
  template t(token: DesignToken): string = DesignTokenHex[token][p.mode]
  case role
  of prWarning: (t(dtColorsUiTextWarningPrimary), t(dtColorsUiTextWarningPrimaryHover))
  of prSuccess: (t(dtColorsUiTextSuccessPrimary), t(dtColorsUiTextSuccessPrimaryHover))
  of prInfo: (t(dtColorsUiTextInformationPrimary), t(dtColorsUiTextInformationPrimaryHover))
  of prError: (t(dtColorsUiTextErrorPrimary), t(dtColorsUiTextErrorPrimaryHover))
  of prIdle, prEnded: (p.textLabel, p.textLabel)

proc statusTextInk*(p: AhPalette; role: PieRole; ground: string;
                    floor = StatusTextFloor): string =
  ## A status word or count of `role` readable on `ground` (see the
  ## section's header): the role's text step, else its hover step, else the
  ## hover step taken toward the body text a `StatusInkStepPercent` step at
  ## a time, the first that holds `floor`; the body text when none does.
  let (primary, hover) = p.statusTextSteps(role)
  if inkContrast(primary, ground) >= floor: return primary
  var step = 0
  while step < 100:
    let ink = mixInk(hover, p.textBody, step)
    if inkContrast(ink, ground) >= floor: return ink
    step += StatusInkStepPercent
  p.textBody

proc markOn*(p: AhPalette; m: MarkStyle; ground: string): MarkStyle =
  ## `m` readable on `ground` (see the section's header): as it is when its
  ## ink holds `StatusMarkFloor` there or it has no status role, else in the
  ## pie's ink for its role on that ground.
  result = m
  if m.roled and inkContrast(m.colour, ground) < StatusMarkFloor:
    result.colour = p.roleInks(ground)[m.role]

type
  PieShape* = enum
    ## How a pie is drawn, whatever its role and inks.
    psRing = "ring"       ## the edge ring, the wedge filled inside it
    psUnknown = "unknown" ## no known progress: the edge ring and a dot

proc pieShapeOf*(pie: ProgressPie): PieShape =
  ## Every role is a ring with its wedge inside; no known progress draws
  ## the ring and a dot instead.
  if pie.known: psRing else: psUnknown

const
  PieEdgePx* = 1
    ## The edge ring's width.
  PieRingGapStepPx* = 12
    ## The ground between the ring and the wedge's disc is one whole pixel
    ## for every this many pixels of diameter (`pieRingGapPx`).
  PieLinePx* = 12
    ## A pie on a line, a row or the initiative popup: sidebar lines,
    ## initiatives-tree lines, fleet rows (the web and GPUI; the terminal's
    ## pie is one cell everywhere).
  PieTabPx* = 10
    ## A pie in a tab, a menu or a `+N` chip.
  PieCaptionPx* = 16
    ## The caption bar's pie (CodeTracer's own agent tab).
  PieDotFraction* = 1.0 / 4.0
    ## An unknown pie's dot: this share of the diameter, centred -- a quarter,
    ## so at native size it stays well short of the wedge's disc (8 px of a
    ## 12 px pie) and a whole pie and an unknown one never read alike.

proc pieRingGapPx*(sizePx: int): int =
  ## The ground between a `sizePx` pie's ring and its wedge's disc, in whole
  ## pixels so neither edge is smeared over a half pixel: 1 px from 12 px up
  ## (2 px from 24 px), none under 12 px, where every pixel of the disc is
  ## needed for a small share to read -- measured with the pie's own
  ## geometry, a 16 % wedge covers 6 whole pixels at 12 px with the 1 px
  ## gap and at 10 px with none, against 3 at 10 px with it.
  max(0, sizePx div PieRingGapStepPx)

proc pieWedgeInsetPx*(sizePx: int): int =
  ## Where the wedge's disc starts inside a `sizePx` pie's box: past the
  ## edge ring and the gap (2 px of a 12 px pie: an 8 px disc).
  PieEdgePx + pieRingGapPx(sizePx)

proc pieStopPercent*(pie: ProgressPie): string =
  ## Where a pie's wedge ends, as a CSS percentage of the turn (`16%`,
  ## `12.5%`): 0 with no known progress. Every front end that draws the pie
  ## as a conic gradient spells it with this.
  let v = if pie.known: pie.fraction * 100.0 else: 0.0
  var s = formatFloat(v, ffDecimal, 3)
  s.trimZeros()
  if s.endsWith("."): s.setLen(s.len - 1)
  s & "%"

proc pieConicGradient*(inks: PieInks; pie: ProgressPie): string =
  ## The pie's disc as a two-stop conic gradient (CSS Images Level 4 §3.3,
  ## https://www.w3.org/TR/css-images-4/#conic-gradients): the wedge from
  ## twelve o'clock clockwise to the share done, hard against the rest,
  ## which is the ground itself (no tint): 0 % is the ground alone.
  let stop = pie.pieStopPercent
  "conic-gradient(" & inks.wedge & " 0 " & stop & ", " & inks.ground & " " & stop & " 100%)"

proc pieStylesheet*(): string =
  ## The web's pie inks (`styles/components/agent_harbor_pie_inks.styl`):
  ## one rule per ground and role, each ink `by-mode(<Dark>, <Light>)` as
  ## this module resolves it, and each ground's own colour for a band of
  ## pies on it. The committed sheet is this text; a unit test holds them
  ## equal, so the web cannot draw a pie in other inks than GPUI and the
  ## terminal do.
  let dark = ahPalette(dmDark)
  let light = ahPalette(dmLight)
  result = "// GENERATED from `viewmodel/views/agent_harbor_palette.nim` " &
    "`pieStylesheet`; do not edit.\n" &
    "// The progress pie's inks per ground and role (`pieInks`): the wedge and\n" &
    "// the edge, each `by-mode(<Dark>, <Light>)`; the rest is the ground.\n"
  # The story's bands: a ground whose colour an earlier ground already has
  # in a mode is not shown in that mode (the earlier band names it), and
  # each band shows the title of the mode it is drawn in.
  result.add "\n.ah-pie-band .ah-pie-title-dark\n  display: by-mode(block, none)\n"
  result.add "\n.ah-pie-band .ah-pie-title-light\n  display: by-mode(none, block)\n"
  # The story's head, on the window's ground.
  result.add "\n.ah-pie-head\n"
  result.add "  color: by-mode(" & dark.readableInk(dark.ground) & ", " &
    light.readableInk(light.ground) & ")\n"
  for ground in PieGround:
    # The ground itself, for the story's band of pies on it, and the ink of
    # the band's words on it.
    result.add "\n.ah-pie-band-" & $ground & "\n"
    result.add "  background: by-mode(" & dark.pieGroundColour(ground) & ", " &
      light.pieGroundColour(ground) & ")\n"
    result.add "  color: by-mode(" & dark.readableInk(dark.pieGroundColour(ground)) & ", " &
      light.readableInk(light.pieGroundColour(ground)) & ")\n"
    let shown = proc(p: AhPalette): string =
      if p.pieGroundShown(ground): "block" else: "none"
    result.add "  display: by-mode(" & shown(dark) & ", " & shown(light) & ")\n"
    for role in PieRole:
      let d = dark.pieInks(role, ground)
      let l = light.pieInks(role, ground)
      result.add "\n.ah-pie-on-" & $ground & ".ah-pie-" & $role & "\n"
      result.add "  --ah-pie-wedge: by-mode(" & d.wedge & ", " & l.wedge & ")\n"
      result.add "  --ah-pie-edge: by-mode(" & d.edge & ", " & l.edge & ")\n"


# ---------------------------------------------------------------------------
# The `link` role: a link in an agent's message, a test's location
# ---------------------------------------------------------------------------
#
# A link (a trace, a recording, a file, a web link in an agent's message;
# a failure's location in the Tests panel) is drawn in one ink, the `link`
# role's, resolved here per ground for every front end under the rules the
# pie's roles keep (the section above):
#
# - the ink holds `PieInkFloor` (3.3:1) against the ground it sits on
#   (WCAG 2.2 SC 1.4.11's 3:1 with the pie's margin; a link's words are
#   also underlined, so the ink is not all that tells them apart);
# - it stands `PieRoleDeltaE` (20) or more in CIEDE2000 from every pie
#   role's ink on that ground (`roleInks`), and from the body text's ink,
#   so a link never reads as a status mark or as the prose around it.
#
# The role's own ink is the design system's information text
# (`textInfo`); the ink taken is the candidate nearest it (`inkCandidates`,
# the info role's search) that holds both rules. Where none does, the one
# with the most contrast that keeps the 20 is taken, and failing that the
# role's own ink, and the shortfall is reported (`linkInkReport`).
#
# The web reads the inks from `agent_harbor_link_inks.styl`, written from
# `linkStylesheet` and held equal to it by `test_agent_harbor_link_ink`;
# GPUI (`ah_theme`) and the terminal canvas read `linkInk` itself, as they
# read the pie's inks.

type
  LinkInkReport* = object
    ## How a ground's link ink was resolved: the ink, and the rule it falls
    ## short of ("" when it meets both).
    ink*: string
    shortOf*: string

var linkInkMemo: seq[(string, LinkInkReport)]

proc linkInkReport*(p: AhPalette; ground: string): LinkInkReport =
  ## The `link` role's ink on `ground` (see the section's header).
  let key = ground & "|" & p.textInfo & "|" & p.textBody
  for (k, v) in linkInkMemo:
    if k == key: return v
  let roles = p.roleInks(ground)
  var others: seq[string]
  for role in PieRole: others.add roles[role]
  others.add p.textBody
  let base = p.textInfo
  var best = ""
  var bestScore = Inf
  var fallback = ""
  var fallbackContrast = 0.0
  for ink in inkCandidates(base, prInfo):
    var apart = true
    for o in others:
      if deltaE2000(ink, o) < PieRoleDeltaE:
        apart = false
        break
    if not apart: continue
    let contrast = inkContrast(ink, ground)
    if contrast >= PieInkFloor:
      let score = deltaE2000(ink, base)
      if score < bestScore:
        best = ink
        bestScore = score
    elif contrast > fallbackContrast:
      fallback = ink
      fallbackContrast = contrast
  result = if best.len > 0: LinkInkReport(ink: best)
           elif fallback.len > 0: LinkInkReport(ink: fallback, shortOf: "contrast")
           else: LinkInkReport(ink: base, shortOf: "role-delta-e")
  linkInkMemo.add (key, result)

proc linkInk*(p: AhPalette; ground: string): string =
  ## The `link` role's ink on `ground` (`#rrggbb`).
  p.linkInkReport(ground).ink

proc linkInk*(p: AhPalette; ground: PieGround): string =
  p.linkInk(p.pieGroundColour(ground))

proc linkStylesheet*(): string =
  ## The web's link inks (`styles/components/agent_harbor_link_inks.styl`):
  ## the `link` role's ink on each ground, `by-mode(<Dark>, <Light>)`, as
  ## custom properties every view's link rule reads (`--ah-link-ink-<ground>`).
  ## The committed sheet is this text; `test_agent_harbor_link_ink` holds
  ## them equal, so the web cannot draw a link in another ink than GPUI and
  ## the terminal do.
  let dark = ahPalette(dmDark)
  let light = ahPalette(dmLight)
  result = "// GENERATED from `viewmodel/views/agent_harbor_palette.nim` " &
    "`linkStylesheet`; do not edit.\n" &
    "// The `link` role's ink per ground (`linkInk`), each `by-mode(<Dark>, <Light>)`.\n" &
    "\n:root\n"
  for ground in PieGround:
    result.add "  --ah-link-ink-" & $ground & ": by-mode(" & dark.linkInk(ground) & ", " &
      light.linkInk(ground) & ")\n"
