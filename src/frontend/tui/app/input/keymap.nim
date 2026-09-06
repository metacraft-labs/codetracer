## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it. This module reads no terminal and holds no session: it turns a
## BYTE TOKEN somebody else read into a named action, and returns it as a value.
##
## app/input/keymap.nim — CTUI-9. CodeTracer-TUI.md §4.2's keybinding table,
## AS DATA.
##
## ## WHY IT IS DATA
##
## CTUI-9's contract: "Bindings are data, so conflict detection is mechanical
## rather than a review convention." A `case token of "n": stepOver()` cannot be
## asked whether `n` is bound twice, whether every published action has a
## binding, or which mode resolves a collision — it can only be read by a
## person, which is the review convention the milestone is written against.
##
## So the table below is a `seq[Binding]`, and
## `app/tests/test_keymap_no_conflicts.nim` is a STRUCTURAL test over it:
##
##   * no chord sequence is bound twice within one mode;
##   * no chord sequence is a proper PREFIX of another within one mode, which is
##     the way a binding becomes unreachable rather than ambiguous;
##   * every action §4.2 names has at least one binding;
##   * and — the load-bearing one — the suite PARSES §4.2's markdown table out
##     of `codetracer-specs/Front-Ends/CodeTracer-TUI.md` and compares it,
##     row by row, against this table. The published document is the oracle, so
##     the implementation and the specification cannot drift apart in either
##     direction without a red run.
##
## ## THE SPELLING AND THE CHORDS ARE TWO FIELDS, DELIBERATELY
##
## `Binding.spelling` is §4.2's own text for the key, verbatim — `rf`,
## `g` `g`, `Ctrl+w` `h`, `t` `<tick>` `Enter`. `Binding.chords` is what the
## resolver matches against. They differ, and each one has a reader:
##
##   * `t <tick> Enter` is ONE chord to this module (`t`), because the digits
##     and the `Enter` belong to CTUI-8's `input/timeline_keys.nim`, which
##     already owns a tick buffer with its own two-state machine. A keymap that
##     re-implemented the buffer would give the product two.
##   * `rf` is TWO chords (`r` then `f`), because that is what a user types,
##     even though §4.2 writes it as one token.
##
## Keeping both means the spec comparison can be exact (`spelling`'s components
## against the published cell's tokens) while the resolver stays a simple
## sequence match.
##
## ## §4.2's ONE COLLISION, AND HOW IT IS RESOLVED
##
## `n` appears twice: "Step Over (Forward)" and "Next / Prev Search Match". The
## resolution is BY MODE — `n` is `kaStepOver` in NORMAL and `kaNextMatch` in
## SEARCH — and it is total rather than assumed because the uniqueness check
## above is per mode and covers every mode.
##
## THE SECOND HALF OF THAT RESOLUTION IS A RULE ABOUT TEXT: in a mode that is
## accepting text (COMMAND always, SEARCH while its prompt is open — see
## `modal_state.isTextEntry`), a bound key that stands for a CHARACTER is
## shadowed by the text field, and one that does not is not. So `n` typed into
## an open `/` prompt is the letter n, `n` pressed while browsing the committed
## matches is "next match", and `Esc` is `Esc` in both. One rule, stated once,
## applied by `resolve` alone.
##
## "STANDS FOR A CHARACTER" IS `keyCharacter`, NOT `isPrintableKey`, and the
## difference is one key. `keyName(" ")` is `"Space"` — a five-letter NAME,
## because §4.2 binds `Space` to "Toggle Breakpoint" — so under the
## `isPrintableKey` spelling this rule had until CTUI-10, a space typed at a `:`
## prompt resolved to `krNone` and was silently lost, and `:goto 4500` could not
## be typed at all. `KeyResolution.character` carries what to insert, so no
## prompt has to know that `Space` is special.
##
## ## THREE ACTIONS COME FROM §4.1 RATHER THAN §4.2, AND THEY ARE MARKED
##
## §4.2's table has no way to ENTER INSPECT mode, no way to run what was typed
## at the `:` prompt, and no way to correct a typo in it. §4.1 supplies the
## first (`i` or `Enter` on a variable); the other two are what a prompt is.
## Rather than smuggle them in, each carries `specSectionOf(…) == ssSpec41` and
## the conflict suite asserts that the set of non-§4.2 actions is EXACTLY those
## three. A fourth one added later fails that assertion by name.
##
## ## THIS TABLE IS GLOBAL, AND ONE PANE-LOCAL KEY OVERLAPS IT
##
## Every binding here is (mode, chord) -> action for the WHOLE screen; §4.2 is
## one flat table and this is it. Several of its actions are nonetheless
## pane-relative — "Scroll Line Down / Up", "Expand Node", "Collapse Node",
## "Toggle Hex / Dec" act on whatever pane has focus — and delivering an action
## to the focused pane is the caller's job, not this module's.
##
## THE ONE MEASURED OVERLAP, recorded rather than resolved by fiat: CTUI-6's
## `app/input/call_stack_keys.KeyToggleGroup` is `x`, and §4.2's `x` is "Toggle
## Hex / Dec". §4.2 has no row for a recursion group at all, so `x` resolves
## here to `kaToggleHexDec` and CTUI-6's pane-local handler keeps `x` for its
## own pane. Nothing dispatches both today — `main.nim` has no driver (CTUI-11)
## — so there is no behaviour to regress; what there is, is a decision the pane
## wiring will have to make, and it is written down here so it is made rather
## than discovered. The same applies to CTUI-6's pane-local `g` / `G`, which
## §4.2 spends on "Jump to Start / End".
##
## ## THE PALETTE IS A COMMAND-MODE SURFACE
##
## §4.2 files `Ctrl+p` / `F1` under "Search and Palette", but what the palette
## searches is COMMANDS — CTUI-10's deliverables put `command_palette.nim`
## beside `command_line.nim` and the §4.3 interpreter, not beside `search.nim`.
## So `kaCommandPalette` raises `meOpenCommand` and the status bar reads
## COMMAND. Recorded here because it is a reading of the specification rather
## than a transcription of it.
##
## ## `.cttui-keys`
##
## `loadKeymap` layers a user's file over the built-in table: one binding per
## line, `MODE  chord [chord …]  = action-id`, `#` comments, and `-` as the
## action to UNBIND. Every malformed line is REPORTED with its number and its
## text — never skipped silently, because a keymap that ignores what it cannot
## parse is a keymap that tells the user their binding works.

