# CodeTracer Book — working on docs.codetracer.com

This is the **CodeTracer documentation site** (published at
<https://docs.codetracer.com>). It is a consumer of the
[isonim-docs](../../../isonim-docs) static-site framework: the Markdown in
`content/` is rendered by the framework's SSG/SSR, themed by the shared
[CodeTracer docs design system](../../../codetracer-design-system/docs/codetracer-docs.tokens.json).

## Prerequisites

Every task runs inside **this book's own dev shell** (provides `nim`, `just`,
`node`). The book consumes the [isonim-docs](../../../isonim-docs) static-site
framework, so it reuses that framework's self-contained dev shell — which
declares **isonim as its dependency** and reuses isonim's toolchain (Nim 2.2.4,
node, `just`). Nobody has to `nix develop ../../../isonim`.

With **direnv** the shell activates automatically on `cd` (see `./.envrc`):

```bash
cd codetracer/docs/book-isonim
just dev-docs
```

Without direnv, enter the framework's dev shell once…

```bash
cd codetracer/docs/book-isonim
nix develop path:../../../isonim-docs      # the framework shell (isonim is its dep)
just dev-docs
```

…or prefix a single recipe with it:

```bash
nix develop path:../../../isonim-docs -c just dev-docs
```

All commands below assume you are in `codetracer/docs/book-isonim/` and in the
dev shell.

## Live preview (hot reload)

```bash
just dev-docs                 # http://127.0.0.1:8000  (loopback only)
just dev-docs-lan             # same, reachable on your private LAN at http://<host-ip>:8000
just open-docs                # open the running server in a browser
```

- `dev-docs` serves `content/` + the themed assets and **live-reloads every open
  tab** on any content edit.
- The **first launch compiles** the dev server and pre-compiles the client JS
  bundle (theme toggle, live search, sidebar collapse) — expect ~1 minute before
  it starts serving; after that, page loads and edits are instant.
- Default host is loopback (`127.0.0.1`). Pass `0.0.0.0` (or set `AH_DEV_HOST`)
  only on a trusted private network — it exposes the unauthenticated docs to the
  LAN/tailnet.

## Build, one-shot preview, tests

```bash
just build         # static build into build/ (what CI deploys via ci/deploy/docs.sh)
just serve-docs    # one-shot SSR preview (no live reload)
just test          # nav-order + dev-server tests
```

### If the build says `cannot open file: build_site`

Nim has no `--path` to the sibling framework. The book's `config.nims` — which
used to supply them, resolved from `currentSourcePath()` — is matched by the
repo-wide `*.nims` line in `codetracer/.gitignore`, so it is not in the
checkout. `ci/deploy/docs.sh` works around this by generating an absolute
`nim.cfg` before the build and deleting it after; do the same locally, once:

```bash
S="$(cd ../../.. && pwd)"      # the workspace root holding the sibling repos
cat > nim.cfg <<CFG
--path:"$S/isonim-docs/src"
--path:"$S/isonim/src"
--path:"$S/nim-everywhere/src"
--path:"$S/nim-faststreams"
--path:"$S/nim-stew"
--path:"$S/isonim/vendor/chronicles"
--path:"$S/isonim/vendor/serialization"
--path:"$S/isonim/vendor/json_serialization"
CFG
```

`nim.cfg` is git-ignored (RV-11 added the entry, after a run of this recipe left
an untracked file full of one machine's absolute paths sitting in the tree), and
CI writes and deletes its own copy regardless, so leaving it in place is
local-only and safe. It must stay untracked: a committed copy would collide with
the one `ci/deploy/docs.sh` generates.

## Where things live

| Path | What |
|------|------|
| `content/index.md` | The home page (WebFlow landing: hero, cards, popular articles, video, help footer) |
| `content/getting_started/`, `usage_guide/`, `reference/` | The three doc sections (order controlled by each page's `order:` front matter + `sectionOrder` in `src/docs_config.nim`) |
| `src/docs_config.nim` | Site config: title, logo, header/sidebar chrome (`headerLinks`, `sidebarLinks`, `sidebarThemeToggle`, `needHelp`), section order, redirects |
| `src/{build,dev,ssr,redirects,theme_tokens}.nim` | The consumer's build/serve entry points |
| `assets/style.css` | Book-owned CSS (theme + WebFlow-parity layout) |
| `static/` | Fonts + images |
| `tests/` | Home-landing, chrome, nav-order, redirect, publish-shape tests |

Add a page by dropping a Markdown file with front matter (`title`, `section`,
`order`, optional `slug`/`aliases`) into the right `content/<section>/` folder.

## Changing the look (design system)

The book is themed by the **shared** design system at
`codetracer-design-system/docs/codetracer-docs.tokens.json` — the same file the
other two docs sites use. To tweak it visually, launch the design-system editor
straight from here:

```bash
just design                   # http://127.0.0.1:8080  (the shared theme editor)
just design 8080 0.0.0.0      # reachable on the LAN
```

Keep `just dev-docs` running in another shell: a token you change and **Save** in
the editor persists to `codetracer-docs.tokens.json` and **hot-reloads the book
live, no rebuild**. You can also edit that JSON file by hand. Book-specific
layout/overrides live in `assets/style.css`. (The editor itself lives in
[`isonim-docs/site/design`](../../../isonim-docs/site/design/README.md).)

## Deployment

CI (`.github/workflows/codetracer.yml` → `ci/deploy/docs.sh`) builds this book
and publishes it to GitHub Pages, decoupled from the app build/test matrix.
There are **two channels**, chosen by the branch that was pushed:

| Branch | URL | Built with |
|---|---|---|
| `stable` | <https://docs.codetracer.com/> (plus the archived mdBook at `/old`) | `CT_DOCS_BASE_PATH` unset |
| `dev` | <https://docs.codetracer.com/nightly> | `CT_DOCS_BASE_PATH=/nightly` |

A push to `main` publishes nothing. Both channels commit to the same `gh-pages`
branch and each run replaces **only its own subtree**, so the other channel
survives untouched; the deploy is a fast-forward push, never a force-push.

Search engines are asked to skip the nightly channel: every released-channel
deploy appends `Disallow: /nightly/` to the **root** `robots.txt` (the only
`robots.txt` crawlers read), so the nightly pages do not compete with the
released ones for the same queries. To publish the nightly channel to search
engines instead, drop that one `printf` from `swap_owned_subtree` in
`ci/deploy/docs.sh`; the next released deploy regenerates `robots.txt` from the
build, so the line disappears on its own.

`CT_DOCS_BASE_PATH` is the URL prefix the build is hosted under: `src/build.nim`
passes it to `bookDocsConfig()`, and the framework then rewrites every
root-relative link, asset, stylesheet `url(...)`, search-index route and legacy
redirect stub to carry it. Build the nightly variant locally with:

```bash
CT_DOCS_BASE_PATH=/nightly just build
```

To rehearse a deploy without pushing anything, from the repo root:

```bash
DOCS_DEPLOY_DRY_RUN=1 DOCS_DEPLOY_BRANCH=dev ./ci/deploy/docs.sh   # or =stable
```

It prints the staged tree, including how many files it preserved from the
channel it does not own. If the book build fails the deploy **fails**: it never
substitutes older content under the published URLs, and because nothing is
pushed the previously published site keeps serving.
