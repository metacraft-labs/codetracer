## M6a — `test_mcr_rr_readfile_extractor`.
##
## The MCR/RR accessed-file extractor (`native_readfiles.nim`) derives the
## correct READ-FILE set from a recording's accessed-file projection — a JSON
## projection of the rr trace's `MMap`/`OpenedFd` records (the documented format
## in `codetracer-rr/src/rr_trace.capnp`, lines 173-209 + 309-318). A LIVE rr/MCR
## recording is Linux/rr-specific and is NOT runnable on this macOS host, so —
## exactly as the M8 native-calltrace tests do — we exercise the extractor at the
## RECORD-FORMAT / parse level over a representative hand-crafted projection that
## maps field-for-field onto the rr records. The set is asserted EXACTLY.
##
## What IS exercised here: the parse of the rr-shaped accessed-file records
## (path + record-time stat), file-backed-vs-anonymous filtering (`source`
## union), de-duplication, the record-time content signature, and the complete
## fail-safe surface (every structural defect ⇒ `Err` ⇒ re-run). What is GATED
## (not run here, not faked): driving a REAL `rr replay` to emit the records —
## that needs the Linux/rr backend the campaign gates the same way.

import std/[unittest, os]
import results
import native_readfiles

# ---------------------------------------------------------------------------
# Helpers — write an rr-shaped accessed-file projection into a temp trace dir.
# ---------------------------------------------------------------------------

proc tmpTraceDir(name: string): string =
  result = getTempDir() / ("m6a_readfiles_" & name & "_" & $getCurrentProcessId())
  removeDir(result)
  createDir(result)

proc writeProjection(traceDir: string; body: string) =
  writeFile(traceDir / NativeReadFilesFile, body)

