## no_sidecar_manifests_test.nim
##
## RS-M12 — ``no_recorder_writes_sidecar_manifests``.
##
## Before this campaign a recorded web session was a *directory of recordings*
## tied together by a sidecar: ``session_manifest.jsonl`` named one trace
## directory per request, and ``codetracer_spans.jsonl`` carried the request
## metadata as JSON lines.  RS-M5..RS-M10 moved all six recorders to the
## container's own span stream; RS-M5/RS-M6/RS-M7 kept the sidecar write path
## "for one release", made opt-in behind ``CODETRACER_SPAN_MANIFEST``.
## RS-M12 retires it, and this is the test that says so.
##
## ## What it actually does
##
## For every language in ``request_span_languages.nim``'s ``LanguageRows`` it
## runs that recorder's own ``record-request-panel-fixture`` recipe — the SAME
## real recording run that produced the checked-in fixture, driving a real
## server over real HTTP — into a scratch directory, and then requires that no
## sidecar manifest exists anywhere the run could have written one.
##
## The run is made deliberately hostile: ``CODETRACER_SPAN_MANIFEST`` is
## **set** in the child environment, pointing at a path inside the scratch
## directory.  That is the switch that used to turn the write path back on, so
## a recorder that merely defaults it off still fails here.  Nothing may
## appear at that path.  This is what makes the test a proof that the write
## path is *gone* rather than a snapshot of today's defaults.
##
## That opt-in path sits OUTSIDE the recording directory on purpose.  The
## recipes post-process their output (flattening a ``worker_<pid>/``
## directory, dropping the recorded ``files/`` tree), so a sidecar written
## *into* the recording and then swept away by the recipe would be invisible —
## whereas a file at the path the environment variable names is not, because
## nothing deletes it.  That is the primary evidence.  Scanning the output tree
## and the pre-RS-M6 default location (``$TMPDIR/codetracer_spans.jsonl``,
## which is where the PHP recorder's retired ``span.php`` wrote
## unconditionally) are the secondary ones.
##
## The read-only shim in ``src/db-backend/src/request_spans.rs`` is out of
## scope and must stay: it PARSES sidecars written before the campaign so
## already-recorded sessions remain openable.  The test asserts it still
## exists and still names both files, so "retire the writers" cannot quietly
## become "drop the reader".
##
## ## Why it is a separate file from the conformance suite
##
## ``request_span_conformance_test.nim`` reads six checked-in fixtures and
## needs no toolchain at all — that is the entire reason the fixtures are
## committed, and it is why that file belongs in the light
## ``just test-vm-native`` lane.  This one shells out to six recorder
## siblings and records six live web sessions.  It is therefore excluded from
## ``test-vm-native`` / ``test-vm-js`` and has its own recipe,
## ``just test-no-sidecar-manifests``, next to ``just test-vm-recorder-gated``
## whose sibling-gating convention (``MISSING-RECORDER SKIP:`` plus a
## zero-test guard) it follows.
##
## A recorder sibling that is not checked out is reported as a skip; a sibling
## that IS checked out and whose recipe fails is a failure, per
## ``codetracer-specs/Working-with-the-CodeTracer-Repos.md`` Part 2 (a missing
## or failed required sibling fails loudly rather than skipping).
##
## Mocking justification (workspace policy on mock objects): none.  There is
## no mock in this file — it runs the real recorders against real servers and
## looks at the real filesystem.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/request-panel/no_sidecar_manifests_test.nim

import std/[os, osproc, strutils, unittest]
import request_span_languages

const
  RecipeTimeoutSeconds = 2400
    ## Generous: a cold sibling has to build its recorder first (the JS one
    ## takes minutes from scratch).  It exists so a hung server cannot wedge
    ## the lane forever, not as a performance budget.

proc scratchRoot(): string =
  getTempDir() / "ct-rsm12-sidecar"

proc topLevelSidecars(dir: string): seq[string] =
  ## Sidecars directly in ``dir`` (not recursive).  Used for the places a
  ## stray write would land by *default* — the process temp dir and the
  ## recorder repo's own working directory — where a recursive walk would
  ## mean crawling ``node_modules`` and ``target`` for no extra signal.
  if not dirExists(dir): return
  for name in SidecarNames:
    let p = dir / name
    if fileExists(p):
      result.add(p)

proc leakLocations(repo: string): seq[string] =
  ## Everywhere other than the recording directory that a recorder could
  ## plausibly drop a sidecar: the temp dir the old default pointed at, and
  ## the working directories the recipes run from.
  result = @[getTempDir(), "/tmp", repo, repo / "tests", repo / "test",
             repo / "test-programs"]

