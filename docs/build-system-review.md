# Build System Review

## Overview
The CodeTracer build tooling spans multiple orchestrators (Just recipes, Tup build
rules, Nix derivations, bespoke shell scripts, and language-specific toolchains),
which produces overlapping binaries and bundles for desktop, extension, and
packaged distributions. The following sections catalogue every build target and
artifact, along with the script or configuration that defines it.

## Just Recipes (top-level automation)
| Target | Description | Command / Script | Location |
| --- | --- | --- | --- |
| `build` | Runs Tup in watch mode and starts webpack for continuous frontend builds. | `tup build-debug`, `tup monitor -a`, `node_modules/.bin/webpack --watch` | `justfile` L1-L27【F:justfile†L1-L27】 |
| `build-once` | Performs a one-off Tup build followed by a webpack bundle pass. | `tup build-debug`; `node_modules/.bin/webpack --progress`; repeats Tup to pick up new files. | `justfile` L29-L47【F:justfile†L29-L47】 |
| `build-docs` | Builds the mdBook documentation. | `mdbook build` | `justfile` L49-L52【F:justfile†L49-L52】 |
| `build-ui-js` | Compiles the extension UI bundle directly with Nim. | `nim ... js src/frontend/ui_js.nim` | `justfile` L54-L63【F:justfile†L54-L63】 |
| `build-deb-package` | Uses `nix bundle` to emit a `.deb`, optionally generating file size reports. | `nix bundle …#codetracer`; optional `dpkg -c`. | `justfile` L70-L91【F:justfile†L70-L91】 |
| `build-nix-app-image` | Produces an AppImage via nix-bundle. | `nix bundle --bundler github:ralismark/nix-appimage …` | `justfile` L93-L99【F:justfile†L93-L99】 |
| `build-macos-app` | Delegates to the non-Nix build script. | `bash non-nix-build/build.sh` | `justfile` L100-L101【F:justfile†L100-L101】 |
| `build-app-image` | Runs the bespoke AppImage script in-tree. | `./appimage-scripts/build_appimage.sh` | `justfile` L103-L104【F:justfile†L103-L104】 |
| `build-nix` | Invokes the main flake package build. | `nix build … '.?submodules=1#codetracer'` | `justfile` L199-L200【F:justfile†L199-L200】 |

## Tup-Orchestrated Artifacts
| Artifact | Description | Tup rule | Location |
| --- | --- | --- | --- |
| `index.js` & `index.js.map` | Electron frontend entry bundle generated from Nim. | `frontend/index.nim |> !nim_node_index` | `src/Tupfile` L3-L16【F:src/Tupfile†L3-L16】 |
| `subwindow.js` & `subwindow.js.map` | Secondary window bundle from Nim. | `frontend/subwindow.nim |> !nim_node_subwindow` | `src/Tupfile` L5-L16【F:src/Tupfile†L5-L16】 |
| `server_index.js` | Server-side rendering bundle for Electron. | `frontend/index.nim |> !nim_node_index_server` | `src/Tupfile` L6-L15【F:src/Tupfile†L6-L16】 |
| `ui.js` | Shared UI bundle copied into `public/ui.js`. | `frontend/ui_js.nim |> !nim_js` | `src/Tupfile` L7-L17【F:src/Tupfile†L7-L17】 |
| `helpers.js` | Copied helper module (placeholder for TS build). | `helpers.js |> !tup_preserve` | `src/Tupfile` L11-L17【F:src/Tupfile†L11-L17】 |
| Runtime links | Binary/tool shims copied from `src/links`. | `links/* |> !tup_preserve` rules | `src/Tupfile` L22-L35【F:src/Tupfile†L22-L35】 |
| Nim CLI binaries | `codetracer_depending_on_env_vars_in_tup`, `ct`, `db-backend-record`. | Nim compilation rules via `!codetracer` / `!nim_c`. | `src/ct/Tupfile` L3-L7; `src/Tuprules.tup` L120-L140【F:src/ct/Tupfile†L3-L7】【F:src/Tuprules.tup†L120-L140】 |
| Rust backends | `backend-manager`, `db-backend`, `small-lang`. | Rust cargo rules. | `src/backend-manager/Tupfile` L3-L3; `src/db-backend/Tupfile` L3-L6; `src/small-lang/Tupfile` L3-L3【F:src/backend-manager/Tupfile†L1-L3】【F:src/db-backend/Tupfile†L1-L6】【F:src/small-lang/Tupfile†L1-L3】 |
| Test harness | `tester` binary compiled from Nim. | `tester.nim |> !nim_tester` | `src/tester/Tupfile` L1-L3【F:src/tester/Tupfile†L1-L3】 |
| CSS assets | Stylus → CSS builds for Electron/extension themes. | Stylus rules. | `src/frontend/styles/Tupfile` L1-L13【F:src/frontend/styles/Tupfile†L1-L13】 |
| Static public assets | Preserved from `src/public`, including vendor JS/CSS. | `: foreach … |> !tup_preserve` | `src/public/Tupfile` L1-L13【F:src/public/Tupfile†L1-L13】 |

