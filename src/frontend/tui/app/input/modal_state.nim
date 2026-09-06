## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. Nothing here touches a terminal: this module is a state machine
## over VALUES, and the only thing it knows about a terminal is the two byte
## sequences a mode's cursor is described by — which it RETURNS as a string
## rather than writes.
##
## app/input/modal_state.nim — CTUI-9. The NORMAL / COMMAND / SEARCH / INSPECT
## state machine of CodeTracer-TUI.md §4.1.
##
## ## THE REJECTIONS ARE THE POINT
##
## `applyModalEvent` answers a `ModalTransition` whose `accepted` field can be
## false, and a rejected event leaves the state BYTE-IDENTICAL. That shape is
## deliberate and it is what CTUI-9 asks for: "the transitions the specification
## does not allow, asserted to be rejected. An unspecified transition silently
## permitted is how modal editors become unpredictable."
##
## A machine that simply ignored an event it did not recognise would be
## indistinguishable, from a test, from one that handled it and happened to land
## back where it started. So every rejection carries a REASON — `mrTextEntry`,
## `mrAlreadyInMode`, `mrNothingToCommit`, `mrNotAModeChange` — and
## `app/tests/test_modal_transitions.nim` sweeps the whole (context x event)
## product and asserts the reason, not merely the mode.
##
## ## SEARCH HAS TWO PHASES, AND THAT IS WHAT RESOLVES §4.2's ONE COLLISION
##
## §4.2 binds `n` twice: "Step Over" under Omniscient Stepping and "Next Search
## Match" under Search and Palette. CTUI-9 resolves it BY MODE — `n` is Step
## Over in NORMAL and Next Match in SEARCH — and `app/tests/
## test_keymap_no_conflicts.nim` proves the resolution is total.
##
## For that resolution to be usable, SEARCH mode has to outlive the prompt: a
## SEARCH mode that ended at `Enter` would put `n` back in NORMAL, where it is
## already Step Over. So SEARCH carries a PHASE:
##
##   * `spTyping`   — the `/` or `?` prompt is open and every printable key is
##                    text. This is where `n` is the letter n.
##   * `spBrowsing` — `Enter` committed the query. The prompt is closed, the
##                    match set is live, and `n` / `N` walk it.
##
## `Esc` leaves SEARCH from either phase. The phase is NOT a fifth mode: §4.1
## names four and the status bar shows four; it is a field of the SEARCH state,
## and `keymap.resolve` consults it only to decide whether a bound key fires or
## is inserted into the query.
##
## THE COST IS RECORDED RATHER THAN HIDDEN: while `spTyping` is open, `n` and
## `N` are ordinary characters, so a user CAN type them into a query; and while
## `spBrowsing` is open, `n` is not Step Over. That second one is the trade §4.2
## forces, and the visible mode indicator (`SEARCH` in the status bar) is what
## tells a user which of the two `n`s they are about to press.
##
## ## THE CURSOR IS PART OF THE MODE
##
## `cursorFor` gives each mode a shape and a visibility, and
## `cursorControlBytes` spells them as DECSCUSR (`CSI Ps SP q`) and DECTCEM
## (`CSI ? 25 h` / `CSI ? 25 l`). Two references:
##
##   * DECSCUSR — https://invisible-island.net/xterm/ctlseqs/ctlseqs.html
##     ("Set cursor style", `CSI Ps SP q`: 2 = steady block, 4 = steady
##     underline, 6 = steady bar).
##   * DECTCEM — the same document, `CSI ? 25 h` (show) and `CSI ? 25 l` (hide).
##
## Neither sequence MOVES the cursor, which is why a snapshot app can emit them
## immediately before a frame without disturbing
## `testing/dual_snap.waitForCompleteFrame`'s bottom-right-cell barrier.
##
## They are here rather than in a view because the mode and its cursor are one
## fact, and because `tests/real_terminal/test_real_keybindings.nim` asserts the
## mode from the TERMINAL's side — `cursorShape()` and `cursorVisible()` are two
## of the seven things `docs/tui-testing.md` lists as unobservable at Tier 1.

import ../views/status_bar