import std/[os, strutils, tables]

import ./modal_state

export modal_state

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
    kaSelectTimeline = "select-timeline"
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

  Binding* = object
    ## One row of the table, for one mode.
    mode*: ModalMode
    spelling*: string
      ## §4.2's own text for the key. See the module header on why this is not
      ## `chords.join(" ")`.
    chords*: seq[string]
      ## The canonical key names, in order, that `resolve` matches.
    action*: KeyAction

  Keymap* = object
    bindings*: seq[Binding]

  SpecSection* = enum
    ## Which published section a binding's action comes from.
    ssSpec42 = "§4.2"
    ssSpec41 = "§4.1"

  KeyResolutionKind* = enum
    krNone = "none"
      ## Nothing is bound and the mode does not want the key.
    krAction = "action"
    krPending = "pending"
      ## A prefix was consumed. `KeyResolution.pending` is what to show.
    krPendingAbandoned = "pending-abandoned"
      ## A pending prefix was followed by a key that completes no binding. The
      ## prefix is dropped and the key is NOT re-interpreted on its own — the
      ## user meant `Ctrl+w` something, and silently running that something's
      ## unprefixed meaning is how a mistyped window command deletes a
      ## breakpoint.
    krPendingTimedOut = "pending-timed-out"
      ## The bounded timeout expired before the second chord and the key that
      ## arrived did not start a binding either. Distinct from
      ## `krPendingAbandoned` so a status bar can say WHY the prefix went away.
    krText = "text"
      ## The mode is a text field and this key is a character in it. What to
      ## INSERT is `KeyResolution.character`, never `key` — see `keyCharacter`.

  KeyResolution* = object
    kind*: KeyResolutionKind
    action*: KeyAction
    spelling*: string
      ## The binding that fired, for a notification or a failure message.
    key*: string
      ## The canonical name of the key that arrived.
    character*: string
      ## What a text field should INSERT for this key — set only on `krText`,
      ## and "" otherwise. `key` is `"Space"` and `character` is `" "`; for
      ## every other text key the two are equal. Carried rather than re-derived
      ## by each prompt, because a caller that inserted `key` would type the
      ## word "Space" into the buffer.
    pending*: string
      ## What the pending indicator should read; empty when nothing is pending.

  PendingState* = object
    ## A partially typed chord sequence, as a value.
    ##
    ## The TIMEOUT is stored as the moment the prefix started rather than as a
    ## countdown, so `resolve` is a pure function of (state, key, now) and a
    ## test can drive it with a virtual clock instead of sleeping.
    chords*: seq[string]
    startedMs*: int64

  KeymapErrorKind* = enum
    keSyntax = "syntax"
    keUnknownMode = "unknown-mode"
    keUnknownAction = "unknown-action"
    keEmptyChords = "empty-chords"

  KeymapError* = object
    ## A `.cttui-keys` line that could not be applied. Reported, never skipped:
    ## see the module header.
    kind*: KeymapErrorKind
    line*: int
    text*: string
    message*: string

  KeymapLoad* = object
    keymap*: Keymap
    errors*: seq[KeymapError]

