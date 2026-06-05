import
  jsffi,
  std/strutils,
  isonim/core/signals,
  ui_imports, trace,
  ./video_player,
  ../viewmodel/viewmodels/video_player_vm

const
  NO_CODE: int = -1
  BROWSER_FORWARD: int = 3
  BROWSER_BACK: int = 4

proc shortcut*(shortcut: string): int =
  let tokens = shortcut.split("+", 2)
  var buttonToken = if tokens[^1].len == 1: cstring(&"Key{tokens[^1].toUpperAscii}") else: cstring(tokens[^1])

  if tokens[^1] == "=":
    buttonToken = "Equal"
  elif tokens[^1] == "-":
    buttonToken = "Minus"
  elif tokens[^1] == "Esc":
    buttonToken = "Escape"

  var button = cast[int](monaco.KeyCode[buttonToken])

  if cast[JsObject](button).isNil:
    return NO_CODE

  if tokens.len == 1:
    result = button
  else:
    let KeyMod = monaco.KeyMod
    for i in 0 ..< tokens.len - 1:
      var code = NO_CODE

      if tokens[i] == "ALT":
        code = cast[int](KeyMod.Alt)
      elif tokens[i] == "SHIFT":
        code = cast[int](KeyMod.Shift)
      elif tokens[i] == "CTRL":
        code = cast[int](KeyMod.CtrlCmd)

      if code == NO_CODE:
        return NO_CODE

      if i == 0:
        result = code
      else:
        result = result or code

    result = result or button

proc delegateShortcut*(
  editor: EditorViewComponent,
  shortcutText: cstring,
  command: proc(editor: MonacoEditor, e: EditorViewComponent),
  monacoEditor: MonacoEditor
) =
  ## try to register a shortcut with a command for it to a monaco editor in its editor view component
  ## on error, print an error message to console
  let shortcutCode = shortcut($shortcutText)

  if shortcutCode != NO_CODE:
    cdebug "shortcut: register shortcut " & $shortcutText & " " & $shortcutCode
    let test = if shortcutText == cstring"Enter": cstring"readOnly" else: cstring""

    monacoEditor.addCommand(shortcutCode, proc = command(monacoEditor, editor))
  else:
    cerror fmt"shortcut: can't generate a monaco editor shortcut for {shortcutText}"


proc bindShortcut(action: ClientAction, renderer: cstring) =
  Mousetrap.`bind`(renderer) do ():
    cdebug "shortcuts: global handle " & $renderer & " " & $action
    data.actions[action](nil)

# ---------------------------------------------------------------------------
# Video Player keyboard overlay (M4).
#
# Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md §Keyboard
#       Shortcuts.
# Milestones: Visual-Replay.milestones.org §M4.
#
# The visual replay player shares several keys with conventional bindings
# (Esc / Home / End / arrow keys collide with aEscape / gotoStart / gotoEnd
# / goLeft / goRight; Space / arrow keys would also disrupt Monaco when an
# editor is focused).  The current ShortcutMap loader (config.nim
# ``initShortcutMap``) is one-action-per-key, so we cannot rely on the YAML
# entries alone to satisfy the spec.  The overlay below installs a single
# Mousetrap handler per Video Player key.  The handler:
#
#   1. Dispatches the Video Player ClientAction when the Video Player panel
#      is focused (or the cursor is hovering its frame canvas).
#   2. Otherwise falls back to the prior ClientAction bound to the same key
#      via the YAML config — preserving F10 → Step Over for the debugger,
#      Esc → onEscape for the active focus component, etc.
#   3. Returns ``false`` (preventDefault + stopPropagation) only when the
#      Video Player action ran, so Monaco still receives arrow keys, Esc,
#      Home / End when it has focus.
#
# Keep this list in lockstep with the spec's keyboard table and with the
# YAML entries under ``videoPlayer*`` in ``default_config.yaml``.

const videoPlayerOverlayBindings: array[11, tuple[
    renderer: cstring; action: ClientAction]] = [
  (cstring"space", ClientAction.videoPlayerTogglePlay),
  (cstring"k",     ClientAction.videoPlayerTogglePlay),
  (cstring"j",     ClientAction.videoPlayerRewind),
  (cstring"l",     ClientAction.videoPlayerFastForward),
  (cstring"left",  ClientAction.videoPlayerStepFrameBack),
  (cstring"right", ClientAction.videoPlayerStepFrameForward),
  (cstring"shift+left",  ClientAction.videoPlayerStepDrawBack),
  (cstring"shift+right", ClientAction.videoPlayerStepDrawForward),
  (cstring"home",  ClientAction.videoPlayerJumpStart),
  (cstring"end",   ClientAction.videoPlayerJumpEnd),
  (cstring"p",     ClientAction.videoPlayerTogglePicker),
  # ``videoPlayerCancelPicker`` is handled separately below because Esc
  # collides with ``aEscape`` and the fall-through logic is asymmetric (the
  # dispatcher returns ``false`` from the wrapper handler when picker mode
  # is off so other Escape consumers still see the key).
]

