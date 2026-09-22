## The four axes a recording is described by.
##
## `Lang` (`src/common/common_lang.nim`) answers *four* different questions with
## one value.  This module gives each question its own type:
##
## | Axis | Granularity | Question |
## | --- | --- | --- |
## | `SourceLanguage` | **per file** | what notation is this source text written in? |
## | `TargetIsa` | per artefact | what does the machine that runs it execute? |
## | `Toolchain` | per artefact | what turned the source into that artefact? |
## | `RecordingApproach` | per artefact | how did CodeTracer observe the run? |
##
## "A language is a property of a file typically" is the load-bearing sentence.
## The product already behaves that way and does not have a type for it: the
## Call Trace Pane re-derives the language on **every move** from the active
## location's path (`toLangFromFilename(self.location.path)`,
## `src/frontend/ui/calltrace.nim:985`), and the Event Log does the same at
## `src/frontend/ui/event_log.nim:921,927,1717`.  A `Trace.lang` field is
## therefore a *summary* of a per-file fact, not the fact itself.
##
## ## Placement
##
## `src/common/` is the shared floor: `common_lang.nim` is `include`-d by both
## `src/common/lang.nim:1` and `src/frontend/lang.nim:1`, and only the latter
## adds `std/jsffi`.  This module is a normal, importable module in the same
## directory, so a native-backend front end (the planned Nim TUI on
## `isonim-tui`) reaches it with a plain `import`, which it cannot do with an
## `include` file.  **Nothing here may import `std/jsffi`** and everything here
## must compile on the C and the JS backend; `target_axes_test.nim` (C) and
## `src/frontend/tests/target_axes_js_test.nim` (JS) assert exactly that.
##
## ## Why plain `string` / `seq`, and not `nim-everywhere`'s `NativeString`
##
## `nim-everywhere`'s `platform.nim` provides `NativeString` / `NativeSeq`
## (`cstring` / `JsArray` under `when defined(js)`, `string` / `seq` otherwise)
## and `codetracer` already depends on it (`config.nims:50`, `flake.nix:235`).
## It is **not used here**, deliberately.  The aliases exist for values that must
## be handed to a JS API or stored in a `JsAssoc`; every payload in this module
## is an ASCII token or a short list of them that stays inside Nim, and
## `Language-Recording-Type-Split.md` §6.3 already established that a plain
## `seq[string]` in the shared floor carries this kind of data on both backends.
## Adding the alias would put a dependency between `src/common/` and
## `nim-everywhere` for no benefit.  A front end that needs a `cstring` wraps at
## its own boundary, which is what `frontend/lang.nim:205` already does for
## `getExtension`.
##
## ## Scope
##
## This module does not replace `Lang`, and no `Lang` member is removed or
## renumbered by its existence.  Since LRS-2B, production code DOES dispatch on
## these types: `src/ct/trace/recorder_dispatch.nim` selects a recorder from a
## `(SourceLanguage, TargetIsa, RecordingApproach)` triple that
## `src/ct/trace/record_assessment.nim` derives from the assessed target, and
## `common_lang.nim`'s `axesOfLang` is the production decomposition of every
## `Lang` value onto these axes.  The remaining migration is sequenced in
## `codetracer-specs/Refactoring-Plans/Language-Recording-Type-Split.milestones.org`.

import std/strutils

