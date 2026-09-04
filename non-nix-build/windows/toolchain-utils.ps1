Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# HOW LONG A SINGLE TOOLCHAIN DOWNLOAD MAY BLOCK BEFORE IT IS A FAILURE.
#
# `Invoke-WebRequest` has NO default timeout: `-TimeoutSec` unset means
# infinite, and under `pwsh` (HttpClient) the value covers the whole transfer,
# body included -- not just the response headers. Every toolchain in this file
# is fetched through `Download-File` / `Download-String`, so before this
# constant existed a single stalled socket parked the ENTIRE Windows dev-env
# bootstrap forever. `Invoke-WithRetry` did not help: it bounds the number of
# attempts (4), never the duration of one, so 4 x infinite is still infinite.
#
# This is not theoretical. On 2026-09-04 run 33880354195, `windows-rust-components`
# sat in `Setup dev env` from 14:37:32 to 20:05:35 and `origin-DAP (materialized
# Python, Windows)` sat in `Setup db-backend siblings` from 14:20:59 to
# 20:05:50 -- both released only by GitHub's DEFAULT 360-minute job timeout,
# because neither job sets `timeout-minutes` either. For those six hours they
# held the `Codetracer CI-dev` concurrency group `in_progress`, which is what
# starved every other verdict on the branch.
#
# The value has to clear the largest asset this bootstrap pulls: the WinDbg
# msixbundle in ensure-ttd.ps1 is ~767 MB, so a total-transfer budget of a few
# minutes would convert a slow link into a spurious red. 30 minutes is ~0.4 MB/s
# sustained for that asset -- far below any healthy runner, far above a socket
# that has stopped moving. Override for a genuinely slow network with
# WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS; 0 restores the old infinite behaviour
# and is deliberately spelled as an opt-in rather than left as the default.
function Get-DownloadTimeoutSeconds {
  $raw = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS")
  if ([string]::IsNullOrWhiteSpace($raw)) { return 1800 }

  $parsed = 0
  if (-not [int]::TryParse($raw.Trim(), [ref]$parsed) -or $parsed -lt 0) {
    throw "WINDOWS_DIY_DOWNLOAD_TIMEOUT_SECONDS must be a non-negative integer (got '$raw')."
  }
  return $parsed
}

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$Script,
    [int]$Attempts = 4,
    [int]$DelaySeconds = 2
  )

  for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
    try {
      return & $Script
    } catch {
      if ($attempt -ge $Attempts) {
        throw
      }
      Start-Sleep -Seconds ($DelaySeconds * $attempt)
    }
  }
}

function Get-WindowsArch {
  $overrideRaw = [Environment]::GetEnvironmentVariable("WINDOWS_DIY_ARCH_OVERRIDE")
  if (-not [string]::IsNullOrWhiteSpace($overrideRaw)) {
    $override = $overrideRaw.Trim().ToLowerInvariant()
    switch ($override) {
      "x64" {
        Write-Warning "WINDOWS_DIY_ARCH_OVERRIDE=x64 is forcing architecture detection."
        return "x64"
      }
      "arm64" {
        Write-Warning "WINDOWS_DIY_ARCH_OVERRIDE=arm64 is forcing architecture detection."
        return "arm64"
      }
      default {
        throw "Unsupported WINDOWS_DIY_ARCH_OVERRIDE value '$overrideRaw'. Supported values: x64, arm64."
      }
    }
  }

  $systemType = (Get-CimInstance Win32_ComputerSystem).SystemType.ToLowerInvariant()
  if ($systemType.Contains("arm64")) { return "arm64" }
  if ($systemType.Contains("x64") -or $systemType.Contains("x86_64")) { return "x64" }
  throw "Unsupported Windows architecture '$systemType'."
}

