import
  std / [ jsffi, asyncjs ]

# `electron_lib` is imported ONLY on the arm that uses it.
#
# The single thing this module ever wanted from it is `require`, for the
# `js-yaml` load below — and that branch is already `when not
# defined(ctRenderer) and not defined(ctInExtension)`. So on every renderer
# build the import was dead weight, and not harmless dead weight: `misc_lib` is
# imported by `renderer.nim` and by `ui/ui_imports.nim`, which means this one
# unconditional line put `electron_lib` into the import graph of all 46 modules
# that reach `ui_imports` and of the renderer entry point itself.
#
# That is why removing `electron_lib` from `ui_imports`' own import and export
# lists (NS1 residual 1) did not make the renderer web-buildable: the edge had
# a second path through here, and `{.error.}` fires on the module being
# compiled at all, not on a symbol being used. Narrowing the import to the
# branch that needs it is what actually cuts it.
when not defined(ctRenderer) and not defined(ctInExtension):
  import electron_lib

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
