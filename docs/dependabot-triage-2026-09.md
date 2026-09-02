# Dependabot alert triage — September 2026

Triage of the 183 open Dependabot alerts on the default branch (`stable`).
Investigation only: no dependencies were upgraded and no lockfile was changed.

**Headline: 27 of 183 alerts (15%) describe code that actually runs in a shipped
artifact's browser bundle. None of the three criticals is among them. The single
most consequential finding is not on the list at all — see "Blind spots".**

## How the counts were derived

- Alert data: `gh api /repos/metacraft-labs/codetracer/dependabot/alerts --paginate
  --state open` → 183 records; severity split 3 critical / 84 high / 70 moderate /
  26 low, matching the push banner exactly.
- npm reachability: a dependency-graph walk of `node-packages/yarn.lock` from only
  those root packages **verified** to be `require`d/imported by non-test product
  source, then intersected with the versions actually resolved in the lock.
- Browser bundle: verified by fetching the deployed assets from
  `https://ide.codetracer.com/` and fingerprinting the minified bytes, not by
  reasoning from `package.json`.

## Reachability split

| Bucket | Alerts | Severity |
|---|---:|---|
| **A. In the deployed browser bundle** (runs in visitors' tabs) | **27** | 6 high, 17 med, 4 low |
| **B. Desktop main process / server mode** (node side, not the tab) | **20** | 9 high, 9 med, 2 low |
| **C. Shipped on disk but never loaded** (dead bytes in `node_modules`) | **95** | 3 crit, 54 high, 29 med, 9 low |
| **D. Storybook, dev-only, never shipped** | **14** | 9 high, 5 med |
| **E. Rust** (see below) | **27** | 6 high, 10 med, 11 low |
| Total | **183** | 3 crit, 84 high, 70 med, 26 low |

These reconcile exactly to the reported 3 / 84 / 70 / 26.

Bucket C is large because **nothing prunes dev dependencies**. All three release
paths copy the full 806 MB dev+prod `node_modules` tree verbatim
(`appimage-scripts/setup_node_deps.sh:20`, `non-nix-build/setup_node_deps.sh:48`,
`repro.nim:1341`). A grep for `--production`, `yarn workspaces focus`, `npm prune`,
`electron-builder`, or `asar` across the release scripts returns zero hits. So these
95 packages ship to users as bytes on disk that no code path ever loads.

### A. What is genuinely in the browser bundle

The deployed page loads `/public/dist/frontend_bundle.js` (13,103,803 bytes) plus
~247 lazy chunks — a webpack build of `src/frontend/frontend_imports.js` produced
from `node-packages/yarn.lock`. This is in addition to the compiled Nim `/ui.js`
and the wasm modules named in the deployment descriptor; the descriptor does **not**
enumerate it, which is why the bundle is easy to overlook.

Only three alerted packages survive into those bytes, and only at these versions:

| Package | Bundled version | Alerts matching that version | Arrives via |
|---|---|---:|---|
| `dompurify` | 3.1.7 **and** 3.2.7 | 20 (16 med, 4 low) | `monaco-editor@0.54.0`; `@codingame/monaco-vscode-api@22.1.4` |
| `brace-expansion` | 2.0.2 | 4 (3 high, 1 med) | `minimatch@5.1.6` |
| `minimatch` | 5.1.6 | 3 (high) | `monaco-languageclient → vscode-languageclient@9.0.1` |

The other 12 `minimatch`/`brace-expansion` alerts fire on the 1.x/3.x/9.x/10.x
copies, which exist only in eslint and native-rebuild tooling and are not bundled.

**Zero critical and zero high-severity dompurify alerts.** The 20 dompurify issues
are sanitizer bypasses (XSS). Their exploitation path here is narrow but real for a
hosted multi-tenant IDE: DOMPurify sanitizes markdown in Monaco hover/completion
docs, which originate from the language server describing the source file the user
opened. Reaching it means getting a user to open a hostile project in the web IDE.

The `minimatch`/`brace-expansion` issues are all ReDoS / unbounded-expansion DoS,
triggered by attacker-controlled *glob patterns*. The patterns here come from LSP
file-watcher registrations, not from user content — plausibly unreachable, though we
did not prove it.

### B. Desktop main process (different threat model)

20 alerts in `express`(+`qs`, `body-parser`, `path-to-regexp`), `socket.io`
(+`engine.io`, `socket.io-parser`), `ws`, `js-yaml`, `lodash`. These run in the
Electron main process on the user's own machine — `src/frontend/index/server_config.nim:65,106`
binds a local express + socket.io server, and `src/lsp/bridge_reduced.nim:55` runs a
localhost WebSocket server for the language server. Mostly DoS-class issues against
a localhost listener, so an attacker needs local code execution first.

`js-yaml` deserves a note: it sits in `devDependencies` but is `require`d at runtime
by `src/frontend/lib/misc_lib.nim:41`, so Dependabot labels its 4 alerts
"development" and they would be wrongly deprioritized. It parses only the app's own
`.config.yaml` and a bundled `data.yaml`, so the quadratic-CPU issues are not
attacker-reachable.

## The three criticals, individually

**All three are in bucket C — present in the shipped tree, never loaded.**

**1. `tar` 7.5.2 — GHSA-23hp-3jrh-7fpw / CVE-2026-59873, fix 7.5.19**
Decompression/parse DoS via unlimited input. Declared as a *direct* dependency in
`node-packages/package.json`, which is why it reads as runtime scope. But
`require('tar')` appears **nowhere in the repository** outside `node_modules` — it is
an unused direct dependency. The other two copies (6.2.1, 7.4.3) sit under
`node-gyp`, `cacache`, and `electron-rebuild`, i.e. native-addon rebuild tooling that
runs at build time. Verified absent from the deployed browser bundle.
*Verified* it is not imported; *inferred* (safely) that the parse path is therefore
never entered.

**2. `shell-quote` 1.8.3 — GHSA-w7jw-789q-3m8p / CVE-2026-9277, fix 1.8.4**
`quote()` does not escape newlines in object `.op` values. Single path into the tree:
`npm-run-all`, a declared devDependency used to run package.json scripts. Its
`quote()` calls operate on script names written in our own `package.json`, not on
attacker input, and it never executes inside a shipped artifact.

**3. `basic-ftp` 5.0.5 — GHSA-5rq4-664w-9x2c / CVE-2026-27699, fix 5.2.0**
Path traversal in `downloadToDir()`. Path into the tree:
`wdio-electron-service → puppeteer-core → @puppeteer/browsers → proxy-agent →
pac-proxy-agent → get-uri → basic-ftp`. Pure browser-driver test tooling. Nothing in
CodeTracer speaks FTP, and `downloadToDir()` has no caller in the product.

## Ecosystem breakdown

| Ecosystem | Alerts | Notes |
|---|---:|---|
| npm | 156 (85%) | 142 in `node-packages/yarn.lock`, 14 in `storybook/package-lock.json` |
| Rust (Cargo) | 27 (15%) | across 4 lockfiles |
| Nix | 0 | **not a supported Dependabot ecosystem** — see Blind spots |
| GitHub Actions | 0 | `.github/dependabot.yml` configures version updates only |

The "183 with 84 high" shape is confirmed as npm transitive-dependency volume: all
183 alerts land in just **6 manifests**, and 37 distinct npm packages account for the
156 npm alerts. Of those 37, only **3** (`ws`, `js-yaml`, `vite`) are referenced by an
actual import statement in product source — the rest are purely transitive.

Encouragingly, `src/db-backend/Cargo.lock` — the main shipped Rust backend — and all
of `libs/*` have **zero** alerts.

### Rust detail (27)

- `test-programs/rs_stylus_vesting/Cargo.lock` (5) — **orphan lockfile**. The
  directory contains only a `Cargo.lock`; no `Cargo.toml`, no sources. Repo-wide
  grep for the name returns zero references. It was left behind when the program was
  moved. `git rm` closes 5 alerts at zero risk.
- `test-programs/stylus_fund_tracker/Cargo.lock` (19) — an Arbitrum Stylus sample
  contract used as a *recording target* for tests. Every consumer is `#[ignore]`d or
  skipped; no build, packaging, or CI step compiles it. All 19 vulnerable crates
  (`openssl`, `rustls-webpki`, `jsonwebtoken`, …) reach the lock only through
  `ethers 2.0.14`, a `[dev-dependencies]` entry, and cannot appear in the wasm
  `cdylib`. Note Dependabot marks all Cargo entries `runtime` — `Cargo.lock` carries
  no dev/normal distinction, so that field is meaningless for Rust.
- `src/tui/Cargo.lock` (2) — `src/tui` **ships nowhere**: absent from `nix/`,
  `flake.nix`, the justfile, and every install script; its Tupfile rule is commented
  out. It is only compiled by CI lint. Alerts are `bytes` (unreachable; `ratatui` never
  calls the affected API) and `lru` (unreachable; blocked behind a `ratatui` major).
- `src/backend-manager/Cargo.lock` (1) — this **is** shipped (`nix/packages/default.nix:544,983`).
  One `bytes` integer-overflow alert, transitive under `tokio`/`http`/`tungstenite`,
  none of which call the affected `BytesMut::reserve` path.

## Upgrade cost

| Fix | Cost | Verdict |
|---|---|---|
| `brace-expansion` 2.0.2 → 2.1.4 | Lockfile-only; `minimatch` declares `^2.0.1` | **Cheap — do it** |
| `minimatch` 5.1.6 → 5.1.8 | Lockfile-only; `vscode-languageclient` declares `^5.1.0` | **Cheap — do it** |
| `bytes` → 1.12.1 (×2 Rust locks) | `cargo update -p bytes --precise`; no manifest edit | **Cheap — do it** |
| Delete `rs_stylus_vesting/Cargo.lock` | `git rm` | **Free — do it** |
| `dompurify` 3.1.7/3.2.7 → 3.4.13 | **Breaking, multi-package** | **Schedule, don't rush** |
| `lru` (Rust) | Requires `ratatui` 0.29 → 0.30 major migration | **Don't** |

The dompurify entry is the important one, and it is a trap:
**bumping the `dompurify` entry in `yarn.lock` would not fix the shipped code.**
`monaco-editor@0.54.0` *vendors* DOMPurify 3.1.7 inline at
`esm/vs/base/browser/dompurify/dompurify.js` (verified via its license header) and
imports it by relative path. Only a `monaco-editor` upgrade replaces it — and the
second copy (3.2.7) needs `@codingame/monaco-vscode-api`, which `monaco-languageclient@10.2.0`
pins. So the real fix is a coordinated three-package upgrade of the editor core, with
regression risk concentrated in the renderer. Given the deploy pipeline is green
after a large landing, and given all 20 dompurify alerts are medium/low, this should
be a deliberately scheduled piece of work, not a reflex bump.

## Blind spots (worth more than most of the alert list)

1. **Electron is invisible to Dependabot.** There are zero `electron@` entries in
   `node-packages/yarn.lock` and no `electron` entry in `package.json`. The Nix path
   uses `pkgs.electron` (pinned through `flake.lock`), but
   `appimage-scripts/install_electron.sh:9` runs a bare, unpinned
   `npm install electron` at build time. The largest attack surface in the desktop
   product — Chromium — is covered by none of the 183 alerts and, on the AppImage
   path, floats to whatever npm serves on build day. Pinning it would both fix that
   and bring it into Dependabot's view.
2. **Nix inputs are unscanned.** `flake.nix` declares 32 inputs pinned by
   `flake.lock`, and the deploy lane now reads sibling revisions from it. Dependabot
   has no Nix ecosystem support, so none of this is covered by any alert.
3. **Alerts are computed on `stable`, but development happens on `dev`/`cloud`.**
   The npm lockfiles are byte-identical across `stable` and `dev`, so the 156 npm
   alerts apply equally; the two small Rust locks differ slightly.

## Recommendation

**Most of these warrant no action.** 136 of 183 alerts (74%) describe code that is
either never loaded (95), dev-only Storybook tooling (14), unshipped Rust test
fixtures and an orphan lockfile (24), or unreachable Rust APIs (3). Dismissing them
with `vulnerable_code_not_actually_used` — rather than upgrading — is the correct
disposition, and would take the queue from 183 to 47, of which 27 are the browser
bundle and 20 are localhost-facing desktop code.

Concretely, in priority order:

1. **Do now (free, no deploy risk):** delete the orphan `rs_stylus_vesting/Cargo.lock`;
   bump `bytes` in the two Rust locks; bump `brace-expansion` → 2.1.4 and
   `minimatch` → 5.1.8, which are pure lockfile moves inside existing semver ranges
   and clear 7 of the 27 browser-bundle alerts.
2. **Do now (paperwork):** bulk-dismiss buckets C, D, and the 24 Rust
   fixture/orphan alerts with reasons. This is where the 183 → 34 reduction comes from.
3. **Schedule deliberately:** the monaco-editor / monaco-vscode-api / monaco-languageclient
   upgrade that actually fixes the 20 dompurify alerts. Do not attempt this while the
   lane is green after a large landing; it is the one change here that could redden it.
4. **Fix the generators, not the symptoms.** Two structural changes would collapse
   most future alert volume: prune dev dependencies before packaging (also cuts a
   806 MB tree out of the shipped artifacts), and correct the `dependencies` /
   `devDependencies` split in `node-packages/package.json` — `@playwright/test`,
   `selenium-webdriver`, `browser-sync`, `node-gyp`, and `node-abi` are test/build
   tooling filed as runtime, while `js-yaml` is runtime filed as dev. Pinning
   `electron` into the lockfile belongs in the same pass.
