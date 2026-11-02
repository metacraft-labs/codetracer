## row_link_dom.nim — what a click on a linked shared row does.
##
## Shared-DOM-Front-Ends D10: when a host passes a link builder, a Call Trace
## row's call text is an `<a href>` and an Event Log row's index cell carries
## one. The link exists for the browser's own affordances — middle-click,
## "open in new tab", "copy link", the status bar. A plain click must still do
## what the row's click always did (select it and move the debugger) and must
## NOT navigate, because the session is already open on the recording; and a
## modified click must be the browser's alone, because the visitor asked for
## the navigation, not for the seek.
##
## One capture-phase listener on the row decides, before the row's own
## handlers run (https://dom.spec.whatwg.org/#dispatching-events: capture
## listeners on an ancestor run before the target's):
##
##   * a primary click with no modifier on a link inside the row: cancel the
##     navigation (`preventDefault`) and let the click reach the row's
##     handlers as usual;
##   * a click with a modifier (Ctrl, Meta, Shift, Alt) or another button:
##     stop it here (`stopPropagation`), so no row handler runs, and leave the
##     default action — opening the URL — to the browser.
##
## A middle click dispatches `auxclick`, not `click`
## (https://w3c.github.io/uievents/#event-type-auxclick), so it never reaches
## the row's click handlers and needs nothing here.
##
## Enter on a focused `<a href>` dispatches a `click` with no modifier, so it
## takes the first branch: the keyboard selects and goes, as a pointer does.

when defined(js):
  import isonim/web/dom_api as isonim_dom

  proc attachRowLinkClicksJs(row: isonim_dom.Element) {.importjs: """
    (function (row) {
      if (!row || !row.addEventListener) return;
      row.addEventListener('click', function (ev) {
        var t = ev.target;
        if (!t || !t.closest) return;
        var link = t.closest('a[href]');
        if (!link || !row.contains(link)) return;
        if (ev.button !== 0 || ev.ctrlKey || ev.metaKey || ev.shiftKey ||
            ev.altKey) {
          ev.stopPropagation();
          return;
        }
        ev.preventDefault();
      }, true);
    })(#)""".}

  proc attachRowLinkClicks*(row: isonim_dom.Element) =
    ## Make a plain click on a link inside `row` the row's click and a
    ## modified one the browser's (see the module comment).
    attachRowLinkClicksJs(row)
