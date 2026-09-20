## Module contains types and procedures for handling the various programming languages
## codetracer might support

# backend agnostic code, part of the lang module, should not be imported directly,
# use common/lang or frontend/lang instead.

import os
# Relative to THIS file, not to the module that includes it: Nim resolves a
# relative import against the file the statement is written in, which is what
# lets one include-d table reach the axes from both `src/common/lang.nim` and
# `src/frontend/lang.nim`.  `target_axes` has no `std/jsffi` and compiles on
# both backends (`target_axes_test.nim`, `target_axes_js_test.nim`).
import ./target_axes
export target_axes

type
  Lang* = enum ## Identifies a programming language implementation
    ## Ordinals MUST match the canonical Rust `Lang` enum in
    ## libs/ct-lang/src/lib.rs (`#[repr(u8)]`), which
    ## `src/tests/cli/lang_enum_contract_test.nim` pins ordinal for ordinal.
    ##
    ## NO wire carries the ordinal any more (LRS-1, both tranches).  The
    ## `ct/load-locals` DAP hop carries `langWireName(lang)` -- the same
    ## spelling as the Rust `Lang::wire_name` -- decoded by `ct-lang`'s
    ## `lang_wire` adapter, which refuses a bare integer.  The tracepoint pair
    ## that used to carry it (`Tracepoint.lang` on `ct/run-tracepoints`,
    ## `Stop.lang` on `ct/tracepoint-results`) was DELETED on both sides:
    ## neither field was ever read by its receiver or set by its sender.  On
    ## the Rust side `Lang` derives no serde implementation at all, so a new
    ## `lang: Lang` field on a wire struct does not compile without the
    ## name-carrying adapter.  The persisted `recordings.lang` column holds
    ## the enum NAME (trace_index schema version 1).  What keeps the two
    ## declarations pinned in lockstep until LRS-4 renumbers is the contract
    ## test, not a wire.
    ##
    ## This used to name src/db-backend/src/lang.rs.  That file now only
    ## re-exports the enum (`pub use ct_lang::{lang_wire, Lang}`); the
    ## declaration moved to the leaf crate `libs/ct-lang` so that
    ## `src/db-backend` and `libs/ct-dap-client` could stop keeping their own
    ## divergent copies.  `src/tests/cli/lang_enum_contract_test.nim` asserts
    ## this list against that one, name for name and ordinal for ordinal, and
    ## asserts that no second ordinal-carrying `Lang` exists in the Rust tree.
    ##
    ## It is NOT `codetracer-native-backend/src/lang.rs`, which this comment
    ## used to name: that enum has a `Small` variant at ordinal 21, so the two
    ## diverge from 21 onwards (`PythonDb` is 21 here and 22 there) and have
    ## different lengths.  Nothing carries an ordinal between this enum and
    ## that one; the replay worker socket between the two Rust crates now
    ## carries language *names*.
    ##
    ## Historical context (pre-M-REC-1.5): the integer previously appeared
    ## inside the retired trace_db_metadata.json sidecar.
    LangC,        # 0
    LangCpp,      # 1
    LangRust,     # 2
    LangNim,      # 3
    LangGo,       # 4
    LangPascal,   # 5
    LangFortran,  # 6
    LangD,        # 7
    LangCrystal,  # 8
    LangLean,     # 9
    LangJulia,    # 10
    LangAda,      # 11
    LangPython,   # 12
    LangRuby,     # 13
    LangRubyDb,   # 14
    LangJavascript, # 15
    LangLua,      # 16
    LangAsm,      # 17
    LangNoir,     # 18
    LangRustWasm, # 19
    LangCppWasm,  # 20
    LangPythonDb, # 21
    LangUnknown,  # 22
    LangBash,     # 23 — tree-sitter support in db-backend; recorded by
                  # codetracer-shell-recorders (`recorderToolFor`, `slBash`),
                  # reachable as `.sh`/`.bash` via `LANGS`
    LangZsh,      # 24 — as LangBash: tree-sitter in db-backend, recorded by
                  # codetracer-shell-recorders (`slZsh`), `.zsh` via `LANGS`
    LangSolidity, # 25
    LangMasm,     # 26
    LangSway,     # 27
    LangMove,     # 28
    LangPolkavm,  # 29
    LangCairo,    # 30
    LangCircom,   # 31
    LangLeo,      # 32
    LangTolk,     # 33
    LangAiken,    # 34
    LangCadence,  # 35
    LangSolana,   # 36
    LangElixir,   # 37
    LangErlang,   # 38
    LangPhp,      # 39
    LangGdScript  # 40 — GDScript (Godot); materialized trace from the patched
                  # engine recorder. MUST stay ordinal 40 to match the db-backend
                  # Rust `Lang::GDScript` (codetracer/src/db-backend/src/lang.rs).

