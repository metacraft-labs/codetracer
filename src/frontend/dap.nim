import std / [jsffi, jsconsole, strformat, async]
import .. / common / ct_event

when not defined(ctInExtension):
  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]    
else:
  import vscode

  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]
      vscode*: VsCode
      context*: VsCodeContext

type
  DapRequest* = ref object
    command*: cstring
    value*: JsObject

const CT_EVENT_DAP_TRACKING_RESPONSE_KINDS = {CtLoadLocals}

func toCtDapResponseEventKind*(kind: CtEventKind): CtEventKind =
  # TODO: based on $kind? or mapping?
  case kind:
  of CtLoadLocals: CtLoadLocalsResponse
  else: raise newException(ValueError, fmt"no response ct event kind for {kind} defined")


func toDapCommandOrEvent(kind: CtEventKind): cstring =
  # TODO
  # eventually auto mapping using $kind and tokenization?
  case kind:
  of CtLoadLocals: "ct/load-locals"
  of CtLoadLocalsResponse: "ct/load-locals-response"
  of DapStopped: "stopped"
  else: raise newException(ValueError, fmt"not mapped to request command yet: {kind}")


func commandToCtResponseEventKind(command: cstring): CtEventKind =
  # based on parseEnum[CtEventKind](command) and toCtDapResponseEventKind?
  # or some common mapping?
  case $command:
  of "ct/load-locals": CtLoadLocalsResponse
  else: raise newException(
    ValueError, 
    "no ct event kind response for command: \"" & $command & "\" defined")


func dapEventToCtEventKind(event: cstring): CtEventKind =
  case $event:
  of "stopped": DapStopped
  of "initialized": DapInitialized
  of "output": DapOutput
  else: raise newException(
    ValueError,
    "no ct event kind for this string: \"" & $event & "\" defined")

### DapApi procedures:

proc on*[T](dap: DapApi, kind: CtEventKind, handler: proc(kind: CtEventKind, value: T)) =
  dap.handlers[kind].add(proc(kind: CtEventKind, rawValue: JsObject) =
    handler(kind, cast[T](rawValue)))

proc receive*(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  for handler in dap.handlers[kind]:
    try:
      handler(kind, rawValue)
    except:
      echo "dap handler error: ", getCurrentExceptionMsg()
      echo "   kind: ", kind
      console.log cstring"rawValue: ", rawValue

proc receiveResponse*(dap: DapApi, command: cstring, rawValue: JsObject) =
  dap.receive(commandToCtResponseEventKind(command), rawValue)

proc receiveEvent*(dap: DapApi, event: cstring, rawValue: JsObject) =
  dap.receive(dapEventToCtEventKind(event), rawValue)
 
when not defined(ctInExtension):
  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    raise newException(NotImplementedError, "asyncSendCtRequest not implemented")
else:
  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    console.log cstring"-> dap request: ", toDapCommandOrEvent(kind), rawValue
    # let response = 
    discard dap.vscode.debug.activeDebugSession.customRequest(toDapCommandOrEvent(kind), rawValue)
    # console.log cstring"<- dap response(or undefined if timeout): ", response
    # if kind in CT_EVENT_DAP_TRACKING_RESPONSE_KINDS and not response.isNil:
    #   dap.receiveResponse(cast[cstring](response.command), response.value)

  proc newDapVsCodeApi*(vscode: VsCode, context: VsCodeContext): DapApi {.exportc.} =
    result = DapApi(vscode: vscode, context: context)
    proc onDidSendMessage(message: VsCodeDapMessage) =
      console.log cstring"<- dap message:", message
      if message.`type` == cstring"event":
        result.receiveEvent(message.event, message.body)
      elif message.`type` == cstring"response":
        try:
          result.receiveResponse(message.command, message.body)
        except ValueError as e:
          console.warn cstring"  receive response error: ", cstring(e.msg)

    context.subscriptions.push(
      vscode.debug.toJs.registerDebugAdapterTrackerFactory(cstring"*", js{
        createDebugAdapterTracker: proc(session: VsCodeDebugSession): JsObject =
          JsObject{
            onDidSendMessage: onDidSendMessage,
          }
        }
      ))

proc sendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  discard dap.asyncSendCtRequest(kind, rawValue)

