## `ct test --incremental` — standalone trace-based incremental test selection.
##
## This is milestone M18 of the Trace-Based Incremental Testing campaign: it
## brings the runtime-dependency test-selection algorithm (spec
## `codetracer-specs/Planned-Features/Nim-Parallel-Test-Framework.md` §16.7) into
## CodeTracer's `ct test` WITHOUT reprobuild, on the CANONICAL engine under
## `incremental/` (codetracer owns the engine; reprobuild reaches it only through
## the engine-free `reprobuild-ct-test-runner` adapter — a one-way dependency).
##
## # What it does (§16.7.4 workflow)
##
## Given a test program for an interpreted language (Python or Ruby) OR a native
## C program, on each invocation it:
##
##   1. records a BASELINE trace of the program via the appropriate production
##      recorder, into a modern CTFS `.ct` bundle (stamped `ctfs-interpreted` so
##      the engine routes it through the SOURCE-TEXT shallow-hash backend);
##   2. extracts the executed-function set + per-function shallow hashes from the
##      bundle (the engine's `record`) and stores `{deepHash, deps}` in a cache;
##   3. on a SUBSEQUENT invocation, recomputes each cached dependency's shallow
##      hash from the CURRENT source and DECIDES skip-vs-rerun (`decide`): SKIP
##      when none of the executed functions changed, RE-RUN (naming the changed
##      functions) otherwise.
##
## # The fail-safe contract (carried over verbatim from the engine)
##
## The ONLY decision that skips is "unchanged". A missing/unreadable trace, an
## unsupported backend, an unreadable source file, or any hashing/extraction
## error routes to a re-run — NEVER a false skip. Recorder unavailability is an
## HONEST GATE: a language whose recorder cannot build/record on this host
## reports a loud, captured diagnostic and exits non-zero; it is never silently
## skipped.
##
## # Live-validated languages
##
## Python and Ruby record live via their production recorders (source-text
## shallow hashing over a CTFS `.ct` bundle). NATIVE C records live via the
## CodeTracer native recorder's compile-time call-trace instrumentation
## (`ct_instrument`, driven through the engine's `native_instrument` module): the
## executed-function SET is captured at runtime and the per-function change signal
## is the function's COMPILED INSTRUCTION BYTES (the engine's `tbNativeDwarf`
## backend). The native path is no longer rejected up front — the canonical
## engine now wires the native dependency-discovery + instruction-byte-hash seams
## (`native_trace`/`native_hash`/`native_instrument`), so a native trace decides
## skip-vs-rerun exactly like the source path, with the same fail-safe contract.
##
## Native recording drives the `ct_instrument` plugin in the
## `codetracer-native-recorder` sibling's own dev shell (resolved by the engine's
## `nativeRecorderRepo()`, overridable via `CT_NATIVE_RECORDER_REPO`). On a host
## without that sibling/toolchain, the native path reports an HONEST gate
## (non-zero exit + captured diagnostic) — never a silent skip.

import std/[os, osproc, strutils, times, tables]
import results

import incremental/engine
# Native recording drives the engine's compile-time-instrumentation seam
# (`instrumentAndRun`) and the recorded-binary naming conventions the native
# backend hashes against (`InstrumentedBinaryName`, `RecordedBinaryName`).
import incremental/native_instrument
import incremental/native_trace
# M2 (Incremental-Test-Runner): the per-test ROOT HASH + re-decide artifact. The
# CLI can additionally WRITE/UPDATE the per-test artifact file alongside the
# decision, reusing the engine's extraction + hashing via `buildArtifact`.
import incremental/root_hash

type
  IncrementalLanguage* = enum
    ## A language `ct test --incremental` can drive a recorder for. The
    ## interpreted languages (Python/Ruby) record a CTFS `.ct` bundle and hash
    ## source text; native C records via compile-time call-trace instrumentation
    ## and hashes the compiled instruction bytes (the engine's `tbNativeDwarf`
    ## backend).
    ilPython = "python"
    ilRuby = "ruby"
    ilNative = "native"

  IncrementalArgs* = object
    ## Parsed `ct test --incremental` arguments.
    language*: IncrementalLanguage
    program*: string        ## Path to the test program (`.py` / `.rb`).
    sourceRoot*: string     ## Root the engine resolves recorded paths under.
                            ## Defaults to "/" (recorded paths are absolute).
    cachePath*: string      ## Backing cache JSON. Defaults under the source root.
    testId*: string         ## Cache key. Defaults to the program's filename.
    writeArtifact*: bool    ## M2: also write/update the per-test root-hash artifact.
    artifactPath*: string   ## M2: artifact file path. Defaults under the source root.

  RecorderOutcomeKind = enum
    roSuccess  ## A real `.ct` bundle was produced.
    roGated    ## The recorder genuinely could not build/record on this host.

  RecorderOutcome = object
    case kind: RecorderOutcomeKind
    of roSuccess:
      traceDir: string  ## Directory holding the produced `.ct` bundle.
      ctPath: string    ## The produced `.ct` bundle itself.
    of roGated:
      diagnostic: string

const
  # Recorder sibling repos live next to the codetracer checkout in the workspace
  # (the CodeTracer build-siblings strategy). Resolved relative to THIS repo so
  # the CLI does not hard-code an absolute workspace path.
  RubyRecorderSubpath = "codetracer-ruby-recorder"
  PythonRecorderSubpath = "codetracer-python-recorder"
  NativeRecorderSubpath = "codetracer-native-recorder"

# ---------------------------------------------------------------------------
# Workspace / recorder-repo resolution
# ---------------------------------------------------------------------------

proc workspaceRoot(): string =
  ## The workspace dir that holds codetracer + the recorder repos as siblings.
  ## `getAppDir()` points at `<codetracer>/src/build-debug/bin`; the workspace is
  ## three levels up from the codetracer root. We instead derive it from the
  ## current executable's path by walking up to the dir that CONTAINS a
  ## `codetracer` sibling, falling back to the env override.
  let override = getEnv("CODETRACER_WORKSPACE_ROOT")
  if override.len > 0:
    return override
  # Walk up from the running binary looking for a dir whose parent holds the
  # recorder siblings. The binary lives at <ws>/codetracer/src/build-*/bin/ct.
  var dir = getAppDir()
  for _ in 0 .. 8:
    let parent = dir.parentDir
    if parent.len == 0 or parent == dir:
      break
    if dirExists(parent / PythonRecorderSubpath) or
        dirExists(parent / RubyRecorderSubpath) or
        dirExists(parent / NativeRecorderSubpath):
      return parent
    dir = parent
  # Fallback: the directory two levels above the source checkout.
  getCurrentDir()

proc runInRecorderShell(repo, command: string): tuple[output: string, code: int] =
  ## Run `command` inside `repo`'s Nix dev shell via `direnv exec` (the
  ## build-siblings strategy: each recorder builds/runs in its own toolchain).
  ## `direnv exec` resets cwd, so the command `cd`s into the repo first. Never
  ## raises: a launch failure is reported as a non-zero code with the exception
  ## text, so callers always get a diagnostic.
  let wrapped =
    "direnv exec " & quoteShell(repo) & " bash -c " &
    quoteShell("cd " & quoteShell(repo) & " && " & command)
  try:
    let (output, exitCode) = execCmdEx(wrapped)
    result = (output, exitCode)
  except CatchableError as e:
    result = ("failed to launch recorder shell for " & repo & ": " & e.msg, 127)
  except Exception as e:
    result = ("failed to launch recorder shell for " & repo & ": " & e.msg, 127)

var liveTempCounter = 0

proc freshLiveDir(prefix: string): string =
  ## A unique temp directory for a recording's CTFS output.
  inc liveTempCounter
  let stamp = (epochTime() * 1_000_000.0).int64
  let dir = getTempDir() / (prefix & $stamp & "_" & $liveTempCounter)
  createDir(dir)
  dir