var CURRENT_LANG*: Lang = LangUnknown ## The current lang in the codetraces session

proc isVMLang*(lang: Lang): bool =
  ## return true if programming language implementation runs in a virtual machine
  false # lang in {LangRuby, LangPython, LangPythonDb, LangLua, LangJavascript, LangUnknown}

type
  LangAxes* = object
    ## One `Lang` value, decomposed onto the artefact axes it conflates.
    ##
    ## `Lang` is a per-file notation, a per-artefact ISA and a per-artefact
    ## recording approach welded into one value; this is the projection back
    ## out.  The toolchain axis is deliberately absent: no `Lang` value names a
    ## toolchain (`LangNim` is `nim c` + `ct-mcr` for a `.nim` and the script VM
    ## for a `.nims`), so it is derived from the assessed KIND alone
    ## (`src/ct/trace/record_assessment.nim`).
    language*: SourceLanguage
    targetIsa*: TargetIsa
    approach*: RecordingApproach

func axesOfLang*(lang: Lang): LangAxes =
  ## Every one of the 41 `Lang` values, on the axes.  **The production
  ## decomposition** — it used to live only in `target_axes_test.nim` as the
  ## safety net for this migration, and it must not survive in both places, so
  ## the test now reads this one.
  ##
  ## An exhaustive `case`, so a new `Lang` member is a compile error here until
  ## someone states which language, ISA and approach it stands for.
  ##
  ## Two things this table cannot say, both by design:
  ##
  ## * It answers per `Lang` VALUE, so it cannot separate `.nim` from `.nims`
  ##   (both `LangNim`) or a plain crate from a wasm one (both `LangRust` until
  ##   `isWasmCargoProject` says otherwise).  Those are decided by the
  ##   assessment, which overrides the ISA below when the target kind says so.
  ##   The answer for `LangNim` is therefore the per-language FALLBACK
  ##   (`fallbackTargetIsaForLanguage(slNim) == tiNative`), not a claim that
  ##   every Nim recording is native.
  ## * `LangSolana` and `LangPolkavm` have NO source language: they name a
  ##   chain and a VM, which is why their `getExtensionName` is empty.  The
  ##   language of a program recorded under either is unknown until a file is
  ##   looked at.  `target_axes_test.nim` asserts these are exactly the two.
  case lang
  of LangC: LangAxes(language: slC, targetIsa: tiNative, approach: raMcr)
  of LangCpp: LangAxes(language: slCpp, targetIsa: tiNative, approach: raMcr)
  of LangRust: LangAxes(language: slRust, targetIsa: tiNative, approach: raMcr)
  of LangNim: LangAxes(language: slNim, targetIsa: tiNative, approach: raMcr)
  of LangGo: LangAxes(language: slGo, targetIsa: tiNative, approach: raMcr)
  of LangPascal: LangAxes(language: slPascal, targetIsa: tiNative, approach: raMcr)
  of LangFortran: LangAxes(language: slFortran, targetIsa: tiNative, approach: raMcr)
  of LangD: LangAxes(language: slD, targetIsa: tiNative, approach: raMcr)
  of LangCrystal: LangAxes(language: slCrystal, targetIsa: tiNative, approach: raMcr)
  of LangLean: LangAxes(language: slLean, targetIsa: tiNative, approach: raMcr)
  of LangJulia: LangAxes(language: slJulia, targetIsa: tiNative, approach: raMcr)
  of LangAda: LangAxes(language: slAda, targetIsa: tiNative, approach: raMcr)
  # `LangPython` and `LangRuby` are the retired rr/gdb backends.  On these axes
  # they are the SAME LANGUAGE as their `Db` siblings with a different recording
  # approach, which is the whole point: the pair was never two languages.
  of LangPython: LangAxes(language: slPython, targetIsa: tiInterpreted, approach: raRr)
  of LangRuby: LangAxes(language: slRuby, targetIsa: tiInterpreted, approach: raRr)
  of LangRubyDb: LangAxes(language: slRuby, targetIsa: tiInterpreted,
                          approach: raInstrumentedRuntime)
  of LangJavascript: LangAxes(language: slJavaScript, targetIsa: tiInterpreted,
                              approach: raInstrumentedRuntime)
  of LangLua: LangAxes(language: slLua, targetIsa: tiInterpreted,
                       approach: raInstrumentedRuntime)
  of LangAsm: LangAxes(language: slAsm, targetIsa: tiNative, approach: raMcr)
  of LangNoir: LangAxes(language: slNoir, targetIsa: tiAcir, approach: raVmEmulation)
  # The wasm pair: same language, different ISA.
  of LangRustWasm: LangAxes(language: slRust, targetIsa: tiWasm, approach: raVmEmulation)
  of LangCppWasm: LangAxes(language: slCpp, targetIsa: tiWasm, approach: raVmEmulation)
  of LangPythonDb: LangAxes(language: slPython, targetIsa: tiInterpreted,
                            approach: raInstrumentedRuntime)
  of LangUnknown: LangAxes(language: slUnknown, targetIsa: tiUnknown, approach: raUnknown)
  of LangBash: LangAxes(language: slBash, targetIsa: tiInterpreted,
                        approach: raInstrumentedRuntime)
  of LangZsh: LangAxes(language: slZsh, targetIsa: tiInterpreted,
                       approach: raInstrumentedRuntime)
  of LangSolidity: LangAxes(language: slSolidity, targetIsa: tiEvm, approach: raVmEmulation)
  of LangMasm: LangAxes(language: slMidenAsm, targetIsa: tiMidenVm, approach: raVmEmulation)
  of LangSway: LangAxes(language: slSway, targetIsa: tiFuelVm, approach: raVmEmulation)
  of LangMove: LangAxes(language: slMove, targetIsa: tiMoveVm, approach: raVmEmulation)
  of LangPolkavm: LangAxes(language: slUnknown, targetIsa: tiPolkaVm, approach: raVmEmulation)
  of LangCairo: LangAxes(language: slCairo, targetIsa: tiCairoVm, approach: raVmEmulation)
  of LangCircom: LangAxes(language: slCircom, targetIsa: tiCircomWitness,
                          approach: raVmEmulation)
  of LangLeo: LangAxes(language: slLeo, targetIsa: tiAleoVm, approach: raVmEmulation)
  of LangTolk: LangAxes(language: slTolk, targetIsa: tiTonVm, approach: raVmEmulation)
  of LangAiken: LangAxes(language: slAiken, targetIsa: tiPlutus, approach: raVmEmulation)
  of LangCadence: LangAxes(language: slCadence, targetIsa: tiFlowVm, approach: raVmEmulation)
  of LangSolana: LangAxes(language: slUnknown, targetIsa: tiSolanaSbf, approach: raVmEmulation)
  of LangElixir: LangAxes(language: slElixir, targetIsa: tiBeam,
                          approach: raInstrumentedRuntime)
  of LangErlang: LangAxes(language: slErlang, targetIsa: tiBeam,
                          approach: raInstrumentedRuntime)
  of LangPhp: LangAxes(language: slPhp, targetIsa: tiInterpreted,
                       approach: raInstrumentedRuntime)
  # GDScript: a real per-file language (`slGdScript`), running on Godot's own
  # bytecode VM (`tiGdScriptVm`), recorded by the patched engine instrumenting
  # itself (`raInstrumentedRuntime`).  See `target_axes.nim` for each choice.
  of LangGdScript: LangAxes(language: slGdScript, targetIsa: tiGdScriptVm,
                            approach: raInstrumentedRuntime)

