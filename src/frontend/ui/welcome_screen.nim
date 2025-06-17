import
  ../ui_helpers,
  ../../ct/version,
  ui_imports, ../types
import std/options
import std/jsffi
import std/enumerate
import std/times except now

const PROGRAM_NAME_LIMIT = 45
const NO_EXPIRE_TIME = -1
const EMPTY_STRING = ""
const ERROR_DOWNLOAD_KEY = "Errored"

proc uploadTrace(self: WelcomeScreenComponent, trace: Trace) {.async.} =
  var uploadedData = await self.data.asyncSend(
    "upload-trace-file",
    UploadTraceArg(
      trace: trace,
      programName: trace.program
    ),
    &"{trace.program}:{trace.id}", UploadedTraceData
  )

  if uploadedData.downloadKey != "Errored":
    trace.downloadKey = uploadedData.downloadKey
    trace.controlId = uploadedData.controlId
    trace.onlineExpireTime = ($uploadedData.expireTime).parseInt()
    self.isUploading[trace.id] = false
  else:
    trace.downloadKey = uploadedData.downloadKey
    self.errorMessageActive[trace.id] = UploadError
    self.isUploading[trace.id] = false

  self.data.redraw()

method onUploadTraceProgress*(self: WelcomeScreenComponent, uploadProgress: UploadProgress) {.async.} =
  let progressBar = document.getElementById(&"progress-bar-{uploadProgress.id}")
  progressBar.style.backgroundImage = fmt"conic-gradient(#6B6B6B {uploadProgress.progress}% 0%, #2C2C2C {uploadProgress.progress}% 100%)"

  if uploadProgress.progress == 100:
    self.isUploading[uploadProgress.id] = false

proc deleteUploadedTrace(self: WelcomeScreenComponent, trace: Trace) {.async.} =
  var deleted = await self.data.asyncSend(
    "delete-online-trace-file",
    DeleteTraceArg(
      traceId: trace.id,
      controlId: trace.controlId
    ),
    &"{trace.id}:{trace.controlId}", bool
  )

  if deleted:
    trace.controlId = EMPTY_STRING
    trace.downloadKey = EMPTY_STRING
    trace.onlineExpireTime = NO_EXPIRE_TIME
  else:
    self.errorMessageActive[trace.id] = DeleteError

  self.data.redraw()

proc recentTransactionView(self: WelcomeScreenComponent, tx: StylusTransaction, position: int): VNode =
  let successId = if tx.isSuccessful: "tx-success" else: "tx-unsuccess"
  buildHtml(
    tdiv(class = "recent-transactions-container")
  ):
    tdiv(class = "recent-transaction"):
      span(): text tx.txHash
      span(id = successId): text if tx.isSuccessful: "Successful" else: "Not"
      span(): text tx.fromAddress
      span(): text tx.toAddress
      span(): text tx.time
      tdiv(
        class = "action-transaction-button",
        onclick = proc() =
          self.loading = true
          # self.loadingTrace = tx TODO: Add maybe the transaction to trace converted
          self.data.ipc.send "CODETRACER::load-recent-transaction", js{ txHash: tx.txHash }
      )

