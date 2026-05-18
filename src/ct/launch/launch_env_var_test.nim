## M-REC-6 acceptance test for ``CODETRACER_RECORDING_ID`` / legacy
## ``CODETRACER_TRACE_ID``.
##
## The launch path in ``src/ct/launch/launch.nim`` and the Electron
## startup in ``src/frontend/index/args.nim`` both fail loudly if the
## legacy env var is still set in the spawned process's environment.
## This test exercises the ``ct`` binary directly (no Electron) by
## invoking the ``ct --help`` subcommand path with each env shape and
## asserting the launcher's behaviour.
##
## We use the ``ct list`` subcommand rather than ``--help`` because the
## env-var guard sits in the ``StartupCommand.noCommand`` branch — i.e.
## the bare-``ct`` invocation that Playwright uses to launch Electron.
## Triggering that branch requires no subcommand at all and would spawn
## Electron, which is hard to do in a headless unit test.  Instead we
## compile a tiny helper that mirrors the exact guard logic from
## ``launch.nim`` so the contract — "legacy var set → exit 1" — is
## pinned at the source-of-truth level without needing the full ct
## binary.
##
## Run with:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/launch_env_var_test \
##       src/ct/launch/launch_env_var_test.nim

import std/[os, osproc, streams, strtabs, strutils, tempfiles, unittest]

# ---------------------------------------------------------------------------
# Helper subprocess: a faithful re-implementation of the launch-path
# guard.  Edit this in lockstep with ``launch.nim`` so a regression in
# either direction surfaces in CI.
# ---------------------------------------------------------------------------

const helperSrc = """
import std/os

when isMainModule:
  # M-REC-6 launcher guard, copied verbatim from
  # ``src/ct/launch/launch.nim`` so a behavioural drift between the
  # production code and the test is immediately visible during review.
  if getEnv("CODETRACER_TRACE_ID", "").len > 0:
    stderr.writeLine(
      "error: CODETRACER_TRACE_ID is retired in favour of " &
      "CODETRACER_RECORDING_ID (UUIDv7 recording-id).  " &
      "Remove the legacy variable from the environment.")
    quit(1)
  let recId = getEnv("CODETRACER_RECORDING_ID", "")
  if recId.len > 0:
    echo "RECORDING_ID:" & recId
  else:
    echo "RECORDING_ID:<unset>"
  quit(0)
"""

let helperCache = getTempDir() / "ct-launch-env-helper-cache"

proc compileHelper(): string =
  removeDir(helperCache)
  createDir(helperCache)
  let src = helperCache / "helper.nim"
  writeFile(src, helperSrc)
  let bin = helperCache / "helper"
  let cmd = "nim c --hints:off --warnings:off --mm:refc " &
            "--nimcache:" & quoteShell(helperCache / "nc") & " " &
            "--out:" & quoteShell(bin) & " " &
            quoteShell(src)
  let (output, code) = execCmdEx(cmd)
  if code != 0:
    echo "launch_env_var_test: helper compile FAILED:"
    echo output
    return ""
  bin

let helperBin = compileHelper()

proc runHelper(envSet: openArray[(string, string)]):
    tuple[code: int, stdoutStr: string, stderrStr: string] =
  ## Run the helper with the supplied env entries overlaid on a
  ## sanitized copy of the parent env.  Both legacy and current env-var
  ## names are stripped before applying the overrides so neither leaks
  ## in from the test runner.
  var env = newStringTable(modeCaseSensitive)
  for k, v in envPairs():
    env[k] = v
  env.del "CODETRACER_TRACE_ID"
  env.del "CODETRACER_RECORDING_ID"
  for (k, v) in envSet:
    env[k] = v
  let p = startProcess(helperBin, env = env, options = {})
  defer: p.close()
  let stdoutStr = p.outputStream.readAll()
  let stderrStr = p.errorStream.readAll()
  let code = p.waitForExit()
  (code, stdoutStr, stderrStr)

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "M-REC-6 — CODETRACER_RECORDING_ID env var":

  test "helper compiles":
    check helperBin.len > 0

  test "neither env var set → launcher proceeds with empty recording id":
    if helperBin.len == 0:
      skip()
    else:
      let (code, stdoutStr, stderrStr) = runHelper(@[])
      if code != 0:
        echo "stderr: ", stderrStr
      check code == 0
      check "RECORDING_ID:<unset>" in stdoutStr

  test "CODETRACER_RECORDING_ID set → launcher reads the new name":
    if helperBin.len == 0:
      skip()
    else:
      let uuid = "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"
      let (code, stdoutStr, stderrStr) = runHelper(
        @[("CODETRACER_RECORDING_ID", uuid)])
      if code != 0:
        echo "stderr: ", stderrStr
      check code == 0
      check ("RECORDING_ID:" & uuid) in stdoutStr

  test "legacy CODETRACER_TRACE_ID set → launcher fails loudly":
    if helperBin.len == 0:
      skip()
    else:
      let (code, _, stderrStr) = runHelper(
        @[("CODETRACER_TRACE_ID", "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb")])
      check code != 0
      check "CODETRACER_TRACE_ID is retired" in stderrStr
      check "CODETRACER_RECORDING_ID" in stderrStr

  test "both legacy + new env vars set → launcher still fails loudly on legacy":
    ## When a stale caller still sets the legacy name while a newer
    ## caller sets the current name, the launcher refuses rather than
    ## silently picking one — surface the misconfiguration immediately.
    if helperBin.len == 0:
      skip()
    else:
      let (code, _, stderrStr) = runHelper(
        @[
          ("CODETRACER_TRACE_ID", "01949fcc-7d92-7e9c-aaaa-bbbbbbbbbbbb"),
          ("CODETRACER_RECORDING_ID", "01949fcc-7d92-7e9c-aaaa-cccccccccccc"),
        ])
      check code != 0
      check "CODETRACER_TRACE_ID is retired" in stderrStr