func sourceLanguageOf*(lang: Lang): SourceLanguage =
  ## The per-file axis of a `Lang` value.  `slUnknown` for the sentinel and
  ## for the two platform pseudo-languages (`LangSolana`, `LangPolkavm`).
  axesOfLang(lang).language

const
  MaterializedSummaryExceptions* = [
    (lang: LangNim, materialized: true),
    (lang: LangLua, materialized: false),
  ]
    ## The two `Lang` values whose replay-side "is this a materialized trace?"
    ## answer is NOT `producesMaterializedTrace(axesOfLang(lang).approach)`.
    ## Each is a deliberate decision, not an average:
    ##
    ## * **`LangNim` — `true`.**  The decomposition says `tiNative` / `raMcr`,
    ##   and MCR is native replay for C, C++ and Rust.  For Nim it is not: BOTH
    ##   Nim flows — `nim e --trace:` for `.nims` AND `nim c` + `ct-mcr` for
    ##   `.nim` — hand their container to `importTrace(..., traceKind = "db")`
    ##   (`src/ct/db_backend_record.nim`, `recordNim`), so every Nim recording
    ##   in the index IS opened as a materialized trace.  The per-value
    ##   decomposition cannot see the extension; the record-side dispatch uses
    ##   the assessment instead (`record_assessment.nim`), which does.
    ## * **`LangLua` — `false`.**  The decomposition says an interpreted
    ##   language is recorded by instrumenting its runtime, which is how Lua
    ##   WOULD be recorded and is unavailable: no Lua recorder exists anywhere
    ##   (`recorderToolFor` declares it unsupported).  No materialized Lua trace
    ##   can therefore exist, and the replay-side answer stays `false`.  The gap
    ##   is made visible on the RECORD side instead: `ct record --lang lua
    ##   foo.lua` now reaches the "no recorder for Lua" diagnostic through the
    ##   assessment rather than attempting a native build of a script.  (`.lua`
    ##   is not in `LANGS` -- `src/ct/utilities/language_detection.nim` -- so a
    ##   bare `ct record foo.lua` still resolves to `LangUnknown` and never
    ##   reaches the arm; that missing registration is a separate gap in the
    ##   extension table, the same kind `.gd` had, and it is recorded, not
    ##   closed, here.)

