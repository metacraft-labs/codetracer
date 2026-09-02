## viewmodels/edit_mode_toolbar.nim
##
## `codetracer-specs/Planned-Features/Edit-Mode-Toolbar.md` — what the topbar
## carries in Edit mode, which button runs what, and why a button is disabled
## rather than missing.
##
## ## The defect this exists to end
##
## §1: there was **no `EditMode` check anywhere in the topbar path**.
## `topbar_actions.topbarModel` takes a `PlatformProfile` and a `fullscreen`
## flag and no mode, and `tbaDebuggerControls` was documented as *"always
## present — they are the product"*. So thirteen stepping buttons painted in
## Edit mode, where there is no session for them to control, and the three
## things a person in Edit mode actually wants — Build, Run, Run Tests — were
## nowhere.
##
## `topbarModel` is still the **platform** layer and still has no mode: which
## slots a platform can carry is a different question from which slots a mode
## carries, and collapsing them is how the next platform becomes a branch at
## every site that asks (`capabilities.nim`'s whole argument). This module
## composes the two.
##
## ## Why a new module and not more of `project_actions.nim`
##
## §3.4 of the spec contradicts itself — it calls the three gaps *"all additive
## to `project_actions.nim` — no new module"* and then says the selection layer
## *"belongs in a new pure module beside `project_actions.nim`"*. Both cannot
## hold, and the resolution is the second:
##
## * `isDefault` **is** additive and landed in `project_actions.nim`, because it
##   is a field of a declaration that module already reads.
## * Selection is not. It needs the platform profile, the wasm registry, the
##   project-kind heuristic and the mode — none of which `project_actions.nim`
##   knows about, and all of which it would have to import to host the layer.
##   `project_actions.nim`'s own header is explicit that it *"has no opinion
##   about verification, about Noir, or about Verno"*, and a selection layer has
##   opinions about all of them.
##
## ## Purity (EMT-A41)
##
## No `std/os`, no process, no `cstring`. `ci/test/hostfree-build.sh` covers
## `viewmodels/`. That is what lets the same suites run on C (`vm-unit`,
## desktop) and JS (`vm-unit-js`, **web** — the acceptance target). The listing
## and the provider results arrive as values, gathered by `host/` (EMT-D5).

import std/strutils

import ../store/types
import ../platform/capabilities
import ../platform/wasm_registry
import ./project_actions
import ./topbar_actions

export project_actions, topbar_actions

# ---------------------------------------------------------------------------
# The mode vocabulary
# ---------------------------------------------------------------------------

type
  ToolbarMode* = enum
    ## A **mirror** of `common/common_types/debugger_features/debugger.nim`'s
    ## `LayoutMode`, member for member and ordinal for ordinal, so that a host
    ## converts with `ToolbarMode(layout.ord)` and back.
    ##
    ## ## Why a mirror rather than an import, stated honestly
    ##
    ## `LayoutMode` appears **nowhere** in the ViewModel tree, and its declaring
    ## module is not standalone-importable: it needs `langstring` from its
    ## parent, and `store/types.nim` is deliberately *"independent of the legacy
    ## frontend types to avoid circular imports"*. So "add a mode parameter" was
    ## never a one-line change; it is either a mirror here or a refactor of
    ## `common/` that this feature does not need and should not smuggle in.
    ##
    ## A mirror is a sixth hand-maintained table, and this repository has been
    ## bitten five times by exactly that (EMT-F5 — `ct record player.gd` blamed
    ## a missing `ct-native-replay` that installing would not have helped). So
    ## the mirror is **derived-checked**: `static` below reads the declaration
    ## and fails the build if the two ever disagree. A table that cannot drift
    ## is not the thing §2.8 warns about.
    DebugMode
    EditMode
    QuickEditMode
    InteractiveEditMode
    CalltraceLayoutMode

const LayoutModeSrc =
  staticRead("../../../common/common_types/debugger_features/debugger.nim")

static:
  # Anchored to the declaration, not to a doc comment: the module's prose names
  # several of these words too, and a scan that matches prose is satisfied by
  # prose (`Verification-Harness-Traps.md` §4d).
  let at = LayoutModeSrc.find("LayoutMode* = enum")
  doAssert at >= 0, "LayoutMode is no longer declared where this mirror reads it"
  var declared: seq[string] = @[]
  for line in LayoutModeSrc[at .. ^1].splitLines:
    let t = line.strip
    if t.startsWith("LayoutMode*"): continue
    if t.len == 0 or not t[0].isUpperAscii: break
    declared.add t.strip(chars = {',', ' '})
  var mirrored: seq[string] = @[]
  for mode in ToolbarMode:
    mirrored.add $mode
  doAssert declared == mirrored,
    "ToolbarMode has drifted from LayoutMode: " & $declared & " vs " & $mirrored

proc isEditing*(mode: ToolbarMode): bool =
  ## The three editing layouts against the two replay ones.
  ##
  ## `CalltraceLayoutMode` counts as replaying: it is a reading surface over a
  ## trace that already exists, so rebuilding underneath it invalidates what it
  ## is showing — the same argument EMT-D12 makes for `deepReviewActive`.
  mode in {EditMode, QuickEditMode, InteractiveEditMode}

# ---------------------------------------------------------------------------
# §6.1 — the project-kind heuristic
# ---------------------------------------------------------------------------

