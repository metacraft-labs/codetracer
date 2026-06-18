[CmdletBinding()]
param()

# Supported opt-out flags consumed via [Environment]::GetEnvironmentVariable:
#   WINDOWS_DIY_SYNC=0             — skip the bootstrap (Ensure-*) calls,
#                                    including the post-probe
#                                    Ensure-NodeTooling step that would
#                                    otherwise shell out to
#                                    <nodeDir>\npx.cmd (which is only
#                                    populated once Phase 1 Ensure-Node
#                                    has run). On hosted GHA Windows
#                                    Server 2022 runners, set this to 0
#                                    together with
#                                    WINDOWS_DIY_SKIP_TTD_PROBE=1 to let
#                                    env.ps1 source cleanly without
#                                    touching the Appx module or running
#                                    yarn install.
#   WINDOWS_DIY_SETUP_NODE_DEPS=0  — skip the yarn install step inside
#                                    Ensure-NodeTooling even when
#                                    WINDOWS_DIY_SYNC=1; useful when the
#                                    caller wants the rest of the
#                                    toolchain bootstrap but already
#                                    manages node-packages/ themselves.
#   WINDOWS_DIY_SKIP_<STEP>=1      — skip the named bootstrap step (e.g.
#                                    WINDOWS_DIY_SKIP_CLINGO=1) when
#                                    WINDOWS_DIY_SYNC is otherwise on.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
  return (Split-Path -Parent $PSCommandPath)
}

function Get-DefaultInstallRoot {
  $envInstallRoot = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($envInstallRoot)) {
    return $envInstallRoot.Trim()
  }

  # Prefer D: drive root when available (more space, avoids C: bloat).
  if (Test-Path -LiteralPath "D:\" -PathType Container) {
    return "D:\metacraft-dev-deps"
  }

  $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if ([string]::IsNullOrWhiteSpace($localAppData)) {
    throw "Could not resolve LocalApplicationData for default WINDOWS_DIY_INSTALL_ROOT."
  }

  return (Join-Path (Join-Path $localAppData "codetracer") "windows-diy")
}

function ConvertTo-BoolFromEnv {
  param(
    [string]$Name,
    [bool]$Default
  )

  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return $Default
  }

  switch ($raw.Trim().ToLowerInvariant()) {
    "1" { return $true }
    "true" { return $true }
    "yes" { return $true }
    "on" { return $true }
    "0" { return $false }
    "false" { return $false }
    "no" { return $false }
    "off" { return $false }
    default { return $Default }
  }
}

function Parse-ToolchainVersions {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Missing toolchain version file at '$Path'."
  }

  $map = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    if ($line -notmatch '^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$') {
      continue
    }

    $name = $matches[1]
    $value = $matches[2].Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    }
    $map[$name] = $value
  }

  return $map
}


function Set-EnvDefault {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$Value
  )

  $existing = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($existing)) {
    [Environment]::SetEnvironmentVariable($Name, $Value, "Process")
  }
}

function Resolve-InstallDirFromRelativePathFile {
  param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$RelativePathFile,
    [string]$FallbackDir = ""
  )

  if (Test-Path -LiteralPath $RelativePathFile -PathType Leaf) {
    $relative = (Get-Content -LiteralPath $RelativePathFile -Raw).Trim()
    if (-not [string]::IsNullOrWhiteSpace($relative)) {
      $parts = $relative -split '[\\/]'
      return (Join-Path $InstallRoot ([System.IO.Path]::Combine($parts)))
    }
  }

  if (-not [string]::IsNullOrWhiteSpace($FallbackDir)) {
    return $FallbackDir
  }

  return ""
}

function Resolve-DotnetRoot {
  param(
    [Parameter(Mandatory = $true)][string]$InstallRoot,
    [Parameter(Mandatory = $true)][string]$PinnedSdkVersion
  )

  $candidates = @()
  $override = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_DOTNET_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    $candidates += $override.Trim()
  }
  $candidates += (Join-Path $InstallRoot ("dotnet\" + $PinnedSdkVersion))
  $candidates += (Join-Path ${env:ProgramFiles} "dotnet")

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $exe = Join-Path $candidate "dotnet.exe"
    if (Test-Path -LiteralPath $exe -PathType Leaf) {
      return $candidate
    }
  }

  # Fall back to the managed install path — Ensure-Dotnet will create it during sync.
  return (Join-Path $InstallRoot ("dotnet\" + $PinnedSdkVersion))
}

function Resolve-TtdExe {
  $candidates = @()
  $override = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_TTD_EXE")
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    $candidates += $override.Trim()
  }

  # Check DIY cache first — these are regular files accessible from SSH/CI
  $diyRoot = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($diyRoot)) {
    $ttdCacheRoot = Join-Path $diyRoot "ttd"
    if (Test-Path -LiteralPath $ttdCacheRoot -PathType Container) {
      $versionDirs = Get-ChildItem -LiteralPath $ttdCacheRoot -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending
      foreach ($vd in $versionDirs) {
        $candidates += (Join-Path $vd.FullName "TTD.exe")
      }
    }
  }

  $ttdPackage = Get-AppxPackage -Name "Microsoft.TimeTravelDebugging" -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
  if ($null -ne $ttdPackage -and -not [string]::IsNullOrWhiteSpace($ttdPackage.InstallLocation)) {
    $candidates += (Join-Path $ttdPackage.InstallLocation "TTD.exe")
  }

  $ttdCmd = Get-Command ttd.exe -ErrorAction SilentlyContinue
  if ($null -ne $ttdCmd -and -not [string]::IsNullOrWhiteSpace($ttdCmd.Source)) {
    $candidates += $ttdCmd.Source
  }
  $ttdCmd = Get-Command ttd -ErrorAction SilentlyContinue
  if ($null -ne $ttdCmd -and -not [string]::IsNullOrWhiteSpace($ttdCmd.Source)) {
    $candidates += $ttdCmd.Source
  }

  $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
  if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
    $candidates += (Join-Path $localAppData "Microsoft\WindowsApps\ttd.exe")
  }
  $candidates += (Join-Path ${env:USERPROFILE} "AppData\Local\Microsoft\WindowsApps\ttd.exe")

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  return ""
}

function Resolve-AppxPackageInfo {
  param([Parameter(Mandatory = $true)][string]$Name)

  $pkg = Get-AppxPackage -Name $Name -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1
  if ($null -eq $pkg) {
    return $null
  }
  return $pkg
}

function Parse-VersionOrNull {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return $null
  }

  try {
    return [version]$Value.Trim()
  } catch {
    return $null
  }
}

function Assert-MinVersion {
  param(
    [Parameter(Mandatory = $true)][string]$DisplayName,
    [Parameter(Mandatory = $true)][string]$ActualVersion,
    [Parameter(Mandatory = $true)][string]$MinVersion,
    [Parameter(Mandatory = $true)][string]$InstallHint
  )

  $actualParsed = Parse-VersionOrNull -Value $ActualVersion
  $minParsed = Parse-VersionOrNull -Value $MinVersion
  if ($null -eq $actualParsed -or $null -eq $minParsed) {
    throw "Could not parse version check inputs for '$DisplayName'. actual='$ActualVersion', min='$MinVersion'."
  }

  if ($actualParsed -lt $minParsed) {
    throw "$DisplayName version '$ActualVersion' is below required minimum '$MinVersion'. Install/upgrade with: $InstallHint"
  }
}

