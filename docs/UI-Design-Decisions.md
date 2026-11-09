# UI Design Decisions

The desktop interface's deliberate design decisions, owned by Nikolay Fenixov
(GitHub `fenix-ov`). A decision here wins over a default, a refactor's
convenience and, on matters of look and interaction, a planned-feature spec
written before it.

The team agreed this record after part 6's × on the strip tabs was removed by a
regression fix (`66bd1d60b`, PR #893). No test covered the ×, so every check that
could have noticed stayed silent. Nobody decided to remove it.

## Rules for people and agents

1. **Do not remove, undo or restyle a recorded decision as part of other work.**
   That includes refactors, regression fixes, test repairs and merges.
2. **If a decision blocks your task or looks like the cause of a bug, stop and
   ask Nikolay.** Say which decision and why, and leave it in place until they
   answer.
3. **Only Nikolay changes this file**, or someone acting on Nikolay's written
   approval linked in the PR.
4. **A failing guard means a decision went missing.** Restore the decision. Do
   not edit the guard to make the check pass.
5. **Keep the decision when you rebuild its code.** If a move or refactor changes
   the guarded text, the new code must do the same thing. Ask Nikolay to update
   the guard in the same PR.
6. **Merges can lose decisions without a conflict.** Git drops a block one side
   deleted and the other left unchanged. Run the check after every merge:
   `python3 ci/test/ui-design-decisions.py`.

Accessibility and contrast fixes are welcome. If one changes a recorded value,
keep the decision's intent and name the decision in the PR so Nikolay can update
this file.

## How the check works

Each `guard` block below lists `path :: text` pairs. The check fails if `text`
is missing from `path`. It proves the code is still there, not that it looks
right on screen, so review still matters.

Run it from the repository root. The workflow
`.github/workflows/ui-design-decisions.yml` runs it on every pull request, and
fails if someone other than Nikolay changes this file without the
`design-approved` label.

## Decisions

### D-01: Active strip tabs have a ×

The active tab on the sidebars and the status bar shows a ×. It hides the panel
and keeps the tab pinned. It looks and behaves like the × in the status bar's
tab-list menu. (2026-10-16, 2026-10-17)

```guard
src/frontend/styles/components/auto_hide.styl :: .auto-hide-strip-tab-hide
src/frontend/viewmodel/views/isonim_auto_hide_side_strip_view.nim :: if callbacks.showsHide(tab):
src/frontend/viewmodel/views/isonim_auto_hide_bottom_strip_view.nim :: if cb.showsHide(tab):
src/frontend/ui/auto_hide.nim :: onHide: proc(index: int) =
```

### D-02: The × only shows on panels opened by a click

A hover preview closes itself when the pointer leaves, so it gets no ×.
(2026-10-17)

```guard
src/frontend/viewmodel/views/isonim_auto_hide_side_strip_view.nim :: tab.active and tab.pinned
src/frontend/viewmodel/views/isonim_auto_hide_bottom_strip_view.nim :: tab.active and tab.pinned
src/frontend/ui/auto_hide.nim :: pinned: isPanelPinnedOpen(panel)
```

### D-03: The × sits 4px from the label

On a status-bar tab it also sits 4px from the tab's right end, not the usual 8px.
(2026-10-17)

```guard
src/frontend/styles/components/auto_hide.styl :: #auto-hide-bottom-strip .auto-hide-strip-tab:has(.auto-hide-strip-tab-hide)
src/frontend/styles/components/auto_hide.styl :: margin-left: 0.25rem
```

### D-04: A minimal sidebar uses the tab-list menu, not a row of icons

The menu already lists every pinned panel, so individual icons appear only when
the menu is not available. (2026-10-15, 2026-10-16)

```guard
src/frontend/viewmodel/views/isonim_auto_hide_collapsed_icons_view.nim :: if not callbacks.hasTabList:
```

### D-05: The location path is hidden from the status bar for now

A deliberate choice for the current iteration, made knowing that
`footer-visibility-css-guard.spec.ts` and `status-bar-footer-contract.spec.ts`
fail while the rule exists. Ask Nikolay before bringing it back. (2026-10-15)

```guard
src/frontend/styles/components/status_bar.styl :: #status #status-base .location-path
```

### D-06: Panel buttons share one look and a 100ms hover

Non-primary buttons in the panels of an open trace use the look and states of the
Requests panel's pickers. Hover is 100ms because the earlier timing read as lag.
(2026-10-20)

```guard
src/frontend/styles/components/button.styl :: control-button()
src/frontend/styles/components/button.styl :: control-button-active()
src/frontend/styles/components/button.styl :: BUTTON_TRANSITION_TIMING = 100ms ease
```

### D-07: Event Log columns are reordered by dragging

A drag handle on each row of the Columns menu replaced the move-left and
move-right arrows. Hidden columns can be placed too. The menu uses the shared
menu row, and the "Columns +" button uses the medium control size. From the
keyboard, the handle takes focus and Enter or Space moves its row one position
lower; a mouse click on it moves nothing. Inside the menu, Up and Down move
between rows and Left and Right between a row's check and handle. (2026-10-20,
2026-11-02)

