## test_image_capability.nim — PLAT-14 deliverables 4 and 5, Tier 1.
##
## `CodeTracer-TUI-Graphics.md` §3 is the section under test, and its rule is
## asymmetric: getting a tier wrong in the PESSIMISTIC direction costs fidelity,
## and getting it wrong in the OPTIMISTIC direction puts escape bytes on a
## user's screen. So this file is written the way `test_capability_resolution
## .nim` is written — a table over environment combinations, each row asserting
## the resolved tier AND the reason — plus two things that table cannot say.
##
## ## THE TWO THINGS A TABLE CANNOT SAY
##
##   1. **Adding uncertainty never improves the tier.** A table asserts the rows
##      somebody thought of. The invariant is swept over the whole cross product
##      of (advertisement x $KITTY_WINDOW_ID x multiplexer x passthrough x
##      probe x link x hint x tty), 1,728 environments, comparing each with the
##      same environment minus one piece of uncertainty. That is the "fails
##      toward the lower tier" claim as an assertion rather than as a sentence.
##      (**1,728 and not 1,344**: the number in this header, in
##      `tests/apps/app_image_probe.nim` and in
##      `tests/real_terminal/test_real_image_probe.nim` said 1,344 through the
##      landing pass while the assertion beside the loop computed
##      `2 * 2 * 3 * 3 * 4 * 2 * 3 * 2`. The assertion was right; three prose
##      copies of it were a stale quotation of the code, which is §16's shape
##      arriving in a doc comment.)
##
##      **THAT SWEEP IS OVER AUTOMATIC RESOLUTION ONLY** — every environment in
##      it is built with `initCapabilityFlags()`, so it says nothing at all
##      about `--image-tier`. The override path has a table of its own below,
##      and it exists because the pinned cases this file used to carry were the
##      three that already worked.
##   2. **The refusal reaches the WIRE.** A tier that resolved correctly and
##      then emitted a graphics escape anyway is a real failure mode, because
##      the decision and the emission are two pieces of code. So the last suite
##      builds the actual byte string for a refused environment and asserts no
##      graphics introducer is in it — with the POSITIVE TWIN first, through the
##      same predicate, on the permitted environment's bytes.
##      (Verification-Harness-Traps §7a: "the terminal did not draw garbage" is
##      a self-comparison wearing a negation unless the scanner is shown to see
##      the thing it is asked to refuse.)
##
## ## NO MOCKS, AND NONE IS JUSTIFIED
##
## Metacraft policy asks that every mock be justified in a test file's header.
## There is none. `resolveImageCapability` takes a `TerminalEnv`, an `ImageEnv`
## and a `GraphicsProbe`; all three are VALUES in the product's own types, and
## constructing one is what `host/image_probe.nim` does after reading the
## environment — the same door, reached without a terminal. The Tier-2 half,
## where a REAL pty answers or fails to answer a REAL probe, is
## `tests/real_terminal/test_real_image_probe.nim`; in-process tests can only
## ask the resolver what it decided.
##
## ## Templates, not procs, for anything that calls `check`
##
## `std/unittest`'s `check` assigns `testStatusIMPL`, which the `test` template
## injects into its own scope; inside a `proc` that symbol is invisible, `check`
## takes its `else` branch, and the case still prints `[OK]` while
## `programResult` goes to 1.

import std/[strutils, unittest]

import ../../../../common/terminal_graphics
import ../cli
import ../theme/capabilities
import ../theme/image_capability

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 2110

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

template ckEq(a, b: untyped) =
  inc countedAssertions
  check a == b

type
  Row = object
    name: string
    clause: string
    env: TerminalEnv
    ienv: ImageEnv
    flags: CapabilityFlags
    probe: GraphicsProbe
    hint: ImageHint
    tier: ImageTier
    protocol: ImageProtocol
    refusal: ProtocolRefusal
    wrapped: bool

proc kittyEnv(): TerminalEnv =
  initTerminalEnv(term = "xterm-kitty", colorterm = "truecolor",
                  lang = "en_US.UTF-8")

proc plainEnv(): TerminalEnv =
  initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                  lang = "en_US.UTF-8")

proc itermEnv(): TerminalEnv =
  initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                  termProgram = "iTerm.app", lang = "en_US.UTF-8")

proc kittyProbe(): GraphicsProbe =
  GraphicsProbe(attempted: true, answered: true, kitty: true)

proc fenceOnlyProbe(): GraphicsProbe =
  ## The path answered DA1 and did NOT answer the graphics query. This is
  ## exactly a tmux without passthrough, and it is the row §3 names.
  GraphicsProbe(attempted: true, answered: true, kitty: false)

proc silentProbe(): GraphicsProbe =
  GraphicsProbe(attempted: true, answered: false)

