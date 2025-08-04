import std/[json, jsffi]          # JsonNode
import jsony               # automatic encode / decode
type
  ## 1.  Exact counterpart of `ProtocolMessage`
  ProtocolMessage* = object
    seq*: int64
    `type`*: string

  Request* = object
    seq*: int64
    `type`*: string
    command*: string
    arguments*: JsObject ## serde_json::Value

## Helpers

proc toJsonStr*(r: Request): string {.inline.} =
  jsony.toJson(r)

proc toJson*(r: Request): string {.inline.} =
  jsony.toJson(r)

proc fromJson*(T: typedesc[ProtocolMessage], s: string): ProtocolMessage =
  s.fromJson(ProtocolMessage)

proc fromJson*(T: typedesc[Request], s: string): Request =
  s.fromJson(Request)

proc toCString*(r: Request): cstring {.inline.} =
  ## `jsony.toJson()` returns a Nim `string`.
  ## A plain `cast` is enough to re-interpret it as `cstring`
  ## on **both** the native and JS back-ends.
  cast[cstring](r.toJson())