```guard
src/frontend/viewmodel/views/isonim_event_log_view.nim :: EventLogColumnHandleClass
src/frontend/viewmodel/views/isonim_event_log_view.nim :: wireColumnDrag(vm, rowEl, item, dragged)
src/frontend/viewmodel/views/isonim_event_log_view.nim :: " ct-menu-item"
src/frontend/viewmodel/views/isonim_event_log_view.nim :: "ct-button-md-secondary "
src/frontend/viewmodel/viewmodels/event_log_vm.nim :: func placeColumn*
src/frontend/viewmodel/viewmodels/event_log_vm.nim :: func placeColumnLower*
src/frontend/viewmodel/views/isonim_event_log_view.nim :: wireColumnHandleKey(vm, handleEl, item)
```

### D-08: Every checkbox is the design system's Checkbox

It is built once as `.ct-checkmark` and has no per-panel overrides or text
glyphs. Source: the design system's Checkbox page, Figma node 69:2282.
(2026-10-20)

```guard
src/frontend/styles/components/checkmark.styl :: .ct-checkmark
src/frontend/viewmodel/views/isonim_event_log_view.nim :: span(class = "ct-checkmark",
src/frontend/viewmodel/views/isonim_welcome_screen_view.nim :: span(class = "ct-checkmark", `aria-hidden` = "true")
```

### D-09: Strip tabs are matched to panels by key, not title

Two panels can share a title, such as two UNIFIED DIFFs, and the outline must
still reach the right tab. (2026-10-20)

```guard
src/frontend/viewmodel/views/isonim_auto_hide_side_strip_view.nim :: `data-ct-panel-key` = tab.key
src/frontend/viewmodel/views/isonim_auto_hide_bottom_strip_view.nim :: `data-ct-panel-key` = tab.key
src/frontend/ui/auto_hide.nim :: data-ct-docked-key
```

### D-10: Status-bar tabs are centred in the window

They sit in the middle of the bar, not after the left-hand readouts.
(2026-10-16)

```guard
src/frontend/styles/components/auto_hide.styl :: // CENTRED in the status bar
src/frontend/styles/components/auto_hide.styl :: position: absolute
```

### D-11: Panel content has an 8px inset

Toolbars, rows and values start on the same line as the tab title, in every
panel. (2026-09-14)

```guard
src/frontend/styles/components/button.styl :: PANEL_INSET = 0.5rem
```

### D-12: One 6px corner for the tab and its panel

Tabs, strip tabs, and docked and overlay panels share one corner size.
(2026-10-15)

```guard
src/frontend/styles/components/golden_layout.styl :: TAB_CORNER_RADIUS = 0.375rem
```

### D-13: The agent status pill is grey

Figma `status-pill`, node 3689:26, with neutral colours rather than the blue
`running` ones, because an agent has no run state to colour yet. (2026-10-16,
2026-10-17)

```guard
src/frontend/styles/components/agent_activity.styl :: agent-status-pill()
src/frontend/styles/components/agent_activity.styl :: background: colors-ui-surface-primary-tertiary
```

### D-14: The welcome screens keep their own button look

