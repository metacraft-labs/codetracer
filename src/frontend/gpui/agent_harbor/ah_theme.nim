## gpui/agent_harbor/ah_theme.nim — CTF-P1b. The colours, sizes and element
## helpers the GPUI views of CodeTracer as an Agent Harbor front-end draw
## with.
##
## The web prototypes (`viewmodel/views/isonim_agent_harbor_*_view.nim`,
## styled by `styles/components/agent_harbor.styl`) take every colour from a
## design-system role; GPUI has no stylesheet, so each role the stylesheet
## names is resolved here from the same generated tokens
## (`styles/generated/design_tokens.nim`), in either colour mode the design
## system publishes. The window's own panes are Dark only today
## (`gpui/chrome.nim`); these views take the mode as a parameter so both of
## the brief's themes can be drawn and captured.
##
## Sizes are the stylesheet's, in pixels (its `rem` against a 16px root):
## caption and label text 12px, body 14px, the status mark 8px, the panel
## inset 8px, a small control 24px.
##
## Every element a view draws that a reader of the render plan needs to find
## carries a `data-ah-*` attribute (`tag`); the CTF-P1b coverage test reads
## the views through them.

import isonim_gpui/renderer
import isonim/viewmodel
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_items]

import ../../styles/generated/design_tokens
import ../chrome
import ../design_font_metrics

export renderer, design_tokens

type
  AhPalette* = object
    ## The design-system roles the Agent Harbor views use, resolved for one
    ## colour mode. Named after the role (`colors-ui-…`) they hold.
    mode*: DesignMode
    ground*: string          ## surface/primary/default: the caption bar, the window
    panel*: string           ## surface/base/panel
    hover*: string           ## surface/primary/secondary-hover: active tab, selected row
    tertiary*: string        ## surface/primary/tertiary
    menu*: string            ## surface/base/card: a dropdown
    action*: string          ## surface/action/primary: the active recording
    onAction*: string        ## text/on-action/primary
    textBody*: string
    textCaption*: string
    textLabel*: string
    textDisabled*: string
    textWarning*: string
    textSuccess*: string
    textError*: string
    borderSecondary*: string ## the hairline between sections
    borderPrimary*: string   ## a dropdown's border
    borderAction*: string
    iconWarning*: string
    iconSuccess*: string
    iconError*: string
    iconInfo*: string
    iconSubtle*: string      ## an ended session's grey mark
    iconDefault*: string     ## the hollow ring of an idle session
    trackPlanned*: string    ## the milestone bar's planned segment (`by-mode`)

  MarkStyle* = object
    ## A status mark: a filled dot, or a hollow ring (idle, planned).
    colour*: string
    ring*: bool

const
  CaptionPx* = 12          ## type-ui-size-caption-md / label-md
  BodyPx* = 14             ## type-ui-size-body-md
  BodyLargePx* = 16        ## type-ui-size-body-lg
  MarkPx* = 8              ## AH_MARK, 0.5rem
  InsetPx* = 8             ## PANEL_INSET, 0.5rem
  ControlPx* = 24          ## CONTROL_HEIGHT_SM, 1.5rem
  ControlRadiusPx* = 6     ## border/radius/control
  StripLinePx* = 30        ## one line of the caption bar's tab strip
  StripTabPx* = 26         ## a session tab's height (1.625em)
  Middot* = " \xC2\xB7 "
  Ellipsis* = "\xE2\x80\xA6"