const
  PendingTimeoutMs* = 1000'i64
    ## How long a pending prefix (`g`, `r`, `Ctrl+w`) waits for its second
    ## chord. CTUI-9: "Pending-prefix bindings have a BOUNDED timeout and a
    ## visible pending indicator." One second is Vim's own `timeoutlen`
    ## default, and the number is named so a test asserts the boundary at
    ## exactly `PendingTimeoutMs` and at `PendingTimeoutMs + 1` rather than
    ## somewhere plausible.

  KeymapFileName* = ".cttui-keys"
    ## The user keymap CTUI-9 names. `loadKeymapFile` takes a full path; this
    ## is the basename a resolver looks for.

  PendingIndicatorSuffix* = "-"
    ## What a pending prefix appends on screen: `g-`, `r-`, `Ctrl+w-`. A
    ## trailing mark rather than a bare `g`, so "a prefix is waiting" is
    ## distinguishable from a stray glyph in the status bar.

# ---------------------------------------------------------------------------
# Canonical key names
# ---------------------------------------------------------------------------

const
  FunctionKeyCodes = {
    15: "F5", 17: "F6", 18: "F7", 19: "F8", 20: "F9", 21: "F10", 23: "F11",
    24: "F12"}.toTable
    ## xterm's `CSI <code> ~` function keys. F1-F4 use SS3 (`ESC O P..S`) and
    ## are handled separately, which is xterm's own split rather than this
    ## module's — https://invisible-island.net/xterm/ctlseqs/ctlseqs.html,
    ## "PC-Style Function Keys".

  ModifierNames = {2: "Shift", 3: "Alt", 4: "Shift+Alt", 5: "Ctrl",
                   6: "Ctrl+Shift", 7: "Ctrl+Alt", 8: "Ctrl+Alt+Shift"}.toTable
    ## xterm's modifier parameter: the value is `1 + (Shift=1 | Alt=2 | Ctrl=4)`.
    ## Spelled in the order §4.2 writes them (`Shift+F10`, `Alt+F5`, `Ctrl+p`).

proc isPrintableKey*(name: string): bool =
  ## Whether a canonical key name is a single printable character.
  ##
  ## `Esc`, `Enter`, `Tab`, `F10` and `Ctrl+p` are all multi-character names,
  ## so this needs no second list to know they are not characters. It is NOT
  ## the whole of the text-entry shadowing rule — see `keyCharacter`.
  name.len == 1 and name[0] >= ' ' and name[0] <= '~'

proc keyCharacter*(name: string): string =
  ## The CHARACTER a canonical key name inserts into a text field, or "".
  ##
  ## THE PREDICATE THE TEXT-ENTRY SHADOWING RULE ACTUALLY USES, and it is not
  ## `isPrintableKey` because of exactly one key. `keyName` answers `"Space"`
  ## for byte `0x20`, deliberately: §4.2 binds `Space` to "Toggle Breakpoint"
  ## and a table cell reading ` ` would be unreadable. But `isPrintableKey`
  ## answers false for a five-letter name, so under CTUI-9's rule a space typed
  ## at a `:` prompt resolved to `krNone` AND WAS SILENTLY LOST — `:goto 4500`
  ## could not be typed at all.
  ##
  ## CTUI-9 could not have seen it: its own header records that "§4.2's table
  ## has no key that enters INSPECT mode and no way to run or edit the `:`
  ## prompt", so there was no text field to lose a character into. CTUI-10 has
  ## one, and `tests/real_terminal/test_real_command_mode.nim` types
  ## `:goto 4500` as real bytes on a real pty, which is where this was measured.
  ##
  ## The fix is here rather than in the prompt because the SHADOWING DECISION is
  ## here: a resolver that classified `Space` as "not text" and left the prompt
  ## to notice would be two rules for one question, which is the thing this
  ## module's header exists to prevent.
  if name == "Space": " "
  elif isPrintableKey(name): name
  else: ""

