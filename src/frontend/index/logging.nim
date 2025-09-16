import
  std / [ json ],
  ../lib,
  ../../common/path_utils

from electron_vars import callerProcessPid

var
  indexLogPath: cstring = cstring""
  logStream: NodeWriteStream = nil

template debugIndex*(msg: string, taskId: TaskId = NO_TASK_ID): untyped =
  if indexLogPath.len == 0:
    indexLogPath = ensureLogPath(
      "index",
      callerProcessPid,
      "index",
      0,
      "log"
    ).cstring

  if logStream.isNil:
    logStream = fs.createWriteStream(indexLogPath, js{flags: cstring"a"})

  if not logStream.isNil:
    discard logStream.write(withDebugInfo(msg.cstring, taskId, "DEBUG") & jsNl)
