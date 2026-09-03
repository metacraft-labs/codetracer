## The dialog states the bindings in force, and the preference resolves.
##
## LANE: `frontend-js` (listed in `ci/lib/test-lane-files.sh`).
##
## Compile and run:
##   nim js -r src/frontend/tests/shortcut_dialog_test.nim
##
## ## The two failures this file is written against
##
## 1. A DIALOG THAT FLATTERS THE PRESET. The interesting bug is a dialog built
##    from the preset table rather than from the config: it prints the chord
##    the preset asked for, including when `initShortcutMap` dropped that chord
##    as a first-writer-wins loser and the action ended up bound to nothing.
##    So every assertion below goes through a real `defaultRendererConfig(...)`
##    and asks what the CONFIG says, which is what `configureShortcuts` binds.
##
## 2. A RENDERER THAT IGNORES ITS ARGUMENT. "The dialog lists the bindings" is
##    satisfied perfectly by a renderer that always draws the same nine rows.
##    So every claim here has a negative: a different preset must draw
##    different chords, and `None` must draw none.
##
## The count assertion has its own trap and its own answer. All three binding
## presets hold exactly nine moves, so `$rows.len` and the literal `"9"` render
## identically and a mutation swapping one for the other survives any test that
## only looks at a preset. The `None` preset and a hand-built partial config are
## what make the count discriminating.

import std/[strutils, unittest, options, sets, jsffi]

import ../config
import ../types
import ../lib/jslib
import ../ui/shortcut_dialog
import ../ui/shortcut_preference
from ../ui/shortcut_labels import renderChord

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 809

const boundPresets = [spCodeTracer, spVsCode, spChorded]

proc walk(node: DialogNode; visit: proc(n: DialogNode)) =
  visit(node)
  for child in node.children:
    walk(child, visit)

proc nodesWithAttr(node: DialogNode; name: string): seq[DialogNode] =
  var acc: seq[DialogNode] = @[]
  walk(node, proc(n: DialogNode) =
    for (attr, _) in n.attrs:
      if attr == name:
        acc.add n)
  acc

proc attrValue(node: DialogNode; name: string): string =
  for (attr, value) in node.attrs:
    if attr == name:
      return value
  ""

proc attrValues(node: DialogNode; name: string): seq[string] =
  for found in nodesWithAttr(node, name):
    result.add found.attrValue(name)

proc allText(node: DialogNode): string =
  var acc = ""
  walk(node, proc(n: DialogNode) =
    if n.text.len > 0:
      acc.add n.text & "\n")
  acc

