import
  std/[ jsffi, strutils, sequtils ],
  ui_imports,
  ../[ types ]
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types import
  RecentTraceRecord, RecentFolderRecord, WelcomeStartOptionRecord,
  WelcomeScreenMode, wsmWelcome, wsmNewRecord, wsmOnlineTrace, wsmEdit
from ../viewmodel/viewmodels/welcome_screen_vm import
  WelcomeScreenVM, NewRecordFormState, createWelcomeScreenVM, setRecentTraces,
  setRecentFolders, setStartOptions, setMode, updateNewRecord,
  syncLoadingState,
  setOnlineTraceInput
from ../viewmodel/viewmodels/welcome_screen_vm import optionKey, NO_LOADING_TRACE
when defined(js):
  from isonim/web/dom_api as isonim_dom import nil
  from ../viewmodel/views/isonim_welcome_screen_view import
    mountIsoNimWelcomeScreen, WelcomeScreenCallbacks

var welcomeScreenVMInstance*: WelcomeScreenVM
var welcomeScreenVMStore: ReplayDataStore
var welcomeScreenComponentRef: WelcomeScreenComponent
var welcomeScreenMountedComponentRef: WelcomeScreenComponent
var isoNimWelcomeScreenMounted = false

proc syncLegacyWelcomeScreenIntoVM*(self: WelcomeScreenComponent)
proc tryMountIsoNimWelcomeScreen*()
proc clearIsoNimWelcomeScreen*()
proc requestWelcomeScreenRender*(self: WelcomeScreenComponent)

proc safeStr(s: cstring): string =
  if s.isNil:
    ""
  else:
    $s

proc toStrings(args: seq[cstring]): seq[string] =
  result = @[]
  for arg in args:
    result.add(safeStr(arg))

proc newDefaultRecordForm(): NewTraceRecord =
  NewTraceRecord(
    defaultOutputFolder: true,
    status: RecordStatus(kind: RecordInit),
    args: @[],
    executable: cstring"",
    formValidator: RecordScreenFormValidator(
      validExecutable: true,
      invalidExecutableMessage: cstring(""),
      validOutputFolder: true,
      invalidOutputFolderMessage: cstring(""),
      validWorkDir: true,
      invalidWorkDirMessage: cstring(""),
      requiredFields: JsAssoc[cstring, bool]{
        "executable": true,
        "workDir": false,
        "outputFolder": false
      }
    )
  )

proc newDefaultDownloadRecord(): NewDownloadRecord =
  NewDownloadRecord(
    args: @[],
    status: RecordStatus(kind: RecordInit)
  )

proc ensureWelcomeScreenVm() =
  if welcomeScreenVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  welcomeScreenVMStore = createReplayDataStore(stubBackend)
  welcomeScreenVMInstance = createWelcomeScreenVM(welcomeScreenVMStore)

proc initWelcomeScreenVM*() =
  ensureWelcomeScreenVm()

proc legacyTraceRecord(trace: Trace): RecentTraceRecord =
  RecentTraceRecord(
    id: $trace.id,
    program: safeStr(trace.program),
    args: toStrings(trace.args),
    workdir: safeStr(trace.workdir),
    date: safeStr(trace.date),
    duration: safeStr(trace.duration),
  )

proc legacyFolderRecord(folder: RecentFolder): RecentFolderRecord =
  RecentFolderRecord(
    id: folder.id,
    name: safeStr(folder.name),
    path: safeStr(folder.path),
  )

proc welcomeStartOptions(self: WelcomeScreenComponent): seq[WelcomeStartOptionRecord] =
  @[
    WelcomeStartOptionRecord(
      key: optionKey("Open folder"),
      name: "Open folder",
      inactive: false,
    ),
    WelcomeStartOptionRecord(
      key: optionKey("Record new trace"),
      name: "Record new trace",
      inactive: false,
    ),
    WelcomeStartOptionRecord(
      key: optionKey("Open local trace"),
      name: "Open local trace",
      inactive: false,
    ),
    WelcomeStartOptionRecord(
      key: optionKey("Open online trace"),
      name: "Open online trace",
      inactive: not self.showTraceSharing,
    ),
    WelcomeStartOptionRecord(
      key: optionKey("CodeTracer shell"),
      name: "CodeTracer shell",
      inactive: true,
    ),
  ]

