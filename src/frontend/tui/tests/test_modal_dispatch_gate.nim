## test_modal_dispatch_gate.nim — CTUI-9's key-to-command dispatch budget.
##
## Tier 1, and deliberately NOT under `app/tests/`.
##
## CTUI-9's verification gate says "Key-to-command dispatch < 2 ms", and this
## file asserts it: every binding in every mode is driven through `resolve`
## from its own byte token, and the worst single dispatch — the fastest of
## `DispatchReps` repetitions per binding — must stay under 2 ms of THIS
## thread's CPU time.
##
## The gate used to be the last test of `app/tests/test_modal_transitions.nim`,
## and it moved here when it reached for `clock_gettime`. The CTUI-0 boundary
## scan (`tests/test_tui_facade_boundary.nim`) walks every `.nim` file under
## `app/`, tests included, and reddens on `std/posix` anywhere in that walk: a
## clock is a host capability, and `app/` may not hold one. This directory is
## outside the walk, and the `tui` lane still runs it (`ci/lib/test-lane-files.sh`
## globs `src/frontend/tui/tests/test_*.nim`). Its checks are unchanged: the same
## repetitions, the same 2 ms bound, the same 1,378-dispatch non-vacuity floor.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_modal_dispatch_gate.nim
##
## ## No mocks
##
## Nothing here opens a session, a terminal or a file. The keymap and the
## resolver are the real ones, driven in process.

import std/[posix, strutils, unittest]

import ../app/input/keymap
import ../app/input/modal_state
import ../app/tests/navigation_table

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 4

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc threadCpuNs(): int64 =
  ## CPU time THIS thread has used, in ns. A dispatch is pure computation on
  ## the calling thread, so this is its cost; time spent waiting for a core is
  ## not in it.
  var ts: Timespec
  discard clock_gettime(ClockId(CLOCK_THREAD_CPUTIME_ID), ts)
  ts.tv_sec.int64 * 1_000_000_000'i64 + ts.tv_nsec.int64

