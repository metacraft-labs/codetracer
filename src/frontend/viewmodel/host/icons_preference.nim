## host/icons_preference.nim — PLAT-48 deliverable 4: THE `icons` SETTING,
## REMEMBERED.
##
## The debugger controls' rendering (`nerd` / `graphics` / `unicode` /
## `text`, `viewmodels/transport_icons`) is the user's choice once they have
## made it, so it is persisted beside the keymap preference
## (`keymap_preference.nim`, the same native state root, the same staged
## write) and read back at start-up by the terminal and the GPUI window. An
## ABSENT file means "not chosen", and the front-end then picks the default
## (`defaultIconsMode`); an unreadable or unknown value is REFUSED by name —
## never silently replaced — and the default is used.
##
## Native only (it touches files), like every module in this directory.

import std/[os, strutils]

import ../viewmodels/transport_icons
import ./native_state

export transport_icons

type
  IconsPreferenceStatus* = enum
    iplAbsent = "absent"
    iplLoaded = "loaded"
    iplRefused = "refused"

  IconsPreferenceLoad* = object
    status*: IconsPreferenceStatus
    mode*: IconsMode
    path*: string
    message*: string

const IconsPreferenceFileName* = "icons"

proc iconsPreferencePath*(): string =
  nativeStateRoot() / IconsPreferenceFileName

proc decodeIconsPreference*(text: string): tuple[ok: bool, mode: IconsMode,
                                                  refusal: string] =
  let value = text.strip
  let (ok, mode) = parseIconsMode(value)
  if ok:
    return (true, mode, "")
  (false, imUnicode, "unknown stored icons value '" & value &
    "'; the accepted values are " & iconsModeNames())

proc loadIconsPreference*(): IconsPreferenceLoad =
  let path = iconsPreferencePath()
  result = IconsPreferenceLoad(status: iplAbsent, mode: imUnicode, path: path)
  if not fileExists(path):
    return
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    result.status = iplRefused
    result.message = "the stored icons setting could not be read: " & path &
                     ": " & e.msg
    return
  let decoded = decodeIconsPreference(text)
  if decoded.ok:
    result.status = iplLoaded
    result.mode = decoded.mode
  else:
    result.status = iplRefused
    result.message = decoded.refusal & " (in " & path & ")"

proc saveIconsPreference*(mode: IconsMode): string =
  ## "" on success, else why it could not be saved.
  let failure = writeStaged(iconsPreferencePath(), $mode & "\n")
  if failure.len == 0: "" else: "the icons setting could not be saved: " &
                                  failure
