## test_variables_tree_expansion.nim — CTUI-7, Tier 1, on a real trace.
##
## ## What this suite establishes
##
## CTUI-7: "expands a real struct from the fixture, asserts its actual fields
## appear, collapses it, and asserts the children are released rather than
## merely hidden."
##
## All three, on `wide_state`, against the engine's own answer:
##
##   * A REAL COMPOUND VALUE, not a constructed one. The session jumps to the
##     recursive call the CALLTRACE reports, steps out into `main`, and reads
##     the locals `StateVM.currentVariables` holds there. One of them is a
##     600-entry mapping and another is the two-field tuple that is one of its
##     entries; both are expanded here.
##   * ITS ACTUAL FIELDS, checked against the PROGRAM. `main.py` builds the
##     mapping as `mapping["key_%03d" % index] = index * 2`, and this suite
##     reads that rule OUT OF THE SOURCE FILE at the path the BACKEND reported
##     before asserting the members against it — so an edit to the program
##     reddens the file instead of silently changing what "its actual fields"
##     means.
##   * RELEASED, NOT HIDDEN. `VariablesModel.heldNodes` is the number of
##     materialised member objects, and it is asserted to be ZERO after a
##     collapse — including for a GRANDCHILD, which a one-level release would
##     leave alive under a node nothing can reach. Counting rows would not find
##     that: a pane that merely stopped drawing a 600-member node keeps 600
##     objects per collapsed node and draws exactly the same screen.
##
## ## AND ONE LIMITATION, MEASURED ON EVERY RUN RATHER THAN QUOTED
##
## CTUI-6 recorded that per-frame variables are not fetched and carried
## `StackFrame.id` for the `scopes` / `variables` request CTUI-7 would make.
## CTUI-7 does not make it, because the engine does not answer it — and this
## suite MEASURES that rather than citing it. DAP `variables` is sent once per
## frame with each frame's own `variablesReference`, and the answers are
## asserted to be IDENTICAL and to equal the current step's own locals.
##
## That is a sharper statement than "the answer is empty", which was the first
## draft and which a stop with no locals would have satisfied for free: measured
## here (2026-09-06) both frames answer the SAME sixteen variables at a stop
## where `ct/load-locals` answers sixteen. It is an EQUALITY, so the day
## `Handler::variables` stops ignoring its argument the suite goes red and says
## the per-frame arm is now buildable — the same construction
## `test_multi_thread_selection.nim` uses for the thread blocker.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`, WHICH IS WHERE CTUI-7 NAMES IT
##
## The same reason CTUI-5 and CTUI-6 recorded, unchanged:
## `tests/test_tui_facade_boundary.nim` walks every `.nim` under
## `src/frontend/tui/app/` and fails on an import resolving to
## `headless_session`. The `tui` lane globs both directories identically, so
## nothing about the coverage changes; the path does.
##
## ## The 39 MB per stop CTUI-1 measured
##
## Every navigation makes `replay-server` push events the session buffers until
## somebody asks for them, and on this fixture each stop's events carry the
## 600-member mapping. `drainEvents()` after each one is here for that reason
## and not as housekeeping.
##
## ## No mocks
##
## A real `.ct` trace recorded by the real Python recorder, opened by a real
## `replay-server`.
##
## ## Templates, not procs, for anything that calls `check`