proc findCtBundle(dir: string): string =
  ## Return the single `.ct` bundle in `dir`, or "" if absent/ambiguous.
  var found: seq[string]
  if dirExists(dir):
    for kind, path in walkDir(dir):
      if kind in {pcFile, pcLinkToFile} and path.toLowerAscii().endsWith(".ct"):
        found.add path
  if found.len == 1: found[0] else: ""

proc markCtfsInterpreted(traceDir: string) =
  ## Stamp an INTERPRETED-language CTFS trace dir with the explicit
  ## `recorder_backend: "ctfs-interpreted"` metadata signal, so the engine's
  ## `detectBackend` routes the bundle through the source-text shallow-hash
  ## backend (`tbSourceCtfs`) rather than the default native-`.ct` classification
  ## (instruction-byte hashing). Recorders for interpreted languages emit
  ## source-language CTFS, so this is the correct routing.
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"ctfs","recorder_backend":"ctfs-interpreted"}""")

# ---------------------------------------------------------------------------
# Per-recorder build + record drivers (build-once, no silent skips)
# ---------------------------------------------------------------------------

proc rubyRecorderBin(repo: string): string =
  repo / "gems/codetracer-ruby-recorder/bin/codetracer-ruby-recorder"

proc rubyRecorderBuilt(repo: string): bool =
  let targetRelease =
    repo / "gems/codetracer-ruby-recorder/ext/native_tracer/target/release"
  if not dirExists(targetRelease): return false
  for kind, path in walkDir(targetRelease):
    if kind in {pcFile, pcLinkToFile} and
        (path.endsWith(".dylib") or path.endsWith(".so") or
         path.endsWith(".bundle")):
      return true
  false

proc ensureRubyRecorderBuilt(repo: string): tuple[ok: bool, diagnostic: string] =
  if rubyRecorderBuilt(repo):
    return (true, "")
  let (output, code) = runInRecorderShell(repo, "just build")
  if code != 0 or not rubyRecorderBuilt(repo):
    return (false, "failed to build the native Ruby recorder (exit " & $code &
      "):\n" & output)
  (true, "")

proc recordRubyLive(repo, program: string): RecorderOutcome =
  let built = ensureRubyRecorderBuilt(repo)
  if not built.ok:
    return RecorderOutcome(kind: roGated, diagnostic: built.diagnostic)
  let outDir = freshLiveDir("ct_incremental_ruby_")
  let cmd =
    quoteShell(rubyRecorderBin(repo)) & " --out-dir " & quoteShell(outDir) &
    " " & quoteShell(program)
  let (output, code) = runInRecorderShell(repo, cmd)
  let bundle = findCtBundle(outDir)
  if bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "ruby recording produced no .ct bundle (exit " & $code &
        ") in " & outDir & ":\n" & output)
  markCtfsInterpreted(outDir)
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: bundle)

proc pythonVenvPython(repo: string): string =
  repo / ".venv/bin/python"

proc pythonRecorderBuilt(repo: string): bool =
  if not fileExists(pythonVenvPython(repo)):
    return false
  let pkgDir =
    repo / "codetracer-python-recorder/codetracer_python_recorder"
  if dirExists(pkgDir):
    for kind, path in walkDir(pkgDir):
      if kind in {pcFile, pcLinkToFile} and
          path.toLowerAscii().endsWith(".so") and
          "codetracer_python_recorder" in path.extractFilename.toLowerAscii():
        return true
  false

proc ensurePythonRecorderBuilt(repo: string): tuple[ok: bool, diagnostic: string] =
  if pythonRecorderBuilt(repo):
    return (true, "")
  let (output, code) = runInRecorderShell(repo, "just venv 3.13 dev")
  if code != 0 or not pythonRecorderBuilt(repo):
    return (false, "failed to build the Python recorder (exit " & $code &
      "):\n" & output)
  (true, "")

proc recordPythonLive(repo, program: string): RecorderOutcome =
  let built = ensurePythonRecorderBuilt(repo)
  if not built.ok:
    return RecorderOutcome(kind: roGated, diagnostic: built.diagnostic)
  let outDir = freshLiveDir("ct_incremental_python_")
  let cmd =
    quoteShell(pythonVenvPython(repo)) &
    " -m codetracer_python_recorder --out-dir " & quoteShell(outDir) &
    " " & quoteShell(program)
  let (output, code) = runInRecorderShell(repo, cmd)
  let bundle = findCtBundle(outDir)
  if bundle.len == 0:
    return RecorderOutcome(kind: roGated,
      diagnostic: "python recording produced no .ct bundle (exit " & $code &
        ") in " & outDir & ":\n" & output)
  markCtfsInterpreted(outDir)
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: bundle)

# ---------------------------------------------------------------------------
# Native (C) recording via compile-time call-trace instrumentation
# ---------------------------------------------------------------------------

proc markNativeInstrumented(traceDir: string) =
  ## Stamp a native compile-time-instrumentation trace dir with the explicit
  ## `recorder_backend: "native-instrumented"` metadata signal so the engine's
  ## `detectBackend` routes the dir through the native instruction-byte backend
  ## (`tbNativeDwarf`). The presence of `trace_db_metadata.json` is ALSO a native
  ## structural signal, so this is belt-and-suspenders; the explicit field makes
  ## the intent self-documenting.
  writeFile(traceDir / "trace_db_metadata.json",
    """{"format":"native-instrument","recorder_backend":"native-instrumented"}""")

proc recordNativeLive(program: string): RecorderOutcome =
  ## Record a native C `program` LIVE via the CodeTracer native recorder's
  ## compile-time call-trace instrumentation. Two artifacts land in the trace dir:
  ##
  ##   1. the EXECUTED-FUNCTION SET — captured by the `ct_instrument` call-trace
  ##      facet (`__cyg_profile_func_enter` + `dladdr`), driven through the
  ##      engine's `instrumentAndRun`. This builds + runs an instrumented binary
  ##      in the native-recorder dev shell and writes the de-duplicated name log.
  ##   2. a CLEAN (non-instrumented) binary of the SAME source, for SHALLOW
  ##      HASHING. Instrumentation injects pc-relative `__cyg_profile_func_*`
  ##      calls that make every function's bytes relocation-sensitive to unrelated
  ##      edits, so the native shallow hash must read the real, non-instrumented
  ##      production binary (see `native_trace.instrumentHashBinaryPath`). The M7
  ##      stability flags (`-O0 -g -fno-stack-protector
  ##      -fno-asynchronous-unwind-tables`) keep a function's bytes a function of
  ##      its OWN body only.
  ##
  ## Any compile/run/read failure is an HONEST GATE (`roGated` + the captured
  ## diagnostic) — never a silent skip. The recorded source lives INSIDE the trace
  ## dir, so the engine resolves the recorded binary from the trace, not a
  ## host-specific path.
  let outDir = freshLiveDir("ct_incremental_native_")
  let src = outDir / "prog.c"
  try:
    let original = readFile(program)
    writeFile(src, original)
  except CatchableError as e:
    return RecorderOutcome(kind: roGated,
      diagnostic: "could not stage native instrumentation source from " &
        program & ": " & e.msg)

  # (1) Discover the executed set via the ct_instrument call-trace facet.
  let runRes = instrumentAndRun(src, outDir)
  if runRes.isErr:
    return RecorderOutcome(kind: roGated,
      diagnostic: "native instrumentation compile/run failed: " & runRes.error)

  # (2) Build the clean (non-instrumented) binary the native shallow hash reads.
  let cleanBin = outDir / RecordedBinaryName
  let cc = (let e = getEnv("CC"); if e.len > 0: e else: "cc")
  let cleanCmd =
    quoteShell(cc) & " -O0 -g -fno-stack-protector " &
    "-fno-asynchronous-unwind-tables -o " & quoteShell(cleanBin) & " " &
    quoteShell(src)
  let (cleanOut, cleanCode) = execCmdEx(cleanCmd)
  if cleanCode != 0 or not fileExists(cleanBin):
    return RecorderOutcome(kind: roGated,
      diagnostic: "clean (non-instrumented) recorded binary build failed (exit " &
        $cleanCode & "):\n" & cleanOut)

  markNativeInstrumented(outDir)
  # ctPath carries the RECORDED BINARY (no `.ct` bundle on the native path; the
  # native flavour keys on the binary the native shallow hash reads).
  RecorderOutcome(kind: roSuccess, traceDir: outDir, ctPath: cleanBin)

proc recordLive(args: IncrementalArgs; ws: string): RecorderOutcome =
  ## Dispatch a live baseline recording to the language's production recorder.
  case args.language
  of ilPython:
    recordPythonLive(ws / PythonRecorderSubpath, args.program)
  of ilRuby:
    recordRubyLive(ws / RubyRecorderSubpath, args.program)
  of ilNative:
    # The native path resolves the `ct_instrument` plugin via the engine's
    # `nativeRecorderRepo()` (honouring `CT_NATIVE_RECORDER_REPO`), so it does
    # NOT consult `ws`. `program` is a C source the recorder compiles + runs.
    recordNativeLive(args.program)

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

proc parseLanguage(s: string): Result[IncrementalLanguage, string] =
  case s.toLowerAscii()
  of "python", "py": ok(ilPython)
  of "ruby", "rb": ok(ilRuby)
  of "native", "c": ok(ilNative)
  of "cpp", "c++", "rust", "go":
    err("language '" & s & "' is not yet wired into `ct test --incremental` " &
      "(the canonical engine's native instruction-byte backend supports it, but " &
      "the CLI currently drives only C through the native call-trace recorder). " &
      "Wired languages: python, ruby, native (C).")
  else:
    err("unknown language '" & s & "' (expected: python, ruby, native)")

proc usage(): string =
  "usage: ct test --incremental --language <python|ruby|native> --program <path> " &
  "[--source-root DIR] [--cache PATH] [--id TESTID] " &
  "[--write-artifact] [--artifact PATH]"

proc takeValue(args: seq[string]; i: var int; flag: string):
    Result[string, string] =
  let arg = args[i]
  let prefix = flag & "="
  if arg.startsWith(prefix):
    return ok(arg[prefix.len .. ^1])
  if arg == flag:
    if i + 1 >= args.len:
      return err(flag & " requires a value")
    inc i
    return ok(args[i])
  err("internal parse error for " & flag)

proc parseIncrementalArgs*(args: seq[string]): Result[IncrementalArgs, string] =
  ## Parse the post-`--incremental` argument list. The `--incremental` flag
  ## itself is consumed by the caller; everything else is parsed here.
  var res = IncrementalArgs(sourceRoot: "/")
  var langSet = false
  var i = 0
  while i < args.len:
    let arg = args[i]
    if arg == "--language" or arg.startsWith("--language="):
      let v = takeValue(args, i, "--language")
      if v.isErr: return err(v.error)
      let lang = parseLanguage(v.value)
      if lang.isErr: return err(lang.error)
      res.language = lang.value
      langSet = true
    elif arg == "--program" or arg.startsWith("--program="):
      let v = takeValue(args, i, "--program")
      if v.isErr: return err(v.error)
      res.program = v.value
    elif arg == "--source-root" or arg.startsWith("--source-root="):
      let v = takeValue(args, i, "--source-root")
      if v.isErr: return err(v.error)
      res.sourceRoot = v.value
    elif arg == "--cache" or arg.startsWith("--cache="):
      let v = takeValue(args, i, "--cache")
      if v.isErr: return err(v.error)
      res.cachePath = v.value
    elif arg == "--id" or arg.startsWith("--id="):
      let v = takeValue(args, i, "--id")
      if v.isErr: return err(v.error)
      res.testId = v.value
    elif arg == "--write-artifact":
      # M2: a bare flag — enable artifact writing at the default path. An
      # explicit path is given via the separate `--artifact PATH` flag.
      res.writeArtifact = true
    elif arg == "--artifact" or arg.startsWith("--artifact="):
      # M2: an explicit artifact path also implies `--write-artifact`.
      let v = takeValue(args, i, "--artifact")
      if v.isErr: return err(v.error)
      res.artifactPath = v.value
      res.writeArtifact = true
    else:
      return err("unknown argument: " & arg)
    inc i
  if not langSet:
    return err("--language is required")
  if res.program.len == 0:
    return err("--program is required")
  if not fileExists(res.program):
    return err("--program does not exist: " & res.program)
  if res.testId.len == 0:
    res.testId = res.program.extractFilename
  if res.cachePath.len == 0:
    res.cachePath = defaultCachePath(res.sourceRoot)
  if res.writeArtifact and res.artifactPath.len == 0:
    res.artifactPath = defaultArtifactPath(res.testId, res.sourceRoot)
  ok(res)

# ---------------------------------------------------------------------------
# The decision driver (§16.7.4)
# ---------------------------------------------------------------------------

proc describeDecision(testId: string; d: IncrementalDecision): string =
  ## A stable, user-facing one-line report of a decision.
  case d.kind
  of idSkipUnchanged:
    "skipped (unchanged: " & testId & ")"
  of idRunFresh:
    "run (fresh baseline: " & testId & ")"
  of idRerunChanged:
    "re-run (changed: " & testId & " — functions: " &
      d.changedFuncs.join(", ") & ")"
  of idRerunNonDeterministic:
    "re-run (non-deterministic: " & testId & ")"
  of idRerunFailSafe:
    "re-run (fail-safe: " & testId & " — " & d.reason & ")"

type
  IncrementalRunKind* = enum
    ## How an incremental selection run ended.
    irkDecided    ## A decision was reached (skip OR run/re-run). `decision` is set.
    irkGated      ## The language's recorder could not build/record on this host.
    irkError      ## A hard failure (record/persist) — `message` carries the cause.

  IncrementalRunResult* = object
    ## The structured outcome of `decideIncremental` (the testable core of
    ## `ct test --incremental`). The CLI wrapper `runIncremental` turns this into
    ## printed output + a process exit code.
    case kind*: IncrementalRunKind
    of irkDecided:
      decision*: IncrementalDecision
      report*: string   ## The user-facing one-line decision report.
    of irkGated, irkError:
      message*: string  ## The exact captured diagnostic.

proc persistArtifactFromCache(args: IncrementalArgs;
                              cache: IncrementalCache): Result[void, string] =
  ## M2: write/update the per-test ROOT-HASH artifact from the just-(re)recorded
  ## engine cache entry, when `--write-artifact`/`--artifact` is set. The artifact
  ## is the per-test projection of the engine's `CachedTest` (root hash =
  ## recorded deep hash, executed functions = recorded deps), so it never
  ## recomputes the hash — it carries the engine's value, keeping the artifact and
  ## the live decision consistent. A no-op when artifact writing is disabled.
  if not args.writeArtifact:
    return ok()
  if not cache.entries.hasKey(args.testId):
    return err("cannot write artifact: no recorded entry for " & args.testId)
  let artifact = fromCachedTest(args.testId, cache.entries[args.testId])
  writeArtifact(artifact, args.artifactPath)

proc decideIncremental*(args: IncrementalArgs; ws: string): IncrementalRunResult =
  ## The testable core of `ct test --incremental` (no I/O side effects beyond the
  ## live recording, the cache file, and reading the source tree). Performs the
  ## §16.7.4 workflow: record a baseline if none exists (⇒ `idRunFresh`),
  ## otherwise decide skip-vs-rerun against the CURRENT source and re-record on a
  ## re-run verdict. Returns a structured result so tests can assert on the
  ## decision directly; the CLI wrapper prints `report` and maps `kind` to an
  ## exit code.
  ##
  ## # The fail-safe contract
  ##
  ## A malformed cache is not trusted (we start fresh ⇒ everything re-runs — the
  ## safe direction, never a false skip). A recorder that cannot build/record on
  ## this host yields `irkGated` with the exact diagnostic — an HONEST gate, never
  ## a silent skip. Any record/persist failure is `irkError`.
  var cache: IncrementalCache
  let loaded = loadCache(args.cachePath)
  if loaded.isErr:
    cache = initCache(args.cachePath)
  else:
    cache = loaded.value

  let haveBaseline = cache.entries.hasKey(args.testId)

  if haveBaseline:
    # We have a prior baseline. Record a fresh trace to supply the executed SET
    # for the backend probe, then DECIDE against the CURRENT source: the recorded
    # executed set is identical for an unchanged program, and the per-dep shallow
    # hashes (compared against the CURRENT source) are what actually drive
    # skip-vs-rerun. This matches the engine's contract: the trace supplies the
    # executed SET; the SOURCE supplies the change signal.
    let rec = recordLive(args, ws)
    if rec.kind == roGated:
      return IncrementalRunResult(kind: irkGated, message: rec.diagnostic)
    let decision = decide(args.testId, rec.traceDir, args.sourceRoot, cache)
    if isRerun(decision):
      # Re-run: re-record the baseline against the (now-current) source so the
      # cache tracks the latest executed set + hashes (§16.7.4 step 4).
      let rerec = record(cache, args.testId, rec.traceDir, args.sourceRoot)
      if rerec.isErr:
        return IncrementalRunResult(kind: irkError,
          message: "failed to re-record baseline: " & rerec.error)
      let saved = saveCache(cache)
      if saved.isErr:
        return IncrementalRunResult(kind: irkError,
          message: "failed to persist cache: " & saved.error)
      # M2: refresh the per-test root-hash artifact to the re-recorded entry.
      let art = persistArtifactFromCache(args, cache)
      if art.isErr:
        return IncrementalRunResult(kind: irkError,
          message: "failed to write artifact: " & art.error)
    return IncrementalRunResult(kind: irkDecided, decision: decision,
      report: describeDecision(args.testId, decision))

  # No baseline yet: record a fresh one, store it, and report "run (fresh)".
  let rec = recordLive(args, ws)
  if rec.kind == roGated:
    return IncrementalRunResult(kind: irkGated, message: rec.diagnostic)
  let recorded = record(cache, args.testId, rec.traceDir, args.sourceRoot)
  if recorded.isErr:
    return IncrementalRunResult(kind: irkError,
      message: "failed to record baseline: " & recorded.error)
  let saved = saveCache(cache)
  if saved.isErr:
    return IncrementalRunResult(kind: irkError,
      message: "failed to persist cache: " & saved.error)
  # M2: write the per-test root-hash artifact for the fresh baseline.
  let art = persistArtifactFromCache(args, cache)
  if art.isErr:
    return IncrementalRunResult(kind: irkError,
      message: "failed to write artifact: " & art.error)
  let decision = runFresh()
  IncrementalRunResult(kind: irkDecided, decision: decision,
    report: describeDecision(args.testId, decision))

proc runIncremental*(rawArgs: seq[string]): int =
  ## The `ct test --incremental` entry point. Parses arguments, runs
  ## `decideIncremental`, prints the decision report, and returns a process exit
  ## code:
  ##   * 0 — a decision was reached (skip OR run/re-run).
  ##   * 2 — a usage / argument error.
  ##   * 1 — a recorder gate (the language's recorder could not build/record on
  ##         this host) or another hard failure. The exact diagnostic is printed.
  let parsedRes = parseIncrementalArgs(rawArgs)
  if parsedRes.isErr:
    stderr.writeLine("ct test --incremental: " & parsedRes.error)
    stderr.writeLine(usage())
    return 2
  let args = parsedRes.value
  let res = decideIncremental(args, workspaceRoot())
  case res.kind
  of irkDecided:
    echo res.report
    0
  of irkGated:
    stderr.writeLine("ct test --incremental: recorder gated for " &
      $args.language & ":\n" & res.message)
    1
  of irkError:
    stderr.writeLine("ct test --incremental: " & res.message)
    1
