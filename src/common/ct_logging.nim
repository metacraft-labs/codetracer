import std/[strutils]
import env

type
  CtLogLevel* {.pure.} = enum
    Debug,
    Info,
    Warn,
    Error

# top priority is runtime env variable: `CODETRACER_LOG_LEVEL`
# if this is not set, then it's a compile `-d:codetracerLogLevel` define flag
# if it's not set, then the default from here, for now: "DEBUG"
const codetracerLogLevel {.strdefine.} = "INFO"
# caps lock should be also recognized because of nim's casing rules
let LOG_LEVEL* = parseEnum[CtLogLevel](env.get("CODETRACER_LOG_LEVEL", codetracerLogLevel))

template debugPrint*(args: varargs[untyped]) =
  if LOG_LEVEL <= CtLogLevel.Debug:
    let i = instantiationInfo(0)
    echo "INFO [ct](", i.filename & ":" & $i.line, "):", args

template infoPrint*(args: varargs[untyped]) =
  if LOG_LEVEL <= CtLogLevel.Info:
    let i = instantiationInfo(0)
    echo "INFO [ct](", i.filename & ":" & $i.line, "):", args

template warnPrint*(args: varargs[untyped]) =
  if LOG_LEVEL <= CtLogLevel.Warn:
    let i = instantiationInfo(0)
    echo "WARN [ct](", i.filename & ":" & $i.line, "):", args

template errorPrint*(args: varargs[untyped]) =
  if LOG_LEVEL <= CtLogLevel.Error:
    let i = instantiationInfo(0)
    echo "ERROR [ct](", i.filename & ":" & $i.line, "):", args