type
  ProjectKind* = enum
    ## Every project shape the toolbar can recognise from a listing.
    ##
    ## ## The declaration ORDER is the tie-break, and only the tie-break
    ##
    ## §6.3 rule 4: *"Ties produce a multi-kind workspace, ordered by enum
    ## declaration purely for determinism"* — and the toolbar then behaves as
    ## §7.2, **disabled, offering a choice, never a silent pick**. So position
    ## here decides which candidate a `seq` happens to start with; it never
    ## decides which command runs.
    ##
    ## The members that `ct/utilities/language_detection.detectFolderLang` also
    ## tests for come **first and in that proc's own order**, because EMT-A40
    ## requires the two to agree on precedence and EMT-D9 adopts `ct`'s rule
    ## (nearest marker, no walk-up) over the native backend's walk-up. A Noir
    ## package inside a Cargo workspace is the live case: it is the layout of
    ## `metacraft-labs/noir` and of aztec-packages, and offering `cargo build`
    ## to somebody editing `.nr` files is the failure that ordering prevents.
    ##
    ## `pkJavascript` sits ahead of `pkRustCargo` and is the one placement that
    ## is not inherited from the chain — `detectFolderLang` has no `package.json`
    ## entry at all. It is not a claim that JS wins: a workspace with both is a
    ## tie, both are listed, and Build is disabled reading *"2 project kinds —
    ## choose one"*. See the note on `projectKinds`.

    # -- markers `detectFolderLang` also tests, in its order -----------------
    pkNoir
    pkCairo
    pkAiken
    pkMove
    pkSway
    pkSolidityFoundry
    pkJavascript
    pkRustCargo
    pkRustWasm
    pkLean
    pkCrystal
    pkLeo

    # -- manifests the toolbar adds (§10.1's additions) ----------------------
    pkGo
    pkElixir
    pkErlang
    pkD
    pkFortran
    pkCMakeConfigured
    pkCMakeUnconfigured
    pkNim
    pkPython
    pkRuby
    pkPhp
    pkJulia
    pkAda
    pkMake

    # -- recognised by extension only (§10.2) --------------------------------
    pkCircom
    pkMasm
    pkTolk
    pkCadence

  ProposalConfidence* = enum
    pcCanonical   ## Ships as a button. Only this tier reaches one (EMT-D8).
    pcAmbiguous   ## The kind is recognised; *which* command is not decidable.
    pcUnknown     ## The kind is recognised and has no build step at all.

  CommandProposal* = object
    command*: string
    args*: seq[string]
    confidence*: ProposalConfidence
    reason*: string
      ## Non-empty whenever `confidence != pcCanonical` (EMT-A48). Without that
      ## rule, *"every proposed command is canonical"* is satisfied by proposing
      ## nothing.

  RankedKind* = object
    kind*: ProjectKind
    marker*: string
      ## The listing entry that selected it — what a `cpConventional` tooltip
      ## has to name (EMT-A25).
    depth*: int
      ## Path components above the marker. §6.3 rule 1: a root marker outranks
      ## one a level down.

proc markerFiles*(kind: ProjectKind): seq[string] {.noSideEffect.} =
  ## The listing entries that select `kind`.
  ##
  ## `*.ext` is a suffix pattern; everything else is an exact basename.
  ## EMT-A40 asserts that every marker `detectFolderLang` tests for appears
  ## here, derived from that proc's source rather than transcribed beside it.
  case kind
  of pkNoir: @["Nargo.toml"]
  of pkCairo: @["Scarb.toml"]
  of pkAiken: @["aiken.toml"]
  of pkMove: @["Move.toml"]
  of pkSway: @["Forc.toml"]
  of pkSolidityFoundry: @["foundry.toml"]
  of pkJavascript: @["package.json"]
  of pkRustCargo: @["Cargo.toml"]
  # `pkRustWasm` carries the SAME marker. §6.3: the two are told apart by the
  # *contents* of `.cargo/config.toml`, which no filename can express, so
  # `projectKinds` is handed `hasWasm32CargoConfig` and never guesses.
  of pkRustWasm: @["Cargo.toml"]
  of pkLean: @["lakefile.lean"]
  of pkCrystal: @["shard.yml"]
  of pkLeo: @["program.json"]
  of pkGo: @["go.mod"]
  of pkElixir: @["mix.exs"]
  of pkErlang: @["rebar.config"]
  of pkD: @["dub.json", "dub.sdl"]
  of pkFortran: @["fpm.toml"]
  of pkCMakeConfigured: @["CMakeLists.txt"]
  of pkCMakeUnconfigured: @["CMakeLists.txt"]
  of pkNim: @["*.nimble"]
  of pkPython: @["pyproject.toml"]
  of pkRuby: @["Gemfile"]
  of pkPhp: @["composer.json"]
  of pkJulia: @["Project.toml"]
  of pkAda: @["alire.toml", "*.gpr"]
  of pkMake: @["Makefile"]
  of pkCircom: @["*.circom"]
  of pkMasm: @["*.masm"]
  of pkTolk: @["*.tolk"]
  of pkCadence: @["*.cdc"]

proc displayName*(kind: ProjectKind): string {.noSideEffect.} =
  case kind
  of pkNoir: "Noir"
  of pkCairo: "Cairo (Scarb)"
  of pkAiken: "Aiken"
  of pkMove: "Move"
  of pkSway: "Sway"
  of pkSolidityFoundry: "Solidity (Foundry)"
  of pkJavascript: "JavaScript / TypeScript"
  of pkRustCargo: "Rust (Cargo)"
  of pkRustWasm: "Rust → wasm"
  of pkLean: "Lean"
  of pkCrystal: "Crystal"
  of pkLeo: "Leo"
  of pkGo: "Go"
  of pkElixir: "Elixir"
  of pkErlang: "Erlang"
  of pkD: "D (dub)"
  of pkFortran: "Fortran (fpm)"
  of pkCMakeConfigured: "C/C++ (CMake)"
  of pkCMakeUnconfigured: "C/C++ (CMake, not configured)"
  of pkNim: "Nim"
  of pkPython: "Python"
  of pkRuby: "Ruby"
  of pkPhp: "PHP"
  of pkJulia: "Julia"
  of pkAda: "Ada"
  of pkMake: "C/C++ (Make)"
  of pkCircom: "Circom"
  of pkMasm: "MASM"
  of pkTolk: "Tolk"
  of pkCadence: "Cadence"

