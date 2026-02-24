# Windows DIY Bootstrap Maintenance

This directory contains the non-Nix Windows bootstrap workflow
and version pins.

Default install root:

- `%LOCALAPPDATA%/codetracer/windows-diy`
  (PowerShell/bootstrap default)
- POSIX equivalent in Git Bash via
  `source non-nix-build/windows/env.sh`
- PowerShell equivalent via
  `. .\non-nix-build\windows\env.ps1`
- Override with `WINDOWS_DIY_INSTALL_ROOT` or bootstrap
  `-InstallRoot`

`env.sh` sourcing behavior:

- When sourced from Git Bash, `env.sh` restores your previous
  shell options on return and does not leave `set -e` enabled
  in the caller shell.
- Missing Node tool deps are auto-provisioned by default
  (`WINDOWS_DIY_SETUP_NODE_DEPS=1`) via `yarn install` in
  `node-packages`, so `stylus.cmd`/`webpack.cmd` are available
  for Tup/Just workflows.
- Set `WINDOWS_DIY_SETUP_NODE_DEPS=0` to disable this
  auto-install and manage Node deps manually.

`env.ps1` dot-sourcing behavior (PowerShell):

- Dot-source with `. .\non-nix-build\windows\env.ps1` so
  environment variables remain in your current shell.
- Mirrors the same bootstrap + PATH wiring goals as `env.sh`
  for Windows-native shells.
- Supports the same key toggles (`WINDOWS_DIY_SYNC`,
  `WINDOWS_DIY_SETUP_NODE_DEPS`,
  `WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER`).
- Applies shared runtime setup from
  `non-nix-build/windows/setup-codetracer-runtime-env.ps1`:
  - creates `ct_paths.json` when missing (required by
    `ct.exe` wrapper)
  - sets `NIX_CODETRACER_EXE_DIR`, `LINKS_PATH_DIR`,
    `CODETRACER_REPO_ROOT_PATH`
  - sets `CODETRACER_E2E_CT_PATH` to
    `src/build-debug/bin/ct.exe` when available
  - prepends `src/build-debug/bin` to PATH for direct `ct`
    invocation
- Resolves `.NET` from `WINDOWS_DIY_DOTNET_ROOT` (if set),
  then
  `$WINDOWS_DIY_INSTALL_ROOT/dotnet/<DOTNET_SDK_VERSION>`,
  then `%ProgramFiles%/dotnet`, exports `DOTNET_ROOT`, and
  validates that the pinned `DOTNET_SDK_VERSION` is installed.
- Resolves Microsoft TTD + WinDbg packages through
  `Get-AppxPackage` and exports:
  - `WINDOWS_DIY_TTD_EXE`, `WINDOWS_DIY_TTD_DIR`,
    `WINDOWS_DIY_TTD_VERSION`,
    `WINDOWS_DIY_TTD_REPLAY_DLL`,
    `WINDOWS_DIY_TTD_REPLAY_CPU_DLL`
  - `WINDOWS_DIY_WINDBG_DIR`,
    `WINDOWS_DIY_WINDBG_VERSION`
  - debugger engine paths for machine APIs:
    `WINDOWS_DIY_CDB_EXE`, `WINDOWS_DIY_DBGENG_DLL`,
    `WINDOWS_DIY_DBGMODEL_DLL`,
    `WINDOWS_DIY_DBGHELP_DLL`
  - note: env scripts prefer
    `C:\Windows\System32\dbgeng.dll`/`dbgmodel.dll`/`dbghelp.dll`
    when available to avoid AppX ACL `LoadLibrary` failures
    from `WindowsApps`.
  - minimum version pins `TTD_MIN_VERSION`,
    `WINDBG_MIN_VERSION`
- By default, validates TTD/WinDbg availability and pinned
  minimum versions (`WINDOWS_DIY_ENSURE_TTD=1`). Set
  `WINDOWS_DIY_ENSURE_TTD=0` to bypass this validation.
- Prepends Nim prebuilt `bin` (when available) before
  source-built Nim `bin` so Windows runtime dependencies like
  `libcrypto-1_1-x64.dll` are discoverable by `ct.exe` and
  UI tests.

