## M2 — `e2e_root_hash_file_redecides`.
##
## END-TO-END through the per-test ROOT-HASH ARTIFACT FILE: write the artifact
## for a recorded test, then on a LATER run re-decide skip-vs-rerun PURELY from
## the persisted artifact (re-hash exactly the recorded executed functions
## against the CURRENT source, recompute the root hash, compare, and name what
## changed). This exercises the full M2 surface — `buildArtifact` (reusing the
## engine's extraction + shallow hashing), the swappable codec boundary
## (`writeArtifact` / `readArtifact`), and `redecideFromArtifact` (reusing the
## engine's `decide`) — not just the in-memory engine cache.
##
## The asserted §16.7.4 decisions, each driven THROUGH a round-tripped artifact
## file on disk (the original in-memory state is discarded between record and
## re-decide):
##
##   * an UNCHANGED tree ⇒ SKIP (the artifact's root hash matches the current
##     source's recomputed root hash);
##   * editing an EXECUTED function ⇒ RE-RUN, NAMING the changed function (the
##     root hash differs); and
##   * editing a NON-executed function ⇒ SKIP (it is not in the artifact's
##     executed set, so the root hash is unchanged).
##
## Reuses the committed M0 `m0_three_funcs` Ruby fixture (interpreted SOURCE
## path; `main` executes `used_a`/`used_b`, `unused_c` is never called), so the
## test is self-contained and needs no live recorder.

import std/[unittest, os, strutils, times]

import engine        # IncrementalDecisionKind, isRerun
import root_hash      # buildArtifact, writeArtifact, readArtifact, redecideFromArtifact

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"
  testId = "fixture::three_funcs"

var counter = 0

proc makeSourceRoot(): string =
  inc counter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("ct_m2_e2e_" & $stamp & "_" & $counter)
  let dst = root / relSourcePath
  createDir(dst.parentDir)
  copyFile(threeFuncsFixture / "src" / "three_funcs.rb", dst)
  root

proc editFunctionBody(root, funcName, newBody: string) =
  let path = root / relSourcePath
  var lines = readFile(path).split('\n')
  for i in 0 ..< lines.len:
    if lines[i].strip() == "def " & funcName:
      doAssert i + 1 < lines.len
      lines[i + 1] = "  " & newBody
      writeFile(path, lines.join("\n"))
      return
  doAssert false, "function not found: " & funcName

proc writeBaselineArtifact(sourceRoot, artifactPath: string) =
  ## Build the per-test artifact from the recorded trace against the (unedited)
  ## source and persist it to `artifactPath` via the codec boundary. This is the
  ## "first run writes the artifact" half of the e2e.
  let built = buildArtifact(testId, threeFuncsTrace, sourceRoot)
  doAssert built.isOk, "buildArtifact failed: " & built.error
  let written = writeArtifact(built.value, artifactPath)
  doAssert written.isOk, "writeArtifact failed: " & written.error
  doAssert fileExists(artifactPath)

suite "M2 e2e — root-hash artifact file drives the re-decision":

  test "unchanged_tree_skips_via_artifact":
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "three_funcs.roothash.json"
    writeBaselineArtifact(sourceRoot, artifactPath)
    # LATER run: reload the artifact from disk and re-decide against the SAME,
    # unedited source. Root hash matches ⇒ SKIP.
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    let d = redecideFromArtifact(loaded.value, threeFuncsTrace, sourceRoot)
    check d.kind == idSkipUnchanged

  test "editing_executed_function_reruns_and_names_it":
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "three_funcs.roothash.json"
    writeBaselineArtifact(sourceRoot, artifactPath)
    # Edit an EXECUTED function AFTER the artifact was written.
    editFunctionBody(sourceRoot, "used_a", "42 + 1")
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    let d = redecideFromArtifact(loaded.value, threeFuncsTrace, sourceRoot)
    check d.kind == idRerunChanged
    check isRerun(d)
    # Function-level precision: the changed EXECUTED function is named.
    check "used_a" in d.changedFuncs
    check "used_b" notin d.changedFuncs

  test "editing_non_executed_function_skips_via_artifact":
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "three_funcs.roothash.json"
    writeBaselineArtifact(sourceRoot, artifactPath)
    # Edit the NON-executed `unused_c` AFTER the artifact was written.
    editFunctionBody(sourceRoot, "unused_c", "999")
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    let d = redecideFromArtifact(loaded.value, threeFuncsTrace, sourceRoot)
    check d.kind == idSkipUnchanged

  test "artifact_round_trips_losslessly_through_the_codec":
    # The persisted artifact decodes back to the same root hash + executed set it
    # was built with — proving the codec boundary is faithful (so M3/M4 can swap
    # the codec without changing the schema or the decision).
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "three_funcs.roothash.json"
    let built = buildArtifact(testId, threeFuncsTrace, sourceRoot)
    require built.isOk
    require writeArtifact(built.value, artifactPath).isOk
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    check loaded.value.testId == built.value.testId
    check loaded.value.rootHash == built.value.rootHash
    check loaded.value.rootHash.len > 0
    check loaded.value.executedFunctions.len == built.value.executedFunctions.len
    check loaded.value.deterministic == built.value.deterministic
    # The reserved M6 read-file slot is present and empty (no read files yet).
    check loaded.value.readFiles.len == 0

  test "executed_set_recorded_in_artifact_excludes_unused":
    # The artifact's executed set carries exactly the functions the test ran —
    # main/used_a/used_b — and NOT the defined-but-never-called unused_c.
    let sourceRoot = makeSourceRoot()
    let built = buildArtifact(testId, threeFuncsTrace, sourceRoot)
    require built.isOk
    var names: seq[string]
    for dep in built.value.executedFunctions:
      names.add dep.fn.name
    check "used_a" in names
    check "used_b" in names
    check "unused_c" notin names
