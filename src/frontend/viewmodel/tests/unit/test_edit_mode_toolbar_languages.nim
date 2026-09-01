## test_edit_mode_toolbar_languages.nim
##
## Edit-Mode-Toolbar.md §6 and §10 — the project-kind heuristic and the
## language matrix. EMT-A23, A40-A49, A60, A61, A62.
##
## ## THIS SUITE IS PARTLY RED ON `dev`, AND IT IS SUPPOSED TO BE.
##
## It states the CORRECT expectation for behaviour that is **not built**, and
## never asserts today's behaviour where today's behaviour is wrong. It goes
## green on its own when `viewmodels/edit_mode_toolbar.nim` lands — no edit to
## this file. Registered in
## `codetracer-specs/Testing/Known-Test-Failures.md`.
##
## **The suite is deliberately not uniformly red.** Three of its checks pass
## today, and they are the controls that stop the rest being vacuous
## (`Verification-Harness-Traps.md` §4/§4a): the anti-drift scan over
## `detectFolderLang`, the `smart-*` exclusion scan, and the `Lang` cardinality
## contract all read source that already exists. If those go red, the red ones
## below are not measuring what they claim to.
##
## ## What the implementer has to provide, and where
##
## §3.4 of the spec is self-contradictory about the module — it says the three
## gaps are "all additive to `project_actions.nim` — **no new module**" and
## then that the selection layer "belongs in **a new pure module** *beside*
## `project_actions.nim`". This suite resolves it in the direction §4's diagram
## implies and **states the choice as a contract**, because a probe cannot
## search for a file whose name nobody fixed:
##
##     src/frontend/viewmodel/viewmodels/edit_mode_toolbar.nim
##
## exporting §6.1's signatures —
##
##     type ProjectKind* = enum ...
##     type ProposalConfidence* = enum pcCanonical, pcAmbiguous, pcUnknown
##     type CommandProposal* = object
##       command*: string; args*: seq[string]
##       confidence*: ProposalConfidence; reason*: string
##     proc projectKinds*(listing: seq[string];
##                        hasWasm32CargoConfig = false): seq[RankedKind] {.noSideEffect.}
##     proc buildProposal*(kind: ProjectKind): CommandProposal {.noSideEffect.}
##     proc markerFiles*(kind: ProjectKind): seq[string] {.noSideEffect.}
##
## The `hasWasm32CargoConfig` parameter is §6.3's decision, not an invention:
## `Cargo.toml` + `wasm32` in `.cargo/config.toml` selects the kind by file
## **contents**, which `markerFiles` cannot express and a listing must not be
## asked to imply.
##
## ## Purity (EMT-A41)
##
## The module must import no `std/os` and spawn nothing; `ci/test/hostfree-
## build.sh` covers `viewmodels/`. That is what lets this suite run in `vm-unit`
## (C) **and** `vm-unit-js` (JS) — the web deployment's backend, which is the
## acceptance target. A heuristic that only ran on the desktop backend would be
## testing the wrong half of the product.
##
## ## A caveat about the readiness probe
##
## `EditModeToolbarBuilt` is a `const` fed by `staticExec`, and Nim caches
## compile-time results in `nimcache`. After the module lands, a stale cache can
## keep this suite red for one build. `nim c -f` or a fresh `--nimcache:` is the
## fix; the lane runner compiles into a per-run cache, so CI is unaffected.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_edit_mode_toolbar_languages.nim
##
## Discovered by the `vm-unit` (C) and `vm-unit-js` (JS) lanes by glob.

import std/[strutils, unittest]

import ../../viewmodels/project_actions

# ---------------------------------------------------------------------------
# Source read at compile time, for the assertions that must be DERIVED from a
# declaration rather than transcribed beside it (EMT-A40, EMT-A23).
#
# `staticRead` works on both backends; `std/os.fileExists` does not exist on
# JS, which is why the readiness probe below uses `staticExec` instead.
# ---------------------------------------------------------------------------

const LanguageDetectionSrc =
  staticRead("../../../../ct/utilities/language_detection.nim")

const SmartHarnessSrc =
  staticRead("../../../../ct_test/frameworks/smart_contract_harnesses.nim")

const CommonLangSrc =
  staticRead("../../../../common/common_lang.nim")

const RustLibtestSrc =
  staticRead("../../../../ct_test/frameworks/rust_libtest.nim")

