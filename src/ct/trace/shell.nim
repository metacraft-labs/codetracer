import
  std/[strformat, strutils, os, options],
  ../../common/[trace_index, types, paths, recording_id]

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

proc resolveRecordingId*(arg: string): Trace =
  ## M-REC-6: resolve a user-supplied recording-id argument.  Accepts:
  ## - canonical 36-char UUIDv7 form → direct lookup.
  ## - 8+ hex-char short prefix → ``findByRecordingIdPrefix``.  Unique
  ##   matches succeed; ambiguous prefixes print the candidate list and
  ##   exit; not-found and too-short surface as ``quit(1)`` with a
  ##   targeted error message.
  ##
  ## Returns the resolved ``Trace`` or terminates the process on failure.
  ## Callers that already validated the input may keep using
  ## ``trace_index.find`` directly.
  let trimmed = arg.strip
  if trimmed.len == 0:
    echo "error: empty recording id"
    quit(1)
  if recording_id.isCanonicalUuidV7(trimmed):
    let trace = trace_index.find(trimmed, test = false)
    if trace.isNil:
      echo fmt"error: no recording matches id '{trimmed}'"
      quit(1)
    return trace
  # Not canonical: try the short-prefix path.
  let res = trace_index.findByRecordingIdPrefix(trimmed, test = false)
  if res.isOk:
    return res.trace
  case res.error
  of trace_index.rieTooShort:
    echo fmt"error: recording-id prefix '{trimmed}' is too short; need at least " &
      $trace_index.MIN_RECORDING_ID_PREFIX_LEN & " hex chars"
    quit(1)
  of trace_index.rieNotFound:
    echo fmt"error: no recording matches prefix '{trimmed}'"
    quit(1)
  of trace_index.rieAmbiguous:
    echo fmt"error: ambiguous prefix '{trimmed}' matches " &
      $res.matches.len & " recordings:"
    for m in res.matches:
      echo "  " & m
    quit(1)

proc findTraceForArgs*(
    patternArg: Option[string],
    recordingIdArg: Option[string],
    traceFolderArg: Option[string]): Trace =
  ## M-REC-3: ``recordingIdArg`` is a UUIDv7 recording-id string.
  ## M-REC-6: also accepts an 8+ hex-char short prefix; resolution is
  ## delegated to ``resolveRecordingId`` which terminates on ambiguity.
  # if no trace found, returning nil for now
  if recordingIdArg.isSome:
    return resolveRecordingId(recordingIdArg.get)
  elif traceFolderArg.isSome:
    let folder = traceFolderArg.get
    var trace = trace_index.findByPath(expandFilename(expandTilde(folder)), test=false)
    if trace.isNil:
      trace = trace_index.findByPath(expandFilename(expandTilde(folder)) & "/", test=false)
    if not trace.isNil:
      return trace
    else:
      return nil
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
      return nil
