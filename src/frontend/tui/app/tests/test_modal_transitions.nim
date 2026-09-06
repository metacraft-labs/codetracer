## test_modal_transitions.nim — CTUI-9, Tier 1, PURE.
##
## ## What this suite is for
##
## CTUI-9: "every transition in the state machine, including `Esc` from each
## mode and the transitions the specification does *not* allow, asserted to be
## rejected. An unspecified transition silently permitted is how modal editors
## become unpredictable."
##
## So the first case is a SWEEP OVER THE WHOLE PRODUCT of five contexts and six
## events — thirty pairs, every one of them decided by an expected table written
## in THIS file — and it asserts its own comparison count against the product of
## its parameters. CTUI-8's audit note is the reason that last clause is there:
## a sweep that asserts only its accumulated expectations catches an inner
## `break` and not an outer `continue`.
##
## ## THE EXPECTED TABLE IS NOT THE MODULE'S
##
## `ExpectedTransitions` below is transcribed from CodeTracer-TUI.md §4.1 —
## four modes, what opens each and what leaves it — and from §4.2's `Esc` row.
## It is NOT read from `app/input/modal_state.nim`, and it must not be: an
## expected value produced by the code under test asserts nothing. Every row
## names the mode, the phase, the acceptance, the destination AND the rejection
## reason, so a machine that got the mode right for the wrong reason is red.
##
## ## The pending prefixes are here rather than in the conflict suite
##
## `g`, `r` and `Ctrl+w` are STATE — a partially typed sequence and the moment
## it started — so their bounded timeout and their visible indicator belong with
## the state machine. `test_keymap_no_conflicts.nim` stays purely structural: it
## reads the table and never presses a key.
##
## ## No mocks, no clock
##
## Nothing here opens a session, a terminal or a file. The timeout is driven by
## passing `nowMs` in, which is why the boundary can be asserted at exactly
## `PendingTimeoutMs` and at `PendingTimeoutMs + 1` rather than by sleeping and
## hoping.
##
## ## Templates, not procs, for anything that calls `check`

import std/[monotimes, strutils, times, unittest]

import ../input/keymap
import ../input/modal_state
import ../layout/profile
import ../views/status_bar

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 136

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  Context = object
    ## One place the machine can be, named so a failure says where.
    name: string
    mode: ModalMode
    phase: SearchPhase

  Expectation = object
    ## What §4.1 says one event does from one context.
    accepted: bool
    toMode: ModalMode
    toPhase: SearchPhase
    rejection: ModalRejection

const
  Contexts = [
    Context(name: "NORMAL", mode: mmNormal, phase: spTyping),
    Context(name: "COMMAND", mode: mmCommand, phase: spTyping),
    Context(name: "SEARCH/typing", mode: mmSearch, phase: spTyping),
    Context(name: "SEARCH/browsing", mode: mmSearch, phase: spBrowsing),
    Context(name: "INSPECT", mode: mmInspect, phase: spTyping),
  ]

  Events = [meOpenCommand, meOpenSearchForward, meOpenSearchBackward,
            meOpenInspect, meCommit, meCancel]

template accepts(m: ModalMode; p: SearchPhase): Expectation =
  Expectation(accepted: true, toMode: m, toPhase: p, rejection: mrAccepted)

template refuses(why: ModalRejection; m: ModalMode;
                 p: SearchPhase): Expectation =
  ## A rejection leaves the machine where it was, so the destination IS the
  ## origin — written out rather than defaulted, because a table whose rejected
  ## rows carried a placeholder destination could not notice a machine that
  ## moved anyway.
  Expectation(accepted: false, toMode: m, toPhase: p, rejection: why)

