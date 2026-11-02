## IsoNim view for the event log filter dropdown panel.
##
## Renders a tab row (Trace events / Recorded events) at the top and a
## two-column grid of tag + kind checkboxes below — one row per EventTag.
## The left column (9 em) shows the tag checkbox label; the right column
## (flex, wrapping) shows the kind checkboxes that belong to that tag.
##
## Calling convention mirrors other isonim_*_view files:
##   - Build seq[FilterTabRecord] / seq[FilterTagRow] from component state.
##   - Pass a FilterDropdownCallbacks with nil-guarded handlers.
##   - Call mountFilterDropdownInto(container, tabs, rows, cb) to refresh.
##
## The container element is managed by the caller (created once, appended to
## document.body, positioned via kdom style properties after each mount).
##
## ONE generic view (Shared-DOM-Front-Ends D3), ``renderFilterDropdownPanel[R,
## N]``: the headless tests render it under ``MockRenderer``, the desktop
## under ``WebRenderer``. The tabs and rows are plain values — the caller
## remounts the panel when they change — so its loops run once per render by
## design.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

# ---------------------------------------------------------------------------
# Public types
# ---------------------------------------------------------------------------

type
  FilterTabRecord* = object
    label*: string
    isSelected*: bool

  FilterKindRecord* = object
    label*: string
    ## "checked" | "unchecked"
    checkState*: string

  FilterTagRow* = object
    label*: string
    ## "checked" | "unchecked" | "indeterminate"
    checkState*: string
    kinds*: seq[FilterKindRecord]

  FilterDropdownCallbacks* = object
    ## onTabClick receives 0 for "Trace events", 1 for "Recorded events".
    onTabClick*: proc(tabIndex: int)
    ## onTagToggle receives the row index in the rendered seq[FilterTagRow].
    onTagToggle*: proc(tagIndex: int)
    ## onKindToggle receives the row index and the kind index within that row.
    onKindToggle*: proc(tagIndex: int; kindIndex: int)
    ## onToggleEnabled is called when the user clicks the enable/disable toggle.
    ## The caller is responsible for flipping the state and calling mount again.
    onToggleEnabled*: proc()

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

const
  FilterDropdownContainerId* = "dropdown-container-id"
  FilterDropdownListId* = "category-image-list"

# ---------------------------------------------------------------------------
# Nil-safe callback helpers
# ---------------------------------------------------------------------------

proc invokeTabClick(cb: FilterDropdownCallbacks; idx: int) =
  if not cb.onTabClick.isNil: cb.onTabClick(idx)

proc invokeTagToggle(cb: FilterDropdownCallbacks; idx: int) =
  if not cb.onTagToggle.isNil: cb.onTagToggle(idx)

proc invokeKindToggle(cb: FilterDropdownCallbacks; ti, ki: int) =
  if not cb.onKindToggle.isNil: cb.onKindToggle(ti, ki)

proc invokeToggleEnabled(cb: FilterDropdownCallbacks) =
  if not cb.onToggleEnabled.isNil: cb.onToggleEnabled()

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc tabClickHandler(cb: FilterDropdownCallbacks; index: int): proc() =
  result = proc() = cb.invokeTabClick(index)

proc tagToggleHandler(cb: FilterDropdownCallbacks; ti: int): proc() =
  result = proc() = cb.invokeTagToggle(ti)

proc kindToggleHandler(cb: FilterDropdownCallbacks; ti, ki: int): proc() =
  result = proc() = cb.invokeKindToggle(ti, ki)

proc renderTab[R, N](r: R; tab: FilterTabRecord; index: int;
                     cb: FilterDropdownCallbacks): N =
  ui(r):
    button(class = "ct-tab",
           `data-selected` = (if tab.isSelected: "true" else: ""),
           onclick = tabClickHandler(cb, index)):
      text tab.label

proc renderKindCheckbox[R, N](r: R; kind: FilterKindRecord;
                              tagIndex, kindIndex: int;
                              cb: FilterDropdownCallbacks): N =
  ui(r):
    label(class = "ct-checkmark-field"):
      input(class = "ct-checkmark-input",
            `type` = "checkbox",
            value = $kindIndex,
            onchange = kindToggleHandler(cb, tagIndex, kindIndex))
      span(class = "ct-checkmark",
           `data-state` = kind.checkState,
           `aria-hidden` = "true"):
        discard
      span(class = "ct-checkmark-label"):
        text kind.label