proc isTextKey*(name: string): bool =
  ## Whether a text field owns this key. `keyCharacter` with the character
  ## thrown away, named so `resolve` reads as a rule rather than as a length
  ## test.
  keyCharacter(name).len > 0

proc keyName*(token: string): string =
  ## The canonical name of one complete input token — a byte, or a whole escape
  ## sequence as `testing/test_app_runtime.nim` frames them.
  ##
  ## Returns "" for anything unrecognised (an SGR-1006 mouse report, a runaway
  ## sequence), so a caller can tell "not a key" from "a key nothing is bound
  ## to".
  if token.len == 0:
    return ""
  if token.len == 1:
    let c = token[0]
    case c
    of '\t': return "Tab"
    of '\r', '\n': return "Enter"
    # `\b` is Ctrl+H on the wire and `\x7f` is what most terminals send for
    # Backspace. Both spell Backspace here, which costs the product a `Ctrl+h`
    # binding it does not have and buys a Backspace that works on every
    # terminal.
    of '\x7f', '\b': return "Backspace"
    of ' ': return "Space"
    of '\x1b': return "Esc"
    else:
      if c >= '\x01' and c <= '\x1a':
        return "Ctrl+" & $char(ord('a') + ord(c) - 1)
      if c >= ' ' and c <= '~':
        return $c
      return ""
  # SS3: ESC O P..S — F1 to F4.
  if token.len == 3 and token[0] == '\x1b' and token[1] == 'O':
    case token[2]
    of 'P': return "F1"
    of 'Q': return "F2"
    of 'R': return "F3"
    of 'S': return "F4"
    else: return ""
  if token.len < 3 or token[0] != '\x1b' or token[1] != '[':
    return ""
  let body = token[2 .. ^1]
  let final = body[^1]
  let params = body[0 ..< body.len - 1]
  case final
  of 'A', 'B', 'C', 'D':
    # Arrows, plain (`CSI A`) or modified (`CSI 1 ; m A`).
    let name = case final
               of 'A': "Up"
               of 'B': "Down"
               of 'C': "Right"
               else: "Left"
    if params.len == 0:
      return name
    let parts = params.split(';')
    if parts.len == 2 and parts[0] == "1":
      try:
        let m = parseInt(parts[1])
        if ModifierNames.hasKey(m):
          return ModifierNames[m] & "+" & name
      except ValueError:
        return ""
    return ""
  of 'Z':
    # `CSI Z` is xterm's back-tab, which is what `Shift+Tab` sends.
    if params.len == 0: return "Shift+Tab"
    return ""
  of 'P', 'Q', 'R', 'S':
    # Modified F1-F4: `CSI 1 ; m P`.
    let parts = params.split(';')
    if parts.len == 2 and parts[0] == "1":
      try:
        let m = parseInt(parts[1])
        if ModifierNames.hasKey(m):
          let name = case final
                     of 'P': "F1"
                     of 'Q': "F2"
                     of 'R': "F3"
                     else: "F4"
          return ModifierNames[m] & "+" & name
      except ValueError:
        return ""
    return ""
  of '~':
    let parts = params.split(';')
    var code = 0
    try:
      code = parseInt(parts[0])
    except ValueError:
      return ""
    var base = ""
    if FunctionKeyCodes.hasKey(code):
      base = FunctionKeyCodes[code]
    else:
      case code
      of 2: base = "Insert"
      of 3: base = "Delete"
      of 5: base = "PageUp"
      of 6: base = "PageDown"
      else: return ""
    if parts.len == 1:
      return base
    if parts.len == 2:
      try:
        let m = parseInt(parts[1])
        if ModifierNames.hasKey(m):
          return ModifierNames[m] & "+" & base
      except ValueError:
        return ""
    return ""
  else:
    return ""

# ---------------------------------------------------------------------------
# The published table, as data
# ---------------------------------------------------------------------------

