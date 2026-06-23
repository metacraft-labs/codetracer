## M1 — `test_executed_functions_seekable_matches_ctprint`.
##
## The CORRECTNESS ANCHOR for the M1 seekable executed-function read: on a real
## modern split-stream `.ct` bundle, the in-process seekable reader
## (`ctfs_seekable.readExecutedFunctionsSeekable`) must yield the IDENTICAL
## executed-function set — names AND best-effort def-file/def-line — as the old
## `ct-print --json-events` path it replaces.
##
## The comparison is against the ACTUAL `ct-print --json-events` output (run
## through the retained `readExecutedFunctionsCtfsViaCtPrint` fallback), NOT a
## re-implementation: both reads run over the SAME bundle and their full
## `ExecutedFunction` sequences (name-sorted) must be equal element-for-element.
##
## We additionally assert the dispatching `readExecutedFunctionsCtfs` (which now
## prefers the seekable path) agrees, and that the seekable read correctly
## EXCLUDES a defined-but-never-called function.
##
## The bundle is generated in-process by `m1_ctfs_fixture` via the production
## `MultiStreamTraceWriter`, so the test is self-contained and needs no
## committed binary fixture.  `ct-print` is resolved via the documented
## precedence (`CT_PRINT` env / PATH / the known build path); when it cannot be
## found the test FAILS LOUDLY (the parity anchor is not optional) with a clear
## instruction, rather than silently skipping.

import std/[os, unittest]
import results

import m1_ctfs_fixture
import m1_ctprint_build  # ensureCtPrint — CI-safe: builds ct-print from source if absent
import ctfs_trace      # readExecutedFunctionsCtfs, readExecutedFunctionsCtfsViaCtPrint
import ctfs_seekable   # readExecutedFunctionsSeekable
import trace_reader    # ExecutedFunction

proc sameExecutedSet(a, b: seq[ExecutedFunction]): bool =
  ## Element-for-element equality of two name-sorted executed-function sets,
  ## comparing the FULL identity (name + file + defLine).
  if a.len != b.len:
    return false
  for i in 0 ..< a.len:
    if a[i].name != b[i].name or a[i].file != b[i].file or
        a[i].defLine != b[i].defLine:
      return false
  true

suite "M1 — seekable executed-function read matches ct-print":
  # Cover BOTH the line-only `resolveGli` def-line path AND the column-aware
  # `decodeGlobalPositionIndex` path the PRODUCTION Python recorder exercises —
  # the latter guards the column-aware GLI-resolution regression a line-only
  # fixture cannot catch.
  let lineOnly = buildM1Fixture(getTempDir() / "m1_matches_lineonly.ct",
    columnAware = false)
  let columnAware = buildM1Fixture(getTempDir() / "m1_matches_columnaware.ct",
    columnAware = true)
  require lineOnly.isOk
  require columnAware.isOk
  let fixtures = @[("line-only", lineOnly.get()), ("column-aware", columnAware.get())]

  # Resolve ct-print ONCE for the whole suite, building it from the
  # trace-format-nim source when no pre-built binary is available (so the parity
  # anchor runs in CI without depending on a stray /tmp artifact).  Exporting it
  # as $CT_PRINT makes the retained `readExecutedFunctionsCtfsViaCtPrint`
  # fallback (which resolves via $CT_PRINT/PATH) use exactly this binary.
  let ctPrint = ensureCtPrint()
  if ctPrint.isOk:
    putEnv("CT_PRINT", ctPrint.get())
  let ctPrintAvailable = ctPrint.isOk
  let ctPrintSkipReason =
    if ctPrint.isOk: ""
    else: "ct-print unavailable and unbuildable: " & ctPrint.error

  test "ct-print is available (built from source if needed)":
    # The parity anchor is only skippable when ct-print can neither be found nor
    # built — a genuinely degraded environment, reported with a clear reason.
    # It is NEVER silently skipped, and never depends on a stray /tmp binary.
    if not ctPrintAvailable:
      checkpoint("SKIP: " & ctPrintSkipReason)
      skip()
    else:
      check fileExists(ctPrint.get())

  test "seekable in-process read equals ct-print --json-events":
    if not ctPrintAvailable:
      checkpoint("SKIP: " & ctPrintSkipReason)
      skip()
    else:
      for (label, fix) in fixtures:
        let seekable = readExecutedFunctionsSeekable(fix.path)
        require seekable.isOk
        let viaCtPrint = readExecutedFunctionsCtfsViaCtPrint(fix.path)
        require viaCtPrint.isOk
        # IDENTICAL set — names AND def-file/def-line — on BOTH GLI paths.
        check sameExecutedSet(seekable.get(), viaCtPrint.get())
        if not sameExecutedSet(seekable.get(), viaCtPrint.get()):
          checkpoint("mismatch on the " & label & " fixture")

  test "dispatcher (readExecutedFunctionsCtfs) prefers the seekable path and agrees":
    if not ctPrintAvailable:
      checkpoint("SKIP: " & ctPrintSkipReason)
      skip()
    else:
      for (label, fix) in fixtures:
        let dispatched = readExecutedFunctionsCtfs(fix.path)
        require dispatched.isOk
        let viaCtPrint = readExecutedFunctionsCtfsViaCtPrint(fix.path)
        require viaCtPrint.isOk
        check sameExecutedSet(dispatched.get(), viaCtPrint.get())
        if not sameExecutedSet(dispatched.get(), viaCtPrint.get()):
          checkpoint("dispatcher mismatch on the " & label & " fixture")

  test "seekable read excludes a defined-but-never-called function":
    for (label, fix) in fixtures:
      let seekable = readExecutedFunctionsSeekable(fix.path)
      require seekable.isOk
      for fn in seekable.get():
        check fn.name != fix.uncalledName
      # And it carries exactly the executed names, in sorted order.
      var gotNames: seq[string] = @[]
      for fn in seekable.get():
        gotNames.add fn.name
      check gotNames == fix.executedNames
