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
    secondary*: string       ## surface/primary/secondary: a Retry button
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
    borderError*: string     ## a failed recording's outline (Dark)
    iconWarning*: string
    iconSuccess*: string
    iconError*: string
    iconInfo*: string
    iconSubtle*: string      ## an ended session's grey mark
    iconDefault*: string     ## the hollow ring of an idle session
    trackPlanned*: string    ## the milestone bar's planned segment (`by-mode`)
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
      ## The active session row's status, meta and detail: `by-mode(caption,
      ## label)` (Light's tertiary is too dark for the caption role).
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
    secondary: t(dtColorsUiSurfacePrimarySecondary),
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
    borderError: t(dtColorsUiBorderError),
    iconWarning: t(dtColorsUiIconWarningPrimary),
    iconSuccess: t(dtColorsUiIconSuccessPrimary),
    iconError: t(dtColorsUiIconErrorPrimary),
    iconInfo: t(dtColorsUiIconInformationPrimary),
    iconSubtle: t(dtColorsUiIconPrimarySubtle),
    iconDefault: t(dtColorsUiIconPrimaryDefault),
    # The stylesheet's last word on planned (`agent_harbor.styl`, "Planned
    # in Dark: a mark the eye finds"): the mark and the bar's segment both
    # `by-mode(colors-ui-icon-primary-subtle, colors-ui-border-primary)`,
    # filled.
    trackPlanned: (if mode == dmDark: t(dtColorsUiIconPrimarySubtle)
                   else: t(dtColorsUiBorderPrimary)),
    # The stylesheet's own literals for Dark, where it states one (`by-mode`
    # with a hex): the design system has no role for these greys.
    activeTab: (if mode == dmDark: "#3c3c3c" else: t(dtColorsUiSurfacePrimaryTertiary)),
    activeRow: (if mode == dmDark: "#3c3c3c" else: t(dtColorsUiSurfacePrimarySecondaryHover)),
    activeTabText: (if mode == dmDark: "#ffffff" else: t(dtColorsUiTextPrimaryBody)),
    activeTabOrigin: (if mode == dmDark: "#b0b0b0" else: t(dtColorsUiTextPrimaryCaption)),
    activeRowQuiet: (if mode == dmDark: t(dtColorsUiTextPrimaryCaption)
                     else: t(dtColorsUiTextPrimaryLabel)),
    addText: (if mode == dmDark: "#b0b0b0" else: t(dtColorsUiTextPrimaryLabel)),
    selectedText: (if mode == dmDark: t(dtColorsUiTextOnActionPrimary)
                   else: t(dtColorsUiTextPrimaryBody)),
    # 0.28 of 255 is 71.4: alpha 0x47.
    selectedTint: (if mode == dmDark: t(dtColorsUiSurfaceActionPrimary) & "47"
                   else: t(dtColorsUiSurfacePrimarySecondaryHover)))

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

proc underline*(r: GpuiRenderer; colour: string; insetPx, ofWidthPx: int): GpuiElement =
  ## A flat 2px line along the bottom of a `position: relative` element of
  ## `ofWidthPx`, `insetPx` in from either side (`.ah-tab-in-focus::after`).
  result = r.createElement("div")
  r.styles(result, [("position", "absolute"), ("left", $insetPx & "px"),
                    ("bottom", "0px"), ("height", "2px"),
                    ("width", $max(0, ofWidthPx - 2 * insetPx) & "px"),
                    ("background", colour)])

proc insetBar*(r: GpuiRenderer; colour: string; widthPx: int): GpuiElement =
  ## A bar down the left edge of a `position: relative` row, drawn over it
  ## (`box-shadow: inset <w> 0 0 <colour>`).
  result = r.createElement("div")
  r.styles(result, [("position", "absolute"), ("left", "0px"), ("top", "0px"),
                    ("bottom", "0px"), ("width", $widthPx & "px"),
                    ("height", "100%"), ("background", colour)])

proc stripNotice*(r: GpuiRenderer; p: AhPalette; message, kind: string;
                  sizePx: int): GpuiElement =
  ## A tab-shaped notice on a tab strip (loading, empty, an error):
  ## OUTLINED, never filled -- a filled one reads as the active tab
  ## (`.ah-tab-strip .session-tab.ah-tab-notice`: transparent, a 1px dashed
  ## border, the error one in the error colour).
  let error = kind == "error"
  result = r.box(pairs = [("height", $StripTabPx & "px"), ("items", "center"),
                          ("gap", "8px"), ("padding-left", "10px"),
                          ("padding-right", "10px"), ("flex-shrink", "1"),
                          ("min-width", "0px"), ("overflow", "hidden"),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("border-width", "1px"), ("border-style", "dashed"),
                          ("border-color", if error: p.textError else: p.borderPrimary)])
  r.tag(result, "notice", kind)
  let words = r.text(message, sizePx, if error: p.textError else: p.textCaption)
  if error: r.tag(words, "error", message)
  r.appendChild(result, words)

