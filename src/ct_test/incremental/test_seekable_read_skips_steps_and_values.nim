## M1 — `test_seekable_read_skips_steps_and_values`.
##
## Proves the seekable executed-function read fetches ONLY function-table + call
## data and does NOT read/dump the step or value streams the old
## `ct-print --json-events` whole-trace path always paid for.
##
## The proof is observable, not by inspection: `NewTraceReader` initializes each
## of its stream readers LAZILY, and exposes (M1) read-only probes for which
## streams were touched and how many step chunks were inflated.  The seekable
## reader surfaces those through `SeekableReadStats`:
##
##   * `valueStreamLoaded` MUST be false — the value stream is NEVER opened on
##     any seekable path (names + def-lines need no recorded values).  If the
##     implementation ever fell back to a whole-trace materialization (which
##     decodes values) this flips true and the test FAILS.
##   * `execChunkDecompressions` MUST stay BOUNDED — at most one inflation per
##     distinct call-entry step chunk, far fewer than the total number of step
##     chunks.  A whole-step-stream scan would inflate EVERY chunk; the bundle
##     is built (small chunk size, many filler steps) so a full scan is strictly
##     larger than the bound, making the assertion discriminating.
##
## We also assert the NAME-ONLY mode (`resolveDefLines = false`) never opens the
## exec stream AT ALL (`execStreamLoaded == false`), and that the executed set is
## still correct — the strongest form of "no step read".
##
## The bundle is generated in-process via the production `MultiStreamTraceWriter`
## (`m1_ctfs_fixture`), so no committed fixture and no `ct-print` are needed.

import std/[os, unittest]
import results

import m1_ctfs_fixture
import ctfs_seekable
import codetracer_trace_writer/new_trace_reader  # openNewTrace, stepCount (total-chunk ground truth)

proc totalStepChunks(ctPath: string): uint64 =
  ## Ground-truth number of `steps.dat` chunks a WHOLE-stream scan would have to
  ## inflate.  Opening the reader and reading only `stepCount` touches the exec
  ## stream's index but inflates no chunk beyond what counting requires; we use
  ## it purely to derive the chunk total the bounded read must stay UNDER.
  let opened = openNewTrace(ctPath)
  doAssert opened.isOk, opened.error
  var rd = opened.get()
  let sc = rd.stepCount()
  doAssert sc.isOk, sc.error
  let chunkSize = uint64(8)  # matches m1_ctfs_fixture's writer chunkSize
  (sc.get() + chunkSize - 1) div chunkSize

suite "M1 — seekable read skips the step and value streams":
  # Run every assertion over BOTH the line-only and the column-aware bundle so
  # the "no value read" / "bounded step read" properties are proven on the
  # PRODUCTION-shaped (column-aware) path too, not only the simpler one.
  let lineOnly = buildM1Fixture(getTempDir() / "m1_skips_lineonly.ct",
    columnAware = false)
  let columnAware = buildM1Fixture(getTempDir() / "m1_skips_columnaware.ct",
    columnAware = true)
  require lineOnly.isOk
  require columnAware.isOk
  let fixtures = @[("line-only", lineOnly.get()), ("column-aware", columnAware.get())]

  test "def-line resolution reads the value stream NEVER and bounded step chunks":
    for (label, fix) in fixtures:
      let r = readExecutedFunctionsSeekableInstrumented(fix.path,
        resolveDefLines = true)
      require r.isOk
      let (funcs, stats) = r.get()

      # The executed set is still correct (names recovered).
      var names: seq[string] = @[]
      for fn in funcs:
        names.add fn.name
      check names == fix.executedNames

      # The value stream is NEVER read — even with def-line resolution on, which
      # only seeks call-entry STEPS, never values.  A whole-trace fallback would
      # decode values and flip this true.
      check stats.valueStreamLoaded == false
      if stats.valueStreamLoaded:
        checkpoint("value stream was read on the " & label & " fixture")

      # Step reads are BOUNDED: def-line resolution seeks only the chunks holding
      # the call-entry steps (here 4 calls), never the whole step stream.  The
      # bound is the call count; a full-stream scan would inflate EVERY chunk.
      check stats.callCount == 4'u64
      check stats.execChunkDecompressions <= stats.callCount

      # The discriminating assertion: the bundle's step stream spans STRICTLY
      # MORE chunks than the seekable read inflated, so a whole-stream scan
      # (what a fallback materialization would do) would have inflated strictly
      # more.
      let totalChunks = totalStepChunks(fix.path)
      check totalChunks > stats.execChunkDecompressions

      # Sanity: at least one chunk was inflated (def-lines WERE resolved), so the
      # bound is a real ceiling rather than a vacuous zero.
      check stats.execChunkDecompressions >= 1'u64
      for fn in funcs:
        check fn.defLine != 0  # every def-line resolved (file/line present)

  test "name-only mode never opens the step stream at all":
    for (label, fix) in fixtures:
      let r = readExecutedFunctionsSeekableInstrumented(fix.path,
        resolveDefLines = false)
      require r.isOk
      let (funcs, stats) = r.get()

      # Names still correct.
      var names: seq[string] = @[]
      for fn in funcs:
        names.add fn.name
      check names == fix.executedNames

      # NEITHER the exec (steps) NOR the value stream was ever opened — the
      # strongest "no step/value read" proof.  Both flags must be false and no
      # step chunk was inflated.
      check stats.execStreamLoaded == false
      check stats.valueStreamLoaded == false
      check stats.execChunkDecompressions == 0'u64
      if stats.execStreamLoaded or stats.valueStreamLoaded:
        checkpoint("a stream was opened in name-only mode on the " & label &
          " fixture")

      # In name-only mode def-file/line are the documented best-effort gap.
      for fn in funcs:
        check fn.file == ""
        check fn.defLine == 0
