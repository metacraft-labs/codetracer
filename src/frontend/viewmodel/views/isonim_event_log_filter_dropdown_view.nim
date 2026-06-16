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

import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
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
# Sub-element renderers — MockRenderer
# ---------------------------------------------------------------------------

proc renderTab(r: MockRenderer; tab: FilterTabRecord; index: int;
               cb: FilterDropdownCallbacks): MockNode =
  ui(r):
    button(class = "ct-tab",
           `data-selected` = (if tab.isSelected: "true" else: ""),
           onclick = proc() = cb.invokeTabClick(index)):
      text tab.label

proc renderKindCheckbox(r: MockRenderer; kind: FilterKindRecord;
                        tagIndex, kindIndex: int;
                        cb: FilterDropdownCallbacks): MockNode =
  let ti = tagIndex
  let ki = kindIndex
  ui(r):
    label(class = "ct-checkmark-field"):
      input(class = "ct-checkmark-input",
            `type` = "checkbox",
            value = $kindIndex,
            onchange = proc() = cb.invokeKindToggle(ti, ki))
      span(class = "ct-checkmark",
           `data-state` = kind.checkState,
           `aria-hidden` = "true"):
        discard
      span(class = "ct-checkmark-label"):
        text kind.label

proc renderTagRow(r: MockRenderer; row: FilterTagRow; tagIndex: int;
                  cb: FilterDropdownCallbacks): MockNode =
  let ti = tagIndex
  ui(r):
    li(class = "dropdown-list-row"):
      label(class = "ct-checkmark-field"):
        input(class = "ct-checkmark-input",
              `type` = "checkbox",
              value = $tagIndex,
              onchange = proc() = cb.invokeTagToggle(ti))
        span(class = "ct-checkmark",
             `data-state` = row.checkState,
             `aria-hidden` = "true"):
          discard
        span(class = "ct-checkmark-label"):
          text row.label
      tdiv(class = "dropdown-kind-items"):
        for ki, kind in row.kinds:
          renderKindCheckbox(r, kind, tagIndex, ki, cb)

proc renderFilterDropdownPanel*(r: MockRenderer;
                                tabs: seq[FilterTabRecord];
                                rows: seq[FilterTagRow];
                                filtersEnabled: bool = true;
                                cb: FilterDropdownCallbacks =
                                  FilterDropdownCallbacks()): MockNode =
  ## Render the full dropdown DOM tree (tab row + tag/kind grid).
  ## Returns the outer .dropdown-container element; children can be moved
  ## into a stable host via mountFilterDropdownInto.
  let checkedAttr = if filtersEnabled: "true" else: "false"
  let toggleLabel = if filtersEnabled: "ENABLED" else: "DISABLED"
  ui(r):
    tdiv(class = "dropdown-container"):
      tdiv(class = "toggle-buttons"):
        for i, tab in tabs:
          renderTab(r, tab, i, cb)
        tdiv(class = "toggle-enabled-wrapper"):
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
      ul(class = "dropdown-list", id = FilterDropdownListId):
        for i, row in rows:
          renderTagRow(r, row, i, cb)

# ---------------------------------------------------------------------------
# Sub-element renderers — WebRenderer
# ---------------------------------------------------------------------------

when defined(js):
  proc renderTab(r: WebRenderer; tab: FilterTabRecord; index: int;
                 cb: FilterDropdownCallbacks): isonim_dom.Element =
    ui(r):
      button(class = "ct-tab",
             `data-selected` = (if tab.isSelected: "true" else: ""),
             onclick = proc() = cb.invokeTabClick(index)):
        text tab.label

  proc renderKindCheckbox(r: WebRenderer; kind: FilterKindRecord;
                          tagIndex, kindIndex: int;
                          cb: FilterDropdownCallbacks): isonim_dom.Element =
    let ti = tagIndex
    let ki = kindIndex
    ui(r):
      label(class = "ct-checkmark-field"):
        input(class = "ct-checkmark-input",
              `type` = "checkbox",
              value = $kindIndex,
              onchange = proc() = cb.invokeKindToggle(ti, ki))
        span(class = "ct-checkmark",
             `data-state` = kind.checkState,
             `aria-hidden` = "true"):
          discard
        span(class = "ct-checkmark-label"):
          text kind.label

  proc renderTagRow(r: WebRenderer; row: FilterTagRow; tagIndex: int;
                    cb: FilterDropdownCallbacks): isonim_dom.Element =
    let ti = tagIndex
    ui(r):
      li(class = "dropdown-list-row"):
        label(class = "ct-checkmark-field"):
          input(class = "ct-checkmark-input",
                `type` = "checkbox",
                value = $tagIndex,
                onchange = proc() = cb.invokeTagToggle(ti))
          span(class = "ct-checkmark",
               `data-state` = row.checkState,
               `aria-hidden` = "true"):
            discard
          span(class = "ct-checkmark-label"):
            text row.label
        tdiv(class = "dropdown-kind-items"):
          for ki, kind in row.kinds:
            renderKindCheckbox(r, kind, tagIndex, ki, cb)

  proc renderFilterDropdownPanel*(r: WebRenderer;
                                  tabs: seq[FilterTabRecord];
                                  rows: seq[FilterTagRow];
                                  filtersEnabled: bool = true;
                                  cb: FilterDropdownCallbacks =
                                    FilterDropdownCallbacks()): isonim_dom.Element =
    ## Render the full dropdown DOM tree (tab row + tag/kind grid).
    ## Returns the outer .dropdown-container element; children are moved
    ## into the stable host container by mountFilterDropdownInto.
    let checkedAttr = if filtersEnabled: "true" else: "false"
    let toggleLabel = if filtersEnabled: "ENABLED" else: "DISABLED"
    ui(r):
      tdiv(class = "dropdown-container"):
        tdiv(class = "toggle-buttons"):
          for i, tab in tabs:
            renderTab(r, tab, i, cb)
          tdiv(class = "toggle-enabled-wrapper"):
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
        ul(class = "dropdown-list", id = FilterDropdownListId):
          for i, row in rows:
            renderTagRow(r, row, i, cb)

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
    let panel = renderFilterDropdownPanel(r, tabs, rows, filtersEnabled, cb)
    let panelNode = isonim_dom.Node(panel)
    # Move the rendered children (toggle-buttons div, dropdown-list ul)
    # into the stable container so the container's id and event listeners
    # (added once on creation) are preserved across refreshes.
    while not isonim_dom.isNodeNil(panelNode.firstChild):
      discard isonim_dom.appendChild(containerNode, panelNode.firstChild)
