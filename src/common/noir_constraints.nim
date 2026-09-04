## What a Noir circuit costs, as `nargo` reports it.
##
## ## Why this shape, and not the one §1a draws
##
## `Planned-Features/Noir-Studio.md` §1a's mock-up shows a per-module roll-up::
##
##     CONSTRAINTS
##      total            14
##      main             9
##      utils::check     5
##
## That is not what the toolchain produces, and the reason is a property of
## the language rather than a gap in the tooling. Noir INLINES every function
## that is not `#[fold]`, so a circuit has one ACIR function per fold boundary
## — for the bundled template, exactly one. Measured against the real producer
## on the real template::
##
##     $ nargo info --json
##     {"programs":[{"package_name":"hello_noir",
##       "functions":[{"name":"main","opcodes":17}],
##       "unconstrained_functions":[
##         {"name":"directive_invert","opcodes":9},
##         {"name":"directive_integer_quotient","opcodes":8}]}]}
##
## `utils::assert_in_range` has no row because it is not a separate circuit —
## its cost is inside `main`'s 17. A pane that showed `main 9 / utils::check 5`
## would be inventing an attribution the compiler did not make, and it would
## teach a visitor a cost model Noir does not have. This is the same class of
## error `platform/noir_template.nim` already records against the same
## mock-up's `tests/` directory: the picture is a sketch, and where it
## disagrees with the toolchain the toolchain is right.
##
## Per-module attribution IS obtainable, and it is named here rather than
## approximated: it needs `noir-profiler`'s per-opcode walk of
## `debug_symbols` (`tooling/profiler/src/cli/opcodes_flamegraph_cmd.rs`),
## which maps each `OpcodeLocation::Acir(index)` to a source call stack.
## `noir-profiler` is not in CodeTracer's nix closure. Until it is, the honest
## roll-up is per ACIR function, which is what this module models.
##
## ## ACIR opcodes are not gates, and the pane must not conflate them
##
## `nargo info` counts ACIR opcodes. Proof-system GATE counts come from a
## proving backend (`bb gates --include_gates_per_opcode`), and Barretenberg is
## not packaged here at all. So `kind` is part of the model: every row says
## which of the two currencies it is counted in, and nothing adds them up
## across kinds.
##
## ## Why a shared module rather than a frontend one
##
## Two hosts answer the same question. The desktop runs `nargo info --json` in
## the index process; the web build has no `nargo`, no subprocess and no `info`
## export in the wasm module, so it carries the template's counts as data
## produced by the same command at build time. One parser, one shape, two
## sources — the property `Noir-Studio.md` §3 asks for, applied to a producer
## instead of a pane.

import std/[json, strutils]