`env.sh` (Git Bash) now applies the same runtime setup via
`non-nix-build/windows/setup-codetracer-runtime-env.sh`.

## tree-sitter-nim parser generation

After `source non-nix-build/windows/env.sh` (Git Bash), the
workflow runs
`non-nix-build/ensure_tree_sitter_nim_parser.sh`, which
regenerates `libs/tree-sitter-nim/src/parser.c` when it is
missing or older than `libs/tree-sitter-nim/grammar.js`.

The script prefers the local CLI at
`libs/tree-sitter-nim/node_modules/.bin/tree-sitter` and uses
lockfile `npm ci` when `package-lock.json` is present. If
local CLI resolution fails, it falls back to an isolated
cached install of `tree-sitter-cli@<pinned-version>` under
`.tools/tree-sitter-cli-cache/` so parser generation can
proceed without building this grammar package's native addon
dependencies.
Set `TREE_SITTER_NIM_FALLBACK_CLI_PACKAGE_SPEC` to override
the fallback npm package spec if needed, and set
`WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER=0` to skip this
parser check.

## ct-remote source selection (local repo vs pinned download)

`bootstrap-windows-diy.ps1` supports two ct-remote bootstrap
inputs:

1. Preferred local source build from sibling repo
   `../codetracer-ci` when available.
2. Existing pinned download fallback from
   `downloads.codetracer.com`.

Behavior is controlled by environment variables:

- `CT_REMOTE_WINDOWS_SOURCE_MODE` (default: `auto`)
  - `auto`: on Windows x64, use local source when available
    and otherwise fall back to pinned download; on Windows
    arm64, require local source and do not fall back to
    pinned x64 download.
  - `local`: require the local source path; fail if
    unavailable.
  - `download`: force pinned-download flow (Windows x64
    only).
- `CT_REMOTE_WINDOWS_SOURCE_REPO` (default:
  `../../../codetracer-ci` relative to
  `non-nix-build/windows/bootstrap-windows-diy.ps1`)
  - Override this path when the C# source repo is in a
    different location.
- `CT_REMOTE_WINDOWS_PUBLISH_SCRIPT` -- default:

  ```text
  <CT_REMOTE_WINDOWS_SOURCE_REPO>/non-nix-build/windows/publish-desktop-client.ps1
  ```

  - Override this path to use a different publish helper
    script. Relative paths are resolved from
    `CT_REMOTE_WINDOWS_SOURCE_REPO`.
  - When this script is available, bootstrap uses it for
    local-source publish and does not require host-global
    `dotnet` on PATH.
  - When this script is missing, bootstrap falls back to
    direct `dotnet publish` behavior.
- `CT_REMOTE_WINDOWS_SOURCE_RID` (default: by architecture)
  - `win-x64` on Windows x64.
  - `win-arm64` on Windows arm64.
  - Override is preserved; supported values are `win-x64`
    and `win-arm64`.

Practical local-source publish path discovered from
`../codetracer-ci`:

- Project:
  `apps/DesktopClient/DesktopClient.App/DesktopClient.App.csproj`
- Preferred publish command used by bootstrap
  (defaults to `PublishAot=false` in that script):

  ```text
  pwsh -File non-nix-build/windows/publish-desktop-client.ps1 -Rid <CT_REMOTE_WINDOWS_SOURCE_RID> -Configuration Release
  ```

- Fallback publish command (only when helper script is
  missing):
  `dotnet publish <project> -c Release -r <CT_REMOTE_WINDOWS_SOURCE_RID>`
- Output consumed by bootstrap:
  `runtime/publish/DesktopClient.App/DesktopClient.App(.exe)`
- Upstream CI workflow
  `../codetracer-ci/.github/workflows/publish-desktop-client.yml`
  currently publishes `win-x64` and has `win-arm64` commented
  as not supported yet, so `win-arm64` local publish should
  be treated as environment-dependent. Use
  `CT_REMOTE_WINDOWS_SOURCE_RID=win-x64` as an explicit
  fallback RID if needed.

## Nim source selection and cache layout

`bootstrap-windows-diy.ps1` supports source and prebuilt Nim
install paths:

