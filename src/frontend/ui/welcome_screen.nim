import
  std/[ jsffi, strutils, sequtils ],
  ui_imports,
  ../[ types ]
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types import
  RecentTraceRecord, RecentFolderRecord, WelcomeStartOptionRecord,
  WelcomeScreenMode, wsmWelcome, wsmNewRecord, wsmOnlineTrace, wsmEdit,
  RecordBackendAvailability, RecordBackendChoice, RecordHostPlatform,
  RecordTargetKind,
  rhpLinux, rhpMacos, rhpWindows, rhpOther,
  recordBackendMcr, recordBackendRr, recordBackendTtd,
  recordTargetAuto, recordTargetNative, recordTargetMaterializedLive,
  recordTargetMaterializedReplayOnly
from ../viewmodel/viewmodels/welcome_screen_vm import
  WelcomeScreenVM, NewRecordFormState, createWelcomeScreenVM, setRecentTraces,
  setRecentFolders, setStartOptions, setMode, updateNewRecord,
  syncLoadingState, setRecordBackendAvailability, recordBackendWireName,
  recordBackendChoiceFromWireName,
  setOnlineTraceInput
from ../viewmodel/viewmodels/welcome_screen_vm import optionKey, NO_LOADING_RECORDING
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

proc currentRecordHostPlatform(): RecordHostPlatform =
  when defined(windows):
    rhpWindows
  elif defined(macosx):
    rhpMacos
  elif defined(linux):
    rhpLinux
  else:
    rhpOther

proc parseRecordBackend(value: cstring): RecordBackendChoice =
  recordBackendChoiceFromWireName(safeStr(value))

proc parseRecordTargetKind(value: cstring): RecordTargetKind =
  case safeStr(value)
  of "recordTargetNative": recordTargetNative
  of "recordTargetMaterializedLive": recordTargetMaterializedLive
  of "recordTargetMaterializedReplayOnly": recordTargetMaterializedReplayOnly
  else: recordTargetAuto

