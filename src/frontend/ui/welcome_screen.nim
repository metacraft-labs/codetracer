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
  setRecentFolders, setStartOptions, setStartOptionsNote, setMode,
  updateNewRecord,
  syncLoadingState, setRecordBackendAvailability, recordBackendWireName,
  recordBackendChoiceFromWireName,
  # Issue #734: both arms' start-option strips come from these two builders
  # now. See the comment on `welcomeStartOptions` below.
  desktopWelcomeStartOptions, webWelcomeStartOptions, WebStartOptionsNote,
  # The host seam's payloads. `installWelcomeVMCallbacks` fills the four
  # `on*` fields these describe; without them the welcome screen's
  # main-process flows have no transport at all.
  LaunchConfigRequest, NewRecordRequest,
  setOnlineTraceInput
# `optionKey` used to be imported here too, to spell out ten start-option keys
# by hand. Both strips now come from `desktopWelcomeStartOptions` /
# `webWelcomeStartOptions`, which derive the key from the name themselves.
from ../viewmodel/viewmodels/welcome_screen_vm import NO_LOADING_RECORDING
when defined(js):
  from isonim/web/dom_api as isonim_dom import nil
  from ../viewmodel/views/isonim_welcome_screen_view import
    mountIsoNimWelcomeScreen, WelcomeScreenCallbacks

var welcomeScreenVMInstance*: WelcomeScreenVM
var welcomeScreenVMStore: ReplayDataStore
var welcomeScreenComponentRef: WelcomeScreenComponent
var welcomeScreenMountedComponentRef: WelcomeScreenComponent
var isoNimWelcomeScreenMounted = false

var webStartOptionHandler: proc(key: string)
  ## ISSUE #735 — THE WEB ARM'S START-OPTION DISPATCH, and the reason it is a
  ## registered hook rather than a direct call.
  ##
  ## `tryMountIsoNimWelcomeScreen` used to hand the view an EMPTY
  ## `WelcomeScreenCallbacks()` whenever there was no legacy component, which
  ## on the web is always; the view then fell through to its own `case`, which
  ## has arms for two keys it can serve from the VM alone. M52 recorded that as
  ## half of #734's dead click, and the half a `WebHandledStartOptions = {}`
  ## made harmless rather than fixed. With a live option on this arm it has to
  ## be fixed: the record says the option is performable, so something must
  ## perform it.
  ##
  ## A hook, because the thing that performs it is `ui/web_entry_surface`, and
  ## this module must not reach into it — `web_entry_surface` is the surface
  ## that mounts panes and it already imports the project store, the replay host
  ## and the pane hosts. `ui_js.startWebArm` is the one place that holds both
  ## modules, which is exactly where `installNoirBuildCommands` is wired for the
  ## template arm, and the same place wires this for the welcome arm.

proc setWebWelcomeStartOptionHandler*(handler: proc(key: string)) =
  ## Install (before mounting) the proc that performs a web start-option click.
  ##
  ## Must be called BEFORE `mountWebWelcomeScreen`: the callbacks record is
  ## built once per mount and `tryMountIsoNimWelcomeScreen` returns early when
  ## the screen is already mounted for the same component, so a handler
  ## installed afterwards would not reach the view until something forced a
  ## remount.
  webStartOptionHandler = handler

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
  ## The desktop arm's strip, built by the shared VM-layer builder rather than
  ## by five record literals here.
  ##
  ## The literals were the shape issue #734 exploited: nothing tied a row's
  ## `inactive` flag to whether `triggerWelcomeStartOption` below can actually
  ## perform it, so the WEB copy of the same five literals shipped an active
  ## "Open folder" that reached `discard`. `desktopWelcomeStartOptions`
  ## derives the active set from `DesktopHandledStartOptions` by SUBTRACTION,
  ## so no record here can be live and unhandled at once.
  ##
  ## One obligation is left to a human, and it is worth knowing which:
  ## `DesktopHandledStartOptions` is a hand-maintained mirror of
  ## `triggerWelcomeStartOption`'s `case` below. Nothing relates the two —
  ## the VM suite that checks this invariant never imports this module, so
  ## deleting an arm from that `case` without shrinking the set would NOT
  ## redden anything. **Delete an arm, shrink the set in the same edit.**
  desktopWelcomeStartOptions(self.showTraceSharing)

