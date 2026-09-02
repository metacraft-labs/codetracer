# FIRST, AND THE POSITION IS LOAD-BEARING — NS9.
#
# `web_boot` starts the web instantiation's `boot()` in its own module
# initialiser, and a Nim module initialises before the module that imports it.
# Putting this line at the top is what makes `boot()` run BEFORE
# `ui/agent_activity`'s module-scope `monaco.editor.createModel`.
#
# That matters because `monaco` comes from the third-party bundle, and a
# deployment that loses it makes this file raise `ReferenceError` a quarter of
# the way through its own top-level code. When the boot call sat at the TAIL of
# this file, such a throw meant the platform never booted and the page reported
# nothing about why — `ci/test/web-renderer-mounts.sh`'s arm A is that
# deployment, and its twin assertion ("the loop arm still booted") is what
# caught the regression when the two Nim bundles were merged into this one.
#
# `boot()` is async, so it returns at its first `await` with its continuation
# already queued; a later synchronous throw in the same module-init pass does
# not cancel it. So the boot line is still reported, and a renderer that dies
# is still distinguishable from a storage layer that refused.
#
# A `from ... import` rather than a plain `import`: `web_boot` re-exports
# `host/web_browser`, and this file's import list is the tree's most
# collision-prone. Two names is the whole surface.
when defined(ctWeb):
  from web_boot import startWebSession, describeRunningPlatform

import
  asyncjs, strformat, strutils, sequtils, jsffi, algorithm, jsconsole, macros,
  options, json,
  ui/[agent_activity, agent_workspace, layout, editor, trace, event_log,
      state, calltrace, menu, status,
      debug, flow, filesystem, vcs, value, repl,
      build, errors, search_results, welcome_screen, scratchpad,
      trace_log, calltrace_editor, terminal_output, shell,
      no_source, ui_imports, shortcuts, step_list, low_level_code,
      request_panel, session_switch, session_tabs, command, frame_viewer,
      pixel_history, shader_debug, video_player, agentic_session_launcher],
  # `layout_config_repair` is dependency-free by design (its own header says
  # so) precisely so a non-Electron caller can use it; `onNoTrace` reads the
  # editor's declared width out of the layout config with it.
  index/layout_config_repair,
  ui/[test_results, constraints],
  ../ct_test/contracts,
  ../common/noir_constraints,
  viewmodel/viewmodels/[test_results_vm, constraints_vm],
  # `electron_presence` supplies `inElectron`, which the two `if inElectron:`
  # blocks at the bottom of this file read to choose an IPC transport.
  #
  # THIS IMPORT IS NOT DECORATION AND ITS ABSENCE WAS A BUILD BREAK. Until now
  # the symbol arrived here by accident, through `ui/ui_imports`' blanket
  # re-export of `electron_lib`. NS1 residual 1 removed that re-export after
  # auditing electron_lib's 14 exported symbols for uses "anywhere under
  # `ui/`" — and this file is `src/frontend/ui_js.nim`, which is not under
  # `ui/`. The audit's scope had a hole exactly the shape of the renderer
  # entry point, and because no CI lane compiled it, `dev` carried a renderer
  # that did not build. Naming the dependency is what stops it recurring.
  lib/[ jslib, logging, electron_presence ],
  types, lang, utils, renderer, config, dap, edit_mode,
  viewmodel/store/replay_data_store,
  viewmodel/viewmodels/video_player_vm,
  ../common/ct_logging,
  property_test / test,
  event_helpers,
  .. / common / ct_event

when defined(ctInExtension):
  import vscode

# Desktop-test machinery: it drives an agentic worktree by running arbitrary
# programs, and its own guard declares it absent from a web build because
# `capProcessArbitraryPrograms` is absent there. A tab can run the declared
# wasm modules and nothing else, so there is no web arm to write.
when not defined(ctWeb):
  import ui/agentic_worktree_test_hooks

from dom import Element, getAttribute, Node, preventDefault, document,
                getElementById, querySelectorAll, querySelector

proc configureIPC(data: Data)

proc jsMissing(value: JsObject): bool {.
  importjs: "((function(v) { return v === undefined || v === null; })(#))".}

