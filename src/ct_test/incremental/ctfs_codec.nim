{.push raises: [].}

## The CTFS-namespace-backed `RootHashArtifactCodec` — the M4a schema-alignment
## deliverable of the Incremental-Test-Runner campaign.
##
## M2 (`root_hash.nim`) deliberately routed all artifact persistence through a
## swappable `RootHashArtifactCodec` boundary so the on-disk FORMAT could change
## in M4 WITHOUT touching the root-hash rule, the schema, or the CLI. M3
## (corrected) decided the format: persist as CTFS **B-tree NAMESPACES** keyed on
## compact numeric ids. This module is that swap — a codec that serializes a
## `RootHashArtifact` through the namespace-backed `CtfsStore` (`ctfs_store.nim`)
## instead of the provisional JSON.
##
## # The numeric-id model (M2's schema evolved)
##
## M2's artifact was a per-test `{testId:string, rootHash, executedFunctions,
## deterministic, readFiles}`. M4a aligns it to the numeric-id, namespace-backed
## model: the artifact becomes ONE `StoreTest` whose `testId = key64(testName)`,
## stored across the store's namespaces (interning `testId -> name`, deep forward
## `testId -> rootHash`, shallow reverse `functionId -> {shallow, [testId]}`,
## and the M6 file-reverse slot). The LOGICAL semantics M2 guaranteed are
## preserved EXACTLY: the per-test root hash and the executed-function set (each
## function's identity + recorded shallow hash) round-trip losslessly, so
## `redecideFromArtifact` re-decides identically. The only change is the bytes on
## disk (a `CtfsStore` container, not a JSON document) — the M2 swap contract.
##
## # Why a single-test store
##
## The M2 codec boundary is per-artifact (one test). A `CtfsStore` naturally
## holds many tests, but for the per-test artifact this module builds a
## single-`StoreTest` store. The daemon (M4c) will hold a MULTI-test store in
## memory; the on-disk per-test artifact is the file-mode projection of one
## entry, mirroring how M2's per-test JSON projected one `CachedTest`.

import std/algorithm
import results

import trace_reader   # ExecutedFunction
import engine         # CachedDep
import root_hash      # RootHashArtifact, RootHashArtifactCodec, ReadFileDep
import ctfs_store     # CtfsStore, StoreTest, key64, functionKey, ...

export results

# ---------------------------------------------------------------------------
# Artifact <-> single-test CtfsStore bridge
# ---------------------------------------------------------------------------