- `NIM_WINDOWS_SOURCE_MODE` (default: `auto`)
  - `auto`: try source build first; on Windows x64, source
    bootstrap failure falls back to pinned prebuilt ZIP; on
    non-x64, source failure is terminal and does not attempt
    prebuilt fallback.
  - `source`: require source build; fail if source bootstrap
    fails.
  - `prebuilt`: force pinned prebuilt ZIP flow (Windows x64
    only).
- `NIM_WINDOWS_SOURCE_REPO` (default from pin:
  `NIM_SOURCE_REPO`)
- `NIM_WINDOWS_SOURCE_REF` (default from pin:
  `NIM_SOURCE_REF`)
- `NIM_WINDOWS_SOURCE_REVISION` (optional exact commit hash
  override; skips ref resolution)
- `NIM_WINDOWS_CSOURCES_REPO` (default from pin:
  `NIM_CSOURCES_REPO`)
- `NIM_WINDOWS_CSOURCES_REF` (default from pin:
  `NIM_CSOURCES_REF`)
- `NIM_WINDOWS_CSOURCES_REVISION` (optional exact commit
  hash override; skips ref resolution)
- `NIM_WINDOWS_SOURCE_CC` (default: `auto`)
  - `auto`: prefer `gcc` when available, otherwise use MSVC
    (`vcc`/`cl.exe`).
  - `gcc`: require `gcc` for source bootstrap.
  - `vcc`: require MSVC toolchain for source bootstrap.
- `NIM_WINDOWS_SOURCE_BOOTSTRAP_GCC_FROM_TUP_MSYS2`
  (default: `1`)
  - When `gcc` is not on PATH, bootstrap may provision/reuse
    pinned Tup MSYS2 toolchain to supply `gcc`.

Deterministic cache paths under install root
(`$WINDOWS_DIY_INSTALL_ROOT`, default
`%LOCALAPPDATA%/codetracer/windows-diy`):

- Source build cache root:
  `nim/<NIM_VERSION>/cache/source/<cache-key>/`
- Cached source install dir:
  `nim/<NIM_VERSION>/cache/source/<cache-key>/nim-<NIM_VERSION>`
- Prebuilt install dir:
  `nim/<NIM_VERSION>/prebuilt/nim-<NIM_VERSION>`
- Selected install pointer:
  `nim/<NIM_VERSION>/nim.install.relative-path`
- Selected install metadata:
  `nim/<NIM_VERSION>/nim.install.meta`
- Source cache metadata:
  `nim/<NIM_VERSION>/cache/source/<cache-key>/nim.source.meta`

`cache-key` is SHA256 over normalized build inputs:

- Nim version + architecture
- Nim repo/ref/resolved revision
- csources repo/ref/resolved revision
- compiler/toolchain hint snapshot (`CC`, `cl`, `gcc`
  detection/version probes)

Reuse policy:

- If `nim.source.meta` matches current normalized inputs and
  `nim --version` matches `NIM_VERSION`, bootstrap reuses the
  cached source install and skips rebuild.
- Otherwise bootstrap rebuilds source into a new
  deterministic cache key directory.
- In `auto` mode on Windows x64, source failure falls back
  to prebuilt ZIP flow.
- In `auto` mode on non-x64 architectures, source failure is
  returned directly and prebuilt fallback is skipped because
  only `nim-<version>_x64.zip` is pinned.

## Cap'n Proto source selection and cache layout

`bootstrap-windows-diy.ps1` supports source and prebuilt
Cap'n Proto install paths:

- `CAPNP_WINDOWS_SOURCE_MODE` (default: `auto`)
  - `auto`: on Windows x64, use pinned prebuilt ZIP by
    default; on non-x64, build from source.
  - `source`: require source build.
  - `prebuilt`: force pinned prebuilt ZIP flow (Windows x64
    only).
- `CAPNP_WINDOWS_SOURCE_REPO` (default from pin:
  `CAPNP_SOURCE_REPO`)
- `CAPNP_WINDOWS_SOURCE_REF` (default from pin:
  `CAPNP_SOURCE_REF`)
- `CAPNP_WINDOWS_SOURCE_REVISION` (optional exact commit
  hash override; skips ref resolution)
