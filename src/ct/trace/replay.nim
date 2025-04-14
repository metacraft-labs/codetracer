import std/[options ],
  ../utilities/[ env ],
  ../trace/[ storage_and_import, ],
  ../cli/[ interactive_replay ],
  ../codetracerconf,
  shell,
  run


proc replayCommand*(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
): bool =
  var tracePath: string
  if interactive:
    tracePath = interactiveTraceSelectMenu();
  else 
    tracePath = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)
  return runRecordedTrace(tracePath, test=false, recordCore=recordCore)
