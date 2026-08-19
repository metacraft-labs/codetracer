## codetracer/docs/book-isonim -- this site's own `DocsConfig`.
##
## The CodeTracer mdBook ported onto isonim-docs, themed with the shared
## Metacraft docs theme (`theme_tokens.nim` + `assets/style.css`, copied
## verbatim from `isonim/docs/users` for M1 -- a shared theme package is a
## future cleanup). Branding here is CodeTracer's: the site title, the
## `docs.codetracer.com` canonical origin the sitemap/robots are built
## against, and the vendored CodeTracer logo + footer chrome.
##
## The site is published on TWO channels off the same content (see
## `ci/deploy/docs.sh`): the released book at `https://docs.codetracer.com/`
## (built from `stable`) and the nightly book at
## `https://docs.codetracer.com/nightly` (built from `dev`). The nightly build
## is the same site hosted under a URL PREFIX, so it must be built with
## `basePath = "/nightly"`: the framework then prefixes every root-relative URL
## it emits (page `href`/`src`, stylesheet `url(...)`, search-index route paths)
## with it, and `baseUrl` carries the same prefix so the canonical/sitemap URLs
## stay correct. Left at its default the config is byte-identical to before, so
## the root channel, the dev server and the SSR entry are unaffected.

import core/config
import core/base_path

const docsSiteOrigin* = "https://docs.codetracer.com"
  ## The canonical origin both channels are served from; the channel's
  ## `basePath` is appended to it to form `baseUrl`.

proc bookDocsConfig*(basePath = ""): DocsConfig =
  ## This book's `DocsConfig`. `basePath` is the URL prefix the build is hosted
  ## under (`""` = the root channel, `"/nightly"` = the nightly channel); it is
  ## normalized by the framework's `normalizeBasePath`, so `"nightly"`,
  ## `"/nightly"` and `"/nightly/"` are all accepted.
  let base = normalizeBasePath(basePath)
  DocsConfig(
    siteTitle: "CodeTracer",
    siteDescription: "Documentation for CodeTracer -- the time-travelling debugger.",
    defaultRoute: "/",
    stylesheetHref: "/assets/style.css",
    # Absolute canonical/og/sitemap URLs must carry the channel prefix too --
    # `basePath` only rewrites the root-relative URLs (see `core/base_path`).
    baseUrl: docsSiteOrigin & base,
    basePath: base,
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
    # unchanged.
    sidebarThemeToggle: true,
    # M3 (issue 2c): the "Need some help?" block WebFlow renders inside the
    # content-column `.footer` (the framework's `renderNeedHelpHtml` emits it as
    # a `.docs-need-help` section above `.docs-footer`; the M3 CSS constrains
    # both to the content column). Contact-support + FAQ links with the same
    # monochrome chrome icons WebFlow uses (copied into `static/img/`).
    needHelp: (
      heading: "Need some help?",
      links: @[
        (label: "Contact our support", href: "/support",
         icon: "/assets/img/icon__support.svg"),
        (label: "Frequently asked questions", href: "/faq",
         icon: "/assets/img/icon__faq.svg"),
      ],
    ),
  )