type
  ModalMode* = enum
    ## §4.1's four modes, spelled as the status bar shows them.
    mmNormal = "NORMAL"
    mmCommand = "COMMAND"
    mmSearch = "SEARCH"
    mmInspect = "INSPECT"

  SearchPhase* = enum
    ## Where SEARCH mode is between `/` and `Esc`. See the module header: this
    ## is a field of the SEARCH state, not a fifth mode.
    spTyping = "typing"
    spBrowsing = "browsing"

  ModalEvent* = enum
    ## Everything that can ASK for a mode change. Deliberately smaller than the
    ## keymap: most keys never touch the mode, and an event enum that grew a
    ## member per key would make the transition sweep a sweep over keys rather
    ## than over the machine.
    meOpenCommand = "open-command"
      ## `:` — §4.2's "Open Command Prompt", and `Ctrl+p` / `F1`, whose palette
      ## is a COMMAND-mode surface (see `keymap.nim` on why).
    meOpenSearchForward = "open-search-forward"    ## `/`
    meOpenSearchBackward = "open-search-backward"  ## `?`
    meOpenInspect = "open-inspect"
      ## `i`. §4.1 names it ("INSPECT Mode (`i` or `Enter` on Variable)") and
      ## §4.2's table does NOT — see `keymap.nim`'s header on that gap.
    meCommit = "commit"                            ## `Enter`
    meCancel = "cancel"                            ## `Esc`

  ModalRejection* = enum
    ## Why an event did not change the mode. `mrAccepted` is the only value a
    ## caller may treat as success.
    mrAccepted = "accepted"
    mrTextEntry = "text-entry-owns-the-key"
      ## The mode is a text field and the key is a character in it: `:` inside
      ## COMMAND, `/` inside a SEARCH prompt. Rejected as a TRANSITION; the
      ## caller inserts it into the buffer instead.
    mrAlreadyInMode = "already-in-mode"
      ## `i` in INSPECT. Distinct from an accepted self-transition, which
      ## `meCancel` in NORMAL is.
    mrNothingToCommit = "nothing-to-commit"
      ## `Enter` while a committed search is being browsed.
    mrNotReachableFromHere = "not-reachable-from-here"
      ## The target mode exists and the key is not a character, but §4.1 does
      ## not describe this edge. INSPECT from a committed search is the only
      ## one: §4.1 enters INSPECT with "`i` or `Enter` on Variable", both of
      ## which are gestures on the variables pane in NORMAL.
    mrNotAModeChange = "not-a-mode-change"
      ## `Enter` in NORMAL is §4.2's "Expand Node" and must not be mistaken for
      ## a commit. INSPECT's `Enter` is the same action.

  ModalState* = object
    ## The whole interaction mode, as a value.
    mode*: ModalMode
    phase*: SearchPhase
      ## Meaningful only in `mmSearch`. Held rather than derived because
      ## `keymap.resolve` needs it and a caller must not have to remember which
      ## other field implies it.
    backward*: bool
      ## True when SEARCH was opened with `?` rather than `/` — §4.2's "Search
      ## Backward". Carried so `n` / `N` know which way "next" is.
    buffer*: string
      ## What the user has typed at the open prompt. Cleared on entry to a
      ## prompt and on `Esc`; preserved across `Enter` into `spBrowsing` so the
      ## committed query is still readable.
    lastQuery*: string
      ## The most recently committed search. Distinct from `buffer` so that
      ## opening a new prompt does not destroy the query `n` is walking.

  ModalTransition* = object
    ## What one event did, reported rather than inferred from a state diff:
    ## "rejected" and "accepted, and landed where it started" are different
    ## answers and only one of them may make a caller beep.
    accepted*: bool
    rejection*: ModalRejection
    fromMode*, toMode*: ModalMode
    fromPhase*, toPhase*: SearchPhase

  ModalCursorShape* = enum
    ## DECSCUSR's three steady shapes. An enum rather than the raw parameter so
    ## a test names what it expects; `decscusrParam` converts.
    mcsBlock = "block"
    mcsUnderline = "underline"
    mcsBar = "bar"

  CursorPresentation* = object
    shape*: ModalCursorShape
    visible*: bool

const
  ShowCursorBytes* = "\x1b[?25h"
    ## DECTCEM set.
  HideCursorBytes* = "\x1b[?25l"
    ## DECTCEM reset.

proc initModalState*(mode = mmNormal): ModalState =
  ModalState(mode: mode, phase: spTyping, backward: false, buffer: "",
             lastQuery: "")

proc isTextEntry*(state: ModalState): bool =
  ## Whether the mode currently owns every printable key.
  ##
  ## COMMAND always does; SEARCH does only while its prompt is open. This is
  ## the ONE predicate `keymap.resolve` consults to decide between a binding and
  ## a character, so "which keys are text" has a single answer rather than one
  ## per call site.
  case state.mode
  of mmCommand: true
  of mmSearch: state.phase == spTyping
  of mmNormal, mmInspect: false