suite "the keyboard shortcuts dialog":

  test "the dialog lists EXACTLY the bindings, and declares the count it drew":
    for id in boundPresets:
      let config = defaultRendererConfig(id)
      let dialog = buildShortcutDialog(config, id, mac = false)
      let rows = nodesWithAttr(dialog, "data-kb-action")
      counted rows.len == PresetActions.len
      counted attrValue(nodesWithAttr(dialog, "data-kb-rows")[0],
                        "data-kb-rows") == $rows.len
      # And each row names its action and spells the chord the CONFIG carries.
      for action in PresetActions:
        let matching = block:
          var acc: seq[DialogNode] = @[]
          for row in rows:
            if row.attrValue("data-kb-action") == $action:
              acc.add row
          acc
        checkpoint($id & " row for " & $action)
        counted matching.len == 1
        var chordText = ""
        for cell in matching[0].children:
          if cell.tag == "kbd":
            chordText = cell.text
        counted chordText == describeChord(renderChord(action, config),
                                           mac = false)
        counted chordText.len > 0

  test "the count is DECLARED, not assumed — a config with fewer rows says so":
    ## THE MUTATION THIS EXISTS FOR. All three presets bind nine moves, so
    ## `$rows.len` and `"9"` are the same string for every preset. `None` binds
    ## none, and a partial config binds some, and only those distinguish them.
    let empty = defaultRendererConfig(spNone)
    let emptyDialog = buildShortcutDialog(empty, spNone, mac = false)
    counted nodesWithAttr(emptyDialog, "data-kb-action").len == 0
    counted nodesWithAttr(emptyDialog, "data-kb-rows").len == 0

    # A config that binds SOME of the family. Built by unbinding four of the
    # nine by hand, so the row count is five — a number no preset produces.
    var partialBindings = JsAssoc[cstring, cstring]{}
    let fullConfig = defaultRendererConfig(spCodeTracer)
    for key, value in fullConfig.bindings:
      partialBindings[key] = value
    for action in [ClientAction.reverseContinue, ClientAction.reverseNext,
                   ClientAction.reverseStep, ClientAction.reverseStepOut]:
      let key = cstring($action)
      {.emit: ["delete ", partialBindings, "[", key, "];"].}
    var partial = defaultRendererConfig(spCodeTracer)
    partial.bindings = partialBindings
    partial.shortcutMap = initShortcutMap(partialBindings)

    let partialDialog = buildShortcutDialog(partial, spCodeTracer, mac = false)
    let partialRows = nodesWithAttr(partialDialog, "data-kb-action")
    counted partialRows.len == 5
    counted attrValue(nodesWithAttr(partialDialog, "data-kb-rows")[0],
                      "data-kb-rows") == "5"
    counted attrValue(nodesWithAttr(partialDialog, "data-kb-rows")[0],
                      "data-kb-rows") != "9"
    # And the rows drawn are the five still bound, not the first five of a
    # table the builder looked up for itself.
    var drawn: HashSet[string]
    for row in partialRows:
      drawn.incl row.attrValue("data-kb-action")
    for action in [ClientAction.forwardContinue, ClientAction.forwardNext,
                   ClientAction.forwardStep, ClientAction.forwardStepOut,
                   ClientAction.stop]:
      counted $action in drawn
    for action in [ClientAction.reverseContinue, ClientAction.reverseNext,
                   ClientAction.reverseStep, ClientAction.reverseStepOut]:
      counted $action notin drawn

  test "a DIFFERENT preset draws DIFFERENT chords under the same labels":
    ## The negative that a renderer ignoring its config would fail.
    var rendered: seq[string] = @[]
    for id in boundPresets:
      let dialog = buildShortcutDialog(defaultRendererConfig(id), id,
                                       mac = false)
      var chords: seq[string] = @[]
      walk(dialog, proc(n: DialogNode) =
        if n.tag == "kbd":
          chords.add n.text)
      counted chords.len == PresetActions.len
      rendered.add chords.join(",")
      # The LABELS are the same across presets; only the chords move.
      counted "Step over" in allText(dialog)
      counted "Reverse continue" in allText(dialog)
    counted rendered.len == boundPresets.len
    counted rendered.toHashSet.len == boundPresets.len

  test "the empty preset renders a sentence, never an empty table":
    ## `None` is a choice a user can make. An empty table reads as a dialog
    ## that failed to load, which is the one thing a settings surface must not
    ## look like.
    let dialog = buildShortcutDialog(defaultRendererConfig(spNone), spNone,
                                     mac = false)
    counted nodesWithAttr(dialog, "data-kb-action").len == 0
    let text = allText(dialog)
    counted "No stepping shortcuts are bound" in text
    counted "toolbar buttons still work" in text
    # It still offers every preset, so the choice is reversible from inside it.
    let offered = dialog.attrValues("data-kb-preset").toHashSet
    counted offered.len == 4
    for id in ShortcutPresetId:
      counted $id in offered

  test "the dialog marks which preset is active, and exactly one":
    for id in ShortcutPresetId:
      let dialog = buildShortcutDialog(defaultRendererConfig(id), id,
                                       mac = false)
      let selected = nodesWithAttr(dialog, "data-kb-selected")
      counted selected.len == 1
      counted selected[0].attrValue("data-kb-preset") == $id
      counted attrValue(nodesWithAttr(dialog, "data-kb-active")[0],
                        "data-kb-active") == $id
      # Every preset is offered with the sentence saying who it is for.
      counted presetWhy(id) in allText(dialog)

  test "hazards are drawn exactly where `hazardOf` finds one":
    ## Counted against the function rather than a number, on both platforms and
    ## every preset — so a builder that dropped the hazard, or printed it on
    ## every row, fails.
    for id in boundPresets:
      let config = defaultRendererConfig(id)
      for mac in [false, true]:
        var expected = 0
        for action in PresetActions:
          let chord = renderChord(action, config)
          if chord.len > 0 and hazardOf(chord, mac) != chNone:
            inc expected
        let dialog = buildShortcutDialog(config, id, mac)
        checkpoint($id & " mac=" & $mac & " expecting " & $expected)
        counted nodesWithAttr(dialog, "data-kb-hazard").len == expected

  test "the same preset draws a DIFFERENT dialog on a Mac":
    ## `hazardOf` is a function of the chord and the platform, never a field.
    ## The proof that this is real is that one preset yields two dialogs.
    let config = defaultRendererConfig(spCodeTracer)
    let onMac = buildShortcutDialog(config, spCodeTracer, mac = true)
    let notMac = buildShortcutDialog(config, spCodeTracer, mac = false)
    counted allText(onMac) != allText(notMac)
    counted nodesWithAttr(onMac, "data-kb-hazard").len >
            nodesWithAttr(notMac, "data-kb-hazard").len
    # The browser-reserved count does NOT move between platforms: F11 and F12
    # are taken above the page everywhere.
    var reservedOnMac = 0
    var reservedOffMac = 0
    for n in nodesWithAttr(onMac, "data-kb-hazard"):
      if n.attrValue("data-kb-hazard") == "reserved": inc reservedOnMac
    for n in nodesWithAttr(notMac, "data-kb-hazard"):
      if n.attrValue("data-kb-hazard") == "reserved": inc reservedOffMac
    counted reservedOnMac == reservedOffMac
    counted reservedOnMac > 0

  test "the browser-safe preset draws no hazard at all, on either platform":
    for mac in [false, true]:
      let dialog = buildShortcutDialog(defaultRendererConfig(spChorded),
                                       spChorded, mac)
      counted nodesWithAttr(dialog, "data-kb-hazard").len == 0
    # THE NEGATIVE: the same code path DOES draw hazards for another preset.
    counted nodesWithAttr(
      buildShortcutDialog(defaultRendererConfig(spCodeTracer), spCodeTracer,
                          mac = true), "data-kb-hazard").len > 0

  test "a Mac reads Cmd where a PC reads Ctrl, in the chord the dialog draws":
    ## The modifier decision, asserted on the text a user actually sees rather
    ## than on `describeChord` alone.
    let config = defaultRendererConfig(spChorded)
    var macChords: seq[string] = @[]
    var pcChords: seq[string] = @[]
    walk(buildShortcutDialog(config, spChorded, mac = true),
         proc(n: DialogNode) = (if n.tag == "kbd": macChords.add n.text))
    walk(buildShortcutDialog(config, spChorded, mac = false),
         proc(n: DialogNode) = (if n.tag == "kbd": pcChords.add n.text))
    counted macChords.len == PresetActions.len
    counted pcChords.len == PresetActions.len
    for chord in macChords:
      counted chord.startsWith("Cmd+")
      counted not chord.contains("Ctrl")
    for chord in pcChords:
      counted chord.startsWith("Ctrl+")
      counted not chord.contains("Cmd")
    # And the literal, so both sides being wrong together is still caught.
    counted "Ctrl+Alt+O" in pcChords
    counted "Cmd+Option+O" in macChords

  test "the dialog carries no markup — every string is a text node":
    ## `htmlSinks.test.mjs` pins the renderer's whole `innerHTML` population.
    ## This dialog adds none, and the way that is kept true is that the builder
    ## produces text and attributes only. A `<` appearing in either would mean
    ## somebody had started assembling markup.
    for id in ShortcutPresetId:
      let dialog = buildShortcutDialog(defaultRendererConfig(id), id,
                                       mac = false)
      walk(dialog, proc(n: DialogNode) =
        counted not n.text.contains('<')
        counted not n.tag.contains('<')
        for (_, value) in n.attrs:
          counted not value.contains('<'))