function Get-ExpectedSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$ShaSource,
    [Parameter(Mandatory = $true)][string]$AssetName
  )

  foreach ($line in ($ShaSource -split "`n")) {
    $trimmed = $line.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
      continue
    }

    if ($trimmed -match "^(?<hash>[A-Fa-f0-9]{64})\s+\*?(?<name>.+)$") {
      if ($Matches.name.Trim() -eq $AssetName) {
        return $Matches.hash.ToLowerInvariant()
      }
    } elseif ($trimmed -match "^[A-Fa-f0-9]{64}$") {
      return $trimmed.ToLowerInvariant()
    }
  }

  throw "Did not find SHA256 entry for '$AssetName'."
}

function Assert-FileSha256 {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Expected
  )

  $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($actual -ne $Expected.ToLowerInvariant()) {
    throw "Checksum mismatch for '$Path'. Expected '$Expected', got '$actual'."
  }
}

function Download-File {
  param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile
  )

  $timeoutSeconds = Get-DownloadTimeoutSeconds
  Invoke-WithRetry -Script {
    # A zero timeout is git's/PowerShell's "wait forever"; only pass the
    # parameter when the operator has NOT asked for that, so the opt-out is a
    # real opt-out rather than `-TimeoutSec 0` meaning something subtly else.
    if ($timeoutSeconds -gt 0) {
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $timeoutSeconds
    } else {
      Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
    }
  } | Out-Null
}

function Download-String {
  param([Parameter(Mandatory = $true)][string]$Url)

  $timeoutSeconds = Get-DownloadTimeoutSeconds
  $content = Invoke-WithRetry -Script {
    if ($timeoutSeconds -gt 0) {
      (Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $timeoutSeconds).Content
    } else {
      (Invoke-WebRequest -Uri $Url -UseBasicParsing).Content
    }
  }

  if ($content -is [byte[]]) {
    return [System.Text.Encoding]::UTF8.GetString($content)
  }
  if (
    $content -is [object[]] -and
    $content.Length -gt 0 -and
    $content[0] -is [byte]
  ) {
    return [System.Text.Encoding]::UTF8.GetString([byte[]]$content)
  }

  return [string]$content
}

function Ensure-CleanDirectory {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (Test-Path $Path) {
    Remove-Item -LiteralPath $Path -Recurse -Force
  }
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Test-BootstrapStepEnabled {
  param([Parameter(Mandatory = $true)][string]$Step)

  $envName = "WINDOWS_DIY_SKIP_$Step"
  $rawValue = [Environment]::GetEnvironmentVariable($envName)
  if ([string]::IsNullOrWhiteSpace($rawValue)) {
    return $true
  }

  $value = $rawValue.Trim().ToLowerInvariant()
  if ($value -in @("1", "true", "yes", "on")) {
    Write-Warning "Skipping bootstrap step '$Step' because $envName=$rawValue."
    return $false
  }

  return $true
}

function ConvertTo-InstallRelativePath {
  param(
    [Parameter(Mandatory = $true)][string]$AbsolutePath,
    [Parameter(Mandatory = $true)][string]$Root
  )

  $absoluteRoot = [System.IO.Path]::GetFullPath($Root)
  $absoluteTarget = [System.IO.Path]::GetFullPath($AbsolutePath)
  $rootPrefix = if ($absoluteRoot.EndsWith([System.IO.Path]::DirectorySeparatorChar)) { $absoluteRoot } else { "$absoluteRoot\" }

  if (-not $absoluteTarget.StartsWith($rootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Expected path '$absoluteTarget' to be under install root '$absoluteRoot'."
  }

  return $absoluteTarget.Substring($rootPrefix.Length).Replace("\", "/")
}

function Get-Sha256HexForString {
  param([Parameter(Mandatory = $true)][string]$Value)

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $hashBytes = [System.Security.Cryptography.SHA256]::HashData($bytes)
  return [System.Convert]::ToHexString($hashBytes).ToLowerInvariant()
}

function Read-KeyValueFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  $result = @{}
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    return $result
  }

  foreach ($line in (Get-Content -LiteralPath $Path)) {
    if ([string]::IsNullOrWhiteSpace($line)) {
      continue
    }
    $trimmed = $line.Trim()
    if ($trimmed.StartsWith("#")) {
      continue
    }
    $separatorIndex = $trimmed.IndexOf("=")
    if ($separatorIndex -lt 1) {
      continue
    }
    $key = $trimmed.Substring(0, $separatorIndex).Trim()
    $value = $trimmed.Substring($separatorIndex + 1).Trim()
    if (-not [string]::IsNullOrWhiteSpace($key)) {
      $result[$key] = $value
    }
  }

  return $result
}

function Write-KeyValueFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$Values
  )

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($key in ($Values.Keys | Sort-Object)) {
    $lines.Add("$key=$($Values[$key])")
  }

  $targetDirectory = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($targetDirectory)) {
    New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
  }

  Set-Content -LiteralPath $Path -Value $lines -Encoding ASCII
}

