## views/agent_harbor_dropdown_view.nim
##
## The design system's Dropdown for the Agent Harbor Changes panel and Inbox
## (`isonim_agent_harbor_changes_view.nim`, `isonim_agent_harbor_inbox_view.nim`):
## a trigger that shows the chosen value in full and an arrow, and, while it
## is open, a menu of the design system's dropdown items under it.
##
## The design system has no native select: its Dropdown is a trigger over a
## menu whose rows are its `dropdown-item` component (CodeTracer's
## `.ct-menu-item`, `styles/components/menu_item.styl`) on the shared
## dropdown surface (`dropdown-surface-chrome()`,
## `styles/components/shared_widgets.styl`), the way the omnibox composer
## opens its add-context menu (`isonim_agent_harbor_composer_view.nim`,
## `.ah-composer-menu`). The trigger keeps the compact select's look
## (`.ah-changes-select`, `agent_harbor_changes.styl`), so it is the same
## size beside the panel's other controls; it is as wide as the value it
## shows, never cut to a placeholder.
##
## Whether the menu is open is the host's drawing state, as a pointer's hover
## is (the terminal's dropped select, `ah_tui_changes_inbox_parts.drawSelect`,
## keeps it the same way): nothing a viewmodel or a story records. Picking a
## row closes the menu and hands its id to `pick`, which calls the
## viewmodel; the dropdown decides nothing about what a choice does.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

export signals, computation, components

const
  DropdownArrow* = "\xE2\x96\xBE"
    ## ▾ after the value, as the terminal's closed select draws it.

type
  DropdownChoice* = object
    ## One row of the menu: the id handed to `pick`, the words it shows.
    id*, label*: string

proc pickPress(open: Signal[bool]; pick: proc(id: string); id: string): proc() =
  ## A row's press: a proc of its own so each closure owns its id (a closure
  ## made in a Nim loop body shares the body's variables with every other
  ## iteration's, https://nim-lang.org/docs/manual.html#closures-creating-closures-in-loops).
  result = proc() =
    open.val = false
    if pick != nil: pick(id)

proc renderAgentHarborDropdown*[R, N](r: R; shown: string; choices: seq[DropdownChoice];
                                      current: string; pick: proc(id: string);
                                      cls = ""; title = ""): N =
  ## A dropdown showing `shown`; open, its menu lists `choices`, `current`
  ## marked active. `cls` goes on the trigger (`ah-changes-select` and the
  ## control's own class), `title` is the trigger's tooltip.
  mixin clearChildren, setAttribute, appendChild
  let open = createSignal(false)
  var trigger, menuHost: N
  result = ui(r):
    span(class = "ah-dropdown"):
      button(ref = trigger, class = "ah-dropdown-trigger " & cls, title = title,
             `aria-haspopup` = "listbox", `data-ah-dropdown` = shown,
             onclick = proc() = open.val = not open.val):
        # Cut, where its row is narrower than it, by the views' one rule
        # (`ah_cut_text`, `data-ah-cut`), never by CSS's ellipsis.
        span(`data-ah-cut` = "line", class = "ah-dropdown-value", title = shown):
          text shown
        span(class = "ah-dropdown-arrow", `aria-hidden` = "true"):
          text DropdownArrow
      span(ref = menuHost, class = "ah-dropdown-menu-host")
  createRenderEffect proc() =
    let isOpen = open.val
    r.clearChildren(menuHost)
    r.setAttribute(trigger, "aria-expanded", if isOpen: "true" else: "false")
    if not isOpen: return
    var menu: N
    let m = ui(r):
      tdiv(ref = menu, class = "ah-dropdown-menu", role = "listbox")
    r.appendChild(menuHost, m)
    for choice in choices:
      # Plain values and a press made before the DSL, which wraps an event
      # handler in a closure of its own (a closure may not capture the
      # loop's borrowed item).
      let id = choice.id
      let label = choice.label
      let on = id == current
      let press = pickPress(open, pick, id)
      let row = ui(r):
        tdiv(class = "ah-dropdown-item ct-menu-item" & (if on: " ct-menu-item--active" else: ""),
             role = "option", `aria-selected` = (if on: "true" else: "false"),
             `data-ah-dropdown-item` = id, onclick = press):
          span(class = "ct-menu-item-label"):
            text label
      r.appendChild(menu, row)