proc stripRetry*(r: GpuiRenderer; p: AhPalette; onClick: proc()): GpuiElement =
  ## Retry inside a strip's error notice (`.ah-tab-retry`): 20px high,
  ## outlined, caption-sized.
  result = r.box(pairs = [("height", "20px"), ("items", "center"),
                          ("justify", "center"), ("padding-left", "8px"),
                          ("padding-right", "8px"), ("flex-shrink", "0"),
                          ("rounded", $ControlRadiusPx & "px"),
                          ("border-width", "1px"), ("border-color", p.borderPrimary),
                          ("cursor", "pointer")])
  r.appendChild(result, r.text("Retry", CaptionPx, p.textLabel, shrink = false))
  r.tag(result, "button", "Retry")
  if onClick != nil: r.addEventListener(result, "click", onClick)

type
  FlowItem* = object
    ## One item of a wrapping row (`flowLines`).
    el*: GpuiElement
    widthPx*: int      ## its natural width (text measured with `textPx`)
    grow*: bool        ## takes its line's free width (`flex: 1 1 auto`)
    ownLine*: bool     ## starts a line of its own (`flex-basis: 100%`)
    alignEnd*: bool    ## pushed to its line's end (`margin-left: auto`)

proc flowLines*(r: GpuiRenderer; items: openArray[FlowItem]; availPx, gapPx,
                lineHeightPx, rowGapPx: int): GpuiElement =
  ## A row of items that WRAPS, as CSS `flex-wrap: wrap` lays one out: each
  ## item goes on the current line while it fits beside the ones already
  ## there (`gapPx` apart, `availPx` wide), else starts the next; an item
  ## wider than a whole line gets a line to itself and is cut there. GPUI's
  ## layout has no wrapping, so the lines are packed here, from the natural
  ## widths, into a column of `lineHeightPx` rows `rowGapPx` apart.
  let column = r.box(column = true, pairs = [("gap", $rowGapPx & "px")])
  var line: GpuiElement = nil
  var used = 0
  var count = 0
  var grows = false
  for item in items:
    let need = if line == nil or used == 0: item.widthPx else: used + gapPx + item.widthPx
    # A measured width is a whole pixel, rounded; the browser's is
    # fractional. One pixel of slack per item already on the line keeps an
    # item whose true width fits exactly from breaking the line.
    if line == nil or item.ownLine or (used > 0 and need > availPx + count):
      if line != nil: r.appendChild(column, line)
      line = r.box(pairs = [("height", $lineHeightPx & "px"), ("items", "center"),
                            ("gap", $gapPx & "px"), ("width", $availPx & "px")])
      used = 0
      count = 0
      grows = false
    if item.alignEnd and not grows:
      r.appendChild(line, r.box(pairs = [("flex-grow", "1")]))
    if item.grow:
      grows = true
      r.styles(item.el, [("flex-grow", "1"), ("flex-shrink", "1"), ("min-width", "0px")])
    r.appendChild(line, item.el)
    used = if used == 0: min(item.widthPx, availPx) else: used + gapPx + item.widthPx
    inc count
  if line != nil: r.appendChild(column, line)
  column

proc clearChildren*(r: GpuiRenderer; el: GpuiElement) =
  while childCount(el) > 0:
    r.removeChild(el, nthChild(el, childCount(el) - 1))

proc notice*(r: GpuiRenderer; p: AhPalette; message: string; kind: string): GpuiElement =
  ## The shared empty-state overlay (`.empty-overlay`, `empty_states.styl`):
  ## filling the panel body, the message centred both ways, 40px clear of
  ## the sides (EMPTY_OVERLAY_SIDE_GAP), upright, 14px on 20px lines in the
  ## body colour at 0.6 opacity, wrapping where the panel's width says.
  result = r.box(column = true, pairs = [("flex-grow", "1"), ("items", "center"),
                                         ("justify", "center"), ("padding-left", "40px"),
                                         ("padding-right", "40px")])
  r.tag(result, "notice", kind)
  r.appendChild(result, r.text(message, BodyPx, p.textBody, shrink = false,
                               pairs = [("white-space", "normal"), ("text-align", "center"),
                                        ("opacity", "0.6"), ("line-height", "20px")]))

proc errorBlock*(r: GpuiRenderer; p: AhPalette; title, message: string;
                 retry: proc()): GpuiElement =
  ## A load failure (`.ah-fleet-error`): what failed, why, and Retry, in the
  ## middle of the panel body it fills -- centred both ways, 40px clear of
  ## the sides (EMPTY_OVERLAY_SIDE_GAP), 8px apart; the title in the error
  ## colour at body size (not bold), the reason a caption.
  result = r.box(column = true, pairs = [("flex-grow", "1"), ("gap", "8px"),
                                         ("padding-left", "40px"),
                                         ("padding-right", "40px"),
                                         ("items", "center"), ("justify", "center")])
  r.tag(result, "notice", "error")
  r.appendChild(result, r.text(title, BodyPx, p.textError, shrink = false))
  let why = r.text(message, CaptionPx, p.textCaption, shrink = false,
                   pairs = [("white-space", "normal"), ("text-align", "center")])
  r.tag(why, "error", message)
  r.appendChild(result, why)
  # `.ah-fleet-retry`: 24px, the secondary surface, outlined.
  let button = r.button(p, "Retry", retry)
  r.styles(button, [("padding-left", "12px"), ("padding-right", "12px"),
                    ("background", p.secondary)])
  r.appendChild(result, button)

proc stateName*(state: AsyncState): string =
  ## The load state a view's root reports (`data-ah-state`).
  case state
  of asIdle, asLoading: "loading"
  of asError: "error"
  of asReady: "ready"