proc stringifyJsObject(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc parseJsonFromJsObject(o: JsObject): JsonNode =
  ## Convert a raw DAP payload into a stdlib `JsonNode`.
  ##
  ## Nim's JS backend represents `JsonNode` as a tagged Nim object, not
  ## a plain JavaScript value, so a payload must round-trip through a
  ## JSON string before the `kind` checks in the decoders will hold.
  ## Same conversion as `viewmodel/backend/real_backend.parseJsonFromJs`
  ## and `ui/state.nim`; duplicated rather than exported because those
  ## modules would otherwise pull their whole dependency graph in here.
  parseJson($stringifyJsObject(o))

proc fsExistsSync(path: cstring): bool {.importjs: """
  ((typeof require === 'function') && require('fs').existsSync(#))
""".}
proc fsReadFileSync(path: cstring, encoding: cstring): cstring {.importjs: """
  ((typeof require === 'function') ? require('fs').readFileSync(#, #) : '')
""".}

proc nimSourceCandidate(program: string): cstring =
  if program.len == 0:
    return cstring""
  if program.endsWith(".nim"):
    return cstring(program)

  let adjacentSource = cstring(program & ".nim")
  if fsExistsSync(adjacentSource):
    return adjacentSource

  let buildSourcesPath = cstring(program & ".ct-build-sources.json")
  if fsExistsSync(buildSourcesPath):
    try:
      let sources = cast[seq[cstring]](
        JSON.parse(fsReadFileSync(buildSourcesPath, cstring"utf8")))
      for source in sources:
        if ($source).endsWith(".nim") and fsExistsSync(source):
          return source
    except:
      cwarn "failed to inspect Nim build sources for " & program & ": " &
        getCurrentExceptionMsg()

  return cstring""

proc normalizeTraceProgramForUi(trace: Trace) =
  if trace.isNil:
    return
  if trace.lang != LangNim and trace.lang != LangUnknown:
    return
  let program = $trace.program
  let sourceCandidate = nimSourceCandidate(program)
  if sourceCandidate.len == 0:
    return
  trace.program = sourceCandidate
  trace.lang = LangNim

proc bootstrapCollabJoinFromLocation() {.importjs: """
(async function() {
  if (window.CODETRACER_COLLAB_BOOTSTRAP_STARTED) return;
  const prefix = "/collab/join/";
  const pathname = window.location.pathname;
  if (!pathname.startsWith(prefix)) return;
  window.CODETRACER_COLLAB_BOOTSTRAP_STARTED = true;
  const tokenPart = pathname.slice(prefix.length);
  if (!tokenPart || tokenPart.includes("/")) return;

  const token = decodeURIComponent(tokenPart);
  const response = await fetch("/api/v1/collab/invites/exchange", {
    method: "POST",
    credentials: "include",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ token })
  });
  if (!response.ok) {
    window.CODETRACER_COLLAB_JOIN_ERROR = await response.text();
    return;
  }

  const bootstrap = await response.json();
  window.CODETRACER_COLLAB_BOOTSTRAP = bootstrap;
  window.CODETRACER_REPLAY_ID = bootstrap.replayId;
  window.localStorage.setItem("CODETRACER_REPLAY_ID", bootstrap.replayId);
  window.localStorage.setItem("CODETRACER_COLLAB_ROOM_ID", bootstrap.roomId);
  if (bootstrap.rendezvousUrl) {
    const rendezvous = await fetch(bootstrap.rendezvousUrl, {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        inviteToken: token,
        payload: {
          client: "webui",
          roomId: bootstrap.roomId,
          grants: bootstrap.initialGrants || []
        }
      })
    });
    if (rendezvous.ok) {
      window.CODETRACER_COLLAB_RENDEZVOUS = await rendezvous.json();
    } else {
      window.CODETRACER_COLLAB_RENDEZVOUS_ERROR = await rendezvous.text();
    }
  }
  const activate = typeof window.activateCollabJoinBootstrap === "function"
    ? window.activateCollabJoinBootstrap
    : (typeof activateCollabJoinBootstrap === "function"
      ? activateCollabJoinBootstrap
      : null);
  if (typeof activate === "function") {
    const activationRaw = activate(JSON.stringify(bootstrap));
    try {
      window.CODETRACER_COLLAB_SESSION = JSON.parse(activationRaw);
    } catch (_error) {
      window.CODETRACER_COLLAB_SESSION = {
        activated: false,
        error: "collaboration activation returned invalid JSON"
      };
    }
    window.CODETRACER_COLLAB_JOIN_READY = true;
  }
})()
""".}

# IPC HANDLERS

var vex* {.importc.}: js
var middlewareConfigured = false
var dapSessionSelectionReady = false
var pendingDapReplaySelection: JsObject
var pendingDapLiveSelection: JsObject
const TAB_LIMIT = 20

proc hideWelcomeScreenSurface() =
  if not data.ui.welcomeScreen.isNil:
    data.ui.welcomeScreen.resetView()
  welcome_screen.clearIsoNimWelcomeScreen()

# ---------------------------------------------------------------------------
# ViewModel layer — SessionViewModel backed by the real DapApi.
# Created once in configureMiddleware; the shared store is passed to
# individual panels so they all share a single real backend connection.
# ---------------------------------------------------------------------------
import viewmodel/session_vm
import viewmodel/backend/[backend_service, real_backend]
import viewmodel/collab/[front_end_adapter, invite_bootstrap, join_session,
  reducer, session_core, types]
import viewmodel/app/isonim_app
import viewmodel/viewmodels/visual_replay_layout
import viewmodel/viewmodels/deepreview_layout
from isonim/core/batch as isoBatch import batch
import hmr_runtime
from viewmodel/store/types import liveMcr
from ui/process_tree import
  consumeListProcessesEvent, mountProcessTree
import viewmodel/viewmodels/state_vm
import viewmodel/viewmodels/origin_chain_types
from viewmodel/viewmodels/origin_chain_vm import applyChainResponse, openSidePanel, onCancelLoad
from isonim/core/signals import val
from isonim/core/computation import val
from viewmodel/viewmodels/trace_open import
  TraceOpenService, TraceOpenRequest, TraceOpenPolicy, topCurrentTab, topNewTab
from viewmodel/viewmodels/review_open import
  ReviewOpenService, ReviewDatasetRequest, ReviewDatasetRequestKind
from viewmodel/viewmodels/evidence_call_vm import
  EvidenceDataset, EvidenceDatasetState, edsReady, edsUnavailable
var activeSessionVM: SessionViewModel
# Backend-reported `supportsStepBack` capability from the DAP `initialize`
# response. The response can arrive (synchronously, via the in-process DAP
# transport) before `activeSessionVM` exists, in which case the handler cannot
# apply it to the session store yet — it stashes it here so the value is
# re-applied once the session VM is created. Without this, reverse-step /
# reverse-continue toolbar buttons stay wrongly disabled on completed DB
# replays even though the backend supports backward stepping.
var pendingSupportsStepBack: bool = false
var activeCollabFrontEndAdapter: FrontEndAdapter
var activeIsoNimApp: IsoNimApp
var pendingCollabJoinBootstrapRaw: cstring = cstring""
const MIN_FONTSIZE = 6
const MAX_FONTSIZE = 40
const EDITOR_GUTTER_PADDING = 2 #px

var disconnectedNotification: Notification

proc seqIsNil[T](s: seq[T]): bool {.importjs: "(# == null)".}

proc publishCollabJoinState(raw: cstring) {.importjs: """
  (function(raw) {
    let state = null;
    try {
      state = JSON.parse(String(raw || "{}"));
    } catch (error) {
      state = { activated: false, error: String(error && error.message || error) };
    }
    window.CODETRACER_COLLAB_SESSION = state;
    window.CODETRACER_COLLAB_JOIN_READY = true;
  })(#);
""".}

proc activateCollabJoinBootstrap*(raw: cstring): cstring {.exportc.} =
  ## JS-callable M6 join hook. Invite exchange can complete before the real
  ## SessionViewModel exists, so this stores the bootstrap and configureMiddleware
  ## replays it once the collaboration core is available.
  if activeSessionVM.isNil or activeSessionVM.collabCore.isNil:
    pendingCollabJoinBootstrapRaw = raw
    result = cstring($(%*{
      "activated": false,
      "pending": true,
    }))
    publishCollabJoinState(result)
    return

  try:
    let activation = activeSessionVM.collabCore.startCollabJoinSession(
      parseJson($raw))
    pendingCollabJoinBootstrapRaw = cstring""
    result = cstring($(activation.toJson))
  except CatchableError as e:
    result = cstring($(%*{
      "activated": false,
      "pending": false,
      "error": e.msg,
    }))
  publishCollabJoinState(result)

proc activateCollabHostInvite*(raw: cstring): cstring {.exportc.} =
  ## JS-callable M6 host hook. Creating an invite starts the same browser
  ## collaboration transport as joining through an invite URL.
  if activeSessionVM.isNil or activeSessionVM.collabCore.isNil:
    result = cstring($(%*{
      "activated": false,
      "pending": true,
    }))
    publishCollabJoinState(result)
    return

  try:
    let activation = activeSessionVM.collabCore.startCollabHostSession(
      parseJson($raw))
    result = cstring($(activation.toJson))
  except CatchableError as e:
    result = cstring($(%*{
      "activated": false,
      "pending": false,
      "error": e.msg,
    }))
  publishCollabJoinState(result)

proc collabTestDispatchSetRegister*(targetPath, value: cstring): cstring {.exportc.} =
  if activeSessionVM.isNil or activeSessionVM.collabCore.isNil:
    return cstring($(%*{"status": "missingCore"}))
  let core = activeSessionVM.collabCore
  let applyResult = core.dispatchLocalViewOp(
    vokSetRegister,
    $targetPath,
    %*{"value": $value})
  let last =
    if core.dispatchLog.len == 0:
      LocalViewOpDispatch()
    else:
      core.dispatchLog[^1]
  cstring($(%*{
    "status": $applyResult.status,
    "reason": applyResult.reason,
    "publishedToPeer": last.publishedToPeer,
    "localOnly": last.localOnly,
    "opId": last.op.opId,
    "selectedPath": core.document.state.statePane.selectedPath.value,
  }))

proc collabTestDispatchDebugCommand*(command, leaseId: cstring): cstring {.exportc.} =
  if activeSessionVM.isNil or activeSessionVM.collabCore.isNil:
    return cstring($(%*{"status": "missingCore"}))
  let core = activeSessionVM.collabCore
  let applyResult = core.dispatchLocalViewOp(
    vokDebugCommand,
    "debugger.commands",
    %*{
      "command": $command,
      "leaseId": $leaseId,
    })
  let last =
    if core.dispatchLog.len == 0:
      LocalViewOpDispatch()
    else:
      core.dispatchLog[^1]
  cstring($(%*{
    "status": $applyResult.status,
    "reason": applyResult.reason,
    "publishedToPeer": last.publishedToPeer,
    "localOnly": last.localOnly,
    "opId": last.op.opId,
  }))

proc collabTestState*(): cstring {.exportc.} =
  if activeSessionVM.isNil or activeSessionVM.collabCore.isNil:
    return cstring($(%*{"status": "missingCore"}))
  let core = activeSessionVM.collabCore
  var grants = newJArray()
  for grant in core.document.state.capabilityGrants:
    if grant.subject == core.localPrincipalId and grant.revokedByOpId.len == 0:
      for cap in grant.capabilities:
        grants.add %($cap)
  cstring($(%*{
    "status": "ready",
    "sessionId": core.document.state.sessionId,
    "traceIdentity": core.document.state.traceIdentity,
    "localPrincipalId": core.localPrincipalId,
    "selectedPath": core.document.state.statePane.selectedPath.value,
    "collaborationEnabled": core.collaborationEnabled,
    "peerTransportStarted": core.peerTransportStarted,
    "localOperationLogLen": core.localOperationLog.len,
    "grants": grants,
  }))

bootstrapCollabJoinFromLocation()

proc rrBackendPath(data: Data): cstring =
  ## Safely retrieve the RR backend executable path from the config.
  ## Returns an empty string when config or rrBackend is nil — this can
  ## happen in web mode when DapInitialized arrives before onInit has
  ## populated data.config (bootstrap-cache replay timing race).
  if not data.config.isNil and not data.config.rrBackend.isNil:
    data.config.rrBackend.path
  else:
    cstring""

proc connectionDetailMessage(reason: ConnectionLossReason, detail: cstring): cstring =
  if detail.len > 0:
    return detail
  connectionLossMessage(reason)

proc showDisconnectedWarning(data: Data, reason: ConnectionLossReason, detail: cstring) =
  let message = $connectionDetailMessage(reason, detail)
  let reconnectAction = newNotificationButtonAction(cstring"Reconnect", proc = domwindow.location.reload())

  if disconnectedNotification.isNil:
    disconnectedNotification = newNotification(
      NotificationKind.NotificationWarning,
      message,
      actions = @[reconnectAction]
    )
    data.viewsApi.showNotification(disconnectedNotification)
  else:
    disconnectedNotification.text = message
    disconnectedNotification.active = true
    disconnectedNotification.seen = false
    if not data.ui.isNil and not data.ui.status.isNil:
      data.ui.status.redraw()

proc clearDisconnectedWarning(data: Data) =
  if disconnectedNotification.isNil:
    return
  disconnectedNotification.active = false
  disconnectedNotification.seen = false
  if not data.ui.isNil and not data.ui.status.isNil:
    data.ui.status.redraw()

proc updateConnectionState(data: Data, connected: bool, reason: ConnectionLossReason, detail: cstring = cstring"") =
  data.connection.connected = connected
  data.connection.reason = reason
  data.connection.detail = detail

  if connected:
    clearDisconnectedWarning(data)
    if not data.ui.isNil and not data.ui.status.isNil:
      data.ui.status.redraw()
  else:
    showDisconnectedWarning(data, reason, detail)

proc connectionReasonFromPayload(reason: cstring): ConnectionLossReason =
  case $reason
  of "idle-timeout":
    ConnectionLossIdleTimeout
  of "superseded":
    ConnectionLossSuperseded
  else:
    ConnectionLossUnknown

when defined(ctmacos):
  proc registerMenu*(menu: MenuNode) =
    ipc.send("CODETRACER::register-menu", js{menu: menu})
else:
  proc registerMenu*(menu: MenuNode) = discard

proc `or`*(a: MenuNodeOS, b: MenuNodeOS): MenuNodeOS =
  return MenuNodeOS(ord(a) or ord(b))

proc `and`*(a: MenuNodeOS, b: MenuNodeOS): MenuNodeOS =
  return MenuNodeOS(ord(a) and ord(b))

proc defineMenuImpl(node: NimNode): (NimNode, bool) =
  case node.kind:
  of nnkCommand:
    let kindOriginal = node[0]
    let nameNode = node[1]
    var currentParent: MenuNode

    if kindOriginal.repr == "folder"                  or
       kindOriginal.repr == "macexclude_folder"       or
       kindOriginal.repr == "macfolder"               or
       kindOriginal.repr == "hostexclude_folder"      or
       kindOriginal.repr == "hostfolder"              or
       kindOriginal.repr == "mac_and_host_exclude_folder":

      var folderType: MenuNodeOS = MenuNodeOSAny;

      if kindOriginal.repr == "macfolder":
        folderType = folderType or MenuNodeOSMacOs

      if kindOriginal.repr == "macexclude_folder":
        folderType = folderType or MenuNodeOSNonMacOS

      if kindOriginal.repr == "hostfolder":
        folderType = folderType or MenuNodeOSHost

      if kindOriginal.repr == "hostexclude_folder":
        folderType = folderType or MenuNodeOSNonHost

      if kindOriginal.repr == "mac_and_host_exclude_folder":
        folderType = folderType or MenuNodeOSNonHost or MenuNodeOSNonMacOS

      var elementsNode: NimNode = quote do: @[]
      if node.len > 2:
        # One more entry for text labels
        let index = if bool(ord(folderType and MenuNodeOSMacOs)): 3 else: 2
        if node.len > index:
          for element in node[index]:
            let (element, isSeparator) = defineMenuImpl(element)
            if not isSeparator:
              elementsNode[1].add(element)
            else:
              elementsNode[1][^1].add(nnkExprColonExpr.newTree(ident"isBeforeNextSubGroup", newLit(true)))

      let tmpcstr = quote do: cast[cstring]("")
      let roleExpr: NimNode =
        if bool(ord(folderType and MenuNodeOSMacOs)):
          node[2]
        else:
          tmpcstr
      let folderTypeInt = ord(folderType)

      var r = quote:
        MenuNode(
          kind: MenuFolder,
          name: `nameNode`,
          elements: `elementsNode`,
          enabled: true,
          menuOs: `folderTypeInt`,
          role: `roleExpr`
        )
      result = (r, false)
    elif  kindOriginal.repr == "element"              or
          kindOriginal.repr == "macexclude_element"   or
          kindOriginal.repr == "macelement"           or
          kindOriginal.repr == "macrole"              or
          kindOriginal.repr == "hostexclude_element"  or
          kindOriginal.repr == "hostelement"          or
          kindOriginal.repr == "mac_and_host_exclude_element":

      var elementType: MenuNodeOS = MenuNodeOSAny;

      if kindOriginal.repr == "macelement" or kindOriginal.repr == "macrole":
        elementType = elementType or MenuNodeOSMacOs

      if kindOriginal.repr == "macexclude_element":
        elementType = elementType or MenuNodeOSNonMacOS

      if kindOriginal.repr == "hostelement":
        elementType = elementType or MenuNodeOSHost

      if kindOriginal.repr == "hostexclude_element":
        elementType = elementType or MenuNodeOSNonHost

      if kindOriginal.repr == "mac_and_host_exclude_element":
        elementType = elementType or MenuNodeOSNonHost or MenuNodeOSNonMacOS

      let bMacRole: bool = kindOriginal.repr == "macrole"
      if node.len < 3 and not bMacRole:
        macros.error "no action " & node.repr & " "

      # If it's a role, insert a random action. It will not get used anyway
      let actionNode = if not bMacRole: node[2] else: newLit(ClientAction.forwardContinue)
      let last = if node.len == 3 or bMacRole: newLit(true) else: node[^1]
      let elementTypeInt = ord(elementType)

      var r = quote:
        MenuNode(
          kind: MenuElement,
          name: `nameNode`,
          action: `actionNode`,
          elements: @[],
          enabled: `last`,
          menuOs: `elementTypeInt`,
          role: if bool(`bMacRole`): `nameNode` else: cast[cstring]("")
        )
      result = (r, false)
  of nnkPrefix:
    if node.repr == "--sub":
      result = (nil, true)
      return
  else:
    echo "menu: expect command or prefix " & $node.kind

macro defineMenu(code: untyped): untyped =
  ## defineMenu:
  ##   folder "menu":
  ##     element name, action, [enabled=MEnabled] or false or name of check
  ## =>
  ## MenuNode(
  ##   kind: MenuFolder, name: "menu", elements: @[
  ##     MenuNode(kind: MenuElement, name: name, action: action, enabled: true)])
  ##
  ## NOTE: this macro USED to call `registerMenu(m)` inside its
  ## expansion.  That ran BEFORE any runtime post-processing
  ## (launch-config injection, per-language View items), which silently
  ## stripped those dynamic additions on macOS where the application
  ## menu is owned by the OS.  The fix is to keep this macro pure
  ## (just emit the `MenuNode`) and call `registerMenu` once at the END
  ## of `webTechMenu`, after every dynamic mutation has happened.
  let menuNode = defineMenuImpl(code[0])[0]
  result = quote do:
    `menuNode`

proc makeMenuElement(label: cstring, action: ClientAction): MenuNode =
  ## Convenience constructor for a leaf View-menu item.  Mirrors the
  ## `MenuElement` shape produced by `defineMenuImpl` so the dynamic
  ## items round-trip the same way through `getCommands`, the IsoNim
  ## menu component, and the macOS Menu.setApplicationMenu bridge.
  MenuNode(
    kind: MenuElement,
    name: label,
    action: action,
    actionData: nil,
    enabled: true,
    elements: @[],
    isBeforeNextSubGroup: false,
    menuOs: ord(MenuNodeOSAny),
    role: cstring""
  )

proc nimSpecificViewItems(data: Data): seq[MenuNode] =
  ## Per-language View-menu items shown when a Nim trace is loaded.
  ## Wired through `appendLanguageSpecificViewItems` from `webTechMenu`
  ## so the four entries appear in the View folder on every supported
  ## OS (Linux uses the in-app MenuComponent; macOS uses the native
  ## application menu via `registerMenu`).
  result = @[
    makeMenuElement(cstring"View Generated C Source", aViewGeneratedCSource),
    makeMenuElement(cstring"View Disassembly", aViewDisassembly),
    makeMenuElement(cstring"Trace Macro at Cursor", aTraceMacroAtCursor),
    makeMenuElement(cstring"Trace Static Block at Cursor",
      aTraceStaticBlockAtCursor)
  ]

proc effectiveTraceLang(data: Data): Lang =
  ## Resolve the language of the currently loaded trace defensively.
  ##
  ## `data.trace.lang` is the canonical signal, but historically the
  ## importer (storage_and_import.importTrace) classified some rr/ttd
  ## recordings as `LangUnknown` when `meta.paths` did not lead with
  ## a recognisable source file.  Fall back to deriving the language
  ## from the trace's `program` filename extension so the menu still
  ## reflects reality on traces that were recorded before that
  ## upstream classifier fix landed.
  if data.trace.isNil:
    return LangUnknown
  if data.trace.lang != LangUnknown:
    return data.trace.lang
  let program = $data.trace.program
  if program.len == 0:
    return LangUnknown
  let dot = program.rfind('.')
  if dot < 0 or dot == program.len - 1:
    return LangUnknown
  # Keep the extension whitelist minimal — every entry below has a
  # matching `nimSpecificViewItems` / future per-language item set
  # so a wrong fallback never surfaces wrong menu items.
  let ext = program.substr(dot + 1).toLowerAscii()
  case ext
  of "nim": LangNim
  else:     LangUnknown

proc appendLanguageSpecificViewItems(menu: MenuNode, data: Data) =
  ## Append items that depend on `data.trace.lang` (or nothing if no
  ## trace is loaded yet) to the View folder.  Each language registers
  ## its own item set via a small dispatcher; for now only Nim has any.
  ##
  ## We mutate the View folder in place so the resulting MenuNode tree
  ## stays a single source of truth for the IsoNim menu component
  ## (Linux) and the macOS Menu.setApplicationMenu bridge.
  if menu.isNil or seqIsNil(menu.elements):
    return
  let lang = effectiveTraceLang(data)
  let items =
    case lang
    of LangNim: nimSpecificViewItems(data)
    else: @[]
  if items.len == 0:
    return

  proc appendToViewFolder(node: MenuNode): bool =
    if node.isNil or node.kind != MenuFolder:
      return false
    if node.name == cstring"View":
      if seqIsNil(node.elements):
        node.elements = @[]
      for item in items:
        node.elements.add(item)
      return true
    if seqIsNil(node.elements):
      return false
    for child in node.elements:
      if appendToViewFolder(child):
        return true
    false

  discard appendToViewFolder(menu)

proc webTechMenu(data: Data, program: cstring): MenuNode =
  let config = data.config
  if not data.startOptions.shellUi:
    result = defineMenu:
      folder program:
        # Needed for compliance on macOS
        macfolder "CodeTracer", "":
          macrole "about"
          --sub
          macrole "services"
          --sub
          macrole "hide"
          macrole "hideOthers"
          macrole "unhide"
          --sub
          macrole "quit"
        folder "File":
          # element "New File", newTab, false
          # element "Preferences", preferences
          # --sub
          # element "Open File", openFile
          # element "Open Folder", openFolder, false
          # element "Open Recent", openRecent, false
          element "Open Trace...", aOpenTrace
          element "Open Trace in New Tab...", aOpenTraceInNewTab
          element "Record New Trace...", aRecordNewTrace
          element "New Trace Tab", aNewTraceTab
          # --sub
          # element "Save", aSave
          # element "Save As ...", saveAs
          # element "Save All", saveAll
          # --sub
          element "Close Current File", closeTab
          element "Reopen File", reopenTab
          element "Next File", switchTabRight
          element "Previous File", switchTabLeft
          element "Switch File", switchTabHistory
          --sub
          # element "Close All Documents", closeAllDocuments
          mac_and_host_exclude_element "Exit CodeTracer", aExit
        folder "Edit":
          # element "Undo", aUndo, false
          # element "Redo", aRedo, false
          # --sub
          # element "Cut", aCut
          # element "Copy", aCopy
          # element "Paste", aPaste
          # --sub
          # element "Replace", aReplace, false
          # --sub
          element "Find in Files", findInFiles
          element "Find Symbol", findSymbol
          # element "Replace in Files", replaceInFiles, false
          --sub
          # folder "Code folding":
            # element "Collapse under cursor", aCollapseUnderCursor, false
            # element "Expand under cursor", aExpandUnderCursor, false
          element "Expand All", aExpandAll
          element "Collapse All", aCollapseAll
          # --sub
          # folder "Advanced":
          #   element "Toggle Comment", aToggleComment, false
          #   element "Increase Indentation", aIncreaseIndentation, false
          #   element "Decrease Indentation", aDecreaseIndentation, false
          #   element "Make Uppercase", aMakeUppercase, false
          #   element "Make Lowercase", aMakeLowercase, false
          #   #* (Other suitalbe Monaco commands)

            #* (Other suitable Monaco commands)
          # element "Delete", ClientAction.del
        folder "View":
          # folder "Panes":
            # folder "New"
          element "Filesystem", aFilesystem
          element "Calltrace", aFullCalltrace
          element "State", aState
          element "Event Log", aEventLog
          element "Timeline", aTimeline
          element "Terminal Output", aTerminal
          element "Scratchpad", aScratchpad
          element "Agent Activity", aAgentActivity
          # VN-M5. The one reachable surface for verification and for the
          # counterexample it produces. There is deliberately no "Counterexample"
          # entry beside it: a counterexample is a region of this panel that
          # exists only while a session is open, and a standing menu entry for
          # it would promise a walk that usually is not there.
          element "Verification", aVerification
          element "Start Agent Worktree Session", aStartAgenticWorktreeSession
          # element "Step List", aStepList
            # element "Shell", aShell
            # element "Find Results", aFindResults, false
            # element "Build Log", aBuildLog, false
            # element "File Explorer", aFileExplorer, false
          # folder "Layouts":
            # element "Save Layout", aSaveLayout, false
            # element "Load Layout", aLoadLayout, false
            # element "Debug (Normal Screen)", switchDebug
            # element "Debug (Wide Screen)", switchDebugWide, false
            # element "Edit (Normal Screen)", switchEditNormal, false
            # element "Edit (Wide Screen)", switchEdit
            #element "can be also"
            #element "Normal screen"
            #element "Wide screen"
            #element "Debug"
            #element "Edit"
          # element "New Horizontal Tab Group", aNewHorizontalTabGroup, false
          # element "New Vertical Tab Group", aNewVerticalTabGroup, false
          # --sub
          # element "Notifications", aNotifications, false
          # element "Start Window", aStartWindow, false
          # element "Full Screen Toggle", aFullScreen, false
          # folder "Choose App Theme":
            # element "Mac Classic Theme", aTheme0
            # element "Default White Theme", aTheme1
            # element "Default Black Theme", aTheme2
            # element "Default Dark Theme", aTheme3
          # folder "Choose Monaco Theme":
            # element "vs-light", aMonacoTheme0, false
            # element "etc",
          # --sub
          # element "Multi-line Preview Mode", aMultiline, false
          # element "Single-line Preview Mode", aSingleLine, false
          # element "No Preview", aNoPreview, false
          # --sub
          # element "View C Code (here it depends on Lang for project)", aLowLevel0, false
          # element "View Assembly Code (similar: can be llvm ir)", aLowLevel1, false
          # --sub
          # element "Zoom In", zoomIn
          # element "Zoom Out", zoomOut
          # element "Show Minimap", aShowMinimap, false
        # folder "Navigate":
        #   element "Go to File", aGotoFile, false
        #   element "Go to Symbol", aGotoSymbol, false
        #   --sub
        #   element "Go to Definition", aGotoDefinition, false
        #   element "Find References", aFindReferences, false
        #   element "Go to Line", aGotoLine, false
        #   --sub
        #   element "Go to Previous Cursor Location", aGotoPreviousCursorLocation, false
        #   element "Go to Next Cursor Location", aGotoNextCursorLocation, false
        #   --sub
        #   element "Go to Previous Edit Location", aGotoPrevious, false
        #   element "Go to Next Edit Location", aGotoNextEditLocation, false
        #   --sub
        #   element "Go to Previous Point in Time", aGotoPreviousPointInTime, false
        #   element "Go to Next Point in Time", aGotoNextPointInTime, false
        #   --sub
        #   element "Go to Next Error", aGotoNextError, false
        #   element "Go to Previous Error", aGotoPreviousError, false
        #   --sub
        #   element "Go to Next Search Result", aGotoNextSearchResult, false
        #   element "Go to Previous Search Result", aGotoPreviousSearchResult, false

        folder "Build":
          element "Rebuild/Re-record file", aReRecord, true
          element "Rebuild/Re-record project", aReRecordProject, true
          --sub
          # The chord beside each label comes for free: `menu.nim:424` fills
          # `MenuNodeRecord.shortcut` from `loadShortcut`, which reads
          # `config.shortcutMap.actionShortcuts` — i.e. the config table only.
          # That is exactly why these two bindings went in
          # `default_config.yaml` and not into `ui/shortcuts.nim`'s hard-bound
          # block: a hard-bound chord cannot be displayed here by
          # construction, and cannot be rebound by the user.
          element "Go to Next Error", aGotoNextError, true
          element "Go to Previous Error", aGotoPreviousError, true
        #   element "Build Project", aBuild, false
        #   element "Compile Current File (Nim Check)", aCompile, false
        #   element "Run Static Analysis (drnim)", aRunStatic, false
        #   # element "Build tasks (nimble)", nil, false

        # TODO:
        folder "Reset":
          element "Restart replay-server", aRestartDbBackend, true
          element "Restart session-manager", aRestartBackendManager, true

        folder "Debug":
          # element "Trace Existing Program...", aTrace, false
          # element "Load Existing Trace...", aLoadTrace, false
          # folder "Panes":
          #   folder "New":
          #     element "Program state explorer", aNewState, false
          #     element "Event log", aNewEventLog, false
          #     element "Full call trace", aNewFullCalltrace, false
          #     element "Terminal output", aNewTerminal, false
          #   element "Breakpoints/Tracepoints", aPointList, false
          #   element "Mixed call/stack trace", aLocalCalltrace, false
          #   element "Full call trace", aFullCalltrace, false
          #   element "Program state explorer", aState, false
          #   element "Event log", aEventLog
          #   element "Terminal output", aTerminal, false
          # element "Options", aOptions, false
          # --sub
          # element "Start Debugging", aDebug, false
          element "Continue", forwardContinue
          element "Step Over", forwardNext
          element "Step In", forwardStep
          element "Step Out", forwardStepOut
          element "Reverse Continue", reverseContinue
          element "Reverse Step Over", reverseNext
          element "Reverse Step In", reverseStep
          element "Reverse Step Out", reverseStepOut
          # element "Stop Debugging", stop
          # TODO dynamic name
          # element "Pause (currently using stop shortcut?)", stop, false
          --sub
          element "Add a Breakpoint", aBreakpoint
          element "Delete Breakpoint", aDeleteBreakpoint
          element "Delete All Breakpoints", aDeleteAllBreakpoints
          element "Enable Breakpoint", aEnableBreakpoint
          element "Enable All Breakpoints", aEnableAllBreakpoint
          element "Disable Breakpoint", aDisableBreakpoint
          element "Disable All Breakpoints", aDisableAllBreakpoints
          --sub
          element "Add a Tracepoint", aTracepoint
          element "Delete Tracepoint", aDeleteTracepoint
          element "Enable Tracepoint", aEnableTracepoint
          element "Enable All Tracepoints", aEnableAllTracepoints
          element "Disable Tracepoint", aDisableTracepoint
          element "Disable All Tracepoints", aDisableAllTracepoints
          element "Run All Tracepoints", aCollectEnabledTracepointResults
          --sub
          element "Invite to Collaborative Session...", aCollabInvite

        # The standard macOS Window menu
        macfolder "Window", "window"
        # TODO: Add this for other OS targets and add missing buttons. Added only on macOS for now, as there the menu is
        # generated automatically
        macfolder "Help", "help"

    # Add dynamic launch configurations to Debug menu if available
    if not seqIsNil(data.ui.launchConfigs) and data.ui.launchConfigs.len > 0:
      let topLevelMenuNodes =
        if seqIsNil(result.elements): @[] else: result.elements
      for element in topLevelMenuNodes:
        if element.kind == MenuFolder and element.name == cstring"Debug":
          if seqIsNil(element.elements):
            element.elements = @[]
          var launchFolder = MenuNode(
            kind: MenuFolder,
            name: cstring"Launch Configurations",
            enabled: true,
            elements: @[],
            isBeforeNextSubGroup: true,
            menuOs: 0,
            role: cstring""
          )
          for i, config in data.ui.launchConfigs:
            launchFolder.elements.add(MenuNode(
              kind: MenuElement,
              name: config.name,
              action: aRecordFromLaunch,
              actionData: js{configIndex: i},
              enabled: true,
              elements: @[],
              isBeforeNextSubGroup: false,
              menuOs: 0,
              role: cstring""
            ))
          # Insert at the beginning of the Debug menu
          element.elements.insert(launchFolder, 0)
          break

    # Inject language-specific View-menu items AFTER any other dynamic
    # mutation (currently: launch configs).  Doing this before the
    # macOS `registerMenu` call below is critical: macOS owns the
    # application menu, and any items not present at registration time
    # silently never appear in the OS menu bar.
    appendLanguageSpecificViewItems(result, data)
  else:
    result = defineMenu:
      folder program:
        macfolder "CodeTracer", "":
          macrole "about"
          --sub
          macrole "services"
          --sub
          macrole "hide"
          macrole "hideOthers"
          macrole "unhide"
          --sub
          macrole "quit"
        # element "New Terminal", aTheme0, false
        folder "Themes":
          element "Mac Classic Theme", aTheme0
          element "Default White Theme", aTheme1
          element "Default Black Theme", aTheme2
          element "Default Dark Theme", aTheme3

        # The standard macOS Window menu
        macfolder "Window", "window":
          macrole "minimize"
          macrole "zoom"
          --sub
          macrole "front"
          --sub
          macrole "window"
        # TODO: Add this for other OS targets and add missing buttons. Added only on macOS for now, as there the menu is
        # generated automatically
        macfolder "Help", "help"
        macexclude_element "Exit CodeTracer", aExit, true

  # Register the (possibly mutated) menu with the macOS native menu
  # bar.  Previously `defineMenu`'s macro expansion did this BEFORE
  # any runtime injection ran, which meant launch configs and the new
  # per-language View items never reached macOS users.  See the
  # comment on `defineMenu` for the rationale.
  when defined(ctmacos):
    registerMenu(result)


proc update*(self: Data, build: bool = false) =
  if build:
    let buildComponent = data.buildComponent(0)
    buildComponent.builds.add(buildComponent.build)
    buildComponent.build = Build(output: @[], running: true, autoScroll: true, buildStartTime: dateNowMs())
    data.saveFiles()
  else:
    let activePath = self.services.editor.active
    if not activePath.isNil and activePath.len > 0:
      console.log(cstring(fmt"[ui] saving active editor path: {activePath}"))
      data.saveFiles(activePath)
    else:
      console.log(cstring"[ui] skip saveFiles — no active editor")
  if build:
    data.services.calltrace.restart()
    data.services.eventLog.restart()
    data.services.debugger.restart()
    data.services.flow.restart()
    data.services.history.restart()
    # maybe not? we want the files there data.services.editor
    for content, map in data.ui.componentMapping:
      for id, component in map:
        component.restart()

  # TODO : are undefined/null cstrings handled as cstring"" in the javascript backend?
  # there are a possible edge case, good to be handled as an empty cstring
  # is active focus ok in general?
  # document with active
  var currentPath = cstring""
  if not self.services.editor.active.isNil:
    currentPath = self.services.editor.active
  elif not self.ui.activeFocus.isNil:
    let focusPath = self.ui.activeFocus.toJs.path
    if not focusPath.isNil:
      currentPath = cast[cstring](focusPath)

  console.log(cstring(fmt"[ui] sending CODETRACER::update (build={build}) for path: {currentPath}"))
  ipc.send "CODETRACER::update", js{build: build, currentPath: currentPath}
  redrawAll()

# alt+1 => low level view source 1
# alt+2/alt+i => low level view source2 / instructions for now
# alt+a => low level ast view
# alt+c => low level cfg view
# they all share the same window, but they are displayed in the order in which they are toggled

proc setEditorsEditable*(data: Data, editable: bool) =
  ## Update Monaco editors to match requested editability.
  ##
  ## A review opened from a dataset is the one state that never becomes
  ## editable, whichever way the read-only flag is driven (`toggleReadOnly`,
  ## the edit/debug mode switch).  DeepReview-GUI.md §5.1 requires the review
  ## representation to stay read-only, and such a tab has no writable target to
  ## begin with: its text is the dataset's snapshot of the reviewed commit
  ## (`index/config.reviewSourceLookup`) and its name is the dataset's
  ## repo-relative path, so a save would land under whatever directory
  ## `ct review` was launched from — silently overwriting an unrelated file
  ## that happens to sit at the same relative path.
  let reallyEditable = editable and not data.isReviewDatasetSession()
  for label, editor in data.ui.editors:
    if editor.monacoEditor.isNil:
      continue
    let minimapEnabled =
      if reallyEditable: data.config.showMinimap
      else: false
    let options = MonacoEditorOptions(
      readOnly: not reallyEditable,
      minimap: js{ enabled: minimapEnabled }
    )
    editor.monacoEditor.updateOptions(options)
    editor.updateLineNumbersOnly()

const editModeAuxiliaryContents = [
  Content.State,
  Content.Scratchpad,
  Content.Repl,
  Content.EventLog,
  Content.TerminalOutput,
  Content.StepList,
  Content.Calltrace
]

proc closeAuxiliaryPanels(data: Data) =
  ## Close side panels that should disappear while edit mode is active.

  if data.ui.editModeHiddenPanels.len > 0:
    return
  if not data.ui.layout.isNil and data.ui.savedLayoutBeforeEdit.isNil:
    let snapshot = data.ui.layout.saveLayout()
    # Clone the resolved config so later layout mutations don't modify our snapshot.
    let snapshotCopy = cast[GoldenLayoutResolvedConfig](JSON.parse(JSON.stringify(snapshot)))
    data.ui.savedLayoutBeforeEdit = snapshotCopy
  for content in editModeAuxiliaryContents:
    var idsToClose: seq[int] = @[]
    for id, component in data.ui.componentMapping[content]:
      if component.isNil or component.layoutItem.isNil:
        continue
      idsToClose.add(id)
    for id in idsToClose:
      if not data.ui.componentMapping[content].hasKey(id):
        continue
      let component = data.ui.componentMapping[content][id]
      let layoutItem = component.layoutItem
      if component.isNil or layoutItem.isNil:
        continue
      let parent = layoutItem.parent
      if parent.isNil:
        continue
      var insertIdx = parent.contentItems.len
      for index, item in parent.contentItems:
        if item == layoutItem:
          insertIdx = index
          break
      let config = cast[GoldenLayoutResolvedConfig](JSON.parse(JSON.stringify(layoutItem.toConfig())))
      data.ui.editModeHiddenPanels.add(EditModeHiddenPanel(
        content: content,
        id: id,
        parent: parent,
        index: insertIdx,
        config: config
      ))
      try:
        layoutItem.remove()
      except:
        cwarn fmt"edit-mode: failed to close {$content} layout tab {id}: {getCurrentExceptionMsg()}"
      component.layoutItem = nil

proc reopenAuxiliaryPanels(data: Data) =
  ## Re-open panels closed while edit mode was active.

  if data.ui.editModeHiddenPanels.len == 0:
    data.ui.savedLayoutBeforeEdit = nil
    return

  if not data.ui.savedLayoutBeforeEdit.isNil and not data.ui.layout.isNil:
    for panel in data.ui.editModeHiddenPanels:
      if not data.ui.componentMapping[panel.content].hasKey(panel.id):
        console.log("Key missing!")
        discard data.makeComponent(panel.content, panel.id)
    try:
      data.ui.layout.loadLayout(data.ui.savedLayoutBeforeEdit)
      data.ui.resolvedConfig = data.ui.savedLayoutBeforeEdit
      data.ui.editModeHiddenPanels.setLen(0)
      data.ui.savedLayoutBeforeEdit = nil
      return
    except:
      cerror fmt"edit-mode: failed to reload saved layout: {getCurrentExceptionMsg()}"

  for panel in data.ui.editModeHiddenPanels:
    if not data.ui.componentMapping[panel.content].hasKey(panel.id):
      discard data.makeComponent(panel.content, panel.id)
    try:
      data.openLayoutTab(panel.content, id = panel.id)
    except:
      cwarn fmt"edit-mode: failed to reopen {$panel.content} layout tab with id {panel.id}: {getCurrentExceptionMsg()}"
  data.ui.editModeHiddenPanels.setLen(0)
  data.ui.savedLayoutBeforeEdit = nil

proc setEditorsReadOnlyState(data: Data, readOnly: bool) =
  ## Keep Monaco editor options and context keys aligned with the requested read-only flag.
  if data.ui.readOnly == readOnly:
    if data.ui.mode == EditMode and not readOnly:
      data.closeAuxiliaryPanels()
    return
  data.ui.readOnly = readOnly
  if readOnly:
    data.reopenAuxiliaryPanels()
  else:
    data.closeAuxiliaryPanels()
  for _, editor in data.ui.editors:
    if editor.isNil:
      continue
    if readOnly:
      editor.enableDebugShortcuts()
    else:
      editor.disableDebugShortcuts()
  data.setEditorsEditable(not readOnly)

proc switchToEdit*(data: Data) =
  if data.ui.mode != EditMode:
    data.ui.mode = EditMode

    # Save current debug layout before switching
    if not data.ui.layout.isNil:
      let currentLayout = data.ui.layout.saveLayout()
      data.ui.savedLayoutBeforeEdit = cast[GoldenLayoutResolvedConfig](
        JSON.parse(JSON.stringify(currentLayout)))

    # Restore edit layout if we have one saved
    if not data.ui.lastUsedEditLayout.isNil and not data.ui.layout.isNil:
      try:
        data.ui.layout.loadLayout(data.ui.lastUsedEditLayout)
        data.ui.resolvedConfig = data.ui.lastUsedEditLayout
      except:
        cerror fmt"edit-mode: failed to restore edit layout: {getCurrentExceptionMsg()}"

    for content, map in data.ui.componentMapping:
      for id, component in map:
        try:
          component.clear()
        except:
          cerror "layout: component clear: " & getCurrentExceptionMsg()
  data.setEditorsReadOnlyState(false)
  redrawAfterModeSwitch()

proc switchToDebug*(data: Data) =
  # Save current edit layout before switching
  if data.ui.mode == EditMode and not data.ui.layout.isNil:
    let currentLayout = data.ui.layout.saveLayout()
    data.ui.lastUsedEditLayout = cast[GoldenLayoutResolvedConfig](
      JSON.parse(JSON.stringify(currentLayout)))

  if data.ui.mode != DebugMode:
    data.ui.mode = DebugMode

    # Restore debug layout if we saved it before
    if not data.ui.savedLayoutBeforeEdit.isNil and not data.ui.layout.isNil:
      try:
        data.ui.layout.loadLayout(data.ui.savedLayoutBeforeEdit)
        data.ui.resolvedConfig = data.ui.savedLayoutBeforeEdit
        data.ui.savedLayoutBeforeEdit = nil
      except:
        cerror fmt"debug-mode: failed to restore debug layout: {getCurrentExceptionMsg()}"

  data.setEditorsReadOnlyState(true)
  redrawAfterModeSwitch()

proc toggleMode*(data: Data) =
  if data.ui.mode == DebugMode:
    data.switchToEdit()
  else:
    data.switchToDebug()

proc toggleReadOnly*(data: Data) =
  ## Toggle Monaco read-only state and accompanying panels without forcing a full layout toggle.
  let goingReadOnly = not data.ui.readOnly
  data.setEditorsReadOnlyState(goingReadOnly)
  if goingReadOnly:
    data.ui.mode = DebugMode
  else:
    data.ui.mode = EditMode
  redrawAfterModeSwitch()

data.functions.toggleMode = toggleMode
data.functions.toggleReadOnly = toggleReadOnly
data.functions.update = update
data.functions.switchToEdit = switchToEdit
data.functions.switchToDebug = switchToDebug
data.functions.focusEventLog = focusEventLog
data.functions.focusCalltrace = focusCalltrace
data.functions.focusEditorView = focusEditorView


proc configure(data: Data) =
  # macOS keeps its native traffic-light buttons and paints them over the top
  # left of the web contents (`titleBarStyle: hidden`, `index/window.nim`), so
  # the caption bar must start clear of them.  Marked here, at startup, rather
  # than only when the menu shell renders: the session tab bar is rendered into
  # `#menu` by `ui/session_tabs.nim` independently of the shell, and on the
  # welcome screen it is the only thing there — it would sit under the buttons
  # while waiting for a shell render that never comes.
  when defined(ctmacos):
    # Reserve room for the traffic-light buttons the OS paints over the caption
    # bar, and follow the window in and out of fullscreen, where they vanish.
    applyCaptionBarWindowMode()
    let fullscreenIpc = data.ipc
    fullscreenIpc["on"].call(
        fullscreenIpc, cstring"CODETRACER::window-fullscreen-changed") do (
        sender: js, response: js):
      setCaptionBarFullscreen(response["fullscreen"].to(bool))

  # Hot module reload — only active when the binary was built with
  # `-d:ctHmr`. The renderer connects to the external LiveReload
  # daemon that `just build` started; `CT_HMR=0` opts out per
  # launch. The bundleUrl is the same relative URL the document's
  # initial `<script>` tag used; the transport resolves it to a
  # file:// path for inline-script bundle reload.
  when defined(ctHmr):
    discard installCtHmrTransport(bundleUrl = cstring"ui.js")

  Mousetrap.`bind`("ctrl+f5") do ():
    data.toggleMode()

  Mousetrap.`bind`("ctrl+e") do ():
    data.toggleReadOnly()

  Mousetrap.`bind`("ctrl+s") do ():
    data.update()

  Mousetrap.`bind`("alt+1") do ():
    data.openLowLevelCode()

  # Mousetrap.`bind`("alt+2") do ():
  #   data.openAlternativeView(2)

  domwindow.onresize = proc(e: js) =
    if not data.isNil and not data.ui.isNil and not data.ui.layout.isNil:
      data.ui.layout.updateSize()

  # AA-2 — drilling from a `ct test` result in the Agent Activity session feed
  # into the recording of that test.
  #
  # DeepReview-GUI.md §2.1.2 requires "the existing trace-opening path and tab
  # model, honouring the `--open-policy` distinction between replacing the
  # current tab and opening a new one", so the service is assembled from the
  # two pieces that already implement it and nothing else:
  #
  #   * `createNewSession(data)` — the same call `onOpenTraceInTabReady` makes
  #     for the "tab" newTracePolicy, i.e. the new-tab half of the policy;
  #   * `CODETRACER::load-trace-file` — the existing open-a-trace-by-path IPC
  #     (`index/traces.onLoadTraceFile`), which also owns the "no trace
  #     registered at that path" answer.  §2.1.2 would rather the panel say so
  #     than open a broken tab, and that handler already replies
  #     `CODETRACER::trace-load-error` instead of creating one.
  #
  # `TraceOpenRequest.tracePath` is the recording's output *directory*, which
  # is what every `ct test` provider reports as `TraceMetadata.path`.
  #
  # Installed here rather than beside the other panel-VM wiring in
  # `configureMiddleware`: that routine runs only from `onTraceLoaded` and
  # `onNoTrace` — the handlers for `CODETRACER::trace-loaded` and
  # `CODETRACER::no-trace` — and a `ct review` dataset launch reaches neither
  # (`index/startup.nim` sends `CODETRACER::start-deepreview` and returns),
  # so a review —
  # the one mode this feature exists for — got a panel with no trace-opening
  # service at all.  `configure` runs once per renderer in every launch mode.
  agent_activity.installAgentActivityTraceOpenService(
    TraceOpenService(openProc: proc(request: TraceOpenRequest) =
      if request.policy == topNewTab:
        createNewSession(data)
      data.ipc.send cstring"CODETRACER::load-trace-file",
        js{tracePath: cstring(request.tracePath)}))

  # AA-3 — reading the review dataset an evidence tool call produced, so the
  # session feed can name its shape and enter a review over it
  # (DeepReview-GUI.md §2.1.1).
  #
  # The renderer cannot read files, so this is the request half of a round
  # trip whose answer arrives as `CODETRACER::review-dataset-read` and is
  # handled by `onReviewDatasetRead`.  The *read* on the other side is
  # `index/review_dataset.readReviewDatasetFile` — the same one
  # `index/args.nim`'s `--deepreview` branch performs for
  # `ct review <PATH>` — and entering the review is
  # `vcs.openReviewDataset`, which publishes the dataset where every launch
  # path publishes it and calls the one host entry point.  Nothing here is a
  # second way to open a review.
  #
  # Installed beside AA-2's service, in `configure`, and for the same
  # measured reason: `configureMiddleware` runs only from `onTraceLoaded` and
  # `onNoTrace`, and a `ct review` dataset launch reaches neither
  # (`index/startup.nim` sends `CODETRACER::start-deepreview` and returns).
  # A review is the one mode this feature exists for, so wiring placed there
  # would be a silent no-op exactly where it is needed.  `configure` runs
  # once per renderer in every launch mode.
  agent_activity.installAgentActivityReviewOpenService(
    ReviewOpenService(requestProc: proc(request: ReviewDatasetRequest) =
      data.ipc.send cstring"CODETRACER::open-review-dataset",
        js{
          anchorId: cstring(request.anchorId),
          datasetPath: cstring(request.datasetPath),
          kind: cstring($request.kind)
        }))

proc loadShortcut*(action: ClientAction, config: Config): cstring =
  # load a shortcut for this node from config
  # if we update config it should effect it
  result = cstring""
  for index, shortcutValue in config.shortcutMap.actionShortcuts[action]:
    if index == 0:
      result = result & shortcutValue.renderer.toUpperCase()
    else:
      result = result & cstring" " & shortcutValue.renderer.toUpperCase()

proc menuNodeChildren(node: MenuNode): seq[MenuNode] =
  if node.isNil or seqIsNil(node.elements):
    @[]
  else:
    node.elements

proc getCommand(node: MenuNode, names: var JsAssoc[cstring, Command], parent: Command = nil) =
  if node.isNil or not node.enabled:
    return

  let children = menuNodeChildren(node)
  if children.len == 0:

    # add node as a subcommand to its parent if it  has one
    if not parent.isNil:
      if not names.hasKey(parent.name):
        names[parent.name] = parent
      names[parent.name].subcommands.add(node.name)

    # add node as a command in commands collection
    if not names.hasKey(node.name):
      names[node.name] = Command(
        name: node.name,
        kind: ActionCommand,
        action: node.action,
        shortcut: loadShortcut(node.action, data.config))

  else:
    # create a parent command from parent
    let parent = Command(
      name: node.name,
      kind: ParentCommand,
      subcommands: @[])

    # get commands of parent children
    for node in children:
      node.getCommand(names, parent)

proc getCommands(node: MenuNode): JsAssoc[cstring, Command] =
  var names = JsAssoc[cstring, Command]{}
  node.getCommand(names)
  return names

proc refreshCommandPaletteMenuIndex*(data: Data) =
  if data.isNil or data.ui.isNil or data.ui.menuNode.isNil:
    return
  if data.ui.commandPalette.isNil or data.ui.commandPalette.interpreter.isNil:
    return

  data.ui.commandPalette.interpreter.commands = getCommands(data.ui.menuNode)
  data.ui.commandPalette.interpreter.commandsPrepared = @[]
  for key, command in data.ui.commandPalette.interpreter.commands:
    data.ui.commandPalette.interpreter.commandsPrepared.add(
      fuzzysort.prepare(key))

proc collectFilesystemFilePaths(node: CodetracerFile, acc: var seq[cstring]) =
  ## Walk a loaded filesystem tree and collect the paths of leaf files.
  if node.isNil:
    return
  if node.children.len == 0:
    # Leaf node — a file (folders always have children, or are empty
    # roots).  Use the original path; skip synthetic group nodes whose
    # path is blank (e.g. the "source folders" root).
    let p = node.original.path
    if p.len > 0:
      acc.add(p)
  else:
    for child in node.children:
      collectFilesystemFilePaths(child, acc)

proc refreshCommandPaletteFileIndex*(data: Data) =
  if data.isNil or data.ui.isNil:
    return
  if data.ui.commandPalette.isNil or data.ui.commandPalette.interpreter.isNil:
    return

  data.ui.commandPalette.interpreter.files = JsAssoc[cstring, cstring]{}
  data.ui.commandPalette.interpreter.filesPrepared = @[]

  proc addPath(path: cstring) =
    if path.len == 0:
      return
    if data.ui.commandPalette.interpreter.files.hasKey(path):
      return
    data.ui.commandPalette.interpreter.files[path] = path
    data.ui.commandPalette.interpreter.filesPrepared.add(
      fuzzysort.prepare(path))

  # Primary source: the debugger's filename list (sent by the backend
  # via the `filenames` event).  Some DB-trace backends (e.g. the Noir
  # materialized path) do not emit that event, so also harvest the file
  # paths from the loaded filesystem tree — the same tree the Files
  # panel renders — so Ctrl+P file search works for those traces too.
  for path in data.services.debugger.paths:
    addPath(path)
  if not data.services.editor.isNil and not data.services.editor.filesystem.isNil:
    var fsPaths: seq[cstring] = @[]
    collectFilesystemFilePaths(data.services.editor.filesystem, fsPaths)
    for path in fsPaths:
      addPath(path)

proc followMouse(event: dom.Event) =
  # dont support ancient IE
  var ev = event
  if ev == nil:
    ev = dom.window.event
  # data.mouseCoords = (ev.pageX, ev.pageY)
  # dom.document.toJs.body.classList.remove(cstring"global-no-cursor")
  # if TELEMETRY_ENABLED:
  #   telemetryBackupIndex += 1
  #   if telemetryBackupIndex == 10:
  #   #  updateTelemetryLog()
  #    telemetryBackupIndex = 0

proc resolvedConfigToJsonNode(config: GoldenLayoutResolvedConfig): JsonNode =
  ## Bridge between the JS-side GoldenLayout config object and Nim's parsed
  ## ``JsonNode`` tree so the pure helpers in ``visual_replay_layout`` can
  ## operate on it.  Returns ``nil`` if the config is missing or unparsable.
  if config.isNil:
    return nil
  let raw = $cast[cstring](JSON.stringify(config))
  if raw.len == 0:
    return nil
  try:
    parseJson(raw)
  except CatchableError:
    nil

proc jsonNodeToResolvedConfig(node: JsonNode): GoldenLayoutResolvedConfig =
  ## Inverse of ``resolvedConfigToJsonNode`` — round-trips a Nim ``JsonNode``
  ## back into the JS object shape GoldenLayout expects.
  if node.isNil:
    return nil
  cast[GoldenLayoutResolvedConfig](JSON.parse(cstring($node)))

proc applyVisualReplayTabsToResolvedConfig*(data: Data) =
  ## Wire the additive walker into the trace-load path.  When the freshly
  ## loaded trace exposes visual-replay artefacts, the Video Player /
  ## Pixel History / Shader Debug tabs are inserted into the user's existing
  ## layout (either the pre-trace welcome layout already in
  ## ``data.ui.resolvedConfig`` or, when a layout is already live, the
  ## currently-rendered tree).  When the trace lacks artefacts but the
  ## previous trace had them mounted, the tabs are pruned again.
  ##
  ## Idempotent on repeat invocation — both ``addVisualReplayTabs`` and
  ## ``removeVisualReplayTabs`` are no-ops when there is nothing to do.
  let visualAvailable = not data.activeSession.isNil and
    data.activeSession.visualReplayAvailable
  let layoutLive = not data.ui.layout.isNil

  var sourceConfig =
    if layoutLive:
      try:
        data.ui.layout.saveLayout()
      except CatchableError:
        data.ui.resolvedConfig
    else:
      data.ui.resolvedConfig

  let layoutNode = resolvedConfigToJsonNode(sourceConfig)
  if layoutNode.isNil:
    return

  let updated =
    if visualAvailable:
      addVisualReplayTabs(layoutNode)
    else:
      removeVisualReplayTabs(layoutNode)

  let newConfig = jsonNodeToResolvedConfig(updated)
  if newConfig.isNil:
    return
  data.ui.resolvedConfig = newConfig

  if layoutLive:
    try:
      data.ui.layout.loadLayout(newConfig)
    except CatchableError:
      cerror "applyVisualReplayTabsToResolvedConfig: loadLayout failed: " &
        getCurrentExceptionMsg()

proc callInitLayoutUnchecked(config: GoldenLayoutResolvedConfig) =
  initLayout(config)

proc tryInitLayout*(data: Data) =
  ## Mount the GoldenLayout tree once both the page and the init event are in.
  ##
  ## `initLayout` reaches into GoldenLayout, which throws *native* JavaScript
  ## `Error`s that Nim's `except` does not catch — so a single bad saved layout
  ## aborted this proc half-way and `redrawAll()` below never ran, leaving a
  ## blank window with nothing in the log.  The guard therefore has to be
  ## written in raw JS, the same way `ui/session_switch.nim` does it.
  if data.ui.pageLoaded and data.ui.initEventReceived:
    if data.ui.layout.isNil:
      var ok = false
      {.emit: """
        try {
          `callInitLayoutUnchecked`(`data`.ui.resolvedConfig);
          `ok` = true;
        } catch (e) {
          console.error("ui_js: initLayout failed: " +
            (e && e.message ? e.message : String(e)));
        }
      """.}
      if not ok:
        cerror "ui_js: layout initialisation failed; see the console"
        # A blank window with only a console line is exactly the class of
        # silent failure this pass is removing.  The notification host is
        # rendered outside the GoldenLayout tree, so it survives this.
        try:
          data.viewsApi.errorMessage(cstring(
            "The saved panel layout could not be restored. " &
            "Reset it from the View menu if the window stays empty."))
        except:
          cerror "ui_js: could not report the layout failure: " &
            getCurrentExceptionMsg()
    redrawAll()

    # DeepReview-GUI.md §7, "Transition into a Review", step 2: "The first
    # modified file opens in the editor with unified diff view."
    #
    # It happens here rather than in `onStartDeepReview` because opening a tab
    # needs a mounted GoldenLayout, and `CODETRACER::start-deepreview` can
    # arrive before the document finishes loading — in which case the tree is
    # only built on the later `onReady` pass through this proc.
    # `startDeepReviewNavigation` is a one-shot, so a review opens its first
    # file exactly once however many times the layout is initialised.
    if data.deepReviewActive and not data.ui.layout.isNil:
      vcs.startDeepReviewNavigation(data)

# In both these `on` functions, we must communicate them to the ui

# We receive a DAP "Response" from the index process
proc onDapReceiveResponse*(sender: JsObject, raw: JsObject) =
  # M8: Extract sessionId from the message for future multi-session routing.
  # During M8 there is only one session, so we log but do not route.
  let sessionId = getSessionIdFromMessage(raw)
  # M49 — settle the `asyncSendCtRequest` continuation waiting on this
  # request's `seq` first. This is what makes `BackendService.send`
  # resolve with the response the backend actually sent; before it, the
  # future was resolved with an empty object at send time and every
  # ViewModel that read a body got `{}`.
  #
  # It runs *before* the `receiveResponse` fan-out and outside its
  # try/except on purpose: the fan-out is keyed on
  # `commandToCtResponseEventKind`, which raises for any command with
  # no `*Response` CtEventKind — `ct/event-load` among them — and that
  # must not swallow the continuation for a command the fan-out has no
  # mapping for. The two paths are independent: legacy subscribers keep
  # receiving exactly what they received before.
  #
  # The continuation is settled on the `DapApi` that *sent* the request,
  # which is not necessarily `data.dapApi`. Every replay session owns its
  # own `DapApi` with its own `seq` counter, while `data.dapApi` forwards
  # to whichever session is on screen; a user with a second tab open
  # would otherwise leave the first tab's continuations unclaimed until
  # their liveness timeout, and — since the counters both start at zero —
  # risk handing a response to an identically numbered request in the
  # wrong session. The main process already tags every response with the
  # session that issued it (`ipc_subsystems/dap.nim::resolveSessionId`),
  # so the owner is known without any new wire field.
  var responseDap = data.dapApi
  for session in data.sessions:
    if not session.dapApi.isNil and session.dapApi.sessionId == sessionId:
      responseDap = session.dapApi
      break
  resolvePendingDapResponse(responseDap, raw)
  try:
    receiveResponse(data.dapApi, raw["command"].to(cstring), raw["body"])
  except ValueError:
    console.log(cstring"dap: ignoring response for unmapped command: ", raw["command"])

# We receive a DAP "Event" from the index process
proc onDapReceiveEvent*(sender: JsObject, raw: JsObject) =
  # M8: Extract sessionId from the message for future multi-session routing.
  let sessionId = getSessionIdFromMessage(raw)
  try:
    receiveEvent(data.dapApi, raw["event"].to(cstring), raw["body"])
  except ValueError:
    console.log(cstring"dap: ignoring event for unmapped event type: ", raw["event"])

proc onReady(event: dom.Event) =
  if cast[cstring](cast[js](dom.document).readyState) == cstring"complete":
    data.ui.pageLoaded = true
    data.tryInitLayout()
    cast[js](dom.document).onmousemove = followMouse

    # Track whether focus was triggered by mouse or keyboard so that CSS can
    # suppress the focus ring on click even for text inputs (which always match
    # :focus-visible in Chromium). Sets data-focus-mode="mouse" on <html> on any
    # mousedown, and "keyboard" when Tab is pressed.
    {.emit: """
      document.documentElement.addEventListener('mousedown', function() {
        document.documentElement.setAttribute('data-focus-mode', 'mouse');
      }, true);
      document.documentElement.addEventListener('keydown', function(e) {
        if (e.key === 'Tab') {
          document.documentElement.setAttribute('data-focus-mode', 'keyboard');
        }
      }, true);
    """.}

    # jqueryFind("body").toJs.on(cstring"click", onGlobalClick)

    discard windowsetInterval(proc =
      if not data.services.editor.active.isNil:
        if data.services.editor.changeLine:
          gotoLine(data.services.editor.currentLine, change=true)

        if data.lowAsm() and scrollAssembly != -1:
          let index = scrollAssembly
          scrollAssembly = -1
          jq(".low-level").toJs.scrollTop = cast[int](jqall(".assembly-offset")[index].toJs.offsetTop) - 300, 500)

      # TODO different debug?

      # TODO next few lines are for live notifications/warnings in the app
      # let debugComponent = data.debugComponent
      # if debugComponent.message.message.len > 0 and
      #   delta(now(), debugComponent.message.time) > 5_000:
      #     debugComponent.message.message = ""
      #     redrawAll()

proc sleepMs(ms: int): Future[void] {.importjs: "new Promise(resolve => setTimeout(resolve, #))".}

proc waitForLayoutGround(data: Data): Future[bool] {.async.} =
  ## Wait until GoldenLayout has a ground item with something in it, and SAY
  ## WHETHER IT DID.
  ##
  ## ## Why this returns a value now
  ##
  ## It used to return `void` after at most 50 × 20 ms, and a caller could not
  ## tell "the layout is ready" from "one second elapsed". `onNoTrace`'s
  ## `openTab` ran either way, and against a layout that had not arrived it
  ## reached `utils.openNewLayoutContainer`'s `data.ui.layout.groundItem` —
  ## measured on the first load of a freshly deployed `ide.codetracer.com/noir`
  ## as an uncaught `TypeError: Cannot read properties of null (reading
  ## 'groundItem')`, with the editor pane simply absent from a screen whose
  ## other four panes were correct. Three later loads of the same URL were
  ## clean, which is the signature of a budget rather than a bug in the layout.
  ##
  ## ## Why the budget is five seconds and not one
  ##
  ## One second is a guess about how long GoldenLayout takes to mount a tree,
  ## and on a warm cache it is a generous one. A COLD one is a different
  ## machine: the first visitor after a deploy fetches a 13 MB third-party
  ## bundle and a 14 MB renderer before any of this runs, and the browser is
  ## still parsing them. Five seconds is still a bound — this cannot hang —
  ## but it is a bound on a slow first load rather than on a fast repeat one.
  ##
  ## Timing out is now a REPORTED failure rather than a silent fall-through;
  ## see the call site.
  for _ in 0 ..< 250:
    if not data.ui.layout.isNil and not data.ui.layout.groundItem.isNil and
        data.ui.layout.groundItem.contentItems.len > 0:
      return true
    await sleepMs(20)
  return false

proc onInit*(
    sender: js,
    response: jsobject(
      time=BiggestInt,
      config=Config,
      layout=js,
      home=cstring,
      startOptions=StartOptions,
      bypass=bool,
      helpers=Helpers)) =
  data.startOptions = response.startOptions
  data.homedir = response.home
  data.config = response.config
  bootstrapCollabJoinFromLocation()
  if response.bypass:
    # if subsystem: DON'T reset the layout:
    #   keep it, and expect that the event log/other global panels
    #   are ok with the same info, as we use the same trace
    #   and more local panels like state/calltrace would be updated
    #   from the next complete move after resstart: probably entrypoint
    #
    #   the goal is for the interface to not change drastically and for this restart
    #   to be not very visible/jarring
    if data.lastRestartKind != RestartSubsystem:
      renderer.resetLayoutState(data)

  data.ui.resolvedConfig = cast[GoldenLayoutResolvedConfig](response.layout)
  data.config.flow.realFlowUI = loadFlowUI(data.config.flow.ui)
  data.services.flow.enabledFlow = response.config.flow.enabled

  renderer.helpers = response.helpers

  # TELEMETRY_ENABLED = false

  # SILENT_LOG = not data.config.debug

  data.createUIComponents()

  loadTheme(data.config.theme)

  configureShortcuts()

  if not response.bypass:
    redrawAll()

when not defined(ctInExtension):
  import
    communication, middleware, dap

  when defined(js):
    proc recordVmBackendRequest(command: cstring; args: JsObject) {.importjs: """
      (function(command, args) {
        window.__CODETRACER_TEST__ = window.__CODETRACER_TEST__ || {};
        const requests = window.__CODETRACER_TEST__.vmBackendRequests || [];
        requests.push({ command, args: JSON.parse(JSON.stringify(args || {})) });
        window.__CODETRACER_TEST__.vmBackendRequests = requests;
      })(#, #);
    """.}

  const middlewareLoggingEnabled = true # TODO: maybe overridable dynamically

  # === LocalToViewTransport

  # for now sending through mediator.emit => for each subscriber, subscriber.emit directly
  # as there are many subscribers
  # IMPORTANT:
  # internalRawReceive for it is called by the LocalViewToMiddlewareTransport when
  # a local view emits

  # === end of LocalToViewsTransport

  proc configureMiddleware =
    setupMiddlewareApis(data.dapApi, data.viewsApi)

    data.dapApi.ipc = data.ipc

    data.dapApi.on(DapInitializeResponse, proc(kind: CtEventKind, response: JsObject) =
      cdebug "[PIPELINE] DapInitializeResponse: received response"
      var supportsStepBack = false
      if not response.isNil and not jsMissing(response["supportsStepBack"]):
        supportsStepBack = response["supportsStepBack"].to(bool)
      cdebug "[PIPELINE] DapInitializeResponse: supportsStepBack=" & $supportsStepBack
      # Remember the capability so it survives even when the response beats the
      # `activeSessionVM` creation below; apply immediately when the VM already
      # exists (e.g. a per-trace re-initialize after load).
      pendingSupportsStepBack = supportsStepBack
      if not activeSessionVM.isNil:
        activeSessionVM.store.setSupportsStepBack(supportsStepBack)
    )

    data.dapApi.sendCtRequest(DapInitialize, toJs(DapInitializeRequestArgs(
      clientName: "codetracer"
    )))

    # -----------------------------------------------------------------------
    # ViewModel layer: create a SessionViewModel backed by the real DapApi.
    # This must happen BEFORE component.register() calls, because register()
    # lazily creates panel VMs — if the shared store is already in place the
    # panels will use it instead of falling back to stub backends.
    # -----------------------------------------------------------------------
    if activeSessionVM.isNil:
      let dapRef = data.dapApi
      let realBackend = newRealBackendService(
        sendCommand = proc(command: string, argsJs: JsObject): BackendFuture[JsObject] =
          when defined(js):
            if data.startOptions.inTest:
              recordVmBackendRequest(cstring(command), argsJs)
          # Translate the BackendService string command to a CtEventKind
          # and forward it through the existing DapApi IPC channel.
          let kind = dapCommandToEventKind(cstring(command))
          dapRef.asyncSendCtRequest(kind, argsJs),
        onBackendEvent = proc(handler: proc(kind: string, raw: JsObject)) =
          # Subscribe to every event kind that has a DAP mapping so the
          # ViewModel store receives the same events as the legacy UI.
          for k in CtEventKind:
            if EVENT_KIND_TO_DAP_MAPPING[k] != "":
              dap.on[JsObject](dapRef, k, proc(kind: CtEventKind, raw: JsObject) =
                handler($kind, raw)),
      )
      activeSessionVM = createSessionVM(realBackend)
      # Apply any `supportsStepBack` capability that arrived before this VM
      # existed (its DAP `initialize` response can beat this assignment), so the
      # reverse-step toolbar buttons reflect the backend's real capability.
      activeSessionVM.store.setSupportsStepBack(pendingSupportsStepBack)
      activeCollabFrontEndAdapter = initWebUiCollabAdapter(
        activeSessionVM.collabCore.localPrincipalId,
        activeSessionVM.collabCore.localActorId
      )
      activeSessionVM.collabCore.installFrontEndAdapterProjection(
        activeCollabFrontEndAdapter)
      cdebug "[PIPELINE] configureMiddleware: SessionVM + RealBackendService created"
      clog "SessionViewModel: created with real DapApi backend"
      if pendingCollabJoinBootstrapRaw.len > 0:
        discard activateCollabJoinBootstrap(pendingCollabJoinBootstrapRaw)

      # Pre-initialise (or upgrade) the panel VMs that have legacy bridge
      # code so they use the shared store from the SessionViewModel.
      # If register() already created stub-backed VM instances during
      # createUIComponents(), these calls replace them with real-backend
      # instances.  If register() hasn't run yet, the instances are
      # created fresh with the real backend.
      template initPanelVM(label: string; body: untyped) =
        try:
          cdebug "[PIPELINE] configureMiddleware: calling " & label
          body
        except CatchableError as e:
          # Stays at ERROR: this is a real failure, not progress.  A panel
          # VM that threw during construction leaves its panel wired to a
          # stub (or to nothing), and every later symptom — an empty
          # calltrace, a state panel that never fills — is downstream of
          # this line.  It must stay at ERROR even though the surrounding
          # `[PIPELINE]` progress traces were demoted to DEBUG.
          cerror "[PIPELINE] configureMiddleware: " & label & " failed: " & e.msg

      initPanelVM("initStateVMWithStore"):
        state.initStateVMWithStore(activeSessionVM.store)
        # M29 §14.8 — attach the OriginChainVM to the SessionVM so
        # the chain panel's breadcrumb chips route process switches
        # through `SessionViewModel.onSwitchProcess` (and so the
        # derived `crossProcessSpans` memo sees a live chain).
        let ocvm = state.activeOriginChainVM()
        if not ocvm.isNil:
          activeSessionVM.attachOriginChainVM(ocvm)
      # M42 §14.8 — multi-process session surface.
      #
      # `ct/listProcesses` is the only description of a session's
      # recordings the renderer ever receives. The backend dispatches it
      # as an unsolicited DAP event exactly once per session load
      # (`dap_server.rs::dispatch_session_load_event`), so this
      # subscription is what makes `processTree` non-empty in a real
      # session — there is no polling fallback and no second source.
      initPanelVM("subscribeListProcesses"):
        dap.on[JsObject](dapRef, CtListProcesses,
          proc(kind: CtEventKind, raw: JsObject) =
            if activeSessionVM.isNil or raw.isNil:
              return
            try:
              activeSessionVM.consumeListProcessesEvent(parseJsonFromJsObject(raw))
            except CatchableError as e:
              cerror "ct/listProcesses: failed to decode payload: " & e.msg)

      # The `ct/originChain` reply had the same fate as `ct/listProcesses`
      # before M42: `OriginChainVM.onShowOrigin` fires the request and
      # discards the future (`asyncSendCtRequest` resolves immediately —
      # real replies arrive out-of-band on the DAP channel), and nothing
      # called `applyChainResponse`, so `activeChain` stayed `none` and
      # the Origin Chain side panel never had a chain to draw. The
      # backend emits `ct/updated-origin-chain` alongside every chain
      # response — including the session-composed cross-process one, whose
      # wire shape is deliberately identical — so one subscription feeds
      # the VM for both the single- and multi-recording paths.
      initPanelVM("subscribeUpdatedOriginChain"):
        dap.on[JsObject](dapRef, CtUpdatedOriginChain,
          proc(kind: CtEventKind, raw: JsObject) =
            let ocvm = state.activeOriginChainVM()
            if ocvm.isNil or raw.isNil:
              return
            try:
              ocvm.applyChainResponse(
                parseOriginChain(parseJsonFromJsObject(raw)))
              # Spec §3.2.2 — "Show value origin" opens the dedicated
              # side panel. There are two menus that can start the
              # request (the IsoNim State Pane row menu, which goes
              # through `OriginChainVM.onShowOrigin`, and the legacy
              # value-row menu in `ui/value.nim`, which emits
              # `CtOriginChain` on the mediator and never touches the
              # VM). Opening here covers both, and a chain only ever
              # arrives because a user asked for one.
              ocvm.openSidePanel()
            except CatchableError as e:
              cerror "ct/updated-origin-chain: failed to decode chain: " & e.msg)
        # The `ct/originChain` response carries the identical chain body
        # and is the request's direct correlate, so it is consumed too:
        # the companion event is emitted only on success, and a failed
        # query would otherwise leave the panel silently shut with no
        # trace of why.
        dap.on[JsObject](dapRef, CtOriginChainResponse,
          proc(kind: CtEventKind, raw: JsObject) =
            let ocvm = state.activeOriginChainVM()
            if ocvm.isNil or raw.isNil:
              return
            try:
              let body = parseJsonFromJsObject(raw)
              if body.kind == JObject and body.hasKey("hops"):
                ocvm.applyChainResponse(parseOriginChain(body))
                ocvm.openSidePanel()
              else:
                ocvm.onCancelLoad()
                cerror "ct/originChain: query returned no chain: " & $body
            except CatchableError as e:
              cerror "ct/originChain: failed to decode response: " & e.msg)

      # The process tree's click handler rotates the ViewModel's active
      # recording; this bridge is what makes that rotation visible in
      # the backend. Requests are routed to a recording purely by the
      # composed `threadId` they carry
      # (`dap_server.rs::handle_request_via_session`), so switching
      # process means re-pointing that id and then moving the cursor
      # into the new recording so the editor and State Pane follow.
      initPanelVM("installSwitchProcessBridge"):
        activeSessionVM.onSwitchProcessProc = proc(recordingId: string) =
          if activeSessionVM.isNil:
            return
          let entryOpt = activeSessionVM.entryForRecording(recordingId)
          if entryOpt.isNone:
            cerror "switch process: unknown recording " & recordingId
            return
          let threadId = entryOpt.get.routingThreadId()
          if threadId == 0:
            cerror "switch process: recording " & recordingId &
              " advertises no thread id; leaving routing unchanged"
            return
          setActiveSessionThreadId(threadId)
          data.dapApi.sendCtRequest(CtRunToEntry, JsObject{})

      # Spec §14.8 — the State Pane's "Switch process" right-click
      # entry. Offered only while a cross-process correlation is
      # active: the targets are the sibling recordings the open origin
      # chain reaches, minus the one already being viewed.
      initPanelVM("installSwitchProcessMenuBridges"):
        let svm = state.activeStateVM()
        if not svm.isNil:
          svm.crossProcessSwitchTargets = proc(): seq[ProcessSwitchTarget] =
            result = @[]
            if activeSessionVM.isNil:
              return
            let activeId = activeSessionVM.activeProcessRecordingId.val
            var seen: seq[string] = @[]
            for span in activeSessionVM.crossProcessSpans.val:
              if span.recordingId.len == 0 or span.recordingId == activeId:
                continue
              if span.recordingId in seen:
                continue
              seen.add(span.recordingId)
              result.add(ProcessSwitchTarget(
                recordingId: span.recordingId, role: span.role))
          svm.onSwitchProcessProc = proc(recordingId: string) =
            if not activeSessionVM.isNil:
              activeSessionVM.onSwitchProcess(recordingId)

      initPanelVM("mountProcessTree"):
        mountProcessTree(activeSessionVM)

      initPanelVM("initDebugControlsVMWithStore"):
        debug.initDebugControlsVMWithStore(activeSessionVM.store)
      initPanelVM("initCalltraceVMWithStore"):
        calltrace.initCalltraceVMWithStore(activeSessionVM.store)
      initPanelVM("initEventLogVMWithStore"):
        event_log.initEventLogVMWithStore(activeSessionVM.store)
        # §5.3 — an Event Log boundary chip whose counterpart lives in
        # a sibling recording rotates the session, exactly as clicking
        # that recording in the process tree would.
        event_log.installEventLogSwitchProcessBridge(proc(recordingId: string) =
          if not activeSessionVM.isNil:
            activeSessionVM.onSwitchProcess(recordingId))
      initPanelVM("initFlowVMWithStore"):
        flow.initFlowVMWithStore(activeSessionVM.store)
      initPanelVM("initEditorVMWithStore"):
        editor.initEditorVMWithStore(activeSessionVM.store)
      initPanelVM("initTimelineVMWithStore"):
        trace.initTimelineVMWithStore(activeSessionVM.store)
      initPanelVM("initTerminalOutputVMWithStore"):
        terminal_output.initTerminalOutputVMWithStore(activeSessionVM.store)
      initPanelVM("initBuildVMWithStore"):
        build.initBuildVMWithStore(activeSessionVM.store)
        build.buildVMInstance.runBuild = proc() = data.update(build=true)
      initPanelVM("initErrorsVMWithStore"):
        errors.initErrorsVMWithStore(activeSessionVM.store)
      initPanelVM("initSearchResultsVMWithStore"):
        search_results.initSearchResultsVMWithStore(activeSessionVM.store)
      initPanelVM("initNoSourceVMWithStore"):
        no_source.initNoSourceVMWithStore(activeSessionVM.store)
      initPanelVM("initStepListVMWithStore"):
        step_list.initStepListVMWithStore(activeSessionVM.store)
      initPanelVM("initCalltraceEditorVMWithStore"):
        calltrace_editor.initCalltraceEditorVMWithStore(activeSessionVM.store)
      initPanelVM("initReplVMWithStore"):
        repl.initReplVMWithStore(activeSessionVM.store)
      initPanelVM("initLowLevelCodeVMWithStore"):
        low_level_code.initLowLevelCodeVMWithStore(activeSessionVM.store)
      initPanelVM("initRequestPanelVMWithStore"):
        request_panel.initRequestPanelVMWithStore(activeSessionVM.store)
      initPanelVM("initTraceLogVMWithStore"):
        trace_log.initTraceLogVMWithStore(activeSessionVM.store)
      initPanelVM("initScratchpadVMWithStore"):
        scratchpad.initScratchpadVMWithStore(activeSessionVM.store)
      initPanelVM("initFilesystemVMWithStore"):
        filesystem.initFilesystemVMWithStore(activeSessionVM.store)
      initPanelVM("initCommandPaletteVMWithStore"):
        command.initCommandPaletteVMWithStore(activeSessionVM.store)
      initPanelVM("initFrameViewerVMWithStore"):
        frame_viewer.initFrameViewerVMWithStore(activeSessionVM.store)
      initPanelVM("initPixelHistoryVMWithStore"):
        pixel_history.initPixelHistoryVMWithStore(activeSessionVM.store)
      initPanelVM("initShaderDebugVMWithStore"):
        shader_debug.initShaderDebugVMWithStore(activeSessionVM.store)
      initPanelVM("initVideoPlayerVMWithStore"):
        video_player.initVideoPlayerVMWithStore(activeSessionVM.store)
      initPanelVM("initAgentActivityVMWithStore"):
        agent_activity.initAgentActivityVMWithStore(activeSessionVM.store)
      initPanelVM("initAgentWorkspaceVMWithStore"):
        agent_workspace.initAgentWorkspaceVMWithStore(activeSessionVM.store)
      when not defined(ctWeb):
        initPanelVM("installAgenticWorktreeTestHooks"):
          agentic_worktree_test_hooks.installAgenticWorktreeTestHooks(
            activeSessionVM.store)

      # -----------------------------------------------------------------
      # Direct viewsApi subscriptions: bypass the component mediator
      # routing so the ViewModel store receives data even when the
      # component-level subscriptions are not yet wired up (the mediator
      # routing between early-registered components and viewsApi is
      # order-dependent and can miss events).
      # -----------------------------------------------------------------
      cdebug "[PIPELINE] configureMiddleware: registering viewsApi subscriptions"
      data.viewsApi.subscribe(CtUpdatedCalltrace,
        proc(kind: CtEventKind, response: CtUpdatedCalltraceResponseBody, sub: Subscriber) =
          cdebug ("[PIPELINE] viewsApi.CtUpdatedCalltrace: received " &
            $response.callLines.len & " lines, totalCalls=" &
            $response.totalCallsCount)
          calltrace.syncCalltraceData(response))

      data.viewsApi.subscribe(CtLoadLocalsResponse,
        proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
          cdebug ("[PIPELINE] viewsApi.CtLoadLocalsResponse: received " &
            $response.locals.len & " variables")
          state.syncStoreLocals(response.locals))

      data.viewsApi.subscribe(CtCompleteMove,
        proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
          cdebug ("[PIPELINE] viewsApi.CtCompleteMove: rrTicks=" &
            $response.location.rrTicks & " file=" & $response.location.path &
            " line=" & $response.location.line)
          # Batch the calltrace + state store writes so the parallel
          # ViewModels' autoLoad effects fire at most once per move.
          # Without batching each write schedules its own observer
          # invalidation, producing several backend round-trips that can
          # clobber the store mid-render and leave Playwright with stale
          # locators (the python/ruby sudoku navigation regression).
          let rrTicks = response.location.rrTicks
          let path = response.location.path
          let line = response.location.line
          let sourceGeneration = response.location.sourceGeneration
          let sourceDigest = response.location.sourceDigest
          let rawResponse = response.toJs
          let geidValue = rawResponse["geid"]
          let currentGeidValue = rawResponse["currentGeid"]
          let locationGeidValue = response.location.toJs["geid"]
          let geid =
            if not jsMissing(geidValue):
              some(geidValue.to(int).uint64)
            elif not jsMissing(currentGeidValue):
              some(currentGeidValue.to(int).uint64)
            elif not jsMissing(locationGeidValue):
              some(locationGeidValue.to(int).uint64)
            else:
              none(uint64)
          isoBatch.batch proc() =
            calltrace.syncCalltraceDebuggerPosition(
              rrTicks, path, line, sourceGeneration, sourceDigest)
            state.syncStoreDebuggerPosition(
              rrTicks, path, line, sourceGeneration, sourceDigest)
            if geid.isSome and not activeSessionVM.isNil:
              activeSessionVM.store.updateCurrentGeid(geid)

          if not data.ui.status.isNil:
            cdebug "[PIPELINE] viewsApi.CtCompleteMove: refreshing status directly"
            data.ui.status.stopSignal = response.stopSignal
            data.ui.status.location = response.location
            data.ui.status.state.stableBusy = false
            inc data.ui.status.completeMoveId
            data.ui.status.redraw()
          else:
            # Stays at ERROR.  The "it just arrived early"
            # reading of this branch does not survive checking: the only
            # thing that registers this subscription is
            # `configureMiddleware`, and both of its call sites
            # (`onTraceLoaded`, `onNoTrace`) run strictly after
            # `createUIComponents`, which constructs `data.ui.status`
            # unconditionally.  So a `CtCompleteMove` cannot reach this
            # handler before the status bar exists on the ordinary path,
            # and a clean trace open reaches this branch ZERO times
            # (measured off the `CODETRACER_TEST_CONSOLE_DUMP_PATH` dump).
            #
            # It therefore costs no log noise to keep, and what it would
            # report is real: `data.ui` was rebuilt without its status
            # component (`renderer.resetLayoutState` replaces `data.ui`
            # wholesale) or a session switch left a session's chrome
            # unbuilt.  The symptom is a status bar frozen on a stale
            # location with nothing else in the log to say why.
            cerror "[PIPELINE] viewsApi.CtCompleteMove: status component is nil")

      # The standalone isonim_app shell remains disabled here because it would
      # create a duplicate DOM tree in #isonim-app. The per-panel mounts in
      # calltrace.nim, state.nim, event_log.nim, etc. are the canonical
      # rendering path and mount directly into GoldenLayout containers.

    for content, components in data.ui.componentMapping:
      for i, component in components:
        let componentToMiddlewareApi =
          if component.api.isNil:
            setupLocalViewToMiddlewareApi(cstring(fmt"{content} #{component.id} api"), data.viewsApi)
          else:
            component.api
        component.register(componentToMiddlewareApi)

    # Replay the last known debugger position so that newly-created
    # VMs (which start with rrTicks=0) learn the current position.
    # CtCompleteMove may have already fired before the VMs were created
    # and before register() wired up the component subscriptions.
    # InternalLastCompleteMove asks the middleware to re-emit CtCompleteMove,
    # which triggers onCompleteMove -> loadLines -> CtLoadCalltraceSection
    # now that all subscriptions are in place.
    if not activeSessionVM.isNil:
      # Immediate replay: catches the case where CtCompleteMove already
      # fired and lastCompleteMove is set in the middleware.
      cdebug "[PIPELINE] configureMiddleware: emitting InternalLastCompleteMove (immediate)"
      data.viewsApi.emit(InternalLastCompleteMove, EmptyArg())
      # Delayed replay: the DAP launch is asynchronous — CtCompleteMove
      # typically arrives 1-5 seconds after configureMiddleware.  This
      # retry ensures VMs learn the position even when the backend
      # responds after the immediate replay above found nothing.
      discard windowSetTimeout(proc() =
        cdebug "[PIPELINE] configureMiddleware: emitting InternalLastCompleteMove (delayed 3s)"
        data.viewsApi.emit(InternalLastCompleteMove, EmptyArg())
      , 3_000)

    # discard windowSetTimeout(proc =
    #   data.dapApi.exampleDap.receiveOnMove(), 1_000)

  # once:
    # configureMiddleware()

cast[js](dom.document).onreadystatechange = onReady

proc jsObjectKeys(obj: js): seq[cstring] {.importjs: "Object.keys(#)".}

proc loadFrontendSourcemap(sourcemapPath: cstring): Future[FrontendSourcemap] {.async.} =
  ## Load and parse a ct_sourcemap_* file into a FrontendSourcemap.
  ## The sourcemap JSON has the structure:
  ##   { "nimSources": {path: id, ...}, "cSources": {path: id, ...},
  ##     "mappings": [ { "lineStr": [[pathID, cLine], ...], ... }, ... ] }
  ## We build bidirectional lookup tables: nim(path,line)->C and C(path,line)->nim.
  ##
  ## Note: In Nim's JS async, `result` is a Future[T], so we must use a local
  ## variable for the FrontendSourcemap and return it explicitly.
  var sm = FrontendSourcemap(
    nimToC: JsAssoc[cstring, JsAssoc[int, seq[seq[SourcemapPathIDLine]]]]{},
    cToNim: JsAssoc[cstring, JsAssoc[int, SourcemapPathIDLine]]{},
    cSources: JsAssoc[int, cstring]{},
    nimSources: JsAssoc[int, cstring]{},
    loaded: false)

  if sourcemapPath.isNil or sourcemapPath.len == 0:
    return sm

  try:
    let rawText = await readFileUtf8(sourcemapPath)
    if rawText.isNil or rawText.len == 0:
      console.log cstring"sourcemap: empty file at ", sourcemapPath
      return sm

    let raw = JSON.parse(rawText)
    if raw.isNil:
      console.log cstring"sourcemap: failed to parse JSON"
      return sm

    # Build ID -> path maps (inverting the path -> ID maps from the JSON)
    let rawCSources = raw.cSources
    let rawNimSources = raw.nimSources

    # cSources: { "path.c": 0, ... } -> sm.cSources[0] = "path.c"
    let cSourceKeys = jsObjectKeys(rawCSources)
    for cPath in cSourceKeys:
      let cID = cast[int](rawCSources[cPath])
      sm.cSources[cID] = cPath
      # Initialize the cToNim table for this C source
      if not sm.cToNim.hasKey(cPath):
        sm.cToNim[cPath] = JsAssoc[int, SourcemapPathIDLine]{}

    # nimSources: { "path.nim": 0, ... } -> sm.nimSources[0] = "path.nim"
    let nimSourceKeys = jsObjectKeys(rawNimSources)
    for nimPath in nimSourceKeys:
      let nimID = cast[int](rawNimSources[nimPath])
      sm.nimSources[nimID] = nimPath
      # Initialize the nimToC table for this Nim source
      if not sm.nimToC.hasKey(nimPath):
        sm.nimToC[nimPath] = JsAssoc[int, seq[seq[SourcemapPathIDLine]]]{}

    # Build mappings: mappings is an array indexed by nimPathID
    # Each element is an object with line numbers as keys -> array of groups
    let rawMappings = raw.mappings
    let mappingsLen = cast[int](rawMappings.length)
    for nimPathID in 0 ..< mappingsLen:
      let pathMapping = rawMappings[nimPathID]
      if pathMapping.isNil:
        continue
      if not sm.nimSources.hasKey(nimPathID):
        continue
      let nimPath = sm.nimSources[nimPathID]
      let lineKeys = jsObjectKeys(pathMapping)
      for lineStr in lineKeys:
        let nimLine = parseInt($lineStr)
        let groups = pathMapping[lineStr]
        let groupsLen = cast[int](groups.length)
        var parsedGroups: seq[seq[SourcemapPathIDLine]] = @[]
        for gi in 0 ..< groupsLen:
          let group = groups[gi]
          let groupLen = cast[int](group.length)
          var parsedGroup: seq[SourcemapPathIDLine] = @[]
          for pi in 0 ..< groupLen:
            let pair = group[pi]
            let pathIDLine: SourcemapPathIDLine = [cast[int](pair[0]), cast[int](pair[1])]
            parsedGroup.add(pathIDLine)
            # Also build the reverse mapping: C -> Nim
            let cPathID = pathIDLine[0]
            let cLine = pathIDLine[1]
            if sm.cSources.hasKey(cPathID):
              let cPath = sm.cSources[cPathID]
              if sm.cToNim.hasKey(cPath):
                sm.cToNim[cPath][cLine] = [nimPathID, nimLine]
          parsedGroups.add(parsedGroup)
        if sm.nimToC.hasKey(nimPath):
          sm.nimToC[nimPath][nimLine] = parsedGroups

    sm.loaded = true
    console.log cstring"sourcemap: loaded successfully from ", sourcemapPath
  except:
    console.log cstring"sourcemap: failed to load: ", cstring(getCurrentExceptionMsg())

  return sm

proc handleDapReplaySelected(response: JsObject; sendInitialize: bool) =
  let trace = response["trace"].to(Trace)
  data.activeSession.replayId = response["replayId"].to(int)
  data.activeSession.liveDebugSession = false
  infoPrint "ui: reinitializing dap for trace ", $trace.recordingId
  if sendInitialize:
    data.dapApi.sendCtRequest(DapInitialize, toJs(DapInitializeRequestArgs(
      clientName: "codetracer"
    )))
  data.dapApi.sendCtRequest(DapConfigurationDone, js{})
  data.dapApi.sendCtRequest(DapLaunch, js{
    traceFolder: trace.outputFolder,
    rawDiffIndex: data.startOptions.rawDiffIndex,
    ctRRWorkerExe: data.rrBackendPath,
  })

proc handleDapLiveSessionSelected(response: JsObject; sendInitialize: bool) =
  let trace = response["trace"].to(Trace)
  data.activeSession.replayId = response["replayId"].to(int)
  data.activeSession.liveDebugSession = true
  if not activeSessionVM.isNil:
    activeSessionVM.store.setSessionMode(liveMcr)
  infoPrint "ui: initializing live dap session for trace ", $trace.recordingId
  if sendInitialize:
    data.dapApi.sendCtRequest(DapInitialize, toJs(DapInitializeRequestArgs(
      clientName: "codetracer"
    )))
  data.dapApi.sendCtRequest(DapConfigurationDone, js{})
  data.dapApi.sendCtRequest(DapLaunch, js{
    program: response["program"],
    args: response["args"],
    cwd: response["cwd"],
    liveRecording: true,
    liveRecordingDir: response["liveRecordingDir"],
    rawDiffIndex: data.startOptions.rawDiffIndex,
    ctRRWorkerExe: data.rrBackendPath,
  })

proc shouldInitializeForDapSelection(): bool =
  data.startOptions.rawTestStrategy.len == 0

proc flushPendingDapSessionSelections() =
  if not dapSessionSelectionReady:
    return
  let sendInitialize = shouldInitializeForDapSelection()
  if not pendingDapReplaySelection.isNil:
    let payload = pendingDapReplaySelection
    pendingDapReplaySelection = nil
    handleDapReplaySelected(payload, sendInitialize)
  if not pendingDapLiveSelection.isNil:
    let payload = pendingDapLiveSelection
    pendingDapLiveSelection = nil
    handleDapLiveSessionSelected(payload, sendInitialize)

proc onDapReplaySelected(sender: js; response: JsObject) =
  data.activeSession.liveDebugSession = false
  if dapSessionSelectionReady:
    handleDapReplaySelected(response, shouldInitializeForDapSelection())
  else:
    pendingDapReplaySelection = response

proc onDapLiveSessionSelected(sender: js; response: JsObject) =
  data.activeSession.liveDebugSession = true
  if dapSessionSelectionReady:
    handleDapLiveSessionSelected(response, shouldInitializeForDapSelection())
  else:
    pendingDapLiveSelection = response

proc onTraceLoaded(
  sender: js,
  response: jsobject(
    trace=Trace,
    tags=JsAssoc[cstring, seq[Tag]],
    functions=seq[Function],
    save=Save,
    diff=Diff,
    withDiff=bool,
    rawDiffIndex=cstring,
    # traceKind=cstring,
    dontAskAgain=bool,
    sourcemapPath=cstring,
    macroSourcemapPath=cstring,
    visualReplayAvailable=bool,
    visualReplayPlayerUrl=cstring,
    visualReplayPlayerError=cstring)) {.async.} =

  clog "trace loaded"
  # console.log response.withDiff, response.diff, response.rawDiffIndex

  hideWelcomeScreenSurface()

  normalizeTraceProgramForUi(response.trace)
  data.trace = response.trace
  requestSessionTabsRender(data)
  data.setEditorsReadOnlyState(true)
  data.services.debugger.functions = response.functions
  data.services.editor.tags = response.tags
  data.save = response.save
  data.save.fileMap = JsAssoc[cstring, int]{}
  data.ui.menuNode = data.webTechMenu(baseName(response.trace.program))
  data.refreshCommandPaletteMenuIndex()
  if not data.ui.menu.isNil:
    data.ui.menu.requestMenuRender()

  dom.document.title = cstring(fmt"CodeTracer | Trace {data.trace.recordingId}: {data.trace.program}")

  for i, file in data.save.files:
    data.save.fileMap[file.path] = i

  duration("traceLoaded")

  # Load the Nim-to-C sourcemap for ViewTargetSource line synchronization.
  # The index process sends the path; the renderer reads and parses it asynchronously.
  if data.trace.lang == LangNim and not response.sourcemapPath.isNil and
     response.sourcemapPath.len > 0:
    data.activeSession.sourcemap = await loadFrontendSourcemap(response.sourcemapPath)
  else:
    data.activeSession.sourcemap = FrontendSourcemap(loaded: false)

  # S6: Track whether a macro sourcemap is available for this trace.
  # The backend loads the macro_sourcemap files during trace setup and handles
  # expansion resolution via the ct/update-expansion DAP command.
  data.activeSession.hasMacroSourcemap =
    not response.macroSourcemapPath.isNil and response.macroSourcemapPath.len > 0
  if data.activeSession.hasMacroSourcemap:
    clog cstring("macro sourcemap available at: " & $response.macroSourcemapPath)

  data.activeSession.visualReplayAvailable = response.visualReplayAvailable
  data.activeSession.visualReplayPlayerUrl =
    if response.visualReplayPlayerUrl.isNil: cstring""
    else: response.visualReplayPlayerUrl
  data.activeSession.visualReplayPlayerError =
    if response.visualReplayPlayerError.isNil: cstring""
    else: response.visualReplayPlayerError
  frame_viewer.syncVisualReplaySessionIntoVM()
  video_player.syncVisualReplaySessionIntoPlayerVM()
  applyVisualReplayTabsToResolvedConfig(data)

  if data.trace.lang in {LangC, LangCpp, LangRust, LangGo}:
    data.startOptions.loading = false
  CURRENT_LANG = data.trace.lang

  if not data.services.eventLog.isNil:
    data.services.eventLog.restart()
  for id, component in data.ui.componentMapping[Content.EventLog]:
    if not component.isNil:
      component.restart()
  for id, component in data.ui.componentMapping[Content.TerminalOutput]:
    if not component.isNil:
      component.restart()

  data.ui.initEventReceived = true
  data.tryInitLayout()
  if data.trace.lang == LangNim and data.trace.program.len > 0 and
      ($data.trace.program).endsWith(".nim"):
    # This path only SHOWS an already-open tab, so a layout that never
    # arrived costs a focus rather than an exception; the result is
    # deliberately discarded and the loop below is already bounded.
    discard await waitForLayoutGround(data)
    let programTab = editorTabPath(data.trace.program, ViewSource)
    if data.services.editor.open.hasKey(programTab):
      for _ in 0 ..< 100:
        if not data.services.editor.open[programTab].loading:
          data.showTab(programTab)
          break
        await sleepMs(20)
    else:
      await data.openNewEditorView(programTab, ViewSource)

  # DeepReview-GUI.md §1, launch method 2: "Open a trace that is associated
  # with a diff."  A trace recorded with `ct record --with-diff` carries its
  # structured diff in the trace folder, and every stage up to here already
  # forwarded it — `ct run` as `--diff <path>`, `index/args.nim` into
  # `StartOptions.diff`, `index/traces.nim` into this very message — but the
  # renderer used to drop it, so the launch method existed on paper only.
  # It enters the review through the same routine `ct review` and the
  # agentic handoff use.
  if response.withDiff and not response.diff.isNil and
      response.diff.files.len > 0:
    discard await waitForLayoutGround(data)
    let reviewedProgram = $baseName(data.trace.program)
    vcs.startReviewForTraceDiff(
      data, response.diff,
      title = "Review: " & reviewedProgram,
      # The open recording *is* the run under review, so it is the review's
      # one trace context.
      traceLabel = reviewedProgram,
      recordingId = $data.trace.recordingId)

  if data.startOptions.rawTestStrategy.len > 0:
    data.testRunner = cast[JsObject](runUiTest(data.startOptions.rawTestStrategy))

  when not defined(ctInExtension):
    if not middlewareConfigured:
      configureMiddleware()
      middlewareConfigured = true

  dapSessionSelectionReady = true
  flushPendingDapSessionSelections()

  data.switchToDebug()
  renderer.requestInitialPanelData(data)
  when not defined(ctInExtension):
    # The status bar is global chrome outside GoldenLayout. During startup the
    # debugger service can receive the first CtCompleteMove before the status
    # host has settled, so retry a few times using the debugger service's last
    # known location. This preserves the old "data.redraw after complete move"
    # startup effect without depending on the ViewModel subscription order.
    var statusRefreshAttempts = 0
    proc refreshStatusFromDebugger() =
      inc statusRefreshAttempts
      if not data.ui.status.isNil:
        data.ui.status.location = data.services.debugger.location
        data.ui.status.stopSignal = data.services.debugger.stopSignal
        data.ui.status.state.stableBusy = data.status.stableBusy
        data.ui.status.redraw()
      if statusRefreshAttempts < 10:
        discard windowSetTimeout(refreshStatusFromDebugger, 500)
    discard windowSetTimeout(refreshStatusFromDebugger, 0)

  if not data.startOptions.isInstalled and not response.dontAskAgain and not data.config.skipInstall:
    data.viewsApi.installMessage()

proc onStartShellUi*(sender: js, response: jsobject(config=Config)) =
  data.startOptions.loading = false
  data.startOptions.shellUi = true
  data.config = response.config
  data.ui.menuNode = data.webTechMenu(cstring"Shell")
  data.refreshCommandPaletteMenuIndex()
  loadTheme(data.config.theme)
  var shellComponent = data.shellComponent(0)

  if shellComponent.isNil:
    shellComponent =
      cast[ShellComponent](data.makeComponent(
        Content.Shell, data.generateId(Content.Shell)))
  discard shellComponent.createShell()

  hideWelcomeScreenSurface()

  if data.ui.menu.isNil:
    discard data.makeMenuComponent()
  if not data.ui.menu.isNil:
    data.ui.menu.requestMenuRender()

  data.ui.initEventReceived = true
  data.tryInitLayout()


proc onStartDeepReview*(sender: js, response: jsobject(config=Config, startOptions=StartOptions, layout=js)) =
  ## Handler for ``CODETRACER::start-deepreview`` IPC message.
  ##
  ## Sets up the frontend for DeepReview offline review mode on the layout the
  ## index process loaded, which is used as-is: a review adds no panel and
  ## removes none, it only retargets the stacks hosting the VCS and Agent
  ## Activity panels at them (``deepreview_layout.focusReviewPanels``).  Every
  ## panel that layout declares therefore stays where the user put it
  ## (issue #610; DeepReview-GUI.md §7).
  ##
  ## The VCS panel detects ``data.deepReviewActive`` and populates its file
  ## list from ``data.deepReviewData.files``; clicking a file opens that
  ## file's review representation as an ordinary editor document — a
  ## ``Content.UnifiedDiff`` tab or the file itself, per the panel's view
  ## mode toggle.
  ##
  ## NOTE (RV-2): the layout that arrives here for a *dataset* launch is the
  ## EDITOR layout, not the debugging one (``index/config.loadReviewLayoutConfig``).
  ## A dataset launch loads no recording at all — ``index/args.nim`` forces
  ## ``recordingID = ""`` and ``index/startup.nim`` returns before
  ## ``CODETRACER::init`` — so the replay-backed panels used to come up present
  ## but EMPTY, which reads as missing data.  They are now simply not in the
  ## layout (DeepReview-GUI.md §1.1).  The other two launch methods have a
  ## recording, do not pass through this handler, and keep the debugging
  ## layout with those panels populated.
  data.startOptions.loading = false
  data.startOptions.withDeepReview = true
  data.config = response.config
  # The deepReview data was already parsed in parseArgs on the index side,
  # but since the renderer runs in a separate Electron process, the
  # startOptions are forwarded via the IPC message.
  data.startOptions.deepReview = response.startOptions.deepReview
  # RV-6: and, when the dataset named an agent session, the resolution `ct`
  # performed for it.  Nil when the dataset named none — which is normal, and
  # is *not* the same as a reference that failed to resolve (that arrives with
  # an explicit non-"loaded" state; DeepReview-GUI.md §2.1).
  data.startOptions.reviewSession = response.startOptions.reviewSession

  # Store DeepReview data at the Data level so all panels can access it.
  data.deepReviewActive = true
  data.deepReviewData = response.startOptions.deepReview

  loadTheme(data.config.theme)

  hideWelcomeScreenSurface()

  # Parse the layout the index process loaded, bring the review's panels to
  # the front of the stacks that already host them, and hand it back to
  # GoldenLayout.  Nothing is inserted: DeepReview has no surface of its own
  # (DeepReview-GUI.md §7).
  var layoutNode = resolvedConfigToJsonNode(
    cast[GoldenLayoutResolvedConfig](response.layout))
  if layoutNode.isNil:
    # `index/config.loadLayoutConfig` never returns nil (it resets to the
    # bundled default, or exits), so this is an emergency path only: keep
    # DeepReview usable with the file list it depends on rather than
    # opening an empty window.
    cerror "onStartDeepReview: no usable layout in the start message; " &
      "falling back to a review-only layout"
    layoutNode = %*{
      "settings": {
        "constrainDragToContainer": true,
        "reorderEnabled": true,
        "popoutWholeStack": false,
        "blockedPopoutsThrowError": true,
        "responsiveMode": "always"
      },
      "dimensions": {
        "borderWidth": 4,
        "borderHeight": 4,
        "headerHeight": 32,
        "dragProxyWidth": 300,
        "dragProxyHeight": 200
      },
      "root": {
        "type": "row",
        "size": "100%",
        "isClosable": false,
        "content": [
          {
            "type": "stack",
            "size": "20%",
            "content": [
              {
                "type": "component",
                "componentType": "genericUiComponent",
                "componentName": "genericUiComponent",
                "componentState": {
                  "id": 0,
                  "label": "vCSComponent-0",
                  "content": VcsContentId
                },
                "title": "genericUiComponent"
              }
            ]
          }
        ]
      },
      "openPopouts": []
    }

  let reviewConfig = jsonNodeToResolvedConfig(focusReviewPanels(layoutNode))
  if not reviewConfig.isNil:
    data.ui.resolvedConfig = reviewConfig
  else:
    cerror "onStartDeepReview: could not build the DeepReview layout"

  # Create UI components from the resolved layout config.  This walks the GL
  # config tree and instantiates each component.  The VCS panel detects
  # deepReviewActive and shows changed files; editor tabs get diff decorations.
  data.createUIComponents()

  data.ui.initEventReceived = true
  data.tryInitLayout()

  # The review's first modified file is opened by `tryInitLayout` itself, as
  # soon as the GoldenLayout tree exists (DeepReview-GUI.md §7 step 2).  It
  # cannot be done here: this message can arrive before the document has
  # finished loading, and `data.ui.layout` is then still nil.


proc onFilenamesLoaded(
    sender: js,
    response: jsobject(
      filenames=seq[string])) =

  data.services.debugger.paths = response.filenames

  data.refreshCommandPaletteFileIndex()

  data.redraw()

proc onSymbolsLoaded(
    sender: js,
    response: jsobject(
      symbols=seq[Symbol])) =

  if data.ui.commandPalette.isNil:
    discard data.makeCommandPaletteComponent()
  if data.ui.commandPalette.isNil or data.ui.commandPalette.interpreter.isNil:
    return

  data.ui.commandPalette.interpreter.symbols = JsAssoc[cstring, seq[Symbol]]{}
  data.ui.commandPalette.interpreter.symbolsPrepared = @[]

  for symbol in response.symbols:
    if not data.ui.commandPalette.interpreter.symbols.hasKey(symbol.name):
      data.ui.commandPalette.interpreter.symbols[symbol.name] = @[]

      # prepare file paths for fast search widh fuzzysort
      data.ui.commandPalette.interpreter.symbolsPrepared.add(fuzzysort.prepare(cstring(symbol.name)))

    # It's possible to have the same symbol in different files
    var nameSymbols = data.ui.commandPalette.interpreter.symbols[symbol.name]
    nameSymbols.add(symbol)
    data.ui.commandPalette.interpreter.symbols[symbol.name] = nameSymbols

  data.redraw()

proc onMenuAction(sender: js, response: jsobject(action=ClientAction)) =
  let f = data.actions[response.action]
  if not f.isNil:
    f(nil)


proc onFilesystemLoaded(
  sender: js,
  response: jsobject(
    folders=CodetracerFile)) =
  data.services.editor.filesystem = response.folders
  filesystem.refreshIsoNimFilesystemPanel()
  # Keep the Ctrl+P file index in sync with the freshly-loaded tree;
  # DB-trace backends that never emit the `filenames` event rely on this
  # to populate command-palette file search.
  data.refreshCommandPaletteFileIndex()
  data.redraw()

proc onFilesystemCategoryLoaded(
  sender: js,
  response: jsobject(
    category=cstring,
    folders=CodetracerFile)) =
  # Add a new category to the filesystem tree
  if data.services.editor.filesystem.isNil:
    # If no filesystem exists yet, just use this as the root
    data.services.editor.filesystem = response.folders
  else:
    # Add the category as a sibling to existing filesystem
    # We need to create a new root that contains both categories
    var newRoot = CodetracerFile(
      text: cstring"Files",
      children: @[],
      state: js{opened: true},
      index: 0,
      parentIndices: @[],
      original: CodetracerFileData(
        text: cstring"Files",
        path: cstring""))

    # Add existing workspace as first child
    newRoot.children.add(data.services.editor.filesystem)
    # Add trace files category as second child
    newRoot.children.add(response.folders)

    data.services.editor.filesystem = newRoot
  filesystem.refreshIsoNimFilesystemPanel()
  data.redraw()

proc onLoadFolderEditMode(
  sender: js,
  response: jsobject(folderPath=cstring)) =
  # Load a folder in edit mode (from welcome screen)
  # This triggers a reload similar to how `ct edit <path>` works
  # For now, we send a request to the index process to load the folder
  data.ipc.send "CODETRACER::init-edit-mode", js{ folder: response.folderPath }

proc onLaunchConfigsLoaded(
  sender: js,
  response: jsobject(configs=seq[FrontendLaunchConfig])) =
  ## Store launch configs and reconstruct the menu to include them
  data.ui.launchConfigs = response.configs
  # Reconstruct menu - webTechMenu now includes launch configs automatically
  data.ui.menuNode = data.webTechMenu(cstring"CodeTracer")
  data.refreshCommandPaletteMenuIndex()
  if not data.ui.menu.isNil:
    data.ui.menu.requestMenuRender()
  data.redraw()

proc onUpdatePathContent(
  sender: js,
  response: jsobject(
    content=CodetracerFile,
    nodeId=cstring,
    nodeIndex=int,
    nodeParentIndices=seq[int])) =
  response.content.changeIcons()

  # Keep the old jstree path alive for any remaining legacy hosts, but
  # do not let its absence abort the service-cache update that feeds the
  # IsoNim filesystem renderer.
  try:
    let tree = jqFind(".filesystem").jstree(true)
    if not tree.isNil:
      let parent = tree.get_node(response.nodeId)
      var children = parent.children.to(seq[cstring])

      if children.len > 0:
        var deletedItems = 0
        for i in 0..<children.len:
          tree.delete_node(children[i - deletedItems])
          deletedItems += 1

      if response.content.children.len > 0:
        for child in response.content.children:
          tree.create_node(response.nodeId, child)
  except:
    discard

  # update component state
  var nodeParent = data.services.editor.filesystem

  for index in response.nodeParentIndices:
    nodeParent = nodeParent.children[index]

  var node = nodeParent.children[response.nodeIndex]
  node[] = response.content[]
  filesystem.refreshIsoNimFilesystemPanel()


proc onUpdateTrace(sender: js, response: jsobject(trace=Trace)) =
  data.trace = response.trace
  requestSessionTabsRender(data)
  data.ui.readOnly = false
  let oldPaths = data.services.debugger.paths
  let oldTags = data.services.editor.tags
  let oldFilesystem = data.services.editor.filesystem
  let oldSave = data.save

  data.services.editor.tags = oldTags
  # TODO initDataTable = true
  data.services.debugger.paths = oldPaths
  data.services.editor.filesystem = oldFilesystem
  data.save = oldSave
  data.switchToDebug()
  redrawAll()


proc onNoTrace(
    sender: js,
    response: jsobject(
      path=cstring,
      lang=Lang,
      layout=js,
      home=cstring,
      startOptions=StartOptions,
      bypass=bool,
      helpers=Helpers,
      config=Config,
      filenames=seq[string],
      filesystem=CodetracerFile,
      functions=seq[Function],
      save=Save)) {.async.} =

  data.trace = nil
  data.ui.readOnly = false
  data.startOptions = response.startOptions
  if data.startOptions.edit and response.path.len > 0:
    data.startOptions.folder = response.path
  data.homedir = response.home
  data.startOptions.app = response.home & cstring"/.local/share" & cstring"/codetracer"
  data.services.debugger.paths = response.filenames
  data.services.debugger.functions = response.functions
  data.ui.menuNode = data.webTechMenu(baseName(response.path))

  hideWelcomeScreenSurface()

  for path in data.services.debugger.paths:
    data.services.search.pathsPrepared.add(fuzzysort.prepare(path))

  for name, source in data.services.search.pluginCommands:
    data.services.search.commandsPrepared.add(
      fuzzysort.prepare(name))

  for function in data.services.debugger.functions:
    var prepared = fuzzysort.prepare(function.signature)
    prepared.obj = function
    data.services.search.functionsPrepared.add(prepared)
    if function.inSourcemap:
      data.services.search.functionsInSourcemapPrepared.add(prepared)

  data.services.editor.filesystem = response.filesystem
  # READ BEFORE THE ASSIGNMENT, and that ordering is the whole of it.
  # `response.layout` still carries the layout's declared `20%` / `25%`
  # strings; the moment GoldenLayout loads it those become the renormalised
  # `44.44` / `55.56` that fill the row, and the space the layout meant to
  # leave for the editor is no longer visible anywhere. Measured, on the
  # deployed `/noir`: the file tree and the editor split the window 50/50
  # because the editor's container was created with no size at all.
  #
  # Both platforms reach this line with the same value — `index/config.
  # loadEditLayoutConfig`'s output on the desktop, `ui/web_entry_surface.
  # noirStudioEditLayout`'s in a browser — so the fix is one call site rather
  # than one per host.
  data.ui.editorAreaPercent =
    max(0, unclaimedTopLevelPercent(cast[js](response.layout)))
  data.ui.resolvedConfig = cast[GoldenLayoutResolvedConfig](response.layout)
  data.config = response.config
  data.config.flow.realFlowUI = loadFlowUI(data.config.flow.ui)
  data.save = response.save
  data.save.fileMap = JsAssoc[cstring, int]{}
  for i, file in data.save.files:
    data.save.fileMap[file.path] = i
  # Use the configured theme from user settings
  loadTheme(data.config.theme)
  # data.tabManager.tabs = JsAssoc[cstring, TabInfo]{}
  # data.tabManager.tabList = @[]
  data.startOptions.screen = false
  data.startOptions.loading = false
  requestSessionTabsRender(data)

  data.ui.initEventReceived = true

  # Create UI components if not already created (needed for menu, status bar, etc.)
  # This must happen before tryInitLayout since layout initialization uses these components
  data.createUIComponents()
  data.refreshCommandPaletteMenuIndex()
  data.refreshCommandPaletteFileIndex()

  when not defined(ctInExtension):
    if not middlewareConfigured:
      configureMiddleware()
      middlewareConfigured = true

  # Check if coming from welcome screen (where layout was already initialized)
  let wasFromWelcomeScreen = not data.ui.layout.isNil

  # If layout already exists (e.g., from welcome screen), reload it with the new config
  if wasFromWelcomeScreen:
    try:
      data.ui.layout.loadLayout(data.ui.resolvedConfig)
    except:
      cerror "onNoTrace: failed to reload layout: " & getCurrentExceptionMsg()
  else:
    data.tryInitLayout()

  # Edit-mode startup has already loaded the edit layout. Avoid the generic
  # switchToEdit path here because it clears live layout components and is
  # meant for toggling an already-running debug session into edit mode.
  data.ui.mode = EditMode
  data.setEditorsReadOnlyState(false)

  # The welcome/new-tab handoff can reuse already-mounted panel instances.
  # Resync the panels against the freshly loaded edit-mode services so the
  # Files and VCS panes reflect the selected folder immediately.
  filesystem.refreshIsoNimFilesystemPanel()
  for _, component in data.ui.componentMapping[Content.VCS]:
    vcs.resetAndRefreshVCS(VCSComponent(component))
    vcs.tryMountIsoNimVCSPanel(component.id)

  # Open the file AFTER layout is initialized. Folder edit mode has no
  # explicit path, so seed the editor from the indexed project files instead
  # of leaving the workspace looking blank.
  var filenameStrings: seq[string] = @[]
  for filename in response.filenames:
    filenameStrings.add($filename)
  let requestedEditPath =
    if data.startOptions.edit:
      $data.startOptions.name
    else:
      $response.path
  let initialEditPath =
    cstring(chooseInitialEditPath(requestedEditPath, filenameStrings,
                                  data.startOptions.edit))
  if initialEditPath.len > 0:
    if await waitForLayoutGround(data):
      data.openTab(initialEditPath, ViewSource) # , response.lang)
    else:
      # Not a silent skip. Opening a tab against a layout that never arrived
      # throws out of `openNewLayoutContainer` and leaves the editor pane
      # missing with nothing in the page to say why — which is what shipped
      # for one load. Saying so costs a line and makes the next report
      # actionable.
      cerror "edit-mode: GoldenLayout did not become ready within 5s; " &
        "the editor was not opened for " & $initialEditPath
  let ext = $toJsLang(response.lang)
  # for i, file in data.save.files:
    # if i < TAB_LIMIT:
      # if ($file.path).endsWith(ext):
        # data.openTab(file.path, cstring"", 0, response.lang)
      # else:
        # data.openTab(file.path, cstring"", 0, LangUnknown)
    # else:
      # remember those and be able to load them on ctrl+page etc
      # TODO
      # discard

  # ASK FOR THE NS9 PANES' DATA once the layout exists, so the panes are
  # mounted by the time an answer arrives. Sent for an EDIT session only: a
  # replay session is looking at a recording, and "which tests does this
  # workspace have" is a question about a workspace.
  if data.startOptions.edit:
    data.ipc.send "CODETRACER::ns9-panes",
      js{ folder: data.startOptions.folder }

  configureShortcuts()
  redrawAll()
  if not data.ui.layout.isNil:
    data.ui.layout.updateSize()
  discard windowSetTimeout(proc =
    redrawAll()
    if not data.ui.layout.isNil:
      data.ui.layout.updateSize(), 1_000)
  discard windowSetTimeout(proc = redrawAll(), 5_000)
  # sometimes stuff isn't rendered and it needs redraw

proc invalidPath(data: Data, fieldName: cstring, message: cstring) =
  let formValidator = data.ui.welcomeScreen.newRecord.formValidator
  let capitalizedField = capitalize(fieldName)
  formValidator.toJs[&"valid{capitalizedField}"] = false
  formValidator.toJs[&"invalid{capitalizedField}Message"] = message

proc recordPath(data: Data, path: cstring, fieldName: cstring) =
  if not data.ui.welcomeScreen.newRecord.isNil:
    data.ui.welcomeScreen.newRecord.toJs[$(fieldName)] = path
    let formValidator = data.ui.welcomeScreen.newRecord.formValidator
    let capitalizedField = capitalize(fieldName)
    formValidator.toJs[&"valid{capitalizedField}"]= true
    formValidator.toJs[&"invalid{capitalizedField}Message"] = cstring""
    data.ui.welcomeScreen.requestWelcomeScreenRender()

proc onRecordPath(
  sender: js,
  response: jsobject(
    execPath=cstring,
    fieldName=cstring)) =

    data.recordPath(response.execPath, response.fieldName)

proc onPathValidated(
  sender: js,
  response: jsobject(
    execPath=cstring,
    isValid=bool,
    fieldName=cstring,
    message=cstring)) =
  if not response.isValid:
    data.invalidPath(response.fieldName, response.message)
    data.ui.welcomeScreen.requestWelcomeScreenRender()
  else:
    data.recordPath(response.execPath, response.fieldName)

proc onSuccessfulRecord(
  sender: js,
  response: jsobject()) =
  if not data.ui.welcomeScreen.isNil and
      not data.ui.welcomeScreen.newRecord.isNil:
    data.ui.welcomeScreen.newRecord.status.kind = RecordSuccess
    data.ui.welcomeScreen.requestWelcomeScreenRender()
  else:
    data.viewsApi.successMessage(cstring"Recording finished. Reloading trace...")

proc onFailedRecord(
  sender: js,
  response: jsobject(errorMessage=cstring)) =
  ## A build/record run failed.
  ##
  ## The notification is unconditional.  Routing the message *only* into the
  ## new-record form's status meant that any user who had ever opened "Record
  ## new trace" got zero feedback from a failed re-record: `welcomeScreen` is
  ## created once at startup and never cleared, and `newRecord` stays non-nil
  ## once the form has been opened, so the form is usually hidden while it
  ## silently absorbs the error (issue #603).
  data.viewsApi.errorMessage(response.errorMessage)
  if not data.ui.welcomeScreen.isNil and
      not data.ui.welcomeScreen.newRecord.isNil:
    data.ui.welcomeScreen.newRecord.status.kind = RecordError
    data.ui.welcomeScreen.newRecord.status.errorMessage = response.errorMessage
    data.ui.welcomeScreen.requestWelcomeScreenRender()

proc onLoadingTrace(
  sender: js,
  response: jsobject(trace=Trace)) =
  data.ui.welcomeScreen.loading = true
  data.ui.welcomeScreen.loadingTrace = response.trace
  data.ui.welcomeScreen.requestWelcomeScreenRender()

proc onFailedDownload(
  sender: js,
  response: jsobject(errorMessage=cstring)
) =
  data.ui.welcomeScreen.newDownload.status.kind = RecordError
  data.ui.welcomeScreen.newDownload.status.errorMessage = response.errorMessage
  data.ui.welcomeScreen.requestWelcomeScreenRender()

proc onSuccessfulDownload(
  sender: js,
  response: jsobject()
) =
  data.ui.welcomeScreen.newDownload.status.kind = RecordSuccess
  data.ui.welcomeScreen.requestWelcomeScreenRender()

proc onWelcomeScreen(
  sender: js,
  response: jsobject(
    home=cstring,
    layout=js,
    startOptions=StartOptions,
    config=Config,
    recentTraces=seq[Trace],
    recentFolders=seq[RecentFolder],
    recentTransactions=seq[StylusTransaction]
  )
) =
  clog "welcome_screen: on welcome screen"
  # TODO: remove unnecessary rows
  data.trace = nil
  data.ui.readOnly = false
  data.startOptions = response.startOptions
  data.homedir = response.home
  data.services.debugger.paths = @[]
  data.ui.resolvedConfig = cast[GoldenLayoutResolvedConfig](response.layout)
  data.config = response.config
  data.config.flow.realFlowUI = loadFlowUI(data.config.flow.ui)
  data.recentTraces = response.recentTraces
  data.recentFolders = response.recentFolders
  data.stylusTransactions = response.recentTransactions
  loadTheme(data.config.theme)
  configureShortcuts()

  if data.ui.welcomeScreen.isNil:
    discard data.makeWelcomeScreenComponent()
  data.ui.welcomeScreen.syncLegacyWelcomeScreenIntoVM()

  data.ui.initEventReceived = true
  data.tryInitLayout()

proc onRecentItems(
  sender: js,
  response: jsobject(
    recentTraces=seq[Trace],
    recentFolders=seq[RecentFolder],
    recentTransactions=seq[StylusTransaction]
  )
) =
  ## Fill the recent-traces / recent-folders cache on startup paths that never
  ## render the welcome screen themselves (issue #568).
  ##
  ## `onWelcomeScreen` above is the only other writer of these fields, and it
  ## only ever runs when CodeTracer was launched *into* the welcome screen.
  ## Started with `ct run <program>`, the process reached the session tab bar's
  ## "+" button with `data.recentTraces` still empty, and
  ## `ui/welcome_screen.nim:syncLegacyWelcomeScreenIntoVM` mirrored that empty
  ## list into `WelcomeScreenVM` — the Recent Traces panel of the new tab was
  ## blank while the identical click after a welcome-screen launch listed them.
  ##
  ## Only the cache is written here: rendering is not forced, so this cannot
  ## draw the welcome surface over a live debugging session.  When a welcome
  ## screen component already exists (an empty tab is open), its ViewModel is
  ## re-synced so a visible, already-mounted panel picks the lists up
  ## reactively.
  clog "welcome_screen: on recent items"
  data.recentTraces = response.recentTraces
  data.recentFolders = response.recentFolders
  data.stylusTransactions = response.recentTransactions
  if not data.ui.welcomeScreen.isNil:
    data.ui.welcomeScreen.syncLegacyWelcomeScreenIntoVM()

proc onNewNotification(sender: js, notification: Notification) =
  data.viewsApi.showNotification(notification)

proc onCtInstallStatus(sender: js, status: (cstring, cstring)) =
  if status[0] == cstring"ok":
    data.viewsApi.successMessage($(status[1]))
  else:
    data.viewsApi.errorMessage($(status[1]))

proc onSavedAs(sender: js, files: JsAssoc[cstring, cstring]) =
  # discard
  # TODO
  for untitledName, newPath in files:
    data.services.editor.open[newPath] = data.services.editor.open[untitledName]
    data.services.editor.open[newPath].untitled = false
    data.services.editor.open[newPath].changed = false
    data.services.editor.open[newPath].name = newPath
    # data.services.editor.open[newPath].fileInfo.path = newPath
    discard jsDelete(data.services.editor.open[untitledName])
    data.ui.editors[newPath] = data.ui.editors[untitledName]
    discard jsDelete(data.ui.editors[untitledName])
    data.ui.editors[newPath].path = newPath

proc onSavedFile(sender: js, response: jsobject(name=cstring)) =
  if data.services.editor.open.hasKey(response.name):
    data.services.editor.open[response.name].changed = false
    data.services.editor.open[response.name].lastSyncedSource =
      data.services.editor.open[response.name].source
  # The editor-chrome updates below touch GoldenLayout internals
  # (`contentItem.config.componentState`) that are not guaranteed to exist for
  # every tab.  They must never be able to stop `checkPendingReRecord` from
  # running: that call is the *only* thing that drains a queued re-record
  # request, and a throw here left the request armed forever (issue #603).
  try:
    if data.ui.editors.hasKey(response.name):
      let editor = data.ui.editors[response.name]
      if not editor.tabInfo.isNil:
        editor.tabInfo.changed = false
        editor.tabInfo.lastSyncedSource = editor.tabInfo.source
      editor.name = response.name
      if not data.services.search.paths.hasKey(response.name):
        data.services.search.pathsPrepared.add(fuzzysort.prepare(response.name))
        data.services.search.paths[response.name] = true
      var tokens = rsplit($response.name, {'/'}, maxsplit=1)
      var label = $response.name
      if tokens.len >= 2:
        label = tokens[1]
      editor.contentItem.setTitle(cstring(label))
      editor.contentItem.config.componentState.label = response.name
      editor.contentItem.config.componentState.fullPath = response.name
  except:
    cerror "saved-file: could not refresh the editor tab for " &
      $response.name & ": " & getCurrentExceptionMsg()
  checkPendingReRecord(data)
  data.redraw()

proc onSaveFileError(sender: js, response: jsobject(name=cstring, error=cstring)) =
  ## The main process could not write a buffer to disk.
  ##
  ## This message had no subscriber at all: the buffer stayed dirty, a queued
  ## re-record request stayed armed with nothing left to answer it, and the
  ## user was told nothing (issue #603).
  cerror "save-file-error: " & $response.name & ": " & $response.error
  data.viewsApi.errorMessage(
    cstring("Could not save " & $response.name & ": " & $response.error))
  data.noteReRecordSaveOutcome(failed = true)
  data.redraw()

proc saveAllFiles*(data: Data): Future[void] =
  var promise = newPromise[void] do (resolve: proc: void):
    var input = ""

    var i = 0
    var changed: seq[TabInfo]
    for name, tab in data.services.editor.open:
      if tab.changed:
        input.add(&"<label for=tab-{i}>{name}</label><input type=checkbox name=tab-{i} />")
        i += 1
        changed.add(tab)

    if i > 0:
      vex.dialog.open(js{
        message: cstring"",
        input: cstring(&"close: files changed, save?\n{input}"),
        buttons: @[
          vex.dialog.buttons.YES, vex.dialog.buttons.NO
        ],
        callback: proc (checkbox: JsAssoc[cstring, cstring]) =
          if cast[bool](checkbox) == false:
            return
          for name, check in checkbox:
            let i = ($name)[4 .. ^1].parseInt
            if check == cstring"on":
              data.saveFiles(changed[i].name)
            changed[i].changed = false
          resolve()
      })
    else:
      resolve()
  return promise

proc closeAllTabsAfterSave*(data: Data) {.locks: 0.} =
  for id, editorComponent in (data.ui.componentMapping)[Content.EditorView]:
    try:
      # get editor component layout item
      let layoutItem = editorComponent.layoutItem
      let parentContentItem = layoutItem.parent

      # remove component layout item
      if parentContentItem.contentItems.len > 1:
        layoutItem.remove()
      else:
        parentContentItem.remove()

    except Exception as e:
      # maybe removed already
      data.viewsApi.warnMessage(&"warn: {e.msg}")

proc exit*(data: Data) {.async.} =
  await data.saveAllFiles()
  ipc.send "CODETRACER::close-app", js{}

proc closeAllFiles*(data: Data) {.async.} =
  await data.saveAllFiles()
  data.closeAllTabsAfterSave()

proc onClose*(data: Data) =
  discard data.exit()

proc onOpenTraceInTabReady*(sender: js, response: jsobject(traceId=cstring)) =
  ## Handler for the "tab" newTracePolicy.  When a second `ct` instance
  ## sends its trace to the existing window, this handler creates a new
  ## session tab and triggers the trace load.  M-REC-3:
  ## ``response.traceId`` carries a UUIDv7 recording-id string; the JS
  ## IPC field name ``traceId`` is preserved as wire format (M-REC-5
  ## territory).
  let recordingId = response.traceId
  clog "open-trace-in-tab-ready: creating new session and loading recording " & $recordingId
  createNewSession(data)
  # After creating the session, send the load-recent-trace IPC so the
  # main process starts the replay backend for the new trace.
  data.ipc.send cstring"CODETRACER::load-recent-trace", js{traceId: recordingId}

proc onOpenEditFolderInTabReady*(
    sender: js,
    response: jsobject(folderPath=cstring)) =
  ## Handler for the "tab" newTracePolicy.  When a second `ct edit <path>`
  ## invocation delegates to the existing window, open a new session tab and
  ## initialize it with the requested workspace folder.
  clog "open-edit-folder-in-tab-ready: creating new session and loading folder " &
    $response.folderPath
  createNewSession(data)
  data.ipc.send cstring"CODETRACER::init-edit-mode",
    js{folder: response.folderPath}

proc onTraceLoadError*(sender: js, response: jsobject(error=cstring)) =
  ## Handler for trace loading errors (e.g. from the Trace Macro action).
  ## Displays the error message to the user via the views API.
  let errorMsg = response.error
  cwarn "trace-load-error: " & errorMsg
  data.viewsApi.errorMessage(errorMsg)

proc onReviewDatasetRead*(sender: js,
    response: jsobject(anchorId=cstring, datasetPath=cstring, kind=cstring,
                       ok=bool, message=cstring, fileCount=int,
                       commit=cstring, dataset=DeepReviewData)) =
  ## AA-3 — the main process answered a request from an evidence card
  ## (`index/review_dataset.onOpenReviewDataset`).
  ##
  ## Two shapes, one channel, because both carry the same fact — what is at
  ## that path — and the panel has to record it either way.  Even the *open*
  ## request lands its shape first: if the dataset vanished between the
  ## inspection and the click, the card must stop offering the affordance and
  ## start saying why, which is §2.1.1's "a dataset that no longer exists says
  ## so when selected, rather than entering an empty review".
  let datasetPath = $response.datasetPath
  if datasetPath.len == 0:
    return
  agent_activity.applyAgentActivityEvidenceDataset(
    datasetPath,
    if response.ok:
      EvidenceDataset(
        state: edsReady,
        fileCount: response.fileCount,
        commit: $response.commit)
    else:
      EvidenceDataset(state: edsUnavailable, message: $response.message))
  if not response.ok or response.kind != cstring"open":
    return
  if response.dataset.isNil:
    # `ok` with no payload would silently enter an empty review, which is the
    # outcome §2.1.1 names as the thing to avoid.
    cerror "review-dataset-read: open answered without a dataset for " &
      datasetPath
    return
  # The ordinary review-entry path from here on: publish the dataset where
  # every launch path publishes it, then the one host entry point.
  vcs.openReviewDataset(data, response.dataset)

# ---------------------------------------------------------------------------
# NS9's two panes, filled by whichever host this build has
#
# ONE MESSAGE, TWO HOSTS, and that is the point rather than an implementation
# detail. `CODETRACER::ns9-panes` asks "what tests does this project have, and
# what does its circuit cost". The Electron index answers it by running the
# `ct test` Noir provider in-process and `nargo info --json` as a subprocess;
# `ui/web_entry_surface.installTemplateHost` answers it for the bundled
# template out of the bundle. The renderer cannot tell which answered, which is
# what keeps the panes CodeTracer's rather than the studio's
# (`Planned-Features/Noir-Studio.md` §3).
# ---------------------------------------------------------------------------

var noirTestRunCounter = 0
  ## Which wasm test run this is, for `TestEvent.runId`.
  ##
  ## A counter and not a timestamp: `runId` is only ever compared for equality
  ## within one stream, and `test_run_summary_vm.ingestTestEvent` fills it from
  ## the first event it sees. A clock would make two runs in the same
  ## millisecond indistinguishable, which is exactly what a double-click does.

proc onNs9PanesCatalog(
    sender: js,
    response: jsobject(catalog=cstring, absence=cstring)) =
  ## The project's test catalog, in `contracts.toJson`'s shape.
  test_results.initTestResultsVM()
  if test_results.testResultsVMInstance.isNil:
    return
  let absence = $response.absence
  test_results.testResultsVMInstance.setRunAbsence(absence)
  let raw = $response.catalog
  if raw.len == 0:
    return
  try:
    test_results.testResultsVMInstance.setCatalog(
      testCatalogFromJson(parseJson(raw)))
  except CatchableError:
    # A catalog that will not parse is a host fault, and the pane must not
    # pretend the project has no tests because of it — that is the reading
    # `absence` exists to make impossible.
    cerror "ns9-panes: the test catalog did not parse: " &
      getCurrentExceptionMsg()
    test_results.testResultsVMInstance.setRunAbsence(
      "The host sent a test catalog this build could not read.")

proc onNs9PanesConstraints(
    sender: js,
    response: jsobject(info=cstring, provenance=cstring, absence=cstring)) =
  ## `nargo info --json`, verbatim, or a stated reason there is none.
  constraints.initConstraintsVM()
  if constraints.constraintsVMInstance.isNil:
    return
  let absence = $response.absence
  if absence.len > 0:
    constraints.constraintsVMInstance.setAbsence(absence)
    return
  constraints.constraintsVMInstance.setReport(
    parseNargoInfoJson($response.info, $response.provenance))

macro uiIpcHandlers*(namespace: static[string], messages: untyped): untyped =
  let ipc = ident("ipc")
  let data = ident("data")
  result = nnkStmtList.newTree()
  for message in messages:
    var fullMessage: NimNode
    var handler: NimNode
    var messageCode: NimNode
    if message.kind == nnkStrLit:
      fullMessage = (namespace & $message).newLit
      handler = (("on-" & $message).toCamelCase).ident
      messageCode = quote:
        `ipc`["on"].call(`ipc`, `fullMessage`, `handler`)
    else:
      # a:t => b
      # echo message.treerepr
      fullMessage = (namespace & $(message[0])).newLit
      var elements: seq[NimNode]
      if message[1][0][2].kind == nnkIdent:
        elements.add(message[1][0][2])
      else:
        for element in message[1][0][2]:
          elements.add(element)
      let response = ident("response")
      var handlers = nnkStmtList.newTree()
      let temp = message[1][0][1]
      for element in elements:
        if element.repr != "ui":
          let service = element
          let name = (("on-" & $(message[0])).toCamelCase).ident
          handler = quote:
            discard functionAsJS(`data`.services.`service`.`name`).call(jsUndefined, `data`.services.`service`, `response`)
        else:
          let name = (("on-" & $(message[0])).toCamelCase).ident
          let nameLit = newLit($name)
          handler = quote:
            # var i = 0
            # while true:
            #   # echo i
            #   if i == `data`.ui.list.len or i > 50:
            #     break
            #   var component = `data`.ui.list[i]
            for content, map in `data`.ui.componentMapping:
              for id, component in map:
                # echo "=> component for content ", content, " with id ", id
                # echo "  method  ", `nameLit`
                # EDIT: now mostly middleware/`self.api.subscribe` is needed/used!
                discard component.`name`(cast[`temp`](`response`))
        handlers.add(handler)
      messageCode = quote:
        `ipc`["on"].call(`ipc`, `fullMessage`) do (sender: js, `response`: js):
          echo "-> received: ", `fullMessage`
          `handlers`
      # echo messageCode.repr
    result.add(messageCode)
  # echo result.repr

proc configureIPC(data: Data) =
  uiIpcHandlers("CODETRACER::"):
    # "new-record-window"
    "record-path"
    "path-validated"
    "successful-record"
    "failed-record"
    "loading-trace"

    "trace-loaded"
    "update-trace"
    "start-shell-ui"
    "start-deepreview"

    "no-trace"
    "ns9-panes-catalog"
    "ns9-panes-constraints"
    "welcome-screen"
    # #568: the recent-traces / recent-folders push for startup paths whose own
    # startup message does not carry them (`index/recent_items.nim`).
    "recent-items"
    "saved-as"
    "saved-file"
    "save-file-error"

    # notifications
    "new-notification"
    "ct-install-status"

    "init"
    "tab-load-received"
    "asm-load-received"
    "load-locals-received"
    "expand-value-received"
    "evaluate-expression-received"
    "expand-values-received"
    "search-calltrace-received"
    "load-parsed-exprs-received"
    "updated-events": seq[EventElement] => eventLog
    "updated-events-content": cstring => eventLog
    "updated-trace": TraceUpdate => [ui]
    "updated-history": HistoryUpdate => [ui]
    "updated-flow": FlowUpdate => [ui]
    # "loaded-terminal": seq[ProgramEvent] => [ui]
    # "updated-table": TableUpdate => [ui]
    # "updated-call-args": CallArgsUpdateResults => [ui]
    "updated-watches": JsAssoc[cstring, Value] => debugger
    "updated-shell": ShellUpdate => shell
    "loaded-flow-shape": FlowShape => [ui]
    "context-start-trace"
    "context-start-history"
    "complete-move": MoveState => [debugger, editor, eventLog, ui]
    "tracepoint-locals": TraceValues => [ui]
    "loaded-locals": JsAssoc[cstring, Value] => debugger
    "search-results-updated": seq[SearchResult] => search
    "load-callstack-received"
    "debug-output": DebugOutput => [debugger, ui]
    "log-output"
    # filesystem handlers
    "filesystem-loaded"
    "filesystem-category-loaded"
    "update-path-content"
    "load-folder-edit-mode"
    "launch-configs-loaded"
    # load trace resources
    "filenames-loaded"
    "symbols-loaded"
    "build-stdout": BuildOutput => [ui]
    "build-stderr": BuildOutput => [ui]
    "build-code": BuildCode => [ui]
    "build-command": BuildCommand => [ui]
    "started"
    "change-file"
    "reload-file"
    "tab-reloaded"
    "opened-tab": OpenedTab => editor
    "close"
    "open-location"
    "add-breakpoint"
    "run-to"
    "collapse-expansion"
    "collapse-all-expansion"
    "add-break-response": BreakpointInfo => debugger
    "add-break-c-response": BreakpointInfo => debugger
    "debugger-started": int => [debugger, ui]
    "output-jump-from-shell-ui": int => ui
    "program-search-results": seq[CommandPanelResult] => ui
    "updated-load-step-lines": LoadStepLinesUpdate => ui

    "finished": JsObject => debugger
    "error": DebuggerError => [debugger, ui]
    "failed-download"
    "successful-download"

    "follow-history"

    "upload-trace-file-received"
    "upload-trace-progress": UploadProgress => ui
    "delete-online-trace-file-received"
    "menu-action"

    # Dap communication
    "dap-receive-response"
    "dap-receive-event"
    "dap-replay-selected"
    "dap-live-session-selected"

    # Acp communication
    # TODO: Rename to "acp-session-update"
    "acp-session-ready"
    "acp-session-load-error"
    "acp-receive-response"
    "acp-prompt-start"
    "acp-create-terminal"
    "acp-request-permission"
    "acp-render-diff"

    "reload-file"

    # Tab-vs-window policy: open a trace as a new tab in the current window
    "open-trace-in-tab-ready"
    "open-edit-folder-in-tab-ready"

    # Trace macro (M11): error loading a .ct file from the langserver
    "trace-load-error"

    # AA-3: the answer to `open-review-dataset` — a review dataset an
    # evidence tool call in the Agent Activity session feed names, either
    # summarised or handed over whole.
    "review-dataset-read"

  duration("configureIPCRun")


proc restoreLayoutState*(layout: GoldenLayout, conf: GoldenLayoutResolvedConfig) =
  # Remove all content items from the root
  let root = layout.root
  let contentItems = root.contentItems  # Assuming this is an array of items

  # Loop through contentItems and remove each one
  for item in contentItems:
    item.remove()  # Assuming remove is a method on the content items

  # Now restore content from the passed `GoldenLayoutResolvedConfig`
  for item in conf.root:
    root.addChild(item)  # Assuming addChild is a method to add items back into the layout

# Function to update the headerHeight in the layout configuration
proc updateGoldenLayoutHeaderHeight(data: Data, emValue: int) =
  let newHeaderHeight = data.ui.fontSize * emValue
  data.ui.layout.layoutConfig.dimensions.headerHeight = newHeaderHeight

proc updateEditors(data: Data) =
  for path, editor in data.ui.monacoEditors:
    let options = cast[MonacoEditorOptions](editor.getOptions())
    options.fontSize = data.ui.fontSize
    options.lineNumbersMinChars = monacoLineNumbersMinChars(editor.getModel().getLineCount())
    options.lineDecorationsWidth = monacoLineDecorationsWidth(data.ui.fontSize)
    editor.updateOptions(options)
  for path, editor in data.ui.traceMonacoEditors:
    let options = cast[MonacoEditorOptions](editor.getOptions())
    options.fontSize = data.ui.fontSize
    editor.updateOptions(options)
  for path, editor in data.ui.editors:
    if not editor.flow.isNil and not editor.flow.flow.isNil:
      editor.flow.redrawFlow()
    for id, zone in editor.testDom:
      let textModel = editor.monacoEditor.getModel()
      let lineContent = textModel.getLineContent(id)
      let editorConfiguration = editor.monacoEditor.config
      let lineHeight = editorConfiguration.lineHeight
      zone.toJs.firstChild.style.left = fmt"calc({lineContent.len()}ch + 1ch)"
      zone.toJs.firstChild.style.lineHeight = fmt"{lineHeight}px"
    for line, zone in editor.diffViewZones:
      zone.dom.style.fontSize = cstring($(data.ui.fontSize)) & cstring"px"
      let editorContentLeft = editor.monacoEditor
        .getOption(LAYOUT_INFO).contentLeft + EDITOR_GUTTER_PADDING
      zone.dom.style.left = fmt"-{editorContentLeft}px"
    for line, diffEditor in editor.diffEditors:
      let options = cast[MonacoEditorOptions](diffEditor.getOptions())
      options.fontSize = data.ui.fontSize
      options.lineNumbersMinChars = monacoLineNumbersMinChars(diffEditor.getModel().getLineCount())
      options.lineDecorationsWidth = monacoLineDecorationsWidth(data.ui.fontSize)
      diffEditor.updateOptions(options)
  # Agent diff Editors
  for a in data.ui.componentMapping[Content.AgentActivity]:
    let agent = cast[AgentActivityComponent](a)
    for _, diff in agent.diffEditors:
      let orgEditor = diff.getOriginalEditor()

      let options = orgEditor.getOptions()
      options.fontSize = data.ui.fontSize
      diff.updateOptions(cast[MonacoEditorOptions](options))

proc updateDataTables(data: Data) =
  for _, component in data.ui.componentMapping[Content.EventLog]:
    if not component.isNil:
      EventLogComponent(component).resizeEventLogHandler()

  for _, component in data.ui.componentMapping[Content.Trace]:
    if not component.isNil:
      let trace = TraceComponent(component)
      trace.refreshTraceComponentLayout()

proc refreshCalltraceOverlays(data: Data) =
  for _, component in data.ui.componentMapping[Content.Calltrace]:
    if not component.isNil:
      let calltrace = CalltraceComponent(component)
      if calltrace.usesMaterializedTracesTrace:
        calltrace.refreshTraceOverlay()

proc updateLayout(data: Data) =
  dom.document.documentElement.style.fontSize = &"{data.ui.fontSize}px"
  data.updateGoldenLayoutHeaderHeight(2)

  data.ui.layout.updateSize()

proc zoomInEditors*(data: Data) =
  if data.ui.fontSize < MAX_FONTSIZE:
    data.ui.fontSize += 2
    data.updateLayout()
    data.updateEditors()

    redrawAll()
    discard setTimeout(proc =
      data.updateDataTables()
      data.refreshCalltraceOverlays()
    , 0)
    clog "editor: zoom in!"

proc zoomOutEditors*(data: Data) =
  if data.ui.fontSize > MIN_FONTSIZE:
    data.ui.fontSize -= 2

    data.updateLayout()
    data.updateEditors()

    redrawAll()
    discard setTimeout(proc =
      data.updateDataTables()
      data.refreshCalltraceOverlays()
    , 0)
    clog "editor: zoom out!"

proc zoomFlowLoopIn*(data: Data) =
  let flow = data.ui.editors[data.services.editor.active].flow
  for loopIndex, state in flow.loopStates:
    if state.viewState == LoopShrinked:
      resetShrinkedLoopIterations(flow)
      state.defaultIterationWidth = state.minWidth
      flow.resetColumnsWidth(1, loopIndex, true)
      state.viewState = LoopValues
    else:
      state.defaultIterationWidth += 1
      flow.resetColumnsWidth(1, loopIndex, false)
  discard calculateLoopSliderWidth(flow)

proc zoomFlowLoopOut*(data: Data) =
  let flow = data.ui.editors[data.services.editor.active].flow
  for loopIndex, state in flow.loopStates:
    if state.defaultIterationWidth > state.minWidth:
      state.defaultIterationWidth -= 1
      flow.resetColumnsWidth(-1, loopIndex, false)
    else:
      if state.viewState != LoopShrinked:
        flow.shrinkLoopIterations(loopIndex)

proc setFlowTypeToMultiline*(data: Data) =
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow
  flow.switchFlowType(FlowMultiline)

proc setFlowTypeToParallel*(data: Data) =
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow
  flow.switchFlowType(FlowParallel)

proc setFlowTypeToInline*(data: Data) =
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow
  flow.switchFlowType(FlowInline)

proc switchFocusedLoopLevelAtPosition*(data: Data) =
  console.time("switchFocusedLoopLevelAtPosition")
  let activeEditor = data.ui.editors[data.services.editor.active]
  let flow = activeEditor.flow

  # get active editor current position
  let monaco = activeEditor.monacoEditor
  let currentEditorPosition = monaco.getPosition().toJs.lineNumber.to(int)

  if not toSeq(flow.flow.positionStepCounts.keys())
    .any(key => key == currentEditorPosition):
      cwarn "flow: no flow at this position"
      return

  # get loops at current position
  let loopsAtCurrentPosition = flow.flowLines[currentEditorPosition].loopIds

  # get currently focused loops
  let currentFocusedLoops = flow.getFocusedLoopsIds()

  if loopsAtCurrentPosition.len > 0 and
    loopsAtCurrentPosition.all(loopIndex => not flow.loopStates[loopIndex].focused):

    # first loop at current position
    let firstLoop = flow.flow.loops[loopsAtCurrentPosition[0]]
    let firstLoopFirstLine = firstLoop.first
    # flow line width at first line of first loop at current position
    let sliderPosition = flow.flowLines[firstLoopFirstLine].sliderPosition
    let sliderPositionLoop = sliderPosition.loopIndex
    let sliderPositionIteration = sliderPosition.iteration
    let step = flow.flow.steps.filterIt(
      it.position == firstLoopFirstLine and
      it.loop == sliderPositionLoop and
      it.iteration == sliderPositionIteration)[0]
    var stepNode = flow.stepNodes[step.stepCount]

    let stepNodeOffset = flow.getStepDomOffsetLeft(step)

    # remove focus on focused loops
    for loopIndex in currentFocusedLoops:
      flow.loopStates[loopIndex].focused = false

    # switch focused loops
    for loopIndex in loopsAtCurrentPosition:
      flow.loopStates[loopIndex].focused = true

    # recalculate loop iterationsWidth
    flow.calculateFlowLoopIterationsWidths()

    # recalculate flowLines width
    for line, flowLine in flow.flowLines:
      flowLine.totalLineWidth = flow.calclulateFlowLineTotalWidth(line)

    flow.redrawLinkedLoops()

    flow.move(sliderPositionLoop, sliderPositionIteration, firstLoopFirstLine, refocus = true)

    flow.updateFlowDom()
  console.timeEnd("switchFocusedLoopLevelAtPosition")

proc restartCodetracer*(data: Data) =
  data.ipc.send "CODETRACER::restart", js{}

proc switchFocusedLoopLevelUp*(data: Data) =
  let flow = data.ui.editors[data.services.editor.active].flow
  let currentFocusedLoops = flow.getFocusedLoopsIds()

  # switch focused loops
  var focusedLoops: seq[int] = @[]
  for loopIndex in currentFocusedLoops:
    let parentLoopIndex = flow.flow.loops[loopindex].base
    if parentLoopIndex != -1:
      flow.loopStates[loopIndex].focused = false
      flow.loopStates[parentLoopIndex].focused = true
      if not focusedLoops.any(index => index == parentLoopIndex):
        focusedLoops.add(parentLoopIndex)

  # recalculate loop iterationsWidth
  flow.calculateFlowLoopIterationsWidths()

  # recalculate flowLines width
  for line, flowLine in flow.flowLines:
    flowLine.totalLineWidth = flow.calclulateFlowLineTotalWidth(line)

  # redraw loops
  flow.redrawLinkedLoops()

proc switchFocusedLoopLevelDown*(data: Data) =
  discard

template pointsOperationsSetup(data: Data): untyped =
  let
    debuggerService {.inject.} = data.services.debugger
    activeEditorPath {.inject.} = data.services.editor.active
    editor {.inject.} = data.ui.editors[activeEditorPath]
    monacoEditor {.inject.} = editor.monacoEditor
    line {.inject.} = monacoEditor.getPosition().lineNumber

proc expandWholeSource*(data: Data) =
  data.pointsOperationsSetup()
  monacoEditor.trigger("unfold", "editor.unfoldAll")

proc collapseWholeSource*(data: Data) =
  data.pointsOperationsSetup()
  monacoEditor.trigger("fold", "editor.foldAll")

proc toggleMinimap*(data: Data) =
  discard

proc addBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.addBreakpoint(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc removeBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.deleteBreakpoint(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc removeAllBreakpoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, point in debuggerService.breakpointTable[activeEditorPath]:
    debuggerService.deleteBreakpoint(activeEditorPath, line)
    editor.refreshEditorLine(line)

proc enableBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.enable(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc enableAllBreakpoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, point in debuggerService.breakpointTable[activeEditorPath]:
    debuggerService.enable(activeEditorPath, line)
    editor.refreshEditorLine(line)

proc disableBreakpointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  debuggerService.disable(activeEditorPath, line)
  editor.refreshEditorLine(line)

proc disableAllBreakpoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, point in debuggerService.breakpointTable[activeEditorPath]:
    debuggerService.disable(activeEditorPath, line)
    editor.refreshEditorLine(line)

proc addTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if not editor.traces.hasKey(line):
    editor.toggleTrace(editor.name, line)

proc removeTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if editor.traces.hasKey(line):
    let trace = editor.traces[line]
    trace.closeTrace()

proc enableTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if editor.traces.hasKey(line):
    let trace = editor.traces[line]
    if trace.isDisabled:
      trace.toggleTraceState()

proc enableAllTracepoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, trace in editor.traces:
    if trace.isDisabled:
      trace.toggleTraceState()

proc disableTracepointAtPosition*(data: Data) =
  data.pointsOperationsSetup()
  if editor.traces.hasKey(line):
    let trace = editor.traces[line]
    if not trace.isDisabled:
      trace.toggleTraceState()

proc disableAllTracepoints*(data: Data) =
  data.pointsOperationsSetup()
  for line, trace in editor.traces:
    if not trace.isDisabled:
      trace.toggleTraceState()

# ---------------------------------------------------------------------------
# M5 — Column-Aware Replay Navigation: Nim-JS service-method exposure.
#
# The M1/M2/M3/M7 milestones introduced five procs on
# ``DebuggerService`` in
# ``src/frontend/services/debugger_service.nim``:
#
#   * ``addColumnBreakpoint``         (M1)
#   * ``stepOverStatement``           (M2)
#   * ``stepBackStatement``           (M7, reverse-direction mirror of M2)
#   * ``setActiveSourceView``         (M3)
#   * ``installSourceViewForTest``    (M3, test-only debug surface)
#
# The GUI Playwright specs call them as JS methods via
# ``window.data.services.debugger.<method>(...)``.  Two distinct
# obstacles previously made this fail:
#
# (1) Dead-code elimination.  Nim's JS backend emits a proc only when
#     some reachable Nim caller references it.  None of the four procs
#     had a Nim caller (their consumers are JS-side tests), so they
#     were stripped from the generated ``ui.js`` and the Playwright
#     specs failed with ``... is not a function``.  ``thunkM5...``
#     procs below resolve this — each one references the underlying
#     service proc, and the thunks themselves are kept reachable via
#     the call to ``installM5ColumnAwareServiceMethods()`` at module
#     init.
#
# (2) Method-style dispatch.  ``DebuggerService`` is a Nim ``ref
#     object``.  Nim's JS backend emits procs that take ``self`` as a
#     first parameter — they are NOT attached as methods on the JS
#     prototype, and ``data.services.debugger.addColumnBreakpoint`` is
#     ``undefined`` even when the proc is reachable.  We bridge this
#     with a JS thunk: ``installM5ColumnAwareServiceMethods`` attaches
#     each thunk as a property on the live ``data.services.debugger``
#     instance.  When the spec calls
#     ``svc.addColumnBreakpoint.call(svc, p, l, c)`` the thunk re-routes
#     the arguments through the Nim proc.
#
# The thunks deliberately reach for ``data.services.debugger`` at call
# time rather than capturing the instance, so multi-replay session
# switching (the ``activeSessionIndex`` forwarder in ``types.nim``
# §multi-session) keeps working — the thunk always targets the active
# session's ``DebuggerService``.
#
# Avoiding closures here is also a JS-codegen workaround: Nim's JS
# backend trips an ``env.kind == nkSym`` assertion when emitting
# ``proc()`` closures that capture module-scope globals.  Using
# top-level ``proc`` thunks with no captures sidesteps that bug.
#
# See ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
# §M5 for the contract.
proc thunkM5AddColumnBreakpoint(path: cstring, line, column: int,
                                condition: cstring = cstring"") =
  ## M1 base — register a column-aware breakpoint via
  ## ``data.services.debugger.addColumnBreakpoint(path, line, column)``.
  ##
  ## M9 — the optional fourth argument ``condition`` is forwarded to
  ## the underlying service method so the GUI Playwright spec can drive
  ## a column-aware conditional breakpoint via
  ## ``data.services.debugger.addColumnBreakpoint.call(svc, path, line,
  ## column, "i > 100")``.  Empty/missing condition preserves the M1
  ## unconditional behaviour.
  data.services.debugger.addColumnBreakpoint(path, line, column, condition)

proc thunkM5AddColumnTracepoint(path: cstring, line, column: int,
                                logMessage: cstring) =
  ## M10 — register a column-aware tracepoint (DAP logpoint) via
  ## ``data.services.debugger.addColumnTracepoint(path, line, column,
  ## logMessage)``.  Same DCE / method-style-dispatch rationale as the
  ## M1 thunk above (see the M5 banner comment).  Exposed to the JS
  ## layer so the M10 GUI Playwright spec can drive a column-aware
  ## logpoint via
  ## ``data.services.debugger.addColumnTracepoint.call(svc, path, line,
  ## column, "hit b")``.
  data.services.debugger.addColumnTracepoint(path, line, column, logMessage)

proc thunkM5StepOverStatement() =
  data.services.debugger.stepOverStatement()

proc thunkM5StepBackStatement() =
  ## M7 — time-travel symmetric counterpart of
  ## [`thunkM5StepOverStatement`].  Exposes
  ## ``data.services.debugger.stepBackStatement()`` to the JS layer so
  ## the GUI Playwright spec and any external test harness can drive
  ## the column-aware backward statement step via the same
  ## ``page.evaluate`` pattern the M2 forward affordance uses.  See
  ## the comment block above the M5 thunks for the dead-code-
  ## elimination + method-style dispatch rationale.
  data.services.debugger.stepBackStatement()

proc thunkM5SetActiveSourceView(viewPath: cstring) =
  data.services.debugger.setActiveSourceView(viewPath)

proc thunkM5InstallSourceViewForTest(
    recordedPath, formattedViewPath, sourcemapV3Json: cstring) =
  data.services.debugger.installSourceViewForTest(
    recordedPath, formattedViewPath, sourcemapV3Json)

proc thunkM5DapSendCtRequest(kindOrdinal: int, rawValue: JsObject) =
  ## The M3 GUI spec drives a plain DAP ``next`` via
  ## ``data.dapApi.sendCtRequest(DapNext, {threadId: 1})`` — the same
  ## pipeline ``DebuggerService.step`` uses for the F10 keybind path.
  ## Without an exposed method dispatch the spec fails with
  ## "Neither dapApi.sendCtRequest nor services.debugger.stepForward
  ## is reachable".  We re-route through the underlying Nim proc with
  ## the ordinal coerced back to ``CtEventKind`` (the wire enum is a
  ## plain ordinal in JS).
  data.dapApi.sendCtRequest(cast[CtEventKind](kindOrdinal), rawValue)

proc installM5ColumnAwareServiceMethods() =
  ## Attach the M1/M2/M3 service procs and the M3 DAP-pipeline
  ## entry-point as JS methods on the live ``DebuggerService`` and
  ## ``DapApi`` instances.  Idempotent.
  let svc = cast[JsObject](data.services.debugger)
  if not svc.isNil:
    svc["addColumnBreakpoint"] = cast[JsObject](thunkM5AddColumnBreakpoint)
    svc["addColumnTracepoint"] = cast[JsObject](thunkM5AddColumnTracepoint)
    svc["stepOverStatement"] = cast[JsObject](thunkM5StepOverStatement)
    svc["stepBackStatement"] = cast[JsObject](thunkM5StepBackStatement)
    svc["setActiveSourceView"] = cast[JsObject](thunkM5SetActiveSourceView)
    svc["installSourceViewForTest"] =
      cast[JsObject](thunkM5InstallSourceViewForTest)
  let dap = cast[JsObject](data.dapApi)
  if not dap.isNil:
    dap["sendCtRequest"] = cast[JsObject](thunkM5DapSendCtRequest)

installM5ColumnAwareServiceMethods()

const ClientActionCount = ClientAction.high.int - ClientAction.low.int + 1

# static:
  # echo ClientActionCount

proc isEditorFocused(data: Data): bool =
  for editor in data.ui.monacoEditors:
    if editor.hasTextFocus():
      return true

  for editor in data.ui.traceMonacoEditors:
    if editor.hasTextFocus():
      return true

proc isInputElementFocused(data: Data): bool =
  var element: JsObject = cast[JsObject](dom.window.document.activeElement)
  return element.tagName.to(cstring) == cstring("INPUT")

proc toggleTracepoint*(path: cstring, line: int) {.exportc.} =
  data.ui.editors[path].toggleTrace(path, line)

proc openCollabInviteDialog(presets: seq[cstring]) {.importjs: """
(async function(presets) {
  const hostGrants = [
    "observe",
    "publishAwareness",
    "mutateSharedViewState",
    "controlDebugger",
    "manageBreakpoints",
    "manageWatches",
    "manageLayout",
    "grantCapabilities",
    "invite",
    "exportSession",
    "hostBackend"
  ];
  const createInvite = async function(normalized, tenantId, replayId) {
    const response = await fetch(
      "/api/v1/tenants/" + encodeURIComponent(tenantId) +
        "/replays/" + encodeURIComponent(replayId) + "/collab/invites",
      {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          grantPreset: normalized,
          expiresInSeconds: 3600
        })
      });

    if (!response.ok) {
      const body = await response.text();
      throw new Error(
        "Could not create collaboration invite: " + response.status + " " + body);
    }

    const invite = await response.json();
    window.CODETRACER_LAST_COLLAB_INVITE = invite;
    const activate = typeof window.activateCollabHostInvite === "function"
      ? window.activateCollabHostInvite
      : (typeof activateCollabHostInvite === "function"
        ? activateCollabHostInvite
        : null);
    if (typeof activate === "function") {
      const activationRaw = activate(JSON.stringify({
        replayId,
        traceId: window.CODETRACER_TRACE_ID || replayId,
        traceIdentity: window.CODETRACER_TRACE_ID || replayId,
        roomId: invite.roomId,
        initialGrants: hostGrants,
        webUiUrl: invite.joinUrl,
        nativeJoinUrl: invite.joinUrl,
        rendezvousUrl: "/api/v1/collab/rooms/" +
          encodeURIComponent(invite.roomId) + "/rendezvous",
        transportHints: ["browser-channel", "viewops-not-accepted"]
      }));
      try {
        window.CODETRACER_COLLAB_HOST_SESSION = JSON.parse(activationRaw);
      } catch (_error) {
        window.CODETRACER_COLLAB_HOST_SESSION = { activated: false };
      }
    }
    return invite;
  };
  window.__ctTestCreateCollabInvite = createInvite;

  const preset = window.prompt(
    "Collaboration role preset (Viewer, Driver, Host)",
    "Viewer");
  if (preset === null) return;

  const normalized = presets.find((candidate) =>
    candidate.toLowerCase() === String(preset).trim().toLowerCase());
  if (!normalized) {
    window.alert("Unknown collaboration role preset.");
    return;
  }

  const tenantId = window.CODETRACER_TENANT_ID ||
    window.localStorage.getItem("CODETRACER_TENANT_ID") ||
    window.prompt("Tenant UUID for this replay");
  if (!tenantId) return;

  const replayId = window.CODETRACER_REPLAY_ID ||
    window.localStorage.getItem("CODETRACER_REPLAY_ID") ||
    window.prompt("Running replay UUID");
  if (!replayId) return;

  let invite = null;
  try {
    invite = await createInvite(normalized, tenantId, replayId);
  } catch (error) {
    window.alert(String(error && error.message || error));
    return;
  }
  if (navigator.clipboard && navigator.clipboard.writeText) {
    await navigator.clipboard.writeText(invite.joinUrl);
  }

  const revoke = window.confirm(
    "Join URL copied:\n" + invite.joinUrl + "\n\nRevoke this invite now?");
  if (!revoke) return;

  await fetch(
    "/api/v1/tenants/" + encodeURIComponent(tenantId) +
      "/collab/invites/" + encodeURIComponent(invite.inviteId) + "/revoke",
    {
      method: "POST",
      credentials: "include",
      headers: { "Content-Type": "application/json" },
      body: "{}"
    });
})(#)
""".}

proc installCollabInviteTestHooks() {.importjs: """
(function() {
  if (window.__ctTestCreateCollabInvite) return;
  const hostGrants = [
    "observe",
    "publishAwareness",
    "mutateSharedViewState",
    "controlDebugger",
    "manageBreakpoints",
    "manageWatches",
    "manageLayout",
    "grantCapabilities",
    "invite",
    "exportSession",
    "hostBackend"
  ];
  window.__ctTestCreateCollabInvite = async function(normalized, tenantId, replayId) {
    const response = await fetch(
      "/api/v1/tenants/" + encodeURIComponent(tenantId) +
        "/replays/" + encodeURIComponent(replayId) + "/collab/invites",
      {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          grantPreset: normalized,
          expiresInSeconds: 3600
        })
      });
    if (!response.ok) {
      throw new Error(await response.text());
    }
    const invite = await response.json();
    window.CODETRACER_LAST_COLLAB_INVITE = invite;
    const activate = typeof window.activateCollabHostInvite === "function"
      ? window.activateCollabHostInvite
      : (typeof activateCollabHostInvite === "function"
        ? activateCollabHostInvite
        : null);
    if (typeof activate === "function") {
      const activationRaw = activate(JSON.stringify({
        replayId,
        traceId: window.CODETRACER_TRACE_ID || replayId,
        traceIdentity: window.CODETRACER_TRACE_ID || replayId,
        roomId: invite.roomId,
        initialGrants: hostGrants,
        webUiUrl: invite.joinUrl,
        nativeJoinUrl: invite.joinUrl,
        rendezvousUrl: "/api/v1/collab/rooms/" +
          encodeURIComponent(invite.roomId) + "/rendezvous",
        transportHints: ["browser-channel", "viewops-not-accepted"]
      }));
      try {
        window.CODETRACER_COLLAB_HOST_SESSION = JSON.parse(activationRaw);
      } catch (_error) {
        window.CODETRACER_COLLAB_HOST_SESSION = { activated: false };
      }
    }
    return invite;
  };
})()
""".}

installCollabInviteTestHooks()

var actions*: array[ClientAction, ClientActionHandler] = [
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"continue"):
      forwardContinue(fromShortcut=true),
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"reverse-continue"):
      reverseContinue(fromShortcut=true),
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"next"):
      next(fromShortcut=true),
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"reverse-next"):
      reverseNext(fromShortcut=true),
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"step-in"):
      stepIn(fromShortcut=true),
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"reverse-step-in"):
      reverseStepIn(fromShortcut=true),
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"step-out"):
      stepOut(fromShortcut=true),
  proc(actionData: JsObject) =
    if not invokeDebugStepAction(cstring"reverse-step-out"):
      reverseStepOut(fromShortcut=true),
  proc(actionData: JsObject) = stopAction(),
  proc(actionData: JsObject) = data.update(build=true),
  proc(actionData: JsObject) = switchTab(change = -1),
  proc(actionData: JsObject) = switchTab(change = 1),
  proc(actionData: JsObject) = data.switchTabHistory(),
  proc(actionData: JsObject) = openFile(),
  proc(actionData: JsObject) = data.openNewTab(),
  proc(actionData: JsObject) = data.reopenLastTab(),
  proc(actionData: JsObject) = data.closeActiveTab(),
  proc(actionData: JsObject) = data.switchToEdit(),
  proc(actionData: JsObject) = data.switchToDebug(),
  proc(actionData: JsObject) = data.commandSearch(),
  proc(actionData: JsObject) = data.fileSearch(),
  proc(actionData: JsObject) = data.fixedSearch(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.delete(),
  proc(actionData: JsObject) = discard data.onSelectFlow(),
  proc(actionData: JsObject) = discard data.onSelectState(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onUp(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onDown(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onRight(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onLeft(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onPageUp(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil and not data.isEditorFocused() and not data.isInputElementFocused():
      discard data.ui.activeFocus.onPageDown(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onGotoStart(),
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onGotoEnd(),
  proc(actionData: JsObject) = # aEnter
    # echo "global array map: enter"
    # affects only renderer, map manually editor differently
    if not data.ui.activeFocus.isNil and not data.isInputElementFocused():
      # echo "  => global array map: enter: activeFocus not nil, calling its method"
      discard data.ui.activeFocus.onEnter(),
  proc(actionData: JsObject) = # goUp
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onEscape(),
  proc(actionData: JsObject) = data.zoomInEditors(),
  proc(actionData: JsObject) = data.zoomOutEditors(),
  (proc(actionData: JsObject) = echo "example"),
  proc(actionData: JsObject) = discard data.exit(), # aExit
  proc(actionData: JsObject) = data.openNewTab(), # NewFile
  proc(actionData: JsObject) = data.openPreferences(), # TODO: fix bottom panels Preferences
  nil,# TODO proc = data.openNewTab(folder=true), # NewFold
  nil,# TODO OpenRecent
  # aSave
  proc(actionData: JsObject) = data.saveFiles(data.services.editor.active),
  proc(actionData: JsObject) = data.saveFiles(data.services.editor.active, saveAs=true),
  proc(actionData: JsObject) = data.saveFiles(),
  proc(actionData: JsObject) = discard data.closeAllFiles(), # close all,
  (proc(actionData: JsObject) = clipboardCopy(data.getMonacoSelectionText())), # aCut
  (proc(actionData: JsObject) = clipboardCopy(data.getMonacoSelectionText())), # aCopy
  (proc(actionData: JsObject) = data.clipboardPaste()), # aPaste
  proc(actionData: JsObject) =
    if not data.ui.activeFocus.isNil:
      discard data.ui.activeFocus.onFindOrFilter(),
  nil,
  proc(actionData: JsObject) = data.findInFiles(),
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  proc(actionData: JsObject) = data.expandWholeSource(), # aExpandAll
  proc(actionData: JsObject) = data.collapseWholeSource(), # aCollapseAll
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  proc(actionData: JsObject) = loadThemeForIndex(0), # aTheme0
  proc(actionData: JsObject) = loadThemeForIndex(1), # aTheme1
  proc(actionData: JsObject) = loadThemeForIndex(2), # aTheme2
  proc(actionData: JsObject) = loadThemeForIndex(3), # aTheme3
  nil,
  nil,
  nil,
  nil,
  nil,
  proc(actionData: JsObject) = data.openLowLevelCode(), # aLowLevel1
  proc(actionData: JsObject) = data.toggleMinimap(), # aShowMinimap
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  nil,
  proc(actionData: JsObject) = data.openLayoutTab(Content.PointList),
  nil,
  proc(actionData: JsObject) = data.openLayoutTab(Content.Calltrace),
  proc(actionData: JsObject) = data.openLayoutTab(Content.State),
  proc(actionData: JsObject) = data.openLayoutTab(Content.EventLog),
  proc(actionData: JsObject) = data.openLayoutTab(Content.TerminalOutput),
  proc(actionData: JsObject) = data.openLayoutTab(Content.StepList),
  proc(actionData: JsObject) = data.openLayoutTab(Content.Scratchpad),
  proc(actionData: JsObject) = data.openLayoutTab(Content.AgentActivity),
  proc(actionData: JsObject) = data.openLayoutTab(Content.Filesystem),
  proc(actionData: JsObject) = data.openShellTab(),
  nil,
  nil,
  proc(actionData: JsObject) = data.addBreakpointAtPosition(),
  proc(actionData: JsObject) = data.removeBreakpointAtPosition(),
  proc(actionData: JsObject) = data.removeAllBreakpoints(),
  proc(actionData: JsObject) = data.enableBreakpointAtPosition(),
  proc(actionData: JsObject) = data.enableAllBreakpoints(),
  proc(actionData: JsObject) = data.disableBreakpointAtPosition(),
  proc(actionData: JsObject) = data.disableAllBreakpoints(),
  proc(actionData: JsObject) = data.addTracepointAtPosition(),
  proc(actionData: JsObject) = data.removeTracepointAtPosition(),
  proc(actionData: JsObject) = data.enableTracepointAtPosition(),
  proc(actionData: JsObject) = data.enableAllTracepoints(),
  proc(actionData: JsObject) = data.disableTracepointAtPosition(),
  proc(actionData: JsObject) = data.disableAllTracepoints(),
  proc(actionData: JsObject) = data.runTracepoints(),
  nil,
  nil,
  nil,
  nil,
  proc(actionData: JsObject) = data.ui.menu.toggle(),
  proc(actionData: JsObject) = data.zoomFlowLoopIn(),
  proc(actionData: JsObject) = data.zoomFlowLoopOut(),
  proc(actionData: JsObject) = data.switchFocusedLoopLevelUp(),
  proc(actionData: JsObject) = data.switchFocusedLoopLevelDown(),
  proc(actionData: JsObject) = data.switchFocusedLoopLevelAtPosition(),
  proc(actionData: JsObject) = data.setFlowTypeToMultiline(),
  proc(actionData: JsObject) = data.setFlowTypeToParallel(),
  proc(actionData: JsObject) = data.setFlowTypeToInline(),
  proc(actionData: JsObject) = data.restartCodetracer(),
  proc(actionData: JsObject) = data.findSymbol(),
  proc(actionData: JsObject) = data.reRecordCurrent(projectOnly=false),
  proc(actionData: JsObject) = data.reRecordCurrent(projectOnly=true),
  proc(actionData: JsObject) = data.restartSubsystem(name="replay-server"),
  proc(actionData: JsObject) = data.restartSubsystem(name="session-manager"),
  proc(actionData: JsObject) = data.openTraceDialog(),
  proc(actionData: JsObject) =
    # aOpenTraceInNewTab: create a new session then open the trace dialog
    # so the selected trace loads into the fresh session tab.
    createNewSession(data)
    data.openTraceInNewTab(),
  proc(actionData: JsObject) = data.showRecordNewTraceDialog(),
  proc(actionData: JsObject) = data.recordFromLaunchConfig(actionData),
  proc(actionData: JsObject) = createNewSession(data), # aNewTraceTab
  # Language-specific View items.  The real implementations live
  # behind the Nim langserver / sourcemap flow (S3/S6/S7) and are not
  # all wired up yet — for now they surface a non-fatal info toast so
  # the action is observable.  The menu shape is the contract these
  # entries protect; behaviour will land in follow-up milestones.
  proc(actionData: JsObject) = # aViewGeneratedCSource
    data.viewsApi.successMessage(
      cstring"View Generated C Source is not yet wired up"),
  proc(actionData: JsObject) = # aViewDisassembly
    data.viewsApi.successMessage(
      cstring"View Disassembly is not yet wired up"),
  proc(actionData: JsObject) = # aTraceMacroAtCursor
    data.viewsApi.successMessage(
      cstring"Trace Macro at Cursor is not yet wired up"),
  proc(actionData: JsObject) = # aTraceStaticBlockAtCursor
    data.viewsApi.successMessage(
      cstring"Trace Static Block at Cursor is not yet wired up"),
  proc(actionData: JsObject) = # aCollabInvite
    openCollabInviteDialog(@[
      cstring(cgpViewer.presetName),
      cstring(cgpDriver.presetName),
      cstring(cgpHost.presetName)]),
  proc(actionData: JsObject) = data.openLayoutTab(Content.Timeline), # aTimeline
  proc(actionData: JsObject) = # aStartAgenticWorktreeSession
    agentic_session_launcher.startAgenticWorktreeSessionFromCommandPalette(),
  # --- M4 Visual Replay / Video Player handlers ----------------------------
  # Each handler delegates to ``dispatchVideoPlayerAction`` on the live
  # VideoPlayerVM instance.  Focus scoping is enforced *by the Mousetrap
  # overlay* registered in ``ui/shortcuts.nim`` (``configureVideoPlayerShortcuts``)
  # — the overlay checks ``videoPlayerHasFocus()`` before calling these
  # handlers, so the handlers themselves do not re-check focus.  This keeps
  # the handlers usable from menus, the command palette, and the Playwright
  # test hook (``__CODETRACER_TEST__.videoPlayerAction``) without requiring a
  # focused panel.  When the VM is not constructed (no visual recording
  # loaded) the handlers are silent no-ops.
  # Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md §Keyboard Shortcuts.
  proc(actionData: JsObject) = # videoPlayerTogglePlay
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaTogglePlay),
  proc(actionData: JsObject) = # videoPlayerRewind
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaRewind),
  proc(actionData: JsObject) = # videoPlayerFastForward
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaFastForward),
  proc(actionData: JsObject) = # videoPlayerStepFrameBack
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaStepFrameBack),
  proc(actionData: JsObject) = # videoPlayerStepFrameForward
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaStepFrameForward),
  proc(actionData: JsObject) = # videoPlayerStepDrawBack
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaStepDrawBack),
  proc(actionData: JsObject) = # videoPlayerStepDrawForward
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaStepDrawForward),
  proc(actionData: JsObject) = # videoPlayerJumpStart
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaJumpStart),
  proc(actionData: JsObject) = # videoPlayerJumpEnd
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaJumpEnd),
  proc(actionData: JsObject) = # videoPlayerTogglePicker
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaTogglePicker),
  proc(actionData: JsObject) = # videoPlayerCancelPicker
    let vm = video_player.currentVideoPlayerVM()
    if not vm.isNil: discard dispatchVideoPlayerAction(vm, VpaCancelPicker),
  proc(actionData: JsObject) = # aVerification
    data.openLayoutTab(Content.Verification),
  # The five debug-toolbar controls that gained chords. Each one hands the
  # toolbar's own action id to `ui/debug.nim`'s dispatcher — the same `case`
  # the button's `onAction` bridge reaches — so the chord cannot drift from
  # the click. Appended at the end, in enum order, matching the five members
  # added at the end of `ClientAction`.
  proc(actionData: JsObject) = # aHistoryBack
    debug.invokeDebugToolbarAction("history-back"),
  proc(actionData: JsObject) = # aHistoryForward
    debug.invokeDebugToolbarAction("history-forward"),
  proc(actionData: JsObject) = # aRunToEntry
    debug.invokeDebugToolbarAction("run-to-entry"),
  proc(actionData: JsObject) = # aResetOperation
    debug.invokeDebugToolbarAction("reset-operation"),
  proc(actionData: JsObject) = # aRunTests
    debug.invokeDebugToolbarAction("run-tests"),
]