func usesMaterializedTraces*(lang: Lang): bool =
  ## Does a recording summarised as ``lang`` open as a self-contained,
  ## materialized (CTFS) trace rather than a native replay recording?
  ##
  ## **Derived**, since LRS-2B: `producesMaterializedTrace(axesOfLang(lang).approach)`
  ## for 39 of the 41 values, with the two exceptions in
  ## `MaterializedSummaryExceptions` stated and reasoned individually.  It used
  ## to be a hand-kept 41-arm `case` (and before LRS-3 a mutable positional
  ## `array[Lang, bool]`) whose 24 `true` answers had to be kept in agreement
  ## with `recorderToolFor`'s `supported` arms by hand.
  ##
  ## **This is a replay-side SUMMARY over a per-recording fact.**  `Trace.lang`
  ## summarises a recording by one `Lang`, and this predicate answers for that
  ## summary — which is why `LangNim` cannot be right for both of its flows and
  ## needs an exception.  The record side does not use it to decide anything
  ## any more: `ct record` derives the approach from the assessment and asks
  ## `producesMaterializedTrace` of that.
  for exception in MaterializedSummaryExceptions:
    if exception.lang == lang:
      return exception.materialized
  producesMaterializedTrace(axesOfLang(lang).approach)

func toCLang*(lang: Lang): string =
  ## The NAME of the language a ``Lang`` value stands for -- the one such
  ## table for both backends since LRS-3 (``src/frontend/lang.nim`` used to
  ## carry a second copy, ``toJsLang``, which agreed with this one on 39 of the
  ## 41 members and is gone).  It feeds the Monaco ``language:``
  ## field (``ui/editor.nim``), the LSP ``languageId`` (``lsp_router.nim``),
  ## the language dropdown (``LANG_PICKER_LANGS`` below) and the CI recording
  ## event's ``langName``.
  ##
  ## It answers per LANGUAGE, not per recording artefact: the four conflated
  ## pairs fold onto one name each (``LangRuby``/``LangRubyDb`` -> ``ruby``,
  ## ``LangPython``/``LangPythonDb`` -> ``python``, ``LangRust``/``LangRustWasm``
  ## -> ``rust``, ``LangCpp``/``LangCppWasm`` -> ``cpp``), exactly as
  ## ``axesOfLang`` gives each pair one ``SourceLanguage``.  That is why this is
  ## NOT a wire name: ``langWireName`` is the one that round-trips.
  ##
  ## The two slots the two copies disagreed on, and how each was decided:
  ##
  ## * ``LangAsm`` -> ``"assembly"`` (design question Q4b, decided 2026-09-20
  ##   against what Monaco registers rather than by averaging).  The vendored
  ##   monaco-editor 0.54.0 registers NEITHER ``assembly`` NOR ``assembler`` --
  ##   its 90 ids (``esm/vs/basic-languages/monaco.contribution.js`` plus the
  ##   language services) contain one assembly-family tokenizer, ``mips``, and
  ##   CodeTracer registers exactly one id of its own, ``nim``
  ##   (``src/frontend/languages/nimLanguage.js``) -- so neither spelling buys
  ##   highlighting and both fall to Monaco's tokenize-nothing path.  The tie
  ##   is broken by which spelling the tree's own consumers already handle:
  ##   every live Monaco and LSP site reads THIS function, so ``"assembly"`` is
  ##   what has always reached them; ``"assembler"`` reached nothing (the sole
  ##   ``toJsLang`` caller assigned a variable nobody read), and the axes'
  ##   ``displayName(slAsm)`` also says ``"assembly"``.  Monaco ids for files
  ##   that DO have a tokenizer are ``diff_document.DiffLanguageByExtension``'s
  ##   business, not this table's.
  ## * ``LangCppWasm`` -> ``"cpp"``, the same name as ``LangCpp``.  The old
  ##   ``"c++"`` made this table say C++ is ``cpp`` and C++-compiled-to-wasm
  ##   is ``c++`` (design §1.2(a)); it is the same language, and ``cpp`` is
  ##   also the id Monaco registers where ``c++`` is not.  The duplicate
  ##   ``<option>`` this used to threaten is closed by ``LANG_PICKER_LANGS``,
  ##   which folds same-name members before the dropdown is rendered.
  ##
  ## Exhaustive ``case`` rather than a positional ``array[Lang, string]``: the
  ## array form is checked for length only, so a member removed or reordered
  ## above shifted every answer after it without any diagnostic.
  case lang
  of LangC: "c"
  of LangCpp: "cpp"
  of LangRust: "rust"
  of LangNim: "nim"
  of LangGo: "go"
  of LangPascal: "pascal"
  of LangFortran: "fortran"
  of LangD: "d"
  of LangCrystal: "crystal"
  of LangLean: "lean"
  of LangJulia: "julia"
  of LangAda: "ada"
  of LangPython: "python"
  of LangRuby: "ruby"
  of LangRubyDb: "ruby"
  of LangJavascript: "javascript"
  of LangLua: "lua"
  of LangAsm: "assembly"
  of LangNoir: "noir"
  of LangRustWasm: "rust"
  of LangCppWasm: "cpp"
  of LangPythonDb: "python"
  of LangUnknown: "unknown"
  of LangBash: "bash"
  of LangZsh: "zsh"
  of LangSolidity: "solidity"
  of LangMasm: "masm"
  of LangSway: "sway"
  of LangMove: "move"
  of LangPolkavm: "polkavm"
  of LangCairo: "cairo"
  of LangCircom: "circom"
  of LangLeo: "leo"
  of LangTolk: "tolk"
  of LangAiken: "aiken"
  of LangCadence: "cadence"
  of LangSolana: "solana"
  of LangElixir: "elixir"
  of LangErlang: "erlang"
  of LangPhp: "php"
  of LangGdScript: "gdscript"

