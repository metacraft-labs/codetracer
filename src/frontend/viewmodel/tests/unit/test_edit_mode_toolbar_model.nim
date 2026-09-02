## test_edit_mode_toolbar_model.nim
##
## Edit-Mode-Toolbar.md §7, §8 and §9 — what the toolbar carries in each mode,
## which button runs what, disabled-versus-hidden, and the Run verdict.
## EMT-A1-A11, A13, A15-A19, A22, A24, A27-A34, A50-A56.
##
## ## THIS SUITE IS PARTLY RED ON `dev`, AND IT IS SUPPOSED TO BE.
##
## It states the CORRECT expectation for behaviour that is **not built** and
## never pins today's behaviour where today's behaviour is wrong. It goes green
## on its own when `viewmodels/edit_mode_toolbar.nim` lands. Registered in
## `codetracer-specs/Testing/Known-Test-Failures.md`.
##
## The green checks are the controls. They assert the seams the feature must
## build ON — `parseTasksJson`, the four platform profiles, the wasm registry's
## subcommand refusal — so that when the red ones flip, they flip over a
## surface already known to work rather than over a mock.
##
## ## The defect, stated as a test
##
## §1: there is **no `EditMode` check anywhere in the topbar path**.
## `topbarModel` (`viewmodels/topbar_actions.nim:75`) takes a `PlatformProfile`
## and a `fullscreen` flag and **no mode**, and begins
##
##     var actions: set[TopbarAction] = {tbaDebuggerControls, tbaOmnibar, tbaSessionTabs}
##
## with `tbaDebuggerControls` documented as *"Always present — they are the
## product."* So thirteen stepping buttons paint in Edit mode, where there is no
## debugger. The first check below asserts that absence directly, so the
## starting state is recorded rather than described.
##
## ## Which render arm these tests bind to (trap 3)
##
## **They bind to the ViewModel, and to the `MockRenderer` arm where a view is
## reached at all.** `renderDebugControlsPanel` has two divergent arms —
## `WebRenderer` (`isonim_debug_controls_view.nim:165-301`) and `MockRenderer`
## (`:68-131`) — and EMT-D28 requires every claim about a *painted* difference
## between modes to ALSO be asserted in the browser (§13/EMT-A63). Two arms is
## how a suite passes against a surface the user never sees. **EMT-A63 is not
## discharged here and is not claimed to be**; it is a Playwright obligation on
## the deployed studio, and it is the control on this file.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_edit_mode_toolbar_model.nim
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/[strutils, unittest]

import ../../store/types
import ../../viewmodels/project_actions
import ../../viewmodels/topbar_actions
import ../../platform/capabilities
import ../../platform/wasm_registry

# `LayoutMode` is deliberately NOT imported here, and the reason is a finding
# rather than a preference — see the header's "the mode vocabulary is not in
# the ViewModel layer". `edit_mode_toolbar.nim` must EXPORT the mode vocabulary
# it takes, and these suites reach `EditMode` / `DebugMode` through it.
const LayoutModeSrc =
  staticRead("../../../../common/common_types/debugger_features/debugger.nim")

const EditModeToolbarModule =
  currentSourcePath()[0 ..< currentSourcePath().rfind('/')] &
    "/../../viewmodels/edit_mode_toolbar.nim"
  ## CORRECTED, and the correction is the reason this suite could not have gone
  ## green on its own as its header claimed.
  ##
  ## It was `currentSourcePath() & "/../../../viewmodels/…"`, which appends
  ## `..` **to a regular file**. Path resolution walks components left to
  ## right, so `…/test_edit_mode_toolbar_model.nim/..` is `ENOTDIR` and
  ## `test -e` answered `NO` unconditionally — with the module present, absent,
  ## or anything else. The probe was not measuring whether the feature had
  ## landed; it was a constant. Dropping the filename first is the whole fix.
  ##
  ## Measured, not reasoned: with the module in place the old spelling still
  ## answered `NO` and all twelve red checks stayed red on both backends.

const EditModeToolbarBuilt =
  staticExec("test -e '" & EditModeToolbarModule & "' && echo YES || echo NO")
    .strip == "YES"

when EditModeToolbarBuilt:
  import ../../viewmodels/edit_mode_toolbar

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template startCount() =
  asserted = 0

template pending(what: string) =
  inc asserted
  checkpoint("UNIMPLEMENTED — " & what)
  check false

