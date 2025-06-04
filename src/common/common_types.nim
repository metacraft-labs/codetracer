# backend agnostic code, part of the types module, should not be imported directly,
# use common/types or frontend/types instead.
import
  strformat, strutils, sequtils, macros, json, times, typetraits, results, paths

import task_and_event

# this module is used in codetracer and core and in the nim plugin so
# it needs to support both C and JavaScript
# try to use langstring when something is
#  string in c backend and cstring in javascript backend
# TODO unify most type definitions for the backends
# currently a lot of app data is saved in data: Data and it's accessed as a global object in renderer.nim and ui_js.nim

include
  common_types/[ notifications, tokens, graveyard ],
  common_types/debugger_features/events,
  common_types/language_features/[ code, "type", "value", value_history, "macro" ],
  common_types/debugger_features/[ breakpoint, call, trace, debugger, flow, frontend, jumps, shell, stepping, tracepoints ]

export task_and_event

include
  common_types/utils/[ errors, constants, meta, text_representation, timer ]
