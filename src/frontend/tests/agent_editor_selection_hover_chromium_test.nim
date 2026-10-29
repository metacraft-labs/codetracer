## A disabled Editor selection still exposes its explanation on hover.
## The production Agent Activity view runs in Chromium with the SHIPPED
## Electron stylesheet, compiled by Stylus rather than copied CSS rules.
## MockBackendService only supplies the store constructor: no backend request
## is under test. The host reason callback is the view's intended seam; the
## renderer-dom counterpart exercises its production desktop implementation.
## Chromium's computed style and hit testing catch pointer-events:none on the
## disabled row; a synthetic click then checks the independent action guard.
## The enabled Upload item is the positive control for both targeting/actions.
## Lane: renderer-chromium. chromium-run.mjs treats page errors as failure.
import std/[jsffi, os]
import isonim/core/[owner, signals]
import isonim/web/[web_renderer, dom_api]
import ../viewmodel/backend/mock_backend
import ../viewmodel/store/replay_data_store
import ../viewmodel/viewmodels/[agent_activity_vm, agent_prompt_context]
import ../viewmodel/views/isonim_agent_activity_view

func buildArg(value: string): string {.compileTime.} =
  when hostOS == "windows": quoteShellWindows(value)
  else: quoteShellPosix(value)

const
  RepoRoot = currentSourcePath().parentDir.parentDir.parentDir.parentDir
  CssBuild = gorgeEx("node " & buildArg(RepoRoot / "node_modules/stylus/bin/stylus") &
    " --print " & buildArg(RepoRoot / "src/frontend/styles/default_dark_theme_electron.styl"))
  ElectronCss = CssBuild.output
  ExpectedChecks = 9
static:
  doAssert CssBuild.exitCode == 0, "The shipped stylesheet must compile: " & CssBuild.output

proc installStyle(css: cstring) {.importjs: """
  (() => { const s = document.createElement('style'); s.textContent = #;
    document.head.appendChild(s); document.body.style.paddingTop = '250px'; })()""".}
proc menuItem(label: cstring): JsObject {.importjs:
  "Array.from(document.querySelectorAll('.agent-add-context-menu-item')).find(e => e.textContent === #)".}
proc attr(el: JsObject; name: cstring): cstring {.importjs:
  "(#.getAttribute(#) || '')".}
proc pointerEvents(el: JsObject): cstring {.importjs:
  "getComputedStyle(#).pointerEvents".}
proc cursor(el: JsObject): cstring {.importjs:
  "getComputedStyle(#).cursor".}
proc hit(el: JsObject): bool {.importjs: """
  ((e) => { const r = e.getBoundingClientRect();
    const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
    return hit != null && hit.closest('.agent-add-context-menu-item') === e;
  })(#)""".}
proc click(el: JsObject) {.importjs:
  "#.dispatchEvent(new MouseEvent('click', {bubbles: true}))".}
proc appendBody(el: Element) {.importjs: "document.body.appendChild(#)".}
proc ctFinish(code: int) {.importjs: "window.ctFinish(#)".}
var checks = 0
var failures = 0
template ck(condition: untyped) =
  inc checks
  if not condition:
    inc failures
    echo "    Check failed: " & astToStr(condition)

installStyle(cstring(ElectronCss))
createRoot proc(dispose: proc()) =
  let store = createReplayDataStore(
    newMockBackendService(autoRespond = true).toBackendService())
  let vm = createAgentActivityVM(store)
  vm.addContextDropdownOpen.val = true
  var selected = 0
  var uploaded = 0
  let callbacks = AgentActivityCallbacks(
    editorSelectionUnavailableReason: (proc(): string = AgentNoEditorSelectionReason),
    onAddEditorSelection: (proc() = inc selected),
    onAddFiles: (proc() = inc uploaded))
  let panel = renderAgentActivityPanel[WebRenderer, Element](
    WebRenderer(), vm, componentId = 91, callbacks = callbacks)
  appendBody(panel)
  let editor = menuItem("Editor selection")
  ck editor.attr("aria-disabled") == cstring"true"
  ck editor.attr("title") == cstring(AgentNoEditorSelectionReason)
  ck editor.cursor() == cstring"not-allowed"
  ck editor.pointerEvents() == cstring"auto"
  ck editor.hit()
  click(editor)
  ck selected == 0
  let upload = menuItem("Upload attachment")
  ck upload.hit()
  click(upload)
  ck uploaded == 1
  ck selected == 0
  dispose()
if checks != ExpectedChecks:
  inc failures
  echo "    Check failed: expected ", ExpectedChecks, " checks, ran ", checks
echo(if failures == 0: "  [OK] " else: "  [FAILED] ",
  "disabled Editor selection remains hoverable and cannot activate")
echo "CHECKS: ", checks
ctFinish(if failures == 0: 0 else: 1)
