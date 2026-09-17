import
  std / [ async, jsffi, strutils, sequtils, jsconsole, sugar, json, os, strformat ],
  electron_vars, traces, files, startup, install, menu, online_sharing, window, logging, config, debugger, server_config, base_handlers, bootstrap_cache, lsp_bridge,
  review_dataset,
  ns9_panes,
  hcr_launch,
  ipc_subsystems/[ dap, socket, acp_ipc ],
  results,
  ../lib/[ jslib, misc_lib, electron_lib ],
  ../[ types, config, trace_metadata ],
  ../../common/[ ct_logging, paths ]

var Object {.importc, nodecl.}: JsObject

proc fsExistsSync(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}

proc jsEmptyArray: JsObject {.importjs: "([])".}
  ## Return a fresh empty JS array.  Used to satisfy ``nimCopy``'s
  ## ``.length`` read when the renderer deserializes ``seq[SearchResult]``
  ## — without this, the ``customFields`` field arrives as ``undefined``
  ## and the copy crashes with "Cannot read properties of undefined
  ## (reading 'length')``.

proc nodeEnv(name: cstring): cstring {.importjs: "(process.env[#] || '')".}

proc execFileJson(
    command: cstring, args: JsObject,
    callback: proc(err: JsObject, stdout: cstring, stderr: cstring)) {.
  importjs: "require('child_process').execFile(#, #, {maxBuffer: 8 * 1024 * 1024}, #)".}

proc prependProcessArg(args: JsObject, value: cstring): JsObject {.
  importjs: "((function(a, v) { a.unshift(v); return a; })(#, #))".}

proc applyEditArgs(edit: cstring, socketPath: cstring, driver: cstring,
                   reportPath: cstring, waitFor: cstring, marker: cstring,
                   markerTimeoutMs: cstring, platform: cstring,
                   pid: cstring, pidFile: cstring, targetImage: cstring,
                   targetPdb: cstring,
                   firstInstructionLength: cstring,
                   releaseFile: cstring): JsObject {.importjs: """
  ((function(edit, sock, drv, report, waitFor, marker, timeout, platform,
             pid, pidFile, targetImage, targetPdb, firstInstructionLength,
             releaseFile) {
    var a = ["--edit", edit, "--driver", drv, "--json-out", report];
    if (platform === "windows") {
      a.push("--platform", "windows");
      if (pid) { a.push("--pid", pid); }
      if (pidFile) { a.push("--pid-file", pidFile); }
      a.push("--target-image", targetImage,
             "--target-pdb", targetPdb,
             "--first-instruction-length", firstInstructionLength);
    } else {
      a.push("--platform", "linux", "--socket", sock);
    }
    if (waitFor && marker) {
      a.push("--wait-for", waitFor, "--marker", marker);
      if (timeout) { a.push("--marker-timeout-ms", timeout); }
    }
    if (releaseFile) {
      a.push("--release-file", releaseFile);
    }
    return a;
  })(#, #, #, #, #, #, #, #, #, #, #, #, #, #))
""".}
  ## The command line handed to the apply-edit command, ONE-SHOT form: the
  ## command opens a coordinator, the target dials it, one patch is served and
  ## the connection closes.
  ##
  ## `--wait-for`/`--marker` are the command's own sequencing arguments: they
  ## make it publish once the target has *printed* a chosen line, rather than
  ## the instant the target connects. They are forwarded only when both are
  ## configured, because the command refuses the pair half-given — which is the
  ## right behaviour and not one to work around here.

