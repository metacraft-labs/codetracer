import std/[options ],
  ../utilities/[ env ],
  ../trace/[ storage_and_import, ],
  ../cli/[ interactive_replay ],
  ../codetracerconf,
  shell,
  run

proc internalReplayOrUpload(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool,
  command: StartupCommand
): bool =
  # replay/console/upload
  #   interactive menu:
  #     limited list of last traces and ability
  #     to replay some of them with <id>
  # replay [<last-trace-matching-pattern>] (including cmd similar to run)
  # e.g.
  #   replay `program-name` # works
  #   # but also as in run
  #   replay `program-name original-args`
  # replay --id <id>
  # replay --trace-folder/-t <trace-output-folder>
  if interactive:
    interactiveReplayMenu(command)
    return false
  else:
    let trace = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)
    # if no trace found, findTraceForArgs directly errors on screen and quits
    if command != StartupCommand.upload:
      let recordCore = envLoadRecordCore()
      return runRecordedTrace(trace, test=false, recordCore=recordCore)
    else:
      uploadTrace(trace)
      return false


proc replay*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
): bool =
  internalReplayOrUpload(patternArg, traceIdArg, traceFolderArg, interactive, command=StartupCommand.replay)
