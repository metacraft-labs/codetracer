{.push raises: [].}

## CTFS-namespace-backed storage for the Incremental-Test-Runner per-test
## maps — the M4a deliverable of the Incremental-Test-Runner campaign.
##
## # What this module is
##
## M3 (corrected benchmark) confirmed the per-test root-hash maps must be
## persisted as CTFS **B-tree NAMESPACES** — the `NSB1` copy-on-write B-tree
## (`codetracer_ctfs/cow_btree.nim`, the Nim writer/reader byte-compatible with
## the Rust `CowNamespaceWriter`/`CowNamespaceReader` per the CTFS campaign).
## This module builds the REFINED data model the team confirmed — all keyed on
## COMPACT NUMERIC ids via FNV-1a string interning — on top of that B-tree:
##
##   1. **Interning** — `testId -> name`, `functionId -> identity`,
##      `fileId -> path` payload-addressed namespaces. The REVERSE direction
##      (`name -> id`) is just `key64(name)` (a pure FNV-1a hash), so no
##      `name -> id` map is stored — exactly the Rust bench model's approach.
##   2. **Deep-hash forward map** — `testId -> one root hash` (the Nim
##      `symBodyHash`/deep-hash case; the artifact's `rootHash`).
##   3. **Shallow reverse structure** — `functionId -> { shallow hash,
##      [testIds that executed it] }`. This is the PRIMARY shallow structure:
##      the per-function recorded shallow hash PLUS the reverse map, built by
##      INVERTING the per-test executed-function sets the engine collects. The
##      shallow query path keys on `functionId`, NOT `testId`.
##   4. **File reverse index** (M6 slot) — `fileId -> { [testIds that read it],
##      mtime }`. Populated minimally now (read files are the reserved M6 slot);
##      M6 fills it.
##
## The byte layout MIRRORS the M3 reference model
## (`tracing-formats-benchmarks/benches_crate/src/roothash_map.rs`,
## module `ctfs_ns`): every structure is a Type-B
## (`[offset:u64][len:u64]` descriptor) payload-addressed namespace — a sizing
## pass learns the committed page-image length so payload offsets are absolute
## into the final image, then the real build appends the payload region and
## page-pads. `key64` is the SAME FNV-1a 64-bit hash. The on-disk value codecs
## (`encode_shallow_value` / the LE-u64 id set) are byte-identical to the
## reference, so the Nim store and the Rust bench produce conceptually identical
## (and where the value codec coincides, byte-identical) namespace images.
##
## # Daemon vs file mode (groundwork; the loop is M4c)
##
## A `CtfsStore` holds the in-memory `CowBTree`s. `serialize`/`load` flush them
## to / restore them from on-disk bytes (the file mode). A daemon would simply
## KEEP the same `CtfsStore` in memory and never flush — the `keepInMemory`
## flag distinguishes the two intents. The daemon LOOP (filter "run all",
## update only executed) is M4c and is NOT implemented here.

import std/[algorithm, tables, options, sets]
import results

import codetracer_ctfs/cow_btree

import trace_reader   # ExecutedFunction
import engine         # CachedDep, CachedTest

export results

# ---------------------------------------------------------------------------
# Compact-id interning hash (FNV-1a 64-bit) — byte-identical to the M3 bench
# `key64` so the Nim store and the Rust reference produce the same keys.
# ---------------------------------------------------------------------------

const
  Fnv64OffsetBasis = 0xcbf29ce484222325'u64
  Fnv64Prime = 0x00000100000001b3'u64

proc key64*(s: string): uint64 =
  ## FNV-1a 64-bit hash of `s`. The compact numeric id used as the namespace
  ## key for every structure. Identical to the Rust bench `key64` (same basis,
  ## same prime, same byte order), so a name interns to the SAME id on both
  ## sides — the cross-language byte-alignment the campaign requires.
  result = Fnv64OffsetBasis
  for ch in s:
    result = result xor uint64(byte(ch))
    result = result * Fnv64Prime

proc functionKey*(fn: ExecutedFunction): uint64 =
  ## The compact id for an executed function's IDENTITY. Mirrors the Rust bench
  ## (`key64("{name}\0{file}\0{def_line}")`) so two distinct functions that
  ## share a name but differ in file/defLine get distinct ids, and the SAME
  ## function always interns to the same id across runs.
  key64(fn.name & "\0" & fn.file & "\0" & $fn.defLine)

# ---------------------------------------------------------------------------
# Little-endian helpers (match the Rust value codecs byte-for-byte)
# ---------------------------------------------------------------------------

proc putU32(buf: var seq[byte], v: uint32) =
  for i in 0 ..< 4: buf.add byte((v shr (i * 8)) and 0xFF)

proc putU64(buf: var seq[byte], v: uint64) =
  for i in 0 ..< 8: buf.add byte((v shr (i * 8)) and 0xFF)

proc putI64(buf: var seq[byte], v: int64) =
  putU64(buf, cast[uint64](v))

proc putStr(buf: var seq[byte], s: string) =
  ## `[len:u32 LE][utf8 bytes]` — the Rust `put_str`.
  putU32(buf, uint32(s.len))
  for ch in s: buf.add byte(ch)