- `CAPNP_WINDOWS_CMAKE_GENERATOR` (optional explicit
  generator override; defaults to `Ninja` when available,
  else `Visual Studio 17 2022`)

Deterministic cache paths under install root
(`$WINDOWS_DIY_INSTALL_ROOT`, default
`%LOCALAPPDATA%/codetracer/windows-diy`):

- Source build cache root:
  `capnp/<CAPNP_VERSION>/cache/source/<cache-key>/`
- Cached source install dir:
  `capnp/<CAPNP_VERSION>/cache/source/<cache-key>/install`
- Prebuilt install dir:
  `capnp/<CAPNP_VERSION>/prebuilt/capnproto-tools-win32-<CAPNP_VERSION>`
- Selected install pointer:
  `capnp/<CAPNP_VERSION>/capnp.install.relative-path`
- Selected install metadata:
  `capnp/<CAPNP_VERSION>/capnp.install.meta`
- Source cache metadata:
  `capnp/<CAPNP_VERSION>/cache/source/<cache-key>/capnp.source.meta`

`cache-key` is SHA256 over normalized build inputs:

- Cap'n Proto version + architecture
- Cap'n Proto repo/ref/resolved revision
- CMake generator + CMake version hint
- compiler/toolchain hint snapshot (`CC`, `cl`, `gcc`
  detection/version probes)

Reuse policy:

- If `capnp.source.meta` matches current normalized inputs
  and `capnp --version` matches `CAPNP_VERSION`, bootstrap
  reuses the cached source install and skips rebuild.
- Otherwise bootstrap rebuilds source into a new
  deterministic cache key directory.
- In `auto` mode on Windows x64, bootstrap uses pinned
  prebuilt by default.
- In `auto` mode on non-x64 architectures, bootstrap selects
  source mode directly.

## Tup source selection and cache layout

`bootstrap-windows-diy.ps1` supports pinned prebuilt Tup
bootstrap by default, with source mode still available:

- `TUP_WINDOWS_SOURCE_MODE` (default: `prebuilt`)
  - `auto`: prefer pinned prebuilt ZIP first, then fallback
    to source build if prebuilt bootstrap fails.
  - `source`: require source build.
  - `prebuilt`: require prebuilt install (uses pinned
    `TUP_PREBUILT_*` defaults unless
    `TUP_WINDOWS_PREBUILT_*` overrides are set).
- `TUP_WINDOWS_SOURCE_REPO` (default from pin:
  `TUP_SOURCE_REPO`)
- `TUP_WINDOWS_SOURCE_REF` (default from pin:
  `TUP_SOURCE_REF`)
- `TUP_WINDOWS_SOURCE_REVISION` (optional exact commit hash
  override; skips ref resolution)
- `TUP_WINDOWS_SOURCE_BUILD_COMMAND` (default from pin:
  `TUP_SOURCE_BUILD_COMMAND`, currently
  `TUP_MINGW=1 TUP_MINGW32=0 ./bootstrap.sh`)
  - When this remains at the pinned default, bootstrap now
    generates and runs `codetracer-bootstrap-windows.sh`
    inside the Tup source checkout (MinGW-only compile path
    that avoids upstream `bootstrap.sh` Unix defaults and
    does not require `pkg-config fuse`).
  - Any non-default value is treated as an explicit override
    and executed as-is in the MSYS2 shell.
- `TUP_WINDOWS_MSYS2_BASE_VERSION` (default from pin:
  `TUP_MSYS2_BASE_VERSION`)
- `TUP_WINDOWS_MSYS2_PACKAGES` (default from pin:
  `TUP_MSYS2_PACKAGES`)
- `TUP_WINDOWS_SELF_HOST_UPDATE` (default: unset/off)
  - Off by default: bootstrap treats manually compiled
    `build/tup.exe` as the final artifact and skips
    `tup init`/`tup upd`.
  - Set to `1`/`true`/`yes`/`on` only for debugging
    self-host updates inside the staged source checkout.
