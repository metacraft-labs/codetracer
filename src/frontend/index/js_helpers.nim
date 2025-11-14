import std/jsffi

proc jsHasKey*(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}
