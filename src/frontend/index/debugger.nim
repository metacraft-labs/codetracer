import
  std / [ async, jsffi, os ],
  ipc_types/socket,
  config,
  ../[ lib, types ],
  ../../common/[ paths, ct_logging ]

let
  CT_DEBUG_INSTANCE_PATH_BASE*: cstring = cstring(codetracerTmpPath) & cstring"/ct_instance_"
  child_process = cast[(ChildProcessLib)](require("child_process"))

proc newDebugInstancePipe(pid: int): Future[JsObject] {.async.} =
  var future = newPromise() do (resolve: proc(response: JsObject)):
    var connections: seq[JsObject] = @[nil.toJs]
    let path = CT_DEBUG_INSTANCE_PATH_BASE & cstring($pid)
    connections[0] = net.createServer(proc(server: JsObject) =
      infoPrint "index: connected instance server for ", path
      resolve(server))

    connections[0].on(cstring"error") do (error: js):
      errorPrint "index: socket instance server error: ", error
      resolve(nil.toJs)

    connections[0].listen(path)
  return await future

proc sendOutputJumpIPC(instance: DebugInstance, outputLine: int) {.async.} =
  debugPrint "send output jump ipc ", cast[int](instance.process.pid), " ", outputLine
  instance.pipe.write(cstring($outputLine & "\n"))

proc onShowInDebugInstance*(sender: js, response: jsobject(traceId=int, outputLine=int)) {.async.} =
  if not data.debugInstances.hasKey(response.traceId):
    var process = child_process.spawn(
      codetracerExe,
      @[cstring"run", cstring($response.traceId)])
    var pipe = await newDebugInstancePipe(process.pid)
    data.debugInstances[response.traceId] = DebugInstance(process: process, pipe: pipe)
    await wait(5_000)

  if response.outputLine != -1:
    await sendOutputJumpIPC(data.debugInstances[response.traceId], response.outputLine)