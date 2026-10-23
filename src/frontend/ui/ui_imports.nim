import
  std / [
    asyncjs, strformat, strutils, sequtils, sugar, os, jsconsole,
    algorithm, jsffi
  ],
  ../[ types, renderer, config, utils, lang, js_assoc ],
  # `electron_lib` is deliberately NOT here. It was imported and re-exported to
  # every module that imports `ui_imports` -- 46 of them -- for zero uses: an
  # audit of all 14 of its exported symbols found none referenced anywhere under
  # `ui/`. (`fs` and `currentPath` appear to match, and neither is its: one is
  # the FACADE's `ctPlatform().fs` plus JavaScript inside an `importjs` string,
  # the other a local parameter and a file-diff field.)
  #
  # Dropping it is hygiene with a purpose: a blanket re-export puts Electron's
  # host bindings in 46 namespaces, where the next use of one is invisible in
  # review and silently un-webs another module. `renderer.nim` still imports it
  # directly, for two `inElectron` checks, so this does not remove it from the
  # transitive graph -- it removes it from 46 SURFACES.
  ../lib/[ jslib, logging, monaco_lib, misc_lib ],
  ../ services / [event_log_service, debugger_service, editor_service, flow_service, search_service, shell_service]

import kdom except Location

from dom import Element, getAttribute, Node, preventDefault, document, getElementById, querySelectorAll, querySelector, focus

proc jqFind*(a: cstring): js {.importcpp: "jQuery(#)".}

export
  kdom, asyncjs, strformat, strutils, sequtils, jsffi, algorithm, js_assoc, sugar, os, jsconsole,
  types, renderer, config, utils, focus, lang,
  jslib, logging, monaco_lib, misc_lib,
  event_log_service, debugger_service, editor_service, flow_service, shell_service,
  search_service
