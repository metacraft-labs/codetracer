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

proc unqualifiedCertificateClaim(page: string; allowed: seq[string];
                                 where: string): string =
  ## The first mention of a test *certificate* on `page` that is NOT one of the
  ## `allowed` qualified phrases, as a quotable excerpt; `""` when the page is
  ## clean.
  ##
  ## Returns rather than asserts, deliberately.  A `check` written inside a
  ## helper proc updates that PROC's status variable, not the enclosing
  ## `test`'s, so the suite prints `[OK]` for a test whose assertion just
  ## failed — the trap RV-7 found across five `justfile` lanes.  The caller
  ## does the `check`, in the `test` block where it binds.
  ##
  ## `ct test` ships `discover` and `run` and issues no certificates at all
  ## (`Agent-Prompt-Guidance.md` §6).  A page that says otherwise sends a
  ## reader looking for an artefact that does not exist, so the only mentions
  ## permitted are the ones that state the absence.
  ##
  ## Matching is on the stem `certificat`, so `certificate`, `certificates` and
  ## `certification` are all caught, and it is case-insensitive so a sentence
  ## opening with the word does not slip through.  The allowed phrases are
  ## deleted from the text first, which means a claim smuggled onto the same
  ## line as a legitimate mention is still found.
  var remaining = page
  for phrase in allowed:
    doAssert phrase in remaining,
      where & ": allow-listed phrase is no longer on the page: " & phrase
    remaining = remaining.replace(phrase, "")
  let lowered = remaining.toLowerAscii
  let at = lowered.find("certificat")
  if at < 0:
    return ""
  # Name the offending text, so the failure says what to delete.
  let start = max(0, at - 80)
  let finish = min(remaining.len - 1, at + 120)
  where & ": unqualified certificate claim near: ..." &
    remaining[start .. finish] & "..."

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
    #
    # +1 = `usage_guide/deep_review`, the DeepReview workflow page (RV-8).
    check entries.len == 61

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

  test "DeepReview is documented, and only as far as it ships":
    ## RV-8's own rule: "Only documents what actually shipped. Any deliverable
    ## deferred in an earlier milestone is either absent from the docs or
    ## explicitly marked as not yet available."
    ##
    ## The parts of that rule a test can hold are the ones stated as text: the
    ## page exists and is reachable, the CLI reference carries both command
    ## groups, and the two claims it would be easiest to make wrongly -- that
    ## `ct test` issues certificates, and that `ct review inspect` reads a
    ## materialized dataset -- are absent or qualified.  The page is where a
    ## user forms their expectations, so a false sentence here costs more than
    ## a false one anywhere else in the book.
    let routes = entries.mapIt(it.routePath).toHashSet
    check "/usage_guide/deep_review" in routes

    let page = readFile(dir / "usage_guide" / "deep_review.md")
    # The three commands the workflow is made of.
    check page.contains("ct review collect")
    check page.contains("ct review <PATH>")
    check page.contains("ct agent prompt >> AGENTS.md")
    check page.contains("ct agent end-of-turn")
    # Both trace kinds, and a worked example on a materialized one.
    check page.contains("Materialized")
    check page.contains("nargo") or page.contains("Noir")
    # The deferrals are named, not implied.
    check page.contains("Not yet available")
    check page.contains("no test certificates")
    # ...and no sentence offers certificates as something that exists.
    #
    # This is asserted on the TOKEN, not on a list of phrasings.  The previous
    # version checked three exact literals -- "issues a certificate", "test
    # certificate is issued", "certificates are available" -- which is a test
    # of three sentences nobody was going to write.  Appending the plausible
    # sentence `ct test` issues test certificates for every run, and they are
    # available to any consumer.` to the page left the suite green, so the
    # assertion was decorative: it could not fail for the reason it existed.
    #
    # The rule now is: every occurrence of the token is allow-listed by an
    # exact qualified phrase, and there is nothing left over.  Removing the
    # allowed phrases before the search is what makes it airtight -- a false
    # claim added to the SAME line as a true one is still caught, which a
    # line-based check would miss.
    check unqualifiedCertificateClaim(page,
      allowed = @["issues **no test certificates**"],
      where = "usage_guide/deep_review.md") == ""

    # The usage-guide index routes a reader to it, and the CLI reference
    # carries the flag tables the page defers to.
    check readFile(dir / "usage_guide" / "index.md").contains("deep_review.md")
    let cli = readFile(dir / "reference" / "ct_cli.md")
    check cli.contains("### ct review collect")
    check cli.contains("### ct review inspect")
    check cli.contains("### ct agent evidence")
    check cli.contains("### ct agent end-of-turn")
    check cli.contains("### ct agent prompt")
    # `inspect` is native-only today; the reference must say so rather than
    # presenting it as the way to summarise any dataset.
    check cli.contains("manifest.dr")
    # The CLI reference carries the other legitimately qualified mention, and
    # is guarded the same way: it is the other page a reader forms an
    # expectation about `ct test` from.
    check unqualifiedCertificateClaim(cli,
      allowed = @["test certificates, which `ct test` does not yet issue"],
      where = "reference/ct_cli.md") == ""

    # RV-11: the worked example produces a MATERIALIZED dataset, and
    # `ct review inspect` cannot read one.  A CI reader who follows the example
    # and then reaches the inspect section must be told that outright, not
    # after a sentence recommending the command.  Asserted on the page's own
    # words so the hedge cannot drift back behind the recommendation.
    check page.contains("cannot be inspected")
    # ...and the `ct record` transcript must admit it shows only the tail.
    check page.contains("unused import")
