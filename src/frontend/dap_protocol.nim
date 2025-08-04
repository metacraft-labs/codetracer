# dap_protocol.nim
# ---------------------------------------------------------------------------
# Minimal DAP helpers that match the Rust structs shown in the question.
#
#  - Uses the stdlib `json` module plus the very small dependency `jsony`
#    (https://github.com/treeform/jsony) for automatic encode / decode.
#  - Keeps field-names identical to the Rust side (`type` is renamed via the
#    {.jsonField.} pragma, exactly like serde’s #[serde(rename = "type")]).
#  - Works in both the native and JS back-ends (VS Code extension).
#
# ---------------------------------------------------------------------------

import std/[json, strutils, tables]
import jsony                      ## tiny, zero-dep serde-like lib

# ---------------------------------------------------------------------------
# 1.  Data structures that look exactly like the Rust ones
# ---------------------------------------------------------------------------

type
  ProtocolMessage* = object
    seq*: int64
    ## `type` is a Nim keyword, so keep the Rust field-name by renaming
    ## it in JSON while calling the slot `type_` in Nim.
    `type`*: string

  Request* = object
    ## `flatten` in Rust means the base fields live at top-level.
    ## Just repeat them here so the JSON layout matches 1-for-1.
    seq*: int64
    `type`*: string
    command*: string
    arguments*: JsonNode          ## `serde_json::Value` equivalent

# ---------------------------------------------------------------------------
# 2.  Simple helpers – automatic encode / decode via jsony
# ---------------------------------------------------------------------------

proc toJson*(p: ProtocolMessage): string =
  p.toJson()                      ## jsony: object -> JSON string

proc toJson*(r: Request): string =
  r.toJson()

proc fromJson*(T: typedesc[ProtocolMessage], s: string): ProtocolMessage =
  s.fromJson(ProtocolMessage)     ## JSON string -> Nim object

proc fromJson*(T: typedesc[Request], s: string): Request =
  s.fromJson(Request)

# ---------------------------------------------------------------------------
# 3.  A monotonically increasing seq counter (DAP requirement)
# ---------------------------------------------------------------------------

# var seqCounter {.threadvar.}: int64 = 1      ## one per thread is fine

# func nextSeq*(): int64 =
#   result = seqCounter
#   inc seqCounter

# ---------------------------------------------------------------------------
# 4.  Helpers that your existing DapApi can call
# ---------------------------------------------------------------------------

when not defined(js):
  import std/asyncdispatch
else:
  import std/jsffi               ## console.log etc. in JS

type
  CtEventKind* = enum             ## just an example – use your real one
    CtLoadLocals, CtUpdateTable, CtLoadCalltraceSection,
    CtEventLoad, CtLoadTerminal, CtCollapseCalls, CtExpandCalls,
    CtCalltraceJump, CtEventJump, CtLoadHistory, CtHistoryJump,
    CtSearchCalltrace, CtSourceLineJump, CtSourceCallJump,
    CtLocalStepJump, CtTracepointToggle, CtTracepointDelete,
    CtTraceJump, CtLoadFlow

  ## Your existing DapApi stays as-is; we only need the socket +
  ## handler table to demonstrate the integration points.
  # DapApi* = ref object
  #   handlers*: array[CtEventKind, seq[proc(kind: CtEventKind,
  #                                          raw: JsonNode)]]
  #   dapSocket*: Stream            ## whatever concrete stream you use

# -- building & sending a JSON request --------------------------------------

proc makeRequest*(kind: CtEventKind; jsArgs: JsonNode): string =
  ## Converts one of your UI “events” into the exact JSON the Rust
  ## server expects.
  let req = Request(
    seq: 0,
    `type`: "request",
    command: $kind,               ## enum name ⇒ "CtLoadLocals", …
    arguments: jsArgs
  )
  req.toJson()

proc sendCtRequest*(dap: DapApi;
                    kind: CtEventKind;
                    rawValue: JsonNode) =
  let payload = makeRequest(kind, rawValue)
  when defined(js):
    console.log "Sending CT request:", payload
  else:
    echo "Sending CT request: ", payload
  if dap.dapSocket.isNil:
    raise newException(IOError, "DAP socket not initialised")
  dap.dapSocket.write payload & "\c\n"     ## DAP prefers \n-delimited