function Test-KeyValueFileMatches {
  param(
    [Parameter(Mandatory = $true)][hashtable]$Expected,
    [Parameter(Mandatory = $true)][hashtable]$Actual
  )

  foreach ($key in $Expected.Keys) {
    if (-not $Actual.ContainsKey($key)) {
      return $false
    }
    if ([string]$Actual[$key] -ne [string]$Expected[$key]) {
      return $false
    }
  }
  return $true
}

function Get-WindowsTarExe {
  $systemTar = Join-Path $env:SystemRoot "System32/tar.exe"
  if (Test-Path $systemTar) {
    return $systemTar
  }

  $tarCommand = Get-Command tar -ErrorAction SilentlyContinue
  if ($null -ne $tarCommand -and -not [string]::IsNullOrWhiteSpace($tarCommand.Source)) {
    return $tarCommand.Source
  }

  throw "Unable to find tar.exe. Required to extract ct-remote archives."
}

function Find-SystemSevenZipExe {
  $commands = @("7z", "7za", "7zr")
  foreach ($commandName in $commands) {
    $command = Get-Command $commandName -ErrorAction SilentlyContinue
    if ($null -ne $command -and -not [string]::IsNullOrWhiteSpace($command.Source)) {
      return $command.Source
    }
  }

  $candidateRoots = @(
    ${env:ProgramFiles},
    ${env:ProgramFiles(x86)}
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

  foreach ($root in $candidateRoots) {
    $candidate = Join-Path $root "7-Zip/7z.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }

  return $null
}

function Get-SevenZipExe {
  param(
    [string]$Root,
    [hashtable]$Toolchain
  )

  # Prefer any 7-Zip already present (fast path for dev machines that have it
  # installed), but the GHA/self-hosted DIY runners do NOT ship 7-Zip, so fall
  # back to provisioning the pinned standalone 7zr.exe into the DIY cache. This
  # mirrors the Ensure-Gcc WinLibs direct-download fallback and keeps toolchain
  # provisioning in-repo rather than relying on ad-hoc runner state.
  $existing = Find-SystemSevenZipExe
  if ($null -ne $existing) {
    return $existing
  }

  if ([string]::IsNullOrWhiteSpace($Root) -or $null -eq $Toolchain) {
    throw "Unable to find 7-Zip (7z.exe/7za/7zr). Required to extract .7z toolchain archives."
  }

  $version = $Toolchain["SEVENZIP_VERSION"]
  if ([string]::IsNullOrWhiteSpace($version)) {
    throw "Missing SEVENZIP_VERSION in toolchain-versions.env; cannot provision 7zr.exe."
  }
  $expectedSha = $Toolchain["SEVENZIP_WIN_X64_SHA256"]
  if ([string]::IsNullOrWhiteSpace($expectedSha) -or $expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Missing or invalid SEVENZIP_WIN_X64_SHA256 in toolchain-versions.env."
  }

  $sevenZipDir = Join-Path $Root "7zip/$version"
  $sevenZipExe = Join-Path $sevenZipDir "7zr.exe"

  if (Test-Path -LiteralPath $sevenZipExe -PathType Leaf) {
    try {
      Assert-FileSha256 -Path $sevenZipExe -Expected $expectedSha
      return $sevenZipExe
    } catch {
      Remove-Item -LiteralPath $sevenZipExe -Force -ErrorAction SilentlyContinue
    }
  }

  New-Item -ItemType Directory -Force -Path $sevenZipDir | Out-Null
  $downloadUrl = "https://github.com/ip7z/7zip/releases/download/$version/7zr.exe"
  Write-Host "Downloading 7-Zip standalone (7zr.exe $version) from $downloadUrl ..."
  Download-File -Url $downloadUrl -OutFile $sevenZipExe
  Assert-FileSha256 -Path $sevenZipExe -Expected $expectedSha

  if (-not (Test-Path -LiteralPath $sevenZipExe -PathType Leaf)) {
    throw "7-Zip provisioning did not produce '$sevenZipExe'."
  }

  Write-Host "Provisioned 7-Zip $version (7zr.exe) at $sevenZipExe"
  return $sevenZipExe
}

function Get-BashExe {
  $bashCommand = Get-Command bash -ErrorAction SilentlyContinue
  if ($null -eq $bashCommand -or [string]::IsNullOrWhiteSpace($bashCommand.Source)) {
    throw "bash is required for Tup source bootstrap but was not found on PATH. Install Git Bash/MSYS2 and retry."
  }
  return $bashCommand.Source
}

function ConvertTo-BashPath {
  param([Parameter(Mandatory = $true)][string]$WindowsPath)

  $normalized = [System.IO.Path]::GetFullPath($WindowsPath).Replace("\", "/")
  if ($normalized -match '^(?<drive>[A-Za-z]):(?<rest>/.*)$') {
    return "/$($Matches.drive.ToLowerInvariant())$($Matches.rest)"
  }
  return $normalized
}

function Resolve-GitRefToRevision {
  param(
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][string]$RefName
  )

  if ($RefName -match '^[A-Fa-f0-9]{40}$') {
    return $RefName.ToLowerInvariant()
  }

  $gitCommand = Get-Command git -ErrorAction SilentlyContinue
  if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace($gitCommand.Source)) {
    throw "git is required for source bootstrap but was not found on PATH."
  }

  $revisionOutput = & $gitCommand.Source ls-remote --refs $Repository $RefName 2>$null
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to resolve git ref '$RefName' for '$Repository'."
  }

  $firstLine = ($revisionOutput | Select-Object -First 1)
  $firstLine = ([string]$firstLine).Trim()
  if ([string]::IsNullOrWhiteSpace($firstLine)) {
    throw "Ref '$RefName' did not resolve to a revision for '$Repository'."
  }

  $parts = $firstLine -split '\s+'
  if ($parts.Length -lt 1 -or $parts[0] -notmatch '^[A-Fa-f0-9]{40}$') {
    throw "Unexpected ls-remote output while resolving '$RefName' for '$Repository': $firstLine"
  }

  return $parts[0].ToLowerInvariant()
}