type
  ConstraintFunctionKind* = enum
    ## Which currency a row is counted in. Never summed across kinds.
    cfkAcir = "acir"
      ## A constrained ACIR function — `nargo info`'s `functions` array. This
      ## is the number that governs proving cost.
    cfkUnconstrained = "unconstrained"
      ## A Brillig function — `nargo info`'s `unconstrained_functions`. These
      ## execute but are not constrained, so their opcodes cost witness
      ## generation time and not proof size.

  ConstraintOpcode* = object
    ## ONE PRINTED ROW OF THE COMPILER'S OWN LISTING, kept rather than tallied.
    ##
    ## `reportFromAcirListing` used to read these rows and keep only how many
    ## there were. That made the count honest — it is derived from the compile
    ## the pane describes — and it threw away the thing a reader actually asked
    ## for. `Noir-Studio.md` §9.2 is explicit that the constraint view IS a
    ## generated-code listing, in the shape `low_level_code_vm`'s
    ## `LowLevelInstruction` already carries: an index, an opcode name and its
    ## operands. So the split is the same one
    ## `ci/test/low_level_code_browser_probe.nim` makes — first token is the
    ## name, the remainder is the arguments — and not a new vocabulary.
    index*: int
      ## The opcode's position in its function, 0-based. THIS IS THE ANCHOR
      ## KEY: `debug_symbols.acir_locations` is an opcode-indexed map, so a row
      ## that did not carry its index could never be tied to a source span.
      ## Nothing anchors yet; the index is kept so that it can.
    name*: string
      ## `ASSERT`, `BRILLIG CALL`, `BLACKBOX::RANGE` — the first token as the
      ## compiler printed it.
    args*: string
      ## Everything after the first token, verbatim. NOT re-formatted: the
      ## compiler's spacing is the compiler's, and a pane that tidied it would
      ## be showing something other than what was generated.

  ConstraintFunction* = object
    name*: string
    kind*: ConstraintFunctionKind
    opcodes*: int
      ## How many opcodes this function has. Kept when there are `rows`, and
      ## then it is exactly `rows.len` — see `reportFromAcirListing`, which
      ## derives it rather than accumulating a separate tally, so a total and
      ## the listing under it cannot disagree about the same compile.
    rows*: seq[ConstraintOpcode]
      ## The listing itself, when there is one. EMPTY IS A REAL STATE and not
      ## a defect: `parseNargoInfoJson` reports counts from `nargo info`, which
      ## prints no opcodes at all, so a report from that producer has counts
      ## and no rows. `hasListing` is what tells the two apart, and the pane
      ## says which it is holding rather than rendering an empty body.

  ConstraintReport* = object
    ## One `nargo info` answer, or a stated absence of one.
    package*: string
    functions*: seq[ConstraintFunction]
    provenance*: string
      ## How these numbers were obtained, in a sentence a user can read. The
      ## pane shows it, because "17" means different things depending on
      ## whether it was measured a second ago or shipped with the bundle.
    absence*: string
      ## Non-empty when there is no report, and then it is the WHOLE content
      ## of the pane: a plain statement of what could not be produced and why.
      ## §1b.3 step 6's rule, applied to a pane instead of a route — "never a
      ## blank editor, never an error page".
    stale*: bool
      ## The sources changed after these counts were produced. A stale number
      ## is worse than no number if it is not labelled, because it looks
      ## exactly like a current one.
    compiling*: bool
      ## A compile that will replace this report is IN FLIGHT.
      ##
      ## THE THIRD STATE, and the reason it is a field rather than a spinner.
      ## This pane's original defect was that its two states were "a number"
      ## and "no number"; making the listing arrive without a gesture adds a
      ## window — between the page mounting and the first compile answering —
      ## in which the pane holds counts it is about to replace. Left unlabelled
      ## that window reads as ABSENCE (the `nargo info` caption says "Build the
      ## project", which is advice for a build that is already running), and a
      ## reader who acted on it would press a key that is refused by
      ## `startNoirBuild`'s `already-running` guard.
      ##
      ## So it is stated. `listingNoticeFor` says a compile is running instead
      ## of telling the reader to start one, and `containerClass` adds
      ## `compiling` so the rows can be styled without the sentence and the
      ## styling ever disagreeing.
      ##
      ## NOT DERIVED FROM `BuildVM.isRunning`, which is the signal the BUILD
      ## pane's ▶/■ read. That one is true for a `nargo test` and a `nargo
      ## trace` as well, neither of which produces a constraint listing, so a
      ## pane bound to it would announce a compile during a test run and then
      ## never replace the counts it promised to replace. This field is set by
      ## the COMPILE phase and by nothing else.
      ##
      ## Cleared by any settle, including a refusal — see
      ## `constraints_vm.noteCompileSettled` for why a failure has to clear it
      ## rather than leave the pane claiming progress that stopped.
    listingAbsence*: string
      ## Why this report has counts but no printed rows, when the reason is
      ## something the pane was TOLD rather than something it can infer.
      ##
      ## DISTINCT FROM `absence`, which is the whole content of the pane and
      ## means there is nothing to show at all. This one is a caption on a pane
      ## that still has counts in it: the compile worked, the totals stand, and
      ## the generated code specifically could not be obtained. Collapsing the
      ## two is what made a successful build blank a correct pane — see
      ## `constraints_vm.noteListingUnavailable`.
      ##
      ## Empty means "no special reason", and then `listingNoticeFor` supplies
      ## the ordinary one: `nargo info` reports totals and prints no opcodes.

proc hasCounts*(report: ConstraintReport): bool =
  report.absence.len == 0 and report.functions.len > 0

proc hasListing*(report: ConstraintReport): bool =
  ## Whether this report carries the compiler's printed rows, and not only how
  ## many of them there were.
  ##
  ## THE DISTINCTION THE PANE IS FOR. A report from `nargo info` has counts and
  ## no rows; a report from an ACIR listing has both. Rendering an empty body
  ## for the first would be a pane that looks broken rather than one that is
  ## holding a different kind of answer, so the view asks this and says so.
  if report.absence.len > 0:
    return false
  for fn in report.functions:
    if fn.rows.len > 0:
      return true
  false