The shared look in D-06 is for the panels of an open trace only. (2026-10-21)

```guard
src/frontend/styles/components/welcome_screen.styl :: // The welcome screens keep their own button look
```

### D-15: The selected panel outline is subtle and grey

It uses `colors-ui-border-primary`, `#565656` in the dark theme, and not the brand
colour. This is a deliberate exception to the 3:1 contrast floor: the outline
measures about 2:1 against the panel. Commit `4424bd111` had changed it to
`colors-ui-border-action` to meet that floor. Do not change it back to meet a
contrast target without asking Nikolay. (2026-08-21, reaffirmed 2026-11-02)

```guard
src/frontend/styles/components/golden_layout.styl :: SELECTED_PANEL_BORDER_COLOR = colors-ui-border-primary
```

### D-16: key-focus is the one keyboard selection style

A control selected from the keyboard shows `key-focus`: a 1.5px border inside its
edge, `#3B82F6` in the dark themes and `#2563EB` in the light ones, the same on
every control. It matches the main menu buttons. The width is deliberate: 2px is
only required at WCAG's AAA level, and an outer ring would crowd these dense panels. The current row of a menu shows it too,
in place of a filled row; the command palette follows D-28. Do not give a control its own focus ring, and do not
remove one. Text fields show it only when reached with Tab. (2026-11-02)

```guard
src/frontend/styles/components/button.styl :: KEY_FOCUS_WIDTH = 0.09375rem
src/frontend/styles/components/button.styl :: by-mode(colors-blue-500, colors-blue-600)
src/frontend/styles/components/menu_item.styl :: &.ct-menu-item--active:not(.ct-menu-item--disabled)
src/frontend/styles/components/button.styl :: key-focus()
src/frontend/styles/components/shared_widgets.styl :: html:not([data-focus-mode="mouse"]) *:focus-visible:not(input)
```

### D-17: Enter and Space both press a focused button

A button or link selected from the keyboard answers both keys, in every panel. A
list's row, an open menu, the command palette and the editor keep their own Enter.
(2026-11-02)

```guard
src/frontend/ui/key_router.nim :: if name == "Enter" and not menuIsOpen() and not contextMenuIsOpen() and
```

### D-18: Dropdowns work from the keyboard, and one thing looks selected

A dropdown is one Tab stop. Opening moves to the chosen row, the arrow keys move
between rows, Enter or Space picks one, Escape closes and returns to the trigger,
and Tab or a click elsewhere closes it. At most one dropdown is open. The chosen option has a subtle grey fill, not `key-focus`,
because it marks a saved value rather than the keyboard's place. Only one element
shows `key-focus` at a time. (2026-11-02)

```guard
src/frontend/viewmodel/views/keyboard_focus.nim :: installKeyboardFocus(cstring DropdownListSelector
src/frontend/viewmodel/views/isonim_request_panel_view.nim :: "ct-menu-item ct-menu-item--chosen"
src/frontend/viewmodel/views/isonim_vcs_view.nim :: "ct-menu-item ct-menu-item--chosen"
src/frontend/styles/components/menu_item.styl :: &.ct-menu-item--chosen:not(.ct-menu-item--disabled)
src/frontend/ui/key_router.nim :: focusIsIn(cstring DropdownListSelector)
```

### D-19: The REQUESTS filter dropdowns have no "All" row

The Method and Status dropdowns list only real values. With no filter on, the
trigger still reads "Method: All" or "Status: All". Picking the chosen row again
turns its filter off, so a filter can always be cleared, even when it leaves no
rows to right-click for Clear Filters. The Status dropdown is as wide as its
longest row. It sits at the panel's right edge, so it grows left. (2026-11-02)

```guard
src/frontend/viewmodel/views/isonim_request_panel_view.nim :: if v.len == 0:
src/frontend/viewmodel/views/isonim_request_panel_view.nim :: pickerSelectHandler(onSelect, if isChosen: "" else: v)
src/frontend/styles/components/request_panel.styl :: .request-panel-filters > :last-child .ct-picker-dropdown
```

### D-20: A disabled button keeps its fill

