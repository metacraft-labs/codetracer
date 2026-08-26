## codetracer/docs/book-isonim -- the DeepReview section (DS-1), C-target.
##
## DeepReview used to be ONE page inside `usage_guide`. DS-1 gives it a section
## of its own, opening with an Introduction that argues why it exists before any
## command appears. Three things have to hold for that to be a move rather than
## a regression, and this file is one test per thing:
##
##   1. **The section is routed and sits in the sidebar where it was placed.**
##      `sectionOrder` in `src/docs_config.nim` is the only thing standing
##      between a new content directory and the framework's default
##      *alphabetical* section order -- which would file `deep_review` FIRST, in
##      front of Getting Started.
##   2. **The published `/usage_guide/deep_review` URL still resolves.** That URL
##      is live on both the released and nightly channels, so a move that drops
##      it is a 404 a reader meets by following a link somebody already shared.
##      On GitHub Pages only a real file at the old path redirects (see
##      `src/redirects.nim`), so this is asserted against the BUILT `public/`
##      tree, not against a table.
##   3. **Nothing on the new pages over-claims.** An Introduction is where
##      enthusiasm creeps in, and the five deferrals below are the ones this
##      feature is most often described as not having. Each is asserted on the
##      page's own words.
##
## No skips: assertions 2 and 4 read the real built site, and fail loudly if
## `just build` has not been run.

import std/[unittest, os, strutils, sequtils, sets]
import core/[content, routes, navigation_vm]
import ../src/docs_config
import ../src/redirects

proc consumerDir(): string =
  currentSourcePath().parentDir().parentDir()

proc contentDir(): string = consumerDir() / "content"
proc publicDir(): string = consumerDir() / "public"
proc sectionDir(): string = contentDir() / "deep_review"

const sectionRoutes = [
  "/deep_review",
  "/deep_review/collecting",
  "/deep_review/reading",
  "/deep_review/agent_workflow",
  "/deep_review/not_yet_available",
]

proc sectionPages(): seq[(string, string)] =
  ## Every markdown file in the section, as (relative name, text). Used by the
  ## honesty checks so a page added later is covered without being listed here
  ## -- a claim is just as wrong on a sixth page as on these five.
  ##
  ## The `doAssert` is load-bearing, not defensive. `walkDirRec` over a
  ## directory that does not exist yields NOTHING and raises nothing, so every
  ## "no page in the section says X" check built on it would pass vacuously the
  ## moment the section were renamed or removed -- a green suite reporting on
  ## content that is not there.
  doAssert dirExists(sectionDir()),
    "the DeepReview section is missing from content/: " & sectionDir()
  for path in walkDirRec(sectionDir()):
    if path.endsWith(".md"):
      result.add (path.relativePath(sectionDir()), readFile(path))
  doAssert result.len >= sectionRoutes.len,
    "expected at least " & $sectionRoutes.len & " pages in the DeepReview " &
    "section, found " & $result.len

type Deferral = object
  ## One thing this feature does NOT do, expressed as a rule a sentence can be
  ## measured against rather than as a phrase to search for.
  what: string          ## the deferral, for the failure message
  topic: string         ## lowercase substring that means "this sentence is about it"
  alsoTopic: string     ## optional second substring both of which must appear
  extraQualifiers: seq[string]  ## words that qualify a mention of THIS topic only

const deferrals = [
  ## The five deferrals `not_yet_available.md` records. Each is guarded on
  ## every page of the section, because a reader forms their expectations
  ## wherever they happen to be standing -- an over-claim on the Introduction
  ## is worse than one on the page that exists to list the limits.
  Deferral(what: "test certificates", topic: "certificat"),
  Deferral(what: "parallel value columns", topic: "column"),
  Deferral(what: "a dragged loop slider", topic: "slider"),
  Deferral(what: "a filtering trace-context selector", topic: "filter"),
  # `inspect` and `materialized` are each common and legitimate on their own
  # (`inspect` names a shipped command; `materialized` names a collector). It
  # is the PAIR that makes the claim, so both have to be in the same sentence
  # before the rule applies.
  Deferral(what: "`ct review inspect` over a materialized dataset",
           topic: "inspect", alsoTopic: "materializ"),
]

