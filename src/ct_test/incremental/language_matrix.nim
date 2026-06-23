## Language → strategy matrix — the M10 deliverable of the
## Trace-Based-Incremental-Testing prototype campaign (the final milestone of
## Phase 2).
##
## This module makes "all CodeTracer languages" concrete: a single dispatch
## table, `languageStrategy(lang)`, mapping every language CodeTracer supports
## to the incremental-testing strategy it implies — its expected
## `TraceBackend`, its dependency-discovery mechanism, and its shallow-hash
## mechanism. The authoritative language list is the CodeTracer
## **Language-Support-Matrix** (`codetracer-specs/Language-Support-Matrix.md`,
## "Last updated: March 2026"); every entry here cites it (see `matrixCitation`).
##
## # The two MECHANISM groups (spec §16.7 + the Phase-2 overview)
##
## CodeTracer has exactly TWO incremental-testing mechanisms, differing on BOTH
## axes (dependency discovery AND shallow hashing):
##
##   * SOURCE / interpreted (`tbSourceInterpreted`): the trace carries canonical
##     `Function`/`Call` records; a function's identity is its SOURCE TEXT. The
##     Language-Support-Matrix's *interpreted* languages take this path:
##     Python, Ruby, JavaScript, TypeScript, Lua, and WASM.
##   * NATIVE / MCR (`tbNativeDwarf`): the trace is an RR/MCR + DWARF capture with
##     NO `Function`/`Call` records; a function's identity is its COMPILED
##     INSTRUCTION BYTES. The Language-Support-Matrix's *system / DWARF-based*
##     languages take this path: C, C++, Rust, Go, Pascal, D, Fortran, Ada,
##     Crystal, Odin, V (plus Lean and Julia, which the matrix records as native
##     DWARF/rr captures with partial value extraction).
##
## # Nim is DUAL — and the table is ADVISORY, not authoritative
##
## Nim is the one language recordable BOTH ways: the materialized-source path
## (`tbSourceInterpreted`) AND the compiled-via-C native path (`tbNativeDwarf`).
## Its table entry is therefore modelled as DUAL (both backends are valid) and it
## records NEITHER single backend as "the" backend.
##
## CRUCIALLY: this table is **informational / advisory**. The engine NEVER picks
## a backend from the language name — `backends.detectBackend(traceDir)` inspects
## the actual trace and is the SINGLE SOURCE OF TRUTH for which strategy runs.
## The table exists for REPORTING and VALIDATION (e.g. "this Rust test is
## expected to use the native path; warn if its trace detected as source"), and
## to prove, at compile time and in tests, that every matrix language is
## classified into one of the two mechanisms. Because Nim genuinely depends on
## the trace, modelling it as a single backend here would create a second source
## of truth that could DRIFT from `detectBackend`; modelling it as DUAL keeps the
## table honest and defers the real choice to `detectBackend`, where it belongs.
##
## # Fail-safe (carried over from Phase 1 / M5)
##
## An unknown / unsupported language yields an `Err` from `languageStrategy`
## (NEVER a guessed strategy, NEVER a wrong hash, NEVER a silent skip). A caller
## that cannot classify a language must conservatively re-run — exactly as the
## engine does for an ambiguous trace.

import std/[strutils, tables, algorithm]
import results

import backends

export results
export backends

