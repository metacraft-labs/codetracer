# `get/` — source for https://get.codetracer.com

This directory is the source tree for CodeTracer's install/onboarding host,
`get.codetracer.com`, per
[product-install-domains.md](https://github.com/metacraft-labs/metacraft-dev-guidelines/blob/main/policies/product-install-domains.md).

It exposes three surfaces:

| URL | Served file | Purpose |
| --- | --- | --- |
| `https://get.codetracer.com/` | `index.html` | Onboarding / install landing page |
| `https://get.codetracer.com/sh` | `install-on-distributions.sh` (re-served) | `curl -fsSL https://get.codetracer.com/sh \| sh` |
| `https://get.codetracer.com/pwsh` | `install.ps1` or `pwsh.stub.ps1` | `irm https://get.codetracer.com/pwsh \| iex` |

## How it is built and served

`build-get.sh` assembles `dist/`:

- `index.html`, `_headers` — copied verbatim.
- `sh` — the repo's **canonical** `install-on-distributions.sh` with a provenance
  header injected after the shebang (single-sourced, never a divergent copy).
- `pwsh` — the repo's `install.ps1` if present, otherwise `pwsh.stub.ps1`
  (a "coming soon" stub that exits non-zero and points at the desktop app /
  releases / WSL). CodeTracer has no PowerShell installer yet, so the stub ships.

`_headers` forces `Content-Type: text/plain; charset=utf-8` + a short cache TTL on
`/sh` and `/pwsh`, so `curl … | less` shows the source and a fixed URL always
yields the current bootstrapper.

The artifact **store** remains GitHub Releases / `downloads.codetracer.com`;
`get.codetracer.com` is only the advertised UX.

## Deploy

`.github/workflows/deploy-get.yml` runs `build-get.sh` and
`wrangler pages deploy get/dist --project-name=get-codetracer --branch=master`
on push to `stable` (paths `get/**`, `install-on-distributions.sh`, `install.ps1`).
The `get-codetracer` Pages project's production branch is `master`, so the
`--branch master` deploy publishes production (served on the custom domain).

Requires repo secrets `CLOUDFLARE_API_TOKEN` (Pages:Edit) and
`CLOUDFLARE_ACCOUNT_ID` (`803741d99690718276ea30950f690c46`).

Build locally: `bash get/build-get.sh && ls get/dist`.
