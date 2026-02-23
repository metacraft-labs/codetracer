import
  std / [ jsffi, async ],
  electron_lib

type
  Chalk* {.importc.} = ref object
    yellow*: proc(s: cstring): cstring
    blue*: proc(s: cstring): cstring
    red*: proc(s: cstring): cstring
    green*: proc(s: cstring): cstring
    keyword*: proc(color: cstring): proc(s: cstring): cstring
    bold*: proc(s: cstring): cstring
    underline*: proc(s: cstring): cstring

  Yaml* {.importc.} = ref object
    load*: proc(a: cstring): js

  Fuzzysort* = object
    goAsync*:   proc(query: cstring, data: seq[js], options: FuzzyOptions): Future[seq[FuzzyResult]]
    go*:   proc(query: cstring, data: seq[js], options: FuzzyOptions): seq[FuzzyResult]
    prepare*:   proc(path: cstring): js
    highlight*: proc(results: FuzzyResult, open, close: cstring): cstring

  FuzzyResult* = object
    score*:     int
    target*:    cstring
    obj*:       js
    `"_indexes"`*: seq[int]

  FuzzyOptions* = object
    limit*: int
    allowTypo*: bool
    threshold*: int
    all*: bool

when defined(ctRenderer):
  proc tippy*(query: cstring, options: JsAssoc[cstring, JsObject]): JsObject {.importc.}

var yaml*: Yaml
when not defined(ctRenderer) and not defined(ctInExtension):
  yaml = cast[Yaml](require("js-yaml"))

var Mousetrap* {.importc.}: js
