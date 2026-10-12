## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reads no terminal and holds no session.
##
## app/input/keymap.nim — the terminal's ACTION VOCABULARY: what
## `runtime.performAction` and CTUI-10's `interpreter.dispatchAction` are
## indexed by, with each action's product-mode scope (Mode-Transitions §8)
## and the published §4.2 text it answers to.
##
## ## WHAT IS NO LONGER HERE, AND WHERE IT WENT (PLAT-68)
##
## This module was CTUI-9's keymap: §4.2's table as a `seq[Binding]`, its own
## resolver (`resolve`, with its pending prefix and its timeout) and the
## `.cttui-keys` loader. Base-Keymaps-And-Layer-Stack.md §8 rules ONE resolver
## and keymaps as data, so:
##
##   * §4.2's table is the Vim and Kakoune bases' navigation table, as data —
##     `viewmodel/keymap/navigation_keymap.NavigationRows` — resolved by the
##     one resolver (`editing_keymap.resolveLayers`) through the router
##     (`viewmodel/keymap/keymap_router`), which every front-end shares;
##   * a row names an OPERATION, and `operation_dispatch` maps the operations
##     the terminal performs through this vocabulary onto its actions;
##   * `.cttui-keys` is imported once into the shared `keybindings.json`
##     (`viewmodel/keymap/keymap_importers`) and not read again.
##
## `test_keymap_no_conflicts.nim` still parses §4.2 out of CodeTracer-TUI.md
## and compares it, row by row, with the navigation table.
##
## ## THE PALETTE IS A COMMAND-MODE SURFACE
##
## §4.2 files `Ctrl+p` / `F1` under "Search and Palette", but what the palette
## searches is COMMANDS. So `kaCommandPalette` raises `meOpenCommand` under the
## modal bases. Recorded here because it is a reading of the specification
## rather than a transcription of it.

# PLAT-16. `ProductMode` from the CORE, through the sanctioned facade. See
# `resolve`'s `product` parameter and `ActionScope` below: scoping a chord by
# the PRODUCT mode is Mode-Transitions.md §8's requirement, and doing it with a
# parameter rather than with a fifth `ModalMode` is §1.2's.
import codetracer_embed

# PLAT-31. `keyName`, `keyCharacter`, `isTextKey` and `isPrintableKey` WERE
# HERE and are now one module both keymaps call — see `key_names.nim`'s header.
# They are re-exported so every call site of this module is unchanged, and so
# that "the editing keymap reuses `keymap.nim`'s existing `keyCharacter`
# spelling" (Editing-Operations-And-Keymaps.md §4.3) is a fact about a shared
# function rather than about two texts that happen to agree today
# (Verification-Harness-Traps §30a).
import ../../../../common/key_names

import ./modal_state

export modal_state
export ProductMode
export key_names

