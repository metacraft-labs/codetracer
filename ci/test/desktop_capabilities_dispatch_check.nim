##
## Capability-file ↔ record-dispatch conformance checker.
##
## WHAT THIS TESTS
##   That the file-extension declarations in
##   `resources/codetracer-desktop-capabilities` are exactly the
##   extensions the CodeTracer core can actually record — no more, no
##   less. Concretely, for `record`, `run` and `record-test`:
##
##     1. FORWARD  — every `<cmd> .ext` the capability file declares has a
##        real dispatch path in the core: `.ext` is in
##        `src/ct/utilities/language_detection.nim`'s `LANGS` table (so
##        `detectLangFromPath` produces a language for it), that language
##        reaches a recorder arm of `src/ct/db_backend_record.nim`'s
##        `record` chain, and `src/ct/trace/recorder_dispatch.nim` builds
##        a non-empty invocation for it. A declaration the core cannot
##        honour silently routes a user's `ct record` to a component that
##        will refuse it, so this is a hard failure.
##     2. CONVERSE — every extension the core CAN record is declared. This
##        is the direction that lets a real bug hide: `.js` had a working
##        JS-recorder dispatch path for a long time while the capability
##        file never declared it, so `ct record app.js` through the
##        launcher failed to route at all. A deliberate omission must be
##        an explicit, justified entry in `DeliberateOmissions` below —
##        never silence.
##
##   The three commands are checked separately because they are NOT the
##   same set in the core (see the predicates below): `record-test` only
##   has a materialized-trace arm for Python.
##
## HOW THE EXPECTED SET IS DERIVED
##   By importing and evaluating the core's own tables — `LANGS`,
##   `usesMaterializedTraces` and `recorderToolFor` — not by restating
##   them. A test that compared two hardcoded lists would prove nothing:
##   it would stay green while the product and the capability file drifted
##   apart together. The only thing written out by hand here is the
##   *shape* of the dispatch chains in `db_backend_record.nim` /
##   `record.nim`, each with the line it mirrors.
##
## DESIGN DOC
##   codetracer-specs/Testing/Launcher-Recorder-Compatibility-Tests.md
##   §5.1 deliverable D2 and §7 (the test matrix's "needs D2 cap fix"
##   row), milestone LRC-1 in
##   Launcher-Recorder-Compatibility-Tests.milestones.org.
##   Capability grammar: codetracer-specs/Planned-Features/CodeTracer-Launcher.md §2.3.
##
## MOCKING POLICY (per metacraft-dev-guidelines/policies/documentation-conventions.md,
##   "Mocking Policy in Integration Tests")
##   This checker mocks NOTHING. It links the real production modules and
##   calls the real dispatch predicates; the "expected" set is computed by
##   the shipping code itself. It reads a real capability file from disk
##   (the checked-in resource, or — for the harness's mutation scenarios —
##   a byte-copy of it with one line edited, which is the input under
##   test, not a stand-in for any component's behaviour). No recorder is
##   stubbed, because nothing is recorded: selection is a pure function,
##   which is exactly why `recorder_dispatch.nim` was split out.
##
## NO SKIPS
##   There is no skip path. A missing capability file, an unparseable one,
##   or zero performed checks all exit non-zero.
##
## USAGE
##   nim c -r ci/test/desktop_capabilities_dispatch_check.nim <capabilities-file>
##

import std/[os, sets, strutils, algorithm, tables]

import ../../src/common/lang
import ../../src/ct/utilities/language_detection
import ../../src/ct/trace/recorder_dispatch
import ../../src/ct/trace/record_assessment  # assessedSelector (LRS-5, .wasm)

type CheckError = object of CatchableError

var checks = 0

let verbose = getEnv("CT_CAPS_CHECK_VERBOSE", "") == "1"
  ## Every individual assertion is echoed with ``CT_CAPS_CHECK_VERBOSE=1``.
  ## Off by default only because the per-extension checks alone run into the
  ## hundreds; a FAILING assertion is always printed, with its full text.

proc expect(cond: bool, what: string) =
  inc checks
  if not cond:
    raise newException(CheckError, what)
  if verbose:
    echo "  ok: ", what

# ---------------------------------------------------------------------------
# The core's dispatch chains, mirrored as predicates.
#
# Each predicate is a transcription of one production control-flow chain.
# The line references are the contract: if the chain moves, the predicate
# has to move with it, and the comment says where to look.
# ---------------------------------------------------------------------------

