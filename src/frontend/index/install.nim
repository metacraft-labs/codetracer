import
  std / [ async, jsffi, json, os, sequtils ],
  results,
  electron_vars,
  ../[ types, lib ],
  ../../common/[ paths, ct_logging ]

type
  InstallResponseKind* {.pure.} = enum Ok, Problem, Dismissed

  InstallResponse = object
    case kind*: InstallResponseKind
    of Ok, Dismissed:
      discard
    of Problem:
      message*: string

var
  installResponseResolve: proc(response: InstallResponse)
  installDialogWindow*: JsObject
  process {.importc.}: js

proc createInstallSubwindow*(): js =
    let win = jsnew electron.BrowserWindow(
      js{
        "width": 700,
        "height": 422,
        "resizable": false,
        "parent": mainWindow,
        "modal": true,
        "webPreferences": js{
          "nodeIntegration": true,
          "contextIsolation": false,
          "spellcheck": false
        },
        "frame": false,
        "transparent": false,
        })

    let url = "file://" & $codetracerExeDir & "/subwindow.html"
    debugPrint "Attempting to load: ", url
    win.loadURL(cstring(url))

    let inDevEnv = nodeProcess.env[cstring"CODETRACER_DEV_TOOLS"] == cstring"1"
    if inDevEnv:
      electronDebug.devTools(win)

    win.toJs


proc onInstallCt*(sender: js, response: js) {.async.} =
  installDialogWindow = createInstallSubwindow()

proc onDismissCtFrontend*(sender: js, dontAskAgain: bool) {.async.} =
  # very important, otherwise we might try to send a message to it
  # and we get a object is destroyed error or something similar
  installDialogWindow = nil

  if dontAskAgain:
    infoPrint "remembering to not ask again for installation"
    let dir = getHomeDir() / ".config" / "codetracer"
    let configFile = dir / "dont_ask_again.txt"
    fs.writeFile(configFile.cstring, "dont_ask_again=true".cstring, proc(err: js) = discard)
  if not installResponseResolve.isNil:
    installResponseResolve(InstallResponse(kind: InstallResponseKind.Dismissed))

proc onInstallCtFrontend*(sender: js, response: js) {.async.} =
  var args = @[cstring"install"]

  if response["desktop"].to(bool):
    args.add(cstring"--desktop")

  if response["path"].to(bool):
    args.add(cstring"--path")

  let res = await readProcessOutput(
    codetracerExe.cstring,
    args)

  let isOk = res.isOk
  let status = if isOk:
      (cstring"ok", cstring"Succesfully installated")
    else:
      # TODO: propagate a more precise message
      (cstring"problem", cstring"there was a problem during installation")

  # leaving this code in, if we decide to re-enable showing
  # status in notifications as well:
  #
  # if not mainWindow.isNil:
  #  mainWindow.webContents.send "CODETRACER::ct-install-status", status

  if not installDialogWindow.isNil:
    installDialogWindow.webContents.send "CODETRACER::ct-install-status", status
  else:
    echo status[1]

proc isCtInstalled*(config: Config): bool =
  when defined(server):
    return true
  else:
    if not config.skipInstall:
      if process.platform == "darwin".toJs:
        let ctLaunchersPath = cstring($paths.home / ".local" / "share" / "codetracer" / "shell-launchers" / "ct")
        return fs.existsSync(ctLaunchersPath)
      else:
        let dataHome = getEnv("XDG_DATA_HOME", getEnv("HOME") / ".local/share")
        let dataDirsCstring = getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(cstring":")
        let dataDirs = dataDirsCstring.mapIt($it)

        # if we find the desktop file then it's installed by the package manager automatically
        for d in @[dataHome] & dataDirs:
          if fs.existsSync(d / "applications/codetracer.desktop"):
            return true
        return false
    else:
      return true

proc waitForResponseFromInstall*: Future[InstallResponse] {.async.} =
  return newPromise() do (resolve: proc(response: InstallResponse)):
    installResponseResolve = resolve
