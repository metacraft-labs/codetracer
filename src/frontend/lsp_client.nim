import
  std/[jsffi, strformat, tables],
  lib/jslib,
  ../common/ct_logging

when defined(js):
  proc ipcOn(ipc: JsObject; channel: cstring; handler: proc(sender: js, response: JsObject) {.closure.}) {.importjs: "#.on(#, #)".}
  proc ipcSend(ipc: JsObject; channel: cstring; payload: JsObject) {.importjs: "#.send(#, #)".}
  proc toJsString(value: JsObject): cstring {.importjs: "String(#)".}

type
  LspStatus* = object
    url*: string
    running*: bool
    error*: string

const
  defaultLspKind* = "rust"

var
  ipcRef: JsObject = nil
  lspUrl*: string = ""
  lastLspError*: string = ""
  statusByKind = initTable[string, LspStatus]()
  lspUrlObserversByKind = initTable[string, seq[proc(url: string) {.closure.}]]()

proc getStatus(kind: string): LspStatus =
  if statusByKind.hasKey(kind):
    statusByKind[kind]
  else:
    LspStatus()

proc setStatus(kind: string; status: LspStatus) =
  statusByKind[kind] = status

proc getLspUrl*(kind: string = defaultLspKind): string =
  if kind == defaultLspKind and lspUrl.len > 0:
    return lspUrl
  result = getStatus(kind).url

proc notifyObservers(kind: string) =
  if not lspUrlObserversByKind.hasKey(kind):
    return
  let url = getLspUrl(kind)
  for observer in lspUrlObserversByKind[kind]:
    observer(url)

proc onLspUrl(sender: js, response: JsObject) =
  var kind = defaultLspKind
  let kindField = response["kind"]
  if not kindField.isNil:
    let rawKind = $toJsString(kindField)
    if rawKind.len > 0:
      kind = rawKind
  var status = getStatus(kind)
  let urlField = response["url"]
  if not urlField.isNil:
    status.url = $toJsString(urlField)
    infoPrint fmt"renderer:lsp url received ({kind}): {status.url}"
  else:
    status.url = ""
    infoPrint fmt"renderer:lsp url response missing url field (kind={kind})"
  let runningField = response["running"]
  if not runningField.isNil:
    status.running = cast[bool](runningField)
    if not status.running:
      warnPrint fmt"renderer:lsp bridge reported not running ({kind})"
  else:
    status.running = false
  let errorField = response["error"]
  if not errorField.isNil:
    status.error = $toJsString(errorField)
    warnPrint fmt"renderer:lsp bridge error ({kind}): {status.error}"
  else:
    status.error = ""
  setStatus(kind, status)
  if kind == defaultLspKind:
    lspUrl = status.url
    lastLspError = status.error
  notifyObservers(kind)

proc initLspClient*(ipcObj: JsObject) =
  if ipcRef == ipcObj and not ipcRef.isNil:
    return
  ipcRef = ipcObj
  ipcOn(ipcRef, cstring"CODETRACER::lsp-url", onLspUrl)
  ipcSend(ipcRef, cstring"CODETRACER::lsp-get-url", js{})

proc requestLspUrl*(kind: string = defaultLspKind) =
  if ipcRef.isNil:
    return
  if kind.len == 0 or kind == defaultLspKind:
    ipcSend(ipcRef, cstring"CODETRACER::lsp-get-url", js{})
  else:
    ipcSend(ipcRef, cstring"CODETRACER::lsp-get-url", js{kind: kind.cstring})

proc onLspUrlChange*(observer: proc(url: string) {.closure.}; kind: string = defaultLspKind) =
  if observer.isNil:
    return
  var observers = lspUrlObserversByKind.getOrDefault(kind, @[])
  observers.add(observer)
  lspUrlObserversByKind[kind] = observers
  let currentUrl = getLspUrl(kind)
  if currentUrl.len > 0:
    observer(currentUrl)