type
  SourceLanguage* = enum
    ## What notation a **file** is written in.
    ##
    ## The sentinel is ordinal 0 on purpose.  `Lang` used to put `LangC` at
    ## ordinal 0, so a proc that fell off its end answered "C" — a defect that
    ## really happened and cost `ct record ./a.out` its recognizer delegation
    ## (the 22-line post-mortem on `detectLangFromPath` in
    ## `src/ct/utilities/language_detection.nim`).  LRS-4 (2026-09-21) moved
    ## `LangUnknown` to ordinal 0 for exactly this reason, so `Lang` now has
    ## the property these axes were given from the start.  A zero-initialised
    ## `SourceLanguage` says "I do not know", which is the honest answer for a
    ## value nobody assigned.
    ##
    ## Chains and VMs are **not** here, and since LRS-5's second deletion
    ## round they are not in `Lang` either.  `LangSolana` and `LangPolkavm`
    ## used to be the only two **non-sentinel** `Lang` members with an empty
    ## `getExtension` entry, because they are not notations anyone writes a
    ## file in — a Solana program is Rust or C, and PolkaVM is a machine.  Both
    ## members are now DELETED; the substrates they named live on `TargetIsa`
    ## below (`tiSolanaSbf`, `tiPolkaVm`) and `--lang solana` / `--lang
    ## polkavm` reaches them through `TargetIsaSpellings`.
    ##
    ## **Rule 7, at the second deletion round:** the careful qualifier this
    ## paragraph used to carry — `getExtension` has *three* empty answers, not
    ## two, the third being the sentinel `LangUnknown` for the unrelated reason
    ## that it names no language at all — no longer has a referent.  There is
    ## now exactly ONE empty answer, the sentinel's, and
    ## `target_axes_test.nim` asserts that directly: every `Lang` but
    ## `LangUnknown` has a non-empty extension.  The single source of those
    ## answers is the exhaustive `getExtensionName` in
    ## `src/common/common_lang.nim`.
    slUnknown           ## 0 — sentinel: not determined, or determined to be none
    slC
    slCpp
    slRust
    slNim
    slGo
    slPascal
    slFortran
    slD
    slCrystal
    slLean
    slJulia
    slAda
    slPython
    slRuby
    slJavaScript
    slLua
    slPhp
    slBash
    slZsh
    slElixir
    slErlang
    slSolidity
    slMove
    slSway
    slCairo
    slCircom
    slLeo
    slTolk
    slAiken
    slCadence
    slNoir
    slAsm               ## assembly, dialect deliberately not committed
    slMidenAsm          ## Miden VM assembly — the one dialect with real support
    slGdScript          ## GDScript, the notation Godot `.gd` files are written
                        ## in.  It is a real per-file language and not a
                        ## substrate, so it belongs here and not on `TargetIsa`:
                        ## the substrate it runs on is `tiGdScriptVm` below.

  TargetIsa* = enum
    ## What the machine that actually runs the artefact executes.
    ##
    ## Every value below names a substrate CodeTracer has a recorder for, and
    ## carries the recorder that observes it.  The **CPU architecture is
    ## deliberately absent**: `tiNative` covers every host ISA, and the specific
    ## architecture travels as a free string
    ## (`TargetAssessment.arch`, matching the `format.arch` field
    ## `ct-native-replay recognize` already emits).  Enumerating x86-64 /
    ## AArch64 / RISC-V in a closed enum would reproduce the very defect this
    ## split removes — a closed enum over an open, externally-defined set.
    ##
    ## Where a value's name comes from outside CodeTracer's own source, the doc
    ## comment says so.  These names are the axis's weakest evidence and are the
    ## most likely to be renamed as real support lands; nothing persists them.
    tiUnknown           ## 0 — sentinel
    tiNative            ## the recording host's own machine code (MCR / rr / TTD)
    tiInterpreted       ## executed by a language runtime CodeTracer does not
                        ## model as a separate ISA: Python, Ruby, JavaScript,
                        ## Lua, PHP, Bash, Zsh.  The list is closed on purpose —
                        ## it is the set of runtimes recorded by instrumenting
                        ## the runtime itself, and a substrate that is not one
                        ## of them gets its own value rather than being filed
                        ## here.  `tiNimVm` immediately below is that case.
    tiNimVm             ## the Nim compiler's compile-time VM, evaluating a
                        ## `.nims` script under `nim e --trace:<…>/trace.ct`
                        ## (`src/ct/db_backend_record.nim:119-141`).  The VM
                        ## emits the trace itself, so the approach is
                        ## `raInstrumentedRuntime` and the artefact IS a
                        ## materialized trace.
                        ##
                        ## This is the second recorder `LangNim` hides, and it
                        ## is the reason the ISA axis cannot be a function of
                        ## the source language: `.nim` and `.nims` are BOTH
                        ## `slNim`, and they run on different machines —
                        ## `tiNative` via `nim c` + `ct-mcr`
                        ## (`db_backend_record.nim:143-188`) versus `tiNimVm`
                        ## here.  See `fallbackTargetIsaForLanguage` below.
    tiWasm              ## WebAssembly — `wazero`
                        ## (`src/ct/trace/recorder_dispatch.nim:300-308`)
    tiEvm               ## EVM bytecode — `codetracer-evm-recorder` (`:139`)
    tiMidenVm           ## Miden VM — `codetracer-miden-recorder` (`:128`)
    tiMoveVm            ## Move VM — `codetracer-move-recorder` (`:129`)
    tiFuelVm            ## FuelVM — `codetracer-fuel-recorder` (`:131`)
    tiPolkaVm           ## PolkaVM — `codetracer-polkavm-recorder` (`:135`)
    tiCairoVm           ## Cairo VM — `codetracer-cairo-recorder` (`:132`)
    tiAleoVm            ## the substrate `codetracer-leo-recorder` observes
                        ## (`:134`); name taken from Leo's upstream, not from
                        ## CodeTracer's own source
    tiTonVm             ## the substrate `codetracer-ton-recorder` observes
                        ## (`:136`); name from Tolk's upstream
    tiPlutus            ## the substrate `codetracer-cardano-recorder` observes
                        ## (`:137`); name from Aiken's upstream
    tiFlowVm            ## the substrate `codetracer-flow-recorder` observes
                        ## (`:138`); name from Cadence's upstream
    tiSolanaSbf         ## the substrate `codetracer-solana-recorder` observes
                        ## (`:130`); this is what `LangSolana` was standing in
                        ## for
    tiAcir              ## Noir's circuit representation — `nargo` (`:290-298`)
    tiCircomWitness     ## the substrate `codetracer-circom-recorder` observes
                        ## (`:133`)
    tiBeam              ## the BEAM — `codetracer-beam-recorder` (`:248-271`)
    tiGdScriptVm        ## Godot's GDScript bytecode VM.  `.gd` is compiled to
                        ## bytecode and executed by `GDScriptFunction::call`
                        ## (`modules/gdscript/gdscript_vm.cpp`), a computed-goto
                        ## interpreter with its own opcodes — which is why it is
                        ## its own value rather than being filed under
                        ## `tiInterpreted`, whose list is closed on purpose.
                        ## `tiNimVm` above is the same shape and the precedent.
                        ##
                        ## The distinction is load-bearing for the mixed-trace
                        ## design rather than decorative: a GDScript session has
                        ## TWO altitudes, the patched Godot host (`tiNative` /
                        ## `raMcr`) and the GDScript VM inside it
                        ## (`codetracer-specs/Planned-Features/Mixed-Trace-GDScript.md`
                        ## §1), and one ISA value cannot name both.
                        ##
                        ## The recorder that observes it is the ENGINE ITSELF —
                        ## a patched Godot linking the CTFS writer
                        ## (`codetracer-specs/Recording-Backends/GDScript-Recorder.md`),
                        ## so the approach is `raInstrumentedRuntime`.  That
                        ## engine is not something CodeTracer ships yet, which is
                        ## a fact about the recorder's availability rather than
                        ## about this axis; see
                        ## `recorderToolFor`'s `LangGdScript` arm
                        ## (`src/ct/trace/recorder_dispatch.nim`).

  Toolchain* = enum
    ## What turned the source into the artefact.
    ##
    ## Every value names a tool CodeTracer spawns or a project marker it reads.
    ## `tcUnknown` is not a wastebasket: it means the assessment did not
    ## determine the toolchain, which is different from `tcNone` ("there is no
    ## compilation step").
    tcUnknown           ## 0 — sentinel: not determined
    tcNone              ## no compilation step; the source is executed as given
    tcGcc               ## `gcc` / `g++` (codetracer-native-backend
                        ## `src/build.rs:510,618`)
    tcClang             ## `clang` / `clang++` (`build.rs:650,667`)
    tcMsvc              ## `cl` via `vcvarsall` (`build.rs:412-463,498-520`)
    tcRustc             ## `rustc` on a single file (`build.rs:709`)
    tcCargo             ## `cargo build` (`build.rs:717`); the `Cargo.toml`
                        ## marker is read at
                        ## `src/ct/utilities/language_detection.nim:41`
    tcGoBuild           ## `go` (`build.rs:265,753`)
    tcNimC              ## `nim c`, then recorded by `ct-mcr`
                        ## (`src/ct/db_backend_record.nim:143-188`;
                        ## `build.rs:267,839`)
    tcNimScriptVm       ## `nim e --trace:<…>/trace.ct` — the M-nim script VM
                        ## (`src/ct/db_backend_record.nim:119-141`).  This is
                        ## the second recorder that `LangNim` hides; naming it
                        ## here puts it on the axis it belongs to.
    tcFpc               ## Free Pascal (`build.rs:945`)
    tcCrystalCompiler   ## `crystal` (`build.rs:981`)
    tcGfortran          ## `gfortran` (`build.rs:1252`)
    tcLdc2              ## `ldc2` for D (`build.rs:266`)
    tcGnat              ## `gnatmake` / `gnatbind` / `gnatlink` for Ada
                        ## (`build.rs:1140-1208`)
    tcLake              ## Lean's Lake (`build.rs:1033`; `lakefile.lean` marker
                        ## at `language_detection.nim:46`)
    tcShards            ## Crystal's Shards (`shard.yml`, `:48`)
    tcNargo             ## `nargo` (`recorder_dispatch.nim:290-298`;
                        ## `Nargo.toml` marker at `language_detection.nim:29`)
    tcScarb             ## Cairo's Scarb (`Scarb.toml`, `:31`)
    tcForc              ## Sway's Forc (`Forc.toml`, `:37`)
    tcFoundry           ## Solidity's Foundry (`foundry.toml`, `:39`)
    tcAikenCli          ## `aiken` (`aiken.toml`, `:33`)
    tcMoveCli           ## the Move CLI (`Move.toml`, `:35`)
    tcLeoCli            ## `leo` (`program.json`, `:50-52`)

  RecordingApproach* = enum
    ## How CodeTracer observed the run.
    ##
    ## This is the axis that `usesMaterializedTraces`
    ## (`src/common/common_lang.nim`) is a one-bit projection of: a *backend*
    ## property answered from a *language* enum.  It was a mutable 40-slot
    ## `array[Lang, bool]` named `USES_MATERIALIZED_TRACES` plus 25
    ## statement-level assignments; LRS-3 made it an exhaustive `case`, and
    ## LRS-2B made it DERIVED — `producesMaterializedTrace(axesOfLang(lang).approach)`
    ## with two named exceptions — so the question is now asked of this axis
    ## and the `Lang`-indexed predicate is a replay-side summary over it.
    ##
    ## **`wasm` is not here.**  An earlier two-axis design put `rtWasm` on the
    ## recording-mode axis because `usesMaterializedTraces(LangRustWasm)` is
    ## `true`.  That was reading the flag backwards:
    ## WebAssembly is a *target ISA*, and the *approach* used to record it is
    ## `raVmEmulation` — the same approach every blockchain recorder uses.  The
    ## flag is true for wasm because emulation produces a materialized trace,
    ## not because "wasm" is a way of recording.
    raUnknown           ## 0 — sentinel
    raMcr               ## the multi-core native recorder; `--backend mcr`
                        ## (`src/ct/trace/native_backend_selection.nim:46`)
    raRr                ## rr, Linux only; `--backend rr` (`:47`)
    raTtd               ## Windows time-travel debugging; `--backend ttd` (`:48`)
    raInstrumentedRuntime
                        ## the language's own runtime is instrumented and writes
                        ## the trace itself: `codetracer-python-recorder`,
                        ## `-ruby-`, `-js-`, `-beam-`, `-bash-`, `-zsh-`, and
                        ## the PHP Zend extension
                        ## (`recorder_dispatch.nim:182-289`)
    raVmEmulation       ## an emulator or VM executes the artefact and emits the
                        ## trace: `wazero` (`:300-308`), `nargo` (`:290-298`),
                        ## and every blockchain recorder (`:321-334`)

