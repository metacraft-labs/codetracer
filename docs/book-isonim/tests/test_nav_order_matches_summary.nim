## codetracer/docs/book-isonim -- nav-structure test (C-target).
##
## The new book DELIBERATELY diverges from the old mdBook SUMMARY.md to match
## the WebFlow docs organization: three top-level sections in a fixed order
## (Getting Started, Usage Guide, Reference), with `building_and_packaging` +
## `misc` folded into `reference` and the root `installation` page moved under
## `getting_started`. DS-1 added a FOURTH, `deep_review`, between Usage Guide
## and Reference. This test proves that organization:
##   1. every page is still present (nothing dropped in the fold);
##   2. the content collapses to exactly those four sections -- no strays, and
##      none of the pre-fold sections back;
##   3. the WebFlow-listed pages lead each section in WebFlow order; and
##   4. the sidebar renders the sections in the configured order (via
##      `DocsConfig.sectionOrder`, not the framework's default alphabetical --
##      which would put `deep_review` first, ahead of Getting Started).
##
## The DeepReview section's own contract (routing, sidebar placement, the
## `/usage_guide/deep_review` redirect, and what the pages may claim) is
## `test_deep_review_section.nim`; what stays here is the book-wide structure
## every section shares.

import std/[unittest, os, tables, sequtils, sets, strutils]
import core/[content, routes, navigation_vm]
import ../src/docs_config

proc contentDir(): string =
  currentSourcePath().parentDir().parentDir() / "content"

proc normalizedProse(text: string): string =
  ## `text` with every run of whitespace collapsed to one space, so a phrase
  ## matches however the paragraph carrying it happens to be wrapped.
  text.splitWhitespace().join(" ")

proc unqualifiedCertificateClaim(page: string; allowed: seq[string];
                                 where: string): string =
  ## The first mention of a test *certificate* on `page` that is NOT one of the
  ## `allowed` phrases, as a quotable excerpt; `""` when the page is clean.
  ##
  ## Returns rather than asserts, deliberately.  A `check` written inside a
  ## helper proc updates that PROC's status variable, not the enclosing
  ## `test`'s, so the suite prints `[OK]` for a test whose assertion just
  ## failed — the trap RV-7 found across five `justfile` lanes.  The caller
  ## does the `check`, in the `test` block where it binds.
  ##
  ## History: until CT-Test-Certificates CTC-3h this guarded the claim that
  ## `ct test` issues certificates at all, which it did not document.  It now
  ## does, and certificates are bound to the CONTENT of the tracked files, so
  ## the claims that would mislead a reader are different ones: that a review
  ## dataset carries a certificate, or the obsolete "commit, then run the tests
  ## again to certify the commit" workflow.  The mechanism is unchanged: every
  ## mention is one of a few exact, reviewed phrases, and nothing is left over.
  ##
  ## Matching is on the stem `certif`, so `certificate`, `certificates`,
  ## `certify` and `certified` are all caught, and it is case-insensitive so a
  ## sentence opening with the word does not slip through.  Page and phrases
  ## are whitespace-normalized first (re-wrapping a paragraph is not a change
  ## of claim), and the allowed phrases are deleted from the text before the
  ## search, which means a claim smuggled onto the same line as a legitimate
  ## mention is still found.
  var remaining = normalizedProse(page)
  for phrase in allowed:
    let flat = normalizedProse(phrase)
    doAssert flat in remaining,
      where & ": allow-listed phrase is no longer on the page: " & phrase
    remaining = remaining.replace(flat, "")
  let lowered = remaining.toLowerAscii
  let at = lowered.find("certif")
  if at < 0:
    return ""
  # Name the offending text, so the failure says what to delete.
  let start = max(0, at - 80)
  let finish = min(remaining.len - 1, at + 120)
  where & ": unqualified certificate claim near: ..." &
    remaining[start .. finish] & "..."

const
  RerunMarkers = ["again", "re-run", "rerun", "second run", "run twice"]
    ## Words that say the tests are run another time.
  Negations = ["no", "not", "never", "without", "nothing", "don't", "needn't"]
    ## A sentence carrying one of these, as a word, is telling the reader NOT
    ## to do what it mentions.

