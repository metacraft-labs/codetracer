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

    # Hero: H1 title + a primary and a secondary action button.
    check html.contains("class=\"docs-md-hero\"")
    check html.contains("class=\"docs-md-hero-title\"")
    check html.contains("Welcome to CodeTracer Docs")
    check html.contains("class=\"docs-md-button\" href=\"/getting_started/installation\"")
    check html.contains("class=\"docs-md-button docs-md-button-secondary\"")

    # M3 (issue 2a): the hero carries NO subtitle -- WebFlow has no extra
    # paragraph between the hero buttons and the Overview section.
    check not html.contains("class=\"docs-md-hero-subtitle\"")

    # Two card grids: "Start here" is the default (category-card) grid; "Popular
    # articles" is the M6 compact (WebFlow popular-article-card) variant.
    check html.contains("class=\"docs-md-card-grid\">")           # Start here (default)
    check html.contains("class=\"docs-md-card-grid docs-md-card-grid--compact\">") # Popular (compact)
    # 3 default category cards + 6 compact popular-article cards = 9 total.
    check html.count("class=\"docs-md-card\" href=") == 3
    check html.count("class=\"docs-md-card docs-md-card--compact\" href=") == 6

    # M6: the landing gets the WIDER content column and DROPS the prev/next
    # pager (the WebFlow home has neither a narrow article column nor a pager).
    check html.contains("class=\"docs-main docs-main--wide\"")
    check not html.contains("docs-nav-adjacent")

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
      # M6: popular-article cards carry the compact variant modifier.
      check html.contains("class=\"docs-md-card docs-md-card--compact\" href=\"" & href & "\"")
      check html.contains("class=\"docs-md-card-title\">" & title & "</div>")

  test "M6: a normal article page keeps the narrow column + prev/next pager (landing-only widening)":
    let (status, html) = renderRoute("/getting_started/introduction", "content")
    check status == 200
    # No hero on an article -> the `<main>` is the plain narrow column...
    check html.contains("class=\"docs-main\" tabindex=\"-1\">")
    check not html.contains("docs-main--wide")
    # ...and the framework's prev/next pager is present, unlike the landing.
    check html.contains("docs-nav-adjacent")

  test "card/button hrefs are resolved routes, never raw .md content paths":
    let (_, html) = renderRoute("/", "content")
    check not html.contains(".md\"")
    check not html.contains("index.md")

  test "M3 (issue 2b): the home embeds the overview YouTube video after Overview":
    let (_, html) = renderRoute("/", "content")
    # The framework `:::video` block renders a privacy-friendly nocookie embed.
    check html.contains("class=\"docs-md-video\"")
    check html.contains("class=\"docs-md-video-frame\" src=\"" &
      "https://www.youtube-nocookie.com/embed/xZsJ55JVqmU\"")
    check html.contains("title=\"CodeTracer - Noir Release Demo\"")
    # Order (within the content body -- the TOC rail repeats these labels): the
    # Overview section precedes the video, which precedes the Start-here cards.
    let bodyAt = html.find("class=\"docs-md-body\"")
    check bodyAt >= 0
    let overviewAt = html.find("id=\"overview\"", bodyAt)
    let videoAt = html.find("docs-md-video", bodyAt)
    let startHereAt = html.find("id=\"start-here\"", bodyAt)
    check overviewAt >= 0 and videoAt >= 0 and startHereAt >= 0
    check overviewAt < videoAt
    check videoAt < startHereAt

  test "M3 (issue 2c): the 'Need some help?' footer block renders with support + FAQ":
    let (_, html) = renderRoute("/", "content")
    check html.contains("class=\"docs-need-help\"")
    check html.contains("class=\"docs-need-help-heading\">Need some help?</div>")
    check html.contains("class=\"docs-need-help-link\" href=\"/support\"")
    check html.contains("class=\"docs-need-help-link\" href=\"/faq\"")
    check html.contains("<span>Contact our support</span>")
    check html.contains("<span>Frequently asked questions</span>")
    check html.contains("/assets/img/icon__support.svg")
    check html.contains("/assets/img/icon__faq.svg")

  test "M3 (issue 7): the built-by attribution is in the content footer, after need-help":
    let (_, html) = renderRoute("/", "content")
    check html.contains("Built by <a href=\"https://github.com/metacraft-labs\">metacraft-labs</a>")
    # The need-help block precedes the `.docs-footer` built-by line (both live in
    # the content column via the M3 CSS; DOM order pins the sequence).
    let needHelpAt = html.find("docs-need-help")
    let footerAt = html.find("class=\"docs-footer\"")
    check needHelpAt >= 0 and footerAt >= 0
    check needHelpAt < footerAt

  test "the Introduction prose is preserved at its own reachable route":
    let (status, html) = renderRoute("/getting_started/introduction", "content")
    check status == 200
    check html.contains("The benefits of time-travel")
    check html.contains("time-traveling debugger")
    # ...and the old plain-prose home is gone: the landing, not an article H1.
    let (_, homeHtml) = renderRoute("/", "content")
    check homeHtml.contains("class=\"docs-md-hero\"")