proc currentWelcomeMode(self: WelcomeScreenComponent): WelcomeScreenMode =
  if self.newRecordScreen:
    wsmNewRecord
  elif self.openOnlineTrace:
    wsmOnlineTrace
  elif not self.welcomeScreen and not self.data.isNil and self.data.ui.mode == EditMode:
    wsmEdit
  else:
    wsmWelcome

proc syncLegacyWelcomeScreenIntoVM*(self: WelcomeScreenComponent) =
  if self.isNil:
    return
  ensureWelcomeScreenVm()
  welcomeScreenComponentRef = self
  self.showTraceSharing =
    (not self.data.isNil and not self.data.config.isNil and
     self.data.config.traceSharing.enabled)
  if not self.data.isNil:
    var traces: seq[RecentTraceRecord] = @[]
    for trace in self.data.recentTraces:
      traces.add(legacyTraceRecord(trace))
    welcomeScreenVMInstance.setRecentTraces(traces)

    var folders: seq[RecentFolderRecord] = @[]
    for folder in self.data.recentFolders:
      folders.add(legacyFolderRecord(folder))
    welcomeScreenVMInstance.setRecentFolders(folders)

  welcomeScreenVMInstance.setStartOptions(self.welcomeStartOptions())
  welcomeScreenVMInstance.setMode(self.currentWelcomeMode())
  welcomeScreenVMInstance.syncLoadingState(
    self.loading,
    (if self.loadingTrace.isNil: NO_LOADING_TRACE else: $self.loadingTrace.id))
  welcomeScreenVMInstance.updateNewRecord(proc(form: var NewRecordFormState) =
    if self.newRecord.isNil:
      form.executable = ""
      form.args = @[]
      form.workDir = ""
      form.outputFolder = ""
      form.defaultOutputFolder = true
    else:
      form.executable = safeStr(self.newRecord.executable)
      form.args = toStrings(self.newRecord.args)
      form.workDir = safeStr(self.newRecord.workDir)
      form.outputFolder = safeStr(self.newRecord.outputFolder)
      form.defaultOutputFolder = self.newRecord.defaultOutputFolder
  )
  if self.newDownload.isNil:
    welcomeScreenVMInstance.setOnlineTraceInput("")
  else:
    welcomeScreenVMInstance.setOnlineTraceInput(self.newDownload.args.mapIt($it).join(" "))

proc requestWelcomeScreenRender*(self: WelcomeScreenComponent) =
  ## Refresh the direct IsoNim welcome screen mount after legacy state changes.
  self.syncLegacyWelcomeScreenIntoVM()
  tryMountIsoNimWelcomeScreen()

proc showNewRecordView*(self: WelcomeScreenComponent) =
  self.welcomeScreen = false
  self.newRecordScreen = true
  self.openOnlineTrace = false
  self.newRecord = newDefaultRecordForm()
  self.syncLegacyWelcomeScreenIntoVM()

proc showOnlineTraceView*(self: WelcomeScreenComponent) =
  self.openOnlineTrace = true
  self.welcomeScreen = false
  self.newRecordScreen = false
  self.newDownload = newDefaultDownloadRecord()
  self.syncLegacyWelcomeScreenIntoVM()

proc showWelcomeView*(self: WelcomeScreenComponent) =
  self.welcomeScreen = true
  self.newRecordScreen = false
  self.openOnlineTrace = false
  self.newRecord = nil
  self.newDownload = nil
  self.loading = false
  self.loadingTrace = nil
  self.syncLegacyWelcomeScreenIntoVM()

proc loadRecentTraceFromWelcome*(self: WelcomeScreenComponent; traceId: string) =
  self.loading = true
  self.loadingTrace = nil
  for trace in self.data.recentTraces:
    if $trace.id == traceId:
      self.loadingTrace = trace
      break
  self.syncLegacyWelcomeScreenIntoVM()
  self.data.ipc.send "CODETRACER::load-recent-trace", js{ traceId: cstring(traceId) }