proc renderTagRow[R, N](r: R; row: FilterTagRow; tagIndex: int;
                        cb: FilterDropdownCallbacks): N =
  var kindsHost: N
  result = ui(r):
    li(class = "dropdown-list-row"):
      label(class = "ct-checkmark-field"):
        input(class = "ct-checkmark-input",
              `type` = "checkbox",
              value = $tagIndex,
              onchange = tagToggleHandler(cb, tagIndex))
        span(class = "ct-checkmark",
             `data-state` = row.checkState,
             `aria-hidden` = "true"):
          discard
        span(class = "ct-checkmark-label"):
          text row.label
      tdiv(ref = kindsHost, class = "dropdown-kind-items"):
        discard
  for ki, kind in row.kinds:
    r.appendChild(kindsHost,
                  renderKindCheckbox[R, N](r, kind, tagIndex, ki, cb))

proc renderFilterDropdownPanel*[R, N](r: R;
                                      tabs: seq[FilterTabRecord];
                                      rows: seq[FilterTagRow];
                                      filtersEnabled: bool = true;
                                      cb: FilterDropdownCallbacks =
                                        FilterDropdownCallbacks()): N =
  ## Render the full dropdown DOM tree (tab row + tag/kind grid). Returns the
  ## outer .dropdown-container element; the browser moves its children into
  ## a stable host (``mountFilterDropdownInto``).
  let checkedAttr = if filtersEnabled: "true" else: "false"
  let toggleLabel = if filtersEnabled: "On" else: "Off"
  var tabsHost, enabledWrapper, listHost: N
  result = ui(r):
    tdiv(class = "dropdown-container"):
      tdiv(ref = tabsHost, class = "toggle-buttons"):
        tdiv(ref = enabledWrapper, class = "toggle-enabled-wrapper"):
          span(class = "ct-toggle-label"):
            text toggleLabel
          span(class = "ct-toggle",
               `data-checked` = checkedAttr,
               `data-size`    = "sm",
               `aria-hidden`  = "true",
               onclick        = proc() = cb.invokeToggleEnabled()):
            input(class = "ct-toggle-input", `type` = "checkbox", role = "switch")
            span(class = "ct-toggle-thumb"):
              discard
      ul(ref = listHost, class = "dropdown-list", id = FilterDropdownListId):
        discard
  # The tabs come before the on/off toggle.
  for i, tab in tabs:
    r.insertBefore(tabsHost, renderTab[R, N](r, tab, i, cb), enabledWrapper)
  for i, row in rows:
    r.appendChild(listHost, renderTagRow[R, N](r, row, i, cb))

when defined(js):
  proc mountFilterDropdownInto*(container: isonim_dom.Element;
                                tabs: seq[FilterTabRecord];
                                rows: seq[FilterTagRow];
                                filtersEnabled: bool = true;
                                cb: FilterDropdownCallbacks =
                                  FilterDropdownCallbacks()) =
    ## Clear `container` and remount a fresh dropdown panel inside it.
    ##
    ## The container is the stable .dropdown-container div owned by
    ## setupFilterDropdown (appended once to document.body, positioned
    ## via kdom style properties by the caller after each mount).
    ##
    ## A fresh WebRenderer is created each time so IsoNim reactive effects
    ## are scoped to the current render pass and do not accumulate.
    let containerNode = isonim_dom.Node(container)
    while not isonim_dom.isNodeNil(containerNode.firstChild):
      discard isonim_dom.removeChild(containerNode, containerNode.firstChild)

    let r = WebRenderer()
    let panel = renderFilterDropdownPanel[WebRenderer, isonim_dom.Element](
      r, tabs, rows, filtersEnabled, cb)
    let panelNode = isonim_dom.Node(panel)
    # Move the rendered children (toggle-buttons div, dropdown-list ul)
    # into the stable container so the container's id and event listeners
    # (added once on creation) are preserved across refreshes.
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
