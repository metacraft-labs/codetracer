## Module contains types and procedures for handling the various programming languages
## codetracer might support

# backend agnostic code, part of the lang module, should not be imported directly,
# use common/lang or frontend/lang instead.

import os
import std/strutils
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
    ## declarations pinned in lockstep is the contract test, not a wire --
    ## which is what let LRS-4 renumber (below) as a visible refactor.
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
    ## used to name: that enum has a `Small` variant at ordinal 21 and its
    ## `Unknown` at 26, while this one starts with `LangUnknown` at 0 since
    ## LRS-4 (before that the two happened to agree below ordinal 21) and the
    ## two have different lengths.  Nothing carries an ordinal between this enum and
    ## that one; the replay worker socket between the two Rust crates now
    ## carries language *names*.
    ##
    ## Historical context (pre-M-REC-1.5): the integer previously appeared
    ## inside the retired trace_db_metadata.json sidecar.
    ## **Ordinal 0 is the sentinel** (LRS-4, 2026-09-21).  Nim zero-initialises
    ## `result` to the enum's first member, so a proc over `Lang` that falls
    ## off its end used to answer "C" (`LangC` was 0) -- the defect the 22-line
    ## comment on `detectLangFromPath` (`src/ct/utilities/language_detection.nim`)
    ## records, measured on seven real paths.  With `LangUnknown` first the
    ## same slip answers "unknown", which every caller already handles.  The
    ## reorder was possible only once no wire or storage boundary carried the
    ## ordinal (LRS-0, LRS-1) and every `Lang`-indexed table was an exhaustive
    ## `case` (LRS-3); the Rust `Lang` moved in lockstep (`Unknown = 0`,
    ## `#[default]`), pinned by the contract test.
    ##
    ## **Retired in LRS-4:** `LangPython` (was 12) and `LangRuby` (was 13), the
    ## rr/gdb backends that no longer exist.  `LangPythonDb` / `LangRubyDb` are
    ## THE Python and Ruby identity; `--lang ruby` now names the working
    ## recorder (design Q6).  Their names still occur in `recordings.lang`
    ## cells written by older builds and decode to `LangUnknown` with the name
    ## preserved (`trace_index.decodeLangColumn`, design §5.6).
    ##
    ## **Retired in LRS-5's second deletion round (2026-09-21):**
    ## `LangRustWasm` (was 18), `LangCppWasm` (19), `LangPolkavm` (27) and
    ## `LangSolana` (34).  Each welded a non-language axis onto a language
    ## enum — the wasm pair an ISA (`tiWasm`) and an approach
    ## (`raVmEmulation`), the platform pair an ISA with NO source language at
    ## all — and each was kept by LRS-4 only because the persisted
    ## `recordings.lang` column had no other way to say it.  Schema version 2
    ## stores all four axes (`rs-wasm-unknown-vm`,
    ## `unknown-solanasbf-unknown-vm`, …) and `Trace.approach` carries the
    ## recording approach per recording, so the column and the replay side say
    ## it without a member.  Their names still occur in cells written by older
    ## builds and decode losslessly (`trace_index.decodeLangColumn`, the frozen
    ## `langV1NameToV2Token` map, design §3.5 and §5.6).
    ##
    ## **What is left is exactly one member per source language.**  After this
    ## round `sourceLanguageOf` is a BIJECTION between `Lang` and
    ## `SourceLanguage` — asserted by `target_axes_test.nim` — which is the
    ## property that makes `Trace.lang` a language summary and nothing else.
    LangUnknown,  # 0 -- the sentinel, at the zero position (see above)
    LangC,        # 1
    LangCpp,      # 2
    LangRust,     # 3
    LangNim,      # 4
    LangGo,       # 5
    LangPascal,   # 6
    LangFortran,  # 7
    LangD,        # 8
    LangCrystal,  # 9
    LangLean,     # 10
    LangJulia,    # 11
    LangAda,      # 12
    LangRubyDb,   # 13 -- Ruby, recorded by codetracer-ruby-recorder (the
                  # `Db` suffix is historical: it was the pair partner of the
                  # retired rr backend `LangRuby`)
    LangJavascript, # 14
    LangLua,      # 15
    LangAsm,      # 16
    LangNoir,     # 17
    LangPythonDb, # 18 -- Python, recorded by codetracer-python-recorder (the
                  # `Db` suffix is historical, as for LangRubyDb)
    LangBash,     # 19 — tree-sitter support in db-backend; recorded by
                  # codetracer-shell-recorders (`recorderToolFor`, `slBash`),
                  # reachable as `.sh`/`.bash` via `LANGS`
    LangZsh,      # 20 — as LangBash: tree-sitter in db-backend, recorded by
                  # codetracer-shell-recorders (`slZsh`), `.zsh` via `LANGS`
    LangSolidity, # 21
    LangMasm,     # 22
    LangSway,     # 23
    LangMove,     # 24
    LangCairo,    # 25
    LangCircom,   # 26
    LangLeo,      # 27
    LangTolk,     # 28
    LangAiken,    # 29
    LangCadence,  # 30
    LangElixir,   # 31
    LangErlang,   # 32
    LangPhp,      # 33
    LangGdScript  # 34 — GDScript (Godot); materialized trace from the patched
                  # engine recorder.  Pinned against the Rust `Lang::GDScript`
                  # (libs/ct-lang/src/lib.rs) by the contract test, like every
                  # other member.

var CURRENT_LANG*: Lang = LangUnknown ## The current lang in the codetraces session

