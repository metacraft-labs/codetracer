## PLAT-42 — the flow overlay's per-line facts, from a real captured window.
##
## `FlowVM.styledLines` is what retired `PLAT22-PG2` ("the flow has no
## per-line fact"). It is computed by `flow_vm.flowLineFacts`, which parses the
## wire's view update and hands it to the desktop editor's own dimming rule,
## `ui/flow_line_styles.flowStyledLines`. So what this suite checks is the
## ADAPTER and the COMPOSITION, not a second copy of the rule:
##
##   * the real window `fixtures/flow/zk_shields_flow_window.json` (captured
##     from a `noir_space_ship` recording by `capture_zk_shields_flow.nim`)
##     yields exactly the lines its `relevantStepCount` names inside the
##     function's extent — read off the fixture here, not typed in;
##   * a declined arm WITH an extent dims its interior and not its header, and
##     the header — whose test was evaluated — is reported as having run;
##   * `NotTaken`'s wire ordinal is the enum's, so a reordering of
##     `BranchState` fails here instead of inverting which arms are dimmed;
##   * the native hosts' `FlowOverlayShownByDefault` agrees with the shipped
##     `default_config.yaml`'s `flow.enabled`.
##
## No mocks: `flowLineFacts` is a pure function of a `JsonNode`, and the one
## window that matters is a real capture.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_flow_line_facts.nim

import std/[algorithm, json, strutils, unittest]

import ../../viewmodels/flow_vm
import ../../../view_vocabulary/editor_surface
import ../../../../common/types except NotTaken, Taken, Unknown
from ../../../../common/types import BranchState

const
  FixtureJson = staticRead("../fixtures/flow/zk_shields_flow_window.json")
  DefaultConfigYaml = staticRead("../../../../config/default_config.yaml")

proc yamlFlowEnabled(raw: string): string =
  ## The value of `flow.enabled` in a flat two-level YAML file: the `enabled:`
  ## key indented UNDER the top-level `flow:` key. A top-level key ends the
  ## block, so an `enabled:` belonging to another section is not read.
  var inFlow = false
  for line in raw.splitLines():
    if line.len == 0 or line.strip().startsWith("#"):
      continue
    let indented = line[0] in {' ', '\t'}
    if not indented:
      inFlow = line.strip() == "flow:"
      continue
    if inFlow:
      let kv = line.strip().split(':', maxsplit = 1)
      if kv.len == 2 and kv[0].strip() == "enabled":
        return kv[1].strip()
  ""

proc positions(facts: seq[FlowStyledLine]; kind: FlowLineStyleKind): seq[int] =
  for f in facts:
    if f.kind == kind:
      result.add f.position

suite "PLAT-42: the flow overlay's per-line facts":

  test "the real captured window yields the lines that ran, and only those":
    let view = parseJson(FixtureJson)["viewUpdate"]
    let first = view["location"]["functionFirst"].getInt
    let last = view["location"]["functionLast"].getInt
    # The expectation is READ OFF THE FIXTURE rather than typed in, so it is
    # the wire's own statement of which lines have a step: every
    # `relevantStepCount` entry inside `(functionFirst, functionLast]`, minus
    # comment lines, once each.
    var comments: seq[int] = @[]
    for n in view["commentLines"]: comments.add n.getInt
    var expected: seq[int] = @[]
    for n in view["relevantStepCount"]:
      let line = n.getInt
      if line > first and line <= last and line notin comments and
         line notin expected:
        expected.add line
    check expected.len > 0
    let facts = flowLineFacts(view)
    var hits = facts.positions(flskHit)
    hits.sort()
    expected.sort()
    check hits == expected
    # This window records no arm extents, so nothing may be dimmed: a state
    # without a span is not a claim about any line.
    check facts.positions(flskSkip).len == 0
    # And the translation every medium uses agrees.
    for line in expected:
      check flowStateOf(facts, line) == efsTaken
    check notTakenLinesOf(facts).len == 0

  test "a declined arm dims its interior, and its header counts as having run":
    # The captured window, with one if/else added inside the function's
    # extent: the header on line 3 declined the arm spanning lines 4-5. The
    # rest of the window is the capture's.
    var view = parseJson(FixtureJson)["viewUpdate"]
    view["location"]["functionFirst"] = %0
    view["location"]["functionLast"] = %8
    view["branchesTaken"][0].elems[0] = %*{
      "table": {"3": FlowWireNotTakenOrdinal},
      "extents": {"3": {"firstLine": 4, "lastLine": 5}}}
    let facts = flowLineFacts(view)
    check facts.positions(flskSkip) == @[4, 5]
    check 3 in facts.positions(flskHit)
    check 4 notin facts.positions(flskHit)
    check flowStateOf(facts, 4) == efsNotTaken
    check flowStateOf(facts, 3) == efsTaken
    check notTakenLinesOf(facts) == @[4, 5]
    # One entry per line, in line order — `notTakenLinesOf` and every reader
    # of `styledLines` rely on it.
    for i in 1 ..< facts.len:
      check facts[i - 1].position < facts[i].position

  test "an Unknown header carries no claim, and a header outside the function is ignored":
    var view = parseJson(FixtureJson)["viewUpdate"]
    view["location"]["functionFirst"] = %0
    view["location"]["functionLast"] = %8
    view["relevantStepCount"] = %*[]
    view["branchesTaken"][0].elems[0] = %*{"table": {"3": 0, "40": 1}}
    check flowLineFacts(view).len == 0

  test "malformed input answers empty rather than raising":
    check flowLineFacts(nil).len == 0
    check flowLineFacts(%*[]).len == 0
    check flowLineFacts(%*{}).len == 0
    check flowLineFacts(%*{"branchesTaken": [], "location": {}}).len == 0

  test "the wire ordinals of NotTaken and Taken are the enum's":
    check FlowWireNotTakenOrdinal == ord(BranchState.NotTaken)
    # `Taken` joined `NotTaken` as a `mixin`ed constant when the dimming rule
    # learned that an arm entered on ANY pass outranks the file-wide sweep's
    # claim that it was not (issue #758). Both are ordinals duplicated out of
    # the enum, so both are pinned to it here: a reordering of `BranchState`
    # would otherwise silently swap which arms are dimmed.
    check FlowWireTakenOrdinal == ord(BranchState.Taken)
    check FlowWireTakenOrdinal != FlowWireNotTakenOrdinal

  test "the native hosts' overlay default is the shipped config's":
    let enabled = yamlFlowEnabled(DefaultConfigYaml)
    check enabled in ["true", "false"]
    check FlowOverlayShownByDefault == (enabled == "true")