const ToolbarAwaited = "`edit_mode_toolbar.editModeToolbar`"

let AllProfiles = [desktopProfile, webProfile, containerProfile,
                   headlessProfile]
  ## `let`, not `const`: the four profiles are themselves `let` in
  ## `capabilities.nim` because their `degradations` seq literals are
  ## runtime-initialised.

# ---------------------------------------------------------------------------
# Declaration fixtures. Hand-written JSON, because the subject is the READER:
# a fixture read off disk would test the host, and this suite runs on the JS
# backend where there is no disk.
# ---------------------------------------------------------------------------

const FourBuildTasksOneDefault = """
{ "version": "2.0.0", "tasks": [
  { "label": "lint",   "type": "shell", "command": "cargo", "args": ["clippy"] },
  { "label": "debug",  "type": "shell", "command": "cargo", "args": ["build"],
    "group": { "kind": "build", "isDefault": false } },
  { "label": "release","type": "shell", "command": "cargo",
    "args": ["build", "--release"],
    "group": { "kind": "build", "isDefault": true } },
  { "label": "docs",   "type": "shell", "command": "cargo", "args": ["doc"],
    "group": "build" }
] }
"""

const TwoBuildTasksBothDefault = """
{ "version": "2.0.0", "tasks": [
  { "label": "alpha", "type": "shell", "command": "make", "args": ["a"],
    "group": { "kind": "build", "isDefault": true } },
  { "label": "beta",  "type": "shell", "command": "make", "args": ["b"],
    "group": { "kind": "build", "isDefault": true } }
] }
"""

const UnknownGroupKind = """
{ "version": "2.0.0", "tasks": [
  { "label": "ship", "type": "shell", "command": "deployer",
    "group": { "kind": "deploy", "isDefault": true } }
] }
"""

const MalformedTasksJson = "{ \"version\": \"2.0.0\", \"tasks\": [ {,,, ] "

## ## §1's starting-state check has EXPIRED and was deleted here
##
## `"the topbar has no mode parameter today, and no command slots"` recorded
## the defect as it stood: `topbarModel` took no mode, `tbaBuild` / `tbaRun` /
## `tbaActionOverflow` / `tbaRunTests` / `tbaRecordTests` did not exist, and
## `tbaDebuggerControls` was unconditional on all four profiles. Its own
## comment set the terms — *"it must go RED when the feature lands, at which
## point it is deleted with the same change; a known-starting-state check that
## outlives the state it records is worse than none"* — and
## `Known-Test-Failures.md` names it as **a check with an expiry**.
##
## All five `not declared(...)` assertions are now false, because the five
## members are declared in `viewmodels/topbar_actions.nim`, which is what the
## suite below reaches through. Mutation arm **M9** was retired with it: its
## killer was this check, and an arm whose killer no longer exists cannot
## resolve to exactly one green check, which is the property
## `verify_arms_are_unambiguous` asserts before anything runs.