proc asBytes(s: string): seq[byte] =
  ## A raw byte copy of a string (no length prefix) — the interning value codec.
  for ch in s: result.add byte(ch)

proc getU32(data: openArray[byte], off: var int): Result[uint32, string] =
  if off + 4 > data.len: return err("truncated u32 at " & $off)
  var v: uint32
  for i in 0 ..< 4: v = v or (uint32(data[off + i]) shl (i * 8))
  off += 4
  ok(v)

proc getU64(data: openArray[byte], off: var int): Result[uint64, string] =
  if off + 8 > data.len: return err("truncated u64 at " & $off)
  var v: uint64
  for i in 0 ..< 8: v = v or (uint64(data[off + i]) shl (i * 8))
  off += 8
  ok(v)

proc getI64(data: openArray[byte], off: var int): Result[int64, string] =
  let r = getU64(data, off)
  if r.isErr: return err(r.error)
  ok(cast[int64](r.value))

proc getStr(data: openArray[byte], off: var int): Result[string, string] =
  let lenRes = getU32(data, off)
  if lenRes.isErr: return err(lenRes.error)
  let n = int(lenRes.value)
  if off + n > data.len: return err("truncated string body at " & $off)
  var s = newStringOfCap(n)
  for i in 0 ..< n: s.add char(data[off + i])
  off += n
  ok(s)

# ---------------------------------------------------------------------------
# Value codecs — the per-record wire shapes (byte-identical to the M3 bench)
# ---------------------------------------------------------------------------

type
  ShallowEntry* = object
    ## The value of the shallow reverse structure for one function id: the
    ## function's recorded shallow hash, its identity (so a reader can rebuild a
    ## `CachedDep` / re-hash it), and the set of test ids that executed it.
    shallow*: string
    name*: string
    file*: string
    defLine*: int
    testIds*: seq[uint64]

  FileEntry* = object
    ## The value of the file reverse index for one file id (M6 slot): the file's
    ## path, its recorded mtime (or 0 when unknown), and the set of test ids that
    ## read it. Empty `testIds` until M6 populates read files.
    path*: string
    mtime*: int64
    testIds*: seq[uint64]

proc encodeIdSet(ids: seq[uint64]): seq[byte] =
  ## A `testId` set as a contiguous LE-u64 array — the Rust `encode_id_set`.
  ## Ids are sorted + de-duplicated for a deterministic, canonical encoding.
  var sorted = ids
  sorted.sort()
  var prev = false
  var last: uint64
  for id in sorted:
    if prev and id == last: continue
    putU64(result, id)
    last = id
    prev = true

proc decodeIdSet(payload: openArray[byte]): seq[uint64] =
  ## Decode a contiguous LE-u64 id array — the Rust `decode_id_set`.
  var off = 0
  while off + 8 <= payload.len:
    var v: uint64
    for i in 0 ..< 8: v = v or (uint64(payload[off + i]) shl (i * 8))
    result.add v
    off += 8

proc encodeShallowEntry(e: ShallowEntry): seq[byte] =
  ## `[len:u32]shallow | [str]name | [str]file | defLine:i64 | id-set`.
  putStr(result, e.shallow)
  putStr(result, e.name)
  putStr(result, e.file)
  putI64(result, int64(e.defLine))
  let ids = encodeIdSet(e.testIds)
  putU32(result, uint32(ids.len div 8))
  for b in ids: result.add b

proc decodeShallowEntry(payload: openArray[byte]): Result[ShallowEntry, string] =
  var off = 0
  let sh = getStr(payload, off);  if sh.isErr: return err(sh.error)
  let nm = getStr(payload, off);  if nm.isErr: return err(nm.error)
  let fl = getStr(payload, off);  if fl.isErr: return err(fl.error)
  let dl = getI64(payload, off);  if dl.isErr: return err(dl.error)
  let cnt = getU32(payload, off); if cnt.isErr: return err(cnt.error)
  var ids: seq[uint64]
  for _ in 0 ..< int(cnt.value):
    let id = getU64(payload, off)
    if id.isErr: return err(id.error)
    ids.add id.value
  ok(ShallowEntry(shallow: sh.value, name: nm.value, file: fl.value,
                  defLine: int(dl.value), testIds: ids))

proc encodeFileEntry(e: FileEntry): seq[byte] =
  ## `[str]path | mtime:i64 | id-set` (M6 read-file slot value).
  putStr(result, e.path)
  putI64(result, e.mtime)
  let ids = encodeIdSet(e.testIds)
  putU32(result, uint32(ids.len div 8))
  for b in ids: result.add b

proc decodeFileEntry(payload: openArray[byte]): Result[FileEntry, string] =
  var off = 0
  let p = getStr(payload, off);  if p.isErr: return err(p.error)
  let mt = getI64(payload, off); if mt.isErr: return err(mt.error)
  let cnt = getU32(payload, off); if cnt.isErr: return err(cnt.error)
  var ids: seq[uint64]
  for _ in 0 ..< int(cnt.value):
    let id = getU64(payload, off)
    if id.isErr: return err(id.error)
    ids.add id.value
  ok(FileEntry(path: p.value, mtime: mt.value, testIds: ids))