proc buildProposal*(kind: ProjectKind): CommandProposal {.noSideEffect.} =
  ## §10.1 and §10.2, as one total function.
  ##
  ## Total over the enum by construction — `case` without an `else` is a
  ## compile error in Nim when a member is missing, which is what makes
  ## EMT-A47 a real assertion rather than a hope. Every non-`pcCanonical` row
  ## carries a reason, because a button that is off and says nothing teaches
  ## the user that the feature is broken rather than that the project has no
  ## build step (EMT-D14).
  ##
  ## ⟨unverified⟩ — the commands are ecosystem convention as understood by the
  ## spec's author and by this one. `nargo compile` is the one that matters for
  ## §13 and it **is** verified: it is the command whose recorded failure
  ## transcript `test-programs/noir_build_error` carries.
  template canonical(cmd: string; a: seq[string]): CommandProposal =
    CommandProposal(command: cmd, args: a, confidence: pcCanonical, reason: "")
  template unsure(why: string): CommandProposal =
    CommandProposal(confidence: pcAmbiguous, reason: why)
  template noBuildStep(why: string): CommandProposal =
    CommandProposal(confidence: pcUnknown, reason: why)

  case kind
  of pkRustCargo: canonical("cargo", @["build"])
  of pkRustWasm:
    # `wasm32-wasip1`, not `wasm32-unknown-unknown`: it is the target the
    # product itself records against (`ct/trace/record.nim`), so a build that
    # produced the other one could not then be replayed.
    canonical("cargo", @["build", "--target", "wasm32-wasip1"])
  of pkNoir: canonical("nargo", @["compile"])
  of pkGo: canonical("go", @["build", "./..."])
  of pkElixir: canonical("mix", @["compile"])
  of pkErlang: canonical("rebar3", @["compile"])
  of pkD: canonical("dub", @["build"])
  of pkSolidityFoundry: canonical("forge", @["build"])
  of pkSway: canonical("forc", @["build"])
  of pkCrystal: canonical("shards", @["build"])
  of pkCairo: canonical("scarb", @["build"])
  of pkAiken: canonical("aiken", @["build"])
  of pkLean: canonical("lake", @["build"])
  of pkFortran: canonical("fpm", @["build"])
  of pkCMakeConfigured: canonical("cmake", @["--build", "build"])

  of pkCMakeUnconfigured:
    unsure("`cmake --build build` fails until `cmake -B build` has been run, " &
           "and a command that fails on a clean clone is worse than none. " &
           "Configure the project and the Build button turns on.")
  of pkJavascript:
    unsure("a `package.json` declares its build in `scripts.build`, which is a " &
           "declaration rather than a convention — CodeTracer runs what the " &
           "project declared and invents no npm command of its own.")
  of pkNim:
    unsure("`nimble build` needs a `bin:` entry the manifest may not declare, " &
           "and a bare `nim c` needs a main module no marker names.")
  of pkMove:
    unsure("two incompatible ecosystems share `Move.toml` — Sui builds with " &
           "`sui move build` and Aptos with `aptos move compile`. Choosing " &
           "would be wrong for half of all Move projects.")
  of pkLeo:
    unsure("the Leo CLI has changed shape across releases, so no single build " &
           "command is safe to propose. ⟨unverified⟩")
  of pkAda:
    unsure("`alr build` is likely, and was not verified against a current " &
           "Alire. Listed so the gap is visible rather than filled.")
  of pkMake:
    unsure("a `Makefile`'s default target is not guaranteed to build, and a " &
           "`Makefile` beside a `CMakeLists.txt` is usually a wrapper.")
  of pkCircom:
    unsure("Circom compiles per file with output flags, and no marker names " &
           "the entry circuit.")
  of pkMasm, pkTolk, pkCadence:
    unsure("a recorder entry exists for this language, and its build " &
           "convention was not verified. Listed so the gap is visible rather " &
           "than filled. ⟨unverified⟩")

  of pkPython:
    noBuildStep("Python projects usually have no build step; use Run.")
  of pkRuby:
    noBuildStep("Ruby projects have no build step; use Run.")
  of pkPhp:
    noBuildStep("PHP projects have no build step; a `composer.json` `scripts` " &
                "entry is read as a declaration where one exists.")
  of pkJulia:
    noBuildStep("Julia projects have no build step; use Run.")

proc runProposal*(kind: ProjectKind): CommandProposal {.noSideEffect.} =
  ## Run means **record-then-replay** (§9.1), so a conventional Run command is
  ## not a guess at the project's entry point — §7.1 is right to forbid that —
  ## it is the **recorder** for the language, which is the product's own and is
  ## known where it is known at all.
  ##
  ## Total, and canonical in exactly one place today. `nargo trace` is the
  ## command §8.1 names as the one that decides whether Noir Studio's Run
  ## button is on: *"Build enabled exactly when a `nargo compile` module is
  ## registered, and Run exactly when a `nargo trace` module is."*
  ##
  ## Everything else answers with a reason, and that is not a placeholder: a
  ## Foundry project genuinely has Build and Run Tests and no Run, and saying
  ## so on the button is what teaches a user the feature exists (§8, EMT-A27).
  case kind
  of pkNoir:
    CommandProposal(command: "nargo", args: @["trace"],
                    confidence: pcCanonical, reason: "")
  else:
    CommandProposal(
      confidence: pcUnknown,
      reason: "Run records a trace, and recording " & kind.displayName &
        " needs an entry point that no marker file names. Declare a " &
        "configuration in `.vscode/launch.json` and it appears here.")