proc runRecipe(repo, outDir, optInPath: string; args: seq[string]):
    tuple[output: string, exitCode: int] =
  ## Drive the sibling's own fixture recipe through its own dev shell, with
  ## the sidecar opt-in deliberately switched ON.
  var cmd = "cd " & quoteShell(repo) & " && " &
    "CODETRACER_SPAN_MANIFEST=" & quoteShell(optInPath) & " " &
    "timeout " & $RecipeTimeoutSeconds & " direnv exec . " &
    "just record-request-panel-fixture " & quoteShell(outDir)
  for a in args:
    cmd.add(" " & quoteShell(a))
  execCmdEx(cmd)

suite "RS-M12 sidecar retirement":

  test "no_recorder_writes_sidecar_manifests":
    let root = workspaceRoot()
    var failures: seq[string] = @[]
    var recorded = 0
    var skipped = 0

    removeDir(scratchRoot())

    for lang in LanguageRows:
      checkpoint("recording run: " & lang.id)
      let repo = root / lang.recorderRepo

      if not dirExists(repo):
        echo "MISSING-RECORDER SKIP: ", lang.id, " — ", repo,
          " is not checked out, so its recording run could not be made"
        skipped += 1
        continue

      let outDir = scratchRoot() / lang.id
      createDir(outDir)
      # Inside the scratch tree, so it is removed with it, and so a write
      # here is unambiguous evidence rather than a pre-existing file.
      let optInPath = scratchRoot() / (lang.id & "-opt-in-sidecar.jsonl")

      var preExisting: seq[string] = @[]
      for dir in leakLocations(repo):
        preExisting.add(topLevelSidecars(dir))

      let (output, exitCode) = runRecipe(
        repo, outDir, optInPath, lang.fixtureRecipeArgs)

      if exitCode != 0:
        let lines = output.strip().splitLines()
        let tail = lines[max(0, lines.len - 8) .. ^1]
        failures.add("[" & lang.id & "] the recording run failed (exit " &
          $exitCode & "); last output:\n      " & tail.join("\n      "))
        continue

      # The run must actually have recorded something, or "no sidecar was
      # written" would be true of a recipe that did nothing at all.
      var containers: seq[string] = @[]
      for path in walkDirRec(outDir, yieldFilter = {pcFile, pcDir,
                                                    pcLinkToFile}):
        if path.splitFile.ext == ".ct":
          containers.add(path)
      if containers.len == 0:
        failures.add("[" & lang.id & "] the recording run produced no .ct " &
          "container under " & outDir & ", so there was no recording to " &
          "check for a sidecar")
        continue
      recorded += 1

      # 1. nothing in the recording's own output tree
      for stray in sidecarsUnder(outDir):
        failures.add("[" & lang.id & "] the recording wrote a sidecar " &
          "manifest into its own output: " & stray)

      # 2. nothing at the opt-in path, even though it was requested
      if fileExists(optInPath):
        failures.add("[" & lang.id & "] " & SidecarOptInEnv &
          " still switches the write path on: " & optInPath &
          " was created during the recording run")

      # 3. nothing new in the places a default write would land
      var post: seq[string] = @[]
      for dir in leakLocations(repo):
        post.add(topLevelSidecars(dir))
      for path in post:
        if path notin preExisting:
          failures.add("[" & lang.id & "] the recording run created a " &
            "sidecar manifest outside its output directory: " & path)

    # Zero-test guard (Cross-Repo-CI-Integration.md): an all-skipped run
    # asserts nothing, and must not read as a pass.
    if recorded == 0:
      failures.add("[suite] no language was actually recorded (" & $skipped &
        " skipped) — this run verified nothing about the sidecar write path")

    # The READ-only shim must survive.
    let shim = root / "codetracer" / "src" / "db-backend" / "src" /
      "request_spans.rs"
    if not fileExists(shim):
      failures.add("[suite] the read-only sidecar shim " & shim &
        " is gone; RS-M12 retires the WRITERS, not the reader")
    else:
      let shimSrc = readFile(shim)
      for needle in SidecarNames:
        if not shimSrc.contains(needle):
          failures.add("[suite] " & shim & " no longer mentions '" & needle &
            "', so sessions recorded before RS-M12 can no longer be read")

    if failures.len > 0:
      checkpoint("sidecar violations (" & $failures.len & "):\n  " &
        failures.join("\n  "))
      fail()

    echo "recorded ", recorded, " language(s), skipped ", skipped
    removeDir(scratchRoot())
