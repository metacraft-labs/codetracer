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
