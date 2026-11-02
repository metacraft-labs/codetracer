## dropdown_focus.nim — the keyboard half of a dropdown (a trigger that opens a
## list of rows): the Requests panel's Method and Status filters, the VCS branch
## picker and the agent prompt's add-context menu
## (docs/UI-Design-Decisions.md, D-18).
##
## A view's trigger and rows carry `role="button"` and a tab stop, so
## `isonim_activation` presses them with Enter or Space. This module adds what a
## dropdown needs on top of that:
##
##   * opening moves the focus to the chosen row, else the first, so only one
##     thing looks selected and the next Tab stays in the list;
##   * Up, Down, Home and End move between the rows;
##   * Escape closes it, and closing from the keyboard returns to the trigger;
##   * focus leaving closes it, so at most one dropdown is open.
##
## THE LISTENERS ARE ON THE DOCUMENT, ONCE. The views rebuild a dropdown's whole
## element each time it opens or closes, so nothing on the element would survive.
## They do no work until a dropdown's trigger or row is involved.
##
## It imports nothing, for the same reason as `isonim_activation`.

when defined(js):
  const
    ContainerSelector* = ".ct-picker, .vcs-branch-picker, .agent-add-context-wrapper"
    TriggerSelector* = ".ct-picker-trigger, .vcs-branch-current, .agent-add-context-button"
    ListSelector* = ".ct-picker-dropdown, .vcs-branch-dropdown, .agent-add-context-dropdown"

  proc installDropdownFocus(container, trigger, list: cstring) {.importjs: """
    (function (CONTAINER, TRIGGER, LIST) {
      if (typeof document === 'undefined' || globalThis.__ctDropdownFocus) return;
      globalThis.__ctDropdownFocus = true;
      var ROW = '.ct-menu-item:not(.ct-menu-item--disabled)';
      // Closing it ourselves clicks the trigger; that click must not move focus.
      var closing = false;
      // A press inside the dropdown's box is not focus leaving it: on macOS a
      // pressed button takes no focus, and closing here would let the same
      // press's click reopen it.
      var pressedIn = null;
      // Only a dropdown closed from the keyboard gives the focus back: after a
      // mouse click the focus belongs to whatever was clicked.
      var fromKeys = false;
      document.addEventListener('keydown', function () { fromKeys = true; }, true);
      function closeQuietly(trigger) {
        closing = true;
        trigger.click();
        closing = false;
      }
      document.addEventListener('mousedown', function (ev) {
        fromKeys = false;
        pressedIn = closest(ev.target, CONTAINER);
      }, true);
      document.addEventListener('mouseup', function () {
        setTimeout(function () { pressedIn = null; }, 0);
      }, true);
      function closest(el, sel) { return el && el.closest ? el.closest(sel) : null; }
      function rows(list) { return Array.prototype.slice.call(list.querySelectorAll(ROW)); }
      function focusAfterRender(pick) {
        requestAnimationFrame(function () {
          var el = pick();
          if (el) el.focus({ preventScroll: false });
        });
      }
      function openList(trigger) {
        var box = closest(trigger, CONTAINER);
        return box ? box.querySelector(LIST) : null;
      }
      function returnToTrigger(index) {
        focusAfterRender(function () { return document.querySelectorAll(TRIGGER)[index]; });
      }
      function triggerIndex(el) {
        return Array.prototype.indexOf.call(document.querySelectorAll(TRIGGER), el);
      }
      document.addEventListener('click', function (ev) {
        if (closing) return;
        var t = ev.target;
        var trigger = closest(t, TRIGGER);
        if (trigger) {
          var index = triggerIndex(trigger);
          var keyed = ev.detail === 0 && fromKeys;
          focusAfterRender(function () {
            var now = document.querySelectorAll(TRIGGER)[index];
            var list = now ? openList(now) : null;
            if (!list) return keyed ? now : null;
            return list.querySelector('.ct-menu-item--chosen') || rows(list)[0] || null;
          });
          return;
        }
        var row = closest(t, ROW);
        var list = row ? closest(row, LIST) : null;
        if (list && ev.detail === 0 && fromKeys) {
          returnToTrigger(triggerIndex(closest(list, CONTAINER).querySelector(TRIGGER)));
        }
      }, true);
      document.addEventListener('keydown', function (ev) {
        var el = ev.target;
        var list = closest(el, LIST);
        if (!list) return;
        var all = rows(list);
        var at = all.indexOf(closest(el, ROW));
        var next = null;
        if (ev.key === 'ArrowDown') next = all[Math.min(at + 1, all.length - 1)];
        else if (ev.key === 'ArrowUp') next = all[Math.max(at - 1, 0)];
        else if (ev.key === 'Home') next = all[0];
        else if (ev.key === 'End') next = all[all.length - 1];
        else if (ev.key === 'Escape') {
          var trigger = closest(list, CONTAINER).querySelector(TRIGGER);
          var index = triggerIndex(trigger);
          ev.preventDefault();
          ev.stopPropagation();
          closeQuietly(trigger);
          returnToTrigger(index);
          return;
        }
        if (next) { ev.preventDefault(); next.focus(); }
      });
      document.addEventListener('focusout', function (ev) {
        var box = closest(ev.target, CONTAINER);
        if (!box || !document.contains(ev.target) || !document.hasFocus()) return;
        if (ev.relatedTarget && box.contains(ev.relatedTarget)) return;
        if (pressedIn === box) return;
        if (!box.querySelector(LIST)) return;
        var trigger = box.querySelector(TRIGGER);
        if (trigger) closeQuietly(trigger);
      });
    })(#, #, #)""".}

  installDropdownFocus(cstring ContainerSelector, cstring TriggerSelector,
                       cstring ListSelector)