proc specSectionOf*(action: KeyAction): SpecSection =
  ## Which published section names this action. See the module header on the
  ## three §4.1 members.
  case action
  of kaEnterInspect, kaCommitPrompt, kaPromptBackspace: ssSpec41
  else: ssSpec42

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
  of kaSelectCallStack, kaSelectSource, kaSelectVariables, kaSelectTimeline:
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

proc b(mode: ModalMode; spelling: string; chords: seq[string];
       action: KeyAction): Binding =
  Binding(mode: mode, spelling: spelling, chords: chords, action: action)

proc b(mode: ModalMode; spelling: string; action: KeyAction): Binding =
  ## The common shape: one chord, spelled as itself.
  b(mode, spelling, @[spelling], action)

proc defaultKeymap*(): Keymap =
  ## §4.2, transcribed, plus the three §4.1-sourced actions this module's header
  ## names. The `spelling` column is the specification's own text, verbatim, and
  ## `app/tests/test_keymap_no_conflicts.nim` compares it against the published
  ## document rather than against a copy of it.
  var r: seq[Binding] = @[]

  # ---- NORMAL ------------------------------------------------------------
  # Pane Navigation
  r.add b(mmNormal, "Tab", kaFocusNextPane)
  r.add b(mmNormal, "Shift+Tab", kaFocusPrevPane)
  r.add b(mmNormal, "Ctrl+w h", @["Ctrl+w", "h"], kaFocusLeft)
  r.add b(mmNormal, "Ctrl+w j", @["Ctrl+w", "j"], kaFocusDown)
  r.add b(mmNormal, "Ctrl+w k", @["Ctrl+w", "k"], kaFocusUp)
  r.add b(mmNormal, "Ctrl+w l", @["Ctrl+w", "l"], kaFocusRight)
  r.add b(mmNormal, "1", kaSelectCallStack)
  r.add b(mmNormal, "2", kaSelectSource)
  r.add b(mmNormal, "3", kaSelectVariables)
  r.add b(mmNormal, "4", kaSelectTimeline)
  r.add b(mmNormal, "z", kaMaximizePane)
  # Omniscient Stepping
  r.add b(mmNormal, "n", kaStepOver)
  r.add b(mmNormal, "F10", kaStepOver)
  r.add b(mmNormal, "p", kaReverseStepOver)
  r.add b(mmNormal, "Shift+F10", kaReverseStepOver)
  r.add b(mmNormal, "s", kaStepInto)
  r.add b(mmNormal, "F11", kaStepInto)
  r.add b(mmNormal, "b", kaReverseStepInto)
  r.add b(mmNormal, "Shift+F11", kaReverseStepInto)
  r.add b(mmNormal, "f", kaStepOut)
  r.add b(mmNormal, "Shift+F5", kaStepOut)
  # `rf` is ONE token in §4.2 and TWO chords here — see the module header.
  r.add b(mmNormal, "rf", @["r", "f"], kaReverseStepOut)
  r.add b(mmNormal, "c", kaContinue)
  r.add b(mmNormal, "F5", kaContinue)
  r.add b(mmNormal, "rc", @["r", "c"], kaReverseContinue)
  r.add b(mmNormal, "Alt+F5", kaReverseContinue)
  # Time-Travel Seeking
  r.add b(mmNormal, "[", kaPrevCall)
  r.add b(mmNormal, "]", kaNextCall)
  r.add b(mmNormal, "{", kaPrevMutation)
  r.add b(mmNormal, "}", kaNextMutation)
  r.add b(mmNormal, "g g", @["g", "g"], kaJumpToStart)
  r.add b(mmNormal, "G", kaJumpToEnd)
  # ONE chord: the digits and the `Enter` are CTUI-8's tick buffer.
  r.add b(mmNormal, "t <tick> Enter", @["t"], kaSeekToTick)
  # Value Origin Tracking
  r.add b(mmNormal, "o", kaValueOrigin)
  r.add b(mmNormal, "O", kaReverseOrigin)
  # Source Navigation
  r.add b(mmNormal, "j", kaScrollLineDown)
  r.add b(mmNormal, "Down", kaScrollLineDown)
  r.add b(mmNormal, "k", kaScrollLineUp)
  r.add b(mmNormal, "Up", kaScrollLineUp)
  r.add b(mmNormal, "Ctrl+u", kaHalfPageUp)
  r.add b(mmNormal, "Ctrl+d", kaHalfPageDown)
  r.add b(mmNormal, ".", kaCenterOnPointer)
  r.add b(mmNormal, "F9", kaToggleBreakpoint)
  r.add b(mmNormal, "Space", kaToggleBreakpoint)
  # Variables Tree
  r.add b(mmNormal, "Enter", kaExpandNode)
  r.add b(mmNormal, "l", kaExpandNode)
  r.add b(mmNormal, "h", kaCollapseNode)
  r.add b(mmNormal, "Backspace", kaCollapseNode)
  r.add b(mmNormal, "x", kaToggleHexDec)
  r.add b(mmNormal, "m", kaViewMemoryDump)
  # Search and Palette
  r.add b(mmNormal, "Ctrl+p", kaCommandPalette)
  r.add b(mmNormal, "F1", kaCommandPalette)
  r.add b(mmNormal, "/", kaSearchForward)
  r.add b(mmNormal, "?", kaSearchBackward)
  # Command Mode
  r.add b(mmNormal, ":", kaOpenCommandPrompt)
  r.add b(mmNormal, "Esc", kaReturnToNormal)
  r.add b(mmNormal, "q", kaQuit)
  r.add b(mmNormal, "Ctrl+c", kaQuit)
  # §4.1's INSPECT entry.
  r.add b(mmNormal, "i", kaEnterInspect)

  # ---- COMMAND -----------------------------------------------------------
  # A text field: every printable key is a character, so only the three
  # non-printable ones are bound. `resolve` enforces that, not this list.
  r.add b(mmCommand, "Esc", kaReturnToNormal)
  r.add b(mmCommand, "Enter", kaCommitPrompt)
  r.add b(mmCommand, "Backspace", kaPromptBackspace)

  # ---- SEARCH ------------------------------------------------------------
  # `n` and `N` are bound HERE and nowhere else, which is the whole of §4.2's
  # one collision resolution. While the prompt is open they are shadowed by the
  # text field; once `Enter` commits, they walk the matches.
  r.add b(mmSearch, "Esc", kaReturnToNormal)
  r.add b(mmSearch, "Enter", kaCommitPrompt)
  r.add b(mmSearch, "Backspace", kaPromptBackspace)
  r.add b(mmSearch, "n", kaNextMatch)
  r.add b(mmSearch, "N", kaPrevMatch)

  # ---- INSPECT -----------------------------------------------------------
  # §4.1: "Deep navigation of complex data structures, memory hex viewing, and
  # expression origin inspection." So: §4.2's Variables Tree row, its Value
  # Origin row, the scrolling motions a deep tree needs, and the three ways out.
  r.add b(mmInspect, "Enter", kaExpandNode)
  r.add b(mmInspect, "l", kaExpandNode)
  r.add b(mmInspect, "h", kaCollapseNode)
  r.add b(mmInspect, "Backspace", kaCollapseNode)
  r.add b(mmInspect, "x", kaToggleHexDec)
  r.add b(mmInspect, "m", kaViewMemoryDump)
  r.add b(mmInspect, "o", kaValueOrigin)
  r.add b(mmInspect, "O", kaReverseOrigin)
  r.add b(mmInspect, "j", kaScrollLineDown)
  r.add b(mmInspect, "Down", kaScrollLineDown)
  r.add b(mmInspect, "k", kaScrollLineUp)
  r.add b(mmInspect, "Up", kaScrollLineUp)
  r.add b(mmInspect, "Ctrl+u", kaHalfPageUp)
  r.add b(mmInspect, "Ctrl+d", kaHalfPageDown)
  r.add b(mmInspect, ":", kaOpenCommandPrompt)
  r.add b(mmInspect, "/", kaSearchForward)
  r.add b(mmInspect, "?", kaSearchBackward)
  r.add b(mmInspect, "Esc", kaReturnToNormal)

  Keymap(bindings: r)