# ---------------------------------------------------------------------------
# Payload-addressed Type-B namespace build + read (mirrors the bench `ctfs_ns`)
# ---------------------------------------------------------------------------

const PageSizeBytes = PageSize  ## one CTFS block == one B-tree page (cow_btree)

proc descriptor16(offset, len: uint64): seq[byte] =
  ## A Type-B `[offset:u64][len:u64]` descriptor (16 bytes) into the payload
  ## region — the production `memwrites.tc` layout.
  result = newSeq[byte](16)
  for i in 0 ..< 8: result[i] = byte((offset shr (i * 8)) and 0xFF)
  for i in 0 ..< 8: result[8 + i] = byte((len shr (i * 8)) and 0xFF)

proc readU64(buf: openArray[byte], off: int): uint64 =
  for i in 0 ..< 8: result = result or (uint64(buf[off + i]) shl (i * 8))

proc pageImageLen(image: openArray[byte]): int =
  ## The byte length of the NSB1 PAGE region of a payload-addressed image: the
  ## header `page_count` field (`cow_btree` `OffPageCount == 53`) times the page
  ## size. Mirrors the Rust `page_image_len`. The payload region is everything
  ## after this. (`loadCowBTree` treats its whole input as the page buffer, so we
  ## must split on the header's own page_count, NOT on the buffer length.)
  if image.len < 53 + 8: return image.len
  int(readU64(image, 53)) * PageSizeBytes

proc buildPayloadNamespace(pairs: seq[(uint64, seq[byte])]):
    Result[seq[byte], string] =
  ## Build a payload-addressed Type-B namespace from sorted `(key, value)`
  ## pairs — the Nim port of the bench `build_payload_ns`:
  ##   1. SIZING PASS: insert each key with a placeholder 16-byte descriptor to
  ##      learn the committed page-image length (the absolute payload base).
  ##   2. REAL BUILD: insert each key with a descriptor addressing its value at
  ##      its absolute offset, then append the payload region and page-pad.
  ##
  ## `pairs` MUST be sorted by key (the callers sort).
  var sizing = initCowBTree(cltTypeB, skipSubBlocks = true)
  let placeholder = newSeq[byte](16)
  for (k, _) in pairs:
    let r = sizing.insertAndCommit(k, placeholder)
    if r.isErr: return err("sizing insert failed: " & r.error)
  let payloadBase = sizing.serialize().len

  var writer = initCowBTree(cltTypeB, skipSubBlocks = true)
  var payload: seq[byte]
  for (k, v) in pairs:
    let offset = uint64(payloadBase + payload.len)
    for b in v: payload.add b
    let r = writer.insertAndCommit(k, descriptor16(offset, uint64(v.len)))
    if r.isErr: return err("build insert failed: " & r.error)

  var image = writer.serialize()
  for b in payload: image.add b
  while image.len mod PageSizeBytes != 0:
    image.add 0'u8
  ok(image)

proc lookupPayload(image: openArray[byte], key: uint64):
    Result[Option[seq[byte]], string] =
  ## Look up one key's payload bytes in a payload-addressed Type-B image.
  ## `none` means the key is absent; an `Err` means the image is malformed.
  let loaded = loadCowBTree(@image, cltTypeB)
  if loaded.isErr:
    return err(loaded.error)
  let lk = loaded.value.lookup(key)
  if lk.isErr:
    # A missing key is `none`, not an error (matches the bench's KeyNotFound).
    return ok(none(seq[byte]))
  let desc = lk.value
  if desc.len < 16:
    return err("descriptor too short")
  let offset = int(readU64(desc, 0))
  let length = int(readU64(desc, 8))
  if offset + length > image.len:
    return err("payload descriptor out of range")
  var v = newSeq[byte](length)
  for i in 0 ..< length: v[i] = image[offset + i]
  ok(some(v))

proc allKeys(image: openArray[byte]): Result[seq[uint64], string] =
  ## All committed keys of a payload-addressed image in ascending order.
  ##
  ## A GENUINELY EMPTY store is a fully-formed canonical empty namespace image
  ## (one zeroed page) that `loadCowBTree` accepts and reports zero keys for — so
  ## a real load failure here means the image is MALFORMED/CORRUPT, NOT empty. We
  ## must NOT swallow that into `ok(@[])`: the suite-level invalidation query
  ## derives its test universe from these keys, and silently returning an empty
  ## key set for a corrupt image would make the query SKIP EVERY TEST — a false
  ## skip, the one outcome the runner must never produce. So a load failure is
  ## propagated as an `Err`, which the invalidation query turns into a re-run
  ## (the caller re-runs the whole suite). (An empty image still round-trips
  ## through `loadCowBTree` to `ok(@[])`; see `test_ctfs_namespace_storage_*`.)
  let loaded = loadCowBTree(@image, cltTypeB)
  if loaded.isErr:
    return err("cannot enumerate namespace keys (corrupt image): " & loaded.error)
  loaded.value.keys()

export options

# ---------------------------------------------------------------------------
# CtfsStore — the five structures over the CoW B-tree namespaces
# ---------------------------------------------------------------------------

