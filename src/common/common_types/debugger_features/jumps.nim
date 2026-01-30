type
  LocalStepJump* = object
    path*: langstring
    line*: int
    stepCount*: int
    targetIteration*: int
    firstLoopLine*: int
    rrTicks*: int
    reverse*: bool
    activeIteration*: int # For rr backend navigation

  JumpBehaviour* = enum
    SmartJump,
    ForwardJump,
    BackwardJump

  SourceLineJumpTarget* = object
    path*: langstring
    line*: int
    behaviour*: JumpBehaviour

  SourceCallJumpTarget* = object
    path*: langstring
    line*: int
    token*: langstring
    behaviour*: JumpBehaviour

  CallstackJump* = object
    index*: int
    functionName*: langstring
