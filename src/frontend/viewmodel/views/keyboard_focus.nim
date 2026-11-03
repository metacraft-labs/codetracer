## keyboard_focus.nim — how the keyboard moves through the desktop's composite
## controls (docs/UI-Design-Decisions.md, "Focus rules").
##
## Tab moves between components and arrow keys move inside them, so each list,
## set of tabs or dropdown is one Tab stop. This module holds that behaviour for:
##
##   * dropdowns (a trigger that opens a list): the Requests filters, the VCS
##     branch picker, the agent's add-context menu and the Event Log's Columns
##     menu. Opening moves to the chosen row, else the first; Up, Down, Home and
##     End move; Escape closes; closing returns to the trigger; focus leaving
##     closes it, without moving the focus from where it went;
##   * roving composites: the Variables tabs and list controls, the strip tabs,
##     the Event Log's header and rows, and the file tree.
##
## A view's elements carry `role="button"` and a tab stop, so `isonim_activation`
## presses them with Enter or Space.
##
## THE LISTENERS ARE ON THE DOCUMENT, ONCE. Views rebuild these elements as they
## change, so nothing attached to one would survive. For the same reason the Tab
## stops are settled when Tab is pressed, not when a view renders; no work runs
## until a key or click involves one of these controls.

when defined(js):
  const
    DropdownListSelector* =
      ".ct-picker-dropdown, .vcs-branch-dropdown, .agent-add-context-dropdown, .eventLog-columns-menu"
    CompositeItemSelector* =
      ".state-tabs button, #auto-hide-bottom-strip .auto-hide-strip-tab, " &
      "#auto-hide-bottom-strip .auto-hide-strip-tab-hide, " &
      "#auto-hide-strip-left .auto-hide-strip-tab, #auto-hide-strip-left .auto-hide-strip-tab-hide, " &
      "#auto-hide-strip-right .auto-hide-strip-tab, #auto-hide-strip-right .auto-hide-strip-tab-hide, " &
      ".eventLog-column-header .eventLog-cell, .eventLog-rows .eventLog-row, " &
      ".isonim-state .value-history-button, .isonim-state .ct-origin-badge"
      ## Elements whose arrow keys are handled here. The router leaves them be.

  proc focusIsIn*(selector: cstring): bool {.importjs: """
    (function (sel) {
      var el = document.activeElement;
      return !!(el && el.closest && el.closest(sel));
    })(#)""".}

  proc closeOpenDropdown*(): bool {.importjs: """
    (globalThis.__ctCloseOpenDropdown ? globalThis.__ctCloseOpenDropdown() : false)""".}
    ## Closes the innermost open dropdown; false when none is open. The key
    ## router calls this before it routes Escape, because a pane's own Escape
    ## (`list.clear-selection`) would otherwise take the key and stop it
    ## (docs/UI-Design-Decisions.md, D-21).

  proc installKeyboardFocus(lists: cstring) {.importjs: """
    (function (LIST) {
      if (typeof document === 'undefined' || globalThis.__ctKeyboardFocus) return;
      globalThis.__ctKeyboardFocus = true;
      var CONTAINER = '.ct-picker, .vcs-branch-picker, .agent-add-context-wrapper';
      var TRIGGER = '.ct-picker-trigger, .vcs-branch-current, .agent-add-context-button, .eventLog-columns-button';
      var COLUMNS = '.eventLog-columns-menu';
      var COLUMN_ITEM = '.eventLog-column-check, .eventLog-column-handle';
      var STRIP_ITEM = '.auto-hide-strip-tab, .auto-hide-strip-tab-hide';
      var COMPOSITES = [
        { box: '.state-tabs', item: 'button', axis: 'h', press: true, current: '.active' },
        { box: '[id="auto-hide-bottom-strip"]', item: STRIP_ITEM, axis: 'h', current: '.active' },
        { box: '[id="auto-hide-strip-left"], [id="auto-hide-strip-right"]', item: STRIP_ITEM, axis: 'v', current: '.active' },
        { box: '.eventLog-column-header', item: '.eventLog-cell', axis: 'h' },
        { box: '.eventLog-rows', item: '.eventLog-row', axis: 'v' },
        { box: '.isonim-state', item: '.value-history-button, .ct-origin-badge', axis: 'both' },
        { box: '.filesystem', item: '.jstree-anchor' }
      ];
      // EVERY dropdown Escape closes, innermost first, so a settings select
      // closes before the panel it sits in. Add new dropdowns here.
      //   open    — matches the list, or a marker, while it is open;
      //   box     — the control around it, where `trigger` is looked up;
      //   trigger — clicked to close it, and given the focus afterwards;
      //   prev    — the trigger is the element just before the list;
      //   blur    — the button's menu follows its focus, so closing is a blur
      //             and focus cannot go back to it without reopening it.
      var DROPDOWNS = [
        { open: '.agent-settings-dropdown-list', box: '.agent-settings-select-wrapper', trigger: '.agent-settings-select-trigger' },
        { open: '.agent-settings-panel', box: '.agent-settings-host', trigger: '.agent-settings-done', focus: '.agent-settings-button' },
        { open: '.agent-model-dropdown', box: '.agent-model-wrapper', trigger: '.agent-model-select' },
        { open: '.agent-branch-dropdown', box: '.agent-branch-wrapper', trigger: '.agent-branch-button' },
        { open: '.agent-add-context-dropdown', box: '.agent-add-context-wrapper', trigger: '.agent-add-context-button' },
        { open: '.ct-picker-dropdown', box: '.ct-picker', trigger: '.ct-picker-trigger' },
        { open: '.vcs-branch-dropdown', box: '.vcs-branch-picker', trigger: '.vcs-branch-current' },
        { open: '.eventLog-columns-menu', box: '.eventLog', trigger: '.eventLog-columns-button' },
        { open: '.session-tab-bar.overflow-open', box: '.session-tab-bar', trigger: '.session-tab-overflow' },
        { open: '.dropdown-list.active', prev: true },
        { open: '[id="category-image"].open', blur: true }
      ];
      // Closing it ourselves clicks the trigger; that click must not move focus.
      var closing = false;
      // A press inside a dropdown is not focus leaving it: on macOS a pressed
      // button takes no focus, and closing here would let its click reopen it.
      var pressed = null;
      function closest(el, sel) { return el && el.closest ? el.closest(sel) : null; }
      function all(root, sel) { return Array.prototype.slice.call(root.querySelectorAll(sel)); }
      function shown(el) { return !!el && getComputedStyle(el).display !== 'none'; }
      function triggerFor(list) {
        var box = closest(list, CONTAINER);
        if (box) return box.querySelector(TRIGGER);
        var pane = closest(list, '.eventLog');
        return pane ? pane.querySelector('.eventLog-columns-button') : null;
      }
      function listFor(trigger) {
        var box = closest(trigger, CONTAINER);
        var list = box ? box.querySelector(LIST)
                       : (closest(trigger, '.eventLog') || document).querySelector(COLUMNS);
        return shown(list) ? list : null;
      }
      function itemsOf(list) {
        return all(list, list.matches(COLUMNS) ? COLUMN_ITEM : '.ct-menu-item');
      }
      function triggerIndex(el) { return all(document, TRIGGER).indexOf(el); }
      function afterRender(fn) { requestAnimationFrame(fn); }
      // An arrow key is the keyboard navigating too, even in a menu the mouse
      // opened, so the row it lands on must show key-focus. Only here, where a
      // key moved the focus: an arrow typed in a clicked text field stays quiet.
      function moveFocus(ev, to) {
        ev.preventDefault();
        document.documentElement.setAttribute('data-focus-mode', 'keyboard');
        to.focus();
      }
      // On screen: a hidden panel's open dropdown must not swallow the key.
      function onScreen(el) { return el.getClientRects().length > 0 && shown(el); }
      function closeOpenDropdown() {
        for (var i = 0; i < DROPDOWNS.length; i++) {
          var d = DROPDOWNS[i];
          var open = all(document, d.open).filter(onScreen)[0];
          if (!open) continue;
          if (d.blur) { open.blur(); return true; }
          var box = d.box ? closest(open, d.box) : null;
          var trigger = d.prev ? open.previousElementSibling : box ? box.querySelector(d.trigger) : null;
          if (!trigger) continue;
          var back = d.focus || d.trigger;
          var index = back ? all(document, back).indexOf(d.focus ? all(document, back).filter(onScreen)[0] : trigger) : -1;
          closing = true; trigger.click(); closing = false;
          afterRender(function () {
            var now = back ? all(document, back)[index] : trigger;
            if (now) now.focus();
          });
          return true;
        }
        return false;
      }
      globalThis.__ctCloseOpenDropdown = closeOpenDropdown;
      function settleStops() {
        COMPOSITES.forEach(function (c) {
          all(document, c.box).forEach(function (box) {
            var items = all(box, c.item);
            var active = document.activeElement;
            var stop = items.indexOf(active) >= 0 ? active
              : (c.current && box.querySelector(c.current)) || items[0];
            items.forEach(function (it) { it.setAttribute('tabindex', it === stop ? '0' : '-1'); });
            if (c.item === '.jstree-anchor' && items.length) box.setAttribute('tabindex', '-1');
          });
        });
      }
      function moveInComposite(ev) {
        for (var i = 0; i < COMPOSITES.length; i++) {
          var c = COMPOSITES[i];
          if (!c.axis) continue;
          var box = closest(ev.target, c.box);
          if (!box || !ev.target.matches(c.item)) continue;
          var items = all(box, c.item);
          var at = items.indexOf(ev.target);
          var both = c.axis === 'both';
          var back = c.axis === 'h' ? 'ArrowLeft' : 'ArrowUp';
          var on = c.axis === 'h' ? 'ArrowRight' : 'ArrowDown';
          var next = ev.key === on || (both && ev.key === 'ArrowRight') ? items[Math.min(at + 1, items.length - 1)]
            : ev.key === back || (both && ev.key === 'ArrowLeft') ? items[Math.max(at - 1, 0)]
            : ev.key === 'Home' ? items[0]
            : ev.key === 'End' ? items[items.length - 1] : null;
          if (!next || next === ev.target) return;
          moveFocus(ev, next);
          if (c.press) {
            var index = items.indexOf(next);
            var sel = c.box;
            next.click();
            afterRender(function () {
              var b = document.querySelector(sel);
              var now = b ? all(b, c.item)[index] : null;
              if (now) now.focus();
            });
          }
          return;
        }
      }
      function moveInList(ev, list) {
        var items = itemsOf(list);
        var at = items.indexOf(closest(ev.target, list.matches(COLUMNS) ? COLUMN_ITEM : '.ct-menu-item'));
        var step = list.matches(COLUMNS) ? 2 : 1;
        var next = ev.key === 'ArrowDown' ? items[at + step]
          : ev.key === 'ArrowUp' ? items[at - step]
          : ev.key === 'ArrowRight' && step === 2 && at % 2 === 0 ? items[at + 1]
          : ev.key === 'ArrowLeft' && step === 2 && at % 2 === 1 ? items[at - 1]
          : ev.key === 'Home' ? items[at % step]
          : ev.key === 'End' ? items[items.length - step + (at % step)] : null;
        if (next) moveFocus(ev, next);
      }
      document.addEventListener('mousedown', function (ev) { pressed = ev.target; }, true);
      document.addEventListener('mouseup', function () {
        setTimeout(function () { pressed = null; }, 0);
      }, true);
      document.addEventListener('keydown', function (ev) {
        if (ev.key === 'Tab') settleStops();
      }, true);
      document.addEventListener('keydown', function (ev) {
        // For a host with no key router (the VS Code extension's views). On the
        // desktop the router has already closed it and stopped the key.
        if (ev.key === 'Escape' && closeOpenDropdown()) {
          ev.preventDefault();
          ev.stopPropagation();
          return;
        }
        var list = closest(ev.target, LIST);
        if (list) moveInList(ev, list);
        else moveInComposite(ev);
      });
      document.addEventListener('click', function (ev) {
        if (closing) return;
        var trigger = closest(ev.target, TRIGGER);
        if (trigger) {
          var index = triggerIndex(trigger);
          afterRender(function () {
            var now = all(document, TRIGGER)[index];
            var list = now ? listFor(now) : null;
            var to = !now ? null : !list ? now
              : list.querySelector('.ct-menu-item--chosen') || itemsOf(list)[0] || now;
            if (to) to.focus();
          });
          return;
        }
        var list = closest(ev.target, LIST);
        if (list) {
          var opener = triggerFor(list);
          var at = triggerIndex(opener);
          afterRender(function () {
            if (document.contains(list) && shown(list)) return;
            var now = all(document, TRIGGER)[at];
            if (now) now.focus();
          });
          return;
        }
        var tab = closest(ev.target, STRIP_ITEM);
        var key = tab ? closest(tab, '[data-ct-panel-key]') : null;
        if (key) {
          var panel = key.getAttribute('data-ct-panel-key');
          afterRender(function () {
            if (document.activeElement && document.activeElement !== document.body) return;
            var again = document.querySelector('.auto-hide-strip-tab[data-ct-panel-key="' + panel + '"]');
            if (again) again.focus();
          });
        }
      }, true);
      document.addEventListener('focusout', function (ev) {
        var t = ev.target;
        if (!document.contains(t) || !document.hasFocus()) return;
        var list = closest(t, LIST);
        var trigger = list ? triggerFor(list) : closest(t, TRIGGER);
        if (!list && trigger) list = listFor(trigger);
        if (!list || !trigger || !shown(list)) return;
        var to = ev.relatedTarget;
        if (to && (list.contains(to) || trigger.contains(to))) return;
        if (pressed && (list.contains(pressed) || trigger.contains(pressed))) return;
        closing = true; trigger.click(); closing = false;
      });
    })(#)""".}

  installKeyboardFocus(cstring DropdownListSelector)