const
  DeclaredUnsupportedLangs* = {LangLua, LangGdScript}
    ## The `Lang` values whose axes name a real recording approach but whose
    ## recorder `recorderToolFor` (`src/ct/trace/recorder_dispatch.nim`)
    ## DECLARES `supported: false` -- the same shape as
    ## `MaterializedSummaryExceptions`: each is a stated decision, and
    ## `target_axes_test.nim` pins this set against the dispatch table member
    ## for member, so an arm that flips there without this set following it
    ## is a red test rather than a stale dropdown.
    ##
    ## * **`LangLua`** -- no Lua recorder exists anywhere; the table's `slLua`
    ##   arm says so and names what would have to exist.
    ## * **`LangGdScript`** -- the recorder IS a patched Godot engine, which
    ##   CodeTracer does not ship; the `tiGdScriptVm` arm prints how to record
    ##   with one you already have.
    ##
    ## NOT here, because they are excluded by their AXES rather than by a
    ## declaration: `LangPython` and `LangRuby` (`raRr`, the retired native
    ## replay backends) and `LangUnknown` (`raUnknown`, the sentinel).

func isSupportedLang*(lang: Lang): bool =
  ## Can `ct record` record something summarised as `lang` -- is there a
  ## working recorder for the selector `axesOfLang(lang)` projects to, or is
  ## it the native family that `ct-native-replay` records?  This is the
  ## design's derivation for the language list (§6.3: "recorderToolFor's
  ## domain plus the native family"), written on the axes so that it compiles
  ## on both backends -- `recorderToolFor` itself lives beside `std/os` and
  ## cannot be reached from the JS front end.  The native side pins the two
  ## against each other over all 41 members (`target_axes_test.nim`).
  ##
  ## An exhaustive `case` over the approach (milestone rule 4): an approach
  ## added to the axis does not compile until it says whether it is
  ## recordable.
  if lang in DeclaredUnsupportedLangs:
    return false
  case axesOfLang(lang).approach
  of raUnknown:
    false   # the sentinel; the only value with no approach is `LangUnknown`
  of raRr, raTtd:
    false   # the retired native-replay backends (`LangPython`, `LangRuby`)
  of raMcr:
    true    # the native family (`ct-native-replay`) and Nim's `ct-mcr`
  of raInstrumentedRuntime, raVmEmulation:
    true    # every declared recorder, less the exceptions above

