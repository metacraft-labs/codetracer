## codetracer/docs/book-isonim -- preview-channel (per-PR base path) test (C-target).
##
## Sibling of `test_nightly_channel.nim`. That file pins the two-channel case
## (`/` and `/nightly`); this one pins the THIRD channel `ci/deploy/docs.sh`
## publishes: a pull request's docs preview at `docs.codetracer.com/pr/<N>`,
## built with `basePath = "/pr/<N>"`.
##
## It is a separate file rather than more cases in the nightly one because it
## tests a property the nightly channel cannot: the preview prefix has TWO path
## segments and a per-PR variable in the second one. Everything downstream of
## `normalizeBasePath` concatenates the prefix onto URLs, and a prefix builder
## that only ever saw single-segment `/nightly` can be wrong in ways no nightly
## test would notice -- a normalizer that stripped every slash rather than the
## leading/trailing ones, say, would turn `/pr/7/` into `/pr7`, and the nightly
## suite would still be green.
##
## The second property here is ISOLATION between previews. Every open pull
## request publishes into the same `/pr/` namespace, so two previews whose URL
## sets overlapped would have readers of PR 7 landing on PR 8's pages. That is
## checked directly rather than assumed from the prefix being interpolated.
##
## No filesystem fixture beyond a temp dir and the old book's real SUMMARY.md,
## so this runs without building the site.

import std/[unittest, os, strutils, sets]
import ../src/docs_config
import ../src/redirects

proc consumerDir(): string =
  currentSourcePath().parentDir().parentDir()

proc summaryPath(): string = consumerDir() / "../book/src/SUMMARY.md"

proc redirectsInto(dir, basePath: string): RedirectCounts =
  ## Generate this channel's redirect artifacts into a fresh `dir`.
  removeDir(dir)
  createDir(dir)
  generateRedirects(dir, summaryPath(), basePath)

proc manifestLines(dir: string): seq[string] =
  for line in readFile(dir / "_redirects").splitLines():
    if line.len > 0:
      result.add line