- Pinned prebuilt defaults (toolchain pins):
  - `TUP_PREBUILT_URL` (currently
    `https://gittup.org/tup/win32/tup-latest.zip`)
  - `TUP_PREBUILT_SHA256` (currently
    `fc55fcff297050582c21454af54372f69057e3c2008dbc093c84eeee317e285e`)
  - `TUP_PREBUILT_VERSION` (currently `latest`)
- Optional prebuilt override controls:
  - `TUP_WINDOWS_PREBUILT_URL`
  - `TUP_WINDOWS_PREBUILT_SHA256`
  - `TUP_WINDOWS_PREBUILT_VERSION`

Deterministic cache paths under install root
(`$WINDOWS_DIY_INSTALL_ROOT`, default
`%LOCALAPPDATA%/codetracer/windows-diy`):

- Source build cache root:
  `tup/cache/source/<cache-key>/`
- Cached source install dir:
  `tup/cache/source/<cache-key>/install`
- Optional explicit prebuilt install dir:
  `tup/prebuilt/<sha256>/install`
- Selected install pointer:
  `tup/tup.install.relative-path`
- Selected install metadata: `tup/tup.install.meta`
- Source cache metadata:
  `tup/cache/source/<cache-key>/tup.source.meta`

`cache-key` is SHA256 over normalized build inputs:

- Tup source repo/ref/resolved revision
- requested source build command
- effective source build command identity (for default path
  this is the codetracer-owned generated script version)

Host prerequisites for source mode:

- `git` must be present on PATH.
- Bootstrap now provisions an MSYS2 base
  (`msys2-base-x86_64-<version>.tar.xz`) under
  `$WINDOWS_DIY_INSTALL_ROOT/tup/msys2/<version>/msys64`
  and installs the pinned package set
  (`mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf make`)
  before running the Tup source build command.
- Tup source bootstrap exports `TUP_MINGW=1` and
  `TUP_MINGW32=0`, and prepends MinGW bin directories
  (`mingw64/bin`, `mingw32/bin`) in the MSYS2 shell PATH so
  Tup builds target MinGW compilers by default.
- In default mode, bootstrap emits
  `codetracer-bootstrap-windows.sh` and compiles Tup directly
  with the MinGW toolchain (including `src/compat/win32` and
  `src/tup/server/windepfile.c`), then installs the compiled
  `build/tup.exe` as the bootstrap artifact without running
  self-host `tup init`/`tup upd`.

Reuse policy:

- If `tup.source.meta` matches current normalized inputs and
  `tup --version` succeeds, bootstrap reuses the cached
  source install and skips rebuild.
- `prebuilt` and `auto` modes use pinned upstream ZIP
  URL/SHA by default for reproducibility. Use `source` mode
  when you need to force source bootstrap.

## Version Bump Process (`toolchain-versions.env`)