proc recentProjectView(self: WelcomeScreenComponent, trace: Trace, position: int): VNode =
  let featureFlag = data.config.traceSharingEnabled
  let tooltipTopPosition = (position + 1) * 36 - self.recentTracesScroll
  let activeClass = if self.copyMessageActive.hasKey(trace.id) and self.copyMessageActive[trace.id]: "welcome-path-active" else: ""
  let infoActive = if self.infoMessageActive.hasKey(trace.id) and self.infoMessageActive[trace.id]: "welcome-path-active" else: ""
  let uploadErrorClass = if self.errorMessageActive.hasKey(trace.id) and self.errorMessageActive[trace.id] == UploadError: "welcome-path-active" else: ""
  let deleteErrorClass = if self.errorMessageActive.hasKey(trace.id) and self.errorMessageActive[trace.id] == DeleteError: "welcome-path-active" else: ""
  if self.errorMessageActive.hasKey(trace.id) and self.errorMessageActive[trace.id] in @[UploadError, DeleteError]:
    discard setTimeout(proc() =
      self.errorMessageActive[trace.id] = ResetMessage
      if self.errorMessageActive[trace.id] == UploadError:
        trace.downloadKey = ""
      self.data.redraw(),
      2000
    )

  let currentTime = cast[int](getTime().toJs.seconds)
  let threeDays = cast[int]((3.days).toJs.seconds)
  let remainingTime = if trace.onlineExpireTime != NO_EXPIRE_TIME: trace.onlineExpireTime - currentTime else: 0
  var (expireState, expireId) =
    if trace.onlineExpireTime == NO_EXPIRE_TIME:
      (NoExpireState, "trace-info-button")
    elif remainingTime > threeDays:
      (NotExpiringSoon, "trace-info-button")
    elif remainingTime < 0:
      (Expired, "trace-info-button-active")
    else:
      (ThreeDaysLeft, "trace-info-button-active")

  buildHtml(
    tdiv(class = "recent-trace-container")
  ):
    tdiv(
      class = "recent-trace",
      onclick = proc (ev: Event, tg: VNode) =
        self.loading = true
        self.loadingTrace = trace
        ev.target.focus()
        data.redraw()
        self.data.ipc.send "CODETRACER::load-recent-trace", js{ traceId: trace.id }
    ):
      let programLimitName = PROGRAM_NAME_LIMIT
      let limitedProgramName = if trace.program.len > programLimitName:
          ".." & ($trace.program)[^programLimitName..^1]
        else:
          $trace.program

      tdiv(class = "recent-trace-title"):
        span(class = "recent-trace-title-id"):
          text fmt"ID: {trace.id}"
        separateBar()
        span(class = "recent-trace-title-content"):
          text limitedProgramName # TODO: tippy
    if featureFlag:
      tdiv(class = "online-functionality-buttons"):
        if self.isUploading[trace.id]:
          tdiv(class = "recent-trace-buttons", id = "progress-bar"):
            tdiv(
              class = "recent-trace-buttons-image progress-circle",
              id = &"progress-bar-{trace.id}"
            )
            tdiv(
              class = "recent-trace-buttons-image inner-circle",
            )
        elif (trace.downloadKey == "" and trace.onlineExpireTime == NO_EXPIRE_TIME) or
            expireState == ExpireTraceState.Expired or
            trace.downloadKey == ERROR_DOWNLOAD_KEY:
          tdiv(class = "recent-trace-buttons", id = "upload-button"):
            tdiv(
              class = "recent-trace-buttons-image",
              id = "trace-upload-button",
              onclick = proc(ev: Event, tg: VNode) =
                ev.stopPropagation()
                ev.target.focus()
                discard self.uploadTrace(trace)
                self.isUploading[trace.id] = true
            ):
              tdiv(class = fmt"custom-tooltip {uploadErrorClass}", id = &"tooltip-{trace.id}",
                style = style(StyleAttr.top, &"{tooltipTopPosition}px")
              ):
                text "Server error!"
        if trace.controlId != EMPTY_STRING and expireState != Expired:
          tdiv(class = "recent-trace-buttons", id = "delete-button"):
            tdiv(
              class = "recent-trace-buttons-image",
              id = "trace-delete-button",
              onclick = proc(ev: Event, tg: VNode) =
                ev.stopPropagation()
                ev.target.focus()
                discard self.deleteUploadedTrace(trace)
              ):
              tdiv(class = fmt"custom-tooltip {deleteErrorClass}", id = &"tooltip-{trace.id}",
                style = style(StyleAttr.top, &"{tooltipTopPosition}px")
              ):
                text "Server error when deleting"
        if trace.downloadKey != EMPTY_STRING and expireState != Expired and trace.downloadKey != ERROR_DOWNLOAD_KEY:
          tdiv(class = "recent-trace-buttons"):
            tdiv(
              class = "recent-trace-buttons-image",
              id = "trace-copy-button",
              onclick = proc(ev: Event, tg: VNode) =
                ev.stopPropagation()
                clipboardCopy(trace.downloadKey)
                self.copyMessageActive[trace.id] = true
                ev.target.focus()
                self.data.redraw()
                discard setTimeout(proc() =
                  self.copyMessageActive[trace.id] = false
                  self.data.redraw(),
                  2000
                )
            ):
              tdiv(class = fmt"custom-tooltip {activeClass}", id = &"tooltip-{trace.id}",
                style = style(StyleAttr.top, &"{tooltipTopPosition}px")
              ):
                text "Download key copied to clipboard"
        if expireState != NoExpireState or expireState in @[Expired, ThreeDaysLeft]:
          let dt = fromUnix(trace.onlineExpireTime)
          let time = dt.format("dd MM yyyy")
          let formatted = time.replace(" ", ".")
          tdiv(class = &"recent-trace-buttons {expireId}"):
            tdiv(
              class = "recent-trace-buttons-image",
              id = &"{expireId}",
              onclick = proc(ev: Event, tg: VNode) =
                ev.stopPropagation()
                clipboardCopy(trace.downloadKey)
                self.infoMessageActive[trace.id] = if self.infoMessageActive.hasKey(trace.id): not self.infoMessageActive[trace.id] else: true
                if self.copyMessageActive.hasKey(trace.id) and self.copyMessageActive[trace.id]:
                  self.copyMessageActive[trace.id] = false
                ev.target.parentNode.focus()
                self.data.redraw(),
              onmouseleave = proc(ev: Event, tg: VNode) =
                self.infoMessageActive[trace.id] = false
            ):
              tdiv(class = fmt"custom-tooltip {infoActive}", id = &"tooltip-{trace.id}",
                style = style(StyleAttr.top, &"{tooltipTopPosition}px")
              ):
                case expireState:
                of ThreeDaysLeft:
                  text &"The key will expire on {formatted}"
                of Expired:
                  text "The key has expired"
                else:
                  text &"The online share key expires on {formatted}"