const NoirNargoSrc =
  staticRead("../../../../ct_test/frameworks/noir_nargo.nim")

# ---------------------------------------------------------------------------
# Is the heuristic built yet?
# ---------------------------------------------------------------------------

const EditModeToolbarModule =
  currentSourcePath() & "/../../../viewmodels/edit_mode_toolbar.nim"

const EditModeToolbarBuilt =
  staticExec("test -e '" & EditModeToolbarModule & "' && echo YES || echo NO")
    .strip == "YES"

when EditModeToolbarBuilt:
  import ../../viewmodels/edit_mode_toolbar

# ---------------------------------------------------------------------------
# A counted `check` — Verification-Harness-Traps.md §4c.
# ---------------------------------------------------------------------------

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
  ## One counted failing assertion naming the unbuilt subject. Counted so the
  ## number written at the end of each check does not move when the feature
  ## lands — the check simply stops failing.
  inc asserted
  checkpoint("UNIMPLEMENTED — " & what)
  check false

const HeuristicAwaited =
  "`edit_mode_toolbar.projectKinds` / `buildProposal` / `markerFiles`"

# ---------------------------------------------------------------------------
# §10.1 — Build, canonical rows, which ship.
#
# THE TABLE IS THE SUITE (EMT-A60). Each row is: a name, the listing that must
# select it, the `Lang` the CLI's own chain answers for the same markers, and
# the command the spec says ships. EMT-A61 asserts the row COUNT, so a row
# quietly dropped fails rather than shrinking the suite (§4b).
# ---------------------------------------------------------------------------

type CanonicalRow = object
  name: string
  listing: seq[string]
  lang: string
  command: string
  args: seq[string]

const CanonicalRows: seq[CanonicalRow] = @[
  CanonicalRow(name: "Rust (Cargo)", listing: @["Cargo.toml", "src/"],
               lang: "LangRust", command: "cargo", args: @["build"]),
  CanonicalRow(name: "Rust -> wasm",
               listing: @["Cargo.toml", ".cargo/config.toml", "src/"],
               lang: "LangRustWasm", command: "cargo",
               args: @["build", "--target", "wasm32-wasip1"]),
  CanonicalRow(name: "Noir", listing: @["Nargo.toml", "src/main.nr"],
               lang: "LangNoir", command: "nargo", args: @["compile"]),
  CanonicalRow(name: "Go", listing: @["go.mod", "main.go"],
               lang: "LangGo", command: "go", args: @["build", "./..."]),
  CanonicalRow(name: "Elixir", listing: @["mix.exs", "lib/"],
               lang: "LangElixir", command: "mix", args: @["compile"]),
  CanonicalRow(name: "Erlang", listing: @["rebar.config", "src/"],
               lang: "LangErlang", command: "rebar3", args: @["compile"]),
  CanonicalRow(name: "D (dub)", listing: @["dub.json", "source/"],
               lang: "LangD", command: "dub", args: @["build"]),
  CanonicalRow(name: "Solidity (Foundry)", listing: @["foundry.toml", "src/"],
               lang: "LangSolidity", command: "forge", args: @["build"]),
  CanonicalRow(name: "Sway", listing: @["Forc.toml", "src/"],
               lang: "LangSway", command: "forc", args: @["build"]),
  CanonicalRow(name: "Crystal", listing: @["shard.yml", "src/"],
               lang: "LangCrystal", command: "shards", args: @["build"]),
  CanonicalRow(name: "Cairo (Scarb)", listing: @["Scarb.toml", "src/"],
               lang: "LangCairo", command: "scarb", args: @["build"]),
  CanonicalRow(name: "Aiken", listing: @["aiken.toml", "validators/"],
               lang: "LangAiken", command: "aiken", args: @["build"]),
  CanonicalRow(name: "Lean", listing: @["lakefile.lean", "Main.lean"],
               lang: "LangLean", command: "lake", args: @["build"]),
  CanonicalRow(name: "Fortran (fpm)", listing: @["fpm.toml", "src/"],
               lang: "LangFortran", command: "fpm", args: @["build"]),
  CanonicalRow(name: "C/C++ (CMake, configured)",
               listing: @["CMakeLists.txt", "build/CMakeCache.txt", "src/"],
               lang: "LangCpp", command: "cmake", args: @["--build", "build"]),
  CanonicalRow(name: "JS / TS (no conventional build)",
               listing: @["package.json", "src/"],
               lang: "LangJavascript", command: "", args: @[])]

