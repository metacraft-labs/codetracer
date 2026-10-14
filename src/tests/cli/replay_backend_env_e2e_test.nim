## replay_backend_env_e2e_test.nim
##
## The SHIPPED `ct replay` publishes `--thread-sync-order` and
## `--os-simulation` as their environment twins to the process it launches,
## and refuses a bad value before launching anything -- codetracer-specs
## `CLI/ct/replay.md`, "Options".
##
## ## Why end to end
##
## A GUI replay runs `ct` -> Electron -> backend-manager -> db-backend ->
## `ct-native-replay replay-worker` -> `ct-mcr`, and every hop after `ct`
## passes its environment on unchanged.  The pure decision
## (`replay_backend_env_test.nim`) cannot see whether the linked `ct` reads the
## options at all: that is a confutils declaration plus the dispatch in
## `launch/launch.nim`, neither of which exists outside a linked binary.  So
## this runs the real `ct` on a real (imported) recording folder and looks at
## what arrives at the next hop.  The hop after that, db-backend's worker
## spawn, is pinned by db-backend's own
## `replay_worker_inherits_replay_engine_options` test.
##
## Mocking justification (workspace policy on mock objects): the FRONT-END is
## replaced, by putting a program named `electron` first on `PATH` (`ct`
## finds Electron there, `common/paths.nim` `electronExe`), and the same stub
## stands in for the terminal front-end through `CODETRACER_TUI_BIN` (the
## `--ui=tui` handoff).  The stub writes the arguments, the `CT_` environment
## and `CODETRACER_NEW_TRACE_POLICY` it receives to a file and exits 0.
## What is under test is what arrives at the front-end's door, which the real
## Electron would consume rather than report.  Everything before it is real:
## the shipped `ct`, its option parsing, the trace import into an isolated
## `CODETRACER_HOME`, and the launch.
##
## The recording is a minimal materialized folder (`trace_metadata.json`,
## `trace_paths.json`, an empty `trace.bin`), which `ct replay -t` imports
## without reading an event: the options are published for every recording
## kind, so the kind does not matter here.
##
## Prerequisites (a missing one FAILS the row, it never skips): the built `ct`
## under `src/build-debug/bin` (or CODETRACER_E2E_CT_PATH), and `nim` on PATH
## to build the stub.
##
## Compile and run:
##   nim c -r src/tests/cli/replay_backend_env_e2e_test.nim

import std/[json, os, osproc, streams, strtabs, strutils, unittest]

proc repoRoot(): string =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc ctBinary(): string =
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  result = (getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug") /
            "bin" / "ct").addFileExt(ExeExt)

const stubSource = """
import std/[os, strutils]
var lines: seq[string]
for a in commandLineParams(): lines.add "ARG " & a
for k, v in envPairs():
  if k.startsWith("CT_") or k == "CODETRACER_NEW_TRACE_POLICY":
    lines.add "ENV " & k & "=" & v
writeFile(getEnv("REPLAY_E2E_CAPTURE"), lines.join("\n") & "\n")
"""

type
  Fixture = object
    work, bin, trace, capture: string
    prerequisite: string   ## non-empty: what is missing

  Run = object
    output: string
    exitCode: int
    launched: bool         ## the front-end stub ran
    env: seq[string]       ## the twins it saw, as NAME=value
    args: seq[string]      ## the arguments it was given
    policy: string         ## its CODETRACER_NEW_TRACE_POLICY ("" when unset)

proc setUp(): Fixture =
  result.work = getTempDir() / ("ct_replay_backend_env_e2e_" &
                                $getCurrentProcessId())
  removeDir(result.work)
  result.bin = result.work / "bin"
  result.trace = result.work / "trace"
  result.capture = result.work / "frontend-saw.txt"
  createDir(result.bin)
  createDir(result.trace)
  if not fileExists(ctBinary()):
    result.prerequisite = "PREREQUISITE MISSING: the built ct at " & ctBinary()
    return
  if findExe("nim").len == 0:
    result.prerequisite = "PREREQUISITE MISSING: nim on PATH (builds the stub)"
    return
  writeFile(result.work / "stub.nim", stubSource)
  let stubExe = (result.bin / "electron").addFileExt(ExeExt)
  let (buildOut, buildCode) = execCmdEx("nim c --hints:off --warnings:off " &
    "--nimcache:" & quoteShell(result.work / "nimcache") & " -o:" &
    quoteShell(stubExe) & " " & quoteShell(result.work / "stub.nim"))
  if buildCode != 0 or not fileExists(stubExe):
    result.prerequisite = "PREREQUISITE MISSING: could not build the " &
      "front-end stub:\n" & buildOut
    return
  writeFile(result.trace / "trace_metadata.json",
    """{"program": "prog", "args": [], "workdir": """ & escapeJson(result.work) &
    """, "recorder": {"name": "replay-backend-env-e2e", "version": "0"}}""")
  writeFile(result.trace / "trace_paths.json", "[]")
  writeFile(result.trace / "trace.bin", "")