const videoPlayerCancelBinding: tuple[
    renderer: cstring; action: ClientAction] =
  (cstring"esc", ClientAction.videoPlayerCancelPicker)

proc invokeFallbackForKey(renderer: cstring): bool =
  ## When the Video Player overlay decides NOT to consume a key, route the
  ## key to whatever ClientAction the YAML config originally assigned to it
  ## (if any).  Returns ``true`` when a fallback ran so the wrapper can
  ## decide whether to preventDefault.  Skips the Video Player actions
  ## themselves to prevent infinite recursion if a user re-binds e.g. Esc
  ## to ``videoPlayerCancelPicker`` in a custom config.
  if data.config.isNil or data.config.shortcutMap.shortcutActions.isNil:
    return false
  let upper = ($renderer).toUpperAscii.cstring
  if not data.config.shortcutMap.shortcutActions.hasKey(upper):
    return false
  let action = data.config.shortcutMap.shortcutActions[upper]
  case action
  of ClientAction.videoPlayerTogglePlay,
     ClientAction.videoPlayerRewind,
     ClientAction.videoPlayerFastForward,
     ClientAction.videoPlayerStepFrameBack,
     ClientAction.videoPlayerStepFrameForward,
     ClientAction.videoPlayerStepDrawBack,
     ClientAction.videoPlayerStepDrawForward,
     ClientAction.videoPlayerJumpStart,
     ClientAction.videoPlayerJumpEnd,
     ClientAction.videoPlayerTogglePicker,
     ClientAction.videoPlayerCancelPicker:
    return false
  else:
    let handler = data.actions[action]
    if handler.isNil:
      return false
    cdebug "shortcuts: video-player overlay falling back to " & $action
    handler(nil)
    return true

proc bindVideoPlayerOverlay(renderer: cstring; action: ClientAction) =
  ## Install a single video player overlay handler for one key.  Extracted
  ## into its own proc so each closure captures its own (renderer, action)
  ## without the ``capture`` macro tripping over tuple destructuring.
  Mousetrap.`bind`(renderer) do () -> bool:
    if videoPlayerHasFocus():
      let handler = data.actions[action]
      if not handler.isNil:
        handler(nil)
      ## Returning ``false`` tells Mousetrap to preventDefault /
      ## stopPropagation — appropriate when we actually consumed the
      ## key for the Video Player.
      return false
    ## Not focused on the Video Player — let the original binding take over.
    ## We invoke it manually here because Mousetrap's bind() replaced the
    ## YAML-driven handler with this wrapper.
    let ran = invokeFallbackForKey(renderer)
    if ran:
      return false
    ## Return ``true`` to let the browser handle the key normally
    ## (important for arrow keys reaching Monaco, etc.).
    return true

proc bindVideoPlayerCancelOverlay(renderer: cstring; action: ClientAction) =
  ## Esc gets its own wrapper because the dispatcher signals fall-through via
  ## a bool return when picker mode is inactive.  Spec: Visual-Replay.md
  ## §Pixel Picker Mode — "Press Escape … → Exit picker mode without
  ## committing." but only when picker is active.
  Mousetrap.`bind`(renderer) do () -> bool:
    if videoPlayerHasFocus():
      let vm = currentVideoPlayerVM()
      if not vm.isNil and vm.pickerState.val == PickerActive:
        data.actions[action](nil)
        return false
    ## Either the Video Player isn't focused or picker mode is off — fall
    ## through to the YAML-defined Esc binding (aEscape -> activeFocus.onEscape).
    let ran = invokeFallbackForKey(renderer)
    if ran:
      return false
    return true

proc configureVideoPlayerShortcuts() =
  ## Install one Mousetrap binding per spec-defined Video Player key.  Must
  ## run AFTER the YAML-driven ``bindShortcut`` loop in ``configureShortcuts``
  ## so the wrapper handlers shadow any prior bindings on the same keys.
  for entry in videoPlayerOverlayBindings:
    bindVideoPlayerOverlay(entry.renderer, entry.action)
  bindVideoPlayerCancelOverlay(
    videoPlayerCancelBinding.renderer, videoPlayerCancelBinding.action)

