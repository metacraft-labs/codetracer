## The keyboard-shortcuts dialog: what is bound right now, and how to change it.
##
## ## IT LISTS WHAT THE ROUTER RUNS, NOT THE PRESET
##
## Every chord below comes from the `ChordOf` the caller passes —
## `key_router.chordForAction`, the chord the ONE key router RUNS the action
## with (the base keymap, the user's `keybindings.json` over it, a chosen
## preset's `include` set among its rows). It is NOT read from the preset
## table.
##
## That distinction is the whole value of the dialog: a preset chord a user's
## own row removed, or that a row of theirs shadows, shows up as what it is —
## absent, or the user's chord — and what did not load is listed under it
## (`notes`). The dialog cannot flatter the preset.
##
## ## WHY A NODE TREE AND NOT AN HTML STRING
##
## `src/frontend/tests/htmlSinks.test.mjs` pins the renderer's ENTIRE
## `innerHTML` population — every write, each one triaged — so that a new one
## is a red run. This dialog carries a chord, an action name and a hazard
## sentence, all of which are constants today; "it is a literal today" is
## precisely the reasoning that arm S of that file caught missing four real
## sinks. So there is no markup here at all.
##
## `DialogNode` is a plain value: `buildShortcutDialog` produces one and is
## pure and fully testable, and `mountShortcutDialog` walks it with
## `createElement` / `setAttribute` / `textContent`. The mounter has no
## per-row logic — it cannot disagree with the tree — so asserting the tree
## asserts what a user sees.

import std/[strutils, options]

import ../types
import ./shortcut_labels
import ./shortcut_presets

type
  DialogNode* = object
    ## One element of the dialog, as a value.
    tag*: string
    attrs*: seq[(string, string)]
    text*: string
    children*: seq[DialogNode]

  ShortcutDialogRow* = object
    ## One binding, as the dialog states it.
    action*: ClientAction
    label*: string
      ## What the command is called, in the words the toolbar uses.
    chord*: string
      ## The chord as a user reads it — `describeChord` applied to the chord
      ## the CONFIG carries, so it is `Cmd` on a Mac and `Ctrl` elsewhere.
    hazard*: ChordHazard

const PresetActionLabels: array[9, tuple[action: ClientAction; label: string]] = [
  (ClientAction.forwardContinue, "Continue"),
  (ClientAction.reverseContinue, "Reverse continue"),
  (ClientAction.forwardNext, "Step over"),
  (ClientAction.reverseNext, "Step over, backwards"),
  (ClientAction.forwardStep, "Step into"),
  (ClientAction.reverseStep, "Step into, backwards"),
  (ClientAction.forwardStepOut, "Step out"),
  (ClientAction.reverseStepOut, "Step out, backwards"),
  (ClientAction.stop, "Stop"),
]
  ## The reading name of each governed command.
  ##
  ## `$action` would give `forwardStepOut`, which is an identifier and not a
  ## name. These are the toolbar's own words, and the order is the toolbar's
  ## paint order with each reverse move beside its forward one.

proc labelFor*(action: ClientAction): string =
  for entry in PresetActionLabels:
    if entry.action == action:
      return entry.label
  $action

type ChordOf = proc(action: ClientAction): string
  ## The chord that runs an action where the focus is — on the desktop,
  ## `ui/key_router.chordForAction` (PLAT-68: the router's, not the YAML's).

proc shortcutDialogRows*(chordOf: ChordOf; mac: bool): seq[ShortcutDialogRow] =
  ## The bindings in force, in reading order.
  ##
  ## An action with NO chord produces NO ROW. That is what makes the `None`
  ## preset's dialog honest, and it is also what would expose a chord the
  ## user's `keybindings.json` removed — the row would simply be missing,
  ## rather than present and lying.
  for entry in PresetActionLabels:
    let chord = chordOf(entry.action)
    if chord.len == 0:
      continue
    result.add ShortcutDialogRow(
      action: entry.action,
      label: entry.label,
      chord: describeChord(chord, mac),
      hazard: hazardOf(chord, mac))

