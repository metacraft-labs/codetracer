## Test catalog reader — the M11 deliverable of the
## Trace-Based-Incremental-Testing campaign.
##
## # What this is for
##
## Nim's compiler can compute a per-symbol *deep* hash at COMPILE TIME via
## `std/macros.symBodyHash` (spec §16.2): it recursively walks the entire
## transitive call graph of a symbol and produces a single digest that changes
## whenever ANY function in the dependency chain changes. This is conceptually
## the same as computing a shallow hash for every runtime dependency and
## combining them (the Phase-1/Phase-2 *runtime* deep hash this engine computes
## from a trace), but the compiler does it in one pass with NO trace and NO
## runtime observation.
##
## When the CodeTracer Nim unit-testing library is linked into the test binary,
## its `test` registration macro is expected to embed each test's `symBodyHash`
## into the binary as a per-test `bodyHash` field, and expose it in the
## `--list-json` *test catalog* (spec §16.3 — "The hash is a compile-time
## `string` constant embedded in the binary"). The runner then compares those
## catalog `bodyHash`es between builds and skips a test whose hash is unchanged
## (spec §16.5 / §3.7), with NO trace at all.
##
## This module reads such a catalog into a `BodyHashCatalog` mapping
## `testId -> bodyHash`. The engine (`engine.decideByCatalog` / `decideTiered`)
## uses it to take the DEEP path when a `bodyHash` is reported for a test, and
## falls back to the existing runtime shallow path (M1/M9) when it is NOT — the
## no-library case, which must keep working.
##
## # Catalog source taken in this prototype — path (1b)
##
## The in-tree library `ct_test_unittest_parallel` does NOT (yet) emit a
## `bodyHash`/`symBodyHash` field in its `--list-json` output — its catalog
## carries only `name`/`suite`/`file`/`line` (see
## `libs/ct_test_unittest_parallel/src/ct_test_unittest_parallel.nim`'s
## `emitListJson`). So the §3.6 "Full" tier (`bodyHash` in `--list-json`) is NOT
## available out of the box here.
##
## Per the M11 brief, path (1a) (read a real test binary's `--list-json`
## `bodyHash`) is therefore unavailable, and we take path (1b): a tiny Nim
## fixture + a macro (`tests/symbodyhash_catalog.nim`) that, for each test proc,
## records the GENUINE compile-time `symBodyHash(theProc)` into a catalog JSON.
## That catalog is then read by this module. The hashes are real
## `std/macros.symBodyHash` digests — NOT hand-invented — so the deep path is
## exercised against true compile-time deep hashes (§16.2).
##
## # Catalog JSON shapes accepted (both are read)
##
## To be forward-compatible with the §16.3 `--list-json` shape AND convenient
## for path (1b), the reader accepts EITHER:
##
##   1. A flat object mapping test id to body hash:
##        ``{ "<suite>::<test>": "<symBodyHash>", ... }``
##      (the shape the M11 macro fixture emits directly.)
##
##   2. The §16.3 `--list-json` shape — an object with a ``tests`` array whose
##      entries each carry a ``name`` (the fully-qualified test id) and a
##      ``bodyHash``:
##        ``{ "tests": [ { "name": "...", "bodyHash": "..." }, ... ] }``
##      Entries WITHOUT a (non-empty) `bodyHash` are OMITTED from the catalog
##      (e.g. `tkExternal` tests embed an empty `bodyHash` per §16.3) — so the
##      tiered selector falls back to the shallow path for them rather than
##      treating an empty string as a real deep hash.
##
## # Fail-safe stance (mirrors the rest of the engine)
##
## Anything we cannot read as a TRUSTWORTHY `testId -> bodyHash` mapping is NOT
## silently dropped into a skip. A malformed/garbled catalog yields an `Err`,
## which the engine treats as "no catalog bodyHash for this test" and so falls
## back to the shallow path (or re-runs) — never a silent skip. An entry whose
## hash is the empty string is treated as ABSENT (no deep hash reported).

import std/[json, os, tables, options]
import results