const claimQualifiers = [
  ## A mention of a deferred capability is honest when the sentence carrying it
  ## also carries one of these. Deliberately a set of QUALIFIER WORDS rather
  ## than a list of approved sentences: an allow-list of exact phrasings only
  ## catches the phrasings somebody thought of, and the whole point of this
  ## guard is to catch the sentence nobody has written yet.
  "not", "no", "never", "cannot", "can't", "without", "only", "nothing",
  "neither", "nor", "instead", "rather", "fail", "fails", "failed", "failing",
  # Subjunctive: "the same numbers `inspect` WOULD summarise" says, precisely,
  # that it does not.
  "would", "yet",
]

proc claimBlocks(text: string): seq[string] =
  ## `text` split into markdown blocks -- a heading, a list item (with its
  ## wrapped continuation lines), a paragraph, a table row, a fenced snippet.
  ##
  ## Blocks matter because the unit a claim is judged in has to be big enough
  ## to hold the sentence that qualifies it and small enough not to borrow a
  ## qualifier from unrelated prose. A wrapped sentence spans two lines, so
  ## lines are too small; a whole page would let any "not" anywhere excuse
  ## anything, so the page is too big.
  var current = ""
  for rawLine in text.splitLines():
    let line = rawLine.strip(trailing = true)
    let body = line.strip()
    let startsBlock = body.len == 0 or body.startsWith("#") or
      body.startsWith("- ") or body.startsWith("* ") or body.startsWith("|") or
      body.startsWith(">") or body.startsWith("```") or body.startsWith(":::") or
      body.startsWith("---")
    if startsBlock:
      if current.strip().len > 0: result.add current
      current = ""
    current.add line & " "
  if current.strip().len > 0: result.add current

proc claimSentences(text: string): seq[string] =
  ## Every block's sentences, whitespace-normalized. Sentence-level is the
  ## granularity the rule is actually about: "X is not offered" and "X is
  ## offered" differ by one word inside one sentence.
  for blk in claimBlocks(text):
    var sentence = ""
    var i = 0
    while i < blk.len:
      sentence.add blk[i]
      let ender = blk[i] in {'.', '!', '?'} and
        (i + 1 >= blk.len or blk[i + 1] in {' ', '\t'})
      if ender:
        result.add sentence.splitWhitespace().join(" ")
        sentence = ""
      inc i
    if sentence.strip().len > 0:
      result.add sentence.splitWhitespace().join(" ")

proc isQualified(sentence: string; extra: seq[string]): bool =
  ## Whether `sentence` carries a qualifier as a WORD. Substring matching would
  ## let "another", "notice" and "canonical" excuse a claim, which is exactly
  ## the kind of accidental pass this guard exists to not have.
  # Em/en dashes are multi-byte, so they are blanked before the byte-wise split
  # rather than listed as separators. `no-op` and `not-yet` must split too.
  let flat = sentence.toLowerAscii.multiReplace(("—", " "), ("–", " "),
                                                ("“", " "), ("”", " "))
  for word in flat.split({' ', '\t', ',', ';', ':', '(', ')', '*', '`', '"',
                          '\'', '-', '/', '[', ']'}):
    let w = word.strip(chars = {'.', '!', '?', '*', '`', '_'})
    if w.len == 0: continue
    if w in claimQualifiers: return true
    if w in extra: return true
  false

proc overClaim(page: string; where: string): string =
  ## The first sentence on `page` that mentions a deferred capability without
  ## qualifying it, as a quotable excerpt; `""` when the page is clean.
  ##
  ## Returns rather than asserts, deliberately: a `check` inside a helper proc
  ## updates that PROC's status variable, not the enclosing `test`'s, so the
  ## suite would print `[OK]` for an assertion that just failed. The caller does
  ## the `check`.
  for sentence in claimSentences(page):
    let lowered = sentence.toLowerAscii
    for deferral in deferrals:
      if deferral.topic notin lowered: continue
      if deferral.alsoTopic.len > 0 and deferral.alsoTopic notin lowered:
        continue
      if isQualified(sentence, deferral.extraQualifiers): continue
      return where & ": unqualified claim about " & deferral.what &
        ", in: \"" & sentence & "\""
  ""