function Get-FlakeLockedGithubNode {
  param(
    [Parameter(Mandatory = $true)][string]$FlakeLockPath,
    [Parameter(Mandatory = $true)][string]$NodeName
  )

  if (-not (Test-Path -LiteralPath $FlakeLockPath -PathType Leaf)) {
    throw "Expected flake lock file at '$FlakeLockPath'."
  }

  $flakeLock = Get-Content -LiteralPath $FlakeLockPath -Raw | ConvertFrom-Json
  if ($null -eq $flakeLock -or $null -eq $flakeLock.nodes) {
    throw "flake.lock at '$FlakeLockPath' does not contain a nodes table."
  }

  $node = $flakeLock.nodes.$NodeName
  if ($null -eq $node -or $null -eq $node.locked) {
    throw "flake.lock is missing node '$NodeName' or its locked entry."
  }

  $type = [string]$node.locked.type
  if ($type -ne "github" -and $type -ne "git") {
    throw "flake.lock node '$NodeName' must be github or git locked. Found type '$type'."
  }

  $owner = ""
  $repo = ""
  $rev = [string]$node.locked.rev
  $url = ""

  if ($type -eq "github") {
    $owner = [string]$node.locked.owner
    $repo = [string]$node.locked.repo
    $url = "https://github.com/$owner/$repo.git"
  } else {
    $url = [string]$node.locked.url
    if ($url -match "github\.com/([^/]+)/([^/.]+?)(?:\.git)?$") {
      $owner = $Matches[1]
      $repo = $Matches[2]
    } else {
      throw "flake.lock node '$NodeName' has type 'git' but URL '$url' is not a GitHub URL."
    }
  }

  if (
    [string]::IsNullOrWhiteSpace($owner) -or
    [string]::IsNullOrWhiteSpace($repo) -or
    [string]::IsNullOrWhiteSpace($rev)
  ) {
    throw "flake.lock node '$NodeName' must include locked owner/repo/rev."
  }

  return @{
    owner = $owner
    repo = $repo
    rev = $rev
    url = $url
  }
}

