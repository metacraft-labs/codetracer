[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-RepoRoot {
  $windowsDir = Split-Path -Parent $PSCommandPath
  $nonNixBuildDir = Split-Path -Parent $windowsDir
  return (Split-Path -Parent $nonNixBuildDir)
}

function Get-DefaultInstallRoot {
  $envInstallRoot = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_INSTALL_ROOT")
  if (-not [string]::IsNullOrWhiteSpace($envInstallRoot)) {
    return $envInstallRoot.Trim()
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

function Get-WindowsArch {
  $systemType = (Get-CimInstance Win32_ComputerSystem).SystemType.ToLowerInvariant()
  if ($systemType.Contains("arm64")) { return "arm64" }
  if ($systemType.Contains("x64") -or $systemType.Contains("x86_64")) { return "x64" }
  throw "Unsupported Windows architecture '$systemType'."
}

function Get-NodeArch {
  param([string]$WindowsArch)
  switch ($WindowsArch) {
    "arm64" { return "arm64" }
    "x64" { return "x64" }
    default { throw "Unsupported Node architecture mapping '$WindowsArch'." }
  }
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

  throw "Could not find dotnet.exe. Expected one of: WINDOWS_DIY_DOTNET_ROOT, '$InstallRoot\\dotnet\\$PinnedSdkVersion', or '$($env:ProgramFiles)\\dotnet'. Install with: winget install --id Microsoft.DotNet.SDK.9 --exact --source winget"
}

function Resolve-TtdExe {
  $candidates = @()
  $override = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_TTD_EXE")
  if (-not [string]::IsNullOrWhiteSpace($override)) {
    $candidates += $override.Trim()
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
  if ($null -ne $ttdPackage) {
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
    [Parameter(Mandatory = $true)][string]$NodePackagesBin
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

  Write-Host "Windows DIY: Node deps missing, running yarn install in node-packages..."
  $nodePackagesDir = Join-Path $RepoRoot "node-packages"
  Push-Location $nodePackagesDir
  try {
    $lockFile = Join-Path $nodePackagesDir "yarn.lock"
    if (Test-Path -LiteralPath $lockFile -PathType Leaf) {
      & npx yarn install --frozen-lockfile
    } else {
      & npx yarn install
    }
  } finally {
    Pop-Location
  }

  if ((-not (Test-Path -LiteralPath $stylusCmd -PathType Leaf)) -or (-not (Test-Path -LiteralPath $webpackCmd -PathType Leaf))) {
    throw "Node dependency setup finished but stylus/webpack commands are still missing under '$NodePackagesBin'."
  }
}

function Prepend-PathEntries {
  param([Parameter(Mandatory = $true)][string[]]$Entries)
  $existing = [Environment]::GetEnvironmentVariable("PATH")
  $prefix = @()
  foreach ($entry in $Entries) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if (-not (Test-Path -LiteralPath $entry)) { continue }
    $prefix += $entry
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

$windowsDir = Split-Path -Parent $PSCommandPath
$repoRoot = Get-RepoRoot
$toolchainPath = Join-Path $windowsDir "toolchain-versions.env"
$toolchain = Parse-ToolchainVersions -Path $toolchainPath

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
  & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $windowsDir "bootstrap-windows-diy.ps1") -InstallRoot $installRoot
}

$arch = Get-WindowsArch
$nodeArch = Get-NodeArch -WindowsArch $arch

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

Ensure-NodeTooling -RepoRoot $repoRoot -NodePackagesBin $nodePackagesBin

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
Set-ExecutableAliasIfPresent -Name "cl" -ExePath $clExe
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
New-BashExeShim -ShimsDir $shimsDir -CommandName "cl" -ExePath $clExe
if (-not [string]::IsNullOrWhiteSpace($ttdExe)) {
  New-BashExeShim -ShimsDir $shimsDir -CommandName "ttd" -ExePath $ttdExe
}
if (-not [string]::IsNullOrWhiteSpace($cdbExe)) {
  New-BashExeShim -ShimsDir $shimsDir -CommandName "cdb" -ExePath $cdbExe
}

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
  $nargoDir
)

$ensureParser = ConvertTo-BoolFromEnv -Name "WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER" -Default $true
if ($ensureParser) {
  $bash = Get-Command bash -ErrorAction SilentlyContinue
  if ($null -eq $bash) {
    throw "WINDOWS_DIY_ENSURE_TREE_SITTER_NIM_PARSER=1 but 'bash' is not available on PATH."
  }
  & $bash.Source (Join-Path (Split-Path -Parent $windowsDir) "ensure_tree_sitter_nim_parser.sh")
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
Write-Host "WINDOWS_DIY_SHIMS_DIR=$shimsDir"
Write-Host "CODETRACER_REPO_ROOT_PATH=$env:CODETRACER_REPO_ROOT_PATH"
Write-Host "NIX_CODETRACER_EXE_DIR=$env:NIX_CODETRACER_EXE_DIR"
Write-Host "LINKS_PATH_DIR=$env:LINKS_PATH_DIR"
Write-Host "CODETRACER_E2E_CT_PATH=$env:CODETRACER_E2E_CT_PATH"
Write-Host "CODETRACER_CT_PATHS=$env:CODETRACER_CT_PATHS"
Write-Host "WINDOWS_DIY_GIT_BASH_BIN=$env:WINDOWS_DIY_GIT_BASH_BIN"
Write-Host "WINDOWS_DIY_TTD_EXE=$env:WINDOWS_DIY_TTD_EXE"
Write-Host "WINDOWS_DIY_CL_EXE=$env:WINDOWS_DIY_CL_EXE"