proc recentProjectsView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "recent-traces")
  ):
    tdiv(class = "recent-traces-title"):
      text "RECENT TRACES"
    tdiv(
      class = "recent-traces-list",
      onscroll = proc(ev: Event, tg: VNode) =
        self.recentTracesScroll = cast[int](ev.target.scrollTop)
    ):
      if self.data.recentTraces.len > 0:
        for (i, trace) in enumerate(self.data.recentTraces):
          recentProjectView(self, trace, i)
      else:
        tdiv(class = "no-recent-traces"):
          text "No traces yet."

proc recentTransactionsView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "recent-transactions")
  ):
    tdiv(class = "recent-transaction-title"):
      text "Stylus Transaction explorer"
    tdiv(class = "table-column-names"):
      span(id = "tx-hash"): text "TX Hash"
      span(id = "tx-status"): text "Status"
      span(id = "tx-from"): text "From"
      span(id = "tx-to"): text "To"
      span(id = "tx-when"): text "When"
      span(id = "tx-action"): text "Action"
    tdiv(
      class = "recent-traces-list",
      onscroll = proc(ev: Event, tg: VNode) =
        self.recentTracesScroll = cast[int](ev.target.scrollTop)
    ):
      if self.data.stylusTransactions.len > 0:
        for (i, trace) in enumerate(self.data.stylusTransactions):
          recentTransactionView(self, trace, i)
          echo "#### CHECK THE TRACE HJHERE!"
          kout trace.txHash

      else:
        tdiv(class = "no-recent-traces"):
          text "No transactions yet."

proc renderOption(self: WelcomeScreenComponent, option: WelcomeScreenOption): VNode =
  let optionClass = toLowerAscii($(option.name)).split().join("-")
  let inactiveClass = if not option.inactive: "" else: "inactive-start-option"
  var containerClass = &"start-option {optionClass} {inactiveClass}"
  var iconClass = &"start-option-icon {optionClass}-icon"
  var nameClass = "start-option-name"

  if option.hovered:
    containerClass = containerClass & " hovered"
    iconClass = iconClass & " hovered"
    nameClass = nameClass & " hovered"

  buildHtml(
    tdiv(
      class = containerClass,
      onmousedown = proc(ev: Event, tg: VNode) =
        ev.preventDefault(),
      onmouseup = proc(ev: Event, tg: VNode) =
        ev.preventDefault()
        option.hovered = false,
      onclick = proc(ev: Event, tg: VNode) =
        ev.preventDefault()
        option.command(),
      onmouseover = proc = option.hovered = true,
      onmouseleave = proc = option.hovered = false
    )
  ):
    tdiv(class = nameClass):
      text &"{option.name}"

proc renderStartOptions(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "start-options")
  ):
    for option in self.options:
      renderOption(self, option)

template customCheckbox*(obj: untyped, name: string) = discard

