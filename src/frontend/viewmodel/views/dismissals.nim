## dismissals.nim — what `Escape` closes before anything else does.
##
## Owns: the stack of open transient surfaces (a dropdown's popover, a revealed
## dock, a right-click menu, an image preview). Each registers how to close
## itself; `keyboard_focus.closeOpenDropdown`, which the key router calls before
## it routes `Escape` and a host with no router calls from its one listener, asks
## them newest first. So no surface installs its own key listener
## (Input-Routing-And-Keymaps.md §6).
##
## Refuses to own: keys, and what closing a surface means.

when defined(js):
  proc registerDismissal*(close: proc(): bool) {.importjs:
    "(globalThis.__ctDismissals = globalThis.__ctDismissals || []).push(#)".}
    ## `close` answers whether it closed something open.

  proc unregisterDismissal*(close: proc(): bool) {.importjs: """
    (function (f) {
      var list = globalThis.__ctDismissals || [];
      var at = list.indexOf(f);
      if (at >= 0) list.splice(at, 1);
    })(#)""".}
