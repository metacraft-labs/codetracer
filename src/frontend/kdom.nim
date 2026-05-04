when not defined(js):
  {.error: "frontend/kdom requires the JS backend".}

import std/dom as dom

export dom

proc `disabled=`*(n: Node; v: bool) {.importcpp: "#.disabled = #", nodecl.}
