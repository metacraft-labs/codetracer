## ct_scenario_stage.nim — `ct-scenario-stage`, the CodeTracer pack's stages
## for the desktop's binding (TypeScript), which cannot link them.
##
##   ct-scenario-stage init <state.json> [<root>]     a fresh, isolated state root
##   ct-scenario-stage run <state.json> <use> <args-json>
##                                                     one stage call; prints the
##                                                     prepared launch as JSON
##   ct-scenario-stage remove <state.json>             delete the state root
##
## The state of a run lives in <state.json> between calls. The stages are
## `ct_stages.nim`'s, the ones the terminal and GPUI bindings run in process.

import std/[json, os]
import ./ct_stages

when isMainModule:
  let args = commandLineParams()
  if args.len < 2:
    stderr.writeLine "usage: ct-scenario-stage init|run|remove <state.json> ..."
    quit 64
  let statePath = args[1]
  try:
    case args[0]
    of "init":
      let s = newStageState(if args.len > 2: args[2] else: "")
      s.saveTo(statePath)
      echo $s.toJson()
    of "run":
      if args.len < 4:
        stderr.writeLine "usage: ct-scenario-stage run <state.json> <use> <args-json>"
        quit 64
      let s = loadFrom(statePath)
      s.runStage(args[2], parseJson(args[3]))
      s.saveTo(statePath)
      echo $s.toJson()
    of "remove":
      if fileExists(statePath):
        loadFrom(statePath).removeStage()
        removeFile(statePath)
    else:
      stderr.writeLine "unknown command " & args[0]
      quit 64
  except CatchableError as e:
    stderr.writeLine e.msg
    quit 1
