## viewmodels/generated_code_operation.nim
##
## THE OPERATION, as declared data: which generated-code targets a file's
## language has, what each one's command is called, and whether that command is
## present, enabled or disabled.
##
## `GUI/Debugging-Features/Generated-Code-Listing.md` §3.1 (GCL-D11), §8
## (GCL-D17), §13.
##
## LANE: `vm-unit` AND `vm-unit-js`. Nothing here reaches the host, `std/os` or
## a browser: it is a pure function of a path, a language and a build proposal.
##
## ## Why this module exists, given `openAlternativeView` already opens these
##
## `renderer.openAlternativeView(data, id: int)` takes a POSITIONAL INDEX into
## a `case` over `data.trace.lang`, so `1` means disassembly for C and
## generated C for Nim, and the name of the thing being opened exists nowhere
## in the product. That is why "Show Assembly Code" cannot be the operation's
## name, and it is GCL-D11's whole argument: **each target contributes its own
## command, labelled with its own display name.**
##
## Two consequences that are requirements rather than restatements:
##
##   * The ladder is a **chain**, not a flat set (§3.1). Nim's assembly is
##     generated from the C, not from the Nim — which is what
##     `openAlternativeView` already reflects by taking `cLocation.asmName`
##     rather than an assembly of the Nim position. `generatedFrom` carries
##     that, so a consumer can tell a one-rung correspondence from a composed
##     two-rung one, and §5.2's rule (composition cannot improve fidelity) has
##     something to be stated about.
##
##   * The language is read **per file, from the path**, and NOT from
##     `Trace.lang` (§3.1). `Trace.lang` is a summary of a per-file fact for a
##     recording that may span several languages. `openAlternativeView` reads
##     it, which is why it cannot answer correctly in a mixed recording.
##
## ## THE EXTENSION TABLE IS DERIVED FROM THE LADDER, NOT PARALLEL TO IT
##
## A second hand-maintained table keyed by language is the drift
## `common_lang.getExtensionName` was consolidated to end. So `LadderRows`
## below carries the extensions AND the targets in one row per language, and
## `test_generated_code_operation.nim` asserts every row has both — a language
## that declares targets no path can select is a feature nobody can invoke.
##
## `targetsFor` and `ladderLanguageOfPath` are INTERNAL. They are the table's
## two readers and `targetsForPath` composes them, which is the only thing any
## caller has wanted; exporting them so a test could address them directly
## would have put two more names in the reachability guard's bucket [A]
## ("tested, no product module reaches it") in the same commit that adds that
## guard's sibling. The suite goes through `targetsForPath`, which is what
## production goes through.
##
## This table covers only the languages that declare a target. A path it does
## not recognise answers `slUnknown`, and `slUnknown` declares no target, so
## the command is ABSENT — which is GCL-D17's first row and the honest default
## (§13: "a language with no producer contributes no command"). It is
## deliberately NOT a general-purpose path→language function, and it is named
## `ladderLanguageOfPath` so no caller mistakes it for one.

import std/strutils

import ../../../common/target_axes
import ./edit_mode_toolbar

export target_axes

type
  GeneratedCodeTarget* = object
    ## One rung of a language's ladder (§3.1).
    id*: string
      ## The STABLE identifier. This is what a saved layout, a keybinding and a
      ## tab key persist — never the display name, which is prose, and never a
      ## positional index, which is what GCL-D11 exists to retire.
    displayName*: string
      ## What the user sees and invokes. `commandLabel` prefixes it.
    generatedFrom*: string
      ## The predecessor rung's `id`, or `""` for the first rung, which is
      ## generated from the source language itself. §3.1's chain.
    producer*: string
      ## Who supplies the rows. Named on the surface, because a row count
      ## cannot discriminate two producers that agree on every number
      ## (GCL-D23).

  TargetAvailability* = enum
    ## GCL-D17's disabled-versus-hidden split. Three states, because *this
    ## language has no generated-code view* and *we cannot work out how to
    ## build your project* have different next actions for the user.
    gaAbsent
      ## No command at all. There is nothing to explain.
    gaEnabled
    gaDisabled
      ## The command exists and carries the reason it cannot run.

  TargetCommand* = object
    target*: GeneratedCodeTarget
    availability*: TargetAvailability
    reason*: string
      ## Non-empty whenever `availability == gaDisabled`, and empty otherwise.
      ## Same discipline as `CommandProposal.reason`: without the rule,
      ## "every disabled command explains itself" is satisfied by disabling
      ## nothing.

  LadderRow = object
    lang: SourceLanguage
    extensions: seq[string]
    targets: seq[GeneratedCodeTarget]

