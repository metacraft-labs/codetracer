import
  std / [ jsffi, jsconsole, strutils ],
  jslib,
  ../task_and_event

template taskLog*(taskId: TaskId): cstring =
  let taskIdString = taskId.cstring
  if taskIdString.len > 0:
    # for compat with codetracer_output for chronicles
    cstring" taskId=" & taskIdString & cstring" time=" & (cast[float](now()) / 1_000).toCString
  else:
    cstring""

template locationInfo: untyped =
  let i = instantiationInfo(0)
  i.filename & ":" & $i.line

template withDebugInfo*(a: cstring, taskId: TaskId, level: string): cstring =
  # tries to be compatible with out codetracer_output
  # in chronicles and with the rr/gdb scripts logs:
  # <time:18> | <level:5> | <task-id:17> | <file:line:28> | ([<indentation space>]<message>:50)[<args>()]
  cstring(
    ($(cast[float](now()) / 1_000)).alignLeft(18) & " | " & # time
    level.alignLeft(5) & " | " &
    ($taskId).alignLeft(17) & " | " &
    locationInfo().alignLeft(28) & " | " &
    ($(a.toCString)))

template cdebug*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.debug withDebugInfo(a.toCString, taskId, "DEBUG")
  #  withLocationInfo(a.toCString) & taskLog(taskId)

template clog*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.log withDebugInfo(a.toCString, taskId, "DEBUG")
  #  withLocationInfo(a.toCString) & taskLog(taskId)

template cwarn*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.warn withDebugInfo(a.toCString, taskId, "WARN")
  # console.warn withLocationInfo(a.toCString) & taskLog(taskId)

template cerror*[T](a: T, taskId: TaskId = NO_TASK_ID): void =
  console.error withDebugInfo(a.toCString, taskId, "ERROR")
  # console.error withLocationInfo(a.toCString) & taskLog(taskId)


# repeat code here inside, instead of calling
# the generic versions, so it's on the same level of compile time stack
# for locationInfo:

template cdebug*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.debug withDebugInfo(a.cstring, taskId, "DEBUG")

template clog*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.log withDebugInfo(a.cstring, taskId, "DEBUG")

template cwarn*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.warn withDebugInfo(a.cstring, taskId, "WARN")

template cerror*(a: string, taskId: TaskId = NO_TASK_ID): void =
  console.error withDebugInfo(a.cstring, taskId, "ERROR")

template uiTestLog*(msg: string): void =
  clog "ui test: " & msg