suite "CTUI-9: key-to-command dispatch stays under its 2 ms gate":

  test "key-to-command dispatch stays under CTUI-9's 2 ms gate":
    ## CTUI-9's verification gate: "Key-to-command dispatch < 2 ms."
    ##
    ## The WORST single dispatch is what is asserted, not the mean: a gate on
    ## the average is satisfied by a table that is fast for `q` and slow for
    ## the one chord a user holds down. Every binding in every mode is driven
    ## through `resolve` once, from its own byte token, and the slowest is
    ## reported.
    const DispatchReps = 5
    let table = navigationKeymap()
    var worstNs = 0'i64
    var totalNs = 0'i64
    var dispatches = 0
    var slowest = ""
    # A representative token per canonical key name, so the measurement
    # includes `keyName`'s decoding — which is the expensive half.
    const Tokens = [".", "n", "\x1b[21~", "\x1b[21;2~", "\x17", "\x1b[Z",
                    "\x1b[B", "\x7f", "\x1b", "\r", "g", "r", "\x1b[15;3~"]
    var coldWorstNs = 0'i64
    for mode in ModalMode:
      var state = initModalState(mode)
      # TWO GATES, ONE BUDGET. A router builds each layer's resolution trie on
      # the first key of a scope and keeps it (`editing_keymap.trieFor`'s
      # cache, one per router). So a fresh router's first key is that
      # construction plus a dispatch, paid once per scope per session, and
      # every later key is a dispatch alone. Until 2026-11-07 this loop timed
      # only fresh routers, so every reading was the first; now each is
      # measured and each must fit the 2 ms. On the CPU clock, fresh routers
      # only: 239 us mean, 425 us worst. This loop, 2026-11-04 and -05 at load
      # 66-98: warm 34-38 us mean, 86-100 us worst; first key 306-342 us.
      for token in Tokens:
        var first = int64.high
        for rep in 0 ..< DispatchReps:
          var fresh = newNavResolver()
          let started = threadCpuNs()
          discard fresh.resolve(state, token, 0)
          first = min(first, threadCpuNs() - started)
        coldWorstNs = max(coldWorstNs, first)
      # ONE WARM RESOLVER PER MODE, as the shipped window has one router for
      # its session; priming it is what makes the readings below dispatches.
      var km = newNavResolver()
      for token in Tokens:
        km.router.cancelPending()
        discard km.resolve(state, token, 0)
      for bnd in table.bindingsFor(mode):
        for token in Tokens:
          # THE DISPATCH'S COST, NOT THE SCHEDULER'S: the fastest of
          # `DispatchReps` identical dispatches, each from no pending prefix
          # (`cancelPending`, the state a fresh resolver starts in).
          # A dispatch that is slow is slow every time; one the kernel
          # descheduled is slow once. Measured 2026-10-30 on `agents` at load
          # 150: a single wall-clock reading put the worst at 10.3 ms (RED) on
          # a table whose every dispatch costs microseconds alone.
          var elapsed = int64.high
          for rep in 0 ..< DispatchReps:
            km.router.cancelPending()
            let started = threadCpuNs()
            discard km.resolve(state, token, 0)
            elapsed = min(elapsed, threadCpuNs() - started)
          inc dispatches
          totalNs += elapsed
          if elapsed > worstNs:
            worstNs = elapsed
            slowest = $mode & " " & bnd.spelling & " via " & token.escape()
    let worstUs = float(worstNs) / 1000.0
    echo "DISPATCH: worst " & $worstUs & " us over " & $dispatches &
      " dispatches (mean " & $(float(totalNs) / float(dispatches) / 1000.0) &
      " us); slowest " & slowest & "; a fresh router's first key " &
      $(float(coldWorstNs) / 1000.0) & " us at worst"
    checkpoint("worst dispatch " & $worstUs & " us over " & $dispatches &
               " dispatches; slowest " & slowest)
    # 2 ms, spelled in nanoseconds so the comparison is integer.
    #
    # ## REPAIRED A THIRD TIME 2026-11-07: the warm dispatch and a fresh router's
    # ## first key are measured apart (see the loop above) and both gated. No
    # ## CPU-clock reading is on record over 2 ms; the reds recorded here were
    # ## wall-clock readings.
    #
    # ## REPAIRED AGAIN 2026-11-03: the clock is the thread's CPU time
    # ## (`threadCpuNs`), not the wall. At load 55 the minimum of five
    # ## wall-clock readings was still 6.4 ms for one binding: every rep had
    # ## waited for a core. A dispatch is computation on this thread, so its
    # ## CPU time is the cost the gate names, and a wait is not in it.
    #
    # ## REPAIRED 2026-10-30: each binding's reading is now the MINIMUM of
    # ## `DispatchReps` dispatches, i.e. its cost rather than the scheduler's
    # ## worst moment — the "distribution rather than a maximum" remedy the
    # ## record below names. The history is kept because it is why.
    #
    # ## KNOWN WEAKNESS, RECORDED 2026-09-12 — THIS IS A §12 COIN FLIP AND IT
    # ## WILL BITE CI
    #
    # It measures an ABSOLUTE wall-clock duration of one function call on a
    # shared machine, and the thing it is supposed to detect — a dispatch table
    # that got slow — is three orders of magnitude away from the thing it
    # actually measures, which is whether this process was descheduled during
    # the slowest of 1,105 `getMonoTime()` intervals.
    #
    # Measured on one host, same tree, same binary:
    #
    # | how it was run | `worstNs` |
    # |---|---|
    # | alone | 19,500 (19.5 us) |
    # | beside other test lanes | **3,052,821 (3.05 ms) — RED** |
    #
    # 156x, from the scheduler. Verification-Harness-Traps §12 is this exact
    # shape: "what would this have said if the thing it names had not happened?"
    # — a dispatch table 100x slower than today's still passes at 1.95 ms, and a
    # correct one fails whenever a neighbour lane is compiling. It fails in the
    # direction that costs most, because a red gate on a correct product teaches
    # the next person to re-run it.
    #
    # IT IS RECORDED RATHER THAN FIXED because the fix is a different
    # milestone's decision, not a different constant: §12's remedy is to assert
    # a two-sided property against a signal, and the signal here has to be
    # established first — either a RELATIVE bound (this table against a
    # trivial-resolve baseline measured in the same process, so both sides carry
    # the same noise) or a per-dispatch budget derived from a distribution
    # rather than from a maximum. Raising the constant is NOT the fix: it widens
    # a gate that is already 100x too loose for its stated subject.
    #
    # PRE-EXISTING: this gate is CTUI-9's and predates PLAT-12, which touched
    # neither this file nor `resolve`.
    ck worstNs < 2_000_000
    ck coldWorstNs < 2_000_000
    # THE NON-VACUITY FLOOR: 107 bindings x 13 tokens = 1391. A sweep that
    # measured nothing would satisfy the gate above trivially.
    #
    # 1105 UNTIL PLAT-16 ADDED ONE BINDING (`Ctrl+F5`, the product-mode
    # toggle), 1118 until the session tabs added FOUR (`g t`, `g T`,
    # `Ctrl+Tab`, `Ctrl+Shift+Tab` — CodeTracer-TUI.md §3.3.1), 1170 until
    # PLAT-68 added THREE (`F6`, `Shift+F6`, `Ctrl+Shift+p`), 1209 until the
    # shared jump history added TWO (`Alt+Left`, `Alt+Right`), 1235 until
    # PLAT-70 added FIVE (the output panes' `z h`, `z l`, `z H`, `z L`, `0`),
    # 1300 until the table panes' Show Detail added TWO (`Shift+K` under the
    # Vim and Kakoune modes, Horizontal-Overflow.md §5.3), 1326 until PLAT-70
    # Part E added FOUR (`g o` and `Menu` in NORMAL and INSPECT), 1378 until
    # the editor's breakpoint column added ONE (`Shift+F9`, `ffec0f79af3`).
    # The literal
    # moves with `ExpectedBindingCount` in `test_keymap_no_conflicts.nim`,
    # and it is still written as a literal BESIDE the computed form rather
    # than replacing it: the line above is satisfied by any binding count,
    # and this one is what notices that the count changed.
    ck dispatches == table.bindings.len * 13
    ck dispatches == 1391

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