proc isVMLang*(lang: Lang): bool =
  ## return true if programming language implementation runs in a virtual machine
  false # lang in {LangRubyDb, LangPythonDb, LangLua, LangJavascript, LangUnknown}

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
  ## Every one of the 39 `Lang` values, on the axes.  **The production
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
  ## * **No member answers `slUnknown` any more except the sentinel.**  Two
  ##   used to -- `LangSolana` and `LangPolkavm`, which named a chain and a VM
  ##   rather than a notation, and whose `getExtensionName` was empty for that
  ##   reason.  LRS-5's second deletion round deleted both; their ISAs are
  ##   `tiSolanaSbf` / `tiPolkaVm` and a `--lang solana` / `--lang polkavm`
  ##   spelling reaches them through `TargetIsaSpellings`.  What
  ##   `target_axes_test.nim` asserts now is the stronger property that
  ##   replaced the old "exactly these two": this function is a BIJECTION onto
  ##   `SourceLanguage`, so every non-sentinel member has a real language and
  ##   an extension.
  case lang
  of LangUnknown: LangAxes(language: slUnknown, targetIsa: tiUnknown, approach: raUnknown)
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
  # `LangRubyDb` / `LangPythonDb` are Ruby and Python.  Until LRS-4 each had a
  # pair partner (`LangRuby`, `LangPython`: the retired rr/gdb backends) that
  # decomposed to the SAME language with `raRr`; the pair was never two
  # languages, and the retired half is gone.  A native-replay approach asked
  # of an interpreted language is still a cell of the dispatch table
  # (`retiredNativeReplayTool`), reached by constructing the selector, not by
  # any `Lang` value.
  of LangRubyDb: LangAxes(language: slRuby, targetIsa: tiInterpreted,
                          approach: raInstrumentedRuntime)
  of LangJavascript: LangAxes(language: slJavaScript, targetIsa: tiInterpreted,
                              approach: raInstrumentedRuntime)
  of LangLua: LangAxes(language: slLua, targetIsa: tiInterpreted,
                       approach: raInstrumentedRuntime)
  of LangAsm: LangAxes(language: slAsm, targetIsa: tiNative, approach: raMcr)
  of LangNoir: LangAxes(language: slNoir, targetIsa: tiAcir, approach: raVmEmulation)
  of LangPythonDb: LangAxes(language: slPython, targetIsa: tiInterpreted,
                            approach: raInstrumentedRuntime)
  of LangBash: LangAxes(language: slBash, targetIsa: tiInterpreted,
                        approach: raInstrumentedRuntime)
  of LangZsh: LangAxes(language: slZsh, targetIsa: tiInterpreted,
                       approach: raInstrumentedRuntime)
  of LangSolidity: LangAxes(language: slSolidity, targetIsa: tiEvm, approach: raVmEmulation)
  of LangMasm: LangAxes(language: slMidenAsm, targetIsa: tiMidenVm, approach: raVmEmulation)
  of LangSway: LangAxes(language: slSway, targetIsa: tiFuelVm, approach: raVmEmulation)
  of LangMove: LangAxes(language: slMove, targetIsa: tiMoveVm, approach: raVmEmulation)
  of LangCairo: LangAxes(language: slCairo, targetIsa: tiCairoVm, approach: raVmEmulation)
  of LangCircom: LangAxes(language: slCircom, targetIsa: tiCircomWitness,
                          approach: raVmEmulation)
  of LangLeo: LangAxes(language: slLeo, targetIsa: tiAleoVm, approach: raVmEmulation)
  of LangTolk: LangAxes(language: slTolk, targetIsa: tiTonVm, approach: raVmEmulation)
  of LangAiken: LangAxes(language: slAiken, targetIsa: tiPlutus, approach: raVmEmulation)
  of LangCadence: LangAxes(language: slCadence, targetIsa: tiFlowVm, approach: raVmEmulation)
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
  ## The per-file axis of a `Lang` value.  `slUnknown` only for the sentinel:
  ## LRS-5's second deletion round removed the two platform pseudo-languages
  ## (`LangSolana`, `LangPolkavm`) that used to share that answer, so this
  ## function is now a BIJECTION `Lang` <-> `SourceLanguage` and
  ## `langForSourceLanguage` below is its inverse.
  axesOfLang(lang).language

func langForSourceLanguage*(language: SourceLanguage): Lang =
  ## The inverse of `sourceLanguageOf`, derived by iterating `Lang` against the
  ## exhaustive `axesOfLang` `case` rather than from a second table (rule 4).
  ##
  ## Total and unambiguous *because* the second deletion round landed: with
  ## `LangRustWasm` / `LangCppWasm` gone no two members share `slRust` or
  ## `slCpp`, and with `LangPolkavm` / `LangSolana` gone `slUnknown` belongs to
  ## `LangUnknown` alone.  `target_axes_test.nim` asserts the bijection, so a
  ## member re-added on an occupied language fails the suite rather than making
  ## this function pick by enum order.
  for lang in Lang:
    if axesOfLang(lang).language == language:
      return lang
  LangUnknown

func storageAxesOfLang*(lang: Lang): TargetAxes =
  ## The four-axis value a `Lang` summary is PERSISTED as — milestone LRS-5.
  ##
  ## Three of the four come straight from `axesOfLang`.  The fourth,
  ## `toolchain`, is `tcUnknown`, and that is a statement rather than a gap:
  ## **no `Lang` value names a toolchain** (`LangNim` is `nim c` + `ct-mcr`
  ## for a `.nim` and the script VM for a `.nims`), so there is nothing to
  ## project onto that axis from this side.  `tcUnknown` means "the
  ## assessment did not determine the toolchain", which is exactly true of
  ## every write that goes through a `Lang`.
  ##
  ## Writing a GUESS here instead would be the defect this whole series is
  ## about: a persisted `cargo` that came from a default table rather than
  ## from an observation makes that table a persisted contract.  Threading
  ## the assessed toolchain through `Trace` and into `recordTrace` is the
  ## precondition LRS-5's second deletion round calls (b), and it is what
  ## will start filling this axis with something observed.
  let axes = axesOfLang(lang)
  TargetAxes(language: axes.language, targetIsa: axes.targetIsa,
             toolchain: tcUnknown, approach: axes.approach)

