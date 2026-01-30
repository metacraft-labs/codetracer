import json_serialization


  Event = object
    test: int

  ReverseRequest = object
    test: int

type
  SendableKind* {.pure.} = enum
    skResponse
    skEvent
    skReverseRequest

  Sendable* = object
    case kind*: SendableKind
    of skResponse:        response*:        Response
    of skEvent:           event*:           Event
    of skReverseRequest:  reverseRequest*:  ReverseRequest

  BaseMessage* = object
    `seq`: int
    message: Sendable

proc serialize[T](self: T): string {.noSideEffect.} =
  result = Json.encode(self)

proc deserialize[T](serialized: string): T {.noSideEffect.} =
  result = Json.decode(serialized)
