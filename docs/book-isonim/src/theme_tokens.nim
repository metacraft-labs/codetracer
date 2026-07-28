## isonim/docs/users -- the Metacraft / CodeTracer docs token layer
## (metacraft-theme M2 deliverable 1).
##
## This is the DATA half of the theme: it binds every `--docs-*` CSS
## custom property the isonim-docs framework components consume to its
## WebFlow-faithful light + dark value, using the M1 `DocsTokenLayer`
## machinery (`core/docs_tokens`). The RULES half -- the structural CSS
## that USES these variables -- lives in `assets/style.css`.
##
## Per the divergence decision (see `DESIGN-DIVERGENCES.md`), the WebFlow
## docs design LEADS: the Geist font stack, the warm `#f0eeea` canvas, the
## blue accent and the `#E7E5E1` warm hover are docs-specific LITERALS
## (`bkLiteral`) with no brand-token equivalent. Where a docs value already
## MATCHES a design-system primitive -- the focus ring and the admonition
## severity border colours are exactly the `brand.json` blue/green/amber/red
## `.500` primitives -- it is bound by TOKEN (`bkToken`), resolved against
## `codetracer-design-system/{brand,alias,mapped}/*.json`, so a future
## alignment pass is mechanical.
##
## The emitted CSS (via `emitTokensCss`) is prepended onto `assets/style.css`
## by the consumer's `src/build.nim` through `buildSite(docsTokensCss = ...)`.

import std/os
import core/[tokens, docs_tokens]

export docs_tokens.emitTokensCss

const usersRoot = currentSourcePath().parentDir().parentDir()
  ## `.../isonim/docs/users` (this module lives in `users/src/`).
const designSystemRoot = usersRoot / "../../.." / "codetracer-design-system"
  ## `users/../../..` -> the workspace root; the design system is a sibling.

proc designSystemTokens*(): TokenSet =
  ## Loads the canonical Metacraft brand/alias/mapped DTCG token set so the
  ## layer's `bkToken` bindings resolve to concrete primitives.
  loadTokens(
    designSystemRoot / "brand" / "brand.json",
    designSystemRoot / "alias" / "alias.json",
    designSystemRoot / "mapped" / "mapped.json")

const docsDesignSystemJson = staticRead(
  designSystemRoot / "docs" / "codetracer-docs.tokens.json")
  ## The shared CodeTracer docs design system, embedded at compile time -- the
  ## SINGLE source of truth for the --docs-* tokens, consumed identically by
  ## every Metacraft docs site and the design-system editor. Edit the tokens
  ## THERE (or via the editor), not here. See that repo's DESIGN-DIVERGENCES.md.

proc metacraftDocsTokenLayer*(): DocsTokenLayer =
  ## The CodeTracer docs token layer, loaded from the shared design system
  ## (codetracer-design-system/docs/codetracer-docs.tokens.json).
  loadDocsTokenLayer(docsDesignSystemJson)
