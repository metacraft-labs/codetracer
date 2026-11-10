## gpui/agent_harbor/ah_theme.nim — CTF-P1b. The colours, sizes and element
## helpers the GPUI views of CodeTracer as an Agent Harbor front-end draw
## with.
##
## The web prototypes (`viewmodel/views/isonim_agent_harbor_*_view.nim`,
## styled by `styles/components/agent_harbor.styl`) take every colour from a
## design-system role; GPUI has no stylesheet, so each role the stylesheet
## names is resolved from the same generated tokens
## (`styles/generated/design_tokens.nim`), in either colour mode the design
## system publishes, by `viewmodel/views/agent_harbor_palette.nim` (shared
## with the terminal's views, so the two front-ends resolve each role alike;
## re-exported here). The window's own panes are Dark only today
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

import ../../../common/pointer_shape
import ../../../common/content_file_cache
import std/[base64, strutils]

import isonim_gpui/renderer
import isonim/viewmodel
import nim_agents_isonim_viewmodels/agent_harbor/[data_source, session_items]

import ../../styles/generated/design_tokens
import ../../viewmodel/views/agent_harbor_palette
import ../chrome
import ../design_font_metrics

export renderer, design_tokens, agent_harbor_palette

const
  CaptionPx* = 12          ## type-ui-size-caption-md / label-md
  CaptionLinePx* = 16      ## type-ui-lineheight-caption-md
  BodyPx* = 14             ## type-ui-size-body-md
  BodyLargePx* = 16        ## type-ui-size-body-lg
  MarkPx* = 8              ## AH_MARK, 0.5rem
  InsetPx* = 8             ## PANEL_INSET, 0.5rem
  ControlPx* = 24          ## CONTROL_HEIGHT_SM, 1.5rem
  ControlRadiusPx* = 6     ## border/radius/control
  StripLinePx* = 30        ## one line of the caption bar's tab strip
  StripTabPx* = 26         ## a session tab's height (1.625em)
  Middot* = " \xC2\xB7 "
  LabelTracking* = "0.03125em"
    ## The uppercase labels' `letter-spacing` (`.ah-fleet-title`,
    ## `.ah-session-list-title`, `.ah-initiative-label`,
    ## `.ah-progress-group-header`, `.ah-milestone-current-tag`): 0.375px
    ## after every character at the caption size (`tracked`).
  Ellipsis* = "\xE2\x80\xA6"

# ---------------------------------------------------------------------------
# Element helpers
# ---------------------------------------------------------------------------

proc textPx*(text: string; sizePx: int; tabular = false): int =
  ## How wide the interface face sets `text` (`design_font_metrics`);
  ## `tabular`: in tabular figures, as `text(..., tabular = true)` draws it.
  groteskTextPx(text, float(sizePx), tabular = tabular)

proc textWidth*(text: string; sizePx: int; tabular = false): float =
  ## The same, unrounded and KERNED, as a browser and GPUI set it: the width
  ## an exact line break is decided on (`FlowItem.exactPx`).
  groteskTextWidth(text, float(sizePx), tabular = tabular, kerned = true)

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
           bold = false; shrink = true; tabular = false;
           pairs: openArray[(string, string)] = []): GpuiElement =
  ## One line of text: never wraps, elides at its box's edge when it may
  ## shrink (the stylesheet's `white-space: nowrap; text-overflow: ellipsis`).
  ## `tabular`: its digits in tabular figures, all one width
  ## (`font-variant-numeric: tabular-nums`, which the stylesheet sets on
  ## counts, ages, `n/m` and the recording buttons); measure such text with
  ## `textPx(..., tabular = true)`.
  result = r.createElement("span")
  r.styles(result, [("font-size", $sizePx & "px"), ("color", colour),
                    ("font-family", WindowFontFamily), ("white-space", "nowrap")])
  if bold: r.setStyle(result, "font-weight", "600")
  if tabular: r.setStyle(result, "font-variant-numeric", "tabular-nums")
  if shrink:
    r.styles(result, [("overflow", "hidden"), ("text-overflow", "ellipsis"),
                      ("flex-shrink", "1")])
  else:
    r.setStyle(result, "flex-shrink", "0")
  r.styles(result, pairs)
  r.appendChild(result, r.createTextNode(s))

proc tracked*(r: GpuiRenderer; el: GpuiElement): GpuiElement =
  ## `el`, an uppercase label, spaced as the stylesheet spaces those
  ## (`LabelTracking`; isonim-gpui sets the glyphs itself). Returns `el`.
  r.setStyle(el, "letter-spacing", LabelTracking)
  el

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