func langForStorageAxes*(axes: TargetAxes): tuple[found: bool, lang: Lang] =
  ## The `Lang` summary of a decoded cell, or `found: false` when no live
  ## member summarises it.
  ##
  ## Derived by iterating `Lang` against the exhaustive `axesOfLang` `case`,
  ## so it cannot drift from the decomposition and needs no second table
  ## (milestone rule 4: a `const` or a derivation from an exhaustive `case`,
  ## never a positional literal).  `found` is a separate field rather than a
  ## `LangUnknown` return, because `LangUnknown` is itself a legitimate answer
  ## — the all-sentinel cell — and "no member summarises this" must not be
  ## confused with it.
  ##
  ## The **toolchain is deliberately not consulted**: `Lang` has no toolchain
  ## axis, so `rs-native-cargo-mcr` and `rs-native-rustc-mcr` both summarise
  ## as `LangRust`.  That is lossy in the SUMMARY and lossless on disk, which
  ## is the whole point of storing four axes — the cell keeps what the summary
  ## cannot hold.
  ##
  ## **The language-axis fallback — LRS-5, second deletion round.**  When no
  ## member matches all three axes the summary is the member for the cell's
  ## LANGUAGE axis, and `found` stays `false` so the caller still preserves the
  ## cell verbatim (`Trace.langRetiredName`, `langLabel`).  This is not a
  ## default implied by a persisted value — Q1's rule — because the language
  ## axis is *stated in the cell*: `rs-wasm-unknown-vm` says `rs`, and the
  ## summary reads it.  What it drops is the ISA and the approach, which since
  ## this milestone are carried per recording by `Trace.approach` and by the
  ## cell itself, and which no reader has to recover from the summary any more.
  ##
  ## Without it, deleting `LangRustWasm` would have made every wasm recording
  ## summarise as `LangUnknown` — no Monaco language, no tree-sitter token
  ## table, no language name in the REPL header — which is a different silent
  ## degradation from the one the deletion was deferred for, not an absence of
  ## one.  `slUnknown` still answers `LangUnknown`, so a cell that genuinely
  ## names no language keeps the sentinel.
  for lang in Lang:
    let candidate = axesOfLang(lang)
    if candidate.language == axes.language and
       candidate.targetIsa == axes.targetIsa and
       candidate.approach == axes.approach:
      return (true, lang)
  (false, langForSourceLanguage(axes.language))

const
  MaterializedSummaryExceptions* = [
    (language: slNim, materialized: true),
    (language: slLua, materialized: false),
  ]
    ## The two SOURCE LANGUAGES whose replay-side "is this a materialized
    ## trace?" answer is NOT `producesMaterializedTrace(approach)`.
    ##
    ## **Re-keyed from `Lang` onto the language axis by LRS-5's second deletion
    ## round.**  The predicate below is now asked of a decoded *cell* (a
    ## language plus an approach) and not only of a `Lang` summary, so the
    ## exception list has to be keyed by something both forms carry.  The
    ## answers are unchanged, member for member: `slNim` is `LangNim`'s
    ## language and nothing else's, `slLua` is `LangLua`'s, and
    ## `target_axes_test.nim` asserts both directions.
    ##
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

func materializedReplayFor*(language: SourceLanguage,
                            approach: RecordingApproach): bool =
  ## **The per-recording form, and the primary one since LRS-5's second
  ## deletion round.**  Does a recording of `language` made with `approach`
  ## open as a self-contained, materialized (CTFS) trace rather than as a
  ## native replay recording?
  ##
  ## `producesMaterializedTrace(approach)` with the two exceptions in
  ## `MaterializedSummaryExceptions`.  Both arguments are facts a decoded
  ## `recordings.lang` cell states outright, which is what lets the four
  ## replay-side call sites stop asking a `Lang` summary a question the
  ## summary could only answer while `LangRustWasm` existed.
  for exception in MaterializedSummaryExceptions:
    if exception.language == language:
      return exception.materialized
  producesMaterializedTrace(approach)

func usesMaterializedTraces*(lang: Lang): bool =
  ## Does a recording summarised as ``lang`` open as a self-contained,
  ## materialized (CTFS) trace rather than a native replay recording?
  ##
  ## **Derived**, since LRS-2B, and since LRS-5's second deletion round a thin
  ## wrapper over `materializedReplayFor` — the per-recording predicate — asked
  ## of the axes the `Lang` value itself decomposes to.  The answers are
  ## unchanged for every surviving member.
  ##
  ## **This is a replay-side SUMMARY over a per-recording fact, and it is no
  ## longer how a loaded recording is judged.**  `Trace.lang` summarises a
  ## recording by one `Lang`, and for a Rust or C++ recording that summary
  ## cannot say whether the recording was native or wasm — which is exactly
  ## why the wasm pair existed.  The four replay-side sites that used to ask
  ## `usesMaterializedTraces(trace.lang)` now ask
  ## `usesMaterializedTraces(trace)`, which reads `Trace.approach` (the
  ## per-recording fact the column carries since schema version 2).  What is
  ## left for this overload is the EXTENSION-derived question
  ## (`usesMaterializedTracesForExtension`) and the record-target question in
  ## `index/traces.nim` when there is no loaded recording to ask.
  let axes = axesOfLang(lang)
  materializedReplayFor(axes.language, axes.approach)