proc rowsOf(): seq[Row] =
  @[
    Row(name: "kitty, local, nothing in the way",
        clause: "§2.1 tier 0 on a terminal that advertises a protocol",
        env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihPhoto,
        tier: itProtocol, protocol: ipKitty, refusal: prNone, wrapped: false),

    Row(name: "kitty under tmux, passthrough unknown, nothing probed",
        clause: "§3 tmux requires explicit passthrough",
        env: kittyEnv(),
        ienv: initImageEnv(kittyWindowId = "1", tmux = "/tmp/tmux-1000/d,0"),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prMultiplexerUnproven, wrapped: false),

    Row(name: "kitty under tmux, passthrough ON, nothing probed",
        clause: "§3 detection must test the EFFECTIVE path",
        env: kittyEnv(),
        ienv: initImageEnv(kittyWindowId = "1", tmux = "/tmp/tmux-1000/d,0",
                           passthrough = ptOn),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prMultiplexerUnproven, wrapped: false),

    Row(name: "kitty under tmux, passthrough ON, only the DA1 fence came back",
        clause: "§3 a terminal running tmux without passthrough will accept " &
                "the escape and show nothing",
        env: kittyEnv(),
        ienv: initImageEnv(kittyWindowId = "1", tmux = "/tmp/tmux-1000/d,0",
                           passthrough = ptOn),
        flags: initCapabilityFlags(), probe: fenceOnlyProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prMultiplexerUnproven, wrapped: false),

    Row(name: "kitty under tmux, passthrough ON, the graphics reply came back",
        clause: "§3 the effective path was measured and it passes",
        env: kittyEnv(),
        ienv: initImageEnv(kittyWindowId = "1", tmux = "/tmp/tmux-1000/d,0",
                           passthrough = ptOn),
        flags: initCapabilityFlags(), probe: kittyProbe(), hint: ihPhoto,
        tier: itProtocol, protocol: ipKitty, refusal: prNone, wrapped: true),

    Row(name: "kitty under tmux, passthrough OFF, the reply came back anyway",
        clause: "§3 the option says no; a reply through a stale pane does not " &
                "outrank it",
        env: kittyEnv(),
        ienv: initImageEnv(kittyWindowId = "1", tmux = "/tmp/tmux-1000/d,0",
                           passthrough = ptOff),
        flags: initCapabilityFlags(), probe: kittyProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prMultiplexerUnproven, wrapped: false),

    Row(name: "kitty under screen",
        clause: "§3 screen generally will not pass graphics protocols at all",
        env: kittyEnv(),
        ienv: initImageEnv(kittyWindowId = "1", sty = "1234.pts-0.host"),
        flags: initCapabilityFlags(), probe: kittyProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prScreenNeverPasses, wrapped: false),

    Row(name: "TERM says screen but no multiplexer variable is set",
        clause: "§3 the ambiguous path resolves to the treatment that asks " &
                "least",
        env: initTerminalEnv(term = "screen-256color", colorterm = "truecolor",
                             lang = "en_US.UTF-8"),
        ienv: initImageEnv(kittyWindowId = "1"),
        flags: initCapabilityFlags(), probe: kittyProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prMultiplexerUnproven, wrapped: false),

    Row(name: "kitty over ssh, nothing in the way",
        clause: "§3 SSH is transparent to the escapes but not to the volume",
        env: kittyEnv(),
        ienv: initImageEnv(kittyWindowId = "1",
                           sshConnection = "10.0.0.1 5 10.0.0.2 22"),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihPhoto,
        tier: itProtocol, protocol: ipKitty, refusal: prNone, wrapped: false),

    Row(name: "a probe was sent down a live path and NOTHING came back",
        clause: "§3 a failed graphics probe must fall back silently",
        env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
        flags: initCapabilityFlags(), probe: silentProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prProbeUnanswered, wrapped: false),

    Row(name: "kitty advertised, nothing in the way, only the DA1 fence back",
        clause: "§3 the one protocol that CAN be measured was measured, and " &
                "it said no — with no multiplexer to hide behind",
        env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
        flags: initCapabilityFlags(), probe: fenceOnlyProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prGraphicsQuerySilent, wrapped: false),

    Row(name: "iTerm2 advertised, nothing in the way, only the DA1 fence back",
        clause: "§3 iTerm2's protocol has NO query, so a fence-only reply is " &
                "silence about a question nobody asked — the positive twin of " &
                "the row above, through the same probe value",
        env: itermEnv(),
        ienv: initImageEnv(termProgram = "iTerm.app"),
        flags: initCapabilityFlags(), probe: fenceOnlyProbe(), hint: ihPhoto,
        tier: itProtocol, protocol: ipITerm2, refusal: prNone, wrapped: false),

    Row(name: "iTerm2, local",
        clause: "§2.1 tier 0 on the other protocol this build emits",
        env: itermEnv(), ienv: initImageEnv(termProgram = "iTerm.app"),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihPhoto,
        tier: itProtocol, protocol: ipITerm2, refusal: prNone, wrapped: false),

    Row(name: "iTerm2 under tmux with passthrough on",
        clause: "§3 iTerm2's protocol has no query, so its path cannot be " &
                "measured",
        env: itermEnv(),
        ienv: initImageEnv(termProgram = "iTerm.app",
                           tmux = "/tmp/tmux-1000/d,0", passthrough = ptOn),
        flags: initCapabilityFlags(), probe: fenceOnlyProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prMultiplexerUnproven, wrapped: false),

    Row(name: "a plain truecolor terminal, photo hint",
        clause: "§2.1 tier 1 is the workhorse",
        env: plainEnv(), ienv: initImageEnv(),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prNoProtocolAdvertised, wrapped: false),

    Row(name: "a plain truecolor terminal, line-art hint",
        clause: "§8 decision 3: braille, gated behind the hint",
        env: plainEnv(), ienv: initImageEnv(),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihLineArt,
        tier: itBraille, protocol: ipNone,
        refusal: prNoProtocolAdvertised, wrapped: false),

    Row(name: "a plain truecolor terminal, mask hint",
        clause: "§8 decision 3: depth buffers and stencil masks",
        env: plainEnv(), ienv: initImageEnv(),
        flags: initCapabilityFlags(), probe: GraphicsProbe(), hint: ihMask,
        tier: itBraille, protocol: ipNone,
        refusal: prNoProtocolAdvertised, wrapped: false),

    Row(name: "TERM=dumb",
        clause: "§2.5 tier 6 exists for TERM=dumb",
        env: initTerminalEnv(term = "dumb", lang = "en_US.UTF-8"),
        ienv: initImageEnv(), flags: initCapabilityFlags(),
        probe: GraphicsProbe(), hint: ihLineArt,
        tier: itAscii, protocol: ipNone,
        refusal: prNoProtocolAdvertised, wrapped: false),

    Row(name: "not a terminal at all — a pipe or a CI log",
        clause: "§2.5 tier 6 exists for a CI log",
        env: initTerminalEnv(term = "xterm-kitty", colorterm = "truecolor",
                             lang = "en_US.UTF-8", isTty = false),
        ienv: initImageEnv(kittyWindowId = "1"),
        flags: initCapabilityFlags(), probe: kittyProbe(), hint: ihPhoto,
        tier: itAscii, protocol: ipNone,
        refusal: prNotATerminal, wrapped: false),

    Row(name: "a non-UTF-8 locale",
        clause: "§2.5 tier 6 honours the same aspect correction",
        env: initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                             lang = "en_US.ISO-8859-1"),
        ienv: initImageEnv(), flags: initCapabilityFlags(),
        probe: GraphicsProbe(), hint: ihPhoto,
        tier: itAscii, protocol: ipNone,
        refusal: prNoProtocolAdvertised, wrapped: false),

    Row(name: "--no-color on a terminal with no graphics protocol",
        clause: "§2.1 every cell tier above the ramp needs fg AND bg",
        env: plainEnv(), ienv: initImageEnv(),
        flags: initCapabilityFlags(noColor = true), probe: GraphicsProbe(),
        hint: ihPhoto, tier: itAscii, protocol: ipNone,
        refusal: prNoProtocolAdvertised, wrapped: false),

    Row(name: "--no-color on a KITTY terminal still draws real pixels",
        clause: "§2.1 tier 0 is not a cell rendering, so colour depth cannot " &
                "floor it",
        env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
        flags: initCapabilityFlags(noColor = true), probe: GraphicsProbe(),
        hint: ihPhoto, tier: itProtocol, protocol: ipKitty,
        refusal: prNone, wrapped: false),

    Row(name: "a Sixel-only terminal",
        clause: "this build has no Sixel encoder; the refusal is reported " &
                "where it can be read, not where it can only abort",
        env: initTerminalEnv(term = "mlterm", colorterm = "truecolor",
                             lang = "en_US.UTF-8"),
        ienv: initImageEnv(), flags: initCapabilityFlags(),
        probe: GraphicsProbe(), hint: ihPhoto,
        tier: itHalfBlock, protocol: ipNone,
        refusal: prSixelHasNoEncoder, wrapped: false)]

