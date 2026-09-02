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

  ConstraintFunction* = object
    name*: string
    kind*: ConstraintFunctionKind
    opcodes*: int

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

proc hasCounts*(report: ConstraintReport): bool =
  report.absence.len == 0 and report.functions.len > 0

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
  ## Build the whole report from `VfsResponse.acir_listing`.
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
  var acirRows = 0
  var currentBrillig = ""
  var brilligRows = 0

  proc flushAcir() =
    if currentAcir >= 0:
      functions.add ConstraintFunction(
        name: "func " & $currentAcir, kind: cfkAcir, opcodes: acirRows)
    currentAcir = -1
    acirRows = 0

  proc flushBrillig() =
    if currentBrillig.len > 0:
      functions.add ConstraintFunction(
        name: currentBrillig, kind: cfkUnconstrained, opcodes: brilligRows)
    currentBrillig = ""
    brilligRows = 0

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
      brilligRows = 0
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
        brilligRows += 1
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
      acirRows = 0
      continue

    if isAcirHeaderLine(line):
      continue

    if currentAcir >= 0:
      acirRows += 1

  flushAcir()
  flushBrillig()

  if functions.len == 0:
    return absentReport(
      "this compile's constraint listing named no functions, which a " &
      "compiled circuit cannot have — the listing was read but is not usable")

  ConstraintReport(package: package, functions: functions,
                   provenance: provenance, absence: "", stale: false)
