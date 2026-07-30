## codetracer/docs/book-isonim -- this site's own `DocsConfig`.
##
## The CodeTracer mdBook ported onto isonim-docs, themed with the shared
## Metacraft docs theme (`theme_tokens.nim` + `assets/style.css`, copied
## verbatim from `isonim/docs/users` for M1 -- a shared theme package is a
## future cleanup). Branding here is CodeTracer's: the site title, the
## `docs.codetracer.com` canonical origin the sitemap/robots are built
## against, and the vendored CodeTracer logo + footer chrome.

import core/config

proc bookDocsConfig*(): DocsConfig =
  DocsConfig(
    siteTitle: "CodeTracer",
    siteDescription: "Documentation for CodeTracer -- the time-travelling debugger.",
    defaultRoute: "/",
    stylesheetHref: "/assets/style.css",
    baseUrl: "https://docs.codetracer.com",
    # Match the WebFlow docs organization: the sidebar's three top-level
    # sections in this order (the framework otherwise sorts sections
    # alphabetically). Content was folded to these three -- building_and_packaging
    # + misc into reference, installation into getting_started.
    sectionOrder: @["getting_started", "usage_guide", "reference"],
    # The CodeTracer look is delivered by the token layer + `assets/style.css`
    # (prepended via `buildSite(docsTokensCss = ...)`), not by pointing
    # `stylesheetHref` elsewhere, so the SSG hash/purge/non-dangling
    # guarantee is untouched.
    siteLogo: "/assets/img/logo-black-horizontal.svg",
    logoHref: "/",
    footerHtml: "Built by <a href=\"https://github.com/metacraft-labs\">metacraft-labs</a> — 2026",
    # M1 (client-JS bundle): ship + inject the compiled client app on every
    # page so the theme toggle, live search and sidebar collapse are live. The
    # bundle is `src/main.nim` (compiled by `build.nim`/the dev server); the
    # asset-hash pass rewrites this placeholder to the cache-busted filename.
    appScriptHref: defaultAppScriptUrl,
    # M1 (robust no-JS nav): render all three sidebar sections default-expanded
    # (WebFlow shows all its blocks open) so the article links are visible and
    # navigable on a plain page load even before/without the client JS.
    expandAllNavSections: true,
    # M2 (WebFlow header chrome, issue 5): the three right-aligned header nav
    # buttons (WebFlow `.ct-nav-links` -> `.ct-nav-btn`). Targets mirror the
    # WebFlow export (sign-in.html/support.html/faq.html) as root-relative
    # routes; the pages themselves are a later deliverable -- M2 only needs the
    # BUTTONS present at WebFlow sizing.
    headerLinks: @[
      (label: "Sign In", href: "/sign-in"),
      (label: "Support", href: "/support"),
      (label: "FAQ", href: "/faq"),
    ],
    # M2 (WebFlow sidebar social, issue 6): the Github/Twitter links WebFlow
    # renders as `.link-with-icon` at the bottom of the left sidebar. Icons are
    # the monochrome chrome SVGs copied into `static/img/` (served from
    # `/assets/img/`); they invert in dark mode via the chrome-inversion rule.
    sidebarLinks: @[
      (label: "Github", href: "https://github.com/metacraft-labs/codetracer",
       icon: "/assets/img/icon__github.svg"),
      (label: "Twitter", href: "https://x.com/CodeTracerIDE",
       icon: "/assets/img/icon__twitter.svg"),
    ],
    # M2 (issue 4 placement): move the theme toggle out of the header and into
    # the sidebar-bottom pill (WebFlow `.theme-switch`). The header stops
    # emitting its standalone toggle glyph; there is still exactly one toggle
    # (same `#docs-theme-toggle` id), so the M1 client JS click wiring is
    # unchanged. (`needHelp` + the home video are M3.)
    sidebarThemeToggle: true,
  )