proc applyEditSessionArgs(edit: cstring, sessionDir: cstring,
                          reportPath: cstring): JsObject {.importjs: """
  ((function(edit, dir, report) {
    return ["--edit", edit, "--session-dir", dir, "--json-out", report];
  })(#, #, #))
""".}
  ## The command line handed to the apply-edit command, SESSION form.
  ##
  ## This is what makes the Scene-1 live-edit loop possible from the product,
  ## and the difference is not a convenience. The in-target HCR agent DIALS OUT
  ## exactly once, at process start, with a bounded retry and no later attempt.
  ## So the one-shot form above can be used ONCE per target process: the
  ## coordinator it spawns closes its connection after the patch, and there is
  ## no second dial-out to accept a replacement. Typing a second value would
  ## spawn a coordinator that waits forever for a target that has long since
  ## stopped trying to connect.
  ##
  ## With `--session-dir` the coordinator is already running and already
  ## connected — opened once when the target was launched — and each edit is a
  ## request into it. Neither `--socket` nor `--driver` is passed, and the
  ## command REFUSES them alongside `--session-dir` by name, because accepting
  ## them would suggest it could open a second connection to the same process.

proc readJsonReport(path: cstring): JsObject {.importjs: """
  ((function(p){
    try { return JSON.parse(require('fs').readFileSync(p, 'utf8')); }
    catch (e) { return null; }
  })(#))
""".}
  ## Read the apply-edit command's JSON report, or `null` if it is absent or
  ## unreadable. The two failures are deliberately one answer here: either way
  ## the command produced no verdict, and the caller reports that as its own
  ## named outcome rather than guessing at one.

proc isJsNull(value: JsObject): bool {.importjs: "(# == null)".}