const
  ExpectedCaseCount = 23
    ## Asserted against `rowsOf().len`. A sweep whose size nobody checks can
    ## lose a row in a merge and stay green.
  ChecksPerCase = 4

proc resolveRow(row: Row): ImageCapability =
  let caps = resolveCapabilities(row.env, row.flags)
  resolveImageCapability(row.env, row.ienv, caps, row.flags, row.probe,
                         row.hint)

suite "PLAT-14 Tier 1: which tier, and why not a better one":

  test "every environment resolves to the documented tier AND reason":
    let rows = rowsOf()
    checkpoint("cases: " & $rows.len)
    ck rows.len == ExpectedCaseCount
    var compared = 0
    for row in rows:
      let cap = resolveRow(row)
      checkpoint(row.name & " [" & row.clause & "] -> " & describe(cap))
      ck cap.tier == row.tier
      ck cap.protocol == row.protocol
      ck cap.refusal == row.refusal
      ck cap.wrapForMultiplexer == row.wrapped
      compared += ChecksPerCase
    # THE COMPARISON COUNT AGAINST ITS PARAMETER. A loop that skipped a row —
    # or a `rowsOf` that returned early — leaves this number short, and the
    # assertion about `rows.len` cannot see that.
    checkpoint("comparisons: " & $compared)
    ck compared == ExpectedCaseCount * ChecksPerCase

  test "the refusals are not all one value, and tier 0 is really reached":
    # THE POSITIVE FLOOR (Verification-Harness-Traps §4b). A resolver that had
    # lost the whole feature would refuse every row, and a table whose rows all
    # expected a refusal would be satisfied by it. So the sweep's own outcomes
    # are counted: some rows reach tier 0, and the refusals span more than one
    # reason.
    var reachedTier0 = 0
    var refusals: seq[ProtocolRefusal] = @[]
    for row in rowsOf():
      let cap = resolveRow(row)
      if cap.tier == itProtocol: inc reachedTier0
      if cap.refusal != prNone and cap.refusal notin refusals:
        refusals.add cap.refusal
    checkpoint("rows reaching tier 0: " & $reachedTier0)
    checkpoint("distinct refusals: " & $refusals)
    ck reachedTier0 == 6
    ck refusals.len == 7
    ck prNotATerminal in refusals
    ck prMultiplexerUnproven in refusals
    ck prScreenNeverPasses in refusals
    ck prProbeUnanswered in refusals
    ck prGraphicsQuerySilent in refusals
    ck prNoProtocolAdvertised in refusals
    ck prSixelHasNoEncoder in refusals

  test "automatic selection never leaves AutomaticTiers":
    # `tiers.AutomaticTiers` is the CLAIM; this is the sweep that holds it.
    # Quadrants, sextants and octants need a font nothing can detect, so a
    # resolver that reached one automatically would be drawing tofu.
    var checked = 0
    for row in rowsOf():
      let cap = resolveRow(row)
      ck cap.tier in AutomaticTiers
      # AND THE RUNG THE TIER IS CHOSEN FROM NEVER RISES EITHER. This is the
      # assertion the tier check alone cannot make: `resolveRepertoire` could
      # return `urOctants16` on every terminal and no tier would move today,
      # because `hintedTier` only ever asks for half blocks or braille — so the
      # claim "sextants and octants need a font nothing can detect" would be
      # true of the OUTCOME and false of the VALUE, and the next hint added
      # would reach a rung nothing measured. A mutation raising the rung
      # survived a 14-case suite until this line existed.
      ck cap.repertoire <= urWide3_2
      inc checked
    ck checked == ExpectedCaseCount

