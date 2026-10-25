## host/layout_preferences.nim — PLAT-51 deliverables 9 and 11: THE LAYOUT
## PREFERENCES, REMEMBERED (`focus-highlight`, `live-resize`;
## `viewmodels/layout_settings.nim`).
##
## Beside each product's remembered layout, in the native state root
## (`native_state.nim`) — the terminal's `tui-preferences`, the GPUI window's
## `gpui-preferences` — one `name=on|off` line per setting, written staged
## (`writeStaged`). An ABSENT file is the defaults; an unreadable or unknown
## line is REFUSED by name, never silently replaced, and the defaults are used.
##
## Native only (it touches files), like every module in this directory.

import std/os

import ../viewmodels/layout_settings
import ./native_state

export layout_settings

type
  LayoutProduct* = enum
    lpTerminal = "tui"
    lpGpui = "gpui"

  LayoutPreferencesStatus* = enum
    lpsAbsent = "absent"
    lpsLoaded = "loaded"
    lpsRefused = "refused"

  LayoutPreferencesLoad* = object
    status*: LayoutPreferencesStatus
    settings*: LayoutSettings
    path*: string
    message*: string

proc layoutPreferencesPath*(product: LayoutProduct): string =
  nativeStateRoot() / ($product & "-preferences")

func productDefaults*(product: LayoutProduct): LayoutSettings =
  ## The defaults of `product`: the overflow markers are on in the terminal
  ## and off in GPUI (Horizontal-Overflow.md §4.6, OQ-H1).
  defaultLayoutSettings(overflowMarkers = product == lpTerminal)

proc loadLayoutPreferences*(product: LayoutProduct): LayoutPreferencesLoad =
  let path = layoutPreferencesPath(product)
  result = LayoutPreferencesLoad(status: lpsAbsent,
                                 settings: productDefaults(product),
                                 path: path)
  if not fileExists(path):
    return
  var text = ""
  try:
    text = readFile(path)
  except CatchableError as e:
    result.status = lpsRefused
    result.message = "the stored layout preferences could not be read: " &
                     path & ": " & e.msg
    return
  let decoded = decodeLayoutSettings(text, productDefaults(product))
  if decoded.ok:
    result.status = lpsLoaded
    result.settings = decoded.settings
  else:
    result.status = lpsRefused
    result.message = decoded.message & " (in " & path & ")"

proc saveLayoutPreference*(product: LayoutProduct; which: LayoutSetting;
                           value: string): string =
  ## Remember one setting's value word; the others keep what is stored. ""
  ## on success, else why it could not be saved.
  var current = loadLayoutPreferences(product)
  var s = if current.status == lpsLoaded: current.settings
          else: productDefaults(product)
  if not s.assignValue(which, value):
    return "'" & value & "' is not a value of " & $which
  let failure = writeStaged(layoutPreferencesPath(product),
                            encodeLayoutSettings(s))
  if failure.len == 0: ""
  else: "the " & $which & " setting could not be saved: " & failure

proc saveLayoutPreference*(product: LayoutProduct; which: LayoutSetting;
                           on: bool): string =
  ## An on / off setting remembered.
  saveLayoutPreference(product, which, if on: "on" else: "off")

proc saveScopedPreference*(product: LayoutProduct; glob: string;
                           which: LayoutSetting; value: string): string =
  ## PLAT-71 (Terminal-Adaptation §5.3, OQ-T6): remember `which = value` for
  ## the terminals `glob` matches — a `[terminal "<glob>"]` section of the
  ## same file. "" on success, else why not.
  var current = loadLayoutPreferences(product)
  if current.status == lpsRefused:
    return current.message
  var s = if current.status == lpsLoaded: current.settings
          else: productDefaults(product)
  if not s.setScoped(glob, which, value):
    return "'" & value & "' is not a value of " & $which &
           " for one terminal"
  let failure = writeStaged(layoutPreferencesPath(product),
                            encodeLayoutSettings(s))
  if failure.len == 0: ""
  else: "the " & $which & " setting could not be saved: " & failure
