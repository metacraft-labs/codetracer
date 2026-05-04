import
  std/[ jsffi, strformat, strutils ],
  kdom, paths

when defined(linux):
  var startMenuChecked = true
  var bpfChecked = true
  var agentHarborChecked = true

var pathChecked = true
var dontAskChecked = false

type
  StepInfo = object
    ## Tracks the status of one install step for the progress display.
    step: string      ## e.g. "path", "desktop", "bpf", "agent-harbor"
    status: string    ## "started", "completed", "failed", "skipped"
    message: string   ## Human-readable description

var installSteps: seq[StepInfo] = @[]
var installOverallStatus = ""  ## "", "installing", "ok", "problem"

var electron* {.importc.}: JsObject
let ipc = electron.ipcRenderer

proc closeWindow() {.importjs: "window.close()".}

proc onDismiss() =
  ipc.send("CODETRACER::dismiss-ct-frontend", dontAskChecked.toJs)

  closeWindow()

proc renderSubwindow()

proc onInstall() =

  let options: JsObject = js{}

  when defined(linux):
    if startMenuChecked:
      options["desktop"] = true
    options["bpf"] = bpfChecked
    options["agent-harbor"] = agentHarborChecked

  if pathChecked:
    options["path"] = true

  ipc.send("CODETRACER::install-ct-frontend", options)
  installOverallStatus = "installing"
  renderSubwindow()

proc stepDisplayName(step: string): string =
  ## Returns a user-friendly label for each install step.
  case step
  of "path": "PATH setup"
  of "desktop": "Desktop file"
  of "bpf": "BPF monitoring"
  of "agent-harbor": "Agent Harbor"
  else: step

proc stepStatusIcon(status: string): string =
  case status
  of "started": "..."
  of "completed": "OK"
  of "failed": "FAILED"
  of "skipped": "skipped"
  else: ""

proc appendText(parent: Node, value: string) =
  parent.appendChild(document.createTextNode(cstring(value)))

proc newElement(tag: cstring, className: cstring = cstring""): Element =
  result = document.createElement(tag)
  if className != cstring"":
    result.setAttribute(cstring"class", className)

proc newTextElement(tag: cstring, className: cstring, value: string): Element =
  result = newElement(tag, className)
  result.appendText(value)

proc appendInfoTooltip(parent: Node, lines: openArray[string]) =
  let icon = newTextElement(cstring"span", cstring"info-icon", "ⓘ ")
  let tooltip = newElement(cstring"div", cstring"custom-tooltip")
  for i, line in lines:
    if i > 0:
      tooltip.appendChild(document.createElement(cstring"br"))
    tooltip.appendText(line)
  icon.appendChild(tooltip)
  parent.appendChild(icon)

proc appendCheckboxOption(
    parent: Node,
    labelText: string,
    checked: bool,
    onToggle: proc(),
    tooltipLines: openArray[string],
  ) =
  let label = document.createElement(cstring"label")
  let input = document.createElement(cstring"input")
  input.setAttribute(cstring"type", cstring"checkbox")
  input.checked = checked
  input.addEventListener(cstring"click", proc(ev: Event) =
    onToggle()
  )
  label.appendChild(input)
  label.appendText(labelText)
  label.appendInfoTooltip(tooltipLines)
  parent.appendChild(label)

proc newActionButton(className, label: cstring, action: proc()): Element =
  result = newTextElement(cstring"button", className, $label)
  result.addEventListener(cstring"click", proc(ev: Event) =
    action()
  )

proc installStatusView: Node =
  result = newElement(cstring"div", cstring"dialog-install-status")
  if installSteps.len == 0 and installOverallStatus == "installing":
    result.appendChild(newTextElement(
      cstring"div",
      cstring"dialog-install-status-installing",
      "Installing..."
    ))
  else:
    for step in installSteps:
      let statusClass = "install-step-" & step.status
      let stepNode = newElement(cstring"div", cstring(fmt"install-step {statusClass}"))
      stepNode.appendChild(newTextElement(cstring"span", cstring"step-icon", stepStatusIcon(step.status)))
      stepNode.appendChild(newTextElement(cstring"span", cstring"step-name", stepDisplayName(step.step)))
      if step.message.len > 0 and step.status == "failed":
        stepNode.appendChild(newTextElement(cstring"span", cstring"step-message", " — " & step.message))
      result.appendChild(stepNode)
    if installOverallStatus == "ok":
      result.appendChild(newTextElement(
        cstring"div",
        cstring"dialog-install-status-ok",
        "Installation complete."
      ))
    elif installOverallStatus == "problem":
      result.appendChild(newTextElement(
        cstring"div",
        cstring"dialog-install-status-problem",
        "Installation encountered errors."
      ))