suite "PLAT-14: adding uncertainty never improves the tier":

  test "the whole cross product, each compared with its more certain twin":
    # THE INVARIANT, swept rather than sampled. For every environment, removing
    # a piece of uncertainty — the multiplexer, the unanswered probe, the
    # non-tty — may only make the tier the SAME or BETTER; adding it back may
    # only make it the same or worse. `isWeakerOrEqual` is `tiers`' own
    # predicate, so the rule and this control call the same function.
    var compared = 0
    var strictlyWorse = 0
    for advertised in ["xterm-kitty", "xterm-256color"]:
      for kittyId in ["1", ""]:
        for mux in [initImageEnv(), initImageEnv(tmux = "/tmp/t,0"),
                    initImageEnv(sty = "1.pts-0.h")]:
          for pass in [ptUnknown, ptOff, ptOn]:
            for probe in [GraphicsProbe(), silentProbe(), fenceOnlyProbe(),
                          kittyProbe()]:
              for ssh in ["", "10.0.0.1 5 10.0.0.2 22"]:
                for hint in [ihPhoto, ihLineArt, ihMask]:
                  for isTty in [true, false]:
                    let env = initTerminalEnv(
                      term = advertised, colorterm = "truecolor",
                      lang = "en_US.UTF-8", isTty = isTty)
                    var ienv = mux
                    ienv.kittyWindowId = kittyId
                    ienv.passthrough = pass
                    ienv.sshConnection = ssh
                    let caps = resolveCapabilities(env, initCapabilityFlags())
                    let uncertain = resolveImageCapability(
                      env, ienv, caps, initCapabilityFlags(), probe, hint)

                    # The SAME environment with the multiplexer removed. That
                    # is strictly less uncertainty about the effective path.
                    var certainIenv = ienv
                    certainIenv.tmux = ""
                    certainIenv.sty = ""
                    let certain = resolveImageCapability(
                      env, certainIenv, caps, initCapabilityFlags(), probe,
                      hint)
                    ck isWeakerOrEqual(uncertain.tier, certain.tier)
                    if ord(uncertain.tier) > ord(certain.tier):
                      inc strictlyWorse
                    inc compared
    checkpoint("environments swept: " & $compared)
    checkpoint("pairs where the uncertain one is STRICTLY worse: " &
               $strictlyWorse)
    ck compared == 2 * 2 * 3 * 3 * 4 * 2 * 3 * 2
    # THE NON-VACUITY FLOOR. `isWeakerOrEqual` is reflexive, so an environment
    # where the multiplexer changed nothing satisfies the invariant trivially.
    # A sweep in which NO pair was strictly worse would be asserting nothing,
    # which is exactly the shape §7a names.
    ck strictlyWorse > 0
    checkpoint("strictly worse pairs: " & $strictlyWorse)

  test "an unanswered probe is never better than no probe at all":
    # The second axis of the same invariant, on its own so a failure names
    # which axis broke.
    var compared = 0
    var strictlyWorse = 0
    for term in ["xterm-kitty", "xterm-256color", "mlterm"]:
      for kittyId in ["1", ""]:
        let env = initTerminalEnv(term = term, colorterm = "truecolor",
                                  lang = "en_US.UTF-8")
        let ienv = initImageEnv(kittyWindowId = kittyId)
        let caps = resolveCapabilities(env, initCapabilityFlags())
        let unmeasured = resolveImageCapability(
          env, ienv, caps, initCapabilityFlags(), GraphicsProbe(), ihPhoto)
        let measuredSilent = resolveImageCapability(
          env, ienv, caps, initCapabilityFlags(), silentProbe(), ihPhoto)
        ck isWeakerOrEqual(measuredSilent.tier, unmeasured.tier)
        if ord(measuredSilent.tier) > ord(unmeasured.tier):
          inc strictlyWorse
        inc compared
    ck compared == 6
    ck strictlyWorse == 4