# ---------------------------------------------------------------------------
# Matching a listing against the marker tables
# ---------------------------------------------------------------------------

proc basename(path: string): string {.noSideEffect.} =
  ## Last `/`-separated component. Not `os.extractFilename`: `std/os` is
  ## exactly what the purity rule forbids, and the listing contract (§4.2)
  ## already fixes `/` as the separator on every platform.
  let at = path.rfind('/')
  if at < 0: path else: path[at + 1 .. ^1]

proc depthOf(path: string): int {.noSideEffect.} =
  for ch in path:
    if ch == '/': inc result
  # A trailing `/` marks a directory rather than another level.
  if path.len > 0 and path[^1] == '/': dec result
  if result < 0: result = 0

proc matchesMarker(entry, marker: string): bool {.noSideEffect.} =
  let name = entry.basename
  if marker.startsWith("*."):
    name.len > marker.len - 1 and name.endsWith(marker[1 .. ^1])
  else:
    name == marker

proc projectKinds*(listing: seq[string];
                   hasWasm32CargoConfig = false): seq[RankedKind]
                  {.noSideEffect.} =
  ## Every kind the listing recognises, ranked. May be empty — that is the
  ## unrecognised-folder case, and it is what hides the command group rather
  ## than showing a row of dead buttons (§8).
  ##
  ## ## The ranking, and what it is allowed to decide
  ##
  ## 1. **Depth** — a root marker outranks one a level down (§6.3 rule 1).
  ## 2. **Enum declaration order** at equal depth, which for the members
  ##    `detectFolderLang` also knows is that proc's own order (EMT-A40's
  ##    precedence half, EMT-D9's Noir-over-Cargo).
  ##
  ## It decides which candidate is *first in a list*. It never decides which
  ## command runs: `editModeToolbar` disables Build whenever more than one kind
  ## is ranked, because §7.2/EMT-D11 says multiple candidates must never
  ## resolve by array position, alphabet or first-wins. A build that silently
  ## ran a different task after somebody reordered a file costs an afternoon
  ## and leaves no trace in the UI.
  ##
  ## **A loose source file never outranks a manifest** (§6.3 rule 3) — it does
  ## not appear at all, because `main.py` is not a marker. `pkPython`'s marker
  ## is `pyproject.toml`.
  var wanted: set[ProjectKind] = {}
  for kind in ProjectKind:
    wanted.incl kind
  # `Cargo.toml` selects exactly one of the two Rust kinds, by the CONTENTS of
  # `.cargo/config.toml` — which a listing cannot carry and must not be asked
  # to imply, so the host answers it (§6.3).
  if hasWasm32CargoConfig:
    wanted.excl pkRustCargo
  else:
    wanted.excl pkRustWasm

  # `cmake --build build` only works once somebody has configured, and the
  # condition is listing-visible, so it stays pure (§10.1).
  var configured = false
  for entry in listing:
    if entry.basename == "CMakeCache.txt":
      configured = true
      break
  if configured:
    wanted.excl pkCMakeUnconfigured
  else:
    wanted.excl pkCMakeConfigured

  var seen: set[ProjectKind] = {}
  for kind in ProjectKind:
    if kind notin wanted:
      continue
    var bestDepth = -1
    var bestMarker = ""
    for entry in listing:
      for marker in markerFiles(kind):
        if entry.matchesMarker(marker):
          let d = entry.depthOf
          if bestDepth < 0 or d < bestDepth:
            bestDepth = d
            bestMarker = entry
    if bestDepth >= 0 and kind notin seen:
      seen.incl kind
      result.add RankedKind(kind: kind, marker: bestMarker, depth: bestDepth)

  # Shallowest first; enum order within a depth, which is the order the loop
  # above already produced, so the sort must be STABLE.
  var sorted: seq[RankedKind] = @[]
  var maxDepth = 0
  for ranked in result:
    if ranked.depth > maxDepth: maxDepth = ranked.depth
  for d in 0 .. maxDepth:
    for ranked in result:
      if ranked.depth == d:
        sorted.add ranked
  result = sorted

# ---------------------------------------------------------------------------
# §5 — provenance, and §7.1 — selection
# ---------------------------------------------------------------------------

type
  CommandProvenance* = enum
    cpNone          ## No command for this verb at all.
    cpDeclared      ## `tasks.json`, `package.json`, or `launch.json`.
    cpProvider      ## A `ct_test` provider recognised the project.
    cpConventional  ## Inferred from a marker file. Asks before it runs.

  BuildSelection* = object
    ## §7.1's ordered search for the Build verb, and §7.2's refusal to pick.
    resolved*: bool
    action*: ProjectAction
    candidates*: seq[ProjectAction]
      ## Every candidate at the step that produced more than one. Listed so the
      ## dropdown can offer the choice; the reason names the count.
    reason*: string