# ---------------------------------------------------------------------------
# §10.2 — Build, recognised but NOT proposed. The kind IS recognised, so the
# button is disabled-with-a-reason rather than hidden (§8, EMT-D13).
# ---------------------------------------------------------------------------

type RecognisedRow = object
  name: string
  listing: seq[string]

const RecognisedRows: seq[RecognisedRow] = @[
  RecognisedRow(name: "Nim", listing: @["app.nimble", "src/"]),
  RecognisedRow(name: "Python", listing: @["pyproject.toml", "src/"]),
  RecognisedRow(name: "Ruby", listing: @["Gemfile", "lib/"]),
  RecognisedRow(name: "PHP", listing: @["composer.json", "src/"]),
  RecognisedRow(name: "Julia", listing: @["Project.toml", "src/"]),
  RecognisedRow(name: "Ada", listing: @["alire.toml", "src/"]),
  RecognisedRow(name: "C/C++ (Make)", listing: @["Makefile", "src/"]),
  RecognisedRow(name: "Move", listing: @["Move.toml", "sources/"]),
  RecognisedRow(name: "Leo", listing: @["program.json", "src/"]),
  RecognisedRow(name: "Circom", listing: @["circuit.circom"]),
  RecognisedRow(name: "MASM", listing: @["prog.masm"]),
  RecognisedRow(name: "Tolk", listing: @["contract.tolk"]),
  RecognisedRow(name: "Cadence", listing: @["contract.cdc"]),
  RecognisedRow(name: "C/C++ (CMake, UNCONFIGURED)",
                listing: @["CMakeLists.txt", "src/"])]

suite "EMT §10.1 the canonical build table is the suite":

  test "EMT-A60/A61 every canonical row yields exactly its own command":
    startCount()
    var exercised = 0
    for row in CanonicalRows:
      checkpoint(row.name)
      inc exercised
      when EditModeToolbarBuilt:
        let ranked = projectKinds(row.listing,
                                  hasWasm32CargoConfig = row.name == "Rust -> wasm")
        ck ranked.len >= 1
        let proposal = buildProposal(ranked[0].kind)
        if row.command.len == 0:
          # JS/TS: `scripts.build` is a DECLARATION, so no conventional command
          # may be proposed — but the kind is still recognised.
          ck proposal.confidence != pcCanonical
          ck proposal.reason.len > 0
        else:
          ck proposal.confidence == pcCanonical
          ck proposal.command == row.command
          ck proposal.args == row.args
      else:
        pending(HeuristicAwaited & " for " & row.name)
        pending(HeuristicAwaited & " for " & row.name)
        pending(HeuristicAwaited & " for " & row.name)
    # EMT-A61: a COUNT, not `>= 1`. Sixteen rows in §10.1; a row dropped from
    # the table fails here rather than silently shrinking the suite.
    ck exercised == 16
    ck CanonicalRows.len == 16
    expectCount(50)

  test "EMT-A62 every recognised-not-proposed row is recognised, and says why":
    ## The whole point of §10.2. "No command" must be a RECOGNISED kind with a
    ## reason, never an unrecognised folder — that is the §8 disabled/hidden
    ## split, and it is where a lazy implementation hides a gap by pretending
    ## not to know the project.
    startCount()
    var exercised = 0
    for row in RecognisedRows:
      checkpoint(row.name)
      inc exercised
      when EditModeToolbarBuilt:
        let ranked = projectKinds(row.listing)
        ck ranked.len >= 1                       # recognised ...
        let proposal = buildProposal(ranked[0].kind)
        ck proposal.confidence != pcCanonical    # ... but not proposed ...
        ck proposal.reason.len > 0               # ... and it says why (EMT-D14)
      else:
        pending(HeuristicAwaited & " for " & row.name)
        pending(HeuristicAwaited & " for " & row.name)
        pending(HeuristicAwaited & " for " & row.name)
    ck exercised == 14
    ck RecognisedRows.len == 14
    expectCount(44)

