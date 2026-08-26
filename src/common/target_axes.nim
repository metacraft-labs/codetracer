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
## This module is **additive**.  It does not replace `Lang`, no production code
## dispatches on it yet, and no `Lang` member is removed or renumbered by its
## existence.  The migration is sequenced in
## `codetracer-specs/Refactoring-Plans/Language-Recording-Type-Split.milestones.org`.

import std/strutils

type
  SourceLanguage* = enum
    ## What notation a **file** is written in.
    ##
    ## The sentinel is ordinal 0 on purpose.  `Lang` puts `LangC` at ordinal 0,
    ## and a proc that falls off its end therefore answers "C" — a defect that
    ## really happened and cost `ct record ./a.out` its recognizer delegation
    ## (the 22-line post-mortem at
    ## `src/ct/utilities/language_detection.nim:125-146`).  A zero-initialised
    ## `SourceLanguage` says "I do not know", which is the honest answer for a
    ## value nobody assigned.
    ##
    ## Chains and VMs are **not** here.  `LangSolana` and `LangPolkavm` are the
    ## two `Lang` members with an empty `getExtension` entry
    ## (`src/common/lang.nim:113,120`) because they are not notations anyone
    ## writes a file in — a Solana program is Rust or C, and PolkaVM is a
    ## machine.  They live on `TargetIsa` below.
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
                        ## Lua, PHP, Bash, Zsh
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
    ## This is the axis that `USES_MATERIALIZED_TRACES`
    ## (`src/common/common_lang.nim:81-118`) is a one-bit projection of: a
    ## 40-slot `array[Lang, bool]` carrying a *backend* property on a *language*
    ## enum.
    ##
    ## **`wasm` is not here.**  An earlier two-axis design put `rtWasm` on the
    ## recording-mode axis because `USES_MATERIALIZED_TRACES[LangRustWasm]` is
    ## `true` (`common_lang.nim:97`).  That was reading the flag backwards:
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

func token*(v: TargetIsa): string =
  ## The wire spelling of a target ISA.
  case v
  of tiUnknown: UnknownToken
  of tiNative: "native"
  of tiInterpreted: "interpreted"
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

func defaultTargetIsa*(lang: SourceLanguage): TargetIsa =
  ## Where a source language ends up when nothing says otherwise.
  ##
  ## Rust and C/C++ default to `tiNative` and reach `tiWasm` only when the
  ## assessment says so — which is exactly what `isWasmCargoProject`
  ## (`src/ct/utilities/language_detection.nim:18-26`) reads `.cargo/config.toml`
  ## for today, and exactly the pair `LangRustWasm` / `LangCppWasm` welded
  ## together into single enum members.
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

func defaultRecordingApproach*(isa: TargetIsa): RecordingApproach =
  ## How CodeTracer records a given target ISA when nothing says otherwise.
  ##
  ## This is a function of the **ISA**, not of the language, and that is the
  ## point: `USES_MATERIALIZED_TRACES` is a 40-entry hand-maintained
  ## `array[Lang, bool]` whose 24 `true` entries were kept in agreement with
  ## `recorderToolFor`'s 24 `supported: true` arms by hand.  Deriving the
  ## approach from the ISA replaces the hand-agreement with one table.
  ##
  ## `LangNim` is the case that shows the improvement.  It is flagged
  ## `usesMaterializedTraces = true` (`common_lang.nim:96`) while its recorder
  ## is `ct-mcr` (`recorder_dispatch.nim:309-318`) — a contradiction under a
  ## one-bit model.  Here Nim is `tiNative` and therefore `raMcr`, and the CTFS
  ## container MCR produces is a property of MCR, not of Nim.
  case isa
  of tiUnknown: raUnknown
  of tiNative: raMcr
  of tiInterpreted: raInstrumentedRuntime
  of tiBeam: raInstrumentedRuntime
  of tiWasm, tiEvm, tiMidenVm, tiMoveVm, tiFuelVm, tiPolkaVm, tiCairoVm,
     tiAleoVm, tiTonVm, tiPlutus, tiFlowVm, tiSolanaSbf, tiAcir,
     tiCircomWitness:
    raVmEmulation

func producesMaterializedTrace*(approach: RecordingApproach): bool =
  ## The successor of `usesMaterializedTraces` (`common_lang.nim:120-123`), as a
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
