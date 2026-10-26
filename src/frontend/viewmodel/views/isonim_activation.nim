## isonim_activation.nim — the keyboard half of a shared view's clickable
## element.
##
## A row of the Call Trace, a row of the Event Log, a value-history line of
## the Variables pane: each answers a click, and each is drawn with the hand
## cursor. Front-End-Architecture §7 forbids an interactive `div`, so such an
## element must announce itself and be operable without a pointer
## (https://www.w3.org/WAI/ARIA/apg/patterns/button/): it carries
## `role="button"` and a tab stop (`tabindex="0"`) in its markup — written in
## the view's DSL, so every renderer, the headless ones included, carries
## them — and Enter or Space does what its click does.
##
## THE KEY HALF IS ONE LISTENER, NOT ONE PER ELEMENT. A native `button` turns
## Enter and Space into a `click`; an element with `role="button"` does not,
## so this module does the same for every one: a single `keydown` listener on
## the document turns Enter or Space on a focused `[role="button"]` that is
## not itself a native control into that element's `click()`. The handler the
## view already attached then runs, so the keyboard cannot drift from the
## pointer, and a view adds a row by adding the two attributes. It is
## installed when a view that draws such rows is loaded (each imports this
## module), once.
##
## It imports nothing: a view that draws such rows imports it for this
## effect, and the Embed SDK's facade, which reaches some of those views, must
## not reach a rendering module through it (CodeTracer-Embed-SDK.md §3.2).

when defined(js):
  proc isActivationKey*(key: string): bool =
    ## Enter and Space ("Spacebar" is the name older engines report).
    key == "Enter" or key == " " or key == "Spacebar"

  proc installDocumentActivation(isKey: proc(key: cstring): bool) {.importjs: """
    (function (isKey) {
      if (typeof document === 'undefined' || globalThis.__ctRoleButtonKeys) return;
      globalThis.__ctRoleButtonKeys = true;
      document.addEventListener('keydown', function (ev) {
        var el = ev.target;
        if (!el || ev.repeat || ev.defaultPrevented || !el.getAttribute) return;
        if (el.getAttribute('role') !== 'button') return;
        // A native control already answers its own keys; text input is typing.
        var tag = el.tagName;
        if (tag === 'BUTTON' || tag === 'A' || tag === 'INPUT' ||
            tag === 'TEXTAREA' || tag === 'SELECT' || el.isContentEditable) return;
        if (el.getAttribute('aria-disabled') === 'true') return;
        if (!isKey(ev.key || '')) return;
        ev.preventDefault();
        el.click();
      });
    })(#)""".}

  installDocumentActivation(proc(key: cstring): bool = isActivationKey($key))
