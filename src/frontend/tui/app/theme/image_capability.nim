## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/image_capability.nim — PLAT-14 deliverables 4 and 5. WHICH TIER,
## AND WHY NOT A BETTER ONE.
##
## `CodeTracer-TUI-Graphics.md` §3 is the section this module exists for, and
## its three sentences are the whole specification:
##
##   * *"Detection must test the **effective** path, not the outermost
##     terminal's advertisement — a Kitty-capable terminal running tmux without
##     passthrough will accept the escape and show nothing."*
##   * *"**screen** generally will not pass graphics protocols at all."*
##   * *"**A failed graphics probe must fall back silently and correctly**,
##     never leave escape bytes on screen. The failure mode of a bad probe is
##     garbage in the user's terminal, which is worse than a low-fidelity
##     picture."*
##
## ## THE SHAPE IS `app/theme/capabilities.nim`'S, DELIBERATELY
##
## That module already establishes the split this one needs: the DECISION is a
## pure function of a value, the READING of the process's environment is a host
## act (`host/capabilities.readTerminalEnv`), and every axis records the
## `CapabilitySource` that decided it so "why is my picture not a picture?" is
## answerable from the value. This module extends the same pattern with an
## image axis rather than starting a second capability model beside it:
## `TerminalCapabilities` is an INPUT here (colour depth and border mode both
## gate cell tiers), `CapabilityFlags` carries `--image-tier`, and
## `ImageCapability` is the same shape of answer.
##
## Nothing here does I/O of any kind: no `getEnv`, no file, no fd. The probe is
## an INPUT (`GraphicsProbe`), performed by `host/image_probe.nim`, which is
## what lets the whole table below be swept in a lane with no terminal in it
## AND what makes the fail-low rule assertable — the interesting case is the
## one where the probe did not answer, and a module that performed its own
## probe could not be handed one.
##
## ## HOW DETECTION FAILS TOWARD THE SAFER TIER, AS ONE SENTENCE
##
## `ord(ImageTier)` is §2.1's own tier number, so a LARGER ordinal is a WEAKER
## rendering, and every rule below either leaves the tier alone or replaces it
## with `tiers.weakerOf(current, safer)`. There is no path in this module that
## makes a tier stronger in response to an unknown — **and that sentence was
## FALSE for the override until 2026-09-14; see the last section of this
## header, which is where the reader who is about to trust it should go.** The
## consequence is the invariant `app/tests/test_image_capability.nim` asserts
## over the whole environment cross product rather than over rows somebody
## chose:
##
##     adding uncertainty never improves the tier
##
## — spelled `isWeakerOrEqual(resolve(moreUncertain), resolve(less))`, swept
## over every (advertisement x $KITTY_WINDOW_ID x multiplexer x passthrough x
## probe x ssh x hint x tty) combination, which is 1,728 of them. That is the
## assertion; the sentence above is only its summary. **The sweep is over
## AUTOMATIC resolution only** — every environment in it is built with
## `initCapabilityFlags()` — so the override has a table of its own, and the
## reason it has one is that it did not.
##
## ## THE ONE THING THAT BEATS THE RULE, AND WHY IT IS NOT A HOLE
##
## §2.2: *"A user override exists (`--image-tier`) and always wins, per the
## campaign's established rule that an explicit flag beats a probe."* So
## `--image-tier=protocol` inside `screen` resolves to tier 0 even though this
## module believes screen will eat the escape. That is the user asserting
## knowledge the probe does not have, and it is the same precedence
## `--truecolor` already has over `TERM=dumb` in `resolveColorDepth`.
##
## **It is not silent.** `ImageCapability.refusal` still carries the reason the
## automatic answer would have refused, `overriddenRefusal` says the flag
## overrode one, and `describe` prints both — so a pane title reads
## `tier=protocol(flag) despite screen-never-passes` rather than pretending the
## decision was uncontested. §3's "fall back silently and correctly" is a rule
## about a FAILED PROBE, not about an explicit instruction.
##
## **AND WHAT IT CANNOT DO IS NAME A PROTOCOL.** `--image-tier=protocol` says
## "use tier 0 on this path"; it does not say "use Kitty", because there is no
## spelling of the flag that does. So the flag can beat every refusal about the
## PATH — screen, tmux, an unanswered probe — and it cannot supply the one thing
## a tier-0 emission needs and nothing measured: which protocol to speak.
## `emittableProtocol` is that question, asked once, and when its answer is
## `ipNone` the pin loses. This is the invariant the whole module rests on,
## stated for the one path that used to break it:
##
##     no path here makes a tier stronger in response to an unknown
##
## It was FALSE until 2026-09-14 — the guard tested `probe.answered`, the DA1
## fence, so a terminal that advertised nothing and merely answered DA1 was
## given `ipITerm2` by the last arm of an `if` chain, while the same terminal
## with nothing answering was correctly refused. Two environments differing by
## one fence, resolving to "no protocol" and to "iTerm2". The sweep in
## `test_image_capability.nim` did not see it because every one of its pinned
## cases was the case that already worked.

