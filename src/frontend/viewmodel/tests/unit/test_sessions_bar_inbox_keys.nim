## The sessions bar's inbox keys: `Alt+]` steps to the next inbox item and
## `Alt+[` to the previous one from anywhere in the window, under every base
## keymap, and the Inbox panel keeps its own unmodified `]` / `[`.
##
## * **The rows**: both chords are rows of the window's (global) table in every
##   base, and the words the bar's tooltips use (`InboxNextChord`,
##   `InboxPreviousChord`) are exactly the keys bound, so a tooltip cannot name
##   a key that does something else.
## * **Every scope**: the window alone, every pane kind the layout has (and a
##   row of each list pane), every scope that is not a pane (the Inbox panel,
##   a story's playback bar, the composer, ...), the editor read-only and
##   writable (in both editing modes under the modal bases), and a text
##   field; in both product modes and under every front-end.
## * **macOS text fields**: Option and a bracket type a character there, so in
##   a desktop, web or GPUI text field on macOS the chord resolves to nothing
##   and reaches the field; outside a text field, and in a terminal, it still
##   steps the inbox.
## * **The keys reach the router** from each device's decoder: the terminal's
##   Kitty (`CSI 93;3u` / `CSI 91;3u`) and modifyOtherKeys
##   (`CSI 27;3;93~` / `CSI 27;3;91~`) forms (`key_names.keyName`), GPUI's
##   keystroke, and the desktop's `KeyboardEvent` by its physical key (`code`
##   `BracketRight` / `BracketLeft`), whatever character the layout makes of
##   it. The classic encoding's `ESC [` is no key at all: that is why a
##   legacy terminal reports the chords unavailable
##   (`inboxChordsAvailable`, covered by `test_sessions_bar_inbox_group`).
##
## No mocks: the four shipped bases, the shared router and the shared
## decoders.

import std/[strutils, unittest]
import ../../keymap/[base_keymaps, base_rows, context_keys, editing_keymap,
                     keymap_router, overlay_rows, scope_path]
import ../../editor/editor_state
import ../../viewmodels/product_mode
import ../../views/agent_harbor_sessions_bar_words
import ../../../gpui/app/gpui_keys
import ../../../../common/key_names
import ../../../../common/key_event_names

const
  NextOperation = "inbox.next"
  PreviousOperation = "inbox.previous"

type Situation = object
  name: string
  path: ScopePath
  facts: SessionFacts
  textField: bool
    ## The focused element accepts text (`textInputFocus`).

proc delivery(frontEnd: FrontEndKind; platform: PlatformKind): KeyDelivery =
  ## Kitty in the terminal, so every chord can be typed there.
  KeyDelivery(frontEnd: frontEnd, platform: platform, keyProtocol: kpKitty)

proc resolve(base: BaseKeymap; d: KeyDelivery; s: Situation;
             key: string): string =
  ## The operation `key` resolves to, or "" when it resolves to none.
  var r = initKeymapRouter(base, d)
  let res = r.route(s.facts, s.path, nmNormal, key, 0)
  if res.kind == erOperation: res.operation else: ""

let window = element(ekWindow, "window")

proc situations(base: BaseKeymap): seq[Situation] =
  ## Every scope path the window can be in, in both product modes.
  let modal = base in {bkVim, bkKakoune}
  for product in [pmDebug, pmEdit]:
    let plain = SessionFacts(product: product, modalBase: modal,
                             editor: EditorFacts(readOnly: true))
    let tag = " (" & $product & ")"
    result.add Situation(name: "window" & tag, path: @[window], facts: plain)
    for kind in PaneKinds:
      result.add Situation(name: "pane " & kind & tag,
                           path: @[window, pane(kind)], facts: plain)
      result.add Situation(name: "a row of " & kind & tag,
                           path: @[window, pane(kind), element(ekRow, "row")],
                           facts: plain)
    for scope in NonPaneScopes:
      result.add Situation(name: "scope " & scope & tag,
                           path: @[window, pane(scope)], facts: plain)
    let editorPath = @[window, pane("editor"), element(ekEditor, "editor")]
    result.add Situation(name: "read-only editor" & tag, path: editorPath,
                         facts: plain)
    for mode in [emNormal, emInsert]:
      let writable = SessionFacts(product: product, modalBase: modal,
                                  editor: EditorFacts(readOnly: false, mode: mode))
      result.add Situation(name: "writable editor, " & $mode & tag,
                           path: editorPath, facts: writable,
                           textField: not modal or mode == emInsert)
    for scope in ["search", "scratchpad"]:
      result.add Situation(name: "a text field in " & scope & tag,
                           path: @[window, pane(scope), element(ekInput, "field")],
                           facts: plain, textField: true)
    result.add Situation(name: "the composer's field" & tag,
                         path: @[window, pane(ComposerScope),
                                 element(ekInput, "composer")],
                         facts: plain, textField: true)