proc onHcrApplyEdit*(sender: js, response: js) {.async.} =
  ## `CODETRACER::hcr-apply-edit` — run the project's apply-edit command and
  ## hand the renderer back exactly what it reported.
  ##
  ## THIS PROCESS DECIDES NOTHING ABOUT THE EDIT. It resolves where the command
  ## lives and which running process to talk to, runs it, and forwards its JSON
  ## report unchanged. Whether an edit is inside the supported edit surface, and
  ## which documented row a refusal maps onto, are the command's answers — a
  ## second opinion formed here would be a second vocabulary to keep in sync
  ## with the first, and the one that reached the user would be the wrong one.
  ##
  ## Configuration is by environment, which is the honest shape for a command
  ## whose target is a process this application did not start:
  ##
  ##   CODETRACER_HCR_APPLY_EDIT_CMD  the apply-edit command to run
  ##   CODETRACER_HCR_APPLY_EDIT_INTERPRETER  optional executable used to run
  ##                                  that script (needed for Python on Windows)
  ##   CODETRACER_HCR_SESSION_DIR     an ALREADY-OPEN live-edit session to
  ##                                  publish into. This is the Scene-1 loop's
  ##                                  path and is mutually exclusive with the
  ##                                  two below; see `applyEditSessionArgs`.
  ##   CODETRACER_HCR_SOCKET          the running target's HCR agent socket
  ##   CODETRACER_HCR_PLATFORM        `windows` for the PID/named-pipe path
  ##   CODETRACER_HCR_PID/_PID_FILE   the running Windows target identity
  ##   CODETRACER_HCR_TARGET_IMAGE    the loaded patchable DLL
  ##   CODETRACER_HCR_TARGET_PDB      that DLL's matching full PDB
  ##   CODETRACER_HCR_FIRST_INSTRUCTION_LENGTH  measured entry instruction
  ##   CODETRACER_HCR_RELEASE_FILE    optional target-side publication barrier
  ##   CODETRACER_HCR_DRIVER          the coordinator driver the command uses
  ##   CODETRACER_HCR_EDIT            the edit to apply, when the caller gave none
  ##   CODETRACER_HCR_WAIT_FOR        a file the command polls before publishing
  ##   CODETRACER_HCR_MARKER          the line it waits to see in that file
  ##   CODETRACER_HCR_MARKER_TIMEOUT_MS  how long it may wait
  ##   CODETRACER_HCR_REPORT          where to write the command's JSON report
  ##
  ## Every one of those being absent is REPORTED, with the name of the variable
  ## that is missing. A command that silently did nothing when it was not
  ## configured would be indistinguishable, from the screen, from one that ran
  ## and changed nothing — which is the exact confusion the whole HCR beat is
  ## built to avoid.
  #
  # A session this process LAUNCHED takes precedence over all of it, and there
  # is no ambiguity to resolve: `hcr_launch` answers with a session dir only
  # while a session it opened is `ready`, and that session's target is a
  # process this application started and is watching. When it answers, the
  # environment describes at best a different target and at worst one that no
  # longer exists.
  let launchedSessionDir = activeHcrSessionDir()
  let launchedCommand = activeHcrApplyEditCommand()
  let launchedInterpreter = activeHcrApplyEditInterpreter()
  let command =
    if launchedCommand.len > 0: launchedCommand
    else: nodeEnv(cstring"CODETRACER_HCR_APPLY_EDIT_CMD")
  let interpreter =
    if launchedSessionDir.len > 0: launchedInterpreter
    else: nodeEnv(cstring"CODETRACER_HCR_APPLY_EDIT_INTERPRETER")
  let sessionDir =
    if launchedSessionDir.len > 0: launchedSessionDir
    else: nodeEnv(cstring"CODETRACER_HCR_SESSION_DIR")
  let socketPath = nodeEnv(cstring"CODETRACER_HCR_SOCKET")
  let driver = nodeEnv(cstring"CODETRACER_HCR_DRIVER")
  let platform = nodeEnv(cstring"CODETRACER_HCR_PLATFORM")
  let targetPid = nodeEnv(cstring"CODETRACER_HCR_PID")
  let targetPidFile = nodeEnv(cstring"CODETRACER_HCR_PID_FILE")
  let targetImage = nodeEnv(cstring"CODETRACER_HCR_TARGET_IMAGE")
  let targetPdb = nodeEnv(cstring"CODETRACER_HCR_TARGET_PDB")
  let firstInstructionLength =
    nodeEnv(cstring"CODETRACER_HCR_FIRST_INSTRUCTION_LENGTH")
  let windowsEndpoint = $platform == "windows"
  var edit = cstring""
  if not response.isNil and not response.edit.isNil:
    edit = cast[cstring](response.edit)
  if edit.len == 0:
    edit = nodeEnv(cstring"CODETRACER_HCR_EDIT")

  proc refuse(status: cstring, message: cstring) =
    mainWindow.webContents.send "CODETRACER::hcr-apply-edit-result", js{
      status: status, surfaceRow: cstring"", message: message, remedy: cstring""}

  if command.len == 0:
    refuse(cstring"not-configured",
      cstring"no apply-edit command is configured for this project; name it as `hcr.applyEditCommand` in the project's .vscode/launch.json, or set CODETRACER_HCR_APPLY_EDIT_CMD")
    return
  # A LIVE-EDIT SESSION takes precedence, and the two are mutually exclusive on
  # purpose rather than by accident. Configuring both would leave it to this
  # process to guess whether the caller meant "patch the running target once"
  # or "add an edit to the open loop", and the wrong guess is not recoverable:
  # the one-shot form consumes the target's single dial-out.
  #
  # The check applies only when BOTH came from the environment. A session this
  # process launched is not in competition with a leftover variable: it names a
  # target this application started, is watching, and will tear down, so it
  # wins outright rather than producing a refusal about someone else's target.
  if launchedSessionDir.len == 0 and sessionDir.len > 0 and
      (socketPath.len > 0 or driver.len > 0 or windowsEndpoint):
    refuse(cstring"not-configured",
      cstring"CODETRACER_HCR_SESSION_DIR is set together with CODETRACER_HCR_SOCKET/_DRIVER; those are two different publication paths and only one can own the target's single agent connection. Unset the ones you do not mean.")
    return
  if sessionDir.len == 0:
    if driver.len == 0:
      refuse(cstring"not-configured",
        cstring"no HCR coordinator driver is configured; set CODETRACER_HCR_DRIVER")
      return
    if windowsEndpoint:
      if targetPid.len == 0 and targetPidFile.len == 0:
        refuse(cstring"not-configured",
          cstring"the Windows HCR endpoint needs CODETRACER_HCR_PID or CODETRACER_HCR_PID_FILE")
        return
      if targetPid.len > 0 and targetPidFile.len > 0:
        refuse(cstring"not-configured",
          cstring"CODETRACER_HCR_PID and CODETRACER_HCR_PID_FILE are mutually exclusive")
        return
      if targetImage.len == 0 or targetPdb.len == 0 or
          firstInstructionLength.len == 0:
        refuse(cstring"not-configured",
          cstring"the Windows HCR endpoint needs CODETRACER_HCR_TARGET_IMAGE, CODETRACER_HCR_TARGET_PDB, and CODETRACER_HCR_FIRST_INSTRUCTION_LENGTH")
        return
      if socketPath.len > 0:
        refuse(cstring"not-configured",
          cstring"CODETRACER_HCR_SOCKET cannot be combined with the Windows PID/named-pipe endpoint")
        return
    elif socketPath.len == 0:
      refuse(cstring"not-configured",
        cstring"no running HCR target is configured; set CODETRACER_HCR_SESSION_DIR for a live-edit session, or CODETRACER_HCR_SOCKET to the agent socket of the process to patch")
      return
  if edit.len == 0:
    refuse(cstring"no-edit-given",
      cstring"no edit was given; pass one as the action's `edit` field or set CODETRACER_HCR_EDIT")
    return

  # Where the command's JSON report is written. `CODETRACER_HCR_REPORT` exists
  # so the report SURVIVES the run: the default lands in `TMPDIR`, which a nix
  # dev shell recreates per invocation and removes on exit, and a measurement
  # whose artifact is gone by the time anyone looks is one nobody can check.
  var reportPath = $nodeEnv(cstring"CODETRACER_HCR_REPORT")
  if reportPath.len == 0:
    var tmpDir = $nodeEnv(cstring"TMPDIR")
    if tmpDir.len == 0:
      tmpDir = $nodeEnv(cstring"TEMP")
    if tmpDir.len == 0:
      tmpDir = "/tmp"
    reportPath = tmpDir & "/ct-hcr-apply-edit-report.json"
  let args =
    if sessionDir.len > 0:
      applyEditSessionArgs(edit, sessionDir, cstring(reportPath))
    else:
      applyEditArgs(
        edit, socketPath, driver, cstring(reportPath),
        nodeEnv(cstring"CODETRACER_HCR_WAIT_FOR"),
        nodeEnv(cstring"CODETRACER_HCR_MARKER"),
        nodeEnv(cstring"CODETRACER_HCR_MARKER_TIMEOUT_MS"),
        platform, targetPid, targetPidFile, targetImage, targetPdb,
        firstInstructionLength,
        nodeEnv(cstring"CODETRACER_HCR_RELEASE_FILE"))
  infoPrint "index: running the apply-edit command for edit " & $edit &
    (if sessionDir.len > 0: " into the live-edit session at " & $sessionDir
     elif windowsEndpoint:
       " through the Windows PID/named-pipe endpoint"
     else: " through a one-shot coordinator on " & $socketPath)
  let executable = if interpreter.len > 0: interpreter else: command
  let processArgs =
    if interpreter.len > 0: prependProcessArg(args, command)
    else: args
  execFileJson(executable, processArgs) do (err: JsObject, stdout: cstring, stderr: cstring):
    # The command's EXIT CODE is not the answer and is not read here: 0 is
    # applied, 2 is a refusal and 1 is the command itself failing, and all three
    # arrive in `err` as "non-zero" with no way to tell them apart. The JSON
    # report is the answer, and its absence is its own named outcome rather than
    # being folded into whichever of the three happened to be true.
    let report = readJsonReport(reportPath)
    if isJsNull(report):
      var detail = $stderr
      if detail.len == 0:
        detail = $stdout
      mainWindow.webContents.send "CODETRACER::hcr-apply-edit-result", js{
        status: cstring"command-failed",
        surfaceRow: cstring"",
        message: cstring("the apply-edit command produced no report: " & detail),
        remedy: cstring""}
      return
    mainWindow.webContents.send "CODETRACER::hcr-apply-edit-result", js{
      status: report.status,
      surfaceRow: report.surfaceRow,
      message: report.message,
      remedy: report.remedy}