func toCLang*(lang: Lang): string =
  ## The NAME of the language a ``Lang`` value stands for -- the one such
  ## table for both backends since LRS-3 (``src/frontend/lang.nim`` used to
  ## carry a second copy, ``toJsLang``, which agreed with this one on 39 of the
  ## 41 members and is gone).  It feeds the Monaco ``language:``
  ## field (``ui/editor.nim``), the LSP ``languageId`` (``lsp_router.nim``),
  ## the language dropdown (``LANG_PICKER_LANGS`` below) and the CI recording
  ## event's ``langName``.
  ##
  ## It answers per LANGUAGE, not per recording artefact.  It used to FOLD the
  ## conflated pairs onto one name each (``LangRust``/``LangRustWasm`` ->
  ## ``rust``, ``LangCpp``/``LangCppWasm`` -> ``cpp``; ``LangRubyDb`` is
  ## ``ruby`` and ``LangPythonDb`` ``python``, their retired pair partners
  ## ``LangRuby`` / ``LangPython`` folding onto the same names until LRS-4
  ## deleted them).  **Since LRS-5's second deletion round there is nothing
  ## left to fold**: ``sourceLanguageOf`` is a bijection, so this table is
  ## injective and every member has its own name.  It is still NOT a wire
  ## name -- ``langWireName`` is the one that round-trips, and the two answer
  ## different questions (a Monaco/LSP id versus a protocol token).
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
  ## * ``LangCppWasm`` -> ``"cpp"`` -- HISTORICAL since LRS-5's second
  ##   deletion round deleted the member, and kept because it is why
  ##   ``LangCpp`` answers ``cpp`` and not ``c++`` today.  The old
  ##   ``"c++"`` made this table say C++ is ``cpp`` and C++-compiled-to-wasm
  ##   is ``c++`` (design §1.2(a)); it is the same language, and ``cpp`` is
  ##   also the id Monaco registers where ``c++`` is not.  The duplicate
  ##   ``<option>`` it threatened is closed by ``LANG_PICKER_LANGS``, whose
  ##   fold is a no-op now that no two members share a name.
  ##
  ## Exhaustive ``case`` rather than a positional ``array[Lang, string]``: the
  ## array form is checked for length only, so a member removed or reordered
  ## above shifted every answer after it without any diagnostic.
  case lang
  of LangUnknown: "unknown"
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
  of LangRubyDb: "ruby"
  of LangJavascript: "javascript"
  of LangLua: "lua"
  of LangAsm: "assembly"
  of LangNoir: "noir"
  of LangPythonDb: "python"
  of LangBash: "bash"
  of LangZsh: "zsh"
  of LangSolidity: "solidity"
  of LangMasm: "masm"
  of LangSway: "sway"
  of LangMove: "move"
  of LangCairo: "cairo"
  of LangCircom: "circom"
  of LangLeo: "leo"
  of LangTolk: "tolk"
  of LangAiken: "aiken"
  of LangCadence: "cadence"
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
    ## NOT here, because it is excluded by its AXES rather than by a
    ## declaration: `LangUnknown` (`raUnknown`, the sentinel).  Until LRS-4
    ## `LangPython` and `LangRuby` (`raRr`, the retired native replay
    ## backends) were excluded the same way; they are gone.

func isSupportedLang*(lang: Lang): bool =
  ## Can `ct record` record something summarised as `lang` -- is there a
  ## working recorder for the selector `axesOfLang(lang)` projects to, or is
  ## it the native family that `ct-native-replay` records?  This is the
  ## design's derivation for the language list (§6.3: "recorderToolFor's
  ## domain plus the native family"), written on the axes so that it compiles
  ## on both backends -- `recorderToolFor` itself lives beside `std/os` and
  ## cannot be reached from the JS front end.  The native side pins the two
  ## against each other over every member (`target_axes_test.nim`) -- 35 of
  ## them since LRS-5's second deletion round.  This line said "all 41", the
  ## count before LRS-4 deleted two, and is corrected under rule 7.
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
    false   # no `Lang` value decomposes to these since LRS-4 retired
            # `LangPython` / `LangRuby`; a selector can still name them
            # (`retiredNativeReplayTool`), and it has no recorder
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
  ## (`LangSolana` and `LangPolkavm` had no source language, so they could
  ## never satisfy the ISA rule and must not have to).
  ##
  ## **All four of those members were deleted by LRS-5's second deletion
  ## round, so every supported member is now `alone` and this function answers
  ## `true` for all 32 of them -- the fold is a no-op, and `LANG_PICKER_LANGS`
  ## therefore EQUALS `SUPPORTED_LANGS`.**  It is kept, and kept order-blind,
  ## because it states the RULE rather than the current population: a member
  ## re-added on an already-claimed `toCLang` name must fold rather than emit a
  ## second `<option>` with the same `value`.
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
  of LangUnknown: "unknown"
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
  # "Ruby" and "Python", not "Ruby(db)" / "Python(db)": since LRS-4 these are
  # the only Ruby and Python members, and the parenthesised recording mode
  # was the conflation spelled into a display name (design §1.2).
  of LangRubyDb: "Ruby"
  of LangJavascript: "Javascript"
  of LangLua: "Lua"
  of LangAsm: "assembly language"
  of LangNoir: "Noir"
  of LangPythonDb: "Python"
  of LangBash: "Bash"
  of LangZsh: "Zsh"
  of LangSolidity: "Solidity"
  of LangMasm: "MASM/Miden"
  of LangSway: "Sway"
  of LangMove: "Move"
  of LangCairo: "Cairo"
  of LangCircom: "Circom"
  of LangLeo: "Leo"
  of LangTolk: "Tolk"
  of LangAiken: "Aiken"
  of LangCadence: "Cadence"
  of LangElixir: "Elixir"
  of LangErlang: "Erlang"
  of LangPhp: "PHP"
  of LangGdScript: "GDScript"