function Resolve-AbsolutePathWithBase {
  param(
    [Parameter(Mandatory = $true)][string]$PathValue,
    [Parameter(Mandatory = $true)][string]$BasePath
  )

  $expanded = [Environment]::ExpandEnvironmentVariables($PathValue)
  if ([System.IO.Path]::IsPathRooted($expanded)) {
    return [System.IO.Path]::GetFullPath($expanded)
  }

  return [System.IO.Path]::GetFullPath((Join-Path $BasePath $expanded))
}

function Get-TupMsys2PackageList {
  param([Parameter(Mandatory = $true)][hashtable]$Toolchain)

  $packagesRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_PACKAGES")
  if ([string]::IsNullOrWhiteSpace($packagesRaw)) {
    $packagesRaw = $Toolchain["TUP_MSYS2_PACKAGES"]
  }
  $packages = @($packagesRaw.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries))
  if ($packages.Count -eq 0) {
    throw "TUP Windows MSYS2 package list is empty. Set TUP_WINDOWS_MSYS2_PACKAGES or add TUP_MSYS2_PACKAGES to toolchain-versions.env."
  }
  return $packages
}

function Ensure-TupMsys2BuildPrereqs {
  param(
    [Parameter(Mandatory = $true)][string]$Root,
    [Parameter(Mandatory = $true)][hashtable]$Toolchain
  )

  $versionRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_VERSION")
  if ([string]::IsNullOrWhiteSpace($versionRaw)) {
    $versionRaw = $Toolchain["TUP_MSYS2_BASE_VERSION"]
  }
  $version = $versionRaw.Trim()
  if ($version -notmatch '^[0-9]{8}$') {
    throw "Invalid TUP_WINDOWS_MSYS2_BASE_VERSION '$versionRaw'. Expected YYYYMMDD."
  }

  $expectedShaRaw = [Environment]::GetEnvironmentVariable("TUP_WINDOWS_MSYS2_BASE_X64_SHA256")
  if ([string]::IsNullOrWhiteSpace($expectedShaRaw)) {
    $expectedShaRaw = $Toolchain["TUP_MSYS2_BASE_X64_SHA256"]
  }
  $expectedSha = $expectedShaRaw.Trim().ToLowerInvariant()
  if ($expectedSha -notmatch '^[A-Fa-f0-9]{64}$') {
    throw "Invalid TUP_WINDOWS_MSYS2_BASE_X64_SHA256 value '$expectedShaRaw'."
  }

  $msys2Root = Join-Path $Root "tup/msys2/$version"
  $msysInstallRoot = Join-Path $msys2Root "msys64"
  $msysBashExe = Join-Path $msysInstallRoot "usr/bin/bash.exe"
  $archiveName = "msys2-base-x86_64-$version.tar.xz"
  $baseUrl = "https://github.com/msys2/msys2-installer/releases/download/$($version.Substring(0,4))-$($version.Substring(4,2))-$($version.Substring(6,2))"
  $assetUrl = "$baseUrl/$archiveName"
  $shaUrl = "$assetUrl.sha256"
  $archivePath = Join-Path $env:TEMP $archiveName
  $installMetaFile = Join-Path $msys2Root "msys2.install.meta"
  $packages = Get-TupMsys2PackageList -Toolchain $Toolchain
  $packageList = ($packages -join " ")

  $expectedMetadata = @{
    tup_msys2_version = $version
    tup_msys2_archive_sha256 = $expectedSha
    tup_msys2_packages = $packageList
  }

  if ((Test-Path -LiteralPath $msysBashExe -PathType Leaf) -and (Test-Path -LiteralPath $installMetaFile -PathType Leaf)) {
    $installedMetadata = Read-KeyValueFile -Path $installMetaFile
    if (Test-KeyValueFileMatches -Expected $expectedMetadata -Actual $installedMetadata) {
      return @{
        root = $msysInstallRoot
        bashExe = $msysBashExe
        metadata = $expectedMetadata
      }
    }
  }

  Download-File -Url $assetUrl -OutFile $archivePath
  try {
    Assert-FileSha256 -Path $archivePath -Expected $expectedSha
  } catch {
    $shaText = Download-String -Url $shaUrl
    $shaFromSidecar = Get-ExpectedSha256 -ShaSource $shaText -AssetName $archiveName
    if ($shaFromSidecar -ne $expectedSha) {
      throw "Pinned TUP MSYS2 SHA mismatch for '$archiveName'. toolchain pin: $expectedSha, sidecar: $shaFromSidecar"
    }
    throw
  }

  Ensure-CleanDirectory -Path $msys2Root
  New-Item -ItemType Directory -Force -Path $msys2Root | Out-Null
  $tarExe = Get-WindowsTarExe
  # Keep native command output visible in the console while preventing it from
  # becoming function pipeline output (which would corrupt the hashtable return value).
  & $tarExe -xJf $archivePath -C $msys2Root | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to extract MSYS2 Tup prerequisite archive '$archivePath'."
  }
  if (-not (Test-Path -LiteralPath $msysBashExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite bootstrap did not produce '$msysBashExe'."
  }

  $packageArgs = ($packages | ForEach-Object { $_.Trim() }) -join " "
  $packageInstallCommand = "set -euo pipefail; pacman -Sy --noconfirm --needed $packageArgs"
  & $msysBashExe -lc $packageInstallCommand | Out-Host
  if ($LASTEXITCODE -ne 0) {
    throw "Failed to install Tup MSYS2 prerequisite packages ($packageArgs)."
  }

  $mingwGccExe = Join-Path $msysInstallRoot "mingw64/bin/gcc.exe"
  $mingwPkgConfigExe = Join-Path $msysInstallRoot "mingw64/bin/pkg-config.exe"
  $msysMakeExe = Join-Path $msysInstallRoot "usr/bin/make.exe"
  if (-not (Test-Path -LiteralPath $mingwGccExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite install is incomplete. Missing MinGW compiler at '$mingwGccExe'."
  }
  if (-not (Test-Path -LiteralPath $mingwPkgConfigExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite install is incomplete. Missing MinGW pkg-config at '$mingwPkgConfigExe'."
  }
  if (-not (Test-Path -LiteralPath $msysMakeExe -PathType Leaf)) {
    throw "MSYS2 Tup prerequisite install is incomplete. Missing make at '$msysMakeExe'."
  }

  Write-KeyValueFile -Path $installMetaFile -Values $expectedMetadata
  return @{
    root = $msysInstallRoot
    bashExe = $msysBashExe
    metadata = $expectedMetadata
  }
}