suite "EMT §7.3 what the toolbar carries in each mode":

  test "EMT-A1/A2/A3/A4 the mode decides the set, on all four profiles":
    ## A1 and A2 are negatives; A4 is their positive twin and exists because a
    ## function that returned an EMPTY set would satisfy both (§16.2).
    startCount()
    when EditModeToolbarBuilt:
      for profile in AllProfiles:
        checkpoint(profile.displayName)
        let editing = editModeToolbar(profile, EditMode)
        let debugging = editModeToolbar(profile, DebugMode)
        # A1 — no stepping buttons where there is no debugger.
        ck tbaDebuggerControls notin editing.actions
        # A2 — and the mirror: no command slots over a live replay, because
        # rebuilding underneath one invalidates the trace being replayed.
        ck tbaDebuggerControls in debugging.actions
        ck tbaBuild notin debugging.actions
        ck tbaRun notin debugging.actions
        ck tbaActionOverflow notin debugging.actions
        # A3 — the test buttons are in BOTH modes: recording a test run is how
        # you enter Debug mode, and re-running tests is how you check a fix.
        ck tbaRunTests in editing.actions
        ck tbaRunTests in debugging.actions
        ck tbaRecordTests in editing.actions
        ck tbaRecordTests in debugging.actions
        # A4 — the positive twin.
        ck tbaOmnibar in editing.actions
        ck tbaOmnibar in debugging.actions
        ck tbaSessionTabs in editing.actions
        ck tbaSessionTabs in debugging.actions
    else:
      for profile in AllProfiles:
        for _ in 0 ..< 13:
          pending(ToolbarAwaited & " — mode gating on " & profile.displayName)
    expectCount(52)
    ## COUNT CORRECTED, 56 -> 52, and no assertion was added or removed.
    ##
    ## The built arm makes **13** assertions per profile — count the `ck` lines
    ## above — and the unbuilt arm emitted 14, so `expectCount(56)` matched the
    ## `pending` arm and could never match the real one. Measured: with the
    ## feature in place every one of the 52 product assertions passed and the
    ## check still failed on `asserted == 56` alone. The `pending` loop is
    ## corrected to 13 in the same edit so the two arms agree, which is the
    ## invariant `expectCount` exists to protect.

  test "EMT-A5 the mode decision is a parameter, not a compile-time define":
    ## `test_topbar_actions_follow_capability_not_build` is the model: ONE test
    ## process produces BOTH answers. A `when defined(...)` split cannot, and
    ## would make the two modes untestable against each other.
    startCount()
    when EditModeToolbarBuilt:
      let editing = editModeToolbar(desktopProfile, EditMode)
      let debugging = editModeToolbar(desktopProfile, DebugMode)
      ck editing.actions != debugging.actions
    else:
      pending(ToolbarAwaited & " — both answers in one process")
    expectCount(1)

  test "EMT-A7 deep review removes the command buttons in BOTH modes":
    ## EMT-D12: a review is a reading surface over a trace that already exists.
    ## Note DeepReview is NOT a `LayoutMode` member — it is the separate flag
    ## `data.deepReviewActive` — so it is a third argument, not a fourth mode.
    startCount()
    when EditModeToolbarBuilt:
      for mode in [EditMode, DebugMode]:
        let model = editModeToolbar(desktopProfile, mode, deepReviewActive = true)
        ck tbaBuild notin model.actions
        ck tbaRun notin model.actions
    else:
      for _ in 0 ..< 4:
        pending(ToolbarAwaited & " — deepReviewActive")
    expectCount(4)

