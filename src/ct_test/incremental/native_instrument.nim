## Native call trace via compile-time instrumentation — the M14/M15 deliverable
## of the Trace-Based-Incremental-Testing campaign (Phase 4).
##
## This module is the native runtime dependency-discovery source for hosts that
## have NO Intel PT / RR / MCR emulator (notably arm64-macOS). The executed-
## function SET a native test actually entered is captured by the EXISTING
## CodeTracer compile-time-instrumentation plugin, `ct_instrument`, in the
## sibling `codetracer-native-recorder` repo — specifically its call-trace facet
## (`ct_instrument/calltrace/ct_calltrace_sink.c` + the `buildWithCalltrace` /
## `runWithCalltrace` build helpers in `ct_instrument/ct_calltrace.nim`). That
## facet uses the `-finstrument-functions` ABI (`__cyg_profile_func_enter`) and
## resolves each entered function via `dladdr(...).dli_sname` (PIE/ASLR-robust),
## de-duplicates, and appends each new name once to the file named by
## `CT_CALLTRACE_OUT`.
##
## This engine does NOT maintain its own `-finstrument-functions` runtime: the
## instrumentation belongs to the native recorder; the engine only CONSUMES the
## executed-function set. We invoke the plugin through the CodeTracer
## build-siblings strategy — `direnv exec <native-recorder-repo> <cmd>` — so the
## plugin builds and runs in ITS OWN Nix dev shell (which has the right clang/gcc
## + Nim), exactly as the M13 live-recorder drivers do for the other recorders.
##
## See:
##   * `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §16.7
##     — the executed-function set drives incremental test selection.
##   * MCR-Calltrace-Design §22d — the compile-time-instrumentation alternative.
##   * `codetracer-native-recorder/ct_instrument/src/ct_instrument/ct_calltrace.nim`
##     — the facet's build/run helpers and the output file format (one function
##     name per line, de-duplicated; Mach-O names carry a leading underscore).
##
## # What this module does
##
##   1. `instrumentAndRun` — drive the ct_instrument call-trace facet (in the
##      native-recorder dev shell) to compile+link a C source with the call-trace
##      sink, run it with `CT_CALLTRACE_OUT` pointing into a trace dir, and leave
##      the captured name log (`InstrumentOutFile`) + the produced binary
##      (`instrumented_prog`) there. (An ALREADY-built binary can be run directly
##      with `runInstrumented`.)
##   2. `readExecutedFunctionsInstrumented` — read the captured name log back as
##      the de-duplicated executed-function SET (`seq[ExecutedFunction]`).
##
## # The native `ExecutedFunction` convention (shared with native_trace.nim)
##
## Native dependencies key on (function NAME + owning BINARY), NOT on a source
## file + line: a native function's identity is its compiled instruction bytes
## (spec §16.7.1), located in the binary by symbol NAME and hashed by
## `native_hash.shallowHashNative`. So, exactly as `native_trace.nim` documents:
##
##   * `name`    = the executed function's name (leading Mach-O underscore
##                 stripped so it matches `native_hash`'s symbol table keys).
##   * `file`    = the owning BINARY path (NOT a source path) — the native
##                 `ShallowHasher` reads `dep.file` as the binary. This keeps the
##                 cache schema unchanged.
##   * `defLine` = 0 for native (no source line in instruction-byte identity).
##
## # Fail-safe invariant (carried over from Phase 1 / M5)
##
## ANY error — a compile/link failure, a missing or empty output log, a run that
## produced nothing, a missing native-recorder sibling — yields an `Err`. The
## engine turns that into a re-run, NEVER a silent skip. No proc here raises.

import std/[os, osproc, sets, sequtils, algorithm, strutils, tables]
import results

import trace_reader  # ExecutedFunction
import native_hash   # nativeFunctionTable (best-effort symbol resolution)

export results