suite "a pull request's docs preview is built under its own URL prefix":
  test "a preview base path is a two-segment prefix on both the framework prefix and the origin":
    let cfg = bookDocsConfig("/pr/123")
    check cfg.basePath == "/pr/123"
    # Canonical/og/sitemap URLs are absolute and are NOT rewritten by the
    # framework's root-relative pass -- they have to carry the prefix here, and
    # they have to carry BOTH of its segments.
    check cfg.baseUrl == "https://docs.codetracer.com/pr/123"

  test "the preview base path is normalized, so a stray slash cannot break the site":
    # Same contract as the nightly channel's, re-checked for a multi-segment
    # prefix: the INNER slash must survive normalization while the leading and
    # trailing ones are canonicalized. Both prefix owners normalize
    # independently -- `bookDocsConfig` is not the only caller-facing entry
    # point, and `generateRedirects` concatenates its `basePath` straight onto
    # URLs.
    let outDir = getTempDir() / "ct-book-preview-normalized"
    for spelling in ["pr/7", "/pr/7", "/pr/7/", " /pr/7 "]:
      check bookDocsConfig(spelling).basePath == "/pr/7"
      check bookDocsConfig(spelling).baseUrl == "https://docs.codetracer.com/pr/7"

      discard redirectsInto(outDir, spelling)
      check metaRefreshTarget(readFile(outDir / "getting_started" / "python.html")) ==
        "/pr/7/getting_started/python"
      check readFile(outDir / "_redirects").contains(
        "/pr/7/installation.html /pr/7/getting_started/installation 301")
    removeDir(outDir)

  test "every redirect stub and manifest entry stays inside the preview":
    let outDir = getTempDir() / "ct-book-preview-redirects"
    let written = redirectsInto(outDir, "/pr/4242")
    defer: removeDir(outDir)
    check written.legacy > 0
    # DS-1's second family: clean routes the book has moved. Their stubs live at
    # `<old route>/index.html`, so a preview that emitted them unprefixed would
    # put a redirect to the RELEASED site at the exact path the preview's own
    # reader lands on.
    check written.moved > 0
    for moved in movedRoutes:
      let movedStub = outDir / moved.oldRoute[1 .. ^1] / "index.html"
      check fileExists(movedStub)
      check metaRefreshTarget(readFile(movedStub)) == "/pr/4242" & moved.newRoute

    let stub = outDir / "getting_started" / "python.html"
    check fileExists(stub)
    # A stub that redirected to `/getting_started/python` would bounce the
    # reviewer out of the preview and onto the RELEASED site -- silently
    # showing them the very content the pull request is changing.
    check metaRefreshTarget(readFile(stub)) == "/pr/4242/getting_started/python"

    # Both halves of every manifest line -- the legacy URL and its target --
    # have to be inside the preview, not just the one that is easier to get
    # right.
    for line in manifestLines(outDir):
      let parts = line.split(' ')
      check parts.len == 3
      check parts[0].startsWith("/pr/4242/")
      check parts[1].startsWith("/pr/4242/")
      check parts[2] == "301"

  test "two previews of the same content share no URL":
    # Every open pull request publishes into the same `/pr/` namespace. If the
    # per-PR segment ever stopped reaching some URL, the two previews would
    # overlap there and a reader of one would be served the other's page.
    let dirSeven = getTempDir() / "ct-book-preview-7"
    let dirEight = getTempDir() / "ct-book-preview-8"
    discard redirectsInto(dirSeven, "/pr/7")
    discard redirectsInto(dirEight, "/pr/8")
    defer:
      removeDir(dirSeven)
      removeDir(dirEight)

    var sevenUrls = initHashSet[string]()
    for line in manifestLines(dirSeven):
      for field in line.split(' ')[0 .. 1]:
        sevenUrls.incl field
    check sevenUrls.len > 0
    for line in manifestLines(dirEight):
      for field in line.split(' ')[0 .. 1]:
        check field notin sevenUrls

    # The stubs live at the same public-relative paths in both previews (they
    # are the same pages), but each must point INTO its own preview.
    let stubRel = "getting_started" / "python.html"
    check metaRefreshTarget(readFile(dirSeven / stubRel)) == "/pr/7/getting_started/python"
    check metaRefreshTarget(readFile(dirEight / stubRel)) == "/pr/8/getting_started/python"

  test "a preview differs from the released channel only in where it is hosted":
    # A preview is meant to answer "what will the docs look like after this
    # merge?", so anything about the site that the CHANNEL changes would make
    # the preview lie about the released result.
    let released = bookDocsConfig()
    let preview = bookDocsConfig("/pr/4242")
    check preview.siteTitle == released.siteTitle
    check preview.siteDescription == released.siteDescription
    check preview.sectionOrder == released.sectionOrder
    check preview.headerLinks == released.headerLinks
    check preview.sidebarLinks == released.sidebarLinks
    check preview.footerHtml == released.footerHtml
    # Root-relative config URLs are prefixed by the framework's pass at render
    # time, not here -- they must stay identical in both configs.
    check preview.stylesheetHref == released.stylesheetHref
    check preview.siteLogo == released.siteLogo
    check preview.logoHref == released.logoHref
    # ... and the only two fields that may differ, do.
    check preview.basePath != released.basePath
    check preview.baseUrl != released.baseUrl

  test "a preview never collides with the released or nightly channels":
    let released = bookDocsConfig()
    let nightly = bookDocsConfig("/nightly")
    let preview = bookDocsConfig("/pr/4242")
    check preview.basePath != nightly.basePath
    check preview.baseUrl != nightly.baseUrl
    # `/pr/...` must not be a prefix of, or prefixed by, the other channels'
    # roots: `docs.sh` gives the released channel `pr` in its preserve list and
    # nothing else, so an overlap here would be an overlap on gh-pages too.
    check not preview.basePath.startsWith(nightly.basePath)
    check not nightly.basePath.startsWith(preview.basePath)
    check released.basePath == ""