type
  CtfsStore* = object
    ## The namespace-backed storage for the incremental runner's per-test maps.
    ## Each field is one payload-addressed Type-B namespace IMAGE (the on-disk
    ## bytes). The store is BUILT from the record-time data the engine produces
    ## (the per-test executed-function sets + hashes), and serialized/reloaded
    ## losslessly. `keepInMemory` lays the groundwork for the M4c daemon (hold
    ## the images in memory, never flush); the daemon loop itself is M4c.
    interning*: seq[byte]      ## testId -> name
    funcInterning*: seq[byte]  ## functionId -> "name\0file\0defLine"
    fileInterning*: seq[byte]  ## fileId -> path
    deepForward*: seq[byte]    ## testId -> root hash (the Nim deep-hash case)
    shallowReverse*: seq[byte] ## functionId -> ShallowEntry (hash + reverse map)
    fileReverse*: seq[byte]    ## fileId -> FileEntry (M6 read-file slot)
    keepInMemory*: bool        ## daemon intent flag (M4c): never flush when true

  StoreTest* = object
    ## One test's record-time contribution to the store: its id/name, its deep
    ## (root) hash, and the executed-function set (each with its recorded shallow
    ## hash). This is exactly what the engine's `record` produces (a `CachedTest`
    ## projected with the test's name + id). `readFiles` is the reserved M6 slot.
    testId*: uint64
    testName*: string
    rootHash*: string
    deps*: seq[CachedDep]
    readFiles*: seq[tuple[path: string, mtime: int64]]

# ---------------------------------------------------------------------------
# Build the store from record-time data (INVERTING the per-test sets)
# ---------------------------------------------------------------------------

proc buildStore*(tests: seq[StoreTest]): Result[CtfsStore, string] =
  ## Build the whole store from the per-test record-time data. The interning
  ## tables map ids back to names; the deep-forward map is `testId -> rootHash`;
  ## the shallow reverse structure is built by INVERTING the per-test executed
  ## sets (`functionId -> { shallow, [testIds] }`); the file reverse index is
  ## built by inverting the per-test read-file sets (empty until M6).
  ##
  ## Every namespace is keyed on a compact numeric id (`key64`) and laid out as a
  ## payload-addressed Type-B namespace, byte-aligned with the M3 bench model.

  # ---- interning: testId -> name (sorted by id for deterministic layout) ----
  var nameById = initOrderedTable[uint64, string]()
  for t in tests:
    nameById[t.testId] = t.testName

  # ---- deep forward: testId -> rootHash ----
  var deepById = initOrderedTable[uint64, string]()
  for t in tests:
    deepById[t.testId] = t.rootHash

  # ---- shallow reverse: invert the per-test executed sets ----
  # functionId -> ShallowEntry. The shallow hash recorded for a given function
  # is the same across tests (it is the function's source/instruction hash), so
  # the FIRST occurrence sets shallow/identity and every test that executed it
  # is appended to the reverse `testIds` set.
  var funcEntries = initOrderedTable[uint64, ShallowEntry]()
  for t in tests:
    for dep in t.deps:
      let fid = functionKey(dep.fn)
      # `mgetOrPut` returns a mutable ref to the (existing or freshly inserted)
      # entry without raising — keeps the `{.push raises: [].}` contract while
      # appending the executing test id to the reverse set.
      let fresh = ShallowEntry(
        shallow: dep.shallow,
        name: dep.fn.name, file: dep.fn.file, defLine: dep.fn.defLine,
        testIds: @[])
      funcEntries.mgetOrPut(fid, fresh).testIds.add t.testId

  # ---- function interning: functionId -> identity ----
  var funcNameById = initOrderedTable[uint64, string]()
  for fid, e in funcEntries:
    funcNameById[fid] = e.name & "\0" & e.file & "\0" & $e.defLine

  # ---- file reverse + file interning: invert the per-test read-file sets ----
  var fileEntries = initOrderedTable[uint64, FileEntry]()
  var fileNameById = initOrderedTable[uint64, string]()
  for t in tests:
    for rf in t.readFiles:
      let fid = key64(rf.path)
      let fresh = FileEntry(path: rf.path, mtime: rf.mtime, testIds: @[])
      fileEntries.mgetOrPut(fid, fresh).testIds.add t.testId
      fileNameById[fid] = rf.path

  # Collect key-sorted (id, value-bytes) pairs (the B-tree wants ascending
  # keys). `pairs(tbl)` does not raise (unlike `tbl[id]`), keeping the
  # `{.push raises: [].}` contract; we sort the resulting seq by key.
  proc byKey(a, b: (uint64, seq[byte])): int = cmp(a[0], b[0])

  var nameP, funcNameP, fileNameP, deepP, shallowP, fileP: seq[(uint64, seq[byte])]
  for id, name in pairs(nameById): nameP.add (id, asBytes(name))
  for id, ident in pairs(funcNameById): funcNameP.add (id, asBytes(ident))
  for id, path in pairs(fileNameById): fileNameP.add (id, asBytes(path))
  for id, h in pairs(deepById): deepP.add (id, asBytes(h))
  for id, e in pairs(funcEntries): shallowP.add (id, encodeShallowEntry(e))
  for id, e in pairs(fileEntries): fileP.add (id, encodeFileEntry(e))
  nameP.sort(byKey); funcNameP.sort(byKey); fileNameP.sort(byKey)
  deepP.sort(byKey); shallowP.sort(byKey); fileP.sort(byKey)

  let interning = buildPayloadNamespace(nameP)
  if interning.isErr: return err("interning ns: " & interning.error)
  let funcInterning = buildPayloadNamespace(funcNameP)
  if funcInterning.isErr: return err("func interning ns: " & funcInterning.error)
  let fileInterning = buildPayloadNamespace(fileNameP)
  if fileInterning.isErr: return err("file interning ns: " & fileInterning.error)
  let deepForward = buildPayloadNamespace(deepP)
  if deepForward.isErr: return err("deep forward ns: " & deepForward.error)
  let shallowReverse = buildPayloadNamespace(shallowP)
  if shallowReverse.isErr: return err("shallow reverse ns: " & shallowReverse.error)
  let fileReverse = buildPayloadNamespace(fileP)
  if fileReverse.isErr: return err("file reverse ns: " & fileReverse.error)

  ok(CtfsStore(
    interning: interning.value,
    funcInterning: funcInterning.value,
    fileInterning: fileInterning.value,
    deepForward: deepForward.value,
    shallowReverse: shallowReverse.value,
    fileReverse: fileReverse.value,
    keepInMemory: false))

