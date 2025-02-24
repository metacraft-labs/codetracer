import
  async, strformat, strutils, sequtils, sugar, dom, os, jsconsole,
  karax, karaxdsl, vstyles, jsffi, algorithm, lookuptables,
  ../lib, ../types, ../renderer, ../config, ../ui_helpers, ../utils, ../lang,
  ../ services / [event_log_service, debugger_service, editor_service, calltrace_service, history_service, flow_service, search_service, shell_service]

import kdom except Location

import vdom except Event
from dom import Element, getAttribute, Node, preventDefault, document, getElementById, querySelectorAll, querySelector, focus

proc fa*(typ: string, kl: string = ""): VNode =
  result = buildHtml(italic(class = "fa fa-$1 $2" % [$typ, kl]))

proc jqFind*(a: cstring): js {.importcpp: "jQuery(#)".}

export karax, karaxdsl, kdom, async, strformat, strutils, sequtils, vstyles, jsffi, algorithm, lookuptables, vdom, sugar, os, jsconsole
export lib, types, renderer, config, ui_helpers, utils, focus, lang
export event_log_service, debugger_service, editor_service, calltrace_service, history_service, flow_service, shell_service
export search_service