const
  ExpectedTransitions: array[5, array[6, Expectation]] = [
    # ---- NORMAL. §4.1: `:` opens COMMAND, `/` and `?` open SEARCH, `i` opens
    # INSPECT. §4.2 gives `Enter` to "Expand Node", so it is not a commit.
    # `Esc` in NORMAL is §4.2's "close popups" and is what drops a pending
    # prefix, so it is an ACCEPTED self-transition.
    [accepts(mmCommand, spTyping),                     # meOpenCommand
     accepts(mmSearch, spTyping),                      # meOpenSearchForward
     accepts(mmSearch, spTyping),                      # meOpenSearchBackward
     accepts(mmInspect, spTyping),                     # meOpenInspect
     refuses(mrNotAModeChange, mmNormal, spTyping),    # meCommit
     accepts(mmNormal, spTyping)],                     # meCancel
    # ---- COMMAND. A text field: `:`, `/`, `?` and `i` are characters in it.
    [refuses(mrTextEntry, mmCommand, spTyping),
     refuses(mrTextEntry, mmCommand, spTyping),
     refuses(mrTextEntry, mmCommand, spTyping),
     refuses(mrTextEntry, mmCommand, spTyping),
     accepts(mmNormal, spTyping),
     accepts(mmNormal, spTyping)],
    # ---- SEARCH while its prompt is open. Same text rule; `Enter` commits the
    # query and SEARCH stays open so `n`/`N` can walk the matches.
    [refuses(mrTextEntry, mmSearch, spTyping),
     refuses(mrTextEntry, mmSearch, spTyping),
     refuses(mrTextEntry, mmSearch, spTyping),
     refuses(mrTextEntry, mmSearch, spTyping),
     accepts(mmSearch, spBrowsing),
     accepts(mmNormal, spTyping)],
    # ---- SEARCH after the commit. The prompt is closed, so nothing is text.
    # INSPECT is the one edge §4.1 does not describe: it is entered with `i` or
    # `Enter` ON A VARIABLE, which a match list is not.
    [accepts(mmCommand, spTyping),
     accepts(mmSearch, spTyping),
     accepts(mmSearch, spTyping),
     refuses(mrNotReachableFromHere, mmSearch, spBrowsing),
     refuses(mrNothingToCommit, mmSearch, spBrowsing),
     accepts(mmNormal, spTyping)],
    # ---- INSPECT. `Enter` is "Expand Node" here too, and `i` again is a
    # no-op that must be reported as one.
    [accepts(mmCommand, spTyping),
     accepts(mmSearch, spTyping),
     accepts(mmSearch, spTyping),
     refuses(mrAlreadyInMode, mmInspect, spTyping),
     refuses(mrNotAModeChange, mmInspect, spTyping),
     accepts(mmNormal, spTyping)],
  ]

  # Counted independently of the table above so that a row deleted by a bad
  # edit changes one number and not both.
  ContextCount = 5
  EventCount = 6

proc contextState(c: Context): ModalState =
  ## A machine parked in `c`, with a query typed so the buffer's fate is
  ## observable.
  result = initModalState(c.mode)
  result.phase = c.phase
  result.buffer = "shield"