data.actions = actions

# Build-error navigation, assigned BY NAME rather than by position in the
# array literal above.
#
# `actions` is a positional `array[ClientAction, ClientActionHandler]` of 184
# entries, and `aGotoNextError` / `aGotoPreviousError` sit at ordinals 101 and
# 102 in the middle of an unbroken run of ~40 `nil`s. Editing the literal in
# place is a silent off-by-one away from binding a different action, and it
# would still compile. Naming the member is checked by the compiler and is the
# same form `data.actions[ClientAction.build] = ...` already uses below.
#
# The two members are not new: they have been in the enum since
# `frontend.nim:122-123` with their menu entries commented out at
# `ui_js.nim:849-850` and no handler anywhere — live enum members that nothing
# could ever reach. This is the wiring they were missing.
data.actions[ClientAction.aGotoNextError] = proc(actionData: JsObject) =
  errors.gotoNextBuildError()
data.actions[ClientAction.aGotoPreviousError] = proc(actionData: JsObject) =
  errors.gotoPreviousBuildError()

when defined(ctWeb):
  # The entry layer, imported HERE and not in the module's import list, because
  # it is web-only: `ui/web_entry_surface.nim` reads `window.location` and
  # mounts the bundled template, neither of which an Electron renderer build
  # has any use for. The desktop arm's import graph is unchanged by this file.
  import ui/web_entry_surface
  # The Build/Run call path, web-only for the same reason: it reaches
  # `ctPlatform().process` expecting the wasm host a browser tab has and an
  # Electron renderer does not.
  import ui/web_noir_build
  # `NoirTestResponse` -> `TestEvent`s, so the Test Results pane is fed by the
  # fold every other run producer is fed by. Web-only for `web_noir_build`'s
  # reason: nothing else in this file has a `NoirTestResponse` to convert.
  from viewmodel/viewmodels/noir_test_run import noirTestRunEvents
  import ui/web_replay_host
  # Where the user's edits live. `web_project_store` is the one mutable
  # project — backend-neutral, so `web_entry_surface` can keep compiling on the
  # C backend for unit tests — and `web_project_persistence` is the js-only
  # half that connects it to the OPFS store `boot()` already opened.
  import ui/web_project_store
  import ui/web_project_persistence
  from viewmodel/platform/web_entry import
    EntryResolution, EntryVerdict, evTemplate, entryPath, entryPathOnHost
  from viewmodel/platform/noir_template import
    ProjectTemplate, templateFor, hasFiles, templateFileCount

  # `web_boot` is imported at the TOP of this file, not here, and its header
  # explains why the position is load-bearing. The short version of what it
  # does: `installPlatform` writes a module-level `var` in
  # `viewmodel/platform/platform.nim`, a `nim js` program gets exactly one of
  # those, and the deployment used to run TWO programs — `web.js` booted and
  # `ui.js` rendered. Measured on the baseline pair, and it is the cleanest
  # statement of the defect available: `web.js` contained
  # `installPlatform__viewmodelZplatformZplatform_u99`, and `ui.js` contained
  # no `installPlatform` at all, the symbol having been eliminated as dead code
  # because nothing in the renderer could ever install a platform. Every
  # `ctPlatform()` here therefore returned `uninstalledProfile`: `pkHeadless`,
  # every capability absent, every operation refusing.

  # -------------------------------------------------------------------------
  # THE WEB BUILD'S ENTRY POINT — the call that was missing.
  #
  # ## The defect this replaces, measured on the deployed page
  #
  # `ide.codetracer.com` served `web.js` and `ui.js`, both correct and both
  # 200, and painted nothing: `#dom-root` was empty and the only text on the
  # page was the boot arm's diagnostic line. Every deploy check was green,
  # because each one asserted a step rather than the artefact — the shape
  # Verification-Harness-Traps.md calls trap 2.
  #
  # What a browser said, and no check did, was:
  #
  #     Uncaught ReferenceError: monaco is not defined
  #       at ui.js:65313            (ui/agent_activity.nim:46)
  #
  # `ui.js` died during module initialisation, roughly a quarter of the way in,
  # on a module-level `monaco.editor.createModel` — because the generated entry
  # document shipped none of the third-party bundle the renderer has always been
  # loaded beside. That is fixed in `platform/web_deployment.nim`, which now
  # renders the renderer's real document.
  #
  # Past that, the tail of this file was the second wall and this block is it.
  # The old code was a two-way gate — Electron, or "not Electron", where "not
  # Electron" meant the browsersync DEV SERVER:
  #
  #     if not inElectron:
  #       var io {.importc.}: ...            # socket.io, from a <script> tag
  #       var frontendSocketPort {.importc.} # injected by views/server_index.ejs
  #       startIPC()                          # opens a websocket, and ONLY the
  #                                           # socket's 'connect' handler calls
  #                                           # configure(data)
  #
  # A statically hosted tab is neither arm. It has no `io` and no injected
  # globals, so `startIPC()` throws `ReferenceError: frontendSocketParameters is
  # not defined` on its first line (confirmed by serving this exact `ui.js`
  # beside the third-party bundle); and even had it not thrown, `configure(data)`
  # sits inside a `connect` callback for a websocket server that does not exist
  # on a CDN and is not going to. The web build could not mount by construction.
  #
  # ## Why an in-page transport rather than no transport
  #
  # `configureIPC(data)` registers ~99 handlers through `data.ipc.on`, and forty
  # call sites across the renderer do `data.ipc.send`. Leaving `data.ipc` nil
  # would move the failure from module init to the first click, which is worse:
  # it is the same blank page, later, and attributable to nothing.
  #
  # So the web arm installs a real object with the same two methods. `on`
  # records; `send` has nowhere to go and SAYS SO on the console rather than
  # failing silently, which is what makes an unported feature legible when
  # someone clicks it. `deliver` is the third method and is the point: it lets
  # the page hand the renderer an event locally, on the same path a host would.
  #
  # `respond` is the fourth, and it is what makes the FIRST SCREEN possible
  # rather than merely legible. Some of those ~99 messages are not
  # notifications but QUESTIONS: `utils.asyncSend` registers a future, sends
  # `CODETRACER::<id>`, and waits for the host to answer on
  # `CODETRACER::<id>-received`. `tab-load` is one, and it is the one edit mode
  # cannot do without — `openNewEditorView` awaits it for the source of the
  # file it is about to show. Warned-about-and-dropped, that await never
  # settles, and the result is a permanently blank editor with nothing in the
  # page to say why.
  #
  # A responder is therefore a HOST CAPABILITY implemented in the page, not a
  # bypass: `ui/web_entry_surface.installTemplateHost` answers `tab-load` out
  # of the bundled template with the same `{argId, value}` message
  # `index/config.sendTabInfo` sends, so `renderer.onTabLoadReceived` resolves
  # the same future the same way. The renderer cannot tell the two apart, which
  # is the property that keeps this one door and not two.
  proc newWebIpc(): js {.importjs: """
(function () {
  var handlers = {};
  var responders = {};
  var deferHostReply = function (fn) { setTimeout(fn, 0); };
  return {
    handlers: handlers,
    responders: responders,
    on: function (id, code) {
      (handlers[id] = handlers[id] || []).push(code);
    },
    respond: function (id, code) {
      responders[id] = code;
    },
    send: function (id, payload) {
      var responder = responders[id];
      if (responder) {
        // ASYNCHRONOUSLY, and this is a correctness requirement rather than a
        // nicety. `utils.asyncSend` calls `ipc.send` from INSIDE the promise
        // executor and only registers `asyncSendCache[id][argId]` on the line
        // AFTER the promise is constructed. A responder that answers
        // synchronously therefore resolves the future before that line runs,
        // and the resolve wrapper's `jsdelete data.asyncSendCache[id][argId]`
        // dereferences an undefined map — measured, as
        // `TypeError: Cannot convert undefined or null to object` thrown out
        // of `CODETRACER::tab-load-received`, with the editor left blank.
        //
        // A real host is a process away, so its reply is always at least a
        // task later. Deferring here makes the in-page host obey the same
        // ordering the renderer was written against instead of asking every
        // responder to remember to.
        //
        // `deferHostReply` is a named helper rather than an inline
        // `setTimeout` so that `ci/test/web-renderer-mounts.sh`'s arm E can
        // substitute ONE unique line and reconstruct the synchronous state
        // exactly. An inline call would need a needle that also matches the
        // renderer's other `setTimeout`s.
        deferHostReply(function () {
          try { responder.call(responder, undefined, payload); }
          catch (e) { console.error('codetracer-web: responder for ' + id +
                                    ' threw', e); }
        });
        return;
      }
      console.warn('codetracer-web: no host for ' + id +
                   ' — this surface is not ported to the browser yet', payload);
    },
    deliver: function (id, payload) {
      var hs = handlers[id] || [];
      for (var i = 0; i < hs.length; i++) {
        try { hs[i].call(hs[i], undefined, payload); }
        catch (e) { console.error('codetracer-web: handler for ' + id +
                                  ' threw', e); }
      }
      return hs.length;
    }
  };
})()""".}

  proc reportWebRenderer(line: cstring) {.importjs: """
(function (s) {
  try { if (typeof console !== 'undefined') { console.log(s); } } catch (e) {}
  try {
    if (typeof document !== 'undefined') {
      var el = document.getElementById('codetracer-renderer');
      if (el) { el.textContent = s; }
    }
  } catch (e) {}
})(#)""".}
    ## Reported the same way `web_main.nim` reports the boot line, and for the
    ## reason its header gives: a page wants it in the DOM, a headless check
    ## wants it on the console, and both must be the same fact. The prefix is
    ## what `ci/test/web-renderer-mounts.sh` reads.
    ##
    ## Deliberately a SEPARATE element from `#codetracer-boot`: the two arms
    ## report independently, and a renderer that failed while the loop arm
    ## succeeded is exactly the state that shipped. Writing both into one
    ## element would let the later one erase the evidence of the earlier.

  proc hideWebRendererStatus() {.importjs: """
(function () {
  try {
    if (typeof document !== 'undefined') {
      var el = document.getElementById('codetracer-renderer');
      if (el) { el.hidden = true; }
      var boot = document.getElementById('codetracer-boot');
      if (boot) { boot.hidden = true; }
    }
  } catch (e) {}
})()""".}
    ## Hides BOTH arms' status lines once a surface has mounted, and the boot
    ## line is the one that was left behind.
    ##
    ## ## Why it matters more than tidiness
    ##
    ## `#codetracer-boot` was never hidden. On the deployed `/noir` it was not
    ## VISIBLE either — but only by accident: it sits at (0,0) and `#menu`,
    ## which comes later in the document, painted over it. So 379 characters of
    ## developer diagnostic were laid out in the page, counted by `innerText`,
    ## and invisible to a user. Measured, 2026-09-01:
    ##
    ##     innerText           425 characters
    ##     readable by a user   46 characters   (the six template file names)
    ##
    ## `ci/test/web-renderer-mounts.sh` asserted `visibleTextLength > 200`, so
    ## its "there is a product on this page" check was being satisfied almost
    ## entirely by a log line nobody can see — and would have passed over a
    ## page that rendered nothing else. That is the trap this campaign keeps
    ## finding, in the INSTRUMENT this time rather than in the product.
    ##
    ## Two fixes, and both were needed. The probe now measures painted text
    ## with a Range and a hit test (`paintedText`), and the diagnostic stops
    ## being in the page at all once the product is on it. A status line whose
    ## invisibility depends on another element's stacking order is not hidden,
    ## it is lucky.
    ##
    ## FAILURES STILL SAY SO. This runs only on the success path; a refusal or
    ## an exception leaves both lines visible, which is the one time a user
    ## needs to be told something.

  const webRendererLinePrefix* = "codetracer-web-renderer:"

  proc modifiedEditorNames(): seq[string] =
    ## The project-relative names of every editor with unsaved changes.
    ##
    ## Read from `data.saveTargets()` — the same list `renderer.saveFiles`
    ## walks — so the names in the pane header are the files that were actually
    ## written and not a second, drifting idea of what "modified" means. Taken
    ## BEFORE the save, because `onSavedFile` clears `changed` and the list
    ## would be empty afterwards.
    for target in data.saveTargets():
      if target.changed and target.editorReady and not target.untitled:
        let relative = web_entry_surface.projectRelative(
          web_project_store.currentProject(), target.name)
        result.add(if relative.len > 0: relative else: target.name)

  proc saveThenCompile(runAfter: bool) =
    ## EMT-D17, and the reason Ctrl+B alone is enough to compile an edit.
    ##
    ## ## Why the save is unconditional, and why Build gets it too
    ##
    ## The decision is written for Run — "Run **saves all modified editors
    ## first, unconditionally**, and the Build pane header names the files
    ## saved" — and its reasoning is that a recording replayed against source
    ## on disk must match the source on screen. Build has the same requirement
    ## for a stronger reason here: an unsaved buffer is not in
    ## `currentProject()`, so a Build that did not save would compile the last
    ## SAVED bytes and paint a result about code the user has since changed.
    ## That is the original defect with a smaller radius, and it is exactly
    ## what a visitor pressing Ctrl+B after typing would hit.
    ##
    ## This is also what the desktop already does: `update(build = true)` calls
    ## `data.saveFiles()` before restarting anything. So both platforms save on
    ## Build, through the same proc, for the same reason.
    ##
    ## ## Why a `setTimeout` and not a straight call
    ##
    ## `saveFiles` sends `CODETRACER::save-file` per modified buffer, and
    ## `newWebIpc.send` hands every responder to `deferHostReply`, which is
    ## `setTimeout(fn, 0)`. The save host is therefore not applied to
    ## `currentProject()` until a later macrotask — so compiling on this tick
    ## would compile the bytes from BEFORE the save, which is the whole bug.
    ##
    ## A zero-delay timer queued after them runs after them: the HTML standard
    ## orders timers of equal delay by insertion, and `saveFiles` has already
    ## queued all of its sends synchronously by the time this line runs. This is
    ## the same ordering guarantee `deferHostReply` itself is built on, and its
    ## comment explains why the deferral cannot simply be removed.
    ##
    ## A microtask would NOT do: `queueMicrotask` drains before the next
    ## macrotask, so it would run before the very responders it is waiting for.
    let saved = modifiedEditorNames()
    data.saveFiles()
    discard windowSetTimeout(proc() =
      if runAfter: web_noir_build.startNoirRun(saved)
      else: web_noir_build.startNoirBuild(saved), 0)

  proc startWebRenderer() =
    ## Install the transport, configure the renderer, mount the first surface.
    ##
    ## The three steps are the desktop's three steps in the desktop's order —
    ## `configureIPC`, `configure`, then a surface — and that ordering is not
    ## cosmetic: `configure` binds shortcuts and installs the panel services
    ## that a mounted surface goes on to use.
    ##
    ## EVERY STEP IS INSIDE THE REPORT. An exception here used to be an
    ## uncaught error in a tab, invisible to every check that ran against this
    ## deployment — traps doc, trap 3: "a module that fails to load leaves no
    ## in-page error". Now a failure names itself in the DOM and on the console,
    ## in the same sentence shape as a success, so the CI assertion can tell
    ## "did not mount" from "mounted" instead of finding an absence either way.
    try:
      ipc = newWebIpc()
      data.ipc = ipc
      configureIPC(data)
      configure(data)

      # THE CALL THAT WAS MISSING, and the reason `/noir` opened the welcome
      # screen. `ui/web_entry_surface.nim`'s header has the full account; the
      # short version is that `classifyPath`, `resolveEntry` and
      # `currentEntryRequest` were all correct, all tested, and all
      # unreachable, so this arm mounted one surface at every address the
      # deployment serves.
      let entry = web_entry_surface.currentRendererEntry()
      let hostLanguage = web_entry_surface.currentRendererHostLanguage()
      let tmpl = templateFor(entry.languageEntry)

      # Rule 5's third row, and it must happen BEFORE the mount rather than
      # after: the surface is what a user then interacts with, and a Back press
      # arriving between the two would find `/noir/new` still on the stack.
      if entry.replacesHistoryEntry:
        # `entryPathOnHost`, not `entryPath`: on a host whose ROOT is the
        # language entry point, `/new` must be replaced by `/` and not by
        # `/noir`. Replacing it with `/noir` would move the visitor off the
        # root of the domain they came to, which is the one outcome
        # "not a mere redirect — the user stays on this domain" rules out.
        web_entry_surface.jsReplaceHistoryEntry(
          cstring(entryPathOnHost(entry.languageEntry, hostLanguage)))

      # §1b.3 step 6 — "Never a blank editor, never an error page". Every arm
      # below mounts something; the choice is WHICH, and it follows from the
      # verdict rather than from a path test here. A second `classifyPath` in
      # this file is exactly the drift `web_entry.nim`'s header warns about.
      let wantsTemplate = entry.verdict == evTemplate and tmpl.hasFiles
      let mounted =
        if wantsTemplate: web_entry_surface.enterTemplateEditMode(tmpl)
        else: welcome_screen.mountWebWelcomeScreen()
      # `edit-mode`, not `noir-template`, and the rename is the finding.
      #
      # The old name described a web-specific surface that drew a Filesystem
      # panel and nothing else. There is no such surface any more:
      # `enterTemplateEditMode` delivers `CODETRACER::no-trace`, which is the
      # message `ct edit <path>` and the welcome screen's "open recent folder"
      # both send, so what mounts is CodeTracer in Edit mode — its
      # GoldenLayout, its topbar, its panes — over the bundled project. A log
      # line that still said `noir-template` would be naming a thing the build
      # no longer contains.
      let surface = if wantsTemplate: "edit-mode" else: "welcome-screen"

      # THE CALL PATH THIS MILESTONE EXISTS FOR, and its position is
      # load-bearing. `enterTemplateEditMode` delivers `CODETRACER::no-trace`
      # SYNCHRONOUSLY through the in-page transport's `deliver`, and
      # `onNoTrace` calls `configureMiddleware()` — which is what creates
      # `build.buildVMInstance` and installs the DESKTOP `runBuild`
      # (`data.update(build=true)`, a message to a host this tab does not
      # have). So by the time control returns here the VM exists and carries
      # the wrong callback; installing before the mount would find no VM at
      # all, and installing inside `enterTemplateEditMode` would put a
      # platform reach into the surface module that mounts panes.
      #
      # Only on the template arm: the welcome screen has no open project, and
      # a Build button pointed at nothing is worse than one that is absent.
      if wantsTemplate and mounted:
        web_noir_build.installNoirBuildCommands(tmpl)

        # THE TEST RESULTS PANE'S ▶, AND WHERE ITS ROWS COME FROM.
        #
        # Here for `installNoirBuildCommands`' reason, one pane over: this is
        # the only place that can see the pane's view-model, the project and
        # the toolchain driver at the same moment, and `web_noir_build` must
        # not import `ui/test_results` — it is the module that talks to the
        # wasm worker, and a Test Results pane is one of two surfaces over what
        # it produces (the BUILD pane is the other, and gets the same run
        # through `noir_build_producer`).
        #
        # `initTestResultsVM` first because the pane may not have been mounted
        # yet: `onNs9PanesCatalog` also calls it, and whichever runs first
        # creates the instance.
        test_results.initTestResultsVM()
        if not test_results.testResultsVMInstance.isNil:
          let testsVM = test_results.testResultsVMInstance
          testsVM.runTests = proc() = web_noir_build.startNoirTests()
          web_noir_build.noirTestRunStarted = proc() = testsVM.beginRun()
          web_noir_build.noirTestRunSettled = proc() = testsVM.endRun()
          web_noir_build.noirTestRunSink =
            proc(response: NoirTestResponse; packageDir: string) =
              # The catalog is read AT FOLD TIME rather than captured, because
              # it arrives on its own message and may not have when this
              # closure was made. Its only use is resolving a selector to the
              # id the pane joins on; `noirTestRunEvents` derives one when the
              # catalog has no such test, so an empty catalog degrades to rows
              # that still carry every verdict.
              inc noirTestRunCounter
              for event in noirTestRunEvents(
                  response, testsVM.catalog.val,
                  runId = "wasm-test-" & $noirTestRunCounter,
                  commandLine = "nargo test",
                  packageDir = packageDir):
                testsVM.ingestEvent(event)

        # RUN IS A MODE TRANSITION — "full surface, returnable".
        #
        # Installed here, beside the Build wiring, and for the same reason its
        # comment gives: `enterTemplateEditMode` has already run, so the
        # renderer's machinery exists, and this is the one place that can see
        # all three things the transition needs at once. The replay host calls
        # it when the engine is ready over a trace the tab produced.
        #
        # THREE STEPS THAT MUST HAPPEN TOGETHER, which is why this is one proc
        # rather than a layout handed to the host:
        #
        #   1. `switchToDebug` — it already saves the edit layout into
        #      `lastUsedEditLayout`, and `switchToEdit` already restores it
        #      and saves the debug layout in turn, so the return leg is
        #      symmetric and neither half is new. Both are bound actions
        #      (`ctrl+f5`, and the `switchEdit`/`switchDebug` client actions),
        #      so nothing state-dependent joins the topbar and
        #      `menuRenderSignature` gains nothing it could silently miss.
        #   2. CONSTRUCT the components the debug layout names.
        #      `renderer.createUIComponents` walks `resolvedConfig` once at
        #      startup, so a layout loaded later names GoldenLayout containers
        #      with no component behind them. Measured: the layout visibly
        #      switched, the panes came up empty, and uncaught page errors
        #      went from 1 to 11.
        #   3. `requestInitialPanelData` — what the desktop calls right after
        #      `switchToDebug` so the Event Log and Terminal Output ask for
        #      their data instead of sitting blank.
        web_replay_host.installDebugSurfaceEntry(proc() =
          let debugLayout = web_entry_surface.noirStudioDebugLayout()
          if debugLayout.isNil:
            cerror "replay: the bundled debug layout did not parse"
            return
          # A REPLAY SESSION HAS A TRACE, and until now `data.trace` was nil.
          #
          # `onNoTrace` sets it nil (there is no recording on an editing
          # surface) and the desktop's `onTraceLoaded` sets it from the
          # response. The web path reached neither, so every
          # `editor.onCompleteMove` died on `data.trace.lang` — measured as
          # seven identical uncaught `TypeError: Cannot read properties of
          # null (reading 'lang')`, one per move, with the session otherwise
          # working.
          #
          # Describing the recording the tab just made is the fix rather than
          # a guard, because the session genuinely HAS one: `LangNoir` is what
          # the tracer produced, and the workdir is the folder the engine was
          # launched against. Fields nothing on this path reads are left at
          # their defaults instead of being invented.
          if data.trace.isNil:
            data.trace = Trace(
              lang: LangNoir,
              program: cstring(tmpl.name),
              workdir: cstring"trace",
              imported: false,
              calltrace: true,
              events: true)
          data.switchToDebug()
          if not data.ui.layout.isNil:
            let resolved = cast[GoldenLayoutResolvedConfig](debugLayout)
            # `Content.Trace` is a retired id that survives only in
            # `editModeHiddenContentIds`; `makeComponent` has no arm for it and
            # raises `ValueError`. Skipping it by name keeps one dead pane from
            # aborting the construction of the seven live ones.
            for declared in web_entry_surface.layoutComponents(debugLayout):
              if declared.content == ord(Content.Trace): continue
              # ONLY THE ONES THAT DO NOT EXIST YET, which is the guard
              # `reopenAuxiliaryPanels` already uses two hundred lines up and
              # which this loop was missing.
              #
              # Constructing a component that already exists does not replace
              # it, it makes a SECOND one — and for the menu that is a second
              # gate owner. `ui/menu.nim` invalidates the render gate whenever
              # `menuShellGateOwner != self`, so two owners alternate and
              # invalidate on every redraw; the shell is then rebuilt every
              # time, `renderMenuShellInto` clears `#isonim-debug-controls` on
              # each rebuild, and the debug toolbar is torn down as fast as it
              # is mounted. Measured as issue #555's storm returning under a
              # new trigger: `mount COMPLETE` four times in twenty seconds and
              # no toolbar on screen at the end of it.
              if data.ui.componentMapping[Content(declared.content)]
                   .hasKey(declared.id):
                continue
              try:
                discard data.makeComponent(Content(declared.content), declared.id)
              except CatchableError as e:
                cerror "replay: component " & $declared.content & ": " & e.msg
              except:
                cerror "replay: component " & $declared.content & " failed"
            try:
              data.ui.layout.loadLayout(resolved)
              data.ui.resolvedConfig = resolved
            except:
              cerror "replay: could not load the debugging layout"
          requestInitialPanelData(data)
          # The toolbar's own mount gave up during boot, against a document
          # that had not drawn the menu shell yet. Now that the surface exists
          # and has just been rebuilt, ask again — a no-op if it is already up.
          debug.remountDebugControls())

        # BUILD IS THE CONFIGURED ACTION, NOT A NEW CHORD.
        #
        # `default_config.yaml` has bound `build: "CTRL+B"` all along, and
        # `bindShortcut` dispatches through `data.actions[action]` — read at
        # PRESS TIME. So replacing the handler here is immune to the rebinding
        # race that a `Mousetrap.bind` from this position loses: `onNoTrace`
        # calls `configureShortcuts()` again, and it is `{.async.}`, so its
        # rebinding lands in a later microtask than this line. Measured — a
        # `Mousetrap.bind("ctrl+b")` here never fired, and neither did
        # `Mousetrap.trigger('ctrl+b')` from the page, because the shortcut
        # table had already been rebuilt over it.
        #
        # The desktop's hard-coded `ctrl+b` in `ui/shortcuts.nim` is excluded
        # from `ctWeb` for the same defect from the other side; see the comment
        # there.
        data.actions[ClientAction.build] = proc(actionData: JsObject) =
          saveThenCompile(runAfter = false)

        # RUN has no configured chord, so it gets one that nothing else binds.
        # NOT `ctrl+r` and NOT `F5`: both are the browser's own reload on every
        # platform, and a studio that ate either would be taking a key away
        # from the user rather than giving them one.
        Mousetrap.`bind`("ctrl+enter") do ():
          saveThenCompile(runAfter = true)

        # EXPORT — the gesture every durability sentence instructs the user to
        # perform, and which had no way to be performed.
        #
        # `web_platform.exportProjectArchive` walks the working tree, builds a
        # tar and hands it to the browser's download path. It has been complete
        # since the store landed and had ZERO callers, while the banner told
        # every visitor to "export to keep them". A product that instructs an
        # action it does not offer is making the same kind of false claim as
        # one that accepts keystrokes and discards them.
        #
        # `ctrl+shift+e` rather than `ctrl+e`: the latter is a browser-level
        # chord on several platforms, and `web_noir_build`'s Run binding
        # records the rule this follows — a studio must not take a key away
        # from the user.
        Mousetrap.`bind`("ctrl+shift+e") do ():
          web_project_persistence.exportOpenProject()

      if mounted:
        # The line names the ENTRY as well as the surface. Two builds — one
        # that routes and one that ignores the path — produce the same DOM at
        # `/`, so the only way a log distinguishes them is if the resolution
        # says itself. `ci/test/web-renderer-mounts.sh`'s route arm reads this.
        reportWebRenderer(cstring(
          webRendererLinePrefix & " ok surface=" & surface &
          " entry=" & $entry.form & "/" & $entry.verdict &
          " language=" & (if entry.languageEntry.len > 0: entry.languageEntry
                          else: "(none)") &
          # WHICH HOST, as the product understood it. A two-domain deployment
          # answers `/` differently on each, so a log that named only the path
          # could not tell a correct `noirstudio.dev/` from a
          # `ide.codetracer.com/` that had wrongly picked up a language.
          " host=" & (if hostLanguage.len > 0: hostLanguage else: "(neutral)") &
          " files=" & $tmpl.templateFileCount &
          # THE KEYBOARD, as a number. A `Config` whose `bindings:` section did
          # not parse is non-nil and empty: it dereferences cleanly in
          # `ui/menu.nim`, `ui/shortcuts.nim` and `ui/editor.nim`, and yields a
          # product that mounts, paints, and answers no key. No DOM assertion
          # can see that, which is why the count is said out loud here rather
          # than left to be inferred from a screen.
          " shortcuts=" & $shortcutBindingCount(data.config) &
          # THE PLATFORM THE RENDERER ITSELF CAN SEE, which is the fact this
          # milestone exists to change and the one no line has ever carried.
          #
          # The boot line already said `platform=pkWeb`, and it was true of the
          # program that printed it. This says it of the program that MOUNTS
          # PANES, and until the arms were merged the honest value here was
          # `platform=pkHeadless run=false` on every load — beside a boot line
          # reporting `toolchain=nargo:compile+trace` from the other bundle.
          # Two true sentences that together were a lie about the product, and
          # nothing printed the second one.
          #
          # `ci/test/web-renderer-mounts.sh` asserts this clause agrees with
          # the boot line's, and its arm C reddens exactly this by neutering
          # `installPlatform` — which leaves the mount untouched, so the arm
          # names the mechanism rather than reporting that something broke.
          describeRunningPlatform() &
          # §1b.3 step 6: "a plain statement of what was asked for and could
          # not be found. Never a blank editor, never an error page."
          # `resolveEntry` composes that sentence for an unresolvable address
          # and for a project pointer that could not be refreshed, and it was
          # going nowhere — a computed value nothing consults, which is the
          # shape this whole change exists to stop repeating.
          #
          # HONEST RESIDUAL: the console and the boot diagnostic are not a
          # user-facing surface. The surface that should carry this sentence is
          # the project view NS9 builds; until then it is at least SAID, so a
          # support question about a mistyped link has an answer in the log
          # rather than a shrug.
          (if entry.explanation.len > 0: " note=" & entry.explanation else: "")))
        # The page belongs to the product now. The line stays on the console —
        # which is what `ci/test/web-renderer-mounts.sh` reads — and leaves the
        # document, because a diagnostic a user has to look at is a diagnostic
        # the product has not replaced. Only the FAILING states stay visible,
        # which is the one time a user needs to be told something.
        hideWebRendererStatus()
      else:
        # Not an exception, and not a success either. The panel declined to
        # mount — its container is missing from the document, which is a
        # deployment fault and not a code fault, and it must not be reported
        # with the same word as a mount.
        reportWebRenderer(cstring(
          webRendererLinePrefix &
          " refused surface=" & surface & " reason=no-container"))
    except CatchableError:
      reportWebRenderer(cstring(
        webRendererLinePrefix & " failed reason=" & getCurrentExceptionMsg()))

  proc durabilityNotificationKind(
      level: web_project_store.DurabilityNoticeLevel): NotificationKind =
    ## The one place the storage tiers meet the notification severities.
    ##
    ## `dnlUnstored` is an ERROR rather than a warning: the work in that row is
    ## not on disk anywhere and goes when the tab does, which is a failure of
    ## the product's basic promise and not a caveat about it.
    case level
    of web_project_store.dnlReassurance: NotificationKind.NotificationSuccess
    of web_project_store.dnlEvictable: NotificationKind.NotificationWarning
    of web_project_store.dnlUnstored: NotificationKind.NotificationError

  proc raiseDurabilityNotice() =
    ## Deliver §4.2's sentence through the notification system every other
    ## message in this product already uses.
    ##
    ## ## Why this is a separate call, after the mount
    ##
    ## `prepareProject` runs BEFORE `startWebRenderer` and must — it restores
    ## the user's saved bytes, and a restore that landed after the mount would
    ## paint the bundled template over their work. But `data.ui.status` does
    ## not exist until `configure(data)` has built the components, so there is
    ## no status bar to raise a notification into at the point the sentence is
    ## composed. The sentence is therefore composed there and RAISED here; the
    ## acknowledgement `readyForEditing` waits on travels with the raising, so
    ## nothing claims to have shown something it has not.
    ##
    ## `startWebRenderer` catches its own exceptions and never rethrows, so a
    ## surface that failed to mount still reaches this line — and a failure to
    ## mount is exactly when a user most needs to be told where their work is.
    let notice = web_project_persistence.takeDurabilityAnnouncement()
    if not notice.show:
      return

    # THE ACTION, not just the chord. The sentence names `Ctrl+Shift+E`
    # because a chord is what a returning user reaches for; the button is what
    # a first-time visitor can actually press, and it is the same call.
    var actions: seq[NotificationAction] = @[]
    if notice.offerExport:
      actions.add(newNotificationButtonAction(
        cstring"Export project",
        proc = web_project_persistence.exportOpenProject()))

    # DISMISSIBLE, AND NOT AUTO-DISMISSED, for the two degraded rows.
    # `status.canAutoDismiss` is false once a notification carries actions, so
    # the warning stays until the user closes it — read at their pace — while
    # `statusShellModel` renders every active notification with `dismiss =
    # true`, so closing it is one click. A notice that cannot be dismissed is a
    # banner by another name, which is the complaint this change answers.
    data.viewsApi.showNotification(
      newNotification(durabilityNotificationKind(notice.level), notice.text,
                      actions = actions))

  const durabilityNoticeMountAttempts = 40
    ## 40 turns of ~25ms — one second — before the sentence goes to the console
    ## instead. Generous next to a mount measured in tens of milliseconds, and
    ## bounded so a surface that never mounts cannot leave a timer running for
    ## the life of the tab.

  proc awaitStatusBarThenRaise(attemptsLeft: int) =
    ## `showNotification` EMITS; something has to be subscribed.
    ##
    ## `StatusComponent.register` is what subscribes to `CtNotification`, and
    ## it runs inside `createUIComponents`, which runs while the layout is
    ## being built. `enterTemplateEditMode` delivers `CODETRACER::no-trace`
    ## synchronously, so in the ordinary case the component exists by the time
    ## `startWebRenderer` returns — but "ordinarily synchronous" is not a
    ## guarantee, and an emit with no subscriber is silently dropped. That is
    ## the failure mode this whole change exists to stop repeating: a correct
    ## sentence, computed, and shown to nobody.
    ##
    ## `takeDurabilityAnnouncement` is NOT called until the bar is there,
    ## because it is what marks the session as told and acknowledges the store.
    if not data.ui.isNil and not data.ui.status.isNil and
       not data.viewsApi.isNil:
      raiseDurabilityNotice()
      return
    if attemptsLeft <= 0:
      # The one channel left. Better than dropping it, and it is what
      # `ci/test/noir-edit-persists.sh` would report as the absence it is.
      cwarn "durability: no status bar to announce into: " &
        web_project_store.durabilityNoticeText()
      return
    discard windowSetTimeout(
      proc() = awaitStatusBarThenRaise(attemptsLeft - 1), 25)

  proc startWebArm() {.async.} =
    ## Boot the platform, THEN render — and in that order for one reason.
    ##
    ## `boot()` is asynchronous by necessity: §4.5 requires the project store
    ## to be OPENED before a platform exists, because a platform is a thing
    ## that can write and a refused store must not be written to. So there is
    ## no synchronous point at which `ctPlatform()` could already be the web
    ## platform, and a renderer that mounted first would run `configure(data)`
    ## and its first surface against `uninstalledProfile` — which is precisely
    ## the state that shipped, just reached from one program instead of two.
    ##
    ## THE COST IS ONE TASK, NOT A ROUND TRIP. `boot()` awaits
    ## `navigator.storage.persisted()` and the OPFS handle; both are local. The
    ## probe in `ci/test/web_renderer_probe.mjs` settles for 9s after `load`,
    ## against a boot measured in single-digit milliseconds.
    ##
    ## A REFUSED BOOT STILL RENDERS. `startWebSession` reports the refusal on
    ## the boot line and returns it; the renderer then mounts against
    ## `uninstalledProfile`, which is no worse than every load before this
    ## change and strictly better than a blank page — §4.5's refusal has a UI,
    ## and a user who cannot be given storage still needs to be told so by
    ## something other than an empty document. The renderer's own line reports
    ## `platform=pkHeadless run=false` in that case, so the two states are
    ## distinguishable in the log rather than being one shrug.
    ## THE PROJECT IS PREPARED BETWEEN THE TWO, and that position is the whole
    ## correctness argument for restoring edited files.
    ##
    ## `web_project_persistence.prepareProject` activates the project in the
    ## store, shows §4.2's durability sentence, acknowledges it, and reads back
    ## whatever a previous visit saved. All of that is asynchronous, and all of
    ## it must be finished before `startWebRenderer` runs — because that call
    ## mounts edit mode, and `onNoTrace` ends by opening the initial tab, which
    ## asks `CODETRACER::tab-load`. A restore that landed after the mount would
    ## paint the BUNDLED bytes into an editor whose file the store holds an
    ## edited copy of, and the user would watch their work vanish on reload
    ## while it was still on disk.
    ##
    ## It needs the entry resolution to know WHICH template, and `booted.entry`
    ## already carries it — `boot()` resolves the address for the boot line, so
    ## this reads the decision rather than making a second one. `ui_js`'s own
    ## `currentRendererEntry()` below re-reads the location for the mount; the
    ## two agree because both go through `platform/web_entry.resolveEntry`.
    let booted = await startWebSession()

    # THE UPGRADE PATH, installed before anything can trigger it. A save is
    # what triggers the re-request (see `recheckPersistence`), and the first
    # save cannot happen until the renderer below has mounted — but installing
    # after the mount would be a race against a fast first Ctrl+S.
    web_project_persistence.setPersistenceUpgradeHandler(proc(message: string) =
      if not data.viewsApi.isNil:
        data.viewsApi.showNotification(
          newNotification(NotificationKind.NotificationSuccess, message)))

    await web_project_persistence.prepareProject(
      booted, templateFor(booted.entry.languageEntry))
    startWebRenderer()
    awaitStatusBarThenRaise(durabilityNoticeMountAttempts)

  discard startWebArm()