suite "EMT §3/§7.1 reading declarations, and selecting among them":

  test "EMT-A11 no `run` group kind exists, and none may be added":
    ## EMT-D4, asserted so the superseded design cannot reappear. Run comes from
    ## `launch.json`, which VS Code owns and CodeTracer already parses; adding
    ## `pagRun` would put a CodeTracer-specific field in a file another tool
    ## owns. Green today, and it must STAY green — this is a guard, not a
    ## specification of unbuilt behaviour.
    startCount()
    var members = 0
    for g in ProjectActionGroup:
      inc members
      ck $g != "run"
    ck members == 3          # pagNone, pagBuild, pagTest — and nothing else
    expectCount(4)

  test "EMT-A9/A10 both group spellings read, and an unknown kind is silent":
    ## Green today. `parseGroup` is private, so these go through the public
    ## `parseTasksJson`, which is the only way a caller can reach it anyway.
    startCount()
    let parsed = parseTasksJson(FourBuildTasksOneDefault)
    ck parsed.problems.len == 0
    ck parsed.actions.len == 4
    # A9 — the bare string spelling.
    ck parsed.actions[3].label == "docs"
    ck parsed.actions[3].group == pagBuild
    # The object spelling reaches the same group.
    ck parsed.actions[2].label == "release"
    ck parsed.actions[2].group == pagBuild

    # A10 — an unknown kind is `pagNone` and NOT a problem row. A task whose
    # group CodeTracer does not understand is still a task the project
    # declared; reporting it would train users to ignore the problems list.
    let deploy = parseTasksJson(UnknownGroupKind)
    ck deploy.actions.len == 1
    ck deploy.actions[0].group == pagNone
    ck deploy.problems.len == 0
    expectCount(9)

  test "EMT-A8 `isDefault` is read and carried, not discarded":
    ## §3.4 gap 1. `parseGroup` reads `kind` and drops `isDefault`, so §7.1's
    ## step 1 — "group.kind == build AND isDefault" — cannot be expressed. The
    ## group half passes today; the field half is the gap.
    startCount()
    let parsed = parseTasksJson(FourBuildTasksOneDefault)
    ck parsed.actions[2].group == pagBuild
    when compiles(parsed.actions[2].isDefault):
      ck parsed.actions[2].isDefault          # "release"
      ck not parsed.actions[1].isDefault      # "debug", explicitly false
      ck not parsed.actions[3].isDefault      # "docs", bare-string spelling
    else:
      pending("`ProjectAction.isDefault` — parseGroup discards it")
      pending("`ProjectAction.isDefault` — the explicit-false case")
      pending("`ProjectAction.isDefault` — the bare-string case")
    expectCount(4)

  test "EMT-A13 a malformed tasks.json is reported, never silently dropped":
    ## Green today, and a REGRESSION GUARD rather than a specification. §4.1
    ## records the shipped defect this pins: on the JS backend `parseJson`
    ## delegates to `JSON.parse`, whose throw is a FOREIGN exception that no
    ## typed Nim handler catches, so a malformed `tasks.json` took down the
    ## renderer. The suite is only meaningful because it runs on BOTH lanes.
    startCount()
    let broken = parseTasksJson(MalformedTasksJson)
    ck broken.problems.len >= 1
    ck broken.actions.len == 0
    let collected = collectProjectActions(MalformedTasksJson, "")
    ck collected.problems.len >= 1
    ck collected.actions.len == 0
    expectCount(4)

  test "EMT-A15/A16/A17 selection picks the default, or refuses to pick":
    ## A16 is the assertion a lazy implementation cheats on: two defaults must
    ## select NEITHER. "First wins" is the defect §7.2 describes — a build that
    ## silently ran a different task after someone reordered the file costs an
    ## afternoon and leaves no trace in the UI.
    ##
    ## A17 makes that concrete: the same tasks in a different ORDER must
    ## produce the same outcome. It is a real assertion rather than a tautology
    ## precisely because array position is what a naive implementation uses.
    startCount()
    when EditModeToolbarBuilt:
      # A15 — one default among four selects the default.
      let one = selectBuildCommand(parseTasksJson(FourBuildTasksOneDefault))
      ck one.resolved
      ck one.action.label == "release"
      # A16 — two defaults select neither, and BOTH are listed.
      let two = selectBuildCommand(parseTasksJson(TwoBuildTasksBothDefault))
      ck not two.resolved
      ck two.candidates.len == 2
      ck two.reason.len > 0
      # A17 — reordering changes no outcome.
      const Reordered = """
{ "version": "2.0.0", "tasks": [
  { "label": "beta",  "type": "shell", "command": "make", "args": ["b"],
    "group": { "kind": "build", "isDefault": true } },
  { "label": "alpha", "type": "shell", "command": "make", "args": ["a"],
    "group": { "kind": "build", "isDefault": true } }
] }
"""
      let swapped = selectBuildCommand(parseTasksJson(Reordered))
      ck not swapped.resolved
      ck swapped.candidates.len == two.candidates.len
    else:
      for _ in 0 ..< 7:
        pending("`selectBuildCommand` — §7.1 ordered selection, §7.2 ambiguity")
    expectCount(7)
    ## COUNT CORRECTED, 8 -> 7, and no assertion was added or removed. There
    ## are seven `ck` lines above; the `pending` arm emitted eight. Measured:
    ## all seven passed and the check failed on `asserted == 8` alone.

  test "EMT-A18/A19 a declaration beats the guess, and the guess must ask":
    ## A18: a declared build task AND a recognised Rust project yields the
    ## declared task — `cargo build` does not appear at all. A19: with no
    ## declarations, `cargo build` appears as `cpConventional` and requires
    ## confirmation showing the exact command line (EMT-D7). The two together
    ## are the whole provenance precedence.
    startCount()
    when EditModeToolbarBuilt:
      let declared = editModeToolbar(
        desktopProfile, EditMode,
        tasksJson = FourBuildTasksOneDefault, listing = @["Cargo.toml"])
      ck declared.build.provenance == cpDeclared
      # THE ASSERTION THIS REPLACES WAS `declared.build.command != "cargo"`,
      # and it could not pass on any correct implementation.
      #
      # `ToolbarButton.command` is THE EXECUTABLE — its own doc comment says
      # so, and the twin four lines down (`guessed.build.command == "cargo"`)
      # depends on that meaning. Every one of `FourBuildTasksOneDefault`'s four
      # tasks runs `cargo`, so the declared winner's executable IS `cargo`, and
      # a model that answered anything else would be reporting the wrong
      # program. The check was asking the executable field to carry a fact
      # about provenance that the line above already carries properly.
      #
      # What the test's own docstring asks for is `cargo build` DOES NOT APPEAR
      # AT ALL — a statement about the command LINE, which is the field the
      # model gives that meaning to (`commandLine`, "the full line"). So the
      # line is what is asserted, and it is asserted positively: the default
      # declared task is `release`, i.e. `cargo build --release`. That is
      # strictly stronger than the inequality it replaces — it rules out the
      # conventional `cargo build` AND pins that the `isDefault` task won over
      # the three non-default ones, which is the other half of "a declaration
      # beats the guess".
      ck declared.build.commandLine == "cargo build --release"
      let guessed = editModeToolbar(
        desktopProfile, EditMode, tasksJson = "", listing = @["Cargo.toml"])
      ck guessed.build.provenance == cpConventional
      ck guessed.build.command == "cargo"
      ck guessed.build.requiresConfirmation
      # EMT-A25 — the tooltip names the marker that produced the guess.
      ck "Cargo.toml" in guessed.build.tooltip
    else:
      for _ in 0 ..< 6:
        pending(ToolbarAwaited & " — provenance precedence")
    expectCount(6)