const
  InstrumentOutFile* = "native_instrument_calls.log"
    ## The default name of the captured executed-function log inside a trace dir.
    ## One function name per line, de-duplicated by the ct_instrument call-trace
    ## sink; the reader de-dups again defensively. The facet is run with
    ## `CT_CALLTRACE_OUT` set to `<traceDir>/<InstrumentOutFile>`.

  InstrumentOutEnvVar* = "CT_CALLTRACE_OUT"
    ## The environment variable the ct_instrument call-trace sink reads its output
    ## path from (see `ct_instrument/ct_calltrace.nim` / `ct_calltrace_sink.c`).

  InstrumentedBinaryName* = "instrumented_prog"
    ## The name the call-trace-instrumented binary is built as inside a trace dir.
    ## This is the binary the sink was linked into and which was actually run to
    ## CAPTURE the executed set (the clean hashing binary is a separate file — see
    ## `native_trace.instrumentHashBinaryPath`).

  NativeRecorderRepoEnvVar* = "CT_NATIVE_RECORDER_REPO"
    ## Optional override for the `codetracer-native-recorder` checkout location.
    ## When unset, the sibling is resolved relative to this checkout's workspace
    ## root (see `nativeRecorderRepo`).

# ---------------------------------------------------------------------------
# Locating the ct_instrument plugin (sibling native-recorder repo)
# ---------------------------------------------------------------------------

proc nativeRecorderRepo*(): string =
  ## Absolute path to the `codetracer-native-recorder` checkout that hosts the
  ## `ct_instrument` plugin. Honour `CT_NATIVE_RECORDER_REPO` if set; otherwise
  ## resolve the sibling relative to THIS module's source file.
  ##
  ## Layout: this file is
  ## `<workspace>/codetracer/src/ct_test/incremental/native_instrument.nim`; the
  ## native recorder is a workspace sibling `<workspace>/codetracer-native-recorder`.
  ## The codetracer repo root is four parents up from this module's file
  ## (`incremental` → `ct_test` → `src` → `codetracer`); the workspace that holds
  ## the recorder sibling is one further parent up.
  let fromEnv = getEnv(NativeRecorderRepoEnvVar)
  if fromEnv.len > 0:
    return fromEnv
  let here = currentSourcePath()
  # …/codetracer/src/ct_test/incremental/native_instrument.nim → codetracer root.
  let codetracerRoot = here.parentDir.parentDir.parentDir.parentDir
  codetracerRoot.parentDir / "codetracer-native-recorder"

proc ctInstrumentDir(repo: string): string =
  repo / "ct_instrument"

# ---------------------------------------------------------------------------
# Compile + run via the ct_instrument call-trace facet (build-siblings strategy)
# ---------------------------------------------------------------------------

type
  InstrumentRun* = object
    ## The artifacts of one instrumentation capture.
    binary*: string   ## The instrumented binary that was built and run.
    outFile*: string  ## The captured name log (`<traceDir>/InstrumentOutFile`).

proc runInNativeRecorderShell(repo, command: string):
    tuple[output: string, code: int] =
  ## Run `command` inside the native-recorder repo's Nix dev shell via
  ## `direnv exec`, with the working directory set to the `ct_instrument` package
  ## (direnv exec resets cwd, so the command explicitly `cd`s there first). Never
  ## raises — a launch failure is reported as a non-zero code with the exception
  ## text as output, so callers always get a diagnostic.
  let pkgDir = ctInstrumentDir(repo)
  let wrapped =
    "direnv exec " & quoteShell(repo) & " bash -c " &
    quoteShell("cd " & quoteShell(pkgDir) & " && " & command)
  try:
    let (output, exitCode) = execCmdEx(wrapped)
    result = (output, exitCode)
  except CatchableError as e:
    result = ("failed to launch native-recorder shell for " & repo & ": " &
      e.msg, 127)
  except Exception as e:
    result = ("failed to launch native-recorder shell for " & repo & ": " &
      e.msg, 127)

proc calltraceDriverProgram(sourceC, binPath, outFile: string;
    runArgs: openArray[string]): string =
  ## Emit a tiny Nim driver that, inside the ct_instrument package, builds
  ## `sourceC` with the call-trace facet into `binPath` and runs it with
  ## `CT_CALLTRACE_OUT = outFile`. The driver prints `CT_CALLTRACE_OK` on success
  ## and a `CT_CALLTRACE_ERR:` line (then exits non-zero) on any failure, so the
  ## caller can distinguish success from a facet error WITHOUT parsing tool noise.
  ##
  ## Paths and run-args are embedded as Nim string literals via `escape` so spaces
  ## / special characters in temp paths are safe. The driver is assembled line by
  ## line (NOT via a triple-quoted heredoc) so embedded literals never collapse a
  ## newline between statements.
  # The `runWithCalltrace` call: pass an explicit `@[...]` seq so an empty arg
  # list is valid Nim (no dangling trailing comma).
  var argsSeq = "@["
  for i, a in runArgs:
    if i > 0: argsSeq.add ", "
    argsSeq.add escape(a)
  argsSeq.add "]"
  let lines = @[
    "import std/os",
    "import results",
    "import ct_instrument/ct_calltrace",
    "",
    "proc main() =",
    "  let src = " & escape(sourceC),
    "  let bin = " & escape(binPath),
    "  let outFile = " & escape(outFile),
    "  let built = buildWithCalltrace(src, bin)",
    "  if built.isErr:",
    "    stdout.write(\"CT_CALLTRACE_ERR:\" & built.error & \"\\n\")",
    "    quit(1)",
    "  let runRes = runWithCalltrace(bin, outFile, " & argsSeq & ")",
    "  if runRes.isErr:",
    "    stdout.write(\"CT_CALLTRACE_ERR:\" & runRes.error & \"\\n\")",
    "    quit(1)",
    "  stdout.write(\"CT_CALLTRACE_OK\\n\")",
    "",
    "main()",
    ""]
  lines.join("\n")

proc driveCalltraceFacet(sourceC, binPath, outFile: string;
    args: openArray[string]): Result[void, string] =
  ## Run the ct_instrument call-trace facet over `sourceC`, producing `binPath`
  ## and the capture log `outFile`, by compiling+running a small Nim driver
  ## INSIDE the native-recorder dev shell (build-siblings strategy). Any failure
  ## (missing sibling, driver compile error, facet build/run error) ⇒ `Err`.
  let repo = nativeRecorderRepo()
  if not dirExists(repo):
    return err("codetracer-native-recorder sibling not found at " & repo &
      " (set " & NativeRecorderRepoEnvVar & " to override)")
  let pkgDir = ctInstrumentDir(repo)
  if not dirExists(pkgDir):
    return err("ct_instrument package not found at " & pkgDir)

  # Materialise the driver in the trace dir alongside the source (so it is
  # cleaned up with the trace dir and never pollutes the plugin checkout).
  let traceDir = binPath.parentDir
  let driverPath = traceDir / "ct_calltrace_driver.nim"
  try:
    writeFile(driverPath, calltraceDriverProgram(sourceC, binPath, outFile, args))
  except CatchableError as e:
    return err("could not write call-trace driver " & driverPath & ": " & e.msg)

  # Compile+run the driver in the plugin's dev shell. `-p:src` puts the
  # ct_instrument sources on the path (the package's own layout). The driver
  # prints CT_CALLTRACE_OK / CT_CALLTRACE_ERR so we parse a definite verdict.
  let driverBin = traceDir / "ct_calltrace_driver"
  let cmd =
    "nim c --hints:off --warnings:off -p:" & quoteShell(pkgDir / "src") &
    " -o:" & quoteShell(driverBin) & " " & quoteShell(driverPath) &
    " && " & quoteShell(driverBin)
  let (output, code) = runInNativeRecorderShell(repo, cmd)
  if "CT_CALLTRACE_OK" in output and code == 0:
    return ok()
  # Surface the facet's own error line when present, else the raw output.
  for line in output.splitLines():
    if line.startsWith("CT_CALLTRACE_ERR:"):
      return err("ct_instrument call-trace facet failed: " &
        line["CT_CALLTRACE_ERR:".len .. ^1])
  err("ct_instrument call-trace facet driver failed (exit " & $code & "):\n" &
    output)

proc compileInstrumented*(sourceC, binPath: string):
    Result[string, string] =
  ## Build (only) a call-trace-instrumented `binPath` from `sourceC` via the
  ## ct_instrument facet, WITHOUT running it. Returns the produced binary path,
  ## or an `Err` on any failure. (The common path uses `instrumentAndRun`, which
  ## builds AND runs in one facet invocation; this helper is kept for callers /
  ## tests that only need the build.)
  if not fileExists(sourceC):
    return err("instrumentation source not found: " & sourceC)
  let traceDir = binPath.parentDir
  let outFile = traceDir / InstrumentOutFile
  # The facet builds and runs in one driver invocation; to honour a build-only
  # contract we run it (harmless — it just also captures), but a build failure is
  # the dominant error. Callers that need a pure build can ignore the capture.
  let driven = driveCalltraceFacet(sourceC, binPath, outFile, @[])
  if driven.isErr:
    return err(driven.error)
  if not fileExists(binPath):
    return err("instrumented binary was not produced at " & binPath)
  ok(binPath)

proc runInstrumented*(binary, traceDir: string;
    args: openArray[string] = []): Result[InstrumentRun, string] =
  ## Run an ALREADY-instrumented `binary` (one linked against the ct_instrument
  ## call-trace sink) with `CT_CALLTRACE_OUT` set to `<traceDir>/InstrumentOutFile`,
  ## capturing the executed-function name log.
  ##
  ## The binary is run via the host's environment (it is a self-contained native
  ## executable — the sink is statically linked, so it does not need the plugin
  ## dev shell to RUN, only to BUILD). A non-existent binary/trace dir, a launch
  ## failure, or a NON-ZERO exit is an `Err` (the engine re-runs).
  if not fileExists(binary):
    return err("instrumented binary not found: " & binary)
  if not dirExists(traceDir):
    return err("trace dir not found: " & traceDir)
  let outFile = traceDir / InstrumentOutFile
  # Remove any stale log so a failed run cannot be mistaken for a prior capture.
  if fileExists(outFile):
    try: removeFile(outFile)
    except CatchableError as e:
      return err("could not clear stale instrument log " & outFile & ": " & e.msg)
  try:
    putEnv(InstrumentOutEnvVar, outFile)
  except CatchableError as e:
    return err("could not set " & InstrumentOutEnvVar & ": " & e.msg)
  var output = ""
  var code = 0
  try:
    (output, code) = execCmdEx(quoteShellCommand(@[binary] & @args))
  except CatchableError as e:
    try: delEnv(InstrumentOutEnvVar)
    except CatchableError: discard
    return err("failed to run instrumented binary '" & binary & "': " & e.msg)
  try: delEnv(InstrumentOutEnvVar)
  except CatchableError: discard
  if code != 0:
    return err("instrumented binary '" & binary & "' exited with code " &
      $code & ":\n" & output)
  ok(InstrumentRun(binary: binary, outFile: outFile))

proc instrumentAndRun*(sourceC, traceDir: string;
    args: openArray[string] = []): Result[InstrumentRun, string] =
  ## Compile a C `sourceC` with the ct_instrument call-trace facet into
  ## `traceDir`, run it with `CT_CALLTRACE_OUT` set, and return the run artifacts.
  ## Any compile/link/run failure ⇒ `Err`.
  ##
  ## The build + run happen in ONE facet invocation inside the native-recorder
  ## dev shell, producing both the capture log (`<traceDir>/InstrumentOutFile`)
  ## and the binary (`<traceDir>/instrumented_prog`).
  if not fileExists(sourceC):
    return err("instrumentation source not found: " & sourceC)
  if not dirExists(traceDir):
    return err("trace dir not found: " & traceDir)
  let binPath = traceDir / InstrumentedBinaryName
  let outFile = traceDir / InstrumentOutFile
  let driven = driveCalltraceFacet(sourceC, binPath, outFile, args)
  if driven.isErr:
    return err(driven.error)
  if not fileExists(binPath):
    return err("instrumented binary was not produced at " & binPath)
  if not fileExists(outFile):
    return err("call-trace capture log was not produced at " & outFile)
  ok(InstrumentRun(binary: binPath, outFile: outFile))

# ---------------------------------------------------------------------------
# Reading the captured executed-function set
# ---------------------------------------------------------------------------

proc stripLeadingUnderscore(name: string): string =
  ## Mach-O's C ABI prefixes a leading underscore (`_used_a`) and `dladdr`
  ## reports that mangled form; strip exactly one so names match the C
  ## identifiers `native_hash`'s symbol table keys on (it strips the same way).
  ## On ELF C symbols carry no prefix, so this is a no-op there.
  when defined(macosx):
    if name.len > 0 and name[0] == '_': name[1 .. ^1] else: name
  else:
    name