function Resolve-MsvcToolsetVersion {
  $envVersion = [Environment]::GetEnvironmentVariable("VCToolsVersion")
  if (-not [string]::IsNullOrWhiteSpace($envVersion)) {
    return $envVersion.Trim().TrimEnd('\')
  }

  $toolsDir = [Environment]::GetEnvironmentVariable("VCToolsInstallDir")
  if (-not [string]::IsNullOrWhiteSpace($toolsDir)) {
    $leaf = Split-Path -Leaf ($toolsDir.Trim().TrimEnd('\'))
    if (-not [string]::IsNullOrWhiteSpace($leaf)) {
      return $leaf
    }
  }

  $msvcBinDir = [Environment]::GetEnvironmentVariable("MSVC_BIN_DIR")
  if (-not [string]::IsNullOrWhiteSpace($msvcBinDir)) {
    $normalized = $msvcBinDir.Replace("/", "\")
    $match = [regex]::Match($normalized, "\\MSVC\\([^\\]+)\\bin\\", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if ($match.Success) {
      return $match.Groups[1].Value
    }
  }

  return ""
}

function Assert-MsvcToolsetVersion {
  param(
    [Parameter(Mandatory = $true)][string]$ActualVersion,
    [Parameter(Mandatory = $true)][string]$PinnedVersion
  )

  if ([string]::IsNullOrWhiteSpace($ActualVersion)) {
    throw "Could not resolve MSVC toolset version from VCToolsVersion/VCToolsInstallDir."
  }

  $actual = $ActualVersion.Trim()
  $pinned = $PinnedVersion.Trim()
  $pinnedPrefix = $pinned + "."
  if ($actual -ne $pinned -and -not $actual.StartsWith($pinnedPrefix)) {
    throw "MSVC toolset version '$actual' does not match pinned '$pinned'. Install the pinned Build Tools/MSVC toolset."
  }
}

function Assert-DotnetSdkPresent {
  param(
    [Parameter(Mandatory = $true)][string]$DotnetExe,
    [Parameter(Mandatory = $true)][string]$PinnedSdkVersion
  )

  $sdkLines = & $DotnetExe --list-sdks 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to query installed .NET SDKs via '$DotnetExe --list-sdks'."
  }

  $installedVersions = @()
  foreach ($line in $sdkLines) {
    if ([string]$line -match "^\s*([0-9]+\.[0-9]+\.[0-9]+)\s") {
      $installedVersions += $matches[1]
    }
  }

  if ($installedVersions -contains $PinnedSdkVersion) {
    [Environment]::SetEnvironmentVariable("DOTNET_SDK_VERSION_EFFECTIVE", $PinnedSdkVersion, "Process")
    return
  }

  $allowFeatureRollForward = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_DOTNET_ROLL_FORWARD_FEATURE" -Default $true
  if ($allowFeatureRollForward) {
    $majorMinorMatch = [regex]::Match($PinnedSdkVersion, '^([0-9]+\.[0-9]+)\.')
    if ($majorMinorMatch.Success) {
      $pinnedMajorMinor = $majorMinorMatch.Groups[1].Value
      $featureBandMatches = @()
      foreach ($v in $installedVersions) {
        if ($v -match "^$([regex]::Escape($pinnedMajorMinor))\.[0-9]+$") {
          $featureBandMatches += $v
        }
      }
      if ($featureBandMatches.Count -gt 0) {
        $effective = $featureBandMatches | Sort-Object {[version]$_} -Descending | Select-Object -First 1
        [Environment]::SetEnvironmentVariable("DOTNET_SDK_VERSION_EFFECTIVE", $effective, "Process")
        Write-Warning "Pinned .NET SDK '$PinnedSdkVersion' not found; using feature-band roll-forward '$effective' from '$DotnetExe'."
        return
      }
    }
  }

  $available = if ($installedVersions.Count -gt 0) { $installedVersions -join ", " } else { "<none>" }
  throw "Pinned .NET SDK '$PinnedSdkVersion' is not installed for '$DotnetExe'. Installed SDKs: $available. Install with: winget install --id Microsoft.DotNet.SDK.9 --exact --source winget"
}

function Resolve-TtdRuntimeInfo {
  $ttdPackage = Resolve-AppxPackageInfo -Name "Microsoft.TimeTravelDebugging"
  $windbgPackage = Resolve-AppxPackageInfo -Name "Microsoft.WinDbg"
  $ttdExe = Resolve-TtdExe

  $ttdInstallDir = ""
  $ttdVersion = ""

  # Prefer DIY cache directory (works from SSH/CI sessions)
  if (-not [string]::IsNullOrWhiteSpace($ttdExe)) {
    $ttdExeDir = Split-Path -Parent $ttdExe
    $metaFile = Join-Path $ttdExeDir "ttd.install.meta"
    if (Test-Path -LiteralPath $metaFile -PathType Leaf) {
      # This is a DIY-cached copy — use its directory and read version from meta
      $ttdInstallDir = $ttdExeDir
      $meta = Read-KeyValueFile -Path $metaFile
      if ($meta.ContainsKey("ttd_version")) {
        $ttdVersion = [string]$meta["ttd_version"]
      }
    }
  }

  # Fall back to AppX package info if DIY cache didn't provide version
  if ([string]::IsNullOrWhiteSpace($ttdVersion) -and $null -ne $ttdPackage) {
    $ttdInstallDir = [string]$ttdPackage.InstallLocation
    $ttdVersion = [string]$ttdPackage.Version
  }

  $windbgInstallDir = ""
  $windbgVersion = ""
  if ($null -ne $windbgPackage) {
    $windbgInstallDir = [string]$windbgPackage.InstallLocation
    $windbgVersion = [string]$windbgPackage.Version
  }

  $ttdReplayDll = ""
  $ttdReplayCpuDll = ""
  if (-not [string]::IsNullOrWhiteSpace($ttdInstallDir)) {
    $replayCandidate = Join-Path $ttdInstallDir "TTDReplay.dll"
    if (Test-Path -LiteralPath $replayCandidate -PathType Leaf) {
      $ttdReplayDll = $replayCandidate
    }
    $replayCpuCandidate = Join-Path $ttdInstallDir "TTDReplayCPU.dll"
    if (Test-Path -LiteralPath $replayCpuCandidate -PathType Leaf) {
      $ttdReplayCpuDll = $replayCpuCandidate
    }
  }

  $cdbExe = ""
  $dbgengDll = ""
  $dbgmodelDll = ""
  $dbghelpDll = ""
  if (-not [string]::IsNullOrWhiteSpace($windbgInstallDir)) {
    $archKey = [Environment]::GetEnvironmentVariable("PROCESSOR_ARCHITECTURE")
    $subdirs = @("arm64", "amd64", "x64", "x86")
    if (-not [string]::IsNullOrWhiteSpace($archKey)) {
      $archLower = $archKey.ToLowerInvariant()
      if ($archLower -eq "amd64") {
        $subdirs = @("amd64", "x64", "arm64", "x86")
      } elseif ($archLower -eq "arm64") {
        $subdirs = @("arm64", "amd64", "x64", "x86")
      } elseif ($archLower -eq "x86") {
        $subdirs = @("x86", "amd64", "x64", "arm64")
      }
    }

    foreach ($sub in $subdirs) {
      if ([string]::IsNullOrWhiteSpace($cdbExe)) {
        $candidate = Join-Path $windbgInstallDir ($sub + "\cdb.exe")
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $cdbExe = $candidate
        }
      }
      if ([string]::IsNullOrWhiteSpace($dbgengDll)) {
        $candidate = Join-Path $windbgInstallDir ($sub + "\dbgeng.dll")
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $dbgengDll = $candidate
        }
      }
      if ([string]::IsNullOrWhiteSpace($dbgmodelDll)) {
        $candidate = Join-Path $windbgInstallDir ($sub + "\dbgmodel.dll")
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $dbgmodelDll = $candidate
        }
      }
      if ([string]::IsNullOrWhiteSpace($dbghelpDll)) {
        $candidate = Join-Path $windbgInstallDir ($sub + "\dbghelp.dll")
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
          $dbghelpDll = $candidate
        }
      }
    }
  }

  $systemRoot = [Environment]::GetEnvironmentVariable("SystemRoot")
  if ([string]::IsNullOrWhiteSpace($systemRoot)) {
    $systemRoot = "C:\Windows"
  }
  $system32 = Join-Path $systemRoot "System32"
  $candidate = Join-Path $system32 "dbgeng.dll"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $dbgengDll = $candidate
  }
  $candidate = Join-Path $system32 "dbgmodel.dll"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $dbgmodelDll = $candidate
  }
  $candidate = Join-Path $system32 "dbghelp.dll"
  if (Test-Path -LiteralPath $candidate -PathType Leaf) {
    $dbghelpDll = $candidate
  }

  return [ordered]@{
    ttdExe = $ttdExe
    ttdInstallDir = $ttdInstallDir
    ttdVersion = $ttdVersion
    ttdReplayDll = $ttdReplayDll
    ttdReplayCpuDll = $ttdReplayCpuDll
    windbgInstallDir = $windbgInstallDir
    windbgVersion = $windbgVersion
    cdbExe = $cdbExe
    dbgengDll = $dbgengDll
    dbgmodelDll = $dbgmodelDll
    dbghelpDll = $dbghelpDll
  }
}

function Ensure-NodeTooling {
  param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [Parameter(Mandatory = $true)][string]$NodePackagesBin,
    [Parameter(Mandatory = $true)][string]$NodeDir
  )

  $stylusCmd = Join-Path $NodePackagesBin "stylus.cmd"
  $webpackCmd = Join-Path $NodePackagesBin "webpack.cmd"
  if ((Test-Path -LiteralPath $stylusCmd -PathType Leaf) -and (Test-Path -LiteralPath $webpackCmd -PathType Leaf)) {
    return
  }

  $setupNodeDeps = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_SETUP_NODE_DEPS" -Default $true
  if (-not $setupNodeDeps) {
    Write-Warning "Node deps are missing (stylus/webpack) and WINDOWS_DIY_SETUP_NODE_DEPS=0. Run 'cd node-packages; npx yarn install'."
    return
  }

  $npxExe = Join-Path $NodeDir "npx.cmd"
  if (-not (Test-Path -LiteralPath $npxExe -PathType Leaf)) {
    throw "npx not found at '$npxExe'. Ensure Node.js is installed (Ensure-Node)."
  }

  Write-Host "Windows DIY: Node deps missing, running yarn install in node-packages..."
  $nodePackagesDir = Join-Path $RepoRoot "node-packages"

  # Temporarily put NodeDir on PATH so child processes (yarn -> node) can find node.exe.
  $savedPath = $env:PATH
  $env:PATH = "$NodeDir;$env:PATH"
  Push-Location $nodePackagesDir
  try {
    $lockFile = Join-Path $nodePackagesDir "yarn.lock"
    if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
      & $npxExe yarn install --frozen-lockfile
    } else {
      & $npxExe yarn install
    }
  } finally {
    Pop-Location
    $env:PATH = $savedPath
  }

  if ((-not (Test-Path -LiteralPath $stylusCmd -PathType Leaf)) -or (-not (Test-Path -LiteralPath $webpackCmd -PathType Leaf))) {
    throw "Node dependency setup finished but stylus/webpack commands are still missing under '$NodePackagesBin'."
  }
}

