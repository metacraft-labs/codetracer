## shortcuts.nim — the desktop renderer's keyboard set-up and its shortcuts
## dialog.
##
## PLAT-68: every key goes through ONE capture-phase listener and the shared
## router (`ui/key_router`). What used to live here — the Mousetrap binding
## loop over the YAML table, the chords bound in code after it, the Monaco
## `commands` table and the config chords mirrored into Monaco — were three
## registries that disagreed with each other (one key running two actions by
## focus, `F2` swallowed, an F-key dispatched twice). They are gone; their
## behaviours are operations of the keymap now:
##
##   * `Alt+E` / `Alt+C` / `Alt+V` focus the event log, the call trace, the
##     editor (`layout.focus-pane`), in EVERY focus context — `Alt+E` no
##     longer toggles macro expansion when the caret is in Monaco;
##   * `Ctrl+1`…`9` (`layout.focus-pane-by-index`), `Ctrl+F5`
##     (`session.toggle-product-mode`), `Alt+F10` / `Alt+Shift+F10` (the
##     statement steps), `Ctrl+Shift+O` (`editor.jump-to-value-origin`, the
##     value-origin chain of the selection or the word at the caret);
##   * `Ctrl+B` toggles the side panels and `Ctrl+Shift+B` builds, as in
##     VS Code; re-recording is the palette's (`session.re-record`).
##
## What stays here: the mouse's back / forward buttons and the palette's
## press-to-activate, and the shortcuts dialog — which lists the chords the
## router RUNS (`key_router.chordForAction`), and whose stepping presets are
## `keybindings.json` include sets now.

import
  jsffi,
  std/[strutils, options],
  isonim/core/signals,
  ui_imports, trace,
  # The toolbar's history, for the mouse's back and forward buttons.
  ./debug_toolbar,
  ./shortcut_labels,
  ./shortcut_presets,
  ./shortcut_dialog,
  ./shortcut_preference,
  ./key_router

export key_router

proc isMacPlatform*(): bool =
  ## Whether `Ctrl` reads as COMMAND on this machine (the dialog's chord
  ## spelling).
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

const ShortcutDialogHostId = "keyboard-shortcuts-dialog"

proc closeShortcutsDialog*() =
  ## Remove the dialog if it is open. Idempotent, because both the close button
  ## and a second press of the opening chord land here.
  let existing = getElementById(ShortcutDialogHostId)
  if not existing.isNil and not existing.parentNode.isNil:
    existing.parentNode.removeChild(existing)

proc openShortcutsDialog*() =
  ## Show what is bound, and offer the stepping presets.
  ##
  ## The chords are the ones the router RUNS (`chordForAction`). A preset is
  ## a `keybindings.json` include set (`stepping:<id>`): choosing one asks the
  ## main process to write it into the file (replacing the previous one), and
  ## the file's reload re-keys the window and redraws the dialog.
  closeShortcutsDialog()
  let mac = isMacPlatform()
  let active = activePreset()
  let tree = buildShortcutDialog(proc(action: ClientAction): string =
                                   $chordForAction(action),
                                 active, mac, keybindingsNotes)
  let host = mountShortcutDialog(tree)
  host.setAttribute("id", ShortcutDialogHostId)

  # The preset buttons and the close button, wired by the attribute the builder
  # stamped rather than by position — so reordering the picker cannot silently
  # rewire it.
  let presetButtons = host.querySelectorAll("[data-kb-preset]")
  for index in 0 ..< presetButtons.len:
    closureScope:
      let button = cast[Element](presetButtons[index])
      let chosen = parsePresetId($button.getAttribute("data-kb-preset"))
      button.addEventListener("click", proc(ev: Event) =
        storePreset(chosen)
        if not data.ipc.isNil:
          data.ipc.send(cstring"CODETRACER::keybindings-import",
                        js{preset: cstring($chosen), replace: true})
        closeShortcutsDialog())
  for node in host.querySelectorAll("[data-kb-close]"):
    cast[Element](node).addEventListener("click", proc(ev: Event) =
      closeShortcutsDialog())

  kdom.document.body.appendChild(host)

var pointerInstalled = false

proc configureShortcuts* =
  ## The keyboard (`installKeyRouter`) and the two pointer gestures this
  ## module still owns. Idempotent: the renderer's start-up paths (init, no
  ## trace, the welcome screen) all call it, and each used to add another
  ## `mousedown` listener.
  installKeyRouter()
  if pointerInstalled:
    return
  pointerInstalled = true
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
      moveInDebugHistory(historyDirectionOfMouseButton(mouseButton))
  )