import std/strutils

import ../../../../common/terminal_graphics/tiers
import ../../../../common/terminal_graphics/emit
import ./capabilities

# The image axis is an EXTENSION of the colour/border/mouse axes and takes
# `TerminalCapabilities` as an input, so every consumer of one needs the other.
# Re-exported for `host/capabilities.nim`'s reason: a caller that had to import
# both would be importing two halves of one decision.
export capabilities

type
  Multiplexer* = enum
    ## What is between this process and the terminal emulator.
    muxNone = "none"
    muxTmux = "tmux"
    muxScreen = "screen"
    muxUnknown = "unknown"
      ## `TERM` names a multiplexer (`screen*`, `tmux*`) but neither `$TMUX`
      ## nor `$STY` is set. That is the state a `screen` inside a `tmux`, a
      ## detached session reattached under a different environment, and a
      ## terminal whose terminfo entry is simply `screen-256color` all present,
      ## and the three want different treatments this build cannot tell apart.
      ## It is therefore treated as the WORST of them.

  PassthroughState* = enum
    ## tmux's `allow-passthrough` option, as read by
    ## `host/image_probe.readPassthrough`.
    ptUnknown = "unknown"
    ptOff = "off"
    ptOn = "on"

  GraphicsProbe* = object
    ## What an EMPIRICAL query of the effective path answered.
    ##
    ## §3: "capability detection must be empirical where it can be". The query
    ## and the reply travel the same path the image will — through the
    ## multiplexer, over the link — so an answer is evidence about the PATH and
    ## not about the outermost terminal's advertisement, which is the
    ## distinction §3 turns on.
    attempted*: bool
      ## Whether a probe was sent at all. The zero value is `false`, and that
      ## is the conservative one: `GraphicsProbe()` means "nothing was
      ## measured", never "the measurement said no".
    answered*: bool
      ## Whether the PATH round-tripped at all — `host/image_probe.nim` sends a
      ## primary device attributes request (`CSI c`) behind the graphics query
      ## as a fence, and every terminal, and every multiplexer, answers it.
      ## `answered == false` after `attempted` therefore means the far end is
      ## not behaving like a terminal, which is a stronger negative than "no
      ## graphics".
    kitty*: bool
      ## The Kitty graphics query came BACK — `\x1b_Gi=<id>;OK\x1b\\`. This is
      ## the only protocol in §2.1's tier 0 that can be measured rather than
      ## advertised, because it is the only one with a query; see
      ## `resolveImageCapability`'s multiplexer arm for what follows from that.
    iterm2*: bool
      ## Reserved and always false today: iTerm2's `File=inline` protocol has
      ## no query, so nothing can set this. It is a field rather than an
      ## absence so the multiplexer rule can be written as "a protocol whose
      ## path was MEASURED" rather than as "kitty", which would have to be
      ## edited if a queryable second protocol ever arrived.
    sixel*: bool
      ## Sixel support as reported in the DA1 attribute list (`;4;`). Recorded
      ## and never selected — this build has no Sixel encoder.

  ProtocolRefusal* = enum
    ## WHY tier 0 was not selected. `prNone` when it was.
    prNone = "none"
    prNotATerminal = "not-a-terminal"
    prNoProtocolAdvertised = "no-protocol-advertised"
    prScreenNeverPasses = "screen-never-passes"
    prMultiplexerUnproven = "multiplexer-unproven"
    prProbeUnanswered = "probe-unanswered"
    prGraphicsQuerySilent = "graphics-query-silent"
      ## The path answered the DA1 fence and did NOT answer the GRAPHICS query,
      ## on a terminal whose advertisement is the one protocol that HAS a query.
      ##
      ## A weaker negative than `prProbeUnanswered` and a stronger one than an
      ## advertisement: the far end is behaving like a terminal and is not
      ## behaving like a Kitty terminal. `TERM=xterm-kitty` set in a shell
      ## profile, a terminfo entry copied to a host whose emulator is something
      ## else, a `$KITTY_WINDOW_ID` inherited by a child started from a kitty
      ## window into a different pty — all present exactly this way, and all of
      ## them are §3's "accept the escape and show nothing".
      ##
      ## IT IS NOT USED FOR `ipITerm2`, and that asymmetry is the whole reason
      ## this refusal names the query rather than the reply. iTerm2's inline
      ## protocol has no query, so a fence-only answer is silence about a
      ## question that was never asked — evidence about Kitty and about nothing
      ## else. Refusing iTerm2 on it would make a probed local iTerm2 session
      ## unable to draw at all, which is a pessimistic failure with no
      ## measurement behind it.
    prPayloadExceedsLink = "payload-exceeds-link-budget"
    prSixelHasNoEncoder = "sixel-has-no-encoder"

  ImageEnv* = object
    ## EVERY environment variable IMAGE capability resolution reads, and
    ## nothing reads one anywhere else — `capabilities.TerminalEnv`'s contract,
    ## restated for the axis this module adds. `host/image_probe.readImageEnv`
    ## is the one function that fills this in a shipped binary.
    ##
    ## SEPARATE FROM `TerminalEnv` RATHER THAN APPENDED TO IT, and the reason is
    ## a live assertion: `test_capability_resolution.nim` sweeps 28 constructed
    ## `TerminalEnv` values and `app/cli.nim`'s parser is compared against
    ## `initCapabilityFlags()` by equality. Widening `TerminalEnv` would make
    ## every one of those rows a row about image capability too, silently, with
    ## zero values nobody chose. A second value object is the honest shape: the
    ## colour ladder does not depend on tmux, and the image ladder does.
    tmux*: string           ## `$TMUX`
    sty*: string            ## `$STY`
    termProgram*: string    ## `$TERM_PROGRAM`
    lcTerminal*: string     ## `$LC_TERMINAL` — how iTerm2 identifies itself
                            ## through an ssh session that forwards it
    kittyWindowId*: string  ## `$KITTY_WINDOW_ID`
    sshConnection*: string  ## `$SSH_CONNECTION`
    sshTty*: string         ## `$SSH_TTY`
    passthrough*: PassthroughState

  ImageCapability* = object
    ## The resolved image axis. ONE value, computed once, like
    ## `TerminalCapabilities`.
    tier*: ImageTier
    tierFrom*: CapabilitySource
    protocol*: ImageProtocol
      ## The protocol tier 0 would use, or `ipNone`.
    advertised*: ImageProtocol
      ## What the ENVIRONMENT alone claimed, before any refusal. Carried
      ## because §3's whole point is that an advertisement is not a permission,
      ## and a value that recorded only the outcome could not say which of the
      ## two a reader was looking at.
    refusal*: ProtocolRefusal
    overriddenRefusal*: bool
      ## `--image-tier` selected tier 0 over a live `refusal`. See the header.
    multiplexer*: Multiplexer
    overSsh*: bool
    repertoire*: UnicodeRepertoire
    wrapForMultiplexer*: bool
      ## Whether an emission must be wrapped in tmux's DCS passthrough.
    linkBudget*: int
      ## The most EMITTED BYTES (`emit.EmittedImage.emittedBytes`, and no other
      ## quantity — see that module's header) one tier-0 image may cost here.
      ## `0` means unbounded, which is a local session.