### Toolchain rules
Nim, TypeScript, Stylus, GCC, and Rust toolchains are parameterised in
`src/Tuprules.tup`, defining compiler flags and cargo invocations reused across
Tupfiles.【F:src/Tuprules.tup†L1-L173】

## Nix Derivations
| Package | Purpose | Key build steps | Location |
| --- | --- | --- | --- |
| `indexJavascript` | Builds `index.js`/`server_index.js` using Nim inside Nix. | Runs `nim … js src/frontend/index.nim`. | `nix/packages/default.nix` L130-L158【F:nix/packages/default.nix†L130-L158】 |
| `subwindowJavascript` | Compiles the subwindow bundle. | Nim invocation for `subwindow.nim`. | `nix/packages/default.nix` L160-L186【F:nix/packages/default.nix†L160-L186】 |
| `uiJavascript` | Produces `ui.js`. | Nim invocation for `ui_js.nim`. | `nix/packages/default.nix` L188-L209【F:nix/packages/default.nix†L188-L209】 |
| `db-backend` | Rust build of the database backend with adjusted test skips. | `cargo build` via `buildRustPackage`. | `nix/packages/default.nix` L212-L234【F:nix/packages/default.nix†L212-L234】 |
| `backend-manager` | Rust build of backend manager. | `buildRustPackage` referencing Cargo.lock. | `nix/packages/default.nix` L236-L245【F:nix/packages/default.nix†L236-L245】 |
| `console` | Compiles the Nim REPL binary. | Nim compile of `src/repl/repl.nim`. | `nix/packages/default.nix` L247-L270【F:nix/packages/default.nix†L247-L270】 |
| `ruby-recorder-pure` | Bundles Ruby recorder executable. | Copies recorder script to `$out/bin`. | `nix/packages/default.nix` L284-L299【F:nix/packages/default.nix†L284-L299】 |
| `resources-derivation` | Copies static resources into a derivation. | `cp -Lr ./resources/*`. | `nix/packages/default.nix` L301-L317【F:nix/packages/default.nix†L301-L317】 |
| `runtimeDeps` | Symlink join aggregating runtime dependencies and staging JS/html assets. | Symlinks node modules, copies HTML/Nim binaries. | `nix/packages/default.nix` L319-L374【F:nix/packages/default.nix†L319-L374】 |
| `node-modules-derivation` | Builds Yarn dependencies inside Nix. | Overrides install phase to expose `node_modules`. | `nix/packages/default.nix` L384-L420【F:nix/packages/default.nix†L384-L420】 |
| `codetracer-electron` | Reproduces webpack/stylus pipeline and stages Electron resources. | Runs TypeScript, Stylus, Webpack, copies outputs. | `nix/packages/default.nix` L422-L488【F:nix/packages/default.nix†L422-L488】 |
| `codetracer` (default) | Full application derivation bundling binaries, JS, config, and wrappers. | Compiles Nim binaries, stages assets, wraps `ct`. | `nix/packages/default.nix` L547-L686【F:nix/packages/default.nix†L547-L686】 |

## Language- and Script-Specific Builds
### Webpack
- `frontend_bundle.js` is generated with entry point `src/frontend/frontend_imports.js`
and output directory `src/public/dist` using `webpack.config.js`.【F:webpack.config.js†L4-L25】

### Extension & Distribution Scripts
| Script | Outputs | Key steps | Location |
| --- | --- | --- | --- |
| `build_for_extension.sh` | Extension UI JS bundle, middleware JS, debug db-backend binary. | Runs two Nim JS builds, `just build-once`, and `cargo build` for db-backend. | `build_for_extension.sh` L1-L27【F:build_for_extension.sh†L1-L27】 |
| `non-nix-build/build.sh` | Platform-specific desktop bundle (`dist` directory, macOS app/dmg). | Dispatches to `build_in_simple_env.sh`, optional macOS packaging pipeline. | `non-nix-build/build.sh` L1-L34【F:non-nix-build/build.sh†L1-L34】 |
| `non-nix-build/build_in_simple_env.sh` | Populates `$DIST_DIR` with binaries, assets, and wrappers. | Installs node deps, builds Nim assets, compiles Rust backends, copies runtime assets, wraps `ct`. | `non-nix-build/build_in_simple_env.sh` L1-L74【F:non-nix-build/build_in_simple_env.sh†L1-L74】 |
| `appimage-scripts/build_appimage.sh` | Produces `CodeTracer.AppImage` after assembling an AppDir. | Installs runtime deps, builds Nim/Rust binaries, copies assets, patches binaries, runs `appimagetool`. | `appimage-scripts/build_appimage.sh` L1-L305【F:appimage-scripts/build_appimage.sh†L1-L305】 |