const
  Program = "/tmp/ct-caps-dispatch-check/app"
  TraceFolder = "/tmp/ct-caps-dispatch-check/out"

proc extensionSelector(extension: string, lang: Lang): RecorderSelector =
  ## The selector `ct record program<extension>` actually dispatches on: the
  ## ASSESSMENT's, not the per-`Lang` projection.
  ##
  ## This used to be `selectorOfLang(lang)`, on the stated ground that for an
  ## extension-detected single file the two agree — "the assessment only
  ## departs from it for a `.nims`, a directory, or an explicit `--lang`".
  ## **LRS-5's second deletion round added a fourth case and broke that
  ## ground**: a `.wasm` file is now `KindWasmModule` and therefore `tiWasm`
  ## from the KIND, where the ISA used to come from `axesOfLang(LangRustWasm)`
  ## — the member the round deleted.  `LANGS["wasm"]` is `LangRust`, whose
  ## projection is `tiNative`, so the old transcription reported `.wasm` as
  ## undispatchable and this checker failed on a capability file that is
  ## correct.  Asking the real assessment is both the fix and the more
  ## faithful transcription.
  assessedSelector("program" & extension, lang)

proc recordDispatches(extension: string, lang: Lang): bool =
  ## `ct record <program>` — src/ct/db_backend_record.nim, proc `record`,
  ## since LRS-2B a function of the ASSESSMENT's selector rather than of the
  ## `Lang`:
  ##
  ##   * `lang == LangUnknown`                          -> error, quit 1
  ##   * `not recorderToolFor(sel).isDeclared`         -> error, quit 1
  ##           (the rr/native family is the separate commercial
  ##            codetracer-rr-backend component's territory, per
  ##            CodeTracer-Launcher.md §2.3's second example file)
  ##   * Nim, wasm/ACIR, Python arms, then `tool.supported` -> recordDb / recordNim
  ##   * otherwise (declared, unsupported: Lua, GDScript)  -> error, quit 1
  if lang == LangUnknown:
    return false
  let tool = recorderToolFor(extensionSelector(extension, lang))
  if not tool.isDeclared:
    return false
  tool.supported

proc runDispatches(extension: string, lang: Lang): bool =
  ## `ct run <program>` — src/ct/trace/run.nim:121 detects the language
  ## and hands it to `runWithRestart`, which at :72 takes the recorded
  ## program straight from argv for a materialized-trace language and
  ## calls `record()` (src/ct/trace/record.nim:301), i.e. the *same*
  ## recorder dispatch as `ct record`. For a non-materialized language it
  ## builds first and needs `ctConfig.rrBackend.enabled`
  ## (record.nim:451) — the commercial rr-backend component again — so
  ## codetracer-desktop must not claim those extensions for `run` either.
  recordDispatches(extension, lang)

proc recordTestDispatches(extension: string, lang: Lang): bool =
  ## `ct record-test` — src/ct/trace/record.nim, proc `recordTest`:
  ##
  ##   * `not recorderToolFor(assessedSelector(path, lang)).isDeclared`
  ##           -> the rr-backend path (a different component); since LRS-2B
  ##           the route is asked of the assessment, not of
  ##           `usesMaterializedTraces`
  ##   * `elif lang == LangPythonDb`       -> the real pytest arm
  ##   * `else` -> "currently `ct record-test` not supported for
  ##           this db-based language", quit 1
  ##
  ## So the ONLY extension codetracer-desktop can honestly declare for
  ## `record-test` is Python's. `.rb` and `.nr` were declared before
  ## LRC-1 and both land on the `else`.
  recorderToolFor(extensionSelector(extension, lang)).isDeclared and
    lang == LangPythonDb

proc dispatches(command: string, extension: string, lang: Lang): bool =
  case command
  of "record": recordDispatches(extension, lang)
  of "run": runDispatches(extension, lang)
  of "record-test": recordTestDispatches(extension, lang)
  else: raise newException(CheckError, "unknown command: " & command)

proc coreExtensions(command: string): HashSet[string] =
  ## The extensions the core can serve `command` for, computed from the
  ## production `LANGS` table.
  for extension, lang in LANGS:
    if dispatches(command, "." & extension, lang):
      result.incl("." & extension)