const
  UnknownToken* = "unknown"
    ## The single token every axis spells its sentinel with.  Held as a constant
    ## rather than repeated so that a reader looking for "who can produce
    ## `unknown`?" finds one answer.

  ReservedSourceLanguageTokens* = ["masm", "gas", "nasm"]
    ## Allocated to nothing, and must stay that way.  Each names an assembler
    ## dialect that would earn a `SourceLanguage` member if it earned real
    ## support; `slMidenAsm` takes `midenasm` precisely so that these three stay
    ## available.  `target_axes_test.nim` asserts no axis spends one.

# ---------------------------------------------------------------------------
# Tokens
#
# Each of these is an exhaustive `case`, not a positional `array[T, string]`.
# Nim rejects a non-exhaustive `case` over an enum, so adding a member to any
# axis above is a compile error at every table that has an opinion about it.
# That is the property `Lang::wire_name` states outright on the Rust side
# (`libs/ct-lang/src/lib.rs:162-167`) and the property the ten positional
# `array[Lang, …]` literals do **not** have — one of them has been silently one
# entry short since `LangPhp` was added.
#
# The tokens are lowercase, hyphen-free ASCII.  Hyphen-free is load-bearing:
# the storage grammar joins axis tokens with `-`, so a token containing one
# would make the join ambiguous.  `target_axes_test.nim` asserts it.
# ---------------------------------------------------------------------------

