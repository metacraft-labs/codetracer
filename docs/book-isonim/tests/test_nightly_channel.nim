## codetracer/docs/book-isonim -- nightly-channel (base path) test (C-target).
##
## The book is published on two channels off the same content (see
## `ci/deploy/docs.sh`): the released book at `docs.codetracer.com/` (from
## `stable`) and the nightly book at `docs.codetracer.com/nightly` (from `dev`).
## The nightly channel is the SAME site hosted under a URL prefix, and every
## root-relative URL it emits has to carry that prefix or the published page
## reaches for `/assets/...` and 404s on a site that lives at `/nightly/...`.
##
## Two things own that prefix in this consumer, and this test pins both:
##
##   1. `bookDocsConfig(basePath)` -- what the framework's own base-path pass
##      keys off (`DocsConfig.basePath`) plus the ABSOLUTE origin the
##      canonical/sitemap URLs are built from (`baseUrl`), which the framework
##      does NOT prefix for us; and
##   2. `generateRedirects(..., basePath)` -- the legacy `*.html` stubs and the
##      `_redirects` manifest, which are hand-emitted HTML the framework's pass
##      never sees.
##
## No filesystem fixture beyond a temp dir and the old book's real SUMMARY.md,
## so this runs without building the site.

import std/[unittest, os, strutils]
import ../src/docs_config
import ../src/redirects

proc consumerDir(): string =
  currentSourcePath().parentDir().parentDir()

proc summaryPath(): string = consumerDir() / "../book/src/SUMMARY.md"

suite "the nightly channel is built under its URL prefix":
  test "the released channel is the unprefixed default":
    let cfg = bookDocsConfig()
    check cfg.basePath == ""
    check cfg.baseUrl == "https://docs.codetracer.com"

  test "a base path sets both the framework prefix and the absolute origin":
    let cfg = bookDocsConfig("/nightly")
    check cfg.basePath == "/nightly"
    # Canonical/og/sitemap URLs are absolute and are NOT rewritten by the
    # framework's root-relative pass -- they have to carry the prefix here.
    check cfg.baseUrl == "https://docs.codetracer.com/nightly"

  test "the base path is normalized, so a stray slash cannot break the site":
    # BOTH prefix owners normalize independently: `bookDocsConfig` is not the
    # only caller-facing entry point, and `generateRedirects` concatenates its
    # `basePath` straight onto URLs -- `"/nightly/"` there would emit a
    # double-slashed `/nightly//getting_started/python`, and a bare `"nightly"`
    # a relative `nightly/...` that resolves differently per page depth.
    let outDir = getTempDir() / "ct-book-normalized-redirects"
    for spelling in ["nightly", "/nightly", "/nightly/", " /nightly "]:
      check bookDocsConfig(spelling).basePath == "/nightly"
      check bookDocsConfig(spelling).baseUrl == "https://docs.codetracer.com/nightly"

      removeDir(outDir)
      createDir(outDir)
      discard generateRedirects(outDir, summaryPath(), spelling)
      check metaRefreshTarget(readFile(outDir / "getting_started" / "python.html")) ==
        "/nightly/getting_started/python"
      check readFile(outDir / "_redirects").contains(
        "/nightly/installation.html /nightly/getting_started/installation 301")
    removeDir(outDir)

  test "nothing else about the config changes with the channel":
    let released = bookDocsConfig()
    let nightly = bookDocsConfig("/nightly")
    check nightly.siteTitle == released.siteTitle
    check nightly.sectionOrder == released.sectionOrder
    check nightly.headerLinks == released.headerLinks
    # Root-relative config URLs are prefixed by the framework's pass at render
    # time, not here -- they must stay identical in both configs.
    check nightly.stylesheetHref == released.stylesheetHref
    check nightly.siteLogo == released.siteLogo

  test "legacy redirect stubs and _redirects carry the channel prefix":
    let outDir = getTempDir() / "ct-book-nightly-redirects"
    removeDir(outDir)
    createDir(outDir)
    defer: removeDir(outDir)

    let written = generateRedirects(outDir, summaryPath(), "/nightly")
    check written.legacy > 0
    # DS-1 added a second redirect family -- clean routes the book itself has
    # moved. It is prefixed by the same code path, and asserted here because a
    # family that silently emitted nothing under a channel prefix would leave
    # the nightly site 404ing on URLs the released site still serves.
    check written.moved > 0

    let stub = outDir / "getting_started" / "python.html"
    check fileExists(stub)
    # A stub that redirected to `/getting_started/python` would bounce the
    # reader out of the nightly site and onto the released one.
    check metaRefreshTarget(readFile(stub)) == "/nightly/getting_started/python"

    for moved in movedRoutes:
      let movedStub = outDir / moved.oldRoute[1 .. ^1] / "index.html"
      check fileExists(movedStub)
      check metaRefreshTarget(readFile(movedStub)) == "/nightly" & moved.newRoute

    let manifest = readFile(outDir / "_redirects")
    check manifest.contains(
      "/nightly/installation.html /nightly/getting_started/installation 301")
    for line in manifest.splitLines():
      if line.len > 0:
        check line.startsWith("/nightly/")

  test "the released channel's redirect artifacts are unprefixed":
    let outDir = getTempDir() / "ct-book-released-redirects"
    removeDir(outDir)
    createDir(outDir)
    defer: removeDir(outDir)

    discard generateRedirects(outDir, summaryPath())
    check metaRefreshTarget(readFile(outDir / "getting_started" / "python.html")) ==
      "/getting_started/python"
    check readFile(outDir / "_redirects").contains(
      "/installation.html /getting_started/installation 301")