proc onSearchProgram*(sender: js, response: cstring) {.async.} =
  ## Handle ``CODETRACER::search-program`` from the renderer.
  ##
  ## Searches exactly the source folders shown in the Files panel.
  ## ``sourceFoldersFromTracePaths`` returns the same roots the Files panel
  ## filesystem tree uses, so the search scope matches what the user sees —
  ## e.g. only ``ruby_space_ship/`` for a Ruby trace rather than the wider
  ## ``examples/`` parent directory.
  ##
  ## Only folders that actually exist on disk are searched; trace-internal
  ## paths that map into a materialized ``files/`` tree are resolved to that
  ## tree as a fallback.
  let query = $response
  if query.len == 0:
    return

  let escapedQuery = query.replace("'", "'\\''")

  var searchRoot = ""
  # When we search inside the materialized files/ tree, rg returns paths like
  # <outputFolder>/files/home/user/project/foo.rb.  We strip this prefix so
  # the renderer receives the original on-disk path and opens the real file
  # rather than the trace-internal copy.
  var materialisedFilesPrefix = ""

  if not data.trace.isNil:
    if data.trace.imported:
      # Imported (recorder) traces materialize source files into the trace
      # output's files/ subdirectory.  This is exactly what the Files panel
      # shows, so searching it gives the right scope without touching the
      # wider project tree or the codetracer repo root.
      let filesRoot = $nodePath.join(data.trace.outputFolder, cstring"files")
      if fsExistsSync(cstring(filesRoot)):
        searchRoot = filesRoot
        materialisedFilesPrefix = filesRoot

    if searchRoot.len == 0:
      # Live trace (or imported trace with no materialized files/):
      # use sourceFoldersFromTracePaths, which returns the same roots the
      # Files panel filesystem tree uses.
      let sourceFolders = await sourceFoldersFromTracePaths(data.trace)
      for f in sourceFolders:
        let s = $f
        if s.len > 0 and fsExistsSync(cstring(s)):
          searchRoot = s
          break

  if searchRoot.len == 0:
    infoPrint "onSearchProgram: no search root for query: ", query
    var emptyBatch: seq[JsObject] = @[]
    mainWindow.webContents.send "CODETRACER::search-results-updated", emptyBatch.toJs
    return

  let escapedRoot = searchRoot.replace("'", "'\\''")
  let rgCmd = cstring(&"rg -n -F -i -H --no-heading -- '{escapedQuery}' '{escapedRoot}'")
  infoPrint "onSearchProgram: rg query=", query, " root=", searchRoot

  # rg exits with code 1 for no matches — that is not an error.
  let (stdoutData, _, _) = await childProcessExec(rgCmd)

  let lines = ($stdoutData).splitLines()
  var batch: seq[JsObject] = @[]
  for rawLine in lines:
    if rawLine.len == 0:
      continue
    # rg -H --no-heading output:  path:linenum:text
    # Paths on Linux do not contain colons, so the first two colons delimit.
    let colonIdx1 = rawLine.find(':')
    if colonIdx1 < 0:
      continue
    let colonIdx2 = rawLine.find(':', colonIdx1 + 1)
    if colonIdx2 < 0:
      continue
    var filePath = rawLine[0 ..< colonIdx1]
    let lineStr  = rawLine[colonIdx1 + 1 ..< colonIdx2]
    let lineText = rawLine[colonIdx2 + 1 .. ^1]
    var lineNum = 0
    try:
      lineNum = parseInt(lineStr)
    except:
      continue
    # Strip the materialized files/ prefix so the renderer opens the real
    # source file (/home/user/project/foo.rb) instead of the trace copy
    # (<outputFolder>/files/home/user/project/foo.rb).
    if materialisedFilesPrefix.len > 0 and filePath.startsWith(materialisedFilesPrefix):
      filePath = filePath[materialisedFilesPrefix.len .. ^1]
    batch.add(js{text: cstring(lineText), path: cstring(filePath), line: lineNum, customFields: jsEmptyArray()})
    if batch.len >= 50:
      mainWindow.webContents.send "CODETRACER::search-results-updated", batch.toJs
      batch = @[]

  # Always send the final batch, even when empty, so the renderer can
  # clear the loading shimmer when ripgrep finds no matches.
  mainWindow.webContents.send "CODETRACER::search-results-updated", batch.toJs