suite "EMT §6 marker collisions, which is where the two tables disagree":

  test "EMT-A42 a Noir package inside a Cargo workspace resolves to Noir":
    ## EMT-D9. This is not hypothetical — it is the layout of
    ## `metacraft-labs/noir` and of aztec-packages, and the two detection
    ## tables genuinely disagree about it:
    ##
    ##   * `ct/utilities/language_detection.nim` — positional first-match with
    ##     `Nargo.toml` ahead of `Cargo.toml`, and NO walk-up  -> Noir
    ##   * `codetracer-native-backend/src/build.rs` — walks UP to the
    ##     filesystem root, `Cargo.toml` first                 -> Rust
    ##
    ## The toolbar follows `ct`'s rule, because the toolbar's subject is the
    ## workspace the user opened. Offering `cargo build` to somebody editing
    ## `.nr` files is the failure this pins.
    startCount()
    when EditModeToolbarBuilt:
      let ranked = projectKinds(@["Cargo.toml", "Nargo.toml", "src/main.nr"])
      ck ranked.len >= 1
      ck buildProposal(ranked[0].kind).command == "nargo"
      ck buildProposal(ranked[0].kind).args == @["compile"]
    else:
      pending(HeuristicAwaited & " — Noir inside a Cargo workspace")
      pending(HeuristicAwaited & " — Noir inside a Cargo workspace")
      pending(HeuristicAwaited & " — Noir inside a Cargo workspace")
    expectCount(3)

  test "the CLI's own chain already answers Noir here — the derived control":
    ## Green today. It reads `detectFolderLang`'s source and shows that the
    ## rule EMT-D9 adopts is the one already written down, so EMT-A42 is a
    ## claim about the toolbar following an existing decision rather than a new
    ## opinion. Anchored to the `fileExists(folder / "…")` call syntax, never to
    ## the doc comment (§16.5 / traps §4d).
    startCount()
    let nargoAt = LanguageDetectionSrc.find("fileExists(folder / \"Nargo.toml\")")
    let cargoAt = LanguageDetectionSrc.find("fileExists(folder / \"Cargo.toml\")")
    ck nargoAt >= 0
    ck cargoAt >= 0
    ck nargoAt < cargoAt          # Nargo.toml is tested first: Noir wins
    ck "walkDir" in LanguageDetectionSrc      # the extension sweep exists ...
    ck "parentDir" notin LanguageDetectionSrc # ... and there is NO walk-up
    expectCount(5)

  test "the wasm Cargo kind is selected by file CONTENTS, not by name":
    ## §6.3's exception, and the reason `markerFiles` alone cannot express it.
    ## The CLI reads `.cargo/config.toml` and substring-matches `wasm32`; the
    ## pure heuristic must therefore be TOLD, via `hasWasm32CargoConfig`.
    startCount()
    ck "isWasmCargoProject" in LanguageDetectionSrc
    ck "\"wasm32\" in content" in LanguageDetectionSrc
    ck ".cargo\" / \"config.toml\"" in LanguageDetectionSrc
    when EditModeToolbarBuilt:
      let plain = projectKinds(@["Cargo.toml", ".cargo/config.toml", "src/"],
                               hasWasm32CargoConfig = false)
      let wasm = projectKinds(@["Cargo.toml", ".cargo/config.toml", "src/"],
                              hasWasm32CargoConfig = true)
      # Same listing, different answer — which is exactly the property that
      # makes the flag necessary rather than decorative.
      ck plain.len >= 1
      ck wasm.len >= 1
      ck buildProposal(plain[0].kind).args == @["build"]
      ck buildProposal(wasm[0].kind).args ==
         @["build", "--target", "wasm32-wasip1"]
    else:
      for _ in 0 ..< 4:
        pending(HeuristicAwaited & " — hasWasm32CargoConfig")
    expectCount(7)

  test "EMT-A43 a loose source file never outranks a manifest":
    ## EMT-D10 rule 3. The brief's own case: a Rust workspace containing a
    ## Python script resolves to Rust, and Python does not appear AT ALL,
    ## because `main.py` is not a marker. The `notin` half is the one that
    ## matters — a heuristic that ranked both would offer a Python command for
    ## a script that is not the project.
    startCount()
    when EditModeToolbarBuilt:
      let ranked = projectKinds(@["Cargo.toml", "script.py", "src/"])
      ck ranked.len == 1
      ck buildProposal(ranked[0].kind).command == "cargo"
    else:
      pending(HeuristicAwaited & " — Cargo.toml + a loose .py")
      pending(HeuristicAwaited & " — Cargo.toml + a loose .py")
    expectCount(2)

  test "EMT-A44 package.json beside Cargo.toml is ambiguity, not a pick":
    ## Two independent facts collide here, and the second is a live gap:
    ## `detectFolderLang` has **no `package.json` entry at all**, so the CLI
    ## chain answers Rust for this listing and never mentions JS. The toolbar
    ## must not inherit that: §7.2/EMT-D11 says multiple candidates NEVER
    ## resolve by array position or first-wins.
    startCount()
    # Derived, and green today: the gap is real.
    ck "package.json" notin LanguageDetectionSrc
    when EditModeToolbarBuilt:
      let ranked = projectKinds(@["Cargo.toml", "package.json"])
      ck ranked.len == 2                       # both recognised ...
      ck buildProposal(ranked[0].kind).confidence == pcAmbiguous
      ck buildProposal(ranked[0].kind).reason.len > 0
    else:
      for _ in 0 ..< 3:
        pending(HeuristicAwaited & " — Cargo.toml + package.json")
    expectCount(4)

  test "EMT-A45 a monorepo with no root manifest is ambiguous, not a guess":
    ## EMT-D10's closing rule: with only `packages/*/package.json`, the kind is
    ## recognised and NO command is proposed, because *which* package to build
    ## is a question the marker cannot answer.
    startCount()
    when EditModeToolbarBuilt:
      let ranked = projectKinds(@["packages/a/package.json",
                                  "packages/b/package.json"])
      ck ranked.len >= 1
      ck buildProposal(ranked[0].kind).confidence == pcAmbiguous
      ck buildProposal(ranked[0].kind).reason.len > 0
    else:
      for _ in 0 ..< 3:
        pending(HeuristicAwaited & " — a package.json monorepo")
    expectCount(3)

  test "one CMake project fires three cpp providers — arbitration is required":
    ## §2.4 hazard 4, derived from the providers' own detection rules rather
    ## than asserted about them. cpp-gtest, cpp-catch2 and cpp-ctest ALL claim a
    ## CMake project, so "the detecting provider" in §7.1 step 4 is not a
    ## function until something arbitrates. Green today; it exists so the
    ## Run Tests column cannot be built on the assumption of a single answer.
    startCount()
    const CppCommonSrc =
      staticRead("../../../../ct_test/frameworks/cpp_common.nim")
    # All three detectors are declared in one module and all three read the
    # SAME file. That is the collision, stated as the shape of the source
    # rather than as an opinion about it.
    ck "proc hasGoogleTestProject*" in CppCommonSrc
    ck "proc hasCatch2Project*" in CppCommonSrc
    ck "proc hasCTestProject*" in CppCommonSrc
    ck CppCommonSrc.count("readProjectFile(projectRoot, \"CMakeLists.txt\")") == 3
    # Nothing in the module ranks them, so §7.1 step 4's "the detecting
    # provider" is not yet a function.
    ck "priority" notin CppCommonSrc
    expectCount(5)

