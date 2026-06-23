## M2 — `test_root_hash_stable_and_sensitive`.
##
## The per-test ROOT HASH (§16.7.3, computed by `engine.deepHash` and exposed via
## `root_hash.rootHashOfDeps` / the recorded `CachedTest.deepHash`) must satisfy
## all four invariants the milestone names, asserted here against REAL recorded
## state — never constants:
##
##   (a) STABLE across identical reruns of the same trace over the same source
##       (the sorted-by-name fold removes call-order dependence);
##   (b) CHANGES when an EXECUTED function's shallow hash changes (a body edit
##       flows through that function's shallow hash into the fold);
##   (c) CHANGES when the executed SET changes (a function added / removed
##       alters the pairs folded in); and
##   (d) UNCHANGED when a NON-executed function's body changes (it is not in the
##       executed set, so it never contributes to the root hash).
##
## The driver reuses the committed M0 `m0_three_funcs` Ruby fixture (an
## interpreted SOURCE-path trace: `main` executes `used_a`/`used_b`; `unused_c`
## is defined but never called) so the test is self-contained and exercises the
## production engine extraction + source-text shallow hashing the artifact reuses.
##
## Invariant (c) — the executed-SET sensitivity — is asserted DIRECTLY over the
## root-hash rule (`rootHashOfDeps`) by adding / removing a dependency from a
## recorded set, since the fixed fixture trace cannot itself change which
## functions it executed.

import std/[unittest, os, strutils, times, tables]

import engine        # record, decide, initCache, CachedDep, deepHash, ExecutedFunction
import root_hash     # rootHashOfDeps, buildArtifact, fromCachedTest

const
  fixturesDir = currentSourcePath().parentDir / "fixtures"
  threeFuncsFixture = fixturesDir / "m0_three_funcs"
  threeFuncsTrace = threeFuncsFixture / "trace"
  relSourcePath = "fixtures/m0_three_funcs/src/three_funcs.rb"
  testId = "fixture::three_funcs"

var counter = 0

proc makeSourceRoot(): string =
  ## Fresh temp dir with the fixture source copied to the path the trace expects
  ## (the trace records `/fixtures/m0_three_funcs/src/three_funcs.rb`; the engine
  ## strips the leading slash and resolves under sourceRoot).
  inc counter
  let stamp = (epochTime() * 1_000_000.0).int64
  let root = getTempDir() / ("ct_m2_roothash_" & $stamp & "_" & $counter)
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

proc recordedRootHash(root: string): string =
  ## Record the fixture trace against the source under `root` and return the
  ## per-test root hash of the recorded entry — i.e. the value the artifact
  ## persists. Goes through the REAL engine extraction + shallow hashing.
  var cache = initCache(root / "cache.json")
  let rec = record(cache, testId, threeFuncsTrace, root)
  doAssert rec.isOk, "record failed: " & rec.error
  let entry = cache.entries[testId]
  # The recorded deep hash IS the root hash; rootHashOfDeps over the recorded
  # deps must agree (the artifact projection carries the same value).
  doAssert rootHashOfDeps(entry.deps) == entry.deepHash
  entry.deepHash

suite "M2 — root hash stable and sensitive (§16.7.3)":

  test "stable_across_identical_reruns":
    # (a) Two independent records of the SAME trace over the SAME (freshly copied,
    # unedited) source yield the SAME root hash.
    let rootA = makeSourceRoot()
    let rootB = makeSourceRoot()
    let hA = recordedRootHash(rootA)
    let hB = recordedRootHash(rootB)
    check hA == hB
    check hA.len > 0
    # And recomputing over the very same recorded source is idempotent.
    check recordedRootHash(rootA) == hA

  test "changes_when_executed_function_body_changes":
    # (b) Editing an EXECUTED function (`used_a`) changes the root hash.
    let baseRoot = makeSourceRoot()
    let baseHash = recordedRootHash(baseRoot)
    let editedRoot = makeSourceRoot()
    editFunctionBody(editedRoot, "used_a", "42 + 1")
    let editedHash = recordedRootHash(editedRoot)
    check editedHash != baseHash

  test "unchanged_when_non_executed_function_body_changes":
    # (d) Editing the NON-executed `unused_c` does NOT change the root hash — it
    # is not in the executed set, so it never enters the fold.
    let baseRoot = makeSourceRoot()
    let baseHash = recordedRootHash(baseRoot)
    let editedRoot = makeSourceRoot()
    editFunctionBody(editedRoot, "unused_c", "999")
    let editedHash = recordedRootHash(editedRoot)
    check editedHash == baseHash

  test "changes_when_executed_set_changes_added_or_removed":
    # (c) The root hash is computed over the executed SET, so adding or removing a
    # dependency changes it. We assert this DIRECTLY over the rule
    # (`rootHashOfDeps`) since the fixed fixture trace cannot vary its own set.
    let baseDeps = @[
      CachedDep(fn: ExecutedFunction(name: "used_a", file: "a.rb", defLine: 1),
                shallow: "hashA"),
      CachedDep(fn: ExecutedFunction(name: "used_b", file: "b.rb", defLine: 5),
                shallow: "hashB")]
    let baseHash = rootHashOfDeps(baseDeps)

    # Remove a function from the executed set ⇒ different root hash.
    let removedDeps = @[baseDeps[0]]
    check rootHashOfDeps(removedDeps) != baseHash

    # Add a function to the executed set ⇒ different root hash.
    let addedDeps = baseDeps & @[
      CachedDep(fn: ExecutedFunction(name: "used_c", file: "c.rb", defLine: 9),
                shallow: "hashC")]
    check rootHashOfDeps(addedDeps) != baseHash

    # And the rule is ORDER-INDEPENDENT over the set: the same pairs in reverse
    # order produce the SAME root hash (the §16.7.3 sort).
    let reversed = @[baseDeps[1], baseDeps[0]]
    check rootHashOfDeps(reversed) == baseHash

  test "changes_iff_a_pairs_shallow_hash_changes":
    # Sharpen (b): changing exactly ONE function's shallow hash changes the root
    # hash, and changing nothing leaves it identical — the fold is sensitive to
    # each pair's shallow hash and to nothing else.
    let deps = @[
      CachedDep(fn: ExecutedFunction(name: "f", file: "x.rb", defLine: 1),
                shallow: "h1"),
      CachedDep(fn: ExecutedFunction(name: "g", file: "x.rb", defLine: 4),
                shallow: "h2")]
    let h0 = rootHashOfDeps(deps)
    var changed = deps
    changed[0].shallow = "h1-prime"
    check rootHashOfDeps(changed) != h0
    # Identity (same pairs) ⇒ identical hash.
    check rootHashOfDeps(deps) == h0