const
  NoirProducer = "noir-acir-compile"
    ## `noir_anchor_producer`, reading a `nargo compile` artefact. Distinct
    ## from the build-time report that `noir_build_producer` carries, which
    ## names the same function `main` where this one names it `func 0`
    ## (§14.2) — which is exactly why the surface states which one painted it.

  NativeProducer = "native-debug-info"

proc target(id, displayName, generatedFrom, producer: string):
    GeneratedCodeTarget {.noSideEffect.} =
  GeneratedCodeTarget(id: id, displayName: displayName,
    generatedFrom: generatedFrom, producer: producer)

const LadderRows: seq[LadderRow] = @[
  LadderRow(
    lang: slNoir,
    extensions: @["nr"],
    targets: @[
      # GCL-D4: named for the `nargo` invocation that produces the same text
      # locally. Disagreeing with the toolchain's own vocabulary is a small
      # permanent tax on every user who runs both.
      target("noir.acir", "ACIR", "", NoirProducer),
      target("noir.brillig", "Brillig", "", NoirProducer),
      # GCL-D5: `After Initial SSA` only, and it is NOT anchorable —
      # `--show-ssa` emits no location information. It is a listing with no
      # anchors, offered because reading it is useful, not because it maps.
      target("noir.ssa", "SSA", "", NoirProducer),
    ]),
  LadderRow(
    lang: slNim,
    extensions: @["nim"],
    targets: @[
      target("nim.c", "Generated C", "", NativeProducer),
      # THE CHAIN. Assembly is generated from the C, not from the Nim.
      target("nim.asm", "Assembly", "nim.c", NativeProducer),
    ]),
  LadderRow(
    lang: slC,
    extensions: @["c", "h"],
    targets: @[target("c.asm", "Assembly", "", NativeProducer)]),
  LadderRow(
    lang: slCpp,
    extensions: @["cpp", "cc", "cxx", "hpp"],
    targets: @[target("cpp.asm", "Assembly", "", NativeProducer)]),
  LadderRow(
    lang: slRust,
    extensions: @["rs"],
    targets: @[target("rust.asm", "Assembly", "", NativeProducer)]),
  LadderRow(
    lang: slGo,
    extensions: @["go"],
    targets: @[target("go.asm", "Assembly", "", NativeProducer)]),
]

proc extensionOf(path: string): string {.noSideEffect.} =
  ## The extension, lowercased, without the dot. `""` when there is none.
  ##
  ## The last `.` must come after the last path separator, or `src.v2/main`
  ## reads as extension `v2/main`.
  var dot = -1
  var sep = -1
  for i in countdown(path.high, 0):
    if path[i] == '.' and dot < 0:
      dot = i
    if (path[i] == '/' or path[i] == '\\') and sep < 0:
      sep = i
    if dot >= 0 and sep >= 0:
      break
  if dot < 0 or dot < sep or dot == path.high:
    return ""
  path[dot + 1 .. path.high].toLowerAscii()

proc ladderLanguageOfPath(path: string): SourceLanguage {.noSideEffect.} =
  ## The file's language FOR THE PURPOSES OF THIS OPERATION, from the path.
  ##
  ## NOT a general path→language function, and not a substitute for one: it
  ## recognises exactly the languages that declare a ladder, and answers
  ## `slUnknown` for everything else. `slUnknown` declares no target, so the
  ## command is absent — GCL-D17's first row.
  ##
  ## Reading the PATH rather than `Trace.lang` is §3.1's rule and not a
  ## convenience: a recording may span several languages, and the generated
  ## code of the file under the cursor is a fact about that file.
  let ext = extensionOf(path)
  if ext.len == 0:
    return slUnknown
  for row in LadderRows:
    for e in row.extensions:
      if e == ext:
        return row.lang
  slUnknown

