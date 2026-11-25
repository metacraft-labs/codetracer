## views/agent_harbor_sessions_bar_words.nim
##
## The sessions bar's inbox group, as every front-end draws it: a bell with
## the inbox's count, Previous and Next, and a small mark while auto-switch
## is on. This module holds the group's state and its words, so the web,
## GPUI and the terminal read one source and say exactly the same thing.
##
## It renders nothing and imports no renderer: only the inbox viewmodel
## (nim-agents-isonim-viewmodels `inbox_vm`), the keymap's description of
## how keys reach a front-end, and the standard library.
##
## The facts all come from `InboxVM`; nothing here decides a state, it only
## reads one:
##
## - the group is drawn whether or not anything waits: with nothing waiting
##   the bell is muted and Next is disabled, but the bell stays, so the
##   control never appears or disappears under the reader's pointer;
## - Previous is enabled only once there is somewhere to go back to, which
##   the inbox's server says (`InboxVM.canPrev`), so the group keeps no
##   state of its own;
## - the bell's tooltip and accessible name say how much waits, where the
##   reader is in the walk (`2 of 5`) and the keys that step through it, or
##   that those keys cannot be typed in this terminal.

import nim_agents_isonim_viewmodels/agent_harbor/inbox_vm
import ../keymap/context_keys

export inbox_vm
export context_keys.KeyDelivery, context_keys.FrontEndKind,
  context_keys.PlatformKind, context_keys.KeyProtocol

type
  InboxGroupState* = object
    ## What the inbox group draws, read from the inbox in one place.
    bellShown*: bool
      ## The bell is drawn. Always: an empty inbox mutes it, never hides it.
    muted*: bool
      ## Nothing waits: the bell is drawn in the quiet ink, with no count.
    nextEnabled*: bool
    prevEnabled*: bool
    autoSwitchOn*: bool
      ## Auto-switch is on: the bar shows `AutoSwitchIndicatorText` beside
      ## the bell.
    badge*: string
      ## The count beside the bell (`3`); "" when nothing waits.
    badgeRole*: string
      ## The count's ink: `warning` while an agent is stopped on an item,
      ## `info` while only feedback requests wait, `quiet` when nothing
      ## waits.
    blocked*: int
      ## Items an agent is stopped on.
    feedback*: int
      ## Feedback requests, which block no agent.

const
  InboxNextChord* = "Alt+]"
    ## The key that steps to the next item from anywhere in the window.
  InboxPreviousChord* = "Alt+["
    ## The key that steps back from anywhere in the window.
  InboxChordsUnavailableText* = "Alt+] and Alt+[ are unavailable in this terminal"
    ## Said instead of the keys where the terminal cannot tell them from a
    ## plain Escape and bracket. The buttons still work.
  InboxNextLabel* = "Next item"
  InboxPreviousLabel* = "Previous item"
  AutoSwitchIndicatorText* = "auto"
    ## The bar's small mark beside the bell while auto-switch is on: after
    ## the reader answers an item, the next one opens by itself.
  AutoSwitchIndicatorTitle* = "Auto-switch is on: answering an item opens the next one"
  BellGlyph* = "\xE2\x8D\xBE"
    ## ⍾ (U+237E BELL SYMBOL, Miscellaneous Technical): one cell wide, so
    ## the terminal can draw it beside the count without a wide-character
    ## gap; the screens with the full glyph set draw it.
  BellGlyphBasic* = "!"
    ## The basic glyph set (WGL4) has no bell; `!` reads as "attention".
  BellGlyphAscii* = "!"
    ## The plain-ASCII screen's bell.
  GroupDot = " \xC2\xB7 "

proc inboxGroupStateOf*(vm: InboxVM): InboxGroupState =
  ## Tracked: the group's state, read from the inbox.
  let count = vm.count
  result.bellShown = true
  result.muted = vm.isEmpty or count == 0
  result.nextEnabled = vm.canNext
  result.prevEnabled = vm.canPrev
  result.autoSwitchOn = vm.autoSwitch.val
  result.blocked = vm.blockedCount
  result.feedback = vm.feedbackCount
  result.badge = if count > 0: $count else: ""
  result.badgeRole =
    if result.muted: "quiet"
    elif result.blocked > 0: "warning"
    elif result.feedback > 0: "info"
    else: "quiet"

func inboxChordsAvailable*(delivery: KeyDelivery): bool =
  ## Whether `Alt+]` and `Alt+[` can be typed on this front-end. A window
  ## receives keys, so it always can. A terminal receives bytes, and with
  ## the classic encoding `Alt+]` arrives as Escape followed by `]`, which
  ## the terminal cannot tell from a lone Escape typed quickly before a
  ## bracket; only the Kitty keyboard protocol and xterm's modifyOtherKeys
  ## send the chord as one unambiguous key.
  if delivery.frontEnd != feTerminal: true
  else: delivery.keyProtocol in {kpKitty, kpModifyOtherKeys}

func chordLine(available: bool): string =
  if available:
    InboxNextChord & " next" & GroupDot & InboxPreviousChord & " previous"
  else:
    InboxChordsUnavailableText

proc bellTitle*(vm: InboxVM; chordsAvailable: bool): string =
  ## Tracked: the bell's tooltip and accessible name: how much waits
  ## (`3 tasks need input`), where the reader is in the walk (`1 of 3`) when
  ## that says more than the count, and the keys that step through it, or
  ## that this terminal cannot type them.
  result = vm.controlTitle
  let position = vm.positionText
  if position.len > 0 and position != vm.countText:
    result.add GroupDot & position
  result.add GroupDot & chordLine(chordsAvailable)

func stepTitle(label, chord: string; available: bool): string =
  if chord.len == 0: label
  elif available: label & " (" & chord & ")"
  else: label & " (" & chord & " is unavailable in this terminal)"

func prevTitle*(chord: string; available: bool): string =
  ## Previous's tooltip: what it does and the key that does it from
  ## anywhere, or that the terminal cannot type that key.
  stepTitle(InboxPreviousLabel, chord, available)

func nextTitle*(chord: string; available: bool): string =
  ## Next's tooltip: what it does and the key that does it from anywhere,
  ## or that the terminal cannot type that key.
  stepTitle(InboxNextLabel, chord, available)
