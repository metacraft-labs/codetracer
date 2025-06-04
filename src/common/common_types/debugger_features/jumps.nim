type
  LocalStepJump* = object
    path*: langstring
    line*: int
    stepCount*: int
    iteration*: int
    firstLoopLine*: int
    rrTicks*: int
    reverse*: bool

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