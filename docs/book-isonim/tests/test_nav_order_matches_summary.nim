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

import std/[unittest, os, tables, sequtils, sets, strutils]
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
    # WebFlow-parity utility pages (faq / support / sign-in) = 50, plus the
    # nine live-request-tracking pages, plus the `sign-up` page = 60.  The
    # sign-up page existed only as a LINK from `sign-in` (pinned by
    # test_support_pages) until the link-resolution test below caught that
    # nothing was on the other end of it.
    #
    # The nine: `usage_guide/live-request-tracking` (the overview that routes
    # a reader to their language) + one `usage_guide/live-requests-<lang>`
    # page for each of the six languages whose recorders publish request
    # spans (python, ruby, php, elixir, javascript, native) + the
    # `getting_started/php` and `getting_started/elixir` basics pages, which
    # were the only supported languages with no getting-started page at all.
    check entries.len == 60

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

  test "every internal link resolves to a page that exists":
    ## Dangling cross-references are the failure mode a hand-maintained book
    ## drifts into first: a page is renamed or never written, and the links to
    ## it keep rendering as ordinary links that 404 on click. Nothing else in
    ## the suite would notice, because each page compiles fine on its own.
    ##
    ## Only root-relative markdown links are checked. External URLs are not
    ## ours to validate, and anchors (`#section`) are stripped before lookup
    ## because they address a position within a page, not a page.
    ##
    ## `/assets/...` is NOT a route -- it is the served form of `static/...`,
    ## so those links are resolved against the static tree on disk instead. A
    ## missing screenshot is just as broken as a missing page, and this is the
    ## check that keeps the generated-asset story honest: a page may only
    ## reference an image that something actually produces.
    let routes = entries.mapIt(it.routePath).toHashSet
    let staticDir = dir.parentDir / "static"
    var dangling: seq[string] = @[]
    for path in walkDirRec(dir):
      if not path.endsWith(".md"): continue
      let body = readFile(path)
      var i = 0
      while true:
        let open = body.find("](/", i)
        if open < 0: break
        let close = body.find(')', open)
        if close < 0: break
        var target = body[open + 2 ..< close]
        let hash = target.find('#')
        if hash >= 0: target = target[0 ..< hash]
        target = target.strip()
        if target.len == 0:
          i = close + 1
          continue
        let ok =
          if target.startsWith("/assets/"):
            fileExists(staticDir / target["/assets/".len .. ^1])
          else:
            target in routes
        if not ok:
          dangling.add(path.relativePath(dir) & " -> " & target)
        i = close + 1
    if dangling.len > 0:
      echo "dangling internal links:"
      for d in dangling: echo "  ", d
    check dangling.len == 0

  test "every language with live request tracking has a guide":
    ## The six languages whose recorders publish request spans are the six
    ## `serverSupport` recognises in
    ## src/ct/trace/recorder_dispatch.nim. A language wired up in the CLI but
    ## missing here is a user who is told the feature exists and then cannot
    ## find out how to use it -- which is how `php` and `elixir` came to have
    ## no getting-started page at all despite being supported.
    let routes = entries.mapIt(it.routePath).toHashSet
    for lang in ["python", "ruby", "php", "elixir", "javascript", "native"]:
      check "/usage_guide/live-requests-" & lang in routes
    # ...and the overview that routes a reader to them.
    check "/usage_guide/live-request-tracking" in routes