import std/[json, os, sequtils, sets, strutils, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel

import headless_session
import store/[replay_data_store, types]

import ../app/variables_binding
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 83

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "wide_state"
  RecursiveFunction = "descend"
    ## Used only to NAVIGATE: the calltrace is asked where this function is and
    ## the session jumps there, so its caller — `main` — is the stop whose
    ## locals hold the wide structures. Its line is never written down.
  OuterFunction = "main"
  WideMappingName = "wide_mapping"
    ## The one variable name written into this file, and CTUI-6 wrote
    ## `descend` for the same reason: the program under test is ours and its
    ## shape is what is being asserted about. Everything ABOUT it — how many
    ## members it has and what they are — comes from the program's source or
    ## from the engine, never from here.
  CountConstantName = "WIDE_PROPERTY_COUNT"
    ## The program's own declaration of the member count, and a local at this
    ## stop as well, so the number is available from two independent places.
  KeyFormat = "\"key_%03d\""
    ## The format the program builds its keys with. Asserted to be PRESENT in
    ## the recorded source before it is used to build an expectation.
  ValueRule = "index * 2"
  MaxSteps = 8
  PaneWidth = 60
  PaneHeight = 40
  PageSize = 25
    ## Smaller than `DefaultPageSize` on purpose: the page boundary has to be
    ## crossed by a 600-member node in a test that can also assert the exact
    ## held count, and a page of 100 makes the two indistinguishable from "the
    ## first hundred happened to be what fitted".

  ChecksNavigation = 7
  ChecksSourceRule = 4
  ChecksRootExpansion = 6
  ChecksWideExpansion = 9
  ChecksMemberFields = 5
  ChecksStructExpansion = 8
  ChecksRelease = 8
  ChecksReExpansion = 5
  ChecksPublishBack = 7
  ChecksPerFrameBlocker = 7
  ChecksGlobalsRoot = 5
  ChecksMemoryBlocker = 8
  ChecksSummary = 4
  ChecksSkippedFixture = 2

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

proc frameFunction(session: HeadlessDebugSession): string =
  let response = session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 5,
  })
  discard session.drainEvents()
  let frames = response.getOrDefault("body").getOrDefault("stackFrames")
  if frames.isNil or frames.len == 0: ""
  else: frames[0].getOrDefault("name").getStr("")

proc frameIds(session: HeadlessDebugSession): seq[int] =
  ## Every frame's own `id` — the handle DAP `scopes` and `variables` take, and
  ## the field CTUI-6 carried on `StackFrame` for this milestone.
  result = @[]
  let response = session.sendRawDapRequest("stackTrace", %*{
    "threadId": 1, "startFrame": 0, "levels": 400,
  })
  discard session.drainEvents()
  let frames = response.getOrDefault("body").getOrDefault("stackFrames")
  if frames.isNil or frames.kind != JArray:
    return
  for f in frames:
    result.add f.getOrDefault("id").getInt(-1)

proc declaredMemberCount(path: string): int =
  ## `WIDE_PROPERTY_COUNT = <n>` as the recorded PROGRAM declares it.
  ##
  ## THE INDEPENDENT GROUND TRUTH for "600". Read off disk at the path the
  ## backend reported, so the expectation is the program's and not the
  ## decoder's.
  result = -1
  if not fileExists(path):
    return
  for line in readFile(path).splitLines():
    let text = line.strip()
    if text.startsWith(CountConstantName) and text.contains("="):
      let rhs = text.split('=')[1].strip()
      try:
        return parseInt(rhs)
      except ValueError:
        return -1

proc expectedMemberValue(index: int): string =
  ## What the program's own rule says member `index` renders as.
  ##
  ## `mapping["key_%03d" % index] = index * 2`, decoded as a tuple. Both halves
  ## of the rule are asserted to be present in the recorded source before this
  ## is used.
  "(\"key_" & align($index, 3, '0') & "\", " & $(index * 2) & ")"

proc rowTextFor(model: VariablesModel; path: string): string =
  let screen = variablesScreen(model, PaneWidth, PaneHeight)
  let row = bodyRowForPath(screen, path)
  if row < 0: "" else: rowText(screen.rows[row])

# ---------------------------------------------------------------------------
# Assertion templates. Every helper that calls `check` is a TEMPLATE.
# ---------------------------------------------------------------------------

template checkReleased(model: VariablesModel; path: string) =
  ## Nothing is held under `path` and nothing under it is open.
  checkpoint("after collapse, " & path & " holds " & $model.heldNodes(path) &
             " node(s); model holds " & $model.heldNodeTotal() & " in total")
  ck model.heldNodes(path) == 0
  ck model.memberTotal(path) == -1
  ck not model.isExpanded(path)

# ---------------------------------------------------------------------------

