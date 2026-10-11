import
  std / [ async, jsffi, json, os, sequtils, strutils ],
  results,
  electron_vars,
  ../lib/[ jslib, electron_lib ],
  ../[ types ],
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
        "height": 500,
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
      win.once("ready-to-show", proc() =
        win.webContents.openDevTools(js{"mode": cstring"detach"})
      )

    win.toJs


proc onInstallCt*(sender: js, response: js) {.async.} =
  installDialogWindow = createInstallSubwindow()

proc onAcpResponse*(sender: js, response: js) {.async.} =
  let resp = cast[cstring](response)

proc onDismissCtFrontend*(sender: js, dontAskAgain: bool) {.async.} =
  # very important, otherwise we might try to send a message to it
  # and we get a object is destroyed error or something similar
  installDialogWindow = nil

  if dontAskAgain:
    infoPrint "remembering to not ask again for installation"
    # `$CODETRACER_HOME/config`, else (as always) `~/.config/codetracer`.
    let dir = ctHomeAreaOr(chaConfig, getHomeDir() / ".config" / "codetracer")
    let configFile = dir / "dont_ask_again.txt"
    fs.writeFile(
      configFile.cstring,
      "dont_ask_again=true".cstring,
      proc(err: js) = discard)
  if not installResponseResolve.isNil:
    installResponseResolve(InstallResponse(kind: InstallResponseKind.Dismissed))

proc forwardJsonLine(line: cstring) =
  ## Parses a JSON progress line from ``ct install --json`` and forwards
  ## it to the install dialog subwindow as an IPC step event.
  ## Non-JSON lines (from sub-processes) are silently ignored.
  let lineStr = $line
  if lineStr.len == 0 or lineStr[0] != '{':
    return  # Skip non-JSON output from sub-processes.

  try:
    let parsed = parseJson(lineStr)
    let stepData = js{
      "kind": cstring"step",
      "step": cstring(parsed["step"].getStr),
      "status": cstring(parsed["status"].getStr),
      "message": cstring(parsed["message"].getStr),
    }
    if not installDialogWindow.isNil:
      installDialogWindow.webContents.send(
        "CODETRACER::ct-install-status",
        stepData)
  except JsonParsingError:
    discard  # Ignore malformed JSON.

proc onInstallCtFrontend*(sender: js, response: js) {.async.} =
  # Step 1: Non-privileged install (PATH + desktop file).
  # BPF and Agent Harbor are excluded — they require privilege elevation
  # and are handled in step 2 via pkexec.
  var args = @[
    cstring"install",
    cstring"--no-bpf",
    cstring"--no-agent-harbor",
    cstring"--json",
  ]

  if response["desktop"].to(bool):
    args.add(cstring"--desktop")

  if response["path"].to(bool):
    args.add(cstring"--path")

  let res = await readProcessOutputStreaming(
    codetracerExe.cstring,
    args,
    forwardJsonLine)

  var isOk = res.isOk

  # Step 2: Privileged install (BPF + Agent Harbor) via pkexec.
  # Both require root: BPF for setcap, Agent Harbor for package installation.
  # A single pkexec invocation covers both, so the user only sees one
  # password prompt.
  when defined(linux):
    let needsBpf = not response["bpf"].isNil and response["bpf"].to(bool)
    let needsAH =
      not response["agent-harbor"].isNil and
      response["agent-harbor"].to(bool)

    if isOk and (needsBpf or needsAH):
      var privArgs = @[
        codetracerExe.cstring,
        cstring"install",
        cstring"--no-path",
        cstring"--no-desktop",
        cstring"--json",
      ]
      if needsBpf:
        privArgs.add(cstring"--bpf")
      else:
        privArgs.add(cstring"--no-bpf")
      if needsAH:
        privArgs.add(cstring"--agent-harbor")
      else:
        privArgs.add(cstring"--no-agent-harbor")

      let privRes = await readProcessOutputStreaming(
        cstring"pkexec", privArgs, forwardJsonLine)
      if not privRes.isOk:
        # Privileged setup failure is non-fatal; PATH install still succeeded.
        echo "Warning: privileged install via pkexec failed."

  # Send completion event to the subwindow.
  let doneData = js{
    "kind": cstring"done",
    "status": if isOk: cstring"ok" else: cstring"problem",
  }

  if not installDialogWindow.isNil:
    installDialogWindow.webContents.send(
      "CODETRACER::ct-install-status",
      doneData)
  else:
    if isOk:
      echo "Installation complete."
    else:
      echo "Installation encountered errors."

proc isCtInstalled*(config: Config): bool =
  when defined(server):
    return true
  else:
    if not config.skipInstall:
      if process.platform == "win32".toJs:
        # On Windows there is no shell-launcher or .desktop install step;
        # the binary is already usable from the build directory.
        return true
      elif process.platform == "darwin".toJs:
        # `install_utils.shellLaunchersDir`'s rule (common/ct_home).
        let ctLaunchersPath = cstring(
          ctDataDirIgnoringXdg() / "shell-launchers" / "ct")
        return fs.existsSync(ctLaunchersPath)
      else:
        let defaultDataHome =
          getEnv("HOME") / ".local/share"
        let dataHome =
          getEnv("XDG_DATA_HOME", defaultDataHome)
        let defaultDirs =
          "/usr/local/share:/usr/share"
        let dataDirsCstring =
          getEnv("XDG_DATA_DIRS", defaultDirs)
            .split(cstring":")
        let dataDirs = dataDirsCstring.mapIt($it)

        # If we find the desktop file then it's
        # installed by the package manager.
        for d in @[dataHome] & dataDirs:
          if fs.existsSync(d / "applications/codetracer.desktop"):
            return true
        return false
    else:
      return true

proc waitForResponseFromInstall*: Future[InstallResponse] {.async.} =
  return newPromise() do (resolve: proc(response: InstallResponse)):
    installResponseResolve = resolve
