## replay_ops.nim — PLAT-37. `--replay-ops`, parsed.
##
## ## Why the GPUI front-end can advance a recording from the command line
##
## `src/tests/visual/scenarios.json` pins six scenarios and five of them are
## STEPPED before capture, for a reason PLAT-23 measured rather than assumed:
## a Python program at line 1 genuinely has no locals, and `calc`'s pane
## census moves from `locals=0` to `locals=8` on that one change. **Two empty
## screens compare equal**, so a corpus of six frames all taken at the entry
## point is six copies of one picture wearing a multiplier —
## [[Verification-Harness-Traps §34]], which is the trap that has fired in
## every milestone of this campaign.
##
## The terminal front-end reaches those states by KEYSTROKE and the Electron
## front-end by clicking its own debug toolbar. The GPUI front-end can do
## neither: `PLAT21-VG1` (`gpui_dispatch_event` carries no payload, so no key
## can be delivered to a view at all) and `PLAT21-VG3` (focus is per WINDOW,
## so there is nothing for a key to be delivered TO) are measured defects in
## `isonim-gpui`, and PLAT-38 owns them. Until they close, this front-end has
## exactly one channel through which a user can ask for any state other than
## the entry point, and it is the command line.
##
## So this is a product affordance with a stated expiry rather than a test
## hook: when PLAT-38 lands, `--replay-ops` becomes the scriptable spelling of
## something a user can also do by hand, which is what `ct`'s other
## non-interactive flags already are.
##
## ## The vocabulary is CLOSED and this module is where it is spelled
##
## `ReplayOpKinds` below is the same five-member set `scenarios.json` declares
## in its own `operationKinds` array. **Two spellings of one vocabulary is
## Verification-Harness-Traps §30**, so the two are compared — in both
## directions, with the cardinality — by
## `src/frontend/gpui/tests/test_gpui_window_frame.nim`, which reads the JSON
## rather than transcribing it. An operation this parser accepts and the
## scenario file does not publish, or the reverse, fails there by name.

import std/strutils

type
  ReplayOp* = object
    ## One member of the vocabulary, with its multiplicity.
    kind*: string
    times*: int
      ## How many times to apply it. Always >= 1 for the four motions.
    line*: int
      ## Only meaningful for `setBreakpoint`: an offset into the editor's
      ## first drawn row. `-1` everywhere else.

  ReplayOpError* = object of CatchableError

const
  ReplayOpKinds* = ["stepIn", "next", "stepOut", "continueForward",
                    "setBreakpoint"]
    ## The closed set. `scenarios.json`'s `operationKinds` is the oracle.

  BreakpointOpKind* = "setBreakpoint"
    ## Named rather than repeated: it is the one member that carries a row
    ## instead of a count, and three call sites test for it.

func isReplayOpKind*(kind: string): bool =
  for k in ReplayOpKinds:
    if k == kind: return true
  false

proc parseReplayOps*(spec: string): seq[ReplayOp] =
  ## `stepIn=6,next=3` / `stepIn=6,setBreakpoint@1` -> the operations.
  ##
  ## **EVERY REJECTION RAISES AND NAMES WHAT IT SAW.** A parser that skipped
  ## an unrecognised term would accept `--replay-ops=steppIn=6` and draw the
  ## entry point, and a frame taken at the wrong state is worse than no frame:
  ## it is a picture nobody can tell from the right one. §4 — a parse that
  ## matched nothing satisfies everything written over it.
  result = @[]
  for rawTerm in spec.split(','):
    let term = rawTerm.strip()
    if term.len == 0:
      continue
    if '@' in term:
      let parts = term.split('@')
      if parts.len != 2:
        raise newException(ReplayOpError,
          "'" & term & "' is not '<operation>@<row>'")
      let kind = parts[0].strip()
      if kind != BreakpointOpKind:
        raise newException(ReplayOpError,
          "'@<row>' belongs to " & BreakpointOpKind & ", not to '" & kind & "'")
      var row = 0
      try: row = parseInt(parts[1].strip())
      except ValueError:
        raise newException(ReplayOpError,
          "'" & parts[1].strip() & "' is not a row offset")
      if row < 0:
        raise newException(ReplayOpError,
          "a breakpoint row offset cannot be negative: " & $row)
      result.add ReplayOp(kind: kind, times: 1, line: row)
      continue
    let parts = term.split('=')
    if parts.len != 2:
      raise newException(ReplayOpError,
        "'" & term & "' is not '<operation>=<count>'")
    let kind = parts[0].strip()
    if not isReplayOpKind(kind):
      raise newException(ReplayOpError,
        "'" & kind & "' is not one of " & ReplayOpKinds.join(", "))
    if kind == BreakpointOpKind:
      raise newException(ReplayOpError,
        BreakpointOpKind & " takes a row (" & BreakpointOpKind &
        "@<row>), not a count")
    var times = 0
    try: times = parseInt(parts[1].strip())
    except ValueError:
      raise newException(ReplayOpError,
        "'" & parts[1].strip() & "' is not a count")
    if times < 1:
      raise newException(ReplayOpError,
        "a count must be at least 1, got " & $times)
    result.add ReplayOp(kind: kind, times: times, line: -1)

func declaredOperations*(ops: seq[ReplayOp]): int =
  ## How many individual operations a spec asks for, counting multiplicity.
  ##
  ## The caller asserts the PERFORMED count against this EXACTLY, never "at
  ## least one" (§4b): a driver that stopped after the first step would
  ## satisfy "at least one" and paint a state three motions short of the one
  ## the scenario names.
  result = 0
  for op in ops:
    if op.kind == BreakpointOpKind:
      continue
    result += op.times

func breakpointRow*(ops: seq[ReplayOp]): int =
  ## The declared breakpoint row offset, or `-1` when there is none.
  result = -1
  for op in ops:
    if op.kind == BreakpointOpKind:
      result = op.line