proc dialogBox(): Node =
  echo "codetracerPrefix: ", codetracerPrefix
  result = document.createElement(cstring"div")

  let box = newElement(cstring"div", cstring"dialog-box")
  result.appendChild(box)

  let header = newElement(cstring"div", cstring"dialog-header")
  let icon = document.createElement(cstring"img")
  icon.setAttribute(cstring"src", cstring"./public/resources/shared/codetracer_welcome_logo.svg")
  icon.setAttribute(cstring"class", cstring"dialog-icon")
  header.appendChild(icon)
  box.appendChild(header)

  let content = newElement(cstring"div", cstring"dialog-content")
  content.appendText("CodeTracer is not installed.")
  content.appendChild(document.createElement(cstring"br"))
  content.appendText("Do you want to install it now?")
  box.appendChild(content)

  if installOverallStatus == "":
    let options = newElement(cstring"div", cstring"dialog-options")
    when defined(linux):
      options.appendCheckboxOption(
        "Add CodeTracer to my start menu",
        startMenuChecked,
        proc() = startMenuChecked = not startMenuChecked,
        [
          "This will install a .desktop file in ~/.local/share/applications",
          "which will exec the binary you ran this executable with"
        ]
      )
    options.appendCheckboxOption(
      "Add the ct command to my PATH",
      pathChecked,
      proc() = pathChecked = not pathChecked,
      [
        "This will create a symlink to the current executable in ~/.local/bin"
      ]
    )
    when defined(linux):
      options.appendCheckboxOption(
        "Enable BPF process monitoring (requires admin password)",
        bpfChecked,
        proc() = bpfChecked = not bpfChecked,
        [
          "Sets up BPF capabilities for process tree monitoring.",
          "Requires sudo for initial setup. Can be skipped and configured later."
        ]
      )
      options.appendCheckboxOption(
        "Install Agent Harbor (requires admin password)",
        agentHarborChecked,
        proc() = agentHarborChecked = not agentHarborChecked,
        [
          "Installs Agent Harbor for AI-powered debugging.",
          "Downloads the official installer. Requires sudo."
        ]
      )
    box.appendChild(options)

    let actions = newElement(cstring"div", cstring"dialog-actions")
    actions.appendChild(newActionButton(cstring"install-btn", cstring"Install", onInstall))
    actions.appendChild(newActionButton(cstring"dismiss-btn", cstring"Dismiss", onDismiss))
    box.appendChild(actions)

    let askAgain = newElement(cstring"div", cstring"dialog-options dialog-ask-again")
    let askLabel = document.createElement(cstring"label")
    askLabel.appendText("Don't ask me again!")
    let askInput = document.createElement(cstring"input")
    askInput.setAttribute(cstring"type", cstring"checkbox")
    askInput.checked = dontAskChecked
    askInput.addEventListener(cstring"click", proc(ev: Event) =
      dontAskChecked = not dontAskChecked
    )
    askLabel.appendChild(askInput)
    askAgain.appendChild(askLabel)
    box.appendChild(askAgain)
  else:
    box.appendChild(installStatusView())
    if installOverallStatus in ["ok", "problem"]:
      let actions = newElement(cstring"div", cstring"dialog-actions")
      actions.appendChild(newActionButton(cstring"dismiss-btn", cstring"Close", onDismiss))
      box.appendChild(actions)

proc main(): Node =
  result = document.createElement(cstring"div")
  result.appendChild(dialogBox())

proc renderSubwindow() =
  let root = document.getElementById(cstring"ROOT")
  if root.isNil:
    return
  root.innerHTML = cstring""
  root.appendChild(main())

proc onCtInstallStatus(sender: js, data: js) =
  ## Handles install progress events from the main process.
  ## Accepts two formats:
  ##   - Step event: {kind: "step", step: "...", status: "...", message: "..."}
  ##   - Done event: {kind: "done", status: "ok"|"problem"}
  let kind = $cast[cstring](data["kind"])
  if kind == "step":
    let info = StepInfo(
      step: $cast[cstring](data["step"]),
      status: $cast[cstring](data["status"]),
      message: $cast[cstring](data["message"]),
    )
    # Update existing step or append new one.
    var found = false
    for i in 0 ..< installSteps.len:
      if installSteps[i].step == info.step:
        installSteps[i] = info
        found = true
        break
    if not found:
      installSteps.add(info)
  elif kind == "done":
    installOverallStatus = $cast[cstring](data["status"])
  renderSubwindow()

ipc.on("CODETRACER::ct-install-status", onCtInstallStatus)

renderSubwindow()