proc selectBuildCommand*(actions: ProjectActionSet): BuildSelection
                        {.noSideEffect.} =
  ## §7.1 Build: (1) `group.kind == "build"` **and** `isDefault`;
  ## (2) `group.kind == "build"`; (3) `package.json` `scripts.build`.
  ##
  ## More than one candidate at any step is §7.2, never an implicit pick — and
  ## this is where "first wins" would go in. It is not here, and EMT-A17 is the
  ## assertion that proves it: the same tasks in a different array ORDER must
  ## produce the same outcome. That is a real assertion rather than a tautology
  ## precisely because array position is what a naive implementation uses.
  proc decide(candidates: seq[ProjectAction]; what: string): BuildSelection =
    if candidates.len == 1:
      BuildSelection(resolved: true, action: candidates[0],
                     candidates: candidates, reason: "")
    else:
      BuildSelection(
        resolved: false, candidates: candidates,
        reason: $candidates.len & " " & what & " — choose one")

  var defaults, builds, scripts: seq[ProjectAction] = @[]
  for action in actions.actions:
    if action.group == pagBuild:
      builds.add action
      if action.isDefault:
        defaults.add action
    elif action.source == pasPackageJson and action.label == "build":
      scripts.add action

  if defaults.len > 0:
    return decide(defaults, "default build tasks")
  if builds.len > 0:
    return decide(builds, "build tasks")
  if scripts.len > 0:
    return decide(scripts, "`build` scripts")
  BuildSelection(resolved: false, candidates: @[], reason: "")

proc selectTestCommand*(actions: ProjectActionSet): BuildSelection
                       {.noSideEffect.} =
  ## §7.1 Run Tests, by the same three steps over `group.kind == "test"`.
  var defaults, tests, scripts: seq[ProjectAction] = @[]
  for action in actions.actions:
    if action.group == pagTest:
      tests.add action
      if action.isDefault:
        defaults.add action
    elif action.source == pasPackageJson and action.label == "test":
      scripts.add action

  proc decide(candidates: seq[ProjectAction]; what: string): BuildSelection =
    if candidates.len == 1:
      BuildSelection(resolved: true, action: candidates[0],
                     candidates: candidates, reason: "")
    else:
      BuildSelection(resolved: false, candidates: candidates,
                     reason: $candidates.len & " " & what & " — choose one")

  if defaults.len > 0: return decide(defaults, "default test tasks")
  if tests.len > 0: return decide(tests, "test tasks")
  if scripts.len > 0: return decide(scripts, "`test` scripts")
  BuildSelection(resolved: false, candidates: @[], reason: "")

# ---------------------------------------------------------------------------
# §8 — the buttons
# ---------------------------------------------------------------------------

type
  DisabledCause* = enum
    ## EMT-A29 asserts the fixture corpus produces each of these, **by count
    ## per cause** — because *"every disabled button has a reason"* is
    ## otherwise satisfied by a corpus with no disabled buttons (§16.1).
    dcNotDisabled
    dcNoCommand
    dcCapability
    dcAmbiguous
    dcUnconfigured
    dcNoProvider
    dcProviderNotImplemented

  ToolbarButton* = object
    action*: TopbarAction
    id*: string
      ## The DOM id. `debug-toolbar-ids.ts` is a **published contract** with
      ## Playwright, so none of the ten existing ids is renamed here.
      ##
      ## ⚠ `run-tests-image` is not new: it exists today and routes to
      ## `ct record-test`, which is *recording*, not running. Adopting the
      ## mapping below therefore changes what an existing id does, and must
      ## land in the same change as the page objects. Recorded here rather than
      ## discovered by a 30 s locator timeout, which is how the two page
      ## objects drifted last time.
    label*: string
    command*: string
      ## The **executable**, exactly as `ProjectAction.command` and
      ## `CommandProposal.command` mean it. The full line is `commandLine`.
    args*: seq[string]
    commandLine*: string
    provenance*: CommandProvenance
    enabled*: bool
    reason*: string
      ## Why it is off. Never empty when `not enabled` (EMT-D14/EMT-A28): a
      ## disabled button with an empty reason is a defect, and is asserted as
      ## one.
    cause*: DisabledCause
    requiresConfirmation*: bool
      ## EMT-D7: a `cpConventional` command is never run without an explicit
      ## confirmation showing the exact command line. CodeTracer proposes; the
      ## developer disposes.
    tooltip*: string
    candidates*: seq[string]
      ## The split button's dropdown (§7.2). Non-empty exactly when the button
      ## is off for `dcAmbiguous`.

  EditToolbarModel* = object
    mode*: ToolbarMode
    actions*: set[TopbarAction]
    commandGroupVisible*: bool
      ## §8's split is on **recognition**, not availability. A folder of notes
      ## gets no row of dead buttons; a folder of notes *with a `tasks.json`*
      ## does, because something was declared.
    kinds*: seq[RankedKind]
    build*: ToolbarButton
    run*: ToolbarButton
    runTests*: ToolbarButton
    recordTests*: ToolbarButton
    buttons*: seq[ToolbarButton]
    problems*: seq[string]
      ## Declarations that could not be read, carried through from
      ## `project_actions` so a developer looking for a task they wrote is told
      ## why it is missing in the place they looked.

  TestProviderInfo* = object
    ## A `ct_test` provider's answer, as data.
    ##
    ## EMT-D5 draws the pure/host line at the existing boundary rather than
    ## moving it: the providers' `detect` procs take a `projectRoot` and are not
    ## pure, so `host/` calls them and the results arrive here as values.
    ##
    ## `canRun` / `canRecord` are read from the **installed proc**, never from
    ## the declared capability flags — §2.4 hazard 3, and not hypothetical:
    ## `rust_libtest` declares `canRunProject: true` and installs
    ## `notImplementedRun`, so a Run Tests button built from the flags is
    ## enabled for Rust and does nothing (EMT-A22).
    id*: string
    displayName*: string
    canRun*: bool
    canRecord*: bool
    runCommand*: string
    runArgs*: seq[string]
    recordRefusal*: string
      ## The provider's own words for why it will not record. Noir's is
      ## load-bearing: it refuses test recording, so §13 reaches a replay
      ## session through **Run**, not Record Tests (EMT-F6/EMT-A21).

