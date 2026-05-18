import
  std / [ jsffi, sequtils, strutils ],
  electron_vars, config,
  ../types,
  ../lib/[ jslib, electron_lib ],
  ../../common/ct_logging

# <traceId>
# --port <port>
# --frontend-socket-port <frontend-socket-port>
# --frontend-socket-parameters <frontend-socket-parameters>
# --backend-socket-port <backend-socket-port>
# --caller-pid <callerPid>
# # eventually if needed --backend-socket-host <backend-socket-host>
proc parseArgs* =
  data.startOptions.screen = true
  data.startOptions.loading = false
  data.startOptions.record = false
  data.startOptions.stylusExplorer = electronProcess.env[cstring"CODETRACER_LAUNCH_MODE"] == cstring"arb.explorer"

  data.startOptions.folder = electronprocess.cwd()

  # Check CODETRACER_TEST for all launch modes (trace, deepreview, welcome, edit, etc.)
  # so that test-mode behaviour (e.g. skipping the install dialog) is always available.
  if electronProcess.env.hasKey(cstring"CODETRACER_TEST") and
      electronProcess.env[cstring"CODETRACER_TEST"] == cstring"1":
    data.startOptions.inTest = true

  if electronProcess.env.hasKey(cstring"CODETRACER_TRACE_ID"):
    # M-REC-2: ``CODETRACER_TRACE_ID`` now carries the recording_id
    # (UUIDv7 string).  The env-var rename to ``CODETRACER_RECORDING_ID``
    # is M-REC-6 scope.
    data.startOptions.traceID = electronProcess.env[cstring"CODETRACER_TRACE_ID"]
    callerProcessPid = electronProcess.env[cstring"CODETRACER_CALLER_PID"].parseJsInt
    return
  else:
    discard

  if electronProcess.env.hasKey(cstring"CODETRACER_TEST_STRATEGY"):
    data.startOptions.rawTestStrategy = electronProcess.env[cstring"CODETRACER_TEST_STRATEGY"]
    infoPrint "RAW TEST STRATEGY:", data.startOptions.rawTestStrategy

  # Filter out flags injected by Electron/Playwright that are not
  # CodeTracer arguments (--no-sandbox, --inspect, --remote-debugging-port,
  # --remote-debugging-pipe, etc.).
  proc isDebuggerFlag(arg: cstring): bool =
    let s = $arg
    s == "--no-sandbox" or
      s.startsWith("--inspect") or
      s.startsWith("--remote-debugging")

  let argsExceptNoSandbox = electronProcess.argv.filterIt(not isDebuggerFlag(it))

  # TODO electron or just node? server code compatibility
  if argsExceptNoSandbox.len > 2:
    var args = argsExceptNoSandbox[2 .. ^1]
    var i = 0
    while i < args.len:
      let arg = args[i]
      if arg == cstring"--bypass":
        data.startOptions.screen = false
        data.startOptions.loading = true
      elif arg == cstring"--test":
        data.startOptions.screen = false
        data.startOptions.inTest = true
      elif arg == cstring"--diff":
        if i + 1 < args.len:
          data.startOptions.diff = cast[Diff](JSON.parse(fs.readFileSync(args[i + 1], cstring"utf8")))
          data.startOptions.withDiff = true
          i += 2
          continue
        else:
          errorPrint "expected --diff <structuredDiffJson>"
          break
      elif arg == cstring"--diff-index":
        if i + 1 < args.len:
          data.startOptions.rawDiffIndex = fs.readFileSync(args[i + 1], cstring"utf-8")
          i += 2
          continue
        else:
          errorPrint "expected --diff-index <indexDiffJson>"
          break
      elif arg == cstring"--deepreview":
        # Load a DeepReview JSON export file for offline review mode.
        # The JSON structure matches the DeepReviewData type produced
        # by ct-native-replay's json_export module.
        if i + 1 < args.len:
          data.startOptions.deepReview = cast[DeepReviewData](JSON.parse(fs.readFileSync(args[i + 1], cstring"utf8")))
          data.startOptions.withDeepReview = true
          data.startOptions.traceID = cstring""
          i += 2
          continue
        else:
          errorPrint "expected --deepreview <deepreviewJson>"
          break
      elif arg == cstring"--no-record":
        data.startOptions.record = false
      elif arg == cstring"--welcome-screen":
        data.startOptions.welcomeScreen = true
        data.startOptions.traceID = cstring""
      elif arg == cstring"edit":
        data.startOptions.edit = true
        if i + 1 >= args.len:
          errorPrint "expected edit <path>"
          break
        let rawEditPath = args[i + 1]
        let nameStr = $rawEditPath
        # Check for absolute path: Unix (/) or Windows drive letter (e.g. D:\)
        let isAbsolute = nameStr.len > 0 and (nameStr[0] == '/' or
          (nameStr.len >= 3 and nameStr[1] == ':' and (nameStr[2] == '\\' or nameStr[2] == '/')))
        let absoluteEditPath =
          if isAbsolute:
            rawEditPath
          else:
            nodePath.join(electronprocess.cwd(), rawEditPath)
        let file = fs.lstatSync(absoluteEditPath)
        var folder = cstring""
        if cast[bool](file.isFile()):
          data.startOptions.name = absoluteEditPath
          folder = nodePath.dirname(absoluteEditPath) & cstring"/"
        else:
          data.startOptions.name = cstring""
          folder = absoluteEditPath
        if folder[folder.len - 1] != '/' and folder[folder.len - 1] != '\\':
          folder = folder & cstring"/"
        data.startOptions.folder = folder
        break
      elif arg == cstring"--shell-ui":
        data.startOptions.shellUi = true
        data.startOptions.folder = electronprocess.cwd()
        data.startOptions.traceID = cstring""
        break
      elif arg == cstring"--port":
        if i + 1 < args.len:
          data.startOptions.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --port <port>"
          break
      elif arg == cstring"--frontend-socket-port":
        if i + 1 < args.len:
          data.startOptions.frontendSocket.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --frontend-socket-port <frontend-socket-port>"
          break
      elif arg == cstring"--frontend-socket-parameters":
        if i + 1 < args.len:
          data.startOptions.frontendSocket.parameters = args[i + 1]
          i += 2
          continue
        else:
          errorPrint "expected --frontend-socket-parameters <frontend-socket-parameters>"
          break
      elif arg == cstring"--backend-socket-port":
        if i + 1 < args.len:
          data.startOptions.backendSocket.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --backend-socket-port <backend-socket-port>"
          break
      elif arg == cstring"--idle-timeout-ms":
        if i + 1 < args.len:
          data.startOptions.idleTimeoutMs = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --idle-timeout-ms <milliseconds>"
          break
      elif arg == cstring"--caller-pid":
        if i + 1 < args.len:
          callerProcessPid = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --caller-pid <caller-pid>"
          break
      elif (let s = $arg; s.len == 36 and s[8] == '-' and s[13] == '-' and
          s[18] == '-' and s[23] == '-'):
        # M-REC-2: positional arg is the recording_id (UUIDv7).  Cheap
        # shape check: 36 chars with hyphens at the canonical positions.
        data.startOptions.screen = false
        data.startOptions.loading = true
        data.startOptions.record = false
        data.startOptions.traceID = arg
        data.startOptions.folder = electronprocess.cwd()
      else:
        discard
      i += 1
  else:
    data.startOptions.traceID = cstring""
    data.startOptions.welcomeScreen = true
    data.startOptions.folder = electronprocess.cwd()