proc totalRows*(report: ConstraintReport): int =
  ## How many printed rows the whole report carries, across every function.
  ## Used by the headline to say how much listing there is to read.
  for fn in report.functions:
    result += fn.rows.len

proc splitOpcodeRow*(index: int; text: string): ConstraintOpcode =
  ## One printed line, split into the name/args shape the generated-code
  ## listing already uses.
  ##
  ## The rule is `ci/test/low_level_code_browser_probe.nim:listingRows`'s,
  ## verbatim: split ONCE on the first space. `BRILLIG CALL func: 0, ...`
  ## therefore has the name `BRILLIG` and the arguments `CALL func: 0, ...`,
  ## which is not a tokenisation anybody would choose from scratch — and it is
  ## the one the Low Level Code pane's rows are already built with. Matching it
  ## keeps one row shape in the product; inventing a better split here would
  ## give the same opcode two different renderings in two panes, which §1a.1's
  ## "no pane is invented for the web" exists to prevent.
  let trimmed = text.strip()
  let parts = trimmed.split(' ', 1)
  ConstraintOpcode(
    index: index,
    name: (if parts.len > 0: parts[0] else: trimmed),
    args: (if parts.len > 1: parts[1] else: ""))

proc totalFor*(report: ConstraintReport; kind: ConstraintFunctionKind): int =
  for fn in report.functions:
    if fn.kind == kind:
      result += fn.opcodes

proc acirTotal*(report: ConstraintReport): int =
  report.totalFor(cfkAcir)

proc unconstrainedTotal*(report: ConstraintReport): int =
  report.totalFor(cfkUnconstrained)

proc absentReport*(reason: string): ConstraintReport =
  ## The only way to build a report with no numbers in it. Named so that a
  ## caller cannot produce an empty-but-not-absent report by accident — an
  ## empty `functions` with an empty `absence` would render as a pane that
  ## says nothing at all, which is the placeholder this module exists to
  ## refuse.
  ConstraintReport(package: "", functions: @[], provenance: "",
                   absence: reason, stale: false)

proc parseNargoInfoJson*(text: string; provenance: string): ConstraintReport =
  ## Parse `nargo info --json`.
  ##
  ## The flag is documented in the compiler as hidden and unstable — "changes
  ## to this format are not currently considered breaking"
  ## (`tooling/nargo_cli/src/cli/info_cmd.rs`) — so every field access here is
  ## guarded and a shape this does not recognise becomes an ABSENCE with the
  ## reason in it, never a silently empty pane. A parser that returned zero
  ## rows for an unreadable answer would be indistinguishable from a circuit
  ## with no opcodes.
  ##
  ## Only the FIRST program is read. `nargo info` reports one program per
  ## package in a workspace; a pane is showing one project, and picking a
  ## package silently out of several would be a worse answer than saying so.
  if text.strip().len == 0:
    return absentReport("nargo info produced no output")

  var parsed: JsonNode
  try:
    parsed = parseJson(text)
  except:
    # A BARE `except`, and it is required rather than lax — CONTRIBUTING.md's
    # portability rule covers exactly this case. On the C backend `parseJson`
    # raises `JsonParsingError`, which `CatchableError` catches. On the JS
    # backend it is `JSON.parse` underneath, and a malformed document raises a
    # native `SyntaxError`: a FOREIGN exception, which `except CatchableError`
    # does not catch and which therefore escaped as an unhandled error in the
    # renderer.
    #
    # Found by running this module's suite on both backends rather than one:
    # `test_ns9_panes_vm` passed on C and died on JS with
    # `Unhandled exception: Unexpected token 'o', "not json at all" is not
    # valid JSON [<foreign exception>]`. In a browser that would have taken
    # the whole renderer down on a `nargo info` answer this parser exists to
    # reject politely.
    return absentReport(
      "nargo info did not produce JSON that could be parsed; the --json " &
      "flag is documented as unstable, so this most likely means the " &
      "toolchain changed its output shape")

  if parsed.kind != JObject or not parsed.hasKey("programs"):
    return absentReport("nargo info's answer has no `programs` array")
  let programs = parsed["programs"]
  if programs.kind != JArray or programs.len == 0:
    return absentReport("nargo info reported no programs for this project")

  let program = programs[0]
  if program.kind != JObject:
    return absentReport("nargo info's first program is not an object")

  result = ConstraintReport(
    package:
      if program.hasKey("package_name") and program["package_name"].kind == JString:
        program["package_name"].getStr()
      else: "",
    functions: @[], provenance: provenance, absence: "", stale: false)

  proc collect(node: JsonNode; kind: ConstraintFunctionKind;
               into: var seq[ConstraintFunction]) =
    if node.isNil or node.kind != JArray:
      return
    for entry in node:
      if entry.kind != JObject: continue
      let name =
        if entry.hasKey("name") and entry["name"].kind == JString:
          entry["name"].getStr()
        else: ""
      let opcodes =
        if entry.hasKey("opcodes") and entry["opcodes"].kind == JInt:
          entry["opcodes"].getInt()
        else: -1
      if name.len == 0 or opcodes < 0: continue
      into.add ConstraintFunction(name: name, kind: kind, opcodes: opcodes)

  if program.hasKey("functions"):
    collect(program["functions"], cfkAcir, result.functions)
  if program.hasKey("unconstrained_functions"):
    collect(program["unconstrained_functions"], cfkUnconstrained,
            result.functions)

  if result.functions.len == 0:
    return absentReport(
      "nargo info reported a program with no functions, which a compiled " &
      "circuit cannot have — the answer was understood but is not usable")