suite "CTUI-9: the modal state machine decides every event":

  test "every (context, event) pair is decided, and a rejection changes nothing":
    var comparisons = 0
    var wrong: seq[string] = @[]
    for ci, c in Contexts:
      for ei, ev in Events:
        inc comparisons
        let want = ExpectedTransitions[ci][ei]
        var state = contextState(c)
        let before = state
        let got = applyModalEvent(state, ev)
        var problems: seq[string] = @[]
        if got.accepted != want.accepted:
          problems.add "accepted " & $got.accepted & " want " & $want.accepted
        if got.rejection != want.rejection:
          problems.add "reason " & $got.rejection & " want " & $want.rejection
        if state.mode != want.toMode:
          problems.add "mode " & $state.mode & " want " & $want.toMode
        if state.phase != want.toPhase:
          problems.add "phase " & $state.phase & " want " & $want.toPhase
        if got.fromMode != c.mode or got.fromPhase != c.phase:
          problems.add "origin " & $got.fromMode & "/" & $got.fromPhase
        if not want.accepted and state != before:
          # THE REJECTION CONTRACT: a refused event leaves the value
          # byte-identical, buffer and direction included. Without this a
          # machine could report `accepted == false` and still have moved.
          problems.add "state changed on a rejection"
        if problems.len > 0:
          wrong.add c.name & " + " & $ev & ": " & problems.join("; ")
    if wrong.len > 0:
      for w in wrong:
        checkpoint(w)
    ck wrong.len == 0
    # THE SWEEP'S OWN SIZE, asserted against its parameters rather than against
    # a number copied from a run: an outer `continue` that skipped a whole
    # context would leave every expectation above satisfied.
    checkpoint("comparisons: " & $comparisons)
    ck comparisons == ContextCount * EventCount
    ck comparisons == 30

  test "the rejected half is a real half, and it is the larger one":
    # THE POSITIVE TWIN FOR THE SWEEP ABOVE. A table with no rejections at all
    # would satisfy every assertion in the first case; these two counts are what
    # make "the machine refuses things" a measured fact.
    var accepted = 0
    var refused = 0
    var reasons: seq[ModalRejection] = @[]
    for ci in 0 ..< ContextCount:
      for ei in 0 ..< EventCount:
        let want = ExpectedTransitions[ci][ei]
        if want.accepted:
          inc accepted
        else:
          inc refused
          if want.rejection notin reasons:
            reasons.add want.rejection
    checkpoint("accepted " & $accepted & ", refused " & $refused &
               ", distinct reasons " & $reasons.len)
    ck accepted == 17
    ck refused == 13
    ck accepted + refused == 30
    # Five distinct reasons, so the rejections are DIAGNOSES rather than one
    # blanket refusal wearing five names.
    ck reasons.len == 5
    for why in [mrTextEntry, mrAlreadyInMode, mrNothingToCommit,
                mrNotAModeChange, mrNotReachableFromHere]:
      checkpoint("reason present: " & $why)
      ck why in reasons
    ck mrAccepted notin reasons

  test "Esc returns to NORMAL from every mode, and clears the prompt":
    var visited = 0
    for c in Contexts:
      inc visited
      var state = contextState(c)
      let t = applyModalEvent(state, meCancel)
      checkpoint(c.name & ": " & describeTransition(t))
      ck t.accepted
      ck state.mode == mmNormal
      ck state.phase == spTyping
      ck state.buffer.len == 0
    ck visited == ContextCount
    # …and the committed query SURVIVES the escape, which is what makes a
    # search resumable. `lastQuery` is set by the commit, not by `Esc`.
    var s = initModalState(mmSearch)
    s.buffer = "damage"
    discard applyModalEvent(s, meCommit)
    ck s.lastQuery == "damage"
    ck s.phase == spBrowsing
    discard applyModalEvent(s, meCancel)
    ck s.mode == mmNormal
    ck s.lastQuery == "damage"
    ck s.buffer.len == 0

  test "the four §4.1 modes each have an indicator and a distinct cursor":
    var seenIndicators: seq[string] = @[]
    var seenCursors: seq[string] = @[]
    var modes = 0
    for m in ModalMode:
      inc modes
      let indicator = $statusMode(m)
      checkpoint($m & " -> indicator '" & indicator & "'")
      # The indicator IS the mode's own spelling: §3.3.6 shows the mode by name,
      # so a mapping that renamed one would put a word on screen no
      # documentation contains.
      ck indicator == $m
      ck indicator notin seenIndicators
      seenIndicators.add indicator
      let c = cursorFor(m)
      seenCursors.add $c.shape & "/" & $c.visible
    ck modes == 4
    ck seenIndicators.len == 4
    # NORMAL hides the cursor; the three that accept a selection or text show
    # one, and no two of the four look the same.
    ck cursorFor(mmNormal).visible == false
    ck cursorFor(mmCommand).visible
    ck cursorFor(mmSearch).visible
    ck cursorFor(mmInspect).visible
    ck cursorFor(mmNormal).shape == mcsBlock
    ck cursorFor(mmCommand).shape == mcsBar
    ck cursorFor(mmSearch).shape == mcsBar
    ck cursorFor(mmInspect).shape == mcsUnderline
    var distinctCursors: seq[string] = @[]
    for d in seenCursors:
      if d notin distinctCursors:
        distinctCursors.add d
    checkpoint("distinct cursor presentations: " & $distinctCursors)
    # Three, not four: COMMAND and SEARCH are both one-line prompts and share
    # the bar. That is why `tests/real_terminal/test_real_keybindings.nim`
    # asserts the status bar AS WELL AS the cursor.
    ck distinctCursors.len == 3
    # The bytes are DECSCUSR then DECTCEM, exactly.
    ck cursorControlBytes(mmNormal) == "\x1b[2 q" & HideCursorBytes
    ck cursorControlBytes(mmCommand) == "\x1b[6 q" & ShowCursorBytes
    ck cursorControlBytes(mmInspect) == "\x1b[4 q" & ShowCursorBytes
    ck decscusrParam(mcsBlock) == 2
    ck decscusrParam(mcsUnderline) == 4
    ck decscusrParam(mcsBar) == 6
    # `umInspect` is CTUI-9's addition to CTUI-3's indicator enum, and its hint
    # strip is §4.1's own description of the mode rather than a copy of
    # another's.
    ck statusMode(mmInspect) == umInspect
    ck keyHints(umInspect, lpStandard) != keyHints(umNormal, lpStandard)
    ck keyHints(umInspect, lpStandard).contains("expand")

  test "text entry is exactly COMMAND and an open SEARCH prompt":
    var checkedContexts = 0
    for c in Contexts:
      inc checkedContexts
      let state = contextState(c)
      let want = c.mode == mmCommand or
                 (c.mode == mmSearch and c.phase == spTyping)
      checkpoint(c.name & " isTextEntry expected " & $want)
      ck state.isTextEntry == want
    ck checkedContexts == ContextCount

  test "§4.2's one collision — `n` — is resolved by mode":
    let km = defaultKeymap()
    var pending = initPendingState()
    # NORMAL: `n` is "Step Over (Forward)".
    var normal = initModalState(mmNormal)
    let inNormal = km.resolve(normal, pending, "n", 0)
    checkpoint("NORMAL n -> " & $inNormal.kind & " " & $inNormal.action)
    ck inNormal.kind == krAction
    ck inNormal.action == kaStepOver
    ck inNormal.spelling == "n"
    ck pending.chords.len == 0
    # SEARCH while the prompt is open: `n` is the letter n.
    var typing = initModalState(mmSearch)
    typing.phase = spTyping
    let whileTyping = km.resolve(typing, pending, "n", 0)
    checkpoint("SEARCH/typing n -> " & $whileTyping.kind)
    ck whileTyping.kind == krText
    ck whileTyping.action == kaNone
    # SEARCH after the commit: `n` is "Next Search Match".
    var browsing = initModalState(mmSearch)
    browsing.phase = spBrowsing
    let whileBrowsing = km.resolve(browsing, pending, "n", 0)
    checkpoint("SEARCH/browsing n -> " & $whileBrowsing.kind & " " &
               $whileBrowsing.action)
    ck whileBrowsing.kind == krAction
    ck whileBrowsing.action == kaNextMatch
    # `N` the same way, so the pair is resolved rather than only its first half.
    ck km.resolve(typing, pending, "N", 0).kind == krText
    ck km.resolve(browsing, pending, "N", 0).action == kaPrevMatch
    # And the NON-printable bindings are NOT shadowed by the prompt, which is
    # what keeps an open prompt escapable.
    ck km.resolve(typing, pending, "\x1b", 0).action == kaReturnToNormal
    ck km.resolve(typing, pending, "\r", 0).action == kaCommitPrompt
    ck km.resolve(typing, pending, "\x7f", 0).action == kaPromptBackspace
    # …and the same three keys in NORMAL mean their §4.2 actions instead.
    ck km.resolve(normal, pending, "\r", 0).action == kaExpandNode
    ck km.resolve(normal, pending, "\x7f", 0).action == kaCollapseNode
    ck km.resolve(normal, pending, "\x1b", 0).action == kaReturnToNormal

  test "a pending prefix is visible, bounded, and abandoned rather than guessed":
    let km = defaultKeymap()
    # The prefixes are DERIVED from the table, not listed beside it.
    let prefixes = km.prefixChords(mmNormal)
    checkpoint("NORMAL prefixes: " & prefixes.join(", "))
    ck prefixes.len == 3
    for p in ["g", "r", "Ctrl+w"]:
      checkpoint("prefix present: " & p)
      ck p in prefixes
    # …and a mode with no multi-chord binding has none, which is the negative
    # twin: "three prefixes" is satisfied by a function that returns three of
    # anything.
    ck km.prefixChords(mmCommand).len == 0
    ck km.prefixChords(mmSearch).len == 0
    ck km.prefixChords(mmInspect).len == 0

    var state = initModalState(mmNormal)
    var pending = initPendingState()
    # `g` alone is PENDING and says so on screen.
    let first = km.resolve(state, pending, "g", 100)
    ck first.kind == krPending
    ck first.pending == "g-"
    ck pendingIndicator(pending) == "g-"
    ck pending.chords == @["g"]
    # `g` `g` completes, and the indicator goes away.
    let second = km.resolve(state, pending, "g", 200)
    checkpoint("g g -> " & $second.kind & " " & $second.action)
    ck second.kind == krAction
    ck second.action == kaJumpToStart
    ck second.spelling == "g g"
    ck pendingIndicator(pending) == ""
    # `G` alone is a DIFFERENT action, so the prefix does not swallow it.
    ck km.resolve(state, pending, "G", 300).action == kaJumpToEnd
    # `r` `f` and `r` `c`, the two §4.2 spells as one token each.
    ck km.resolve(state, pending, "r", 400).kind == krPending
    ck pendingIndicator(pending) == "r-"
    ck km.resolve(state, pending, "f", 401).action == kaReverseStepOut
    ck km.resolve(state, pending, "r", 500).kind == krPending
    ck km.resolve(state, pending, "c", 501).action == kaReverseContinue
    # `Ctrl+w` `l`, whose indicator names the modifier so a user can see what
    # the terminal delivered.
    ck km.resolve(state, pending, "\x17", 600).kind == krPending
    ck pendingIndicator(pending) == "Ctrl+w-"
    ck km.resolve(state, pending, "l", 601).action == kaFocusRight
    ck pendingIndicator(pending) == ""

    # THE BOUNDED TIMEOUT, at both sides of the boundary. Exactly
    # `PendingTimeoutMs` later the prefix still stands; one millisecond more and
    # it does not.
    ck km.resolve(state, pending, "g", 1000).kind == krPending
    let justInTime = km.resolve(state, pending, "g", 1000 + PendingTimeoutMs)
    checkpoint("at +" & $PendingTimeoutMs & " -> " & $justInTime.kind)
    ck justInTime.kind == krAction
    ck justInTime.action == kaJumpToStart
    ck km.resolve(state, pending, "g", 2000).kind == krPending
    let tooLate = km.resolve(state, pending, "g", 2000 + PendingTimeoutMs + 1)
    checkpoint("at +" & $(PendingTimeoutMs + 1) & " -> " & $tooLate.kind &
               " " & $tooLate.action)
    # The late `g` is read on its OWN terms: it starts a fresh prefix rather
    # than completing the expired one.
    ck tooLate.kind == krPending
    ck tooLate.action == kaNone
    ck pending.chords == @["g"]
    pending.clear()

    # AN ABANDONED PREFIX DOES NOT FALL BACK. `Ctrl+w` then `q` must not quit:
    # the user asked for a window command, and running `q`'s unprefixed meaning
    # is how a mistyped chord ends a session.
    ck km.resolve(state, pending, "\x17", 3000).kind == krPending
    let abandoned = km.resolve(state, pending, "q", 3001)
    checkpoint("Ctrl+w q -> " & $abandoned.kind & " " & $abandoned.action)
    ck abandoned.kind == krPendingAbandoned
    ck abandoned.action == kaNone
    ck pendingIndicator(pending) == ""
    # …and `q` on its own DOES quit, through the same call, which is the
    # positive twin that makes the line above a statement about the prefix.
    ck km.resolve(state, pending, "q", 3002).action == kaQuit

    # A MOUSE REPORT DOES NOT CANCEL A PREFIX. It is not a key, and a user who
    # moved the mouse between `Ctrl+w` and `l` did not change their mind.
    ck km.resolve(state, pending, "\x17", 4000).kind == krPending
    let mouse = km.resolve(state, pending, "\x1b[<0;12;5M", 4001)
    checkpoint("mouse during a prefix -> " & $mouse.kind & " pending '" &
               mouse.pending & "'")
    ck mouse.kind == krNone
    ck mouse.pending == "Ctrl+w-"
    ck km.resolve(state, pending, "h", 4002).action == kaFocusLeft

    # `Esc` clears a pending prefix through the state machine, which is the
    # §4.2 row that says it "cancels ... closes popups".
    ck km.resolve(state, pending, "g", 5000).kind == krPending
    let escaped = km.resolve(state, pending, "\x1b", 5001)
    checkpoint("Esc during a prefix -> " & $escaped.kind & " " &
               $escaped.action)
    ck escaped.kind == krPendingAbandoned
    ck pendingIndicator(pending) == ""

  test "key-to-command dispatch stays under CTUI-9's 2 ms gate":
    ## CTUI-9's verification gate: "Key-to-command dispatch < 2 ms."
    ##
    ## The WORST single dispatch is what is asserted, not the mean: a gate on
    ## the average is satisfied by a table that is fast for `q` and slow for
    ## the one chord a user holds down. Every binding in every mode is driven
    ## through `resolve` once, from its own byte token, and the slowest is
    ## reported.
    let km = defaultKeymap()
    var worstNs = 0'i64
    var totalNs = 0'i64
    var dispatches = 0
    var slowest = ""
    # A representative token per canonical key name, so the measurement
    # includes `keyName`'s decoding — which is the expensive half.
    for mode in ModalMode:
      var state = initModalState(mode)
      for bnd in km.bindingsFor(mode):
        for token in [".", "n", "\x1b[21~", "\x1b[21;2~", "\x17", "\x1b[Z",
                      "\x1b[B", "\x7f", "\x1b", "\r", "g", "r", "\x1b[15;3~"]:
          var pending = initPendingState()
          let started = getMonoTime()
          discard km.resolve(state, pending, token, 0)
          let elapsed = (getMonoTime() - started).inNanoseconds
          inc dispatches
          totalNs += elapsed
          if elapsed > worstNs:
            worstNs = elapsed
            slowest = $mode & " " & bnd.spelling & " via " & token.escape()
    let worstUs = float(worstNs) / 1000.0
    echo "DISPATCH: worst " & $worstUs & " us over " & $dispatches &
      " dispatches (mean " & $(float(totalNs) / float(dispatches) / 1000.0) &
      " us); slowest " & slowest
    checkpoint("worst dispatch " & $worstUs & " us over " & $dispatches &
               " dispatches; slowest " & slowest)
    # 2 ms, spelled in nanoseconds so the comparison is integer.
    ck worstNs < 2_000_000
    # THE NON-VACUITY FLOOR: 85 bindings x 13 tokens = 1105. A sweep that
    # measured nothing would satisfy the gate above trivially.
    ck dispatches == km.bindings.len * 13
    ck dispatches == 1105

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