const
  KittyTerms* = ["xterm-kitty"]
  KittyPrograms* = ["kitty"]
  ITerm2Programs* = ["iTerm.app", "WezTerm"]
  ITerm2LcTerminals* = ["iTerm2"]
  SixelTerms* = ["mlterm", "yaft-256color", "foot", "foot-extra"]
    ## Terminals whose terminfo name means Sixel. Present so the ADVERTISEMENT
    ## is complete.
    ##
    ## **`ImageCapability.protocol` is never `ipSixel`, on any path**, and the
    ## sentence that used to stand here — "detection never SELECTS Sixel" —
    ## was true of the automatic path and FALSE of `--image-tier=protocol`,
    ## which reached past `prSixelHasNoEncoder` and handed a caller a protocol
    ## `emit.emitProtocolImage` raises for. Corrected on 2026-09-14; the rule is
    ## now one predicate (`emittableProtocol`) that both the pin and the sixel
    ## refusal are written against, and the pinned Sixel row is in
    ## `test_image_capability.nim`'s override table rather than in a comment.

  EmittableProtocols* = {ipKitty, ipITerm2}
    ## The tier-0 protocols THIS BUILD can turn into bytes.
    ##
    ## `ipSixel` is absent because `emit.emitProtocolImage` RAISES for it —
    ## `nim_termctl.emitSixel` needs a quantiser and a dither this build does
    ## not carry — so naming it as the protocol of a tier-0 rendering does not
    ## produce a worse picture, it produces an exception where a picture was
    ## asked for. `ipNone` is absent because it is the absence.
    ##
    ## A SET RATHER THAN A COMPARISON AT EACH SITE, for §14's reason: the
    ## refusal (`prSixelHasNoEncoder`) and the pin both ask "can this build emit
    ## it?", and two spellings of that question are two things that can drift.

