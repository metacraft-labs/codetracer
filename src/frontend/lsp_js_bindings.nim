import std/jsffi

when defined(js):
  proc newWebSocket*(url: cstring): JsObject {.importjs: "new WebSocket(#)".}
  proc closeWebSocket*(ws: JsObject) {.importjs: "#.close()".}
  proc setTimeout*(callback: proc() {.closure.}; delay: int): int {.importjs: "setTimeout(#, #)".}
  proc clearTimeout*(timerId: int) {.importjs: "clearTimeout(#)".}
  proc field*(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
  proc isUndefined*(value: JsObject): bool {.importjs: "(# === undefined)".}
  proc construct1*(ctor: JsObject; arg: JsObject): JsObject {.importjs: "new #(#)".}
  proc call0*(fn: JsObject): JsObject {.importjs: "#()".}
  proc call1*(fn: JsObject; arg: JsObject): JsObject {.importjs: "#(#)".}
  proc newObject*(): JsObject {.importjs: "({})".}
  proc newArray*(): JsObject {.importjs: "([])".}
  proc setField*(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
  proc push*(target: JsObject; value: JsObject) {.importjs: "#.push(#)".}
  proc toJs*(str: cstring): JsObject {.importjs: "#".}
  proc requireModule*(name: cstring): JsObject {.importjs: "require(#)".}
  proc arrayLen*(arr: JsObject): int {.importjs: "#.length".}
  proc arrayAt*(arr: JsObject; idx: int): JsObject {.importjs: "#[#]".}
  proc toCString*(value: JsObject): cstring {.importjs: "String(#)".}
else:
  {.error: "lsp_js_bindings can only be used with the JS backend.".}
