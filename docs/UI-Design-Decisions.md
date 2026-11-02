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
only required at WCAG's AAA level, and an outer ring would crowd these dense panels. The current row of a menu or the command palette shows it too,
in place of a filled row. Do not give a control its own focus ring, and do not
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
- **Icons:** take them from the design system's icons page, Figma
  `Ytr6Ux4bYZYRUBpgNsSVml` node 1:12.
- **Panels:** build them as Golden Layout stacks with the standard header and
  search-field toolbar, reusing the shared field, icon button and sub-tab.
- **Cards:** keep at least 24px between content and its button. Do not rely on
  `margin-top: auto` alone.
- **Spacing:** keep paddings consistent, and fix sibling panels and screens
  together.

## Open questions

Not protected until Nikolay and the team settle them.

- **State panel tabs.** The Locals / Globals / Watches tabs and the one-row
  toolbar are in `dev` today, restored by PR #893. `Variable-State-Pane.md`
  ("Decisions (2026-10-24)") and the tests in `isonim_views_test.nim` still expect
  one list with no tabs, so those tests fail on `dev`.