const DeliberateOmissions: seq[string] = @[]
  ## Extensions the core CAN dispatch but that codetracer-desktop
  ## deliberately does NOT declare. Empty, and it should stay that way:
  ## an omission here is a routing hole, so anything added must carry a
  ## comment saying which component claims the extension instead.

# ---------------------------------------------------------------------------
# Capability-file reader.
#
# Tolerant line reader over the grammar in CodeTracer-Launcher.md §2.3.
# It is NOT a second implementation of the launcher's parser (that one is
# exercised, byte for byte, by ci/test/desktop_component_caps_check.nim
# against codetracer-launcher/src/caps.nim); it only enumerates what the
# file claims so the claims can be compared with the dispatch tables.
# ---------------------------------------------------------------------------

const
  KnownExtensionsKeyword = "known-extensions"
    ## The NTR-1 keyword. It is capability-file metadata, NOT a routable
    ## command: `caps.matches` skips the line outright
    ## (codetracer-launcher/src/caps.nim), so it must be reserved here too
    ## or the checker would compare it against the core's command set.
  NoextToken = "noext"
    ## The reserved routing token of rule NTR-R1 cases R1a/R1c. It is not
    ## an extension and has no `LANGS` entry, so it is separated out of
    ## the declared set below rather than compared against the core's
    ## dispatch tables — and its PRESENCE is asserted independently, so
    ## deleting it is a named failure rather than a silent one.

const ReservedKeywords = [
  "name", "version", "bin", "description", "help-delegate", "licensed",
  "project", "requires", KnownExtensionsKeyword]

proc declaredExtensions(path: string, command: string):
    tuple[found: bool, exts: HashSet[string], routingTokens: HashSet[string]] =
  ## Splits a command line's tokens into real extensions (leading '.')
  ## and the reserved routing tokens of rule NTR-R1. Anything that is
  ## neither shape stays in `exts` on purpose, so a typo is still caught
  ## by the comparison against the core.
  for rawLine in readFile(path).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"):
      continue
    let tokens = line.splitWhitespace()
    if tokens[0] in ReservedKeywords:
      continue
    if tokens[0] != command:
      continue
    result.found = true
    for token in tokens[1 .. ^1]:
      if token == NoextToken:
        result.routingTokens.incl(token)
      else:
        result.exts.incl(token)

proc knownExtensions(path: string): HashSet[string] =
  ## The `known-extensions` line: suffixes the core RECOGNIZES as naming
  ## a language but cannot dispatch. NTR-R1 case R1d — they never route,
  ## and they must never appear on a command line as well (that would be
  ## a claim to dispatch what the same file says is undispatchable).
  for rawLine in readFile(path).splitLines():
    let tokens = rawLine.strip().splitWhitespace()
    if tokens.len >= 2 and tokens[0] == KnownExtensionsKeyword:
      for token in tokens[1 .. ^1]:
        result.incl(token)

proc allLangsExtensions(): HashSet[string] =
  ## Every extension the core's `LANGS` table names, dispatchable or not.
  for extension, _ in LANGS:
    result.incl("." & extension)

type
  ProjectLine = object
    ## One parsed `project` line, in the launcher's own grammar.
    raw: string
    scoped: bool
      ## True when the line names the command it qualifies -- the LRS-2P form,
      ## `project <cmd> <marker>...`.  False for the legacy one-token form,
      ## `project <marker>`, which applies to the WHOLE COMPONENT.
    command: string     ## "" when unscoped
    markers: seq[string]

proc declaredProjectLines(path: string): seq[ProjectLine] =
  ## Parse every `project` line exactly the way `caps.projectMarkersFor`
  ## does: one token after the keyword is a marker; two or more make the
  ## first a command name.
  ##
  ## Transcribing the launcher's rule rather than importing it is a real cost
  ## and is paid on purpose.  This checker imports NOTHING from the launcher
  ## (the sibling `ci/test/desktop_component_caps_check.nim` is the one that
  ## compiles `codetracer-launcher/src/caps.nim`, via `--path`), and it could
  ## not usefully import this rule anyway: `projectMarkersFor` yields raw
  ## pointers into a `CapBuffer` and cannot be driven from Nim code that wants
  ## strings.  `ci/test/desktop-capabilities-dispatch.sh` mutation-tests this
  ## parse in BOTH directions -- a component-wide line is rejected and a
  ## correctly scoped one is accepted -- so the transcription cannot drift
  ## silently in either.
  for rawLine in readFile(path).splitLines():
    let tokens = rawLine.strip().splitWhitespace()
    if tokens.len >= 2 and tokens[0] == "project":
      if tokens.len >= 3:
        result.add(ProjectLine(raw: rawLine.strip(), scoped: true,
                               command: tokens[1],
                               markers: tokens[2 .. ^1]))
      else:
        result.add(ProjectLine(raw: rawLine.strip(), scoped: false,
                               command: "", markers: @[tokens[1]]))