func measuredProtocol*(probe: GraphicsProbe): bool =
  ## Whether a GRAPHICS reply — not merely a live path — came back.
  ##
  ## One predicate, so the multiplexer rule and every control written against
  ## it reach the same function (§14). `sixel` is deliberately absent: a DA1
  ## attribute list is a claim by whatever answered DA1, which under tmux is
  ## tmux, so it is an advertisement wearing a probe's clothes.
  probe.attempted and probe.answered and (probe.kitty or probe.iterm2)

func emittableProtocol*(advertised: ImageProtocol;
                        probe: GraphicsProbe): ImageProtocol =
  ## WHICH PROTOCOL A TIER-0 EMISSION WOULD USE HERE, or `ipNone` if nothing
  ## named one this build can emit.
  ##
  ## This is the predicate `--image-tier=protocol` is written against, and it
  ## exists because the override used to answer that question inline, with a
  ## three-armed `if` whose last arm was a bare `else: ipITerm2` — a protocol
  ## chosen by position in a chain rather than by evidence. Two rules, and
  ## neither of them is a precedence rule:
  ##
  ##   * **A protocol this build cannot emit is not a candidate.** See
  ##     `EmittableProtocols`. An advertisement of `ipSixel` names a real
  ##     capability of a real terminal and this build still cannot use it.
  ##   * **A protocol NOTHING named is never synthesised.** The only thing that
  ##     outranks an absent advertisement is a GRAPHICS reply, which is
  ##     `measuredProtocol` — the module's single predicate for that — and not
  ##     `probe.answered`, which is the DA1 fence every terminal and every
  ##     multiplexer answers. A flag saying "use tier 0" is the user asserting
  ##     knowledge about the PATH; it is not the user naming a protocol, and
  ##     guessing one on their behalf emits an escape at a terminal that
  ##     claimed neither — §3's garbage, produced by a flag instead of by a
  ##     probe.
  ##
  ## THE ADVERTISEMENT IS CONSULTED FIRST AND THE MEASUREMENT ONLY AFTER IT,
  ## which is the same order `advertisedProtocol` uses and the reason a Sixel
  ## terminal that answered the Kitty query resolves to `ipKitty` here: the
  ## advertisement was rejected for a stated reason (nothing can emit it), and
  ## what is left is a measurement. That case is a row in the override table.
  if advertised in EmittableProtocols: return advertised
  if measuredProtocol(probe):
    if probe.kitty: return ipKitty
    if probe.iterm2: return ipITerm2
  ipNone