suite "PLAT-14 §2.2: an explicit flag beats a probe":

  test "--image-tier reaches the three tiers detection never picks":
    var pinned = 0
    for tier in [itQuadrant, itSextant, itOctant]:
      let flags = initCapabilityFlags(imageTier = tier, imageTierPinned = true)
      let env = plainEnv()
      let caps = resolveCapabilities(env, flags)
      let cap = resolveImageCapability(env, initImageEnv(), caps, flags,
                                       GraphicsProbe(), ihPhoto)
      ck cap.tier == tier
      ck cap.tierFrom == csFlag
      ck tier notin AutomaticTiers
      inc pinned
    ck pinned == 3

  test "a pinned tier 0 wins over a refusal, and the refusal is still SAID":
    # §2.2's override, and the honesty rule beside it. A user inside `screen`
    # who pins tier 0 gets tier 0 — and the value still carries the reason the
    # automatic answer refused, so a pane title can say so.
    let flags = initCapabilityFlags(imageTier = itProtocol,
                                    imageTierPinned = true)
    let env = kittyEnv()
    let ienv = initImageEnv(kittyWindowId = "1", sty = "1234.pts-0.host")
    let caps = resolveCapabilities(env, flags)
    let cap = resolveImageCapability(env, ienv, caps, flags, GraphicsProbe(),
                                     ihPhoto)
    ck cap.tier == itProtocol
    ck cap.tierFrom == csFlag
    ck cap.protocol == ipKitty
    ck cap.refusal == prScreenNeverPasses
    ck cap.overriddenRefusal
    ck describe(cap).contains("refused-tier0=screen-never-passes")
    ck describe(cap).contains("overridden by --image-tier")
    # THE FALSIFYING TWIN: without the flag the same environment refuses, so
    # the override is doing the work and not the environment.
    let unpinned = resolveImageCapability(env, ienv, caps,
                                          initCapabilityFlags(),
                                          GraphicsProbe(), ihPhoto)
    ck unpinned.tier != itProtocol
    ck not unpinned.overriddenRefusal

  test "a pinned tier 0 over EVERY advertisement and EVERY probe outcome":
    # THE TABLE THE OVERRIDE PATH DID NOT HAVE, and its absence is what let a
    # guard written against `probe.answered` — the DA1 FENCE, which
    # `GraphicsProbe.answered`'s own doc says every terminal and every
    # multiplexer answers — sit in the tree through a landing pass. Every
    # pinned case this file used to carry was one of the three that already
    # worked; the whole cross product is four advertisements x four probe
    # outcomes, and the interesting rows are the ones where the probe answered
    # the FENCE and nothing else.
    #
    # Read the `pinnable` column as the claim: `--image-tier=protocol` says
    # "use tier 0 on this path" and there is no spelling of it that says "use
    # Kitty", so the flag can beat every refusal ABOUT THE PATH and cannot
    # supply a protocol. When nothing this build can emit has been named, the
    # pin loses — and `tierFrom` stays `csFlag`, so a reader can see the flag
    # was read and could not be honoured.
    type PinRow = object
      name: string
      env: TerminalEnv
      ienv: ImageEnv
      probe: GraphicsProbe
      tier: ImageTier
      protocol: ImageProtocol
      refusal: ProtocolRefusal
      overridden: bool
    let sixelEnv = initTerminalEnv(term = "mlterm", colorterm = "truecolor",
                                   lang = "en_US.UTF-8")
    let rows = @[
      # -- Kitty advertised: the flag is honoured on every probe outcome,
      #    because the ADVERTISEMENT named a protocol this build can emit.
      PinRow(name: "kitty advertised, nothing probed",
             env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
             probe: GraphicsProbe(), tier: itProtocol, protocol: ipKitty,
             refusal: prNone, overridden: false),
      PinRow(name: "kitty advertised, NOTHING came back",
             env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
             probe: silentProbe(), tier: itProtocol, protocol: ipKitty,
             refusal: prProbeUnanswered, overridden: true),
      PinRow(name: "kitty advertised, only the DA1 fence came back",
             env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
             probe: fenceOnlyProbe(), tier: itProtocol, protocol: ipKitty,
             refusal: prGraphicsQuerySilent, overridden: true),
      PinRow(name: "kitty advertised, the graphics reply came back",
             env: kittyEnv(), ienv: initImageEnv(kittyWindowId = "1"),
             probe: kittyProbe(), tier: itProtocol, protocol: ipKitty,
             refusal: prNone, overridden: false),

      # -- iTerm2 advertised: same, and a fence-only reply is NOT a refusal
      #    here, because iTerm2's protocol has no query to be silent about.
      PinRow(name: "iTerm2 advertised, nothing probed",
             env: itermEnv(), ienv: initImageEnv(termProgram = "iTerm.app"),
             probe: GraphicsProbe(), tier: itProtocol, protocol: ipITerm2,
             refusal: prNone, overridden: false),
      PinRow(name: "iTerm2 advertised, NOTHING came back",
             env: itermEnv(), ienv: initImageEnv(termProgram = "iTerm.app"),
             probe: silentProbe(), tier: itProtocol, protocol: ipITerm2,
             refusal: prProbeUnanswered, overridden: true),
      PinRow(name: "iTerm2 advertised, only the DA1 fence came back",
             env: itermEnv(), ienv: initImageEnv(termProgram = "iTerm.app"),
             probe: fenceOnlyProbe(), tier: itProtocol, protocol: ipITerm2,
             refusal: prNone, overridden: false),
      PinRow(name: "iTerm2 advertised, a KITTY reply came back",
             env: itermEnv(), ienv: initImageEnv(termProgram = "iTerm.app"),
             probe: kittyProbe(), tier: itProtocol, protocol: ipITerm2,
             refusal: prNone, overridden: false),

      # -- Sixel advertised: THE ROW THAT USED TO RAISE. The pin reached past
      #    `prSixelHasNoEncoder` and handed the caller `ipSixel`, which
      #    `emit.emitProtocolImage` raises for — a picture turned into an
      #    exception by a flag. It refuses now, and says why.
      PinRow(name: "sixel advertised, nothing probed",
             env: sixelEnv, ienv: initImageEnv(),
             probe: GraphicsProbe(), tier: itHalfBlock, protocol: ipNone,
             refusal: prSixelHasNoEncoder, overridden: false),
      PinRow(name: "sixel advertised, NOTHING came back",
             env: sixelEnv, ienv: initImageEnv(),
             probe: silentProbe(), tier: itHalfBlock, protocol: ipNone,
             refusal: prProbeUnanswered, overridden: false),
      PinRow(name: "sixel advertised, only the DA1 fence came back",
             env: sixelEnv, ienv: initImageEnv(),
             probe: fenceOnlyProbe(), tier: itHalfBlock, protocol: ipNone,
             refusal: prSixelHasNoEncoder, overridden: false),
      # …and a MEASUREMENT outranks an advertisement this build cannot use: a
      # terminal calling itself mlterm that answers the Kitty query has named
      # a protocol, by reply rather than by name. This is the positive twin
      # that keeps the three rows above from being "the pin always loses on
      # mlterm".
      PinRow(name: "sixel advertised, a KITTY reply came back",
             env: sixelEnv, ienv: initImageEnv(),
             probe: kittyProbe(), tier: itProtocol, protocol: ipKitty,
             refusal: prSixelHasNoEncoder, overridden: true),

      # -- NOTHING advertised: the case the guard exists for, and the two rows
      #    that used to differ only by a fence answering.
      PinRow(name: "nothing advertised, nothing probed",
             env: plainEnv(), ienv: initImageEnv(),
             probe: GraphicsProbe(), tier: itHalfBlock, protocol: ipNone,
             refusal: prNoProtocolAdvertised, overridden: false),
      PinRow(name: "nothing advertised, NOTHING came back",
             env: plainEnv(), ienv: initImageEnv(),
             probe: silentProbe(), tier: itHalfBlock, protocol: ipNone,
             refusal: prProbeUnanswered, overridden: false),
      # THE ROW THE DEFECT WAS: a DA1 answer and no graphics reply used to
      # resolve to `protocol=ipITerm2` on a terminal that named no protocol at
      # all, and emitted 33 bytes of OSC 1337 at it.
      PinRow(name: "nothing advertised, only the DA1 fence came back",
             env: plainEnv(), ienv: initImageEnv(),
             probe: fenceOnlyProbe(), tier: itHalfBlock, protocol: ipNone,
             refusal: prNoProtocolAdvertised, overridden: false),
      PinRow(name: "nothing advertised, a KITTY reply came back",
             env: plainEnv(), ienv: initImageEnv(),
             probe: kittyProbe(), tier: itProtocol, protocol: ipKitty,
             refusal: prNone, overridden: false)]

    const ExpectedPinRows = 16
    const ChecksPerPinRow = 5
    ck rows.len == ExpectedPinRows
    var compared = 0
    var honoured = 0
    var refused = 0
    for row in rows:
      let flags = initCapabilityFlags(imageTier = itProtocol,
                                      imageTierPinned = true)
      let caps = resolveCapabilities(row.env, flags)
      let cap = resolveImageCapability(row.env, row.ienv, caps, flags,
                                       row.probe, ihPhoto)
      checkpoint("--image-tier=protocol + " & row.name & " -> " & describe(cap))
      ck cap.tier == row.tier
      ck cap.protocol == row.protocol
      ck cap.refusal == row.refusal
      ck cap.overriddenRefusal == row.overridden
      # THE FLAG WAS READ IN BOTH OUTCOMES. A pin that loses still reports
      # `csFlag`, because "the flag was not read" and "the flag was read and
      # could not be honoured" are different facts and only one of them is a
      # bug in the parser.
      ck cap.tierFrom == csFlag
      if cap.tier == itProtocol: inc honoured else: inc refused
      compared += ChecksPerPinRow
    checkpoint("pinned rows honoured: " & $honoured & ", refused: " & $refused)
    ck compared == ExpectedPinRows * ChecksPerPinRow
    # THE NON-VACUITY FLOOR ON BOTH SIDES (§4b). A resolver that honoured every
    # pin and one that refused every pin would each satisfy a table whose rows
    # all agreed with it, so the two outcomes are counted and both asserted.
    ck honoured == 10
    ck refused == 6
    # …AND NO PROTOCOL THIS BUILD CANNOT EMIT IS EVER NAMED, over the whole
    # table, through the product's own set. `emit.emitProtocolImage` RAISES for
    # `ipSixel`, so this is the assertion that "the picture is not an exception"
    # rather than a restatement of the rows above.
    var namedProtocols = 0
    for row in rows:
      let flags = initCapabilityFlags(imageTier = itProtocol,
                                      imageTierPinned = true)
      let cap = resolveImageCapability(
        row.env, row.ienv, resolveCapabilities(row.env, flags), flags,
        row.probe, ihPhoto)
      ck cap.protocol == ipNone or cap.protocol in EmittableProtocols
      if cap.protocol != ipNone: inc namedProtocols
    ck namedProtocols == honoured

  test "a pinned tier 0 with NO protocol anywhere is the one case it loses":
    # Not a precedence rule: there is no protocol to emit, so honouring it
    # would mean picking one by guess. The refusal is reported and the tier
    # falls to the automatic cell answer, with the SOURCE still recorded as the
    # flag so a reader can see the flag was read.
    let flags = initCapabilityFlags(imageTier = itProtocol,
                                    imageTierPinned = true)
    let env = plainEnv()
    let caps = resolveCapabilities(env, flags)
    let cap = resolveImageCapability(env, initImageEnv(), caps, flags,
                                     GraphicsProbe(), ihPhoto)
    ck cap.tier == itHalfBlock
    ck cap.protocol == ipNone
    ck cap.refusal == prNoProtocolAdvertised
    ck not cap.overriddenRefusal

  test "the CLI parses --image-tier into the flag, and refuses an unknown name":
    # THROUGH `parseTuiCommand`, WHICH IS THE POINT. The case that used to
    # stand here was named this and called neither the CLI nor any refusal: it
    # asserted `initCapabilityFlags()`'s defaults and a `parseTierName`
    # round-trip, so DELETING THE ENTIRE `--image-tier` BRANCH FROM `cli.nim`
    # left both suites green, and so did deleting its usage-error arm (after
    # which an unknown name silently pins `itAscii`, the WEAKEST tier, on a
    # user who asked for the strongest). Both are arms in the PLAT-14 harness
    # now. `test_capability_resolution.nim`'s CTUI-14 sibling had this right
    # already — it asserts the VALUE the parser produced, not the absence of an
    # error — which is the shape copied here.
    ck not initCapabilityFlags().imageTierPinned
    ck initCapabilityFlags().imageTier == itAscii
    # UNPINNED IS THE DEFAULT AT THE PARSER TOO, not only in the constructor:
    # a trace path alone must leave the image axis exactly where
    # `initCapabilityFlags` leaves it.
    let bare = parseTuiCommand(["/tmp"])
    ck bare.kind == tckOpenTrace
    ck not bare.flags.imageTierPinned
    ck bare.flags.imageTier == initCapabilityFlags().imageTier
    ck bare.flags == initCapabilityFlags()

    # EVERY PUBLISHED NAME REACHES ITS OWN TIER. The loop is over `ImageTier`
    # itself rather than over a list somebody wrote out, so a tier added to
    # §2.1's table and not to the parser fails here.
    var pinnedByName = 0
    for tier in ImageTier:
      let cmd = parseTuiCommand(["--image-tier=" & tierName(tier), "/tmp"])
      checkpoint("--image-tier=" & tierName(tier) & " -> " & $cmd.kind)
      ck cmd.kind == tckOpenTrace
      ck cmd.flags.imageTierPinned
      ck cmd.flags.imageTier == tier
      ck cmd.tracePath == "/tmp"
      inc pinnedByName
    ck pinnedByName == 7
    ck pinnedByName == ord(high(ImageTier)) + 1

    # AN UNKNOWN NAME IS A USAGE ERROR, and the flag is NOT pinned by it.
    # `parseTierName` fails to `itAscii` deliberately (a parse failure must not
    # hand a caller tier 0, which is `ImageTier`'s zero value), so an
    # implementation that dropped the refusal would pin the WEAKEST tier and
    # never say a word — which is why the second assertion is here and not
    # merely the first.
    let bad = parseTuiCommand(["--image-tier=octarine", "/tmp"])
    checkpoint("--image-tier=octarine -> " & $bad.kind & ": " &
               (if bad.kind == tckUsageError: bad.message else: ""))
    ck bad.kind == tckUsageError
    ck bad.kind != tckOpenTrace
    ck bad.message.contains("octarine")
    ck bad.message.contains("unknown image tier")
    # …and the message names the alternatives, which is the difference between
    # a refusal and a wall.
    ck bad.message.contains(tierName(itProtocol))
    ck bad.message.contains(tierName(itAscii))
    # An EMPTY value is refused the same way rather than silently meaning
    # "default": `--image-tier=` is a user who meant something.
    let empty = parseTuiCommand(["--image-tier=", "/tmp"])
    ck empty.kind == tckUsageError

    # AND THE ROUND TRIP the old case asserted, kept — it is a real property of
    # `tiers`, it is just not a property of the CLI.
    var parsed = 0
    for tier in ImageTier:
      let (ok, back) = parseTierName(tierName(tier))
      ck ok
      ck back == tier
      inc parsed
    ck parsed == 7

