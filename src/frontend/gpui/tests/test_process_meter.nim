## test_process_meter.nim — `process_meter.residentKb` measures this process's
## CURRENT resident set on every host the `gpui-shell` lane runs on.
##
## `test_gpui_editing_surface.nim`'s large-file case asserts that RSS does not
## grow while it scrolls. That assertion is only as good as the reader under
## it, and a reader that answered a constant would pass it for free. So this
## suite is the reader's POSITIVE CONTROL: it makes the process touch a known
## amount of fresh memory and requires the reading to rise by most of it.
##
## No mocks: the reader is called against this process and the real kernel.
##
## Compile and run (from the repository root):
##   nim c -r src/frontend/gpui/tests/test_process_meter.nim

import std/[posix, strutils, unittest]

import process_meter

const
  TouchedMiB = 128
    ## Large enough to dwarf allocator noise on a shared host, small enough
    ## for any CI runner.
  PageStride = 4096
    ## Writing one byte per 4 KiB faults in every page whatever the host's page
    ## size is (4, 16 or 64 KiB), because the stride never exceeds it.

suite "process_meter: the resident-set reader":
  test "the reading is positive and does not raise on this host":
    # On a host with no reader this raises IOError, which fails the case BY
    # NAME — the refusal the large-file bound relies on.
    check residentKb() > 0

  test "touching fresh memory raises the reading by most of what was touched":
    let before = residentKb()
    var buf = newSeq[byte](TouchedMiB * 1024 * 1024)
    var i = 0
    while i < buf.len:
      buf[i] = byte(i shr 12)
      i += PageStride
    let after = residentKb()
    # Keep the buffer alive past the second reading, and make the writes
    # observable so they cannot be elided.
    var sum = 0
    i = 0
    while i < buf.len:
      sum += int(buf[i])
      i += PageStride
    check sum > 0
    # Half of what was touched: RSS is process-wide, so other allocations may
    # be returned meanwhile, but a reader that answers a constant or a unit off
    # by 1024 cannot clear this. A PEAK reader can (the touch is a new peak);
    # the next case is the one that refuses it.
    check after - before >= TouchedMiB * 1024 div 2
    # And not absurdly more: a reader in BYTES instead of KiB would be ~1024x.
    check after - before <= TouchedMiB * 1024 * 4

  test "releasing memory LOWERS the reading: it is the current size, not a peak":
    # `mmap`/`munmap` directly rather than a `seq`, so the release reaches the
    # kernel now instead of whenever the allocator decides to return a chunk.
    # A peak reader (`ru_maxrss`, `resident_size_max`) passes the previous
    # case — touching fresh memory makes a new peak — and fails this one,
    # because a peak never falls. Measured on Darwin arm64 2026-10-28: with
    # `resident_size_max` substituted the previous case passed.
    let size = TouchedMiB * 1024 * 1024
    let region = mmap(nil, size, PROT_READ or PROT_WRITE,
                      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    require region != MAP_FAILED
    let bytes = cast[ptr UncheckedArray[byte]](region)
    var i = 0
    while i < size:
      bytes[i] = 1
      i += PageStride
    let touched = residentKb()
    require munmap(region, size) == 0
    let released = residentKb()
    check touched - released >= TouchedMiB * 1024 div 2

  test "the load-average label is a number, or says it is unavailable":
    let load = loadAverage1()
    if load != "unavailable":
      check parseFloat(load) >= 0.0