# ---------------------------------------------------------------------------
# Read-back accessors (lossless reload of each structure)
# ---------------------------------------------------------------------------

proc testName*(s: CtfsStore, testId: uint64): Result[Option[string], string] =
  ## Resolve a test id back to its name (the interning table id->name path).
  let p = lookupPayload(s.interning, testId)
  if p.isErr: return err(p.error)
  if p.value.isNone: return ok(none(string))
  var name = newStringOfCap(p.value.get.len)
  for b in p.value.get: name.add char(b)
  ok(some(name))

proc functionIdentity*(s: CtfsStore, functionId: uint64):
    Result[Option[string], string] =
  ## Resolve a function id back to its interned `"name\0file\0defLine"` identity.
  let p = lookupPayload(s.funcInterning, functionId)
  if p.isErr: return err(p.error)
  if p.value.isNone: return ok(none(string))
  var ident = newStringOfCap(p.value.get.len)
  for b in p.value.get: ident.add char(b)
  ok(some(ident))

proc filePath*(s: CtfsStore, fileId: uint64): Result[Option[string], string] =
  ## Resolve a file id back to its path (the file interning id->path path).
  let p = lookupPayload(s.fileInterning, fileId)
  if p.isErr: return err(p.error)
  if p.value.isNone: return ok(none(string))
  var path = newStringOfCap(p.value.get.len)
  for b in p.value.get: path.add char(b)
  ok(some(path))

proc deepHashOf*(s: CtfsStore, testId: uint64): Result[Option[string], string] =
  ## The test's deep (root) hash from the deep-forward map.
  let p = lookupPayload(s.deepForward, testId)
  if p.isErr: return err(p.error)
  if p.value.isNone: return ok(none(string))
  var h = newStringOfCap(p.value.get.len)
  for b in p.value.get: h.add char(b)
  ok(some(h))

proc shallowEntryOf*(s: CtfsStore, functionId: uint64):
    Result[Option[ShallowEntry], string] =
  ## The shallow reverse structure entry for a function: its recorded shallow
  ## hash, identity, and the set of test ids that executed it (the primary
  ## shallow query path — keyed on functionId, NOT testId).
  let p = lookupPayload(s.shallowReverse, functionId)
  if p.isErr: return err(p.error)
  if p.value.isNone: return ok(none(ShallowEntry))
  let e = decodeShallowEntry(p.value.get)
  if e.isErr: return err(e.error)
  ok(some(e.value))

proc fileEntryOf*(s: CtfsStore, fileId: uint64):
    Result[Option[FileEntry], string] =
  ## The file reverse index entry for a file (M6 slot): its path, mtime, and the
  ## set of test ids that read it.
  let p = lookupPayload(s.fileReverse, fileId)
  if p.isErr: return err(p.error)
  if p.value.isNone: return ok(none(FileEntry))
  let e = decodeFileEntry(p.value.get)
  if e.isErr: return err(e.error)
  ok(some(e.value))

proc testIds*(s: CtfsStore): Result[seq[uint64], string] =
  ## All test ids present in the deep-forward map (ascending).
  allKeys(s.deepForward)

proc functionIds*(s: CtfsStore): Result[seq[uint64], string] =
  ## All function ids present in the shallow reverse structure (ascending).
  allKeys(s.shallowReverse)

proc fileIds*(s: CtfsStore): Result[seq[uint64], string] =
  ## All file ids present in the file reverse index (ascending).
  allKeys(s.fileReverse)

# ---------------------------------------------------------------------------
# Point update (the daemon hot path; the loop itself is M4c)
# ---------------------------------------------------------------------------

proc pointUpdateDeep*(image: seq[byte], testId: uint64, newHash: string):
    Result[seq[byte], string] =
  ## Update ONE test's deep-forward entry copy-on-write — the daemon hot path
  ## (only executed tests update). Mirrors the bench `point_update_deep`:
  ## strip the payload region, reload the writer from the PAGE region alone,
  ## `insertAndCommit` a descriptor pointing at a freshly-appended value, then
  ## reassemble. On a rare spine split (the page image grows) the existing
  ## descriptors' absolute offsets shift, so we fall back to a full rebuild from
  ## the decoded contents (still correct; O(map) only on the split).
  let loadedFull = loadCowBTree(image, cltTypeB)
  if loadedFull.isErr:
    return err("cannot load deep-forward image: " & loadedFull.error)
  # The page region is the header's page_count * PageSize — NOT the whole buffer
  # length (`loadCowBTree` adopts the whole image, payload included, as its page
  # buffer). Splitting on page_count is what lets us reload the writer from ONLY
  # the page region and re-append the payload after the commit.
  let origPagesLen = pageImageLen(image)
  if origPagesLen > image.len:
    return err("page region larger than image")
  var pageRegion = newSeq[byte](origPagesLen)
  for i in 0 ..< origPagesLen: pageRegion[i] = image[i]
  let payloadRegion = image[origPagesLen ..< image.len]

  var writer = loadCowBTree(pageRegion, cltTypeB)
  if writer.isErr:
    return err("cannot resume writer: " & writer.error)
  var w = writer.value

  var newVal: seq[byte]
  for ch in newHash: newVal.add byte(ch)
  let newOffset = uint64(origPagesLen + payloadRegion.len)
  let r = w.insertAndCommit(testId, descriptor16(newOffset, uint64(newVal.len)))
  if r.isErr:
    return err("point-update insert failed: " & r.error)
  let newPages = w.serialize()

  if newPages.len == origPagesLen:
    # No split: existing descriptors' absolute offsets are still valid and our
    # provisional offset for the new value is correct.
    var rebuilt = newPages
    for b in payloadRegion: rebuilt.add b
    for b in newVal: rebuilt.add b
    while rebuilt.len mod PageSizeBytes != 0: rebuilt.add 0'u8
    return ok(rebuilt)

  # Rare: the spine grew. Rebuild the map cleanly from the decoded contents.
  let keysRes = allKeys(image)
  if keysRes.isErr: return err(keysRes.error)
  var pairs: seq[(uint64, seq[byte])]
  for k in keysRes.value:
    if k == testId: continue
    let p = lookupPayload(image, k)
    if p.isErr: return err(p.error)
    if p.value.isSome: pairs.add (k, p.value.get)
  pairs.add (testId, newVal)
  pairs.sort(proc (a, b: (uint64, seq[byte])): int = cmp(a[0], b[0]))
  buildPayloadNamespace(pairs)

# ---------------------------------------------------------------------------
# Generic namespace mutation (the substrate of the incremental store update)
# ---------------------------------------------------------------------------
#
# The M4c daemon updates ONLY the executed tests' entries: it must REMOVE a
# re-run test's OLD contributions from the reverse maps (its old functions'
# reverse sets, its old read-files' reader sets) and ADD its NEW ones, while
# leaving every skipped test's bytes untouched. The deep-forward map has a
# specialised O(log n) hot path (`pointUpdateDeep`); the reverse maps need
# arbitrary per-key upserts/removals (a function/file may gain or lose a single
# reader id, or appear/disappear entirely). Rebuilding the namespace from its
# decoded contents with the requested upserts/removals applied is correct and
# byte-stable (the same sorted payload-addressed layout `buildStore` produces),
# which is what makes file mode and daemon mode produce IDENTICAL images. The
# cost is O(map) per rewritten namespace; for the per-test reverse-map fix-up
# that is the unavoidable shape (the namespaces touched are only those holding
# the re-run test's functions/files).

proc readAllPairs(image: openArray[byte]): Result[seq[(uint64, seq[byte])], string] =
  ## Decode EVERY committed (key, payload-bytes) pair of a payload-addressed
  ## Type-B image, ascending by key. Used to rebuild a namespace with a few keys
  ## changed. A load/lookup failure is propagated (never silently dropped — a
  ## dropped key in a reverse map would be a false skip).
  let keysRes = allKeys(image)
  if keysRes.isErr: return err(keysRes.error)
  var pairs: seq[(uint64, seq[byte])]
  for k in keysRes.value:
    let p = lookupPayload(image, k)
    if p.isErr: return err(p.error)
    if p.value.isSome: pairs.add (k, p.value.get)
  ok(pairs)

proc rebuildNamespace(image: openArray[byte];
                      upserts: seq[(uint64, seq[byte])];
                      removals: seq[uint64]): Result[seq[byte], string] =
  ## Rebuild a payload-addressed namespace from its current contents with
  ## `upserts` applied (each key's value replaced or inserted) and `removals`
  ## deleted. The result is byte-identical to what `buildPayloadNamespace` would
  ## produce for the resulting key/value set, so two stores that reach the same
  ## logical contents by different update orders serialize identically.
  let curRes = readAllPairs(image)
  if curRes.isErr: return err(curRes.error)
  var byKey = initOrderedTable[uint64, seq[byte]]()
  for (k, v) in curRes.value: byKey[k] = v
  for k in removals: byKey.del k
  for (k, v) in upserts: byKey[k] = v
  var pairs: seq[(uint64, seq[byte])]
  for k, v in pairs(byKey): pairs.add (k, v)
  pairs.sort(proc (a, b: (uint64, seq[byte])): int = cmp(a[0], b[0]))
  buildPayloadNamespace(pairs)