# ---------------------------------------------------------------------------
# The machine
# ---------------------------------------------------------------------------

proc rejected(state: ModalState; why: ModalRejection): ModalTransition =
  ModalTransition(accepted: false, rejection: why, fromMode: state.mode,
                  toMode: state.mode, fromPhase: state.phase,
                  toPhase: state.phase)

proc applyModalEvent*(state: var ModalState; ev: ModalEvent): ModalTransition =
  ## Apply one mode-changing event. A REJECTED event leaves `state` untouched.
  ##
  ## The whole machine is one `case` over (mode, event) with no fallthrough, so
  ## the sweep in `app/tests/test_modal_transitions.nim` covers every pair by
  ## construction rather than by the author having remembered them all.
  let fromMode = state.mode
  let fromPhase = state.phase
  template accept(target: ModalMode; targetPhase: SearchPhase):
      ModalTransition =
    state.mode = target
    state.phase = targetPhase
    ModalTransition(accepted: true, rejection: mrAccepted, fromMode: fromMode,
                    toMode: target, fromPhase: fromPhase,
                    toPhase: targetPhase)

  # EVERY ACCEPTED TRANSITION LANDS IN `spTyping` EXCEPT THE COMMIT INSIDE
  # SEARCH. One rule, so a phase cannot survive a trip through COMMAND and make
  # the next `/` open a prompt that is already "browsing".

  case state.mode
  of mmNormal:
    case ev
    of meOpenCommand:
      state.buffer = ""
      accept(mmCommand, spTyping)
    of meOpenSearchForward:
      state.buffer = ""
      state.backward = false
      accept(mmSearch, spTyping)
    of meOpenSearchBackward:
      state.buffer = ""
      state.backward = true
      accept(mmSearch, spTyping)
    of meOpenInspect:
      accept(mmInspect, spTyping)
    of meCommit:
      # §4.2 gives `Enter` in NORMAL to "Expand Node". Reporting it as
      # `mrNotAModeChange` rather than swallowing it is what keeps a caller from
      # treating a tree expansion as a committed prompt.
      rejected(state, mrNotAModeChange)
    of meCancel:
      # `Esc` in NORMAL is an ACCEPTED self-transition: §4.2 says it cancels a
      # search, closes popups or exits command mode, and in NORMAL it is what
      # abandons a pending prefix (`keymap.PendingKeys`). A rejection here would
      # make "there was nothing to cancel" indistinguishable from "Esc is not
      # allowed", and the pending prefix would survive it.
      state.buffer = ""
      accept(mmNormal, fromPhase)
  of mmCommand:
    case ev
    of meOpenCommand, meOpenSearchForward, meOpenSearchBackward:
      # `:`, `/` and `?` are characters at the `:` prompt.
      rejected(state, mrTextEntry)
    of meOpenInspect:
      # `i` is a character too, and INSPECT is not reachable from a text field.
      rejected(state, mrTextEntry)
    of meCommit:
      # The command runs and the mode returns to NORMAL. CTUI-10 owns what
      # running it means; CTUI-9 owns only that the mode comes back.
      state.buffer = ""
      accept(mmNormal, spTyping)
    of meCancel:
      state.buffer = ""
      accept(mmNormal, spTyping)
  of mmSearch:
    # THE PHASE DECIDES, and it decides one thing: whether the key is a
    # character. While the prompt is open (`spTyping`) `:`, `/`, `?` and `i`
    # are text. Once `Enter` has committed, the prompt is closed and they mean
    # what they mean everywhere else.
    case ev
    of meOpenCommand:
      if state.phase == spTyping:
        rejected(state, mrTextEntry)
      else:
        state.buffer = ""
        accept(mmCommand, spTyping)
    of meOpenSearchForward:
      if state.phase == spTyping:
        rejected(state, mrTextEntry)
      else:
        state.buffer = ""
        state.backward = false
        accept(mmSearch, spTyping)
    of meOpenSearchBackward:
      if state.phase == spTyping:
        rejected(state, mrTextEntry)
      else:
        state.buffer = ""
        state.backward = true
        accept(mmSearch, spTyping)
    of meOpenInspect:
      if state.phase == spTyping:
        rejected(state, mrTextEntry)
      else:
        # §4.1 enters INSPECT with "`i` or `Enter` on Variable" — a gesture on
        # the variables pane, which a committed search is not on. Refused
        # rather than half-implemented; `Esc` then `i` is the spelling, and it
        # is two accepted transitions.
        rejected(state, mrNotReachableFromHere)
    of meCommit:
      if state.phase == spTyping:
        state.lastQuery = state.buffer
        accept(mmSearch, spBrowsing)
      else:
        rejected(state, mrNothingToCommit)
    of meCancel:
      state.buffer = ""
      accept(mmNormal, spTyping)
  of mmInspect:
    case ev
    of meOpenCommand:
      state.buffer = ""
      accept(mmCommand, spTyping)
    of meOpenSearchForward:
      state.buffer = ""
      state.backward = false
      accept(mmSearch, spTyping)
    of meOpenSearchBackward:
      state.buffer = ""
      state.backward = true
      accept(mmSearch, spTyping)
    of meOpenInspect:
      rejected(state, mrAlreadyInMode)
    of meCommit:
      # `Enter` in INSPECT is §4.2's "Expand Node", exactly as in NORMAL.
      rejected(state, mrNotAModeChange)
    of meCancel:
      # The buffer is cleared here as it is on every other accepted route back
      # to NORMAL: `Esc` means "the prompt is gone", and a mode that left a
      # stale query behind would show it again the next time `:` opened.
      state.buffer = ""
      accept(mmNormal, spTyping)

