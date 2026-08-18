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
    check stubsWritten == 45

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
    # `sign-up` page = 60, + `usage_guide/deep_review` = 61); the framework
    # output must still be intact.
    check dirExists(publicDir())
    check fileExists(publicDir() / "index.html")
    let entries = loadContentEntries(contentDir())
    check entries.len == 61

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

  test "_redirects manifest lists every stubbed legacy URL as a 301":
    let manifest = readFile(publicDir() / "_redirects")
    for r in redirects:
      if r.needsStub:
        check manifest.contains(r.oldUrl & " " & r.newRoute & " 301")
