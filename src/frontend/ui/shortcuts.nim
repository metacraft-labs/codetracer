import
  jsffi,
  karax, ui_imports

const NO_CODE: int = -1

proc shortcut*(shortcut: string): int =
  let tokens = shortcut.split("+", 2)
  var buttonToken = if tokens[^1].len == 1: j(&"Key{tokens[^1].toUpperAscii}") else: j(tokens[^1])

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
    data.actions[action]()

proc configureShortcuts* =
  if data.config.shortcutMap.conflictList.len > 0:
    cwarn "shortcuts: LIST OF SHORTCUT CONFLICTS"
    for (shortcut, actions) in data.config.shortcutMap.conflictList:
      cwarn "  shortcuts: " & $shortcut & "  " & $actions

  for action, shortcuts in data.config.shortcutMap.actionShortcuts:
    for shortcut in shortcuts:
      bindShortcut(action, shortcut.renderer)



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
    discard

  Mousetrap.`bind`("alt+t") do ():
    runTracepoints()

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