# ---------------------------------------------------------------------------
# Queries over the table
# ---------------------------------------------------------------------------

proc bindingsFor*(km: Keymap; mode: ModalMode): seq[Binding] =
  result = @[]
  for bnd in km.bindings:
    if bnd.mode == mode:
      result.add bnd

proc bindingsOf*(km: Keymap; action: KeyAction): seq[Binding] =
  result = @[]
  for bnd in km.bindings:
    if bnd.action == action:
      result.add bnd

proc prefixChords*(km: Keymap; mode: ModalMode): seq[string] =
  ## Every chord that only ever STARTS a sequence in this mode — `g`, `r`,
  ## `Ctrl+w`.
  ##
  ## Derived from the table rather than written beside it: a second list would
  ## be a second thing to keep true, and CTUI-9's contract is that the pending
  ## prefixes ARE the multi-chord bindings.
  result = @[]
  for bnd in km.bindings:
    if bnd.mode == mode and bnd.chords.len > 1 and bnd.chords[0] notin result:
      result.add bnd.chords[0]

proc pendingIndicator*(pending: PendingState): string =
  ## What §4.2's status bar shows while a prefix is waiting: `g-`, `Ctrl+w-`.
  ## Empty when nothing is pending.
  if pending.chords.len == 0: ""
  else: pending.chords.join(" ") & PendingIndicatorSuffix