proc artifactToStore(a: RootHashArtifact): Result[CtfsStore, string] =
  ## Project the per-test artifact into a single-`StoreTest` `CtfsStore`. The
  ## test id is the compact `key64(testId-string)` (the numeric-id model); the
  ## executed functions become the store's shallow reverse structure; the M6
  ## read files seed the file reverse index.
  var reads: seq[tuple[path: string, mtime: int64]]
  for rf in a.readFiles:
    # M2 carries read files as {path, hash}; the store's file slot carries
    # {path, mtime}. M6 will fold hashes in; for now mtime is 0 (unknown) and
    # the hash is preserved separately by the artifact's own readFiles (not lost
    # — see storeToArtifact, which reads the path set back; the per-file hash is
    # an M6 concern the store does not yet persist).
    reads.add (path: rf.path, mtime: 0'i64)
  let st = StoreTest(
    testId: key64(a.testId),
    testName: a.testId,
    rootHash: a.rootHash,
    deps: a.executedFunctions,
    readFiles: reads)
  buildStore(@[st])

proc storeToArtifact(s: CtfsStore, testIdStr: string;
                     deterministic: bool;
                     readFiles: seq[ReadFileDep]):
    Result[RootHashArtifact, string] =
  ## Reconstruct the per-test artifact from a single-test store. The test id
  ## string is recovered from the interning table; the root hash from the deep
  ## forward map; the executed-function set (identity + shallow) from the shallow
  ## reverse structure (every function whose reverse set contains this test).
  let tid = key64(testIdStr)

  # Recover the test name from interning (asserts the store round-trips it).
  let nameRes = s.testName(tid)
  if nameRes.isErr: return err(nameRes.error)
  if nameRes.value.isNone: return err("store missing test name for id")
  let name = nameRes.value.get

  # Root hash from the deep-forward map.
  let deepRes = s.deepHashOf(tid)
  if deepRes.isErr: return err(deepRes.error)
  if deepRes.value.isNone: return err("store missing deep hash for test")
  let rootHash = deepRes.value.get

  # Executed-function set: walk every function id, keep those whose reverse set
  # contains this test, and rebuild a `CachedDep` from the stored shallow entry.
  let fidsRes = s.functionIds()
  if fidsRes.isErr: return err(fidsRes.error)
  var deps: seq[CachedDep]
  for fid in fidsRes.value:
    let eRes = s.shallowEntryOf(fid)
    if eRes.isErr: return err(eRes.error)
    if eRes.value.isNone: continue
    let e = eRes.value.get
    if tid notin e.testIds: continue
    deps.add CachedDep(
      fn: ExecutedFunction(name: e.name, file: e.file, defLine: e.defLine),
      shallow: e.shallow)
  # Deterministic ordering (the JSON codec sorted by name/file/defLine).
  deps.sort(proc (x, y: CachedDep): int =
    result = cmp(x.fn.name, y.fn.name)
    if result == 0: result = cmp(x.fn.file, y.fn.file)
    if result == 0: result = cmp(x.fn.defLine, y.fn.defLine))

  ok(RootHashArtifact(
    testId: name,
    rootHash: rootHash,
    executedFunctions: deps,
    deterministic: deterministic,
    readFiles: readFiles))

# ---------------------------------------------------------------------------
# Sidecar header — the few scalar fields the store's namespaces do not carry
# ---------------------------------------------------------------------------
#
# The store's namespaces carry the test name, root hash, executed-function set
# (identity + shallow), and the read-file PATH set. They do NOT carry the
# per-test `deterministic` flag or the per-read-file HASH (an M6 concern). The
# CTFS-backed artifact prepends a tiny self-describing sidecar with exactly
# those fields so the artifact remains a COMPLETE re-decide input (M2's
# guarantee), then concatenates the serialized store. This keeps the namespace
# images byte-aligned with the M3 bench model while losslessly carrying M2's
# full logical content.

const CtfsArtifactMagic = ['C', 'T', 'A', '1']  ## CTFS-backed artifact, format 1

proc putU32(buf: var seq[byte], v: uint32) =
  for i in 0 ..< 4: buf.add byte((v shr (i * 8)) and 0xFF)

proc putU64(buf: var seq[byte], v: uint64) =
  for i in 0 ..< 8: buf.add byte((v shr (i * 8)) and 0xFF)

proc putStr(buf: var seq[byte], s: string) =
  putU32(buf, uint32(s.len))
  for ch in s: buf.add byte(ch)

proc getU32(data: openArray[byte], off: var int): Result[uint32, string] =
  if off + 4 > data.len: return err("truncated u32")
  var v: uint32
  for i in 0 ..< 4: v = v or (uint32(data[off + i]) shl (i * 8))
  off += 4
  ok(v)

proc getU64(data: openArray[byte], off: var int): Result[uint64, string] =
  if off + 8 > data.len: return err("truncated u64")
  var v: uint64
  for i in 0 ..< 8: v = v or (uint64(data[off + i]) shl (i * 8))
  off += 8
  ok(v)

proc getStr(data: openArray[byte], off: var int): Result[string, string] =
  let n = getU32(data, off)
  if n.isErr: return err(n.error)
  let len = int(n.value)
  if off + len > data.len: return err("truncated string")
  var s = newStringOfCap(len)
  for i in 0 ..< len: s.add char(data[off + i])
  off += len
  ok(s)

proc encodeCtfs(a: RootHashArtifact): Result[string, string]
    {.nimcall, gcsafe.} =
  ## Serialize the artifact to the CTFS-namespace-backed container: a sidecar
  ## header (magic, testId string, deterministic, read-file hashes) followed by
  ## the serialized single-test `CtfsStore`.
  let storeRes = artifactToStore(a)
  if storeRes.isErr: return err("ctfs artifact build: " & storeRes.error)
  let storeBytes = storeRes.value.serialize()

  var buf: seq[byte]
  for ch in CtfsArtifactMagic: buf.add byte(ch)
  putStr(buf, a.testId)
  buf.add (if a.deterministic: 1'u8 else: 0'u8)
  # Read-file hashes (paths live in the store's file namespaces; the hash is an
  # M2-carried value the store does not yet persist — keep it in the sidecar so
  # the artifact stays a lossless re-decide input).
  putU32(buf, uint32(a.readFiles.len))
  for rf in a.readFiles:
    putStr(buf, rf.path)
    putStr(buf, rf.hash)
  putU64(buf, uint64(storeBytes.len))
  for b in storeBytes: buf.add b

  # The codec boundary is `string`-typed (it predates the binary format); carry
  # the bytes verbatim in a string (1 byte per char, no transcoding).
  var s = newStringOfCap(buf.len)
  for b in buf: s.add char(b)
  ok(s)

proc decodeCtfs(bytes: string): Result[RootHashArtifact, string]
    {.nimcall, gcsafe.} =
  ## Parse a CTFS-namespace-backed artifact container: validate the sidecar,
  ## reload the store, and reconstruct the artifact (root hash + executed set +
  ## deterministic + read files) losslessly.
  var data = newSeq[byte](bytes.len)
  for i in 0 ..< bytes.len: data[i] = byte(bytes[i])
  if data.len < 4:
    return err("ctfs artifact too short")
  for i in 0 ..< 4:
    if char(data[i]) != CtfsArtifactMagic[i]:
      return err("invalid ctfs artifact magic")
  var off = 4
  let testIdRes = getStr(data, off)
  if testIdRes.isErr: return err(testIdRes.error)
  if off >= data.len: return err("ctfs artifact truncated at deterministic")
  let deterministic = data[off] != 0
  off += 1
  let nReads = getU32(data, off)
  if nReads.isErr: return err(nReads.error)
  var readFiles: seq[ReadFileDep]
  for _ in 0 ..< int(nReads.value):
    let p = getStr(data, off)
    if p.isErr: return err(p.error)
    let h = getStr(data, off)
    if h.isErr: return err(h.error)
    readFiles.add ReadFileDep(path: p.value, hash: h.value)
  let storeLen = getU64(data, off)
  if storeLen.isErr: return err(storeLen.error)
  if off + int(storeLen.value) > data.len:
    return err("ctfs artifact store region truncated")
  let storeBytes = data[off ..< off + int(storeLen.value)]
  let storeRes = loadStore(storeBytes)
  if storeRes.isErr: return err("ctfs artifact store load: " & storeRes.error)
  storeToArtifact(storeRes.value, testIdRes.value, deterministic, readFiles)

proc ctfsNamespaceCodec*(): RootHashArtifactCodec =
  ## The M4a CTFS-namespace-backed codec: serializes the per-test artifact
  ## through the `CtfsStore` (CoW B-tree namespaces), byte-aligned with the M3
  ## bench model. Drop-in for `provisionalJsonCodec` behind the M2
  ## `RootHashArtifactCodec` boundary — same schema, same logical semantics,
  ## different on-disk bytes.
  RootHashArtifactCodec(name: "ctfs-ns", encode: encodeCtfs, decode: decodeCtfs)

# Install the CTFS-namespace codec as the process-wide default the moment this
# module is linked (the M4a wholesale format swap behind M2's boundary). Any
# module importing `ctfs_codec` — the CLI, the M4a tests — now persists the
# per-test artifact through the CoW B-tree namespaces. Modules that do NOT
# import `ctfs_codec` keep the provisional JSON default, so `root_hash` stays
# usable stand-alone.
setDefaultCodec(ctfsNamespaceCodec())