func token*(v: SourceLanguage): string =
  ## The wire and CLI spelling of a source language.
  case v
  of slUnknown: UnknownToken
  of slC: "c"
  of slCpp: "cpp"
  of slRust: "rust"
  of slNim: "nim"
  of slGo: "go"
  of slPascal: "pascal"
  of slFortran: "fortran"
  of slD: "d"
  of slCrystal: "crystal"
  of slLean: "lean"
  of slJulia: "julia"
  of slAda: "ada"
  of slPython: "python"
  of slRuby: "ruby"
  of slJavaScript: "javascript"
  of slLua: "lua"
  of slPhp: "php"
  of slBash: "bash"
  of slZsh: "zsh"
  of slElixir: "elixir"
  of slErlang: "erlang"
  of slSolidity: "solidity"
  of slMove: "move"
  of slSway: "sway"
  of slCairo: "cairo"
  of slCircom: "circom"
  of slLeo: "leo"
  of slTolk: "tolk"
  of slAiken: "aiken"
  of slCadence: "cadence"
  of slNoir: "noir"
  of slAsm: "asm"
  # `slMidenAsm` is deliberately NOT `masm`.  Assembler dialect is a
  # distinction on this axis — "assemblers are just different types of
  # compilers after all" — so the namespace is expected to hold `gas`, `nasm`
  # and a Microsoft `masm`.  Letting Miden hold the unqualified name would
  # strand the obvious spelling for a dialect that might later be supported.
  # `masm`, `gas` and `nasm` are RESERVED and must not be allocated to anything
  # else (`ReservedSourceLanguageTokens` below, asserted by the test).  This
  # token intentionally differs from the `Lang` member name (`LangMasm`) and
  # from `libs/tree-sitter-masm`; do not "fix" it back.
  of slMidenAsm: "midenasm"
  of slGdScript: "gdscript"

func displayName*(v: SourceLanguage): string =
  ## The human-facing name of a source language, for diagnostics.
  ##
  ## This is the third vocabulary beside `token` (wire/CLI) and `Lang.toName`,
  ## and it exists because `toName` spells four of its answers as
  ## *language(mode)* by hand — `"Ruby(db)"`, `"Python(db)"`, `"Rust(wasm)"`,
  ## `"C++(wasm)"` — which is the conflation this axis removes.  A diagnostic
  ## about a recorder names the language the file is written in; the mode is
  ## a separate fact and is spelled separately when it matters.
  case v
  of slUnknown: "unknown"
  of slC: "C"
  of slCpp: "C++"
  of slRust: "Rust"
  of slNim: "Nim"
  of slGo: "Go"
  of slPascal: "Pascal"
  of slFortran: "Fortran"
  of slD: "D"
  of slCrystal: "Crystal"
  of slLean: "Lean"
  of slJulia: "Julia"
  of slAda: "Ada"
  of slPython: "Python"
  of slRuby: "Ruby"
  of slJavaScript: "JavaScript"
  of slLua: "Lua"
  of slPhp: "PHP"
  of slBash: "Bash"
  of slZsh: "Zsh"
  of slElixir: "Elixir"
  of slErlang: "Erlang"
  of slSolidity: "Solidity"
  of slMove: "Move"
  of slSway: "Sway"
  of slCairo: "Cairo"
  of slCircom: "Circom"
  of slLeo: "Leo"
  of slTolk: "Tolk"
  of slAiken: "Aiken"
  of slCadence: "Cadence"
  of slNoir: "Noir"
  of slAsm: "assembly"
  of slMidenAsm: "Miden assembly"
  of slGdScript: "GDScript"

func token*(v: TargetIsa): string =
  ## The wire spelling of a target ISA.
  case v
  of tiUnknown: UnknownToken
  of tiNative: "native"
  of tiInterpreted: "interpreted"
  of tiNimVm: "nimvm"
  of tiWasm: "wasm"
  of tiEvm: "evm"
  of tiMidenVm: "midenvm"
  of tiMoveVm: "movevm"
  of tiFuelVm: "fuelvm"
  of tiPolkaVm: "polkavm"
  of tiCairoVm: "cairovm"
  of tiAleoVm: "aleovm"
  of tiTonVm: "tonvm"
  of tiPlutus: "plutus"
  of tiFlowVm: "flowvm"
  of tiSolanaSbf: "solanasbf"
  of tiAcir: "acir"
  of tiCircomWitness: "circomwitness"
  of tiBeam: "beam"
  of tiGdScriptVm: "gdscriptvm"