# ---------------------------------------------------------------------------
# Icons: the web's images and masks, drawn as GPUI images
# ---------------------------------------------------------------------------

const
  PlusSvg = staticRead("../../../public/resources/shared/session_tab_add.svg")
    ## `.session-tab-add::before`'s mask (12×12, `#DDDDDD` filled).
  TabPinSvg = staticRead("../../../public/resources/menu/lm_pin_tab_dark.svg")
    ## `LAYOUT_TAB_PIN_ICON_PATH`, both themes (`#919191` filled).
  TabCloseSvg = staticRead("../../../public/resources/menu/lm_close_tab_dark.svg")
    ## `LAYOUT_TAB_CLOSE_ICON_PATH` in Dark (`#919191` filled).
  TabClosePng = staticRead("../../../public/third_party/golden-layout/dist/img/lm_close_black.png")
    ## `LAYOUT_TAB_CLOSE_ICON_PATH` in Light: golden-layout's 9×9 black X.

proc iconFile(name, content: string): string =
  ## An icon as a file, since GPUI's `img` loads a picture from a path: in
  ## the per-user cache, named by its content, so every process draws the
  ## same icon from the same file and leaves nothing behind
  ## (`common/content_file_cache`).
  contentFile("gpui-agent-harbor-icons", name, content)

proc maskedPng(png: string; side: int; colour: string): string =
  ## A raster image as an SVG whose alpha is the PNG's (`mask-type: alpha`,
  ## https://www.w3.org/TR/css-masking-1/#the-mask-type), over a rectangle
  ## of `colour`: usable as a `mask-image`, whose colour does not matter.
  let uri = "data:image/png;base64," & encode(png)
  "<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" " &
    "width=\"" & $side & "\" height=\"" & $side & "\" viewBox=\"0 0 " & $side & " " & $side & "\">" &
    "<mask id=\"m\" mask-type=\"alpha\" style=\"mask-type:alpha\">" &
    "<image width=\"" & $side & "\" height=\"" & $side & "\" href=\"" & uri &
    "\" xlink:href=\"" & uri & "\"/></mask>" &
    "<rect width=\"" & $side & "\" height=\"" & $side & "\" fill=\"" & colour &
    "\" mask=\"url(#m)\"/></svg>"

proc icon(r: GpuiRenderer; file: string; widthPx, heightPx: float;
          opacity = 1.0): GpuiElement =
  result = r.createElement("img")
  r.setAttribute(result, "src", file)
  r.styles(result, [("width", formatFloat(widthPx, ffDecimal, 1) & "px"),
                    ("height", formatFloat(heightPx, ffDecimal, 1) & "px"),
                    ("flex-shrink", "0")])
  if opacity < 1.0: r.setStyle(result, "opacity", $opacity)

proc maskIcon(r: GpuiRenderer; mask: string; colour: string; widthPx, heightPx: float;
              opacity = 1.0): GpuiElement =
  ## A one-colour icon as the stylesheet draws it: `colour` painted through
  ## the mask file's alpha (`background-color` under `mask-image`,
  ## https://www.w3.org/TR/css-masking-1/#the-mask-image), which isonim-gpui
  ## renders at the box's device size. An `img` of a recoloured SVG is
  ## minified from twice its size with straight-alpha filtering and draws
  ## every 1px stroke dimmer than the browser (isonim-gpui shim-design.md,
  ## "Mask Image").
  result = r.createElement("div")
  r.styles(result, [("width", formatFloat(widthPx, ffDecimal, 1) & "px"),
                    ("height", formatFloat(heightPx, ffDecimal, 1) & "px"),
                    ("flex-shrink", "0"), ("background", colour),
                    ("mask-image", "url(\"" & mask & "\")")])
  if opacity < 1.0: r.setStyle(result, "opacity", $opacity)

proc plusIcon*(r: GpuiRenderer; p: AhPalette): GpuiElement =
  ## "+" on its disc (`.session-tab-add::before`): the 12px plus mask in the
  ## control's colour (`by-mode(#b0b0b0, text-primary-label)`) at 0.7.
  r.maskIcon(iconFile("session-tab-add.svg", PlusSvg), p.addText, 12, 12, 0.7)