func getExtensionName*(lang: Lang): string =
  ## The canonical source-file extension for ``lang``, without the dot.
  ##
  ## Lives here, in the backend-agnostic half, because ``src/common/lang.nim``
  ## and ``src/frontend/lang.nim`` each held a byte-identical 40-entry (then)
  ## positional copy of this table.  Two hand-maintained copies of one mapping,
  ## neither checked against the other, is the drift this enum has already
  ## suffered elsewhere; the wrappers now differ only in whether they return a
  ## ``string`` or a ``cstring``.
  ##
  ## **Exactly ONE member answers with the empty string since LRS-5's second
  ## deletion round: ``LangUnknown``, the sentinel.**  Three did before it --
  ## the sentinel plus ``LangPolkavm`` and ``LangSolana``, which were
  ## folder-based, a chain and a VM rather than notations anyone writes a file
  ## in.  Both members are deleted, so the old careful qualifier ("the only two
  ## NON-SENTINEL members with an empty entry") no longer has a referent.
  ## ``target_axes_test.nim`` asserts the current shape directly: every
  ## ``Lang`` but the sentinel has a non-empty extension.
  case lang
  of LangUnknown: ""            # sentinel
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
  of LangRubyDb: "rb"
  of LangJavascript: "js"
  of LangLua: "lua"
  of LangAsm: "asm"
  of LangNoir: "nr"
  of LangPythonDb: "py"
  of LangBash: "sh"
  of LangZsh: "zsh"
  of LangSolidity: "sol"
  of LangMasm: "masm"
  of LangSway: "sw"
  of LangMove: "move"
  of LangCairo: "cairo"
  of LangCircom: "circom"
  of LangLeo: "leo"
  of LangTolk: "tolk"
  of LangAiken: "ak"
  of LangCadence: "cdc"
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
  of LangUnknown, LangC, LangCpp, LangRust, LangGo, LangPascal, LangFortran,
     LangD, LangCrystal, LangLean, LangJulia, LangAda,
     LangRubyDb, LangJavascript, LangLua, LangAsm, LangNoir,
     LangPythonDb, LangBash, LangZsh, LangSolidity,
     LangMasm, LangSway, LangMove, LangCairo, LangCircom,
     LangLeo, LangTolk, LangAiken, LangCadence, LangElixir,
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
  of LangUnknown, LangC, LangCpp, LangRust, LangGo, LangPascal, LangFortran,
     LangD, LangCrystal, LangLean, LangJulia, LangAda,
     LangRubyDb, LangJavascript, LangLua, LangAsm, LangNoir,
     LangPythonDb, LangBash, LangZsh, LangSolidity,
     LangMasm, LangSway, LangMove, LangCairo, LangCircom,
     LangLeo, LangTolk, LangAiken, LangCadence, LangElixir,
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
  ## for member.  Not ``toCLang``: that one is a DISPLAY choice and was a
  ## folding one -- it used to fold ``LangRustWasm`` into ``"rust"`` -- while a
  ## wire name must round-trip.  (Since LRS-5's second deletion round nothing
  ## is left to fold, but the two functions still answer different questions
  ## and must not be merged: ``toCLang`` names a Monaco/LSP language id and
  ## ``langWireName`` names a protocol token.)
  ## (``LangRubyDb`` / ``LangPythonDb`` keep ``rubydb`` / ``pythondb`` on the
  ## wire after LRS-4 retired their pair partners: the spelling is a contract
  ## with ``codetracer-native-backend``'s ``Lang::from_str`` and is not
  ## renamed for tidiness.)
  ##
  ## Exhaustive ``case`` on purpose (milestone rule 4): a member added to
  ## ``Lang`` does not compile until it has been given a name here, exactly as
  ## on the Rust side.
  case lang
  of LangUnknown: "unknown"
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
  of LangRubyDb: "rubydb"
  of LangJavascript: "javascript"
  of LangLua: "lua"
  of LangAsm: "asm"
  of LangNoir: "noir"
  of LangPythonDb: "pythondb"
  of LangBash: "bash"
  of LangZsh: "zsh"
  of LangSolidity: "solidity"
  of LangMasm: "masm"
  of LangSway: "sway"
  of LangMove: "move"
  of LangCairo: "cairo"
  of LangCircom: "circom"
  of LangLeo: "leo"
  of LangTolk: "tolk"
  of LangAiken: "aiken"
  of LangCadence: "cadence"
  of LangElixir: "elixir"
  of LangErlang: "erlang"
  of LangPhp: "php"
  of LangGdScript: "gdscript"

