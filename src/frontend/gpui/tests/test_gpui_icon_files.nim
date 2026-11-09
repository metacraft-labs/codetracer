## test_gpui_icon_files.nim — the shell's generated icon files are written once
## per content into the per-user cache, and no process leaves a directory in
## the system temp directory behind (codetracer-pm issue 2026-11-08, "The GPUI
## shell leaves a temp icon directory behind for every process").
##
## Runs the six real writers of `app/leaves` (`flowHidePath`,
## `stickyChevronPath`, `foldChevronPath`, `executionMarkPath`, `callIconPath`,
## `stateIconPath`) against the real filesystem, in the scratch
## `CODETRACER_HOME` every test program here gets
## (`test_support/state_isolation.nim`). No mocks.
##
## Run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_gpui_icon_files.nim

import std/[os, sequtils, strutils, unittest]

import gpui/app/leaves
import ../../../common/ct_home

const SampleSvg = """<svg xmlns="http://www.w3.org/2000/svg"><path fill="currentColor" d="M0 0"/></svg>"""

proc iconPaths(): seq[string] =
  @[flowHidePath(), stickyChevronPath(), foldChevronPath(), executionMarkPath(),
    callIconPath("dot"), stateIconPath("search", SampleSvg, "#f3f3f3")]

suite "gpui shell icon files":

  test "every icon is a file in the per-user cache, none in the temp directory":
    let cache = ctCacheDir()
    for p in iconPaths():
      check fileExists(p)
      check p.startsWith(cache)
      check not p.startsWith(getTempDir() / "codetracer-gpui-marks-")
    check not dirExists(getTempDir() / ("codetracer-gpui-marks-" &
                                        $getCurrentProcessId()))

  test "asking again returns the same path and creates no further file":
    let first = iconPaths()
    let before = toSeq(walkDirRec(ctCacheDir())).len
    check iconPaths() == first
    check toSeq(walkDirRec(ctCacheDir())).len == before

  test "one icon in two inks is two files, neither overwritten":
    let light = stateIconPath("copy", SampleSvg, "#f3f3f3")
    let dark = stateIconPath("copy", SampleSvg, "#333333")
    check light != dark
    check readFile(light).contains("#f3f3f3")
    check readFile(dark).contains("#333333")

  test "an icon deleted from the cache is written again":
    let p = foldChevronPath()
    removeFile(p)
    check foldChevronPath() == p
    check fileExists(p)