proc tabCloseIcon*(r: GpuiRenderer; p: AhPalette): GpuiElement =
  ## A session tab's close control (`.session-tab-close`): the layout's close
  ## image as it is (`background-image`, not a mask) -- the SVG in Dark,
  ## golden-layout's black PNG in Light -- 0.6em (9.6px) at 0.4.
  if p.mode == dmDark:
    r.icon(iconFile("tab-close-dark.svg", TabCloseSvg), 9.6, 9.6, 0.4)
  else:
    r.icon(iconFile("tab-close-light.png", TabClosePng), 9.6, 9.6, 0.4)

proc framePinIcon*(r: GpuiRenderer; p: AhPalette): GpuiElement =
  ## A frame tab's pin (`.lm_pin_tab`): the pin mask, 0.85em (13.6px), in
  ## `TAB_ICON_COLOR`.
  r.maskIcon(iconFile("lm-pin-tab.svg", TabPinSvg), p.tabIcon, 13.6, 13.6)

proc frameCloseIcon*(r: GpuiRenderer; p: AhPalette): GpuiElement =
  ## A frame tab's close (`.lm_close_tab`): the theme's close image used as
  ## a mask, 0.6em (9.6px), in `TAB_ICON_COLOR`.
  let mask = if p.mode == dmDark: iconFile("lm-close-tab.svg", TabCloseSvg)
             else: iconFile("lm-close-black.svg", maskedPng(TabClosePng, 9, "#000000"))
  r.maskIcon(mask, p.tabIcon, 9.6, 9.6)

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
                          ("cursor", cursorOf(hkControl))])
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
  r.tag(result, "strip-notice", kind)
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
                          ("cursor", cursorOf(hkControl))])
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
    exactPx*: float
      ## Its exact (fractional) width, when every part of it is known
      ## exactly; 0 when only the rounded `widthPx` is.
    dropPx*: int
      ## How far below the line's top it sits when it shares its line with
      ## the items before it, its line growing by as much: a row laid out
      ## with `align-items: baseline`, where a smaller text's baseline-aligned
      ## box ends lower than a larger one's (the fleet's 12px meta beside its
      ## 14px title). 0 for an item that does not move.

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
  var exactUsed = 0.0
  var allExact = true
  for item in items:
    let need = if line == nil or used == 0: item.widthPx else: used + gapPx + item.widthPx
    # A measured width is a whole pixel, rounded; the browser's is
    # fractional. One pixel of slack per item already on the line keeps an
    # item whose true width fits exactly from breaking the line. When every
    # item on the line knows its exact width, the line breaks exactly where
    # the browser's does, with no slack: a line that overflows by half a
    # pixel breaks there too.
    let exact = allExact and item.exactPx > 0
    let overflows =
      if exact: exactUsed + float(gapPx) + item.exactPx > float(availPx)
      else: need > availPx + count
    if line == nil or item.ownLine or (used > 0 and overflows):
      if line != nil: r.appendChild(column, line)
      line = r.box(pairs = [("height", $lineHeightPx & "px"), ("items", "center"),
                            ("gap", $gapPx & "px"), ("width", $availPx & "px")])
      used = 0
      count = 0
      grows = false
      exactUsed = 0.0
      allExact = true
    if item.dropPx > 0 and count > 0:
      # Baseline-aligned beside what is already on the line: the line's
      # items keep to its top, this one `dropPx` lower, the line that much
      # taller.
      r.styles(line, [("height", $(lineHeightPx + item.dropPx) & "px"), ("items", "start")])
      r.setStyle(item.el, "margin-top", $item.dropPx & "px")
    if item.alignEnd and not grows:
      r.appendChild(line, r.box(pairs = [("flex-grow", "1")]))
    if item.grow:
      grows = true
      r.styles(item.el, [("flex-grow", "1"), ("flex-shrink", "1"), ("min-width", "0px")])
    r.appendChild(line, item.el)
    exactUsed = if used == 0: item.exactPx else: exactUsed + float(gapPx) + item.exactPx
    allExact = allExact and item.exactPx > 0
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
  # On the caption's 16px lines (`.ah-fleet-error-message`: `line-height:
  # type-ui-lineheight-caption-md`), not the face's own, which wraps at 19px.
  let why = r.text(message, CaptionPx, p.textCaption, shrink = false,
                   pairs = [("white-space", "normal"), ("text-align", "center"),
                            ("line-height", $CaptionLinePx & "px")])
  r.tag(why, "error", message)
  r.tag(why, "error-reason", "true")
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