proc declaredCommands(path: string): HashSet[string] =
  ## Every routable command the file declares -- the first token of a line
  ## that is not one of the metadata keywords.  Mirrors
  ## `caps.isReservedKeyword` plus `known-extensions`.
  const Reserved = ["name", "version", "bin", "description", "help-delegate",
                    "licensed", "requires", "project", "known-extensions"]
  result = initHashSet[string]()
  for rawLine in readFile(path).splitLines():
    let line = rawLine.strip()
    if line.len == 0 or line.startsWith("#"): continue
    let tokens = line.splitWhitespace()
    if tokens.len == 0: continue
    if tokens[0] in Reserved: continue
    result.incl(tokens[0])

proc sortedSeq(s: HashSet[string]): seq[string] =
  for item in s:
    result.add(item)
  result.sort()

proc render(s: HashSet[string]): string =
  if s.len == 0: "<none>" else: sortedSeq(s).join(" ")

# ---------------------------------------------------------------------------
# The checks.
# ---------------------------------------------------------------------------

proc checkCommand(capsPath, command: string) =
  echo ""
  echo "command `", command, "`"

  let (found, declared, routingTokens) = declaredExtensions(capsPath, command)
  expect(found, "`" & command & "` is declared in the capability file")

  # --- NTR-R1: the reserved routing token ----------------------------------
  # `record` and `run` must carry `noext`, or an extension-less argument
  # (a native binary, a directory, `--help`, a flag before the target)
  # stops reaching the core at all. `record-test` must NOT: it takes a
  # test file, and nothing in the core recognizes an extension-less one.
  if command in ["record", "run"]:
    expect(NoextToken in routingTokens,
      "`" & command & "` carries the reserved routing token `" & NoextToken &
      "` (rule NTR-R1 cases R1a/R1c — without it `ct " & command &
      " ./my-project`, `ct " & command & " --help` and `ct " & command &
      " a.out` are refused by the launcher)")
  else:
    expect(NoextToken notin routingTokens,
      "`" & command & "` does NOT carry `" & NoextToken &
      "` (only `record` and `run` accept an uninformative suffix)")

  let core = coreExtensions(command)
  expect(core.len > 0,
    "the core dispatches at least one extension for `" & command &
    "` (guards against a vacuous comparison of two empty sets)")

  echo "    declared: ", render(declared)
  echo "    core:     ", render(core)

  # --- FORWARD: nothing declared that the core cannot record ---------------
  let undispatchable = sortedSeq(declared - core)
  expect(undispatchable.len == 0,
    "every declared `" & command & " .ext` has a dispatch path in the core" &
    (if undispatchable.len == 0: ""
     else: " — but these do not: " & undispatchable.join(" ") &
       ". A declaration the core cannot honour makes the launcher route " &
       "`ct " & command & "` to a component that will refuse it"))

  # --- CONVERSE: nothing the core can record left undeclared ---------------
  var omissions = initHashSet[string]()
  for extension in DeliberateOmissions:
    omissions.incl(extension)
  let undeclared = sortedSeq(core - declared - omissions)
  expect(undeclared.len == 0,
    "every extension the core can `" & command & "` is declared" &
    (if undeclared.len == 0: ""
     else: " — but these are missing: " & undeclared.join(" ") &
       ". The launcher will refuse to route them (this is exactly the " &
       "`.js` bug LRC-1 exists to fix). Declare them, or add them to " &
       "DeliberateOmissions with a justification"))

  expect(declared == core,
    "`" & command & "` declares exactly the extensions the core dispatches (" &
      $core.len & ")")

  # --- Per-extension evidence, through the production entry points --------
  for extension in sortedSeq(declared):
    expect(extension.startsWith("."),
      "`" & command & "` extension " & extension &
      " is written with its leading dot (the launcher matches the token " &
      "including the dot — codetracer-launcher/src/caps.nim `matches`)")
    expect(extension == extension.toLowerAscii,
      "`" & command & "` extension " & extension & " is lowercase " &
      "(detectLangFromPath lowercases before the LANGS lookup)")

    let lang = detectLangFromPath("program" & extension)
    expect(lang != LangUnknown,
      "`" & command & " " & extension &
      "` : detectLangFromPath resolves it to " & lang.toName)
    expect(dispatches(command, extension, lang),
      "`" & command & " " & extension & "` : " & lang.toName &
      " reaches a dispatch arm")

    if command != "record-test":
      # The argv/env the recorder is actually spawned with. LangNim is the
      # one language whose argv is built by db_backend_record.nim's
      # `recordNim` (it compiles first, then hands off to ct-mcr) rather
      # than by the shared table, so the table is empty for it by design.
      if lang == LangNim:
        expect(recorderToolFor(selectorOfLang(lang)).recorderLabel.len > 0,
          "`" & command & " " & extension &
          "` : Nim names its recorder (argv is built by recordNim)")
      else:
        let invocation = recorderInvocation(
          extensionSelector(extension, lang), Program, TraceFolder)
        expect(invocation.args.len > 0,
          "`" & command & " " & extension &
          "` : recorder_dispatch builds a non-empty invocation")
        var envNamesFolder = false
        for (_, value) in invocation.env:
          if value == TraceFolder:
            envNamesFolder = true
        expect(TraceFolder in invocation.args or
               invocation.workdir.len > 0 or envNamesFolder,
          "`" & command & " " & extension &
          "` : the recorder is told where to write the trace")

