## IsoNim view for the ct-toggle switch component.
##
## A design-system toggle / switch that can be dropped anywhere a boolean
## preference needs a visual control — settings panels, toolbar rows, filter
## dropdowns, etc.
##
## Recommended usage:
##
##   let rec = ToggleRecord(
##     label:      "Auto-scroll",
##     isChecked:  true,
##     isDisabled: false,
##     size:       "md")          # "md" (default) or "sm"
##
##   let cb = ToggleCallbacks(onChange: proc() = ...)
##
##   # In a MockRenderer context (tests / SSR):
##   let node = renderToggle[MockRenderer, MockNode](r, rec, cb)
##
##   # In the browser — mount into a stable host element:
##   mountToggleInto(hostElement, rec, cb)
##
## The component is purely CSS-driven: the track color and thumb position are
## controlled by data-checked / data-size / data-disabled on the wrapper
## elements.  No JS timer or animation logic lives here.

import isonim/dsl/ui
import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom

# The generic proc expands the DSL at its caller.
export signals, computation, components

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  ToggleRecord* = object
    ## Data needed to render one toggle switch.
    label*:      string  ## Visible label text (uppercased in CSS).
    isChecked*:  bool    ## Current on/off state.
    isDisabled*: bool    ## When true the whole control is muted / inert.
    size*:       string  ## "md" (default) or "sm".

  ToggleCallbacks* = object
    ## onChange is called when the user clicks the toggle.
    ## The caller is responsible for flipping the backing state and
    ## re-rendering (or calling mountToggleInto again).
    onChange*: proc()

# ---------------------------------------------------------------------------
# Nil-safe callback helper
# ---------------------------------------------------------------------------

proc invokeChange(cb: ToggleCallbacks) =
  if not cb.onChange.isNil: cb.onChange()

# ---------------------------------------------------------------------------
# The toggle, for every renderer
# ---------------------------------------------------------------------------

proc renderToggle*[R, N](r: R;
                         rec: ToggleRecord;
                         cb: ToggleCallbacks = ToggleCallbacks()): N =
  ## Render a toggle switch.
  let checkedAttr  = if rec.isChecked: "true" else: "false"
  let sizeAttr     = if rec.size == "sm": "sm" else: "md"
  let disabledAttr = if rec.isDisabled: "true" else: ""
  ui(r):
    label(class = "ct-toggle-field",
          `data-disabled` = disabledAttr):
      span(class = "ct-toggle",
           `data-checked` = checkedAttr,
           `data-size`    = sizeAttr,
           `aria-hidden`  = "true",
           onclick        = proc() = cb.invokeChange()):
        input(class = "ct-toggle-input",
              `type`  = "checkbox",
              role    = "switch")
        span(class = "ct-toggle-thumb"):
          discard
      span(class = "ct-toggle-label"):
        text rec.label

when defined(js):
  proc mountToggleInto*(container: isonim_dom.Element;
                        rec: ToggleRecord;
                        cb: ToggleCallbacks = ToggleCallbacks()) =
    ## Clear `container` and render a fresh toggle switch inside it.
    ##
    ## Call this whenever the backing state changes to refresh the visual.
    ## A fresh WebRenderer is created each time so IsoNim reactive effects
    ## are scoped to the current render pass and do not accumulate.
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    let r     = WebRenderer()
    let el    = renderToggle[WebRenderer, isonim_dom.Element](r, rec, cb)
    let elNode = isonim_dom.Node(el)
    # Move children (the label, its span children) into the stable host.
    while not isonim_dom.isNodeNil(elNode.firstChild):
      discard isonim_dom.appendChild(containerNode, elNode.firstChild)