proc ahPalette*(mode: DesignMode): AhPalette =
  template t(token: DesignToken): string = DesignTokenHex[token][mode]
  AhPalette(
    mode: mode,
    ground: t(dtColorsUiSurfacePrimaryDefault),
    panel: t(dtColorsUiSurfaceBasePanel),
    hover: t(dtColorsUiSurfacePrimarySecondaryHover),
    tertiary: t(dtColorsUiSurfacePrimaryTertiary),
    menu: t(dtColorsUiSurfaceBaseCard),
    action: t(dtColorsUiSurfaceActionPrimary),
    onAction: t(dtColorsUiTextOnActionPrimary),
    textBody: t(dtColorsUiTextPrimaryBody),
    textCaption: t(dtColorsUiTextPrimaryCaption),
    textLabel: t(dtColorsUiTextPrimaryLabel),
    textDisabled: t(dtColorsUiTextPrimaryDisabled),
    textWarning: t(dtColorsUiTextWarningPrimary),
    textSuccess: t(dtColorsUiTextSuccessPrimary),
    textError: t(dtColorsUiTextErrorPrimary),
    borderSecondary: t(dtColorsUiBorderSecondary),
    borderPrimary: t(dtColorsUiBorderPrimary),
    borderAction: t(dtColorsUiBorderAction),
    iconWarning: t(dtColorsUiIconWarningPrimary),
    iconSuccess: t(dtColorsUiIconSuccessPrimary),
    iconError: t(dtColorsUiIconErrorPrimary),
    iconInfo: t(dtColorsUiIconInformationPrimary),
    iconSubtle: t(dtColorsUiIconPrimarySubtle),
    iconDefault: t(dtColorsUiIconPrimaryDefault),
    # `by-mode(colors-ui-border-primary, colors-ui-surface-primary-tertiary)`.
    trackPlanned: (if mode == dmDark: t(dtColorsUiBorderPrimary)
                   else: t(dtColorsUiSurfacePrimaryTertiary)))

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
  of saEnded: MarkStyle(colour: p.iconSubtle)

proc markOf*(p: AhPalette; state: InitiativeState): MarkStyle =
  case state
  of isNeedsInput: MarkStyle(colour: p.iconWarning)
  of isWorking: MarkStyle(colour: p.iconSuccess)
  of isBlocked: MarkStyle(colour: p.iconError)
  of isIdle: MarkStyle(colour: p.iconDefault, ring: true)
  of isEnded: MarkStyle(colour: p.iconSubtle)

proc markOf*(p: AhPalette; status: MilestoneStatusClass): MarkStyle =
  case status
  of mscCompleted: MarkStyle(colour: p.iconSuccess)
  of mscInProgress: MarkStyle(colour: p.iconInfo)
  of mscPartial: MarkStyle(colour: p.iconWarning)
  of mscBlocked: MarkStyle(colour: p.iconError)
  of mscPlanned: MarkStyle(colour: p.iconDefault, ring: true)
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
  of saEnded: p.textCaption
  else: p.textLabel

proc stateWordColour*(p: AhPalette; state: InitiativeState): string =
  case state
  of isNeedsInput: p.textWarning
  of isWorking: p.textSuccess
  of isBlocked: p.textError
  else: p.textCaption

# ---------------------------------------------------------------------------
# Element helpers
# ---------------------------------------------------------------------------

proc textPx*(text: string; sizePx: int): int =
  ## How wide the interface face sets `text` (`design_font_metrics`).
  groteskTextPx(text, float(sizePx))

proc styles*(r: GpuiRenderer; el: GpuiElement;
             pairs: openArray[(string, string)]) =
  for (k, v) in pairs: r.setStyle(el, k, v)

proc tag*(r: GpuiRenderer; el: GpuiElement; name, value: string) =
  ## A `data-ah-<name>` fact for the render plan's reader.
  r.setAttribute(el, "data-ah-" & name, value)

proc box*(r: GpuiRenderer; column = false;
          pairs: openArray[(string, string)] = []): GpuiElement =
  ## A flex container (a row unless `column`).
  result = r.createElement("div")
  r.setStyle(result, "display", "flex")
  r.setStyle(result, "flex-direction", if column: "column" else: "row")
  r.styles(result, pairs)