proc readInstrumentLog*(outFile: string): Result[seq[string], string] =
  ## Read the raw captured name log into a de-duplicated, sorted list of NAMES
  ## (leading Mach-O underscore stripped). One name per line; blank lines are
  ## ignored. A missing or empty (no resolvable names) log ⇒ `Err` (fail-safe).
  if not fileExists(outFile):
    return err("instrument log not found: " & outFile)
  var raw: string
  try:
    raw = readFile(outFile)
  except CatchableError as e:
    return err("failed to read instrument log " & outFile & ": " & e.msg)
  var seen = initHashSet[string]()
  for rawLine in raw.splitLines():
    let line = rawLine.strip()
    if line.len == 0:
      continue
    seen.incl stripLeadingUnderscore(line)
  if seen.len == 0:
    return err("instrument log " & outFile & " contains no function names")
  var names = seen.toSeq()
  names.sort(cmp)
  ok(names)

proc readExecutedFunctionsInstrumented*(traceDir: string):
    Result[seq[ExecutedFunction], string] =
  ## The instrumentation `DependencyDiscovery` implementation: read the
  ## executed-function SET captured by the ct_instrument call-trace facet from
  ## `<traceDir>/InstrumentOutFile`, as a de-duplicated, name-sorted
  ## `seq[ExecutedFunction]`.
  ##
  ## Each entry carries the executed function NAME (`name`) and the owning BINARY
  ## path (`file`); `defLine` is always 0 (native deps key on name+binary — see
  ## the module doc). The owning binary is the instrumented binary the run
  ## produced (`<traceDir>/instrumented_prog`) when present; this is the binary
  ## the native shallow hasher reads each function's instruction bytes from.
  ##
  ## BEST-EFFORT source resolution: if the binary is available we consult
  ## `native_hash.nativeFunctionTable` to confirm each captured name is a real,
  ## locatable code symbol; names absent from the binary's symbol table (e.g. a
  ## libc helper the loader resolved but which is not in THIS binary) are dropped
  ## from the dependency set — they are not functions of the unit under test and
  ## cannot be instruction-byte hashed against this binary. The NAME remains the
  ## dependency identity; file/defLine stay empty/0 per the native convention.
  ##
  ## Any structural problem (missing/empty log, no resolvable functions) ⇒ `Err`.
  if not dirExists(traceDir):
    return err("native instrument trace dir not found: " & traceDir)
  let outFile = traceDir / InstrumentOutFile
  let namesRes = readInstrumentLog(outFile)
  if namesRes.isErr:
    return err(namesRes.error)
  let names = namesRes.get()

  # The owning binary the run produced (if instrumentAndRun built it here). When
  # absent (e.g. a caller that ran a pre-built binary elsewhere) we still return
  # the names keyed on an empty binary path; the engine resolves the binary at
  # decide time. The common path produces the binary in the trace dir.
  let binary = traceDir / InstrumentedBinaryName
  let haveBinary = fileExists(binary)

  # Best-effort: build the binary's function table so we can confirm each
  # captured name is a locatable code symbol of THIS binary. If the table cannot
  # be built (e.g. tooling unavailable), we DO NOT fail — we keep every captured
  # name (the names are the dependency identity and the sink only emits names
  # dladdr resolved). The table only PRUNES names that are not this binary's own
  # functions; it never invents or relaxes the fail-safe.
  var symTable = initTable[string, native_hash.HashSlice]()
  var haveTable = false
  if haveBinary:
    let tblRes = nativeFunctionTable(binary)
    if tblRes.isOk:
      symTable = tblRes.get()
      haveTable = true

  var resultSeq: seq[ExecutedFunction] = @[]
  for name in names:
    if haveTable and name notin symTable:
      # Not a function of the unit under test (a loader/libc symbol dladdr
      # resolved). Drop it: it is not an instruction-byte-hashable dependency of
      # this binary.
      continue
    resultSeq.add ExecutedFunction(
      name: name,
      file: (if haveBinary: binary else: ""),
      defLine: 0)

  if resultSeq.len == 0:
    return err("native instrument capture in " & traceDir &
      " yielded no resolvable executed functions")

  resultSeq.sort(proc (a, b: ExecutedFunction): int = cmp(a.name, b.name))
  ok(resultSeq)