proc initPendingState*(): PendingState =
  PendingState(chords: @[], startedMs: 0)

proc clear*(pending: var PendingState) =
  pending.chords = @[]
  pending.startedMs = 0

# ---------------------------------------------------------------------------
# Resolution
# ---------------------------------------------------------------------------

proc matchExact(km: Keymap; mode: ModalMode;
                chords: seq[string]): (bool, Binding) =
  for bnd in km.bindings:
    if bnd.mode == mode and bnd.chords == chords:
      return (true, bnd)
  (false, Binding())

proc hasPrefix(km: Keymap; mode: ModalMode; chords: seq[string]): bool =
  ## Whether some binding in `mode` STARTS with `chords` and is longer.
  for bnd in km.bindings:
    if bnd.mode == mode and bnd.chords.len > chords.len:
      var ok = true
      for i, c in chords:
        if bnd.chords[i] != c:
          ok = false
          break
      if ok:
        return true
  false

proc resolve*(km: Keymap; state: ModalState; pending: var PendingState;
              token: string; nowMs: int64): KeyResolution =
  ## Turn one input token into an action, a pending prefix, or a character.
  ##
  ## `nowMs` is passed in rather than read, which is what makes the bounded
  ## timeout assertable without a sleep: `app/tests/test_modal_transitions.nim`
  ## drives it at `PendingTimeoutMs` and at `PendingTimeoutMs + 1` and asserts
  ## the two different answers.
  let name = keyName(token)
  result = KeyResolution(kind: krNone, action: kaNone, spelling: "", key: name,
                         pending: "", character: "")
  if name.len == 0:
    # Not a key at all — a mouse report, or a sequence this module does not
    # name. A pending prefix SURVIVES it: a mouse report arriving between
    # `Ctrl+w` and `l` is not the user changing their mind.
    result.pending = pendingIndicator(pending)
    return

  var timedOut = false
  if pending.chords.len > 0 and nowMs - pending.startedMs > PendingTimeoutMs:
    # THE BOUNDED TIMEOUT. Checked before the key is interpreted, so the key
    # that arrives late is read on its own terms rather than as the second half
    # of a prefix the user has long forgotten.
    pending.clear()
    timedOut = true

  let candidate = pending.chords & @[name]
  let (matched, bnd) = matchExact(km, state.mode, candidate)
  if matched:
    # THE TEXT-ENTRY SHADOW. A printable key bound in a text-accepting mode is
    # a character, not a command — see the module header. Non-printable
    # bindings (`Esc`, `Enter`, `Backspace`) are never shadowed, which is what
    # keeps a prompt escapable.
    if pending.chords.len == 0 and isTextKey(name) and state.isTextEntry:
      result.kind = krText
      result.character = keyCharacter(name)
      return
    pending.clear()
    result.kind = krAction
    result.action = bnd.action
    result.spelling = bnd.spelling
    return

  if hasPrefix(km, state.mode, candidate):
    if pending.chords.len == 0 and isTextKey(name) and state.isTextEntry:
      result.kind = krText
      result.character = keyCharacter(name)
      return
    pending.chords = candidate
    pending.startedMs = nowMs
    result.kind = krPending
    result.pending = pendingIndicator(pending)
    return

  if pending.chords.len > 0:
    # A prefix was open and this key completes nothing. Drop both — see
    # `krPendingAbandoned`.
    pending.clear()
    result.kind = krPendingAbandoned
    return

  if isTextKey(name) and state.isTextEntry:
    result.kind = krText
    result.character = keyCharacter(name)
    return

  result.kind = if timedOut: krPendingTimedOut else: krNone