func token*(v: Toolchain): string =
  ## The wire spelling of a toolchain.
  case v
  of tcUnknown: UnknownToken
  of tcNone: "none"
  of tcGcc: "gcc"
  of tcClang: "clang"
  of tcMsvc: "msvc"
  of tcRustc: "rustc"
  of tcCargo: "cargo"
  of tcGoBuild: "gobuild"
  of tcNimC: "nimc"
  of tcNimScriptVm: "nimscriptvm"
  of tcFpc: "fpc"
  of tcCrystalCompiler: "crystal"
  of tcGfortran: "gfortran"
  of tcLdc2: "ldc2"
  of tcGnat: "gnat"
  of tcLake: "lake"
  of tcShards: "shards"
  of tcNargo: "nargo"
  of tcScarb: "scarb"
  of tcForc: "forc"
  of tcFoundry: "foundry"
  of tcAikenCli: "aiken"
  of tcMoveCli: "move"
  of tcLeoCli: "leo"

func token*(v: RecordingApproach): string =
  ## The wire spelling of a recording approach.
  case v
  of raUnknown: UnknownToken
  of raMcr: "mcr"
  of raRr: "rr"
  of raTtd: "ttd"
  of raInstrumentedRuntime: "instrumented"
  of raVmEmulation: "vm"

# ---------------------------------------------------------------------------
# Parsers
#
# Total: they never raise and never `quit`.  A parser that raises on an
# unrecognised token turns a forward-compatible document into a crash, and the
# recognition wire format already made the opposite choice deliberately
# (`src/ct/utilities/target_recognition.nim:93-95,178-189`: unknown enum values
# are carried, not refused).
#
# Each parser is DERIVED from the `token` function above by iterating the enum,
# so the two cannot drift.  That is safe here and would not be safe for a
# HISTORICAL table: `langV0OrdinalNames` (`src/common/trace_index.nim`) decodes
# integers written by an OLDER build and is therefore a frozen literal that must
# never be regenerated from the live enum.  The difference is which side of the
# boundary the data was written on.
# ---------------------------------------------------------------------------

func parseSourceLanguage*(s: string, value: var SourceLanguage): bool =
  ## Parse a source-language token.  Returns `false` and leaves `value`
  ## untouched when the token is not one this build knows.
  let key = s.strip.toLowerAscii
  for v in SourceLanguage:
    if token(v) == key:
      value = v
      return true
  false

func parseTargetIsa*(s: string, value: var TargetIsa): bool =
  ## Parse a target-ISA token.  Total; see `parseSourceLanguage`.
  let key = s.strip.toLowerAscii
  for v in TargetIsa:
    if token(v) == key:
      value = v
      return true
  false

func parseToolchain*(s: string, value: var Toolchain): bool =
  ## Parse a toolchain token.  Total; see `parseSourceLanguage`.
  let key = s.strip.toLowerAscii
  for v in Toolchain:
    if token(v) == key:
      value = v
      return true
  false

func parseRecordingApproach*(s: string, value: var RecordingApproach): bool =
  ## Parse a recording-approach token.  Total; see `parseSourceLanguage`.
  let key = s.strip.toLowerAscii
  for v in RecordingApproach:
    if token(v) == key:
      value = v
      return true
  false

# ---------------------------------------------------------------------------
# The relations between the axes
#
# These are DEFAULTS, applied at the moment a target is assessed.  They are
# never implied by a persisted value: a stored recording spells every axis out.
# The rule generalises past this enum — *a default may be applied at parse time;
# a default may never be implied by a persisted value* — because a default that
# is implied by storage makes the default table itself a persisted contract,
# which is the ordinal defect with different letters.
# ---------------------------------------------------------------------------

func fallbackTargetIsaForLanguage*(lang: SourceLanguage): TargetIsa =
  ## **FALLBACK ONLY.**  The ISA to assume for a source language when no
  ## assessment is available.  The primary path is
  ## `targetIsaForAssessment` in `target_assessment.nim`, which derives the ISA
  ## from the assessed target KIND; reach for this one only when there is no
  ## assessment to derive from, and say so at the call site.
  ##
  ## ## Why this is a fallback and not the answer
  ##
  ## This function used to be called `defaultTargetIsa`, and the name hid a
  ## category error: **the ISA is a property of the artefact, and the language
  ## is a property of the file**, so no total function of `SourceLanguage` can
  ## return it.  The counterexample is not hypothetical and not rare — it is
  ## Nim:
  ##
  ## | target | language | ISA | toolchain | approach |
  ## | --- | --- | --- | --- | --- |
  ## | `a.nim` | `slNim` | `tiNative` | `tcNimC` | `raMcr` |
  ## | `a.nims` | `slNim` | `tiNimVm` | `tcNimScriptVm` | `raInstrumentedRuntime` |
  ##
  ## One language, two ISAs, two toolchains, two recording approaches, decided
  ## by which file was handed to `ct record` — that is, by the **assessment**.
  ## `src/ct/db_backend_record.nim` has the two arms side by side (`:119-141`
  ## for the script VM, `:143-188` for `nim c` + `ct-mcr`).
  ##
  ## Rust and C/C++ are the same shape one axis over: they answer `tiNative`
  ## here and reach `tiWasm` only when the assessment says so, which is exactly
  ## what `assessCargoProject` (`src/ct/utilities/language_detection.nim`)
  ## reads `.cargo/config.toml` for, and exactly the pair `LangRustWasm` /
  ## `LangCppWasm` welded together into single enum members.
  ##
  ## So the answers below are the ISA a language reaches **when nothing else is
  ## known**, which is a useful thing to have and a dangerous thing to mistake
  ## for the truth.  The name now says which one it is.
  case lang
  of slUnknown: tiUnknown
  of slC, slCpp, slRust, slNim, slGo, slPascal, slFortran, slD, slCrystal,
     slLean, slJulia, slAda, slAsm:
    tiNative
  of slPython, slRuby, slJavaScript, slLua, slPhp, slBash, slZsh:
    tiInterpreted
  of slElixir, slErlang: tiBeam
  of slSolidity: tiEvm
  of slMove: tiMoveVm
  of slSway: tiFuelVm
  of slCairo: tiCairoVm
  of slCircom: tiCircomWitness
  of slLeo: tiAleoVm
  of slTolk: tiTonVm
  of slAiken: tiPlutus
  of slCadence: tiFlowVm
  of slNoir: tiAcir
  of slMidenAsm: tiMidenVm
  of slGdScript: tiGdScriptVm

