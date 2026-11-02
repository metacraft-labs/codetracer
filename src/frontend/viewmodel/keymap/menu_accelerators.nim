## menu_accelerators.nim — the chord a NATIVE application menu shows beside an
## item, from the router (KL-8 / IR-3), in Electron's accelerator syntax.
##
## Owns: the translation of a displayed chord (`keymap_router.chordFor`'s
## answer: `Ctrl+Shift+K`, `F10`, `Ctrl+K Ctrl+W`) into an Electron
## `accelerator` string, and the menu item's chord for a `ClientAction` —
## the chord that runs that action at the window's scope in a replay, the
## user's `keybindings.json` laid over the base.
##
## Refuses to own: building the menu (`index/menu.nim`, the macOS main
## process), reading the user's file (`index/keybindings.nim`), and which
## chord runs an operation (`keymap_router.chordFor`).
##
## ## WHAT HAS NO ACCELERATOR
##
## An accelerator is REGISTERED with the system on macOS: the menu takes the
## key before the page sees it. So a chord whose key is a printable character
## with no command modifier (`n`, `Shift+G`: CUA's letters in the read-only
## editor) is never given one — it would take that character away from every
## text field. A chord SEQUENCE (`Ctrl+K Ctrl+W`) has no Electron spelling,
## and neither has `Alt` pressed alone; both show no accelerator. The item is
## still there and still runs; only the hint is absent.
##
## Pure; compiles on C and JS.

import std/strutils

import ../../../common/key_names
import ./client_actions
import ./editing_keymap
import ./context_keys
import ./keymap_router
import ./operation_catalogue
import ./scope_path

const
  ElectronKeyNames = [
    ("Esc", "Escape"), ("Enter", "Return"), ("Tab", "Tab"),
    ("Backspace", "Backspace"), ("Delete", "Delete"), ("Insert", "Insert"),
    ("Space", "Space"), ("Home", "Home"), ("End", "End"),
    ("PageUp", "PageUp"), ("PageDown", "PageDown"), ("Up", "Up"),
    ("Down", "Down"), ("Left", "Left"), ("Right", "Right")]
    ## The canonical named keys (`key_names.NamedKeys`) as Electron's
    ## accelerator key codes
    ## (https://www.electronjs.org/docs/latest/api/accelerator). `F1`–`F12`
    ## are spelled alike; `Alt` alone has no code.

func electronKeyOf(key: string): string =
  for (ours, theirs) in ElectronKeyNames:
    if key == ours: return theirs
  if key.len >= 2 and key[0] == 'F' and key[1 .. ^1].allCharsInSet(Digits):
    return key
  if key.len == 1:
    let c = key[0]
    if c == '+': return "Plus"
    if c in {'a'..'z'}: return $chr(ord(c) - 32)
    if c in {'!'..'~'}: return $c
  ""

func electronAccelerator*(chord: string; platform: PlatformKind): string =
  ## `chord` — one displayed chord, as `chordFor` answers — as an Electron
  ## accelerator, or "" when it has none (a sequence, a bare or Shift-only
  ## printable key, `Alt` alone, nothing). `Meta` is `Cmd` on macOS (`⌘`) and
  ## `Super` elsewhere; `Ctrl` is the Control key on every platform, as the
  ## desktop's decoder reads it (`key_event_names.canonicalKeyOfDom`).
  let text = chord.strip
  if text.len == 0 or ' ' in text:
    return ""
  # The key is what follows the last modifier: `Ctrl++` ends in the key `+`.
  var parts: seq[string] = @[]
  var rest = text
  while true:
    let i = rest.find('+')
    if i <= 0 or i == rest.high:
      break
    parts.add rest[0 ..< i]
    rest = rest[i + 1 .. ^1]
  let key = rest
  var mods: seq[string] = @[]
  var command = false
  for m in parts:
    case m.toLowerAscii
    of "ctrl", "control":
      mods.add "Ctrl"; command = true
    of "alt", "option":
      mods.add "Alt"; command = true
    of "meta", "cmd", "super":
      mods.add(if platform == pkMac: "Cmd" else: "Super"); command = true
    of "shift":
      mods.add "Shift"
    else:
      return ""
  if key == "Alt":
    return ""
  let code = electronKeyOf(key)
  if code.len == 0:
    return ""
  # A printable key without Ctrl, Alt or Meta is TYPING: never registered.
  if code.len == 1 and not command:
    return ""
  # A letter is upper case in both spellings (`displayChord` writes `Ctrl+N`
  # for Ctrl and the `n` key, and spells Shift out: `Ctrl+Shift+K`).
  (mods & @[code]).join("+")

func menuFacts*(): SessionFacts =
  ## The situation a native menu's chords are shown for: a replay in Debug
  ## mode, nothing focused below the window — the global chords, as VS Code's
  ## native menu shows them.
  SessionFacts(product: pmDebug, replayLoaded: true,
               editor: EditorFacts(readOnly: true, mode: emInsert))

func menuScopePath*(): ScopePath =
  @[element(ekWindow, "window")]

proc menuChord*(router: KeymapRouter; action: string): string =
  ## The chord that runs the desktop `ClientAction` named `action` at the
  ## window's scope (`menuFacts`), the user's rows included; "" when no key
  ## reaches it there.
  let op = operationOfClientAction(action)
  if op.len == 0:
    return ""
  let (name, arg) = splitOperation(op)
  router.chordFor(name, menuFacts(), menuScopePath(), nmNormal, arg)

proc menuAccelerator*(router: KeymapRouter; action: string): string =
  ## **THE ACCELERATOR A NATIVE MENU ITEM SHOWS** for `action`: the router's
  ## chord, in Electron's syntax for the router's platform.
  electronAccelerator(router.menuChord(action), router.delivery.platform)
