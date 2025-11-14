import std / [options, os, osproc, strutils, strformat ],
  ../utilities/[ env, zip ],
  ../cli/[ interactive_replay ],
  ../trace / storage_and_import,
  ../../common/[ types, common_trace_index, lang, paths, config ],
  ../codetracerconf,
  shell,
  run


# TODO: re-enable if restoring multitraces:
# proc replayMultitrace*(archivePath: string, indexDiff: bool = false): bool =
#   # TODO: a more unique path? or is this enough
#   let fullArchivePath = expandFilename(expandTilde(archivePath))
#   let outputFolder = getTempDir() / "codetracer" / fullArchivePath.extractFilename.changeFileExt("")
#   unzipIntoFolder(fullArchivePath, outputFolder)

#   var traceDir = ""
#   for kind, file in walkDir(outputFolder, relative=true):
#     if kind == pcDir and file.startsWith("trace-"):
#       traceDir = outputFolder / file
#       # for now we start with supporting only 1 trace
#       # TODO: pass all the traces to the client
#       break
  
#   if traceDir.len == 0:
#     echo "ERROR: a trace folder not found inside multitrace"
#     quit(1)

#   let trace = importDbTrace(traceDir / "trace_metadata.json", NO_TRACE_ID, NO_PID, LangUnknown)
#   if trace.isNil:
#     echo fmt"ERROR: couldn't import the trace with name {traceDir.extractFilename} from the multitrace"
#     quit(1)

#   var structuredDiffPath = outputFolder / "diff.json"
#   var diffIndexPath = ""

#   if indexDiff:
#     let backend = if trace.lang.isDbBased:
#         dbBackendExe
#       else:
#         let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
#         if ctConfig.rrBackend.enabled:
#           ctConfig.rrBackend.path
#         else:
#           echo fmt"ERROR: rr backend not configured, but required for this trace lang: {trace.lang}"
#           quit(1)

#     var eventualDiffIndexPath = outputFolder / "diff_index.json"
#     if not fileExists(eventualDiffIndexPath):
#       let process = startProcess(backend, args = @["index-diff", structuredDiffPath, traceDir, outputFolder], options={poParentStreams})
#       let exitCode = waitForExit(process)

#       if exitCode == 0:
#         # replace with an archive with the indexed data
#         removeFile(archivePath)
#         zipFolder(outputFolder, archivePath)
#         diffIndexPath = eventualDiffIndexPath
#       else:
#         echo "WARN: a problem with indexing diff: no diff index"
#         diffIndexPath = "" # some kind of a problem        # indexDiffJson = ""

#     # if ok: trace patched, diff indexed: archive still accessible
#     # remove only the temp extracted folder: ok here for index-diff; not for `replay` in the next case for now
#     removeDir(outputFolder)
#     return false # this means it shouldn't restart: for now restart maybe supported in dev mode only for replays
#   else:
#     var eventualDiffIndexPath = outputFolder / "diff_index.json"
#     if fileExists(eventualDiffIndexPath):
#       diffIndexPath = eventualDiffIndexPath
#     else:
#       diffIndexPath = ""
    
#     # trace imported, diff and eventually index copied: archive still accessible
#     # remove only the temp extracted folder?
#     # TODO: stopped removing it (or remove after replay):
#     #   decide what to do for this folder: for now depend on it for index/run: 
#     # removeDir(outputFolder)

#     let recordCore = envLoadRecordCore()

#     return runRecordedTrace(trace, test=false, structuredDiffPath=structuredDiffPath, indexDiffPath=diffIndexPath, recordCore=recordCore)

# proc indexDiff*(multitracePath: string) =
#   discard replayMultitrace(multitracePath, indexDiff=true)

proc indexDiff*(tracePath: string) =
  let trace = findTraceForArgs(none(string), none(int), some(tracePath))
  if trace.isNil:
    echo fmt"ERROR: can't find a trace with path {tracePath}"
    quit(1)
  var structuredDiffPath = trace.outputFolder / "diff.json"
  let backend = dbBackendExe

  var eventualDiffIndexPath = trace.outputFolder / "diff_index.json"
  if not fileExists(eventualDiffIndexPath):
    # db-backend index-diff writes in the trace the indexed flow
    let process = startProcess(
      backend,
      args = @["index-diff", structuredDiffPath, trace.outputFolder],
      options={poParentStreams, poEchoCmd})
    let exitCode = waitForExit(process)

    if exitCode == 0:
      echo "OK"
      quit(0)
    else:
      echo "ERROR: backend couldn't index diff: exit code ", exitCode
      quit(exitCode)

  else:
    echo "WARN: trace already with indexed diff: not indexing again"
    quit(0)

  # discard runRecordedTrace(trace, test=false, recordCore=recordCore, indexDiff=true)
  # discard replayMultitrace(multitracePath, indexDiff=true)

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
      # TODO: when restoring multitraces: 
      # if filename.startsWith("multitrace-") and filename.endsWith(".zip"):
        # return replayMultitrace(traceFolder)

    # not a multitrace:

    trace = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)

    if trace.isNil and traceFolderArg.isSome:
      trace = importTrace(traceFolderArg.get(), NO_TRACE_ID, NO_PID, LangUnknown)
    if trace.isNil:
      echo "ERROR: can't find or import trace"
      quit(1)
  return runRecordedTrace(trace, test=false, recordCore=recordCore)