func defaultRecordingApproach*(isa: TargetIsa): RecordingApproach =
  ## How CodeTracer records a given target ISA when nothing says otherwise.
  ##
  ## This is a function of the **ISA**, not of the language, and that is the
  ## point: `USES_MATERIALIZED_TRACES` was a 40-entry hand-maintained
  ## `array[Lang, bool]` whose 24 `true` entries were kept in agreement with
  ## `recorderToolFor`'s 24 `supported: true` arms by hand.  Deriving the
  ## approach from the ISA replaces the hand-agreement with one table.
  ##
  ## Both sides of this signature are **artefact** properties, so unlike
  ## `fallbackTargetIsaForLanguage` it is a genuine total function and needs no
  ## fallback caveat: once the assessment has established the ISA, the approach
  ## follows from it with nothing left to guess.  That is why fixing the `.nims`
  ## case needed only a new ISA value and no change here beyond its arm.
  ##
  ## `LangNim` is the case that shows the improvement.  It is flagged
  ## `usesMaterializedTraces = true` (`common_lang.nim`) while the recorder for
  ## a compiled `.nim` is `ct-mcr` (`recorder_dispatch.nim:309-318`) — a
  ## contradiction under a one-bit model.  Here a compiled `.nim` is `tiNative`
  ## and therefore `raMcr` (the CTFS container MCR produces is a property of
  ## MCR, not of Nim), while a `.nims` is `tiNimVm` and therefore
  ## `raInstrumentedRuntime`.  The flag was answering for both at once, which is
  ## why it could not be right for either.
  case isa
  of tiUnknown: raUnknown
  of tiNative: raMcr
  of tiInterpreted: raInstrumentedRuntime
  of tiNimVm: raInstrumentedRuntime
  of tiBeam: raInstrumentedRuntime
  # The patched Godot engine instruments its own GDScript VM and writes the
  # container itself by linking `libcodetracer_trace_writer.a` — the same
  # relationship `tiNimVm` has with `nim e --trace:` (GDScript-Recorder.md,
  # "The writer (link, do not reimplement)").  Nothing emulates the artefact,
  # so this is `raInstrumentedRuntime` and not `raVmEmulation`.
  of tiGdScriptVm: raInstrumentedRuntime
  of tiWasm, tiEvm, tiMidenVm, tiMoveVm, tiFuelVm, tiPolkaVm, tiCairoVm,
     tiAleoVm, tiTonVm, tiPlutus, tiFlowVm, tiSolanaSbf, tiAcir,
     tiCircomWitness:
    raVmEmulation

func producesMaterializedTrace*(approach: RecordingApproach): bool =
  ## The successor of `usesMaterializedTraces` (`common_lang.nim`), as a
  ## predicate over the axis that actually decides it rather than a flag stored
  ## per language.
  ##
  ## `raMcr` is deliberately **not** included even though MCR writes a CTFS
  ## container: the question this predicate answers for its callers is "is this
  ## a self-contained materialized trace rather than a native replay recording?",
  ## and `nativeReplayTraceKindForBackend` (`src/ct/trace/record.nim:302-305`)
  ## maps MCR onto the *native replay* family for exactly that reason.
  case approach
  of raUnknown, raMcr, raRr, raTtd: false
  of raInstrumentedRuntime, raVmEmulation: true

func isNativeReplay*(approach: RecordingApproach): bool =
  ## The three approaches `--backend` accepts and refuses per host
  ## (`src/ct/trace/native_backend_selection.nim:104-112,142-185`).
  case approach
  of raMcr, raRr, raTtd: true
  of raUnknown, raInstrumentedRuntime, raVmEmulation: false