func advertisedProtocol*(env: TerminalEnv; ienv: ImageEnv): ImageProtocol =
  ## What the environment CLAIMS, with no judgement about whether it survives
  ## the path. §3's "the outermost terminal's advertisement".
  ##
  ## Order is Kitty, then iTerm2, then Sixel — the order of what this build can
  ## actually emit, so an advertisement this build cannot use never displaces
  ## one it can.
  let term = env.term.toLowerAscii()
  if ienv.kittyWindowId.len > 0 or term in KittyTerms or
     term.contains("kitty") or ienv.termProgram.toLowerAscii() in KittyPrograms:
    return ipKitty
  if ienv.termProgram in ITerm2Programs or ienv.lcTerminal in ITerm2LcTerminals:
    return ipITerm2
  if term.contains("sixel") or term in SixelTerms:
    return ipSixel
  ipNone

func detectMultiplexer*(env: TerminalEnv; ienv: ImageEnv): Multiplexer =
  ## §3's "the effective path", first half: what is in the way.
  ##
  ## `$TMUX` and `$STY` are set by the multiplexer in the pane's own
  ## environment and are the positive evidence. `TERM=screen…` / `TERM=tmux…`
  ## without either is AMBIGUOUS rather than absent — see `muxUnknown` — and
  ## the ambiguous case resolves to the treatment that asks least of the path.
  if ienv.tmux.len > 0: return muxTmux
  if ienv.sty.len > 0: return muxScreen
  let term = env.term.toLowerAscii()
  if term.startsWith("screen") or term.startsWith("tmux"):
    return muxUnknown
  muxNone

func overSsh*(ienv: ImageEnv): bool =
  ## §3's link. `SSH_CONNECTION` and `SSH_TTY` are both set by `sshd` for an
  ## interactive session; either alone is enough, because a user who forwards
  ## one and not the other has still told us the truth about the link.
  ienv.sshConnection.len > 0 or ienv.sshTty.len > 0

func resolveRepertoire*(env: TerminalEnv;
                        caps: TerminalCapabilities): UnicodeRepertoire =
  ## What glyphs may be emitted.
  ##
  ## **NEVER ABOVE `urWide3_2` AUTOMATICALLY**, and that is the fail-low rule
  ## in its purest form. Sextants (Unicode 13) and octants (Unicode 16) need a
  ## FONT that carries them, and no escape sequence, terminfo entry or
  ## environment variable reports what fonts are installed. A terminal that
  ## lacks the glyph draws `.notdef` — a grid of tofu boxes, which is a
  ## DIFFERENT picture and not a coarser one. So those two rungs are reachable
  ## only through `--image-tier`, which is the user telling this build
  ## something it cannot measure.
  ##
  ## `bmAscii` is reused rather than re-deriving the locale test: it is exactly
  ## `resolveBorders`' answer to "may this terminal be sent a multi-byte
  ## glyph?", and asking the same question twice is how the two answers come to
  ## differ (§14).
  if isDumbTerminal(env): return urAscii
  if caps.borders == bmAscii: return urAscii
  urWide3_2

func automaticCeiling(repertoire: UnicodeRepertoire;
                      caps: TerminalCapabilities): ImageTier =
  ## The best CELL tier this terminal may be sent, ignoring tier 0.
  ##
  ## Two independent floors, and the WEAKER of them wins — `weakerOf` rather
  ## than an `if/elif` chain, so the combination of two restrictions cannot
  ## accidentally resolve to the stronger of the two.
  var ceiling = itHalfBlock
  if repertoire < urBlocks1_1:
    ceiling = weakerOf(ceiling, itAscii)
  if caps.colors == cdMonochrome:
    # Every cell tier above the ramp carries its picture in TWO COLOURS
    # (`tiers.needsTwoColours`); on a monochrome terminal a field of half
    # blocks is a solid rectangle. Tier 6 carries luminance in the glyph and
    # survives.
    ceiling = weakerOf(ceiling, itAscii)
  ceiling

