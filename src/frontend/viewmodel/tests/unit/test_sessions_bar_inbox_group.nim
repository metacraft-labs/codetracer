## The sessions bar's inbox group (`agent_harbor_sessions_bar_words`): the
## bell, its count and ink, Previous and Next, the auto-switch mark, and the
## words the bell and the buttons say, read from a real `InboxVM`.
##
## Test doubles, and why each is justified: the inbox is read from
## nim-agents-isonim-viewmodels' `inboxFixture` (`synthetic_inbox`), a
## `ScriptedActionSource` holding invented items. It is the source the
## Agent Harbor stories run on; a test may not reach a real Agent Harbor
## server, and the scripted source keeps the server's own cursor rules
## (Previous needs an item visited), which are what the group reads. The
## viewmodel, the words and the key-delivery rule are the production ones.

import std/[strutils, unittest]
import isonim/core/[owner, signals, computation]
import nim_agents_isonim_viewmodels/agent_harbor/synthetic_inbox
import ../../views/agent_harbor_sessions_bar_words

proc loaded(fixture: string): InboxVM =
  result = newInboxVM(inboxFixture(fixture), cursorName = "default", showPages = false)
  result.load()

suite "the sessions bar's inbox group":
  test "an empty inbox: the bell is muted but still drawn, Next and Previous disabled":
    createRoot proc(disposeRoot: proc()) =
      let vm = loaded("empty")
      check vm.isEmpty
      let s = inboxGroupStateOf(vm)
      check s.bellShown
      check s.muted
      check not s.nextEnabled
      check not s.prevEnabled
      check s.badge == ""
      check s.badgeRole == "quiet"
      check s.blocked == 0
      check s.feedback == 0
      check bellTitle(vm, true).startsWith("No input required")
      disposeRoot()

  test "items waiting: Previous is disabled until Next, then enabled":
    createRoot proc(disposeRoot: proc()) =
      let vm = loaded("populated")
      let before = inboxGroupStateOf(vm)
      check before.bellShown
      check not before.muted
      check before.nextEnabled
      check not before.prevEnabled
      check vm.next()
      let first = inboxGroupStateOf(vm)
      check first.nextEnabled
      check not first.prevEnabled
      check vm.next()
      let second = inboxGroupStateOf(vm)
      check second.prevEnabled
      check second.nextEnabled
      disposeRoot()

  test "the badge is the inbox's count, inked by what waits":
    createRoot proc(disposeRoot: proc()) =
      let vm = loaded("populated")
      let s = inboxGroupStateOf(vm)
      check vm.count == 5
      check s.badge == $vm.count
      check s.badge == "5"
      check s.blocked == vm.blockedCount
      check s.blocked > 0
      check s.feedback == 1
      check s.badgeRole == "warning"
      disposeRoot()

  test "the group's state follows the inbox: Previous and auto-switch":
    createRoot proc(disposeRoot: proc()) =
      let vm = loaded("populated")
      var seen: seq[InboxGroupState]
      createEffect proc() =
        seen.add inboxGroupStateOf(vm)
      check seen.len == 1
      check not seen[^1].autoSwitchOn
      vm.setAutoSwitch(true)
      check seen[^1].autoSwitchOn
      discard vm.next()
      discard vm.next()
      check seen[^1].prevEnabled
      check AutoSwitchIndicatorText.len > 0
      disposeRoot()

  test "the bell names the count, the reader's place after Next, and the keys":
    createRoot proc(disposeRoot: proc()) =
      let vm = loaded("populated")
      let before = bellTitle(vm, true)
      check before.startsWith(vm.controlTitle)
      check "5 tasks need input" in before
      check "Alt+]" in before
      check "Alt+[" in before
      check "of 5" notin before
      check vm.next()
      check vm.positionText == "1 of 5"
      let after = bellTitle(vm, true)
      check vm.positionText in after
      check "1 of 5" in after
      let legacy = bellTitle(vm, false)
      check "1 of 5" in legacy
      check InboxChordsUnavailableText in legacy
      check "Alt+] next" notin legacy
      disposeRoot()

  test "Previous's and Next's tooltips name their keys, or say they are unavailable":
    check nextTitle(InboxNextChord, true) == "Next item (Alt+])"
    check prevTitle(InboxPreviousChord, true) == "Previous item (Alt+[)"
    check "unavailable" in nextTitle(InboxNextChord, false)
    check "Alt+]" in nextTitle(InboxNextChord, false)
    check "unavailable" in prevTitle(InboxPreviousChord, false)
    check nextTitle("", true) == "Next item"

  test "the keys reach a window always, a terminal only with an unambiguous protocol":
    for frontEnd in [feWeb, feDesktop, feGpui]:
      for protocol in KeyProtocol:
        check inboxChordsAvailable(KeyDelivery(frontEnd: frontEnd, platform: pkLinux,
                                               keyProtocol: protocol))
    for platform in PlatformKind:
      for protocol in KeyProtocol:
        let available = inboxChordsAvailable(KeyDelivery(frontEnd: feTerminal,
                                                         platform: platform,
                                                         keyProtocol: protocol))
        check available == (protocol in {kpKitty, kpModifyOtherKeys})
    check not inboxChordsAvailable(KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                                               keyProtocol: kpLegacy))
    check not inboxChordsAvailable(KeyDelivery(frontEnd: feTerminal, platform: pkLinux,
                                               keyProtocol: kpNative))
    check inboxChordsAvailable(KeyDelivery(frontEnd: feTerminal, platform: pkMac,
                                           keyProtocol: kpKitty))

  test "the bell's glyphs are one cell wide on every glyph set":
    check BellGlyph == "⍾"
    check BellGlyphBasic.len == 1
    check BellGlyphAscii.len == 1
    check BellGlyphAscii[0].ord < 128
