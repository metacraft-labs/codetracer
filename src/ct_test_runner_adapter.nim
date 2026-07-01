## ct_test_runner_adapter — Spec-Implementation M4
##
## The ``TestRunner`` cross-cutting-interface adapter that satisfies the
## interface declared by the dependency-free ``repro_test_adapters`` package.
## The adapter delegates RUN to the existing ``ct-test-runner`` binary
## (a one-binary positional invocation, with ``--filter`` mapping the
## ``filter`` argument) and delegates LIST
## / ENUMERATE to the binary's own Tier-1 "Standard" binary protocol
## (``--list`` / ``--list-json``).
##
## Usage from a reprobuild project file::
##
##   import ct_test_nim_unittest
##   import ct_test_runner_adapter
##
##   # Reprobuild recipes wire the adapter with
##   # `installCtTestRunner(currentBuildContext())` from Reprobuild's
##   # `ct_test_runner_install` module. This module only constructs the
##   # dependency-free TestRunner value; it does not import the Reprobuild
##   # engine or active build context.
##
## Locating the runner: the adapter resolves the runner binary in this
## order:
##
##   1. ``$CT_TEST_RUNNER`` (absolute path override; honoured for
##      developer-checkout setups and the M4 integration tests).
##   2. ``ct-test-runner`` on ``$PATH`` (the production hop, exercised
##      under ``nix develop`` once the binary is built and installed).
##   3. The bare ``ct-test-runner`` name; process spawning will produce
##      a normal OS error if it is unavailable.
##
## The resolved path is captured once at adapter construction time so
## later ``run`` invocations don't pay the lookup cost.

import std/[json, os, osproc, strutils]

import repro_test_adapters/test_runner
export test_runner

const
  RunnerBinaryEnv* = "CT_TEST_RUNNER"
    ## Env-var override read at adapter construction time.
  DefaultRunnerName* = "ct-test-runner"
    ## ``$PATH`` lookup name when no env override is set.

type
  CtTestRunnerAdapterState* = ref object
    ## Captured runner location plus any metadata the closures need at
    ## execution time. Stored as a closure-captured ref so the
    ## ``TestRunner`` vtable's procs share one resolution result.
    runnerPath*: string
      ## Absolute path to the resolved ``ct-test-runner`` binary, or
      ## the bare basename when the binary was located via ``$PATH``.
    runnerName*: string
      ## Stable identifier for diagnostics
      ## (``"ct-test-runner-adapter"``).

proc resolveRunnerPath(explicit: string = ""): string =
  ## Three-tier resolution. The explicit override is the M4-test
  ## escape hatch (``ctTestRunner(runnerPath = abspath)``).
  if explicit.len > 0:
    return explicit
  let env = getEnv(RunnerBinaryEnv)
  if env.len > 0:
    return env
  let found = findExe(DefaultRunnerName)
  if found.len > 0:
    return found
  # Final fallback: let process spawning produce a clean ``OSError`` if the
  # binary is unavailable. We don't preemptively raise here so adapter
  # construction stays side-effect-free.
  "ct-test-runner"

proc adapterRunInvocation(state: CtTestRunnerAdapterState;
                          binary: TestBinary; filter: string): ExitCode =
  ## Spawn ``ct-test-runner <binary> [--filter <filter>]`` as a single
  ## positional-binary invocation. The runner's argv shape supports a
  ## positional binary path that takes precedence over its
  ## ``--bin-dir`` scan, so a single ``TestBinary`` flows in cleanly.
  if binary.path.len == 0:
    return -1
  if state.runnerPath.len == 0:
    return -1
  var argv: seq[string] = @[state.runnerPath, "run", binary.path]
  if filter.len > 0:
    # ct-test-runner's ``parseopt``-driven CLI parses ``--filter=<v>``
    # but treats space-separated ``--filter <v>`` as a missing value
    # plus a trailing positional binary. Use the equals form to keep
    # ``filter`` from leaking into ``positionalBinaries``.
    argv.add("--filter=" & filter)
  try:
    var quoted: seq[string] = @[]
    for piece in argv:
      quoted.add(quoteShell(piece))
    let cmdline = quoted.join(" ")
    execShellCmd(cmdline)
  except OSError:
    -1

proc parseListJsonCatalog(payload: string): seq[TestCase] =
  ## Parse the binary's ``--list-json`` output. Schema per
  ## ``ct_test_unittest_parallel`` (Tier-1 "Standard"): top-level
  ## object with ``tests`` array whose entries carry ``suite`` and
  ## ``name`` fields. ``name`` may already be qualified
  ## (``suite::test``); the parser normalises so ``qualifiedName``
  ## always includes the suite prefix once.
  result = @[]
  let trimmed = payload.strip()
  if trimmed.len == 0:
    return
  let doc =
    try:
      parseJson(trimmed)
    except JsonParsingError:
      return
  if not doc.hasKey("tests") or doc["tests"].kind != JArray:
    return
  for entry in doc["tests"]:
    let suite = entry{"suite"}.getStr("")
    let name = entry{"name"}.getStr("")
    if name.len == 0:
      continue
    var bareName = name
    if suite.len > 0 and name.startsWith(suite & "::"):
      bareName = name[len(suite) + 2 .. ^1]
    let qualified =
      if suite.len > 0: suite & "::" & bareName
      else: bareName
    let display =
      if bareName.len > 0: bareName
      else: qualified
    result.add(TestCase(qualifiedName: qualified, displayName: display))

proc adapterListInvocation(binary: TestBinary): seq[TestCase] =
  ## Invoke the binary's own ``--list-json`` protocol entry point and
  ## return the structured catalog. The binary is the source of truth
  ## for the case list (ct-test-runner's catalog is itself derived from
  ## this); querying the binary directly avoids the runner's worker-
  ## pool overhead for what should be a single-process lookup.
  if binary.path.len == 0:
    return @[]
  let (output, exitCode) =
    try:
      execCmdEx(quoteShell(binary.path) & " --list-json")
    except CatchableError:
      ("", -1)
  if exitCode != 0:
    return @[]
  parseListJsonCatalog(output)

proc adapterEnumerateInvocation(binary: TestBinary): seq[QualifiedName] =
  ## Invoke the binary's ``--list`` protocol entry point — one
  ## qualified name per line. Skips blank lines so partial output
  ## from a malformed binary doesn't produce empty entries.
  if binary.path.len == 0:
    return @[]
  let (output, exitCode) =
    try:
      execCmdEx(quoteShell(binary.path) & " --list")
    except CatchableError:
      ("", -1)
  if exitCode != 0:
    return @[]
  for raw in output.splitLines():
    let line = raw.strip()
    if line.len == 0:
      continue
    result.add(line)

proc ctTestRunner*(runnerPath: string = ""): TestRunner =
  ## Construct a fully populated ``TestRunner`` whose vtable delegates
  ## to ``ct-test-runner`` for ``run`` and to the test binary's own
  ## protocol for ``list`` / ``enumerate``. The ``runnerPath`` argument
  ## overrides the three-tier resolution so M4 integration tests can
  ## point at a known-good location without touching the env.
  let state = CtTestRunnerAdapterState(
    runnerPath: resolveRunnerPath(runnerPath),
    runnerName: "ct-test-runner-adapter")
  newTestRunner(
    name = state.runnerName,
    run = proc(binary: TestBinary; filter: string): ExitCode =
      adapterRunInvocation(state, binary, filter),
    list = proc(binary: TestBinary): seq[TestCase] =
      adapterListInvocation(binary),
    enumerate = proc(binary: TestBinary): seq[QualifiedName] =
      adapterEnumerateInvocation(binary))