proc targetsFor(lang: SourceLanguage): seq[GeneratedCodeTarget]
    {.noSideEffect.} =
  ## The language's ladder, in rung order. Empty for a language with none.
  for row in LadderRows:
    if row.lang == lang:
      return row.targets
  @[]

proc targetsForPath*(path: string): seq[GeneratedCodeTarget] {.noSideEffect.} =
  targetsFor(ladderLanguageOfPath(path))

proc targetById*(id: string; found: var GeneratedCodeTarget): bool
    {.noSideEffect.} =
  ## Resolve a persisted identifier. Returns false rather than a zeroed target,
  ## so a stale saved layout cannot silently address rung zero of some other
  ## language — the failure GCL-D26 names for instantiation indices, one level
  ## up.
  for row in LadderRows:
    for t in row.targets:
      if t.id == id:
        found = t
        return true
  false

proc commandLabel*(t: GeneratedCodeTarget): string {.noSideEffect.} =
  ## What the omnibox and the editor's context menu show. "Show ACIR", "Show
  ## Generated C" — the target's own display name, never a shared "Show
  ## Assembly Code" that means a different thing per language.
  "Show " & t.displayName

# `keybindingTarget` WAS HERE AND IS DELETED.
#
# GCL-D11 specifies a keybinding bound to "the first target of the current
# file's language", so the familiar one-key gesture survives without any
# binding having to mean different things in different files. NO KEY IS BOUND
# TO IT, and a resolver for a gesture nobody can make is the same shape as the
# producer this whole commit exists to reach: correct, tested, and unreachable.
# The context menu is the open path that exists. When a key is bound, this is
# three lines over `targetsForPath` — and the binding is what makes them worth
# writing.

proc commandsForPath*(path: string; proposal: CommandProposal;
                      platformReason: string = ""): seq[TargetCommand]
    {.noSideEffect.} =
  ## GCL-D17's table, evaluated on the same input the Build button uses.
  ##
  ## | Situation | The command |
  ## | --- | --- |
  ## | the language declares no target | absent — nothing to explain |
  ## | a target exists, the proposal is `pcCanonical` | enabled |
  ## | a target exists, the proposal is not `pcCanonical` | disabled, carrying the proposal's own reason |
  ## | a target exists, the platform cannot run the command | disabled, carrying the platform's sentence |
  ##
  ## "No artefact has been built yet" is deliberately NOT a disabling
  ## condition: invoking the command is what builds it (§8). A target with no
  ## artefact is `gaEnabled`, and the wait is the answer.
  ##
  ## `platformReason` outranks the proposal because it is the more specific
  ## refusal: a canonical command the platform cannot run is still a command
  ## that cannot run, and reporting the proposal's silence there would tell the
  ## user to fix a build file that is already correct.
  let targets = targetsForPath(path)
  if targets.len == 0:
    return @[]

  for t in targets:
    if platformReason.len > 0:
      result.add TargetCommand(target: t, availability: gaDisabled,
        reason: platformReason)
    elif proposal.confidence != pcCanonical:
      # `CommandProposal.reason` is non-empty whenever the confidence is not
      # canonical (EMT-A48), so this branch always carries a sentence. The
      # fallback exists so a caller that hand-builds a proposal cannot produce
      # a disabled command with nothing on it — a row that refuses and will not
      # say why is the failure `absentBecause` exists to prevent.
      result.add TargetCommand(target: t, availability: gaDisabled,
        reason: if proposal.reason.len > 0: proposal.reason
                else: "this project's build command could not be determined")
    else:
      result.add TargetCommand(target: t, availability: gaEnabled, reason: "")
