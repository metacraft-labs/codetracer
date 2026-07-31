## codetracer/docs/book-isonim -- nav-structure test (C-target).
##
## The new book DELIBERATELY diverges from the old mdBook SUMMARY.md to match
## the WebFlow docs organization: THREE top-level sections in a fixed order
## (Getting Started, Usage Guide, Reference), with `building_and_packaging` +
## `misc` folded into `reference` and the root `installation` page moved under
## `getting_started`. This test proves that reorganization:
##   1. every page is still present (nothing dropped in the fold);
##   2. the content collapses to exactly the three WebFlow sections;
##   3. the WebFlow-listed pages lead each section in WebFlow order; and
##   4. the sidebar renders the three sections in the WebFlow order (via
##      `DocsConfig.sectionOrder`, not the framework's default alphabetical).

import std/[unittest, os, tables, sequtils, sets]
import core/[content, routes, navigation_vm]
import ../src/docs_config

proc contentDir(): string =
  currentSourcePath().parentDir().parentDir() / "content"

suite "book nav matches the WebFlow 3-section organization":
  let dir = contentDir()
  let entries = loadContentEntries(dir)

  test "every page survives the fold (nothing dropped)":
    # 46 folded pages + the M5 `getting_started/introduction` article the home
    # landing links to (the Introduction prose lifted out of the old root
    # `index.md` when it became the WebFlow-parity landing) + the three
    # WebFlow-parity utility pages (faq / support / sign-in) = 50.
    check entries.len == 50

  test "content collapses to exactly the three WebFlow sections":
    var sections: seq[string] = @[]
    for e in entries:
      if e.section.len > 0 and e.section notin sections:
        sections.add e.section
    check sections.toHashSet == ["getting_started", "usage_guide", "reference"].toHashSet
    # the old sections are gone
    check "misc" notin sections
    check "building_and_packaging" notin sections
    # the folded/moved pages live in their new homes
    let routes = entries.mapIt(it.routePath)
    check "/reference/contributing" in routes
    check "/reference/build_systems" in routes
    check "/getting_started/installation" in routes

  test "WebFlow-listed pages lead each section in WebFlow order":
    var bySection = initTable[string, seq[string]]()
    for e in entries:                 # entries are (section, order, slug)-sorted
      bySection.mgetOrPut(e.section, @[]).add e.routePath
    proc leads(section: string; expected: seq[string]) =
      let actual = bySection[section]
      check actual[0 ..< expected.len] == expected
    leads("getting_started", @["/getting_started", "/getting_started/introduction",
      "/getting_started/installation",
      "/getting_started/noir", "/getting_started/stylus", "/getting_started/wasm",
      "/getting_started/ruby", "/getting_started/python"])
    leads("usage_guide", @["/usage_guide", "/usage_guide/cli", "/usage_guide/gui",
      "/usage_guide/tracepoints", "/usage_guide/codetracer_shell"])
    leads("reference", @["/reference/build_systems", "/reference/contributing",
      "/reference/troubleshooting", "/reference/environment_variables",
      "/reference/building_docs"])

  test "the sidebar renders the three sections in WebFlow order":
    let manifest = buildManifestFromContent(dir)
    let navPages = buildNavPages(manifest,
      proc(p: string): ContentEntry = loadContentEntry(dir, p))
    let sidebar = buildSidebar(navPages, "", bookDocsConfig().sectionOrder)
    # top-level section keys, in the order the sidebar lays them out
    let keys = sidebar.sections.mapIt(it.key).filterIt(it.len > 0)
    check keys == @["getting_started", "usage_guide", "reference"]