proc renderFormCheckboxRow(
  parameterName: cstring,
  label: cstring,
  condition: bool,
  handler: proc,
  disabled: bool = true
): VNode =
  buildHtml(
    tdiv(class = "new-record-form-row")
  ):
    tdiv(class = "new-record-input-row"):
      input(
        name = parameterName,
        `type` = "checkbox",
        class = "checkbox",
        checked = toChecked(condition),
        value = parameterName
      )
      span(
        class = "checkmark",
        onclick = proc =
          handler()
      )
      label(`for` = parameterName):
        text &"{label}"

proc renderInputRow(
  parameterName: cstring,
  label: cstring,
  buttonText: cstring,
  buttonHandler: proc(ev: Event, tg: VNode),
  inputHandler: proc(ev: Event, tg: Vnode),
  enterHandler: proc(ev: KeyboardEvent, tg: VNode) = nil,
  inputText: cstring = "",
  validationMessage: cstring = "",
  disabled: bool = false,
  hasButton: bool = true,
  validInput: bool = true
): VNode =
  var class: cstring = ""

  if disabled: class = class & "disabled"
  if not validInput: class = class & " invalid"

  buildHtml(
    tdiv(class = "new-record-form-row")
  ):
    tdiv(class = "new-record-input-row"):
      input(
        `type` = "text",
        id = inputText,
        class = class,
        name = parameterName,
        value = inputText,
        onchange = inputHandler,
        onkeydown = enterHandler,
        placeholder = &"{label}"
      )
      if hasButton:
        button(
          class = class,
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            buttonHandler(ev,tg)
        ): text(buttonText)

proc chooseExecutable(self: WelcomeScreenComponent) =
  self.data.ipc.send "CODETRACER::load-path-for-record", js{ fieldName: cstring("executable") }

proc chooseDir(self: WelcomeScreenComponent, fieldName: cstring) =
  self.data.ipc.send "CODETRACER::choose-dir", js{ fieldName: fieldName }

proc renderRecordResult(self: WelcomeScreenComponent, status: RecordStatus, isDownload: bool = false): VNode =
  var containerClass = "new-record-result"
  var iconClass = "new-record-status-icon"
  let name = if isDownload: "Download" else: "Record"
  case status.kind:
  of RecordInit:
    containerClass = containerClass & " empty"
    iconClass = iconClass & " empty"

  of RecordError:
    containerClass = containerClass & " failed"
    iconClass = iconClass & " failed"

  of RecordSuccess:
    containerClass = containerClass & " success"
    iconClass = iconClass & " success"

  of InProgress:
    containerClass = containerClass & " in-progress"
    iconClass = iconClass & " in-progress"

  buildHtml(
    tdiv(class = fmt"new-record-result-wrapper {iconClass}")
  ):
    tdiv(class = containerClass):
      tdiv(class = iconClass)
      tdiv(class = &"new-record-{status.kind}-message"):
        case status.kind:
        of InProgress:
          text &"{name}ing..."

        of RecordError:
          text &"{name} failed. Error: {status.errorMessage}"

        of RecordSuccess:
          text &"{name} successful! Opening..."

        else:
          discard

proc prepareArgs(self: WelcomeScreenComponent): seq[cstring] =
  var args: seq[cstring] = @[]
  var outputDir = ""

  if not self.newRecord.defaultOutputFolder:
    args.add(cstring("-o"))
    args.add(self.newRecord.outputFolder)

  args.add(self.newRecord.executable)

  return args.concat(self.newRecord.args)

proc onlineFormView(self: WelcomeScreenComponent): VNode =
  proc handler(ev: Event, tg: VNode) =
    ev.preventDefault()
    self.newDownload.status.kind = InProgress
    self.data.ipc.send(
        "CODETRACER::download-trace-file", js{
          downloadKey: concat(self.newDownload.args),
        }
    )

  buildHtml(
    tdiv(class = "new-record-form new-online-trace-form")
  ):
    renderInputRow(
      "args",
      "Download ID with password",
      "",
      proc(ev: Event, tg: VNode) = discard,
      proc(ev: Event, tg: VNode) =
        self.newDownload.args = ev.target.value.split(" "),
      proc(e: KeyboardEvent, tg: VNode) =
        if e.keyCode == ENTER_KEY_CODE:
          self.newDownload.args = e.target.value.split(" ")
          handler(cast[Event](e), tg),
      hasButton = false,
      inputText = self.newDownload.args.join(j" ")
    )
    renderRecordResult(self, self.newDownload.status, true)
    tdiv(class = "new-record-form-row"):
      button(
        class = "cancel-button",
        onclick = proc(ev: Event, tg: VNode) =
          ev.preventDefault()
          self.welcomeScreen = true
          self.openOnlineTrace = false
          self.newDownload = nil
      ):
        text "Back"
      button(
        class = "confirmation-button",
        onclick = handler
      ):
        text "Download"