proc obsoleteWorkflowClaim(page: string; where: string): string =
  ## The first sentence on `page` that teaches the workflow the 2026-10-09
  ## revision of the test-certificate standard removed — commit, then run the
  ## tests again to obtain a certificate for the commit — as a quotable
  ## excerpt; `""` when there is none.
  ##
  ## A certificate is bound to the content of the tracked files, so the first
  ## passing run already covers a commit that records exactly the tested
  ## content.  A page that tells a reader to re-run after committing sends
  ## them through a ceremony that adds nothing, and teaches them that a
  ## certificate "attests a commit", which is the misreading that leads to
  ## testing only after committing.
  ##
  ## The rule, per sentence: mentions tests, says "commit" and THEN a re-run
  ## word, and carries no negation.  The order matters: "run the tests again
  ## before committing" is correct advice (the content changed), and "commit,
  ## then run the tests again" is the obsolete workflow.  Returns rather than
  ## asserts, for the reason `unqualifiedCertificateClaim` gives.
  let flat = normalizedProse(page)
  var sentence = ""
  var sentences: seq[string]
  for i, c in flat:
    sentence.add c
    if c in {'.', '!', '?', ';'} and (i + 1 >= flat.len or flat[i + 1] == ' '):
      sentences.add sentence
      sentence = ""
  if sentence.len > 0: sentences.add sentence
  for s in sentences:
    let lowered = s.toLowerAscii
    if "test" notin lowered: continue
    let commitAt = lowered.find("commit")
    if commitAt < 0: continue
    var rerun = false
    for marker in RerunMarkers:
      if lowered.find(marker, commitAt) >= 0:
        rerun = true
    if not rerun: continue
    var negated = false
    for word in lowered.split({' ', ',', ';', ':', '(', ')', '*', '`', '"',
                               '-', '/', '[', ']', '.', '!', '?'}):
      if word in Negations:
        negated = true
    if not negated:
      return where & ": teaches the obsolete re-run-after-commit workflow: \"" &
        s.strip() & "\""
  ""

proc ctTestSection(cli: string): string =
  ## The `### ct test` section of the CLI reference, up to the next `### `
  ## heading — the one place the book documents test certificates in full.
  let start = cli.find("\n### ct test\n")
  doAssert start >= 0, "reference/ct_cli.md has no `### ct test` section"
  let finish = cli.find("\n### ", start + 1)
  result = if finish < 0: cli[start .. ^1] else: cli[start ..< finish]

