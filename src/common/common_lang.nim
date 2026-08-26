## Module contains types and procedures for handling the various programming languages
## codetracer might support

# backend agnostic code, part of the lang module, should not be imported directly,
# use common/lang or frontend/lang instead.

import os

type
  Lang* = enum ## Identifies a programming language implementation
    ## Ordinals MUST match the canonical Rust `Lang` enum in
    ## libs/ct-lang/src/lib.rs, which uses `#[repr(u8)]` with `serde_repr`.
    ## That is the enum on the other side of the `ct/load-locals` DAP hop,
    ## where `lang` is still sent as an integer (see
    ## `frontend/viewmodel/store/replay_data_store.nim`).
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
    LangBash,     # 23 — internal only (tree-sitter support in db-backend)
    LangZsh,      # 24 — internal only (tree-sitter support in db-backend)
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
    LangPhp       # 39

var CURRENT_LANG*: Lang = LangUnknown ## The current lang in the codetraces session

proc isVMLang*(lang: Lang): bool =
  ## return true if programming language implementation runs in a virtual machine
  false # lang in {LangRuby, LangPython, LangPythonDb, LangLua, LangJavascript, LangUnknown}

func usesMaterializedTraces*(lang: Lang): bool =
  ## Return true if ``lang`` produces materialized (self-contained) traces
  ## via a dedicated recorder, as opposed to rr/gdb-based replay traces.
  ##
  ## This used to be a mutable ``var USES_MATERIALIZED_TRACES*: array[Lang, bool]``
  ## literal of 40 ``false`` entries followed by 29 statement-level assignments
  ## that switched 24 of them on.  Two independent hazards came with that shape:
  ##
  ## * The literal was indexed by enum *position*.  Nim checks an
  ##   ``array[Lang, T]`` literal's LENGTH, not the order of its entries, so
  ##   removing or reordering a ``Lang`` member left the literal compiling while
  ##   every lookup past the edit silently returned a neighbour's answer.
  ## * It was a ``var``, and an exported one, so the table was writable by any
  ##   importer for the life of the process.
  ##
  ## As an exhaustive ``case`` it is a compiler-checked total function: adding a
  ## ``Lang`` member fails to compile here until someone states its answer, and
  ## no caller can mutate it.  The 24 ``true`` answers below are exactly the 24
  ## the assignments produced; nothing referenced the array itself, so removing
  ## it changed no call site.
  ##
  ## **This proc is itself an instance of the defect the four axes remove**, and
  ## converting it to a ``case`` does not fix that — it only makes the table
  ## checkable.  "Does this produce a materialized trace?" is a property of the
  ## ARTEFACT and of how it was recorded; ``lang`` is a property of a FILE.  The
  ## successor is ``producesMaterializedTrace(approach)``
  ## (``src/common/target_axes.nim``), which asks the question of the axis that
  ## actually decides it.  See ``LangNim`` below for the case where one bit
  ## demonstrably cannot answer.
  case lang
  # LangNim answers for TWO recorders at once, which is why this single bit
  # cannot be right for both:
  #   * ``.nim``  -> ``nim c`` then ct-mcr (``db_backend_record.nim:143-188``),
  #                  which is NATIVE REPLAY and not a materialized trace;
  #   * ``.nims`` -> ``nim e --trace:<...>/trace.ct`` (``:119-141``), where the
  #                  Nim VM emits the container itself -- an instrumented
  #                  runtime, and genuinely materialized.
  # Both call ``importTrace(..., LangNim, ...)``, so `Lang` cannot tell them
  # apart.  ``true`` is kept here because it is what the tree does today and
  # this milestone changes no behaviour; the split lives on the axes, where the
  # pair is `tiNative`/`raMcr` versus `tiNimVm`/`raInstrumentedRuntime`.
  of LangNim: true
  of LangRubyDb, LangPythonDb: true
  of LangNoir: true
  of LangRustWasm, LangCppWasm: true
  of LangSolidity, LangMasm, LangSway, LangMove, LangPolkavm, LangCairo,
     LangCircom, LangLeo, LangTolk, LangAiken, LangCadence, LangSolana: true
  of LangBash, LangZsh: true
  of LangJavascript: true
  of LangElixir, LangErlang, LangPhp: true
  of LangC, LangCpp, LangRust, LangGo, LangPascal, LangFortran, LangD,
     LangCrystal, LangLean, LangJulia, LangAda: false
  of LangPython, LangRuby, LangLua, LangAsm: false
  of LangUnknown: false

func toCLang*(lang: Lang): string =
  ## convert Lang_ to string
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
  of LangCppWasm: "c++"
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
     LangErlang, LangPhp:
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
     LangErlang, LangPhp:
    @[]

proc toLang*(lang: string): Lang
proc toLang*(lang: cstring): Lang

proc usesMaterializedTracesForExtension*(extension: string): bool =
  ## Return true if the file extension belongs to a language that produces
  ## materialized traces.
  let lang = toLang(extension)
  usesMaterializedTraces(lang)