proc describeTransition*(t: ModalTransition): string =
  ## One line for a failure message: what was asked, and what the machine said.
  $t.fromMode & "(" & $t.fromPhase & ") -> " &
    (if t.accepted: $t.toMode & "(" & $t.toPhase & ")" else: "REJECTED " &
     $t.rejection)

# ---------------------------------------------------------------------------
# What a mode looks like
# ---------------------------------------------------------------------------

proc statusMode*(mode: ModalMode): UiMode =
  ## §3.3.6's mode indicator for a §4.1 mode.
  ##
  ## `app/views/status_bar.UiMode` predates this module (CTUI-3) and carries two
  ## members §4.1 does not name — `umVisual` and `umSeek`, the latter being
  ## CTUI-8's `t <tick>` prompt. This mapping is total in the direction that
  ## matters: every §4.1 mode has an indicator.
  case mode
  of mmNormal: umNormal
  of mmCommand: umCommand
  of mmSearch: umSearch
  of mmInspect: umInspect

proc cursorFor*(mode: ModalMode): CursorPresentation =
  ## The cursor a mode shows.
  ##
  ## The rule is one line long: A MODE THAT ACCEPTS TEXT SHOWS A CURSOR WHERE
  ## THE TEXT GOES, and a mode that does not shows none. So NORMAL hides it —
  ## there is no insertion point on a screen whose every key is a command, and a
  ## block parked in a pane would read as a selection that is not there.
  ##
  ## The three shapes are distinct so a terminal can be asked which mode it is
  ## in without reading a single glyph, which is what
  ## `tests/real_terminal/test_real_keybindings.nim` does. COMMAND and SEARCH
  ## share the bar because both are one-line prompts; the status bar's own
  ## indicator is what separates them, and that test asserts BOTH.
  case mode
  of mmNormal: CursorPresentation(shape: mcsBlock, visible: false)
  of mmCommand: CursorPresentation(shape: mcsBar, visible: true)
  of mmSearch: CursorPresentation(shape: mcsBar, visible: true)
  of mmInspect: CursorPresentation(shape: mcsUnderline, visible: true)

proc decscusrParam*(shape: ModalCursorShape): int =
  ## DECSCUSR's `Ps` for a shape. The STEADY variants (even numbers): a blinking
  ## cursor would make two consecutive Tier-2 reads of the same mode disagree
  ## about `cursorBlink`, and nothing in §4.1 asks for a blink.
  case shape
  of mcsBlock: 2
  of mcsUnderline: 4
  of mcsBar: 6

proc cursorControlBytes*(mode: ModalMode): string =
  ## DECSCUSR then DECTCEM for `mode`: the exact bytes a driver writes so that a
  ## terminal's own cursor reports the mode.
  ##
  ## Shape first, then visibility, so that hiding never races a shape change on
  ## a terminal that resets the cursor on `CSI ? 25 h`.
  let c = cursorFor(mode)
  "\x1b[" & $decscusrParam(c.shape) & " q" &
    (if c.visible: ShowCursorBytes else: HideCursorBytes)