suite "EMT §8 disabled versus hidden, and the browser's capability tier":

  test "the four profiles disagree about running programs — the control":
    ## Green today. This is the mechanism EMT-A31/A32/A34 rest on, asserted
    ## first so those are not green over a capability model that answers the
    ## same thing everywhere.
    startCount()
    # Web can spawn (wasm modules in the tab) but can never run an arbitrary
    # program — the split that makes the browser tier expressible at all.
    ck webProfile.has(capProcessSpawn)
    ck not webProfile.has(capProcessArbitraryPrograms)
    ck desktopProfile.has(capProcessArbitraryPrograms)
    ck headlessProfile.has(capProcessArbitraryPrograms)
    ck containerProfile.has(capProcessArbitraryPrograms)
    # And the sentence a disabled button has to carry is already computed.
    ck webProfile.degradedBehaviour(capProcessArbitraryPrograms).len > 0
    # `degradedBehaviour` returns "" when the capability is PRESENT, so the
    # desktop answer is empty — asserted so the check above is not trivially
    # true for every profile.
    ck desktopProfile.degradedBehaviour(capProcessArbitraryPrograms).len == 0
    expectCount(7)

  test "the wasm registry refuses by SUBCOMMAND — the control for A34":
    ## Green today, and it is the mechanism that makes §13 checkable: Noir
    ## Studio's Build button is enabled exactly when a `nargo compile` module is
    ## registered, and Run exactly when `nargo trace` is.
    startCount()
    let compileOnly = WasmRegistry(modules: @[
      WasmModule(command: "nargo", moduleId: WasmModuleId("nargo-compile"),
                 displayName: "nargo (compile)",
                 subcommands: @["compile"], builtFrom: "test fixture")])
    ck compileOnly.resolve("nargo", @["compile"]).kind == wrResolved
    ck compileOnly.resolve("nargo", @["trace"]).kind == wrSubcommandNotBuilt
    ck compileOnly.resolve("nargo", @["trace"]).available == @["compile"]
    ck compileOnly.resolve("cargo", @["build"]).kind == wrNoModuleForCommand
    # A project's own binary is never shadowed.
    ck compileOnly.resolve("./tools/nargo", @["compile"]).kind == wrPathQualified
    # An empty registry is a fact about the deployment, not about the command.
    ck WasmRegistry().resolve("nargo", @["compile"]).kind == wrNoModulesLoaded
    expectCount(6)

  test "EMT-A30/A31 recognition decides visible; capability decides enabled":
    ## The §8 split, and the pair of cases that make it a split rather than a
    ## slogan: an unrecognised folder hides the group, but the SAME folder with
    ## a `tasks.json` shows it, because something was declared.
    startCount()
    when EditModeToolbarBuilt:
      # A30 — both directions.
      let bare = editModeToolbar(desktopProfile, EditMode,
                                 tasksJson = "", listing = @["notes.txt"])
      ck not bare.commandGroupVisible
      let declared = editModeToolbar(desktopProfile, EditMode,
                                     tasksJson = FourBuildTasksOneDefault,
                                     listing = @["notes.txt"])
      ck declared.commandGroupVisible
      # A31 — lacking spawn entirely, the group is hidden even with a full
      # tasks.json. A platform that can run nothing must not claim it can run
      # something.
      let noSpawn = desktopProfile.withCapabilities({}, @[])
      let gated = editModeToolbar(noSpawn, EditMode,
                                  tasksJson = FourBuildTasksOneDefault,
                                  listing = @["Cargo.toml"])
      ck not gated.commandGroupVisible
    else:
      for _ in 0 ..< 3:
        pending(ToolbarAwaited & " — commandGroupVisible")
    expectCount(3)

  test "EMT-A32/A33/A34 the browser tier, with both of its positive twins":
    ## A32 alone is green over a model that disables EVERYTHING — §16.2's R6
    ## arm exactly. A33 is its twin at command granularity and A34 at
    ## SUBCOMMAND granularity, which is the granularity the registry actually
    ## has and the granularity §13 turns on.
    startCount()
    when EditModeToolbarBuilt:
      let noModules = WasmRegistry()
      let compileOnly = WasmRegistry(modules: @[
        WasmModule(command: "nargo", moduleId: WasmModuleId("nargo-compile"),
                   displayName: "nargo (compile)", subcommands: @["compile"],
                   builtFrom: "test fixture")])
      let full = WasmRegistry(modules: @[
        WasmModule(command: "nargo", moduleId: WasmModuleId("nargo-all"),
                   displayName: "nargo", subcommands: @["compile", "trace"],
                   builtFrom: "test fixture")])

      # A32 — disabled, carrying EXACTLY the profile's own sentence. Asserted
      # by equality against `degradedBehaviour`, not by a substring, so a
      # hand-written approximation of it fails.
      let refused = editModeToolbar(webProfile, EditMode,
                                    listing = @["Nargo.toml"],
                                    wasm = noModules)
      ck not refused.build.enabled
      ck refused.build.reason ==
         webProfile.degradedBehaviour(capProcessArbitraryPrograms)

      # A33 — the positive twin: with a module registered, the same task is
      # ENABLED.
      let enabled = editModeToolbar(webProfile, EditMode,
                                    listing = @["Nargo.toml"], wasm = full)
      ck enabled.build.enabled
      ck enabled.run.enabled

      # A34 — compile but not trace: Build enabled, Run disabled NAMING the
      # missing subcommand.
      let partial = editModeToolbar(webProfile, EditMode,
                                    listing = @["Nargo.toml"],
                                    wasm = compileOnly)
      ck partial.build.enabled
      ck not partial.run.enabled
      ck "trace" in partial.run.reason
    else:
      for _ in 0 ..< 7:
        pending(ToolbarAwaited & " — the web capability tier")
    expectCount(7)

  test "EMT-A27/A28/A29 every disabled button carries a reason":
    ## A28 is universal, so A29 pairs it with a COUNT PER CAUSE — otherwise
    ## "every disabled button has a reason" is satisfied by a corpus with no
    ## disabled buttons (§16.1). A27 is the worked example: a Foundry project
    ## has Build and Run Tests, and no Run — and saying so is what teaches the
    ## user the feature exists.
    startCount()
    when EditModeToolbarBuilt:
      # A27 — disabled WITH A REASON, not hidden.
      let foundry = editModeToolbar(desktopProfile, EditMode,
                                    listing = @["foundry.toml", "src/"])
      ck foundry.build.enabled
      ck not foundry.run.enabled
      ck foundry.run.reason.len > 0
      ck foundry.commandGroupVisible          # shown, not hidden

      # A28 — over every button of every model in the corpus.
      var disabledSeen = 0
      let corpus = [
        editModeToolbar(desktopProfile, EditMode, listing = @["foundry.toml"]),
        editModeToolbar(desktopProfile, EditMode, listing = @["CMakeLists.txt"]),
        editModeToolbar(webProfile, EditMode, listing = @["Nargo.toml"]),
        editModeToolbar(desktopProfile, EditMode,
                        tasksJson = TwoBuildTasksBothDefault,
                        listing = @["Cargo.toml"]),
        editModeToolbar(desktopProfile, EditMode, listing = @["pyproject.toml"])]
      for model in corpus:
        for button in model.buttons:
          if not button.enabled:
            inc disabledSeen
            ck button.reason.len > 0
      # A29 — the corpus really does exercise each of the causes, asserted as a
      # count so a corpus that quietly stopped producing them fails.
      ck disabledSeen >= 5
      expectCount(4 + disabledSeen + 1)
      ## COUNT CORRECTED, and this one was not off by a constant — it was
      ## **unsatisfiable**.
      ##
      ## The built arm asserts 4 (the Foundry case) + **one per disabled
      ## button** + 1 (`disabledSeen >= 5`). So `asserted == 5 + disabledSeen`,
      ## while `disabledSeen >= 5` is required — the two can never both hold
      ## against the fixed `expectCount(5)`, which was sized for the `pending`
      ## arm. Measured with the feature in place: `disabledSeen == 19` and
      ## `asserted == 24`, every one of the 24 passing, and the check failing
      ## on `asserted == 5` alone.
      ##
      ## Written as an EXPRESSION rather than as the literal 24 deliberately.
      ## The guard's job is that a check which quietly stopped asserting fails;
      ## a literal would freeze today's corpus size and turn `expectCount` into
      ## a second thing to update whenever a fixture is added, which is how it
      ## ends up loosened to `>=` by the next person.
    else:
      for _ in 0 ..< 5:
        pending(ToolbarAwaited & " — the disabled-button corpus")
      expectCount(5)

