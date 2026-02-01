type Message = enum
  Cancelled
  NotStopped
  Other

type ResponseBody = object

  Attach
  BreakpointLocations(BreakpointLocationsResponse)
  Completions(CompletionsResponse)
  ConfigurationDone
  Continue(ContinueResponse)
  DataBreakpointInfo(DataBreakpointInfoResponse)
  Disassemble(DisassembleResponse)
  Disconnect
  Evaluate(EvaluateResponse)
  ExceptionInfo(ExceptionInfoResponse)
  Goto
  GotoTargets(GotoTargetsResponse)
  Initialize(Capabilities)
  Launch
  LoadedSources(LoadedSourcesResponse)
  Modules(ModulesResponse)
  Next
  Pause
  ReadMemory(ReadMemoryResponse)
  Restart
  RestartFrame
  ReverseContinue
  Scopes(ScopesResponse)
  SetBreakpoints(SetBreakpointsResponse)
  SetDataBreakpoints(SetDataBreakpointsResponse)
  SetExceptionBreakpoints(SetExceptionBreakpointsResponse)
  SetExpression(SetExpressionResponse)
  SetFunctionBreakpoints(SetFunctionBreakpointsResponse)
  SetInstructionBreakpoints(SetInstructionBreakpointsResponse)
  SetVariable(SetVariableResponse)
  Source(SourceResponse)
  StackTrace(StackTraceResponse)
  StepIn
  StepOut
  Terminate
  TerminateThreads
  Threads(ThreadsResponse)
  Variables(VariablesResponse)
  WriteMemory(WriteMemoryResponse)

type
  Response = object
    request_seq: int
    success: bool
    command: string
    response:
