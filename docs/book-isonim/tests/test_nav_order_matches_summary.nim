## codetracer/docs/book-isonim -- nav-order fidelity test (C-target).
##
## Proves the `order:` front matter added to every ported page reproduces
## the ORIGINAL mdBook `SUMMARY.md` sequence, per section -- the book's
## nav order is deliberately NON-alphabetical (python before ruby before
## javascript; cli before gui; ct_cli before mcp-tools), so a plain
## slug-alphabetical sort would NOT reproduce it. The framework sorts
## content entries by (section, order, slug); this test asserts the
## resulting per-section route order equals the SUMMARY order exactly.
##
## `recording-a-browser-app` is present in the source tree but NOT in
## SUMMARY.md, so it is excluded from the comparison (it is ordered last
## in its section via a high `order:`), while still being required to
## exist so the page count stays complete.

import std/[unittest, os, tables]
import core/content

const expectedSummaryOrder: seq[tuple[section: string, routes: seq[string]]] = @[
  ("", @["/", "/installation"]),
  ("getting_started", @[
    "/getting_started",
    "/getting_started/python",
    "/getting_started/ruby",
    "/getting_started/javascript",
    "/getting_started/wasm",
    "/getting_started/noir",
    "/getting_started/circom",
    "/getting_started/miden",
    "/getting_started/leo",
    "/getting_started/solidity",
    "/getting_started/stylus",
    "/getting_started/cairo",
    "/getting_started/aiken",
    "/getting_started/cadence",
    "/getting_started/move",
    "/getting_started/solana",
    "/getting_started/sway",
    "/getting_started/polkavm",
    "/getting_started/tolk",
  ]),
  ("usage_guide", @[
    "/usage_guide",
    "/usage_guide/cli",
    "/usage_guide/gui",
    "/usage_guide/visual_recordings",
    "/usage_guide/tracepoints",
    "/usage_guide/incremental-testing",
    "/usage_guide/value-origin-tracking",
    "/usage_guide/cross-tracer-demo",
    "/usage_guide/variable-rename-list",
    "/usage_guide/codetracer_shell",
    "/usage_guide/omniscient-db-size-bench",
    "/usage_guide/native-omniscient-timing-bench",
    "/usage_guide/slice-prep-speed-bench",
    "/usage_guide/gui-ops-latency-bench",
  ]),
  ("reference", @[
    "/reference/ct_cli",
    "/reference/mcp-tools",
    "/reference/origin-kinds",
    "/reference/recorders",
  ]),
  ("building_and_packaging", @[
    "/building_and_packaging/build_systems",
  ]),
  ("misc", @[
    "/misc/contributing",
    "/misc/logs",
    "/misc/troubleshooting",
    "/misc/environment_variables",
    "/misc/building_docs",
  ]),
]

proc contentDir(): string =
  currentSourcePath().parentDir().parentDir() / "content"

suite "nav order reproduces the original SUMMARY.md sequence":
  let entries = loadContentEntries(contentDir())

  test "every SUMMARY page was ported and no content is dropped":
    # 46 source pages -> 46 content entries (nothing lost, nothing duplicated).
    check entries.len == 46
    var summaryCount = 0
    for sec in expectedSummaryOrder:
      summaryCount += sec.routes.len
    # 45 of the 46 pages are listed in SUMMARY; recording-a-browser-app is not.
    check summaryCount == 45

  test "per-section route order matches SUMMARY (non-alphabetical) order":
    # Group the framework-sorted entries by section, preserving the
    # (section, order, slug) order loadContentEntries produced.
    var bySection = initOrderedTable[string, seq[string]]()
    for e in entries:
      bySection.mgetOrPut(e.section, @[]).add e.routePath

    for expected in expectedSummaryOrder:
      check bySection.hasKey(expected.section)
      let actualAll = bySection[expected.section]
      let summarySet = expected.routes
      # Filter the section's derived order down to the routes SUMMARY lists,
      # preserving derived order, then require an exact sequence match.
      var actualFiltered: seq[string] = @[]
      for r in actualAll:
        if r in summarySet:
          actualFiltered.add r
      check actualFiltered == expected.routes

  test "the non-SUMMARY page exists but sorts last in its section":
    var usage: seq[string] = @[]
    for e in entries:
      if e.section == "usage_guide":
        usage.add e.routePath
    check "/usage_guide/recording-a-browser-app" in usage
    check usage[^1] == "/usage_guide/recording-a-browser-app"