suite "PLAT-14 §3: the link budget, and the tier that follows from it":

  test "an SSH session carries a budget and a local one does not":
    let env = kittyEnv()
    let caps = resolveCapabilities(env, initCapabilityFlags())
    let remote = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1",
                        sshTty = "/dev/pts/3"), caps, initCapabilityFlags())
    ck remote.overSsh
    ck remote.linkBudget == MaxLinkImageBytes
    let local = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1"), caps, initCapabilityFlags())
    ck not local.overSsh
    ck local.linkBudget == 0
    ck withinLinkBudget(local, 100_000_000)
    ck not withinLinkBudget(remote, 100_000_000)
    ck withinLinkBudget(remote, 1024)

  test "an oversized tier-0 emission demotes, measured in EMITTED bytes":
    # The unit hazard, at the decision rather than at the emitter: the number
    # `demoteForPayload` compares is the length of the string that would be
    # written. `emit_test.nim` asserts the same rule at the emitter; this
    # asserts that the DECISION uses it.
    let env = kittyEnv()
    let caps = resolveCapabilities(env, initCapabilityFlags())
    let remote = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1", sshTty = "/dev/pts/3"), caps,
      initCapabilityFlags())
    ck remote.tier == itProtocol

    var payload = newSeq[byte](200_000)
    for i in 0 ..< payload.len: payload[i] = byte(i mod 251)
    let emission = emitProtocolImage(ipKitty, payload, 1, 1, 0, 0, false)
    ck payload.len < MaxLinkImageBytes
    ck emission.emittedBytes > MaxLinkImageBytes
    let demoted = demoteForPayload(remote, emission.emittedBytes)
    ck demoted.tier == itHalfBlock
    ck demoted.protocol == ipNone
    ck demoted.refusal == prPayloadExceedsLink
    # THE POSITIVE TWIN: a small image is NOT demoted, so the rule is about the
    # size. And a placement of the same big image is small, which is why §3's
    # placement rule is what makes a scrub affordable.
    let small = emitProtocolImage(ipKitty, payload[0 ..< 64], 1, 1, 0, 0, false)
    ck demoteForPayload(remote, small.emittedBytes).tier == itProtocol
    let placement = emitProtocolImage(ipKitty, payload, 1, 1, 0, 0, true)
    ck demoteForPayload(remote, placement.emittedBytes).tier == itProtocol
    # A LOCAL session is never demoted by size at all.
    let local = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1"), caps, initCapabilityFlags())
    ck demoteForPayload(local, emission.emittedBytes).tier == itProtocol
    # §2.2: AN EXPLICITLY PINNED TIER 0 IS NOT DEMOTED EITHER, and this is the
    # only evidence for that line. It is the SAME environment as `remote` — the
    # same terminal, the same link, the same budget, the same oversized
    # emission — differing in one thing, the pin, so what is being asserted is
    # the flag's precedence and not a second rule about size. `remote` demoting
    # four assertions above is the positive twin through the same function
    # (Verification-Harness-Traps §4a).
    let pinned = initCapabilityFlags(imageTier = itProtocol,
                                     imageTierPinned = true)
    let pinnedRemote = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1", sshTty = "/dev/pts/3"),
      resolveCapabilities(env, pinned), pinned)
    ck pinnedRemote.tier == itProtocol
    ck pinnedRemote.tierFrom == csFlag
    ck pinnedRemote.linkBudget == MaxLinkImageBytes
    ck not withinLinkBudget(pinnedRemote, emission.emittedBytes)
    let notDemoted = demoteForPayload(pinnedRemote, emission.emittedBytes)
    ck notDemoted.tier == itProtocol
    ck notDemoted.protocol == ipKitty
    ck notDemoted.refusal != prPayloadExceedsLink
    # …and the unpinned twin, built from the same environment, IS demoted by
    # the same number — so `tierFrom` is what decided and not the size.
    ck remote.tierFrom != csFlag
    ck demoteForPayload(remote, emission.emittedBytes).tier != itProtocol
    # …and demotion only ever demotes: a cell tier handed a huge number comes
    # back unchanged rather than being "demoted" into something else.
    let cells = resolveImageCapability(plainEnv(), initImageEnv(),
                                       resolveCapabilities(plainEnv(),
                                                           initCapabilityFlags()),
                                       initCapabilityFlags())
    ck demoteForPayload(cells, 10_000_000).tier == cells.tier