# handling incoming messages from frontend:
#   calls on<actionToCamelCase>
#   with sender, response
# ipc.on("maximize-window", onMaximizeWindow.toJs)
proc configureIpcMain* =
  indexIpcHandlers("CODETRACER::"):
    # main window controls
    "minimize-window"
    "restore-window"
    "maximize-window"
    "close-window"

    "load-path-for-record"
    "choose-dir"
    "new-record"
    "install-ct"
    "install-ct-frontend"
    "dismiss-ct-frontend"
    "stop-recording-process"
    "load-trace-by-record-process-id"
    "path-validation"
    "save-file"
    "save-untitled"
    "no-reload-file"
    "run-test"
    "restart-subsystem"

    # welcome screen options
    "load-codetracer-shell"
    "load-recent-trace"
    "open-local-trace"
    "open-folder-dialog"
    "load-recent-folder"
    "load-recent-transaction"
    "open-trace-dialog"
    "load-trace-file"
    # AA-3 — read the review dataset an evidence tool call in the Agent
    # Activity session feed names, and either report its shape or enter a
    # review over it (`index/review_dataset.onOpenReviewDataset`).
    "open-review-dataset"
    "record-from-launch"
    "record-with-launch-config"
    "init-edit-mode"

    # NS9 — the one message Test Results and Constraints are fed by. Answered
    # here by `index/ns9_panes.onNs9Panes`, and in a browser by
    # `ui/web_entry_surface.installTemplatePaneHost`.
    "ns9-panes"

    "tab-load"
    "load-low-level-tab"

    # Dap
    "dap-raw-message"

    # LSP
    "start-lsp"

    # Acp
    "acp-prompt"
    "acp-session-init"
    "acp-stop"
    "acp-cancel-prompt"

    "save-config"
    # Auto-hide (pinned panel) state.  It is persisted separately from the
    # GoldenLayout config because pinning a panel REMOVES it from the
    # GoldenLayout tree — see `onSaveAutoHideState` in `index/window.nim`.
    # `request-auto-hide-state` answers an `ipcRenderer.sendSync` from
    # `ui/layout.nim`'s `initLayout`.
    "save-auto-hide-state"
    "request-auto-hide-state"
    "exit-error"
    "started"
    "open-tab"
    "close-app"
    "show-in-debug-instance"
    "send-bug-report-and-logs"

    # Multi-window (M17)
    "open-new-window"

    # Open trace as a new tab in the current window (tab-vs-window policy)
    "open-trace-in-tab"

    # Cross-window panel transfer (M21)
    "panel-detach"
    "list-windows"

    # Session lifecycle
    "close-replay-session"

    # Upload/Download
    "upload-trace-file"
    "download-trace-file"
    "delete-online-trace-file"
    "lsp-get-url"

    # H4 — the in-app apply-edit -> HCR reload command.
    "hcr-apply-edit"

    # H6 — launching a target UNDER hot code reload, which is the half of the
    # Scene-1 loop the product did not have: the session coordinator, the target
    # started into it, and the session's lifetime. See `index/hcr_launch.nim`
    # and `The-Flame-Demo-Spec.md` §2.5.
    "hcr-launch-target"


  when defined(ctmacos):
    indexIpcHandlers("CODETRACER::"):
      "register-menu"

  indexIpcHandlers("CODETRACER::"):
    "restart"
    # update filesystem component
    "load-path-content"
    "open-devtools"
    "search-program"