proc runReplay(f: Fixture, options: seq[string],
               extraEnv: openArray[(string, string)] = []): Run =
  ## Run the shipped `ct replay <options> -t <trace>` with the stub front-end
  ## first on PATH, an isolated CODETRACER_HOME, and an environment that holds
  ## neither twin unless `extraEnv` sets it.
  removeFile(f.capture)
  let env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    if k notin ["CT_THREAD_SYNC_ORDER", "CT_OS_SIMULATION", "CODETRACER_UI",
                "CODETRACER_NEW_TRACE_POLICY", "CODETRACER_TUI_BIN"]:
      env[k] = v
  env["PATH"] = f.bin & $PathSep & getEnv("PATH")
  # `--ui=tui` finds the terminal front-end here; the stub stands in for it.
  env["CODETRACER_TUI_BIN"] = (f.bin / "electron").addFileExt(ExeExt)
  env["CODETRACER_HOME"] = f.work / "home"
  env["REPLAY_E2E_CAPTURE"] = f.capture
  for (k, v) in extraEnv:
    env[k] = v
  # An argument list, not a shell line: no shell is involved on Windows, so a
  # redirection written into the line would reach `ct` as an argument.
  let args = @["replay"] & options & @["-t", f.trace]
  let p = startProcess(ctBinary(), workingDir = f.work, args = args,
                       env = env, options = {poStdErrToStdOut})
  result.output = p.outputStream.readAll()
  result.exitCode = p.waitForExit()
  p.close()
  result.launched = fileExists(f.capture)
  if result.launched:
    for line in readFile(f.capture).splitLines:
      if line.startsWith("ENV CT_THREAD_SYNC_ORDER=") or
          line.startsWith("ENV CT_OS_SIMULATION="):
        result.env.add line[4 .. ^1]
      elif line.startsWith("ENV CODETRACER_NEW_TRACE_POLICY="):
        result.policy = line["ENV CODETRACER_NEW_TRACE_POLICY=".len .. ^1]
      elif line.startsWith("ARG "):
        result.args.add line[4 .. ^1]

proc describe(r: Run): string =
  "\n  exit " & $r.exitCode & ", front-end launched: " & $r.launched &
    ", twins it saw: " & $r.env & ", policy: '" & r.policy & "', args: " &
    $r.args & "\n  ct said: " & r.output.strip

let fixture = setUp()

suite "ct replay: replay-engine options reach the launched front-end":
  test "the flags arrive as CT_THREAD_SYNC_ORDER / CT_OS_SIMULATION":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      # Both spellings confutils accepts: `--flag value` and `--flag=value`.
      let r = runReplay(fixture, @["--thread-sync-order", "per-object",
                                   "--os-simulation=strong-userspace"])
      checkpoint describe(r)
      check r.exitCode == 0
      check r.launched
      check "CT_THREAD_SYNC_ORDER=per-object" in r.env
      check "CT_OS_SIMULATION=strong-userspace" in r.env

  test "the variable seeds the choice and the flag wins (Rule 3)":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @["--thread-sync-order=total"],
                        {"CT_THREAD_SYNC_ORDER": "per-object",
                         "CT_OS_SIMULATION": "strong-kernel"})
      checkpoint describe(r)
      check r.exitCode == 0
      check r.env == @["CT_THREAD_SYNC_ORDER=total",
                       "CT_OS_SIMULATION=strong-kernel"] or
            r.env == @["CT_OS_SIMULATION=strong-kernel",
                       "CT_THREAD_SYNC_ORDER=total"]

  test "nothing given publishes nothing, so the engine's own default applies":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @[])
      checkpoint describe(r)
      check r.exitCode == 0
      check r.launched
      check r.env.len == 0

suite "ct replay: a replay that carries an option opens its own window":
  # Under "tab", an open window takes the trace over through Electron's
  # single-instance lock with the argument list only, and its replay backend
  # keeps its own environment: the option would be dropped.
  test "an option makes the policy 'window', even over --new-tab":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @["--thread-sync-order=per-object"])
      checkpoint describe(r)
      check r.exitCode == 0
      check r.policy == "window"
      let tab = runReplay(fixture, @["--new-tab"],
                          {"CT_OS_SIMULATION": "strong-userspace"})
      checkpoint describe(tab)
      check tab.exitCode == 0
      check tab.policy == "window"
      check "CT_OS_SIMULATION=strong-userspace" in tab.env
      check "--new-tab is ignored" in tab.output

  test "with no option the tab policy is left alone":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @["--new-tab"])
      checkpoint describe(r)
      check r.exitCode == 0
      check r.policy == "tab"

suite "ct replay --ui=tui: the handoff publishes the same twins":
  test "the options become twins and leave the front-end's argument list":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @["--ui=tui", "--thread-sync-order",
                                   "per-object",
                                   "--os-simulation=strong-kernel"])
      checkpoint describe(r)
      check r.exitCode == 0
      check r.launched
      check "CT_THREAD_SYNC_ORDER=per-object" in r.env
      check "CT_OS_SIMULATION=strong-kernel" in r.env
      check r.args == @[fixture.trace]

  test "a bad value is refused before the handoff":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @["--ui=tui", "--os-simulation=weak"])
      checkpoint describe(r)
      check r.exitCode != 0
      check not r.launched
      check "--os-simulation='weak'" in r.output

suite "ct replay: a bad value is refused before anything is launched":
  test "a bad flag value names the flag; the front-end never starts":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @["--thread-sync-order=global"])
      checkpoint describe(r)
      check r.exitCode != 0
      check not r.launched
      check "--thread-sync-order='global'" in r.output
      check "'total' or 'per-object'" in r.output

  test "a bad variable names the variable; the front-end never starts":
    check fixture.prerequisite == ""
    if fixture.prerequisite == "":
      let r = runReplay(fixture, @[], {"CT_OS_SIMULATION": "weak"})
      checkpoint describe(r)
      check r.exitCode != 0
      check not r.launched
      check "CT_OS_SIMULATION='weak'" in r.output

removeDir(fixture.work)