suite "EMT §6 totality, emptiness and the two unrecognisable languages":

  test "EMT-A46 an empty listing recognises nothing":
    startCount()
    when EditModeToolbarBuilt:
      ck projectKinds(@[]).len == 0
    else:
      pending(HeuristicAwaited & " — the empty listing")
    expectCount(1)

  test "EMT-A47/A48 buildProposal is total, and never silently absent":
    ## A47 asserts totality over the enum with the member count asserted, so a
    ## kind added later WITHOUT a row fails rather than passes. A48 forbids a
    ## proposal that is neither canonical nor explained — without it, "every
    ## proposed command is canonical" is satisfiable by proposing nothing
    ## (§16.3).
    startCount()
    when EditModeToolbarBuilt:
      var seen = 0
      for kind in ProjectKind:
        inc seen
        let proposal = buildProposal(kind)
        ck proposal.confidence == pcCanonical or proposal.reason.len > 0
      ck seen == ProjectKind.high.ord + 1
      ck seen >= CanonicalRows.len
    else:
      pending(HeuristicAwaited & " — ProjectKind totality")
      pending(HeuristicAwaited & " — the asserted member count")
    expectCount(2)

  test "EMT-A49 LangPolkavm and LangSolana cannot be recognised from sources":
    ## EMT-F7, and the assertion exists so the gap is not quietly "fixed" by a
    ## guess. Both have recorder entries with `supported: true` and NO detection
    ## path: no extension in `LANGS`, no marker in `detectFolderLang`, and
    ## `getExtensionName` answers "" for both. Derived from source — green
    ## today, and it is the control that keeps the heuristic honest.
    startCount()
    ck "LangPolkavm" in CommonLangSrc
    ck "LangSolana" in CommonLangSrc
    ck "of LangPolkavm: \"\"" in CommonLangSrc
    ck "of LangSolana: \"\"" in CommonLangSrc
    # Neither appears in the CLI's marker chain or its extension table.
    ck "LangPolkavm" notin LanguageDetectionSrc
    ck "LangSolana" notin LanguageDetectionSrc
    when EditModeToolbarBuilt:
      # No listing of source files alone yields recognition for either.
      ck projectKinds(@["main.polkavm"]).len == 0
      ck projectKinds(@["program.so", "src/lib.rs.solana"]).len == 0
    else:
      pending(HeuristicAwaited & " — PolkaVM/Solana non-recognition")
      pending(HeuristicAwaited & " — PolkaVM/Solana non-recognition")
    expectCount(8)