# ---------------------------------------------------------------------------
# Incremental per-test update (the M4c daemon hot path: only executed tests)
# ---------------------------------------------------------------------------

proc updateTests*(s: var CtfsStore; updated: seq[StoreTest]):
    Result[void, string] =
  ## Update ONLY the entries of the given (just re-run) tests in place,
  ## incrementally. For each re-run test this:
  ##
  ##   1. DEEP-FORWARD: upserts `testId -> rootHash` (the test's new root hash).
  ##   2. SHALLOW REVERSE (the crux): REMOVES this test's id from the reverse set
  ##      of every function it USED TO execute, then ADDS it to the reverse set of
  ##      every function it executes NOW — and refreshes each current function's
  ##      recorded shallow hash + identity. A function that loses its last reader
  ##      is dropped entirely; a newly-executed function is created. SKIPPED tests
  ##      keep their reverse-set membership untouched.
  ##   3. FILE REVERSE: the same remove-old/add-new for the test's read-file set.
  ##   4. INTERNING: refreshes `testId -> name`, and adds id->identity / id->path
  ##      for any newly-referenced function/file (stale interning entries for a
  ##      function/file that no test references any more are pruned).
  ##
  ## The OLD contributions are read back from the store (the authoritative record
  ## of what each test executed last time), so the caller need only supply the
  ## NEW `StoreTest`s. Tests NOT in `updated` are never touched — their bytes are
  ## byte-identical before and after (the M4c "update only executed" guarantee).
  ##
  ## Any store read/build error is propagated as an `Err` (the daemon then treats
  ## the cycle as failed and re-runs / re-seeds, never trusting a partial update).

  # ---- gather each updated test's OLD function/file sets from the store ----
  # We need the prior reverse-map membership to remove it. The deep-forward map
  # does not record which functions a test executed, so we reconstruct each
  # test's OLD function id set by scanning the shallow reverse structure for
  # entries whose reverse set contains the test id. (This is the inverse of the
  # forward set; it is the authoritative prior membership.) Likewise for files.
  var updatedIds = initHashSet[uint64]()
  for t in updated: updatedIds.incl t.testId

  # functionId -> its current ShallowEntry (decoded once).
  var funcEntries = initOrderedTable[uint64, ShallowEntry]()
  block:
    let pairsRes = readAllPairs(s.shallowReverse)
    if pairsRes.isErr: return err("shallow reverse read: " & pairsRes.error)
    for (fid, payload) in pairsRes.value:
      let e = decodeShallowEntry(payload)
      if e.isErr: return err("shallow entry decode: " & e.error)
      funcEntries[fid] = e.value

  var fileEntries = initOrderedTable[uint64, FileEntry]()
  block:
    let pairsRes = readAllPairs(s.fileReverse)
    if pairsRes.isErr: return err("file reverse read: " & pairsRes.error)
    for (fid, payload) in pairsRes.value:
      let e = decodeFileEntry(payload)
      if e.isErr: return err("file entry decode: " & e.error)
      fileEntries[fid] = e.value

  # ---- (2a) REMOVE each updated test's OLD contributions ----
  # Drop the updated test ids from EVERY function/file reverse set. After this
  # the maps reflect only the SKIPPED tests' contributions; the new ones are
  # re-added below. Removing first (rather than diffing) keeps the logic simple
  # and provably correct: a function a test no longer executes simply never gets
  # re-added, so it is dropped (or shrinks) exactly as it should.
  for fid, e in funcEntries.mpairs:
    var kept: seq[uint64]
    for tid in e.testIds:
      if tid notin updatedIds: kept.add tid
    e.testIds = kept
  for fid, e in fileEntries.mpairs:
    var kept: seq[uint64]
    for tid in e.testIds:
      if tid notin updatedIds: kept.add tid
    e.testIds = kept

  # ---- (2b) ADD each updated test's NEW contributions ----
  for t in updated:
    for dep in t.deps:
      let fid = functionKey(dep.fn)
      # The current shallow hash + identity OVERWRITE the stored ones (the body
      # may have changed — that is why the test re-ran). `mgetOrPut` inserts a
      # fresh entry for a newly-executed function without raising.
      let fresh = ShallowEntry(shallow: dep.shallow, name: dep.fn.name,
                               file: dep.fn.file, defLine: dep.fn.defLine,
                               testIds: @[])
      var entry = funcEntries.mgetOrPut(fid, fresh)
      entry.shallow = dep.shallow
      entry.name = dep.fn.name; entry.file = dep.fn.file
      entry.defLine = dep.fn.defLine
      entry.testIds.add t.testId
      funcEntries[fid] = entry
    for rf in t.readFiles:
      let fid = key64(rf.path)
      let fresh = FileEntry(path: rf.path, mtime: rf.mtime, testIds: @[])
      var entry = fileEntries.mgetOrPut(fid, fresh)
      entry.path = rf.path; entry.mtime = rf.mtime
      entry.testIds.add t.testId
      fileEntries[fid] = entry

  # ---- compute upserts/removals per namespace ----
  # Shallow reverse + function interning: a function with an EMPTY reverse set
  # (its last reader re-ran and no longer executes it) is REMOVED from both the
  # reverse map and the interning table; otherwise its (possibly refreshed)
  # entry/identity is upserted.
  var shallowUpserts, funcInternUpserts: seq[(uint64, seq[byte])]
  var shallowRemovals, funcInternRemovals: seq[uint64]
  for fid, e in funcEntries:
    if e.testIds.len == 0:
      shallowRemovals.add fid
      funcInternRemovals.add fid
    else:
      shallowUpserts.add (fid, encodeShallowEntry(e))
      funcInternUpserts.add (fid,
        asBytes(e.name & "\0" & e.file & "\0" & $e.defLine))

  var fileUpserts, fileInternUpserts: seq[(uint64, seq[byte])]
  var fileRemovals, fileInternRemovals: seq[uint64]
  for fid, e in fileEntries:
    if e.testIds.len == 0:
      fileRemovals.add fid
      fileInternRemovals.add fid
    else:
      fileUpserts.add (fid, encodeFileEntry(e))
      fileInternUpserts.add (fid, asBytes(e.path))

  # Deep-forward + test interning: upsert each updated test's root hash + name.
  var deepUpserts, nameUpserts: seq[(uint64, seq[byte])]
  for t in updated:
    deepUpserts.add (t.testId, asBytes(t.rootHash))
    nameUpserts.add (t.testId, asBytes(t.testName))

  # ---- apply (rebuild each touched namespace) ----
  let shallowRes = rebuildNamespace(s.shallowReverse, shallowUpserts, shallowRemovals)
  if shallowRes.isErr: return err("rebuild shallow reverse: " & shallowRes.error)
  let funcInternRes = rebuildNamespace(s.funcInterning, funcInternUpserts, funcInternRemovals)
  if funcInternRes.isErr: return err("rebuild func interning: " & funcInternRes.error)
  let fileRevRes = rebuildNamespace(s.fileReverse, fileUpserts, fileRemovals)
  if fileRevRes.isErr: return err("rebuild file reverse: " & fileRevRes.error)
  let fileInternRes = rebuildNamespace(s.fileInterning, fileInternUpserts, fileInternRemovals)
  if fileInternRes.isErr: return err("rebuild file interning: " & fileInternRes.error)
  let deepRes = rebuildNamespace(s.deepForward, deepUpserts, @[])
  if deepRes.isErr: return err("rebuild deep forward: " & deepRes.error)
  let nameRes = rebuildNamespace(s.interning, nameUpserts, @[])
  if nameRes.isErr: return err("rebuild test interning: " & nameRes.error)

  s.shallowReverse = shallowRes.value
  s.funcInterning = funcInternRes.value
  s.fileReverse = fileRevRes.value
  s.fileInterning = fileInternRes.value
  s.deepForward = deepRes.value
  s.interning = nameRes.value
  ok()