suite "EMT §9 Run means record-then-replay, and the verdict is the artefact":

  test "EMT-A51/A52/A53/A55 four outcomes, and exit 0 is not one of them":
    ## EMT-D16, and the single most important assertion in the feature.
    ## `resources/codetracer-desktop-capabilities` records a SHIPPED case:
    ##
    ##   "KNOWN GAP: `.ex` `.exs` `.erl` `.hrl` ROUTE but do not RECORD.
    ##    `ct record foo.ex` **exits 0 with a recordingId and a 2-event,
    ##    0-function trace**."
    ##
    ## An exit-code verdict calls that SUCCESS and drops the user into an empty
    ## session. So A52 — exit 0 with no usable trace — must be an outcome
    ## DISTINCT from both success and failure, and distinct again from cancel.
    ## Four verdicts asserted as four, mutually distinct.
    startCount()
    when EditModeToolbarBuilt:
      let ok = runOutcome(exitCode = 0, traceOpened = true)
      let noTrace = runOutcome(exitCode = 0, traceOpened = false)
      let failed = runOutcome(exitCode = 1, traceOpened = false)
      let cancelled = runOutcomeCancelled()
      ck ok.entersDebugMode                    # A51
      ck not noTrace.entersDebugMode           # A52 — exit 0 is not enough
      ck noTrace != failed                     # A52 — and it is its OWN answer
      ck not failed.entersDebugMode            # A53
      ck failed.selectsProblems
      ck failed.revealsBuildPane
      ck cancelled != noTrace                  # A55 — no verdict at all
      ck cancelled != failed
      ck not cancelled.hasVerdict
    else:
      for _ in 0 ..< 9:
        pending("`runOutcome` — the artefact-not-exit-code verdict")
    expectCount(9)

  test "EMT-A54 a failure that matches no matcher still produces a row":
    ## Otherwise a build whose diagnostics nobody can parse looks like a build
    ## that succeeded and printed nothing. The exit code and the raw tail are
    ## the minimum honest content of that row.
    startCount()
    when EditModeToolbarBuilt:
      let outcome = runOutcome(exitCode = 101, traceOpened = false,
                               tail = "linker: totally unparseable\n")
      ck outcome.problems.len >= 1
      ck "101" in outcome.problems[0].message
      ck "unparseable" in outcome.problems[0].message
    else:
      for _ in 0 ..< 3:
        pending("`runOutcome` — the unmatched-failure row")
    expectCount(3)

  test "EMT-A50/A56 Run saves first, and never evicts a session":
    ## EMT-D17: a recording is replayed against source ON DISK, so recording
    ## unsaved buffers produces a trace whose line positions do not match the
    ## file on screen — silent, late, and it reads as a debugger bug. The save
    ## is unconditional and the Build pane header NAMES the files saved.
    ## EMT-D18: a new recording opens as a NEW session tab. No automatic
    ## eviction — silently closing a session someone was reading is worse than
    ## a crowded strip.
    startCount()
    when EditModeToolbarBuilt:
      let plan = runPlan(modifiedEditors = @["src/main.nr", "src/lib.nr"],
                         openSessions = 1)
      ck plan.savedFiles.len == 2
      ck "src/main.nr" in plan.savedFiles
      ck plan.headerNamesSavedFiles
      ck plan.sessionsAfter == 2               # A56 — two, not one
      ck not plan.evictsAnySession
    else:
      for _ in 0 ..< 5:
        pending("`runPlan` — save-first and no-eviction")
    expectCount(5)
