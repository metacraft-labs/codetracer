## binding_sets.nim — the named BINDING SETS a user's `keybindings.json`
## may `include`.
##
## Owns: Base-Keymaps-And-Layer-Stack.md §3.4's `include` — the desktop's
## stepping presets (`codetracer`, `vscode`, `chorded`, `none`,
## Keyboard-Shortcuts-System.md § Shortcut presets) as sets of user rows in
## `keybindings.json`'s own shape, so a preset is not a second selector beside
## the base: it is rows a user includes, layered like any of their own.
##
## Refuses to own: the base's rows (`cua_keymap`) and how a row loads
## (`user_keymap`).
##
## CUA's own stepping rows ARE the `codetracer` set (CUA-Keymap.md §4), so
## including it changes nothing; every other set first REMOVES those rows
## (`-command`, VS Code's removal) and then binds its own — the desktop
## preset replaced the nine actions' chords, and so does its set.
##
## **NOTHING HERE BUT DATA** (§8 item 3).

type
  SetRow* = object
    key*: string
    command*: string
      ## `-<name>` removes the base row with this key and command.
    whenText*: string

  BindingSet* = object
    name*: string
    rows*: seq[SetRow]

const
  SteppingRemovals = @[
    SetRow(key: "F8", command: "-debugger.continue"),
    SetRow(key: "F2", command: "-debugger.continue"),
    SetRow(key: "F5", command: "-debugger.continue"),
    SetRow(key: "Shift+F8", command: "-debugger.reverse-continue"),
    SetRow(key: "F10", command: "-debugger.step-over"),
    SetRow(key: "Shift+F10", command: "-debugger.reverse-step-over"),
    SetRow(key: "F11", command: "-debugger.step-into"),
    SetRow(key: "Shift+F11", command: "-debugger.reverse-step-into"),
    SetRow(key: "F12", command: "-debugger.step-out"),
    SetRow(key: "Shift+F12", command: "-debugger.reverse-step-out"),
    SetRow(key: "Shift+F5", command: "-debugger.stop"),
  ]
    ## CUA's stepping chords — the `codetracer` set plus VS Code's `F5`.

  D = "productMode == debug"

  BindingSets*: seq[BindingSet] = @[
    BindingSet(name: "stepping:codetracer", rows: @[]),
    BindingSet(name: "stepping:vscode", rows: @[
      # VS Code keeps F5 / F10 / Shift+F10 / F11 / Shift+F5; it moves the
      # reverse moves to Alt and step-out to Shift+F11.
      SetRow(key: "F8", command: "-debugger.continue"),
      SetRow(key: "F2", command: "-debugger.continue"),
      SetRow(key: "Shift+F8", command: "-debugger.reverse-continue"),
      SetRow(key: "Shift+F11", command: "-debugger.reverse-step-into"),
      SetRow(key: "F12", command: "-debugger.step-out"),
      SetRow(key: "Shift+F12", command: "-debugger.reverse-step-out"),
      SetRow(key: "Alt+F5", command: "debugger.reverse-continue", whenText: D),
      SetRow(key: "Alt+F11", command: "debugger.reverse-step-into", whenText: D),
      SetRow(key: "Shift+F11", command: "debugger.step-out", whenText: D),
      SetRow(key: "Alt+Shift+F11", command: "debugger.reverse-step-out", whenText: D),
    ]),
    BindingSet(name: "stepping:chorded", rows: SteppingRemovals & @[
      SetRow(key: "Ctrl+Alt+G", command: "debugger.continue", whenText: D),
      SetRow(key: "Ctrl+Alt+Shift+G", command: "debugger.reverse-continue", whenText: D),
      SetRow(key: "Ctrl+Alt+O", command: "debugger.step-over", whenText: D),
      SetRow(key: "Ctrl+Alt+Shift+O", command: "debugger.reverse-step-over", whenText: D),
      SetRow(key: "Ctrl+Alt+S", command: "debugger.step-into", whenText: D),
      SetRow(key: "Ctrl+Alt+Shift+S", command: "debugger.reverse-step-into", whenText: D),
      SetRow(key: "Ctrl+Alt+T", command: "debugger.step-out", whenText: D),
      SetRow(key: "Ctrl+Alt+Shift+T", command: "debugger.reverse-step-out", whenText: D),
      SetRow(key: "Ctrl+Alt+X", command: "debugger.stop", whenText: D),
    ]),
    BindingSet(name: "stepping:none", rows: SteppingRemovals),
  ]

func bindingSetIndex*(name: string): int =
  for i, s in BindingSets:
    if s.name == name: return i
  -1