suite "the rows":
  test "both chords are rows of the window's table in every base":
    for base in BaseKeymap:
      var next, previous = 0
      for b in keymapOf(base).keymap.rows:
        if b.operation == NextOperation and b.table == GlobalTable:
          check b.spelling == InboxNextChord
          inc next
        if b.operation == PreviousOperation and b.table == GlobalTable:
          check b.spelling == InboxPreviousChord
          inc previous
      checkpoint($base)
      check next == 1
      check previous == 1

  test "the Inbox panel keeps its own unmodified brackets":
    var seen = 0
    for row in OverlayRows:
      if row.table == InboxTable and row.operation == NextOperation:
        check row.chords == "]"
        inc seen
      if row.table == InboxTable and row.operation == PreviousOperation:
        check row.chords == "["
        inc seen
    check seen == 2

suite "every scope, every base, every front-end":
  test "Alt+] and Alt+[ step the inbox wherever the focus is":
    var probed = 0
    for base in BaseKeymap:
      for s in situations(base):
        for frontEnd in FrontEndKind:
          for platform in [pkLinux, pkWindows]:
            let d = delivery(frontEnd, platform)
            let next = resolve(base, d, s, InboxNextChord)
            let previous = resolve(base, d, s, InboxPreviousChord)
            if next != NextOperation or previous != PreviousOperation:
              checkpoint($base & " / " & $frontEnd & " / " & $platform & " / " &
                         s.name & ": " & next & ", " & previous)
            check next == NextOperation
            check previous == PreviousOperation
            inc probed
    # Four bases, two product modes, 35+ situations each, four front-ends,
    # two platforms: a sweep that silently built no situations reads 0.
    check probed > 4 * 2 * 30 * 4 * 2

  test "] and [ still step the inbox in the Inbox panel's scope":
    let inbox = Situation(name: "inbox", path: @[window, pane(InboxPanelScope)],
                          facts: SessionFacts(product: pmDebug))
    for base in BaseKeymap:
      let d = delivery(feTerminal, pkLinux)
      checkpoint($base)
      check resolve(base, d, inbox, "]") == NextOperation
      check resolve(base, d, inbox, "[") == PreviousOperation

  test "a story's playback bar keeps the plain brackets":
    let bar = Situation(name: "playback", path: @[window, pane(StoryPlaybackScope)],
                        facts: SessionFacts(product: pmDebug))
    for base in BaseKeymap:
      let d = delivery(feTerminal, pkLinux)
      check resolve(base, d, bar, "]") == "story-playback.next"
      check resolve(base, d, bar, InboxNextChord) == NextOperation

suite "macOS text fields keep Option and a bracket":
  test "a desktop, web or GPUI text field on macOS receives the chord":
    var fields = 0
    for base in BaseKeymap:
      for s in situations(base):
        for frontEnd in FrontEndKind:
          let d = delivery(frontEnd, pkMac)
          let next = resolve(base, d, s, InboxNextChord)
          let previous = resolve(base, d, s, InboxPreviousChord)
          let toField = s.textField and frontEnd != feTerminal
          if toField: inc fields
          checkpoint($base & " / " & $frontEnd & " / " & s.name)
          if toField:
            check next == ""
            check previous == ""
          else:
            check next == NextOperation
            check previous == PreviousOperation
    check fields > 0

suite "the keys reach the router from each device's decoder":
  test "the terminal reads the Kitty and modifyOtherKeys forms":
    check keyName("\e[93;3u") == InboxNextChord
    check keyName("\e[91;3u") == InboxPreviousChord
    check keyName("\e[27;3;93~") == InboxNextChord
    check keyName("\e[27;3;91~") == InboxPreviousChord

  test "the classic encoding's ESC [ is no key":
    check keyName("\e[") == ""
    check not legacyEncodable(InboxPreviousChord)

  test "GPUI's keystroke decoder spells the same chords":
    check canonicalKeyOfGpui("]", ["alt"]) == InboxNextChord
    check canonicalKeyOfGpui("[", ["alt"]) == InboxPreviousChord

  test "the desktop matches the physical key, whatever the layout types":
    # Linux and Windows: the key is the bracket itself.
    check canonicalKeyOfDom("]", "BracketRight", false, false, true, false) ==
      InboxNextChord
    check canonicalKeyOfDom("[", "BracketLeft", false, false, true, false) ==
      InboxPreviousChord
    # macOS, US layout: Option turns the key into a quotation mark.
    check canonicalKeyOfDom("\xE2\x80\x98", "BracketRight", false, false, true,
                            false) == InboxNextChord
    check canonicalKeyOfDom("\xE2\x80\x9C", "BracketLeft", false, false, true,
                            false) == InboxPreviousChord