# ---------------------------------------------------------------------------
# `.cttui-keys`
# ---------------------------------------------------------------------------

proc parseModeName*(s: string): (bool, ModalMode) =
  for m in ModalMode:
    if cmpIgnoreCase($m, s) == 0:
      return (true, m)
  (false, mmNormal)

proc parseActionName*(s: string): (bool, KeyAction) =
  for a in KeyAction:
    if $a == s:
      return (true, a)
  (false, kaNone)

proc unbind(km: var Keymap; mode: ModalMode; chords: seq[string]) =
  var kept: seq[Binding] = @[]
  for bnd in km.bindings:
    if bnd.mode == mode and bnd.chords == chords:
      continue
    kept.add bnd
  km.bindings = kept

proc loadKeymap*(base: Keymap; text: string): KeymapLoad =
  ## Layer a `.cttui-keys` file over `base`.
  ##
  ## Line format, one binding per line:
  ##
  ##     # a comment
  ##     NORMAL   Ctrl+w  l   = focus-right
  ##     NORMAL   n           = -            # unbind
  ##
  ## The chords are whitespace-separated and are the CANONICAL names `keyName`
  ## produces, so a user writes `Ctrl+w l` and `r f` rather than escape bytes.
  ##
  ## Every malformed line becomes a `KeymapError` carrying its number and its
  ## text. NOTHING IS SKIPPED SILENTLY: a keymap that ignored a line the user
  ## wrote would report a working binding for a key that does nothing.
  result = KeymapLoad(keymap: base, errors: @[])
  var lineNo = 0
  for rawLine in text.splitLines():
    inc lineNo
    var line = rawLine
    let hash = line.find('#')
    if hash >= 0:
      line = line[0 ..< hash]
    line = line.strip()
    if line.len == 0:
      continue
    let eq = line.find('=')
    if eq < 0:
      result.errors.add KeymapError(
        kind: keSyntax, line: lineNo, text: rawLine,
        message: "expected '<MODE> <chord…> = <action>'; no '=' on the line")
      continue
    let lhs = line[0 ..< eq].strip()
    let rhs = line[eq + 1 .. ^1].strip()
    let fields = lhs.splitWhitespace()
    if fields.len < 2:
      result.errors.add KeymapError(
        kind: keEmptyChords, line: lineNo, text: rawLine,
        message: "expected a mode and at least one chord before '='")
      continue
    let (modeOk, mode) = parseModeName(fields[0])
    if not modeOk:
      result.errors.add KeymapError(
        kind: keUnknownMode, line: lineNo, text: rawLine,
        message: "unknown mode '" & fields[0] & "'")
      continue
    let chords = fields[1 .. ^1]
    if rhs == "-":
      unbind(result.keymap, mode, chords)
      continue
    let (actionOk, action) = parseActionName(rhs)
    if not actionOk:
      result.errors.add KeymapError(
        kind: keUnknownAction, line: lineNo, text: rawLine,
        message: "unknown action '" & rhs & "'")
      continue
    unbind(result.keymap, mode, chords)
    result.keymap.bindings.add Binding(mode: mode, spelling: chords.join(" "),
                                       chords: chords, action: action)

proc describeError*(e: KeymapError): string =
  KeymapFileName & ":" & $e.line & ": " & e.message & " — in: " & e.text.strip()

proc loadKeymapFile*(base: Keymap; path: string): KeymapLoad =
  ## `loadKeymap` over a file.
  ##
  ## A MISSING FILE IS NOT AN ERROR — nobody is required to have one, and every
  ## user without a `.cttui-keys` would otherwise start with a complaint. A file
  ## that exists and cannot be READ is: it means the user wrote one and the
  ## product is about to behave as if they had not, which is the state that must
  ## never be silent.
  ##
  ## WHERE the file lives is not decided here. A path resolver belongs with the
  ## CLI flags (CTUI-11) and the launcher integration (CTUI-12); this module
  ## takes a path so it stays testable without an environment.
  if not fileExists(path):
    return KeymapLoad(keymap: base, errors: @[])
  var text = ""
  try:
    text = readFile(path)
  except IOError, OSError:
    return KeymapLoad(keymap: base, errors: @[KeymapError(
      kind: keSyntax, line: 0, text: path,
      message: "the file exists but could not be read")])
  loadKeymap(base, text)
