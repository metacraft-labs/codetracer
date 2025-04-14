import std/options,
  ../utilities/[ env ],
  ../cli/[ interactive_replay ],
  ../../common/[ types ],
  ../codetracerconf,
  shell,
  run


proc replay*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
): bool =
  let recordCore = envLoadRecordCore()
  var trace: Trace

  if interactive:
    trace = interactiveTraceSelectMenu(StartupCommand.replay);
  else:
    trace = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)
  return runRecordedTrace(trace, test=false, recordCore=recordCore)