suite "M6a — MCR/RR read-file extractor":

  test "extractor_derives_exact_readfile_set_from_rr_projection":
    # A representative projection modeled on rr's `mmaps` + `OpenedFd` records:
    #   * /data/config.json  — a file-backed MMap (source "file") ⇒ a dependency.
    #   * /data/table.csv    — an OpenedFd (no source ⇒ defaults "file") ⇒ a dep.
    #   * /data/config.json  — a SECOND mapping of the same file ⇒ de-duplicated.
    #   * <anon>             — an anonymous (source "zero") mapping ⇒ DROPPED.
    #   * <heap-from-trace>  — a data-in-trace (source "trace") mapping ⇒ DROPPED.
    let d = tmpTraceDir("exact")
    defer: removeDir(d)
    writeProjection(d, """
{
  "reads": [
    { "path": "/data/config.json", "source": "file",
      "statSize": 256, "statMTime": 1700000000 },
    { "path": "/data/table.csv",
      "statSize": 1024, "statMTime": 1700000500 },
    { "path": "/data/config.json", "source": "file",
      "statSize": 256, "statMTime": 1700000000 },
    { "path": "/anon/region", "source": "zero",
      "statSize": 0, "statMTime": 0 },
    { "path": "/heap/from-trace", "source": "trace",
      "statSize": 4096, "statMTime": 42 }
  ]
}
""")
    let res = readFileDepsNative(d)
    check res.isOk
    let reads = res.value
    # Exactly the two file-backed reads, de-duplicated, path-sorted.
    check reads.len == 2
    check reads[0].path == "/data/config.json"
    check reads[1].path == "/data/table.csv"
    # Record-time mtime is carried straight from the rr `statMTime`.
    check reads[0].mtime == 1700000000'i64
    check reads[1].mtime == 1700000500'i64
    # The content signature is the (size, mtime) record-time identity — derived,
    # non-empty, and DISTINCT for the two distinct files.
    check reads[0].hash == signatureOf(256, 1700000000)
    check reads[1].hash == signatureOf(1024, 1700000500)
    check reads[0].hash != reads[1].hash

  test "explicit_content_hash_is_honoured_over_the_derived_signature":
    # A real extractor can hash the trace's backing copy and supply `contentHash`
    # directly; when present it wins over the (size, mtime) signature.
    let d = tmpTraceDir("explicit")
    defer: removeDir(d)
    writeProjection(d, """
{ "reads": [ { "path": "/data/x.bin", "source": "file",
               "statSize": 8, "statMTime": 5, "contentHash": "deadbeef" } ] }
""")
    let res = readFileDepsNative(d)
    check res.isOk
    check res.value.len == 1
    check res.value[0].hash == "deadbeef"

  test "signature_changes_when_mtime_or_size_changes":
    # The record-time signature is sensitive to BOTH size and mtime — a changed
    # file (new mtime OR new size) gets a different signature ⇒ its reader re-runs.
    check signatureOf(100, 10) != signatureOf(100, 11)  # mtime change
    check signatureOf(100, 10) != signatureOf(101, 10)  # size change
    check signatureOf(100, 10) == signatureOf(100, 10)  # stable

  test "no_projection_means_empty_set_only_via_the_or_empty_helper":
    # A trace with NO read-file projection (e.g. the interpreted M0 fixtures) is
    # an EMPTY dependency set — but ONLY via the explicit best-effort helper. The
    # strict reader treats the absence as an Err (the caller must opt in to the
    # empty interpretation), so a genuinely-required projection is never silently
    # skipped.
    let d = tmpTraceDir("absent")
    defer: removeDir(d)
    check (not hasReadFiles(d))
    check readFileDepsNative(d).isErr                 # strict: absence ⇒ Err
    let orEmpty = readFileDepsNativeOrEmpty(d)         # best-effort: absence ⇒ @[]
    check orEmpty.isOk
    check orEmpty.value.len == 0

  # ---- Fail-safe surface: every structural defect ⇒ Err (⇒ re-run). ----

  test "failsafe_malformed_json_errs":
    let d = tmpTraceDir("malformed")
    defer: removeDir(d)
    writeProjection(d, "{ this is not json ")
    check readFileDepsNative(d).isErr
    # Even the best-effort helper must surface a CORRUPT projection as an Err
    # (the file EXISTS, so it is not the "absent" case) — never a silent skip.
    check readFileDepsNativeOrEmpty(d).isErr

  test "failsafe_non_object_root_errs":
    let d = tmpTraceDir("nonobj")
    defer: removeDir(d)
    writeProjection(d, "[1, 2, 3]")
    check readFileDepsNative(d).isErr

  test "failsafe_missing_reads_array_errs":
    let d = tmpTraceDir("noreads")
    defer: removeDir(d)
    writeProjection(d, """{ "notReads": [] }""")
    check readFileDepsNative(d).isErr

  test "failsafe_read_entry_without_path_errs":
    let d = tmpTraceDir("nopath")
    defer: removeDir(d)
    writeProjection(d, """{ "reads": [ { "source": "file", "statSize": 1 } ] }""")
    check readFileDepsNative(d).isErr

  test "failsafe_empty_path_errs":
    let d = tmpTraceDir("emptypath")
    defer: removeDir(d)
    writeProjection(d, """{ "reads": [ { "path": "", "source": "file" } ] }""")
    check readFileDepsNative(d).isErr

  test "failsafe_unknown_source_errs":
    let d = tmpTraceDir("badsource")
    defer: removeDir(d)
    writeProjection(d,
      """{ "reads": [ { "path": "/x", "source": "weird" } ] }""")
    check readFileDepsNative(d).isErr

  test "failsafe_non_integer_stat_errs":
    let d = tmpTraceDir("badstat")
    defer: removeDir(d)
    writeProjection(d,
      """{ "reads": [ { "path": "/x", "source": "file", "statMTime": "soon" } ] }""")
    check readFileDepsNative(d).isErr

  test "failsafe_empty_explicit_content_hash_errs":
    let d = tmpTraceDir("emptyhash")
    defer: removeDir(d)
    writeProjection(d,
      """{ "reads": [ { "path": "/x", "source": "file", "contentHash": "" } ] }""")
    check readFileDepsNative(d).isErr

  test "empty_reads_array_is_a_valid_empty_set":
    # A recording that mapped/opened NO external file (all anonymous) yields an
    # empty set — that is valid, not an error (the test simply has no read-file
    # dependency).
    let d = tmpTraceDir("emptyok")
    defer: removeDir(d)
    writeProjection(d, """{ "reads": [] }""")
    let res = readFileDepsNative(d)
    check res.isOk
    check res.value.len == 0
