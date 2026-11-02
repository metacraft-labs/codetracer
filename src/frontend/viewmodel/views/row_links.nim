## row_links.nim — a linked shared row's attributes, on every renderer.
##
## Shared-DOM-Front-Ends D10: with a host's link builder, a Call Trace row's
## call text is an `<a>` and an Event Log row's index cell holds one. Its
## `href` is what the builder makes of the row's address, and it follows the
## row as the section scrolls (the views reuse a row's element for the next
## call or event). A builder may answer `""` for a row it cannot address; that
## row then has NO `href` — an empty one would be a link to the page itself,
## focusable and navigable — so the attribute is set and removed here, in one
## render effect, rather than bound through the DSL, which writes an empty
## string as an empty attribute.
##
## Generic over the renderer (`MockRenderer` in the headless lanes,
## `WebRenderer` in every page and webview), like the views it serves.

import isonim/core/computation

proc bindLinkAttributes*[R, N](r: R; el: N; link: proc(): string;
                               asButtonWhenUnlinked = false) =
  ## Keep `el`'s `href` equal to `link()`, and absent while it is empty.
  ##
  ## With `asButtonWhenUnlinked`, an unlinked `el` is the `role="button"` with
  ## a tab stop the row would have been without a builder (`isonim_activation`
  ## answers Enter and Space on an `<a>` only while it has no `href`), and a
  ## linked one drops both: a link announces and focuses itself.
  mixin setAttribute, removeAttribute
  createRenderEffect proc() =
    let url = link()
    if url.len > 0:
      r.setAttribute(el, "href", url)
      if asButtonWhenUnlinked:
        r.removeAttribute(el, "role")
        r.removeAttribute(el, "tabindex")
    else:
      r.removeAttribute(el, "href")
      if asButtonWhenUnlinked:
        r.setAttribute(el, "role", "button")
        r.setAttribute(el, "tabindex", "0")