## Artifact Inventory
- **Desktop executables**: `ct`, `codetracer_depending_on_env_vars_in_tup`, `db-backend`,
  `db-backend-record`, `backend-manager`, `small-lang`, `tester`, `console` (Nim), each
  generated via Tup or Nix derivations.【F:src/ct/Tupfile†L3-L7】【F:src/backend-manager/Tupfile†L1-L3】【F:src/db-backend/Tupfile†L1-L6】【F:src/small-lang/Tupfile†L1-L3】【F:src/tester/Tupfile†L1-L3】【F:nix/packages/default.nix†L247-L686】
- **JavaScript bundles**: `index.js`, `server_index.js`, `subwindow.js`, `ui.js`,
  `frontend_bundle.js`, plus extension-specific outputs. Generated through Tup, Webpack,
  and direct Nim commands.【F:src/Tupfile†L3-L17】【F:webpack.config.js†L4-L25】【F:build_for_extension.sh†L6-L20】
- **CSS assets**: Stylus-derived themes and loader styles emitted under
  `src/frontend/styles/*.css`.【F:src/frontend/styles/Tupfile†L1-L13】
- **Packages & bundles**: `.deb` package, nix-bundled AppImage, AppDir-based
  `CodeTracer.AppImage`, macOS `.app` and `.dmg`, and Nix flake outputs (default `codetracer`).【F:justfile†L70-L104】【F:non-nix-build/build.sh†L1-L34】【F:appimage-scripts/build_appimage.sh†L1-L305】【F:nix/packages/default.nix†L547-L686】
- **Supporting assets**: Resources copied via Tup, Nix, and packaging scripts
  (HTML, configs, helper scripts, node modules, Ruby recorder, electron assets).【F:src/Tupfile†L14-L40】【F:nix/packages/default.nix†L319-L686】【F:non-nix-build/build_in_simple_env.sh†L42-L74】【F:appimage-scripts/build_appimage.sh†L41-L246】

## Recommendations
1. **Consolidate the Nim/JS build logic** – Today `tup`, `just build-ui-js`, Nix
   derivations, the extension script, the non-Nix pipeline, and the AppImage script
   all invoke Nim with slightly different flag sets. Centralising these invocations
   (for example by wrapping them in a shared script or leveraging Tup targets in the
   downstream scripts) would reduce drift and ensure consistent outputs.【F:justfile†L54-L63】【F:src/Tupfile†L3-L17】【F:nix/packages/default.nix†L130-L209】【F:build_for_extension.sh†L6-L20】【F:non-nix-build/build_in_simple_env.sh†L18-L27】【F:appimage-scripts/build_appimage.sh†L101-L205】
2. **Rationalise packaging flows** – Multiple paths produce installers (`nix bundle`
   `.deb`, Nix AppImage, bespoke AppImage script, macOS `.app`/`.dmg`). Evaluating
   whether a single packaging strategy (e.g., Nix-based) can serve all platforms would
   simplify maintenance and prevent duplicated asset-staging logic seen across scripts
   and derivations.【F:justfile†L70-L104】【F:non-nix-build/build_in_simple_env.sh†L42-L74】【F:appimage-scripts/build_appimage.sh†L141-L305】【F:nix/packages/default.nix†L319-L686】
3. **Factor shared asset staging** – Copy/link steps for HTML, `node_modules`, configs,
   and helper binaries are replicated in Tup, Nix derivations, non-Nix builds, and the
   AppImage script. Extracting a shared manifest or using Tup outputs as the single
   source could cut down on manual syncing and packaging errors.【F:src/Tupfile†L14-L40】【F:nix/packages/default.nix†L319-L686】【F:non-nix-build/build_in_simple_env.sh†L42-L74】【F:appimage-scripts/build_appimage.sh†L171-L246】
4. **Adopt a unified orchestrator** – `just build`, `build-once`, direct scripts, and Nix
   commands overlap. Establishing one authoritative entry point (e.g., Just recipes that
   internally call Nix or Tup) and deprecating redundant scripts will make the build
   story clearer for contributors and automation.【F:justfile†L1-L200】【F:build_for_extension.sh†L6-L27】【F:non-nix-build/build.sh†L1-L34】【F:appimage-scripts/build_appimage.sh†L1-L305】
