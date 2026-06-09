import
  std/[ osproc, os, options ],
  ../../common/[ paths, config ]

when not defined(windows):
  import std/[posix, posix_utils]

var coreProcessId* = -1

proc startBackend*(backendKind: string, isStdio: bool = true, socketPath: Option[string]) =
  # `replay-server` requires a subcommand (`dap-server`) before any
  # transport flag — `replay-server --stdio` errors with
  # "unexpected argument '--stdio'".  The `rr` backend's binary
  # (`ct-rr-support`) accepts `--stdio` directly with no subcommand.
  let (backendExe, prelude) =
    if backendKind == "db":
      (dbBackendExe, @["dap-server"])
    elif backendKind == "rr":
      let ctConfig = loadConfig(folder=getCurrentDir(), inTest=false)
      if ctConfig.rrBackend.enabled:
        (ctConfig.rrBackend.path, @[])
      else:
        echo "ERROR: rr backend not enabled!"
        quit(1)
    else:
      echo "ERROR: Backend kind not recognized, needs to be 'rr' or 'db'"
      quit(1)

  let transport =
    if isStdio:
      @["--stdio"]
    elif socketPath.isSome:
      @[socketPath.get()]
    else:
      echo "ERRROR: Needs to have either --stdio or a valid socket path"
      quit(1)

  let args = prelude & transport

  let process = startProcess(
    backendExe,
    args = args,
    options = { poParentStreams }
  )

  coreProcessId = process.processId
  when not defined(windows):
    onSignal(SIGTERM):
      if coreProcessId != -1:
        echo "ct: stopping core process"
        sendSignal(coreProcessId.Pid, SIGTERM)

  let code = waitForExit(process)
  quit(code)