type
  BodyHashCatalog* = object
    ## A parsed test catalog: `testId -> bodyHash` (the §16.3 compile-time deep
    ## hash). Use `bodyHashFor` to look a test up; an absent test means "the
    ## library did not report a deep hash for this test" ⇒ the engine falls back
    ## to the runtime shallow path.
    entries*: Table[string, string]

func initBodyHashCatalog*(): BodyHashCatalog =
  ## An empty catalog (no test has a reported deep hash). The tiered selector
  ## treats every test as a shallow-path test against this catalog.
  BodyHashCatalog(entries: initTable[string, string]())

func bodyHashFor*(catalog: BodyHashCatalog; testId: string): Option[string] =
  ## The reported `bodyHash` for `testId`, or `none` when the catalog does not
  ## report one (so the engine should use the shallow path). Implemented over
  ## `std/options` so the "absent" case is explicit and cannot be confused with
  ## an empty-string hash (which the reader already excludes).
  if catalog.entries.hasKey(testId):
    some(catalog.entries[testId])
  else:
    none(string)

func hasBodyHash*(catalog: BodyHashCatalog; testId: string): bool =
  ## True iff the catalog reports a deep `bodyHash` for `testId`.
  catalog.entries.hasKey(testId)

proc parseBodyHashCatalog*(raw: string): Result[BodyHashCatalog, string] =
  ## Parse a catalog from its JSON text. Accepts both the flat
  ## `{testId: bodyHash}` shape and the §16.3 `--list-json` `{tests: [...]}`
  ## shape (see the module doc). Returns an `Err` on malformed JSON or a
  ## structurally-wrong document — never a crash, never a partial silent skip.
  var root: JsonNode
  try:
    root = parseJson(raw)
  except CatchableError as e:
    return err("malformed catalog JSON: " & e.msg)
  if root.kind != JObject:
    return err("catalog JSON root must be an object")
  var catalog = initBodyHashCatalog()
  if root.hasKey("tests"):
    # §16.3 `--list-json` shape: an array of test entries each with `name` +
    # (optionally) `bodyHash`.
    let tests = root["tests"]
    if tests.kind != JArray:
      return err("catalog 'tests' must be a JSON array")
    for entry in tests.elems:
      if entry.kind != JObject:
        return err("catalog 'tests' entry must be an object")
      if not entry.hasKey("name") or entry["name"].kind != JString:
        return err("catalog 'tests' entry missing a string 'name'")
      let name = entry["name"].getStr()
      # bodyHash is OPTIONAL: a tkExternal test embeds an empty hash (§16.3), and
      # a library that predates the field omits it entirely. Either way we treat
      # it as "no deep hash reported" so the engine falls back to the shallow
      # path rather than mistaking an empty string for a real digest.
      if entry.hasKey("bodyHash"):
        if entry["bodyHash"].kind != JString:
          return err("catalog entry '" & name & "' bodyHash must be a string")
        let h = entry["bodyHash"].getStr()
        if h.len > 0:
          catalog.entries[name] = h
    return ok(catalog)
  # Flat `{testId: bodyHash}` shape (the M11 macro-fixture output). Every value
  # must be a string; an empty-string hash is treated as ABSENT.
  for testId, value in root.fields:
    if value.kind != JString:
      return err("catalog entry '" & testId & "' must map to a string hash")
    let h = value.getStr()
    if h.len > 0:
      catalog.entries[testId] = h
  ok(catalog)

proc loadBodyHashCatalog*(path: string): Result[BodyHashCatalog, string] =
  ## Load and parse a catalog file. A missing file is an `Err` (the caller
  ## decides whether "no catalog" means shallow-everywhere or a hard error). A
  ## present-but-unreadable/malformed file is an `Err` — never a silent skip.
  if not fileExists(path):
    return err("catalog file not found: " & path)
  var raw: string
  try:
    raw = readFile(path)
  except CatchableError as e:
    return err("failed to read catalog " & path & ": " & e.msg)
  parseBodyHashCatalog(raw)