proc loadHelpers(main: js, filename: string): Future[Helpers] {.async.} =
  var file = cstring(userConfigDir & filename)
  let (raw, err) = await fsReadFileWithErr(file)
  if not err.isNil:
    return JsAssoc[cstring, Helper]{}
  var res = cast[Helpers](yaml.load(raw)[cstring"helpers"])
  return res

let runtimePlatform {.importjs: "process.platform", nodecl.}: cstring

proc ready*(): Future[void] {.async.} =
  infoPrint "index: ready start"
  infoPrint "index: backendManagerExe = ", backendManagerExe
  let spawnOptions = when defined(windows):
    js{ "windowsHide": true }
  else:
    js{ "stdio": cstring"inherit" }
  let processEnv = js{}
  let nodeEnv = nodeProcess.toJs.env
  let envKeys = Object.keys(nodeEnv)
  for i in 0..<cast[int](envKeys.length):
    let key = envKeys[i].to(cstring)
    processEnv[key] = nodeEnv[key]
  processEnv[cstring"CODETRACER_TMP_PATH"] = cstring(codetracerTmpPath)
  spawnOptions["env"] = processEnv
  let backendManager = await startProcess(backendManagerExe.cstring, @[], spawnOptions)
  if backendManager.isOk:
    backendManagerProcess = backendManager.value
    infoPrint "index: session-manager started, pid = ", $backendManagerProcess.pid
  else:
    errorPrint "index: session-manager FAILED to start: ", backendManager.error
    errorPrint "index: backendManagerExe was: ", backendManagerExe

  if runtimePlatform == cstring"win32":
    # On Windows, the session-manager uses TCP on localhost.
    # It writes the port number to a .port file.
    let portFilePath = codetracerTmpPath / "session-manager" / $backendManagerProcess.pid & ".port"
    infoPrint "index: waiting for TCP port file at ", portFilePath

    await asyncSleep(100)

    var socketAttempt = 0
    while true:
      let portStr = await readPortFile(portFilePath)
      if portStr.len > 0:
        let port = parseInt(portStr)
        if port > 0:
          backendManagerSocket = await startTcpSocket(cstring"127.0.0.1", port)
          if not backendManagerSocket.isNil:
            break
      socketAttempt += 1
      if socketAttempt mod 5 == 0:
        infoPrint "index: still waiting for session-manager TCP port (attempt ", $socketAttempt, ")"
      await asyncSleep(1000)
  else:
    let backendManagerSocketPath =
      codetracerTmpPath / "session-manager" / $backendManagerProcess.pid & ".sock"
    infoPrint "index: waiting for socket at ", backendManagerSocketPath

    await asyncSleep(100)

    var socketAttempt = 0
    while true:
      backendManagerSocket = await startSocket(backendManagerSocketPath)
      if not backendManagerSocket.isNil:
        break
      socketAttempt += 1
      if socketAttempt mod 5 == 0:
        infoPrint "index: still waiting for session-manager socket (attempt ", $socketAttempt, ")"
      await asyncSleep(1000)

  setupProxyForDap(backendManagerSocket)
  infoPrint "index: session manager socket configured"

  configureIpcMain()

  # we load the config file
  var config = await mainWindow.loadConfig(data.startOptions, home=paths.home.cstring, send=true)
  infoPrint "index: config loaded"
  when defined(server):
    # replay bootstrap state on reconnect (server builds only)
    ipc.replayBootstrap = proc() =
      if data.bootstrapMessages.len == 0:
        debugPrint "ipc replay bootstrap: nothing cached"
      else:
        debugPrint cstring(fmt"ipc replay bootstrap: {data.bootstrapMessages.len} messages")
        replayBootstrap(data.bootstrapMessages, proc(id: cstring, payload: cstring) =
          ipc.emit(id, payload))

  when not defined(server):
    # Skip the install dialog entirely when running in test mode
    # (CODETRACER_TEST=1). Without this, the dialog blocks creation of
    # the main window and Playwright tests see only subwindow.html.
    if not data.startOptions.inTest:
      config.skipInstall = isCtInstalled(config)
      if not config.skipInstall:
        installDialogWindow = createInstallSubwindow()
        discard await waitForResponseFromInstall()

  debugPrint "index: creating window"
  mainWindow = createMainWindow()
  registerMainWindow()
  infoPrint "index: main window created"
  sendLspStatusToRenderer()

  when not defined(server):
    mainWindow.setMenuBarVisibility(false)
    mainWindow.setMenu(jsNull)
  # TODO cleanup code
  data.pluginClient = PluginClient(
    cancelled: false,
    running: false,
    cancelOrWaitFunction: nil,
    window: mainWindow,
    trace: nil,
    startOptions: data.startOptions)

  when not defined(server):
    # we hook output code in send for debug
    var internalSend = mainWindow.webContents.send

    mainWindow.webContents.send = proc(id: cstring, data: js) =
      # debug "send", _ = $id
      # too much content sometimes here, just log we did it
      if id == "filenames-loaded":
        debugPrint cstring"frontend ... <=== index: ", id, "[..not shown to optimize send time..]"
      else:
        debugPrint cstring"frontend ... <=== index: ", id
      debugIndex fmt"frontend ... <=== index: {id}"  # TODO? too big: {Json.stringify(data, nil, 2.toJs)}"
      debugSend(mainWindow.webContents, internalSend, id, data)

  else:
    proc replacer(key: cstring, value: js): js =
      if key == cstring"m_type":
        undefined
      else:
        value

    proc recordBootstrap(id, key, serialized: cstring) =
      ## Cache a payload for replay on socket reconnect.
      ##
      ## ``key`` differentiates multiple payloads on the same channel
      ## (used by ``dap-receive-event`` so distinct DAP events do not
      ## clobber each other in the cache).  For the legacy single-
      ## payload channels listed in ``bootstrapEvents`` the key is empty.
      if id in bootstrapEvents:
        let payload = BootstrapPayload(id: id, key: cstring"", payload: serialized)
        upsertBootstrap(data.bootstrapMessages, payload)
      elif id == cstring"CODETRACER::dap-receive-event" and key.len > 0:
        let payload = BootstrapPayload(id: id, key: key, payload: serialized)
        upsertBootstrap(data.bootstrapMessages, payload)

    proc dapReceiveEventKey(response: js): cstring =
      ## Extract the inner DAP event name from a ``dap-receive-event``
      ## payload, returning an empty string when the event is not one
      ## of the bootstrap-critical kinds we want to cache.
      if response.isNil:
        return cstring""
      let raw = response[cstring"event"]
      if raw.isUndefined or raw.isNull:
        return cstring""
      let eventName = cast[cstring](raw)
      bootstrapDapEventKey(eventName)

    mainWindow.webContents.send = proc(id: cstring, response: js) =
      debugPrint cstring"frontend ... <=== index: ", id, response
      let serialized = JSON.stringify(response, replacer, 2.toJs)
      debugIndex fmt"frontend ... <=== index: {id}"  # TODO? too big: {serialized}"
      let dapKey =
        if id == cstring"CODETRACER::dap-receive-event":
          dapReceiveEventKey(response)
        else:
          cstring""
      recordBootstrap(id, dapKey, serialized)
      ipc.emit(id, serialized)

  # bootstrap payloads that may need replay after reconnect
  let layout = await mainWindow.loadLayoutConfig(string(fmt"{userLayoutDir / $config.layout}.json"))
  data.layout = layout
  let helpers = await mainWindow.loadHelpers("/data" / "data.yaml")
  data.helpers = helpers
  data.config = config
  infoPrint "index: layout/helpers loaded, calling data.init"

  # init the UI directly; delayed timer scheduling can be skipped in server mode
  discard data.init(config, layout, helpers)
  infoPrint "index: data.init dispatched"
