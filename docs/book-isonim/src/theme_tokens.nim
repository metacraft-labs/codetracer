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

const geistFontFace = """@font-face {
  font-family: "Geist";
  font-style: normal;
  font-weight: 100 900;
  font-display: swap;
  src: url(/assets/fonts/Geist-Variable.woff2) format("woff2");
}"""

proc metacraftDocsTokenLayer*(): DocsTokenLayer =
  ## The full Metacraft/CodeTracer docs token layer: every `--docs-*`
  ## variable the framework consumes, plus the handful of extra vars the
  ## CodeTracer rules need (radii vocabulary 10px/6px/999px, the distinct
  ## inline-code tint, the white search field, the sidebar width). Ordered
  ## for a deterministic, diff-stable emit.
  result.fontFaces = geistFontFace

  # --- fonts -------------------------------------------------------------
  # (1) Geist is a docs-specific literal; the brand mandates Space Grotesk.
  result.add "--docs-font-sans", literal(
    "\"Geist\", ui-sans-serif, system-ui, -apple-system, \"Segoe UI\", Roboto, sans-serif")
  # (2) code font: the WebFlow mockup left this at the browser default; keep
  # a real monospace stack (a strict improvement, no brand conflict).
  result.add "--docs-font-mono", literal(
    "ui-monospace, SFMono-Regular, \"SF Mono\", Menlo, Consolas, \"Liberation Mono\", monospace")

  # --- structural scale (identical light/dark) ---------------------------
  result.add "--docs-space-1", literal("0.25rem")
  result.add "--docs-space-2", literal("0.5rem")
  result.add "--docs-space-3", literal("0.75rem")
  result.add "--docs-space-4", literal("1rem")
  result.add "--docs-space-5", literal("1.5rem")
  result.add "--docs-space-6", literal("2rem")
  result.add "--docs-space-8", literal("3rem")

  # radii vocabulary: 4 / 8 / 10 / 6 / 999px.
  result.add "--docs-radius-sm", literal("4px")
  result.add "--docs-radius-md", literal("8px")
  result.add "--docs-radius-lg", literal("10px")     # search field + dropdown
  result.add "--docs-radius-code", literal("6px")    # <pre> blocks
  result.add "--docs-radius-pill", literal("999px")  # pill controls

  result.add "--docs-font-size-sm", literal("0.85rem")   # sidebar/toc items
  result.add "--docs-font-size-base", literal("1rem")
  result.add "--docs-line-height", literal("1.5")        # --lh-body 1.5em
  result.add "--docs-max-content-width", literal("50rem")
  result.add "--docs-sidebar-width", literal("20rem")

  # --- surfaces & text (WebFlow shade ramp, light / dark) ----------------
  # (4) warm off-white canvas -- docs-specific literal, no brand token.
  result.add "--docs-bg", literal("#f0eeea", "#161719")
  # warm hover surface -- WebFlow `#E7E5E1` / dark shade-30.
  result.add "--docs-bg-raised", literal("#E7E5E1", "#31343a")
  # body text -- shade-90 `#111` light / shade-80 `#dfe0e4` dark.
  result.add "--docs-fg", literal("#111111", "#dfe0e4")
  # muted text -- shade-60 `#7e7e7e` / `#a8aab1`.
  result.add "--docs-fg-muted", literal("#7e7e7e", "#a8aab1")
  # borders/dividers -- `#e5e7eb` / dark shade-40 `#3c4046`.
  result.add "--docs-border", literal("#e5e7eb", "#3c4046")

  # (3) blue accent/link -- docs-specific literal (`--blue` / dark `--blue`);
  # the brand mandates indigo.
  result.add "--docs-accent", literal("#4168cc", "#88a4f2")
  result.add "--docs-accent-fg", literal("#ffffff", "#161719")
  result.add "--docs-link", literal("#4168cc", "#88a4f2")

  # --- code --------------------------------------------------------------
  result.add "--docs-code-bg", literal("#f6f8fa", "#1d1f22")        # <pre>
  result.add "--docs-code-inline-bg", literal("#f1f5f9", "#272a2e") # inline
  result.add "--docs-code-fg", literal("#282A2D", "#eeeef1")

  # --- focus ring: EXACT match to brand blue.500 -> bind by token --------
  result.add "--docs-focus-ring", token("colors.blue.500", "colors.blue.500")

  # search dropdown / overlay elevation.
  result.add "--docs-shadow", literal(
    "0 14px 40px rgba(0, 0, 0, 0.13)", "0 14px 40px rgba(0, 0, 0, 0.55)")

  # white search field surface (pops against the warm canvas) / dark shade-10.
  result.add "--docs-input-bg", literal("#ffffff", "#202124")

  # --- syntax highlight (no WebFlow spec; keep the framework palette) -----
  result.add "--docs-tok-keyword", literal("#a626a4", "#d2a8ff")
  result.add "--docs-tok-string", literal("#22863a", "#7ee787")
  result.add "--docs-tok-comment", literal("#6a737d", "#8b949e")
  result.add "--docs-tok-number", literal("#005cc5", "#79c0ff")

  # --- admonitions: severity BORDERS are the brand .500 primitives -------
  # (exact match -> bind by token); the tinted backgrounds are docs literals.
  result.add "--docs-admonition-note-border", token("colors.blue.500", "colors.blue.500")
  result.add "--docs-admonition-note-bg", literal("#eff6ff", "rgba(99, 160, 255, 0.12)")
  result.add "--docs-admonition-tip-border", token("colors.green.500", "colors.green.500")
  result.add "--docs-admonition-tip-bg", literal("#f0fdf4", "rgba(74, 222, 128, 0.12)")
  result.add "--docs-admonition-warning-border", token("colors.amber.500", "colors.amber.500")
  result.add "--docs-admonition-warning-bg", literal("#fffbeb", "rgba(251, 191, 36, 0.12)")
  result.add "--docs-admonition-danger-border", token("colors.red.500", "colors.red.500")
  result.add "--docs-admonition-danger-bg", literal("#fef2f2", "rgba(248, 113, 113, 0.12)")
  # metacraft-theme M3 (Gap D): the framework's new `important`/`caution`
  # severities now render distinctly, so the book's 5-severity WebFlow palette
  # ports 1:1 -- `important` = violet.500 (matches brand primitive), `caution`
  # = red.500 (WebFlow's caution IS red; it no longer has to borrow `danger`).
  result.add "--docs-admonition-important-border", token("colors.violet.500", "colors.violet.500")
  result.add "--docs-admonition-important-bg", literal("#f5f3ff", "rgba(139, 92, 246, 0.12)")
  result.add "--docs-admonition-caution-border", token("colors.red.500", "colors.red.500")
  result.add "--docs-admonition-caution-bg", literal("#fef2f2", "rgba(248, 113, 113, 0.12)")

  # --- API reference method colours (no WebFlow spec; framework palette) --
  result.add "--docs-api-get", literal("#1a8754", "#56d364")
  result.add "--docs-api-post", literal("#2f6feb", "#6ea8ff")
  result.add "--docs-api-put", literal("#b8860b", "#e3b341")
  result.add "--docs-api-patch", literal("#8250df", "#d2a8ff")
  result.add "--docs-api-delete", literal("#cc3333", "#ff7b72")
  result.add "--docs-api-other", literal("#5b6270", "#9aa2b1")
