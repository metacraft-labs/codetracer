## codetracer/docs/book-isonim -- M5 home-landing test (C-target).
##
## The book home (docs.codetracer.com, served from `content/index.md`) must be
## the WebFlow-parity landing (webflow-ref/index.html): a `:::hero` with a
## primary + secondary action button, a "Start here" grid of THREE category
## cards, and a "Popular articles" grid of SIX article cards -- authored on the
## framework's M2 content-component directives and rendered through this site's
## own `renderRoute` shell (the same path `just build` takes). This pins the
## structure + the exact real in-site links the cards resolve to, and guards
## that the old plain-prose "Introduction" home is gone while its content is
## still reachable at its own `/getting_started/introduction` route.

import std/[unittest, os, strutils]
import ../src/ssr

suite "book home renders the WebFlow-parity landing (hero + cards)":
  test "the home is the landing: hero + Start-here + Popular-articles grids":
    let (status, html) = renderRoute("/", "content")
    check status == 200

    # Hero: H1 title + subtitle + a primary and a secondary action button.
    check html.contains("class=\"docs-md-hero\"")
    check html.contains("class=\"docs-md-hero-title\"")
    check html.contains("Welcome to CodeTracer Docs")
    check html.contains("class=\"docs-md-hero-subtitle\"")
    check html.contains("class=\"docs-md-button\" href=\"/getting_started/installation\"")
    check html.contains("class=\"docs-md-button docs-md-button-secondary\"")

    # Two card grids (Start here + Popular articles) = 3 + 6 = 9 cards total.
    check html.count("class=\"docs-md-card-grid\"") == 2
    check html.count("class=\"docs-md-card\"") == 9

  test "the three category cards carry the WebFlow titles + real section links":
    let (_, html) = renderRoute("/", "content")
    for (title, href) in [("Getting Started", "/getting_started"),
                          ("Reference", "/reference/build_systems"),
                          ("Usage Guide", "/usage_guide")]:
      check html.contains("class=\"docs-md-card\" href=\"" & href & "\"")
      check html.contains("class=\"docs-md-card-title\">" & title & "</div>")

  test "the popular-articles grid links the six WebFlow articles to real pages":
    let (_, html) = renderRoute("/", "content")
    for (title, href) in [("Introduction", "/getting_started/introduction"),
                          ("Installation", "/getting_started/installation"),
                          ("Tracepoints", "/usage_guide/tracepoints"),
                          ("Graphical interface", "/usage_guide/gui"),
                          ("Command-line interface", "/usage_guide/cli"),
                          ("Build systems", "/reference/build_systems")]:
      check html.contains("class=\"docs-md-card\" href=\"" & href & "\"")
      check html.contains("class=\"docs-md-card-title\">" & title & "</div>")

  test "card/button hrefs are resolved routes, never raw .md content paths":
    let (_, html) = renderRoute("/", "content")
    check not html.contains(".md\"")
    check not html.contains("index.md")

  test "the Introduction prose is preserved at its own reachable route":
    let (status, html) = renderRoute("/getting_started/introduction", "content")
    check status == 200
    check html.contains("The benefits of time-travel")
    check html.contains("time-traveling debugger")
    # ...and the old plain-prose home is gone: the landing, not an article H1.
    let (_, homeHtml) = renderRoute("/", "content")
    check homeHtml.contains("class=\"docs-md-hero\"")