proc newRecordFormView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "new-record-form")
  ):
    # TODO: two separate dialogs for executable and project folder?
    # read https://www.electronjs.org/docs/latest/api/dialog , Note: On Windows and Linux..
    # (it seems an open dialog can't select both files and directories there)
    renderInputRow(
      "executable",
      "Local project path",
      "Choose",
      proc(ev: Event, tg: VNode) = chooseExecutable(self),
      proc(ev: Event, tg: VNode) =
        self.newRecord.executable = ev.target.value
        self.data.ipc.send("CODETRACER::path-validation",
          js{
            path: ev.target.value,
            fieldName: cstring("executable"),
            required: self.newRecord.formValidator.requiredFields[cstring("executable")]}),
      inputText = self.newRecord.executable,
      validationMessage = self.newRecord.formValidator.invalidExecutableMessage,
      validInput = self.newRecord.formValidator.validExecutable
    )
    renderInputRow(
      "args",
      "Command line arguments",
      "",
      proc(ev: Event, tg: VNode) = discard,
      proc(ev: Event, tg: VNode) = self.newRecord.args = ev.target.value.split(" "),
      hasButton = false,
      inputText = self.newRecord.args.join(j" ")
    )
    renderInputRow(
      "workDir",
      "Working directory",
      "Choose",
      proc(ev: Event, tg: VNode) = chooseDir(self, cstring("workDir")),
      proc(ev: Event, tg: VNode) =
        self.newRecord.workDir = ev.target.value
        self.data.ipc.send("CODETRACER::path-validation",
          js{
            path: ev.target.value,
            fieldName: cstring("workDir"),
            required: self.newRecord.formValidator.requiredFields[cstring("workDir")]}),
      inputText = self.newRecord.workDir,
      validationMessage = self.newRecord.formValidator.invalidWorkDirMessage,
      validInput = self.newRecord.formValidator.validWorkDir
    )
    renderFormCheckboxRow(
      "defaultOutputFolder",
      "Use default output folder",
      self.newRecord.defaultOutputFolder,
      proc = (self.newRecord.defaultOutputFolder = not self.newRecord.defaultOutputFolder)
    )
    renderInputRow(
      "outputFolder",
      "Output folder",
      "Choose",
      proc(ev: Event, tg: VNode) = chooseDir(self, cstring("outputFolder")),
      proc(ev: Event, tg: VNode) =
        self.newRecord.outputFolder = ev.target.value
        self.data.ipc.send("CODETRACER::path-validation",
          js{
            path: ev.target.value,
            fieldName: cstring("outputFolder"),
            required: self.newRecord.formValidator.requiredFields[cstring("outputFolder")]}),
      inputText =
        if self.newRecord.defaultOutputFolder:
          cstring"/home/<user>/.local/codetracer/"
        else:
          self.newRecord.outputFolder,
      validationMessage = self.newRecord.formValidator.invalidOutputFolderMessage,
      validInput = self.newRecord.formValidator.validOutputFolder,
      disabled = self.newRecord.defaultOutputFolder
    )
    renderRecordResult(self, self.newRecord.status)
    case self.newRecord.status.kind:
    of RecordInit, RecordError:
      tdiv(class = "new-record-form-row"):
        button(
          class = "cancel-button",
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            self.welcomeScreen = true
            self.newRecordScreen = false
            self.newRecord = nil
        ):
          text "Back"
        button(
          class = "confirmation-button",
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            self.newRecord.status.kind = InProgress
            let workDir = if self.newRecord.workDir.isNil or self.newRecord.workDir.len == 0:
                jsUndefined
              else:
                cast[JsObject](self.newRecord.workDir)
            self.data.ipc.send(
                "CODETRACER::new-record", js{
                  args: prepareArgs(self),
                  options: js{ cwd: workDir }
                }
            )
        ):
          text "Run"

    of InProgress:
      tdiv(class = "new-record-form-row"):
        button(
          class = "record-stop-button",
          onclick = proc(ev: Event, tg: VNode) =
            ev.preventDefault()
            self.data.ipc.send "CODETRACER::stop-recording-process"
            self.newRecord.status.kind = RecordError
            self.newRecord.status.errorMessage = "Cancelled by the user."
        ):
          text "Stop"

    else:
      discard