suite "DeepReview has its own section (DS-1)":
  let entries = loadContentEntries(contentDir())
  let routes = entries.mapIt(it.routePath).toHashSet

  test "the section is routed, and the page it was split from is gone":
    for route in sectionRoutes:
      check route in routes
    # The old single page must not survive alongside the section: two copies of
    # the same prose drift, and the redirect below would then point at a route
    # whose content is the stale one.
    check "/usage_guide/deep_review" notin routes
    check not fileExists(contentDir() / "usage_guide" / "deep_review.md")

  test "the section appears in the sidebar in the configured order":
    # Left to the framework's default, sections sort ALPHABETICALLY -- which
    # puts `deep_review` ahead of `getting_started`. `sectionOrder` is what
    # places it, so the assertion is on the rendered sidebar, not on the config.
    let manifest = buildManifestFromContent(contentDir())
    let navPages = buildNavPages(manifest,
      proc(p: string): ContentEntry = loadContentEntry(contentDir(), p))
    let sidebar = buildSidebar(navPages, "", bookDocsConfig().sectionOrder)
    let keys = sidebar.sections.mapIt(it.key).filterIt(it.len > 0)
    check keys == @["getting_started", "usage_guide", "deep_review", "reference"]

    # ...and inside it, the Introduction leads: a reader arriving cold is told
    # what the feature is FOR before being shown a command.
    var items: seq[string] = @[]
    for section in sidebar.sections:
      if section.key == "deep_review":
        items = section.items.mapIt(it.routePath)
    check items == @sectionRoutes

  test "the old usage_guide URL still resolves, on the built site":
    # `https://docs.codetracer.com/nightly/usage_guide/deep_review/` is live.
    # GitHub Pages honours neither `_redirects` nor `.htaccess`, so the only
    # thing that redirects a reader is a real file at the old path.
    let stub = publicDir() / "usage_guide" / "deep_review" / "index.html"
    check fileExists(stub)
    let html = readFile(stub)
    check metaRefreshTarget(html) == "/deep_review"
    check html.contains("rel=\"canonical\" href=\"/deep_review\"")
    check html.contains("location.replace(\"/deep_review\")")
    # ...and the belt-and-braces manifest agrees with the stub.
    check readFile(publicDir() / "_redirects").contains(
      "/usage_guide/deep_review /deep_review 301")

  test "the moved-route redirect follows the reader into a prefixed channel":
    # A stub that redirected to a bare `/deep_review` from inside `/nightly` or
    # `/pr/<N>` would bounce the reader onto the RELEASED site -- silently, and
    # onto the very content the channel exists to show a different version of.
    let outDir = getTempDir() / "ct-book-ds1-moved-redirects"
    defer: removeDir(outDir)
    for base in ["/nightly", "/pr/4242"]:
      removeDir(outDir)
      createDir(outDir)
      discard generateRedirects(outDir, consumerDir() / "../book/src/SUMMARY.md", base)
      let stub = outDir / "usage_guide" / "deep_review" / "index.html"
      check fileExists(stub)
      check metaRefreshTarget(readFile(stub)) == base & "/deep_review"
      check readFile(outDir / "_redirects").contains(
        base & "/usage_guide/deep_review " & base & "/deep_review 301")

  test "the Introduction makes the argument before it shows a command":
    let intro = readFile(sectionDir() / "index.md")
    # The argument DS-1 asks for: a diff says what changed, a review says what
    # the change did. Asserted on the contrast being made at all, and on it
    # being made ABOVE the first shell command -- an Introduction that opens
    # with `ct review collect` has skipped the part a cold reader needs.
    let didClaim = intro.find("what the")
    let firstCommand = intro.find("```sh")
    check didClaim >= 0
    check firstCommand > didClaim
    # It states the benefit as questions a reviewer can now answer.
    check intro.contains("questions")
    check intro.count('?') >= 4
    # ...and it shows the feature rather than only describing it.
    check intro.contains("/assets/img/deep_review/review-window.png")

  test "no page in the section over-claims what shipped":
    ## The five deferrals this feature is most often described as not having.
    ## Each is asserted on the section's own words, because the page is where a
    ## reader forms their expectations and a false sentence here costs more than
    ## a false one anywhere else in the book.
    # Half the rule: the deferrals are STATED, on the page whose job that is.
    let stated = readFile(sectionDir() / "not_yet_available.md")
    # `ct test` issues no certificates.
    check stated.contains("no test certificates")
    # The trace-context selector does not filter yet.
    check stated.contains("does not filter yet")
    # `ct review inspect` cannot read a materialized dataset.
    check stated.contains("manifest.dr")
    check stated.contains("native datasets only")
    # Values are one strip per line, not parallel columns.
    check stated.contains("not the debugger's parallel value columns")
    # The loop control is a stepper, not a dragged slider.
    check stated.contains("not a dragged slider")

    # The other half, and the one that matters: NO page in the section claims
    # any of the five as a thing that exists. Every page, every deferral, every
    # phrasing -- a rule ("a sentence that raises a deferred capability must
    # qualify it"), not a list of sentences somebody remembered to forbid.
    # Stating the limits on one page while a second page contradicts them is a
    # worse outcome than never having written the limits down.
    for (name, text) in sectionPages():
      let claim = overClaim(text, "deep_review/" & name)
      if claim.len > 0: echo claim
      check claim == ""

  test "the section's own cross-references survive a prefixed build":
    ## The book publishes three channels (`/`, `/nightly`, `/pr/<N>`), and the
    ## framework's base-path pass rewrites ROOT-RELATIVE URLs. An absolute
    ## `https://docs.codetracer.com/...` link is not rewritten, so it would
    ## walk a nightly or preview reader out of the channel and onto the
    ## released site without either of them noticing.
    for (name, text) in sectionPages():
      check not text.contains("](https://docs.codetracer.com")
      check not text.contains("](http://docs.codetracer.com")

    # Every in-book link in the section is root-relative and lands on a route
    # the site really serves. (`test_nav_order_matches_summary` runs the same
    # resolution book-wide; repeated here so the section's own cross-links --
    # five pages that reference each other heavily -- fail in the suite that
    # names them.)
    var dangling: seq[string] = @[]
    for (name, text) in sectionPages():
      var i = 0
      while true:
        let open = text.find("](/", i)
        if open < 0: break
        let close = text.find(')', open)
        if close < 0: break
        var target = text[open + 2 ..< close]
        let hash = target.find('#')
        if hash >= 0: target = target[0 ..< hash]
        target = target.strip()
        if target.len > 0 and not target.startsWith("/assets/") and
           target notin routes:
          dangling.add name & " -> " & target
        i = close + 1
    if dangling.len > 0:
      echo "dangling links inside the DeepReview section:"
      for d in dangling: echo "  ", d
    check dangling.len == 0

  test "the section's screenshots are generated assets that exist":
    ## The pictures are produced by `just capture-deep-review-assets`, never
    ## drawn. A page may only reference an image the capture script actually
    ## writes, and the script must actually write every image the pages
    ## reference -- the two halves drift in opposite directions and each is a
    ## different kind of broken.
    let staticDir = consumerDir() / "static" / "img" / "deep_review"
    let script = consumerDir() / "../../scripts/docs/capture-deep-review-screenshots.sh"
    let scriptText = readFile(script)
    var referenced = initHashSet[string]()
    for (_, text) in sectionPages():
      var i = 0
      while true:
        let open = text.find("(/assets/img/deep_review/", i)
        if open < 0: break
        let close = text.find(')', open)
        if close < 0: break
        referenced.incl text[open + len("(/assets/img/deep_review/") ..< close]
        i = close + 1
    check referenced.len >= 3
    for image in referenced:
      check fileExists(staticDir / image)
      check scriptText.contains(image)