proc text*(r: GpuiRenderer; s: string; sizePx: int; colour: string;
           bold = false; shrink = true; pairs: openArray[(string, string)] = []): GpuiElement =
  ## One line of text: never wraps, elides at its box's edge when it may
  ## shrink (the stylesheet's `white-space: nowrap; text-overflow: ellipsis`).
  result = r.createElement("span")
  r.styles(result, [("font-size", $sizePx & "px"), ("color", colour),
                    ("font-family", WindowFontFamily), ("white-space", "nowrap")])
  if bold: r.setStyle(result, "font-weight", "600")
  if shrink:
    r.styles(result, [("overflow", "hidden"), ("text-overflow", "ellipsis"),
                      ("flex-shrink", "1")])
  else:
    r.setStyle(result, "flex-shrink", "0")
  r.styles(result, pairs)
  r.appendChild(result, r.createTextNode(s))

proc mark*(r: GpuiRenderer; m: MarkStyle; sizePx = MarkPx): GpuiElement =
  ## The status mark every sessions view shares: a dot, or a hollow ring.
  result = r.createElement("div")
  r.styles(result, [("width", $sizePx & "px"), ("height", $sizePx & "px"),
                    ("min-width", $sizePx & "px"), ("flex-shrink", "0"),
                    ("rounded", $(sizePx div 2) & "px")])
  if m.ring:
    r.styles(result, [("border-width", "1.5px"), ("border-color", m.colour)])
  else:
    r.setStyle(result, "background", m.colour)
  r.tag(result, "mark", if m.ring: "ring:" & m.colour else: m.colour)

proc rule*(r: GpuiRenderer; el: GpuiElement; colour: string) =
  ## The hairline under a section (`border-bottom: 1px solid …`).
  r.styles(el, [("border-bottom-width", "1px"), ("border-color", colour)])

proc button*(r: GpuiRenderer; p: AhPalette; label: string; onClick: proc();
             outlined = true): GpuiElement =
  ## A small control (`ah-fleet-retry`, `ah-tab-retry`, `ah-inbox-*`).
  result = r.box(pairs = [("height", $ControlPx & "px"), ("items", "center"),
                          ("justify", "center"), ("padding-left", "8px"),
                          ("padding-right", "8px"), ("flex-shrink", "0"),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("cursor", "pointer")])
  if outlined:
    r.styles(result, [("border-width", "1px"), ("border-color", p.borderPrimary)])
  r.appendChild(result, r.text(label, CaptionPx, p.textLabel, shrink = false))
  r.tag(result, "button", label)
  if onClick != nil: r.addEventListener(result, "click", onClick)

proc clearChildren*(r: GpuiRenderer; el: GpuiElement) =
  while childCount(el) > 0:
    r.removeChild(el, nthChild(el, childCount(el) - 1))

proc notice*(r: GpuiRenderer; p: AhPalette; message: string; kind: string): GpuiElement =
  ## The shared empty-state overlay (`.empty-overlay`): a centred, quiet,
  ## italic line in an otherwise empty panel body.
  result = r.box(column = true, pairs = [("flex-grow", "1"), ("items", "center"),
                                         ("justify", "center"), ("padding", "16px")])
  r.tag(result, "notice", kind)
  r.appendChild(result, r.text(message, BodyPx, p.textCaption,
                               pairs = [("font-style", "italic")]))

proc errorBlock*(r: GpuiRenderer; p: AhPalette; title, message: string;
                 retry: proc()): GpuiElement =
  ## A load failure (`.ah-fleet-error`): what failed, why, and Retry.
  result = r.box(column = true, pairs = [("gap", "6px"), ("padding", "16px"),
                                         ("items", "start")])
  r.tag(result, "notice", "error")
  r.appendChild(result, r.text(title, BodyPx, p.textError, bold = true))
  let why = r.text(message, CaptionPx, p.textLabel, shrink = false,
                   pairs = [("white-space", "normal")])
  r.tag(why, "error", message)
  r.appendChild(result, why)
  r.appendChild(result, r.button(p, "Retry", retry))

proc stateName*(state: AsyncState): string =
  ## The load state a view's root reports (`data-ah-state`).
  case state
  of asIdle, asLoading: "loading"
  of asError: "error"
  of asReady: "ready"