type
  KeyAction* = enum
    ## One named action. The string values are the identifiers a `.cttui-keys`
    ## file uses, so the file format and the enum cannot drift.
    kaNone = "none"

    # ---- §4.2 Pane Navigation ---------------------------------------------
    kaFocusNextPane = "focus-next-pane"
    kaFocusPrevPane = "focus-prev-pane"
    kaFocusLeft = "focus-left"
    kaFocusDown = "focus-down"
    kaFocusUp = "focus-up"
    kaFocusRight = "focus-right"
    kaSelectCallStack = "select-call-stack"
    kaSelectSource = "select-source"
    kaSelectVariables = "select-variables"
    kaSelectEventLog = "select-event-log"
    kaMaximizePane = "maximize-pane"

    # ---- §4.2 Omniscient Stepping -----------------------------------------
    kaStepOver = "step-over"
    kaReverseStepOver = "reverse-step-over"
    kaStepInto = "step-into"
    kaReverseStepInto = "reverse-step-into"
    kaStepOut = "step-out"
    kaReverseStepOut = "reverse-step-out"
    kaContinue = "continue"
    kaReverseContinue = "reverse-continue"

    # ---- §4.2 Time-Travel Seeking -----------------------------------------
    kaPrevCall = "prev-call"
    kaNextCall = "next-call"
    kaPrevMutation = "prev-mutation"
    kaNextMutation = "next-mutation"
    kaJumpToStart = "jump-to-start"
    kaJumpToEnd = "jump-to-end"
    kaSeekToTick = "seek-to-tick"

    # ---- §4.2 Value Origin Tracking ---------------------------------------
    kaValueOrigin = "value-origin"
    kaReverseOrigin = "reverse-origin"

    # ---- §4.2 Source Navigation -------------------------------------------
    kaScrollLineDown = "scroll-line-down"
    kaScrollLineUp = "scroll-line-up"
    kaHalfPageUp = "half-page-up"
    kaHalfPageDown = "half-page-down"
    kaCenterOnPointer = "center-on-pointer"
    kaToggleBreakpoint = "toggle-breakpoint"

    # ---- §4.2 Variables Tree ----------------------------------------------
    kaExpandNode = "expand-node"
    kaCollapseNode = "collapse-node"
    kaToggleHexDec = "toggle-hex-dec"
    kaViewMemoryDump = "view-memory-dump"

    # ---- §4.2 Search and Palette ------------------------------------------
    kaCommandPalette = "command-palette"
    kaSearchForward = "search-forward"
    kaSearchBackward = "search-backward"
    kaNextMatch = "next-match"
    kaPrevMatch = "prev-match"

    # ---- §4.2 Command Mode ------------------------------------------------
    kaOpenCommandPrompt = "open-command-prompt"
    kaReturnToNormal = "return-to-normal"
    kaQuit = "quit"

    # ---- §4.1, not §4.2 — see the module header ---------------------------
    kaEnterInspect = "enter-inspect"
    kaCommitPrompt = "commit-prompt"
    kaPromptBackspace = "prompt-backspace"

    # ---- Mode-Transitions.md, not CodeTracer-TUI.md — PLAT-16 -------------
    kaToggleProductMode = "toggle-product-mode"
      ## `Ctrl+F5`. Mode-Transitions.md §1: *"The mode toggle is one command.
      ## `Ctrl+F5` switches to whichever mode the session is not in. It is the
      ## same command in both directions, so it cannot get the two out of
      ## step, and it is bound in both modes."*
      ##
      ## It comes from a DIFFERENT PUBLISHED DOCUMENT than every other member
      ## of this enum, which is why `SpecSection` gained a third value rather
      ## than this action being quietly filed under §4.2 — where
      ## `test_keymap_no_conflicts.nim` would then have looked for a row that
      ## does not exist and found the whole partition inconsistent.
      ##
      ## Its scope is `asBoth` and that is load-bearing: §8.4 — *"The mode
      ## toggle is bound in both modes, or the transition is one-way from the
      ## keyboard."*

    # ---- CodeTracer-TUI.md §3.3.1, not §4.2 --------------------------------
    kaNextSessionTab = "next-session-tab"
      ## `g t` / `Ctrl+Tab`. §3.3.1 (Session Header and Info Bar): *"When
      ## multiple trace sessions are loaded, tabs along the top bar allow
      ## instant switching via `Ctrl+Tab` or `gt`/`gT`."* The strip is
      ## `headless_app/session_tabs`; this steps it, wrapping.
    kaPrevSessionTab = "previous-session-tab"
      ## `g T` / `Ctrl+Shift+Tab`, the same row read backwards.

  SpecSection* = enum
    ## Which published section a binding's action comes from.
    ssSpec42 = "§4.2"
    ssSpec41 = "§4.1"
    ssModeTransitions = "Mode-Transitions.md"
      ## PLAT-16. An action whose oracle is the GUI's mode-transition
      ## specification rather than the terminal front-end's key table. There is
      ## exactly one today (`kaToggleProductMode`) and
      ## `test_product_mode_dimensions.nim` asserts that count, on the same
      ## rule `test_keymap_no_conflicts.nim` applies to the §4.1 three: a
      ## fourth source of bindings must arrive announced.
    ssSpec331 = "§3.3.1"
      ## The session tabs' two steps, named in CodeTracer-TUI.md §3.3.1's
      ## prose rather than in §4.2's table. Asserted to be EXACTLY those two
      ## by `test_keymap_no_conflicts.nim`, on the rule the other two extra
      ## sources are held to.

  ActionScope* = enum
    ## WHICH PRODUCT MODES AN ACTION MEANS ANYTHING IN.
    ##
    ## Mode-Transitions.md §8.1: *"A chord whose action has no meaning in the
    ## current mode must be inert **and say so**. … A key that silently does
    ## nothing is indistinguishable from a key that is broken."*
    ##
    ## THIS IS A PROPERTY OF THE ACTION, NOT A FIFTH INPUT MODE, and that is
    ## the distinction CodeTracer-TUI-Edit-Mode.md §1.2 insists on: *"A
    ## keybinding may be bound differently per product mode … but that is a
    ## property of the keymap's scoping, not a fifth input mode."* The scope is
    ## consulted by `runtime.performAction` AFTER a key resolved to the
    ## action, so the key is inert AND SAYS SO rather than looking unbound.
    asBoth = "both"
    asDebugOnly = "debug-only"
    asEditOnly = "edit-only"