# ---------------------------------------------------------------------------
# A report the PANE COMPUTED, from the compile it is describing
# ---------------------------------------------------------------------------
#
# Everything above turns `nargo info`'s JSON into a report. That JSON cannot be
# produced in a browser, so the web pane shipped a compile-time constant of it
# instead — and `Generated-Code-Listing.md` §15.4 records what that cost: the
# constant was measured by the NATIVE toolchain and rendered by the WEB engine,
# which are different compilers, so it was wrong by two opcodes for every
# visitor while a gate that compared it against the wrong `nargo` certified it.
#
# These procedures remove the need for it. Both derive the counts from the
# artefact of the compile the pane is describing, so the number and the thing
# it describes cannot drift apart: a number the pane computes cannot be stale
# with respect to itself.

type
  AcirCountRead* = object
    ## An opcode count, or a stated reason there is not a trustworthy one.
    count*: int
    ok*: bool
    reason*: string
      ## Empty when `ok`. Otherwise why the artefact could not be counted,
      ## phrased for a pane rather than a log.

proc acirCountFromDebugInfo*(debugSymbols: JsonNode): AcirCountRead =
  ## The ACIR opcode count, from a DECODED `debug_symbols`.
  ##
  ## `debug_symbols` is base64 of RAW deflate; decoding it is transport's job
  ## (`Generated-Code-Listing.md` GCL-D7) and this takes the decoded node, for
  ## the same reason `noir_anchor_producer` does — so it runs in both ViewModel
  ## lanes with no compression library.
  ##
  ## ## Why this REFUSES a sparse map instead of counting its keys
  ##
  ## `acir_locations` is a `BTreeMap<AcirOpcodeLocation, CallStackId>` in the
  ## compiler. A map permits gaps: an opcode carrying no source location is
  ## simply absent, and then `len` is not the opcode count — it is the count of
  ## opcodes that happened to be attributable, which is a smaller number that
  ## looks exactly like the right one.
  ##
  ## Measured dense (`0..n-1`, contiguous) on every artefact this campaign
  ## produced — native beta.2, native beta.26, and the wasm module's own
  ## `program` compile. That is evidence and not a guarantee, so the density is
  ## CHECKED here rather than relied upon, and a sparse map produces a stated
  ## absence instead of a confident undercount. §4's rule: this pane's failure
  ## mode is a plausible wrong answer, so an unverifiable number is refused.
  ##
  ## The `debug` compile legitimately yields ZERO entries — `force_brillig`
  ## moves every instruction into an unconstrained function and leaves no
  ## located ACIR opcode at all (GCL-D9, measured through the wasm module). So
  ## an empty map is reported as "this artefact has no constrained opcodes",
  ## which is true of it, rather than as a fault.
  if debugSymbols.isNil or debugSymbols.kind != JObject:
    return AcirCountRead(count: 0, ok: false,
      reason: "the compiler's debug symbols were not readable, so the " &
              "opcode count could not be taken from this compile")

  var circuit = debugSymbols
  if circuit.hasKey("debug_infos"):
    let infos = circuit["debug_infos"]
    if infos.kind != JArray or infos.len == 0:
      return AcirCountRead(count: 0, ok: false,
        reason: "the compiler's debug symbols carry no circuit")
    circuit = infos[0]

  if circuit.isNil or circuit.kind != JObject:
    return AcirCountRead(count: 0, ok: false,
      reason: "the compiler's debug symbols carry no circuit")

  # `acir_locations` is the current spelling; `locations` is what compilers
  # before the call-stack tree emitted. Both are opcode-indexed maps, and the
  # newer is tried first so a compiler emitting both is not read by the older
  # path — the same precedence `noir_anchor_producer.readArtefact` uses.
  var located: JsonNode = nil
  if circuit.hasKey("acir_locations"):
    located = circuit["acir_locations"]
  elif circuit.hasKey("locations"):
    located = circuit["locations"]

  if located.isNil or located.kind != JObject:
    return AcirCountRead(count: 0, ok: false,
      reason: "the compiler's debug symbols name no opcode locations, so " &
              "the opcode count could not be taken from this compile")

  var indices: seq[int] = @[]
  for key, _ in located:
    var index = -1
    try:
      index = parseInt(key)
    except CatchableError:
      index = -1
    if index < 0:
      return AcirCountRead(count: 0, ok: false,
        reason: "the compiler's debug symbols are keyed by something that " &
                "is not an opcode index")
    indices.add index

  if indices.len == 0:
    return AcirCountRead(count: 0, ok: true, reason: "")

  var maxIndex = -1
  for index in indices:
    if index > maxIndex: maxIndex = index

  # A map whose largest index runs far past its entry count is not something to
  # allocate a bitmap for. The bound is generous — no circuit this pane opens is
  # near it — and it exists so a malformed artefact cannot ask for a huge
  # allocation on the strength of one absurd key.
  const SparsityBound = 1 shl 20
  if maxIndex >= SparsityBound or maxIndex >= indices.len + SparsityBound:
    return AcirCountRead(count: 0, ok: false,
      reason: "the compiler's opcode indices are too far apart to describe a " &
              "circuit this pane can count")

  var seen = newSeq[bool](maxIndex + 1)
  for index in indices:
    seen[index] = true

  # THE GAP IS NAMED, and named before the count is. `len` on a map with a hole
  # is the number of ATTRIBUTABLE opcodes — smaller than the circuit, and
  # indistinguishable from the right answer once it reaches a headline.
  for index, present in seen:
    if not present:
      return AcirCountRead(count: 0, ok: false,
        reason: "the compiler left opcode " & $index & " unlocated, so the " &
                "located count is smaller than the circuit and would be a " &
                "confident wrong answer")

  AcirCountRead(count: maxIndex + 1, ok: true, reason: "")