const
  SUPPORTED_LANGS* = block:
    ## The languages `ct record` can record, in `Lang` declaration order.
    ## DERIVED at compile time from `isSupportedLang`, which is why there is
    ## one of it: `src/common/lang.nim` and `src/frontend/lang.nim` used to
    ## carry a 29- and a 30-entry hand-kept list each, disagreeing by three
    ## members and both omitting Python and JavaScript, whose recorders have
    ## existed for as long as the lists have.
    var langs: seq[Lang] = @[]
    for lang in Lang:
      if isSupportedLang(lang):
        langs.add(lang)
    langs

func langPickerRepresentative(lang: Lang): bool =
  ## Is `lang` the member that stands for its `toCLang` NAME in the language
  ## dropdown?  `toCLang` folds each conflated pair onto one name, so a
  ## dropdown keyed by that name must offer each name ONCE and must choose
  ## which member's label to show.  The choice is order-blind (milestone
  ## Class B: two members swapped in the enum change nothing here): among the
  ## supported members sharing a name, the representative is the one whose
  ## ISA is the language's own fallback -- the plain `LangRust` over the
  ## wasm `LangRustWasm`, `LangCpp` over `LangCppWasm` -- and a member that
  ## shares its name with no other supported member represents itself
  ## (`LangSolana` and `LangPolkavm` have no source language, so they could
  ## never satisfy the ISA rule and must not have to).
  if not isSupportedLang(lang):
    return false
  let name = toCLang(lang)
  var alone = true
  for other in Lang:
    if other != lang and isSupportedLang(other) and toCLang(other) == name:
      alone = false
  if alone:
    return true
  let axes = axesOfLang(lang)
  axes.targetIsa == fallbackTargetIsaForLanguage(axes.language)

const
  LANG_PICKER_LANGS* = block:
    ## `SUPPORTED_LANGS` with the same-name members folded: exactly one entry
    ## per distinct `toCLang` name, so the dropdown `renderer.langs` builds
    ## (`<option value='toCLang(z)'>toName(z)</option>`) carries no duplicate
    ## `value` -- it used to emit `rust` twice (design §1.2(c)) and, with
    ## `LangCppWasm` now spelled `cpp`, would have emitted `cpp` twice.  The
    ## ISA and the recording approach are the assessment's to decide
    ## (LRS-2B), not a dropdown's, so folding the wasm siblings loses nothing
    ## a user could have asked for here.
    var langs: seq[Lang] = @[]
    for lang in Lang:
      if langPickerRepresentative(lang):
        langs.add(lang)
    langs

static:
  # A picker that is not a fold of the supported list is a bug in the fold,
  # and one that offers a name twice is the defect this exists to remove;
  # both are caught while compiling rather than in a lane.
  var seen: seq[string] = @[]
  for lang in LANG_PICKER_LANGS:
    doAssert lang in SUPPORTED_LANGS, $lang & " is offered but not supported"
    doAssert toCLang(lang) notin seen, "duplicate picker value " & toCLang(lang)
    seen.add(toCLang(lang))
  for lang in SUPPORTED_LANGS:
    doAssert toCLang(lang) in seen, $lang & " is supported but has no picker entry"

func toName*(lang: Lang): string =
  ## convert Lang_ to string
  ##
  ## Exhaustive ``case``; see ``toCLang`` for why the positional array form was
  ## unsafe.
  case lang
  of LangC: "C"
  of LangCpp: "C++"
  of LangRust: "Rust"
  of LangNim: "Nim"
  of LangGo: "Go"
  of LangPascal: "Pascal"
  of LangFortran: "Fortran"
  of LangD: "D"
  of LangCrystal: "Crystal"
  of LangLean: "Lean"
  of LangJulia: "Julia"
  of LangAda: "Ada"
  of LangPython: "Python"
  of LangRuby: "Ruby"
  of LangRubyDb: "Ruby(db)"
  of LangJavascript: "Javascript"
  of LangLua: "Lua"
  of LangAsm: "assembly language"
  of LangNoir: "Noir"
  of LangRustWasm: "Rust(wasm)"
  of LangCppWasm: "C++(wasm)"
  of LangPythonDb: "Python(db)"
  of LangUnknown: "unknown"
  of LangBash: "Bash"
  of LangZsh: "Zsh"
  of LangSolidity: "Solidity"
  of LangMasm: "MASM/Miden"
  of LangSway: "Sway"
  of LangMove: "Move"
  of LangPolkavm: "PolkaVM"
  of LangCairo: "Cairo"
  of LangCircom: "Circom"
  of LangLeo: "Leo"
  of LangTolk: "Tolk"
  of LangAiken: "Aiken"
  of LangCadence: "Cadence"
  of LangSolana: "Solana"
  of LangElixir: "Elixir"
  of LangErlang: "Erlang"
  of LangPhp: "PHP"
  of LangGdScript: "GDScript"

