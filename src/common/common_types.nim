# backend agnostic code, part of the types module, should not be imported directly,
# use common/types or frontend/types instead.
import
  strformat, strutils, sequtils, macros, json, times, results, paths

import task_and_event

# The `ct/load-flow` wire vocabulary, re-exported so the `include`d
# `codetracer_features/flow.nim` can build its enum bridge on it and every
# consumer of `common_types` sees the same spellings the engine parses.
import flow_mode_wire
export flow_mode_wire

# PLAT-2's value-presentation pipeline. A NORMAL import, unlike everything in
# the `include` list below, because `PValue` and `Presentation` are plain trees
# of `string` and therefore have exactly one spelling whichever way `langstring`
# is bound. That is the whole point: the terminal reaches the same presenter
# through `value_presentation/json_adapter`, and one type meets in the middle.
#
# Re-exported so every consumer of `common/types` or `frontend/types` — which is
# every surface — can name `Budget`, `Presentation` and the per-surface budgets
# without a second import.
import value_presentation
export value_presentation

# this module is used in codetracer and core and in the nim plugin so
# it needs to support both C and JavaScript
# try to use langstring when something is
#  string in c backend and cstring in javascript backend
# TODO unify most type definitions for the backends
# currently a lot of app data is saved in data: Data and it's accessed as a global object in renderer.nim and ui_js.nim

include
  common_types/graveyard,
  common_types/codetracer_features/[ notifications, events ],
  common_types/utils/constants,
  common_types/language_features/[ tokens, code, "type", "value", value_history, "macro" ],
  common_types/debugger_features/[ breakpoint, call, dap_types, trace, debugger, jumps],
  common_types/codetracer_features/[ flow, diff, deepreview, deepreview_from_diff, agentic_coding, frontend, shell_and_ci, stylus ],
  common_types/debugger_features/[ stepping, tracepoints ]

export task_and_event

include
  common_types/utils/[ errors, meta, text_representation, timer,
                       value_presentation_bridge ]

# TODO: think if this is useful/where to put validation or type safety
# type
#   CtEvent* = ref object
#     case kind*: CtEventKind:
#     of CtUpdateTable: ctUpdateTableArg*: UpdateTableArgs
#     of CtUpdatedTable: ctUpdatedTableData*: CtUpdatedTableResponseBody
#     of CtUpdatedTableResponse: discard
#     of CtSubscribe: ctSubscribeArg*: CtEventKind
#     of CtLoadLocals: ctLoadLocalsArg*: LoadLocalsArg
#     of CtLoadLocalsResponse: ctLoadLocalsResponseValue*: CtLoadLocalsResponseBody
#     of CtUpdatedCalltrace: ctUpdatedCalltraceData*: CtUpdatedCalltraceResponseBody
#     else: discard

# func rawValue*(event: CtEvent): JsObject =
#   case event.kind:
#   of CtUpdateTable: event.ctUpdateTableArg.toJs
#   of CtUpdatedTable: event.ctUpdatedTableData.toJs
#   of CtUpdatedTableResponse: jsNull
#   of CtSubscribe: event.ctSubscribeArg
#   of CtLoadLocals: event.ctLoadLocalsArg
#   of CtLoadLocalsResponse: event.ctLoadLocalsResponseValue
#   of CtUpdatedCalltrace: event.ctUpdatedCalltraceData
#   else: jsNull