# ---------------------------------------------------------------------------
# Serialize / load the whole store (file mode); daemon keeps it in memory
# ---------------------------------------------------------------------------

const StoreMagic = ['C', 'T', 'I', 'S']  ## "CTIS" — CodeTracer Incremental Store

proc serialize*(s: CtfsStore): seq[byte] =
  ## Flush the whole store to a single on-disk container: a tiny header naming
  ## each of the six namespace images by length, followed by the images
  ## concatenated. This is the FILE-mode artifact; the daemon (M4c) holds the
  ## `CtfsStore` in memory and never calls this.
  for ch in StoreMagic: result.add byte(ch)
  result.add byte(1)  # container version
  let imgs = [s.interning, s.funcInterning, s.fileInterning,
              s.deepForward, s.shallowReverse, s.fileReverse]
  for img in imgs:
    putU64(result, uint64(img.len))
  for img in imgs:
    for b in img: result.add b

proc loadStore*(bytes: openArray[byte]): Result[CtfsStore, string] =
  ## Reload a store flushed by `serialize`. Validates the magic + version and
  ## that the declared lengths fit the buffer, then slices out each namespace
  ## image. Lossless: the six images come back byte-for-byte.
  if bytes.len < 5:
    return err("store too short for header")
  for i in 0 ..< 4:
    if char(bytes[i]) != StoreMagic[i]:
      return err("invalid store magic")
  if bytes[4] != 1:
    return err("unsupported store version " & $int(bytes[4]))
  var off = 5
  var lens: array[6, int]
  for i in 0 ..< 6:
    let r = getU64(bytes, off)
    if r.isErr: return err(r.error)
    lens[i] = int(r.value)
  var imgs: array[6, seq[byte]]
  for i in 0 ..< 6:
    if off + lens[i] > bytes.len:
      return err("store image " & $i & " truncated")
    var img = newSeq[byte](lens[i])
    for j in 0 ..< lens[i]: img[j] = bytes[off + j]
    imgs[i] = img
    off += lens[i]
  ok(CtfsStore(
    interning: imgs[0], funcInterning: imgs[1], fileInterning: imgs[2],
    deepForward: imgs[3], shallowReverse: imgs[4], fileReverse: imgs[5],
    keepInMemory: false))
