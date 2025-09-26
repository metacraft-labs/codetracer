import
  dom, jsffi, vdom, strutils, sequtils,
  lib/jslib

import kdom except Location, document

const
  commandPrefix* = ":"

template byId*(id: typed): untyped =
  document.getElementById(`id`)

template byClass*(class: typed): untyped =
  document.getElementsByClassName(`class`)

template byTag*(class: typed): untyped =
  document.getElementsByTagName(`tag`)

template findElement*(selector: cstring): kdom.Element =
  kdom.document.querySelector(`selector`)

template jq*(selector: typed): untyped =
  dom.document.querySelector(`selector`)

template jqall*(selector: typed): untyped =
  dom.document.querySelectorAll(`selector`)

proc findAllNodesInElement*(element: kdom.Node, selector: cstring): seq[kdom.Node] {.importjs:"Array.from(#.querySelectorAll(#))".}

proc findNodeInElement*(element: kdom.Node, selector: cstring): js {.importjs:"#.querySelector(#)".}

proc isHidden*(e: kdom.Element): bool =
  e.classList.contains(cstring("hidden"))

proc hideDomElement*(e: kdom.Element) =
  e.classList.add(cstring("hidden"))

proc showDomElement*(e: kdom.Element) =
  e.classList.remove(cstring("hidden"))

proc isActive*(e: kdom.Element): bool =
  e.classList.contains(cstring("active"))

proc activateDomElement*(e: kdom.Element) =
  e.classList.add(cstring("active"))

proc deactivateDomElement*(e: kdom.Element) =
  e.classList.remove(cstring("active"))

proc hide*(e: dom.Element) =
  e.style.display = cstring"none"

proc show*(e: dom.Element) =
  e.style.display = cstring"block"

proc parentElement*(e: dom.Element): dom.Element =
  if not e.isNil:
    result = cast[dom.Element](e.parentNode)
  else:
    result = nil

proc scrollBy*(e: dom.Element, deltaX: int, deltaY: int) {.importjs: "#.scrollBy(#,#)".}

proc createDom*(tag: string, attr: JsObject, content: string): dom.Node = discard

# EXAMPLE: onclick = proc(e: Event, v: VNode) =
#           onClicks(
#               e,
#             proc = dropdown ..,
#             proc = select all kinds from category,
#             100)

proc onClicks*(e: kdom.Event, onClick: proc (ev: kdom.Event, et: VNode), onDoubleClick: proc (ev: kdom.Event, et: VNode), timeout: int, id: var int) =
  case cast[kdom.UIEvent](e).detail:
  of 1:
    let timeout = windowSetTimeout(proc =
    #  echo "onclicks: after timeout: before onclick"
      onClick(e, nil), timeout)
    # e.target.toJs.timeoutId = timeout # workaround because it is difficult to map DOM elements to timeouts
    id = timeout
    # echo "onclicks 1 ", timeout
  of 2:
    let currentId = id # e.target.toJs.timeoutId
    # kout cstring"onclicks 2 start ", currentId
    if currentId != 0:
      windowClearTimeout(currentId)
      id = 0
    onDoubleClick(e,nil)
  else:
    discard

proc eattr*(e: dom.Element, s: string): cstring {.importcpp: "#.getAttribute('data-' + toJSStr(#))" .}
proc eattr*(e: dom.Node, s: string): cstring {.importcpp: "#.getAttribute('data-' + toJSStr(#))" .}
proc eattr*(e: kdom.Node, s: string): cstring {.importcpp: "#.getAttribute('data-' + toJSStr(#))" .}
proc eattr*(e: js, s: string): cstring {.importcpp: "#.getAttribute('data-' + toJSStr(#))" .}
proc createElementNS*(document: dom.Document, a: cstring, b: cstring): dom.Element {.importcpp: "(#.createElementNS(#, #))".}
proc append*(element: dom.Element, other: dom.Element) {.importcpp: "(#.append(#))".}

proc convertStringToHtmlClass*(input : cstring): cstring =
  var normalString: string
  let pattern =  regex("([a-zA-Z][a-zA-Z0-9-]+)")
  var matches = input.matchAll(pattern)

  normalString = ($(matches.mapIt(it[0]).join(cstring"-"))).toLowerAscii()

  return normalString.cstring