suite "which preset is in force, and why":

  test "nobody has chosen — the default, reported as the default":
    let resolved = resolvePreference(account = none(string),
                                     local = none(string))
    counted resolved.id == DefaultShortcutPresetId
    counted resolved.source == psDefault

  test "an anonymous choice is this browser's, and says so":
    for id in ShortcutPresetId:
      let resolved = resolvePreference(account = none(string),
                                       local = some($id))
      counted resolved.id == id
      counted resolved.source == psLocal

  test "an account choice OUTRANKS the browser's":
    ## A signed-in user who set their keymap elsewhere should get it on a
    ## borrowed laptop, not the laptop's leftover value.
    let resolved = resolvePreference(account = some($spChorded),
                                     local = some($spVsCode))
    counted resolved.id == spChorded
    counted resolved.source == psAccount
    # THE NEGATIVE: with no account value, the same local value wins.
    let anonymous = resolvePreference(account = none(string),
                                      local = some($spVsCode))
    counted anonymous.id == spVsCode
    counted anonymous.source == psLocal

  test "an unreadable value at either tier yields the default, not an error":
    let badAccount = resolvePreference(account = some("from-a-newer-build"),
                                       local = some($spVsCode))
    counted badAccount.id == DefaultShortcutPresetId
    # REPORTED AS `psAccount`, because the user DID choose — this build simply
    # does not know the spelling. Falling through to `local` would silently
    # reinstate a choice they had replaced.
    counted badAccount.source == psAccount
    let badLocal = resolvePreference(account = none(string),
                                     local = some("nonsense"))
    counted badLocal.id == DefaultShortcutPresetId
    counted badLocal.source == psLocal
    # And "none" is a real choice at either tier, not an absence.
    counted resolvePreference(account = none(string),
                              local = some("none")).id == spNone

  test "signing up ADOPTS the anonymous choice; signing in never overwrites":
    ## The migration rule, both halves, and the third case that is neither.
    #
    # A new account with a local choice adopts it — signing up must not throw
    # away the configuration that made the user want an account.
    let adopted = migrationOnSignIn(account = none(string),
                                    local = some($spChorded))
    counted adopted.isSome
    counted adopted.get == $spChorded

    # An established account is never overwritten by a borrowed browser's
    # leftover value.
    let untouched = migrationOnSignIn(account = some($spVsCode),
                                      local = some($spChorded))
    counted untouched.isNone

    # Nothing local, nothing to write — and therefore no request at all.
    counted migrationOnSignIn(account = none(string),
                              local = none(string)).isNone
    counted migrationOnSignIn(account = some($spVsCode),
                              local = none(string)).isNone

    # An unrecognised local value is NORMALISED on the way up, never promoted
    # verbatim: a value no build understands would otherwise be delivered to
    # every device, each falling back to the default while reporting
    # `psAccount` — an account setting that does nothing and cannot be seen to
    # be doing nothing.
    let normalised = migrationOnSignIn(account = none(string),
                                       local = some("from-a-newer-build"))
    counted normalised.isSome
    counted normalised.get == $DefaultShortcutPresetId
    counted normalised.get != "from-a-newer-build"
    # `none` survives the trip, because it is a real choice.
    counted migrationOnSignIn(account = none(string),
                              local = some("none")).get == "none"

  test "the resolved preset is the one the config is actually built with":
    ## Ties the preference layer to the binding layer: whatever
    ## `resolvePreference` answers is what `defaultRendererConfig` consumes,
    ## so a user's stored choice reaches their keyboard.
    for id in boundPresets:
      let resolved = resolvePreference(account = none(string), local = some($id))
      let config = defaultRendererConfig(resolved.id)
      for b in presetOf(id).bindings:
        checkpoint($id & " " & $b.action)
        counted renderChord(b.action, config) == b.chord

  test "shortcut_dialog_assertion_count_is_measured":
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