Disabled changes only the text, the icon or the border, depending on the kind of
button. The fill stays as it is on an enabled button, at rest and on hover, and the
whole button is never faded with `opacity`. Applies to every kind of button,
including primary ones and the welcome screens' own look (D-14). (2026-11-02)

```guard
src/frontend/styles/components/button.styl :: Disabled changes only the text, the icon or the border, never the fill
src/frontend/styles/components/button.styl :: LOOP_ICON_DIM
src/frontend/styles/components/welcome_screen.styl :: &:hover:not(:disabled):not([aria-disabled="true"])
```

### D-21: Esc closes the open dropdown first, wherever the focus is

With a dropdown open, Esc closes that dropdown and does nothing else: it does not
clear a list's selection or hide the panel. Focus returns to the dropdown's button.
A select inside the agent settings closes before the panel does. Add every new
dropdown to `DROPDOWNS` in `views/keyboard_focus.nim`. (2026-11-02)

```guard
src/frontend/ui/key_router.nim :: closeOpenDropdown():
src/frontend/viewmodel/views/keyboard_focus.nim :: var DROPDOWNS = [
src/frontend/viewmodel/views/keyboard_focus.nim :: globalThis.__ctCloseOpenDropdown = closeOpenDropdown
```

### D-22: A focused strip tab's key-focus runs around its whole panel

When a strip tab has keyboard focus and its panel is open, in the footer or a side
strip, `key-focus` is one continuous line around the tab and the panel together. The
tab has no ring of its own, because the panel's edge and the curves that join the two
would cut it up. This holds even if another panel is the selected one; the grey
selection outline comes back when focus moves on. A tab whose panel is closed keeps
its own ring. (2026-11-02)

```guard
src/frontend/ui/layout.nim :: function showKeyFocusOnOutline(svg, tab)
src/frontend/styles/components/auto_hide.styl :: .ct-docked-outline.ct-outline--key-focus path
src/frontend/styles/components/shared_widgets.styl :: :not(.ct-key-focus-traced)
```

### D-23: A Columns menu row shows key-focus on the whole row

When a row's checkbox has keyboard focus, `key-focus` runs around the whole row, as
on every other dropdown's rows. The drag handle keeps its own small ring, because it
is a separate action reached with the Right arrow (D-07). Arrow keys count as
keyboard navigation, so a menu opened with the mouse shows `key-focus` as soon as an
arrow key moves in it. (2026-11-02)

```guard
src/frontend/styles/components/event_log.styl :: .eventLog-column-option:has(> .eventLog-column-check:focus-visible)
src/frontend/styles/components/shared_widgets.styl :: :not(.eventLog-column-check)
src/frontend/viewmodel/views/keyboard_focus.nim :: function moveFocus(ev, to)
```

### D-24: The Files tree's first arrow lines up with the panel title

The expand arrow of the Files panel's top level starts at the same left position as
the "FILES" title, 8px from the panel edge. Every deeper level moves with it, and the
hover strips still run from the panel's edge. (2026-11-02)

```guard
src/frontend/styles/components/filesystem.styl :: .filesystem.jstree-default > .jstree-container-ul > .jstree-node
```

### D-25: An active strip tab stays joined to its panel when focused

A click gives a strip tab focus, and the "no ring on a mouse click" rule clears
shadows on anything focused. The active tab's shadow is what fills the gap to its
panel, so each strip keeps it on a focused tab. Without it the strip shows through as
a dark bar. (2026-11-02)

```guard
src/frontend/styles/components/auto_hide.styl :: box-shadow: 0em -0.48em 0em 0em colors-ui-surface-base-panel !important
src/frontend/styles/components/auto_hide.styl :: box-shadow: 0.48em 0em 0em 0em colors-ui-surface-base-panel !important
src/frontend/styles/components/auto_hide.styl :: box-shadow: -0.48em 0em 0em 0em colors-ui-surface-base-panel !important
```

### D-26: Every dropdown row's text is 14px

All text in a dropdown row is 14px (`0.875rem`), in every menu and every theme: the
label, the sublabel and the shortcut. A new dropdown uses the shared row
(`ct-menu-item`), which sets this size itself, so a row must not take its size from
the menu or panel around it. The button that opens a dropdown keeps its own control
size. (2026-11-02)