proc loadRecentFolderFromWelcome*(self: WelcomeScreenComponent; folderPath: string) =
  self.loading = true
  self.syncLegacyWelcomeScreenIntoVM()
  self.data.ipc.send "CODETRACER::load-recent-folder",
    js{ folderPath: cstring(folderPath) }

proc triggerWelcomeStartOption*(self: WelcomeScreenComponent; key: string) =
  case key
  of "open-folder":
    self.data.ipc.send "CODETRACER::open-folder-dialog"
  of "record-new-trace":
    self.showNewRecordView()
  of "open-local-trace":
    self.data.ipc.send "CODETRACER::open-local-trace"
  of "open-online-trace":
    if self.showTraceSharing:
      self.showOnlineTraceView()
  of "codetracer-shell":
    self.loading = true
    self.syncLegacyWelcomeScreenIntoVM()
    self.data.ipc.send "CODETRACER::load-codetracer-shell"
  else:
    discard

proc resetView*(self: WelcomeScreenComponent) =
  self.loading = false
  self.welcomeScreen = false
  self.newRecordScreen = false
  self.openOnlineTrace = false
  if welcomeScreenVMInstance != nil:
    self.syncLegacyWelcomeScreenIntoVM()

method onUploadTraceProgress*(self: WelcomeScreenComponent, uploadProgress: UploadProgress) {.async.} =
  let progressBar = document.getElementById(&"progress-bar-{uploadProgress.id}")
  progressBar.style.backgroundImage = fmt"conic-gradient(#6B6B6B {uploadProgress.progress}% 0%, #2C2C2C {uploadProgress.progress}% 100%)"

  if uploadProgress.progress == 100:
    self.isUploading[uploadProgress.id] = false

proc chooseExecutable(self: WelcomeScreenComponent) =
  self.data.ipc.send "CODETRACER::load-path-for-record", js{ fieldName: cstring("executable") }

proc chooseDir(self: WelcomeScreenComponent, fieldName: cstring) =
  self.data.ipc.send "CODETRACER::choose-dir", js{ fieldName: fieldName }

proc prepareArgs(self: WelcomeScreenComponent): seq[cstring] =
  var args: seq[cstring] = @[]

  if not self.newRecord.defaultOutputFolder:
    args.add(cstring("-o"))
    args.add(self.newRecord.outputFolder)

  args.add(self.newRecord.executable)

  return args.concat(self.newRecord.args)