func hintedTier(ceiling: ImageTier; repertoire: UnicodeRepertoire;
                hint: ImageHint): ImageTier =
  ## §2.2: "picks the highest tier the terminal supports that suits the hint".
  ##
  ## `ihPhoto` wants COLOUR, which is tier 1 (§2.1: "Tier 1 is the workhorse …
  ## two full-colour pixels per cell"). `ihLineArt` and `ihMask` want SHAPE,
  ## which is braille (§8 decision 3: "yes, gated behind the
  ## `ihLineArt`/`ihMask` hint, because those buffers are exactly what a
  ## graphics debugger looks at most"). Neither ever reaches tiers 2-4; see
  ## `tiers.AutomaticTiers`.
  let wanted =
    case hint
    of ihPhoto: itHalfBlock
    of ihLineArt, ihMask:
      if repertoire >= urWide3_2: itBraille else: itHalfBlock
  weakerOf(wanted, ceiling)

func resolveImageCapability*(env: TerminalEnv; ienv: ImageEnv;
                             caps: TerminalCapabilities;
                             flags: CapabilityFlags;
                             probe = GraphicsProbe();
                             hint = ihPhoto): ImageCapability =
  ## THE whole image decision, as one pure function.
  ##
  ## The default `probe` is the zero value — "nothing was measured" — because a
  ## caller that forgot to probe must get the answer a failed probe would give,
  ## not the answer a successful one would.
  let mux = detectMultiplexer(env, ienv)
  let ssh = overSsh(ienv)
  let repertoire = resolveRepertoire(env, caps)
  let advertised = advertisedProtocol(env, ienv)

  # ---- Is tier 0 reachable on the EFFECTIVE PATH? ----
  var refusal = prNone
  var protocol = advertised
  if not env.isTty:
    refusal = prNotATerminal
  elif probe.attempted and not probe.answered:
    # NEGATIVE EVIDENCE BEATS AN ADVERTISEMENT, everywhere, and this arm is
    # above the multiplexer arms on purpose: a probe that travelled the whole
    # path and came back with nothing has measured the path, which is exactly
    # what §3 asks detection to do.
    refusal = prProbeUnanswered
  elif mux == muxScreen:
    refusal = prScreenNeverPasses
  elif mux == muxUnknown:
    refusal = prMultiplexerUnproven
  elif mux == muxTmux and not (measuredProtocol(probe) and
                               ienv.passthrough == ptOn):
    # §3's named failure: "a Kitty-capable terminal running tmux without
    # passthrough will accept the escape and show nothing".
    #
    # BOTH HALVES ARE REQUIRED, and the first is the GRAPHICS reply and not
    # merely a live path. `probe.answered` is the DA1 fence, which tmux answers
    # ITSELF whether or not it forwards APC — so a rule written against it
    # would be satisfied by exactly the configuration §3 names. The evidence
    # that the effective path passes graphics is a graphics reply that came
    # back through the pane, which is `measuredProtocol`.
    #
    # The consequence is that iTerm2 is never selected under tmux: its inline
    # protocol has no query, so its effective path cannot be measured, and
    # §3's rule about the unmeasurable case is to refuse. Recorded rather than
    # hidden, because it is a real narrowing and not an oversight.
    refusal = prMultiplexerUnproven
  elif advertised == ipNone:
    if probe.answered and probe.kitty:
      protocol = ipKitty
    elif probe.answered and probe.iterm2:
      protocol = ipITerm2
    else:
      refusal = prNoProtocolAdvertised
  elif advertised == ipKitty and probe.attempted and probe.answered and
       not probe.kitty:
    # THE SAME NEGATIVE THE TMUX ARM ABOVE IS BUILT ON, ARRIVING WITHOUT A
    # MULTIPLEXER. A probe that reached the far end and came back WITHOUT the
    # Kitty reply has measured the one protocol that can be measured, and it
    # said no. That is evidence about the path, which is what §3 asks detection
    # to test, and the arm above already treats it as decisive under tmux — so
    # ignoring it locally would make the same measurement mean two different
    # things depending on whether `$TMUX` happens to be set.
    #
    # BELOW THE MULTIPLEXER ARMS ON PURPOSE, and this is not a stylistic
    # ordering. A tmux pane with `allow-passthrough` on and a fence-only reply
    # is §3's named failure and must report `prMultiplexerUnproven`; if this arm
    # ran first it would answer for that row too, the tmux arm's own case would
    # be satisfied by a second mechanism, and the arm aimed at it could not be
    # killed — Verification-Harness-Traps §16a, bought rather than inherited.
    # The two refusals therefore have disjoint evidence: the row here has no
    # multiplexer, and the tmux rows are answered above.
    #
    # `ipITerm2` IS NOT REFUSED HERE. See `prGraphicsQuerySilent`.
    refusal = prGraphicsQuerySilent
  if refusal == prNone and protocol == ipSixel:
    # An advertisement this build cannot honour. `emit.emitProtocolImage`
    # raises for `ipSixel`, so selecting it would turn a picture into an
    # exception — the refusal is here, where it can be reported, rather than
    # there, where it can only abort.
    refusal = prSixelHasNoEncoder
  if refusal != prNone:
    protocol = ipNone

  # ---- The automatic answer ----
  let ceiling = automaticCeiling(repertoire, caps)
  var tier = if refusal == prNone: itProtocol
             else: hintedTier(ceiling, repertoire, hint)
  var tierFrom = if isDumbTerminal(env) or advertised != ipNone or
                    mux != muxNone or ssh: csEnvironment
                 else: csDefault
  var overridden = false

  # ---- §2.2's override, which always wins ----
  if flags.imageTierPinned:
    # THE PROTOCOL A PINNED TIER 0 WOULD EMIT, asked ONCE, through the one
    # predicate — so the test below ("is there one?") and the assignment in the
    # other arm ("use it") cannot come to disagree (§14).
    let pinnable = emittableProtocol(advertised, probe)
    if flags.imageTier == itProtocol and pinnable == ipNone:
      # THE ONE CASE THE FLAG CANNOT WIN, and it is not a precedence rule: a
      # pinned tier 0 needs a protocol to emit, and nothing this build can emit
      # has been named by anything.
      #
      # THE TEST IS `pinnable`, NOT THE FENCE. It used to be
      # `advertised == ipNone and not probe.answered`, and `probe.answered` is
      # the DA1 fence — which `GraphicsProbe.answered`'s own doc says every
      # terminal and every multiplexer answers. So the guard fired only when
      # NOTHING at all replied, a state the shipped lazy-probe design never
      # produces, and a terminal that had merely answered DA1 got `ipITerm2`
      # chosen for it by the last arm of a chain. Two environments differing
      # only by a fence answering resolved to "no protocol" and to "iTerm2".
      #
      # The reason it is stated as a refusal rather than as a clamp is that the
      # tier falls to the automatic cell answer while `tierFrom` stays `csFlag`:
      # the flag WAS read, and a reader has to be able to see that it was read
      # and could not be honoured.
      if refusal == prNone:
        refusal = prNoProtocolAdvertised
      tier = hintedTier(ceiling, repertoire, hint)
      tierFrom = csFlag
    else:
      tier = flags.imageTier
      tierFrom = csFlag
      if tier == itProtocol:
        overridden = refusal != prNone
        protocol = pinnable

  ImageCapability(
    tier: tier, tierFrom: tierFrom,
    protocol: (if tier == itProtocol: protocol else: ipNone),
    advertised: advertised, refusal: refusal, overriddenRefusal: overridden,
    multiplexer: mux, overSsh: ssh, repertoire: repertoire,
    wrapForMultiplexer: tier == itProtocol and mux == muxTmux,
    linkBudget: (if ssh: MaxLinkImageBytes else: 0))

