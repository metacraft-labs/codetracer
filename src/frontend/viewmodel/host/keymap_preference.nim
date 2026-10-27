## keymap_preference.nim — PLAT-43: the chosen keymap model, remembered.
##
## A one-line document, `<state root>/keymap`, holding a `BaseKeymap` name.
## Read at start-up by BOTH native hosts and written by the terminal when the
## user runs `:keymap <name>`. What the text MEANS is
## `keymap_selection.decodeKeymapPreference`'s — the same `selectKeymap` the
## command calls — so a stored value is accepted or refused by exactly the
## rule a typed one is.
##
## A BAD STORED VALUE IS REFUSED BY NAME, not silently replaced: the load
## reports `kplRefused` with the refusal text, the host shows it, and the
## session runs the product default. The file is left as it is — rewriting it
## would destroy the evidence of what was wrong.

import std/os

import ../keymap/keymap_selection
import ./native_state

export keymap_selection

type
  KeymapPreferenceStatus* = enum
    kplAbsent = "absent"
      ## No document: a first run. Nothing to say.
    kplLoaded = "loaded"
    kplMigrated = "migrated"
      ## PLAT-68: the document said `default`; the session runs `cua`, the
      ## document has been rewritten, and `message` is the one-time notice.
    kplRefused = "refused"
      ## A document whose content is not a model name, or that could not be
      ## read. `message` says which.

  KeymapPreferenceLoad* = object
    status*: KeymapPreferenceStatus
    model*: BaseKeymap
      ## The model this session runs: the stored one when `kplLoaded`, the
      ## product default otherwise.
    path*: string
    message*: string
    reason*: string
      ## PLAT-68: why `model` is active — `flag`, `stored` or `default`
      ## (Base-Keymaps-And-Layer-Stack.md §3.6: *"the surface must be able to
      ## say why the active value is active"*). Set by `sessionKeymap`.

const KeymapPreferenceFileName* = "keymap"

proc saveKeymapPreference*(model: BaseKeymap): string

proc keymapPreferencePath*(): string =
  nativeStateRoot() / KeymapPreferenceFileName

proc loadKeymapPreference*(): KeymapPreferenceLoad =
  let path = keymapPreferencePath()
  result = KeymapPreferenceLoad(status: kplAbsent, model: bkCua,
                                path: path, message: "")
  if not fileExists(path):
    return
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    result.status = kplRefused
    result.message = "the stored keymap could not be read: " & path & ": " & e.msg
    return
  let selection = decodeKeymapPreference(text)
  if selection.ok and selection.migrated:
    result.status = kplMigrated
    result.model = selection.model
    let failure = saveKeymapPreference(selection.model)
    result.message = RetiredDefaultNotice &
      (if failure.len == 0: "" else: " (" & failure & ")")
  elif selection.ok:
    result.status = kplLoaded
    result.model = selection.model
  else:
    result.status = kplRefused
    result.message = selection.refusal & " (in " & path & ")"

proc saveKeymapPreference*(model: BaseKeymap): string =
  ## Remember `model`. "" on success, else a one-line message naming the path.
  let failure = writeStaged(keymapPreferencePath(), encodeKeymapPreference(model))
  if failure.len == 0: "" else: "the keymap could not be saved: " & failure

proc sessionKeymap*(flag: string): KeymapPreferenceLoad =
  ## **THE BASE A SESSION STARTS UNDER**, for every native host: the
  ## `--keymap` flag (this session only, never written), else the stored
  ## preference (a stored `default` migrated to `cua`), else `cua`.
  result = loadKeymapPreference()
  result.reason = if result.status in {kplLoaded, kplMigrated}: "stored"
                  else: "default"
  if flag.len > 0:
    let selection = selectKeymap(flag, "--keymap")
    if selection.ok:
      result.model = selection.model
      result.reason = "flag"
