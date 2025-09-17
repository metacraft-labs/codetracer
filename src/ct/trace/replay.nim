import std / [options, os, strutils, strformat ],
  ../utilities/[ env, zip ],
  ../cli/[ interactive_replay ],
  ../trace / storage_and_import,
  ../../common/[ types, common_trace_index, lang ],
  ../codetracerconf,
  shell,
  run


proc replayMultitrace*(archivePath: string): bool =
  # TODO: a more unique path? or is this enough
  let outputFolder = getTempDir() / "codetracer" / archivePath.extractFilename.changeFileExt("")
  unzipIntoFolder(archivePath, outputFolder)

  var traceDir = ""
  for kind, file in walkDir(outputFolder, relative=true):
    if kind == pcDir and file.startsWith("trace-"):
      traceDir = outputFolder / file
      # for now we start with supporting only 1 trace
      # TODO: pass all the traces to the client
      break
  
  if traceDir.len == 0:
    echo "ERROR: a trace folder not found inside multitrace"
    quit(1)

  let trace = importDbTrace(traceDir / "trace_metadata.json", NO_TRACE_ID, NO_PID, LangUnknown)
  if trace.isNil:
    echo fmt"ERROR: couldn't import the trace with name {traceDir.extractFilename} from the multitrace"
    quit(1)

  var structuredDiffJson = ""
  try:
    structuredDiffJson = readFile(outputFolder / "diff.json")
  except CatchableError as e:
    # assume no diff.json recorded: that's ok
    # we might have just a multitrace to replay multiple traces at once without a diff
    # in the future
    structuredDiffJson = ""

  # trace imported, diff copied: archive still accessible
  # remove only the temp extracted folder
  removeDir(outputFolder)

  let recordCore = envLoadRecordCore()
  return runRecordedTrace(trace, test=false, structuredDiffJson=structuredDiffJson, recordCore=recordCore)

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
    if traceFolderArg.isSome:
      let traceFolder = traceFolderArg.get
      let filename = traceFolder.extractFilename
      if filename.startsWith("multitrace-") and filename.endsWith(".zip"):
        return replayMultitrace(traceFolder)

    # not a multitrace:

    trace = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)

    if trace.isNil and traceFolderArg.isSome:
      trace = importDbTrace(traceFolderArg.get() / "trace_metadata.json", NO_TRACE_ID, NO_PID, LangUnknown)
    if trace.isNil:
      echo "ERROR: can't find or import trace"
      quit(1)
  return runRecordedTrace(trace, test=false, recordCore=recordCore)
