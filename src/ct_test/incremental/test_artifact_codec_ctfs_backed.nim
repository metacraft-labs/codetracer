## M4a — `test_artifact_codec_ctfs_backed`.
##
## The M2 per-test artifact now persists through the CTFS-namespace-backed codec
## (`ctfs_codec.nim`) behind M2's existing `RootHashArtifactCodec` boundary. This
## test proves the SWAP preserves M2's logical semantics:
##
##   * the per-test artifact round-trips LOSSLESSLY through the CTFS codec
##     (root hash + executed-function set with identities + recorded shallow
##     hashes + deterministic + read files all survive encode→decode);
##   * the CTFS codec is the installed DEFAULT (importing `ctfs_codec` calls
##     `setDefaultCodec`), so `writeArtifact`/`readArtifact` use it with no
##     explicit codec argument; and
##   * the re-decide path (`redecideFromArtifact`) still produces M2's decisions
##     when driven THROUGH a CTFS-backed artifact file: unchanged ⇒ skip, an
##     edited executed function ⇒ re-run naming it, an edited non-executed
##     function ⇒ skip.
##
## Built over the committed M0 `m0_three_funcs` Ruby fixture (the same fixture
## the M2 tests use), so the codec is exercised over REAL recorded engine state,
## never constants. This is the M4a counterpart of M2's
## `e2e_root_hash_file_redecides` — the M2 logical contract, against the new
## bytes-on-disk backing.

import std/[unittest, os, strutils, times, algorithm]

import engine        # IncrementalDecisionKind, isRerun, CachedDep, ExecutedFunction
import root_hash      # RootHashArtifact, buildArtifact, writeArtifact, readArtifact, redecide..., defaultCodec
import ctfs_codec     # installs the CTFS codec as default; ctfsNamespaceCodec

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
  let root = getTempDir() / ("ct_m4a_codec_" & $stamp & "_" & $counter)
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

proc sortedDeps(a: RootHashArtifact): seq[CachedDep] =
  result = a.executedFunctions
  result.sort(proc (x, y: CachedDep): int =
    result = cmp(x.fn.name, y.fn.name)
    if result == 0: result = cmp(x.fn.file, y.fn.file)
    if result == 0: result = cmp(x.fn.defLine, y.fn.defLine))

suite "M4a — artifact codec CTFS-backed (M2 semantics preserved)":

  test "ctfs_codec_is_the_installed_default":
    # Importing `ctfs_codec` installs it as the default behind M2's boundary.
    check defaultCodec().name == "ctfs-ns"

  test "artifact_round_trips_losslessly_through_ctfs_codec":
    # Build the artifact from REAL recorded engine state, encode+decode through
    # the CTFS namespace codec EXPLICITLY, and assert every field survives.
    let sourceRoot = makeSourceRoot()
    let built = buildArtifact(testId, threeFuncsTrace, sourceRoot)
    require built.isOk
    let codec = ctfsNamespaceCodec()
    let enc = codec.encode(built.value)
    require enc.isOk
    let dec = codec.decode(enc.value)
    require dec.isOk
    let a = dec.value
    check a.testId == built.value.testId
    check a.rootHash == built.value.rootHash
    check a.rootHash.len > 0
    check a.deterministic == built.value.deterministic
    # The executed-function set survives with identity + shallow, order-normalized.
    let want = sortedDeps(built.value)
    let got = sortedDeps(a)
    check got.len == want.len
    for i in 0 ..< want.len:
      check got[i].fn.name == want[i].fn.name
      check got[i].fn.file == want[i].fn.file
      check got[i].fn.defLine == want[i].fn.defLine
      check got[i].shallow == want[i].shallow

  test "round_trips_through_the_file_via_default_codec":
    # The DEFAULT-codec path (no explicit codec arg) writes + reads a CTFS-backed
    # artifact file losslessly.
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "three_funcs.roothash.bin"
    let built = buildArtifact(testId, threeFuncsTrace, sourceRoot)
    require built.isOk
    require writeArtifact(built.value, artifactPath).isOk
    require fileExists(artifactPath)
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    check loaded.value.rootHash == built.value.rootHash
    check loaded.value.executedFunctions.len == built.value.executedFunctions.len
    check loaded.value.deterministic == built.value.deterministic
    check loaded.value.readFiles.len == 0  # reserved M6 slot, still empty

  test "read_files_sidecar_survives_the_ctfs_codec":
    # The M6 read-file slot (path + hash) is carried losslessly even though the
    # store's file namespace only persists the path: the hash rides the sidecar.
    var a = buildArtifact(testId, threeFuncsTrace, makeSourceRoot()).value
    a.readFiles = @[ReadFileDep(path: "data/x.json", hash: "deadbeef"),
                    ReadFileDep(path: "data/y.json", hash: "cafef00d")]
    let codec = ctfsNamespaceCodec()
    let dec = codec.decode(codec.encode(a).value)
    require dec.isOk
    check dec.value.readFiles.len == 2
    var paths, hashes: seq[string]
    for rf in dec.value.readFiles:
      paths.add rf.path; hashes.add rf.hash
    check "data/x.json" in paths
    check "deadbeef" in hashes
    check "cafef00d" in hashes

  test "non_deterministic_flag_survives_the_ctfs_codec":
    var a = buildArtifact(testId, threeFuncsTrace, makeSourceRoot()).value
    a.deterministic = false
    let codec = ctfsNamespaceCodec()
    let dec = codec.decode(codec.encode(a).value)
    require dec.isOk
    check dec.value.deterministic == false

  # ---- M2's e2e re-decide semantics, now through the CTFS-backed file ----

  proc writeBaseline(sourceRoot, artifactPath: string) =
    let built = buildArtifact(testId, threeFuncsTrace, sourceRoot)
    doAssert built.isOk, built.error
    doAssert writeArtifact(built.value, artifactPath).isOk

  test "unchanged_tree_skips_via_ctfs_artifact":
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "a.bin"
    writeBaseline(sourceRoot, artifactPath)
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    let d = redecideFromArtifact(loaded.value, threeFuncsTrace, sourceRoot)
    check d.kind == idSkipUnchanged

  test "editing_executed_function_reruns_and_names_it_via_ctfs_artifact":
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "a.bin"
    writeBaseline(sourceRoot, artifactPath)
    editFunctionBody(sourceRoot, "used_a", "42 + 1")
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    let d = redecideFromArtifact(loaded.value, threeFuncsTrace, sourceRoot)
    check d.kind == idRerunChanged
    check isRerun(d)
    check "used_a" in d.changedFuncs
    check "used_b" notin d.changedFuncs

  test "editing_non_executed_function_skips_via_ctfs_artifact":
    let sourceRoot = makeSourceRoot()
    let artifactPath = sourceRoot / "a.bin"
    writeBaseline(sourceRoot, artifactPath)
    editFunctionBody(sourceRoot, "unused_c", "999")
    let loaded = readArtifact(artifactPath)
    require loaded.isOk
    let d = redecideFromArtifact(loaded.value, threeFuncsTrace, sourceRoot)
    check d.kind == idSkipUnchanged