# ---------------------------------------------------------------------------
# Canonical key names — MOVED, not deleted
# ---------------------------------------------------------------------------
#
# The byte decoder (`keyName`), the one modifier spelling (`chordName`, since
# PLAT-68) and the text-entry predicate (`isPrintableKey`, `keyCharacter`,
# `isTextKey`) live in `src/common/key_names.nim` and are re-exported by the
# import above, so every call site here and in every consumer of this module
# reads exactly as it did.
#
# WHY THEY MOVED, IN ONE SENTENCE: PLAT-31's editing keymap has to ask the same
# text-entry question of the same key names, and the alternative to sharing the
# function was writing it a second time — which is the shape
# Verification-Harness-Traps §30a calls "the worst instance … a whole re-derived
# module", over the one predicate in this file whose narrower spelling has
# ALREADY cost the product a defect (`Space`, and `:goto 4500`).

# ---------------------------------------------------------------------------
# The published table, as data
# ---------------------------------------------------------------------------

proc specSectionOf*(action: KeyAction): SpecSection =
  ## Which published section names this action. See the module header on the
  ## three §4.1 members.
  case action
  of kaEnterInspect, kaCommitPrompt, kaPromptBackspace: ssSpec41
  of kaToggleProductMode: ssModeTransitions
  of kaNextSessionTab, kaPrevSessionTab: ssSpec331
  else: ssSpec42

proc scopeOf*(action: KeyAction): ActionScope =
  ## Which product modes `action` means anything in.
  ##
  ## ## THE RULE, AND THE TWO EXCEPTIONS MODE-TRANSITIONS.MD MAKES BY NAME
  ##
  ## Everything that moves a replay is `asDebugOnly`: §8.1's example is Step
  ## Over, and "there is no session to step" is true of every stepping, seeking
  ## and origin-tracking action in Edit mode.
  ##
  ## Everything structural is `asBoth`. Pane focus, the command prompt, search,
  ## the palette, quit and the mode toggle itself all mean the same thing in
  ## both modes, and scoping them out would make Edit mode a different
  ## application rather than a different mode of one.
  ##
  ## `kaToggleBreakpoint` is `asBoth` DELIBERATELY, and it is the one that
  ## looks wrong until you read the specification: CodeTracer-TUI-Edit-Mode.md
  ## §3 — *"Breakpoint markers stay: setting a breakpoint while editing is a
  ## normal thing to do, and the point list survives the transition per
  ## Mode-Transitions.md."* Mode-Transitions.md §5 agrees, listing breakpoints
  ## among what a transition preserves because *"they belong to the project,
  ## not to the session"*.
  ##
  ## `kaCenterOnPointer` is `asDebugOnly` for the same reason
  ## `views/gutter.nim` drops the pointer glyph in Edit mode: there is no
  ## execution to centre on.
  ##
  ## NOTHING IS `asEditOnly` YET, and the value exists anyway rather than being
  ## added when the first member arrives. `:run` and `:build` are COMMANDS in
  ## this milestone and not chords (CodeTracer-TUI-Edit-Mode.md §5: *"There is
  ## no toolbar. The trigger is a keybinding and a command"* — the command is
  ## what landed), so the third arm is uninhabited. `test_product_mode_
  ## dimensions.nim` asserts that emptiness EXPLICITLY, so the day something
  ## fills it the fact is announced rather than absorbed.
  case action
  of kaStepOver, kaReverseStepOver, kaStepInto, kaReverseStepInto,
     kaStepOut, kaReverseStepOut, kaContinue, kaReverseContinue,
     kaPrevCall, kaNextCall, kaPrevMutation, kaNextMutation,
     kaJumpToStart, kaJumpToEnd, kaSeekToTick,
     kaValueOrigin, kaReverseOrigin,
     kaCenterOnPointer,
     kaToggleHexDec, kaViewMemoryDump, kaEnterInspect:
    asDebugOnly
  else:
    asBoth

proc appliesIn*(action: KeyAction; product: ProductMode): bool =
  ## Whether `action` means anything in `product`.
  case scopeOf(action)
  of asBoth: true
  of asDebugOnly: product == pmDebug
  of asEditOnly: product == pmEdit

