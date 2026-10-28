import
  std / [ async, jsffi, strutils, sequtils, jsconsole, sugar, json, os, strformat ],
  electron_vars, traces, files, startup, install, menu, online_sharing, window, logging, config, debugger, server_config, host_clients, base_handlers, bootstrap_cache, lsp_bridge,
  review_dataset, keybindings, table_columns, replay_open_in,
  ns9_panes,
  hcr_launch,
  build_runner,
  file_tree_operations,
  tab_answers,
  ipc_subsystems/[ dap, socket, acp_ipc ],
  results,
  ../lib/[ jslib, misc_lib, electron_lib ],
  ../[ types, config, trace_metadata ],
  ../../common/[ ct_logging, paths ],
  ../viewmodel/host/find_in_files

var Object {.importc, nodecl.}: JsObject

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
    mainWindow.webContents.send "CODETRACER::hcr-apply-edit-result", answerFor(response, js{
      status: status, surfaceRow: cstring"", message: message, remedy: cstring""})

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
      mainWindow.webContents.send "CODETRACER::hcr-apply-edit-result", answerFor(response, js{
        status: cstring"command-failed",
        surfaceRow: cstring"",
        message: cstring("the apply-edit command produced no report: " & detail),
        remedy: cstring""})
      return
    # The answer goes to the tab whose live-edit panel asked (`tab_answers`).
    mainWindow.webContents.send "CODETRACER::hcr-apply-edit-result", answerFor(response, js{
      status: report.status,
      surfaceRow: report.surfaceRow,
      message: report.message,
      remedy: report.remedy})

var findInFilesRuns = newFindInFilesService()
  ## The main process's Find in Files runner: the run in flight, cancelled
  ## when the renderer asks for the next one.

proc searchBatchToJs(batch: FindInFilesBatch): JsObject =
  ## One runner batch as the renderer's `CODETRACER::search-results-updated`
  ## payload: the run id the renderer drops stale batches by, the rows, and
  ## whether this is the last batch.
  var rows: seq[JsObject] = @[]
  # Iterated by index with an explicit copy, not `for r in batch.rows`.
  # jsffi's `js{...}` literal expands to an immediately-called anonymous
  # proc, so it CAPTURES `r` — and a `for x in seq` loop variable is
  # `lent T`, which cannot be captured:
  #
  #   Error: 'r' is of type <lent SearchResultLine> which cannot be captured
  #   as it would violate memory safety
  #
  # The tup build never sees this: `NIM_COMMON_FLAGS` in `src/Tuprules.tup`
  # passes `-d:nimNoLentIterators`, which makes `items` yield copies. The
  # Nix derivations (`nix/packages/default.nix`) do not pass it, so only the
  # packaged build (`nix build .#codetracer`) fails, and it fails on the
  # dev shell's Nim as well as on the packaged one. That flag divergence is
  # recorded in `scripts/test-build-alignment.sh`. This loop compiles under
  # both lanes, so it does not depend on how that divergence is resolved.
  for rowIndex in 0 ..< batch.rows.len:
    let r = batch.rows[rowIndex]
    rows.add js{text: cstring(r.text), path: cstring(r.path), line: r.line,
                matchStart: r.matchStart, matchLength: r.matchLength}
  js{id: batch.runId, rows: rows.toJs, done: batch.done,
     note: cstring(batch.note)}

proc onSearchProgram*(sender: js, request: JsObject) {.async.} =
  ## Handle ``CODETRACER::search-program`` from the renderer: run Find in
  ## Files through THE shared runner (``viewmodel/host/find_in_files``) — the
  ## one the terminal and GPUI run — and stream its batches back, each
  ## carrying the request's run id.
  ##
  ## The scope is the runner's ``findInFilesScope``, fed with this trace's
  ## facts: an imported recording's materialised ``files/`` store, else the
  ## source folders the Files panel shows (``sourceFoldersFromTracePaths``);
  ## with no trace (Edit mode), the folder CodeTracer was started in.
  let runId = request.id.to(int)
  let query = $request.query.to(cstring)
  let options = TextMatchOptions(
    caseSensitive: request.caseSensitive.to(bool),
    wholeWord: request.wholeWord.to(bool),
    regex: request.regex.to(bool))
  var store = ""
  var imported = false
  var folders: seq[string] = @[]
  if not data.trace.isNil:
    imported = data.trace.imported
    store = $nodePath.join(data.trace.outputFolder, cstring"files")
    for f in await sourceFoldersFromTracePaths(data.trace):
      folders.add $f
  elif not data.startOptions.folder.isNil:
    folders.add $data.startOptions.folder
  let scope = findInFilesScope(store, imported, folders)
  infoPrint "onSearchProgram: query=", query, " roots=", $scope.roots
  # Each batch goes to the tab whose Find in Files asked (`tab_answers`).
  let tab = askingTab(request)
  discard findInFilesRuns.search(runId, query, options, scope,
    proc(batch: FindInFilesBatch) =
      mainWindow.webContents.send "CODETRACER::search-results-updated",
                                  withTab(searchBatchToJs(batch), tab))

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
    # The Test Results pane's header ▶ on the desktop: `ct test run` over the
    # project, answered with `CODETRACER::test-suite-settled`
    # (`index/traces.onRunTestSuite`, `GUI/Core-Panes/Test-Results-Pane.md`
    # §4.3).
    "run-test-suite"
    # The BUILD panel's builds: a task or a typed command run by the main
    # process, and stopped (`index/build_runner`, Build-Output-Pane.md §4.2).
    "build-start"
    "build-cancel"
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
    # Issue #735 — "New file": edit mode with no project, answered by
    # `index/traces.onNewFile`. A browser tab reaches the same renderer state
    # through `ui/web_entry_surface.enterNewFileEditMode`, which delivers the
    # `CODETRACER::no-trace` this handler sends.
    "new-file"

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
    "acp-pick-files"

    "save-config"
    # PLAT-68: the renderer's stepping preset (`localStorage`), merged once
    # into `keybindings.json` (`index/keybindings.onKeybindingsImport`).
    "keybindings-import"
    "keybindings-request"
    # PLAT-70 Part B: the table panes' remembered column widths, one
    # document with the terminal and GPUI (`index/table_columns`).
    "table-columns-request"
    "table-columns-save"
    # Test-Results-Pane.md §9.3: the workspace's `replay-open-in`, one
    # document with the terminal and GPUI (`index/replay_open_in`).
    "replay-open-in-save"
    # Auto-hide (pinned panel) state.  It is persisted separately from the
    # GoldenLayout config because pinning a panel REMOVES it from the
    # GoldenLayout tree — see `onSaveAutoHideState` in `index/window.nim`.
    # `request-auto-hide-state` answers an `ipcRenderer.sendSync` from
    # `ui/layout.nim`'s `initLayout`.
    "save-auto-hide-state"
    "request-auto-hide-state"
    # PLAT-45: View > Reset Layout — `index/window.onResetLayout` deletes the
    # desktop's own saved layout files and answers `reset-layout-done`.
    "reset-layout"
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
    # The Files pane's Create, Rename and Delete in edit mode
    # (`index/file_tree_operations.nim`; Filesystem-Pane.md § "Context menu").
    "file-tree-create"
    "file-tree-rename"
    "file-tree-delete"
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