# Mirror of env.sh:600-601 — `ln -s node-packages/node_modules ./node_modules`.
#
# `scripts/build-once.sh` and other build scripts hard-code
# `node_modules/.bin/webpack` relative to the repo root, but yarn installs the
# JS deps under `node-packages/node_modules/`. On POSIX env.sh creates a
# symlink. On Windows we use an NTFS junction (works without symlink privilege
# and is transparent to all consumers, including bash and Node's CommonJS
# resolver).
#
# Idempotent: re-running this is a no-op when the junction already exists and
# points at the right target. If something else owns `node_modules` (a real
# directory, a stale junction pointing elsewhere, or a symlink), we leave it
# alone and emit a warning rather than risk destroying real state.
function Ensure-NodeModulesJunction {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $repoNodeModules = Join-Path $RepoRoot "node_modules"
  $packagesNodeModules = Join-Path (Join-Path $RepoRoot "node-packages") "node_modules"

  if (-not (Test-Path -LiteralPath $packagesNodeModules -PathType Container)) {
    # yarn install hasn't run yet — Ensure-NodeTooling handles that path. We
    # skip silently because the junction target doesn't exist yet; a follow-up
    # source of env.ps1 (after yarn install) will create the link.
    return
  }

  $expectedTarget = [System.IO.Path]::GetFullPath($packagesNodeModules)

  if (Test-Path -LiteralPath $repoNodeModules) {
    try {
      $existing = Get-Item -LiteralPath $repoNodeModules -Force -ErrorAction Stop
    } catch {
      Write-Warning "Could not stat '$repoNodeModules': $($_.Exception.Message). Skipping node_modules junction creation."
      return
    }

    $isReparse = $false
    try {
      $isReparse = (([int]$existing.Attributes) -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0
    } catch {}

    if ($isReparse) {
      $currentTarget = ""
      try {
        $currentTarget = [string]$existing.Target
      } catch {}
      if ([string]::IsNullOrWhiteSpace($currentTarget) -and $null -ne $existing.PSObject.Properties["LinkTarget"]) {
        $currentTarget = [string]$existing.LinkTarget
      }
      if (-not [string]::IsNullOrWhiteSpace($currentTarget)) {
        try {
          $resolvedTarget = [System.IO.Path]::GetFullPath($currentTarget)
        } catch {
          $resolvedTarget = $currentTarget
        }
        if ($resolvedTarget.TrimEnd('\','/') -ieq $expectedTarget.TrimEnd('\','/')) {
          # Already pointing at the right place — idempotent no-op.
          return
        }
        Write-Warning "node_modules at '$repoNodeModules' is a reparse point pointing at '$resolvedTarget' (expected '$expectedTarget'). Leaving it in place; please remove it manually if you want env.ps1 to manage the junction."
        return
      }
      Write-Warning "node_modules at '$repoNodeModules' is a reparse point but its target could not be resolved. Leaving it in place."
      return
    }

    # Real directory or file — don't clobber.
    Write-Warning "node_modules at '$repoNodeModules' already exists as a regular path. Skipping junction creation. Remove it and re-source env.ps1 to let the bootstrap manage the junction."
    return
  }

  try {
    New-Item -ItemType Junction -Path $repoNodeModules -Target $packagesNodeModules | Out-Null
    Write-Host "Created node_modules junction: $repoNodeModules -> $packagesNodeModules"
  } catch {
    Write-Warning "Failed to create node_modules junction '$repoNodeModules' -> '$packagesNodeModules': $($_.Exception.Message)"
  }
}

# Materialize the GoldenLayout CSS directory inside the *build output*
# so the runtime `<link>` references resolve on Windows.
#
# `src/public/third_party/golden-layout/dist` is a git mode-120000 POSIX
# symlink into `node_modules/golden-layout/dist`.  On a Windows checkout
# with `core.symlinks=false` it materializes as a ~44-byte text-file
# stub.  The Tup rule `: third_party/golden-layout/dist |> !tup_preserve
# |> %f` treats that stub as a single opaque leaf — exactly the way the
# sibling `third_party/monaco-editor/min`, `@exuanbo`, `mousetrap`,
# `vex-js`, and `xterm` stubs are handled.  This MUST stay a plain-file
# stub in the source tree: if it is materialized as a real directory
# (junction or directory symlink) Tup's scanner registers `dist` as a
# directory node and the leaf `!tup_preserve` rule then fails with
# "Attempting to insert '.../dist' as a generated node when it already
# exists as a different type (directory)".  We therefore DO NOT touch
# the source stub here.
#
# Tup `!tup_preserve` copies that stub verbatim to
# `build-debug/public/third_party/golden-layout/dist`, so the build
# output also ends up with a useless text stub and the `<link>` to
# `goldenlayout-base.css` from index.html / server_index.ejs 404s,
# leaving GoldenLayout unstyled (collapsed, unclickable tab headers).
#
# The fix: after Tup has produced the build tree, replace the build-only
# stub with a real directory symlink into the actual
# `node_modules/golden-layout/dist`.  This is a build-output-only change
# — the tup-scanned source tree stays a plain stub, so the leaf rule
# keeps parsing cleanly on every platform.  A directory symlink is
# preferred (resolves with relative `<link>` paths exactly like a Linux
# symlink); a junction is the fallback when the symlink privilege is
# unavailable.  When the build output does not exist yet (first shell
# activation before any `tup upd`), this is a silent no-op and the next
# activation after a build installs the link.
function Ensure-GoldenLayoutAsset {
  param([Parameter(Mandatory = $true)][string]$RepoRoot)

  $target = [System.IO.Path]::GetFullPath(
    (Join-Path $RepoRoot "node_modules/golden-layout/dist"))
  if (-not (Test-Path -LiteralPath $target -PathType Container)) {
    return
  }

  $buildDistParent = Join-Path $RepoRoot "src/build-debug/public/third_party/golden-layout"
  if (-not (Test-Path -LiteralPath $buildDistParent -PathType Container)) {
    # Build output not produced yet — nothing to fix up.
    return
  }
  $linkPath = Join-Path $buildDistParent "dist"

  if (Test-Path -LiteralPath $linkPath) {
    $item = Get-Item -LiteralPath $linkPath -Force -ErrorAction SilentlyContinue
    if ($null -ne $item) {
      $isReparse = $false
      try {
        $isReparse = (([int]$item.Attributes) -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0
      } catch {}
      if ($isReparse) {
        # Already a junction/symlink directory — idempotent no-op.
        return
      }
    }
    # Plain Tup-preserved stub (or stale dir) — replace it.
    try {
      if (($null -ne $item) -and $item.PSIsContainer -and -not $isReparse) {
        Remove-Item -LiteralPath $linkPath -Force -Recurse -ErrorAction Stop
      } else {
        Remove-Item -LiteralPath $linkPath -Force -ErrorAction Stop
      }
    } catch {
      Write-Warning "Could not remove golden-layout build stub '$linkPath': $($_.Exception.Message)"
      return
    }
  }

  try {
    New-Item -ItemType SymbolicLink -Path $linkPath -Target $target -ErrorAction Stop | Out-Null
    Write-Host "Linked golden-layout CSS into build output: $linkPath -> $target"
  } catch {
    try {
      New-Item -ItemType Junction -Path $linkPath -Target $target -ErrorAction Stop | Out-Null
      Write-Host "Linked golden-layout CSS into build output (junction): $linkPath -> $target"
    } catch {
      Write-Warning "Failed to link golden-layout CSS into build output '$linkPath' -> '$target': $($_.Exception.Message)"
    }
  }
}

function Prepend-PathEntries {
  param([Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][AllowEmptyCollection()][string[]]$Entries)
  $existing = [Environment]::GetEnvironmentVariable("PATH")
  $prefix = @()
  foreach ($entry in $Entries) {
    if ($null -eq $entry) { continue }
    $entryPath = [string]$entry
    if ([string]::IsNullOrWhiteSpace($entryPath)) { continue }
    if (-not (Test-Path -LiteralPath $entryPath)) { continue }
    $prefix += $entryPath
  }
  if ($prefix.Count -eq 0) { return }
  [Environment]::SetEnvironmentVariable("PATH", (($prefix -join ";") + ";" + $existing), "Process")
}

function Resolve-GitBashBinDir {
  $candidates = @(
    (Join-Path ${env:ProgramFiles} "Git\bin"),
    (Join-Path ${env:ProgramFiles} "Git\usr\bin"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\bin"),
    (Join-Path ${env:ProgramFiles(x86)} "Git\usr\bin")
  )

  # Also derive candidates from wherever `git` actually resolves on PATH.
  # The fixed Program Files paths above miss non-standard installs (scoop,
  # winget, portable Git). Without this, `WINDOWS_DIY_GIT_BASH_BIN` stays
  # empty and `Get-Command bash` later resolves to WSL's System32 bash,
  # which cannot open `D:/...` Windows paths (it needs `/mnt/d/...`).
  $gitCmd = Get-Command git -ErrorAction SilentlyContinue
  if ($null -ne $gitCmd -and -not [string]::IsNullOrWhiteSpace($gitCmd.Source)) {
    $gitExeDir = Split-Path -Parent $gitCmd.Source   # ...\cmd or ...\bin
    $gitRoot = Split-Path -Parent $gitExeDir         # install root
    foreach ($root in @($gitRoot, (Split-Path -Parent $gitRoot))) {
      if ([string]::IsNullOrWhiteSpace($root)) { continue }
      $candidates += (Join-Path $root "bin")
      $candidates += (Join-Path $root "usr\bin")
    }
  }

  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    $bashExe = Join-Path $candidate "bash.exe"
    if (Test-Path -LiteralPath $bashExe -PathType Leaf) {
      return $candidate
    }
  }

  return ""
}

function Convert-WindowsPathToMsys {
  param([Parameter(Mandatory = $true)][string]$Path)

  $normalized = $Path -replace '\\', '/'
  if ($normalized -match '^([A-Za-z]):/(.*)$') {
    $drive = $matches[1].ToLowerInvariant()
    $rest = $matches[2]
    if ([string]::IsNullOrWhiteSpace($rest)) {
      return "/$drive"
    }
    return "/$drive/$rest"
  }

  return $normalized
}

function New-BashExeShim {
  param(
    [Parameter(Mandatory = $true)][string]$ShimsDir,
    [Parameter(Mandatory = $true)][string]$CommandName,
    [Parameter(Mandatory = $true)][string]$ExePath
  )

  if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    return
  }

  $exeMsys = Convert-WindowsPathToMsys -Path $ExePath
  $shimPath = Join-Path $ShimsDir $CommandName
  $shimText = @"
#!/usr/bin/env bash
set -euo pipefail
exe_msys="$exeMsys"
exe_win="$ExePath"

if [ -x "`$exe_msys" ]; then
  exec "`$exe_msys" "`$@"
fi

# WSL bash commonly mounts Windows drives under /mnt/<drive>, not /<drive>.
if [[ "`$exe_msys" =~ ^/([A-Za-z])/(.*)$ ]]; then
  drive="`${BASH_REMATCH[1],,}"
  rest="`${BASH_REMATCH[2]}"
  exe_wsl="/mnt/`$drive/`$rest"
  if [ -x "`$exe_wsl" ]; then
    exec "`$exe_wsl" "`$@"
  fi
fi

# Fallback for environments where wslpath is available and mounts are custom.
if command -v wslpath >/dev/null 2>&1; then
  exe_wsl_dynamic="`$(wslpath -u "`$exe_win" 2>/dev/null || true)"
  if [ -n "`$exe_wsl_dynamic" ] && [ -x "`$exe_wsl_dynamic" ]; then
    exec "`$exe_wsl_dynamic" "`$@"
  fi
fi

echo "ERROR: could not find executable for '$CommandName'." >&2
echo "Tried: `$exe_msys, `${exe_wsl:-<unset>}, `${exe_wsl_dynamic:-<unset>}, `$exe_win" >&2
exit 127
"@ -replace "`r`n", "`n"
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($shimPath, $shimText, $utf8NoBom)
}

function Set-ExecutableAliasIfPresent {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$ExePath
  )

  if (Test-Path -LiteralPath $ExePath -PathType Leaf) {
    Set-Alias -Name $Name -Value $ExePath -Scope Global
  }
}

$repoRoot = Get-RepoRoot
$windowsDir = Join-Path $repoRoot "non-nix-build\windows"
$toolchainPath = Join-Path $windowsDir "toolchain-versions.env"
$toolchain = Parse-ToolchainVersions -Path $toolchainPath

# Dot-source ensure modules for install-on-demand bootstrap.
. "$windowsDir/toolchain-utils.ps1"
. "$windowsDir/ensure-rust.ps1"
. "$windowsDir/ensure-just.ps1"
. "$windowsDir/ensure-nextest.ps1"
. "$windowsDir/ensure-node.ps1"
. "$windowsDir/ensure-uv.ps1"
. "$windowsDir/ensure-nim.ps1"
. "$windowsDir/ensure-capnp.ps1"
. "$windowsDir/ensure-tup.ps1"
. "$windowsDir/ensure-dotnet.ps1"
. "$windowsDir/ensure-ct-remote.ps1"
. "$windowsDir/ensure-nargo.ps1"
. "$windowsDir/ensure-ttd.ps1"
. "$windowsDir/ensure-gcc.ps1"
. "$windowsDir/ensure-gnat.ps1"
. "$windowsDir/ensure-go.ps1"
. "$windowsDir/ensure-ldc.ps1"
. "$windowsDir/ensure-vlang.ps1"
. "$windowsDir/ensure-fpc.ps1"
. "$windowsDir/ensure-zstd.ps1"
. "$windowsDir/ensure-zlib.ps1"
. "$windowsDir/ensure-llvm.ps1"
. "$windowsDir/ensure-clingo.ps1"

$preferGitBash = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_PREFER_GIT_BASH" -Default $true
$gitBashBinDir = ""
if ($preferGitBash) {
  $gitBashBinDir = Resolve-GitBashBinDir
  if (-not [string]::IsNullOrWhiteSpace($gitBashBinDir)) {
    Prepend-PathEntries -Entries @($gitBashBinDir)
    [Environment]::SetEnvironmentVariable("WINDOWS_DIY_GIT_BASH_BIN", $gitBashBinDir, "Process")
  }
}

$installRoot = Get-DefaultInstallRoot
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT", $installRoot, "Process")

Set-EnvDefault -Name "NIM_WINDOWS_SOURCE_MODE" -Value "auto"
Set-EnvDefault -Name "NIM_WINDOWS_SOURCE_REPO" -Value $toolchain["NIM_SOURCE_REPO"]
Set-EnvDefault -Name "NIM_WINDOWS_SOURCE_REF" -Value $toolchain["NIM_SOURCE_REF"]
Set-EnvDefault -Name "NIM_WINDOWS_CSOURCES_REPO" -Value $toolchain["NIM_CSOURCES_REPO"]
Set-EnvDefault -Name "NIM_WINDOWS_CSOURCES_REF" -Value $toolchain["NIM_CSOURCES_REF"]

Set-EnvDefault -Name "CAPNP_WINDOWS_SOURCE_MODE" -Value "auto"
Set-EnvDefault -Name "CAPNP_WINDOWS_SOURCE_REPO" -Value $toolchain["CAPNP_SOURCE_REPO"]
Set-EnvDefault -Name "CAPNP_WINDOWS_SOURCE_REF" -Value $toolchain["CAPNP_SOURCE_REF"]

Set-EnvDefault -Name "TUP_WINDOWS_SOURCE_MODE" -Value "prebuilt"
Set-EnvDefault -Name "TUP_WINDOWS_SOURCE_REPO" -Value $toolchain["TUP_SOURCE_REPO"]
Set-EnvDefault -Name "TUP_WINDOWS_SOURCE_REF" -Value $toolchain["TUP_SOURCE_REF"]
Set-EnvDefault -Name "TUP_WINDOWS_SOURCE_BUILD_COMMAND" -Value $toolchain["TUP_SOURCE_BUILD_COMMAND"]
Set-EnvDefault -Name "TUP_WINDOWS_PREBUILT_VERSION" -Value $toolchain["TUP_PREBUILT_VERSION"]
Set-EnvDefault -Name "TUP_WINDOWS_PREBUILT_URL" -Value $toolchain["TUP_PREBUILT_URL"]
Set-EnvDefault -Name "TUP_WINDOWS_PREBUILT_SHA256" -Value $toolchain["TUP_PREBUILT_SHA256"]
Set-EnvDefault -Name "TUP_WINDOWS_MSYS2_BASE_VERSION" -Value $toolchain["TUP_MSYS2_BASE_VERSION"]
Set-EnvDefault -Name "TUP_WINDOWS_MSYS2_PACKAGES" -Value $toolchain["TUP_MSYS2_PACKAGES"]

Set-EnvDefault -Name "CT_REMOTE_WINDOWS_SOURCE_MODE" -Value "auto"
Set-EnvDefault -Name "CT_REMOTE_WINDOWS_SOURCE_REPO" -Value (Join-Path $repoRoot "..\codetracer-ci")

[Environment]::SetEnvironmentVariable("RUSTUP_HOME", (Join-Path $installRoot "rustup"), "Process")
[Environment]::SetEnvironmentVariable("CARGO_HOME", (Join-Path $installRoot "cargo"), "Process")

$doSync = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_SYNC" -Default $true
if ($doSync) {
  $arch = Get-WindowsArch

  # Phase 1: No dependencies
  if (Test-BootstrapStepEnabled "TTD")  { Ensure-Ttd -Root $installRoot }
  if (Test-BootstrapStepEnabled "NODE") { Ensure-Node -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "UV")   { Ensure-Uv   -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "GCC")  { Ensure-Gcc  -Root $installRoot -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "GNAT") { Ensure-Gnat -Root $installRoot -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "GO")    { Ensure-Go    -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "LDC")   { Ensure-Ldc   -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "VLANG") { Ensure-Vlang -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "FPC")   { Ensure-Fpc   -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "ZSTD") { Ensure-Zstd -Root $installRoot -Arch $arch -Toolchain $toolchain }
  # Ensure-Zlib must run after Ensure-Gcc (depends on mingw32-make + gcc).
  if (Test-BootstrapStepEnabled "ZLIB") { Ensure-Zlib -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "LLVM") { Ensure-Llvm -Root $installRoot -Arch $arch -Toolchain $toolchain }
  # Clingo is the ASP solver `repro` and its child `extract_runner.exe`
  # dlopen at runtime via `clingo.dll`. It has no other build-system
  # dependency; install it whenever the user does not opt out via
  # WINDOWS_DIY_SKIP_CLINGO=1.
  if (Test-BootstrapStepEnabled "CLINGO") { Ensure-Clingo -Root $installRoot -Arch $arch -Toolchain $toolchain }

  # Phase 2: Rust (no deps on other managed tools)
  if (Test-BootstrapStepEnabled "RUST") { Ensure-Rust -Root $installRoot -Arch $arch -Toolchain $toolchain }

  # Phase 3: Depends on Rust/cargo
  if (Test-BootstrapStepEnabled "JUST") { Ensure-Just -Root $installRoot -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "NEXTEST") { Ensure-Nextest -Root $installRoot -Toolchain $toolchain }

  # Phase 4: May need MSYS2 for source builds
  if (Test-BootstrapStepEnabled "NIM")   { Ensure-Nim   -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "CAPNP") { Ensure-Capnp -Root $installRoot -Arch $arch -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "TUP")   { Ensure-Tup   -Root $installRoot -Toolchain $toolchain }

  # Phase 5: Depends on Rust + MSYS2
  if (Test-BootstrapStepEnabled "NARGO") { Ensure-Nargo -Root $installRoot -Toolchain $toolchain -RepoRoot $repoRoot }

  # Phase 6: dotnet and tools that depend on it
  if (Test-BootstrapStepEnabled "DOTNET")    { Ensure-Dotnet    -Root $installRoot -Toolchain $toolchain }
  if (Test-BootstrapStepEnabled "CT_REMOTE") { Ensure-CtRemote -Root $installRoot -Arch $arch -Toolchain $toolchain -WindowsDir $windowsDir }
}

$arch = Get-WindowsArch
$nodeArch = ConvertTo-NodeFileArch -Arch $arch

if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_RID"))) {
  $rid = if ($nodeArch -eq "arm64") { "win-arm64" } else { "win-x64" }
  [Environment]::SetEnvironmentVariable("CT_REMOTE_WINDOWS_SOURCE_RID", $rid, "Process")
}

