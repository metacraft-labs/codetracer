import
  std/[strformat, strutils, os, options],
  ../../common/[trace_index, types, paths],
  ../cli/logging

proc scriptSessionLogPath*(sessionId: int): string =
  let bashLogFile = getEnv("CODETRACER_SHELL_BASH_LOG_FILE", "")
  if bashLogFile.len == 0:
    codetracerTmpPath / fmt"session-{sessionId}-script.log"
  else:
    bashLogFile

proc loadSessionId*: int =
  let sessionIdRaw = getEnv("CODETRACER_SESSION_ID", "-1")
  var sessionId = -1
  try:
    sessionId = sessionIdRaw.parseInt
  except ValueError:
    sessionId = -1
  sessionId

proc loadLine*(sessionId: int, sessionLogPath: string): int =
  if sessionId == -1:
    NO_LINE
  else:
    let useScript = getEnv("CODETRACER_SHELL_USE_SCRIPT", "0") == "1"
    let raw = readFile(sessionLogPath)
    if not useScript:
      raw.parseInt
    else:
      raw.splitLines.len - 1

proc findTraceForArgs*(
    patternArg: Option[string],
    traceIdArg: Option[int],
    traceFolderArg: Option[string]): Trace =
  # if no trace found, direct error on screen and quit
  if traceIdArg.isSome:
    let traceId = traceIdArg.get
    let trace = trace_index.find(traceId, test=false)
    if not trace.isNil:
      return trace
    else:
      errorMessage fmt"error: trace with id {traceId} not found in local codetracer db"
      quit(1)
  elif traceFolderArg.isSome:
    let folder = traceFolderArg.get
    var trace = trace_index.findByPath(expandFilename(folder), test=false)
    if trace.isNil:
      trace = trace_index.findByPath(expandFilename(folder) & "/", test=false)
    if not trace.isNil:
      return trace
    else:
      errorMessage fmt"error: trace with output folder {folder} not found in local codetracer db"
      quit(1)
  else:
    assert patternArg.isSome
    let programPattern = patternArg.get
    #var traceID = -1
    # for now:
    #   no program args match
    #   i think i haven't used it lately
    #   but this can be re-added
    #   either by configuration  update
    #   or maybe a custom flag/restArgs
    # var runArgs: seq[string]
    # for i in 1 ..< args.len:
    #   runArgs.add(args[i])
    # if runArgs.len > 0:
    #   runTrace(
    #     program,
    #     runArgs,
    #     "",
    #     LangUnknown,
    #     test=false,
    #     repl=repl,
    #     traceID=traceID,
    #     recordCore=recordCore)
    # else:
    # if true:
    let trace = if '#' in programPattern:
        let localTrace = trace_index.findByProgramPattern(programPattern, test=false)
        if localTrace.isNil:
          echo "trace not found locally: do you want to download it from registry and replay? y/n"
          echo "  WARNING: might include sensitive data/foreign code"
          let userInput = readLine(stdin)
          if userInput.toLowerAscii() != "y":
            echo "no download and replay!"
            quit(1)
          else:
            # downloadTrace(programPattern)
            echo "error: unsupported currently!"
            quit(1)
        else:
          localTrace
      else:
        trace_index.findByProgramPattern(programPattern, test=false)
    if not trace.isNil:
      return trace
    else:
      errorMessage fmt"error: trace matching program with {programPattern} not found in local codetracer db"
      quit(1)