proc idFor(action: TopbarAction): string =
  case action
  of tbaBuild: "build-image"
  of tbaRun: "run-image"
  of tbaRunTests: "run-tests-image"
  of tbaRecordTests: "record-tests-image"
  of tbaActionOverflow: "action-overflow-image"
  else: ""

proc labelFor(action: TopbarAction): string =
  case action
  of tbaBuild: "Build"
  of tbaRun: "Run"
  of tbaRunTests: "Run Tests"
  of tbaRecordTests: "Record Tests"
  of tbaActionOverflow: "More"
  else: ""

proc disabled(action: TopbarAction; cause: DisabledCause;
              reason: string; candidates: seq[string] = @[]): ToolbarButton =
  ToolbarButton(action: action, id: action.idFor, label: action.labelFor,
                enabled: false, reason: reason, cause: cause,
                provenance: cpNone, candidates: candidates)

# ---------------------------------------------------------------------------
# §8.1 — the platform gate
# ---------------------------------------------------------------------------

type PlatformVerdict = object
  allowed: bool
  reason: string
  cause: DisabledCause

proc platformVerdict(profile: PlatformProfile; wasm: WasmRegistry;
                     command: string; args: seq[string]): PlatformVerdict =
  ## EMT-D15, and the whole of the browser tier.
  ##
  ## A platform with `capProcessArbitraryPrograms` runs whatever the project
  ## names. A platform with `capProcessSpawn` and **not** that one — the web,
  ## whose process column is *"wasm modules in the tab"* — runs a command only
  ## if it resolves to a registered module, **at subcommand granularity**.
  ##
  ## The sentence a refused button carries is the profile's own
  ## `degradedBehaviour`, which is the promise `webProfile` already makes
  ## ("reported as unavailable by name, with the command shown"). The one
  ## exception is `wrSubcommandNotBuilt`, where the registry can say something
  ## strictly more useful — *this part of a tool you have is missing*, and
  ## which parts you do have. Collapsing that into the generic sentence is the
  ## loss `wasm_registry.nim` was written to prevent.
  if profile.has(capProcessArbitraryPrograms):
    return PlatformVerdict(allowed: true)
  if not profile.has(capProcessSpawn):
    return PlatformVerdict(
      allowed: false, cause: dcCapability,
      reason: profile.degradedBehaviour(capProcessSpawn))

  let resolution = wasm.resolve(command, args)
  case resolution.kind
  of wrResolved:
    PlatformVerdict(allowed: true)
  of wrSubcommandNotBuilt:
    PlatformVerdict(
      allowed: false, cause: dcCapability,
      reason: "`" & command & " " & resolution.subcommand & "` is not in " &
        "this build of " & resolution.module.displayName & "; it implements " &
        resolution.available.join(", ") & ".")
  else:
    PlatformVerdict(
      allowed: false, cause: dcCapability,
      reason: profile.degradedBehaviour(capProcessArbitraryPrograms))

# ---------------------------------------------------------------------------
# §7 — the toolbar
# ---------------------------------------------------------------------------

proc conventionalTooltip(proposal: CommandProposal; marker: string): string =
  var line = proposal.command
  for arg in proposal.args:
    line.add ' '
    line.add arg
  line & " — inferred from `" & marker & "`; CodeTracer is guessing"

proc declaredButton(action: TopbarAction; selection: BuildSelection;
                    profile: PlatformProfile;
                    wasm: WasmRegistry): ToolbarButton =
  let act = selection.action
  let verdict = platformVerdict(profile, wasm, act.command, act.args)
  result = ToolbarButton(
    action: action, id: action.idFor, label: act.label,
    command: act.command, args: act.args, commandLine: act.commandLine,
    provenance: cpDeclared, enabled: verdict.allowed,
    reason: verdict.reason, cause: verdict.cause,
    requiresConfirmation: false, tooltip: act.commandLine)

proc conventionalButton(action: TopbarAction; proposal: CommandProposal;
                        marker: string; profile: PlatformProfile;
                        wasm: WasmRegistry): ToolbarButton =
  var line = proposal.command
  for arg in proposal.args:
    line.add ' '
    line.add arg
  let verdict = platformVerdict(profile, wasm, proposal.command, proposal.args)
  result = ToolbarButton(
    action: action, id: action.idFor, label: action.labelFor,
    command: proposal.command, args: proposal.args, commandLine: line,
    provenance: cpConventional, enabled: verdict.allowed,
    reason: verdict.reason, cause: verdict.cause,
    requiresConfirmation: true,
    tooltip: conventionalTooltip(proposal, marker))

proc commandButton(action: TopbarAction; selection: BuildSelection;
                   kinds: seq[RankedKind];
                   proposal: proc(kind: ProjectKind): CommandProposal
                     {.noSideEffect.};
                   profile: PlatformProfile;
                   wasm: WasmRegistry): ToolbarButton =
  ## §7.1's ordered search, expressed once for Build and Run: a declaration
  ## beats a guess, and a guess beats nothing but has to ask (EMT-A18/A19).
  if selection.resolved:
    return declaredButton(action, selection, profile, wasm)
  if selection.candidates.len > 1:
    var labels: seq[string] = @[]
    for candidate in selection.candidates:
      labels.add candidate.label
    return disabled(action, dcAmbiguous, selection.reason, labels)

  if kinds.len == 0:
    return disabled(action, dcNoCommand,
      "CodeTracer does not recognise this folder as a project, and it " &
      "declares no " & action.labelFor.toLowerAscii & " task.")
  if kinds.len > 1:
    var names: seq[string] = @[]
    for ranked in kinds:
      names.add ranked.kind.displayName
    return disabled(action, dcAmbiguous,
      $kinds.len & " project kinds — choose one", names)

  let proposed = proposal(kinds[0].kind)
  if proposed.confidence != pcCanonical:
    # EMT-D8: only `pcCanonical` reaches a button. The kind IS recognised, so
    # this is disabled-with-a-reason and not hidden — §8's split, and where a
    # lazy implementation hides a gap by pretending not to know the project.
    return disabled(action,
      if proposed.confidence == pcAmbiguous: dcAmbiguous else: dcNoCommand,
      proposed.reason)
  conventionalButton(action, proposed, kinds[0].marker, profile, wasm)