suite "EMT anti-drift and exclusion — the controls":

  test "EMT-A40 the marker table is DERIVED, and this feature adds no sixth":
    ## The anti-drift assertion, and the most important one in the file. §2.8
    ## records that the tree already carries FIVE hand-maintained
    ## extension/marker tables and that the consequence of drift was not a
    ## missing feature but a WRONG diagnostic — `ct record player.gd` blamed a
    ## missing `ct-native-replay` that installing would not have helped.
    ##
    ## So `markerFiles` must be derived from the same declaration
    ## `detectFolderLang` reads, and the two must agree on membership AND on
    ## precedence. Per §16.5 the scan is anchored to the `fileExists(folder /
    ## "X")` CALL syntax — the module's own doc comment names several of the
    ## same files, and a scan matching prose is satisfied by prose (traps §4d).
    startCount()

    # Derive the chain from source, in order.
    var chain: seq[string] = @[]
    for line in LanguageDetectionSrc.splitLines:
      let at = line.find("fileExists(folder / \"")
      if at >= 0:
        let rest = line[at + len("fileExists(folder / \"") .. ^1]
        let close = rest.find('"')
        if close > 0:
          chain.add rest[0 ..< close]

    # The derivation itself must not be vacuous: a scan that finds nothing
    # passes every "must not contain" check written over it (traps §4).
    ck chain.len == 10
    ck chain[0] == "Nargo.toml"
    ck chain[1] == "Scarb.toml"
    ck chain[2] == "aiken.toml"
    ck chain[3] == "Move.toml"
    ck chain[4] == "Forc.toml"
    ck chain[5] == "foundry.toml"
    ck chain[6] == "Cargo.toml"
    ck chain[7] == "lakefile.lean"
    ck chain[8] == "shard.yml"
    ck chain[9] == "program.json"

    when EditModeToolbarBuilt:
      # Membership: every marker the CLI knows is a marker the toolbar knows.
      for marker in chain:
        var found = false
        for kind in ProjectKind:
          if marker in markerFiles(kind): found = true
        ck found
      # Precedence: for the two that collide in a real repository, the
      # toolbar's ranking agrees with the chain's order.
      let ranked = projectKinds(@["Cargo.toml", "Nargo.toml"])
      ck ranked.len >= 1
      ck "Nargo.toml" in markerFiles(ranked[0].kind)
    else:
      for _ in 0 ..< 10:
        pending("`markerFiles` — derived membership against detectFolderLang")
      pending("`markerFiles` — derived precedence")
      pending("`markerFiles` — derived precedence")

    expectCount(23)

  test "EMT-A23 no smart-* provider can appear on a user-facing surface":
    ## EMT-D2. All 14 are generated from `SmartHarnessSpec` records and their
    ## `detect` is `siblingRepoInWorkspace(projectRoot, "<recorder repo>")` — a
    ## DIRECTORY-NAME match that fires only when the workspace is or contains a
    ## recorder-repo checkout, never on a user project. Surfacing them would put
    ## a Run Tests button on a CodeTracer developer's machine and on nobody
    ## else's.
    ##
    ## Derived and green today: it pins the mechanism, so the exclusion rests on
    ## what the code does rather than on a list of 14 names to keep in sync.
    startCount()
    const SmartCommonSrc =
      staticRead("../../../../ct_test/frameworks/smart_contract_common.nim")
    ck "siblingRepoInWorkspace" in SmartCommonSrc
    ck "spec.findRecorderRepo(projectRoot).len > 0" in SmartCommonSrc
    # The count is asserted, so a 15th harness cannot be added unnoticed.
    ck SmartHarnessSrc.count("SmartHarnessSpec(") == 14
    ck SmartHarnessSrc.count("recorderRepo:") == 14
    when EditModeToolbarBuilt:
      # No listing whatsoever produces a smart-* command.
      for listing in [@["Nargo.toml"], @["Cargo.toml"], @["foundry.toml"],
                      @["Move.toml"], @["Scarb.toml"]]:
        for ranked in projectKinds(listing):
          ck not buildProposal(ranked.kind).command.startsWith("smart-")
    else:
      for _ in 0 ..< 5:
        pending("`projectKinds` — the smart-* exclusion over the corpus")
    expectCount(9)

  test "the Lang enum is the closed set, and it has 41 members":
    ## §10's premise. `SUPPORTED_LANGS` must NOT be used for this — two
    ## divergent hand-maintained lists, 30 vs 29 members, both omitting Python
    ## and JavaScript, feeding only an HTML dropdown. Derived from the enum's
    ## own declaration, which is ordinal-pinned to Rust and contract-tested.
    ##
    ## The first spelling of this check counted any line starting with `Lang`
    ## that either contained a comma OR started with `LangGdScript`, and
    ## asserted `"LangGdScript" in CommonLangSrc`. Mutation arm M3 renamed the
    ## member to `LangGdScriptRenamed` and the check **survived** — both
    ## predicates are prefix-satisfied by the longer name. The count was
    ## therefore not measuring membership at all. Tightened below: the 40
    ## comma-terminated members are counted, and the 41st is pinned by name
    ## AND ordinal, which is the form the Rust contract test also uses.
    startCount()
    var members = 0
    var inEnum = false
    for line in CommonLangSrc.splitLines:
      let t = line.strip
      if t.startsWith("Lang* = enum"): inEnum = true; continue
      if not inEnum: continue
      # The enum has no closing token, so the LAST member terminates the scan.
      # Without this the loop ran on through the rest of the module and counted
      # 54 — a derivation that silently over-counts is the mirror of one that
      # silently finds nothing (Verification-Harness-Traps.md §4).
      if t.startsWith("LangGdScript"): break
      if t.startsWith("Lang") and t.contains(","):
        inc members
    ck members == 40                      # every member but the last
    ck "LangGdScript  # 40" in CommonLangSrc   # the 41st, by name and ordinal
    ck "LangC," in CommonLangSrc               # and the 0th
    expectCount(3)

  test "EMT-A22 a provider's DECLARED capability is not its availability":
    ## §2.4 hazard 3, and the trap this campaign was warned about by name.
    ## `rust_libtest` declares `canRunProject/File/Single: true` and installs
    ## `notImplementedRun`. Availability per verb must be read from the
    ## INSTALLED proc; a Run Tests button built from the capability flags is
    ## enabled for Rust and does nothing.
    ##
    ## Derived and green today. The toolbar half — that the button is DISABLED —
    ## is asserted in `test_edit_mode_toolbar_model.nim`.
    startCount()
    ck "canRunProject: true" in RustLibtestSrc
    ck "notImplementedRun" in RustLibtestSrc
    ck "provider.run = notImplementedRun" in RustLibtestSrc
    expectCount(3)

  test "EMT-A21 Noir refuses test RECORDING, in the provider's own words":
    ## EMT-F6, and it is load-bearing for the acceptance journey: the one
    ## language Noir Studio is written for is the one that refuses to record a
    ## test run. §13 therefore reaches a replay session through **Run**, not
    ## Record Tests, and no assertion anywhere in these suites claims otherwise.
    startCount()
    ck "NoirRecordUnsupported" in NoirNargoSrc
    ck "provider.record = recordUnsupported" in NoirNargoSrc
    ck "a trace of one event and zero steps" in NoirNargoSrc
    # And the positive half: Noir DOES run tests, so the refusal is specific.
    ck "provider.run = runNoir" in NoirNargoSrc
    ck "nargo" in NoirNargoSrc
    expectCount(5)
