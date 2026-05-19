## M-REC-6 acceptance test for ``CODETRACER_RECORDING_ID`` / legacy
## ``CODETRACER_TRACE_ID``.
##
## The launch path in ``src/ct/launch/launch.nim`` and the Electron
## startup in ``src/frontend/index/args.nim`` both fail loudly if the
## legacy env var is still set in the spawned process's environment.
## This test pins that contract at the source-of-truth level: the
## guard now lives in a small public proc in
## ``src/ct/launch/recording_id_env.nim`` so a helper subprocess can
## import and invoke it directly — no inline mirror, no drift.
##
## We still need a subprocess because the production guard calls
## ``quit(1)`` and reads ``getEnv``, both of which are easier to set
## up cleanly in a fresh child than to mock inside the test runner.
##
## Run with:
##   nim c -r --hints:off --warnings:off --mm:refc \
##       --nimcache:/tmp/ct-nim-cache/launch_env_var_test \
##       src/ct/launch/launch_env_var_test.nim

import std/[os, osproc, streams, strtabs, strutils, unittest]

# ---------------------------------------------------------------------------
# Helper subprocess: imports the production guard from
# ``recording_id_env`` and exercises it.  No copy-paste — any change to
# the guard surfaces here automatically.
# ---------------------------------------------------------------------------

const recordingIdEnvModuleDir = currentSourcePath().parentDir()
  ## Absolute path to the directory holding ``recording_id_env.nim``,
  ## baked into the test at compile time so the helper compiles
  ## regardless of the cwd the test is invoked from.  Passed to ``nim
  ## c`` as ``--path:`` so the helper can ``import recording_id_env``.

const helperSrc = """
import std/os
import recording_id_env

when isMainModule:
  refuseLegacyRecordingIdEnv(
    proc (msg: string) = stderr.writeLine(msg))
  let recId = getEnv(CurrentRecordingIdEnvVar, "")
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
            "--path:" & quoteShell(recordingIdEnvModuleDir) & " " &
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