suite "CTUI-7: a real compound value expands, shows its fields, and is " &
      "released on collapse":

  test "wide_state: the 600-entry mapping expands, pages, and is released":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()

      # ---- NAVIGATE TO THE FRAME THAT HOLDS THE WIDE STRUCTURES ------------
      # The calltrace says where the recursive function is; jumping there and
      # stepping out lands in its caller, which is where the mapping is live.
      # No line number is written down.
      session.requestAndLoadCalltrace(depth = 200, height = 400)
      var target = CallLine(index: -1)
      for callLine in session.getCalltraceLines():
        if callLine.name == RecursiveFunction:
          target = callLine
          break
      ck target.index >= 0
      ck target.location.file.len > 0
      session.calltraceJumpByLine(target)
      discard session.drainEvents()
      ck session.frameFunction() == RecursiveFunction
      var steps = 0
      while steps < MaxSteps and session.frameFunction() != OuterFunction:
        session.stepOut()
        discard session.drainEvents()
        inc steps
      echo "CTUI-7 EXPANSION: reached " & session.frameFunction() & " after " &
           $steps & " stepOut(s) at " & session.getCurrentFile() & ":" &
           $session.getCurrentLine()
      ck steps < MaxSteps
      ck session.frameFunction() == OuterFunction
      ck session.getDebuggerStatus() == dsIdle

      session.requestAndLoadLocals()
      let locals = session.getLocals()
      ck locals.len > 0

      # ---- THE PROGRAM'S OWN RULE, READ OFF DISK ---------------------------
      let programPath = session.getCurrentFile()
      let source = (if fileExists(programPath): readFile(programPath) else: "")
      let declared = declaredMemberCount(programPath)
      echo "CTUI-7 EXPANSION: " & programPath & " declares " &
           CountConstantName & " = " & $declared
      ck declared > 500
      ck source.contains(KeyFormat)
      ck source.contains(ValueRule)
      # …and the engine agrees, through a completely different route: the
      # constant is also a LOCAL at this stop.
      var constantValue = ""
      for v in locals:
        if v.name == CountConstantName:
          constantValue = v.value
      ck constantValue == $declared

      # ---- THE TREE, THROUGH THE PRODUCTION BINDING ------------------------
      var timeline = initValueTimeline()
      let tick = session.getCurrentRRTicks()
      timeline.observeStop(tick, locals)
      var model = variablesModelFor(session.session.stateVM, timeline, tick,
                                    pageSize = PageSize)
      let localsPath = scopePath(skLocals)
      # `variablesModelFor` opens the root `activeTab` names, which is the one
      # fetch the pane does unasked.
      ck model.isExpanded(localsPath)
      ck model.memberTotal(localsPath) == locals.len
      ck model.populations == 1
      let rootsHeld = model.heldNodes(localsPath)
      ck rootsHeld == min(PageSize, locals.len)
      ck rootsHeld > 0
      ck model.heldNodeTotal() == rootsHeld

      # ---- EXPAND THE 600-ENTRY MAPPING ------------------------------------
      let widePath = childPath(localsPath, WideMappingName)
      var wideNode = VarNode(memberCount: -1)
      for node in model.childrenOf(localsPath):
        if node.name == WideMappingName:
          wideNode = node
      checkpoint("root node for " & WideMappingName & ": " & $wideNode)
      ck wideNode.path == widePath
      ck wideNode.memberCount == declared
      ck wideNode.typeName.len > 0

      let populationsBefore = model.populations
      model.expandNode(widePath)
      echo "CTUI-7 EXPANSION: " & WideMappingName & " reports " &
           $model.memberTotal(widePath) & " member(s); the model holds " &
           $model.heldNodes(widePath) & " of them"
      ck model.isExpanded(widePath)
      ck model.populations == populationsBefore + 1
      ck model.memberTotal(widePath) == declared
      # PAGED, not materialised: the whole point of the seam.
      ck model.heldNodes(widePath) == PageSize
      ck model.heldNodes(widePath) < declared
      ck model.heldNodeTotal() == rootsHeld + PageSize

      # ---- ITS ACTUAL FIELDS, AGAINST THE PROGRAM'S RULE -------------------
      let members = model.childrenOf(widePath)
      var wrongMembers: seq[string] = @[]
      for i, member in members:
        if member.name != "[" & $i & "]" or
           member.value != expectedMemberValue(i):
          wrongMembers.add member.name & " = " & member.value &
            " (expected [" & $i & "] = " & expectedMemberValue(i) & ")"
      if wrongMembers.len > 0:
        checkpoint(wrongMembers[0 .. min(2, wrongMembers.high)].join("\n"))
      ck wrongMembers.len == 0
      ck members.len == PageSize
      # …and the pane really draws them, with the expander showing the node is
      # open and the first member's own key on its row.
      ck rowTextFor(model, widePath).startsWith(ExpandedGlyph)
      ck rowTextFor(model, members[0].path).contains("key_000")
      ck rowTextFor(model, members[0].path).startsWith(CollapsedGlyph)

      # ---- EXPAND ONE MEMBER: A REAL TWO-FIELD STRUCTURE -------------------
      let memberPath = members[0].path
      ck members[0].memberCount == 2
      model.expandNode(memberPath)
      let fields = model.childrenOf(memberPath)
      checkpoint("fields of " & memberPath & ": " & $fields)
      ck model.isExpanded(memberPath)
      ck model.memberTotal(memberPath) == 2
      ck fields.len == 2
      # The key and the value the PROGRAM put there, each in its own row.
      ck fields[0].value == "\"key_000\""
      ck fields[1].value == "0"
      ck rowTextFor(model, fields[0].path).contains("key_000")
      ck model.heldNodeTotal() == rootsHeld + PageSize + 2

      # ---- COLLAPSE: THE CHILDREN ARE RELEASED, NOT HIDDEN -----------------
      model.collapseNode(widePath)
      checkReleased(model, widePath)
      # …AND THE GRANDCHILD'S PAGE WENT WITH IT. A one-level release would
      # leave these two objects alive under a node nothing can reach — a leak no
      # screen shows and no row count finds.
      checkReleased(model, memberPath)
      ck model.heldNodeTotal() == rootsHeld
      # …and the rows are gone too, which is the WEAKER statement the strong one
      # implies. Asserted second, so it cannot stand in for the first.
      ck rowTextFor(model, memberPath).len == 0

      # ---- RE-EXPANDING QUERIES AGAIN --------------------------------------
      # The CTUI-4 shape, guarded against: if a re-expansion found the state
      # already populated and did no work, `populations` would not move and the
      # "released" assertion above would be about a screen rather than about
      # memory.
      let populationsAfterCollapse = model.populations
      model.expandNode(widePath)
      ck model.populations == populationsAfterCollapse + 1
      ck model.heldNodes(widePath) == PageSize
      ck model.memberTotal(widePath) == declared
      ck model.childrenOf(widePath)[0].value == expectedMemberValue(0)
      ck model.heldNodeTotal() == rootsHeld + PageSize

      # ---- THE PANE'S STATE GOES BACK INTO `StateVM`, AND MOVES NOTHING ----
      # `selectPath` and `toggleExpand` each write ONE signal and issue no
      # backend command, which is the property CTUI-6 needed from
      # `CalltraceVM.selectEntry`: a cursor that must not move the program.
      # Asserted by moving it and re-reading the position, exactly as CTUI-6
      # asserted its inspection cursor.
      let fileBefore = session.getCurrentFile()
      let lineBefore = session.getCurrentLine()
      let tickBefore = session.getCurrentRRTicks()
      model.selected = widePath
      publishSelection(session.session.stateVM, model)
      publishExpansion(session.session.stateVM, model)
      let published = session.session.stateVM.expandedPaths.val
      checkpoint("published expansion: " & $published & ", selection '" &
                 session.session.stateVM.selectedPath.val & "'")
      # The DESKTOP'S KEY SPACE: variable paths, with no `@Scope.` prefix and no
      # entry for a scope root, which the desktop has tabs for instead.
      ck session.session.stateVM.selectedPath.val == WideMappingName
      ck WideMappingName in published
      ck scopePath(skLocals) notin published
      ck published.len == 1
      # …AND THE DEBUGGER DID NOT MOVE.
      ck session.getCurrentFile() == fileBefore
      ck session.getCurrentLine() == lineBefore
      ck session.getCurrentRRTicks() == tickBefore

      # ---- THE PER-FRAME BLOCKER, MEASURED ---------------------------------
      # CTUI-6 carried `StackFrame.id` for exactly this request, and CTUI-7 is
      # the milestone that would use it. It cannot: `Handler::variables`
      # (`src/db-backend/src/dap_handler.rs`) names its argument `_arg` and
      # answers `self.reader.variables_at_owned(self.step_id)` — the CURRENT
      # step's variables, whatever frame was asked for.
      #
      # THE ASSERTION IS THAT TWO DIFFERENT FRAMES ANSWER THE SAME BYTES, which
      # is a much sharper statement than "the answer is empty" and, unlike it,
      # cannot be satisfied by a stop that simply has no locals. It is an
      # EQUALITY, so the day the engine makes the request frame-sensitive this
      # suite goes red and says the per-frame arm is now buildable — the same
      # construction `test_multi_thread_selection.nim` uses for the thread
      # blocker.
      let ids = session.frameIds()
      ck ids.len >= 2
      ck ids[0] != ids[1]
      var answers: seq[string] = @[]
      var answeredCounts: seq[int] = @[]
      for id in ids:
        let response = session.sendRawDapRequest(
          "variables", %*{"variablesReference": id})
        discard session.drainEvents()
        let answered = response.getOrDefault("body").getOrDefault("variables")
        answers.add (if answered.isNil: "<none>" else: $answered)
        answeredCounts.add (if answered.isNil: -1 else: answered.len)
      echo "CTUI-7 PER-FRAME: stackTrace ids " & $ids &
           " -> DAP variables counts " & $answeredCounts &
           ", distinct answers " & $deduplicate(answers).len &
           "; ct/load-locals answered " & $locals.len & " row(s)"
      ck deduplicate(answers).len == 1
      ck answers.len == ids.len
      # …and the one answer they share is the CURRENT step's own locals, which
      # is what "it ignores the frame" means rather than "it answers nothing".
      ck answeredCounts[0] == locals.len
      let scopesResponse = session.sendRawDapRequest(
        "scopes", %*{"frameId": ids[0]})
      discard session.drainEvents()
      let scopes = scopesResponse.getOrDefault("body").getOrDefault("scopes")
      ck (if scopes.isNil: -1 else: scopes.len) == 1
      ck scopesResponse.getOrDefault("success").getBool(false)

      # ---- THE `Globals` ROOT SAYS WHY IT IS EMPTY, AND IS MEASURED --------
      # `store.locals.globals` is a signal nothing in this repository fills from
      # a backend response — the shape CTUI-5 found in `PointListVM.points`.
      # Asserted as an EQUALITY on the signal's own length, so the day something
      # fills it this suite goes red; and the pane's availability is DERIVED
      # from that signal rather than written down, so on that day the root
      # starts showing its contents instead of its excuse.
      ck session.session.store.locals.globals.val.len == 0
      var globalsScope = Scope(kind: skGlobals, availability: savaAvailable)
      for scope in model.scopes:
        if scope.kind == skGlobals:
          globalsScope = scope
      checkpoint("globals root: " & $globalsScope.availability & " — " &
                 globalsScope.note)
      ck globalsScope.availability == savaUnsupported
      ck globalsScope.note == UnsupportedGlobals
      # …and the reason is ON SCREEN, under the root, rather than only in a
      # field: an empty tree and an unfillable one are different answers.
      var noteRows = 0
      for row in model.paneRows():
        if row.kind == vrkNote and row.scope == skGlobals:
          inc noteRows
          ck row.note == UnsupportedGlobals
      ck noteRows == 1

      # ---- THE HEX INSPECTOR'S BLOCKER, MEASURED ---------------------------
      # CTUI-7 delivers `app/views/hex_inspector.nim` "only if a memory-read
      # capability is confirmed on the backend; otherwise this deliverable is
      # cut and recorded as cut". It IS cut, and this is the measurement that
      # says so on every lane run rather than a citation of one.
      #
      # THREE INDEPENDENT LEGS, each an EQUALITY, so the day ANY of them changes
      # this suite goes red and says the hex inspector is now buildable — the
      # same construction `test_multi_thread_selection.nim` uses for the thread
      # blocker.
      #
      #   1. the engine has no `readMemory` / `writeMemory` arm at all: both
      #      fall through `dap_server.rs`'s dispatch to
      #      `dap_command_to_step_action` and are REFUSED;
      #   2. `initialize` cannot even advertise the capability: the
      #      `Capabilities` struct the engine serialises (`src/db-backend/
      #      src/dap.rs:159`) has no `supportsReadMemoryRequest` FIELD, so the
      #      key is absent rather than false;
      #   3. no variable carries an ADDRESS to inspect — `Handler::variables`
      #      and the `ct/load-locals` builder set `address: NO_ADDRESS` (-1) on
      #      every row of the CTFS path, and `dap.rs`'s `new_dap_variable`
      #      hard-codes `memory_reference: None`.
      var refusals = 0
      for command in ["readMemory", "writeMemory"]:
        let response = session.sendRawDapRequest(command, %*{
          "memoryReference": "0x1000", "offset": 0, "count": 16})
        discard session.drainEvents()
        echo "CTUI-7 MEMORY: " & command & " -> " & $response
        if not response.getOrDefault("success").getBool(true) and
           response.getOrDefault("message").getStr("").contains("not supported"):
          inc refusals
      ck refusals == 2

      let caps = session.sendRawDapRequest("initialize", %*{
        "clientID": "ctui7", "adapterID": "codetracer"})
      discard session.drainEvents()
      let capsBody = caps.getOrDefault("body")
      echo "CTUI-7 MEMORY: initialize capabilities " & $capsBody
      ck caps.getOrDefault("success").getBool(false)
      ck not capsBody.hasKey("supportsReadMemoryRequest")
      ck not capsBody.hasKey("supportsWriteMemoryRequest")
      # THE POSITIVE TWIN: this really is a capabilities body, so "the key is
      # absent" is a statement about the capability and not about the response.
      ck capsBody.hasKey("supportsStepBack")

      let rawLocals = session.sendRawDapRequest("ct/load-locals", %*{
        "rrTicks": session.getCurrentRRTicks().int64,
        "countBudget": 3000, "minCountLimit": 50, "depthLimit": 7,
        "watchExpressions": newSeq[string](), "lang": 0,
      }).getOrDefault("body").getOrDefault("locals")
      discard session.drainEvents()
      var addressed = 0
      var addresses: seq[int] = @[]
      if not rawLocals.isNil and rawLocals.kind == JArray:
        for row in rawLocals:
          let address = row.getOrDefault("address").getInt(0)
          if address notin addresses:
            addresses.add address
          if address != -1:
            inc addressed
      echo "CTUI-7 MEMORY: " & $(if rawLocals.isNil: 0 else: rawLocals.len) &
           " local(s), distinct address value(s) " & $addresses &
           ", addressed " & $addressed
      ck (if rawLocals.isNil: -1 else: rawLocals.len) == locals.len
      ck addressed == 0
      ck addresses == @[-1]

  test "every fixture was examined, and the assertion tally proves it":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    let expected =
      verifiedFixtures * (
        ChecksNavigation + ChecksSourceRule + ChecksRootExpansion +
        ChecksWideExpansion + ChecksMemberFields + ChecksStructExpansion +
        ChecksRelease + ChecksReExpansion + ChecksPublishBack +
        ChecksPerFrameBlocker + ChecksGlobalsRoot + ChecksMemoryBlocker) +
      skippedFixtures * ChecksSkippedFixture +
      ChecksSummary
    checkpoint("counted " & $countedAssertions & ", derived " & $expected)
    ck countedAssertions == expected

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