```guard
src/frontend/styles/components/menu_item.styl :: font-size: 0.875rem
src/frontend/styles/components/menu_bar.styl :: font-size: 0.875rem
src/frontend/styles/components/event_log.styl :: font-size: 0.875rem
src/frontend/styles/components/text_editor.styl :: font-size: 0.875rem
src/frontend/styles/components/status_bar.styl :: font-size: 0.875rem
src/frontend/styles/components/session_tabs.styl :: font-size 0.875rem
src/frontend/styles/components/unified_diff.styl :: font-size 0.875rem
```

### D-27: Variable names use the syntax colour for identifiers

A variable's name in the State, Scratchpad and value-popup rows is
`colors/editor/syntax/plain` from the `mapped` collection: `#F3F3F3` in the dark theme
and `#1D1C1A` in the light one. Code and program data take their colours from
`colors/editor/syntax`. `colors/ui/text/primary/active` is for interface states, so it
is not used for code. (2026-11-02)

```guard
src/frontend/styles/components/state.styl :: color: colors-editor-syntax-plain
```

### D-28: The command palette's first row is marked, not focused

When the palette opens, the keyboard is in the search field, so the field shows
`key-focus`. The row Enter would run has the grey chosen fill. Once the arrow keys
move onto the rows, `key-focus` moves to the current row and the field's line goes
away. Typing puts it back in the field. A click on the field shows no line until a
key is pressed, as with every field. (2026-11-02)

```guard
src/frontend/viewmodel/views/isonim_command_palette_view.nim :: if keyNavigation: "ct-menu-item--active" else: "ct-menu-item--chosen"
src/frontend/styles/components/shared_widgets.styl :: .command-view:not(:has(.ct-menu-item--active)) .command-input-row:focus-within:not(.ct-palette-clicked)
```

### D-29: Dropdown rows have no line between them

No dropdown draws a line between its rows. The add-context menu, the status bar's
tab-list menu and the command palette's results used to, through
`dropdown-surface-row()`, while every other dropdown did not. (2026-11-02)

```guard
src/frontend/styles/components/shared_widgets.styl :: No line between rows, on any dropdown
```

### D-30: A dropdown row's hover is quieter than a list row's

A dropdown row's hover uses `colors-ui-surface-primary-default-hover`, `#262626` in
the dark themes and `#DBD6CC` in the light ones. Lists and tables keep the stronger
`#333333`, which is also the chosen row's fill, so hover no longer looks like the
chosen row. A dropdown painted `#242424` or lighter stays on the list hover, because
this colour would not show on it. (2026-11-02)

```guard
src/frontend/styles/components/button.styl :: DROPDOWN_HOVER_BG = colors-ui-surface-primary-default-hover
src/frontend/styles/components/menu_item.styl :: background: DROPDOWN_HOVER_BG
```

### D-31: One tooltip, from the design system

Every tooltip looks like the Tooltip component in Figma, with no arrow. One line is `sm`:
4px corners, 12/16 text, padding 6px and 12px in the dark theme, 4px and 8px in the light
one. Wrapped text is `lg`: 320px wide, 8px corners, padding 6px and 8px. The dark theme
is `colors/ui/surface/base/raised` with a 1px `colors/ui/border/tertiary` border inside
its edge. The light theme is `colors/ui/surface/on-color/secondary` with no border and
`colors/ui/text/primary/body` text, because Figma's `text/on-color/body` is unreadable
on that fill in the light mode. Controls
state their tooltip as a `title`, and `views/tooltips.nim` shows it in place of the
operating system's. It appears after a 0.2s rest or when the keyboard reaches the
control, and Esc, a click or moving away hides it. Every icon-only control has a tooltip.
A tooltip that repeats the text on screen shows nothing, and text cut off with an
ellipsis shows its full value. The debug toolbar keeps its `.custom-tooltip` children,
which its tests read, painted the same way. The code editor shows its own hovers, but a
tracepoint's box inside it uses this tooltip, including its run button. (2026-11-02,
tracepoint box 2026-11-03)