# ---------------------------------------------------------------------------
# The persisted encoding — design §5.2/§5.3/§5.4, milestone LRS-5
#
# `recordings.lang` (`src/common/trace_index.nim`) stores ONE TEXT cell per
# recording.  Since trace_index schema version 2 that cell is a token over all
# FOUR axes, joined by `AxisSeparator`:
#
#     cell ::= "unknown" | slug "-" isa "-" toolchain "-" approach
#
# and nothing else.  The grammar is stated in full, with its reasoning, in
# `codetracer-specs/Refactoring-Plans/Language-Recording-Type-Split.md` §5.2-§5.4
# and in `codetracer-specs/Architecture/Language-Enum-Ordinal-Contracts.md`.
# Three decisions are load-bearing and each has a test in
# `src/tests/cli/target_axes_test.nim`:
#
# **All four axes, always (design Q9, option A, decided by the user).**  With
# four axes, storing fewer than four means a reader must *imply* defaults for
# the missing ones -- and the rule this whole series turns on is *a default may
# be applied at parse time; a default may never be IMPLIED by a persisted
# value*.  A stored `rs` that meant `(tiNative, tcCargo, raMcr)` through
# `fallbackTargetIsaForLanguage` / `defaultRecordingApproach` would make those
# two tables a persisted contract, which is the ordinal defect with different
# letters: changing Nim's default recording approach would silently re-point
# every stored `nim` row.  So every axis is spelled out, including the ones
# that are "usually derivable", because "usually derivable" is exactly what
# the rule forbids relying on.
#
# **The sentinel is the bare token `unknown` (design Q3, decided by the
# user).**  One documented exception to the grammar and the only one.  It is
# matched as a LITERAL, before any split is attempted -- never fallen into by a
# parser that failed to find a separator.  `parseAxesToken` accepts exactly one
# hyphen-free token, and `target_axes_test.nim` asserts that no other bare word
# -- no slug, no ISA token, no toolchain token, no approach token -- decodes at
# all.  That assertion is the one that keeps the exception from generalising
# into the persisted-default contract the paragraph above forbids, and it is
# the one most easily lost: a decoder that "helpfully" applies the default
# tables to a bare slug passes every other obligation on the list.
#
# **`unknown` is the canonical spelling of the all-sentinel tuple, and the only
# one.**  `encodeAxesToken` emits the bare form for
# `(slUnknown, tiUnknown, tcUnknown, raUnknown)`, and `parseAxesToken` REFUSES
# the long `unknown-unknown-unknown-unknown` spelling of the same value.  One
# value, one spelling, in both directions: `decode(encode(v)) == v` over the
# whole four-axis product, and `encode(decode(s)) == s` over every `s` that
# decodes.  The long all-sentinel form is therefore the combination that has
# no spelling *by decision* -- the four-axis analogue of the two-axis
# `(Unknown, rtMcr)` the design's §5.3 names -- and a round-trip test must not
# assert it.
#
# The separator is `-` (design §5.3).  It is safe because no token on any axis
# contains one: that is asserted over every member of every axis and over
# every slug, so `split` always yields exactly four parts.
# ---------------------------------------------------------------------------

const
  AxisSeparator* = '-'
    ## The one character that joins the four axis tokens in a persisted cell.
    ## No axis token and no slug may contain it; that is what makes the split
    ## unambiguous, and it is asserted rather than assumed.

  AxisTokenCount* = 4
    ## How many axis tokens a non-sentinel cell carries.  Named so the decoder
    ## and its test cannot disagree about the arity design question Q9 settled.

func storageSlug*(v: SourceLanguage): string =
  ## The **persisted** spelling of a source language — design §5.2, question
  ## Q2, confirmed by the coordinator on 2026-09-21.
  ##
  ## This is deliberately a different vocabulary from `token` above, and the
  ## difference is the answer to Q2 rather than an accident:
  ##
  ## * `token` is the **wire and CLI** spelling (`python`, `javascript`,
  ##   `rust`).  It is the Nim twin of Rust's `Lang::wire_name` and it is
  ##   retained unchanged for the replay-worker socket and for
  ##   `codetracer.target-recognition.v1`.
  ## * `storageSlug` is the **storage** spelling: the primary file extension
  ##   where that extension is unique and non-empty (`py`, `rs`, `cpp`, `js`),
  ##   a hand-assigned name where no extension exists, and a *disambiguated*
  ##   name where the extension would claim a broader namespace than the
  ##   language occupies (`midenasm`, see below).
  ##
  ## Two coexisting vocabularies is a real cost and it is accepted, for the
  ## reason §5.2 gives: `wire_name`'s spellings are exactly the length the
  ## encoding was asked to reduce, and a namespace that must hold
  ## `gas`/`nasm`/`masm` beside `midenasm` is a *designed* namespace rather
  ## than a mechanical projection of either table.  The seed table is
  ## `getExtensionName` (`common_lang.nim`); this one is written out in full
  ## rather than derived from it, because the persisted encoding must not move
  ## when an editor-facing extension table does — that coupling is what §5.1
  ## rejected when it refused to use `getExtension` as the encoder outright.
  ##
  ## The two folder-based entries the design's §5.2 table hand-assigned —
  ## `solana` and `polkavm` — are NOT here, and their absence is the four-axis
  ## revision rather than a regression: neither names a notation anyone writes
  ## a file in, so both moved to `TargetIsa` (`token(tiSolanaSbf)` is
  ## `solanasbf`, `token(tiPolkaVm)` is `polkavm` verbatim).  A recording under
  ## either stores `unknown` on *this* axis and the substrate on the ISA axis,
  ## which is exactly what `axesOfLang(LangSolana)` said while that member
  ## existed.  LRS-5's second deletion round deleted it, so the ISA axis is now
  ## the ONLY place either substrate is named — which is the four-axis revision
  ## carried all the way through rather than a regression.
  case v
  of slUnknown: UnknownToken
  of slC: "c"
  of slCpp: "cpp"
  of slRust: "rs"
  of slNim: "nim"
  of slGo: "go"
  of slPascal: "pas"
  of slFortran: "f90"
  of slD: "d"
  of slCrystal: "cr"
  of slLean: "lean"
  of slJulia: "jl"
  of slAda: "adb"
  of slPython: "py"
  of slRuby: "rb"
  of slJavaScript: "js"
  of slLua: "lua"
  of slPhp: "php"
  of slBash: "sh"
  of slZsh: "zsh"
  of slElixir: "ex"
  of slErlang: "erl"
  of slSolidity: "sol"
  of slMove: "move"
  of slSway: "sw"
  of slCairo: "cairo"
  of slCircom: "circom"
  of slLeo: "leo"
  of slTolk: "tolk"
  of slAiken: "ak"
  of slCadence: "cdc"
  of slNoir: "nr"
  # `slAsm` keeps the unqualified `asm` as the explicit DIALECT-UNSPECIFIED
  # token — not as a claim about any dialect.
  of slAsm: "asm"
  # `slMidenAsm` is deliberately NOT `masm`, even though `masm` is exactly
  # what `getExtensionName(LangMasm)` answers and exactly what this table
  # otherwise seeds from.  Assembler DIALECT is a distinction on this axis
  # (design Q4a, decided by the user: "assemblers are just different types of
  # compilers after all"), so the namespace is expected to grow a GNU `gas`, a
  # Netwide `nasm` and a Microsoft `masm`; letting Miden hold the unqualified
  # name would strand the obvious spelling for a dialect that might later be
  # supported, in a table that is PERSISTED and therefore cannot be renamed
  # afterwards.  `masm`, `gas` and `nasm` are RESERVED AND UNALLOCATED
  # (`ReservedSourceLanguageTokens` above); `target_axes_test.nim` asserts no
  # axis and no slug spends one.  This token intentionally differs from the
  # `Lang` member name (`LangMasm`), from `getExtensionName(LangMasm)` and
  # from the grammar directory `libs/tree-sitter-masm`; read design §2.5
  # before "fixing" it back.
  of slMidenAsm: "midenasm"
  of slGdScript: "gd"