proc currentWelcomeMode(self: WelcomeScreenComponent): WelcomeScreenMode =
  if self.newRecordScreen:
    wsmNewRecord
  elif self.openOnlineTrace:
    wsmOnlineTrace
  elif not self.welcomeScreen and not self.data.isNil and self.data.ui.mode == EditMode:
    wsmEdit
  else:
    wsmWelcome

# Defined below, once the IPC helpers it closes over are in scope. Declared
# here because `syncLegacyWelcomeScreenIntoVM` is the one place that has both
# a live component and a live VM, and so is where the seam gets installed.
proc installWelcomeVMCallbacks*(self: WelcomeScreenComponent)

proc syncLegacyWelcomeScreenIntoVM*(self: WelcomeScreenComponent) =
  if self.isNil:
    return
  ensureWelcomeScreenVm()
  welcomeScreenComponentRef = self
  self.installWelcomeVMCallbacks()
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
  # The desktop needs no standing note: at least three of the five options are
  # live here, so the strip is not a wall of refusals, and each refusal that
  # IS present carries its own `disabledReason`. Set explicitly rather than
  # left alone so a VM that previously rendered the web arm (storybook, a
  # test) cannot leak the web note onto a desktop screen.
  welcomeScreenVMInstance.setStartOptionsNote("")
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
  ## THE DESKTOP ARM'S DISPATCH, and the `case` that
  ## `DesktopHandledStartOptions` mirrors. An arm added here must be added
  ## there in the same edit, and an arm deleted here must be deleted there —
  ## nothing relates the two (see `welcomeStartOptions` above).
  case key
  of "new-file":
    # ISSUE #735. Through the main process rather than straight into
    # `renderer.openNewTab`, and the reason is that the welcome screen has NO
    # LAYOUT: `ui/layout.initLayout` returns before GoldenLayout is constructed
    # while `startOptions.welcomeScreen` is true and `data.trace` is nil, so a
    # tab opened from here would have no container to go in. `CODETRACER::new-file`
    # is answered by `index/traces.onNewFile`, which sends `CODETRACER::no-trace`
    # with an EMPTY project — the same message "Open folder" ends up sending,
    # so edit mode is entered by one door rather than two — and `ui_js.onNoTrace`
    # opens the untitled buffer once the layout is on the ground.
    self.data.ipc.send "CODETRACER::new-file"
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

when not defined(js):
  # The seam's four flows are all Electron main-process IPC, which does not
  # exist on the native target. The VM's callbacks simply stay nil there, and
  # `loadRecentTrace` and friends become the explicit no-op their doc comments
  # promise rather than a command nothing answers.
  proc installWelcomeVMCallbacks*(self: WelcomeScreenComponent) = discard

