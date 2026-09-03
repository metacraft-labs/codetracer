import
  jsffi,
  std/strutils,
  isonim/core/signals,
  ui_imports, trace,
  # `debug` FOR `handleHistoryJump`, and the import is the fix.
  #
  # Until now this module called that name without importing anything that
  # declares it for a `DebugComponent`: it bound to a `{.base.}` method on
  # `Component` in `types.nim` whose body was `discard`, so both mouse
  # side-button handlers below compiled, dispatched and did nothing. The base
  # is gone; this import is what makes the call reach the implementation, and
  # what makes its absence a build error rather than a dead gesture.
  ./debug,
  ./shortcut_presets,
  ./shortcut_dialog,
  ./shortcut_preference,
  ./video_player,
  ../viewmodel/viewmodels/video_player_vm,
  ../../common/ct_event,
  ../dap

const
  NO_CODE: int = -1
  # `BROWSER_FORWARD = 3` / `BROWSER_BACK = 4` WERE HERE, AND THEY WERE
  # SWAPPED. `MouseEvent.button` 3 is the fourth button, which every desktop
  # browser makes BACK, and 4 is the fifth, which is FORWARD. The two branches
  # below read consistently with those wrong names, so the mouse path carried
  # its own pair of cancelling inversions on top of `isForward`'s.
  #
  # The numbers now live in `history_cursor` as `MouseButtonBack` /
  # `MouseButtonForward`, beside the proc that turns one into a direction, so
  # `test_history_cursor` can state which physical button walks which way.

proc shortcut*(shortcut: string): int =
  # `chordTokens` SPLITS ON EVERY `+`. This line used to read
  # `shortcut.split("+", 2)` — a maximum of two splits, therefore a maximum of
  # three tokens — and the consequence was silent: a four-token chord like
  # `CTRL+ALT+SHIFT+R` had its key parsed as `"SHIFT+R"`, `monaco.KeyCode` has
  # no such member, `button` came back nil and the proc returned `NO_CODE`. So
  # `delegateShortcut` logged one `cerror` and registered nothing, and the
  # chord was dead with the caret in the editor while working everywhere else.
  #
  # Nothing in `default_config.yaml` had four tokens, so the limit cost
  # nothing until a preset wanted `SHIFT` as its "backwards" modifier on top of
  # `CTRL+ALT`. It is shared with `ui/shortcut_presets.nim` rather than
  # duplicated because the dialog and this parser must agree about where a
  # chord's modifiers end and its key begins.
  let tokens = chordTokens(shortcut)
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

proc isMacPlatform*(): bool =
  ## Whether Monaco's `KeyMod.CtrlCmd` means COMMAND on this machine.
  ##
  ## Read from the browser rather than from a `when defined(...)` because the
  ## renderer is one bundle served to every platform — a compile-time answer
  ## would be the BUILDER's operating system, which is not the visitor's.
  when defined(js):
    var mac: bool = false
    {.emit: [mac, """ = /Mac|iPhone|iPad|iPod/.test(
      (typeof navigator !== 'undefined' &&
       (navigator.platform || navigator.userAgent)) || '');"""].}
    mac
  else:
    false

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

    # THE LITERAL CONTROL KEY ON macOS, and the reason a `CTRL+…` chord
    # otherwise does nothing in the editor on a Mac.
    #
    # `shortcut()` above maps `CTRL` to `KeyMod.CtrlCmd`, and Monaco defines
    # that as COMMAND on macOS and Control everywhere else. So the command
    # registered on the line above answers Cmd+B on a Mac and Ctrl+B on Linux
    # and Windows — while `default_config.yaml`, the menus and the Mousetrap
    # bind in `bindShortcut` all say CTRL, literally, on every platform.
    #
    # Measured on the assembled bundle, caret in `src/main.nr`, macOS: with
    # `CTRL+B` whitelisted, `Control+b` produced NO delivery and `Meta+b`
    # produced exactly one (`monaco handle CTRL+B build`, and the Noir build
    # ran). So the chord worked and it was not the chord the product told the
    # user to press — which is the same class of false claim as a binding that
    # does not exist, and is how this arrived as a bug report.
    #
    # `KeyMod.WinCtrl` IS the literal Control key on macOS, so registering the
    # same command under it gives the Mac both: Cmd+B, which is what a Mac user
    # expects, and Ctrl+B, which is what the product says. Guarded to macOS
    # because off it `WinCtrl` is the Windows/Meta key — a chord nothing here
    # means and the OS often owns.
    #
    # It cannot double-deliver: Cmd+B and Ctrl+B are different key events, so
    # one press raises one of them, and Mousetrap's `ctrl+b` never reaches the
    # editor (the keydown does not survive to `document`'s bubble phase with
    # the caret in Monaco). `ci/test/chord-and-pane-uniqueness.sh` measures
    # exactly this over all 11 whitelisted chords in both focus contexts.
    if isMacPlatform():
      let KeyMod = monaco.KeyMod
      let ctrlCmd = cast[int](KeyMod.CtrlCmd)
      let winCtrl = cast[int](KeyMod.WinCtrl)
      if ctrlCmd != 0 and winCtrl != 0 and (shortcutCode and ctrlCmd) != 0:
        let literalCtrl = (shortcutCode and not ctrlCmd) or winCtrl
        cdebug "shortcut: register mac literal-control variant " &
          $shortcutText & " " & $literalCtrl
        monacoEditor.addCommand(
          literalCtrl, proc = command(monacoEditor, editor))
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