func getExtensionName*(lang: Lang): string =
  ## The canonical source-file extension for ``lang``, without the dot.
  ##
  ## Lives here, in the backend-agnostic half, because ``src/common/lang.nim``
  ## and ``src/frontend/lang.nim`` each held a byte-identical 40-entry
  ## positional copy of this table.  Two hand-maintained copies of one mapping,
  ## neither checked against the other, is the drift this enum has already
  ## suffered elsewhere; the wrappers now differ only in whether they return a
  ## ``string`` or a ``cstring``.
  ##
  ## Three members answer with the empty string, not two: ``LangUnknown`` is the
  ## sentinel, and ``LangPolkavm`` and ``LangSolana`` are folder-based — a chain
  ## and a VM rather than notations anyone writes a file in.  Prose elsewhere in
  ## the tree says "the only two"; it means the only two NON-SENTINEL members,
  ## and has been corrected to say so.
  case lang
  of LangC: "c"
  of LangCpp: "cpp"
  of LangRust: "rs"
  of LangNim: "nim"
  of LangGo: "go"
  of LangPascal: "pas"
  of LangFortran: "f90"
  of LangD: "d"
  of LangCrystal: "cr"
  of LangLean: "lean"
  of LangJulia: "jl"
  of LangAda: "adb"
  of LangPython: "py"
  of LangRuby: "rb"
  of LangRubyDb: "rb"
  of LangJavascript: "js"
  of LangLua: "lua"
  of LangAsm: "asm"
  of LangNoir: "nr"
  of LangRustWasm: "rs"
  of LangCppWasm: "cpp"
  of LangPythonDb: "py"
  of LangUnknown: ""            # sentinel
  of LangBash: "sh"
  of LangZsh: "zsh"
  of LangSolidity: "sol"
  of LangMasm: "masm"
  of LangSway: "sw"
  of LangMove: "move"
  of LangPolkavm: ""            # folder-based
  of LangCairo: "cairo"
  of LangCircom: "circom"
  of LangLeo: "leo"
  of LangTolk: "tolk"
  of LangAiken: "ak"
  of LangCadence: "cdc"
  of LangSolana: ""             # folder-based
  of LangElixir: "ex"
  of LangErlang: "erl"
  of LangPhp: "php"
  of LangGdScript: "gd"

func reservedNames*(lang: Lang): seq[string] =
  ## The identifiers a language's editor surfaces must not treat as user names.
  ##
  ## The DATA lives here, in the backend-agnostic floor, and the JS front end
  ## builds its `JsAssoc` container from it (`src/frontend/lang.nim`).  It was a
  ## positional `array[Lang, JsAssoc[cstring, bool]]` of 40 rows with exactly
  ## ONE non-empty entry, which is the worst case for a silent positional
  ## shift: removing a member above `LangNim` would have handed Nim's keyword
  ## set to whichever language landed on ordinal 3, and 39 identical-looking
  ## empty rows gave a reviewer nothing to notice it by.
  ##
  ## `seq[string]`, not `seq[cstring]` and not `nim-everywhere`'s
  ## `NativeSeq`/`NativeString`: this is a short list of ASCII tokens that stays
  ## inside Nim until the front end wraps it, and the wrapping belongs at the
  ## front end's own boundary.
  case lang
  of LangNim:
    @["if", "elif", "else", "when", "case", "of",
      "for", "while", "block", "try", "except", "finally",
      "proc", "func", "method", "iterator", "template", "macro", "converter",
      "var", "let", "const", "type",
      "return", "yield", "discard", "break", "continue",
      "and", "or", "not", "xor", "in", "notin", "is", "isnot",
      "nil", "true", "false", "result"]
  # Listed exhaustively rather than with an `else`, because an `else` would
  # restore exactly the property this conversion removes: a member added later
  # silently acquiring an answer nobody chose for it.
  of LangC, LangCpp, LangRust, LangGo, LangPascal, LangFortran, LangD,
     LangCrystal, LangLean, LangJulia, LangAda, LangPython, LangRuby,
     LangRubyDb, LangJavascript, LangLua, LangAsm, LangNoir, LangRustWasm,
     LangCppWasm, LangPythonDb, LangUnknown, LangBash, LangZsh, LangSolidity,
     LangMasm, LangSway, LangMove, LangPolkavm, LangCairo, LangCircom,
     LangLeo, LangTolk, LangAiken, LangCadence, LangSolana, LangElixir,
     LangErlang, LangPhp, LangGdScript:
    @[]

