import std/[ strutils, sequtils ]

var errors = newSeq[string]()

proc pushError*(msg: string) =
  errors.add(msg)

proc throwErrorsIfAny*() =
  if errors.len > 0:
    raise newException(ValueError, "Errors encountered: " & errors.join(", "))

proc runSafe*(action: proc(), cleanup: proc() = nil, caller: string) =
  try:
    action()
  except CatchableError as e:
    pushError("[" & caller & "] " & e.msg)
  finally:
    if not isNil(cleanup): cleanup()