type
  LanguageMechanism* = enum
    ## Which of the two incremental-testing MECHANISMS a language uses. This is
    ## the coarse classification the table guarantees is total over the matrix.
    lmSourceInterpreted
      ## Source / interpreted path: canonical `Function`/`Call` dependency
      ## discovery + source-text shallow hash (`tbSourceInterpreted`).
    lmNativeDwarf
      ## Native / MCR path: native-calltrace dependency discovery +
      ## instruction-byte shallow hash (`tbNativeDwarf`).
    lmDual
      ## Recordable BOTH ways (Nim). The actual mechanism is chosen per-trace by
      ## `detectBackend`; this table does not pin one.

  DependencyDiscoveryKind* = enum
    ## The dependency-discovery mechanism a language's strategy implies
    ## (descriptive label; the running impl is the seam in `backendStrategies`).
    ddCanonicalFunctionCall
      ## Executed set = the `Function` records referenced by `Call` records in a
      ## canonical `trace.json` (source path; `trace_reader.readExecutedFunctions`).
    ddNativeCalltrace
      ## Executed set = the function names in a native trace's calltrace
      ## (`native_trace.readExecutedFunctionsNative`).
    ddPerTrace
      ## Dual (Nim): whichever of the above the detected backend selects.

  ShallowHashKind* = enum
    ## The shallow-hash mechanism a language's strategy implies.
    shSourceText
      ## Hash of the function's body SOURCE TEXT (Phase-1 extractors).
    shInstructionBytes
      ## Hash of the function's COMPILED INSTRUCTION BYTES
      ## (`native_hash.shallowHashNative`).
    shPerTrace
      ## Dual (Nim): whichever of the above the detected backend selects.

  LanguageStrategy* = object
    ## The advisory incremental-testing strategy for one CodeTracer language.
    ##
    ## `mechanism` is the coarse group; `backends` lists the expected
    ## `TraceBackend`(s) (one for the single-mechanism languages, BOTH for Nim);
    ## `discovery` / `shallowHash` name the implied mechanisms; `matrixCitation`
    ## records WHERE in the Language-Support-Matrix this classification comes from
    ## (so a reviewer can audit it and a test can assert every entry is cited).
    language*: string
    mechanism*: LanguageMechanism
    backends*: seq[TraceBackend]
    discovery*: DependencyDiscoveryKind
    shallowHash*: ShallowHashKind
    matrixCitation*: string
      ## A human-readable citation into `codetracer-specs/`
      ## `Language-Support-Matrix.md` justifying the mechanism classification.

const
  MatrixDoc* = "codetracer-specs/Language-Support-Matrix.md"
    ## The authoritative source for the supported-language list + recorders.

func sourceStrategy(language, citation: string): LanguageStrategy =
  ## Build a SOURCE/interpreted strategy entry.
  LanguageStrategy(
    language: language,
    mechanism: lmSourceInterpreted,
    backends: @[tbSourceInterpreted],
    discovery: ddCanonicalFunctionCall,
    shallowHash: shSourceText,
    matrixCitation: citation)

func nativeStrategy(language, citation: string): LanguageStrategy =
  ## Build a NATIVE/MCR strategy entry.
  LanguageStrategy(
    language: language,
    mechanism: lmNativeDwarf,
    backends: @[tbNativeDwarf],
    discovery: ddNativeCalltrace,
    shallowHash: shInstructionBytes,
    matrixCitation: citation)

func dualStrategy(language, citation: string): LanguageStrategy =
  ## Build a DUAL (Nim) strategy entry — both backends valid, the actual one
  ## chosen per-trace by `detectBackend` (the table does NOT pin one).
  LanguageStrategy(
    language: language,
    mechanism: lmDual,
    backends: @[tbSourceInterpreted, tbNativeDwarf],
    discovery: ddPerTrace,
    shallowHash: shPerTrace,
    matrixCitation: citation)

# ---------------------------------------------------------------------------
# The dispatch table
# ---------------------------------------------------------------------------
#
# Every language in `codetracer-specs/Language-Support-Matrix.md` (the "Platform
# Support Overview" + "Recording Backends by Language" tables) is classified
# here into one of the two mechanisms (or DUAL, for Nim). Citations point at the
# specific matrix evidence for each classification so the table can be audited
# against the spec and re-validated when the matrix changes.

