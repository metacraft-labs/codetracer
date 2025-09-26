import
  std / [
    async, strformat, strutils, sequtils, sugar, os, jsconsole,
    algorithm, jsffi
  ],
  # third party
  karax, karaxdsl, vstyles, lookuptables, # lookuptables is from karax 
  ../[ types, renderer, config, ui_helpers, utils, lang ],
  ../lib/[ jslib, logging, monaco_lib, electron_lib, misc_lib ],
  ../ services / [event_log_service, debugger_service, editor_service, flow_service, search_service, shell_service]

import kdom except Location

import vdom except Event
from dom import Element, getAttribute, Node, preventDefault, document, getElementById, querySelectorAll, querySelector, focus

proc fa*(typ: string, kl: string = ""): VNode =
  result = buildHtml(italic(class = cstring(fmt"fa fa-{typ} {kl}")))

proc jqFind*(a: cstring): js {.importcpp: "jQuery(#)".}

export
  karax, karaxdsl, kdom, async, strformat, strutils, sequtils, vstyles, jsffi, algorithm, lookuptables, vdom, sugar, os, jsconsole,
  types, renderer, config, ui_helpers, utils, focus, lang,
  jslib, logging, monaco_lib, electron_lib, misc_lib,
  event_log_service, debugger_service, editor_service, flow_service, shell_service,
  search_service