```guard
src/frontend/viewmodel/views/tooltips.nim :: globalThis.__ctTooltips = true
src/frontend/ui_js.nim :: import viewmodel/views/tooltips
src/frontend/styles/codetracer.styl :: @import "components/tooltip"
src/frontend/styles/components/tooltip.styl :: .ct-tooltip--lg
src/frontend/styles/components/button.styl :: background-color: by-mode(colors-ui-surface-base-raised, colors-ui-surface-on-color-secondary)
src/frontend/ui/layout.nim :: _pinBtn.title = 'Pin to the sidebar'
src/frontend/viewmodel/views/isonim_agent_activity_view.nim :: title = "Agent settings"
src/frontend/viewmodel/views/isonim_state_view.nim :: title = badgeAriaForRow(vm, item())
src/frontend/viewmodel/views/tooltips.nim :: OURS_INSIDE = '.trace'
src/frontend/ui/trace.nim :: runButton.setAttribute(cstring"title", cstring"Run tracepoints (Ctrl+Enter)")
```

### D-32: 6px between controls, from Figma, on whole pixels

Neighbouring controls are 6px apart: button and button, field and button, side by
side or stacked. The value is Figma's `space / gap/control` variable (Compact
density), which is the source of truth, so the code reads it from the generated
token as `CONTROL_GAP` in `button.styl` and never writes 6px by hand. Tabs are not
controls here: strip tabs stay 4px apart and sub-tabs keep their track. The status
bar's sidebar toggle and tab-list button still touch (2026-10-16) until Nikolay
decides otherwise. Every size lands on a whole pixel: a value that comes to a
fraction (0.24em = 3.84px, 11.6px, 14.5px) is rounded to the nearest whole pixel,
and the debug toolbar's half-pixel dividers sit in a 1px box. (2026-11-03)

```guard
src/frontend/styles/components/button.styl :: CONTROL_GAP = unit(gap-control / 16, 'rem')
src/frontend/styles/components/custom_components.styl :: gap: CONTROL_GAP
src/frontend/styles/components/shared_components.styl :: gap: CONTROL_GAP
src/frontend/styles/components/menu_bar.styl :: gap: CONTROL_GAP
src/frontend/styles/components/request_panel.styl :: gap: CONTROL_GAP
src/frontend/styles/components/shared_widgets.styl :: background: linear-gradient(to right, colors-ui-divider-primary 50%, transparent 50%)
src/frontend/styles/components/auto_hide.styl :: margin-right: 0.25rem
src/frontend/styles/components/agent_activity.styl :: margin-top: 0.875rem
```

### D-33: The session tabs' overflow button shows the Design System chevron

When the session tabs don't fit, the button that lists them all shows the chevron-down
from the Design System icons page (`icons-lg=chevron-down`), shown at 18px, not a typed "⌄"
character. It is painted through a mask in the button's text colour. The button looks
and behaves like the "+" beside it: a 26px circle filled with
`colors/ui/surface/primary/tertiary`, its mark at 70% at rest, and the "+"'s hover and
press. While its list is open, the chevron turns to point up and the circle is the hover
colour (`colors/ui/surface/primary/tertiary-hover`) at 35% opacity. Inactive session tabs
are filled with that hover colour at 25% on screen. The session tabs, the overflow
button and the "+" are all 6px apart. (2026-11-03)

```guard
src/frontend/styles/components/session_tabs.styl :: mask-image url('../../public/resources/shared/build_chevron_down.svg')
src/frontend/styles/components/session_tabs.styl :: flex 0 0 CONTROL_HEIGHT_MD
src/frontend/styles/components/session_tabs.styl :: controls (CONTROL_GAP, D-32).  Was 0.25em (4px)
src/frontend/styles/components/session_tabs.styl :: background-color rgba(colors-ui-surface-primary-tertiary-hover, 0.35)
src/frontend/styles/components/session_tabs.styl :: background-color rgba(colors-ui-surface-primary-tertiary-hover, (0.25 / 0.7))
```

### D-34: An empty trace tab hides the debugger controls