type
  TargetAxes* = object
    ## The four axes of one recording, as a value — what a `recordings.lang`
    ## cell holds since trace_index schema version 2.
    ##
    ## `LangAxes` (`common_lang.nim`) is the THREE-axis projection of a `Lang`
    ## value and is a different thing: `Lang` names no toolchain, so nothing
    ## can be projected onto that axis from it.  This object is what a cell
    ## decodes to and what a cell is encoded from.
    language*: SourceLanguage
    targetIsa*: TargetIsa
    toolchain*: Toolchain
    approach*: RecordingApproach

const
  UnknownTargetAxes* = TargetAxes(language: slUnknown, targetIsa: tiUnknown,
                                  toolchain: tcUnknown, approach: raUnknown)
    ## The all-sentinel tuple, whose one spelling is the bare `unknown` token.

func encodeAxesToken*(axes: TargetAxes): string =
  ## The persisted spelling of `axes`.  Total over the whole four-axis
  ## product; see the section comment above for why the all-sentinel tuple
  ## gets the bare form and nothing else does.
  if axes == UnknownTargetAxes:
    return UnknownToken
  storageSlug(axes.language) & AxisSeparator &
    token(axes.targetIsa) & AxisSeparator &
    token(axes.toolchain) & AxisSeparator &
    token(axes.approach)

func parseStorageSlug*(s: string, value: var SourceLanguage): bool =
  ## Parse a persisted source-language slug.  Total; returns `false` and
  ## leaves `value` untouched for a token this build does not know.
  ##
  ## Derived from `storageSlug` by iterating the enum, so the two cannot
  ## drift.  That is safe because both sides of this parse are written by
  ## THIS build's grammar; the historical `$lang` names a schema-version-1
  ## database holds are a different problem and are decoded from a frozen
  ## literal (`langV1NameToV2Token`, `trace_index.nim`) that never touches the
  ## live enum — milestone rule 3.
  for v in SourceLanguage:
    if storageSlug(v) == s:
      value = v
      return true
  false

func parseAxesToken*(raw: string, dest: var TargetAxes): bool =
  ## Decode a persisted cell.  Total: never raises, never quits, and leaves
  ## `dest` untouched when it returns `false`.
  ##
  ## The order of the three steps is the decision, not an implementation
  ## detail:
  ##
  ## 1. the literal `unknown` — matched BEFORE any split is attempted, so the
  ##    Q3 exception is a single equality test rather than something a failed
  ##    split falls into;
  ## 2. exactly four `-`-separated parts, each parsed against its own axis;
  ## 3. everything else is refused, INCLUDING every other hyphen-free token
  ##    and including the long `unknown-unknown-unknown-unknown` spelling of
  ##    the value step 1 already names.
  ##
  ## Step 3's first half is the obligation the design's §5.4 calls the one
  ## most likely to be lost: a decoder that treated a bare `py` as "slug with
  ## the default mode" would pass every other round-trip obligation and would
  ## reintroduce the persisted-default contract Q1 exists to forbid.  There is
  ## no defaulting anywhere in this function, and no path from a short token
  ## to a populated `dest` other than step 1.
  ##
  ## Deliberately NOT case-folding and NOT stripping whitespace, unlike the
  ## per-axis parsers above: those read a token a HUMAN or another program
  ## typed, this one reads a cell THIS module wrote.  A cell that differs from
  ## what the encoder emits was not written by any CodeTracer build, and
  ## accepting it would be guessing.
  if raw == UnknownToken:
    dest = UnknownTargetAxes
    return true
  let parts = raw.split(AxisSeparator)
  if parts.len != AxisTokenCount:
    return false
  var decoded: TargetAxes
  if not parseStorageSlug(parts[0], decoded.language): return false
  if not parseTargetIsa(parts[1], decoded.targetIsa): return false
  if not parseToolchain(parts[2], decoded.toolchain): return false
  if not parseRecordingApproach(parts[3], decoded.approach): return false
  # The three axis parsers above strip whitespace and lower-case, because
  # they read tokens a human or another program typed.  This one does not:
  # re-checking each part against the canonical spelling is how the leniency
  # is undone without a second copy of the three tables.
  if token(decoded.targetIsa) != parts[1]: return false
  if token(decoded.toolchain) != parts[2]: return false
  if token(decoded.approach) != parts[3]: return false
  if decoded == UnknownTargetAxes:
    # `unknown-unknown-unknown-unknown` is well-formed and is still refused:
    # the value it spells already has a spelling (step 1), and admitting a
    # second one would mean `encode` is no longer the inverse of `decode`.
    # Nothing produces it — see the section comment.
    return false
  dest = decoded
  true