suite "PLAT-14 §3: the refusal reaches the wire":

  test "a refused environment emits NO graphics escape, and a permitted one does":
    # Verification-Harness-Traps §7a. THE POSITIVE CONTROL COMES FIRST and uses
    # the same predicate: `containsGraphicsEscape` is shown to see a graphics
    # introducer in the permitted environment's bytes before it is asked to
    # find none in the refused environment's.
    let env = kittyEnv()
    let caps = resolveCapabilities(env, initCapabilityFlags())

    # PERMITTED: kitty, local, nothing in the way.
    let permitted = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1"), caps, initCapabilityFlags())
    ck permitted.tier == itProtocol
    let permittedBytes = emitProtocolImage(
      permitted.protocol, [1'u8, 2'u8, 3'u8], 5, 1, 4, 2, false,
      permitted.wrapForMultiplexer).bytes
    ck containsGraphicsEscape(permittedBytes)

    # REFUSED: the same terminal inside screen. The rendering is a cell grid,
    # and the bytes carry SGR and glyphs and no graphics introducer.
    let refused = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1", sty = "1234.pts-0.host"), caps,
      initCapabilityFlags())
    ck refused.tier != itProtocol
    var px = newSeq[byte](2 * 2 * 4)
    for i in 0 ..< 4:
      px[i * 4] = byte(40 * i)
      px[i * 4 + 1] = 90'u8
      px[i * 4 + 2] = 10'u8
      px[i * 4 + 3] = 255'u8
    let raster = initRgbaImage(2, 2, px)
    let fit = fitToCells(2, 2, DefaultCellAspect, 2, 2)
    let refusedBytes = emitCellGrid(
      renderCells(raster, refused.tier, fit), cwTrueColor)
    ck not containsGraphicsEscape(refusedBytes)
    # …and the refused rendering is not EMPTY, which is the other half of §2.6:
    # a lower tier shows the same content at lower fidelity, it does not show
    # nothing.
    ck refusedBytes.len > 0
    ck refusedBytes.contains("\x1b[38;2;")

  test "describe names the tier, the source and the reason":
    let env = kittyEnv()
    let caps = resolveCapabilities(env, initCapabilityFlags())
    let cap = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1", tmux = "/tmp/t,0"), caps,
      initCapabilityFlags())
    let text = describe(cap)
    checkpoint(text)
    ck text.contains("image-tier=half-block(environment)")
    ck text.contains("advertised=ipKitty")
    ck text.contains("mux=tmux")
    ck text.contains("refused-tier0=multiplexer-unproven")
    # …and the permitted spelling differs, so the two are distinguishable in
    # the text rather than both reading the same.
    let ok = resolveImageCapability(
      env, initImageEnv(kittyWindowId = "1", tmux = "/tmp/t,0",
                        passthrough = ptOn), caps, initCapabilityFlags(),
      kittyProbe())
    let okText = describe(ok)
    checkpoint(okText)
    ck okText.contains("image-tier=protocol(environment)")
    ck okText.contains("tmux-passthrough=wrapped")
    ck not okText.contains("refused-tier0")

suite "PLAT-14: the tally":

  test "every assertion in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    ck countedAssertions == ExpectedAssertions
