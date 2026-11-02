## The desktop's add-context menu uses its actual panel-host callback.
## jsdom supplies the DOM; the IPC recorder sits at the main-process boundary
## so a file-picker request is observed without opening a native dialog.
## Monaco's getSelection is supplied at the editor boundary: these tests cover
## the host's use of Monaco's documented 1-based range, not Monaco internals.
## The shared bootstrap only supplies unrelated import-time Monaco models.
## Every view, menu handler, context chip and AgentActivityVM is production.
## Lane: renderer-dom. Browser-target unittest needs an explicit exit status.
import ./legacy_loop_dom_bootstrap
import std/[unittest, jsffi, dom, strutils]
import ../types
import ../utils
import ../lib/monaco_lib
import ../renderer
import ../ui/layout
import ../ui/agent_activity
import ../ui/panel_host
import ../ui/session_viewmodels
import ../dap_backend
import ../viewmodel/sdk/debugger_session
import ../viewmodel/session_vm
import ../viewmodel/viewmodels/[agent_activity_vm, agent_prompt_context]
from isonim/web/dom_api as idom import nil

var failures = 0
var assertions = 0
var completedTests = 0
const ExpectedAssertions = 16
const ExpectedTests = 5
type ExitStatusFormatter = ref object of OutputFormatter
method testEnded(formatter: ExitStatusFormatter; result: TestResult) =
  inc completedTests
  if result.status != OK:
    inc failures
addOutputFormatter(newConsoleOutputFormatter())
addOutputFormatter(ExitStatusFormatter())
template ck(condition: untyped) =
  inc assertions
  if not condition: inc failures
  check condition

var channels: seq[string] = @[]
let ipc = JsObject{}
ipc.send = proc(channel: cstring; payload: JsObject) = channels.add $channel
data.ipc = ipc
data.dapApi.ipc = ipc
for content in Content:
  data.ui.componentMapping[content] = JsAssoc[int, Component]{}
let fixtureSession = newDebuggerSession(newDapBackendService(data.dapApi))
let session = fixtureSession.session
session.initializePanelViewModels()
initAgentActivityVMWithStore(session.store)
let component = data.makeAgentActivityComponent(71)
component.syncLegacyAgentActivityIntoVM()
setPanelSession(session)
let host = document.createElement("div")
host.id = "agentActivityComponent-71"
document.body.appendChild(host)
let mounted = mountPanel(cast[idom.Element](host), Content.AgentActivity)
let vm = agentActivityVMInstances[data.tabScopedId(component)]

proc click(el: JsObject) {.importjs: "#.dispatchEvent(new window.MouseEvent('click', {bubbles: true}))".}
proc attribute(el: JsObject; name: cstring): cstring {.importjs:
  "(#.getAttribute(#) || '')".}
proc menuItem(label: cstring): JsObject {.importjs:
  "Array.from(document.querySelectorAll('.agent-add-context-menu-item')).find(e => e.textContent === #)".}
proc openMenu() =
  click(host.toJs.querySelector(cstring".agent-add-context-button"))
proc setEditor(path: cstring; first, last: int) =
  let monaco = JsObject{}
  monaco.getSelection = proc(): JsObject =
    JsObject{startLineNumber: first, endLineNumber: last}
  data.services.editor.active = path
  data.ui.editors[path] = EditorViewComponent(path: path,
    monacoEditor: cast[MonacoEditor](monaco))

suite "desktop Agent Activity attaches the editor selection":
  test "the menu attaches selected file lines without asking for a picker":
    setEditor(cstring"/project/source.nim", 3, 7)
    channels = @[]
    openMenu()
    click(menuItem("Editor selection"))
    ck vm.getContextPaths() == @["/project/source.nim:3-7"]
    ck "CODETRACER::acp-pick-files" notin channels
    ck "/project/source.nim:3-7" in $host.toJs.textContent.to(cstring)

  test "the current editor and caret are read when the item is chosen":
    vm.clearContextPaths()
    setEditor(cstring"/project/source.nim", 3, 7)
    channels = @[]
    openMenu()
    setEditor(cstring"/project/other.nim", 11, 11)
    click(menuItem("Editor selection"))
    ck vm.getContextPaths() == @["/project/other.nim:11"]
    ck "CODETRACER::acp-pick-files" notin channels

  test "closing the editor after opening the menu cannot attach a stale selection":
    vm.clearContextPaths()
    setEditor(cstring"/project/source.nim", 3, 7)
    channels = @[]
    openMenu()
    data.services.editor.active = cstring""
    click(menuItem("Editor selection"))
    ck vm.getContextPaths().len == 0
    ck "CODETRACER::acp-pick-files" notin channels

  test "no open file disables Editor selection and explains why":
    vm.clearContextPaths()
    data.services.editor.active = cstring""
    channels = @[]
    openMenu()
    let item = menuItem("Editor selection")
    ck item.attribute(cstring"aria-disabled") == cstring"true"
    ck item.attribute(cstring"title") == cstring(AgentNoEditorSelectionReason)
    click(item)
    ck vm.getContextPaths().len == 0
    ck "CODETRACER::acp-pick-files" notin channels

    # Closing/reopening uses the file that exists now, not a cached state.
    if not host.toJs.querySelector(cstring".agent-add-context-dropdown").isNil:
      openMenu()
    setEditor(cstring"/project/reopened.nim", 5, 2)
    openMenu()
    click(menuItem("Editor selection"))
    ck vm.getContextPaths() == @["/project/reopened.nim:2-5"]

  test "an untitled buffer has no file to attach":
    vm.clearContextPaths()
    setEditor(cstring"#untitled0", 1, 1)
    data.ui.editors[cstring"#untitled0"].tabInfo = TabInfo(untitled: true)
    channels = @[]
    openMenu()
    let item = menuItem("Editor selection")
    ck item.attribute(cstring"aria-disabled") == cstring"true"
    ck item.attribute(cstring"title") == cstring(AgentNoEditorSelectionReason)
    click(item)
    ck vm.getContextPaths().len == 0
    ck "CODETRACER::acp-pick-files" notin channels

mounted.dispose()
session.dispose()
window.toJs.close()
if assertions != ExpectedAssertions or completedTests != ExpectedTests:
  inc failures
echo "editor-selection assertions: ", assertions, "; failures: ", failures
{.emit: "if (`failures` !== 0) process.exitCode = 1;".}