proc testButtons(kinds: seq[RankedKind]; declared: BuildSelection;
                 providers: seq[TestProviderInfo];
                 profile: PlatformProfile;
                 wasm: WasmRegistry): tuple[run, record: ToolbarButton] =
  ## §10.3: **Run Tests** yields pass/fail, **Record Tests** yields a
  ## debuggable trace. Two buttons, because they have different backings and
  ## different availability — and collapsing them is why the single existing
  ## button is misleading.
  if declared.resolved:
    let button = declaredButton(tbaRunTests, declared, profile, wasm)
    var recorded = button
    recorded.action = tbaRecordTests
    recorded.id = tbaRecordTests.idFor
    return (button, recorded)
  if declared.candidates.len > 1:
    var labels: seq[string] = @[]
    for candidate in declared.candidates:
      labels.add candidate.label
    return (disabled(tbaRunTests, dcAmbiguous, declared.reason, labels),
            disabled(tbaRecordTests, dcAmbiguous, declared.reason, labels))

  if providers.len == 0:
    let why =
      if kinds.len == 0:
        "CodeTracer does not recognise this folder as a project, and it " &
        "declares no test task."
      else:
        "no test framework was detected in this " &
        kinds[0].kind.displayName & " project, and it declares no test task."
    return (disabled(tbaRunTests, dcNoProvider, why),
            disabled(tbaRecordTests, dcNoProvider, why))

  let provider = providers[0]
  var runButton: ToolbarButton
  if not provider.canRun:
    # EMT-A22 / §2.4 hazard 3: read the INSTALLED proc, never the declared
    # capability flag. `rust_libtest` declares `canRunProject: true` and
    # installs `notImplementedRun`.
    runButton = disabled(tbaRunTests, dcProviderNotImplemented,
      provider.displayName & " is detected, but running its tests is not " &
      "implemented in this build.")
  else:
    let verdict = platformVerdict(profile, wasm, provider.runCommand,
                                  provider.runArgs)
    var line = provider.runCommand
    for arg in provider.runArgs:
      line.add ' '
      line.add arg
    runButton = ToolbarButton(
      action: tbaRunTests, id: tbaRunTests.idFor, label: "Run Tests",
      command: provider.runCommand, args: provider.runArgs, commandLine: line,
      provenance: cpProvider, enabled: verdict.allowed,
      reason: verdict.reason, cause: verdict.cause,
      tooltip: line & " — " & provider.displayName)

  var recordButton: ToolbarButton
  if not provider.canRecord:
    # EMT-F6/EMT-A21. Noir is the case that matters: the one language the
    # acceptance journey is written for refuses test *recording*, in the
    # provider's own words — a recorded `nargo test` would be "a trace of one
    # event and zero steps".
    recordButton = disabled(tbaRecordTests, dcProviderNotImplemented,
      if provider.recordRefusal.len > 0: provider.recordRefusal
      else: provider.displayName & " cannot record a test run in this build.")
  else:
    recordButton = runButton
    recordButton.action = tbaRecordTests
    recordButton.id = tbaRecordTests.idFor
    recordButton.label = "Record Tests"
  (runButton, recordButton)

proc editModeToolbar*(profile: PlatformProfile;
                      mode: ToolbarMode;
                      deepReviewActive = false;
                      tasksJson = "";
                      packageJson = "";
                      listing: seq[string] = @[];
                      hasWasm32CargoConfig = false;
                      wasm = WasmRegistry();
                      providers: seq[TestProviderInfo] = @[]):
                     EditToolbarModel =
  ## §7.3's table, computed.
  ##
  ## The mode is a **parameter**, not a `when defined(...)` (EMT-A5): one test
  ## process has to produce both answers, or the two modes are untestable
  ## against each other. That is the same argument `topbar_actions.nim` makes
  ## about `defined(ctmacos)`, and it is why this feature could be written at
  ## all.
  let declaredActions = collectProjectActions(tasksJson, packageJson)
  let kinds = projectKinds(listing, hasWasm32CargoConfig)
  let editing = mode.isEditing

  result.mode = mode
  result.kinds = kinds
  result.problems = declaredActions.problems
  result.actions = topbarModel(profile).actions

  # §7.3: `tbaDebuggerControls` is mode-gated. There is no session in Edit
  # mode, so there is nothing for a stepping button to step.
  if editing:
    result.actions.excl tbaDebuggerControls

  # The test buttons are in BOTH modes: recording a test run is one way into
  # Debug mode, and re-running tests from a session is how you check a fix.
  result.actions.incl tbaRunTests
  result.actions.incl tbaRecordTests

  # §8's recognition split. Something recognised OR something declared shows
  # the group; neither hides it. A platform that can spawn nothing at all must
  # not claim it can run something (EMT-A31).
  result.commandGroupVisible =
    profile.has(capProcessSpawn) and
    (kinds.len > 0 or declaredActions.actions.len > 0)

  let buildSelection = selectBuildCommand(declaredActions)
  let testSelection = selectTestCommand(declaredActions)

  result.build = commandButton(tbaBuild, buildSelection, kinds, buildProposal,
                               profile, wasm)
  result.run = commandButton(tbaRun, BuildSelection(), kinds, runProposal,
                             profile, wasm)
  let tests = testButtons(kinds, testSelection, providers, profile, wasm)
  result.runTests = tests.run
  result.recordTests = tests.record
  result.buttons = @[result.build, result.run, result.runTests,
                     result.recordTests]

  # EMT-D12: Build and Run are **absent** in Debug mode, not deprioritised —
  # rebuilding underneath a live replay invalidates the trace being replayed.
  # With `deepReviewActive` they are absent in both modes, because a review is
  # a reading surface over a trace that already exists. `deepReviewActive` is
  # a third argument rather than a fourth mode because it is the separate flag
  # `data.deepReviewActive`, not a `LayoutMode` member.
  if editing and not deepReviewActive and result.commandGroupVisible:
    result.actions.incl tbaBuild
    result.actions.incl tbaRun
    result.actions.incl tbaActionOverflow