proc dirExist(self: WelcomeScreenComponent, path: cstring): bool = discard

proc stylusExplorer(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "new-record-screen")
  ):
    tdiv(class = "new-record-screen-content"):
      tdiv(class = "welcome-logo")
      tdiv(class = "new-record-title transactions"):
        tdiv(class = "welcome-content"):
          recentTransactionsView(self)

proc newRecordView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "new-record-screen")
  ):
    tdiv(class = "new-record-screen-content"):
      tdiv(class = "welcome-logo")
      tdiv(class = "new-record-title"):
        text "Start Debugger"
      newRecordFormView(self)

proc onlineTraceView(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "new-record-screen")
  ):
    tdiv(class = "new-record-screen-content"):
      tdiv(class = "welcome-logo")
      tdiv(class = "new-record-title"):
        text "Download and open online trace"
      onlineFormView(self)

proc loadInitialOptions(self: WelcomeScreenComponent) =
  self.options = @[
    WelcomeScreenOption(
      name: "Record new trace",
      command: proc =
        self.welcomeScreen = false
        self.newRecordScreen = true
        self.newRecord = NewTraceRecord(
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
            requiredFields: JsAssoc[cstring,bool]{
              "executable": true,
              "workDir": false,
              "outputFolder": false
            }
          )
        )
    ),
    WelcomeScreenOption(
      name: "Open local trace",
      command: proc =
        self.data.ipc.send "CODETRACER::open-local-trace"
    ),
    WelcomeScreenOption(
      name: "Open online trace",
      inactive: not data.config.traceSharingEnabled,
      command: proc =
        self.openOnlineTrace = true
        self.welcomeScreen = false
        self.newDownload = NewDownloadRecord(
          args: @[],
          status: RecordStatus(kind: RecordInit)
        )
    ),
    WelcomeScreenOption(
      name: "CodeTracer shell",
      inactive: true,
      command: proc =
        self.data.ui.welcomeScreen.loading = true
        self.data.ipc.send "CODETRACER::load-codetracer-shell"
    )
  ]

proc welcomeScreenView(self: WelcomeScreenComponent): VNode =
  var class = "welcome-screen"

  if self.loading:
    class = class & " welcome-screen-loading"

  buildHtml(
    tdiv(
      id = "welcome-screen",
      class = class
    )
  ):
    tdiv(class = "welcome-title"):
      tdiv(class = "welcome-text"):
        tdiv(class = "welcome-logo")
        text "Welcome to CodeTracer IDE"
      tdiv(class = "welcome-version"):
        text fmt"Version {CodeTracerVersionStr}"
    tdiv(class = "welcome-content"):
      recentProjectsView(self)
      renderStartOptions(self)

proc loadingOverlay(self: WelcomeScreenComponent): VNode =
  buildHtml(
    tdiv(class = "welcome-screen-loading-overlay")
  ):
    tdiv(class = "welcome-screen-loading-overlay-icon")
    tdiv(class = "welcome-screen-loading-overlay-text"):
      tdiv(): text "Loading trace..."

method render*(self: WelcomeScreenComponent): VNode =
  if self.data.ui.welcomeScreen.isNil:
    return
  if self.options.len == 0:
    self.loadInitialOptions()

  buildHtml(tdiv()):
    if self.welcomeScreen or self.newRecordScreen or self.openOnlineTrace:
      tdiv(class = "welcome-screen-wrapper"):
        windowMenu(data, true)
        if data.startOptions.stylusExplorer:
          stylusExplorer(self)
        else:
          if self.welcomeScreen:
            welcomeScreenView(self)
          elif self.newRecordScreen:
            newRecordView(self)
          elif self.openOnlineTrace:
            onlineTraceView(self)

      if self.loading:
        loadingOverlay(self)