proc newDefaultRecordForm(): NewTraceRecord =
  NewTraceRecord(
    defaultOutputFolder: true,
    status: RecordStatus(kind: RecordInit),
    args: @[],
    executable: cstring"",
    languageHint: cstring"",
    targetKind: cstring"recordTargetAuto",
    recordBackend: cstring"mcr",
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
    # M-REC-3: ``Trace.recordingId`` is a UUIDv7 ``langstring``; the VM
    # store uses ``string`` for backend portability, so ``safeStr`` does
    # the cstring → string conversion in the JS backend.
    recordingId: safeStr(trace.recordingId),
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
    welcomeScreenVMInstance.setRecordBackendAvailability(
      RecordBackendAvailability(
        nativeBackendInstalled:
          (not self.data.config.isNil and self.data.config.rrBackend.enabled),
        hostPlatform: currentRecordHostPlatform(),
      ))

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
    (if self.loadingTrace.isNil: NO_LOADING_RECORDING else: safeStr(self.loadingTrace.recordingId)))
  welcomeScreenVMInstance.updateNewRecord(proc(form: var NewRecordFormState) =
    if self.newRecord.isNil:
      form.executable = ""
      form.args = @[]
      form.workDir = ""
      form.outputFolder = ""
      form.defaultOutputFolder = true
      form.languageHint = ""
      form.targetKind = recordTargetAuto
      form.backendChoice = recordBackendMcr
    else:
      form.executable = safeStr(self.newRecord.executable)
      form.args = toStrings(self.newRecord.args)
      form.workDir = safeStr(self.newRecord.workDir)
      form.outputFolder = safeStr(self.newRecord.outputFolder)
      form.defaultOutputFolder = self.newRecord.defaultOutputFolder
      form.languageHint = safeStr(self.newRecord.languageHint)
      form.targetKind = parseRecordTargetKind(self.newRecord.targetKind)
      form.backendChoice = parseRecordBackend(self.newRecord.recordBackend)
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

proc loadRecentTraceFromWelcome*(self: WelcomeScreenComponent; recordingId: cstring) =
  ## M-REC-3: ``recordingId`` is a UUIDv7 recording-id string.  The IPC
  ## payload field name ``traceId`` is preserved here as the wire format
  ## is owned by M-REC-5.
  self.loading = true
  self.loadingTrace = nil
  for trace in self.data.recentTraces:
    if trace.recordingId == recordingId:
      self.loadingTrace = trace
      break
  self.syncLegacyWelcomeScreenIntoVM()
  self.data.ipc.send "CODETRACER::load-recent-trace", js{ traceId: recordingId }

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
      onRecentTraceClick: proc(recordingId: string) =
        # M-REC-3: VM callbacks pass ``string`` recording-ids; the legacy
        # WelcomeScreenComponent IPC hop expects ``cstring``, so we
        # convert at the boundary.
        self.loadRecentTraceFromWelcome(cstring(recordingId)),
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
      onRecordBackendChange: proc(backend: RecordBackendChoice) =
        if not self.newRecord.isNil:
          self.newRecord.recordBackend =
            cstring(recordBackendWireName(backend))
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
              filename: self.newRecord.executable,
              args: prepareArgs(self),
              options: js{ cwd: workDir },
              projectOnly: false,
              recordBackend: self.newRecord.recordBackend,
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

  proc mountWebWelcomeScreen*(): bool =
    ## The web build's first rendered surface, and the reason it needs its own
    ## entry rather than reusing `syncLegacyWelcomeScreenIntoVM`.
    ##
    ## ## What was wrong
    ##
    ## Every other path into this panel is driven by a HOST. The desktop's
    ## `onWelcomeScreen` handler runs on `CODETRACER::welcome-screen`, which the
    ## Electron main process sends; it fills `data.recentTraces`,
    ## `data.config` and the rest out of the user's home directory, and only
    ## then does `syncLegacyWelcomeScreenIntoVM` push those into the ViewModel.
    ##
    ## A statically hosted tab has no such process and never will — that is the
    ## point of the deployment. So on the web that event never arrives, nothing
    ## calls `tryMountIsoNimWelcomeScreen`, and the renderer sits fully loaded
    ## with an empty document. `ui.js` was DELIVERED and never STARTED.
    ##
    ## ## Why this does not synthesise the host's message instead
    ##
    ## The obvious alternative is to fabricate a `CODETRACER::welcome-screen`
    ## payload and feed it to the existing handler, so the web takes a code path
    ## the desktop already exercises. It was rejected after reading what that
    ## handler does: it assigns `data.config`, and `configureShortcuts()` then
    ## indexes `config.shortcutMap.actionShortcuts[action]` for every
    ## `ClientAction`. A fabricated config has an empty map, so the fabrication
    ## has to be a COMPLETE one — a second, hand-written copy of
    ## `default_config.yaml` living in the renderer, drifting from the real one,
    ## and read by nothing that would notice. That is the third-copy shape
    ## `web_deployment.nim`'s own header refuses for the asset list.
    ##
    ## This mounts the panel through the ViewModel directly, which is the same
    ## thing `storybook_components.mountWelcome` does and for the same reason:
    ## `ensureWelcomeScreenVm` already builds the store over a STUB backend that
    ## resolves every command with `{}`. The panel has never needed a host; only
    ## the legacy component wrapper did.
    ##
    ## ## What it deliberately does not claim
    ##
    ## This is a mounted welcome screen, not NS9 — and the distinction is now
    ## a ROUTE rather than a milestone boundary. NS9 asks that "the first
    ## screen is CodeTracer in Edit mode on a working multi-file project —
    ## Filesystem, Editor, Test Results, Constraints — not a landing page",
    ## and that is what `/noir` opens: `ui/web_entry_surface.
    ## enterTemplateEditMode` delivers `CODETRACER::no-trace` and all four
    ## panes mount. This surface is what a LANGUAGE-NEUTRAL root opens, where
    ## rule 0 says there is no right template to pick, so a welcome screen is
    ## the correct answer rather than a lesser one.
    ##
    ## Returns whether it mounted, so the caller can say so rather than assume.
    ensureWelcomeScreenVm()
    if welcomeScreenVMInstance.isNil:
      return false

    # No host, so no recents: an empty list is the TRUE answer here, not a
    # placeholder. `setRecentTraces` is still called rather than left unset —
    # an unset signal and an empty one render differently, and the second is
    # what a first visit actually is.
    welcomeScreenVMInstance.setRecentTraces(@[])
    welcomeScreenVMInstance.setRecentFolders(@[])

    # The start options a TAB can honour. `inactive` is the panel's own word
    # for "shown and refused", and it is used here rather than dropping the
    # rows: a user who cannot find "Record new trace" concludes the product is
    # broken, and one who sees it greyed out learns what this surface is.
    #
    # Only "Open folder" is live, and it is live because NS2's project store
    # (OPFS) is what this same program already booted — the same capability the boot
    # line reports as `platform=pkWeb`.
    welcomeScreenVMInstance.setStartOptions(@[
      WelcomeStartOptionRecord(
        key: optionKey("Open folder"), name: "Open folder", inactive: false),
      WelcomeStartOptionRecord(
        key: optionKey("Record new trace"), name: "Record new trace",
        inactive: true),
      WelcomeStartOptionRecord(
        key: optionKey("Open local trace"), name: "Open local trace",
        inactive: true),
      WelcomeStartOptionRecord(
        key: optionKey("Open online trace"), name: "Open online trace",
        inactive: true),
      WelcomeStartOptionRecord(
        key: optionKey("CodeTracer shell"), name: "CodeTracer shell",
        inactive: true),
    ])
    welcomeScreenVMInstance.setMode(wsmWelcome)

    tryMountIsoNimWelcomeScreen()
    isoNimWelcomeScreenMounted

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