suite "book nav matches the book's four-section organization":
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
    # +5 = the `deep_review` section (DS-1), which is the single RV-8
    # `usage_guide/deep_review` article split into an Introduction that argues
    # why the feature exists plus four articles: collecting, reading, the agent
    # workflow, and the deferrals.
    check entries.len == 65

  test "content collapses to exactly the four sections":
    var sections: seq[string] = @[]
    for e in entries:
      if e.section.len > 0 and e.section notin sections:
        sections.add e.section
    check sections.toHashSet ==
      ["getting_started", "usage_guide", "deep_review", "reference"].toHashSet
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
    # DS-1: the section opens with the Introduction, before any command page.
    leads("deep_review", @["/deep_review", "/deep_review/collecting",
      "/deep_review/reading"])

  test "the sidebar renders the four sections in the configured order":
    let manifest = buildManifestFromContent(dir)
    let navPages = buildNavPages(manifest,
      proc(p: string): ContentEntry = loadContentEntry(dir, p))
    let sidebar = buildSidebar(navPages, "", bookDocsConfig().sectionOrder)
    # top-level section keys, in the order the sidebar lays them out
    let keys = sidebar.sections.mapIt(it.key).filterIt(it.len > 0)
    check keys == @["getting_started", "usage_guide", "deep_review", "reference"]

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
    ## content exists and is reachable, the CLI reference carries both command
    ## groups, and the two claims it would be easiest to make wrongly -- that
    ## `ct test` issues certificates, and that `ct review inspect` reads a
    ## materialized dataset -- are absent or qualified.  These are where a user
    ## forms their expectations, so a false sentence here costs more than a
    ## false one anywhere else in the book.
    ##
    ## DS-1 split the single page into a section, so the assertions read the
    ## section's pages joined rather than one file.  Reading them JOINED is
    ## deliberate: the rule is about what the documentation as a whole says, and
    ## pinning each sentence to the page it currently lives on would fail the
    ## next time an article is rebalanced without anything untrue being written.
    ## `test_deep_review_section.nim` pins the per-page structure.
    let routes = entries.mapIt(it.routePath).toHashSet
    check "/deep_review" in routes

    var page = ""
    for path in walkDirRec(dir / "deep_review"):
      if path.endsWith(".md"):
        page.add readFile(path) & "\n"
    check page.len > 0

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
    # CTC-3h: `ct test` issues certificates, and a review dataset carries none.
    # Asserted on the normalized prose so a re-wrap is not a failure.
    check normalizedProse(page).contains(
      "a review dataset carries **no test certificates**")
    # ...and no sentence makes any OTHER claim about certificates.
    #
    # This is asserted on the TOKEN, not on a list of phrasings.  The original
    # RV-8 version checked three exact literals -- "issues a certificate", "test
    # certificate is issued", "certificates are available" -- which is a test
    # of three sentences nobody was going to write.  Appending a plausible
    # false sentence to the page left the suite green, so the assertion was
    # decorative: it could not fail for the reason it existed.
    #
    # The rule is: every occurrence of the token is allow-listed by an exact
    # reviewed phrase, and there is nothing left over.  Removing the allowed
    # phrases before the search is what makes it airtight -- a false claim
    # added to the SAME line as a true one is still caught, which a line-based
    # check would miss.  Since CTC-3h the phrase states both halves of the
    # truth: `ct test` issues a certificate, and a review does not carry it.
    check unqualifiedCertificateClaim(page,
      allowed = @["a passing run of `ct test` issues a test certificate, but " &
                  "a review dataset carries **no test certificates**"],
      where = "deep_review/*.md") == ""
    # The obsolete workflow ("commit, then run ct test again to certify the
    # commit") is the over-claim to catch now: it is what a reader who still
    # thinks a certificate attests a commit would write.
    check obsoleteWorkflowClaim(page, "deep_review/*.md") == ""

    # The usage-guide index still routes a reader to the feature, which now
    # lives one section over -- the guide is where somebody learning to record
    # and replay is standing when they first need it.
    check readFile(dir / "usage_guide" / "index.md").contains("(/deep_review)")
    let cli = readFile(dir / "reference" / "ct_cli.md")
    check cli.contains("### ct review collect")
    check cli.contains("### ct review inspect")
    check cli.contains("### ct agent evidence")
    check cli.contains("### ct agent end-of-turn")
    check cli.contains("### ct agent prompt")
    # `inspect` is native-only today; the reference must say so rather than
    # presenting it as the way to summarise any dataset.
    check cli.contains("manifest.dr")
    # The CLI reference documents certificates in its `ct test` section and
    # mentions them elsewhere only in the reviewed phrases below: the command
    # table's two rows and the `ct agent prompt` paragraph.  The section itself
    # is held by "the book does not document the removed --certificate flag"
    # and by the obsolete-workflow rule.
    let section = ctTestSection(cli)
    check unqualifiedCertificateClaim(cli.replace(section, ""),
      allowed = @[
        "Run the tests; a passing run issues a test certificate",
        "Ask whether your test certificates cover a state",
        "A passing run's test certificate already covers that commit, so " &
          "the text tells the agent not to run the tests again after " &
          "committing."],
      where = "reference/ct_cli.md") == ""
    check obsoleteWorkflowClaim(cli, "reference/ct_cli.md") == ""

    # RV-11: the worked example produces a MATERIALIZED dataset, and
    # `ct review inspect` cannot read one.  A CI reader who follows the example
    # and then reaches the inspect section must be told that outright, not
    # after a sentence recommending the command.  Asserted on the page's own
    # words so the hedge cannot drift back behind the recommendation.
    check page.contains("cannot be inspected")
    # ...and the `ct record` transcript must admit it shows only the tail.
    check page.contains("unused import")

  test "the book does not document the removed --certificate flag":
    ## CTC-3e removed `ct test run --certificate <path>`: every certificate
    ## goes to the local certificate store, and nothing is ever written to a
    ## path the caller names.  A book that still documents the flag sends a
    ## reader to an "unknown run argument" error, and teaches them that a
    ## certificate is a file they place, which is the thing the store
    ## replaced.  `--no-certificate` stays and must be documented.
    let cli = readFile(dir / "reference" / "ct_cli.md")
    let section = ctTestSection(cli)
    check section.contains("--no-certificate")
    check section.contains("local certificate store")
    check section.contains("ct test verify --staged")
    check section.contains(".codetracer/test.toml")
    check section.contains("--no-verify")
    # Book-wide: once every `--no-certificate` is set aside, the string
    # `--certificate` appears nowhere -- not in a table row, not in prose.
    for path in walkDirRec(dir):
      if not path.endsWith(".md"): continue
      let text = readFile(path).replace("--no-certificate", "")
      if "--certificate" in text:
        echo path.relativePath(dir), ": documents the removed --certificate flag"
      check "--certificate" notin text
