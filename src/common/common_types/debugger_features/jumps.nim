type
  LocalStepJump* = object
    path*: langstring
    line*: int
    stepCount*: int
    iteration*: int
    firstLoopLine*: int
    rrTicks*: int
    reverse*: bool
    opId*: int

  JumpBehaviour* = enum
    SmartJump,
    ForwardJump,
    BackwardJump

  SourceLineJumpTarget* = object
    path*: langstring
    line*: int
    behaviour*: JumpBehaviour
    opId*: int

  SourceCallJumpTarget* = object
    path*: langstring
    line*: int
    token*: langstring
    behaviour*: JumpBehaviour
    opId*: int

  CallstackJump* = object
    index*: int
    functionName*: langstring
