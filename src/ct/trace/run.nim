import std/[osproc, strformat, sequtils],
  ../../common/[ paths, lang, types ],
  ../launch/electron,
  ../utilities/[ env, language_detection ],
  ../cli/[logging],
  record

# run a recorded trace based on args, a saving project for it in the process
proc runRecordedTrace*(
  trace: Trace,
  test: bool,
  recordCore: bool = false
): bool =
  let args = if test: @[$trace.id, "--test"] else: @[$trace.id]
  return launchElectron(args, trace, ElectronLaunchMode.Default, recordCore, test)


proc runWithRestart(
  test: bool,
  recordCore: bool = false,
  lang: Lang = LangUnknown,
  recordArgs: seq[string] = @[]
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
      recordedTrace = record(lang=extension,
                             outputFolder="",
                             backend="",
                             exportFile="",
                             stylusTrace="",
                             program=recordArgs[0],
                             args=recordArgs[1..^1])
    if not recordedTrace.isNil:
      let shouldRestart =
        if not afterRestart:
          runRecordedTrace(recordedTrace, test, recordCore)
        else:
          let process = startProcess(codetracerExe, args = @["replay", fmt"--id={recordedTrace.id}"], options = {poParentStreams})
          waitForExit(process) == RESTART_EXIT_CODE

      if not shouldRestart:
        break
      else:
        afterRestart = true

    else:
      break

proc run*(programArg: string, args: seq[string]) =
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
    recordArgs=recordArgs
  )
