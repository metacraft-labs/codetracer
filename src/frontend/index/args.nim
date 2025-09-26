import
  std / [ jsffi, sequtils ],
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

  if electronProcess.env.hasKey(cstring"CODETRACER_TRACE_ID"):
    data.startOptions.traceID = electronProcess.env[cstring"CODETRACER_TRACE_ID"].parseJSInt
    data.startOptions.inTest = electronProcess.env[cstring"CODETRACER_TEST"] == cstring"1"
    callerProcessPid = electronProcess.env[cstring"CODETRACER_CALLER_PID"].parseJsInt
    return
  else:
    discard

  if electronProcess.env.hasKey(cstring"CODETRACER_TEST_STRATEGY"):
    data.startOptions.rawTestStrategy = electronProcess.env[cstring"CODETRACER_TEST_STRATEGY"]
    infoPrint "RAW TEST STRATEGY:", data.startOptions.rawTestStrategy

  let argsExceptNoSandbox = electronProcess.argv.filterIt(it != cstring"--no-sandbox")

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
          data.startOptions.diff = cast[Diff](JSON.parse(args[i + 1]))
          data.startOptions.withDiff = true
          i += 2
          continue
        else:
          errorPrint "expected --diff <structuredDiffJson>"
          break
      elif arg == cstring"--no-record":
        data.startOptions.record = false
      elif arg == cstring"edit":
        data.startOptions.edit = true
        data.startOptions.name = argsExceptNoSandbox[i + 3]
        let file = fs.lstatSync(data.startOptions.name)
        var folder = cstring""
        if data.startOptions.name[0] == '/':
          if cast[bool](file.isFile()):
            folder = nodePath.dirname(data.startOptions.name) & cstring"/"
          else:
            folder = data.startOptions.name
            data.startOptions.name = cstring""
          if folder[folder.len - 1] != '/':
            folder = folder & cstring"/"
        else:
          folder = electronprocess.cwd() & cstring"/"
        data.startOptions.folder = folder
        break
      elif arg == cstring"--shell-ui":
        data.startOptions.shellUi = true
        data.startOptions.folder = electronprocess.cwd()
        data.startOptions.traceID = -1
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
      elif arg == cstring"--caller-pid":
        if i + 1 < args.len:
          callerProcessPid = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --caller-pid <caller-pid>"
          break
      elif not arg.isNaN:
        data.startOptions.screen = false
        data.startOptions.loading = true
        data.startOptions.record = false
        data.startOptions.traceID = arg.parseJSInt
        data.startOptions.folder = electronprocess.cwd()
      else:
        discard
      i += 1
  else:
    data.startOptions.traceID = -1
    data.startOptions.welcomeScreen = true
    data.startOptions.folder = electronprocess.cwd()
