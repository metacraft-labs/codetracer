import
  std/[jsffi, strformat],
  lib/jslib,
  ../common/ct_logging

when defined(js):
  proc ipcOn(ipc: JsObject; channel: cstring; handler: proc(sender: js, response: JsObject) {.closure.}) {.importjs: "#.on(#, #)".}
  proc ipcSend(ipc: JsObject; channel: cstring; payload: JsObject) {.importjs: "#.send(#, #)".}
  proc toJsString(value: JsObject): cstring {.importjs: "String(#)".}

var
  ipcRef: JsObject = nil
  lspUrl*: string = ""
  lspUrlObservers: seq[proc(url: string) {.closure.}] = @[]
  lastLspError*: string = ""

proc notifyObservers() =
  for observer in lspUrlObservers:
    observer(lspUrl)

proc onLspUrl(sender: js, response: JsObject) =
  let urlField = response["url"]
  if not urlField.isNil:
    lspUrl = $toJsString(urlField)
    infoPrint fmt"renderer:lsp url received: {lspUrl}"
  else:
    infoPrint "renderer:lsp url response missing url field"
  let runningField = response["running"]
  if not runningField.isNil and not cast[bool](runningField):
    warnPrint "renderer:lsp bridge reported not running"
  let errorField = response["error"]
  if not errorField.isNil:
    lastLspError = $toJsString(errorField)
    warnPrint fmt"renderer:lsp bridge error: {lastLspError}"
  notifyObservers()

proc initLspClient*(ipcObj: JsObject) =
  if ipcRef == ipcObj and not ipcRef.isNil:
    return
  ipcRef = ipcObj
  ipcOn(ipcRef, cstring"CODETRACER::lsp-url", onLspUrl)
  ipcSend(ipcRef, cstring"CODETRACER::lsp-get-url", js{})

proc requestLspUrl* =
  if ipcRef.isNil:
    return
  ipcSend(ipcRef, cstring"CODETRACER::lsp-get-url", js{})

proc onLspUrlChange*(observer: proc(url: string) {.closure.}) =
  if observer.isNil:
    return
  lspUrlObservers.add(observer)
  if lspUrl.len > 0:
    observer(lspUrl)