proc errorText(error: JsObject): string {.importjs: """
  (function (e) {
    if (e === null || e === undefined) { return ''; }
    return String(e.message !== undefined ? e.message : e);
  })(#)""".}
  ## What a Node error says (`message`), or the value itself as text.

proc failStartup(message: string) {.async.} =
  ## The session this process was started for cannot start: say why and exit
  ## non-zero, rather than wait for ever or open a window over a session with
  ## no backend (the session manager is every replay's parent, so without it
  ## nothing can be shown).
  ##
  ## * desktop: the reason on stdout and, outside the test harness, in an
  ##   error box (an app that disappears without a word is no better than one
  ##   that never opens); then the app exits 1.
  ## * `ct host`: every connected page is told the reason
  ##   (`CODETRACER::connection-disconnected`), and the server exits 1, which
  ##   `ct host` hands on as its own exit status (`trace/host.nim`), so a
  ##   supervisor or a test sees a cause rather than a session that never
  ##   starts.
  errorPrint "index: cannot start: ", message
  stopBackendManager()
  when defined(server):
    if not serverClients.isNil:
      serverClients.disconnectAll(cstring"server-error", cstring(message))
      # An emit is written when the event loop next runs: give the pages'
      # sockets a moment to carry the reason before the process ends.
      await asyncSleep(250)
    nodeProcess.exit(1)
  else:
    if not data.startOptions.inTest:
      electron.dialog.showErrorBox(cstring"CodeTracer cannot start", cstring(message))
    electron_vars.app.exit(1)

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
    await failStartup(fmt"the session-manager {backendManagerExe} could not be started: " &
      errorText(backendManager.error))
    return

  # The session manager listens where the wait below looks only once it has
  # bound its socket, and it EXITS when it cannot: a socket path longer than
  # a socket address holds (`sockaddr_un.sun_path`, under a deep
  # `CODETRACER_HOME`) is refused by name, on its stderr, which this process
  # shares. The wait used to retry for ever and no window opened, so its exit
  # ends the wait, with the path waited on and the exit status.
  var sessionManagerExit = ""
  backendManagerProcess.toJs.on(cstring"exit", proc(code: JsObject, signal: JsObject) =
    sessionManagerExit =
      if not signal.isNil and not signal.isUndefined: "signal " & errorText(signal)
      else: "code " & errorText(code))

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
      if sessionManagerExit.len > 0:
        await failStartup(fmt"the session-manager {backendManagerExe} exited ({sessionManagerExit}) " &
          fmt"before it wrote its port file {portFilePath}")
        return
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
      if sessionManagerExit.len > 0:
        await failStartup(fmt"the session-manager {backendManagerExe} exited ({sessionManagerExit}) " &
          fmt"before its socket {backendManagerSocketPath} appeared " &
          fmt"({backendManagerSocketPath.len} bytes); its own message is above")
        return
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
    # Every client gets a replay of its own (`host_clients`): the first takes
    # the one this startup opens, the others are started here; a client
    # stops only its own, and its replays are stopped when it is released.
    let clients = serverClients
    clients.startReplay = startReplayProcess
    clients.stopReplay = stopReplayProcess
    replayStopAllowed = proc(replayId: int): bool =
      clients.mayStopReplay(replayId)
    replayStopped = proc(replayId: int) =
      clients.forgetStoppedReplay(replayId)

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
  mainWindow = createMainWindow(config)
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
      # Which client hears it, and what each keeps for its next socket, is
      # `host_clients.deliver`'s decision (`ipc.route`): the asking client,
      # the client whose replay spoke, or every client.
      if not ipc.route.isNil:
        ipc.route(id, dapKey, serialized)
      else:
        ipc.emit(id, serialized)

  # bootstrap payloads that may need replay after reconnect
  let layout = await mainWindow.loadLayoutConfig(string(fmt"{userLayoutDir / $config.layout}.json"))
  data.layout = layout
  let helpers = await mainWindow.loadHelpers("/data" / "data.yaml")
  data.helpers = helpers
  data.config = config
  infoPrint "index: layout/helpers loaded, calling init"

  # init the UI directly; delayed timer scheduling can be skipped in server mode
  discard init(config, layout, helpers)
  infoPrint "index: init dispatched"
