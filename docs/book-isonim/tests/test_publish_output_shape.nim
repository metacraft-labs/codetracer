## codetracer/docs/book-isonim -- publish-output-shape test (C-target).
##
## Asserts that the built `public/` tree -- the EXACT bytes CI's
## `ci/deploy/docs.sh` copies onto the gh-pages branch that serves
## docs.codetracer.com -- has the shape GitHub Pages must serve:
##
##   * the real home page `index.html` (a rendered page, NOT a redirect stub),
##   * all 49 rendered section/utility pages (one `<route>/index.html` per
##     content page), incl. a representative spread across every top-level
##     section and the WebFlow-parity faq/support/sign-in utility pages,
##   * the hashed, cache-busted theme stylesheet under `assets/` plus the
##     `assets/{fonts,img}` the CSS and content reference,
##   * the hashed `search-index.*.json` client search payload,
##   * `sitemap.xml` and `robots.txt`,
##   * the M2 legacy-URL redirect artifacts: the meta-refresh `*.html` stubs
##     AND the `_redirects` manifest.
##
## No skips: if `public/` is missing (build not run), every assertion fails
## loudly. Run `just build` (or `nix develop ../../../isonim -c just build`)
## first; the CI verification pipeline builds before running this test.

import std/[unittest, os, strutils]
import core/content

proc consumerDir(): string =
  currentSourcePath().parentDir().parentDir()

proc publicDir(): string = consumerDir() / "public"
proc contentDir(): string = consumerDir() / "content"

proc globOne(dir, pattern: string): seq[string] =
  ## Files directly in `dir` matching a `*`-glob on their basename.
  result = @[]
  for path in walkFiles(dir / pattern):
    result.add path

proc isMetaRefresh(html: string): bool =
  html.contains("http-equiv=\"refresh\"")

suite "the gh-pages publish output has the expected shape":
  let pub = publicDir()

  test "public/ exists (the build ran)":
    check dirExists(pub)

  test "the real home page is a rendered page, not a redirect stub":
    let home = pub / "index.html"
    check fileExists(home)
    let html = readFile(home)
    check not isMetaRefresh(html)
    # A real rendered page carries the site chrome, not just a redirect shim.
    check html.contains("<html")
    check html.toLowerAscii.contains("codetracer")

  test "all 61 rendered pages are present as clean-route index.html files":
    # The SSG emits every content page at `<route>/index.html`; the count must
    # match the ported content set exactly (46 M1 pages + the M5
    # `getting_started/introduction` article split out of the old root
    # `index.md` when it became the WebFlow-parity landing + the three
    # WebFlow-parity utility pages faq/support/sign-in = 50, + the nine
    # live-request-tracking pages + the `sign-up` page = 60, + the
    # `usage_guide/deep_review` DeepReview workflow page = 61).
    var pageCount = 0
    for path in walkDirRec(pub, yieldFilter = {pcFile}):
      if path.lastPathPart == "index.html":
        inc pageCount
    check pageCount == 61
    # Cross-check against the content source of truth.
    check loadContentEntries(contentDir()).len == 61

  test "a representative page from every top-level section is present":
    let pages = [
      "getting_started/index.html",       # section index (overview.md)
      "getting_started/python/index.html", # non-alphabetical order page
      "usage_guide/index.html",
      "usage_guide/cli/index.html",
      "reference/ct_cli/index.html",
      "reference/build_systems/index.html",  # M1 reorg folded building_and_packaging/ into reference/
      "reference/contributing/index.html",   # CONTRIBUTING.md remap (folded into reference/)
      "getting_started/installation/index.html",  # root installation moved under getting_started/
    ]
    for rel in pages:
      check fileExists(pub / rel)

  test "the WebFlow-parity utility pages (faq/support/sign-in) ship as clean routes":
    for rel in ["faq/index.html", "support/index.html", "sign-in/index.html"]:
      check fileExists(pub / rel)
      check not isMetaRefresh(readFile(pub / rel))

  test "the hashed theme stylesheet + its asset dirs ship under assets/":
    let styles = globOne(pub / "assets", "style.*.css")
    check styles.len == 1
    # Cache-busting hash present (not the bare `style.css`).
    check styles[0].lastPathPart.len > "style..css".len
    check dirExists(pub / "assets" / "fonts")
    check dirExists(pub / "assets" / "img")
    # Non-empty stylesheet.
    check getFileSize(styles[0]) > 0

  test "the hashed client search index ships":
    let idx = globOne(pub, "search-index.*.json")
    check idx.len == 1
    check getFileSize(idx[0]) > 0
    # Valid-looking JSON payload.
    let body = readFile(idx[0]).strip
    check (body.startsWith("[") or body.startsWith("{"))

  test "sitemap.xml and robots.txt ship":
    check fileExists(pub / "sitemap.xml")
    check fileExists(pub / "robots.txt")
    check readFile(pub / "sitemap.xml").contains("docs.codetracer.com")

  test "the M2 legacy-URL redirect artifacts ship":
    # The _redirects manifest ...
    let manifest = pub / "_redirects"
    check fileExists(manifest)
    check readFile(manifest).contains(" 301")
    # ... and a representative spread of meta-refresh *.html stubs, each a
    # redirect shim (NOT a rendered page).
    let stubs = [
      "installation.html",
      "getting_started/python.html",
      "usage_guide/cli.html",
      "reference/ct_cli.html",
    ]
    for rel in stubs:
      let stub = pub / rel
      check fileExists(stub)
      check isMetaRefresh(readFile(stub))
    # And there are many of them (M2 emits 45).
    var stubCount = 0
    for path in walkDirRec(pub, yieldFilter = {pcFile}):
      if path.endsWith(".html") and path.lastPathPart != "index.html" and
         isMetaRefresh(readFile(path)):
        inc stubCount
    check stubCount == 45