A session tab with no trace loaded (a blank welcome tab, not an edit workspace) hides
the debugger's navigation buttons in the caption bar: there is nothing for them to
step through. They keep their space, so the command prompt and the tabs do not move
when switching between an empty tab and a trace. (2026-11-03)

```guard
src/frontend/ui/session_tabs.nim :: menu.setClass(cstring CaptionBarNoTraceClass, activeSessionIsEmpty(data))
src/frontend/styles/components/menu_bar.styl :: &.menu-shell--no-trace #isonim-debug-controls
```

## Focus rules

Agreed by Nikolay on 2026-11-02, from
[WebAIM](https://webaim.org/techniques/keyboard/), the
[W3C ARIA Authoring Practices](https://www.w3.org/WAI/ARIA/apg/practices/keyboard-interface/)
and [Subux](https://subux.pro/guides/article/focus-states). They apply to all new UI
work.

**How it looks**

1. **Always visible.** Everything the keyboard can land on shows `key-focus`. Never
   remove it without a replacement. The code editor's own cursor and focus line are
   the one exception.
2. **One style.** `key-focus` is defined once, as an outline, because shadows
   disappear in Windows high-contrast mode.
3. **Keyboard only.** It appears when navigating by keyboard, not after a click.
4. **One at a time.** Only one element shows it.
5. **Each state looks different.** Focus is where the keyboard is. It must look
   different from hover and from selection, which is a saved choice that stays after
   focus leaves.

**How it moves**

6. **Tab moves between components; arrow keys move inside them.** A list, menu, set
   of tabs or dropdown is one Tab stop. Add new ones to `views/keyboard_focus.nim`.
7. **Entering a component.** Focus lands on the selected item, or the first.
8. **Order follows the layout.** Left to right, top to bottom, one section at a time.
   Never use a positive `tabindex`.
9. **Only controls take focus.** Text, cells that do nothing and containers do not.
   A pane is focused by a click or from code (`tabindex="-1"`), and a closed panel
   is hidden from Tab.
10. **Focus is never lost.** When something closes, focus returns to what opened it.
    When an item is deleted, it moves to the next item.
11. **No traps.** Esc closes menus and dialogs. A non-modal one closes when focus
    leaves it.

**Which keys do what**

12. **Standard keys.** Buttons: Enter or Space. Links: Enter. Checkboxes: Space. Tabs
    and lists: arrow keys.
13. **Shortcuts are extras.** Everything must also be reachable with Tab or arrows.
14. **Real controls first.** Use native buttons and links where possible. Custom ones
    must behave the same way.

## Standing rules

These apply to all new UI work. A source check cannot judge them, so they have
no guard. Reviewers and agents apply them by hand.

- **Typography:** Space Mono is only for code and program data. All other text,
  including titles, buttons, labels, messages and panel UI, is Space Grotesk.
- **Dark theme weight:** no font weight above 300. Space Mono stays at 400
  because it has no Light cut. Older declarations still break this rule and are
  being cleaned up.
- **Units:** write styles in `rem` or `em` (root 16px) and land on whole pixels.
  This one is checked: `ci/test/ui-design-decisions.py` fails on a px value in
  any stylesheet under `src/frontend/styles`. Comments may still say px.
- **Icons:** take them from the design system's icons page, Figma
  `Ytr6Ux4bYZYRUBpgNsSVml` node 1:12.
- **Panels:** build them as Golden Layout stacks with the standard header and
  search-field toolbar, reusing the shared field, icon button and sub-tab.
- **Cards:** keep at least 24px between content and its button. Do not rely on
  `margin-top: auto` alone.
- **Spacing:** keep paddings consistent, and fix sibling panels and screens
  together.
- **Tooltips:** give every new icon-only control a `title`, saying what it does.
  `views/tooltips.nim` shows it in the design system's Tooltip.

## Open questions

Not protected until Nikolay and the team settle them.

- **State panel tabs.** The Locals / Globals / Watches tabs and the one-row
  toolbar are in `dev` today, restored by PR #893. `Variable-State-Pane.md`
  ("Decisions (2026-10-24)") and the tests in `isonim_views_test.nim` still expect
  one list with no tabs, so those tests fail on `dev`.