proc configureShortcuts* =
  if data.config.shortcutMap.conflictList.len > 0:
    cwarn "shortcuts: LIST OF SHORTCUT CONFLICTS"
    for (shortcut, actions) in data.config.shortcutMap.conflictList:
      cwarn "  shortcuts: " & $shortcut & "  " & $actions

  for action, shortcuts in data.config.shortcutMap.actionShortcuts:
    for shortcut in shortcuts:
      bindShortcut(action, shortcut.renderer)

  kdom.document.addEventListener("mousedown", proc(e: Event) =
    # Command palette active state control
    let element = getElementById("command-view")
    if element != nil:
      let rect = element.getBoundingClientRect()
      let mouseEvent = MouseEvent(e)
      let inside = mouseEvent.clientX.float >= rect.left and mouseEvent.clientX.float <= rect.right and
                  mouseEvent.clientY.float >= rect.top and mouseEvent.clientY.float <= rect.bottom
      if inside:
        data.ui.commandPalette.active = true
        data.search(SearchFileRealTime, "".cstring)
      else:
        data.ui.commandPalette.active = false
        data.ui.commandPalette.inAgentMode = false
        if not data.ui.commandPalette.agent.isNil and not data.ui.commandPalette.agent.shell.isNil:
          data.ui.commandPalette.agent.shell.initialized = false

    if cast[int](e.toJs.button) == BROWSER_FORWARD:
      cast[DebugComponent](data.ui.componentMapping[Content.Debug][0]).handleHistoryJump(isForward = true)
    elif cast[int](e.toJs.button) == BROWSER_BACK:
      cast[DebugComponent](data.ui.componentMapping[Content.Debug][0]).handleHistoryJump(isForward = false)
  )

  Mousetrap.`bind`("f1") do ():
    discard

  Mousetrap.`bind`("f2") do ():
    discard

  # Mousetrap.`bind`("alt+0") do ():
  #   openNormalEditor()

  # Mousetrap.`bind`("alt+1") do ():
  #   discard openLowLevel(1)

  # Mousetrap.`bind`("alt+2") do ():
  #   discard openLowLevel(2)

  # Mousetrap.`bind`("alt+f+0") do ():
  #   data.ui.editors[data.services.editor.active].flow.switchFlowUI(FlowParallel)

  # Mousetrap.`bind`("alt+f+1") do ():
  #   data.ui.editors[data.services.editor.active].flow.switchFlowUI(FlowInline)

  # Mousetrap.`bind`("alt+f+2") do ():
  #   data.ui.editors[data.services.editor.active].flow.switchFlowUI(FlowMultiline)

  for i in 1 .. 9:
    capture [i]:
      discard Mousetrap.`bind`("CTRL+" & $i) do ():
        cdebug "shortcuts: CTRL+" & $i
        discard data.ui.activeFocus.onCtrlNumber(i)

  Mousetrap.`bind`("ctrl+r") do ():
    data.reRecordCurrent(projectOnly=false)

  Mousetrap.`bind`("alt+l") do ():
    let options = RunTestOptions(newWindow: true, path: data.services.debugger.location.path, testName: "")
    data.runTests(options)

  Mousetrap.`bind`("ctrl+b") do ():
    data.reRecordCurrent(projectOnly=true)

  # Mousetrap.`bind`("alt+t") do ():
  #   runTracepoints(data)

  Mousetrap.`bind`("ctrl+pageup") do ():
    switchTab(change = -1)

  Mousetrap.`bind`("ctrl+pagedown") do ():
    switchTab(change = 1)

  Mousetrap.prototype.stopCallback = proc(): bool =
    return false

  Mousetrap.`bind`("alt+e") do ():
    data.focusEventLog()

  Mousetrap.`bind`("alt+c") do ():
    data.focusCalltrace()

  Mousetrap.`bind`("alt+v") do ():
    data.focusEditorView()

  Mousetrap.`bind`("ctrl+alt+d") do ():
    data.ipc.send("CODETRACER::open-devtools", JsObject{})

  ## Visual Replay / Video Player keyboard overlay must register LAST so its
  ## wrappers shadow any prior bindings on shared keys (Esc, Home, End, arrow
  ## keys).  Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
  ## §Keyboard Shortcuts.
  configureVideoPlayerShortcuts()
