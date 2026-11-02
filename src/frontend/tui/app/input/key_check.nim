## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/input/key_check.nim — `:keys check` (palette: **Help: Check Key
## Delivery**), Base-Keymaps-And-Layer-Stack.md §7.3.
##
## Owns: the check's state as a value (the keys that arrived, in order) and
## the table of the usual INTERCEPTORS — the terminal emulators and
## multiplexers that take a chord before it reaches any application — with
## the report that names, for each chord the active keymap binds and that
## did not arrive, who probably took it.
##
## Refuses to own: running the check (the runtime pushes its layer and feeds
## it every key), and the keymap (the router answers which chords are bound).
##
## What the tty itself would take (`ISIG`, `IXON`, …) is not here: the driver's
## raw mode clears all of it (§7.3), so every such byte arrives.

import std/strutils

type
  KeyCheck* = object
    active*: bool
    seen*: seq[string]
      ## Canonical names, in arrival order.

  Interceptor* = object
    chord*: string
    who*: string

const
  KnownInterceptors*: seq[Interceptor] = @[
    Interceptor(chord: "F10", who: "GNOME Terminal and Konsole (menu bar)"),
    Interceptor(chord: "F11", who: "GNOME Terminal and Konsole (full screen)"),
    Interceptor(chord: "Shift+F10", who: "GNOME Terminal (context menu)"),
    Interceptor(chord: "Ctrl+Shift+t", who: "GNOME Terminal and Konsole (new tab)"),
    Interceptor(chord: "Ctrl+Shift+w", who: "GNOME Terminal and Konsole (close tab)"),
    Interceptor(chord: "Ctrl+Shift+n", who: "GNOME Terminal and Konsole (new window)"),
    Interceptor(chord: "Ctrl+Shift+q", who: "GNOME Terminal (close window)"),
    Interceptor(chord: "Ctrl+Shift+c", who: "GNOME Terminal and Konsole (copy)"),
    Interceptor(chord: "Ctrl+Shift+v", who: "GNOME Terminal and Konsole (paste)"),
    Interceptor(chord: "Ctrl+Shift+f", who: "GNOME Terminal and Konsole (find)"),
    Interceptor(chord: "Ctrl+b", who: "tmux (its default prefix)"),
    Interceptor(chord: "Ctrl+a", who: "screen (its default prefix)"),
  ]

func startCheck*(): KeyCheck = KeyCheck(active: true, seen: @[])

proc note*(c: var KeyCheck; name: string) =
  if name.len > 0: c.seen.add name

func arrivalLine*(name, resolvesTo: string): string =
  ## What the status line says as each key arrives.
  "keys check: `" & name & "` arrived — " &
    (if resolvesTo.len > 0: resolvesTo else: "bound to nothing here") &
    " (Esc ends the check)"

func report*(c: KeyCheck; bound: openArray[string]): string =
  ## The closing report: how many keys arrived, and for every chord in
  ## `bound` (the active keymap's) that a known interceptor takes and that
  ## did not arrive, who probably took it.
  var missing: seq[string] = @[]
  for i in KnownInterceptors:
    if i.chord in bound and i.chord notin c.seen:
      missing.add "`" & i.chord & "` (" & i.who & ")"
  result = "keys check: " & $c.seen.len & " key(s) arrived"
  if missing.len > 0:
    result.add "; not seen, and usually taken before the terminal " &
               "application: " & missing.join(", ")
