## codetracer/docs/book-isonim -- M2 header/sidebar chrome test (C-target).
##
## M2 brings the WebFlow shell chrome to parity by populating `bookDocsConfig()`'s
## framework chrome hooks: the header nav buttons (Sign In / Support / FAQ), the
## sidebar social links (Github / Twitter), and moving the theme toggle into the
## sidebar-bottom pill. The hooks already exist in the framework shell; this pins
## that the CONSUMER config drives the real SSR render (`renderRoute`, the same
## path `just build` takes), so the buttons/social/pill are actually emitted and
## the header no longer carries the standalone toggle glyph.

import std/[unittest, strutils]
import ../src/ssr

proc headerRegion(html: string): string =
  ## The `<header id="docs-region-header" ...>...</header>` slice, so a test can
  ## assert on the header in isolation (e.g. that the theme toggle has LEFT it).
  let startMarker = "id=\"docs-region-header\""
  let s = html.find(startMarker)
  if s < 0: return ""
  let e = html.find("</header>", s)
  if e < 0: return ""
  html[s ..< e]

suite "book M2 chrome: header nav buttons + sidebar social + theme pill":
  test "the header carries the Sign In / Support / FAQ nav buttons (issue 5)":
    let (status, html) = renderRoute("/", "content")
    check status == 200
    check html.contains("class=\"docs-header-nav\"")
    check html.contains("class=\"docs-header-nav-btn\" href=\"/sign-in\">Sign In</a>")
    check html.contains("class=\"docs-header-nav-btn\" href=\"/support\">Support</a>")
    check html.contains("class=\"docs-header-nav-btn\" href=\"/faq\">FAQ</a>")

  test "the sidebar carries the Github + Twitter social links with icons (issue 6)":
    let (_, html) = renderRoute("/", "content")
    check html.contains("class=\"docs-sidebar-extras\"")
    check html.contains(
      "class=\"docs-sidebar-link\" href=\"https://github.com/metacraft-labs/codetracer\"")
    check html.contains("class=\"docs-sidebar-link\" href=\"https://x.com/CodeTracerIDE\"")
    check html.contains("/assets/img/icon__github.svg")
    check html.contains("/assets/img/icon__twitter.svg")
    check html.contains("<span>Github</span>")
    check html.contains("<span>Twitter</span>")

  test "the theme toggle moves into the sidebar pill; the header no longer emits it (issue 4)":
    let (_, html) = renderRoute("/", "content")
    # The pill wrapper wraps the single `#docs-theme-toggle` button in the sidebar.
    check html.contains("class=\"docs-theme-switch-wrap\"")
    check html.contains("id=\"docs-theme-toggle\"")
    # There is exactly ONE toggle button on the page (the JS binds by id).
    check html.count("id=\"docs-theme-toggle\"") == 1
    # ...and it is NOT in the header any more -- the header dropped its glyph.
    let header = headerRegion(html)
    check header.len > 0
    check not header.contains("docs-theme-toggle")
    # The one toggle lives inside the sidebar extras' pill wrapper.
    check html.contains("docs-theme-switch-wrap")

  test "an ordinary article page also gets the same header + sidebar chrome":
    let (status, html) = renderRoute("/getting_started/introduction", "content")
    check status == 200
    check html.contains("class=\"docs-header-nav-btn\" href=\"/faq\">FAQ</a>")
    check html.contains("class=\"docs-theme-switch-wrap\"")
    let header = headerRegion(html)
    check not header.contains("docs-theme-toggle")