func langSpellings*(lang: Lang): seq[string] =
  ## Every INPUT spelling `toLang` resolves to `lang`: the `--lang` names and
  ## the file extensions, lower-case, without the dot.  This is the one such
  ## table since LRS-3.  Three hand-kept copies used to exist -- the core's
  ## `toLang` (`src/common/lang.nim`, `--lang` names plus extensions), the
  ## front end's `toLang` (`src/frontend/lang.nim`, extensions plus a few
  ## names) and its `fromPath` (extensions again, for the editor) -- and they
  ## had drifted exactly as the design's §2.5 recorded: the core knew `asm`
  ## but not `s`, the front end knew `asm` and `s` but not `miden`, and no
  ## comment anywhere said either gap was meant.  The rows below are the
  ## UNION of the three (64 spellings at LRS-3, no two tables ever disagreed
  ## on a shared one), and unifying them changed detection on both sides: the
  ## core gained five spellings (`s`, and the extension rows `h`, `hpp`,
  ## `pas`, `js` only the front end had), the front end gained the core's 23
  ## `--lang` names (`miden`, `rust`, `nims`, `gdscript`, `ruby(db)`, the
  ## `-wasm` forms, ...) and case-insensitive matching.
  ## `src/tests/cli/lang_spellings_test.nim` and
  ## `src/frontend/tests/frontend_lang_test.nim` pin the new behaviour.
  ##
  ## Written per `Lang` as an exhaustive `case` (milestone rule 4) rather
  ## than as the string-keyed literal it used to be: a member added to the
  ## enum does not compile until it has been given its spellings (an empty
  ## list is a valid, deliberate answer), and `LANG_SPELLINGS` below is
  ## built from this at compile time with every spelling checked for
  ## uniqueness.
  ##
  ## **LRS-4 (2026-09-21, design Q6, decided by the coordinator):** `ruby`
  ## names `LangRubyDb`, the working Ruby recorder -- the member it used to
  ## name, `LangRuby` (the retired rr backend, whose only content was a
  ## diagnostic), is gone.  `--lang ruby foo.rb` therefore records instead of
  ## erroring.  `ruby(db)` is KEPT as a deprecated alias of the same member
  ## (`DeprecatedLangSpellings`): `ct record` prints one note on stderr when
  ## it is used and records anyway, so no invocation breaks; the alias is
  ## slated for removal one release later.  `LangPython` had no spelling at
  ## all (`python` and `py` always named `LangPythonDb`, design §3.1), so its
  ## deletion removed no row here.
  ##
  ## **LRS-5, second deletion round (2026-09-21): where `rust-wasm` and
  ## `cpp-wasm` went.**  Those two spellings named `LangRustWasm` /
  ## `LangCppWasm`, the members this round deleted, and the milestone required
  ## them to have a new home or a reasoned removal -- "a user who typed
  ## `--lang rust-wasm` must still get a wasm recording or a clear error,
  ## never a silent native one".  Both are now **deprecated aliases of their
  ## LANGUAGE** (`rust-wasm`/`rustwasm` -> `LangRust`, `cpp-wasm`/`cppwasm` ->
  ## `LangCpp`), announced once on stderr like `ruby(db)`.
  ##
  ## That keeps every invocation that works today working, because the
  ## wasm-ness was never coming from the spelling in the cases that work:
  ##
  ## * `ct record --lang rust-wasm foo.wasm` -- the ISA comes from the
  ##   `.wasm` extension (`KindWasmModule`, LRS-5 (c)), so the route is
  ##   `wazero` with or without the flag;
  ## * `ct record --lang rust-wasm ./crate` where `.cargo/config.toml` names
  ##   `wasm32` -- the ISA comes from the marker (`KindWasmCargoProject`),
  ##   which is how LRS-2B already routed it;
  ## * `ct record --lang rust-wasm ./crate` with NO wasm marker is the one
  ##   case where the member was the only source of `tiWasm`, and it does not
  ##   work today either: `record.nim` builds a wasm binary only for
  ##   `KindWasmCargoProject`, so the pre-existing behaviour was to hand a
  ##   DIRECTORY to `wazero`.  A spelling whose only unique power is to reach
  ##   a broken path is not a home worth keeping.
  ##
  ## The wasm-ness is not lost even where no artefact fact states it: the
  ## four aliases are also `WasmLangSpellingIsa` rows, so `--lang rust-wasm`
  ## carries `tiWasm` as an ISA OVERRIDE beside its language, and a crate with
  ## no `wasm32` marker still records as wasm.  A separate `--target` FLAG was
  ## the other alternative and is NOT added: `ct record` has no `--target`
  ## today, the assessment already reads both artefact facts that decide the
  ## ISA, and a second flag for one axis is what this series closed.  If one is
  ## ever added, `TargetIsaSpellings` is what it parses.
  ##
  ## **`polkavm` and `solana` did NOT get the same treatment, and they did not
  ## go either.**  They name no language, so they are not rows of this table
  ## at all — they are `TargetIsaSpellings` rows.  Keeping them working was
  ## not a courtesy: neither target has an extension, a project marker or a
  ## `LANGS` row, so `--lang` was the ONLY route to their recorders, and an
  ## unrecognised `--lang` resolves to `LangUnknown`, which `detectTarget`
  ## reads as "no language was given" rather than refusing.  Deleting the
  ## spellings would therefore have deleted `ct record` for both targets
  ## *silently*.
  ##
  ## Three members have NO spelling, each on purpose:
  ## * `LangUnknown` -- the sentinel; it is what a miss returns.
  ## * `LangBash` / `LangZsh` -- reachable by `ct record` through `LANGS`
  ##   (`src/ct/utilities/language_detection.nim`, `sh`/`bash`/`zsh`), which
  ##   is the extension-routing table the desktop capability file is derived
  ##   from, and NOT merged here for that reason: it must stay extension-only
  ##   and it carries routing rows (`wasm`, `ts`, `mjs`) that are not
  ##   spellings of a language.  Neither hand-kept `toLang` copy knew a shell
  ##   spelling, so none is added; the gap is recorded, not closed.
  case lang
  of LangUnknown: @[]
  of LangC: @["c", "h"]
  # `cpp-wasm` / `cppwasm`: deprecated aliases, as `rust-wasm` above.
  of LangCpp: @["cpp", "hpp", "cpp-wasm", "cppwasm"]
  # `rust-wasm` / `rustwasm`: deprecated aliases since LRS-5's second
  # deletion round deleted `LangRustWasm`.  See the block comment above and
  # `DeprecatedLangSpellings` below.
  of LangRust: @["rust", "rs", "rust-wasm", "rustwasm"]
  of LangNim: @["nim", "nims"]
  of LangGo: @["go"]
  of LangPascal: @["pascal", "pas"]
  of LangFortran: @["fortran", "f90"]
  of LangD: @["d", "dlang"]
  of LangCrystal: @["crystal", "cr"]
  of LangLean: @["lean"]
  of LangJulia: @["julia", "jl"]
  of LangAda: @["ada", "adb"]
  # `ruby` since LRS-4 (Q6); `ruby(db)` is the deprecated alias, see
  # `DeprecatedLangSpellings` below.
  of LangRubyDb: @["ruby", "rb", "ruby(db)"]
  of LangJavascript: @["javascript", "js"]
  of LangLua: @["lua"]
  # `asm` AND `s`: the front end always mapped both, the core only `asm`.
  of LangAsm: @["asm", "s"]
  of LangNoir: @["noir", "nr"]
  of LangPythonDb: @["python", "py"]
  of LangBash: @[]
  of LangZsh: @[]
  of LangSolidity: @["solidity", "sol"]
  # `masm` AND `miden`: the core always accepted both, the front end only
  # `masm`.  `miden` is the Miden-qualified spelling the design's §2.5 cites
  # as the precedent for the `midenasm` storage slug.
  of LangMasm: @["masm", "miden"]
  of LangSway: @["sway", "sw"]
  of LangMove: @["move"]
  of LangCairo: @["cairo"]
  of LangCircom: @["circom"]
  of LangLeo: @["leo"]
  of LangTolk: @["tolk"]
  of LangAiken: @["aiken", "ak"]
  of LangCadence: @["cadence", "cdc"]
  of LangElixir: @["elixir", "ex", "exs"]
  of LangErlang: @["erlang", "erl", "hrl"]
  of LangPhp: @["php"]
  of LangGdScript: @["gdscript", "gd"]

const
  LANG_SPELLINGS* = block:
    ## `(spelling, Lang)` for every row of `langSpellings`, in `Lang`
    ## declaration order -- the lookup `toLang` scans.  A `seq` rather than a
    ## `Table`/`JsAssoc` because it must be built at compile time from the
    ## exhaustive `case` and be the same value on both backends; at ~90 rows a
    ## scan is not a cost anyone can measure.
    var pairs: seq[(string, Lang)] = @[]
    for lang in Lang:
      for spelling in langSpellings(lang):
        pairs.add((spelling, lang))
    pairs

