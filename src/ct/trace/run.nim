import std/[os, osproc, strformat, sequtils, options],
  ../../common/[ paths, lang, types, trace_index ],
  ../launch/electron,
  ../utilities/[ env, language_detection ],
  ../cli/[logging, build],
  ../globals,
  record

# run a recorded trace based on args, a saving project for it in the process
# Note: This function does not return on POSIX (launchElectron uses execv)
proc runRecordedTrace*(
  trace: Trace,
  test: bool,
  # TODO: we use those if we restore multitraces
  structuredDiffPath: string = "",
  indexDiffPath: string = "",
  recordCore: bool = false,
  newTracePolicy: string = "",
  inspect: Option[string] = none(string),
  remoteDebuggingPort: Option[string] = none(string),
  remoteDebuggingPipe: bool = false,
) =
  var args = if test: @[$trace.recordingId, "--test"] else: @[$trace.recordingId]
  let traceStructuredDiffPath = trace.outputFolder / "diff.json"
  let traceIndexDiffPath = trace.outputFolder / "diff_index.json"
  if existsFile(traceStructuredDiffPath):
    args.add("--diff")
    args.add(traceStructuredDiffPath)
    if existsFile(traceIndexDiffPath):
      args.add("--diff-index")
      args.add(traceIndexDiffPath)
  launchElectron(args, trace, ElectronLaunchMode.Default, recordCore, test,
                 inspect = inspect,
                 remoteDebuggingPort = remoteDebuggingPort,
                 remoteDebuggingPipe = remoteDebuggingPipe,
                 newTracePolicy = newTracePolicy)


proc runWithRestart(
  test: bool,
  recordCore: bool = false,
  lang: Lang = LangUnknown,
  recordArgs: seq[string] = @[],
  newTracePolicy: string = ""
) =
  var afterRestart = false

  while true:
    var recordedTrace: Trace = nil

    if lang == LangUnknown:
      errorMessage fmt"error: lang unknown: probably an unsupported type of project/extension, or folder/path doesn't exist?"
      quit(1)
    else:
      let extension = if lang notin {LangRustWasm, LangCppWasm}:
          getExtension(lang)
        else:
          "wasm"

      var outputFolder = ""
      var nimcachePath = ""

      # For Nim, pre-create the trace folder so we can set nimcache to be inside it
      # This matches the legacy backend behavior where generated C files are kept in the trace.
      # M-REC-7: folder name is the bare ``recording_id`` (UUIDv7) — see paths.recordingFolder.
      if lang == LangNim:
        let traceID = trace_index.newID(test=false)
        outputFolder = recordingFolder(codetracerShareFolder, traceID)
        createDir(outputFolder)
        nimcachePath = outputFolder / "nimcache"

      let program = if lang.usesMaterializedTraces:
          recordArgs[0]
        else:
          let binary = build(recordArgs[0], "", nimcachePath)
          binary

      recordedTrace = record(lang=extension,
                             outputFolder=outputFolder,
                             exportFile="",
                             stylusTrace="",
                             address="",
                             socketPath="",
                             recordBackend="",
                             withDiff="",
                             storeTraceFolderForPid = -1,
                             upload=false,
                             useInterpose=false,
                             program=program,
                             args=recordArgs[1..^1])
    if not recordedTrace.isNil:
      # Always spawn a subprocess for replay so the restart loop can work.
      # (runRecordedTrace uses execv which never returns)
      var replayArgs = @["replay", fmt"--id={recordedTrace.recordingId}"]
      if newTracePolicy == "tab":
        replayArgs.add("--new-tab")
      elif newTracePolicy == "window":
        replayArgs.add("--new-window")
      let process = startProcess(codetracerExe, args = replayArgs, options = {poParentStreams})
      let shouldRestart = waitForExit(process) == RESTART_EXIT_CODE

      if not shouldRestart:
        break
      else:
        afterRestart = true

    else:
      break

proc run*(programArg: string, args: seq[string],
          newTracePolicy: string = "") =
  # run <program> <args>
  # optionally if env variable CODETRACER_RECORD_CORE=true
  # try to record core (dispatcher run) with codetracer

  let recordCore = envLoadRecordCore()
  var traceID = -1
  var program = programArg
  var dbBasedSupport = false

  let lang = detectLang(program, LangUnknown)
  let recordArgs = @[programArg].concat(args)

  runWithRestart(
    test=false,
    recordCore=recordCore,
    lang=lang,
    newTracePolicy=newTracePolicy,
    recordArgs=recordArgs
  )
