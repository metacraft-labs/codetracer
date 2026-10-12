## keybindings_file.nim — WHERE the one user keymap lives on a native host,
## and the one-time import of the old configuration files into it.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §3.5's native half — reading the
## file at its location (`keybindings_location`, shared with the desktop's
## main process),
## noticing that it changed (the terminal, GPUI and Electron's main process
## poll the modification time between frames — a reload that reports errors
## keeps the rows that loaded), and the first-run import of `.cttui-keys` and
## the desktop's edited YAML `bindings:` block.
##
## Refuses to own: what the text means (`keymap/user_keymap`) and what the
## old texts translate to (`keymap/keymap_importers`).
##
## THE IMPORT RUNS ONCE. It runs only when there is no `keybindings.json`,
## and it writes one — with a comment naming each source and how much of it
## translated — even when nothing translated, so it is never run again. The
## old files are left untouched and are not read afterwards.

import std/[os, times]

import ../keymap/keymap_importers
import ../keymap/user_keymap
import ./keybindings_location
import ./native_state

export user_keymap, keymap_importers, keybindings_location

type
  KeybindingsLoad* = object
    path*: string
    exists*: bool
    stamp*: Time
      ## The file's modification time when it was read; `changedSince`
      ## compares it.
    keymap*: UserKeymap
    readError*: string


proc stampOf(path: string): Time =
  try: getLastModificationTime(path)
  except CatchableError: Time()

proc readKeybindings*(path = keybindingsPath()): KeybindingsLoad =
  ## The file, parsed. A missing file is no rows and no complaint (nobody
  ## is required to have one); one that exists and cannot be read is a
  ## `readError`.
  result = KeybindingsLoad(path: path, exists: fileExists(path))
  if not result.exists:
    return
  result.stamp = stampOf(path)
  try:
    result.keymap = parseUserKeymap(readFile(path))
  except CatchableError as e:
    result.readError = "keybindings.json could not be read: " & path & ": " &
                       e.msg

proc changedSince*(load: KeybindingsLoad): bool =
  ## Whether the file was created, removed or rewritten since `load`.
  let exists = fileExists(load.path)
  exists != load.exists or (exists and stampOf(load.path) != load.stamp)

proc importOldConfigsOnce*(old: OldConfigs;
                           path = keybindingsPath()): seq[string] =
  ## THE ONE-TIME IMPORT. When `path` does not exist and an old surface
  ## does, translate it, write `path`, and answer one summary line per
  ## source (`.cttui-keys: 7 of 8 translated…`). Nothing to do — the file
  ## exists, or there is nothing old — is an empty answer.
  result = @[]
  if fileExists(path):
    return
  var imports: seq[ConfigImport] = @[]
  for candidate in old.cttuiKeys:
    if fileExists(candidate):
      try:
        imports.add importCttuiKeys(readFile(candidate))
      except CatchableError as e:
        result.add ".cttui-keys could not be read: " & candidate & ": " & e.msg
      break
  if old.userYaml.len > 0 and fileExists(old.userYaml):
    try:
      let imp = importYamlBindings(readFile(old.userYaml), old.defaultYaml)
      if imp.total > 0: imports.add imp
    except CatchableError as e:
      result.add ".config.yaml could not be read: " & e.msg
  if imports.len == 0:
    return
  createDir(path.parentDir)
  let failure = writeStaged(path, keybindingsText(imports))
  for imp in imports:
    result.add imp.summary
  if failure.len > 0:
    result.add "keybindings.json could not be written: " & failure