func flowKeywords*(lang: Lang): seq[string] =
  ## The tokens the flow pane renders as keywords, per language.
  ##
  ## Same shape and same history as `reservedNames` above: a 40-row positional
  ## table with one populated row, where 39 rows pointed at a single shared
  ## `emptyKeywords` value.  The container is built in
  ## `src/frontend/ui/flow.nim`; the data is here so it is checkable from both
  ## backends and so a native front end can reach it.
  case lang
  of LangNim:
    @["func", "proc", "int", "seq", "for", "in", "var"]
  of LangC, LangCpp, LangRust, LangGo, LangPascal, LangFortran, LangD,
     LangCrystal, LangLean, LangJulia, LangAda, LangPython, LangRuby,
     LangRubyDb, LangJavascript, LangLua, LangAsm, LangNoir, LangRustWasm,
     LangCppWasm, LangPythonDb, LangUnknown, LangBash, LangZsh, LangSolidity,
     LangMasm, LangSway, LangMove, LangPolkavm, LangCairo, LangCircom,
     LangLeo, LangTolk, LangAiken, LangCadence, LangSolana, LangElixir,
     LangErlang, LangPhp, LangGdScript:
    @[]

func langWireName*(lang: Lang): string =
  ## The ordinal-independent spelling of ``lang`` on a wire: what the
  ## ``ct/load-locals`` request's ``lang`` field carries since LRS-1.
  ##
  ## Byte-for-byte the Rust ``Lang::wire_name`` in ``libs/ct-lang/src/lib.rs``
  ## -- the receiver decodes it with that crate's ``lang_wire`` adapter, so a
  ## spelling that differs here is a refused request, not a wrong language.
  ## ``src/tests/cli/lang_enum_contract_test.nim`` pins the two tables member
  ## for member.  Not ``toCLang``: that one folds ``LangRubyDb`` into
  ## ``"ruby"`` and ``LangRustWasm`` into ``"rust"``, which is a display
  ## choice, and a wire name must round-trip.
  ##
  ## Exhaustive ``case`` on purpose (milestone rule 4): a member added to
  ## ``Lang`` does not compile until it has been given a name here, exactly as
  ## on the Rust side.
  case lang
  of LangC: "c"
  of LangCpp: "cpp"
  of LangRust: "rust"
  of LangNim: "nim"
  of LangGo: "go"
  of LangPascal: "pascal"
  of LangFortran: "fortran"
  of LangD: "d"
  of LangCrystal: "crystal"
  of LangLean: "lean"
  of LangJulia: "julia"
  of LangAda: "ada"
  of LangPython: "python"
  of LangRuby: "ruby"
  of LangRubyDb: "rubydb"
  of LangJavascript: "javascript"
  of LangLua: "lua"
  of LangAsm: "asm"
  of LangNoir: "noir"
  of LangRustWasm: "rustwasm"
  of LangCppWasm: "cppwasm"
  of LangPythonDb: "pythondb"
  of LangUnknown: "unknown"
  of LangBash: "bash"
  of LangZsh: "zsh"
  of LangSolidity: "solidity"
  of LangMasm: "masm"
  of LangSway: "sway"
  of LangMove: "move"
  of LangPolkavm: "polkavm"
  of LangCairo: "cairo"
  of LangCircom: "circom"
  of LangLeo: "leo"
  of LangTolk: "tolk"
  of LangAiken: "aiken"
  of LangCadence: "cadence"
  of LangSolana: "solana"
  of LangElixir: "elixir"
  of LangErlang: "erlang"
  of LangPhp: "php"
  of LangGdScript: "gdscript"

proc toLang*(lang: string): Lang
proc toLang*(lang: cstring): Lang

proc usesMaterializedTracesForExtension*(extension: string): bool =
  ## Return true if the file extension belongs to a language that produces
  ## materialized traces.
  let lang = toLang(extension)
  usesMaterializedTraces(lang)
