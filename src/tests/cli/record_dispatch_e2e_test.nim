## record_dispatch_e2e_test.nim
##
## A REAL `ct record` per language, through the real dispatch, against the
## real recorder siblings — the other end of the pair that starts with
## `record_dispatch_test.nim`.
##
## The pure test asserts which recorder a language selects and with what argv.
## That is exactly the assertion a wrong-but-consistent table would also pass,
## so it cannot on its own show that the wiring reaches a working recorder.
## This one runs the shipped `ct` binary on a real program and requires a real
## CTFS container to come out — the same code path an end user hits, with
## nothing stubbed.
##
## ## Gating
##
## Each language is skipped, with the workspace's uniform
## `MISSING-RECORDER SKIP:` marker, when its recorder sibling is not usable in
## this environment.  A skip is honest here: the codetracer dev shell carries
## the Ruby and JavaScript recorders but not a PHP or Elixir runtime (those
## live in their own siblings' shells), so requiring all four would fail for a
## reason that has nothing to do with dispatch.
##
## The suite nonetheless has a ZERO-TEST GUARD, per
## `codetracer-specs/Testing/Cross-Repo-CI-Integration.md`: if NOTHING
## recorded, the run fails rather than reporting a vacuous pass.  An
## all-skipped outcome is precisely how a broken wiring hides.
##
## Mocking justification (workspace policy on mock objects): none. This file
## contains no mock. It runs the real `ct` binary, the real recorders and the
## real filesystem, and reads the containers they produce.
##
## Compile and run:
##   nim c -r src/tests/cli/record_dispatch_e2e_test.nim

import std/[os, osproc, strutils, unittest]
import ../../common/lang

const
  RecordTimeoutSeconds = 600
    ## Generous — a cold recorder can be slow — but bounded, so a hung
    ## recording cannot wedge the lane.
  Marker = "ct-dispatch-e2e-marker"
    ## Printed by every program below, so "the recorder ran the program"
    ## is observable in the relayed output rather than inferred.
  CtfsMagic = "\xC0\xDE\x72\xAC\xE2"
    ## The CTFS container magic — the same five bytes
    ## ``src/backend-manager/src/meta_dat.rs``'s ``CTFS_MAGIC`` validates.

proc repoRoot(): string =
  currentSourcePath.parentDir.parentDir.parentDir.parentDir

proc workspaceRoot(): string =
  repoRoot().parentDir

proc ctBinary(): string =
  result = getEnv("CODETRACER_E2E_CT_PATH", "")
  if result.len > 0:
    return
  let buildDir = getEnv("CODETRACER_BUILD_DIR", repoRoot() / "src" / "build-debug")
  result = buildDir / "bin" / "ct"

type
  E2ECase = object
    lang: Lang
    extension: string
    source: string
    extraEnv: seq[(string, string)]
      ## Environment the language needs that the codetracer dev shell does
      ## not provide (the PHP interpreter, resolved from its own sibling).

proc phpAvailableOnPath(): bool =
  findExe("php").len > 0

proc phpFromSibling(): string =
  ## The codetracer dev shell has no `php`; codetracer-php-recorder's does.
  ## Ask that sibling's shell where its interpreter is, so the PHP row can
  ## RUN here instead of being permanently skipped.  Returns "" when the
  ## sibling is absent or its shell cannot be entered.
  if phpAvailableOnPath():
    return findExe("php")
  let sibling = getEnv("CODETRACER_PHP_RECORDER_PATH",
                       workspaceRoot() / "codetracer-php-recorder")
  if not fileExists(sibling / "Justfile"):
    return ""
  let (output, exitCode) = execCmdEx(
    "cd " & quoteShell(sibling) &
    " && timeout 900 direnv exec . bash -c 'command -v php' 2>/dev/null")
  if exitCode != 0:
    return ""
  for line in output.splitLines:
    let candidate = line.strip
    if candidate.len > 0 and fileExists(candidate):
      return candidate
  ""

proc e2eCases(): seq[E2ECase] =
  result.add(E2ECase(
    lang: LangRubyDb, extension: "rb",
    source: "puts \"" & Marker & "\"\n"))
  result.add(E2ECase(
    lang: LangJavascript, extension: "js",
    source: "console.log(\"" & Marker & "\")\n"))

  # PHP is the language this dispatch work added, so it is worth going out of
  # the way to run it for real.
  let php = phpFromSibling()
  let extension = getEnv("CODETRACER_PHP_RECORDER_EXTENSION", "")
  if php.len > 0 and extension.len > 0 and fileExists(extension):
    result.add(E2ECase(
      lang: LangPhp, extension: "php",
      source: "<?php\necho \"" & Marker & "\\n\";\n",
      extraEnv: @[("CODETRACER_PHP_EXE_PATH", php)]))