let languageTable: Table[string, LanguageStrategy] = block:
  var t = initTable[string, LanguageStrategy]()

  proc add(s: LanguageStrategy) =
    # Languages are keyed by their lowercased name; aliases are added explicitly.
    t[s.language.toLowerAscii()] = s

  # --- SOURCE / interpreted group ---------------------------------------------
  # The Language-Support-Matrix lists these under interpreted-language support;
  # their recorders emit canonical Function/Call trace records (Phase-1 path).
  add sourceStrategy("Python",
    MatrixDoc & " — Python: Supported on Linux, recorded by the Python recorder " &
    "(interpreted; canonical Function/Call records). Platform Support Overview row 'Python'.")
  add sourceStrategy("Ruby",
    MatrixDoc & " — Ruby: Supported on Linux, recorded by the Ruby recorder " &
    "(interpreted; canonical Function/Call records). Platform Support Overview row 'Ruby'.")
  add sourceStrategy("JavaScript",
    MatrixDoc & " — JavaScript: Planned, JS recorder (interpreted; canonical " &
    "Function/Call records). Platform Support Overview row 'JavaScript'.")
  add sourceStrategy("TypeScript",
    MatrixDoc & " — TypeScript: traced via the JavaScript recorder (TS compiles/" &
    "runs as JS; interpreted; canonical Function/Call records). Classified with " &
    "the 'JavaScript' Platform Support Overview row.")
  add sourceStrategy("Lua",
    MatrixDoc & " — Lua: Planned, Lua recorder (interpreted; canonical " &
    "Function/Call records). Platform Support Overview row 'Lua'.")
  add sourceStrategy("WASM",
    MatrixDoc & " — WASM: recorded by the Wasm/wasmi recorders (managed-runtime; " &
    "canonical Function/Call records, NOT native machine code). Classified with " &
    "the interpreted/managed group (the Wasm recorders, listed in the CodeTracer " &
    "Language-Support recorder set).")

  # --- NATIVE / MCR group (DWARF-based system languages) -----------------------
  # The Language-Support-Matrix's "Recording Backends by Language → Linux: RR +
  # LLDB/GDB" table shows these are recorded via rr + DWARF (native machine code).
  add nativeStrategy("C",
    MatrixDoc & " — C: LLDB + DWARF, rr-recorded native (Recording Backends by " &
    "Language → Linux row 'C'; Platform Support Overview row 'C': Supported).")
  add nativeStrategy("C++",
    MatrixDoc & " — C++: LLDB + DWARF, rr-recorded native (Recording Backends by " &
    "Language → Linux row 'C++'; Platform Support Overview row 'C++').")
  add nativeStrategy("Rust",
    MatrixDoc & " — Rust: LLDB + DWARF, custom Rust value loader, rr-recorded " &
    "native (Recording Backends → Linux row 'Rust'; Overview row 'Rust').")
  add nativeStrategy("Go",
    MatrixDoc & " — Go: Delve + DWARF, rr-recorded native (Recording Backends → " &
    "Linux row 'Go'; Overview row 'Go').")
  add nativeStrategy("Pascal",
    MatrixDoc & " — Pascal: LLDB + DWARF, rr-recorded native (Recording Backends " &
    "→ Linux row 'Pascal'; Overview row 'Pascal').")
  add nativeStrategy("D",
    MatrixDoc & " — D: LLDB + DWARF, rr-recorded native (Recording Backends → " &
    "Linux row 'D'; Overview row 'D').")
  add nativeStrategy("Fortran",
    MatrixDoc & " — Fortran: GDB + DWARF, rr-recorded native (Recording Backends " &
    "→ Linux row 'Fortran'; Overview row 'Fortran').")
  add nativeStrategy("Ada",
    MatrixDoc & " — Ada: GDB + DWARF + GNAT encodings, rr-recorded native " &
    "(Recording Backends → Linux row 'Ada'; Overview row 'Ada').")
  add nativeStrategy("Crystal",
    MatrixDoc & " — Crystal: LLDB + DWARF, rr-recorded native (Recording Backends " &
    "→ Linux row 'Crystal'; Overview row 'Crystal').")
  add nativeStrategy("Odin",
    MatrixDoc & " — Odin: LLDB + DWARF, rr-recorded native (Recording Backends → " &
    "Linux row 'Odin'; Overview row 'Odin').")
  add nativeStrategy("V",
    MatrixDoc & " — V: LLDB + DWARF (via C backend), rr-recorded native " &
    "(Recording Backends → Linux row 'V'; Overview row 'V').")
  add nativeStrategy("Lean",
    MatrixDoc & " — Lean: LLDB + DWARF (via C backend), rr-recorded native " &
    "(Recording Backends → Linux row 'Lean'; Overview row 'Lean': Partial value " &
    "extraction — still the native machine-code path).")
  add nativeStrategy("Julia",
    MatrixDoc & " — Julia: LLDB + DWARF, rr-recorded native (Recording Backends → " &
    "Linux row 'Julia'; Overview row 'Julia': Partial — native capture).")
  add nativeStrategy("Assembly",
    MatrixDoc & " — Assembly: Partial; recorded as native machine code (rr/DWARF; " &
    "Platform Support Overview row 'Assembly'). Instruction-byte hashing is the " &
    "natural identity for hand-written assembly.")

  # --- DUAL (Nim) --------------------------------------------------------------
  # Nim is recordable BOTH ways. The matrix lists it as "DWARF (via C backend)"
  # for the native path; CodeTracer also supports Nim's materialized-source path.
  # The table does NOT pin a backend — detectBackend chooses per trace.
  add dualStrategy("Nim",
    MatrixDoc & " — Nim: DWARF (via C backend) native path (Recording Backends → " &
    "Linux row 'Nim') AND a materialized-source path. DUAL: detectBackend selects " &
    "per trace. Overview row 'Nim': Supported.")

  t

