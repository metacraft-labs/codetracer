const
  SHARED* = false
  NO_INDEX*: int = -1
  NO_EVENT*: int = -1
  NO_OFFSET*: int = -1
  NO_LINE*: int = -1
  NO_STEP_COUNT*: int = -1
  NO_POSITION*: int = -1
  NO_KEY*: string = "-1"
  NO_LIMIT*: int = -1
  NO_TICKS*: int = -1
  FLOW_ITERATION_START*: int = 0
  RESTART_EXIT_CODE*: int = 10
  NO_NAME* = langstring""
  VOID_RESULT*: langstring = langstring("{}")
  IN_DEBUG* = true

type EmptyArg* = object