## dom_pointer_test_host.nim — a jsdom suite's page as a DOM front-end hosts a
## pane: the pane's host carries its scope (`data-scope-kind="pane"`), and a
## press on the pane's elements goes through the one pointer listener
## (`viewmodel/input/dom_pointer`), the shipped router over the shipped base
## keymap's pointer rows, and the shipped procedures (`input/pane_presses`)
## over the suite's own ViewModels — what the desktop's key router and a VS
## Code panel install. Nothing here stands in for the product.

import isonim/web/dom_api

import ../viewmodel/input/[pane_presses, dom_pane_presses]

proc documentBodyEl(): Element {.importjs: "(document.body)@".}
proc newDiv(): Element {.importjs: "document.createElement('div')".}

proc paneHost*(paneKind: string): Element =
  ## A pane's host in the document, as a DOM front-end's: mount the view in it.
  result = newDiv()
  result.setAttribute(cstring"data-scope-kind", cstring"pane")
  result.setAttribute(cstring"data-scope-id", cstring(paneKind))
  discard appendChild(Node(documentBodyEl()), Node(result))

proc routePresses*(perform: proc(operation: string;
                                 attr: AttributeReader): bool) =
  ## Every press on a pane's element through the base keymap's pointer rows,
  ## performed by `perform` (a suite's `pane_presses` call over its VMs) —
  ## the shipped `installPanePointerRoutingWith`, as an embedder calls it.
  installPanePointerRoutingWith(perform)