# ---------------------------------------------------------------------------
# Public lookup
# ---------------------------------------------------------------------------

func normalizeLanguage(lang: string): string =
  ## Canonicalise a language name for lookup: trim, lowercase, and accept a few
  ## common aliases/spellings so callers passing a recorder or file-type label
  ## still resolve. Unknown spellings fall through to an `Err` in
  ## `languageStrategy` (NEVER a guess).
  let s = lang.strip().toLowerAscii()
  case s
  of "c++", "cpp", "cxx": "c++"
  of "js", "javascript", "ecmascript": "javascript"
  of "ts", "typescript": "typescript"
  of "wasm", "webassembly", "wat": "wasm"
  of "golang": "go"
  of "asm", "assembly": "assembly"
  else: s

proc supportedLanguages*(): seq[string] =
  ## The canonical (lowercased) language keys in the table, sorted, for
  ## diagnostics, docs generation, and the matrix-coverage test.
  for k in languageTable.keys:
    result.add k
  result.sort()

proc languageStrategy*(lang: string): Result[LanguageStrategy, string] =
  ## Resolve a CodeTracer language name to its advisory `LanguageStrategy`.
  ##
  ## # Advisory, NOT authoritative
  ##
  ## The returned strategy is the EXPECTED mechanism for the language, suitable
  ## for reporting and validation. The engine still detects the REAL backend from
  ## the trace via `backends.detectBackend`, which is the single source of truth —
  ## see this module's header. For Nim (DUAL) the returned `backends` lists BOTH
  ## valid backends precisely because the language alone cannot decide.
  ##
  ## # Fail-safe
  ##
  ## An unknown / unsupported language is an `Err` (NEVER a guessed strategy). A
  ## caller that cannot classify a language must conservatively re-run, exactly as
  ## the engine does for an ambiguous trace — never a wrong hash, never a silent
  ## skip.
  let key = normalizeLanguage(lang)
  if key.len == 0:
    return err("empty language name; cannot resolve an incremental-testing strategy")
  if languageTable.hasKey(key):
    ok(languageTable[key])
  else:
    err("unsupported/unknown language '" & lang & "': no incremental-testing " &
      "strategy in the CodeTracer Language-Support-Matrix (" & MatrixDoc & "). " &
      "Conservatively re-run rather than guess a hash.")

func expectedBackends*(s: LanguageStrategy): seq[TraceBackend] =
  ## The `TraceBackend`(s) this language is EXPECTED to record as. One for a
  ## single-mechanism language; BOTH (`tbSourceInterpreted`, `tbNativeDwarf`) for
  ## Nim. Use this to VALIDATE a detected backend against the language's
  ## expectation — but remember `detectBackend` is authoritative; a mismatch is a
  ## reporting signal, not an override.
  s.backends

func backendIsExpected*(s: LanguageStrategy; detected: TraceBackend): bool =
  ## True iff `detected` (from `detectBackend`, the authoritative per-trace
  ## source of truth) is among this language's expected backends. A caller can
  ## use a `false` here to WARN that a trace was recorded via an unexpected path
  ## — it must NOT use it to override `detectBackend`.
  detected in s.backends
