import std / [ async, jsffi, strutils, sequtils, sugar, dom, strformat, os, jsconsole, json ]
import results
import lib, types, lang, paths, index_config, config, trace_metadata
import rr_gdb
import program_search
import ../common/ct_logging

import index/ipc_events/[ install, files, window, startup, traces, args, tabs, menu, online_sharing, ipc_utils, electron_vars ]

data.start = now()
parseArgs()
when not defined(server):
  electron_vars.app.on("window-all-closed") do ():
    electron_vars.app.quit(0)

  electron_vars.app.on("ready") do ():
    electron_vars.app.js.setName "CodeTracer"
    electron_vars.app.js.setAppUserModelId "com.codetracer.CodeTracer"
    discard ready()
else:
  readyVar = functionAsJs(ready)
  setupServer()
