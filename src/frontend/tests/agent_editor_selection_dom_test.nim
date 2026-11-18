## The desktop's add-context menu uses its actual panel-host callback.
## jsdom supplies the DOM; the IPC recorder sits at the main-process boundary
## so a file-picker request is observed without opening a native dialog.
## Monaco is stood in for at the editor boundary because it needs a real layout
## engine that jsdom lacks, and these tests cover the host's use of Monaco's API,
## not Monaco internals. The stand-in holds to the documented contract the host
## reads (https://microsoft.github.io/monaco-editor/typedoc/): `getSelections()`
## gives every selection as a 1-based range, start before end whichever way it
## was dragged, an empty range being a caret, and `getPosition()` gives the
## caret. It has no `getSelection`, so a host that goes back to reading one
## selection fails here.
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
const ExpectedAssertions = 23
const ExpectedTests = 7
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
proc monacoSelection(r: EditorRange): JsObject =
  JsObject{startLineNumber: r.startLine, startColumn: r.startColumn,
    endLineNumber: r.endLine, endColumn: r.endColumn}
proc setEditorSelections(path: cstring; ranges: seq[EditorRange];
                         caretLine: int) =
  ## Show `path` with exactly these selections and this caret.
  let monaco = JsObject{}
  monaco.getSelections = proc(): seq[JsObject] =
    for r in ranges:
      result.add monacoSelection(r)
  monaco.getPosition = proc(): JsObject =
    JsObject{lineNumber: caretLine}
  data.services.editor.active = path
  data.ui.editors[path] = EditorViewComponent(path: path,
    monacoEditor: cast[MonacoEditor](monaco))
proc setEditor(path: cstring; first, last: int) =
  ## A selection dragged from line `first` to line `last`, which may run
  ## backwards; Monaco still reports it start first, with the caret where the
  ## drag ended. `first == last` is a caret with nothing selected.
  let selection: EditorRange =
    if first == last: (first, 1, first, 1)
    else: (min(first, last), 1, max(first, last), 4)
  setEditorSelections(path, @[selection], last)

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

  test "every selection counts, by the lines its text covers":
    vm.clearContextPaths()
    # The second range is lines 8 and 9 picked by their line numbers: it ends
    # at column 1 of line 10, so line 10 is not selected.
    setEditorSelections(cstring"/project/source.nim",
      @[(3, 2, 3, 9).EditorRange, (8, 1, 10, 1).EditorRange], 10)
    channels = @[]
    openMenu()
    click(menuItem("Editor selection"))
    ck vm.getContextPaths() == @["/project/source.nim:3-9"]
    ck "CODETRACER::acp-pick-files" notin channels

    # An empty range selects nothing, so only the caret's line is attached.
    vm.clearContextPaths()
    setEditorSelections(cstring"/project/source.nim",
      @[(14, 5, 14, 5).EditorRange], 14)
    openMenu()
    click(menuItem("Editor selection"))
    ck vm.getContextPaths() == @["/project/source.nim:14"]

    # Beside a real selection, an empty range is a second cursor, not a line
    # of the selection: line 20 must not stretch the attachment to 3-20.
    vm.clearContextPaths()
    setEditorSelections(cstring"/project/source.nim",
      @[(3, 2, 5, 9).EditorRange, (20, 4, 20, 4).EditorRange], 5)
    openMenu()
    click(menuItem("Editor selection"))
    ck vm.getContextPaths() == @["/project/source.nim:3-5"]

  test "an editor with no model has no selection to attach":
    vm.clearContextPaths()
    # Monaco types `getSelections()` as `Selection[] | null`; its editor widget
    # answers null when it has no model.
    setEditorSelections(cstring"/project/source.nim", @[], 1)
    data.ui.editors[cstring"/project/source.nim"].monacoEditor.toJs.getSelections =
      proc(): JsObject = nil
    channels = @[]
    openMenu()
    let item = menuItem("Editor selection")
    ck item.attribute(cstring"aria-disabled") == cstring"true"
    click(item)
    ck vm.getContextPaths().len == 0
    ck "CODETRACER::acp-pick-files" notin channels
    # A disabled item leaves the menu open; close it for the next case.
    if not host.toJs.querySelector(cstring".agent-add-context-dropdown").isNil:
      openMenu()

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