proc buildShortcutDialog*(chordOf: ChordOf; active: ShortcutPresetId;
                          mac: bool; notes: seq[string] = @[]): DialogNode =
  ## The whole dialog, as a value.
  ##
  ## `data-kb-rows` DECLARES THE COUNT IT DREW, and it is `$rows.len` rather
  ## than a constant on purpose: all three binding presets hold nine moves, so
  ## a mutation replacing the expression with the literal `"9"` is invisible to
  ## any test that only looks at a preset. `shortcut_dialog_test.nim` builds a
  ## config whose count is not nine for exactly that reason.
  let rows = shortcutDialogRows(chordOf, mac)

  var table = DialogNode(tag: "div", attrs: @[("class", "kb-rows"),
                                              ("data-kb-rows", $rows.len)])
  for row in rows:
    var cells = @[
      DialogNode(tag: "span", attrs: @[("class", "kb-label")],
                 text: row.label),
      DialogNode(tag: "kbd", attrs: @[("class", "kb-chord")], text: row.chord),
    ]
    var attrs = @[("class", "kb-row"), ("data-kb-action", $row.action)]
    if row.hazard != chNone:
      attrs.add ("data-kb-hazard", hazardMarker(row.hazard))
      cells.add DialogNode(tag: "span", attrs: @[("class", "kb-hazard")],
                           text: hazardText(row.hazard))
    table.children.add DialogNode(tag: "div", attrs: attrs, children: cells)

  if rows.len == 0:
    # A SENTENCE, NEVER AN EMPTY TABLE. `None` is a choice a user can make, and
    # an empty table reads as a dialog that failed to load — the one thing a
    # settings surface must not look like.
    table = DialogNode(tag: "div", attrs: @[("class", "kb-empty")],
      text: "No stepping shortcuts are bound. " &
            "The toolbar buttons still work.")

  var picker = DialogNode(tag: "div", attrs: @[("class", "kb-presets"),
                                               ("data-kb-active", $active)])
  for id in ShortcutPresetId:
    var attrs = @[("class", "kb-preset"), ("data-kb-preset", $id)]
    if id == active:
      attrs.add ("data-kb-selected", "true")
    picker.children.add DialogNode(tag: "button", attrs: attrs, children: @[
      DialogNode(tag: "span", attrs: @[("class", "kb-preset-name")],
                 text: presetName(id)),
      DialogNode(tag: "span", attrs: @[("class", "kb-preset-why")],
                 text: presetWhy(id)),
    ])

  DialogNode(
    tag: "div",
    attrs: @[("class", "kb-dialog"), ("role", "dialog"),
             ("aria-modal", "true"), ("aria-label", "Keyboard shortcuts")],
    children: @[
      DialogNode(tag: "h2", attrs: @[("class", "kb-title")],
                 text: "Keyboard shortcuts"),
      table,
      picker,
      # PLAT-68: what the last `keybindings.json` load said — a row that did
      # not load, a base row a user row shadows — never silent.
      DialogNode(tag: "div", attrs: @[("class", "kb-notes"),
                                      ("data-kb-notes", $notes.len)],
                 children: (block:
                   var lines: seq[DialogNode] = @[]
                   for n in notes:
                     lines.add DialogNode(tag: "div",
                                          attrs: @[("class", "kb-note")],
                                          text: n)
                   lines)),
      DialogNode(tag: "button",
                 attrs: @[("class", "kb-close"), ("data-kb-close", "true")],
                 text: "Close"),
    ])

when defined(js):
  import std/dom

  proc mountShortcutDialog*(node: DialogNode): dom.Element =
    ## The tree as DOM.
    ##
    ## Deliberately generic: it walks `DialogNode` and knows nothing about
    ## chords, presets or hazards, so it cannot disagree with the tree that
    ## `buildShortcutDialog` produced and the tests assert. `textContent` and
    ## `setAttribute` only — no markup enters the document here, which is what
    ## keeps `htmlSinks.test.mjs`'s pinned `innerHTML` population unchanged.
    result = dom.document.createElement(cstring(node.tag))
    for (name, value) in node.attrs:
      result.setAttribute(cstring(name), cstring(value))
    if node.text.len > 0:
      result.textContent = cstring(node.text)
    for child in node.children:
      result.appendChild(mountShortcutDialog(child))