const ShortcutDialogHostId = "keyboard-shortcuts-dialog"

proc configureShortcuts*()
  ## Forward-declared because `applyShortcutPresetChoice` below re-runs it: a
  ## preset change has to re-register the whole table, and the proc that does
  ## that is defined after the dialog it is called from.

proc closeShortcutsDialog*() =
  ## Remove the dialog if it is open. Idempotent, because both the close button
  ## and a second press of the opening chord land here.
  let existing = getElementById(ShortcutDialogHostId)
  if not existing.isNil and not existing.parentNode.isNil:
    existing.parentNode.removeChild(existing)

proc applyShortcutPresetChoice(id: ShortcutPresetId) =
  ## Remember a choice and put it into effect.
  ##
  ## REBUILDING THE CONFIG IS NOT ENOUGH ON ITS OWN. `configureShortcuts` calls
  ## `Mousetrap.bind` once per chord, and Mousetrap keeps a binding until
  ## something replaces it — so a preset that moved Step Over from `F10` to
  ## `CTRL+ALT+O` would leave `F10` still bound to Step Over unless the old
  ## table is cleared first. `Mousetrap.reset()` is what clears it, and it is
  ## safe here precisely because `configureShortcuts` re-registers EVERYTHING
  ## it is responsible for: the config table, the hardcoded chords below, and
  ## the Video Player overlay through `configureVideoPlayerShortcuts`.
  ##
  ## The editor is the other half and is deliberately NOT re-run here. Monaco
  ## commands are registered per editor instance in `delegateShortcuts` when
  ## the instance is created, and there is no removal API for them — calling it
  ## again would add a second command for every chord rather than replace the
  ## first. So an open editor keeps the chords it was built with until it is
  ## recreated, which the dialog says.
  storePreset(id)
  data.config = defaultRendererConfig(id)
  Mousetrap.reset()
  configureShortcuts()