when isMainModule:
  let args = commandLineParams()
  if args.len != 1:
    stderr.writeLine "usage: desktop_capabilities_dispatch_check <capabilities-file>"
    quit 2

  let capsPath = args[0]
  if not fileExists(capsPath):
    stderr.writeLine "error: no capability file at " & capsPath
    quit 1

  echo "capability-file ↔ record-dispatch conformance"
  echo "  file: ", capsPath

  try:
    for command in ["record", "run", "record-test"]:
      checkCommand(capsPath, command)

    # ----------------------------------------------------------------------
    # NTR-R1: `record` declared ∪ `known-extensions` is a PARTITION of LANGS.
    #
    # This is the invariant that makes rule R1c safe. R1c routes any suffix
    # that is declared by nobody AND known by nobody, on the reasoning that
    # such a suffix is one the core has never heard of. That reasoning is
    # only true if every LANGS extension is in exactly one of the two
    # halves: an extension missing from both would start routing to
    # codetracer-desktop, which would then refuse it — the silent-misroute
    # this checker exists to prevent, arriving through a new door.
    # ----------------------------------------------------------------------
    echo ""
    echo "NTR-R1 partition (record ∪ known-extensions == LANGS)"
    let known = knownExtensions(capsPath)
    let langs = allLangsExtensions()
    let (_, recordDeclared, _) = declaredExtensions(capsPath, "record")
    let (_, runDeclared, _) = declaredExtensions(capsPath, "run")

    echo "    known-extensions: ", render(known)
    echo "    LANGS:            ", $langs.len, " extensions"

    expect(known.len > 0,
      "the capability file declares a non-empty `known-extensions` line " &
      "(guards against a vacuous partition: with it empty the union check " &
      "would silently degrade into the declared==dispatched check)")

    for extension in sortedSeq(known):
      expect(extension.startsWith("."),
        "`known-extensions` entry " & extension & " is written with its " &
        "leading dot (the launcher compares the token including the dot)")
      expect(extension in langs,
        "`known-extensions` entry " & extension & " is a real LANGS " &
        "extension — a suffix the core does NOT recognize must be left off " &
        "the line entirely, so that rule R1c routes it")

    for command in ["record", "run", "record-test"]:
      let (_, declared, _) = declaredExtensions(capsPath, command)
      let overlap = sortedSeq(declared * known)
      expect(overlap.len == 0,
        "`" & command & "` and `known-extensions` are disjoint" &
        (if overlap.len == 0: ""
         else: " — but both claim: " & overlap.join(" ") &
           ". `known-extensions` means 'recognized and NOT dispatchable'; " &
           "declaring the same suffix for a command says the opposite"))

    for (command, declared) in [("record", recordDeclared), ("run", runDeclared)]:
      let missing = sortedSeq(langs - declared - known)
      expect(missing.len == 0,
        "every LANGS extension is either dispatched by `" & command &
        "` or listed on `known-extensions`" &
        (if missing.len == 0: ""
         else: " — but these are in neither: " & missing.join(" ") &
           ". Under rule NTR-R1 case R1c the launcher treats a suffix that " &
           "is declared by nobody and known by nobody as carrying no " &
           "routing information, so it would route to codetracer-desktop " &
           "and be refused there"))
      let strayKnown = sortedSeq(known - langs)
      expect(strayKnown.len == 0,
        "`known-extensions` names nothing outside LANGS (stray: " &
        strayKnown.join(" ") & ")")
      expect(declared + known == langs,
        "`" & command & "` ∪ `known-extensions` is exactly LANGS (" &
        $langs.len & " extensions: " & $declared.len & " dispatched + " &
        $known.len & " known-but-undispatchable)")

    echo ""
    echo "project markers"
    # ---------------------------------------------------------------------
    # LRS-2P replaced this assertion, and the replacement is STRONGER rather
    # than merely different.  It used to read `markers.len == 0`: no `project`
    # line at all.  That was the only safe rule available, because
    # `projectMarkerOutcome` read markers from the whole `CapBuffer` and the
    # router drops an unqualified match when a component declares markers and
    # none of them match -- so ONE `project Cargo.toml` line here would have
    # made `ct list` outside a Cargo project answer "no component handles
    # 'list'", for all 25 commands this file declares unqualified.
    #
    # `codetracer-launcher/src/caps.nim` now scopes a marker to the command it
    # qualifies, so the rule that keeps that catastrophe impossible is no
    # longer "declare none" but "declare none that is component-wide, and name
    # only commands you actually declare".  A file with no `project` lines
    # still passes, which is the state this file is in; what has changed is
    # that adding one is now possible AND still cannot strand a sibling
    # command.
    #
    # Both halves are mutation-tested by
    # ci/test/desktop-capabilities-dispatch.sh: a bare `project <marker>` is
    # rejected, a scoped line naming an undeclared command is rejected, and a
    # correctly scoped line is ACCEPTED -- the last one being what stops this
    # degenerating back into "no markers allowed" wearing a longer message.
    # ---------------------------------------------------------------------
    let projectLines = declaredProjectLines(capsPath)
    let commands = declaredCommands(capsPath)
    echo "    project lines:    ", $projectLines.len
    for line in projectLines:
      expect(line.scoped,
        "the `project` line `" & line.raw & "` is COMPONENT-WIDE (one token " &
        "after the keyword). The launcher drops an unqualified command match " &
        "when the component declares markers and none match the cwd, and this " &
        "file declares " & $commands.len & " commands unqualified -- so a " &
        "component-wide marker would make `ct list` (and `ct login`, and `ct " &
        "replay <id>`, ...) answer 'no component handles' outside a marked " &
        "directory. Write `project <command> " & line.markers.join(" ") &
        "` instead, naming the command the marker was written for")
      # Guarded by `line.scoped` so the two assertions are INDEPENDENTLY
      # load-bearing.  Found by mutation, 2026-09-22: with them unguarded, an
      # unscoped line has `command == ""`, which is never a declared command,
      # so the second assertion caught a component-wide marker even with the
      # first one disabled -- and a mutation of the first therefore SURVIVED.
      # The property was still enforced; what was missing was the ability to
      # tell which assertion was enforcing it.
      if not line.scoped: continue
      expect(line.command in commands,
        "the `project` line `" & line.raw & "` qualifies the command `" &
        line.command & "`, which this file does not declare. A marker for a " &
        "command nobody routes is dead text in a 4096-byte buffer, and it is " &
        "the shape a typo takes")
      for marker in line.markers:
        expect(marker.len > 0 and not marker.startsWith("-"),
          "the `project` marker `" & marker & "` is not a file name")

    echo ""
    if checks == 0:
      stderr.writeLine "FAIL: no checks ran — the checker itself is broken"
      quit 1
    echo "PASS: ", checks, " capability/dispatch assertions"
    quit 0
  except CheckError as e:
    stderr.writeLine ""
    stderr.writeLine "FAIL: " & e.msg
    quit 1