when defined(js):
  proc installWelcomeVMCallbacks*(self: WelcomeScreenComponent) =
    ## Install the host seam on `WelcomeScreenVM`.
    ##
    ## The four flows below are Electron main-process concerns, and the VM used
    ## to reach for them by sending `ct/load-recent-trace`,
    ## `ct/load-recent-folder`, `ct/launch-config` and `ct/new-record` through
    ## `store.backend`. No engine implements any of those four
    ## (`backend/dap_dialect.md` §7), and this VM's backend is the stub in
    ## `ensureWelcomeScreenVm` that resolves `%*{}` for everything — so in
    ## production those sends reached nothing while the mock-backend tests
    ## stayed green. Same failure as `ErrorsVM`'s `ct/jump-location`, same fix:
    ## the host owns the IPC, the VM owns the decision.
    ##
    ## The closures here are the ones `buildWelcomeCallbacks` already installs
    ## on the VIEW's callbacks record. That record stays as it is — the view
    ## prefers it and falls back to the VM — so both paths now reach the same
    ## main-process handlers instead of one of them reaching a stub.
    if self.isNil or welcomeScreenVMInstance.isNil:
      return

    welcomeScreenVMInstance.onLoadRecentTrace = proc(recordingId: string) =
      # M-REC-3: VM callbacks pass `string` recording-ids; the legacy IPC hop
      # expects `cstring`, so we convert at the boundary.
      self.loadRecentTraceFromWelcome(cstring(recordingId))

    welcomeScreenVMInstance.onLoadRecentFolder = proc(folderPath: string) =
      self.loadRecentFolderFromWelcome(folderPath)

    welcomeScreenVMInstance.onLaunchConfig = proc(request: LaunchConfigRequest) =
      # The one genuine impedance mismatch in this change. Everything on the
      # VM side is keyed by `slug`; `CODETRACER::record-with-launch-config` is
      # keyed by an index into `getLaunchConfigsForWorkspace`
      # (`index/traces.nim:1034`, which rejects out-of-range). `configIndex` is
      # the entry's position in the list the host itself installed via
      # `setLaunchConfigs`, so the two agree as long as that list is installed
      # in main-process order — which is what `CODETRACER::launch-configs-loaded`
      # delivers, `index` field and all.
      self.data.ipc.send("CODETRACER::record-with-launch-config",
        js{ configIndex: request.configIndex })

    welcomeScreenVMInstance.onSubmitNewRecord = proc(request: NewRecordRequest) =
      # `request` carries the VM's decision (target kind, record backend,
      # session mode); the payload itself is still built from the legacy form
      # state, which is what `prepareArgs` reads and what the main process has
      # always been sent.
      if self.newRecord.isNil:
        return
      self.newRecord.status.kind = InProgress
      let workDir =
        if self.newRecord.workDir.isNil or self.newRecord.workDir.len == 0:
          jsUndefined
        else:
          cast[JsObject](self.newRecord.workDir)
      self.data.ipc.send(
        "CODETRACER::new-record", js{
          filename: self.newRecord.executable,
          args: prepareArgs(self),
          options: js{ cwd: workDir },
          projectOnly: false,
          recordBackend: cstring(request.recordBackend),
        }
      )

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
    # broken, and one who sees it greyed out WITH A REASON learns what this
    # surface is.
    #
    # ISSUE #734. The "WITH A REASON" is new, and so is the fifth row's
    # honesty. This list used to claim "Open folder" was live — the comment
    # here said so too, reasoning from NS2's OPFS project store — and it was
    # not: `tryMountIsoNimWelcomeScreen` below hands the view an EMPTY
    # `WelcomeScreenCallbacks()` on this arm because there is no legacy
    # component to build one from, the view's `case` fallback has no
    # `open-folder` arm, and the desktop implementation is an Electron IPC
    # message no browser tab answers. The click reached nothing.
    #
    # What "Open folder" should MEAN over OPFS is a product decision no spec
    # has taken (grep `Noir-Studio.milestones.org`,
    # `Browser-Based-Replaying.md` and `Unified-Browser-Replay-Architecture.md`
    # for `showDirectoryPicker` — nothing), and `Noir-Studio.md` §4.1 is clear
    # that OPFS is "a working copy, not durable storage the user owns", so the
    # web meaning is not the desktop meaning. Until that spec exists the
    # honest state is refused-and-explained, which is what
    # `webWelcomeStartOptions` produces for that row and four others.
    #
    # ISSUE #735 made the SIXTH row live, and it is the only one: "New file"
    # needs no folder, no file on disk, no recorder and no main process, so it
    # is the one start option this surface can actually perform. The screen is
    # therefore no longer a wall of refusals — see
    # `GUI/Welcome-And-Sessions/Welcome-Screen.md` §Start Options.
    welcomeScreenVMInstance.setStartOptions(webWelcomeStartOptions())
    welcomeScreenVMInstance.setStartOptionsNote(WebStartOptionsNote)
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
      if not welcomeScreenComponentRef.isNil:
        welcomeScreenComponentRef.buildWelcomeCallbacks()
      elif webStartOptionHandler != nil:
        # ISSUE #735. The web arm has no legacy component to build a full
        # callbacks record from, and needs exactly one field: the start-option
        # dispatch. Every other callback stays nil, so the view's own fallbacks
        # (`vm.loadRecentTrace`, `vm.showWelcome`, …) keep serving the rows this
        # arm does render — there are none, the recents lists are empty here —
        # and nothing else changes shape.
        WelcomeScreenCallbacks(
          onStartOptionClick: proc(key: string) = webStartOptionHandler(key))
      else:
        WelcomeScreenCallbacks()
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
