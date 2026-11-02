## keybindings.nim — PLAT-68: the desktop's half of the ONE user keymap
## (Base-Keymaps-And-Layer-Stack.md §3.5), in Electron's main process.
##
## The terminal and GPUI read `keybindings.json` themselves
## (`viewmodel/host/keybindings_file`). The desktop's renderer cannot touch the
## filesystem, so the main process does the host's three jobs here, over the
## same location (`viewmodel/host/keybindings_location`) and the same pure
## importers (`viewmodel/keymap/keymap_importers`):
##
##   * the ONE-TIME IMPORT, when there is no `keybindings.json` yet: the
##     terminal's `.cttui-keys` and the desktop's EDITED YAML `bindings:`
##     block become rows of a new file, each source introduced by its
##     summary; the old files are left untouched and not read again;
##   * the TEXT, sent to the renderer (`CODETRACER::keybindings`), which
##     parses it with `user_keymap` and lays it over the base
##     (`ui/key_router`) — and sent again whenever the file changes on disk
##     (`fs.watchFile`), so an edit takes effect without a restart;
##   * the renderer's half of the import: the stepping preset the old
##     shortcuts dialog stored in `localStorage`, which only the renderer can
##     read, arrives as `CODETRACER::keybindings-import` and is merged into
##     the file once (`keymap_importers.withImported`); the same message with
##     `replace` is the dialog CHOOSING a preset, which makes the file's
##     stepping include that one (`withSteppingPreset`).

import
  std / [async, jsffi, os, sequtils, strutils],
  electron_vars, served_client,
  ../lib / [jslib, electron_lib],
  ../config as frontend_config,
  ../viewmodel/host/keybindings_location,
  ../viewmodel/keymap/keymap_importers,
  ../../common / ct_logging

const
  KeybindingsMessage* = "CODETRACER::keybindings"
  WatchIntervalMs = 500

var
  watching = ""
  importNotes: seq[string] = @[]
  onKeybindingsText*: proc(text: string) = nil
    ## Called with the file's text (or "") whenever it is sent to the
    ## renderer: the macOS native menu (`index/menu`) re-reads its
    ## accelerators from the router over the same text.

proc readIfExists(path: string): tuple[ok: bool, text: string] =
  if not fs.existsSync(cstring(path)):
    return (false, "")
  try:
    (true, $fs.readFileSync(cstring(path), cstring"utf8"))
  except CatchableError:
    (false, "")

proc writeText(path, text: string): string =
  ## "" or why the file could not be written.
  try:
    fs.mkdirSync(cstring(path.parentDir), js{recursive: true})
    fs.writeFileSync(cstring(path), cstring(text))
    ""
  except CatchableError as e:
    e.msg

proc importOldConfigsOnce(path: string): seq[string] =
  ## The first-run import (`keybindings_file.importOldConfigsOnce`'s rule):
  ## only when the file does not exist and an old surface does.
  result = @[]
  if fs.existsSync(cstring(path)):
    return
  let shipped = readIfExists(frontend_config.configDir / defaultConfigPath)
  let old = defaultOldConfigs(shipped.text)
  var imports: seq[ConfigImport] = @[]
  for candidate in old.cttuiKeys:
    let read = readIfExists(candidate)
    if read.ok:
      imports.add importCttuiKeys(read.text)
      break
  let yaml = readIfExists(old.userYaml)
  if yaml.ok:
    let imp = importYamlBindings(yaml.text, old.defaultYaml)
    if imp.total > 0: imports.add imp
  if imports.len == 0:
    return
  let failure = writeText(path, keybindingsText(imports))
  for imp in imports:
    result.add imp.summary
  if failure.len > 0:
    result.add "keybindings.json could not be written: " & failure

proc sendKeybindings*() =
  ## The file's text (or "" for none) to the renderer, with what the import
  ## said, if it ran.
  if mainWindow.isNil:
    return
  let path = keybindingsPath()
  let read = readIfExists(path)
  if not onKeybindingsText.isNil:
    onKeybindingsText(read.text)
  mainWindow.webContents.send(cstring(KeybindingsMessage), js{
    path: cstring(path),
    exists: read.ok,
    text: cstring(read.text),
    notes: importNotes.mapIt(cstring(it))})

proc startKeybindings*() =
  ## At window creation: import once, send, and watch the file.
  let path = keybindingsPath()
  importNotes = importOldConfigsOnce(path)
  for note in importNotes:
    infoPrint "keybindings: ", note
  sendKeybindings()
  if watching != path:
    watching = path
    try:
      fs.watchFile(cstring(path), js{interval: WatchIntervalMs,
                                     persistent: false}) do (curr: js, prev: js):
        importNotes = @[]
        # The file is every client's (`ct host` serves several), though the
        # watch began while one client was being served.
        forEveryClient(proc() = sendKeybindings())
    except CatchableError:
      warnPrint "keybindings: cannot watch ", path, ": ", getCurrentExceptionMsg()

proc onKeybindingsImport*(sender: js, response: js) {.async.} =
  ## The renderer's stepping preset (`localStorage`), merged into the file
  ## once. The renderer remembers that it asked; the merged file arrives back
  ## through the watch.
  let preset = $cast[cstring](response[cstring"preset"])
  let replace = not response[cstring"replace"].isUndefined and
                cast[bool](response[cstring"replace"])
  let path = keybindingsPath()
  let current = readIfExists(path)
  let next =
    if replace:
      # The shortcuts dialog's choice: THE stepping preset becomes this one.
      withSteppingPreset(current.text, preset)
    else:
      # The one-time import of what `localStorage` held.
      let imp = importStepPreset(preset)
      if imp.rows.len == 0: return
      withImported(current.text, imp)
  let failure = writeText(path, next)
  if failure.len > 0:
    warnPrint "keybindings: the stepping preset could not be written: ", failure
  else:
    infoPrint "keybindings: stepping preset ", preset
    sendKeybindings()

proc onKeybindingsRequest*(sender: js, response: js) {.async.} =
  ## The renderer's router asks for the file when it is installed (it may
  ## have missed the start-up send).
  sendKeybindings()