func withinLinkBudget*(cap: ImageCapability; emittedBytes: int): bool =
  ## Whether an emission of `emittedBytes` bytes is allowed on this link.
  ##
  ## THE ARGUMENT IS THE EMITTED LENGTH AND THE CALLER HAS TO SAY SO. See
  ## `emit.fitsLinkBudget`, which takes the `EmittedImage` itself so the wrong
  ## quantity cannot be passed; this overload exists for the decision that has
  ## to happen BEFORE an emission is built, and its name carries the unit
  ## because nothing else can.
  cap.linkBudget == 0 or emittedBytes <= cap.linkBudget

func demoteForPayload*(cap: ImageCapability; emittedBytes: int;
                       hint = ihPhoto): ImageCapability =
  ## §3: *"tier selection must account for the link"*.
  ##
  ## A tier-0 emission too large for a constrained link is replaced by the cell
  ## tier the same terminal would otherwise have got. The decision is made on
  ## the EMITTED byte count — the length of the string that would be written —
  ## and this function takes that number rather than a payload so the unit is
  ## in the signature.
  ##
  ## IT ONLY EVER DEMOTES. A caller passing a small payload gets its argument
  ## back unchanged; there is no path from here to a stronger tier.
  if cap.tier != itProtocol: return cap
  # AN EXPLICITLY PINNED TIER 0 IS NOT DEMOTED BY A SIZE RULE EITHER — §2.2's
  # "always wins", applied to the one rule that runs after the decision is
  # made. The link budget is a judgement about what a user would rather wait
  # for, and a user who typed `--image-tier=protocol` on a link they are sitting
  # on has already made it. The alternative — demote anyway — would make the
  # flag mean "tier 0 unless this build disagrees about your bandwidth", which
  # is not a spelling anyone would choose.
  #
  # It is the asymmetry with the line above it, so it has a case of its own:
  # `test_image_capability.nim`'s demotion case demotes an UNPINNED SSH
  # capability and refuses to demote the pinned one built from the same
  # environment, which is the positive twin that keeps this line from being an
  # argument nothing can falsify (Verification-Harness-Traps §7a).
  if cap.tierFrom == csFlag: return cap
  if withinLinkBudget(cap, emittedBytes): return cap
  result = cap
  result.tier = weakerOf(cap.tier,
                         hintedTier(itHalfBlock, cap.repertoire, hint))
  result.protocol = ipNone
  result.refusal = prPayloadExceedsLink
  result.wrapForMultiplexer = false

