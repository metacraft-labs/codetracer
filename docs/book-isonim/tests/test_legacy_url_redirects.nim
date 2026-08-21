## codetracer/docs/book-isonim -- legacy-URL redirect fidelity test (C-target).
##
## Proves every legacy mdBook `*.html` deep link is preserved after the
## migration to clean isonim-docs URLs. The old book served each page at
## `/section/page.html`; the SSG serves `/section/page`. This test:
##
##   1. (re)invokes the redirect generator against the real built `public/`
##      (the verification pipeline runs `just build` first, which also emits
##      these artifacts; regenerating is idempotent and makes the test
##      self-sufficient), then
##   2. asserts a representative set of legacy URLs has a stub in `public/`
##      whose meta-refresh target is the correct clean URL, and
##   3. asserts NO legacy URL from the FULL enumerated set (parsed from the
##      old book's SUMMARY.md) is left without a redirect -- each either has
##      a stub pointing at a real route, or (the root /index.html) is served
##      by the real generated home page.
##
## No skips: if the site has not been built, the real-page assertions fail
## loudly (run `just build` first).

import std/[unittest, os, strutils, sets, tables]
import core/content
import ../src/redirects

proc consumerDir(): string =
  currentSourcePath().parentDir().parentDir()

proc publicDir(): string = consumerDir() / "public"
proc summaryPath(): string = consumerDir() / "../book/src/SUMMARY.md"
proc contentDir(): string = consumerDir() / "content"