proc inertReason*(action: KeyAction; product: ProductMode): string =
  ## §8.1's *"the reason, on the surface the user is looking at"*.
  ##
  ## It names the action AND the mode, because a message that said only "not
  ## available" would leave a user who pressed `n` expecting Step Over unable
  ## to tell whether the key is unbound, the session is gone, or they are in
  ## the wrong mode — and only the third has a remedy they can act on. The
  ## remedy is named too.
  if appliesIn(action, product):
    return ""
  case scopeOf(action)
  of asDebugOnly:
    "'" & $action & "' needs a replay session; you are in " & $product &
      " mode. Ctrl+F5 switches."
  of asEditOnly:
    "'" & $action & "' needs an editing session; you are in " & $product &
      " mode. Ctrl+F5 switches."
  of asBoth:
    ""

proc specAction*(action: KeyAction): string =
  ## The text of §4.2's "Action" cell for this action, VERBATIM — including the
  ## slash-joined rows, which name two actions at once.
  ##
  ## This string is what `app/tests/test_keymap_no_conflicts.nim` matches
  ## against the table it parses out of the specification, so it is a
  ## transcription and must stay one: a "tidier" spelling here is a red run.
  case action
  of kaNone: ""
  of kaFocusNextPane, kaFocusPrevPane: "Next / Previous Pane"
  of kaFocusLeft, kaFocusDown, kaFocusUp, kaFocusRight: "Directional Focus"
  of kaSelectCallStack, kaSelectSource, kaSelectVariables, kaSelectEventLog:
    "Direct Pane Select"
  of kaMaximizePane: "Maximize / Restore Pane"
  of kaStepOver: "Step Over (Forward)"
  of kaReverseStepOver: "Reverse Step Over (Backward)"
  of kaStepInto: "Step Into (Forward)"
  of kaReverseStepInto: "Reverse Step Into (Backward)"
  of kaStepOut: "Step Out / Finish"
  of kaReverseStepOut: "Reverse Step Out"
  of kaContinue: "Continue (Forward)"
  of kaReverseContinue: "Reverse Continue (Backward)"
  of kaPrevCall, kaNextCall: "Jump Prev / Next Call"
  of kaPrevMutation, kaNextMutation: "Jump Prev / Next Mutation"
  of kaJumpToStart, kaJumpToEnd: "Jump to Start / End"
  of kaSeekToTick: "Seek to Tick"
  of kaValueOrigin: "Jump to Value Origin"
  of kaReverseOrigin: "Reverse Origin"
  of kaScrollLineDown, kaScrollLineUp: "Scroll Line Down / Up"
  of kaHalfPageUp, kaHalfPageDown: "Half Page Up / Down"
  of kaCenterOnPointer: "Center on Execution Pointer"
  of kaToggleBreakpoint: "Toggle Breakpoint"
  of kaExpandNode: "Expand Node"
  of kaCollapseNode: "Collapse Node"
  of kaToggleHexDec: "Toggle Hex / Dec"
  of kaViewMemoryDump: "View Memory Dump"
  of kaCommandPalette: "Fuzzy Command Palette"
  of kaSearchForward: "Search Forward"
  of kaSearchBackward: "Search Backward"
  of kaNextMatch, kaPrevMatch: "Next / Prev Search Match"
  of kaOpenCommandPrompt: "Open Command Prompt"
  of kaReturnToNormal: "Return to NORMAL Mode"
  of kaQuit: "Quit Debugger"
  # §4.1, so no §4.2 row exists. The empty string is what the conflict suite
  # keys its "not published in §4.2" partition on.
  of kaEnterInspect, kaCommitPrompt, kaPromptBackspace: ""
  # Mode-Transitions.md, so no §4.2 row exists either. Same empty string, and
  # `specSectionOf` is what tells the two apart.
  of kaToggleProductMode: ""
  # §3.3.1's prose, not §4.2's table.
  of kaNextSessionTab, kaPrevSessionTab: ""

proc modalEventFor*(action: KeyAction): (bool, ModalEvent) =
  ## Which `modal_state` event an action raises, if any.
  ##
  ## Here rather than in `modal_state.nim` because it is a property of the
  ## BINDING TABLE — `Ctrl+p` opens COMMAND, and that is a reading of §4.2 (see
  ## the module header) that the state machine must not have to know about.
  case action
  of kaOpenCommandPrompt, kaCommandPalette: (true, meOpenCommand)
  of kaSearchForward: (true, meOpenSearchForward)
  of kaSearchBackward: (true, meOpenSearchBackward)
  of kaEnterInspect: (true, meOpenInspect)
  of kaCommitPrompt: (true, meCommit)
  of kaReturnToNormal: (true, meCancel)
  else: (false, meCancel)