proc isAcirHeaderLine(line: string): bool =
  ## The four lines `display_compiled_program` prints before the opcodes.
  ##
  ## GCL-D6: these are NOT rows. `func 0`, `private parameters:`,
  ## `public parameters:` and `return values:` precede every ACIR function, and
  ## counting them would make the total wrong by a constant four per function —
  ## the most plausible-looking failure available here, since the number would
  ## still look like an opcode count.
  let text = line.strip()
  text.startsWith("func ") or
    text.startsWith("private parameters:") or
    text.startsWith("public parameters:") or
    text.startsWith("return values:")

proc reportFromAcirListing*(listing: string; package: string;
                            provenance: string): ConstraintReport =
  ## Build the whole report from `VfsResponse.acir_listing` — THE ROWS AND THE
  ## COUNTS, from one reading of one artefact.
  ##
  ## ## What this used to throw away
  ##
  ## The first version of this procedure parsed the listing and kept only how
  ## many rows it had seen. That was the right correction to make first — the
  ## number stopped being a constant measured by a different compiler — and it
  ## left the pane doing the one thing a reader had not asked for. A user
  ## opening CONSTRAINTS wants to READ the generated code; "17" is a summary of
  ## a document the pane had already parsed and then discarded.
  ##
  ## So the rows are kept. `opcodes` is now `rows.len` rather than a parallel
  ## tally, which is what makes the headline and the listing beneath it two
  ## views of one quantity instead of two quantities that agree today.
  ##
  ## ## Why the LISTING and not `nargo info`
  ##
  ## They are the same numbers. `nargo info`'s opcode total for a function IS
  ## the number of rows the listing prints for it, because the listing prints
  ## one row per opcode — measured equal on the bundled template at 15 under
  ## one compiler and at 17 under another, and equal at both. So the listing
  ## answers everything `nargo info` answers, from an artefact the browser
  ## already has, and `nargo info` cannot run in a tab.
  ##
  ## It answers the unconstrained half too, and by NAME:
  ## `unconstrained func 0: directive_invert` heads a block of numbered rows.
  ## Measured on the bundled template, the listing gives `directive_invert` 9
  ## opcodes and `directive_integer_quotient` 8 — the same two names and the
  ## same two counts `nargo info` reports for it.
  ##
  ## So this is the whole of §15.3's "one artefact, one provenance, one
  ## timestamp": the counts and the listing are the same reading of the same
  ## compile, and there is nothing left for them to disagree about.
  ##
  ## ACIR functions are named as the compiler prints them — `func 0` — and not
  ## as `main`. The listing does not say which source function a circuit came
  ## from, and inventing the name would be a positional claim this artefact
  ## does not support (§4).
  if listing.strip().len == 0:
    return absentReport(
      "this compile produced no constraint listing, so there are no counts " &
      "to show for it")

  var functions: seq[ConstraintFunction] = @[]
  var currentAcir = -1
  var acirRows: seq[ConstraintOpcode] = @[]
  var currentBrillig = ""
  var brilligRows: seq[ConstraintOpcode] = @[]

  # THE COUNT IS `rows.len`, NOT A SEPARATE TALLY. The two used to be one
  # integer incremented per line; keeping the rows and *also* counting them
  # would reintroduce the exact drift this module spent a commit removing, one
  # level down — a headline that disagrees with the listing printed beneath it,
  # on the same compile, in the same pane. There is nothing to reconcile if
  # there is only one quantity.
  proc flushAcir() =
    if currentAcir >= 0:
      functions.add ConstraintFunction(
        name: "func " & $currentAcir, kind: cfkAcir,
        opcodes: acirRows.len, rows: acirRows)
    currentAcir = -1
    acirRows = @[]

  proc flushBrillig() =
    if currentBrillig.len > 0:
      functions.add ConstraintFunction(
        name: currentBrillig, kind: cfkUnconstrained,
        opcodes: brilligRows.len, rows: brilligRows)
    currentBrillig = ""
    brilligRows = @[]

  for rawLine in listing.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue

    if line.startsWith("unconstrained func "):
      flushAcir()
      flushBrillig()
      # `unconstrained func 0: directive_invert` — the name is what a user
      # sees in `nargo info`, so it is carried through rather than renumbered.
      let colon = line.find(':')
      currentBrillig =
        if colon >= 0 and colon + 1 < line.len: line[colon + 1 .. ^1].strip()
        else: line["unconstrained func ".len .. ^1].strip()
      if currentBrillig.len == 0:
        currentBrillig = line
      brilligRows = @[]
      continue

    if currentBrillig.len > 0:
      # Brillig rows are `<index>: <opcode>`; anything else ends the block.
      let colon = line.find(':')
      var index = -1
      if colon > 0:
        try:
          index = parseInt(line[0 ..< colon].strip())
        except CatchableError:
          index = -1
      if index >= 0:
        # THE INDEX IS THE COMPILER'S, not this loop's. Brillig rows are
        # printed `<index>: <opcode>`, so the number is already on the line and
        # re-deriving it from the row's position would silently renumber a
        # listing the compiler chose to number itself. The opcode text is what
        # follows the colon.
        let body =
          if colon + 1 < line.len: line[colon + 1 .. ^1].strip() else: ""
        brilligRows.add splitOpcodeRow(index, body)
        continue
      flushBrillig()

    if line.startsWith("func "):
      flushAcir()
      var index = -1
      try:
        index = parseInt(line["func ".len .. ^1].strip())
      except CatchableError:
        index = -1
      currentAcir = max(index, 0)
      acirRows = @[]
      continue

    if isAcirHeaderLine(line):
      continue

    if currentAcir >= 0:
      # ACIR rows are NOT numbered by the compiler — `display_compiled_program`
      # prints the opcode alone. The index is therefore this row's position in
      # its function, which is exactly what `acir_locations` is keyed by, so a
      # later change can anchor a row to a source span without renumbering
      # anything. GCL-D6's four header lines are skipped above and so never
      # take an index, which is what keeps that key aligned.
      acirRows.add splitOpcodeRow(acirRows.len, line)

  flushAcir()
  flushBrillig()

  if functions.len == 0:
    return absentReport(
      "this compile's constraint listing named no functions, which a " &
      "compiled circuit cannot have — the listing was read but is not usable")

  ConstraintReport(package: package, functions: functions,
                   provenance: provenance, absence: "", stale: false)