func describe*(cap: ImageCapability): string =
  ## One line naming the tier AND the reason, for a pane title (§4: "The pane
  ## declares its tier in its title") and for every failure message with a
  ## capability in scope. `capabilities.describe`'s rule, restated: a report
  ## that named the tier without naming the reason leaves the reader to
  ## re-derive the decision from an environment they cannot see.
  result = "image-tier=" & tierName(cap.tier) & "(" & $cap.tierFrom & ")"
  result.add " protocol=" & $cap.protocol
  result.add " advertised=" & $cap.advertised
  result.add " mux=" & $cap.multiplexer
  result.add " ssh=" & (if cap.overSsh: "yes" else: "no")
  result.add " repertoire=" & $cap.repertoire
  if cap.refusal != prNone:
    result.add " refused-tier0=" & $cap.refusal
  if cap.overriddenRefusal:
    result.add " (overridden by --image-tier)"
  if cap.wrapForMultiplexer:
    result.add " tmux-passthrough=wrapped"
  if cap.linkBudget > 0:
    result.add " link-budget=" & $cap.linkBudget & "B"

func initImageEnv*(tmux = ""; sty = ""; termProgram = ""; lcTerminal = "";
                   kittyWindowId = ""; sshConnection = ""; sshTty = "";
                   passthrough = ptUnknown): ImageEnv =
  ## An `ImageEnv` with every field named, for `initTerminalEnv`'s reason: a
  ## test that varies one variable says which one it varied.
  ImageEnv(tmux: tmux, sty: sty, termProgram: termProgram,
           lcTerminal: lcTerminal, kittyWindowId: kittyWindowId,
           sshConnection: sshConnection, sshTty: sshTty,
           passthrough: passthrough)