when defined(js):
  proc buildWelcomeCallbacks(self: WelcomeScreenComponent):
      WelcomeScreenCallbacks =
    WelcomeScreenCallbacks(
      onRecentTraceClick: proc(traceId: string) =
        self.loadRecentTraceFromWelcome(traceId),
      onRecentFolderClick: proc(folderPath: string) =
        self.loadRecentFolderFromWelcome(folderPath),
      onStartOptionClick: proc(key: string) =
        self.triggerWelcomeStartOption(key),
      onChooseExecutable: proc() =
        self.chooseExecutable(),
      onChooseWorkDir: proc() =
        self.chooseDir(cstring("workDir")),
      onChooseOutputFolder: proc() =
        self.chooseDir(cstring("outputFolder")),
      onRecordExecutableChange: proc(path: string) =
        if not self.newRecord.isNil:
          self.newRecord.executable = cstring(path)
          self.data.ipc.send("CODETRACER::path-validation",
            js{
              path: cstring(path),
              fieldName: cstring("executable"),
              required: self.newRecord.formValidator.requiredFields[cstring("executable")]}
          )
        self.syncLegacyWelcomeScreenIntoVM(),
      onRecordArgsChange: proc(args: seq[string]) =
        if not self.newRecord.isNil:
          self.newRecord.args = args.mapIt(cstring(it))
        self.syncLegacyWelcomeScreenIntoVM(),
      onRecordWorkDirChange: proc(path: string) =
        if not self.newRecord.isNil:
          self.newRecord.workDir = cstring(path)
          self.data.ipc.send("CODETRACER::path-validation",
            js{
              path: cstring(path),
              fieldName: cstring("workDir"),
              required: self.newRecord.formValidator.requiredFields[cstring("workDir")]}
          )
        self.syncLegacyWelcomeScreenIntoVM(),
      onRecordOutputFolderChange: proc(path: string) =
        if not self.newRecord.isNil:
          self.newRecord.outputFolder = cstring(path)
          self.newRecord.defaultOutputFolder = path.len == 0
          self.data.ipc.send("CODETRACER::path-validation",
            js{
              path: cstring(path),
              fieldName: cstring("outputFolder"),
              required: self.newRecord.formValidator.requiredFields[cstring("outputFolder")]}
          )
        self.syncLegacyWelcomeScreenIntoVM(),
      onToggleDefaultOutputFolder: proc() =
        if not self.newRecord.isNil:
          self.newRecord.defaultOutputFolder = not self.newRecord.defaultOutputFolder
        self.syncLegacyWelcomeScreenIntoVM(),
      onSubmitNewRecord: proc() =
        if self.newRecord.isNil:
          return
        self.newRecord.status.kind = InProgress
        let workDir = if self.newRecord.workDir.isNil or self.newRecord.workDir.len == 0:
            jsUndefined
          else:
            cast[JsObject](self.newRecord.workDir)
        self.syncLegacyWelcomeScreenIntoVM()
        self.data.ipc.send(
            "CODETRACER::new-record", js{
              args: prepareArgs(self),
              options: js{ cwd: workDir },
              projectOnly: false,
            }
        ),
      onShowWelcome: proc() =
        self.showWelcomeView(),
      onOnlineTraceInputChange: proc(value: string) =
        if self.newDownload.isNil:
          self.newDownload = newDefaultDownloadRecord()
        self.newDownload.args = value.split(" ").filterIt(it.len > 0).mapIt(cstring(it))
        self.syncLegacyWelcomeScreenIntoVM(),
      onSubmitOnlineTrace: proc(value: string) =
        if self.newDownload.isNil:
          self.newDownload = newDefaultDownloadRecord()
        self.newDownload.args = value.split(" ").filterIt(it.len > 0).mapIt(cstring(it))
        self.newDownload.status.kind = InProgress
        self.syncLegacyWelcomeScreenIntoVM()
        self.data.ipc.send(
            "CODETRACER::download-trace-file", js{
              downloadKey: concat(self.newDownload.args),
            }
        ),
    )

  proc tryMountIsoNimWelcomeScreen*() =
    if welcomeScreenVMInstance.isNil:
      return
    let container = isonim_dom.getElementById(isonim_dom.document,
                                              cstring"welcomeScreen")
    if container.isNil:
      return
    isonim_dom.setAttribute(container, cstring"style", cstring"display: block")
    if isoNimWelcomeScreenMounted and
        welcomeScreenMountedComponentRef == welcomeScreenComponentRef:
      return
    container.innerHTML = cstring""
    let callbacks =
      if welcomeScreenComponentRef.isNil:
        WelcomeScreenCallbacks()
      else:
        welcomeScreenComponentRef.buildWelcomeCallbacks()
    mountIsoNimWelcomeScreen(container, welcomeScreenVMInstance, callbacks)
    isoNimWelcomeScreenMounted = true
    welcomeScreenMountedComponentRef = welcomeScreenComponentRef

  proc clearIsoNimWelcomeScreen*() =
    let container = isonim_dom.getElementById(isonim_dom.document,
                                              cstring"welcomeScreen")
    if not container.isNil:
      container.innerHTML = cstring""
      isonim_dom.setAttribute(container, cstring"style", cstring"display: none")
    isoNimWelcomeScreenMounted = false
    welcomeScreenMountedComponentRef = nil

when not defined(js):
  proc tryMountIsoNimWelcomeScreen*() = discard
  proc clearIsoNimWelcomeScreen*() = discard
