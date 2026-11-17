## field_keys.nim — the one DOM decoder for what a key means ON A FOCUSED FIELD
## OR A ROVING ELEMENT that owns its keys.
##
## Owns: `FieldKey`, the closed set of things a view's field or small composite
## does with a key (commit, cancel, a move, activation), and `fieldKeyOf`, which
## reads a `KeyboardEvent`'s fields into one (Input-Routing-And-Keymaps.md §6: a
## view decodes and hands on; `ci/test/input-routing-gate.sh` declares this
## module as that decoder).
##
## Refuses to own: what the view does with the answer, and every key that is not
## the element's. The window's keys go through the router (`ui/key_router`);
## these are the keys §4.1's text-entry rule leaves to the focused element.
##
## Pure; compiles on C and JS, so the views' mock-renderer suites read it too.

type
  FieldKey* = enum
    fkNone
    fkCommit
      ## `Enter`.
    fkCommitModified
      ## `Ctrl+Enter` / `Cmd+Enter`.
    fkCancel
      ## `Escape`.
    fkNext
      ## `ArrowDown`.
    fkPrevious
      ## `ArrowUp`.
    fkLeft
      ## `ArrowLeft`.
    fkRight
      ## `ArrowRight`.
    fkComplete
      ## `Tab`.
    fkActivate
      ## `Enter` or `Space` on something that is not a text field.
    fkContextMenu
      ## The context-menu key, or `Shift+F10`.

const
  KeyDownEvent* = "keydown"
    ## The event a field's own keys arrive on.

func fieldKeyOf*(key: string; ctrl = false; shift = false; meta = false): FieldKey =
  ## A text field's reading of `KeyboardEvent.key`.
  case key
  of "Enter": (if ctrl or meta: fkCommitModified else: fkCommit)
  of "Escape", "Esc": fkCancel
  of "ArrowDown", "Down": fkNext
  of "ArrowUp", "Up": fkPrevious
  of "ArrowLeft", "Left": fkLeft
  of "ArrowRight", "Right": fkRight
  of "Tab": fkComplete
  of "ContextMenu": fkContextMenu
  of "F10": (if shift: fkContextMenu else: fkNone)
  else: fkNone

func isModifierOnly*(key: string): bool =
  ## `KeyboardEvent.key` of a key that is no key of its own.
  key in ["Shift", "Control", "Alt", "Meta", "CapsLock", "AltGraph", "Dead",
          "Unidentified", ""]

func keyCodeName(code: int): string =
  ## The legacy `keyCode`s the older views still read.
  case code
  of 13: "Enter"
  of 27: "Escape"
  of 9: "Tab"
  of 37: "ArrowLeft"
  of 38: "ArrowUp"
  of 39: "ArrowRight"
  of 40: "ArrowDown"
  else: ""

func fieldKeyOfCode*(code: int; ctrl = false; shift = false; meta = false): FieldKey =
  fieldKeyOf(keyCodeName(code), ctrl, shift, meta)

func isActivationKey*(key: string): bool =
  ## `Enter` and `Space` (`Spacebar` is the name older engines report) on a
  ## focused element that is not a field.
  key == "Enter" or key == " " or key == "Spacebar"
