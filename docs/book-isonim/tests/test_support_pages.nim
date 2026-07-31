## codetracer/docs/book-isonim -- FAQ / Support / Sign-In pages test (C-target).
##
## The book header links Sign In / Support / FAQ to /sign-in /support /faq;
## those pages are now real, WebFlow-parity content pages. This pins, through
## the same `renderRoute` shell `just build` takes:
##   * /faq: the standard docs layout with the 5-item `:::faq` accordion, the
##     "Popular articles" compact card grid, and a "Still have questions?" block;
##   * /support: the standard docs layout with the `:::form` contact form
##     (email / name / category-select / message-textarea / submit) + a FAQ link;
##   * /sign-in: the MINIMAL auth layout (logo + centered card, no sidebar /
##     header nav / footer) with the `:::form` auth form (email / password /
##     remember checkbox / submit) + a "Sign up" link;
##   * the three utility pages are HIDDEN from the docs sidebar (matching
##     WebFlow) yet fully routed.

import std/[unittest, strutils]
import ../src/ssr

suite "book FAQ / Support / Sign-In pages (WebFlow parity)":
  test "/faq renders the standard layout + 5-item accordion + popular cards":
    let (status, html) = renderRoute("/faq", "content")
    check status == 200
    # Standard docs chrome (header nav + sidebar + footer) present.
    check html.contains("id=\"docs-region-nav\"")
    check html.contains("class=\"docs-header-nav\"")
    check html.contains("class=\"docs-footer\"")
    # The 5 WebFlow FAQ questions, as a native <details>/<summary> accordion.
    check html.contains("class=\"docs-md-faq\"")
    check html.count("<details class=\"docs-md-faq-item\">") == 5
    check html.contains(">What is CodeTracer?</summary>")
    check html.contains("time-traveling debugger")
    check html.contains("<code>ct record")
    # The "Popular articles" compact card grid + the closing block.
    check html.contains("class=\"docs-md-card-grid docs-md-card-grid--compact\">")
    check html.contains("Still have questions?")
    # NOT the minimal layout.
    check not html.contains("docs-frame--minimal")

  test "/support renders the contact form with all WebFlow fields":
    let (status, html) = renderRoute("/support", "content")
    check status == 200
    check html.contains("class=\"docs-md-form\" action=\"/support\" method=\"get\">")
    # Email + Name text/email inputs.
    check html.contains("type=\"email\" name=\"Email\"")
    check html.contains("type=\"text\" name=\"Name\"")
    # Category <select> with the WebFlow options.
    check html.contains("<select class=\"docs-md-form-input docs-md-form-select\" name=\"Category\"")
    check html.contains("<option value=\"Payments\">Payments</option>")
    check html.contains("<option value=\"Account\">Account</option>")
    check html.contains("<option value=\"Software\">Software</option>")
    # Message <textarea>.
    check html.contains("<textarea class=\"docs-md-form-input docs-md-form-textarea\" name=\"Message\"")
    # Submit button + the FAQ cross-link.
    check html.contains(">Send message</button>")
    check html.contains("href=\"/faq\"")
    # Standard layout, not minimal.
    check html.contains("id=\"docs-region-nav\"")
    check not html.contains("docs-frame--minimal")

  test "/sign-in renders the MINIMAL auth layout (no sidebar/header-nav/footer)":
    let (status, html) = renderRoute("/sign-in", "content")
    check status == 200
    # Minimal frame + centered card + logo-only top bar.
    check html.contains("docs-frame--minimal")
    check html.contains("class=\"docs-minimal-nav\"")
    check html.contains("class=\"docs-minimal-card\"")
    check html.contains("class=\"docs-main docs-main--minimal\"")
    check html.contains("<img class=\"docs-logo\"")
    # The card owns the page <h1> and the auth form.
    check html.contains("class=\"docs-md-title\">Sign In</h1>")
    check html.contains("type=\"password\" name=\"Password\"")
    check html.contains("type=\"checkbox\" class=\"docs-md-form-check-input\" name=\"remember\"")
    check html.contains(">Sign in</button>")
    check html.contains("href=\"/sign-up\"")   # the "Sign up" link
    # NONE of the full docs chrome.
    check not html.contains("id=\"docs-region-nav\"")
    check not html.contains("id=\"docs-region-header\"")
    check not html.contains("class=\"docs-footer\"")
    check not html.contains("docs-header-nav")

  test "the utility pages are HIDDEN from the docs sidebar (routed, not listed)":
    # `/sign-in` is linked ONLY from the header nav button (never the need-help
    # block), so exactly one occurrence proves it is absent from the sidebar /
    # prev-next of an ordinary article page.
    let (status, html) = renderRoute("/getting_started/introduction", "content")
    check status == 200
    check html.count("href=\"/sign-in\"") == 1
