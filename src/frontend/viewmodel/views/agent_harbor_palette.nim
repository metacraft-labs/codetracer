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

import ../../styles/generated/design_tokens
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_items]

export design_tokens

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
    iconSubtle*: string      ## icon/primary/subtle
    endedMark*: string
      ## An ended session's, initiative's or fleet row's grey mark:
      ## `by-mode(colors-ui-icon-primary-subtle,
      ## colors-ui-icon-primary-default-hover)` (`agent_harbor.styl`). Light's
      ## icon-subtle (#999180) fell to 1.42:1 on the active tab (#b5ae9f) and
      ## 2.42:1 on the panel; #4e4b45 keeps 3:1 (WCAG 1.4.11, a graphical
      ## object) on every Light surface a mark sits on. Dark keeps its role.
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
    selectedText*: string
      ## Every text of a row on the action surface (the fleet's selected
      ## row): the selected commit row's, `by-mode(on-action, text-primary-body)`.
    selectedTint*: string
      ## The selected initiative: `by-mode(rgba(surface-action-primary, 0.28),
      ## surface-primary-secondary-hover)`, as `#rrggbbaa`.

  MarkStyle* = object
    ## A status mark: a filled dot, or a hollow ring (idle, planned).
    colour*: string
    ring*: bool

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
    iconSubtle: t(dtColorsUiIconPrimarySubtle),
    endedMark: (if mode == dmDark: t(dtColorsUiIconPrimarySubtle)
                else: t(dtColorsUiIconPrimaryDefaultHover)),
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
    selectedText: (if mode == dmDark: t(dtColorsUiTextOnActionPrimary)
                   else: t(dtColorsUiTextPrimaryBody)),
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
  of saNeedsInput: MarkStyle(colour: p.iconWarning)
  of saRunning: MarkStyle(colour: p.iconSuccess)
  of saQueued: MarkStyle(colour: p.iconInfo)
  of saFailed: MarkStyle(colour: p.iconError)
  of saIdle: MarkStyle(colour: p.iconDefault, ring: true)
  of saEnded: MarkStyle(colour: p.endedMark)

proc markOf*(p: AhPalette; state: InitiativeState): MarkStyle =
  case state
  of isNeedsInput: MarkStyle(colour: p.iconWarning)
  of isWorking: MarkStyle(colour: p.iconSuccess)
  of isBlocked: MarkStyle(colour: p.iconError)
  of isIdle: MarkStyle(colour: p.iconDefault, ring: true)
  of isEnded: MarkStyle(colour: p.endedMark)

proc markOf*(p: AhPalette; status: MilestoneStatusClass): MarkStyle =
  case status
  of mscCompleted: MarkStyle(colour: p.iconSuccess)
  of mscInProgress: MarkStyle(colour: p.iconInfo)
  of mscPartial: MarkStyle(colour: p.iconWarning)
  of mscBlocked: MarkStyle(colour: p.iconError)
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
  of "warning": p.textWarning
  of "running": p.iconInfo
  of "ended": p.endedWord
  of "added": p.textSuccess
  else: p.textBody