$nodeDir = Join-Path $installRoot ("node\" + $toolchain["NODE_VERSION"] + "\node-v" + $toolchain["NODE_VERSION"] + "-win-" + $nodeArch)
$uvDir = Join-Path $installRoot ("uv\" + $toolchain["UV_VERSION"])
$dotnetPinnedVersion = $toolchain["DOTNET_SDK_VERSION"]
$msvcToolsetPinnedVersion = $toolchain["MSVC_TOOLSET_VERSION"]
$ttdMinVersion = $toolchain["TTD_MIN_VERSION"]
$windbgMinVersion = $toolchain["WINDBG_MIN_VERSION"]
[Environment]::SetEnvironmentVariable("DOTNET_SDK_VERSION", $dotnetPinnedVersion, "Process")
$dotnetRoot = Resolve-DotnetRoot -InstallRoot $installRoot -PinnedSdkVersion $dotnetPinnedVersion
$dotnetExe = Join-Path $dotnetRoot "dotnet.exe"
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_EXE", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_DIR", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_VERSION", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_REPLAY_DLL", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_REPLAY_CPU_DLL", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_WINDBG_DIR", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_WINDBG_VERSION", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_CDB_EXE", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_DBGENG_DLL", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_DBGMODEL_DLL", "", "Process")
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_DBGHELP_DLL", "", "Process")
[Environment]::SetEnvironmentVariable("TTD_MIN_VERSION", $ttdMinVersion, "Process")
[Environment]::SetEnvironmentVariable("WINDBG_MIN_VERSION", $windbgMinVersion, "Process")
$ttdRuntime = Resolve-TtdRuntimeInfo
$ttdExe = [string]$ttdRuntime["ttdExe"]
$cdbExe = [string]$ttdRuntime["cdbExe"]
$dbgengDll = [string]$ttdRuntime["dbgengDll"]
$dbgmodelDll = [string]$ttdRuntime["dbgmodelDll"]
$dbghelpDll = [string]$ttdRuntime["dbghelpDll"]
if (-not [string]::IsNullOrWhiteSpace($ttdExe)) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_EXE", $ttdExe, "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["ttdInstallDir"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_DIR", [string]$ttdRuntime["ttdInstallDir"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["ttdVersion"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_VERSION", [string]$ttdRuntime["ttdVersion"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["ttdReplayDll"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_REPLAY_DLL", [string]$ttdRuntime["ttdReplayDll"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["ttdReplayCpuDll"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_TTD_REPLAY_CPU_DLL", [string]$ttdRuntime["ttdReplayCpuDll"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["windbgInstallDir"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_WINDBG_DIR", [string]$ttdRuntime["windbgInstallDir"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["windbgVersion"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_WINDBG_VERSION", [string]$ttdRuntime["windbgVersion"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["cdbExe"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_CDB_EXE", [string]$ttdRuntime["cdbExe"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["dbgengDll"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DBGENG_DLL", [string]$ttdRuntime["dbgengDll"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["dbgmodelDll"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DBGMODEL_DLL", [string]$ttdRuntime["dbgmodelDll"], "Process")
}
if (-not [string]::IsNullOrWhiteSpace([string]$ttdRuntime["dbghelpDll"])) {
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_DBGHELP_DLL", [string]$ttdRuntime["dbghelpDll"], "Process")
}

$ensureTtd = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_ENSURE_TTD" -Default $true
if ($ensureTtd) {
  if ([string]::IsNullOrWhiteSpace($ttdExe)) {
    throw "Microsoft Time Travel Debugging is not available. Install with: winget install --id Microsoft.TimeTravelDebugging --exact --source winget"
  }
  if ([string]::IsNullOrWhiteSpace([string]$ttdRuntime["ttdReplayDll"])) {
    throw "TTDReplay.dll was not found. Ensure Microsoft.TimeTravelDebugging is correctly installed from winget."
  }
  if ([string]::IsNullOrWhiteSpace([string]$ttdRuntime["ttdVersion"])) {
    throw "Could not determine installed Microsoft.TimeTravelDebugging package version via Get-AppxPackage."
  }
  Assert-MinVersion -DisplayName "Microsoft.TimeTravelDebugging" -ActualVersion ([string]$ttdRuntime["ttdVersion"]) -MinVersion $ttdMinVersion -InstallHint "winget install --id Microsoft.TimeTravelDebugging --exact --source winget"
  if ([string]::IsNullOrWhiteSpace([string]$ttdRuntime["windbgVersion"])) {
    throw "Could not determine installed Microsoft.WinDbg package version via Get-AppxPackage. Install with: winget install --id Microsoft.WinDbg --exact --source winget"
  }
  Assert-MinVersion -DisplayName "Microsoft.WinDbg" -ActualVersion ([string]$ttdRuntime["windbgVersion"]) -MinVersion $windbgMinVersion -InstallHint "winget install --id Microsoft.WinDbg --exact --source winget"
}

[Environment]::SetEnvironmentVariable("DOTNET_SDK_VERSION_EFFECTIVE", $dotnetPinnedVersion, "Process")
$ensureDotnet = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_ENSURE_DOTNET" -Default $true
if ($ensureDotnet) {
  Assert-DotnetSdkPresent -DotnetExe $dotnetExe -PinnedSdkVersion $dotnetPinnedVersion
}
[Environment]::SetEnvironmentVariable("DOTNET_ROOT", $dotnetRoot, "Process")
$nodePackagesBin = Join-Path (Join-Path $repoRoot "node-packages") "node_modules\.bin"

$nimVersionRoot = Join-Path $installRoot ("nim\" + $toolchain["NIM_VERSION"])
$nimDir = Resolve-InstallDirFromRelativePathFile -InstallRoot $installRoot -RelativePathFile (Join-Path $nimVersionRoot "nim.install.relative-path")
if ([string]::IsNullOrWhiteSpace($nimDir)) {
  $prebuiltNim = Join-Path $nimVersionRoot ("prebuilt\nim-" + $toolchain["NIM_VERSION"])
  if (Test-Path -LiteralPath $prebuiltNim -PathType Container) {
    $nimDir = $prebuiltNim
  } else {
    $nimDir = Join-Path $nimVersionRoot ("nim-" + $toolchain["NIM_VERSION"])
  }
}
$nim1 = Join-Path $nimDir "bin\nim.exe"
$nimLegacyPrebuiltBinDir = Join-Path $nimVersionRoot ("prebuilt\nim-" + $toolchain["NIM_VERSION"] + "\bin")

$ctRemoteDir = Join-Path $installRoot ("ct-remote\" + $toolchain["CT_REMOTE_VERSION"])

$capnpVersionRoot = Join-Path $installRoot ("capnp\" + $toolchain["CAPNP_VERSION"])
$capnpDir = Resolve-InstallDirFromRelativePathFile -InstallRoot $installRoot -RelativePathFile (Join-Path $capnpVersionRoot "capnp.install.relative-path")
if ([string]::IsNullOrWhiteSpace($capnpDir)) {
  $prebuiltCapnp = Join-Path $capnpVersionRoot ("prebuilt\capnproto-tools-win32-" + $toolchain["CAPNP_VERSION"])
  if (Test-Path -LiteralPath $prebuiltCapnp -PathType Container) {
    $capnpDir = $prebuiltCapnp
  } else {
    $capnpDir = Join-Path $capnpVersionRoot ("capnproto-tools-win32-" + $toolchain["CAPNP_VERSION"])
  }
}
$capnpBinDir = Join-Path $capnpDir "bin"
if (-not (Test-Path -LiteralPath $capnpBinDir -PathType Container)) {
  $capnpBinDir = $capnpDir
}

$tupRoot = Join-Path $installRoot "tup"
$tupDir = Resolve-InstallDirFromRelativePathFile -InstallRoot $installRoot -RelativePathFile (Join-Path $tupRoot "tup.install.relative-path")
if ([string]::IsNullOrWhiteSpace($tupDir)) {
  $fallbackCurrent = Join-Path $tupRoot "current"
  if (Test-Path -LiteralPath $fallbackCurrent -PathType Container) {
    $tupDir = $fallbackCurrent
  } else {
    $tupDir = $tupRoot
  }
}
$tupExe = Join-Path $tupDir "tup.exe"
$tupMsys2MingwBin = Join-Path $installRoot ("tup\msys2\" + [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_VERSION") + "\msys64\mingw64\bin")
$shimsDir = Join-Path $installRoot "shims"

$nargoRoot = Join-Path $installRoot "nargo"
$nargoDir = Resolve-InstallDirFromRelativePathFile -InstallRoot $installRoot -RelativePathFile (Join-Path $nargoRoot "nargo.install.relative-path")

$gccDir = Join-Path $installRoot ("gcc\" + $toolchain["GCC_VERSION"])
$gccBinDir = Join-Path $gccDir "bin"

$gnatVersion = if (-not [string]::IsNullOrWhiteSpace($toolchain["GNAT_VERSION"])) { $toolchain["GNAT_VERSION"] } else { $toolchain["GCC_VERSION"] }
$gnatDir = Join-Path $installRoot ("gnat\" + $gnatVersion)
$gnatBinDir = Join-Path $gnatDir "bin"

$goDir = Join-Path $installRoot ("go\" + $toolchain["GO_VERSION"] + "\go")
$goBinDir = Join-Path $goDir "bin"

$ldcArch = ConvertTo-LdcFileArch -Arch $arch
$ldcDir = Join-Path $installRoot ("ldc\" + $toolchain["LDC_VERSION"] + "\ldc2-" + $toolchain["LDC_VERSION"] + "-windows-" + $ldcArch)
$ldcBinDir = Join-Path $ldcDir "bin"

$vlangDir = Join-Path $installRoot ("vlang\" + $toolchain["VLANG_VERSION"] + "\v")
$vlangBinDir = $vlangDir

$fpcDir = Join-Path $installRoot ("fpc\" + $toolchain["FPC_VERSION"])
$fpcBinDir = Join-Path $fpcDir "bin/x86_64-win64"

$zstdArch = ConvertTo-ZstdFileArch -Arch $arch
$zstdDir = Join-Path $installRoot ("zstd\" + $toolchain["ZSTD_VERSION"] + "\zstd-v" + $toolchain["ZSTD_VERSION"] + "-" + $zstdArch)

# zlib install layout is `$installRoot/zlib/<version>/{include,lib}/`. Both
# subdirs must be added to the toolchain search paths so the MinGW linker can
# resolve `-lz` (see `src/Tuprules.tup`'s WINDOWS_ZLIB_DIR pin) and so any
# build that consults `LIBRARY_PATH`/`C_INCLUDE_PATH` finds the headers.
$zlibDir = Join-Path $installRoot ("zlib\" + $toolchain["ZLIB_VERSION"])
$zlibIncludeDir = Join-Path $zlibDir "include"
$zlibLibDir = Join-Path $zlibDir "lib"

$llvmTarget = ConvertTo-LlvmFileArch -Arch $arch
$llvmDir = Join-Path $installRoot ("llvm\" + $toolchain["LLVM_VERSION"] + "\LLVM-" + $toolchain["LLVM_VERSION"] + "-" + $llvmTarget)
$llvmBinDir = Join-Path $llvmDir "bin"

# Clingo install layout produced by ensure-clingo.ps1:
#   $installRoot/clingo/<version>/bin/clingo.dll
# `repro` and `extract_runner.exe` dlopen `clingo.dll` by leaf name; putting
# the bin dir on PATH is what lets the Win32 loader resolve it.
$clingoDir = Join-Path $installRoot ("clingo\" + $toolchain["CLINGO_VERSION"])
$clingoBinDir = Join-Path $clingoDir "bin"

# Ensure-NodeTooling shells out to npx.cmd under $nodeDir to run `yarn install`
# in node-packages/ when the stylus/webpack shims aren't yet on disk. When the
# bootstrap phase is skipped (WINDOWS_DIY_SYNC=0, e.g. on hosted GHA Windows
# Server 2022 runners — see workflow `value-origin-windows.yml`), Ensure-Node
# never runs, so $nodeDir\npx.cmd doesn't exist and the function throws,
# preventing the entire env.ps1 source. Gate it behind the same $doSync flag
# that gates the Phase 1 Ensure-Node bootstrap (this mirrors the existing
# `WINDOWS_DIY_ENSURE_TTD=0` discipline around heavy installers).
#
# Callers that explicitly want Node deps without the full bootstrap can still
# set WINDOWS_DIY_SETUP_NODE_DEPS=1 + WINDOWS_DIY_SYNC=0 + a pre-populated
# nodeDir; in that case they should drive `cd node-packages; npx yarn install`
# manually after sourcing env.ps1. Ensure-NodeModulesJunction and
# Ensure-GoldenLayoutAsset are already silent no-ops when their targets don't
# exist, so they stay unconditional.
if ($doSync) {
  Ensure-NodeTooling -RepoRoot $repoRoot -NodePackagesBin $nodePackagesBin -NodeDir $nodeDir
}
Ensure-NodeModulesJunction -RepoRoot $repoRoot
Ensure-GoldenLayoutAsset -RepoRoot $repoRoot

$msvcBlob = & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $windowsDir "export-msvc-env.ps1")
foreach ($line in $msvcBlob) {
  if ($line -notmatch '^([^=]+)=(.*)$') {
    continue
  }
  $key = $matches[1]
  $value = $matches[2]
  switch ($key) {
    "PATH" {
      [Environment]::SetEnvironmentVariable("PATH", $value, "Process")
    }
    "Path" {
      [Environment]::SetEnvironmentVariable("PATH", $value, "Process")
    }
    default {
      [Environment]::SetEnvironmentVariable($key, $value, "Process")
    }
  }
}

# Put the Visual Studio Installer directory on PATH so child build
# processes (cargo's cc-rs, MSYS2 sub-builds such as the nargo bootstrap,
# etc.) can resolve a bare `vswhere.exe` — several toolchains invoke it
# without a full path and otherwise fail with "'vswhere.exe' is not
# recognized".
$vsInstallerDir = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer"
if (Test-Path -LiteralPath (Join-Path $vsInstallerDir "vswhere.exe") -PathType Leaf) {
  Prepend-PathEntries -Entries @($vsInstallerDir)
}

function Resolve-ClExePath {
  $cmd = Get-Command cl.exe -ErrorAction SilentlyContinue
  if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace($cmd.Source)) {
    return $cmd.Source
  }

  $msvcBinDir = [Environment]::GetEnvironmentVariable("MSVC_BIN_DIR")
  if (-not [string]::IsNullOrWhiteSpace($msvcBinDir)) {
    $candidate = Join-Path $msvcBinDir "cl.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      Prepend-PathEntries -Entries @($msvcBinDir)
      return $candidate
    }
  }

  return ""
}

[Environment]::SetEnvironmentVariable("CARGO_TARGET_AARCH64_PC_WINDOWS_MSVC_LINKER", "link.exe", "Process")
[Environment]::SetEnvironmentVariable("CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_LINKER", "link.exe", "Process")
[Environment]::SetEnvironmentVariable("CC", "cl", "Process")
[Environment]::SetEnvironmentVariable("CXX", "cl", "Process")
[Environment]::SetEnvironmentVariable("CT_NIM_CC_FLAGS", "--cc:gcc", "Process")
[Environment]::SetEnvironmentVariable("NIM1", $nim1, "Process")
[Environment]::SetEnvironmentVariable("CAPNP_DIR", $capnpDir, "Process")
[Environment]::SetEnvironmentVariable("TUP_DIR", $tupDir, "Process")
[Environment]::SetEnvironmentVariable("TUP", $tupExe, "Process")
[Environment]::SetEnvironmentVariable("NARGO_DIR", $nargoDir, "Process")
[Environment]::SetEnvironmentVariable("GCC_DIR", $gccDir, "Process")
[Environment]::SetEnvironmentVariable("GNAT_DIR", $gnatDir, "Process")
[Environment]::SetEnvironmentVariable("GO_DIR", $goDir, "Process")
[Environment]::SetEnvironmentVariable("GOROOT", $goDir, "Process")
[Environment]::SetEnvironmentVariable("LDC_DIR", $ldcDir, "Process")
[Environment]::SetEnvironmentVariable("VLANG_DIR", $vlangDir, "Process")
[Environment]::SetEnvironmentVariable("FPC_DIR", $fpcDir, "Process")
[Environment]::SetEnvironmentVariable("ZSTD_DIR", $zstdDir, "Process")
[Environment]::SetEnvironmentVariable("ZLIB_DIR", $zlibDir, "Process")
[Environment]::SetEnvironmentVariable("CLINGO_DIR", $clingoDir, "Process")
# Prepend the zlib lib dir to LIBRARY_PATH so the MinGW gcc linker finds
# `libz.a` when codetracer's Nim build emits `-lz` via Tuprules.tup. PATH gets
# the same dir below (mirrors how ZSTD_DIR is consumed downstream) for any
# build that resolves runtime DLLs from the same install root layout.
$existingLibraryPath = [Environment]::GetEnvironmentVariable("LIBRARY_PATH")
if ([string]::IsNullOrWhiteSpace($existingLibraryPath)) {
  [Environment]::SetEnvironmentVariable("LIBRARY_PATH", $zlibLibDir, "Process")
} elseif ($existingLibraryPath -notlike "*$zlibLibDir*") {
  [Environment]::SetEnvironmentVariable("LIBRARY_PATH", ($zlibLibDir + ";" + $existingLibraryPath), "Process")
}
$existingCIncludePath = [Environment]::GetEnvironmentVariable("C_INCLUDE_PATH")
if ([string]::IsNullOrWhiteSpace($existingCIncludePath)) {
  [Environment]::SetEnvironmentVariable("C_INCLUDE_PATH", $zlibIncludeDir, "Process")
} elseif ($existingCIncludePath -notlike "*$zlibIncludeDir*") {
  [Environment]::SetEnvironmentVariable("C_INCLUDE_PATH", ($zlibIncludeDir + ";" + $existingCIncludePath), "Process")
}
# LLVM_CONFIG and LLDB_LIB_PATH are used by the lldb-sys crate's build.rs
# to locate the LLDB shared library and LLVM headers for FFI compilation.
$llvmConfigExe = Join-Path $llvmBinDir "llvm-config.exe"
if (Test-Path -LiteralPath $llvmConfigExe -PathType Leaf) {
  [Environment]::SetEnvironmentVariable("LLVM_CONFIG", $llvmConfigExe, "Process")
}
$llvmLibDir = Join-Path $llvmDir "lib"
if (Test-Path -LiteralPath $llvmLibDir -PathType Container) {
  [Environment]::SetEnvironmentVariable("LLDB_LIB_PATH", $llvmLibDir, "Process")
}
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_SHIMS_DIR", $shimsDir, "Process")

$clExe = Resolve-ClExePath
if ([string]::IsNullOrWhiteSpace($clExe)) {
  throw "cl.exe was not found on PATH and MSVC_BIN_DIR did not resolve it. Install Visual Studio Build Tools with the MSVC toolchain (e.g., 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' or 'Microsoft.VisualStudio.Component.VC.Tools.ARM64')."
}
[Environment]::SetEnvironmentVariable("WINDOWS_DIY_CL_EXE", $clExe, "Process")
if (-not [string]::IsNullOrWhiteSpace($msvcToolsetPinnedVersion)) {
  $actualMsvcToolsetVersion = Resolve-MsvcToolsetVersion
  Assert-MsvcToolsetVersion -ActualVersion $actualMsvcToolsetVersion -PinnedVersion $msvcToolsetPinnedVersion
  [Environment]::SetEnvironmentVariable("WINDOWS_DIY_MSVC_TOOLSET_VERSION", $actualMsvcToolsetVersion, "Process")
}

# In PowerShell, prefer native executables over extensionless bash shims.
Set-ExecutableAliasIfPresent -Name "tup" -ExePath $tupExe
Set-ExecutableAliasIfPresent -Name "dotnet" -ExePath (Join-Path $dotnetRoot "dotnet.exe")
Set-ExecutableAliasIfPresent -Name "node" -ExePath (Join-Path $nodeDir "node.exe")
Set-ExecutableAliasIfPresent -Name "npm" -ExePath (Join-Path $nodeDir "npm.exe")
Set-ExecutableAliasIfPresent -Name "npx" -ExePath (Join-Path $nodeDir "npx.exe")
Set-ExecutableAliasIfPresent -Name "uv" -ExePath (Join-Path $uvDir "uv.exe")
Set-ExecutableAliasIfPresent -Name "capnp" -ExePath (Join-Path $capnpBinDir "capnp.exe")
Set-ExecutableAliasIfPresent -Name "nim" -ExePath $nim1
Set-ExecutableAliasIfPresent -Name "ct-remote" -ExePath (Join-Path $ctRemoteDir "ct-remote.exe")
Set-ExecutableAliasIfPresent -Name "cargo" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\\cargo.exe")
Set-ExecutableAliasIfPresent -Name "rustc" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\\rustc.exe")
Set-ExecutableAliasIfPresent -Name "rustup" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\\rustup.exe")
Set-ExecutableAliasIfPresent -Name "just" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\\just.exe")
Set-ExecutableAliasIfPresent -Name "cargo-nextest" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\\cargo-nextest.exe")
Set-ExecutableAliasIfPresent -Name "cl" -ExePath $clExe
Set-ExecutableAliasIfPresent -Name "gcc" -ExePath (Join-Path $gccBinDir "gcc.exe")
Set-ExecutableAliasIfPresent -Name "g++" -ExePath (Join-Path $gccBinDir "g++.exe")
Set-ExecutableAliasIfPresent -Name "gdb" -ExePath (Join-Path $gccBinDir "gdb.exe")
Set-ExecutableAliasIfPresent -Name "gfortran" -ExePath (Join-Path $gccBinDir "gfortran.exe")
Set-ExecutableAliasIfPresent -Name "gnatmake" -ExePath (Join-Path $gnatBinDir "gnatmake.exe")
Set-ExecutableAliasIfPresent -Name "go" -ExePath (Join-Path $goBinDir "go.exe")
Set-ExecutableAliasIfPresent -Name "ldc2" -ExePath (Join-Path $ldcBinDir "ldc2.exe")
Set-ExecutableAliasIfPresent -Name "dub" -ExePath (Join-Path $ldcBinDir "dub.exe")
Set-ExecutableAliasIfPresent -Name "rdmd" -ExePath (Join-Path $ldcBinDir "rdmd.exe")
Set-ExecutableAliasIfPresent -Name "v" -ExePath (Join-Path $vlangBinDir "v.exe")
Set-ExecutableAliasIfPresent -Name "fpc" -ExePath (Join-Path $fpcBinDir "fpc.exe")
Set-ExecutableAliasIfPresent -Name "clang" -ExePath (Join-Path $llvmBinDir "clang.exe")
Set-ExecutableAliasIfPresent -Name "clang++" -ExePath (Join-Path $llvmBinDir "clang++.exe")
Set-ExecutableAliasIfPresent -Name "lldb" -ExePath (Join-Path $llvmBinDir "lldb.exe")
Set-ExecutableAliasIfPresent -Name "llvm-config" -ExePath (Join-Path $llvmBinDir "llvm-config.exe")
if (-not [string]::IsNullOrWhiteSpace($ttdExe)) {
  Set-ExecutableAliasIfPresent -Name "ttd" -ExePath $ttdExe
}
if (-not [string]::IsNullOrWhiteSpace($cdbExe)) {
  Set-ExecutableAliasIfPresent -Name "cdb" -ExePath $cdbExe
}

New-Item -ItemType Directory -Force -Path $shimsDir | Out-Null
New-BashExeShim -ShimsDir $shimsDir -CommandName "tup" -ExePath $tupExe
New-BashExeShim -ShimsDir $shimsDir -CommandName "dotnet" -ExePath (Join-Path $dotnetRoot "dotnet.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "node" -ExePath (Join-Path $nodeDir "node.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "npm" -ExePath (Join-Path $nodeDir "npm.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "npx" -ExePath (Join-Path $nodeDir "npx.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "uv" -ExePath (Join-Path $uvDir "uv.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "capnp" -ExePath (Join-Path $capnpBinDir "capnp.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "capnpc-c++" -ExePath (Join-Path $capnpBinDir "capnpc-c++.exe")
if (-not [string]::IsNullOrWhiteSpace($nargoDir)) {
  New-BashExeShim -ShimsDir $shimsDir -CommandName "nargo" -ExePath (Join-Path $nargoDir "nargo.exe")
}
New-BashExeShim -ShimsDir $shimsDir -CommandName "nim" -ExePath $nim1
New-BashExeShim -ShimsDir $shimsDir -CommandName "ct-remote" -ExePath (Join-Path $ctRemoteDir "ct-remote.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "cargo" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\cargo.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "rustc" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\rustc.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "rustup" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\rustup.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "just" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\just.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "cargo-nextest" -ExePath (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin\cargo-nextest.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "cl" -ExePath $clExe
if (-not [string]::IsNullOrWhiteSpace($ttdExe)) {
  New-BashExeShim -ShimsDir $shimsDir -CommandName "ttd" -ExePath $ttdExe
}
if (-not [string]::IsNullOrWhiteSpace($cdbExe)) {
  New-BashExeShim -ShimsDir $shimsDir -CommandName "cdb" -ExePath $cdbExe
}
New-BashExeShim -ShimsDir $shimsDir -CommandName "gcc" -ExePath (Join-Path $gccBinDir "gcc.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "g++" -ExePath (Join-Path $gccBinDir "g++.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "gdb" -ExePath (Join-Path $gccBinDir "gdb.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "gfortran" -ExePath (Join-Path $gccBinDir "gfortran.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "gnatmake" -ExePath (Join-Path $gnatBinDir "gnatmake.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "go" -ExePath (Join-Path $goBinDir "go.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "ldc2" -ExePath (Join-Path $ldcBinDir "ldc2.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "dub" -ExePath (Join-Path $ldcBinDir "dub.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "rdmd" -ExePath (Join-Path $ldcBinDir "rdmd.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "v" -ExePath (Join-Path $vlangBinDir "v.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "fpc" -ExePath (Join-Path $fpcBinDir "fpc.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "clang" -ExePath (Join-Path $llvmBinDir "clang.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "clang++" -ExePath (Join-Path $llvmBinDir "clang++.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "lldb" -ExePath (Join-Path $llvmBinDir "lldb.exe")
New-BashExeShim -ShimsDir $shimsDir -CommandName "llvm-config" -ExePath (Join-Path $llvmBinDir "llvm-config.exe")

Prepend-PathEntries -Entries @(
  $(if (-not [string]::IsNullOrWhiteSpace($ttdExe)) { Split-Path -Parent $ttdExe }),
  $(if (-not [string]::IsNullOrWhiteSpace($cdbExe)) { Split-Path -Parent $cdbExe }),
  $(if (-not [string]::IsNullOrWhiteSpace($dbgengDll)) { Split-Path -Parent $dbgengDll }),
  $tupMsys2MingwBin,
  $dotnetRoot,
  $nodePackagesBin,
  $shimsDir,
  (Join-Path ([Environment]::GetEnvironmentVariable("CARGO_HOME")) "bin"),
  $nodeDir,
  $uvDir,
  $nimLegacyPrebuiltBinDir,
  (Join-Path $nimDir "bin"),
  $ctRemoteDir,
  $capnpBinDir,
  $capnpDir,
  $tupDir,
  $nargoDir,
  $gccBinDir,
  $gnatBinDir,
  $goBinDir,
  $ldcBinDir,
  $vlangBinDir,
  $fpcBinDir,
  $llvmBinDir,
  $zlibLibDir,
  $clingoBinDir
)

$ensureParser = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER" -Default $true
if ($ensureParser) {
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($null -eq $bash) {
    throw "WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER=1 but 'bash' is not available on PATH."
  }
  # Pass a forward-slash path: bash reads `\m`, `\c`, ... in a `D:\...`
  # argument as escape sequences and strips the separators, so the script
  # path arrived mangled (`D:metacraftcodetracer...sh: No such file`) and
  # parser regeneration was silently skipped. MSYS/Git bash opens a
  # `D:/...` path fine.
  $tsParserScript = (Join-Path (Split-Path -Parent $windowsDir) "ensure_tree_sitter_nim_parser.sh") -replace '\\', '/'
  & $bash.Source $tsParserScript
}

& (Join-Path $windowsDir "setup-codetracer-runtime-env.ps1") -RepoRoot $repoRoot

# Keep shims first-class after runtime setup path mutations.
Prepend-PathEntries -Entries @($shimsDir)

Write-Host "WINDOWS_DIY_INSTALL_ROOT=$installRoot"
Write-Host "RUSTUP_HOME=$env:RUSTUP_HOME"
Write-Host "CARGO_HOME=$env:CARGO_HOME"
Write-Host "NODE_DIR=$nodeDir"
Write-Host "UV_DIR=$uvDir"
Write-Host "DOTNET_SDK_VERSION=$dotnetPinnedVersion"
Write-Host "DOTNET_SDK_VERSION_EFFECTIVE=$env:DOTNET_SDK_VERSION_EFFECTIVE"
Write-Host "DOTNET_ROOT=$env:DOTNET_ROOT"
Write-Host "MSVC_TOOLSET_VERSION=$msvcToolsetPinnedVersion"
Write-Host "WINDOWS_DIY_MSVC_TOOLSET_VERSION=$env:WINDOWS_DIY_MSVC_TOOLSET_VERSION"
Write-Host "WINDBG_MIN_VERSION=$env:WINDBG_MIN_VERSION"
Write-Host "WINDOWS_DIY_WINDBG_VERSION=$env:WINDOWS_DIY_WINDBG_VERSION"
Write-Host "WINDOWS_DIY_WINDBG_DIR=$env:WINDOWS_DIY_WINDBG_DIR"
Write-Host "TTD_MIN_VERSION=$env:TTD_MIN_VERSION"
Write-Host "WINDOWS_DIY_TTD_VERSION=$env:WINDOWS_DIY_TTD_VERSION"
Write-Host "WINDOWS_DIY_TTD_DIR=$env:WINDOWS_DIY_TTD_DIR"
Write-Host "WINDOWS_DIY_TTD_REPLAY_DLL=$env:WINDOWS_DIY_TTD_REPLAY_DLL"
Write-Host "WINDOWS_DIY_TTD_REPLAY_CPU_DLL=$env:WINDOWS_DIY_TTD_REPLAY_CPU_DLL"
Write-Host "WINDOWS_DIY_CDB_EXE=$env:WINDOWS_DIY_CDB_EXE"
Write-Host "WINDOWS_DIY_DBGENG_DLL=$env:WINDOWS_DIY_DBGENG_DLL"
Write-Host "WINDOWS_DIY_DBGMODEL_DLL=$env:WINDOWS_DIY_DBGMODEL_DLL"
Write-Host "WINDOWS_DIY_DBGHELP_DLL=$env:WINDOWS_DIY_DBGHELP_DLL"
Write-Host "NIM_DIR=$nimDir"
Write-Host "NIM1=$nim1"
Write-Host "CT_NIM_CC_FLAGS=$env:CT_NIM_CC_FLAGS"
Write-Host "CT_REMOTE_DIR=$ctRemoteDir"
Write-Host "CT_REMOTE_WINDOWS_SOURCE_MODE=$env:CT_REMOTE_WINDOWS_SOURCE_MODE"
Write-Host "CT_REMOTE_WINDOWS_SOURCE_REPO=$env:CT_REMOTE_WINDOWS_SOURCE_REPO"
Write-Host "CT_REMOTE_WINDOWS_SOURCE_RID=$env:CT_REMOTE_WINDOWS_SOURCE_RID"
Write-Host "CAPNP_WINDOWS_SOURCE_MODE=$env:CAPNP_WINDOWS_SOURCE_MODE"
Write-Host "CAPNP_WINDOWS_SOURCE_REPO=$env:CAPNP_WINDOWS_SOURCE_REPO"
Write-Host "CAPNP_WINDOWS_SOURCE_REF=$env:CAPNP_WINDOWS_SOURCE_REF"
Write-Host "CAPNP_DIR=$capnpDir"
Write-Host "TUP_WINDOWS_SOURCE_MODE=$env:TUP_WINDOWS_SOURCE_MODE"
Write-Host "TUP_WINDOWS_SOURCE_REPO=$env:TUP_WINDOWS_SOURCE_REPO"
Write-Host "TUP_WINDOWS_SOURCE_REF=$env:TUP_WINDOWS_SOURCE_REF"
Write-Host "TUP_WINDOWS_SOURCE_BUILD_COMMAND=$env:TUP_WINDOWS_SOURCE_BUILD_COMMAND"
Write-Host "TUP_WINDOWS_PREBUILT_VERSION=$env:TUP_WINDOWS_PREBUILT_VERSION"
Write-Host "TUP_WINDOWS_PREBUILT_URL=$env:TUP_WINDOWS_PREBUILT_URL"
Write-Host "TUP_WINDOWS_PREBUILT_SHA256=$env:TUP_WINDOWS_PREBUILT_SHA256"
Write-Host "TUP_WINDOWS_MSYS2_BASE_VERSION=$env:TUP_WINDOWS_MSYS2_BASE_VERSION"
Write-Host "TUP_WINDOWS_MSYS2_PACKAGES=$env:TUP_WINDOWS_MSYS2_PACKAGES"
Write-Host "TUP_DIR=$tupDir"
Write-Host "TUP=$tupExe"
Write-Host "NARGO_DIR=$nargoDir"
Write-Host "GCC_DIR=$gccDir"
Write-Host "GO_DIR=$goDir"
Write-Host "GOROOT=$env:GOROOT"
Write-Host "ZSTD_DIR=$zstdDir"
Write-Host "ZLIB_DIR=$zlibDir"
Write-Host "CLINGO_DIR=$clingoDir"
Write-Host "LLVM_DIR=$llvmDir"
Write-Host "WINDOWS_DIY_SHIMS_DIR=$shimsDir"
Write-Host "CODETRACER_REPO_ROOT_PATH=$env:CODETRACER_REPO_ROOT_PATH"
Write-Host "CODETRACER_PREFIX=$env:CODETRACER_PREFIX"
Write-Host "CODETRACER_E2E_CT_PATH=$env:CODETRACER_E2E_CT_PATH"
Write-Host "WINDOWS_DIY_GIT_BASH_BIN=$env:WINDOWS_DIY_GIT_BASH_BIN"
Write-Host "WINDOWS_DIY_TTD_EXE=$env:WINDOWS_DIY_TTD_EXE"
Write-Host "WINDOWS_DIY_CL_EXE=$env:WINDOWS_DIY_CL_EXE"