static:
  # A spelling claimed by two members would resolve to whichever is declared
  # first -- an ordinal dependency of exactly the kind this series removes --
  # so it is refused at compile time.  So is a spelling `toLang` could never
  # match: it lower-cases its input before the scan.
  var seen: seq[string] = @[]
  for (spelling, lang) in LANG_SPELLINGS:
    doAssert spelling.len > 0, $lang & " has an empty spelling"
    doAssert spelling notin seen, "spelling `" & spelling & "` is claimed twice"
    for ch in spelling:
      doAssert ch notin {'A'..'Z'}, "spelling `" & spelling & "` is not lower-case"
    seen.add(spelling)

const
  WasmSpellingNote* =
    "The wasm target is not named by `--lang` any more: it is read from the " &
    "artefact -- a `.wasm` module, or a Cargo project whose " &
    "`.cargo/config.toml` names `wasm32`."
    ## The second sentence the four wasm aliases below carry.  Held as a
    ## constant so the diagnostic and the test that pins it cannot drift.

  DeprecatedLangSpellings* = [
    (spelling: "ruby(db)", lang: LangRubyDb, preferred: "ruby", extra: ""),
    (spelling: "rust-wasm", lang: LangRust, preferred: "rust",
     extra: WasmSpellingNote),
    (spelling: "rustwasm", lang: LangRust, preferred: "rust",
     extra: WasmSpellingNote),
    (spelling: "cpp-wasm", lang: LangCpp, preferred: "cpp",
     extra: WasmSpellingNote),
    (spelling: "cppwasm", lang: LangCpp, preferred: "cpp",
     extra: WasmSpellingNote),
  ]
    ## Input spellings `toLang` still accepts but that `ct record` announces
    ## as deprecated (one line on stderr, then it records exactly as the
    ## preferred spelling would).  Design question Q6, decided 2026-09-21 by
    ## the coordinator: `--lang ruby` selects the working Ruby backend, and
    ## `ruby(db)` -- a spelling with parentheses in it that no shell likes,
    ## which existed only because `ruby` was taken by the retired rr backend
    ## -- stays for one release so no script breaks, then goes.  Each row
    ## MUST also be a row of `langSpellings` for the same member; the
    ## `static:` block below refuses one that is not, so the alias cannot
    ## silently stop resolving while still being announced as merely
    ## deprecated.
    ##
    ## `extra` is a second sentence for rows where "it selects X exactly as
    ## `--lang Y` does" would leave a user wondering where a fact went.  The
    ## four wasm rows (LRS-5's second deletion round) need it: what the
    ## spelling used to add was a target ISA, and the note has to say where
    ## the ISA comes from now instead of leaving the user to find out by
    ## getting a native recording.

static:
  for row in DeprecatedLangSpellings:
    doAssert row.spelling in langSpellings(row.lang),
      "deprecated spelling `" & row.spelling & "` is not a spelling of " & $row.lang
    doAssert row.preferred in langSpellings(row.lang),
      "preferred spelling `" & row.preferred & "` is not a spelling of " & $row.lang
    doAssert row.spelling != row.preferred

const
  TargetIsaSpellings* = [
    # The two that MUST be here, because they were `Lang` members and nothing
    # else can reach their recorder.  A PolkaVM blob and a Solana program have
    # no source language and no detectable marker (`getExtensionName` was `""`
    # for both, no `LANGS` row, no `assessFolderKind` arm -- the Edit-Mode
    # Toolbar spec's EMT-F7 says so), so `--lang polkavm` / `--lang solana`
    # was the ONLY way to record one.  Deleting the members without this table
    # would not have renamed that route, it would have DELETED it: the target
    # would fall through to `assessFolderKind`, a Solana crate would be read
    # as plain Rust, and `ct record` would take the native path.
    ("polkavm", tiPolkaVm),
    ("solana", tiSolanaSbf),
    ("solanasbf", tiSolanaSbf),
    # The general form, and the one the wasm aliases below ride on.
    ("wasm", tiWasm),
  ]
    ## `--lang` spellings that name a **target ISA** rather than a language.
    ##
    ## **LRS-5, second deletion round.**  `--lang` has always accepted these
    ## -- `polkavm` and `solana` were `Lang` MEMBERS, which is the conflation
    ## this series removes -- and this table is that fact stated on the right
    ## axis rather than a new feature.  The value overrides the assessment's
    ## ISA (`assessRecordingTarget`'s `isaOverride`), which then decides the
    ## recording approach and therefore the recorder, exactly as the deleted
    ## members' `axesOfLang` arms did.
    ##
    ## A spelling here need not also be a `langSpellings` row and usually is
    ## not: `polkavm` names no language, so `toLang("polkavm")` is
    ## `LangUnknown` and the LANGUAGE stays undetermined -- which is the
    ## truth, and which is what `unknown-polkavm-unknown-vm` stores.
    ##
    ## No new CLI FLAG was added for this.  `ct record` has no `--target`
    ## today, the assessment already reads the two artefact facts that decide
    ## the ISA on its own (a `.wasm` extension, a `.cargo/config.toml`
    ## `wasm32` marker), and a second flag for one axis is what this series
    ## closed.  If a `--target` is ever added, this table is what it parses.

  WasmLangSpellingIsa* = [
    ("rust-wasm", tiWasm), ("rustwasm", tiWasm),
    ("cpp-wasm", tiWasm), ("cppwasm", tiWasm),
  ]
    ## The four DEPRECATED aliases carry an ISA as well as a language: they
    ## resolve to `LangRust` / `LangCpp` through `langSpellings` AND override
    ## the ISA to `tiWasm` here.  Without the second half, `--lang rust-wasm`
    ## on a crate with no `wasm32` marker would silently become a native
    ## recording -- the one thing the milestone said must not happen.

func targetIsaSpelling*(spelling: string): TargetIsa =
  ## The target ISA a `--lang` spelling names, or `tiUnknown` when it names
  ## none.  Case-insensitive, like `toLang`.  Both tables are consulted: the
  ## ISA-only spellings and the four wasm aliases that carry an ISA beside
  ## their language.
  let key = spelling.toLowerAscii
  for (name, isa) in TargetIsaSpellings:
    if name == key:
      return isa
  for (name, isa) in WasmLangSpellingIsa:
    if name == key:
      return isa
  tiUnknown