# The DEV-SERVER arm, unchanged, and now guarded against the web build rather
# than serving as its accidental default. `not defined(ctWeb)` is the whole of
# the change here: everything below assumes a page that loaded socket.io and
# had `frontendSocketPort` / `frontendSocketParameters` injected into it by
# `views/server_index.ejs`, which is true of `just serve` and false of a CDN.
when not defined(ctInExtension) and not defined(ctWeb):
  if not inElectron:
    var io {.importc.}: proc(address: cstring, options: JsObject): js
    var frontendSocketPort {.importc.}: int
    var frontendSocketParameters {.importc.}: cstring

    proc startIPC =
      let host = domwindow.location.hostname.to(cstring)
      let parameters = if frontendSocketParameters.len > 0:
          cstring"/" & frontendSocketParameters
        else:
          cstring""

      let port = if frontendSocketPort != -1:
          cstring($frontendSocketPort)
        else:
          domwindow.location.port.to(cstring)

      let protocol = domwindow.location.protocol.to(cstring)
      let wsProtocol = if protocol == cstring"https:":
          cstring"wss:"
        else: # assume http: , can it be different?
          cstring"ws:"
      let address = if port != cstring"":
          cstring(fmt"{wsProtocol}//{host}:{port}")
        else:
          cstring(fmt"{wsProtocol}//{host}")

      console.log protocol, wsProtocol, address
      var socket = io(
        address,
        js{withCredentials: false, query: cstring(fmt"socketParam={parameters}&pathname={domwindow.location.pathname.to(cstring)}")})
      socketdebug = socket
      socket.on(cstring"disconnect") do (reason: cstring):
        updateConnectionState(data, false, ConnectionLossUnknown, reason)
      socket.on(cstring"CODETRACER::connection-disconnected") do (payload: cstring):
        var parsedReason = ConnectionLossUnknown
        var detail = cstring""
        try:
          let parsed = JSON.parse(payload)
          if not parsed.isNil and not parsed[cstring"reason"].isUndefined:
            parsedReason = connectionReasonFromPayload(cast[cstring](parsed[cstring"reason"]))
          if not parsed.isNil and not parsed[cstring"message"].isUndefined:
            detail = cast[cstring](parsed[cstring"message"])
        except:
          discard
        updateConnectionState(data, false, parsedReason, detail)
      socket.on(cstring"connect") do ():
        updateConnectionState(data, true, ConnectionLossNone, cstring"")
        ipc = js{
          send: proc(id: cstring, response: js) =
            if not data.connection.connected:
              showDisconnectedWarning(data, data.connection.reason, data.connection.detail)
            console.log cstring"=> ", id, response
            socket.emit(id, response),
          on: proc(id: cstring, code: js) = socket.on(id, proc(response: cstring) =
            console.log cstring"<= ", id, response
            code.call(code, undefined, JSON.parse(response))
            )}
        data.ipc = ipc
        configureIPC(data)
        configure(data)

    startIPC()

when defined(ctInExtension):
  once:
    # configureIPC(data)
    configure(data)

if inElectron:
  once:
    configureIPC(data)
    configure(data)
    cast[JsObject](dom.window)["__CODETRACER_DATA__"] = data.toJs