1. Pick target versions and verify they exist upstream:
   - `RUSTUP_VERSION`:
     <https://github.com/rust-lang/rustup/releases>
   - `RUST_TOOLCHAIN_VERSION`:
     <https://blog.rust-lang.org/releases/>
   - `NODE_VERSION`:
     <https://nodejs.org/dist/index.json>
   - `UV_VERSION`:
     <https://github.com/astral-sh/uv/releases>
   - `DOTNET_SDK_VERSION`:
     <https://dotnet.microsoft.com/download/dotnet> (pin
     exact SDK patch used by Windows non-Nix workflow)
   - `WINDBG_MIN_VERSION`: minimum accepted AppX package
     version for `Microsoft.WinDbg`
   - `TTD_MIN_VERSION`: minimum accepted AppX package
     version for `Microsoft.TimeTravelDebugging`
   - `NIM_VERSION`:
     <https://nim-lang.org/install_windows.html> (download
     assets are under `https://nim-lang.org/download/`)
   - `NIM_WIN_X64_SHA256`: SHA256 for
     `nim-<version>_x64.zip` from
     `https://nim-lang.org/download/nim-<version>_x64.zip.sha256`
   - `NIM_SOURCE_REPO`: Nim source repository URL used for
     source mode cache keying/build
   - `NIM_SOURCE_REF`: Nim source ref to resolve
     (tag/branch/refname)
   - `NIM_CSOURCES_REPO`: Nim csources repository URL used
     for source mode cache keying/build
   - `NIM_CSOURCES_REF`: Nim csources ref to resolve
     (tag/branch/refname)
   - `CT_REMOTE_VERSION`: artifact revision at:

     ```text
     https://downloads.codetracer.com/DesktopClient.App/DesktopClient.App-win-x64-<revision>.tar.gz
     ```

   - `CT_REMOTE_WIN_X64_SHA256`: SHA256 for that exact
     Windows archive.
   - `CAPNP_VERSION`:
     <https://capnproto.org/install.html> (Windows asset
     `https://capnproto.org/capnproto-c++-win32-<version>.zip`)
   - `CAPNP_WIN_X64_SHA256`: SHA256 for that exact
     `capnproto-c++-win32-<version>.zip` asset. Cap'n Proto
     currently does not publish a `.sha256` sidecar for this
     ZIP, so we pin and verify the repo-managed hash.
   - `CAPNP_SOURCE_REPO`: Cap'n Proto source repository URL
     used for source mode cache keying/build.
   - `CAPNP_SOURCE_REF`: Cap'n Proto source ref to resolve
     (tag/branch/refname).
   - `TUP_SOURCE_REPO`: Tup source repository URL used for
     source mode cache keying/build (default pin points to
     the variants-capable Windows fork).
   - `TUP_SOURCE_REF`: Tup source ref to resolve
     (tag/branch/refname), defaulting to
     `variants-for-windows`.
   - `TUP_SOURCE_BUILD_COMMAND`: Bash command executed inside
     Tup source checkout to build Tup for Windows bootstrap
     (default pin sets
     `TUP_MINGW=1 TUP_MINGW32=0 ./bootstrap.sh`).
   - `TUP_PREBUILT_VERSION`: version label for the pinned
     official prebuilt Tup archive.
   - `TUP_PREBUILT_URL`: prebuilt Tup archive URL (default
     pin points to
     `https://gittup.org/tup/win32/tup-latest.zip`).
   - `TUP_PREBUILT_SHA256`: SHA256 for that exact prebuilt
     Tup archive.
   - `TUP_MSYS2_BASE_VERSION`: pinned MSYS2 base release
     date (YYYYMMDD) used for Tup source prerequisites.
   - `TUP_MSYS2_BASE_X64_SHA256`: SHA256 for
     `msys2-base-x86_64-<version>.tar.xz`.
   - `TUP_MSYS2_PACKAGES`: space-separated MSYS2 package
     list installed for Tup source builds (default pin uses
     MinGW-targeted
     `mingw-w64-x86_64-gcc mingw-w64-x86_64-pkgconf make`).
2. Update
   `non-nix-build/windows/toolchain-versions.env`.
3. Keep
   `non-nix-build/windows/bootstrap-windows-diy.ps1` in
   sync with the same pinned versions.
4. Validate checksums from upstream checksum documents
   before merging:
   - Node.js archive must match `SHASUMS256.txt` from
     `https://nodejs.org/dist/v<version>/`.
   - rustup installer must match
     `rustup-init.exe.sha256` from
     `https://static.rust-lang.org/rustup/archive/<rustup-version>/<target>/`.
   - uv archive must match `<asset>.sha256` from the
     corresponding GitHub release tag.
   - Nim prebuilt archive must match
     `nim-<version>_x64.zip.sha256` from
     `https://nim-lang.org/download/`.
   - ct-remote archive must match the pinned
     `CT_REMOTE_WIN_X64_SHA256` hash in
     `toolchain-versions.env`.
   - Cap'n Proto archive must match the pinned
     `CAPNP_WIN_X64_SHA256` hash in
     `toolchain-versions.env`.

### Nim hash bump helper

Use this command from PowerShell to compute and verify the
Nim hash you should pin:

```powershell
$version = "2.2.6"
$asset = "nim-$version`_x64.zip"
$url = "https://nim-lang.org/download/$asset"
$sidecarUrl = "$url.sha256"
$tmp = Join-Path $env:TEMP $asset
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
$calculated = (Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
$upstream = ((Invoke-WebRequest -Uri $sidecarUrl -UseBasicParsing).Content -split '\s+')[0].ToLowerInvariant()
"calculated=$calculated"
"upstream=$upstream"
if ($calculated -ne $upstream) { throw "Nim hash mismatch" }
```

## Windows note: ct-rr-support and UI tests

- `ct-rr-support` (from sibling repo
  `../codetracer-rr-backend`) can now be compiled on Windows
  in a compile-only mode.
- Runtime RR replay/record behavior is still Linux-only, so
  Windows flows that require active RR replay are expected to
  return explicit unsupported errors.
- This means `ct record` for scenarios that require the RR
  backend (for example some Noir flows) may still fail on
  Windows even when the binary is present.
- Current observed Windows non-Nix issue: Noir recording can
  hang in `nargo trace`, which leaves `trace-*` folders with
  incomplete data (for example only `symbols.json`) and
  causes Playwright UI tests to timeout waiting for core
  components.
- Interim test-unblock recommendation: run Web-mode
  program-agnostic/layout UI tests with
  `CODETRACER_TRACE_PATH` set to a known non-Noir trace
  folder (for example `src/tui/trace`) while investigating
  the Noir hang.
- Windows-native time-travel backend is now implemented
  behind `DebuggerBackend` via `ct-rr-support` using
  Microsoft TTD + dbgeng.
  - Enable native dbgeng control with
    `CT_TTD_CONTROL_MODE=dbgeng` (optional: enforce
    `CT_TTD_REQUIRE_NATIVE_DBGENG=1` to disable cdb
    fallback).
  - The Windows env scripts already export
    `WINDOWS_DIY_TTD_*`, `WINDOWS_DIY_CDB_EXE`, and
    `WINDOWS_DIY_DBGENG_DLL`; ensure those are available in
    the shell that launches `ct-rr-support`.
  - API surface reference lives in
    `codetracer-rr-backend/docs/dbgeng-api-surface.md`
    alongside the implementation.

### ct-remote hash bump helper

Use this command from PowerShell to compute the hash you
should pin:

```powershell
$revision = "102d2c8"
$asset = "DesktopClient.App-win-x64-$revision.tar.gz"
$url = "https://downloads.codetracer.com/DesktopClient.App/$asset"
$tmp = Join-Path $env:TEMP $asset
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
(Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
```

### Cap'n Proto hash bump helper

Use this command from PowerShell to compute the hash you
should pin:

```powershell
$version = "1.3.0"
$asset = "capnproto-c++-win32-$version.zip"
$url = "https://capnproto.org/$asset"
$tmp = Join-Path $env:TEMP $asset
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
(Get-FileHash -Path $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
```

`bootstrap-windows-diy.ps1` keeps pinned ct-remote download
constrained to Windows x64
(`DesktopClient.App-win-x64-<revision>.tar.gz` +
`CT_REMOTE_WIN_X64_SHA256`). On Windows arm64,
`CT_REMOTE_WINDOWS_SOURCE_MODE=auto` now routes to
local-source mode and will not attempt x64 pinned-download
fallback. Nim source mode can be attempted on both `x64` and
`arm64`, while Nim prebuilt mode remains pinned to
`nim-<version>_x64.zip` and therefore x64-only. Cap'n Proto
now supports
`CAPNP_WINDOWS_SOURCE_MODE=auto|source|prebuilt`: prebuilt
remains pinned to x64 ZIP, and source mode provides the
non-x64 path with deterministic source-cache reuse. Tup now
supports `TUP_WINDOWS_SOURCE_MODE=prebuilt|auto|source` with
default pinned prebuilt install from
`https://gittup.org/tup/win32/tup-latest.zip` and
`TUP_PREBUILT_SHA256`, while keeping source bootstrap support
pinned to `https://github.com/zah/tup.git` branch
`variants-for-windows`, MinGW-targeted bootstrap defaults
(`TUP_SOURCE_BUILD_COMMAND=TUP_MINGW=1 TUP_MINGW32=0 ./bootstrap.sh`)
and MSYS2 prerequisite pins (`TUP_MSYS2_*`) to provision
`mingw-w64-x86_64-gcc`, `mingw-w64-x86_64-pkgconf`, and
`make` reproducibly before source builds. Source defaults come
from `NIM_SOURCE_*`, `NIM_CSOURCES_*`, `CAPNP_SOURCE_*`, and
`TUP_SOURCE_*` pins.

### ct-remote arm64 blocker runbook

If Windows arm64 `ct-remote` bootstrap is still blocked, run
these exact URL probes first:

```powershell
$revision = "102d2c8"
$base = "https://downloads.codetracer.com/DesktopClient.App"
$urls = @(
  "$base/DesktopClient.App-win-x64-$revision.tar.gz",
  "$base/DesktopClient.App-win-arm64-$revision.tar.gz",
  "$base/DesktopClient.App-win-aarch64-$revision.tar.gz",
  "$base/DesktopClient.App-win-arm64ec-$revision.tar.gz"
)
foreach ($url in $urls) {
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $url
    "$url -> $([int]$r.StatusCode) $($r.StatusDescription)"
  } catch {
    $code = if ($_.Exception.Response -and $_.Exception.Response.StatusCode) { [int]$_.Exception.Response.StatusCode } else { "ERR" }
    "$url -> $code"
  }
}
```

Expected outcome as of 2026-02-09:

- `DesktopClient.App-win-x64-102d2c8.tar.gz` returns `200`.
- `DesktopClient.App-win-arm64-102d2c8.tar.gz` returns
  `404`.
- `DesktopClient.App-win-aarch64-102d2c8.tar.gz` returns
  `404`.
- `DesktopClient.App-win-arm64ec-102d2c8.tar.gz` returns
  `404`.

Required inputs to unblock arm64 support:

1. Official arm64 artifact URL at
   `downloads.codetracer.com` for the pinned revision (or an
   approved new revision to pin), including exact filename
   convention (`win-arm64` vs `win-aarch64`).
2. A trustworthy SHA256 value for that exact artifact. There
   is currently no sidecar checksum document for ct-remote
   assets, so this must come from release engineering
   process/publish channel.
3. Confirmation whether x64 and arm64 must share
   `CT_REMOTE_VERSION` or whether per-arch revisions are
   allowed.

### Cap'n Proto non-x64 mode-routing probe

To verify that `CAPNP_WINDOWS_SOURCE_MODE=auto` selects
source mode for non-x64 architectures without requiring an
arm64 host, run:

```powershell
$env:WINDOWS_DIY_ARCH_OVERRIDE = "arm64"
$env:CAPNP_WINDOWS_SOURCE_MODE = "auto"
$env:CAPNP_WINDOWS_SOURCE_REVISION = "7dbb95989721016f8b590245ec7528c6ff03d1fe"
$env:WINDOWS_DIY_SKIP_NIM = "1"
$env:WINDOWS_DIY_SKIP_CT_REMOTE = "1"
pwsh -File non-nix-build/windows/bootstrap-windows-diy.ps1
```

Expected behavior:

- Bootstrap logs Cap'n Proto source-mode activity
  (`Building Cap'n Proto ... from source` or
  `Cap'n Proto ... source cache hit`).
- `capnp/<CAPNP_VERSION>/capnp.install.meta` records
  `requested_mode=auto` and `effective_mode=source`.
- Probe intentionally skips Nim and `ct-remote` via
  `WINDOWS_DIY_SKIP_NIM=1` and
  `WINDOWS_DIY_SKIP_CT_REMOTE=1` so Cap'n Proto route
  selection can be validated in isolation.

## Required Validation Commands

Run these from repo root:

```powershell
pwsh -File non-nix-build/windows/validate-toolchain-versions.ps1
pwsh -Command "$errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('non-nix-build/windows/bootstrap-windows-diy.ps1', [ref]$null, [ref]$errors); if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }"
pwsh -Command "$errors = $null; [void][System.Management.Automation.Language.Parser]::ParseFile('non-nix-build/windows/validate-toolchain-versions.ps1', [ref]$null, [ref]$errors); if ($errors.Count -gt 0) { $errors | ForEach-Object { Write-Error $_.Message }; exit 1 }"
bash -n non-nix-build/windows/env.sh
```

## Changelog and Status Update Expectations

- Add an entry to `CHANGELOG.md` describing the Windows
  toolchain version bump.
- Update `windows-porting-initiative-status.md` when process
  or automation changes.
