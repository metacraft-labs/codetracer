import
  std / [ async, jsffi, json, jsconsole, strformat ],
  files,
  ../../[ lib, lang, types, index_config ],
  ../../../common/ct_logging

proc onTabLoad*(sender: js, response: jsobject(location=types.Location, name=cstring, editorView=EditorView, lang=Lang)) {.async.} =
  console.log response
  case response.lang:
  of LangC, LangCpp, LangRust, LangNim, LangGo, LangRubyDb:
    if response.editorView in {ViewSource, ViewTargetSource, ViewCalltrace}:
      discard mainWindow.openTab(response.location, response.lang, response.editorView)
    else:
     discard
  of LangAsm:
    if response.editorView == ViewInstructions:
      let res = await data.nativeLoadInstructions(FunctionLocation(path: response.location.path, name: response.location.functionName, key: response.location.key))
      mainWindow.webContents.send "CODETRACER::tab-load-received", js{argId: response.name, value: res}
  else:
    discard mainWindow.openTab(response.location, response.lang, response.editorView)

proc onLoadLowLevelTab*(sender: js, response: jsobject(pathOrName=cstring, lang=Lang, view=EditorView)) {.async.} =
  case response.lang:
  of LangC, LangCpp, LangRust, LangGo:
    case response.view:
    of ViewTargetSource:
      warnPrint fmt"low level view source not supported for {response.lang}"
    of ViewInstructions:
      let res = await data.nativeLoadInstructions(FunctionLocation(name: response.pathOrName))
      mainWindow.webContents.send "CODETRACER::low-level-tab-received", js{argId: response.pathOrName & j" " & j($response.view), value: res}
    else:
      warnPrint fmt"low level view {response.view} not supported for {response.lang}"
  of LangNim:
    case response.view:
    of ViewTargetSource, ViewInstructions:
      let res = await data.nimLoadLowLevel(response.pathOrName, response.view)
      mainWindow.webContents.send "CODETRACER::low-level-tab-received", js{argId: response.pathOrName & j" " & j($response.view), value: res}
    else:
      warnPrint fmt"low level view {response.view} not supported for {response.lang}"
  else:
    warnPrint fmt"low level view not supported for {response.lang}"

proc onOpenTab*(sender: js, response: js) {.async.} =
  let options = js{
    properties: @[j"openFile"],
    title: cstring"Select File",
    buttonLabel: cstring"Select"}

  let file = await selectFileOrFolder(options)
  if file != "":
    if file.slice(-4) == j".nim":
      mainWindow.webContents.send "CODETRACER::opened-tab", js{path: file, lang: LangNim}
    else:
      mainWindow.webContents.send "CODETRACER::opened-tab", js{path: file, lang: LangUnknown}