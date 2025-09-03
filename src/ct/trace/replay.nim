import std / [options, os],
  ../utilities/[ env ],
  ../cli/[ interactive_replay ],
  ../trace / storage_and_import,
  ../../common/[ types, common_trace_index, lang ],
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
    
    if trace.isNil and traceFolderArg.isSome:
      trace = importDbTrace(traceFolderArg.get() / "trace_metadata.json", NO_TRACE_ID, NO_PID, LangUnknown)
    if trace.isNil:
      echo "ERROR: can't find or import trace"
      quit(1)
  return runRecordedTrace(trace, test=false, recordCore=recordCore)