suite "legacy mdBook *.html URLs redirect to the new clean URLs":
  # Ensure the redirect artifacts exist in public/ (idempotent regen).
  let stubsWritten = generateRedirects(publicDir(), summaryPath())
  let redirects = legacyRedirects(summaryPath())

  test "the old book SUMMARY yields the expected legacy URL count":
    # 45 SUMMARY-listed pages + the mdBook root copy (/index.html).
    check redirects.len == 46
    var needStub = 0
    for r in redirects:
      if r.needsStub: inc needStub
    check needStub == 45
    check stubsWritten.legacy == 45
    # The second family (`movedRoutes`) is counted separately so this suite
    # keeps asserting the mdBook migration is intact even as the book's own
    # moves accumulate. DS-1's `/usage_guide/deep_review` is the first.
    check stubsWritten.moved == movedRoutes.len
    check stubsWritten.moved >= 1

  test "representative legacy URLs have a stub pointing at the right clean URL":
    let expected = {
      "getting_started/python.html": "/getting_started/python",
      "usage_guide/cli.html": "/usage_guide/cli",
      "installation.html": "/getting_started/installation",
      "reference/ct_cli.html": "/reference/ct_cli",
      "misc/troubleshooting.html": "/reference/troubleshooting",
    }.toTable
    for oldRel, cleanUrl in expected:
      let stubPath = publicDir() / oldRel
      check fileExists(stubPath)
      let html = readFile(stubPath)
      check metaRefreshTarget(html) == cleanUrl
      # canonical + JS fallback carry the same target.
      check html.contains("rel=\"canonical\" href=\"" & cleanUrl & "\"")
      check html.contains("location.replace(\"" & cleanUrl & "\")")

  test "the overview -> section-index and CONTRIBUTING -> reference remaps hold":
    var byOld = initTable[string, string]()
    for r in redirects:
      byOld[r.oldRelPath] = r.newRoute
    check byOld["getting_started/overview.html"] == "/getting_started"
    check byOld["usage_guide/overview.html"] == "/usage_guide"
    # CONTRIBUTING folds into the reference section (the M1 3-section reorg
    # folded `misc/` and `building_and_packaging/` into `reference/`).
    check byOld["CONTRIBUTING.html"] == "/reference/contributing"
    # M5: the Introduction prose moved out of the root landing into its own
    # Getting Started article, so its legacy URL follows the content.
    check byOld["introduction.html"] == "/getting_started/introduction"

  test "the real generated site is present (build ran)":
    # The redirect stubs are ADDITIONAL to the real pages (46 M1 pages + the M5
    # `getting_started/introduction` split + the three WebFlow utility pages
    # faq/support/sign-in = 50, + the nine live-request-tracking pages + the
    # `sign-up` page = 60, + the five `deep_review` section pages DS-1 split the
    # single `usage_guide/deep_review` article into = 65); the framework output
    # must still be intact.
    check dirExists(publicDir())
    check fileExists(publicDir() / "index.html")
    let entries = loadContentEntries(contentDir())
    check entries.len == 65

  test "every moved clean route redirects to where its content went":
    ## The second redirect family. These are URLs the SSG itself published and
    ## the book later moved, so unlike the mdBook set there is no external
    ## SUMMARY to enumerate them -- `movedRoutes` IS the list, and it is
    ## append-only. Each entry has to point at a route the site really serves,
    ## or the redirect just relocates the 404.
    var realRoutes = initHashSet[string]()
    for e in loadContentEntries(contentDir()):
      realRoutes.incl e.routePath

    let moved = movedRouteRedirects()
    check moved.len == movedRoutes.len
    check moved.len >= 1
    for r in moved:
      check r.needsStub
      check r.newRoute in realRoutes
      # The old route must NOT still be served: a live page and a redirect at
      # the same URL means the content did not move, and the reader gets
      # whichever the file system hands over.
      check r.oldUrl notin realRoutes
      # The stub lives where the real page used to be written -- `<route>/
      # index.html` -- which is the only path GitHub Pages serves for the
      # trailing-slash URL a reader actually has.
      let stubPath = publicDir() / r.oldRelPath
      check r.oldRelPath.endsWith("/index.html")
      check fileExists(stubPath)
      check metaRefreshTarget(readFile(stubPath)) == r.newRoute

  test "no legacy URL is left without a redirect":
    # Build the set of clean routes the real site actually serves, so we can
    # confirm every redirect points at a real destination (not a dead link).
    var realRoutes = initHashSet[string]()
    for e in loadContentEntries(contentDir()):
      realRoutes.incl e.routePath

    for r in redirects:
      # Every target must be a route the site really serves.
      check r.newRoute in realRoutes
      if r.needsStub:
        # A stub file must exist at the legacy path and resolve to the route.
        let stubPath = publicDir() / r.oldRelPath
        check fileExists(stubPath)
        check metaRefreshTarget(readFile(stubPath)) == r.newRoute
      else:
        # The one collision (root /index.html) is served by the real home
        # page -- it must exist and must NOT have been overwritten by a stub.
        check r.oldRelPath == "index.html"
        check r.newRoute == "/"
        check fileExists(publicDir() / "index.html")
        check metaRefreshTarget(readFile(publicDir() / "index.html")) == ""

  test "_redirects manifest lists every intended redirect as a 301":
    let manifest = readFile(publicDir() / "_redirects")
    for r in redirects:
      check manifest.contains(r.oldUrl & " " & r.newRoute & " 301")
    for r in movedRouteRedirects():
      check manifest.contains(r.oldUrl & " " & r.newRoute & " 301")
    # Including the ONE entry that has no stub. `/index.html` is served by the
    # real generated home page, so nothing is written there -- but the manifest
    # describes the intended redirect rather than the files on disk, and a
    # `_redirects`-honouring front end should still canonicalize `/index.html`
    # onto `/`. Pinned because it is the one line whose presence is a judgement
    # call rather than a mechanical consequence.
    check manifest.contains("/index.html / 301")

    # Every line is a well-formed three-field rule, so a malformed one cannot
    # ride along unnoticed behind the `contains` checks above.
    var lineCount = 0
    for line in readFile(publicDir() / "_redirects").splitLines():
      if line.len == 0: continue
      inc lineCount
      let parts = line.split(' ')
      check parts.len == 3
      check parts[0].startsWith("/")
      check parts[1].startsWith("/")
      check parts[2] == "301"
    check lineCount == redirects.len + movedRouteRedirects().len