func deprecatedLangSpellingNote*(spelling: string): string =
  ## The one-line note `ct record` prints on stderr when `--lang` was given a
  ## deprecated spelling; `""` for every other input.  Case-insensitive like
  ## `toLang`.  Kept beside the table so the wording and the alias list
  ## cannot drift apart; `record_backend_selection_test.nim` pins both.
  let key = spelling.toLowerAscii
  for row in DeprecatedLangSpellings:
    if row.spelling == key:
      result = "note: `--lang " & spelling & "` is deprecated and will be " &
        "removed in a later release; it selects " & toName(row.lang) &
        " exactly as `--lang " & row.preferred & "` does -- use that instead."
      if row.extra.len > 0:
        result.add(" " & row.extra)
      return result
  ""

proc toLang*(lang: string): Lang =
  ## The `Lang` a `--lang` name or a file extension (without the dot) names,
  ## case-insensitively; `LangUnknown` for anything `langSpellings` does not
  ## list.  One definition for both backends since LRS-3; see `langSpellings`
  ## for the three tables it replaced.
  let key = lang.toLowerAscii
  for (spelling, value) in LANG_SPELLINGS:
    if spelling == key:
      return value
  LangUnknown

proc toLang*(lang: cstring): Lang =
  toLang($lang)

static:
  # An ISA-only spelling must NOT also be a language spelling: that would be
  # the conflation again, one table over.  The wasm aliases are the stated
  # exception and live in their own table for exactly that reason.
  for (name, _) in TargetIsaSpellings:
    doAssert toLang(name) == LangUnknown,
      "`" & name & "` names both a language and a target ISA"
  for (name, _) in WasmLangSpellingIsa:
    doAssert toLang(name) != LangUnknown,
      "the wasm alias `" & name & "` must also resolve to its language"

func isKnownLangSpelling*(spelling: string): bool =
  ## Does `--lang <spelling>` name ANYTHING this build knows -- a language
  ## (`LANG_SPELLINGS`, via `toLang`) or a target ISA (`TargetIsaSpellings`
  ## and the four wasm aliases, via `targetIsaSpelling`)?
  ##
  ## **The defect this exists to close, found at LRS-5's review.**  `--lang`
  ## resolves through `toLang`, which answers `LangUnknown` for a spelling it
  ## does not have, and `detectTarget` reads `LangUnknown` as *"no language
  ## was given"* rather than as *"the user named one I do not know"*:
  ##
  ##     if lang != LangUnknown:
  ##       return DetectedTarget(lang: lang, recognitionRan: false)
  ##
  ## So `ct record --lang typo ./crate` behaved EXACTLY like `ct record
  ## ./crate` -- detection ran, the crate was read as plain Rust, and a native
  ## recording was made under a flag that asked for something else.  Measured
  ## on the built binary at review: the two invocations produced
  ## byte-identical output.
  ##
  ## That is the same class of defect `record_backend_selection_test.nim`
  ## documents for `--backend`, which `ct-mcr/record.md` settled in the other
  ## direction: *"refuse to start when the requested configuration cannot be
  ## honored, rather than silently downgrading"*.  LRS-5's second deletion
  ## round walked right up to it -- removing the `polkavm` / `solana`
  ## spellings would have deleted `ct record` for those targets *through this
  ## fall-through* -- and kept the spellings without closing the hole.  This
  ## closes it.
  ##
  ## An EMPTY spelling is not this function's business: `--lang` absent is
  ## "no language given", which is the legitimate case.  Callers check
  ## `spelling.len > 0` first.
  toLang(spelling) != LangUnknown or targetIsaSpelling(spelling) != tiUnknown

func unknownLangSpellingLines*(spelling: string): seq[string] =
  ## The diagnostic `ct record` prints for a `--lang` value that names
  ## neither a language nor a target ISA, then exits non-zero.  Every accepted
  ## spelling is listed, from the same two tables `isKnownLangSpelling`
  ## consults, so the message cannot drift from what is accepted.
  var accepted: seq[string] = @[]
  for (known, _) in LANG_SPELLINGS:
    accepted.add(known)
  for (name, _) in TargetIsaSpellings:
    if name notin accepted:
      accepted.add(name)
  @["error: `--lang " & spelling & "` names neither a language nor a target " &
    "CodeTracer knows, so `ct record` will not guess what you meant.",
    "help: drop `--lang` to let CodeTracer assess the target, or use one of: " &
    accepted.join(", ")]

proc decodeLangName*(name: string): tuple[lang: Lang, retiredName: string] =
  ## ``$lang`` back to a ``Lang``, by the enum's own member names, for a
  ## reader that must NEVER raise: the Electron renderer decoding
  ## ``ct trace-metadata``'s ``"lang": "LangPythonDb"``
  ## (``src/frontend/trace_metadata.nim``).  A name this build does not have
  ## is the sentinel with the name preserved in ``retiredName`` -- the
  ## retired-name policy of design §5.6, as ``trace_index.decodeLangColumn``
  ## applies it to the persisted column, minus that decoder's refusal of
  ## foreign strings: there the string came off THIS build's own disk and a
  ## foreign one is corruption worth raising about, here it came from a
  ## possibly newer ``ct`` and refusing it would take the whole trace down
  ## with it.  ``parseEnum`` reads the ordinal from the enum, so there is no
  ## second hand-written list of ordinals to keep in step (LRS-4 deleted the
  ## one the renderer had).  Works on both backends;
  ## ``src/frontend/tests/frontend_lang_test.nim`` pins it on JS.
  let lang = parseEnum[Lang](name, LangUnknown)
  if lang == LangUnknown and name.len > 0 and name != $LangUnknown:
    (lang: LangUnknown, retiredName: name)
  else:
    (lang: lang, retiredName: "")

proc usesMaterializedTracesForExtension*(extension: string): bool =
  ## Return true if the file extension belongs to a language that produces
  ## materialized traces.
  let lang = toLang(extension)
  usesMaterializedTraces(lang)