# ---------------------------------------------------------------------------
# §9 — Run means record-then-replay, and the verdict is the artefact
# ---------------------------------------------------------------------------

type
  RunVerdict* = enum
    ## Four outcomes, and **exit 0 is not one of them** (EMT-D16).
    ##
    ## `resources/codetracer-desktop-capabilities` records the shipped case
    ## this enum exists for:
    ##
    ##   "KNOWN GAP: `.ex` `.exs` `.erl` `.hrl` ROUTE but do not RECORD.
    ##    `ct record foo.ex` **exits 0 with a recordingId and a 2-event,
    ##    0-function trace**."
    ##
    ## An exit-code verdict calls that SUCCESS and drops the user into an empty
    ## session. So *"ran, produced no trace"* is its own answer, distinct from
    ## both failure and cancellation.
    rvNone          ## Cancelled: no verdict at all.
    rvRecorded      ## A trace was produced and opened.
    rvNoTrace       ## Ran, exited cleanly, produced nothing replayable.
    rvFailed        ## Build or execution failure.

  RunOutcome* = object
    verdict*: RunVerdict
    exitCode*: int
    entersDebugMode*: bool
    selectsProblems*: bool
    revealsBuildPane*: bool
    hasVerdict*: bool
    problems*: seq[BuildProblemLine]
    reason*: string

proc runOutcome*(exitCode: int; traceOpened: bool;
                 tail = ""): RunOutcome {.noSideEffect.} =
  ## **The verdict comes from the artefact — a trace directory that opens —
  ## never from the exit code.**
  ##
  ## `tail` is the raw end of the child's output, and it is what makes a
  ## failure nobody could parse still produce a row (EMT-A54). Otherwise a
  ## build whose diagnostics no matcher recognises looks exactly like a build
  ## that succeeded and printed nothing.
  if traceOpened:
    return RunOutcome(verdict: rvRecorded, exitCode: exitCode,
                      entersDebugMode: true, hasVerdict: true)

  if exitCode == 0:
    return RunOutcome(
      verdict: rvNoTrace, exitCode: exitCode, hasVerdict: true,
      selectsProblems: true, revealsBuildPane: true,
      reason: "the run finished without error and produced no trace to " &
        "replay, so there is nothing to open.",
      problems: @[BuildProblemLine(
        severity: blsError, path: "", line: 0, col: 0,
        message: "the run exited 0 and produced no trace" &
          (if tail.len > 0: ": " & tail.strip else: ""))])

  RunOutcome(
    verdict: rvFailed, exitCode: exitCode, hasVerdict: true,
    selectsProblems: true, revealsBuildPane: true,
    reason: "the run failed with exit code " & $exitCode,
    problems: @[BuildProblemLine(
      severity: blsError, path: "", line: 0, col: 0,
      message: "exited " & $exitCode &
        (if tail.len > 0: ": " & tail.strip else: ""))])

proc runOutcomeCancelled*(): RunOutcome {.noSideEffect.} =
  ## §9.2's fourth state. A cancelled recording establishes **nothing** — the
  ## web profile's own degradation sentence for `capProcessGracefulSignal`
  ## says as much — so it is not a failure and not a success, and it must not
  ## be equal to either.
  RunOutcome(verdict: rvNone, exitCode: -1, hasVerdict: false,
             reason: "cancelled before a verdict")

type RunPlan* = object
  ## What Run does **before** it records (§9.3).
  savedFiles*: seq[string]
  headerNamesSavedFiles*: bool
  sessionsAfter*: int
  evictsAnySession*: bool

proc runPlan*(modifiedEditors: seq[string];
              openSessions: int): RunPlan {.noSideEffect.} =
  ## EMT-D17: Run saves all modified editors first, **unconditionally**, and
  ## the Build pane header names the files saved. A recording is replayed
  ## against source on disk, so recording unsaved buffers produces a trace
  ## whose line positions do not match the file on screen — silent, late, and
  ## it reads as a debugger bug.
  ##
  ## EMT-D18: the new recording opens as a **new** session tab. No automatic
  ## eviction: silently closing a session someone was reading is worse than a
  ## crowded strip, and *"a developer comparing a passing and a failing case
  ## does not lose one to look at the other"* is the motivating case.
  RunPlan(savedFiles: modifiedEditors,
          headerNamesSavedFiles: modifiedEditors.len > 0,
          sessionsAfter: openSessions + 1,
          evictsAnySession: false)