proc containersUnder(dir: string): seq[string] =
  if not dirExists(dir): return
  for path in walkDirRec(dir):
    if path.endsWith(".ct"):
      result.add(path)

proc runRecord(ct, program, outDir: string; env: seq[(string, string)]):
    tuple[output: string, exitCode: int] =
  var cmd = ""
  for (name, value) in env:
    cmd.add(name & "=" & quoteShell(value) & " ")
  cmd.add("timeout " & $RecordTimeoutSeconds & " " & quoteShell(ct) &
          " record -o " & quoteShell(outDir) & " " & quoteShell(program) &
          " 2>&1")
  execCmdEx(cmd)

suite "ct record end-to-end dispatch":

  let ct = ctBinary()
  let scratch = getTempDir() / "ct-dispatch-e2e"

  test "the ct binary under test exists":
    if not fileExists(ct):
      echo "ERROR: no ct binary at ", ct
      echo "  build it with `just build-once`, or set CODETRACER_E2E_CT_PATH."
    check fileExists(ct)

  test "recording a real program produces a real container":
    require fileExists(ct)
    removeDir(scratch)
    var recorded = 0
    var skipped = 0

    for e2e in e2eCases():
      checkpoint("language: " & e2e.lang.toName)
      let dir = scratch / ($e2e.lang)
      createDir(dir)
      let program = dir / ("program." & e2e.extension)
      writeFile(program, e2e.source)
      let outDir = dir / "out"

      let (output, exitCode) = runRecord(ct, program, outDir, e2e.extraEnv)
      checkpoint("ct output:\n" & output)

      if exitCode != 0 and "was not found" in output:
        # The recorder sibling is not usable here. Report it the way the
        # rest of the repo does, and let the zero-test guard below decide
        # whether an all-skipped run is acceptable (it is not).
        echo "MISSING-RECORDER SKIP: ", e2e.lang.toName, " — ",
          output.splitLines[0]
        skipped += 1
        continue

      # A successful `ct record` must exit 0 ...
      check exitCode == 0
      # ... print the recording id it minted ...
      check "recordingId:" in output
      # ... have actually RUN the program ...
      check Marker in output
      # ... and left a CTFS container behind.
      let containers = containersUnder(outDir)
      checkpoint("containers: " & containers.join(", "))
      check containers.len > 0
      for container in containers:
        # Not merely "a file exists": a real CTFS container starts with the
        # format magic (the same five bytes
        # src/backend-manager/src/meta_dat.rs's CTFS_MAGIC checks), so an
        # empty or truncated file cannot pass for a recording.
        check getFileSize(container) > CtfsMagic.len
        let header = readFile(container)[0 ..< CtfsMagic.len]
        checkpoint("container: " & container)
        check header == CtfsMagic
      recorded += 1

    echo "recorded: ", recorded, ", skipped: ", skipped
    # Zero-test guard: an all-skipped run is how a broken dispatch hides.
    if recorded == 0:
      echo "ERROR: no language recorded end-to-end."
      echo "  The Ruby and JavaScript recorders are expected to be built in"
      echo "  the CodeTracer dev shell — see scripts/detect-siblings.sh and"
      echo "  codetracer-specs/Testing/Cross-Repo-CI-Integration.md."
    check recorded > 0

  test "the recorded container is readable by ct print":
    # Producing bytes is not the same as producing a trace: `ct print` is the
    # shipped reader, so it is what decides whether the container has real
    # content. Reuses the recordings the previous test made.
    require fileExists(ct)
    var inspected = 0
    for e2e in e2eCases():
      let outDir = scratch / ($e2e.lang) / "out"
      let containers = containersUnder(outDir)
      if containers.len == 0:
        continue
      checkpoint("language: " & e2e.lang.toName)
      let (output, exitCode) = execCmdEx(
        "timeout 300 " & quoteShell(ct) & " print " & quoteShell(outDir) &
        " 2>&1")
      checkpoint("ct print output:\n" & output)
      check exitCode == 0
      # `ct print` must have opened the container we just recorded — it
      # echoes the path it resolved, which is also the proof that
      # importTrace's container lookup found it (the JS recorder writes one
      # directory deeper than its --out-dir, and that used to make
      # `ct record app.js` fail after a successful recording).
      # `ct print` must have opened the recording we just made. Recorders
      # differ in where the container lands relative to --out-dir (the JS
      # recorder writes `<out-dir>/trace-<n>/`, which is what importTrace's
      # one-level-down lookup exists for), so the stable assertion is that
      # the reader names the recording it resolved.
      check outDir in output
      var named = false
      for container in containers:
        if container in output or container.parentDir.lastPathPart in output:
          named = true
      checkpoint("expected the output to name one of: " & containers.join(", "))
      check named
      inspected += 1
    check inspected > 0