proc openShortcutsDialog*() =
  ## Show what is bound, and offer the presets.
  ##
  ## WHY THIS IS NOT ON THE TOPBAR. `Planned-Features/Noir-Studio.md` §1a.2
  ## settles the topbar's one addition — a Share icon beside the identity
  ## avatar — and counts "the debugger controls, the omnibar, the tabs" as
  ## already on it. The session tab bar is therefore part of the topbar, so a
  ## gear beside its `+` would be a second addition to the surface that section
  ## closed. §1a.2 also names the alternative in its own words, about `Deploy`:
  ## "the command palette and a project-level menu are both better candidates"
  ## for something "rare" and "consequential". A keymap is chosen rarely and
  ## never mid-gesture, so it goes in the menu and answers a chord.
  closeShortcutsDialog()
  let mac = isMacPlatform()
  let active = activePreset()
  let tree = buildShortcutDialog(data.config, active, mac)
  let host = mountShortcutDialog(tree)
  host.setAttribute("id", ShortcutDialogHostId)

  # The preset buttons and the close button, wired by the attribute the builder
  # stamped rather than by position — so reordering the picker cannot silently
  # rewire it.
  for node in host.querySelectorAll("[data-kb-preset]"):
    let button = cast[Element](node)
    let chosen = parsePresetId($button.getAttribute("data-kb-preset"))
    button.addEventListener("click", proc(ev: Event) =
      applyShortcutPresetChoice(chosen)
      openShortcutsDialog())
  for node in host.querySelectorAll("[data-kb-close]"):
    cast[Element](node).addEventListener("click", proc(ev: Event) =
      closeShortcutsDialog())

  kdom.document.body.appendChild(host)

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

    let mouseButton = cast[int](e.toJs.button)
    if mouseButton == MouseButtonBack or mouseButton == MouseButtonForward:
      if data.ui.componentMapping[Content.Debug].len > 0:
        cast[DebugComponent](data.ui.componentMapping[Content.Debug][0])
          .handleHistoryJump(historyDirectionOfMouseButton(mouseButton))
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

  # ALT+L (Run tests) MOVED TO `src/config/default_config.yaml` as `aRunTests`.
  #
  # It used to be a bare `Mousetrap.bind("alt+l")` here, with a copy of the
  # `RunTestOptions` body that `ui/debug.nim`'s `action("run-tests")` already
  # held — that file's copy still carries the comment "copied from alt+l
  # shortcut handling in shortcuts.nim". Two copies of one behaviour, and a
  # chord that no `ClientAction` named.
  #
  # The reason it had to move is the point of this change rather than tidiness:
  # a hard-bound chord is INVISIBLE to `menu.nim:151 loadShortcut`, which reads
  # `config.shortcutMap.actionShortcuts`. The Run-tests toolbar button could
  # therefore never have displayed its chord without hardcoding the string —
  # and a hardcoded chord is exactly what goes stale when someone rebinds. The
  # chord itself is unchanged, so no muscle memory moves.
  #
  # The loop at the top of this proc now installs it, and it dispatches through
  # `data.actions[ClientAction.aRunTests]` into the same `action("run-tests")`
  # the button uses, so the two paths can no longer drift apart.

  # CTRL+B IS A CONFIGURED SHORTCUT, AND THIS LINE SHADOWS IT.
  #
  # `src/config/default_config.yaml` binds `build: "CTRL+B"`, the loop at the
  # top of this proc binds it to `ClientAction.build`, and then this runs and
  # replaces it — Mousetrap's `bind` overwrites a chord rather than chaining —
  # so the YAML entry has been dead on every platform. Left alone on the
  # desktop, where re-recording the project is what the chord has meant in
  # practice and changing it is not this milestone's business.
  #
  # EXCLUDED FROM THE WEB BUILD, because there it is not merely a surprise but
  # a dead end. `reRecordCurrent` returns immediately when `data.trace.isNil`
  # ("No trace is loaded; nothing to re-record."), and a tab in edit mode never
  # has a trace — so Ctrl+B in the browser could do nothing else, ever. With
  # this line out of the way the configured `build` action reaches
  # `data.actions[ClientAction.build]`, which `ui_js.nim`'s web arm points at
  # the Noir wasm toolchain.
  #
  # `data.actions` is read AT PRESS TIME by `bindShortcut`, which is why the
  # web arm can install its handler whenever it likes: `configureShortcuts`
  # runs again from `onNoTrace` and `onWelcomeScreen`, and a rebinding race
  # over the chord would otherwise decide whether Build worked.
  when not defined(ctWeb):
    Mousetrap.`bind`("ctrl+b") do ():
      data.reRecordCurrent(projectOnly=true)

  # Mousetrap.`bind`("alt+t") do ():
  #   runTracepoints(data)

  Mousetrap.`bind`("ctrl+pageup") do ():
    switchTab(change = -1)

  Mousetrap.`bind`("ctrl+pagedown") do ():
    switchTab(change = 1)

  # WHAT THIS IS FOR, and what it is no longer for. Measured in a real tab
  # against the assembled web bundle on 2026-09-02; the gate is
  # `ci/test/chord-and-pane-uniqueness.sh` and the probes it drives are
  # `ci/test/chord_double_fire_probe.mjs` and
  # `ci/test/chord_stopcallback_probe.mjs`.
  #
  # Mousetrap's DEFAULT `stopCallback` returns `true` — swallow the chord —
  # when the event target is an INPUT / SELECT / TEXTAREA or `isContentEditable`
  # and does not carry the class `mousetrap`
  # (`node_modules/mousetrap/mousetrap.js`). Returning `false` unconditionally
  # therefore means: every chord fires no matter where the caret is.
  #
  # THE ORIGINAL REASON WAS MONACO, AND IT HAS EXPIRED. Monaco used to take
  # keystrokes on a hidden `textarea.inputarea`, which the default rule
  # swallowed, so without this line F8/F10/F11/F12 died whenever the caret was
  # in the code editor. Current Chromium Monaco uses the EditContext API
  # instead: the focused element is `div.native-edit-context`, with
  # `isContentEditable == false` and no `mousetrap` class, so the DEFAULT rule
  # already returns `false` for it. Measured on the shipped bundle:
  # `hasTextareaInputArea: false`, `hasNativeEditContext: true`,
  # `defaultWouldStop: false` for the focused element. Monaco no longer needs
  # this line at all.
  #
  # WHAT IT STILL BUYS, and this is the reason it is not simply deleted. Five
  # ordinary inputs in the page WOULD be blocked by the default rule, because
  # nobody tagged them: `#fixed-search-include`, `#fixed-search-exclude`,
  # `textarea.ime-text-area`, `#fif-input` and `.request-filter-search`. Two
  # others are already exempt the intended way, by carrying the class —
  # `#command-query-text` and `#fixed-search-query`. So the product HAS a
  # per-element mechanism for this and uses it inconsistently; this line is the
  # blunt instrument covering the gap. Deleting it would silently kill chords
  # in those five, and narrowing it is a behaviour change about whether F10
  # should step while you are typing in the Find-in-Files filter — a question
  # worth answering deliberately, by tagging those five `mousetrap`, rather
  # than as a side effect of a cleanup.
  #
  # IT IS NOT A DOUBLE-DELIVERY HAZARD TODAY, which is the thing this comment
  # exists to stop being rediscovered. The whitelisted chords in
  # `ui/editor.nim`'s MONACO_SHORTCUTS_WHITELIST are registered BOTH as Monaco
  # commands (`delegateShortcuts`) and as Mousetrap binds (`bindShortcut`
  # above), and both call the same `data.actions[action]`. The two never both
  # deliver: with the caret in Monaco, Monaco's keybinding service
  # `preventDefault`s AND `stopPropagation`s, so the event never reaches
  # Mousetrap's listener on `document`; with the caret outside, Monaco's
  # command does not run. Measured over all ten whitelisted chords in both
  # focus contexts — 20 presses, every one delivering exactly once, and never
  # by both paths.
  #
  # THE HAZARD IS REAL FOR THE NEXT CHORD, THOUGH, and that is what the gate
  # is for rather than this line. A chord Monaco ALSO binds natively breaks the
  # exclusivity: the build-error-navigation work measured ALT+F8 (Monaco's
  # marker navigation) firing TWICE per press when whitelisted and never when
  # not. Nothing in the product would notice — stepping's apparent immunity is
  # `data.status.stableBusy`, a step-serialisation guard that swallows a second
  # delivery by accident, and a non-stepping action has no such accident.
  # Anything added to MONACO_SHORTCUTS_WHITELIST must go through the gate.
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

  # Value Origin Tracking (M4) — `CodeTracer: Show Value Origin`
  # default keybinding per spec §3.7 / M4 deliverable. Ctrl+Shift+O
  # on Linux/Windows; Cmd+Shift+O on macOS (Mousetrap maps "command"
  # automatically). The handler reads the focused editor's word at
  # the cursor (mirrors the right-click "Show value origin" context
  # menu entry in `ui/value.nim`) and forwards a `ct/originChain`
  # request through the existing DAP transport.
  proc dispatchShowValueOrigin() =
    ## Shared handler for the `CodeTracer: Show Value Origin`
    ## keybindings. Reads the focused editor's selection (or word
    ## under the cursor) and forwards a `ct/originChain` request
    ## through `data.dapApi`. Mirrors the right-click "Show value
    ## origin" entry in `ui/value.nim`.
    if data.isNil or data.activeSessionIndex < 0:
      return
    var expression: cstring = cstring""
    let activeEditorName = data.services.editor.active
    if not activeEditorName.isNil and
       data.ui.editors.hasKey(activeEditorName):
      let editor = data.ui.editors[activeEditorName]
      if not editor.isNil and not editor.monacoEditor.isNil:
        let monacoEditor = editor.monacoEditor
        let model = monacoEditor.toJs.getModel()
        let selection = monacoEditor.toJs.getSelection()
        if not selection.isNil:
          let selected = cast[cstring](
            model.getValueInRange(selection))
          if ($selected).strip().len > 0:
            expression = selected
        if expression.len == 0:
          let position = monacoEditor.toJs.getPosition()
          if not position.isNil:
            let wordInfo = model.getWordAtPosition(position)
            if not wordInfo.isNil:
              expression = cast[cstring](wordInfo.word)
    if expression.len == 0:
      cwarn "shortcuts: Show Value Origin — no editor selection " &
            "or word under cursor; ignoring"
      return
    # Build the `ct/originChain` payload identical to the one
    # `middleware.nim`'s `CtOriginChain` subscriber assembles. The
    # shortcut works from any focused surface because we go directly
    # through `data.dapApi`.
    let args = js{
      variableName: expression,
      variablePath: [],
      frameId: -1,
      stepId: -1,
      threadId: 0,
      maxHops: 16,
      lazy: false,
      sessionId: "",
      classifySource: true,
    }
    data.dapApi.sendCtRequest(CtOriginChain, args)

  # Value Origin Tracking (M4) — `CodeTracer: Show Value Origin`
  # default keybinding per spec §3.7 / M4 deliverable. Ctrl+Shift+O
  # on Linux/Windows; Cmd+Shift+O (`command+shift+o`) on macOS, which
  # Mousetrap recognises as the Meta key.
  Mousetrap.`bind`("ctrl+shift+o") do ():
    cdebug "shortcuts: Ctrl+Shift+O — Show Value Origin"
    dispatchShowValueOrigin()

  Mousetrap.`bind`("command+shift+o") do ():
    cdebug "shortcuts: Cmd+Shift+O — Show Value Origin"
    dispatchShowValueOrigin()

  # Column-Aware Replay Navigation (M2) — `Step Over Statement`
  # keybinding (Alt+F10) layered on top of the existing F10 line-
  # granularity step-over.  The legacy F10 / `next` action stays
  # bit-for-bit identical (spec §M2: legacy DAP `next` MUST keep its
  # line-granularity behaviour); Alt+F10 invokes the column-aware
  # `stepOverStatement` surface on the debugger service, which sends
  # a DAP `next` with `granularity: "statement"` so the replay-server
  # dispatches to the column-aware runner.  Reusing the existing
  # debug-controls component instead of introducing a new toolbar
  # button keeps the M2 surface compact.
  #
  # Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M2.
  Mousetrap.`bind`("alt+f10") do ():
    cdebug "shortcuts: Alt+F10 — Step Over Statement"
    if not data.isNil and not data.services.debugger.isNil:
      data.services.debugger.stepOverStatement()

  # Column-Aware Replay Navigation (M7) — `Step Back Statement`
  # keybinding (Alt+Shift+F10): time-travel symmetric counterpart of
  # M2's Alt+F10.  The mapping mirrors the existing reverse-debug
  # convention where the forward action is `KEY` and the reverse is
  # `Shift+KEY` (see `default_config.yaml`: F10/Shift+F10 for the
  # legacy line-granularity next/reverse-next pair).  Alt+F10 is the
  # forward column-aware step-over (M2); Alt+Shift+F10 layers the
  # `Shift` reverse-modifier on top to get the backward column-aware
  # step.  Falls through cleanly to the legacy F10 / Shift+F10
  # bindings — neither legacy keybind is touched.
  #
  # Spec: codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M7.
  Mousetrap.`bind`("alt+shift+f10") do ():
    cdebug "shortcuts: Alt+Shift+F10 — Step Back Statement"
    if not data.isNil and not data.services.debugger.isNil:
      data.services.debugger.stepBackStatement()

  ## Visual Replay / Video Player keyboard overlay must register LAST so its
  ## wrappers shadow any prior bindings on shared keys (Esc, Home, End, arrow
  ## keys).  Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
  ## §Keyboard Shortcuts.
  configureVideoPlayerShortcuts()
